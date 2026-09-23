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

printf 'PASS: redeploy Infisical secrets-response classification\n'
