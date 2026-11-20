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

# The prune step, from its settings through the prune call, anchored on code
# (not line numbers) so the test drives the shipped block.
extract_prune_step() {
    awk '
        /^PRUNE_ATTEMPTS=/ { capture = 1 }
        capture { print }
        capture && /could not prune unused images/ { exit }
    ' "$ROOT_DIR/maintenance-redeploy.sh"
}

# Runs the extracted block against a stubbed docker whose `image prune` fails
# the first $1 calls with the "already running" error the daemon returns.
# `sleep` only records its delay. Prints "<exit code> <calls and messages>";
# AFTER marks that the script went on past the prune.
run_prune_step() {
    local driver out status
    driver=$(mktemp)
    {
        printf '%s\n' \
            'set -euo pipefail' \
            'failures=$1' \
            'docker() {' \
            '    echo "docker $*"' \
            '    if [[ $failures -gt 0 ]]; then' \
            '        failures=$((failures - 1))' \
            '        echo "Error response from daemon: a prune operation is already running" >&2' \
            '        return 1' \
            '    fi' \
            '}' \
            'sleep() { echo "sleep $1"; }'
        extract_prune_step
        printf '%s\n' 'echo AFTER'
    } > "$driver"

    out=$(bash "$driver" "$@" 2>&1) && status=0 || status=$?
    rm -f "$driver"
    printf '%s %s' "$status" "$(echo "$out" | grep -v 'already running' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
}

# ── the maintenance prune step ────────────────────────────────────────────────
# The prune is housekeeping after every stack is back: its failure costs disk
# space, never uptime, so it must never fail the job.
assert_eq "0 [maintenance-redeploy] pruning unused images docker image prune -a -f AFTER" \
    "$(run_prune_step 0)" \
    'prune succeeds → job continues'

assert_eq "0 [maintenance-redeploy] pruning unused images docker image prune -a -f sleep 10 docker image prune -a -f sleep 20 docker image prune -a -f AFTER" \
    "$(run_prune_step 2)" \
    'a prune already running is retried with backoff'

assert_eq "0 [maintenance-redeploy] pruning unused images docker image prune -a -f sleep 10 docker image prune -a -f sleep 20 docker image prune -a -f [maintenance-redeploy] WARNING: could not prune unused images; continuing AFTER" \
    "$(run_prune_step 99)" \
    'a persistently failing prune only warns'

# ── nothing destructive before the redeploy ───────────────────────────────────
# On 2026-11-10 the job stopped every stack, removed every container, then
# died on the prune and left production down. Guard the shape, not just the
# behavior: no stack stop, no container removal, no system prune (which also
# removes networks other stacks join as external), and the only prune comes
# after the redeploy and the health check.
SCRIPT="$ROOT_DIR/maintenance-redeploy.sh"
code_only() { grep -v '^[[:space:]]*#' "$SCRIPT"; }
assert_eq "" "$(code_only | grep -E '/stop|docker rm|docker (container|network|system) prune' || true)" \
    'maintenance-redeploy.sh never stops stacks, removes containers or system-prunes'

line_of() { code_only | grep -n -m1 -- "$1" | cut -d: -f1; }
REDEPLOY_LINE=$(line_of '^redeploy_pass "\${STACK_NAMES')
HEALTH_LINE=$(line_of '^    wait_until_healthy ')
PRUNE_LINE=$(line_of '^prune_with_retry docker')
[[ -n "$REDEPLOY_LINE" && -n "$HEALTH_LINE" && -n "$PRUNE_LINE" ]] \
    || { echo "FAIL: could not locate redeploy/health/prune lines" >&2; exit 1; }
assert_eq "ordered" \
    "$([[ $REDEPLOY_LINE -lt $HEALTH_LINE && $HEALTH_LINE -lt $PRUNE_LINE ]] && echo ordered || echo "$REDEPLOY_LINE/$HEALTH_LINE/$PRUNE_LINE")" \
    'redeploy → health check → prune'

printf 'PASS: maintenance redeploy prune handling\n'
