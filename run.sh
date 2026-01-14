#!/bin/bash

# =============================================================================
# Minecraft Bedrock Server Auto-Installer for Ubuntu
# =============================================================================
# Features:
# 1. Installs dependencies (curl, wget, unzip, libcurl4)
# 2. Creates a dedicated user 'mcbedrock' for security
# 3. Scrapes the official website for the latest version URL
# 4. Downloads and installs the server to /opt/minecraft_bedrock
# 5. Configures UFW firewall
# 6. Creates a Systemd service for auto-start on reboot
# =============================================================================

set -e # Exit on error

# Variables
USER_NAME="mcbedrock"
INSTALL_DIR="/opt/minecraft_bedrock"
SERVICE_FILE="/etc/systemd/system/bedrock.service"
BACKUP_DIR="/opt/minecraft_backups"

echo ">>> Starting Minecraft Bedrock Server Installation..."

# 1. Update and Install Dependencies
echo ">>> Updating system and installing dependencies..."
apt-get update -q
apt-get install -y unzip wget curl libcurl4 ufw grep

# 2. Create Dedicated User
if id "$USER_NAME" &>/dev/null; then
    echo ">>> User '$USER_NAME' already exists. Skipping user creation."
else
    echo ">>> Creating dedicated user '$USER_NAME'..."
    useradd -r -m -d $INSTALL_DIR -s /bin/bash $USER_NAME
fi

# 3. Create Directories
echo ">>> Setting up directories..."
mkdir -p $INSTALL_DIR
mkdir -p $BACKUP_DIR
chown $USER_NAME:$USER_NAME $BACKUP_DIR

# 4. Fetch Latest Download URL
echo ">>> Finding latest Bedrock Server version..."
# We scrape the official page for the linux zip link.
# Note: This relies on the specific HTML structure of the download page.
DOWNLOAD_URL=$(curl -L -s -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" https://www.minecraft.net/en-us/download/server/bedrock | grep -o 'https://minecraft.azureedge.net/bin-linux/bedrock-server-[0-9.]*\.zip' | head -1)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "!!! Error: Could not automatically detect the download URL."
    echo "!!! Please download the zip manually from minecraft.net and place it in $INSTALL_DIR."
    exit 1
else
    echo ">>> Found version: $DOWNLOAD_URL"
fi

# 5. Download and Install
echo ">>> Downloading server files..."
cd $INSTALL_DIR
# Run as the mcbedrock user to keep permissions clean
sudo -u $USER_NAME wget -O server.zip "$DOWNLOAD_URL"

echo ">>> Unzipping..."
sudo -u $USER_NAME unzip -o server.zip
sudo -u $USER_NAME rm server.zip

# 6. Configure Firewall
echo ">>> Configuring Firewall (UFW)..."
ufw allow 19132/udp
echo ">>> Port 19132/UDP allowed."

# 7. Create Systemd Service
echo ">>> Creating Systemd Service at $SERVICE_FILE..."

cat <<EOF > $SERVICE_FILE
[Unit]
Description=Minecraft Bedrock Server
After=network.target

[Service]
User=$USER_NAME
Group=$USER_NAME
WorkingDirectory=$INSTALL_DIR
# LD_LIBRARY_PATH is required for Bedrock to find its libraries
Environment="LD_LIBRARY_PATH=$INSTALL_DIR"
# ExecStart runs the server
ExecStart=$INSTALL_DIR/bedrock_server
# Restart automatically if it crashes
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 8. Start the Server
echo ">>> Reloading daemon and starting server..."
systemctl daemon-reload
systemctl enable bedrock.service
systemctl start bedrock.service

echo "========================================================="
echo "   INSTALLATION COMPLETE!"
echo "========================================================="
echo "1. Service Status:  sudo systemctl status bedrock"
echo "2. View Logs:       sudo journalctl -u bedrock -f"
echo "3. Stop Server:     sudo systemctl stop bedrock"
echo "4. Start Server:    sudo systemctl start bedrock"
echo "5. Config File:     $INSTALL_DIR/server.properties"
echo ""
echo "Your server should now be reachable on Port 19132."
echo "========================================================="
