#!/bin/bash

#############################################################################
# Complete Multi-Service Deployment Script (Correction v3)
# Fixes: Permission handling, Directory vs File input, Docker Config
#############################################################################

set -e

# --- Visual Styling ---
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Logging Functions ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo ""; echo -e "${BOLD}--- Step $1: $2 ---${NC}"; }

# --- PRE-FLIGHT CHECKS ---

# 1. Check if running as root (We want normal user)
if [ "$EUID" -eq 0 ]; then 
    log_error "Please do NOT run this script as root."
    log_error "Run it as your normal user: bash deploy.sh"
    exit 1
fi

# 2. Check Sudo Access
if ! sudo -n true 2>/dev/null; then
    log_warn "Sudo access is required for installation."
    echo "Please enter your password:"
    sudo -v
fi

clear
echo "=================================================="
echo "   Multi-Service Deployment: The Robust Fix"
echo "=================================================="
echo ""

# --- CONFIGURATION INPUT ---

read -p "Enter your Main Domain (e.g., example.com): " DOMAIN_NAME
[ -z "$DOMAIN_NAME" ] && { log_error "Domain name is required."; exit 1; }

read -p "Enter API subdomain [default: api]: " API_SUB
API_SUB=${API_SUB:-api}

read -p "Enter AI subdomain [default: ai]: " AI_SUB
AI_SUB=${AI_SUB:-ai}

read -p "Enter Tunnel Name [default: myserver]: " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-myserver}

# Set Derived Variables
API_DOMAIN="${API_SUB}.${DOMAIN_NAME}"
AI_DOMAIN="${AI_SUB}.${DOMAIN_NAME}"
INSTALL_DIR="/srv"
LOCAL_CERT_DIR="$HOME/.cloudflared"
TARGET_CERT="$LOCAL_CERT_DIR/cert.pem"

step 1 "Certificate Acquisition"
log_info "Ensuring Cloudflare certificate is accessible..."

mkdir -p "$LOCAL_CERT_DIR"

CERT_FOUND=false

# List of probable locations (including Root paths)
POSSIBLE_LOCATIONS=(
    "$HOME/.cloudflared/cert.pem"
    "/root/.cloudflared/cert.pem"
    "/.cloudflared/cert.pem"
    "/etc/cloudflared/cert.pem"
    "/opt/homebrew/etc/cloudflared/cert.pem"
)

# 1. Auto-Search
for LOC in "${POSSIBLE_LOCATIONS[@]}"; do
    if sudo test -f "$LOC"; then
        log_success "Found certificate at: $LOC"
        
        # Copy to user directory with correct ownership
        log_info "Securely copying certificate to $TARGET_CERT..."
        sudo cp "$LOC" "$TARGET_CERT"
        sudo chown "$USER":"$USER" "$TARGET_CERT"
        chmod 600 "$TARGET_CERT"
        
        CERT_FOUND=true
        break
    fi
done

# 2. Manual Input (Robust Fix)
while [ "$CERT_FOUND" = false ]; do
    log_warn "Certificate not found in standard paths."
    echo "Please search for 'cert.pem' on your system."
    echo "Enter the FULL PATH to the file (or the folder containing it)."
    read -p "Path: " MANUAL_PATH

    # Clean input (remove quotes if user added them)
    MANUAL_PATH=$(echo "$MANUAL_PATH" | tr -d '"' | tr -d "'")

    # Check if input is empty
    if [ -z "$MANUAL_PATH" ]; then
        log_error "Path cannot be empty. Try again."
        continue
    fi

    # Logic: Did user provide a Folder or a File?
    REAL_FILE=""
    
    if [ -d "$MANUAL_PATH" ]; then
        # User gave a folder (e.g., /home/me)
        CHECK_FILE="${MANUAL_PATH%/}/cert.pem"
        log_info "You provided a directory. Checking for $CHECK_FILE..."
        if sudo test -f "$CHECK_FILE"; then
            REAL_FILE="$CHECK_FILE"
        fi
    elif sudo test -f "$MANUAL_PATH"; then
        # User gave a direct file
        REAL_FILE="$MANUAL_PATH"
    fi

    # Process Result
    if [ -n "$REAL_FILE" ]; then
        log_success "Valid certificate found at: $REAL_FILE"
        sudo cp "$REAL_FILE" "$TARGET_CERT"
        sudo chown "$USER":"$USER" "$TARGET_CERT"
        chmod 600 "$TARGET_CERT"
        CERT_FOUND=true
    else
        log_error "Could not find 'cert.pem' at that location."
        echo "Tip: Run 'sudo find / -name cert.pem' in another terminal to find it."
    fi
done

step 2 "System Prerequisites"
# Update and Install Docker if missing
if ! command -v docker &> /dev/null; then
    log_info "Installing Docker..."
    sudo apt-get update -qq
    sudo apt-get install -y ca-certificates curl gnupg lsb-release -qq
    
    sudo mkdir -p /etc/apt/keyrings
    [ -f /etc/apt/keyrings/docker.gpg ] && sudo rm /etc/apt/keyrings/docker.gpg
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -qq
else
    log_info "Docker is already installed."
fi

# Ensure Cloudflared
if ! command -v cloudflared &> /dev/null; then
    log_info "Installing cloudflared..."
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    sudo dpkg -i cloudflared.deb
    rm cloudflared.deb
fi

step 3 "Project Structure"
# Create directories (Robust permission fix)
if [ ! -d "$INSTALL_DIR" ]; then
    sudo mkdir -p "$INSTALL_DIR"
fi
sudo chown "$USER":"$USER" "$INSTALL_DIR"

mkdir -p $INSTALL_DIR/{nginx,cloudflared,services/{api,ai,frontend}}
log_success "Directory structure ready at $INSTALL_DIR"

step 4 "Generating Configurations"

# NGINX
cat > $INSTALL_DIR/nginx/nginx.conf << EOF
events { worker_connections 1024; }
http {
    server {
        listen 80;
        server_name $DOMAIN_NAME;
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

# Services (Simplified for reliability)
# API
echo 'from fastapi import FastAPI; app=FastAPI(); @app.get("/")' > $INSTALL_DIR/services/api/main.py
echo 'def r(): return {"status":"online","service":"API"}' >> $INSTALL_DIR/services/api/main.py
echo -e 'FROM python:3.11-slim\nRUN pip install fastapi uvicorn\nCOPY . .\nCMD ["uvicorn","main:app","--host","0.0.0.0","--port","8000"]' > $INSTALL_DIR/services/api/Dockerfile

# AI
echo 'import streamlit as st; st.title("AI Service"); st.success("Online")' > $INSTALL_DIR/services/ai/app.py
echo -e 'FROM python:3.11-slim\nRUN pip install streamlit\nCOPY . .\nCMD ["streamlit","run","app.py","--server.port=8501","--server.address=0.0.0.0"]' > $INSTALL_DIR/services/ai/Dockerfile

# Frontend
echo "<h1>Deployed via Robust Script</h1><p>$DOMAIN_NAME is Live</p>" > $INSTALL_DIR/services/frontend/index.html
echo -e 'FROM nginx:alpine\nCOPY index.html /usr/share/nginx/html/' > $INSTALL_DIR/services/frontend/Dockerfile

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
    container_name: tunnel_worker
    command: tunnel run
    volumes:
      - ./cloudflared:/etc/cloudflared
    networks: [internal]
    restart: always
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

step 5 "Tunnel Setup"

# Ensure we have the cert locally before running cloudflared commands
if [ ! -f "$TARGET_CERT" ]; then
    log_error "Critical: Certificate file missing at $TARGET_CERT. Script logic failed."
    exit 1
fi

log_info "Creating Tunnel..."
# Check if tunnel exists, if not create it
EXISTING_ID=$(cloudflared tunnel list 2>/dev/null | grep -w "$TUNNEL_NAME" | awk '{print $1}' || true)

if [ -n "$EXISTING_ID" ]; then
    TUNNEL_ID="$EXISTING_ID"
    log_success "Using existing tunnel ID: $TUNNEL_ID"
else
    # Create tunnel and capture ID
    TUNNEL_OUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
    TUNNEL_ID=$(echo "$TUNNEL_OUT" | grep -oP '[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}' | head -1)
    
    if [ -z "$TUNNEL_ID" ]; then
        log_error "Failed to create tunnel. Ensure cert.pem is valid."
        echo "$TUNNEL_OUT"
        exit 1
    fi
    log_success "Created new tunnel ID: $TUNNEL_ID"
fi

# Locate the Credential JSON file (Cloudflared creates this where the cert is)
# It might be in ~/.cloudflared or it might have failed to move if we ran sudo
log_info "Locating tunnel credentials..."

CRED_JSON="${TUNNEL_ID}.json"
FOUND_CRED=""

if [ -f "$LOCAL_CERT_DIR/$CRED_JSON" ]; then
    FOUND_CRED="$LOCAL_CERT_DIR/$CRED_JSON"
elif sudo test -f "/root/.cloudflared/$CRED_JSON"; then
    FOUND_CRED="/root/.cloudflared/$CRED_JSON"
fi

if [ -z "$FOUND_CRED" ]; then
    # Deep search if standard paths fail
    FOUND_CRED=$(sudo find / -name "$CRED_JSON" 2>/dev/null | head -n 1)
fi

if [ -z "$FOUND_CRED" ]; then
    log_error "Could not find credential file: $CRED_JSON"
    exit 1
fi

log_success "Found credentials at $FOUND_CRED"
sudo cp "$FOUND_CRED" "$INSTALL_DIR/cloudflared/"
sudo chmod 644 "$INSTALL_DIR/cloudflared/$CRED_JSON"

# Create Tunnel Config
cat > $INSTALL_DIR/cloudflared/config.yml << EOF
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json
ingress:
  - hostname: $DOMAIN_NAME
    service: http://nginx:80
  - hostname: $API_DOMAIN
    service: http://nginx:80
  - hostname: $AI_DOMAIN
    service: http://nginx:80
  - service: http_status:404
EOF

step 6 "Deployment"

# DNS Routing
log_info "Updating DNS records..."
cloudflared tunnel route dns -f "$TUNNEL_NAME" "$DOMAIN_NAME" || true
cloudflared tunnel route dns -f "$TUNNEL_NAME" "$API_DOMAIN" || true
cloudflared tunnel route dns -f "$TUNNEL_NAME" "$AI_DOMAIN" || true

log_info "Starting Containers..."
cd "$INSTALL_DIR"
sudo docker compose down --remove-orphans 2>/dev/null || true
sudo docker compose up -d --build

step 7 "Status"
echo ""
log_success "DEPLOYMENT COMPLETE!"
echo "----------------------------------------------------"
echo "  Main Site:   https://$DOMAIN_NAME"
echo "  API:         https://$API_DOMAIN"
echo "  AI Service:  https://$AI_DOMAIN"
echo "----------------------------------------------------"
