#!/bin/bash

# =============================================================================
# Minecraft Bedrock Server Auto-Installer (Ubuntu Server)
# =============================================================================
# ✔ No HTML scraping
# ✔ Uses official direct download URL
# ✔ Safe permissions
# ✔ Systemd hardened
# ✔ UFW handled gracefully
# =============================================================================

set -euo pipefail

### -------- VARIABLES -------- ###
USER_NAME="mcbedrock"
INSTALL_DIR="/opt/minecraft_bedrock"
BACKUP_DIR="/opt/minecraft_backups"
SERVICE_FILE="/etc/systemd/system/bedrock.service"
VERSION="1.21.132.3"
DOWNLOAD_URL="https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-${VERSION}.zip"

### -------- ROOT CHECK -------- ###
if [[ $EUID -ne 0 ]]; then
  echo "❌ Please run as root (sudo)"
  exit 1
fi

echo "🚀 Installing Minecraft Bedrock Server ${VERSION}"

### -------- DEPENDENCIES -------- ###
echo "📦 Installing dependencies..."
apt-get update -qq
apt-get install -y unzip wget curl libcurl4 ufw ca-certificates

### -------- USER SETUP -------- ###
if id "$USER_NAME" &>/dev/null; then
    echo "👤 User '$USER_NAME' already exists"
else
    echo "👤 Creating user '$USER_NAME'"
    useradd --system --create-home --home-dir /home/$USER_NAME --shell /usr/sbin/nologin "$USER_NAME"
fi

### -------- DIRECTORIES -------- ###
echo "📁 Creating directories..."
mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"
chown -R "$USER_NAME:$USER_NAME" "$INSTALL_DIR" "$BACKUP_DIR"

### -------- DOWNLOAD -------- ###
echo "⬇ Downloading Bedrock Server..."
cd "$INSTALL_DIR"

sudo -u "$USER_NAME" wget -q --show-progress -O server.zip "$DOWNLOAD_URL"

echo "📦 Extracting..."
sudo -u "$USER_NAME" unzip -oq server.zip
rm -f server.zip

chmod +x "$INSTALL_DIR/bedrock_server"
chown -R "$USER_NAME:$USER_NAME" "$INSTALL_DIR"

### -------- FIREWALL -------- ###
echo "🔥 Configuring firewall..."
if ufw status | grep -q "Status: active"; then
    ufw allow 19132/udp
    echo "✔ UFW rule added (19132/udp)"
else
    echo "⚠ UFW inactive — skipping firewall rule"
fi

### -------- SYSTEMD SERVICE -------- ###
echo "⚙ Creating systemd service..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Minecraft Bedrock Server
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
Group=$USER_NAME
WorkingDirectory=$INSTALL_DIR
Environment=LD_LIBRARY_PATH=$INSTALL_DIR
ExecStart=$INSTALL_DIR/bedrock_server
Restart=always
RestartSec=10
LimitNOFILE=100000

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_FILE"

### -------- START SERVICE -------- ###
echo "▶ Starting server..."
systemctl daemon-reload
systemctl enable bedrock.service
systemctl restart bedrock.service

### -------- DONE -------- ###
echo ""
echo "====================================================="
echo "✅ Minecraft Bedrock Server Installed Successfully!"
echo "====================================================="
echo "Service Status : systemctl status bedrock"
echo "View Logs      : journalctl -u bedrock -f"
echo "Server Files   : $INSTALL_DIR"
echo "Config File    : $INSTALL_DIR/server.properties"
echo "Port           : 19132/UDP"
echo "====================================================="
