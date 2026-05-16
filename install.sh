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
PORTAINER_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9@#$%' </dev/urandom | head -c 20)
PORTAINER_PORT_HTTP="${PORTAINER_PORT_HTTP:-9000}"
PORTAINER_PORT_HTTPS="${PORTAINER_PORT_HTTPS:-9443}"

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║        Server Bootstrap Installer        ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── 1. Docker ─────────────────────────────────────────────────────────────────

log "Step 1/3 — Docker"

if command -v docker &>/dev/null; then
    ok "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
else
    log "Downloading and running official Docker install script..."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed"

    if id -nG "$USER" | grep -qw docker; then
        ok "User '$USER' already in docker group"
    else
        sudo usermod -aG docker "$USER" || warn "Could not add $USER to docker group — you may need to run docker with sudo"
    fi
fi

if ! sudo systemctl is-active --quiet docker 2>/dev/null; then
    log "Starting Docker service..."
    sudo systemctl enable --now docker
fi

# ── 2. Portainer ───────────────────────────────────────────────────────────────

log "Step 2/3 — Portainer CE"

docker volume create portainer_data &>/dev/null || true

if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
    warn "Removing existing Portainer container..."
    docker rm -f portainer &>/dev/null
fi

docker run -d \
    --name portainer \
    --restart=always \
    -p "${PORTAINER_PORT_HTTP}:9000" \
    -p "${PORTAINER_PORT_HTTPS}:9443" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest &>/dev/null

ok "Portainer container started"

# ── 3. Credentials ─────────────────────────────────────────────────────────────

log "Step 3/3 — Configuring admin credentials"

PORTAINER_API="http://localhost:${PORTAINER_PORT_HTTP}"
MAX_WAIT=90
elapsed=0

log "Waiting for Portainer API to become ready..."
until curl -sf "${PORTAINER_API}/api/status" &>/dev/null; do
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        err "Portainer did not become ready within ${MAX_WAIT}s"
        err "Check logs: docker logs portainer"
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
