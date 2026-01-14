#!/bin/bash
###############################################################################
# Minecraft Bedrock Server – Global Production Setup
# World-wide access + auto-update + backups
# 100% Free & Open Source
###############################################################################

set -euo pipefail

### ================= CONFIG ================= ###
MC_USER="mcbedrock"
MC_HOME="/home/$MC_USER"
INSTALL_DIR="/opt/minecraft_bedrock"
BACKUP_DIR="/opt/minecraft_backups"
SERVICE_NAME="bedrock"
UPDATE_SCRIPT="/usr/local/bin/bedrock-update.sh"
BACKUP_SCRIPT="/usr/local/bin/bedrock-backup.sh"

VERSION="1.21.132.3"
DOWNLOAD_URL="https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-${VERSION}.zip"

CLOUDFLARED_REPO="https://pkg.cloudflare.com"
TUNNEL_NAME="mc-bedrock"
DOMAIN_NOTE="(You will map a domain after login)"

### =============== ROOT CHECK =============== ###
if [[ $EUID -ne 0 ]]; then
  echo "❌ Run as root (sudo)"
  exit 1
fi

echo "🚀 Starting Minecraft Bedrock Global Setup"

### ============ DEPENDENCIES ================ ###
apt-get update -qq
apt-get install -y \
  curl wget unzip ufw ca-certificates \
  systemd cron tar grep

### ============== USER ====================== ###
if ! id "$MC_USER" &>/dev/null; then
  useradd --system --create-home --home-dir "$MC_HOME" \
          --shell /usr/sbin/nologin "$MC_USER"
fi

### ============ DIRECTORIES ================= ###
mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"
chown -R "$MC_USER:$MC_USER" "$INSTALL_DIR" "$BACKUP_DIR"

### ============ BEDROCK INSTALL ============= ###
cd "$INSTALL_DIR"
sudo -u "$MC_USER" wget -q --show-progress -O server.zip "$DOWNLOAD_URL"
sudo -u "$MC_USER" unzip -oq server.zip
rm -f server.zip
chmod +x "$INSTALL_DIR/bedrock_server"
chown -R "$MC_USER:$MC_USER" "$INSTALL_DIR"

### ============ SYSTEMD SERVICE ============== ###
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Minecraft Bedrock Server
After=network-online.target
Wants=network-online.target

[Service]
User=$MC_USER
Group=$MC_USER
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

chmod 644 /etc/systemd/system/${SERVICE_NAME}.service
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}

### ============ FIREWALL (SAFE) ============== ###
if ufw status | grep -q "Status: active"; then
  ufw allow 19132/udp
fi

### ============ CLOUDFLARED ================= ###
if ! command -v cloudflared &>/dev/null; then
  curl -fsSL $CLOUDFLARED_REPO/cloudflare-main.gpg \
    | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
$CLOUDFLARED_REPO $(lsb_release -cs) main" \
    | tee /etc/apt/sources.list.d/cloudflare.list

  apt-get update -qq
  apt-get install -y cloudflared
fi

echo "🔐 Cloudflare login required (browser will open)"
cloudflared tunnel login

echo "🚇 Creating tunnel: $TUNNEL_NAME"
cloudflared tunnel create "$TUNNEL_NAME"

mkdir -p "$MC_HOME/.cloudflared"
mv ~/.cloudflared/*.json "$MC_HOME/.cloudflared/"
chown -R "$MC_USER:$MC_USER" "$MC_HOME/.cloudflared"

cat > "$MC_HOME/.cloudflared/config.yml" <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $MC_HOME/.cloudflared/$(ls $MC_HOME/.cloudflared | grep json)

ingress:
  - service: udp://localhost:19132
  - service: http_status:404
EOF

chown "$MC_USER:$MC_USER" "$MC_HOME/.cloudflared/config.yml"

cloudflared service install
systemctl enable --now cloudflared

### ============ AUTO UPDATE ================== ###
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
set -e

INSTALL_DIR="/opt/minecraft_bedrock"
BACKUP_DIR="/opt/minecraft_backups"
SERVICE="bedrock"

LATEST_URL=$(curl -s https://www.minecraft.net/en-us/download/server/bedrock \
 | grep -o 'https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-[0-9.]*\.zip' \
 | head -1)

[[ -z "$LATEST_URL" ]] && exit 0

VERSION=$(basename "$LATEST_URL")

if [[ -f "$INSTALL_DIR/.version" ]] && grep -q "$VERSION" "$INSTALL_DIR/.version"; then
  exit 0
fi

systemctl stop $SERVICE
tar -czf "$BACKUP_DIR/preupdate-$(date +%F).tar.gz" -C "$INSTALL_DIR" worlds

wget -q -O /tmp/server.zip "$LATEST_URL"
unzip -oq /tmp/server.zip -d "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/bedrock_server"

echo "$VERSION" > "$INSTALL_DIR/.version"
systemctl start $SERVICE
EOF

chmod +x "$UPDATE_SCRIPT"

### ============ BACKUPS ====================== ###
cat > "$BACKUP_SCRIPT" <<'EOF'
#!/bin/bash
set -e

SRC="/opt/minecraft_bedrock/worlds"
DEST="/opt/minecraft_backups"
DATE=$(date +%F)

tar -czf "$DEST/worlds-$DATE.tar.gz" -C "$SRC" .
find "$DEST" -type f -mtime +30 -delete
EOF

chmod +x "$BACKUP_SCRIPT"

### ============ CRON JOBS ==================== ###
crontab -l 2>/dev/null | grep -v bedrock-update | grep -v bedrock-backup > /tmp/cron.tmp || true
echo "0 4 * * * $UPDATE_SCRIPT" >> /tmp/cron.tmp
echo "0 3 * * 0 $BACKUP_SCRIPT" >> /tmp/cron.tmp
crontab /tmp/cron.tmp
rm -f /tmp/cron.tmp

### ============ DONE ========================= ###
echo "====================================================="
echo "✅ Minecraft Bedrock Global Setup COMPLETE"
echo "====================================================="
echo "🌍 World-wide access via Cloudflare Tunnel"
echo "🔄 Auto-update: Daily @ 04:00"
echo "💾 Backups: Weekly (30-day retention)"
echo "🎮 Server Port: 19132 (UDP)"
echo "📁 Server Dir: $INSTALL_DIR"
echo "====================================================="
