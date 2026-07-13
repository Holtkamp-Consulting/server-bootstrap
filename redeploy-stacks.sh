#!/bin/bash
set -euo pipefail

STACK_NAME=""
REF=""
KEEP_IMAGES=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --stack) STACK_NAME="$2"; shift 2 ;;
        --ref)   REF="$2";        shift 2 ;;
        --keep-images) KEEP_IMAGES=1; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$STACK_NAME" ]]; then
    echo "Usage: $0 --stack <name> [--ref <git-ref>] [--keep-images]"
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
PORTAINER_TOKEN=$(curl -sfk -X POST \
    -H "Content-Type: application/json" \
    -d "$AUTH_PAYLOAD" \
    "${PORTAINER_URL}/api/auth" | jq -r '.jwt // empty')
[[ -z "$PORTAINER_TOKEN" ]] && { echo "Portainer auth failed"; exit 1; }

ENDPOINT_ID=$(curl -sfk \
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

ENV_JSON=$(echo "$SECRETS_RESP" | jq '
def normalize_private_key_value:
    if type != "string" then .
    elif test("\\\\n") then gsub("\\\\n"; "\n")
    elif test("^-----BEGIN [^-]+-----[[:space:]]+.+[[:space:]]+-----END [^-]+-----$") then
        capture("^(?<header>-----BEGIN [^-]+-----)[[:space:]]+(?<body>.+)[[:space:]]+(?<footer>-----END [^-]+-----)$")
        | "\(.header)\n\(.body | gsub("[[:space:]]+"; "\n"))\n\(.footer)"
    else .
    end;
def env_secret_value($key):
    if ($key | test("(^|_)PRIVATE_KEY$")) then normalize_private_key_value
    elif type == "string" then gsub("\n"; "\\n")
    else .
    end;
[
    ((.imports // []) | .[].secrets[]?),
    (.secrets // [])[]
] | reduce .[] as $s ({}; .[$s.secretKey] = ($s.secretValue | env_secret_value($s.secretKey)))
  | to_entries | map({name: .key, value: .value})')

# Default the compose IMAGE_TAG to the branch moving-tag (dev/main) that the app
# CI publishes to GHCR. Without this, compose's ${IMAGE_TAG:-latest} resolves to
# :latest — which is only published on main (see focus/.github/workflows/deploy.yml)
# — so dev deploys fail with "ghcr.io/.../<svc>:latest: not found". An explicit
# IMAGE_TAG from Infisical wins (e.g. to pin a specific SHA).
REF_BRANCH="${REF#refs/heads/}"
REF_BRANCH="${REF_BRANCH#refs/tags/}"
if [[ -n "$REF_BRANCH" ]] && ! echo "$ENV_JSON" | jq -e 'any(.[]; .name == "IMAGE_TAG")' >/dev/null; then
    ENV_JSON=$(echo "$ENV_JSON" | jq --arg tag "$REF_BRANCH" \
        '. + [{name: "IMAGE_TAG", value: $tag}]')
fi

if [[ "$STACK_NAME" == "github-runner" ]]; then
    [[ -z "${APP_PRIVATE_KEY:-}" ]] && { echo "APP_PRIVATE_KEY missing from deploy config"; exit 1; }
    APP_PRIVATE_KEY_B64="$(printf '%s' "$APP_PRIVATE_KEY" | base64 | tr -d '\n')"
    ENV_JSON=$(echo "$ENV_JSON" | jq \
        --arg value "$APP_PRIVATE_KEY_B64" \
        'map(select(.name != "APP_PRIVATE_KEY" and .name != "APP_PRIVATE_KEY_B64")) + [{name: "APP_PRIVATE_KEY_B64", value: $value}]')
fi

# ── Portainer stack ───────────────────────────────────────────────────────────
STACK_ID=$(curl -sfk \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    "${PORTAINER_URL}/api/stacks" \
    | jq --arg n "$STACK_NAME" '.[] | select(.Name == $n) | .Id')

if [[ -z "$STACK_ID" || "$STACK_ID" == "null" ]]; then
    echo "Stack '$STACK_NAME' not found in Portainer — run install.sh first"
    exit 1
fi

# ── Pre-redeploy image cleanup ────────────────────────────────────────────────
# Stop the stack, remove its containers, and delete its images so the redeploy
# below pulls fresh images for the branch moving-tag (dev/main) instead of
# reusing a cached digest. Best-effort: cleanup failures never block redeploy.

# Reads `docker/containers/json` on stdin, prints ".Id .ImageID" for every
# container belonging to this stack's compose project (case-insensitive match,
# mirroring the Infisical project match above).
stack_project_containers() {
    jq -r --arg name "$STACK_NAME" '
        .[]
        | select((.Labels["com.docker.compose.project"] // "" | ascii_downcase) == ($name | ascii_downcase))
        | "\(.Id) \(.ImageID)"'
}

clean_stack_images() {
    echo "Stopping stack '$STACK_NAME' before image cleanup"
    curl -sSk -o /dev/null -X POST \
        -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
        "${PORTAINER_URL}/api/stacks/${STACK_ID}/stop?endpointId=${ENDPOINT_ID}" || true

    local containers_json rows container_ids image_ids
    containers_json=$(curl -sSk \
        -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
        "${PORTAINER_URL}/api/endpoints/${ENDPOINT_ID}/docker/containers/json?all=1") || return 0

    rows=$(printf '%s' "$containers_json" | stack_project_containers)
    if [[ -z "$rows" ]]; then
        echo "No containers found for stack '$STACK_NAME'; skipping image cleanup"
        return 0
    fi

    container_ids=$(printf '%s\n' "$rows" | awk '{print $1}')
    image_ids=$(printf '%s\n' "$rows" | awk '{print $2}' | sort -u)

    # Remove containers first: Docker refuses to delete an image still
    # referenced by a container, even a stopped one, even with force.
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        local cid_q; cid_q=$(jq -nr --arg v "$cid" '$v | @uri')
        echo "Removing container ${cid}"
        curl -sSk -o /dev/null -X DELETE \
            -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
            "${PORTAINER_URL}/api/endpoints/${ENDPOINT_ID}/docker/containers/${cid_q}?force=1" || true
    done <<< "$container_ids"

    while IFS= read -r iid; do
        [[ -z "$iid" ]] && continue
        local iid_q; iid_q=$(jq -nr --arg v "$iid" '$v | @uri')
        echo "Removing image ${iid}"
        curl -sSk -o /dev/null -X DELETE \
            -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
            "${PORTAINER_URL}/api/endpoints/${ENDPOINT_ID}/docker/images/${iid_q}?force=1" || true
    done <<< "$image_ids"
}

if [[ "$STACK_NAME" != "github-runner" && "${KEEP_IMAGES:-}" != "1" ]]; then
    clean_stack_images
fi

BODY=$(jq -n \
    --argjson env "$ENV_JSON" \
    --arg password "$GITHUB_TOKEN" \
    '{env: $env, pullImage: true, repositoryAuthentication: true, repositoryUsername: "token", repositoryPassword: $password}')

if [[ -n "$REF" ]]; then
    BODY=$(echo "$BODY" | jq --arg ref "$REF" '. + {repositoryReferenceName: $ref}')
fi

update_stack_from_repository() {
    local response_file="$1"
    local repo="${GITHUB_REPOSITORY:-Holtkamp-Consulting/${STACK_NAME}}"
    local ref="${REF:-refs/heads/main}"
    local ref_name="$ref"
    ref_name="${ref_name#refs/heads/}"
    ref_name="${ref_name#refs/tags/}"
    local ref_q
    ref_q=$(jq -nr --arg v "$ref_name" '$v | @uri')

    local compose_file
    if ! compose_file=$(curl -sSfL \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.raw" \
        "https://api.github.com/repos/${repo}/contents/docker-compose.yml?ref=${ref_q}" 2>"$response_file"); then
        echo "000"
        return
    fi

    local update_body
    update_body=$(jq -n \
        --arg content "$compose_file" \
        --argjson env "$ENV_JSON" \
        '{stackFileContent: $content, env: $env, pullImage: true}')

    curl -sSk -X PUT \
        -o "$response_file" -w "%{http_code}" \
        -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
        -H "Content-Type: application/json" \
        "${PORTAINER_URL}/api/stacks/${STACK_ID}?endpointId=${ENDPOINT_ID}" \
        -d "$update_body"
}

schedule_self_update_from_repository() {
    local response_file="$1"
    local repo="${GITHUB_REPOSITORY:-Holtkamp-Consulting/${STACK_NAME}}"
    local ref="${REF:-refs/heads/main}"
    local ref_name="$ref"
    ref_name="${ref_name#refs/heads/}"
    ref_name="${ref_name#refs/tags/}"
    local ref_q
    ref_q=$(jq -nr --arg v "$ref_name" '$v | @uri')

    local compose_file
    if ! compose_file=$(curl -sSfL \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.raw" \
        "https://api.github.com/repos/${repo}/contents/docker-compose.yml?ref=${ref_q}" 2>"$response_file"); then
        echo "Failed to fetch docker-compose.yml for '$STACK_NAME'"
        head -c 500 "$response_file"
        rm -f "$response_file"
        exit 1
    fi

    local update_body_file
    update_body_file=$(mktemp)
    chmod 600 "$update_body_file"
    jq -n \
        --arg content "$compose_file" \
        --argjson env "$ENV_JSON" \
        '{stackFileContent: $content, env: $env, pullImage: true}' > "$update_body_file"

    # Updating the runner stack stops this very container. Detach the Portainer
    # call so GitHub Actions can record a successful job before the restart.
    env -u RUNNER_TRACKING_ID \
        PORTAINER_TOKEN="$PORTAINER_TOKEN" \
        PORTAINER_URL="$PORTAINER_URL" \
        STACK_ID="$STACK_ID" \
        ENDPOINT_ID="$ENDPOINT_ID" \
        UPDATE_BODY_FILE="$update_body_file" \
        nohup bash -c '
        sleep 5
        curl -sSk -X PUT \
            -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
            -H "Content-Type: application/json" \
            "${PORTAINER_URL}/api/stacks/${STACK_ID}?endpointId=${ENDPOINT_ID}" \
            -d @"${UPDATE_BODY_FILE}" >/tmp/github-runner-self-update.log 2>&1
        rm -f "${UPDATE_BODY_FILE}"
    ' >/dev/null 2>&1 &

    echo "Stack '$STACK_NAME' self-update scheduled; runner will restart shortly"
    rm -f "$response_file"
}

RESPONSE_FILE=$(mktemp)
HTTP=$(curl -sSk -X PUT \
    -o "$RESPONSE_FILE" -w "%{http_code}" \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    -H "Content-Type: application/json" \
    "${PORTAINER_URL}/api/stacks/${STACK_ID}/git/redeploy?endpointId=${ENDPOINT_ID}" \
    -d "$BODY")

if [[ "$HTTP" -ge 200 && "$HTTP" -lt 300 ]]; then
    echo "Stack '$STACK_NAME' redeployed (HTTP $HTTP)"
    rm -f "$RESPONSE_FILE"
elif [[ "$HTTP" == "400" ]] && grep -q "Stack is not created from git" "$RESPONSE_FILE"; then
    echo "Stack '$STACK_NAME' is not git-based in Portainer; updating stack file from repository"
    if [[ "$STACK_NAME" == "github-runner" ]]; then
        schedule_self_update_from_repository "$RESPONSE_FILE"
        exit 0
    fi
    HTTP=$(update_stack_from_repository "$RESPONSE_FILE")
    if [[ "$HTTP" -ge 200 && "$HTTP" -lt 300 ]]; then
        echo "Stack '$STACK_NAME' updated (HTTP $HTTP)"
        rm -f "$RESPONSE_FILE"
    else
        echo "Failed to update '$STACK_NAME' (HTTP $HTTP)"
        head -c 500 "$RESPONSE_FILE"
        rm -f "$RESPONSE_FILE"
        exit 1
    fi
else
    echo "Failed to redeploy '$STACK_NAME' (HTTP $HTTP)"
    head -c 500 "$RESPONSE_FILE"
    rm -f "$RESPONSE_FILE"
    exit 1
fi
