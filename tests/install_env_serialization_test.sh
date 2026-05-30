#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

eval "$(
    awk '
        /^quote_env_value\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
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
private_key="${private_key_raw//$'\n'/\\n}"

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
stripped_key="${prefixed_key#APP_PRIVATE_KEY=}"

assert_eq \
    'BEGIN TEST KEY' \
    "$stripped_key" \
    'optional APP_PRIVATE_KEY prefix is removed'

printf 'PASS: install env serialization\n'
