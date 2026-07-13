#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# awk-extract only the pure helpers — redeploy-stacks.sh runs top-to-bottom
# with no `main` guard, so sourcing the whole file would fire its API calls.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { capture = 1 }
        capture { print }
        capture && /^}$/ { capture = 0 }
    ' "$ROOT_DIR/redeploy-stacks.sh"
}
eval "$(extract_fn stack_project_containers)"
eval "$(extract_fn should_clean_stack)"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# stack_project_containers reads the global STACK_NAME and matches it
# case-insensitively (lowercasing both sides inside jq via ascii_downcase), so
# the fixtures below use mixed case on purpose.
STACK_NAME="MyApp"

containers='[
  {"Id":"c1","ImageID":"sha256:aaa","Labels":{"com.docker.compose.project":"myapp"}},
  {"Id":"c2","ImageID":"sha256:bbb","Labels":{"com.docker.compose.project":"other"}},
  {"Id":"c3","ImageID":"sha256:ccc","Labels":{}}
]'

assert_eq \
    "c1 sha256:aaa" \
    "$(printf '%s' "$containers" | stack_project_containers)" \
    'only the case-insensitively matching compose-project container is selected'

# Container missing the com.docker.compose.project label is excluded (no crash).
missing_label='[
  {"Id":"c3","ImageID":"sha256:ccc","Labels":{}}
]'
assert_eq \
    "" \
    "$(printf '%s' "$missing_label" | stack_project_containers)" \
    'container without a compose-project label yields no rows'

# Multiple matching containers → one row each, in order.
multi_match='[
  {"Id":"c1","ImageID":"sha256:aaa","Labels":{"com.docker.compose.project":"MYAPP"}},
  {"Id":"c4","ImageID":"sha256:ddd","Labels":{"com.docker.compose.project":"MyApp"}}
]'
assert_eq \
    $'c1 sha256:aaa\nc4 sha256:ddd' \
    "$(printf '%s' "$multi_match" | stack_project_containers)" \
    'every matching container is emitted as an Id ImageID row'

assert_eq \
    "" \
    "$(printf '%s' '[]' | stack_project_containers)" \
    'empty container array yields no rows'

# ── should_clean_stack guard ──────────────────────────────────────────────────
# The single most consequential predicate in the feature: it decides whether the
# destructive cleanup runs. A regression here is a self-inflicted runner outage.
assert_clean() {
    local stack="$1" keep="$2" expected="$3" label="$4"
    local actual
    STACK_NAME="$stack" KEEP_IMAGES="$keep" should_clean_stack && actual="yes" || actual="no"
    assert_eq "$expected" "$actual" "$label"
}

assert_clean "focus"         ""  "yes" 'normal stack is cleaned'
assert_clean "github-runner" ""  "no"  'github-runner is never cleaned (cannot stop itself mid-job)'
assert_clean "focus"         "1" "no"  'KEEP_IMAGES=1 (--keep-images) suppresses cleanup'
assert_clean "github-runner" "1" "no"  'both guards together still skip'

printf 'PASS: redeploy image cleanup\n'
