#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# awk-extract only the pure helper — install.sh runs top-to-bottom and would
# execute its full bootstrap if sourced.
extract_fn() {
    awk -v fn="$2" '
        $0 ~ "^" fn "\\(\\) \\{" { capture = 1 }
        capture { print }
        capture && /^}$/ { capture = 0 }
    ' "$ROOT_DIR/$1"
}

# The deploy loop's response branch, anchored on code (not line numbers) so the
# test drives the shipped block itself rather than a copy of it.
extract_secrets_branch() {
    awk '
        /^    SECRETS_STATE="\$\(classify_secrets_response/ { capture = 1 }
        capture { print }
        capture && /^    esac$/ { exit }
    ' "$ROOT_DIR/install.sh"
}

eval "$(extract_fn install.sh classify_secrets_response)"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# ── classify_secrets_response(http_code) ──────────────────────────────────────
# GET /api/v4/secrets is environment-scoped, so the 4xx family meaning "this
# project has no such environment/path" (issue #46: an n8n project with no
# `dev` environment on a Dev-Pi) must skip one stack, never abort the install.
assert_eq "ok"   "$(classify_secrets_response "200")" '200 proceeds normally'
assert_eq "skip" "$(classify_secrets_response "400")" '400 (environment slug unknown in this project) is skippable'
assert_eq "skip" "$(classify_secrets_response "403")" '403 (no access to this environment in this project) is skippable'
assert_eq "skip" "$(classify_secrets_response "404")" '404 (SecretPathNotFound) is skippable'
assert_eq "fail" "$(classify_secrets_response "401")" '401 (bad/expired Machine Identity token) is a hard failure'
assert_eq "fail" "$(classify_secrets_response "429")" '429 (rate limited) is a hard failure, not a silent skip'
assert_eq "fail" "$(classify_secrets_response "500")" '500 (Infisical server error) is a hard failure'
assert_eq "fail" "$(classify_secrets_response "502")" '502 (Infisical gateway error) is a hard failure'
assert_eq "fail" "$(classify_secrets_response "000")" 'curl network failure (000) is a hard failure, not a silent skip'

# ── the deploy loop's secrets branch ──────────────────────────────────────────
# Runs the extracted branch over a two-stack loop and reports what survived:
# "<exit code> skipped=<n> deployed=<n>". The regression this guards is the
# whole install dying on stack 1 (issue #46) — deployed=0 with a non-zero exit.
run_secrets_branch() {
    local http="$1" json="$2" driver
    driver=$(mktemp)
    {
        printf '%s\n' \
            'set -euo pipefail' \
            'warn() { :; }' \
            'err()  { :; }' \
            'STACK_NAME=stack; STACK_PROJECT_NAME=stack; STACK_PROJECT_ID=proj' \
            'INFISICAL_ENV=dev; INFISICAL_PATH=/' \
            'SECRETS_HTTP="$1"; SECRETS_JSON="$2"' \
            'SKIPPED_STACKS=(); DEPLOYED_STACKS=()'
        extract_fn install.sh classify_secrets_response
        printf '%s\n' 'for STACK_NAME in first second; do'
        extract_secrets_branch
        printf '%s\n' \
            '    DEPLOYED_STACKS+=("$STACK_NAME")' \
            'done' \
            'printf "skipped=%s deployed=%s\n" "${#SKIPPED_STACKS[@]}" "${#DEPLOYED_STACKS[@]}"'
    } > "$driver"

    local out status
    out=$(bash "$driver" "$http" "$json" 2>/dev/null) && status=0 || status=$?
    rm -f "$driver"
    printf '%s %s' "$status" "${out:-<no-output>}"
}

SECRETS_OK='{"secrets":[{"secretKey":"A","secretValue":"1"}]}'
SECRETS_ERR='{"statusCode":403,"error":"Forbidden"}'

assert_eq "0 skipped=0 deployed=2" "$(run_secrets_branch 200 "$SECRETS_OK")" \
    '200 with a secrets array deploys every stack'

# Issue #46 proper: one stack without a `dev` environment must not take the
# rest of the install (and Steps 7-9) down with it.
assert_eq "0 skipped=2 deployed=0" "$(run_secrets_branch 403 "$SECRETS_ERR")" \
    '403 skips the stack and the loop continues'
assert_eq "0 skipped=2 deployed=0" "$(run_secrets_branch 400 "$SECRETS_ERR")" \
    '400 skips the stack and the loop continues'
assert_eq "0 skipped=2 deployed=0" "$(run_secrets_branch 404 "$SECRETS_ERR")" \
    '404 skips the stack and the loop continues'

assert_eq "1 <no-output>" "$(run_secrets_branch 401 "$SECRETS_ERR")" \
    '401 aborts the install — the Machine Identity itself is unusable'
assert_eq "1 <no-output>" "$(run_secrets_branch 429 "$SECRETS_ERR")" \
    '429 aborts instead of quietly dropping stacks'
assert_eq "1 <no-output>" "$(run_secrets_branch 503 "$SECRETS_ERR")" \
    '503 aborts instead of quietly dropping stacks'
assert_eq "1 <no-output>" "$(run_secrets_branch 000 "$SECRETS_ERR")" \
    'a network failure aborts instead of quietly dropping stacks'
assert_eq "1 <no-output>" "$(run_secrets_branch 200 '{"secrets":"not-an-array"}')" \
    'a 200 without a secrets array aborts instead of being skipped as missing'

# ── install.sh and redeploy-stacks.sh must agree ──────────────────────────────
# The two scripts carry independent copies (install.sh downloads
# redeploy-stacks.sh onto the server at install time; there is no shared lib).
# When they disagree, a stack install.sh skips fails the weekly maintenance
# redeploy instead — the divergence issue #46 found between 400/429/5xx/000.
assert_eq "$(extract_fn install.sh classify_secrets_response)" \
    "$(extract_fn redeploy-stacks.sh classify_secrets_response)" \
    'both scripts classify secrets responses identically'

printf 'PASS: install Infisical secrets-response classification and skip branch\n'
