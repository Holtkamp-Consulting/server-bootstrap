#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[•]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

prompt_input() {
    local prompt="$1"
    local var_name="$2"

    if [ -r /dev/tty ]; then
        read -r -p "$prompt" "$var_name" < /dev/tty
    else
        read -r -p "$prompt" "$var_name"
    fi
}

prompt_secret() {
    local prompt="$1"
    local var_name="$2"

    if [ -r /dev/tty ]; then
        read -r -s -p "$prompt" "$var_name" < /dev/tty
    else
        read -r -s -p "$prompt" "$var_name"
    fi
    echo ""
}

prompt_multiline_secret() {
    local prompt="$1"
    local var_name="$2"

    echo -e "$prompt (paste PEM key, input stops automatically at -----END line):"
    local value="" line
    local fd=0
    [ -r /dev/tty ] && exec 3</dev/tty && fd=3 || exec 3<&0 && fd=3
    while IFS= read -r line <&3; do
        value+="${line}"$'\n'
        [[ "$line" == *"-----END "*"-----"* ]] && break
    done
    exec 3<&-
    value="${value%$'\n'}"
    printf -v "$var_name" '%s' "$value"
    echo ""
}

normalize_private_key() {
    local value="$1"
    value="${value#APP_PRIVATE_KEY=}"
    value="${value//$'\r'/}"

    if [[ "$value" == *$'\n'* ]]; then
        printf '%s' "$value"
        return
    fi

    if [[ "$value" == *'\n'* ]]; then
        local newline=$'\n'
        printf '%s' "${value//\\n/$newline}"
        return
    fi

    if [[ "$value" =~ ^(-----BEGIN[[:space:]][^-]+-----)[[:space:]]+(.+)[[:space:]]+(-----END[[:space:]][^-]+-----)$ ]]; then
        local header="${BASH_REMATCH[1]}"
        local body="${BASH_REMATCH[2]}"
        local footer="${BASH_REMATCH[3]}"

        body="$(printf '%s' "$body" | tr -s '[:space:]' '\n')"
        printf '%s\n%s\n%s' "$header" "$body" "$footer"
        return
    fi

    printf '%s' "$value"
}

quote_env_value() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'\n" "$value"
}

require_value() {
    local value="$1"
    local label="$2"

    if [ -z "$value" ]; then
        err "$label must not be empty"
        exit 1
    fi
}

PORTAINER_ADMIN="admin"
PORTAINER_PORT_HTTP="${PORTAINER_PORT_HTTP:-9000}"
PORTAINER_PORT_HTTPS="${PORTAINER_PORT_HTTPS:-9443}"
DEPLOY_CONFIG="/etc/infisical-deploy.env"

load_deploy_config() {
    # The config is root-owned and mode 600 because it contains secrets.
    # Read it through sudo instead of making it world-readable.
    source <(sudo cat "$DEPLOY_CONFIG")
}

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║        Server Bootstrap Installer        ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Sudo precheck ──────────────────────────────────────────────────────────────
log "Checking sudo access..."
sudo -v || { err "sudo privileges required to run this script."; exit 1; }
ok "sudo OK"

if [ -f "$DEPLOY_CONFIG" ] && load_deploy_config && [ -n "${PORTAINER_PASSWORD:-}" ]; then
    PORTAINER_PASSWORD_FROM_CONFIG=1
else
    PORTAINER_PASSWORD_FROM_CONFIG=0
    PORTAINER_PASSWORD=$(openssl rand -hex 10)
fi

# ── Dependencies ───────────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    log "Installing jq..."
    sudo apt-get update -qq >/dev/null
    sudo apt-get install -y -qq jq >/dev/null
    ok "jq installed"
fi

# ── 1. Docker ─────────────────────────────────────────────────────────────────
log "Step 1/7 — Docker"

if command -v docker &>/dev/null; then
    ok "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
else
    log "Downloading and running official Docker install script..."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed"
    sudo usermod -aG docker "$USER" 2>/dev/null || true
fi

if ! sudo systemctl is-active --quiet docker 2>/dev/null; then
    log "Starting Docker service..."
    sudo systemctl enable --now docker
fi

# ── 2. Portainer ───────────────────────────────────────────────────────────────
log "Step 2/7 — Portainer CE"

# Use sudo only if the current user can't write to the socket directly
if [ -w /var/run/docker.sock ]; then
    DOCKER="docker"
else
    DOCKER="sudo docker"
fi

${DOCKER} volume create portainer_data >/dev/null || true

if ${DOCKER} ps --format '{{.Names}}' 2>/dev/null | grep -q '^portainer$'; then
    ok "Portainer already running — skipping"
else
    ${DOCKER} rm -f portainer >/dev/null 2>&1 || true
    ${DOCKER} run -d \
        --name portainer \
        --restart=always \
        -p "${PORTAINER_PORT_HTTP}:9000" \
        -p "${PORTAINER_PORT_HTTPS}:9443" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:latest >/dev/null
    ok "Portainer container started"
fi

# ── 3. Credentials ─────────────────────────────────────────────────────────────
log "Step 3/7 — Configuring admin credentials"

PORTAINER_API="http://localhost:${PORTAINER_PORT_HTTP}"
MAX_WAIT=90
elapsed=0

log "Waiting for Portainer API to become ready..."
until curl -sf "${PORTAINER_API}/api/status" &>/dev/null; do
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        err "Portainer did not become ready within ${MAX_WAIT}s"
        err "Check logs: sudo docker logs portainer"
        exit 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

INIT_PAYLOAD=$(jq -n \
    --arg username "$PORTAINER_ADMIN" \
    --arg password "$PORTAINER_PASSWORD" \
    '{Username: $username, Password: $password}')

INIT_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "$INIT_PAYLOAD" \
    "${PORTAINER_API}/api/users/admin/init" 2>/dev/null || echo "000")

case "$INIT_HTTP" in
    200|201) ok "Admin user configured" ;;
    409)
        ok "Admin user already initialised — skipping"
        if [ "$PORTAINER_PASSWORD_FROM_CONFIG" -eq 0 ]; then
            warn "Existing Portainer admin password required for API access"
            prompt_secret "  Portainer admin password:                  " PORTAINER_PASSWORD
            require_value "$PORTAINER_PASSWORD" "Portainer admin password"
        fi
        ;;
    *)       err "Failed to initialise admin user (HTTP ${INIT_HTTP})"; exit 1 ;;
esac

# ── 4. Infisical CLI ───────────────────────────────────────────────────────────
log "Step 4/7 — Infisical CLI"

if command -v infisical &>/dev/null; then
    ok "Infisical CLI already installed ($(infisical --version 2>&1 | head -1))"
else
    curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' | sudo -E bash
    sudo apt-get install -y infisical
    ok "Infisical CLI installed"
fi

# ── 5. Credentials ────────────────────────────────────────────────────────────
log "Step 5/7 — Infisical + GitHub credentials"

if [ -f "$DEPLOY_CONFIG" ]; then
    warn "Deploy config already exists at $DEPLOY_CONFIG — skipping credential setup"
    load_deploy_config
else
    log "Infisical Machine Identity: Infisical UI → Project → Access Control → Machine Identities → Create"
    echo ""
    prompt_input "  Infisical URL (e.g. http://mac-studio:80): " INF_URL
    prompt_input "  Client ID:                                  " INF_CLIENT_ID
    prompt_secret "  Client Secret:                              " INF_CLIENT_SECRET
    require_value "$INF_URL" "Infisical URL"
    require_value "$INF_CLIENT_ID" "Infisical Client ID"
    require_value "$INF_CLIENT_SECRET" "Infisical Client Secret"

    INF_ENV=""
    case "$(hostname)" in
        *-prod) INF_ENV="prod" ; log "Environment derived from hostname: prod" ;;
        *-dev)  INF_ENV="dev"  ; log "Environment derived from hostname: dev"  ;;
    esac
    if [ -z "$INF_ENV" ]; then
        prompt_input "  Environment (prod/staging/dev):             " INF_ENV
        require_value "$INF_ENV" "Infisical environment"
    fi

    echo ""
    log "GitHub Personal Access Token (needs repo scope):"
    prompt_secret "  GitHub Token: " GITHUB_TOKEN
    require_value "$GITHUB_TOKEN" "GitHub token"

    log "GitHub App Private Key (paste the PEM file content):"
    prompt_multiline_secret "  APP_PRIVATE_KEY" APP_PRIVATE_KEY_RAW
    require_value "$APP_PRIVATE_KEY_RAW" "APP_PRIVATE_KEY"
    APP_PRIVATE_KEY="$(normalize_private_key "$APP_PRIVATE_KEY_RAW")"

    log "Fetching Portainer API token..."
    AUTH_PAYLOAD=$(jq -n \
        --arg username "$PORTAINER_ADMIN" \
        --arg password "$PORTAINER_PASSWORD" \
        '{username: $username, password: $password}')
    PORTAINER_JWT=$(curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$AUTH_PAYLOAD" \
        "${PORTAINER_API}/api/auth" 2>/dev/null | jq -r '.jwt // empty' || true)

    if [ -z "$PORTAINER_JWT" ]; then
        err "Could not authenticate with Portainer — check the admin password"
        exit 1
    fi

    {
        printf 'INFISICAL_URL=%s\n' "$(quote_env_value "$INF_URL")"
        printf 'INFISICAL_CLIENT_ID=%s\n' "$(quote_env_value "$INF_CLIENT_ID")"
        printf 'INFISICAL_CLIENT_SECRET=%s\n' "$(quote_env_value "$INF_CLIENT_SECRET")"
        printf 'INFISICAL_ENV=%s\n' "$(quote_env_value "$INF_ENV")"
        printf 'INFISICAL_PATH=%s\n' "$(quote_env_value "/")"
        printf 'PORTAINER_URL=%s\n' "$(quote_env_value "https://localhost:${PORTAINER_PORT_HTTPS}")"
        printf 'PORTAINER_PASSWORD=%s\n' "$(quote_env_value "$PORTAINER_PASSWORD")"
        printf 'PORTAINER_TOKEN=%s\n' "$(quote_env_value "$PORTAINER_JWT")"
        printf 'GITHUB_TOKEN=%s\n' "$(quote_env_value "$GITHUB_TOKEN")"
        printf 'APP_PRIVATE_KEY=%s\n' "$(quote_env_value "$APP_PRIVATE_KEY")"
    } | sudo tee "$DEPLOY_CONFIG" > /dev/null
    sudo chown root:docker "$DEPLOY_CONFIG"
    sudo chmod 640 "$DEPLOY_CONFIG"
    load_deploy_config
    ok "Credentials saved to $DEPLOY_CONFIG"
fi

# ── 6. Stacks deployen ─────────────────────────────────────────────────────────
log "Step 6/7 — Stack deployment from GitHub"

# Portainer JWT immer frisch holen (cached token kann abgelaufen sein)
log "Refreshing Portainer API token..."
AUTH_PAYLOAD=$(jq -n \
    --arg username "$PORTAINER_ADMIN" \
    --arg password "$PORTAINER_PASSWORD" \
    '{username: $username, password: $password}')
PORTAINER_TOKEN=$(curl -sfk -X POST \
    -H "Content-Type: application/json" \
    -d "$AUTH_PAYLOAD" \
    "${PORTAINER_URL}/api/auth" 2>/dev/null | jq -r '.jwt // empty' || true)

if [ -z "$PORTAINER_TOKEN" ]; then
    err "Could not authenticate with Portainer — check credentials in $DEPLOY_CONFIG"
    exit 1
fi
ok "Portainer token refreshed"

# Portainer local endpoint ID
# Older Portainer versions return a plain array [...]; newer versions return
# a paginated object {"value": [...], "totalCount": n}. Handle both.
ENDPOINT_RESPONSE=$(curl -sfk \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    "${PORTAINER_URL}/api/endpoints" 2>/dev/null || true)
ENDPOINT_ID=$(printf '%s' "$ENDPOINT_RESPONSE" | \
    jq 'if type == "array" then .[0].Id else .value[0].Id end' 2>/dev/null || true)

if [ -z "$ENDPOINT_ID" ] || [ "$ENDPOINT_ID" = "null" ]; then
    err "Could not determine Portainer endpoint ID"
    exit 1
fi

# GitHub repos auflisten
log "Fetching GitHub repositories..."
REPOS_JSON="[]"
REPOS_PAGE=1
while true; do
    REPOS_RESPONSE_FILE=$(mktemp)
    REPOS_HTTP=$(curl -sS -L \
        -o "$REPOS_RESPONSE_FILE" \
        -w "%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/user/repos?per_page=100&page=${REPOS_PAGE}&sort=updated&affiliation=owner,collaborator,organization_member")
    REPOS_PAGE_JSON=$(cat "$REPOS_RESPONSE_FILE")
    rm -f "$REPOS_RESPONSE_FILE"

    case "$REPOS_HTTP" in
        200) ;;
        *)
            GITHUB_ERROR=$(echo "$REPOS_PAGE_JSON" | jq -r '.message // empty' 2>/dev/null || true)
            err "Could not fetch GitHub repositories (HTTP ${REPOS_HTTP})"
            if [ -n "$GITHUB_ERROR" ]; then
                err "GitHub API: ${GITHUB_ERROR}"
            fi
            err "Check that GITHUB_TOKEN in $DEPLOY_CONFIG is valid and has repository access"
            exit 1
            ;;
    esac

    PAGE_COUNT=$(echo "$REPOS_PAGE_JSON" | jq 'length')
    REPOS_JSON=$(jq -s 'add' <(echo "$REPOS_JSON") <(echo "$REPOS_PAGE_JSON"))

    if [ "$PAGE_COUNT" -lt 100 ]; then
        break
    fi
    REPOS_PAGE=$((REPOS_PAGE + 1))
done

mapfile -t REPO_NAMES < <(echo "$REPOS_JSON" | jq -r '.[].full_name')

if [ ${#REPO_NAMES[@]} -eq 0 ]; then
    err "No repositories found for this token"
    err "The token must be able to list owner, collaborator, or organization-member repositories"
    exit 1
fi

ok "Found ${#REPO_NAMES[@]} GitHub repositories"

# Infisical-Token holen
log "Authenticating with Infisical..."
INFISICAL_TOKEN=$(infisical login \
    --method=universal-auth \
    --client-id="${INFISICAL_CLIENT_ID}" \
    --client-secret="${INFISICAL_CLIENT_SECRET}" \
    --domain="${INFISICAL_URL}" \
    --plain 2>/dev/null)

if [ -z "$INFISICAL_TOKEN" ]; then
    err "Infisical authentication failed — check Client ID/Secret and URL"
    exit 1
fi
ok "Infisical authenticated"

# Alle Infisical-Projekte laden, auf die die Machine Identity Zugriff hat.
echo ""
log "Fetching Infisical projects available to the Machine Identity..."

INFISICAL_API_BASE="${INFISICAL_URL%/}"

fetch_infisical_api() {
    local url="$1"
    local response_file
    local http_code

    response_file=$(mktemp)
    http_code=$(curl -sS \
        -o "$response_file" \
        -w "%{http_code}" \
        -H "Authorization: Bearer ${INFISICAL_TOKEN}" \
        "$url" 2>/dev/null || true)
    http_code="${http_code:-000}"

    printf '%s\n' "$http_code"
    cat "$response_file"
    rm -f "$response_file"
}

PROJECTS_RESPONSE=$(fetch_infisical_api "${INFISICAL_API_BASE}/api/v1/projects")
PROJECTS_HTTP=$(printf '%s\n' "$PROJECTS_RESPONSE" | sed -n '1p')
PROJECTS_JSON=$(printf '%s\n' "$PROJECTS_RESPONSE" | sed '1d')

if [ "$PROJECTS_HTTP" != "200" ] || ! echo "$PROJECTS_JSON" | jq -e '.projects | type == "array"' >/dev/null 2>&1; then
    err "Could not fetch Infisical projects from ${INFISICAL_API_BASE}/api/v1/projects"
    err "This endpoint must return the Machine Identity's authorized projects as a JSON projects array."
    err "HTTP ${PROJECTS_HTTP}: $(echo "$PROJECTS_JSON" | head -c 300)"
    exit 1
fi

mapfile -t PROJECT_ROWS < <(echo "$PROJECTS_JSON" | jq -r '.projects[] | [.name, .id] | @tsv')

if [ ${#PROJECT_ROWS[@]} -eq 0 ]; then
    err "No Infisical projects visible to this Machine Identity"
    err "Add the Machine Identity to each project that should be deployed"
    exit 1
fi

ok "Found ${#PROJECT_ROWS[@]} Infisical projects"

declare -A REPOS_BY_STACK_NAME=()
for REPO in "${REPO_NAMES[@]}"; do
    STACK_NAME="${REPO##*/}"
    STACK_KEY="${STACK_NAME,,}"
    if [ -n "${REPOS_BY_STACK_NAME[$STACK_KEY]:-}" ]; then
        warn "Multiple GitHub repositories named '$STACK_NAME' found — using ${REPOS_BY_STACK_NAME[$STACK_KEY]}"
        continue
    fi
    REPOS_BY_STACK_NAME[$STACK_KEY]="$REPO"
done

DEPLOY_REPOS=()
DEPLOY_PROJECT_IDS=()
DEPLOY_STACK_NAMES=()
DEPLOY_PROJECT_NAMES=()

for ROW in "${PROJECT_ROWS[@]}"; do
    IFS=$'\t' read -r PROJECT_NAME PROJECT_ID <<< "$ROW"
    STACK_KEY="${PROJECT_NAME,,}"
    if [ -n "${REPOS_BY_STACK_NAME[$STACK_KEY]:-}" ]; then
        REPO="${REPOS_BY_STACK_NAME[$STACK_KEY]}"
        DEPLOY_REPOS+=("$REPO")
        DEPLOY_PROJECT_IDS+=("$PROJECT_ID")
        DEPLOY_STACK_NAMES+=("${REPO##*/}")
        DEPLOY_PROJECT_NAMES+=("$PROJECT_NAME")
    else
        warn "No GitHub repository found for Infisical project '$PROJECT_NAME' — skipping"
    fi
done

if [ ${#DEPLOY_REPOS[@]} -eq 0 ]; then
    err "No deployable stacks found"
    err "GitHub repository names must match Infisical project names"
    exit 1
fi

echo ""
log "Deploying ${#DEPLOY_REPOS[@]} stack(s) authorized by the Infisical Machine Identity"

# Repos deployen, für die ein gleichnamiges Infisical-Projekt sichtbar ist.
for i in "${!DEPLOY_REPOS[@]}"; do
    REPO="${DEPLOY_REPOS[$i]}"
    STACK_PROJECT_ID="${DEPLOY_PROJECT_IDS[$i]}"
    STACK_NAME="${DEPLOY_STACK_NAMES[$i]}"
    STACK_PROJECT_NAME="${DEPLOY_PROJECT_NAMES[$i]}"

    log "Deploying stack '$STACK_NAME' from github.com/$REPO ..."
    log "  Using matched Infisical project '$STACK_PROJECT_NAME' (${STACK_PROJECT_ID})"

    # Secrets für diesen Stack holen
    log "  Fetching Infisical secrets for env '${INFISICAL_ENV}' path '${INFISICAL_PATH}'"
    PROJECT_ID_QUERY=$(jq -nr --arg value "$STACK_PROJECT_ID" '$value | @uri')
    ENV_QUERY=$(jq -nr --arg value "$INFISICAL_ENV" '$value | @uri')
    PATH_QUERY=$(jq -nr --arg value "$INFISICAL_PATH" '$value | @uri')
    SECRETS_RESPONSE=$(fetch_infisical_api "${INFISICAL_API_BASE}/api/v4/secrets?projectId=${PROJECT_ID_QUERY}&environment=${ENV_QUERY}&secretPath=${PATH_QUERY}&viewSecretValue=true&includeImports=true")
    SECRETS_HTTP=$(printf '%s\n' "$SECRETS_RESPONSE" | sed -n '1p')
    SECRETS_JSON=$(printf '%s\n' "$SECRETS_RESPONSE" | sed '1d')

    if [ "$SECRETS_HTTP" != "200" ] || ! echo "$SECRETS_JSON" | jq -e '.secrets | type == "array"' >/dev/null 2>&1; then
        err "Failed to fetch Infisical secrets for stack '$STACK_NAME' (HTTP ${SECRETS_HTTP})"
        err "Project: ${STACK_PROJECT_NAME} (${STACK_PROJECT_ID}), env: ${INFISICAL_ENV}, path: ${INFISICAL_PATH}"
        err "$(echo "$SECRETS_JSON" | head -c 500)"
        exit 1
    fi

    ENV_JSON=$(echo "$SECRETS_JSON" \
        | jq '
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
        ] | reduce .[] as $secret ({};
            .[$secret.secretKey] = ($secret.secretValue | env_secret_value($secret.secretKey))
        ) | to_entries | map({name: .key, value: .value})')

    if [ "$STACK_NAME" = "github-runner" ]; then
        require_value "${APP_PRIVATE_KEY:-}" "APP_PRIVATE_KEY"
        APP_PRIVATE_KEY_B64="$(printf '%s' "$APP_PRIVATE_KEY" | base64 | tr -d '\n')"
        ENV_JSON=$(echo "$ENV_JSON" | jq \
            --arg value "$APP_PRIVATE_KEY_B64" \
            'map(select(.name != "APP_PRIVATE_KEY" and .name != "APP_PRIVATE_KEY_B64")) + [{name: "APP_PRIVATE_KEY_B64", value: $value}]')
    fi
    ok "  Loaded $(echo "$ENV_JSON" | jq 'length') secret(s)"

    # Prüfen ob Stack schon existiert → update vs. create
    EXISTING_ID=$(curl -sfk \
        -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
        "${PORTAINER_URL}/api/stacks" \
        | jq --arg name "$STACK_NAME" '.[] | select(.Name == $name) | .Id' 2>/dev/null || true)

    if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
        STACK_FILE=$(curl -sfk \
            -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
            "${PORTAINER_URL}/api/stacks/${EXISTING_ID}/file" \
            | jq -r '.StackFileContent')

        PORTAINER_RESPONSE_FILE=$(mktemp)
        PORTAINER_HTTP=$(curl -sSk -X PUT \
            -o "$PORTAINER_RESPONSE_FILE" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
            -H "Content-Type: application/json" \
            "${PORTAINER_URL}/api/stacks/${EXISTING_ID}?endpointId=${ENDPOINT_ID}" \
            -d "$(jq -n \
                --arg content "$STACK_FILE" \
                --argjson env "$ENV_JSON" \
                '{stackFileContent: $content, env: $env, pullImage: true}')" 2>/dev/null || true)
        PORTAINER_HTTP="${PORTAINER_HTTP:-000}"
        if [ "$PORTAINER_HTTP" -lt 200 ] || [ "$PORTAINER_HTTP" -ge 300 ]; then
            err "Failed to update Portainer stack '$STACK_NAME' (HTTP ${PORTAINER_HTTP})"
            err "$(head -c 500 "$PORTAINER_RESPONSE_FILE")"
            rm -f "$PORTAINER_RESPONSE_FILE"
            exit 1
        fi
        rm -f "$PORTAINER_RESPONSE_FILE"
        ok "Stack '$STACK_NAME' updated"
    else
        PORTAINER_RESPONSE_FILE=$(mktemp)
        PORTAINER_HTTP=$(curl -sSk -X POST \
            -o "$PORTAINER_RESPONSE_FILE" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
            -H "Content-Type: application/json" \
            "${PORTAINER_URL}/api/stacks/create/standalone/repository?endpointId=${ENDPOINT_ID}" \
            -d "$(jq -n \
                --arg name "$STACK_NAME" \
                --arg repo "https://github.com/${REPO}" \
                --arg token "$GITHUB_TOKEN" \
                --argjson env "$ENV_JSON" \
                '{
                    name: $name,
                    repositoryURL: $repo,
                    repositoryReferenceName: "refs/heads/main",
                    filePathInRepository: "docker-compose.yml",
                    repositoryAuthentication: true,
                    repositoryUsername: "token",
                    repositoryPassword: $token,
                    env: $env
                }')" 2>/dev/null || true)
        PORTAINER_HTTP="${PORTAINER_HTTP:-000}"
        if [ "$PORTAINER_HTTP" -lt 200 ] || [ "$PORTAINER_HTTP" -ge 300 ]; then
            err "Failed to create Portainer stack '$STACK_NAME' (HTTP ${PORTAINER_HTTP})"
            err "$(head -c 500 "$PORTAINER_RESPONSE_FILE")"
            rm -f "$PORTAINER_RESPONSE_FILE"
            exit 1
        fi
        rm -f "$PORTAINER_RESPONSE_FILE"
        ok "Stack '$STACK_NAME' created and deployed"
    fi
done

# ── 7. Redeploy script ────────────────────────────────────────────────────────
log "Step 7/7 — Installing redeploy-stacks.sh"

sudo mkdir -p /opt/deploy
curl -fsSL \
    "https://raw.githubusercontent.com/Holtkamp-Consulting/server-bootstrap/main/redeploy-stacks.sh" \
    | sudo tee /opt/deploy/redeploy-stacks.sh > /dev/null
sudo chmod +x /opt/deploy/redeploy-stacks.sh
ok "Installed /opt/deploy/redeploy-stacks.sh"

# ── Summary ────────────────────────────────────────────────────────────────────
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
LOCAL_IP="${LOCAL_IP:-localhost}"

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║              Installation Complete!                  ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Portainer:${NC}"
echo -e "    HTTP  → ${BLUE}http://${LOCAL_IP}:${PORTAINER_PORT_HTTP}${NC}"
echo -e "    HTTPS → ${BLUE}https://${LOCAL_IP}:${PORTAINER_PORT_HTTPS}${NC}"
echo ""
echo -e "  ${BOLD}Credentials:${NC}"
echo -e "    Username : ${GREEN}${PORTAINER_ADMIN}${NC}"
echo -e "    Password : ${GREEN}${PORTAINER_PASSWORD}${NC}"
echo ""
echo -e "  ${YELLOW}⚠  Save these credentials — they won't be shown again.${NC}"
echo ""
