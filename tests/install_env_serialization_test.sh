#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

eval "$(
    awk '
        /^normalize_private_key\(\) \{/ { capture = 1 }
        /^quote_env_value\(\) \{/ { capture = 1 }
        /^extract_portainer_endpoint_id\(\) \{/ { capture = 1 }
        /^create_local_portainer_endpoint\(\) \{/ { capture = 1 }
        /^extract_portainer_registry_id\(\) \{/ { capture = 1 }
        /^ensure_ghcr_registry\(\) \{/ { capture = 1 }
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

tmp_env="$(mktemp)"
tmp_bin="$(mktemp -d)"
trap 'rm -f "$tmp_env"; rm -rf "$tmp_bin"' EXIT

private_key_raw=$'BEGIN TEST KEY\nline with spaces\nEND TEST KEY'
private_key="$(normalize_private_key "$private_key_raw")"

printf 'APP_PRIVATE_KEY=%s\n' "$(quote_env_value "$private_key")" > "$tmp_env"
source "$tmp_env"

assert_eq \
    $'BEGIN TEST KEY\nline with spaces\nEND TEST KEY' \
    "$APP_PRIVATE_KEY" \
    'private key keeps real newlines when sourced'

quoted_secret="$(quote_env_value "token with spaces and ' quote")"
printf 'SECRET=%s\n' "$quoted_secret" > "$tmp_env"
source "$tmp_env"

assert_eq \
    "token with spaces and ' quote" \
    "$SECRET" \
    'single quotes are escaped for sourceable env files'

prefixed_key='APP_PRIVATE_KEY=BEGIN TEST KEY'
stripped_key="$(normalize_private_key "$prefixed_key")"

assert_eq \
    'BEGIN TEST KEY' \
    "$stripped_key" \
    'optional APP_PRIVATE_KEY prefix is removed'

collapsed_pem='-----BEGIN RSA TEST-----  abc def  -----END RSA TEST-----'
normalized_pem="$(normalize_private_key "$collapsed_pem")"

assert_eq \
    $'-----BEGIN RSA TEST-----\nabc\ndef\n-----END RSA TEST-----' \
    "$normalized_pem" \
    'single-line PEM private key spaces become real newlines'

escaped_pem='-----BEGIN RSA TEST-----\nabc\n-----END RSA TEST-----'
normalized_escaped_pem="$(normalize_private_key "$escaped_pem")"

assert_eq \
    $'-----BEGIN RSA TEST-----\nabc\n-----END RSA TEST-----' \
    "$normalized_escaped_pem" \
    'escaped private key newlines become real newlines'

# ── Portainer endpoint ID detection ──────────────────────────────────────────

plain_array='[{"Id": 1, "Name": "local"}]'
assert_eq \
    "1" \
    "$(printf '%s' "$plain_array" | extract_portainer_endpoint_id)" \
    'endpoint ID extracted from plain array response'

paginated='{"value": [{"Id": 2, "Name": "local"}], "totalCount": 1}'
assert_eq \
    "2" \
    "$(printf '%s' "$paginated" | extract_portainer_endpoint_id)" \
    'endpoint ID extracted from paginated response'

items_response='{"items": [{"Id": 3, "Name": "local"}], "totalCount": 1}'
assert_eq \
    "3" \
    "$(printf '%s' "$items_response" | extract_portainer_endpoint_id)" \
    'endpoint ID extracted from items response'

created_endpoint='{"Id": 6, "Name": "local", "Type": 1, "URL": "unix:///var/run/docker.sock"}'
assert_eq \
    "6" \
    "$(printf '%s' "$created_endpoint" | extract_portainer_endpoint_id)" \
    'endpoint ID extracted from single endpoint object'

multiple_endpoints='[{"Id": 4, "Name": "remote", "Type": 1, "URL": "tcp://host:2375"}, {"Id": 5, "Name": "docker", "Type": 1, "URL": "unix:///var/run/docker.sock"}]'
assert_eq \
    "5" \
    "$(printf '%s' "$multiple_endpoints" | extract_portainer_endpoint_id)" \
    'local Docker socket endpoint is preferred'

empty_array='[]'
assert_eq \
    "" \
    "$(printf '%s' "$empty_array" | extract_portainer_endpoint_id)" \
    'empty array returns empty value (triggers create path)'

cat > "$tmp_bin/curl" <<'EOF'
#!/bin/bash
output_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output_file="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

printf '{"Id": 7, "Name": "local", "Type": 1, "URL": "unix:///var/run/docker.sock"}' > "$output_file"
printf '201'
EOF
chmod +x "$tmp_bin/curl"

PATH="$tmp_bin:$PATH" PORTAINER_TOKEN="test-token" PORTAINER_URL="https://portainer.test"
assert_eq \
    "7" \
    "$(create_local_portainer_endpoint)" \
    'local endpoint creation returns created endpoint ID'

# ── Portainer GHCR registry ID detection ─────────────────────────────────────

registry_plain_array='[{"Id": 9, "Name": "ghcr", "URL": "ghcr.io"}]'
assert_eq \
    "9" \
    "$(printf '%s' "$registry_plain_array" | extract_portainer_registry_id)" \
    'registry ID extracted from plain array response'

registry_paginated='{"value": [{"Id": 10, "URL": "ghcr.io"}], "totalCount": 1}'
assert_eq \
    "10" \
    "$(printf '%s' "$registry_paginated" | extract_portainer_registry_id)" \
    'registry ID extracted from paginated response'

registry_no_ghcr='[{"Id": 1, "URL": "docker.io"}]'
assert_eq \
    "" \
    "$(printf '%s' "$registry_no_ghcr" | extract_portainer_registry_id)" \
    'no ghcr.io registry returns empty value (triggers create path)'

registry_empty_array='[]'
assert_eq \
    "" \
    "$(printf '%s' "$registry_empty_array" | extract_portainer_registry_id)" \
    'empty registry array returns empty value'

# ── ensure_ghcr_registry create path (mocked curl) ───────────────────────────

# ensure_ghcr_registry logs via ok/warn, which are not extracted by the harness.
ok()   { :; }
warn() { :; }

cat > "$tmp_bin/curl" <<'EOF'
#!/bin/bash
method="GET"
output_file=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        -X) method="${args[$((i + 1))]}" ;;
        -o) output_file="${args[$((i + 1))]}" ;;
    esac
done

if [ "$method" = "GET" ]; then
    # GET /api/registries → no ghcr.io registry yet (create path)
    printf '[]'
    exit 0
fi

# POST /api/registries → created
[ -n "$output_file" ] && printf '{"Id": 11, "URL": "ghcr.io"}' > "$output_file"
printf '201'
EOF
chmod +x "$tmp_bin/curl"

registry_created_http=$(
    PATH="$tmp_bin:$PATH" \
    PORTAINER_TOKEN="test-token" \
    PORTAINER_URL="https://portainer.test" \
    GHCR_USERNAME="ghcr-user" \
    GHCR_TOKEN="ghcr-pat" \
    ensure_ghcr_registry; echo "$?"
)
assert_eq \
    "0" \
    "$registry_created_http" \
    'ensure_ghcr_registry succeeds on HTTP 201 create path'

printf 'PASS: install env serialization\n'
