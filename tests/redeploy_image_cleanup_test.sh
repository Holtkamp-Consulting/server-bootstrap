#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# awk-extract only the pure parsing helper — redeploy-stacks.sh runs top-to-bottom
# with no `main` guard, so sourcing the whole file would fire its API calls.
eval "$(
    awk '
        /^stack_project_containers\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { capture = 0 }
    ' "$ROOT_DIR/redeploy-stacks.sh"
)"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# stack_project_containers reads STACK_NAME from the environment via ${STACK_NAME,,}.
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

printf 'PASS: redeploy image cleanup\n'
