#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# awk-extract the pure-ish helpers plus the Step 7 orchestration function —
# install.sh runs top-to-bottom and would execute its full bootstrap if
# sourced directly.
eval "$(
    awk '
        /^quote_env_value\(\) \{/ { capture = 1 }
        /^resolve_portainer_admin_id\(\) \{/ { capture = 1 }
        /^mint_portainer_access_token\(\) \{/ { capture = 1 }
        /^deploy_portainer_proxy\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { capture = 0 }
    ' "$ROOT_DIR/install.sh"
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

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'FAIL: %s\nexpected to contain: %q\nactual: %q\n' "$label" "$needle" "$haystack" >&2
        exit 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        printf 'FAIL: %s\nexpected NOT to contain: %q\nactual: %q\n' "$label" "$needle" "$haystack" >&2
        exit 1
    fi
}

tmp_root="$(mktemp -d)"
tmp_bin="$tmp_root/bin"
mkdir -p "$tmp_bin"
trap 'rm -rf "$tmp_root"' EXIT

# deploy_portainer_proxy logs via log/ok/warn/err — capture their output
# instead of the real ANSI-colored versions so assertions can inspect it.
CAPTURED_LOG=""
log()  { CAPTURED_LOG+="LOG:${*}"$'\n'; }
ok()   { CAPTURED_LOG+="OK:${*}"$'\n'; }
warn() { CAPTURED_LOG+="WARN:${*}"$'\n'; }
err()  { CAPTURED_LOG+="ERR:${*}"$'\n'; }

# sudo is stubbed, not invoked for real: rewrite any /opt/deploy/* argument to
# a path under tmp_root so `sudo mkdir`/`sudo tee` exercise the exact code
# path against a throwaway directory instead of the real host filesystem, and
# no-op the ownership calls that only make sense as root.
cat > "$tmp_bin/sudo" <<EOF
#!/bin/bash
args=()
for a in "\$@"; do
    case "\$a" in
        /opt/deploy/*) a="$tmp_root\$a" ;;
    esac
    args+=("\$a")
done
case "\${args[0]}" in
    chown|chmod) exit 0 ;;
    *) exec "\${args[@]}" ;;
esac
EOF
chmod +x "$tmp_bin/sudo"

DOCKER_RUN_LOG="$tmp_root/docker_run.log"
CURL_CALL_LOG="$tmp_root/curl_calls.log"

# docker: `ps --format` reports whether portainer-proxy is already running
# (controlled per-case via $DOCKER_PS_OUTPUT); `run` just records its
# invocation so tests can assert whether/how the container was (re)started.
cat > "$tmp_bin/docker" <<EOF
#!/bin/bash
if [[ "\$1" == "ps" ]]; then
    cat "$tmp_root/docker_ps_output" 2>/dev/null || true
    exit 0
fi
if [[ "\$1" == "run" ]]; then
    printf '%s\n' "\$*" >> "$DOCKER_RUN_LOG"
    exit 0
fi
exit 0
EOF
chmod +x "$tmp_bin/docker"

# curl: dispatches on the request URL/args, controlled per-case via env vars
# so each scenario only needs to declare the responses it actually exercises.
cat > "$tmp_bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CURL_CALL_LOG"

output_file=""
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
    case "\${args[\$i]}" in
        -o) output_file="\${args[\$((i + 1))]}" ;;
    esac
done

if [[ "\$*" == *"/api/endpoints"* ]]; then
    [ "\${TOKEN_VALIDATION_OK:-1}" = "1" ] && exit 0 || exit 22
fi
if [[ "\$*" == *"/api/users/me"* ]]; then
    [ -n "\$output_file" ] && printf '{"Id": 7}' > "\$output_file"
    printf '200'
    exit 0
fi
if [[ "\$*" == *"/tokens"* ]]; then
    [ -n "\$output_file" ] && printf '{"rawAPIKey": "%s"}' "\${MINTED_TOKEN:-minted-token}" > "\$output_file"
    printf '200'
    exit 0
fi
if [[ "\$*" == *"/caddy/portainer-proxy.Caddyfile"* ]]; then
    printf ':__PROXY_PORT__ { reverse_proxy __PORTAINER_UPSTREAM__ }'
    exit 0
fi
if [[ "\$*" == *"/api/status"* ]]; then
    exit 0
fi
exit 0
EOF
chmod +x "$tmp_bin/curl"

run_deploy_portainer_proxy() {
    local ps_output="$1"
    local deploy_config="$2"

    printf '%s' "$ps_output" > "$tmp_root/docker_ps_output"
    : > "$DOCKER_RUN_LOG"
    : > "$CURL_CALL_LOG"
    CAPTURED_LOG=""

    PATH="$tmp_bin:$PATH" \
    DOCKER="docker" \
    DEPLOY_CONFIG="$deploy_config" \
    PORTAINER_URL="https://portainer.test" \
    PORTAINER_PROXY_PORT="9444" \
    PORTAINER_PORT_HTTP="9000" \
    PORTAINER_PASSWORD="admin-pw" \
    RAW_BASE="https://raw.githubusercontent.com/example/repo/main" \
    deploy_portainer_proxy "fake-admin-jwt"
}

# ── Branch 1: portainer-proxy already running → retrofit no-op ──────────────
deploy_config="$tmp_root/deploy-skip.env"
: > "$deploy_config"
run_deploy_portainer_proxy "portainer-proxy" "$deploy_config"

assert_contains "$CAPTURED_LOG" "already running — skipping" \
    'already-running host reports the idempotency skip'
assert_eq "" "$(cat "$DOCKER_RUN_LOG")" \
    'already-running host never issues a docker run'
assert_eq "" "$(cat "$CURL_CALL_LOG")" \
    'already-running host makes no Portainer API calls at all'

# ── Branch 2: no existing token → fresh mint, appended to deploy config ─────
deploy_config="$tmp_root/deploy-mint.env"
: > "$deploy_config"
MINTED_TOKEN="fresh-token-abc" \
    run_deploy_portainer_proxy "" "$deploy_config"

assert_contains "$CAPTURED_LOG" "Creating Portainer access token" \
    'no reusable token on disk triggers the mint path'
assert_contains "$CAPTURED_LOG" "Portainer read-only proxy started on port 9444" \
    'proxy readiness check passes and reports success'
assert_contains "$(cat "$deploy_config")" "PORTAINER_ACCESS_TOKEN='fresh-token-abc'" \
    'freshly minted token is persisted to the deploy config'
assert_contains "$(cat "$DOCKER_RUN_LOG")" "PORTAINER_ACCESS_TOKEN=fresh-token-abc" \
    'freshly minted token is wired into the docker run invocation'

# ── Branch 3: valid existing token → reused, no mint call ───────────────────
deploy_config="$tmp_root/deploy-reuse.env"
printf "PORTAINER_ACCESS_TOKEN='existing-valid-token'\n" > "$deploy_config"
TOKEN_VALIDATION_OK=1 PORTAINER_ACCESS_TOKEN="existing-valid-token" \
    run_deploy_portainer_proxy "" "$deploy_config"

assert_contains "$CAPTURED_LOG" "Reusing existing Portainer access token" \
    'a token that still validates is reused rather than re-minted'
assert_not_contains "$(cat "$CURL_CALL_LOG")" "/tokens" \
    'reuse path never calls the token-minting endpoint'
assert_contains "$(cat "$DOCKER_RUN_LOG")" "PORTAINER_ACCESS_TOKEN=existing-valid-token" \
    'reused token is wired into the docker run invocation'

# ── Branch 4: stale/revoked existing token → validation fails, re-minted ────
deploy_config="$tmp_root/deploy-stale.env"
printf "PORTAINER_ACCESS_TOKEN='stale-revoked-token'\n" > "$deploy_config"
TOKEN_VALIDATION_OK=0 MINTED_TOKEN="rotated-token-xyz" PORTAINER_ACCESS_TOKEN="stale-revoked-token" \
    run_deploy_portainer_proxy "" "$deploy_config"

assert_contains "$CAPTURED_LOG" "no longer valid — minting a new one" \
    'a token that fails validation is not silently reused'
assert_contains "$CAPTURED_LOG" "Creating Portainer access token" \
    'validation failure falls through to the mint path'
assert_contains "$(cat "$deploy_config")" "PORTAINER_ACCESS_TOKEN='rotated-token-xyz'" \
    'rotated token replaces the stale one in the deploy config'
assert_not_contains "$(cat "$deploy_config")" "stale-revoked-token" \
    'stale token line is removed, not left alongside the new one (no duplicate keys)'

# ── Step N/9 renumbering sanity check ────────────────────────────────────────
# Guards against a future edit reintroducing a gap or duplicate in the
# "Step N/9" log lines (e.g. this PR's own 1/8→1/9 ... 8/8→9/9 renumbering).
step_numbers="$(grep -o 'Step [0-9]*/9' "$ROOT_DIR/install.sh" | sed 's#Step ##; s#/9##' | sort -n)"
assert_eq \
    "$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9')" \
    "$step_numbers" \
    'Step N/9 log lines cover exactly 1 through 9 with no gaps or duplicates'

printf 'PASS: install portainer proxy step (idempotency skip / token reuse / mint)\n'
