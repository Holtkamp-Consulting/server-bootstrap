#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# awk-extract only the pure helper — redeploy-stacks.sh runs top-to-bottom with
# no `main` guard, so sourcing the whole file would fire its API calls.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { capture = 1 }
        capture { print }
        capture && /^}$/ { capture = 0 }
    ' "$ROOT_DIR/redeploy-stacks.sh"
}
eval "$(extract_fn classify_secrets_response)"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# ── classify_secrets_response(http_code) ────────────────────────────────────────────────
# The whole 4xx family that says "this project has no such environment/path"
# (issue #46: an n8n project with no `dev` environment on a Dev-Pi) must skip
# only this stack. 401 and every transient status must still fail loudly.

assert_eq "ok" "$(classify_secrets_response "200")" \
    '200 proceeds normally'

assert_eq "skip" "$(classify_secrets_response "404")" \
    '404 (SecretPathNotFound / project or env not provisioned) is skippable'

assert_eq "skip" "$(classify_secrets_response "400")" \
    '400 (environment slug unknown in this project) is skippable'

assert_eq "skip" "$(classify_secrets_response "403")" \
    '403 (no access to this environment in this project) is skippable'

assert_eq "fail" "$(classify_secrets_response "401")" \
    '401 (bad/expired Machine Identity token) surfaces as a failure'

assert_eq "fail" "$(classify_secrets_response "429")" \
    '429 (rate limited) surfaces as a failure, not a silent skip'

assert_eq "fail" "$(classify_secrets_response "500")" \
    '500 (Infisical server error) surfaces as a failure'

assert_eq "fail" "$(classify_secrets_response "502")" \
    '502 (Infisical gateway error) surfaces as a failure'

assert_eq "fail" "$(classify_secrets_response "000")" \
    'curl network failure (000) surfaces as a failure, not a silent skip'

# ── what the classified response does to this script's exit code ─────────────
# Anchored on code (not line numbers) so the test drives the shipped block.
extract_secrets_branch() {
    awk '
        /^case "\$\(classify_secrets_response/ { capture = 1 }
        capture { print }
        capture && /^esac$/ { exit }
    ' "$ROOT_DIR/redeploy-stacks.sh"
}

run_secrets_branch() {
    local driver out status
    driver=$(mktemp)
    {
        printf '%s\n' \
            'set -euo pipefail' \
            'SECRETS_HTTP="$1"; SECRETS_RESP="{}"' \
            'STACK_NAME=stack; PROJECT_ID=proj' \
            'INFISICAL_ENV=dev; INFISICAL_PATH=/'
        grep -m1 '^EXIT_SKIPPED=' "$ROOT_DIR/redeploy-stacks.sh"
        extract_fn classify_secrets_response
        extract_secrets_branch
        printf '%s\n' 'echo deployed'
    } > "$driver"

    out=$(bash "$driver" "$1" 2>/dev/null) && status=0 || status=$?
    rm -f "$driver"
    if grep -qx deployed <<<"$out"; then
        printf '%s deployed' "$status"
    else
        printf '%s not-deployed' "$status"
    fi
}

assert_eq "0 deployed" "$(run_secrets_branch 200)" \
    '200 deploys the stack'

# A skip must not look like a successful redeploy: maintenance-redeploy.sh has
# already stopped the stack and pruned its image before calling this script, so
# an exit 0 here would leave it down while the job reports success.
assert_eq "3 not-deployed" "$(run_secrets_branch 400)" \
    '400 exits with the distinct skip code'
assert_eq "3 not-deployed" "$(run_secrets_branch 403)" \
    '403 exits with the distinct skip code'
assert_eq "3 not-deployed" "$(run_secrets_branch 404)" \
    '404 exits with the distinct skip code'

assert_eq "1 not-deployed" "$(run_secrets_branch 401)" \
    '401 fails the run'
assert_eq "1 not-deployed" "$(run_secrets_branch 429)" \
    '429 fails the run'
assert_eq "1 not-deployed" "$(run_secrets_branch 500)" \
    '500 fails the run'
assert_eq "1 not-deployed" "$(run_secrets_branch 000)" \
    'a network failure fails the run'

printf 'PASS: redeploy Infisical secrets-response classification\n'
