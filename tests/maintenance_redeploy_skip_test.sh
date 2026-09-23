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

# The redeploy loop and its result reporting, anchored on code (not line
# numbers) so the test drives the shipped block itself. It runs to the end of
# the file, which is where the stamp file is removed.
extract_redeploy_loop() {
    awk '
        /^FAILED_STACKS=\(\)$/ { capture = 1 }
        capture { print }
    ' "$ROOT_DIR/maintenance-redeploy.sh"
}

# Runs the extracted block over the named stacks against a stubbed
# redeploy-stacks.sh that exits by stack name: `skipped` → EXIT_SKIPPED,
# `broken` → 1, anything else → deployed. Prints
# "<exit code> stamp=<kept|removed> <messages>".
run_redeploy_loop() {
    local driver stamp out status
    driver=$(mktemp)
    stamp=$(mktemp)
    {
        printf '%s\n' \
            'set -euo pipefail' \
            'STAMP_FILE="$1"; shift' \
            'STACK_NAMES=("$@")' \
            'INFISICAL_ENV=dev' \
            'BRANCH=main'
        grep -m1 '^REDEPLOY_EXIT_SKIPPED=' "$ROOT_DIR/maintenance-redeploy.sh"
        printf '%s\n' \
            '/opt/deploy/redeploy-stacks.sh() {' \
            '    local name=""' \
            '    while [[ $# -gt 0 ]]; do' \
            '        case $1 in --stack) name="$2"; shift 2 ;; *) shift ;; esac' \
            '    done' \
            '    case "$name" in' \
            '        skipped) return "$REDEPLOY_EXIT_SKIPPED" ;;' \
            '        broken)  return 1 ;;' \
            '        *)       return 0 ;;' \
            '    esac' \
            '}'
        extract_redeploy_loop
    } > "$driver"

    out=$(bash "$driver" "$stamp" "$@" 2>&1) && status=0 || status=$?
    local stamp_state="removed"
    [[ -e "$stamp" ]] && stamp_state="kept"
    rm -f "$driver" "$stamp"
    printf '%s stamp=%s %s' "$status" "$stamp_state" "$(echo "$out" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
}

# ── the maintenance redeploy loop ─────────────────────────────────────────────
# Every stack is stopped, its containers removed and every image pruned before
# this loop runs, so a stack this loop does not bring back stays down until
# someone notices. Reporting "complete" and clearing the stamp file (which
# disarms the next boot's retry) is only correct when every stack came back.
assert_eq "0 stamp=removed [maintenance-redeploy] complete" \
    "$(run_redeploy_loop alpha beta)" \
    'all stacks redeployed → success, stamp cleared'

assert_eq "1 stamp=kept [maintenance-redeploy] FAILED to redeploy: broken" \
    "$(run_redeploy_loop alpha broken)" \
    'a failed stack fails the job and keeps the stamp file for the next boot'

assert_eq "1 stamp=kept [maintenance-redeploy] STOPPED and NOT redeployed — no Infisical secrets for environment 'dev': skipped" \
    "$(run_redeploy_loop alpha skipped)" \
    'a skipped stack was torn down and stays down — it must not report success'

assert_eq "1 stamp=kept [maintenance-redeploy] FAILED to redeploy: broken [maintenance-redeploy] STOPPED and NOT redeployed — no Infisical secrets for environment 'dev': skipped" \
    "$(run_redeploy_loop broken skipped alpha)" \
    'failed and skipped stacks are reported separately'

# ── the skip exit code must agree across every caller ─────────────────────────
# redeploy-stacks.sh is downloaded onto the server by install.sh and called by
# both this job and .github/workflows/redeploy.yml; there is no shared lib, so
# the three copies of the code can only be kept honest by asserting them here.
# Drift means either a skip silently counts as a redeploy again, or an ordinary
# push-triggered skip starts failing CI.
SKIP_CODE=$(grep -m1 '^EXIT_SKIPPED=' "$ROOT_DIR/redeploy-stacks.sh" | cut -d= -f2)
assert_eq "$SKIP_CODE" \
    "$(grep -m1 '^REDEPLOY_EXIT_SKIPPED=' "$ROOT_DIR/maintenance-redeploy.sh" | cut -d= -f2)" \
    'maintenance-redeploy.sh matches redeploy-stacks.sh EXIT_SKIPPED'
assert_eq "$SKIP_CODE" \
    "$(grep -o '"\$rc" -eq [0-9]*' "$ROOT_DIR/.github/workflows/redeploy.yml" | awk '$NF != 0 {print $NF}')" \
    'redeploy.yml tolerates exactly the EXIT_SKIPPED code'

printf 'PASS: maintenance redeploy skip handling\n'
