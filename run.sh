#!/bin/bash

#############################################################################
# Complete Multi-Service Deployment Script (Robust Version)
# Deploys Docker + NGINX + Cloudflare Tunnel
# Features: Deep Cert Search, Manual Path Fallback, Permission Handling
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

# Check sudo (soft check - doesn't exit if fails, just notes it)
CAN_SUDO=false
if sudo -n true 2>/dev/null; then
    CAN_SUDO=true
else
    # Try to prompt once
    if sudo -v 2>/dev/null; then
        CAN_SUDO=true
    else
        log_warning "Running without sudo/root access. Some system paths may be unreadable."
    fi
fi

#############################################################################
# STEP 0: Configuration
#############################################################################

clear
echo "=========================================="
echo "  Multi-Service Deployment (Robust)"
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
# STEP 1-5: Setup (Condensed)
#############################################################################

log_info "Step 1/8: System Setup & Directories..."

# Prerequisites
if $CAN_SUDO; then
    sudo apt update -qq >/dev/null 2>&1
    sudo apt install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1
else
    log_warning "Skipping apt update (no sudo). Ensure packages are installed."
fi

# Directory Structure
if $CAN_SUDO; then
    sudo mkdir -p $INSTALL_DIR/{nginx,cloudflared,services/{api,ai,frontend}}
    sudo chown -R $USER:$USER $INSTALL_DIR
else
    # Fallback to local dir if can't write to /srv
    if [ ! -w "$INSTALL_DIR" ]; then
        log_warning "Cannot write to $INSTALL_DIR. Using $HOME/deploy instead."
        INSTALL_DIR="$HOME/deploy"
    fi
    mkdir -p $INSTALL_DIR/{nginx,cloudflared,services/{api,ai,frontend}}
fi

log_success "Working directory: $INSTALL_DIR"

# Generate Configs
log_info "Step 2/8: Generating Configs..."

# NGINX
cat > $INSTALL_DIR/nginx/nginx.conf << EOF
events { worker_connections 1024; }
http {
    server { listen 80; server_name $MAIN_DOMAIN; location / { proxy_pass http://frontend:3000; } }
    server { listen 80; server_name $API_DOMAIN; location / { proxy_pass http://api:8000; } }
    server { listen 80; server_name $AI_DOMAIN; location / { proxy_pass http://ai:8501; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; } }
}
EOF

# Services (Simplified for brevity)
echo 'from fastapi import FastAPI; app=FastAPI(); @app.get("/")' > $INSTALL_DIR/services/api/main.py
echo 'def r(): return {"s":"ok"}' >> $INSTALL_DIR/services/api/main.py
echo -e 'FROM python:3.11-slim\nRUN pip install fastapi uvicorn\nCOPY . .\nCMD ["uvicorn","main:app","--host","0.0.0.0"]' > $INSTALL_DIR/services/api/Dockerfile

echo 'import streamlit as st; st.title("AI Service Online")' > $INSTALL_DIR/services/ai/app.py
echo -e 'FROM python:3.11-slim\nRUN pip install streamlit\nCOPY . .\nCMD ["streamlit","run","app.py","--server.port=8501","--server.address=0.0.0.0"]' > $INSTALL_DIR/services/ai/Dockerfile

echo "<h1>$MAIN_DOMAIN</h1>" > $INSTALL_DIR/services/frontend/index.html
echo -e 'FROM nginx:alpine\nCOPY index.html /usr/share/nginx/html/' > $INSTALL_DIR/services/frontend/Dockerfile

# Compose
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
  api: {build: ./services/api, networks: [internal]}
  ai: {build: ./services/ai, networks: [internal]}
  frontend: {build: ./services/frontend, networks: [internal]}
networks: {internal: }
EOF

#############################################################################
# STEP 6: CERTIFICATE HUNT (The Fix)
#############################################################################

log_info "Step 3/8: Locating Cloudflare Certificate..."

CERT_FOUND=false
TARGET_CERT="$HOME/.cloudflared/cert.pem"
mkdir -p "$HOME/.cloudflared"

# 1. Define specific paths to check first
PATHS_TO_CHECK=(
    "$HOME/.cloudflared/cert.pem"
    "/.cloudflared/cert.pem"
    "/.cloudfared/cert.pem"
    "/etc/cloudflared/cert.pem"
    "/root/.cloudflared/cert.pem"
)

# 2. Check specific paths
for LOC in "${PATHS_TO_CHECK[@]}"; do
    # Use sudo if available, else standard test
    if $CAN_SUDO; then
        if sudo test -f "$LOC"; then
            FOUND_LOC="$LOC"
            break
        fi
    else
        if [ -f "$LOC" ]; then
            FOUND_LOC="$LOC"
            break
        fi
    fi
done

# 3. If not found, use FIND command (ignoring permission errors)
if [ -z "$FOUND_LOC" ]; then
    log_info "Not found in standard paths. Searching system..."
    
    # Construct find command
    # We look in / but exclude proc/sys/dev/mnt to avoid hanging
    # 2>/dev/null hides the "Permission denied" spam
    if $CAN_SUDO; then
        FOUND_LOC=$(sudo find / -maxdepth 5 -name "cert.pem" -not -path "*/proc/*" 2>/dev/null | grep "cloudflared" | head -n 1)
    else
        FOUND_LOC=$(find / -maxdepth 5 -name "cert.pem" -not -path "*/proc/*" 2>/dev/null | grep "cloudflared" | head -n 1)
    fi
fi

# 4. Process the found file
if [ -n "$FOUND_LOC" ]; then
    log_success "Certificate found at: $FOUND_LOC"
    
    # Copy logic
    if [ "$FOUND_LOC" != "$TARGET_CERT" ]; then
        if $CAN_SUDO; then
            sudo cp "$FOUND_LOC" "$TARGET_CERT"
            sudo chown $USER:$USER "$TARGET_CERT"
        else
            cp "$FOUND_LOC" "$TARGET_CERT"
        fi
    fi
    CERT_FOUND=true
fi

# 5. FINAL FALLBACK: Ask User
if [ "$CERT_FOUND" = false ]; then
    log_warning "Automatic search failed."
    echo ""
    echo "Please open a new terminal, find your 'cert.pem' file, and copy the full path."
    read -p "Paste the full path to cert.pem here (or press Enter to login again): " MANUAL_PATH
    
    if [ -n "$MANUAL_PATH" ]; then
        # Remove quotes if user added them
        MANUAL_PATH=$(echo "$MANUAL_PATH" | tr -d '"' | tr -d "'")
        
        if $CAN_SUDO; then
            sudo cp "$MANUAL_PATH" "$TARGET_CERT"
            sudo chown $USER:$USER "$TARGET_CERT"
            CERT_FOUND=true
        elif [ -r "$MANUAL_PATH" ]; then
            cp "$MANUAL_PATH" "$TARGET_CERT"
            CERT_FOUND=true
        else
            log_error "Cannot read file at $MANUAL_PATH (Permission denied?)"
        fi
    fi
fi

# 6. If STILL not found, force login
if [ "$CERT_FOUND" = false ]; then
    log_warning "No certificate provided. Initiating login..."
    cloudflared tunnel login
fi

#############################################################################
# STEP 7: Tunnel Setup
#############################################################################

log_info "Step 4/8: Configuring Tunnel..."

# Reuse existing or create new
EXISTING_ID=$(cloudflared tunnel list 2>/dev/null | grep -w "$TUNNEL_NAME" | awk '{print $1}' || true)

if [ -n "$EXISTING_ID" ]; then
    TUNNEL_ID="$EXISTING_ID"
    log_success "Using ID: $TUNNEL_ID"
else
    TUNNEL_OUT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1)
    TUNNEL_ID=$(echo "$TUNNEL_OUT" | grep -oP '[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}' | head -1)
    log_success "Created ID: $TUNNEL_ID"
fi

# Find credentials (similar robust search)
log_info "Step 5/8: Finding Credentials..."
CRED_NAME="${TUNNEL_ID}.json"
CRED_FILE=""

# Check home
if [ -f "$HOME/.cloudflared/$CRED_NAME" ]; then
    CRED_FILE="$HOME/.cloudflared/$CRED_NAME"
# Check root/system
elif $CAN_SUDO; then
    CRED_FILE=$(sudo find / -name "$CRED_NAME" 2>/dev/null | head -n 1)
else
    CRED_FILE=$(find / -name "$CRED_NAME" 2>/dev/null | head -n 1)
fi

if [ -z "$CRED_FILE" ]; then
    log_error "Credentials file $CRED_NAME not found!"
    exit 1
fi

log_success "Credentials found: $CRED_FILE"

# Copy to install dir
if $CAN_SUDO; then
    sudo cp "$CRED_FILE" "$INSTALL_DIR/cloudflared/"
    sudo chmod 644 "$INSTALL_DIR/cloudflared/$(basename $CRED_FILE)"
else
    cp "$CRED_FILE" "$INSTALL_DIR/cloudflared/"
fi

# Config.yml
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
# STEP 8: Launch
#############################################################################

log_info "Step 6/8: Routing DNS..."
cloudflared tunnel route dns -f $TUNNEL_NAME $MAIN_DOMAIN >/dev/null 2>&1 || true
cloudflared tunnel route dns -f $TUNNEL_NAME $API_DOMAIN >/dev/null 2>&1 || true
cloudflared tunnel route dns -f $TUNNEL_NAME $AI_DOMAIN >/dev/null 2>&1 || true

log_info "Step 7/8: Launching Services..."
cd $INSTALL_DIR

if $CAN_SUDO; then
    sudo docker compose down 2>/dev/null || true
    sudo docker compose up -d --build
else
    # Try without sudo if user is in docker group
    docker compose down 2>/dev/null || true
    docker compose up -d --build
fi

echo ""
log_success "DEPLOYMENT COMPLETE!"
echo "Main: https://$MAIN_DOMAIN"
