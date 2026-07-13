#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# awk-extract only the pure helper — install.sh runs top-to-bottom and would
# execute its full bootstrap if sourced.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { capture = 1 }
        capture { print }
        capture && /^}$/ { capture = 0 }
    ' "$ROOT_DIR/install.sh"
}
eval "$(extract_fn deploy_branch_for_env)"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# ── deploy_branch_for_env(env) ────────────────────────────────────────────────
# Decides which branch's images a host runs. A wrong answer here is exactly the
# bug this fixes: a dev host must run `dev` images, not `main` (`:latest`).
assert_eq "dev"  "$(deploy_branch_for_env dev)"     'dev env → dev branch'
assert_eq "main" "$(deploy_branch_for_env prod)"    'prod env → main branch'
assert_eq "main" "$(deploy_branch_for_env staging)" 'staging env → main branch'
assert_eq "main" "$(deploy_branch_for_env '')"      'empty env → main (safe default)'
assert_eq "main" "$(deploy_branch_for_env unknown)" 'unknown env → main (safe default)'

printf 'PASS: install deploy branch resolution\n'
