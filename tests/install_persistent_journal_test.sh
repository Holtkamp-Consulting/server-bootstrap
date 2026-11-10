#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# awk-extract the Step 1 drop-in path and function — install.sh runs
# top-to-bottom and would execute its full bootstrap if sourced directly.
eval "$(
    awk '
        /^JOURNALD_DROPIN=/ { print }
        /^configure_persistent_journal\(\) \{/ { capture = 1 }
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

tmp_root="$(mktemp -d)"
tmp_bin="$tmp_root/bin"
mkdir -p "$tmp_bin"
trap 'rm -rf "$tmp_root"' EXIT

CAPTURED_LOG=""
log()  { CAPTURED_LOG+="LOG:${*}"$'\n'; }
ok()   { CAPTURED_LOG+="OK:${*}"$'\n'; }
warn() { CAPTURED_LOG+="WARN:${*}"$'\n'; }
err()  { CAPTURED_LOG+="ERR:${*}"$'\n'; }

SERVICE_CALL_LOG="$tmp_root/service_calls.log"

# sudo is stubbed, not invoked for real: rewrite /etc/systemd/* and
# /var/log/journal arguments to paths under tmp_root so the real mkdir/cmp/tee
# run against a throwaway tree, and record systemctl/journalctl instead of
# touching the host's journald.
cat > "$tmp_bin/sudo" <<EOF
#!/bin/bash
args=()
for a in "\$@"; do
    case "\$a" in
        /etc/systemd/*|/var/log/journal) a="$tmp_root\$a" ;;
    esac
    args+=("\$a")
done
case "\${args[0]}" in
    systemctl|journalctl) printf '%s\n' "\${args[*]}" >> "$SERVICE_CALL_LOG"; exit 0 ;;
    *) exec "\${args[@]}" ;;
esac
EOF
chmod +x "$tmp_bin/sudo"

dropin="$tmp_root$JOURNALD_DROPIN"
expected_dropin=$'[Journal]\nStorage=persistent\nSystemMaxUse=500M'

run_configure_persistent_journal() {
    : > "$SERVICE_CALL_LOG"
    CAPTURED_LOG=""
    PATH="$tmp_bin:$PATH" configure_persistent_journal
}

# ── Fresh host: no journal dir, no drop-in ──────────────────────────────────
run_configure_persistent_journal

assert_eq "$expected_dropin" "$(cat "$dropin")" \
    'fresh host gets the drop-in with Storage=persistent and SystemMaxUse'
[ -d "$tmp_root/var/log/journal" ] || { echo 'FAIL: /var/log/journal not created' >&2; exit 1; }
assert_eq $'systemctl restart systemd-journald\njournalctl --flush' "$(cat "$SERVICE_CALL_LOG")" \
    'fresh host restarts journald and flushes the runtime journal to disk'
assert_contains "$CAPTURED_LOG" "Persistent journal enabled" \
    'fresh host reports the journal as enabled'

# ── Second run: same content → no rewrite, no restart ───────────────────────
run_configure_persistent_journal

assert_eq "$expected_dropin" "$(cat "$dropin")" \
    'second run leaves the drop-in content unchanged'
assert_eq "" "$(cat "$SERVICE_CALL_LOG")" \
    'second run does not restart or flush journald'
assert_contains "$CAPTURED_LOG" "already configured — skipping" \
    'second run reports the idempotency skip'

# ── Existing drop-in with differing content → replaced and applied ──────────
printf '[Journal]\nStorage=volatile\nSystemMaxUse=50M\nStorage=persistent\n' > "$dropin"
run_configure_persistent_journal

assert_eq "$expected_dropin" "$(cat "$dropin")" \
    'differing drop-in is replaced wholesale, leaving no stale or duplicate keys'
assert_eq $'systemctl restart systemd-journald\njournalctl --flush' "$(cat "$SERVICE_CALL_LOG")" \
    'updated drop-in is applied by restarting journald'

printf 'PASS: install persistent journal step (fresh / idempotent / update)\n'
