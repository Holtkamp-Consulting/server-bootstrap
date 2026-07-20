#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# awk-extract only the pure helper — maintenance-redeploy.sh runs top-to-bottom
# with no `main` guard, so sourcing the whole file would fire its API calls.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { capture = 1 }
        capture { print }
        capture && /^}$/ { capture = 0 }
    ' "$ROOT_DIR/maintenance-redeploy.sh"
}
eval "$(extract_fn redeploy_branch_for_env)"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# ── redeploy_branch_for_env(env) ───────────────────────────────────────────
# Selects which branch's images the weekly maintenance redeploy pulls. A wrong
# answer here means the maintenance job silently redeploys the wrong branch's
# images on that host every Saturday.
assert_eq "dev"  "$(redeploy_branch_for_env dev)"     'dev env → dev branch'
assert_eq "main" "$(redeploy_branch_for_env prod)"    'prod env → main branch'
assert_eq "main" "$(redeploy_branch_for_env staging)" 'staging env → main branch'
assert_eq "main" "$(redeploy_branch_for_env '')"      'empty env → main (safe default)'

printf 'PASS: maintenance redeploy branch resolution\n'
