#!/bin/bash
set -euo pipefail

STACK_NAME=""
REF=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --stack) STACK_NAME="$2"; shift 2 ;;
        --ref)   REF="$2";        shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$STACK_NAME" ]]; then
    echo "Usage: $0 --stack <name> [--ref <git-ref>]"
    exit 1
fi

DEPLOY_CONFIG="/etc/infisical-deploy.env"
PORTAINER_ADMIN="admin"

# Env vars take precedence (container context); fall back to config file (host context).
if [[ -z "${PORTAINER_URL:-}" ]]; then
    if [[ -r "$DEPLOY_CONFIG" ]]; then
        source "$DEPLOY_CONFIG"
    else
        source <(sudo cat "$DEPLOY_CONFIG")
    fi
fi

# ── Portainer JWT ──────────────────────────────────────────────────────────────
AUTH_PAYLOAD=$(jq -n --arg u "$PORTAINER_ADMIN" --arg p "$PORTAINER_PASSWORD" \
    '{username: $u, password: $p}')
PORTAINER_TOKEN=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -d "$AUTH_PAYLOAD" \
    "${PORTAINER_URL}/api/auth" | jq -r '.jwt // empty')
[[ -z "$PORTAINER_TOKEN" ]] && { echo "Portainer auth failed"; exit 1; }

ENDPOINT_ID=$(curl -sf \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    "${PORTAINER_URL}/api/endpoints" | jq '.[0].Id')

# ── Infisical ─────────────────────────────────────────────────────────────────
INFISICAL_TOKEN=$(curl -sf -X POST \
    "${INFISICAL_URL%/}/api/v1/auth/universal-auth/login" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg cid "$INFISICAL_CLIENT_ID" --arg cs "$INFISICAL_CLIENT_SECRET" \
        '{clientId: $cid, clientSecret: $cs}')" \
    | jq -r '.accessToken // empty')
[[ -z "$INFISICAL_TOKEN" ]] && { echo "Infisical auth failed"; exit 1; }

INFISICAL_API_BASE="${INFISICAL_URL%/}"

PROJECTS_JSON=$(curl -sf \
    -H "Authorization: Bearer ${INFISICAL_TOKEN}" \
    "${INFISICAL_API_BASE}/api/v1/projects" | jq '.projects')

PROJECT_ID=$(echo "$PROJECTS_JSON" | jq -r --arg name "${STACK_NAME,,}" \
    '.[] | select((.name | ascii_downcase) == $name) | .id // empty')
[[ -z "$PROJECT_ID" ]] && { echo "No Infisical project found for '$STACK_NAME'"; exit 1; }

P_Q=$(jq -nr --arg v "$PROJECT_ID"    '$v | @uri')
E_Q=$(jq -nr --arg v "$INFISICAL_ENV" '$v | @uri')
PTH_Q=$(jq -nr --arg v "$INFISICAL_PATH" '$v | @uri')

SECRETS_RESP=$(curl -sf \
    -H "Authorization: Bearer ${INFISICAL_TOKEN}" \
    "${INFISICAL_API_BASE}/api/v4/secrets?projectId=${P_Q}&environment=${E_Q}&secretPath=${PTH_Q}&viewSecretValue=true&includeImports=true")

ENV_JSON=$(echo "$SECRETS_RESP" | jq '[
    ((.imports // []) | .[].secrets[]?),
    (.secrets // [])[]
] | reduce .[] as $s ({}; .[$s.secretKey] = $s.secretValue)
  | to_entries | map({name: .key, value: .value})')

# ── Portainer stack ───────────────────────────────────────────────────────────
STACK_ID=$(curl -sf \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    "${PORTAINER_URL}/api/stacks" \
    | jq --arg n "$STACK_NAME" '.[] | select(.Name == $n) | .Id')

if [[ -z "$STACK_ID" || "$STACK_ID" == "null" ]]; then
    echo "Stack '$STACK_NAME' not found in Portainer — run install.sh first"
    exit 1
fi

BODY=$(jq -n \
    --argjson env "$ENV_JSON" \
    --arg password "$GITHUB_TOKEN" \
    '{env: $env, pullImage: true, repositoryAuthentication: true, repositoryUsername: "token", repositoryPassword: $password}')

if [[ -n "$REF" ]]; then
    BODY=$(echo "$BODY" | jq --arg ref "$REF" '. + {repositoryReferenceName: $ref}')
fi

RESPONSE_FILE=$(mktemp)
HTTP=$(curl -sS -X POST \
    -o "$RESPONSE_FILE" -w "%{http_code}" \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    -H "Content-Type: application/json" \
    "${PORTAINER_URL}/api/stacks/${STACK_ID}/git/redeploy?endpointId=${ENDPOINT_ID}" \
    -d "$BODY")

if [[ "$HTTP" -ge 200 && "$HTTP" -lt 300 ]]; then
    echo "Stack '$STACK_NAME' redeployed (HTTP $HTTP)"
    rm -f "$RESPONSE_FILE"
else
    echo "Failed to redeploy '$STACK_NAME' (HTTP $HTTP)"
    head -c 500 "$RESPONSE_FILE"
    rm -f "$RESPONSE_FILE"
    exit 1
fi
