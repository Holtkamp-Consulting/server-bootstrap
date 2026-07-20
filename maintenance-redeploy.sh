#!/bin/bash
set -euo pipefail

STAMP_FILE="/var/lib/server-bootstrap/maintenance-reboot-pending"
DEPLOY_CONFIG="/etc/infisical-deploy.env"
PORTAINER_ADMIN="admin"

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

echo "[maintenance-redeploy] pruning all images"
docker system prune -a -f

echo "[maintenance-redeploy] redeploying all stacks"
BRANCH=$(redeploy_branch_for_env "${INFISICAL_ENV:-}")
mapfile -t STACK_NAMES < <(echo "$STACKS_JSON" | jq -r '.[].Name')
FAILED_STACKS=()
for name in "${STACK_NAMES[@]}"; do
    /opt/deploy/redeploy-stacks.sh --stack "$name" --ref "refs/heads/${BRANCH}" \
        || FAILED_STACKS+=("$name")
done

if [[ "${#FAILED_STACKS[@]}" -gt 0 ]]; then
    echo "[maintenance-redeploy] FAILED to redeploy: ${FAILED_STACKS[*]}" >&2
    exit 1
fi

# Must stay last: on any earlier failure, set -euo pipefail exits before this
# runs, leaving the stamp file in place so ConditionPathExists= re-triggers
# this service on the next boot instead of silently giving up.
rm -f "$STAMP_FILE"
echo "[maintenance-redeploy] complete"
