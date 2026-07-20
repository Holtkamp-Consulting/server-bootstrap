#!/bin/bash
set -euo pipefail

STAMP_FILE="/var/lib/server-bootstrap/maintenance-reboot-pending"
DEPLOY_CONFIG="/etc/infisical-deploy.env"
PORTAINER_ADMIN="admin"

# Maps this host's persisted Infisical environment to the branch whose images
# it runs — mirrors install.sh's deploy_branch_for_env(), duplicated (not
# fetched at runtime) because this script must work unattended overnight with
# no network dependency on install.sh; see plan Alternatives Rejected.
redeploy_branch_for_env() {
    case "$1" in
        dev) printf 'dev' ;;
        *)   printf 'main' ;;
    esac
}

if [[ -z "${PORTAINER_URL:-}" ]]; then
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

echo "[maintenance-redeploy] stopping all stacks"
mapfile -t STACK_IDS < <(echo "$STACKS_JSON" | jq -r '.[].Id')
for id in "${STACK_IDS[@]}"; do
    curl -sfk -X POST \
        -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
        "${PORTAINER_URL}/api/stacks/${id}/stop?endpointId=${ENDPOINT_ID}" >/dev/null || true
done

echo "[maintenance-redeploy] removing all containers"
CONTAINER_IDS=$(docker ps -aq)
# shellcheck disable=SC2086
[[ -n "$CONTAINER_IDS" ]] && docker rm -f $CONTAINER_IDS

echo "[maintenance-redeploy] pruning all images"
docker system prune -a -f

echo "[maintenance-redeploy] redeploying all stacks"
BRANCH=$(redeploy_branch_for_env "${INFISICAL_ENV:-}")
mapfile -t STACK_NAMES < <(echo "$STACKS_JSON" | jq -r '.[].Name')
for name in "${STACK_NAMES[@]}"; do
    /opt/deploy/redeploy-stacks.sh --stack "$name" --ref "refs/heads/${BRANCH}"
done

rm -f "$STAMP_FILE"
echo "[maintenance-redeploy] complete"
