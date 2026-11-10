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

# The prune step, from its settings through the call that gates the redeploy,
# anchored on code (not line numbers) so the test drives the shipped block.
extract_prune_step() {
    awk '
        /^PRUNE_ATTEMPTS=/ { capture = 1 }
        capture { print }
        capture && /^prune_images \|\|/ { exit }
    ' "$ROOT_DIR/maintenance-redeploy.sh"
}

# Runs the extracted block against a stubbed docker whose `system prune` fails
# the first $1 calls and whose `image prune` fails the first $2 calls, with the
# same "already running" error the daemon returns. `sleep` only records its
# delay. Prints "<exit code> <calls and messages>"; REDEPLOY marks that the
# script went on to the redeploy loop.
run_prune_step() {
    local driver out status
    driver=$(mktemp)
    {
        printf '%s\n' \
            'set -euo pipefail' \
            'system_failures=$1 image_failures=$2' \
            'docker() {' \
            '    echo "docker $*"' \
            '    local kind=$1' \
            '    if [[ $kind == system && $system_failures -gt 0 ]] \' \
            '        || [[ $kind == image && $image_failures -gt 0 ]]; then' \
            '        [[ $kind == system ]] && system_failures=$((system_failures - 1))' \
            '        [[ $kind == image ]] && image_failures=$((image_failures - 1))' \
            '        echo "Error response from daemon: a prune operation is already running" >&2' \
            '        return 1' \
            '    fi' \
            '}' \
            'sleep() { echo "sleep $1"; }'
        extract_prune_step
        printf '%s\n' 'echo REDEPLOY'
    } > "$driver"

    out=$(bash "$driver" "$@" 2>&1) && status=0 || status=$?
    rm -f "$driver"
    printf '%s %s' "$status" "$(echo "$out" | grep -v 'already running' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
}

# ── the maintenance prune step ────────────────────────────────────────────────
# Every container is already removed when this step runs, so exiting here
# leaves every stack down until the next boot. Only a failure to remove the
# images justifies that: the redeploy uses the branch's moving tag and would
# otherwise silently reuse a stale cached image.
assert_eq "0 [maintenance-redeploy] pruning all images docker system prune -a -f REDEPLOY" \
    "$(run_prune_step 0 0)" \
    'prune succeeds → redeploy runs'

assert_eq "0 [maintenance-redeploy] pruning all images docker system prune -a -f sleep 10 docker system prune -a -f sleep 20 docker system prune -a -f REDEPLOY" \
    "$(run_prune_step 2 0)" \
    'a prune already running is retried with backoff instead of aborting the job'

assert_eq "0 [maintenance-redeploy] pruning all images docker system prune -a -f sleep 10 docker system prune -a -f sleep 20 docker system prune -a -f [maintenance-redeploy] docker system prune failed; falling back to docker image prune docker image prune -a -f REDEPLOY" \
    "$(run_prune_step 99 0)" \
    'a persistently failing system prune falls back to an image prune and still redeploys'

assert_eq "1 [maintenance-redeploy] pruning all images docker system prune -a -f sleep 10 docker system prune -a -f sleep 20 docker system prune -a -f [maintenance-redeploy] docker system prune failed; falling back to docker image prune docker image prune -a -f sleep 10 docker image prune -a -f sleep 20 docker image prune -a -f [maintenance-redeploy] could not prune images — not redeploying onto stale cached images" \
    "$(run_prune_step 99 99)" \
    'images that cannot be pruned at all stop the job before the moving-tag redeploy'

printf 'PASS: maintenance redeploy prune handling\n'
