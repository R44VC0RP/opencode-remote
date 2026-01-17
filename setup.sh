#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}OpenCode Server Setup with Performance Optimizations${NC}"
echo "===================================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo ./setup.sh)${NC}"
    exit 1
fi

# Check for config file
if [ ! -f "config.env" ]; then
    echo -e "${RED}config.env not found!${NC}"
    echo "Please create config.env and fill in your values"
    exit 1
fi

# Load config
source config.env

# Validate required variables
if [ -z "$DOMAIN" ] || [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ] || [ -z "$ALLOWED_EMAILS" ]; then
    echo -e "${RED}Missing required configuration!${NC}"
    echo "Please fill in all required values in config.env"
    exit 1
fi

# Get the actual user (not root)
ACTUAL_USER=${SUDO_USER:-$USER}
ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)

echo -e "${YELLOW}Installing for user: $ACTUAL_USER${NC}"
echo -e "${YELLOW}Home directory: $ACTUAL_HOME${NC}"

# Generate secrets
COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '\n' | head -c 32)

echo ""
echo -e "${GREEN}Step 1: Installing OpenCode...${NC}"
sudo -u $ACTUAL_USER bash -c 'curl -fsSL https://opencode.ai/install | bash'

echo ""
echo -e "${GREEN}Step 2: Installing nginx...${NC}"
apt update
apt install -y nginx
systemctl enable nginx

echo ""
echo -e "${GREEN}Step 3: Installing OAuth2 Proxy...${NC}"
cd /tmp
wget -q https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v7.6.0/oauth2-proxy-v7.6.0.linux-amd64.tar.gz
tar -xzf oauth2-proxy-v7.6.0.linux-amd64.tar.gz
mv oauth2-proxy-v7.6.0.linux-amd64/oauth2-proxy /usr/local/bin/
rm -rf oauth2-proxy-v7.6.0.linux-amd64*
cd - > /dev/null

echo ""
echo -e "${GREEN}Step 4: Configuring OpenCode...${NC}"
sudo -u $ACTUAL_USER mkdir -p $ACTUAL_HOME/.config/opencode

sudo -u $ACTUAL_USER tee $ACTUAL_HOME/.config/opencode/opencode.json > /dev/null << 'EOFCONFIG'
{
  "$schema": "https://opencode.ai/config.json",
  "server": {
    "port": 4096,
    "hostname": "127.0.0.1"
  },
  "autoupdate": false
}
EOFCONFIG

# Create env file with API key (no password - OAuth2 Proxy handles auth)
sudo -u $ACTUAL_USER tee $ACTUAL_HOME/.config/opencode/.env > /dev/null << EOFENV
ZEN_API_KEY=$ZEN_API_KEY
EOFENV
chmod 600 $ACTUAL_HOME/.config/opencode/.env

echo ""
echo -e "${GREEN}Step 5: Configuring OAuth2 Proxy...${NC}"
mkdir -p /etc/oauth2-proxy

tee /etc/oauth2-proxy/oauth2-proxy.cfg > /dev/null << EOFOAUTH
provider = "google"
client_id = "$GOOGLE_CLIENT_ID"
client_secret = "$GOOGLE_CLIENT_SECRET"
cookie_secret = "$COOKIE_SECRET"

authenticated_emails_file = "/etc/oauth2-proxy/allowed-emails.txt"

upstreams = ["http://127.0.0.1:4096"]
http_address = "127.0.0.1:4180"

cookie_secure = true
redirect_url = "https://$DOMAIN/oauth2/callback"
EOFOAUTH

# Create allowed emails file
echo "$ALLOWED_EMAILS" | tr ',' '\n' > /etc/oauth2-proxy/allowed-emails.txt

chmod 600 /etc/oauth2-proxy/oauth2-proxy.cfg
chmod 600 /etc/oauth2-proxy/allowed-emails.txt

echo ""
echo -e "${GREEN}Step 6: Configuring nginx with performance optimizations...${NC}"

# Create nginx config with WebSocket map at http level
tee /etc/nginx/conf.d/websocket-upgrade.conf > /dev/null << 'EOFMAP'
# WebSocket upgrade map
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOFMAP

tee /etc/nginx/sites-available/$DOMAIN > /dev/null << 'EOFNGINX'
upstream opencode_backend {
    server 127.0.0.1:4180 max_fails=3 fail_timeout=30s;
    keepalive 32;
    keepalive_requests 100;
    keepalive_timeout 60s;
}

server {
    server_name DOMAIN_PLACEHOLDER;

    # Enable HTTP/2
    http2 on;

    # Increase max body size for large file uploads and AI responses
    client_max_body_size 500M;
    
    # Optimize buffer sizes for large AI responses
    client_body_buffer_size 128k;
    
    # Connection timeouts
    client_body_timeout 300s;
    client_header_timeout 60s;
    
    location / {
        proxy_pass http://opencode_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support with HTTP/1.1
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        
        # Extended timeouts for long-running AI operations
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        send_timeout 300s;
        
        # Disable proxy buffering for streaming AI responses
        proxy_buffering off;
        proxy_request_buffering off;
        
        # Increase buffer sizes for large responses
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        
        # Prevent 502 errors on backend restart
        proxy_next_upstream error timeout invalid_header http_502 http_503 http_504;
        proxy_next_upstream_tries 2;
        
        # Permissive CSP for web coding agent with WASM terminal
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self' 'unsafe-inline' 'unsafe-eval'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data:; style-src 'self' 'unsafe-inline' data:; img-src 'self' data: blob: https:; font-src 'self' data: blob:; connect-src 'self' data: blob: wss: ws: https: http:; worker-src 'self' blob: data:; child-src 'self' blob: data:; frame-src 'self' blob: data:; manifest-src 'self';" always;
    }

    # Enable gzip compression for faster transfers
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject image/svg+xml application/manifest+json;
    gzip_disable "msie6";

    listen 80;
    listen [::]:80;
}
EOFNGINX

# Replace placeholder with actual domain
sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" /etc/nginx/sites-available/$DOMAIN

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

echo ""
echo -e "${GREEN}Step 7: Getting SSL certificate...${NC}"
apt install -y certbot python3-certbot-nginx

# Temporarily allow port 80
ufw allow 80/tcp || true

certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $(echo $ALLOWED_EMAILS | cut -d',' -f1)

# Close port 80
ufw delete allow 80/tcp || true

echo ""
echo -e "${GREEN}Step 8: Creating systemd services with reliability features...${NC}"

tee /etc/systemd/system/opencode.service > /dev/null << EOFSERVICE
[Unit]
Description=OpenCode AI Server
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$ACTUAL_USER
WorkingDirectory=$ACTUAL_HOME
EnvironmentFile=$ACTUAL_HOME/.config/opencode/.env
ExecStart=$ACTUAL_HOME/.opencode/bin/opencode web --port 4096 --hostname 127.0.0.1

# Restart configuration for reliability
Restart=always
RestartSec=10
StartLimitBurst=5

# Resource limits
LimitNOFILE=65536
MemoryMax=2G

# Watchdog - restart if service becomes unresponsive
WatchdogSec=60

[Install]
WantedBy=multi-user.target
EOFSERVICE

tee /etc/systemd/system/oauth2-proxy.service > /dev/null << 'EOFPROXY'
[Unit]
Description=OAuth2 Proxy
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/oauth2-proxy --config=/etc/oauth2-proxy/oauth2-proxy.cfg

# Restart configuration for reliability
Restart=always
RestartSec=10
StartLimitBurst=5

# Resource limits
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOFPROXY

echo ""
echo -e "${GREEN}Step 9: Creating health check monitoring...${NC}"

tee /usr/local/bin/opencode-health-check.sh > /dev/null << 'EOFHEALTH'
#!/bin/bash

# Health check script for OpenCode server
LOG_FILE="/var/log/opencode-health.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check OpenCode service
if ! systemctl is-active --quiet opencode; then
    log "ERROR: OpenCode service is not running. Restarting..."
    systemctl restart opencode
fi

# Check OAuth2 Proxy service
if ! systemctl is-active --quiet oauth2-proxy; then
    log "ERROR: OAuth2 Proxy service is not running. Restarting..."
    systemctl restart oauth2-proxy
fi

# Check if OpenCode is responding
if ! curl -f -s http://127.0.0.1:4096/global/health > /dev/null 2>&1; then
    log "WARNING: OpenCode health endpoint not responding"
fi

# Check if OAuth2 Proxy is responding
if ! curl -f -s http://127.0.0.1:4180/ping > /dev/null 2>&1; then
    log "WARNING: OAuth2 Proxy not responding"
fi

log "Health check completed"
EOFHEALTH

chmod +x /usr/local/bin/opencode-health-check.sh

# Create health check timer
tee /etc/systemd/system/opencode-health.service > /dev/null << 'EOFHEALTHSVC'
[Unit]
Description=OpenCode Health Check
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/opencode-health-check.sh
EOFHEALTHSVC

tee /etc/systemd/system/opencode-health.timer > /dev/null << 'EOFHEALTHTIMER'
[Unit]
Description=OpenCode Health Check Timer
Requires=opencode-health.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=opencode-health.service

[Install]
WantedBy=timers.target
EOFHEALTHTIMER

echo ""
echo -e "${GREEN}Step 10: Starting services...${NC}"
systemctl daemon-reload
systemctl enable opencode oauth2-proxy opencode-health.timer
systemctl start opencode oauth2-proxy opencode-health.timer

echo ""
echo -e "${GREEN}Step 11: Configuring firewall...${NC}"
ufw allow 22/tcp
ufw allow 443/tcp
ufw --force enable

echo ""
echo -e "${GREEN}===================================================="
echo -e "Setup complete!${NC}"
echo -e "${GREEN}===================================================="
echo ""
echo "Your OpenCode server is now running at:"
echo -e "  ${YELLOW}https://$DOMAIN${NC}"
echo ""
echo "Performance optimizations applied:"
echo "  - HTTP/2 enabled for faster connections"
echo "  - 500MB max request size for large files"
echo "  - Streaming AI responses (no buffering)"
echo "  - 5-minute timeouts for long operations"
echo "  - gzip compression (60-80% bandwidth savings)"
echo "  - Permissive CSP for WASM terminal support"
echo ""
echo "Reliability features enabled:"
echo "  - Automatic service restart on failure"
echo "  - Health monitoring every 5 minutes"
echo "  - nginx upstream with error retry"
echo "  - Connection pooling to prevent 502 errors"
echo "  - Resource limits (2GB memory, 65k files)"
echo "  - Watchdog for automatic restart on hang"
echo "  - OAuth2 authentication via Google"
echo ""
echo "Allowed users:"
cat /etc/oauth2-proxy/allowed-emails.txt | sed 's/^/  - /'
echo ""
echo "Useful commands:"
echo "  sudo systemctl status opencode oauth2-proxy nginx"
echo "  sudo journalctl -u opencode -f"
echo "  sudo tail -f /var/log/opencode-health.log"
