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
eval "$(extract_fn resolve_default_image_tag)"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# ── resolve_default_image_tag(explicit_tag, ref) ──────────────────────────────
# The predicate behind the stale-deploy fix: an explicit per-commit tag must
# win over the branch moving-tag, otherwise Portainer keeps reusing the cached
# digest of dev/main and never deploys the freshly-built image.

# 1. Explicit per-commit tag wins and is returned verbatim.
assert_eq \
    "sha-0123456789abcdef" \
    "$(resolve_default_image_tag "sha-0123456789abcdef" "refs/heads/dev")" \
    'explicit --image-tag / $DEPLOY_IMAGE_TAG takes precedence over the branch'

# 2. No explicit tag → fall back to the branch name from a refs/heads ref.
assert_eq \
    "dev" \
    "$(resolve_default_image_tag "" "refs/heads/dev")" \
    'empty explicit tag falls back to the refs/heads branch moving-tag'

assert_eq \
    "main" \
    "$(resolve_default_image_tag "" "refs/heads/main")" \
    'main branch ref resolves to the main moving-tag'

# 3. A tag ref also strips its prefix (belt-and-suspenders for manual runs).
assert_eq \
    "v1.2.3" \
    "$(resolve_default_image_tag "" "refs/tags/v1.2.3")" \
    'refs/tags/ prefix is stripped to the bare tag'

# 4. Neither an explicit tag nor a ref → empty (caller then injects nothing and
#    compose's ${IMAGE_TAG:-latest} default applies).
assert_eq \
    "" \
    "$(resolve_default_image_tag "" "")" \
    'no explicit tag and no ref yields an empty default'

# 5. An explicit tag wins even when a ref is also present (the CI redeploy path:
#    --ref refs/heads/dev + DEPLOY_IMAGE_TAG=sha-<sha> together).
assert_eq \
    "sha-deadbeef" \
    "$(resolve_default_image_tag "sha-deadbeef" "refs/heads/dev")" \
    'explicit tag still wins when a branch ref is supplied alongside it'

printf 'PASS: redeploy image tag resolution\n'
