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

# ── classify_secrets_response(http_code) ───────────────────────────────────────
# The predicate behind issue #11: a 404 (project/env/path not yet provisioned
# in Infisical, e.g. SecretPathNotFound) must skip only this stack; every other
# non-200 status must still be treated as a real failure.

assert_eq "ok" "$(classify_secrets_response "200")" \
    '200 proceeds normally'

assert_eq "skip" "$(classify_secrets_response "404")" \
    '404 (SecretPathNotFound / project or env not provisioned) is skippable'

assert_eq "fail" "$(classify_secrets_response "400")" \
    '400 is not silently swallowed — surfaces as a failure'

assert_eq "fail" "$(classify_secrets_response "401")" \
    '401 (bad Infisical credentials) surfaces as a failure'

assert_eq "fail" "$(classify_secrets_response "403")" \
    '403 (unauthorized) surfaces as a failure'

assert_eq "fail" "$(classify_secrets_response "500")" \
    '500 (Infisical server error) surfaces as a failure'

assert_eq "fail" "$(classify_secrets_response "000")" \
    'curl network failure (000) surfaces as a failure, not a silent skip'

printf 'PASS: redeploy Infisical skip-on-404 classification\n'
