#!/bin/bash
set -euo pipefail

# Integration test for the read-only Portainer API proxy deployed by
# install.sh (Step 7/9). Renders the checked-in Caddyfile the same way
# install.sh does, runs it against a mock upstream, and asserts both the
# allowlist behaviour and that the injected Portainer credential never
# reaches the caller.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Unlike the other tests in this directory, this one needs real infrastructure.
# Degrade to a skip rather than failing a suite run in a minimal environment.
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker not available"
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

MOCK_PORT=19000
PROXY_PORT=19444
FAKE_TOKEN="test-secret-token-must-not-leak"
CONTAINER_NAME="portainer-proxy-allowlist-test-$$"

tmp_dir="$(mktemp -d)"
mock_pid=""

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if [ -n "$mock_pid" ]; then
        kill "$mock_pid" >/dev/null 2>&1 || true
        # Reap it here so bash does not print a job-control "Terminated" notice
        # after the test's own PASS line.
        wait "$mock_pid" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

# Mock upstream Portainer: logs every received X-Api-Key to a file (read
# directly by this script, bypassing the proxy) and answers with a static body
# that never echoes the header back — same as real Portainer, which does not
# reflect request headers to the caller.
cat > "$tmp_dir/mock_upstream.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG_PATH = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def _handle(self):
        with open(LOG_PATH, 'a') as f:
            f.write(f"{self.command} {self.path} {self.headers.get('X-Api-Key', '')}\n")
        body = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def log_message(self, *args):
        pass


HTTPServer(('0.0.0.0', int(sys.argv[1])), Handler).serve_forever()
PY

: > "$tmp_dir/upstream.log"
python3 "$tmp_dir/mock_upstream.py" "$MOCK_PORT" "$tmp_dir/upstream.log" &
mock_pid=$!

# Render the checked-in Caddyfile exactly the way install.sh does, except for
# the upstream address: install.sh runs the container with --network host and
# points it at localhost, which Docker Desktop on macOS does not support the way
# Linux does. Bridge networking + host.docker.internal is portable and exercises
# identical matching logic — the allowlist is unaffected by the network mode.
sed \
    -e "s|__PROXY_PORT__|${PROXY_PORT}|g" \
    -e "s|__PORTAINER_UPSTREAM__|host.docker.internal:${MOCK_PORT}|g" \
    "$ROOT_DIR/caddy/portainer-proxy.Caddyfile" > "$tmp_dir/Caddyfile"

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER_NAME" \
    --add-host=host.docker.internal:host-gateway \
    -p "127.0.0.1:${PROXY_PORT}:${PROXY_PORT}" \
    -e "PORTAINER_ACCESS_TOKEN=${FAKE_TOKEN}" \
    -v "$tmp_dir/Caddyfile:/etc/caddy/Caddyfile:ro" \
    caddy:2-alpine >/dev/null

ready=0
for _ in $(seq 1 40); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PROXY_PORT}/api/status" 2>/dev/null)" = "200" ]; then
        ready=1
        break
    fi
    sleep 0.5
done
if [ "$ready" -ne 1 ]; then
    echo "FAIL: proxy did not become ready" >&2
    docker logs "$CONTAINER_NAME" >&2 || true
    exit 1
fi

proxy_code() {
    curl -s -o /dev/null -w '%{http_code}' "$@"
}

# ── Positive: every allowlisted GET route passes ─────────────────────────────
assert_eq "200" \
    "$(proxy_code "http://127.0.0.1:${PROXY_PORT}/api/status")" \
    'GET /api/status is allowed'
assert_eq "200" \
    "$(proxy_code "http://127.0.0.1:${PROXY_PORT}/api/endpoints")" \
    'GET /api/endpoints is allowed'
assert_eq "200" \
    "$(proxy_code "http://127.0.0.1:${PROXY_PORT}/api/endpoints/3/docker/containers/json")" \
    'GET /api/endpoints/{id}/docker/containers/json is allowed'
assert_eq "200" \
    "$(proxy_code "http://127.0.0.1:${PROXY_PORT}/api/endpoints/3/docker/networks")" \
    'GET /api/endpoints/{id}/docker/networks is allowed'

# ── Negative: everything else is denied ──────────────────────────────────────
assert_eq "403" \
    "$(proxy_code "http://127.0.0.1:${PROXY_PORT}/api/nonexistent")" \
    'unlisted route is denied'
assert_eq "403" \
    "$(proxy_code "http://127.0.0.1:${PROXY_PORT}/api/users")" \
    'sensitive unlisted route /api/users is denied'
assert_eq "403" \
    "$(proxy_code -X POST "http://127.0.0.1:${PROXY_PORT}/api/status")" \
    'POST on an allowed route is denied'
assert_eq "403" \
    "$(proxy_code -X POST "http://127.0.0.1:${PROXY_PORT}/api/endpoints")" \
    'POST on a second allowed route is denied'
assert_eq "403" \
    "$(proxy_code -X DELETE "http://127.0.0.1:${PROXY_PORT}/api/endpoints/3/docker/networks")" \
    'DELETE on an allowed route is denied'
assert_eq "403" \
    "$(proxy_code "http://127.0.0.1:${PROXY_PORT}/api/endpoints/abc/docker/networks")" \
    'non-numeric {id} is denied'
assert_eq "403" \
    "$(proxy_code "http://127.0.0.1:${PROXY_PORT}/api/endpoints/3/docker/networks/extra")" \
    'trailing path segment beyond an allowed route is denied'

# A denied request must never reach Portainer at all.
if grep -q '/api/users' "$tmp_dir/upstream.log"; then
    echo "FAIL: a denied request was forwarded to the upstream" >&2
    exit 1
fi

# ── Credential handling ──────────────────────────────────────────────────────
if ! grep -q "^GET /api/status ${FAKE_TOKEN}\$" "$tmp_dir/upstream.log"; then
    echo "FAIL: token was not injected into the upstream request" >&2
    cat "$tmp_dir/upstream.log" >&2
    exit 1
fi

response="$(curl -si "http://127.0.0.1:${PROXY_PORT}/api/status")"
if [[ "$response" == *"$FAKE_TOKEN"* ]]; then
    echo "FAIL: token leaked into the client-facing response" >&2
    exit 1
fi

printf 'PASS: portainer proxy allowlist\n'
