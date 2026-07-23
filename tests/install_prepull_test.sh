#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

eval "$(
    awk '
        /^prepull_stack_images\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { capture = 0 }
    ' "$ROOT_DIR/install.sh"
)"

log()  { :; }
ok()   { :; }
warn() { :; }

assert_status() {
    local expected="$1" label="$2"
    shift 2
    local actual=0
    "$@" || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected status: %s\nactual status:   %s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

tmp_bin="$(mktemp -d)"
trap 'rm -rf "$tmp_bin"' EXIT

DOCKER="docker"
STACK_NAME="test-stack"

# 1. Missing docker CLI → return 1, no crash. Fully empty PATH is safe here
# since the docker-CLI check is the function's very first statement, run
# before any jq/curl/grep call that would otherwise need the real PATH.
PATH="$tmp_bin" GITHUB_TOKEN=x REPO=x DEPLOY_BRANCH=main ENV_JSON='[]' \
    assert_status 1 'missing docker CLI returns 1' prepull_stack_images

# 2. docker present, but compose fetch fails (curl mock exits nonzero) → return 1.
cat > "$tmp_bin/docker" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$tmp_bin/curl" <<'EOF'
#!/bin/bash
exit 22
EOF
chmod +x "$tmp_bin/docker" "$tmp_bin/curl"
PATH="$tmp_bin:$PATH" GITHUB_TOKEN=x REPO=x DEPLOY_BRANCH=main ENV_JSON='[]' \
    assert_status 1 'compose fetch failure returns 1' prepull_stack_images

# 3. Compose has no ghcr.io images → return 1 (nothing to pull).
cat > "$tmp_bin/curl" <<'EOF'
#!/bin/bash
printf 'services:\n  grafana:\n    image: grafana/grafana:latest\n'
EOF
chmod +x "$tmp_bin/curl"
PATH="$tmp_bin:$PATH" GITHUB_TOKEN=x REPO=x DEPLOY_BRANCH=main ENV_JSON='[]' \
    assert_status 1 'no ghcr.io images returns 1' prepull_stack_images

# 4. docker login fails → return 1.
cat > "$tmp_bin/curl" <<'EOF'
#!/bin/bash
printf 'services:\n  app:\n    image: ghcr.io/holtkamp-consulting/app:latest\n'
EOF
cat > "$tmp_bin/docker" <<'EOF'
#!/bin/bash
[ "$1" = "login" ] && exit 1
exit 0
EOF
chmod +x "$tmp_bin/curl" "$tmp_bin/docker"
PATH="$tmp_bin:$PATH" GITHUB_TOKEN=x REPO=x DEPLOY_BRANCH=main ENV_JSON='[]' \
    assert_status 1 'docker login failure returns 1' prepull_stack_images

# 5. All commands succeed → return 0.
cat > "$tmp_bin/docker" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$tmp_bin/docker"
PATH="$tmp_bin:$PATH" GITHUB_TOKEN=x REPO=x DEPLOY_BRANCH=main ENV_JSON='[]' \
    assert_status 0 'full success path returns 0' prepull_stack_images

printf 'PASS: install prepull_stack_images\n'
