#!/bin/bash

#############################################################################
# Complete Multi-Service Deployment Script (Final Fix)
# Deploys Docker + NGINX + Cloudflare Tunnel
# Fixes: Cert detection, Docker Plugin, Permissions, DNS
#############################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Root check
if [ "$EUID" -eq 0 ]; then 
    log_error "Please run this script as a NORMAL user (not root)."
    exit 1
fi

# Sudo check
if ! sudo -n true 2>/dev/null; then
    log_warning "Sudo access required. Please enter password:"
    sudo -v
fi

#############################################################################
# STEP 0: Configuration
#############################################################################

clear
echo "=========================================="
echo "  Multi-Service Deployment (Fixed)"
echo "=========================================="
echo ""

# defaults
DEFAULT_TUNNEL="myserver"
DEFAULT_INSTALL="/srv"

read -p "Enter your domain name (e.g., example.com): " DOMAIN_NAME
[ -z "$DOMAIN_NAME" ] && { log_error "Domain required"; exit 1; }

read -p "Enter API subdomain [default: api]: " API_SUB
API_SUB=${API_SUB:-api}

read -p "Enter AI subdomain [default: ai]: " AI_SUB
AI_SUB=${AI_SUB:-ai}

read -p "Enter Tunnel Name [default: myserver]: " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-$DEFAULT_TUNNEL}

read -p "Enter Install Dir [default: /srv]: " USER_INSTALL_DIR
INSTALL_DIR=${USER_INSTALL_DIR:-$DEFAULT_INSTALL}

# Domains
MAIN_DOMAIN="$DOMAIN_NAME"
API_DOMAIN="${API_SUB}.${DOMAIN_NAME}"
AI_DOMAIN="${AI_SUB}.${DOMAIN_NAME}"

log_info "Deploying to: $MAIN_DOMAIN, $API_DOMAIN, $AI_DOMAIN"
echo ""

#############################################################################
# STEP 1: Prerequisites
#############################################################################

log_info "Step 1/11: Installing prerequisites..."
sudo apt update -qq
sudo apt install -y ca-certificates curl gnupg lsb-release -qq

#############################################################################
# STEP 2: Install Docker (Official Repo)
#############################################################################

log_info "Step 2/11: Checking Docker..."

if ! command -v docker &> /dev/null; then
    log_info "Installing Docker..."
    sudo install -m 0755 -d /etc/apt/keyrings
    [ -f /etc/apt/keyrings/docker.gpg ] && sudo rm /etc/apt/keyrings/docker.gpg
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update -qq
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    sudo systemctl start docker
    sudo usermod -aG docker $USER
    log_success "Docker installed."
else
    log_success "Docker already installed."
fi

#############################################################################
# STEP 3: Install Cloudflared
#############################################################################

log_info "Step 3/11: Checking Cloudflared..."

if ! command -v cloudflared &> /dev/null; then
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    sudo dpkg -i cloudflared.deb
    rm cloudflared.deb
    log_success "Cloudflared installed."
else
    log_success "Cloudflared already installed."
fi

#############################################################################
# STEP 4: Setup Directories
#############################################################################

log_info "Step 4/11: Setting up directories..."
sudo mkdir -p $INSTALL_DIR/{nginx,cloudflared,services/{api,ai,frontend}}
sudo chown -R $USER:$USER $INSTALL_DIR

#############################################################################
# STEP 5: Create Configs (NGINX & Services)
#############################################################################

log_info "Step 5/11: Generating configuration files..."

# NGINX Config
cat > $INSTALL_DIR/nginx/nginx.conf << EOF
events { worker_connections 1024; }
http {
    server {
        listen 80;
        server_name $MAIN_DOMAIN;
        location / { proxy_pass http://frontend:3000; }
    }
    server {
        listen 80;
        server_name $API_DOMAIN;
        location / { proxy_pass http://api:8000; }
    }
    server {
        listen 80;
        server_name $AI_DOMAIN;
        location / {
            proxy_pass http://ai:8501;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
EOF

# API Service
cat > $INSTALL_DIR/services/api/Dockerfile << 'EOF'
FROM python:3.11-slim
RUN pip install fastapi uvicorn[standard]
COPY main.py .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF
cat > $INSTALL_DIR/services/api/main.py << EOF
from fastapi import FastAPI
app = FastAPI()
@app.get("/")
def read_root(): return {"status": "online", "service": "API"}
@app.get("/health")
def health(): return {"status": "healthy"}
EOF

# AI Service
cat > $INSTALL_DIR/services/ai/Dockerfile << 'EOF'
FROM python:3.11-slim
RUN pip install streamlit
COPY app.py .
CMD ["streamlit", "run", "app.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF
cat > $INSTALL_DIR/services/ai/app.py << EOF
import streamlit as st
st.title("🤖 AI Service")
st.success("Service is Online!")
EOF

# Frontend Service
cat > $INSTALL_DIR/services/frontend/Dockerfile << 'EOF'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/
EOF
echo "<h1>Welcome to $MAIN_DOMAIN</h1>" > $INSTALL_DIR/services/frontend/index.html

# Docker Compose
cat > $INSTALL_DIR/docker-compose.yml << EOF
version: "3.8"
services:
  nginx:
    image: nginx:alpine
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on: [api, ai, frontend]
    networks: [internal]
  cloudflared:
    image: cloudflare/cloudflared:latest
    command: tunnel run
    volumes:
      - ./cloudflared:/etc/cloudflared
    networks: [internal]
  api:
    build: ./services/api
    networks: [internal]
  ai:
    build: ./services/ai
    networks: [internal]
  frontend:
    build: ./services/frontend
    networks: [internal]
networks:
  internal:
EOF

#############################################################################
# STEP 6: Cloudflare Auth (SMART FIX)
#############################################################################

log_info "Step 6/11: Verifying Cloudflare Certificate..."

CERT_FOUND=false
TARGET_CERT="$HOME/.cloudflared/cert.pem"
mkdir -p "$HOME/.cloudflared"

# Search locations for cert.pem (including root and custom paths)
LOCATIONS=(
    "$HOME/.cloudflared/cert.pem"
    "/root/.cloudflared/cert.pem"
    "/.cloudflared/cert.pem"
    "/etc/cloudflared/cert.pem"
)

# Try to find the cert in known locations
for LOC in "${LOCATIONS[@]}"; do
    if sudo test -f "$LOC"; then
        log_success "Found certificate at: $LOC"
        if [ "$LOC" != "$TARGET_CERT" ]; then
            log_info "Copying certificate to current user..."
            sudo cp "$LOC" "$TARGET_CERT"
            sudo chown $USER:$USER "$TARGET_CERT"
        fi
        CERT_FOUND=true
        break
    fi
done

# Fallback: If not found in known list, search the whole system (fast)
if [ "$CERT_FOUND" = false ]; then
    log_info "Searching system for cert.pem..."
    # Find cert.pem in / (exclude proc/sys/dev to save time/errors)
    FOUND_LOC=$(sudo find / -maxdepth 4 -name "cert.pem" 2>/dev/null | grep "cloudflared" | head -n 1)
    
    if [ -n "$FOUND_LOC" ]; then
        log_success "Found certificate at: $FOUND_LOC"
        sudo cp "$FOUND_LOC" "$TARGET_CERT"
        sudo chown $USER:$USER "$TARGET_CERT"
        CERT_FOUND=true
    fi
fi

if [ "$CERT_FOUND" = false ]; then
    log_warning "Certificate not found automatically."
    log_warning "Please log in via the browser link below:"
    cloudflared tunnel login
else
    log_success "Certificate verified."
fi

#############################################################################
# STEP 7: Create Tunnel
#############################################################################

log_info "Step 7/11: Setting up Tunnel..."

# Check existing
EXISTING_ID=$(cloudflared tunnel list 2>/dev/null | grep -w "$TUNNEL_NAME" | awk '{print $1}' || true)

if [ -n "$EXISTING_ID" ]; then
    TUNNEL_ID="$EXISTING_ID"
    log_success "Using existing tunnel: $TUNNEL_ID"
else
    # Create new
    TUNNEL_OUT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1)
    TUNNEL_ID=$(echo "$TUNNEL_OUT" | grep -oP '[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}' | head -1)
    [ -z "$TUNNEL_ID" ] && { error_exit "Tunnel creation failed"; }
    log_success "Created new tunnel: $TUNNEL_ID"
fi

#############################################################################
# STEP 8: Configure Tunnel
#############################################################################

log_info "Step 8/11: Configuring Tunnel credentials..."

# Locate credentials json
CRED_FILE=""
# Search recursively in home for the ID
CRED_FILE=$(find $HOME/.cloudflared -name "${TUNNEL_ID}.json" 2>/dev/null | head -1)

# If not in home, check /root (via sudo)
if [ -z "$CRED_FILE" ]; then
    sudo test -f "/root/.cloudflared/${TUNNEL_ID}.json" && CRED_FILE="/root/.cloudflared/${TUNNEL_ID}.json"
fi

# Fallback search
if [ -z "$CRED_FILE" ]; then
     CRED_FILE=$(sudo find / -maxdepth 4 -name "${TUNNEL_ID}.json" 2>/dev/null | head -n 1)
fi

if [ -z "$CRED_FILE" ]; then
    log_error "Could not find credentials file for ID: $TUNNEL_ID"
    log_error "Please run 'cloudflared tunnel create $TUNNEL_NAME' manually to generate it."
    exit 1
fi

log_info "Found credentials: $CRED_FILE"
sudo cp "$CRED_FILE" "$INSTALL_DIR/cloudflared/"
sudo chmod 644 "$INSTALL_DIR/cloudflared/$(basename $CRED_FILE)"

# Write config
cat > $INSTALL_DIR/cloudflared/config.yml << EOF
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json
ingress:
  - hostname: $MAIN_DOMAIN
    service: http://nginx:80
  - hostname: $API_DOMAIN
    service: http://nginx:80
  - hostname: $AI_DOMAIN
    service: http://nginx:80
  - service: http_status:404
EOF

#############################################################################
# STEP 9: DNS Routing
#############################################################################

log_info "Step 9/11: Routing DNS..."
cloudflared tunnel route dns -f $TUNNEL_NAME $MAIN_DOMAIN
cloudflared tunnel route dns -f $TUNNEL_NAME $API_DOMAIN
cloudflared tunnel route dns -f $TUNNEL_NAME $AI_DOMAIN

#############################################################################
# STEP 10: Start Services
#############################################################################

log_info "Step 10/11: Launching Docker Containers..."
cd $INSTALL_DIR
sudo docker compose down --remove-orphans 2>/dev/null || true
sudo docker compose up -d --build

#############################################################################
# STEP 11: Final Status
#############################################################################

echo ""
log_success "DEPLOYMENT COMPLETE!"
echo "----------------------------------------"
echo "  Frontend:  https://$MAIN_DOMAIN"
echo "  API:       https://$API_DOMAIN"
echo "  AI:        https://$AI_DOMAIN"
echo "----------------------------------------"
