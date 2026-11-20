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

extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { capture = 1 }
        capture { print }
        capture && /^}$/ { capture = 0 }
    ' "$ROOT_DIR/maintenance-redeploy.sh"
}
eval "$(extract_fn stack_health_problem)"

# Stubbed docker: prints $DOCKER_PS (one "State|Status" per line) and records
# its arguments (it runs in a command substitution, hence a file).
ARGS_FILE=$(mktemp)
trap 'rm -f "$ARGS_FILE"' EXIT
docker() {
    printf '%s' "$*" > "$ARGS_FILE"
    [[ -n "$DOCKER_PS" ]] && printf '%s\n' "$DOCKER_PS"
    return 0
}

# Prints "<ok|bad> <problem>" for the given container states.
health() {
    DOCKER_PS="$1"
    local problem rc=0
    problem=$(stack_health_problem "${2:-Focus}") || rc=$?
    if [[ $rc -eq 0 ]]; then printf 'ok'; else printf 'bad %s' "$problem"; fi
}

# ── stack_health_problem(stack) ───────────────────────────────────────────────
# A 2xx from Portainer only means compose accepted the stack. The maintenance
# job counts a stack as back only once its containers actually run.
assert_eq "ok" "$(health 'running|Up 2 minutes (healthy)')" 'healthy container'
assert_eq "ok" "$(health $'running|Up 1 minute\nexited|Exited (0) 1 minute ago')" \
    'a one-shot container that exited 0 next to a running one is fine'
assert_eq "bad no containers" "$(health '')" 'a stack without containers is down'
assert_eq "bad no running container" "$(health 'exited|Exited (0) 1 minute ago')" \
    'a stack whose only container exited is down'
assert_eq "bad Exited (1) 5 seconds ago" "$(health $'running|Up 1 minute\nexited|Exited (1) 5 seconds ago')" \
    'a container that exited non-zero'
assert_eq "bad restarting: Restarting (1) 3 seconds ago" "$(health 'restarting|Restarting (1) 3 seconds ago')" \
    'a crash-looping container'
assert_eq "bad created: Created" "$(health $'running|Up 1 minute\ncreated|Created')" \
    'a container created but never started (e.g. a dependency failed)'
assert_eq "bad Up 3 minutes (unhealthy)" "$(health 'running|Up 3 minutes (unhealthy)')" \
    'a failing healthcheck'
assert_eq "bad Up 5 seconds (health: starting)" "$(health 'running|Up 5 seconds (health: starting)')" \
    'still in the healthcheck start period → not yet back'

health 'running|Up 1 minute' 'Speedtest-Tracker' >/dev/null
assert_eq "ps -a --filter label=com.docker.compose.project=speedtest-tracker --filter label=com.docker.compose.oneoff=False --format {{.State}}|{{.Status}}" \
    "$(cat "$ARGS_FILE")" 'filters on the lowercased compose project name'

printf 'PASS: maintenance redeploy health check\n'
