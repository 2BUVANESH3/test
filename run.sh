#!/bin/bash

#############################################################################
# Complete Multi-Service Deployment Script
# Deploys Docker + NGINX + Cloudflare Tunnel setup on Ubuntu Server
# 100% FREE - Works with any domain (DuckDNS, nic.us.kg, etc.)
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
    error_exit "Please DO NOT run this script as root. Run as normal user with sudo access."
fi

# Check sudo access
if ! sudo -n true 2>/dev/null; then
    log_warning "This script requires sudo access. You may be prompted for password."
fi

#############################################################################
# STEP 0: User Input Collection
#############################################################################

clear
echo "=========================================="
echo "  Multi-Service Deployment Setup"
echo "=========================================="
echo ""

log_info "Please provide the following information:"
echo ""

# Get domain name
read -p "Enter your domain name (e.g., rovira.qzz.io or myserver.duckdns.org): " DOMAIN_NAME
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
INSTALL_DIR="/srv"
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
# STEP 1: System Update
#############################################################################

log_info "Step 1/12: Updating system packages..."
sudo apt update -qq
sudo apt upgrade -y -qq
log_success "System updated"

#############################################################################
# STEP 2: Install Docker & Docker Compose
#############################################################################

log_info "Step 2/12: Installing Docker..."

if ! command -v docker &> /dev/null; then
    sudo apt install -y docker.io docker-compose-plugin
    sudo systemctl enable docker
    sudo systemctl start docker
    
    # Add user to docker group
    sudo usermod -aG docker $USER
    
    log_success "Docker installed"
    log_warning "You'll need to logout and login again after this script completes for Docker group to take effect"
else
    log_success "Docker already installed"
fi

# Verify Docker installation
if ! docker --version &> /dev/null; then
    error_exit "Docker installation failed"
fi

log_success "Docker version: $(docker --version)"

#############################################################################
# STEP 3: Install Cloudflared
#############################################################################

log_info "Step 3/12: Installing Cloudflare Tunnel (cloudflared)..."

if ! command -v cloudflared &> /dev/null; then
    cd /tmp
    curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
    sudo dpkg -i cloudflared.deb
    rm cloudflared.deb
    log_success "Cloudflared installed"
else
    log_success "Cloudflared already installed"
fi

log_success "Cloudflared version: $(cloudflared --version)"

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

@app.get("/info")
def info():
    return {
        "service": "API",
        "version": "1.0.0",
        "endpoints": ["/", "/health", "/info"]
    }
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

with col1:
    st.metric("Status", "Online", "✅")
    
with col2:
    st.metric("Service", "AI/ML")
    
with col3:
    st.metric("Version", "1.0.0")

st.divider()

st.subheader("Interactive Demo")
name = st.text_input("Enter your name:", placeholder="John Doe")

if name:
    st.success(f"👋 Hello, **{name}**! The AI service is ready.")
    
    if st.button("Generate Greeting"):
        st.balloons()
        st.write(f"🎉 Welcome to the AI-powered platform, {name}!")

st.divider()

with st.expander("System Information"):
    st.write(f"**Hostname:** {socket.gethostname()}")
    st.write(f"**Timestamp:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    st.write(f"**Domain:** $AI_DOMAIN")
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
        * { margin: 0; padding: 0; box-sizing: border-box; }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        
        .container {
            max-width: 900px;
            width: 100%;
        }
        
        .card {
            background: white;
            border-radius: 20px;
            padding: 40px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            animation: fadeIn 0.5s ease-in;
        }
        
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }
        
        h1 {
            color: #333;
            margin-bottom: 10px;
            font-size: 2.5em;
        }
        
        .subtitle {
            color: #666;
            margin-bottom: 30px;
            font-size: 1.1em;
        }
        
        .services {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin: 30px 0;
        }
        
        .service-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 30px;
            border-radius: 15px;
            color: white;
            text-decoration: none;
            transition: transform 0.3s ease, box-shadow 0.3s ease;
            display: block;
        }
        
        .service-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 10px 30px rgba(0,0,0,0.3);
        }
        
        .service-icon {
            font-size: 3em;
            margin-bottom: 10px;
        }
        
        .service-title {
            font-size: 1.5em;
            font-weight: bold;
            margin-bottom: 5px;
        }
        
        .service-desc {
            opacity: 0.9;
            font-size: 0.9em;
        }
        
        .status {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 10px;
            margin-top: 30px;
        }
        
        .status-item {
            display: flex;
            align-items: center;
            margin: 10px 0;
            color: #333;
        }
        
        .status-icon {
            color: #28a745;
            margin-right: 10px;
            font-size: 1.2em;
        }
        
        .footer {
            text-align: center;
            margin-top: 30px;
            color: #666;
            font-size: 0.9em;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="card">
            <h1>🚀 Multi-Service Platform</h1>
            <p class="subtitle">Your services are live on <strong>$MAIN_DOMAIN</strong></p>
            
            <div class="services">
                <a href="https://$API_DOMAIN" target="_blank" class="service-card">
                    <div class="service-icon">🔌</div>
                    <div class="service-title">API Service</div>
                    <div class="service-desc">RESTful API endpoint</div>
                </a>
                
                <a href="https://$AI_DOMAIN" target="_blank" class="service-card">
                    <div class="service-icon">🤖</div>
                    <div class="service-title">AI Service</div>
                    <div class="service-desc">AI/ML Dashboard</div>
                </a>
            </div>
            
            <div class="status">
                <h3 style="margin-bottom: 15px; color: #333;">System Status</h3>
                <div class="status-item">
                    <span class="status-icon">✅</span>
                    <span>All services online and secured with HTTPS</span>
                </div>
                <div class="status-item">
                    <span class="status-icon">✅</span>
                    <span>Cloudflare DDoS protection active</span>
                </div>
                <div class="status-item">
                    <span class="status-icon">✅</span>
                    <span>Zero exposed ports (Cloudflare Tunnel)</span>
                </div>
                <div class="status-item">
                    <span class="status-icon">✅</span>
                    <span>Reverse proxy configured</span>
                </div>
            </div>
            
            <div class="footer">
                <p>Powered by Docker + NGINX + Cloudflare Tunnel</p>
                <p>100% Free Setup • Enterprise-Grade Security</p>
            </div>
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

cat > $INSTALL_DIR/docker-compose.yml << EOF
version: "3.9"

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
    log_warning "Please authorize cloudflared in your browser"
    
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

#################
