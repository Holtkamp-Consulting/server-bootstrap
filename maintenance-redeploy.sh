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
PORTAINER_TOKEN=$(curl -sfk -X POST \
    -H "Content-Type: application/json" \
    -d "$AUTH_PAYLOAD" \
    "${PORTAINER_URL}/api/auth" | jq -r '.jwt // empty')
[[ -z "$PORTAINER_TOKEN" ]] && { echo "Portainer auth failed"; exit 1; }

ENDPOINT_ID=$(curl -sfk \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    "${PORTAINER_URL}/api/endpoints" | jq '.[0].Id')

STACKS_JSON=$(curl -sfk \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    "${PORTAINER_URL}/api/stacks")
[[ -n "$STACKS_JSON" ]] && jq -e 'type == "array"' <<<"$STACKS_JSON" >/dev/null \
    || { echo "Failed to fetch stack list from Portainer — aborting before teardown"; exit 1; }

echo "[maintenance-redeploy] stopping all stacks"
mapfile -t STACK_IDS < <(echo "$STACKS_JSON" | jq -r '.[].Id')
for id in "${STACK_IDS[@]}"; do
    curl -sfk -X POST \
        -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
        "${PORTAINER_URL}/api/stacks/${id}/stop?endpointId=${ENDPOINT_ID}" >/dev/null || true
done

echo "[maintenance-redeploy] removing all containers (except portainer)"
CONTAINER_IDS=$(docker ps -a --format '{{.ID}} {{.Names}}' | awk '$2 != "portainer" {print $1}')
# Intentional word-split: CONTAINER_IDS is one ID per line, and docker rm -f
# needs each as a separate argument.
# shellcheck disable=SC2086
[[ -n "$CONTAINER_IDS" ]] && docker rm -f $CONTAINER_IDS

PRUNE_ATTEMPTS=3
PRUNE_BACKOFF_SECONDS=10

# Docker rejects a prune while another of the same kind is still in flight
# ("a prune operation is already running"), which happens at boot. By now every
# container is already removed, so aborting on that transient error leaves every
# stack down; retry with a growing backoff instead.
prune_with_retry() {
    local attempt
    for (( attempt = 1; attempt <= PRUNE_ATTEMPTS; attempt++ )); do
        "$@" && return 0
        (( attempt < PRUNE_ATTEMPTS )) && sleep $(( PRUNE_BACKOFF_SECONDS * attempt ))
    done
    return 1
}

# Only the images have to go — the redeploy below resolves the branch's moving
# tag, which is safe only when no cached image of it is left. So when the full
# system prune keeps failing, an image-only prune still satisfies that.
prune_images() {
    prune_with_retry docker system prune -a -f && return 0
    echo "[maintenance-redeploy] docker system prune failed; falling back to docker image prune" >&2
    prune_with_retry docker image prune -a -f
}

echo "[maintenance-redeploy] pruning all images"
# Redeploying onto cached moving-tag images would silently reuse stale ones, so
# this is the one failure that must stop the job with every stack down; the
# stamp file stays, so the next boot retries the whole run.
prune_images || { echo "[maintenance-redeploy] could not prune images — not redeploying onto stale cached images" >&2; exit 1; }

echo "[maintenance-redeploy] redeploying all stacks"
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
# The prune also removed networks that one stack creates and another joins as
# external (n8n reaches focus's Postgres over focus_focus-network), so a stack
# can fail only because it came before its dependency in Portainer's order. A
# second pass, once every other stack had its turn, resolves that without
# encoding the dependencies here; a skip is deterministic and is not retried.
if [[ "${#FAILED_STACKS[@]}" -gt 0 ]]; then
    echo "[maintenance-redeploy] retrying after first pass: ${FAILED_STACKS[*]}"
    redeploy_pass "${FAILED_STACKS[@]}"
fi

if [[ "${#FAILED_STACKS[@]}" -gt 0 ]]; then
    echo "[maintenance-redeploy] FAILED to redeploy: ${FAILED_STACKS[*]}" >&2
fi
# A skip elsewhere costs nothing, but here the stack was running when this job
# started and the teardown above already stopped it, so a skipped stack stays
# down. That is a failed maintenance run, not a quiet success: report it and
# leave the stamp file for the next boot's retry.
if [[ "${#SKIPPED_STACKS[@]}" -gt 0 ]]; then
    echo "[maintenance-redeploy] STOPPED and NOT redeployed — no Infisical secrets for environment '${INFISICAL_ENV:-}': ${SKIPPED_STACKS[*]}" >&2
fi
if [[ "$(( ${#FAILED_STACKS[@]} + ${#SKIPPED_STACKS[@]} ))" -gt 0 ]]; then
    exit 1
fi

# Must stay last: on any earlier failure, set -euo pipefail exits before this
# runs, leaving the stamp file in place so ConditionPathExists= re-triggers
# this service on the next boot instead of silently giving up.
rm -f "$STAMP_FILE"
echo "[maintenance-redeploy] complete"
