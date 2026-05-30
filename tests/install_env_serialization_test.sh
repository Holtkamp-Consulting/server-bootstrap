#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

eval "$(
    awk '
        /^normalize_private_key\(\) \{/ { capture = 1 }
        /^quote_env_value\(\) \{/ { capture = 1 }
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
trap 'rm -f "$tmp_env"' EXIT

private_key_raw=$'BEGIN TEST KEY\nline with spaces\nEND TEST KEY'
private_key="$(normalize_private_key "$private_key_raw")"

printf 'APP_PRIVATE_KEY=%s\n' "$(quote_env_value "$private_key")" > "$tmp_env"
source "$tmp_env"

assert_eq \
    'BEGIN TEST KEY\nline with spaces\nEND TEST KEY' \
    "$APP_PRIVATE_KEY" \
    'private key keeps escaped newlines when sourced'

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
    '-----BEGIN RSA TEST-----\nabc\ndef\n-----END RSA TEST-----' \
    "$normalized_pem" \
    'single-line PEM private key spaces become escaped newlines'

escaped_pem='-----BEGIN RSA TEST-----\nabc\n-----END RSA TEST-----'
normalized_escaped_pem="$(normalize_private_key "$escaped_pem")"

assert_eq \
    "$escaped_pem" \
    "$normalized_escaped_pem" \
    'already escaped private key newlines are preserved'

printf 'PASS: install env serialization\n'
