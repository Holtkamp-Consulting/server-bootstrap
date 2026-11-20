#!/bin/bash
set -euo pipefail

STAMP_FILE="/var/lib/server-bootstrap/maintenance-reboot-pending"
DEPLOY_CONFIG="/etc/infisical-deploy.env"
PORTAINER_ADMIN="admin"
# Must match redeploy-stacks.sh's EXIT_SKIPPED (asserted by
# tests/maintenance_redeploy_skip_test.sh).
REDEPLOY_EXIT_SKIPPED=3

# Maps this host's persisted Infisical environment to the branch whose images
# it runs — mirrors install.sh's deploy_branch_for_env(). Duplicated rather than
# fetched-and-eval'd at runtime from install.sh: eval'ing remotely-fetched code
# as root inside an unattended, unsupervised overnight job is a security/
# reliability smell (a compromised or unreachable GitHub raw endpoint could
# silently break or hijack the job) — not worth avoiding a 4-line duplication
# that's independently tested (tests/maintenance_redeploy_branch_test.sh).
redeploy_branch_for_env() {
    case "$1" in
        dev) printf 'dev' ;;
        *)   printf 'main' ;;
    esac
}

if [[ -z "${PORTAINER_URL:-}" ]]; then
    [[ -f "$DEPLOY_CONFIG" ]] || { echo "Deploy config not found at $DEPLOY_CONFIG"; exit 1; }
    if [[ -r "$DEPLOY_CONFIG" ]]; then
        source "$DEPLOY_CONFIG"
    else
        source <(sudo cat "$DEPLOY_CONFIG")
    fi
fi

AUTH_PAYLOAD=$(jq -n --arg u "$PORTAINER_ADMIN" --arg p "$PORTAINER_PASSWORD" \
    '{username: $u, password: $p}')
# Right after boot the Portainer container may not be listening yet; give it a
# few minutes rather than failing (and alerting) on a cold start.
PORTAINER_TOKEN=""
for _ in $(seq 1 18); do
    PORTAINER_TOKEN=$(curl -sfk -X POST \
        -H "Content-Type: application/json" \
        -d "$AUTH_PAYLOAD" \
        "${PORTAINER_URL}/api/auth" | jq -r '.jwt // empty') || PORTAINER_TOKEN=""
    [[ -n "$PORTAINER_TOKEN" ]] && break
    sleep 10
done
[[ -z "$PORTAINER_TOKEN" ]] && { echo "Portainer auth failed"; exit 1; }

STACKS_JSON=$(curl -sfk \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    "${PORTAINER_URL}/api/stacks")
[[ -n "$STACKS_JSON" ]] && jq -e 'type == "array"' <<<"$STACKS_JSON" >/dev/null \
    || { echo "Failed to fetch stack list from Portainer"; exit 1; }

# This job never stops a stack, removes a container or prunes before the
# redeploy. The old version tore everything down first and rebuilt it after;
# any failure in between (on 2026-11-10: a "prune operation is already running"
# at boot) left every production stack down until someone noticed. Now each
# stack is redeployed in place: redeploy-stacks.sh pre-pulls the branch's
# images on the host (a plain `docker pull` always refreshes a moving tag, so
# no prior prune is needed against stale cached images) and Portainer only
# recreates the containers. A stack whose redeploy fails before compose starts
# recreating (Infisical, GitHub or Portainer API errors) keeps what was running;
# a failure during the recreate itself can still take a service down, which is
# why every stack is health-checked afterwards and any failure alerts.
echo "[maintenance-redeploy] redeploying all stacks in place"
BRANCH=$(redeploy_branch_for_env "${INFISICAL_ENV:-}")
mapfile -t STACK_NAMES < <(echo "$STACKS_JSON" | jq -r '.[].Name')
# Sets FAILED_STACKS to the stacks of "$@" that failed; appends skips to
# SKIPPED_STACKS.
redeploy_pass() {
    local name rc
    FAILED_STACKS=()
    for name in "$@"; do
        rc=0
        /opt/deploy/redeploy-stacks.sh --stack "$name" --ref "refs/heads/${BRANCH}" || rc=$?
        case "$rc" in
            0) ;;
            "$REDEPLOY_EXIT_SKIPPED") SKIPPED_STACKS+=("$name") ;;
            *) FAILED_STACKS+=("$name") ;;
        esac
    done
}

SKIPPED_STACKS=()
redeploy_pass "${STACK_NAMES[@]}"
# A stack can fail only because it came before a stack it depends on in
# Portainer's order (n8n joins focus's focus_focus-network as external). A
# second pass, once every other stack had its turn, resolves that without
# encoding the dependencies here; a skip is deterministic and is not retried.
if [[ "${#FAILED_STACKS[@]}" -gt 0 ]]; then
    echo "[maintenance-redeploy] retrying after first pass: ${FAILED_STACKS[*]}"
    redeploy_pass "${FAILED_STACKS[@]}"
fi

if [[ "${#FAILED_STACKS[@]}" -gt 0 ]]; then
    echo "[maintenance-redeploy] FAILED to redeploy: ${FAILED_STACKS[*]}" >&2
fi
# Nothing was stopped before the redeploy, so a skipped stack keeps running as
# it was. Worth reporting, not worth failing the job over.
if [[ "${#SKIPPED_STACKS[@]}" -gt 0 ]]; then
    echo "[maintenance-redeploy] skipped (no Infisical secrets for environment '${INFISICAL_ENV:-}'), left running as before: ${SKIPPED_STACKS[*]}" >&2
fi

HEALTH_TIMEOUT_SECONDS=${HEALTH_TIMEOUT_SECONDS:-300}
HEALTH_POLL_SECONDS=10
# A container that crashes a few seconds after start looks "Up" on the first
# poll, so stacks must still be healthy after this settle period too.
HEALTH_SETTLE_SECONDS=${HEALTH_SETTLE_SECONDS:-60}

# A 2xx from Portainer only means compose accepted the stack, not that its
# containers came up. Prints the problem and returns 1 while the stack is not
# (yet) healthy: no container, none running, a container restarting, dead,
# created but never started, exited non-zero, unhealthy or still in its
# healthcheck's start period. A one-shot container that exited 0 is fine.
stack_health_problem() {
    # Compose lowercases the project name Portainer passes (the stack name).
    local project states line state status running=0
    project=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    # oneoff=False drops `docker compose run` leftovers, which are not part of
    # the stack's running services.
    states=$(docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --filter "label=com.docker.compose.oneoff=False" \
        --format '{{.State}}|{{.Status}}') || { echo "docker ps failed"; return 1; }
    [[ -z "$states" ]] && { echo "no containers"; return 1; }
    while IFS= read -r line; do
        state="${line%%|*}"; status="${line#*|}"
        case "$state" in
            running)
                case "$status" in
                    *"(unhealthy)"*)        echo "$status"; return 1 ;;
                    *"(health: starting)"*) echo "$status"; return 1 ;;
                esac
                running=$((running + 1)) ;;
            exited)
                [[ "$status" == "Exited (0)"* ]] || { echo "$status"; return 1; } ;;
            *)  echo "$state: $status"; return 1 ;;
        esac
    done <<< "$states"
    [[ "$running" -gt 0 ]] || { echo "no running container"; return 1; }
}

# Sets UNHEALTHY_STACKS to the stacks of "$@" still unhealthy at the deadline.
wait_until_healthy() {
    local deadline=$(( SECONDS + HEALTH_TIMEOUT_SECONDS )) name problem pending
    while :; do
        pending=()
        for name in "$@"; do
            stack_health_problem "$name" >/dev/null || pending+=("$name")
        done
        UNHEALTHY_STACKS=(${pending[@]+"${pending[@]}"})
        [[ "${#pending[@]}" -eq 0 || "$SECONDS" -ge "$deadline" ]] && break
        sleep "$HEALTH_POLL_SECONDS"
    done
    for name in ${UNHEALTHY_STACKS[@]+"${UNHEALTHY_STACKS[@]}"}; do
        problem=$(stack_health_problem "$name") || true
        echo "[maintenance-redeploy] UNHEALTHY after ${HEALTH_TIMEOUT_SECONDS}s: ${name} (${problem})" >&2
    done
}

REDEPLOYED_STACKS=()
for name in "${STACK_NAMES[@]}"; do
    [[ " ${FAILED_STACKS[*]-} ${SKIPPED_STACKS[*]-} " == *" ${name} "* ]] || REDEPLOYED_STACKS+=("$name")
done
UNHEALTHY_STACKS=()
if [[ "${#REDEPLOYED_STACKS[@]}" -gt 0 ]]; then
    echo "[maintenance-redeploy] waiting for redeployed stacks to become healthy"
    wait_until_healthy "${REDEPLOYED_STACKS[@]}"
    if [[ "${#UNHEALTHY_STACKS[@]}" -eq 0 ]]; then
        echo "[maintenance-redeploy] all healthy; re-checking after ${HEALTH_SETTLE_SECONDS}s"
        sleep "$HEALTH_SETTLE_SECONDS"
        HEALTH_TIMEOUT_SECONDS=0 wait_until_healthy "${REDEPLOYED_STACKS[@]}"
    fi
fi

if [[ "$(( ${#FAILED_STACKS[@]} + ${#UNHEALTHY_STACKS[@]} ))" -gt 0 ]]; then
    # No prune: a stack that did not come back may still need its images for a
    # manual rollback. The stamp file stays so the next boot retries; the
    # non-zero exit fires the unit's OnFailure= alert.
    exit 1
fi

PRUNE_ATTEMPTS=3
PRUNE_BACKOFF_SECONDS=10

# Docker rejects a prune while another of the same kind is still in flight
# ("a prune operation is already running"), which happens at boot.
prune_with_retry() {
    local attempt
    for (( attempt = 1; attempt <= PRUNE_ATTEMPTS; attempt++ )); do
        "$@" && return 0
        (( attempt < PRUNE_ATTEMPTS )) && sleep $(( PRUNE_BACKOFF_SECONDS * attempt ))
    done
    return 1
}

# Housekeeping only, after every stack is back and healthy: `image prune -a`
# removes just the images no container uses (the ones the redeploy replaced).
# It never touches containers, networks or volumes, and its failure costs disk
# space, not uptime — so it warns instead of failing the job.
echo "[maintenance-redeploy] pruning unused images"
prune_with_retry docker image prune -a -f \
    || echo "[maintenance-redeploy] WARNING: could not prune unused images; continuing" >&2

# Must stay last: on any earlier failure the job exits before this runs,
# leaving the stamp file in place so ConditionPathExists= re-triggers this
# service on the next boot. That retry is safe now that the job is in place.
rm -f "$STAMP_FILE"
echo "[maintenance-redeploy] complete"
