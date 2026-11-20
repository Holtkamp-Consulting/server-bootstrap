#!/bin/bash
# Started by server-bootstrap-alert@<unit>.service through OnFailure= on the
# maintenance units. Posts the failed unit and the tail of its journal to
# ALERT_WEBHOOK_URL (from the deploy config) as a Microsoft Teams Adaptive
# Card — the payload a Teams Workflows webhook ("Send webhook alerts to a
# channel") posts to a channel.
#
# The maintenance redeploy failed on every boot from 2026-09-12 to 2026-11-10
# without anyone noticing; a failure that only lands in the journal is not
# reported. So a missing webhook fails this unit too, which at least shows up
# in `systemctl --failed`.
set -uo pipefail

UNIT="${1:-unknown}"
DEPLOY_CONFIG="${DEPLOY_CONFIG:-/etc/infisical-deploy.env}"
JOURNAL_LINES=40

if [[ -z "${ALERT_WEBHOOK_URL:-}" && -r "$DEPLOY_CONFIG" ]]; then
    ALERT_WEBHOOK_URL=$(
        # shellcheck disable=SC1090
        source "$DEPLOY_CONFIG" >/dev/null 2>&1
        printf '%s' "${ALERT_WEBHOOK_URL:-}"
    )
fi

build_alert_title() {
    printf '🚨 %s: %s failed' "$2" "$1"
}

# Adaptive Card TextBlocks do not render code fences and collapse single
# newlines, so each journal line gets its own monospace block.
build_teams_payload() {
    local title="$1" journal="$2"
    jq -n --arg title "$title" --arg journal "$journal" --arg n "$JOURNAL_LINES" '{
        type: "message",
        attachments: [{
            contentType: "application/vnd.microsoft.card.adaptive",
            contentUrl: null,
            content: {
                "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                type: "AdaptiveCard",
                version: "1.4",
                msteams: {width: "Full"},
                body: ([
                    {type: "TextBlock", text: $title, weight: "Bolder",
                     size: "Medium", color: "Attention", wrap: true},
                    {type: "TextBlock", text: "Last \($n) journal lines:", wrap: true}
                ] + [
                    $journal | split("\n")[] | select(length > 0)
                    | {type: "TextBlock", text: ., fontType: "Monospace",
                       size: "Small", spacing: "None", wrap: true}
                ])
            }
        }]
    }'
}

JOURNAL=$(journalctl -u "$UNIT" -b --no-pager -n "$JOURNAL_LINES" -o cat 2>&1 || true)
TITLE=$(build_alert_title "$UNIT" "$(hostname)")

if [[ -z "${ALERT_WEBHOOK_URL:-}" ]]; then
    echo "ALERT NOT SENT — ALERT_WEBHOOK_URL is not set in ${DEPLOY_CONFIG}:" >&2
    printf '%s\n%s\n' "$TITLE" "$JOURNAL" >&2
    exit 1
fi

# Runs right after a boot, possibly before the network is usable: retry.
build_teams_payload "$TITLE" "$JOURNAL" \
    | curl -fsS -m 20 --retry 6 --retry-delay 10 --retry-all-errors \
        -H "Content-Type: application/json" -d @- "$ALERT_WEBHOOK_URL" >/dev/null \
    || { echo "Failed to deliver alert for ${UNIT}" >&2; exit 1; }
echo "Alert sent for ${UNIT}"
