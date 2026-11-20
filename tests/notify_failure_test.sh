#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

# Runs notify-failure.sh with stubbed journalctl/hostname/curl on PATH and the
# given deploy config content. Prints "<exit code>|<payload curl received>".
run_notify() {
    local config_content="$1" dir status
    dir=$(mktemp -d)
    mkdir "$dir/bin"
    printf '#!/bin/bash\necho "line one"\necho "line two"\n' > "$dir/bin/journalctl"
    printf '#!/bin/bash\necho pi-prod\n' > "$dir/bin/hostname"
    # Records the URL and stdin payload; like `curl -f`, exits 22 (HTTP error)
    # for a URL containing "revoked".
    printf '#!/bin/bash\necho "${@: -1}" > "%s/url"\ncat > "%s/payload"\n[[ "${@: -1}" != *revoked* ]] || exit 22\n' "$dir" "$dir" > "$dir/bin/curl"
    chmod +x "$dir/bin/"*
    printf '%s\n' "$config_content" > "$dir/deploy.env"

    env -u ALERT_WEBHOOK_URL PATH="$dir/bin:$PATH" DEPLOY_CONFIG="$dir/deploy.env" \
        bash "$ROOT_DIR/notify-failure.sh" maintenance-redeploy.service >/dev/null 2>&1 \
        && status=0 || status=$?
    printf '%s|%s|%s' "$status" "$(cat "$dir/url" 2>/dev/null)" \
        "$(jq -r '.attachments[0] | select(.contentType == "application/vnd.microsoft.card.adaptive") | .content.body[].text' "$dir/payload" 2>/dev/null | tr '\n' '~')"
    rm -rf "$dir"
}

# ── notify-failure.sh ─────────────────────────────────────────────────────────
assert_eq '0|https://hooks.example/abc|🚨 pi-prod: maintenance-redeploy.service failed~Last 40 journal lines:~line one~line two~' \
    "$(run_notify "ALERT_WEBHOOK_URL='https://hooks.example/abc'")" \
    'posts host, failed unit and journal tail to the configured webhook as a Teams Adaptive Card'

assert_eq '1||' \
    "$(run_notify "INFISICAL_ENV=prod")" \
    'without a webhook the alert unit itself fails instead of passing silently'

assert_eq '1|https://hooks.example/revoked|' \
    "$(run_notify "ALERT_WEBHOOK_URL='https://hooks.example/revoked'" | cut -d'|' -f1-2)|" \
    'a webhook answering with an HTTP error fails the alert unit instead of reporting success'

printf 'PASS: notify-failure alert\n'
