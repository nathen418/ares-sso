#!/bin/bash
# -----------------------------------------------------------------------------
# Authentik System Agent Installation Script (Ubuntu 24.04+)
#
# Features:
#   - Installs Authentik CLI, system agent, and user agent
#   - Installs NSS + PAM integration modules
#   - Supports fully headless enrollment
#   - Registers host into an Authentik domain
# -----------------------------------------------------------------------------
set -e

# -----------------------------------------------------------------------------
# Terminal Colors
# -----------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# === LOAD CONFIG =============================================================
if [ -f .env ]; then
    echo -e "${YELLOW}[*] Loading environment from .env...${NC}"
    # shellcheck disable=SC1091
    source .env
else
    echo -e "${RED}[!] No .env file found. Please create one (see .env.example).${NC}"
    exit 1
fi

# Validate required vars
for VAR in AUTHENTIK_URL AUTHENTIK_DOMAIN AUTHENTIK_TOKEN; do
    if [ -z "${!VAR}" ]; then
        echo -e "${RED}[!] Missing required variable: $VAR${NC}"
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# Verify Authentik server connectivity
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Running Authentik connectivity checks...${NC}"

AUTH_HOST=$(echo "$AUTHENTIK_URL" | sed -E 's|https?://([^/]+)/?.*|\1|')

# -----------------------------------------------------------------------------
# DNS Check
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Checking DNS resolution for $AUTH_HOST...${NC}"

if getent hosts "$AUTH_HOST" > /dev/null; then
    echo -e "${GREEN}[+] DNS resolution successful.${NC}"
else
    echo -e "${RED}[!] DNS resolution failed for $AUTH_HOST${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# TCP Port Check
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Checking TCP connectivity to $AUTH_HOST:443...${NC}"

if timeout 5 bash -c "</dev/tcp/$AUTH_HOST/443" 2>/dev/null; then
    echo -e "${GREEN}[+] TCP port 443 reachable.${NC}"
else
    echo -e "${RED}[!] Cannot connect to $AUTH_HOST on port 443.${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# TLS Certificate Check
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Verifying TLS certificate...${NC}"

echo | openssl s_client -connect "$AUTH_HOST:443" -servername "$AUTH_HOST" -verify_return_error -CApath /etc/ssl/certs >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[+] TLS certificate chain appears valid.${NC}"
else
    echo -e "${RED}[!] TLS certificate validation failed.${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# HTTPS / Authentik API Check
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Checking Authentik API endpoint...${NC}"

if curl --silent --show-error --fail \
    --connect-timeout 5 \
    --max-time 10 \
    "$AUTHENTIK_URL/api/v3/" > /dev/null; then

    echo -e "${GREEN}[+] Authentik API reachable.${NC}"
else
    echo -e "${RED}[!] Authentik API not reachable.${NC}"
    exit 1
fi

echo -e "${GREEN}[+] All Authentik connectivity checks passed.${NC}"

# ============================================================================

echo -e "${YELLOW}[*] Starting Authentik agent installation...${NC}"

# -----------------------------------------------------------------------------
# Install Required Packages
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Installing prerequisite packages...${NC}"
sudo apt update
sudo apt install -y curl ca-certificates gpg

# -----------------------------------------------------------------------------
# Add Authentik GPG Key
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Adding Authentik package signing key...${NC}"

if [ ! -f /usr/share/keyrings/authentik-keyring.gpg ]; then
    curl -fsSL https://pkg.goauthentik.io/keys/gpg-key.asc \
        | sudo gpg --dearmor -o /usr/share/keyrings/authentik-keyring.gpg
else
    echo -e "${GREEN}[+] Authentik GPG key already installed.${NC}"
fi

# -----------------------------------------------------------------------------
# Add Authentik Repository
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Adding Authentik APT repository...${NC}"

if [ ! -f /etc/apt/sources.list.d/authentik.list ]; then
    echo "deb [signed-by=/usr/share/keyrings/authentik-keyring.gpg] https://pkg.goauthentik.io stable main" \
        | sudo tee /etc/apt/sources.list.d/authentik.list > /dev/null
else
    echo -e "${GREEN}[+] Authentik repository already configured.${NC}"
fi

# -----------------------------------------------------------------------------
# Install Authentik Packages
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Installing Authentik components...${NC}"

sudo apt update
sudo apt install -y \
    authentik-cli \
    authentik-agent \
    authentik-sysd \
    libnss-authentik \
    libpam-authentik

# -----------------------------------------------------------------------------
# Enable system agent
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Enabling system agent...${NC}"

sudo systemctl enable ak-sysd
sudo systemctl restart ak-sysd

# -----------------------------------------------------------------------------
# Start user agent for headless environments
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Starting Authentik user agent...${NC}"

CURRENT_USER=$(logname)

sudo loginctl enable-linger "$CURRENT_USER"

sudo -u "$CURRENT_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $CURRENT_USER)" \
    systemctl --user start ak-agent || true

# -----------------------------------------------------------------------------
# Join Authentik Domain
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[*] Enrolling host into Authentik domain...${NC}"

if sudo ak-sysd domains list 2>/dev/null | grep -q "$AUTHENTIK_DOMAIN"; then
    echo -e "${GREEN}[+] Host already joined to $AUTHENTIK_DOMAIN${NC}"
else
    echo "$AUTHENTIK_TOKEN" | sudo ak-sysd domains join "$AUTHENTIK_DOMAIN" \
        --authentik-url "$AUTHENTIK_URL"
fi

# -----------------------------------------------------------------------------
# Final Status
# -----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}[+] Authentik agent setup complete!${NC}"
echo ""
echo "Domain: $AUTHENTIK_DOMAIN"
echo "Server: $AUTHENTIK_URL"
echo ""
echo "Host should now appear in the Authentik admin panel."