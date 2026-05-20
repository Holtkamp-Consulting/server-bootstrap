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

PORTAINER_ADMIN="admin"
PORTAINER_PASSWORD=$(openssl rand -hex 10)
PORTAINER_PORT_HTTP="${PORTAINER_PORT_HTTP:-9000}"
PORTAINER_PORT_HTTPS="${PORTAINER_PORT_HTTPS:-9443}"

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║        Server Bootstrap Installer        ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Sudo precheck ──────────────────────────────────────────────────────────────
# Prime sudo credentials early, before any installation steps
log "Checking sudo access..."
sudo -v || { err "sudo privileges required to run this script."; exit 1; }
ok "sudo OK"

# ── 1. Docker ─────────────────────────────────────────────────────────────────
log "Step 1/6 — Docker"

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
log "Step 2/6 — Portainer CE"

# Use sudo only if the current user can't write to the socket directly
if [ -w /var/run/docker.sock ]; then
    DOCKER="docker"
else
    DOCKER="sudo docker"
fi

${DOCKER} volume create portainer_data >/dev/null || true

if ${DOCKER} ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^portainer$'; then
    warn "Removing existing Portainer container..."
    ${DOCKER} rm -f portainer >/dev/null
fi

${DOCKER} run -d \
    --name portainer \
    --restart=always \
    -p "${PORTAINER_PORT_HTTP}:9000" \
    -p "${PORTAINER_PORT_HTTPS}:9443" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest >/dev/null

ok "Portainer container started"

# ── 3. Credentials ─────────────────────────────────────────────────────────────
log "Step 3/6 — Configuring admin credentials"

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

RESPONSE=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -d "{\"Username\":\"${PORTAINER_ADMIN}\",\"Password\":\"${PORTAINER_PASSWORD}\"}" \
    "${PORTAINER_API}/api/users/admin/init" 2>&1)

if echo "$RESPONSE" | grep -q '"Id"'; then
    ok "Admin user configured"
else
    err "Failed to initialise admin user"
    err "API response: ${RESPONSE}"
    exit 1
fi

# ── 4. Infisical CLI ───────────────────────────────────────────────────────────
log "Step 4/6 — Infisical CLI"

if command -v infisical &>/dev/null; then
    ok "Infisical CLI already installed ($(infisical --version 2>&1 | head -1))"
else
    curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' | sudo -E bash
    sudo apt-get install -y infisical
    ok "Infisical CLI installed"
fi

# ── 5. Credentials ────────────────────────────────────────────────────────────
log "Step 5/6 — Infisical + GitHub credentials"

DEPLOY_CONFIG="/etc/infisical-deploy.env"

if [ -f "$DEPLOY_CONFIG" ]; then
    warn "Deploy config already exists at $DEPLOY_CONFIG — skipping credential setup"
    source "$DEPLOY_CONFIG"
else
    log "Infisical Machine Identity: Infisical UI → Project → Access Control → Machine Identities → Create"
    echo ""
    read -rp "  Infisical URL (e.g. http://mac-studio:80): " INF_URL
    read -rp "  Client ID:                                  " INF_CLIENT_ID
    read -rsp "  Client Secret:                              " INF_CLIENT_SECRET
    echo ""
    read -rp "  Project ID:                                 " INF_PROJECT_ID
    read -rp "  Environment (prod/staging/dev):             " INF_ENV
    echo ""
    log "GitHub Personal Access Token (needs repo scope):"
    read -rsp "  GitHub Token: " GITHUB_TOKEN
    echo ""

    log "Fetching Portainer API token..."
    PORTAINER_JWT=$(curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${PORTAINER_ADMIN}\",\"password\":\"${PORTAINER_PASSWORD}\"}" \
        "${PORTAINER_API}/api/auth" | grep -o '"jwt":"[^"]*"' | cut -d'"' -f4)

    sudo tee "$DEPLOY_CONFIG" > /dev/null <<EOF
INFISICAL_URL=${INF_URL}
INFISICAL_CLIENT_ID=${INF_CLIENT_ID}
INFISICAL_CLIENT_SECRET=${INF_CLIENT_SECRET}
INFISICAL_PROJECT_ID=${INF_PROJECT_ID}
INFISICAL_ENV=${INF_ENV}
INFISICAL_PATH=/
PORTAINER_URL=http://localhost:${PORTAINER_PORT_HTTP}
PORTAINER_TOKEN=${PORTAINER_JWT}
GITHUB_TOKEN=${GITHUB_TOKEN}
EOF
    sudo chmod 600 "$DEPLOY_CONFIG"
    source "$DEPLOY_CONFIG"
    ok "Credentials saved to $DEPLOY_CONFIG"
fi

# ── 6. Stacks deployen ─────────────────────────────────────────────────────────
log "Step 6/6 — Stack deployment from GitHub"

# Portainer local endpoint ID
ENDPOINT_ID=$(curl -sf \
    -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
    "${PORTAINER_URL}/api/endpoints" | jq '.[0].Id')

if [ -z "$ENDPOINT_ID" ] || [ "$ENDPOINT_ID" = "null" ]; then
    err "Could not determine Portainer endpoint ID"
    exit 1
fi

# GitHub repos auflisten
log "Fetching GitHub repositories..."
REPOS_JSON=$(curl -sf \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user/repos?per_page=100&sort=updated&affiliation=owner")

mapfile -t REPO_NAMES < <(echo "$REPOS_JSON" | jq -r '.[].full_name')

if [ ${#REPO_NAMES[@]} -eq 0 ]; then
    err "No repositories found for this token"
    exit 1
fi

echo ""
log "Available repositories:"
for i in "${!REPO_NAMES[@]}"; do
    printf "  [%2d] %s\n" "$((i+1))" "${REPO_NAMES[$i]}"
done
echo ""
read -rp "  Select repos to deploy (space-separated numbers, e.g. 1 3): " SELECTION

# Infisical-Token holen
log "Authenticating with Infisical..."
INFISICAL_TOKEN=$(infisical login \
    --method=universal-auth \
    --client-id="${INFISICAL_CLIENT_ID}" \
    --client-secret="${INFISICAL_CLIENT_SECRET}" \
    --domain="${INFISICAL_URL}" \
    --plain --silent 2>/dev/null)

# Secrets als Portainer-Env-Array holen
ENV_JSON=$(infisical secrets \
    --token="${INFISICAL_TOKEN}" \
    --projectId="${INFISICAL_PROJECT_ID}" \
    --env="${INFISICAL_ENV}" \
    --path="${INFISICAL_PATH}" \
    --domain="${INFISICAL_URL}" \
    --format=json --silent 2>/dev/null \
    | jq '[.[] | {name: .secretKey, value: .secretValue}]')

# Ausgewählte Repos deployen
for NUM in $SELECTION; do
    IDX=$((NUM - 1))
    REPO="${REPO_NAMES[$IDX]}"
    STACK_NAME="${REPO##*/}"  # nur Repo-Name ohne Owner

    log "Deploying stack '$STACK_NAME' from github.com/$REPO ..."

    # Prüfen ob Stack schon existiert → update vs. create
    EXISTING_ID=$(curl -sf \
        -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
        "${PORTAINER_URL}/api/stacks" \
        | jq --arg name "$STACK_NAME" '.[] | select(.Name == $name) | .Id' 2>/dev/null || true)

    if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
        STACK_FILE=$(curl -sf \
            -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
            "${PORTAINER_URL}/api/stacks/${EXISTING_ID}/file" \
            | jq -r '.StackFileContent')

        curl -sf -X PUT \
            -H "Authorization: Bearer ${PORTAINER_TOKEN}" \
            -H "Content-Type: application/json" \
            "${PORTAINER_URL}/api/stacks/${EXISTING_ID}?endpointId=${ENDPOINT_ID}" \
            -d "$(jq -n \
                --arg content "$STACK_FILE" \
                --argjson env "$ENV_JSON" \
                '{stackFileContent: $content, env: $env, pullImage: true}')" > /dev/null
        ok "Stack '$STACK_NAME' updated"
    else
        curl -sf -X POST \
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
                    filePathInRepository: "docker-compose.yaml",
                    repositoryAuthentication: true,
                    repositoryUsername: "token",
                    repositoryPassword: $token,
                    env: $env
                }')" > /dev/null
        ok "Stack '$STACK_NAME' created and deployed"
    fi
done

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
