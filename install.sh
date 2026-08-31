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

extract_portainer_endpoint_id() {
    jq -r '
        def endpoint_list:
            if type == "array" then .
            elif type == "object" and (.Id != null) then [.]
            elif type == "object" and (.value | type == "array") then .value
            elif type == "object" and (.items | type == "array") then .items
            elif type == "object" and (.Items | type == "array") then .Items
            else []
            end;

        endpoint_list
        | map(select(.Id != null))
        | (
            map(select(((.Type // "") | tostring) == "1" and (.URL // "") == "unix:///var/run/docker.sock"))
            + map(select(((.Name // "") | ascii_downcase) == "local"))
            + .
        )
        | .[0].Id // empty
    ' 2>/dev/null
}

create_local_portainer_endpoint() {
    local response_file http endpoint_id

    response_file=$(mktemp)
    http=$(curl -sk -o "$response_file" -w "%{http_code}" -X POST \
        -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
        -F "Name=local" \
        -F "EndpointCreationType=1" \
        "${PORTAINER_URL}/api/endpoints" 2>/dev/null || echo "000")

    endpoint_id=$(extract_portainer_endpoint_id < "$response_file" || true)
    rm -f "$response_file"

    if [[ "$http" =~ ^20[01]$ ]] && [ -n "$endpoint_id" ]; then
        printf '%s' "$endpoint_id"
        return 0
    fi

    return 1
}

extract_portainer_registry_id() {
    jq -r '
        def registry_list:
            if type == "array" then .
            elif type == "object" and (.Id != null) then [.]
            elif type == "object" and (.value | type == "array") then .value
            elif type == "object" and (.items | type == "array") then .items
            elif type == "object" and (.Items | type == "array") then .Items
            else []
            end;

        registry_list
        | map(select(.Id != null))
        | map(select((.URL // "") == "ghcr.io"))
        | .[0].Id // empty
    ' 2>/dev/null
}

ensure_ghcr_registry() {
    local response_file http registry_id payload

    registry_id=$(curl -sfk \
        -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
        "${PORTAINER_URL}/api/registries" 2>/dev/null \
        | extract_portainer_registry_id || true)

    # Reuse the GitHub token collected during install as the ghcr.io credential.
    # Portainer requires a non-empty username; fall back to the literal "token"
    # (a valid GHCR username when authenticating with a PAT) if none was derived.
    payload=$(jq -n \
        --arg url "ghcr.io" \
        --arg user "${GHCR_USERNAME:-token}" \
        --arg pass "$GITHUB_TOKEN" \
        '{Name: "ghcr.io", Type: 3, URL: $url, Authentication: true, Username: $user, Password: $pass}')

    response_file=$(mktemp)
    if [ -n "$registry_id" ]; then
        http=$(curl -sSk -X PUT \
            -o "$response_file" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
            -H "Content-Type: application/json" \
            "${PORTAINER_URL}/api/registries/${registry_id}" \
            -d "$payload" 2>/dev/null || true)
    else
        http=$(curl -sSk -X POST \
            -o "$response_file" \
            -w "%{http_code}" \
            -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
            -H "Content-Type: application/json" \
            "${PORTAINER_URL}/api/registries" \
            -d "$payload" 2>/dev/null || true)
    fi
    http="${http:-000}"

    if [[ "$http" =~ ^20[01]$ ]]; then
        rm -f "$response_file"
        ok "GHCR registry ensured in Portainer"
        return 0
    fi
    if [ "$http" = "409" ]; then
        rm -f "$response_file"
        ok "GHCR registry already present in Portainer"
        return 0
    fi

    warn "Could not ensure GHCR registry (HTTP ${http}); private ghcr.io pulls may fail"
    warn "$(head -c 500 "$response_file")"
    rm -f "$response_file"
    return 1
}

# Print the ID of the user the given JWT authenticates as. The token-creation
# endpoint is self-service only (Portainer returns 403 if the {id} in the URL is
# not the calling user), so the ID must be resolved rather than hardcoded to 1.
resolve_portainer_admin_id() {
    local jwt="$1"
    local response_file http id

    response_file=$(mktemp)
    http=$(curl -sSk \
        -o "$response_file" \
        -w "%{http_code}" \
        -H "Authorization: Bearer ${jwt}" \
        "${PORTAINER_URL}/api/users/me" 2>/dev/null || true)
    http="${http:-000}"

    if [ "$http" != "200" ]; then
        # This function's stdout is the ID, so diagnostics must go to stderr
        # or they are swallowed by the caller's command substitution.
        warn "Could not resolve Portainer admin user ID (HTTP ${http})" >&2
        warn "$(head -c 500 "$response_file")" >&2
        rm -f "$response_file"
        return 1
    fi

    id=$(jq -r '.Id // empty' < "$response_file" 2>/dev/null || true)
    rm -f "$response_file"
    printf '%s' "$id"
}

# Mint a non-expiring Portainer Access Token (used via the X-API-Key header) and
# print its raw value. Portainer returns the raw key exactly once, at creation,
# so the caller must persist it immediately. Requires JWT (not X-API-Key) auth:
# Portainer explicitly rejects API-key auth on this endpoint.
mint_portainer_access_token() {
    local jwt="$1" admin_id="$2" description="$3"
    local payload response_file http token

    payload=$(jq -n \
        --arg description "$description" \
        --arg password "$PORTAINER_PASSWORD" \
        '{description: $description, password: $password}')

    response_file=$(mktemp)
    http=$(curl -sSk -X POST \
        -o "$response_file" \
        -w "%{http_code}" \
        -H "Authorization: Bearer ${jwt}" \
        -H "Content-Type: application/json" \
        "${PORTAINER_URL}/api/users/${admin_id}/tokens" \
        -d "$payload" 2>/dev/null || true)
    http="${http:-000}"

    if [ "$http" != "200" ]; then
        # This function's stdout is the token, so diagnostics must go to stderr
        # or they are swallowed by the caller's command substitution.
        warn "Could not create Portainer access token (HTTP ${http})" >&2
        warn "$(head -c 500 "$response_file")" >&2
        rm -f "$response_file"
        return 1
    fi

    token=$(jq -r '.rawAPIKey // empty' < "$response_file" 2>/dev/null || true)
    rm -f "$response_file"

    if [ -z "$token" ]; then
        warn "Portainer access token response contained no rawAPIKey" >&2
        return 1
    fi

    printf '%s' "$token"
}

PORTAINER_ADMIN="admin"
PORTAINER_PORT_HTTP="${PORTAINER_PORT_HTTP:-9000}"
PORTAINER_PORT_HTTPS="${PORTAINER_PORT_HTTPS:-9443}"
PORTAINER_PROXY_PORT="${PORTAINER_PROXY_PORT:-9444}"
MAINTENANCE_SCHEDULE="${MAINTENANCE_SCHEDULE:-Sat *-*-* 00:00:00}"
RAW_BASE="https://raw.githubusercontent.com/Holtkamp-Consulting/server-bootstrap/main"
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
log "Step 1/9 — Docker"

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
log "Step 2/9 — Portainer CE"

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
log "Step 3/9 — Configuring admin credentials"

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
log "Step 4/9 — Infisical CLI"

if command -v infisical &>/dev/null; then
    ok "Infisical CLI already installed ($(infisical --version 2>&1 | head -1))"
else
    curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' | sudo -E bash
    sudo apt-get install -y infisical
    ok "Infisical CLI installed"
fi

# ── 5. Credentials ────────────────────────────────────────────────────────────
log "Step 5/9 — Infisical + GitHub credentials"

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
    log "GitHub Personal Access Token (needs 'repo' and 'read:packages' scopes):"
    log "  read:packages lets Portainer pull private ghcr.io/holtkamp-consulting/* images."
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

# ── Image tag resolution ──────────────────────────────────────────────────────
# Map the Infisical environment to the git branch whose images this host runs:
# a dev host runs the repo's `dev` branch, prod/staging run `main`. Mirrors the
# branch→environment routing in templates/stack-deploy.yml (main→prod, dev→dev).
deploy_branch_for_env() {
    case "$1" in
        dev) printf 'dev' ;;
        *)   printf 'main' ;;
    esac
}

# Print the HEAD commit SHA of branch $2 in repo $1 via the GitHub API, or
# nothing if the branch does not exist or the call fails.
github_branch_head_sha() {
    local repo="$1" branch="$2"
    curl -sf \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}/commits/${branch}" 2>/dev/null \
        | jq -r '.sha // empty' 2>/dev/null || true
}

# ── 6. Stacks deployen ─────────────────────────────────────────────────────────
log "Step 6/9 — Stack deployment from GitHub"

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
ENDPOINT_ID=$(printf '%s' "$ENDPOINT_RESPONSE" | extract_portainer_endpoint_id || true)

if [ -z "$ENDPOINT_ID" ]; then
    log "No Portainer endpoint found — creating local Docker endpoint..."
    ENDPOINT_ID=$(create_local_portainer_endpoint || true)
fi

if [ -z "$ENDPOINT_ID" ]; then
    err "Could not determine or create Portainer endpoint ID"
    exit 1
fi
ok "Using Portainer endpoint ID ${ENDPOINT_ID}"

# Ensure a Portainer registry credential exists for ghcr.io so private
# ghcr.io/holtkamp-consulting/* images can be pulled during stack deploys.
# The GitHub token is always present, so this runs unconditionally. Derive the
# GitHub login for the registry username via /user; fall back to "token" (a
# valid GHCR username for PAT auth) if the lookup fails or returns nothing.
GHCR_USERNAME=$(curl -sf \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user" 2>/dev/null | jq -r '.login // empty' || true)
GHCR_USERNAME="${GHCR_USERNAME:-token}"
log "Ensuring GHCR registry credential in Portainer..."
ensure_ghcr_registry || true

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

# ── Host pre-pull ─────────────────────────────────────────────────────────────
# Portainer's own image pull has repeatedly resolved a stale/wrong image for our
# per-commit sha tags — it recreated the container on an old cached image while a
# plain `docker pull` of the SAME tag fetched the correct one. So pull the images
# ourselves with the reliable docker client (the host has the docker socket),
# then tell Portainer NOT to pull (pullImage:false); it just recreates onto the
# freshly-pulled local image. Best-effort: on any failure PULL_IMAGE_FLAG stays
# true and Portainer pulls as before. Only the stack-update Portainer request
# accepts a pullImage flag — the stack-create-from-repository endpoint has no
# such field — but Compose's default pull_policy:missing still benefits from the
# image already being present locally when Portainer creates a new stack.
prepull_stack_images() {
    command -v docker >/dev/null 2>&1 || { warn "  [$STACK_NAME] docker CLI unavailable; leaving image pull to Portainer"; return 1; }

    local ref_q
    ref_q=$(jq -nr --arg v "$DEPLOY_BRANCH" '$v | @uri')

    local compose
    compose=$(curl -sSfL \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.raw" \
        "https://api.github.com/repos/${REPO}/contents/docker-compose.yml?ref=${ref_q}") \
        || { warn "  [$STACK_NAME] Could not fetch docker-compose.yml for pre-pull; leaving pull to Portainer"; return 1; }

    # Every ghcr.io image reference (registry/owner/name, sans tag). Only these
    # are ours to pull with GITHUB_TOKEN; other images (e.g. grafana) are left for
    # compose to pull on demand.
    local images
    images=$(printf '%s\n' "$compose" | grep -oE 'ghcr\.io/[a-z0-9._/-]+' | sort -u)
    [[ -z "$images" ]] && { warn "  [$STACK_NAME] No ghcr.io images in compose; leaving pull to Portainer"; return 1; }

    local tag
    tag=$(printf '%s' "$ENV_JSON" | jq -r 'map(select(.name == "IMAGE_TAG")) | .[0].value // "latest"')

    printf '%s' "$GITHUB_TOKEN" | ${DOCKER} login ghcr.io -u token --password-stdin >/dev/null 2>&1 \
        || { warn "  [$STACK_NAME] docker login ghcr.io failed; leaving pull to Portainer"; return 1; }

    local img ok=1
    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        log "  Pre-pulling ${img}:${tag}"
        ${DOCKER} pull "${img}:${tag}" >/dev/null 2>&1 || { warn "    [$STACK_NAME] pull failed: ${img}:${tag}"; ok=0; }
    done <<< "$images"

    ${DOCKER} logout ghcr.io >/dev/null 2>&1 || true
    [[ "$ok" == "1" ]]
}

# Repos deployen, für die ein gleichnamiges Infisical-Projekt sichtbar ist.
SKIPPED_STACKS=()
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
        # Auth-Fehler sind global (falsche Machine Identity) → hart abbrechen.
        if [ "$SECRETS_HTTP" = "401" ] || [ "$SECRETS_HTTP" = "403" ]; then
            err "Infisical authentication/authorization failed for stack '$STACK_NAME' (HTTP ${SECRETS_HTTP})"
            err "Project: ${STACK_PROJECT_NAME} (${STACK_PROJECT_ID}), env: ${INFISICAL_ENV}, path: ${INFISICAL_PATH}"
            err "$(echo "$SECRETS_JSON" | head -c 500)"
            exit 1
        fi
        # Fehlende Umgebung/Pfad (404/400/…) betrifft nur diesen Stack → überspringen, Loop läuft weiter.
        warn "No Infisical secrets for stack '$STACK_NAME' (HTTP ${SECRETS_HTTP}) — skipping"
        warn "Project: ${STACK_PROJECT_NAME} (${STACK_PROJECT_ID}), env: ${INFISICAL_ENV}, path: ${INFISICAL_PATH}"
        warn "$(echo "$SECRETS_JSON" | head -c 500)"
        SKIPPED_STACKS+=("$STACK_NAME")
        continue
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

    # Pin IMAGE_TAG to the deploy branch's immutable per-commit tag (sha-<sha>,
    # published by app CI via docker/metadata-action type=sha) so Portainer's
    # pullImage:true always fetches a fresh image instead of reusing a cached
    # moving-tag digest — the same fix redeploy-stacks.sh applies for CI-driven
    # redeploys. Without this, compose's ${IMAGE_TAG:-latest} resolved to :latest
    # (only published on main), so a dev host silently deployed main images.
    # An explicit IMAGE_TAG from Infisical still wins.
    DEPLOY_BRANCH="$(deploy_branch_for_env "${INFISICAL_ENV:-}")"
    DEPLOY_SHA="$(github_branch_head_sha "$REPO" "$DEPLOY_BRANCH")"
    if [ -z "$DEPLOY_SHA" ] && [ "$DEPLOY_BRANCH" != "main" ]; then
        warn "  Repo '$REPO' has no '$DEPLOY_BRANCH' branch — falling back to 'main'"
        DEPLOY_BRANCH="main"
        DEPLOY_SHA="$(github_branch_head_sha "$REPO" "$DEPLOY_BRANCH")"
    fi
    if echo "$ENV_JSON" | jq -e 'any(.[]; .name == "IMAGE_TAG")' >/dev/null; then
        log "  IMAGE_TAG pinned by Infisical — leaving as-is"
    elif [ -n "$DEPLOY_SHA" ]; then
        ENV_JSON=$(echo "$ENV_JSON" | jq --arg tag "sha-${DEPLOY_SHA}" \
            '. + [{name: "IMAGE_TAG", value: $tag}]')
        log "  Pinning IMAGE_TAG=sha-${DEPLOY_SHA} (branch '$DEPLOY_BRANCH')"
    else
        warn "  Could not resolve a HEAD sha for '$REPO' — falling back to compose \${IMAGE_TAG:-latest}"
    fi

    # The github-runner stack can't pre-pull the image running this very script
    # (it doesn't exist yet on first install anyway), so leave it to Portainer.
    PULL_IMAGE_FLAG=true
    if [ "$STACK_NAME" != "github-runner" ] && prepull_stack_images; then
        PULL_IMAGE_FLAG=false
        ok "  Images pre-pulled on host"
    fi

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
                --argjson pull "$PULL_IMAGE_FLAG" \
                '{stackFileContent: $content, env: $env, pullImage: $pull}')" 2>/dev/null || true)
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
                --arg ref "refs/heads/${DEPLOY_BRANCH}" \
                '{
                    name: $name,
                    repositoryURL: $repo,
                    repositoryReferenceName: $ref,
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

if [ "${#SKIPPED_STACKS[@]}" -gt 0 ]; then
    warn "Skipped ${#SKIPPED_STACKS[@]} stack(s) without Infisical secrets: ${SKIPPED_STACKS[*]}"
fi

# ── 7. Portainer read-only API proxy ──────────────────────────────────────────
# Deliberately its own top-level step, not nested in Step 2: a run against an
# already-bootstrapped host hits Step 2's "already running — skipping" branch,
# and the proxy must still be added retroactively there.
#
# Extracted into a function (rather than left as inline Step 7 body) so its
# three branches — idempotency skip, stale-token reuse, fresh mint — can be
# unit-tested with stubbed docker/curl/sudo, per tests/install_portainer_proxy_step_test.sh.
deploy_portainer_proxy() {
    local jwt="$1"

    if ${DOCKER} ps --format '{{.Names}}' 2>/dev/null | grep -q '^portainer-proxy$'; then
        ok "Portainer proxy already running — skipping"
        return 0
    fi

    # A token reused from a prior run may have been revoked (e.g. an operator
    # completed only step 1 of the documented manual rotation flow). Validate
    # it with a lightweight authenticated call before wiring it into the
    # container; fall through to minting a fresh one on failure.
    if [ -n "${PORTAINER_ACCESS_TOKEN:-}" ] \
        && ! curl -sfk -H "X-Api-Key: ${PORTAINER_ACCESS_TOKEN}" "${PORTAINER_URL}/api/endpoints" &>/dev/null; then
        warn "Existing Portainer access token is no longer valid — minting a new one"
        PORTAINER_ACCESS_TOKEN=""
    fi

    if [ -z "${PORTAINER_ACCESS_TOKEN:-}" ]; then
        log "Creating Portainer access token for the read-only proxy..."
        # mint_portainer_access_token needs JWT (it rejects X-API-Key auth);
        # $jwt is the admin JWT Step 6 just refreshed, still fresh here.
        local PROXY_ADMIN_ID
        PROXY_ADMIN_ID=$(resolve_portainer_admin_id "$jwt")
        if [ -z "$PROXY_ADMIN_ID" ]; then
            err "Could not resolve the Portainer admin user ID"
            exit 1
        fi

        if ! PORTAINER_ACCESS_TOKEN=$(mint_portainer_access_token "$jwt" "$PROXY_ADMIN_ID" "server-topologie-proxy"); then
            err "Failed to create Portainer access token"
            exit 1
        fi

        # Portainer returns the raw key only once, so it must be persisted
        # before anything else can fail. Any stale line from a prior mint
        # (e.g. after the reuse-validation fallback above) is dropped first
        # so re-runs don't accumulate duplicate PORTAINER_ACCESS_TOKEN lines.
        if [ -f "$DEPLOY_CONFIG" ]; then
            sudo awk '!/^PORTAINER_ACCESS_TOKEN=/' "$DEPLOY_CONFIG" \
                | sudo tee "${DEPLOY_CONFIG}.tmp" > /dev/null
            sudo mv "${DEPLOY_CONFIG}.tmp" "$DEPLOY_CONFIG"
        fi
        printf 'PORTAINER_ACCESS_TOKEN=%s\n' "$(quote_env_value "$PORTAINER_ACCESS_TOKEN")" \
            | sudo tee -a "$DEPLOY_CONFIG" > /dev/null
        sudo chown root:docker "$DEPLOY_CONFIG"
        sudo chmod 640 "$DEPLOY_CONFIG"
        ok "Portainer access token created and saved to $DEPLOY_CONFIG"
    else
        ok "Reusing existing Portainer access token from $DEPLOY_CONFIG"
    fi

    log "Installing Portainer proxy config..."
    sudo mkdir -p /opt/deploy/portainer-proxy
    curl -fsSL "${RAW_BASE}/caddy/portainer-proxy.Caddyfile" \
        | sed \
            -e "s|__PROXY_PORT__|${PORTAINER_PROXY_PORT}|g" \
            -e "s|__PORTAINER_UPSTREAM__|localhost:${PORTAINER_PORT_HTTP}|g" \
        | sudo tee /opt/deploy/portainer-proxy/Caddyfile > /dev/null

    ${DOCKER} rm -f portainer-proxy >/dev/null 2>&1 || true
    ${DOCKER} run -d \
        --name portainer-proxy \
        --restart=always \
        --network host \
        -e "PORTAINER_ACCESS_TOKEN=${PORTAINER_ACCESS_TOKEN}" \
        -v /opt/deploy/portainer-proxy/Caddyfile:/etc/caddy/Caddyfile:ro \
        caddy:2-alpine >/dev/null

    log "Waiting for the Portainer proxy to become ready..."
    local proxy_max_wait=30 proxy_elapsed=0
    until curl -sf "http://localhost:${PORTAINER_PROXY_PORT}/api/status" &>/dev/null; do
        if [ "$proxy_elapsed" -ge "$proxy_max_wait" ]; then
            err "Portainer proxy did not become ready within ${proxy_max_wait}s"
            err "Check logs: sudo docker logs portainer-proxy"
            exit 1
        fi
        sleep 1
        proxy_elapsed=$((proxy_elapsed + 1))
    done
    ok "Portainer read-only proxy started on port ${PORTAINER_PROXY_PORT}"
}

log "Step 7/9 — Portainer read-only API proxy"
deploy_portainer_proxy "$PORTAINER_TOKEN"

# ── 8. Redeploy script ────────────────────────────────────────────────────────
log "Step 8/9 — Installing redeploy-stacks.sh"

sudo mkdir -p /opt/deploy
curl -fsSL \
    "https://raw.githubusercontent.com/Holtkamp-Consulting/server-bootstrap/main/redeploy-stacks.sh" \
    | sudo tee /opt/deploy/redeploy-stacks.sh > /dev/null
sudo chmod +x /opt/deploy/redeploy-stacks.sh
ok "Installed /opt/deploy/redeploy-stacks.sh"

# ── 9. Scheduled maintenance ──────────────────────────────────────────────────
log "Step 9/9 — Installing scheduled maintenance timer"

sudo mkdir -p /opt/deploy /var/lib/server-bootstrap


for f in maintenance-update.sh maintenance-redeploy.sh; do
    curl -fsSL "${RAW_BASE}/${f}" | sudo tee "/opt/deploy/${f}" > /dev/null
    sudo chmod +x "/opt/deploy/${f}"
done

for f in maintenance-update.service maintenance-redeploy.service; do
    curl -fsSL "${RAW_BASE}/systemd/${f}" | sudo tee "/etc/systemd/system/${f}" > /dev/null
done

curl -fsSL "${RAW_BASE}/systemd/maintenance-update.timer" \
    | sed "s|__MAINTENANCE_SCHEDULE__|${MAINTENANCE_SCHEDULE}|" \
    | sudo tee /etc/systemd/system/maintenance-update.timer > /dev/null

sudo systemctl daemon-reload
sudo systemctl enable --now maintenance-update.timer
sudo systemctl enable maintenance-redeploy.service

ok "Installed and enabled maintenance-update.timer (schedule: ${MAINTENANCE_SCHEDULE})"

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
echo -e "  ${BOLD}Portainer read-only proxy:${NC}"
echo -e "    URL   → ${BLUE}http://${LOCAL_IP}:${PORTAINER_PROXY_PORT}${NC} (GET allowlist, no credential required)"
echo ""
echo -e "  ${BOLD}Credentials:${NC}"
echo -e "    Username : ${GREEN}${PORTAINER_ADMIN}${NC}"
echo -e "    Password : ${GREEN}${PORTAINER_PASSWORD}${NC}"
echo ""
echo -e "  ${BOLD}Maintenance:${NC}"
echo -e "    Schedule → ${BLUE}${MAINTENANCE_SCHEDULE}${NC} (systemctl list-timers maintenance-update.timer)"
echo ""
echo -e "  ${YELLOW}⚠  Save these credentials — they won't be shown again.${NC}"
echo ""
