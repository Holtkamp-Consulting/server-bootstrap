#!/bin/bash
set -euo pipefail

STACK_NAME=""
REF=""
# Explicit compose IMAGE_TAG to deploy. The CI caller (redeploy.yml) passes this
# via the $DEPLOY_IMAGE_TAG environment variable rather than a CLI flag on
# purpose: an older copy of this script already installed on a server ignores an
# unknown env var but aborts on an unknown flag ("Unknown argument"), so the env
# var keeps redeploys working during the window between merging a new
# redeploy.yml and re-running install.sh to refresh /opt/deploy/redeploy-stacks.sh.
IMAGE_TAG_ARG="${DEPLOY_IMAGE_TAG:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --stack) STACK_NAME="$2"; shift 2 ;;
        --ref)   REF="$2";        shift 2 ;;
        --image-tag) IMAGE_TAG_ARG="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$STACK_NAME" ]]; then
    echo "Usage: $0 --stack <name> [--ref <git-ref>] [--image-tag <tag>]"
    echo "       (--image-tag may also be supplied via \$DEPLOY_IMAGE_TAG)"
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

# Resolve the compose IMAGE_TAG to inject when Infisical does not pin one.
#
# Prefer an explicit per-commit tag ($1, from --image-tag / $DEPLOY_IMAGE_TAG):
# app CI publishes an immutable `sha-<sha>` tag (docker/metadata-action
# type=sha,format=long) that never exists on the server, so Portainer's
# pullImage:true reliably fetches it. A branch moving-tag (dev/main) does exist
# locally after the first deploy, and Portainer then reuses the cached digest
# instead of pulling the newly-built image — the stale-deploy bug this fixes.
#
# Fall back to the branch moving-tag ($2 is the git ref) when no per-commit tag
# is given (e.g. a manual host run without --image-tag) so those deploys still
# resolve a tag that exists on GHCR rather than compose's ${IMAGE_TAG:-latest}
# default, which is only published on main.
resolve_default_image_tag() {
    local explicit_tag="$1" ref="$2"
    if [[ -n "$explicit_tag" ]]; then
        printf '%s' "$explicit_tag"
        return 0
    fi
    local branch="${ref#refs/heads/}"
    branch="${branch#refs/tags/}"
    printf '%s' "$branch"
}

# An explicit IMAGE_TAG from Infisical wins over the resolved default (e.g. to
# pin a specific build), so only inject when Infisical does not already set one.
DEFAULT_IMAGE_TAG="$(resolve_default_image_tag "$IMAGE_TAG_ARG" "$REF")"
if [[ -n "$DEFAULT_IMAGE_TAG" ]] && ! echo "$ENV_JSON" | jq -e 'any(.[]; .name == "IMAGE_TAG")' >/dev/null; then
    ENV_JSON=$(echo "$ENV_JSON" | jq --arg tag "$DEFAULT_IMAGE_TAG" \
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

# ── Host pre-pull ─────────────────────────────────────────────────────────────
# Portainer's own image pull has repeatedly resolved a stale/wrong image for our
# per-commit sha tags — it recreated the container on an old cached image while a
# plain `docker pull` of the SAME tag fetched the correct one. So pull the images
# ourselves with the reliable docker client (the runner has the host docker
# socket), then tell Portainer NOT to pull (pullImage:false); it just recreates
# onto the freshly-pulled local image. Best-effort: on any failure PULL_IMAGE_FLAG
# stays true and Portainer pulls as before.
PULL_IMAGE_FLAG=true

prepull_stack_images() {
    command -v docker >/dev/null 2>&1 || { echo "docker CLI unavailable; leaving image pull to Portainer"; return 1; }

    local repo="${GITHUB_REPOSITORY:-Holtkamp-Consulting/${STACK_NAME}}"
    local ref_name="${REF#refs/heads/}"; ref_name="${ref_name#refs/tags/}"; ref_name="${ref_name:-main}"
    local ref_q; ref_q=$(jq -nr --arg v "$ref_name" '$v | @uri')

    local compose
    compose=$(curl -sSfL \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.raw" \
        "https://api.github.com/repos/${repo}/contents/docker-compose.yml?ref=${ref_q}") \
        || { echo "Could not fetch docker-compose.yml for pre-pull; leaving pull to Portainer"; return 1; }

    # Every ghcr.io image reference (registry/owner/name, sans tag). Only these
    # are ours to pull with GITHUB_TOKEN; other images (e.g. grafana) are left for
    # compose to pull on demand.
    local images
    images=$(printf '%s\n' "$compose" | grep -oE 'ghcr\.io/[a-z0-9._/-]+' | sort -u)
    [[ -z "$images" ]] && { echo "No ghcr.io images in compose; leaving pull to Portainer"; return 1; }

    local tag
    tag=$(printf '%s' "$ENV_JSON" | jq -r 'map(select(.name == "IMAGE_TAG")) | .[0].value // "latest"')

    printf '%s' "$GITHUB_TOKEN" | docker login ghcr.io -u token --password-stdin >/dev/null 2>&1 \
        || { echo "docker login ghcr.io failed; leaving pull to Portainer"; return 1; }

    local img ok=1
    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        echo "Pre-pulling ${img}:${tag}"
        docker pull "${img}:${tag}" >/dev/null 2>&1 || { echo "  pull failed: ${img}:${tag}"; ok=0; }
    done <<< "$images"

    docker logout ghcr.io >/dev/null 2>&1 || true
    [[ "$ok" == "1" ]]
}

# The github-runner stack can't pre-pull the image running this very script, so
# leave its (async) self-update to Portainer's own pull.
if [[ "$STACK_NAME" != "github-runner" ]] && prepull_stack_images; then
    PULL_IMAGE_FLAG=false
    echo "Images pre-pulled on host; Portainer will redeploy without pulling"
fi

BODY=$(jq -n \
    --argjson env "$ENV_JSON" \
    --arg password "$GITHUB_TOKEN" \
    --argjson pull "$PULL_IMAGE_FLAG" \
    '{env: $env, pullImage: $pull, repositoryAuthentication: true, repositoryUsername: "token", repositoryPassword: $password}')

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
        --argjson pull "$PULL_IMAGE_FLAG" \
        '{stackFileContent: $content, env: $env, pullImage: $pull}')

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
