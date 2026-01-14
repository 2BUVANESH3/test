#!/bin/bash

#############################################################################
# Complete Multi-Service Deployment Script (Refined)
# Deploys Docker + NGINX + Cloudflare Tunnel setup on Ubuntu Server
# Fixed: Docker Repository, DNS Routing, and Permissions
#############################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Error handler
error_exit() {
    log_error "$1"
    exit 1
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    error_exit "Please DO NOT run this script as root. Run as a normal user with sudo access."
fi

# Check sudo access
if ! sudo -n true 2>/dev/null; then
    log_warning "This script requires sudo access. You may be prompted for your password."
    sudo -v
fi

#############################################################################
# STEP 0: User Input Collection
#############################################################################

clear
echo "=========================================="
echo "  Multi-Service Deployment Setup (v2.0)"
echo "=========================================="
echo ""

log_info "Please provide the following information:"
echo ""

# Get domain name
read -p "Enter your domain name (Must be active on Cloudflare, e.g., mysite.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
    error_exit "Domain name cannot be empty"
fi

# Get subdomain preferences
read -p "Enter API subdomain [default: api]: " API_SUBDOMAIN
API_SUBDOMAIN=${API_SUBDOMAIN:-api}

read -p "Enter AI subdomain [default: ai]: " AI_SUBDOMAIN
AI_SUBDOMAIN=${AI_SUBDOMAIN:-ai}

# Set full domains
MAIN_DOMAIN="$DOMAIN_NAME"
API_DOMAIN="${API_SUBDOMAIN}.${DOMAIN_NAME}"
AI_DOMAIN="${AI_SUBDOMAIN}.${DOMAIN_NAME}"

# Get tunnel name
read -p "Enter Cloudflare tunnel name [default: myserver]: " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-myserver}

# Installation directory
read -p "Enter installation directory [default: /srv]: " USER_INSTALL_DIR
INSTALL_DIR=${USER_INSTALL_DIR:-/srv}

# Confirm settings
echo ""
log_info "Configuration Summary:"
echo "  Main Domain:    $MAIN_DOMAIN"
echo "  API Domain:     $API_DOMAIN"
echo "  AI Domain:      $AI_DOMAIN"
echo "  Tunnel Name:    $TUNNEL_NAME"
echo "  Install Dir:    $INSTALL_DIR"
echo ""

read -p "Continue with these settings? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_warning "Installation cancelled by user"
    exit 0
fi

#############################################################################
# STEP 1: System Update & Prerequisites
#############################################################################

log_info "Step 1/12: Updating system and installing prerequisites..."
sudo apt update -qq
sudo apt install -y ca-certificates curl gnupg lsb-release -qq
log_success "System prerequisites installed"

#############################################################################
# STEP 2: Install Docker (Official Repo Method)
#############################################################################

log_info "Step 2/12: Installing Docker from Official Repository..."

# 1. Add Docker's official GPG key:
sudo install -m 0755 -d /etc/apt/keyrings
if [ -f /etc/apt/keyrings/docker.gpg ]; then
    sudo rm /etc/apt/keyrings/docker.gpg
fi
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# 2. Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 3. Install Docker packages
sudo apt update -qq
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 4. Enable Docker
sudo systemctl enable docker
sudo systemctl start docker

# 5. Add user to docker group
sudo usermod -aG docker $USER

log_success "Docker installed successfully"
log_info "Docker Version: $(docker --version)"
log_info "Compose Version: $(docker compose version)"

#############################################################################
# STEP 3: Install Cloudflared
#############################################################################

log_info "Step 3/12: Installing Cloudflare Tunnel (cloudflared)..."

if ! command -v cloudflared &> /dev/null; then
    cd /tmp
    # Explicitly fetching .deb for amd64 (most common)
    curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
    sudo dpkg -i cloudflared.deb
    rm cloudflared.deb
    log_success "Cloudflared installed"
else
    log_success "Cloudflared already installed"
fi

#############################################################################
# STEP 4: Create Directory Structure
#############################################################################

log_info "Step 4/12: Creating directory structure..."

sudo mkdir -p $INSTALL_DIR/{nginx,cloudflared,services/{api,ai,frontend}}
sudo chown -R $USER:$USER $INSTALL_DIR

log_success "Directory structure created at $INSTALL_DIR"

#############################################################################
# STEP 5: Create NGINX Configuration
#############################################################################

log_info "Step 5/12: Creating NGINX configuration..."

# Note: We escape $ variables intended for Nginx config so Bash doesn't expand them
cat > $INSTALL_DIR/nginx/nginx.conf << EOF
events {
    worker_connections 1024;
}

http {
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Logging
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    
    # Main frontend
    server {
        listen 80;
        server_name $MAIN_DOMAIN;
        
        location / {
            proxy_pass http://frontend:3000;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
        
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }
    }
    
    # API service
    server {
        listen 80;
        server_name $API_DOMAIN;
        
        location / {
            proxy_pass http://api:8000;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
    
    # AI service
    server {
        listen 80;
        server_name $AI_DOMAIN;
        
        location / {
            proxy_pass http://ai:8501;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            
            # WebSocket support for Streamlit
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
EOF

log_success "NGINX configuration created"

#############################################################################
# STEP 6: Create Service Files
#############################################################################

log_info "Step 6/12: Creating service files..."

# API Service (FastAPI)
cat > $INSTALL_DIR/services/api/Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn[standard]
COPY main.py .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

cat > $INSTALL_DIR/services/api/main.py << EOF
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import socket
from datetime import datetime

app = FastAPI(title="API Service", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
def read_root():
    return {
        "message": "API Service Online",
        "domain": "$API_DOMAIN",
        "hostname": socket.gethostname(),
        "timestamp": datetime.now().isoformat(),
        "status": "healthy"
    }

@app.get("/health")
def health_check():
    return {"status": "healthy", "service": "api"}
EOF

# AI Service (Streamlit)
cat > $INSTALL_DIR/services/ai/Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir streamlit pandas numpy
COPY app.py .
EXPOSE 8501
CMD ["streamlit", "run", "app.py", "--server.port=8501", "--server.address=0.0.0.0", "--server.headless=true"]
EOF

cat > $INSTALL_DIR/services/ai/app.py << EOF
import streamlit as st
import socket
from datetime import datetime

st.set_page_config(page_title="AI Service", page_icon="🤖")
st.title("🤖 AI Service Dashboard")
st.write(f"Running on **$AI_DOMAIN**")
st.divider()

col1, col2, col3 = st.columns(3)
col1.metric("Status", "Online", "✅")
col2.metric("Service", "AI/ML")
col3.metric("Version", "1.0.0")

st.divider()
name = st.text_input("Enter your name:", placeholder="John Doe")
if name:
    st.success(f"👋 Hello, **{name}**!")
    if st.button("Generate"):
        st.balloons()
        st.write(f"🎉 Welcome to AI!")

with st.expander("System Info"):
    st.write(f"**Hostname:** {socket.gethostname()}")
EOF

# Frontend Service (HTML)
cat > $INSTALL_DIR/services/frontend/Dockerfile << 'EOF'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 3000
EOF

cat > $INSTALL_DIR/services/frontend/nginx.conf << 'EOF'
server {
    listen 3000;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF

cat > $INSTALL_DIR/services/frontend/index.html << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Multi-Service Platform</title>
    <style>
        body { font-family: sans-serif; background: #f0f2f5; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .card { background: white; padding: 2rem; border-radius: 12px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); text-align: center; max-width: 600px; }
        .btn { display: inline-block; margin: 10px; padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 6px; }
        .btn:hover { background: #0056b3; }
        h1 { margin-bottom: 0.5rem; }
    </style>
</head>
<body>
    <div class="card">
        <h1>🚀 Platform Online</h1>
        <p>Main Domain: $MAIN_DOMAIN</p>
        <div style="margin-top: 2rem;">
            <a href="https://$API_DOMAIN" class="btn">🔌 API Service</a>
            <a href="https://$AI_DOMAIN" class="btn">🤖 AI Service</a>
        </div>
    </div>
</body>
</html>
EOF

log_success "Service files created"

#############################################################################
# STEP 7: Create Docker Compose File
#############################################################################

log_info "Step 7/12: Creating Docker Compose configuration..."

# Note: Using version '3.8' which is broadly compatible
cat > $INSTALL_DIR/docker-compose.yml << EOF
version: "3.8"

services:
  nginx:
    image: nginx:alpine
    container_name: nginx-proxy
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - nginx-logs:/var/log/nginx
    restart: unless-stopped
    networks:
      - internal
    depends_on:
      - api
      - ai
      - frontend
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflare-tunnel
    command: tunnel run
    volumes:
      - ./cloudflared:/etc/cloudflared
    restart: unless-stopped
    networks:
      - internal
    depends_on:
      - nginx

  api:
    build: ./services/api
    container_name: api-service
    restart: unless-stopped
    networks:
      - internal
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 30s
      timeout: 10s
      retries: 3

  ai:
    build: ./services/ai
    container_name: ai-service
    restart: unless-stopped
    networks:
      - internal
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8501/_stcore/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  frontend:
    build: ./services/frontend
    container_name: frontend-service
    restart: unless-stopped
    networks:
      - internal

networks:
  internal:
    driver: bridge

volumes:
  nginx-logs:
EOF

log_success "Docker Compose file created"

#############################################################################
# STEP 8: Cloudflare Authentication
#############################################################################

log_info "Step 8/12: Setting up Cloudflare authentication..."

if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    log_warning "Opening browser for Cloudflare authentication..."
    log_warning "You need to copy the URL below and paste it in your browser to authorize:"
    
    # We run this in foreground so user sees the URL
    cloudflared tunnel login
    
    if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
        error_exit "Cloudflare authentication failed. Please run 'cloudflared tunnel login' manually."
    fi
    
    log_success "Cloudflare authentication successful"
else
    log_success "Already authenticated with Cloudflare"
fi

#############################################################################
# STEP 9: Create Cloudflare Tunnel
#############################################################################

log_info "Step 9/12: Creating Cloudflare tunnel..."

# Check if tunnel already exists
EXISTING_TUNNEL=$(cloudflared tunnel list 2>/dev/null | grep -w "$TUNNEL_NAME" | awk '{print $1}' || true)

if [ -n "$EXISTING_TUNNEL" ]; then
    log_warning "Tunnel '$TUNNEL_NAME' already exists with ID: $EXISTING_TUNNEL"
    TUNNEL_ID="$EXISTING_TUNNEL"
else
    # Create new tunnel
    TUNNEL_OUTPUT=$(cloudflared tunnel create $TUNNEL_NAME 2>&1)
    TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | grep -oP '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1)
    
    if [ -z "$TUNNEL_ID" ]; then
        error_exit "Failed to create tunnel. Output: $TUNNEL_OUTPUT"
    fi
    
    log_success "Tunnel created with ID: $TUNNEL_ID"
fi

#############################################################################
# STEP 10: Configure Cloudflare Tunnel
#############################################################################

log_info "Step 10/12: Configuring Cloudflare tunnel..."

# Find credentials file
CRED_FILE=$(find $HOME/.cloudflared -name "${TUNNEL_ID}.json" | head -1)

if [ -z "$CRED_FILE" ]; then
    error_exit "Credentials file not found for tunnel ID: $TUNNEL_ID"
fi

# Copy credentials to installation directory
cp "$CRED_FILE" "$INSTALL_DIR/cloudflared/"

# Create tunnel configuration
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

log_success "Tunnel configuration created"

#############################################################################
# STEP 11: Route DNS (CRITICAL FIX)
#############################################################################

log_info "Step 11/12: Routing DNS to Tunnel..."

log_info "Routing $MAIN_DOMAIN..."
cloudflared tunnel route dns -f $TUNNEL_NAME $MAIN_DOMAIN

log_info "Routing $API_DOMAIN..."
cloudflared tunnel route dns -f $TUNNEL_NAME $API_DOMAIN

log_info "Routing $AI_DOMAIN..."
cloudflared tunnel route dns -f $TUNNEL_NAME $AI_DOMAIN

log_success "DNS records updated on Cloudflare"

#############################################################################
# STEP 12: Start Services
#############################################################################

log_info "Step 12/12: Starting services..."

cd $INSTALL_DIR

# Use sudo docker compose explicitly to avoid permission issues in current session
log_info "Building and starting containers..."
sudo docker compose build
sudo docker compose up -d

log_success "Services started!"
echo ""
echo "=========================================="
echo "  Deployment Complete! 🚀"
echo "=========================================="
echo "  Frontend:  https://$MAIN_DOMAIN"
echo "  API:       https://$API_DOMAIN"
echo "  AI:        https://$AI_DOMAIN"
echo "=========================================="
echo "  IMPORTANT: If you see permission errors when running docker commands manually,"
echo "  please log out and log back in for group changes to take effect."
echo "=========================================="
