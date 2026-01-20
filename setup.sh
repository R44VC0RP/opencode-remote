#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}OpenCode Server Setup${NC}"
echo "================================"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo ./setup.sh)${NC}"
    exit 1
fi

# Check for config file
if [ ! -f "config.env" ]; then
    echo -e "${RED}config.env not found!${NC}"
    echo "Please copy config.example.env to config.env and fill in your values"
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

sudo -u $ACTUAL_USER tee $ACTUAL_HOME/.config/opencode/opencode.json > /dev/null << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "server": {
    "port": 4096,
    "hostname": "127.0.0.1"
  },
  "autoupdate": false
}
EOF

# Create env file with API key
sudo -u $ACTUAL_USER tee $ACTUAL_HOME/.config/opencode/.env > /dev/null << EOF
ZEN_API_KEY=$ZEN_API_KEY
EOF
chmod 600 $ACTUAL_HOME/.config/opencode/.env

echo ""
echo -e "${GREEN}Step 5: Configuring OAuth2 Proxy...${NC}"
mkdir -p /etc/oauth2-proxy

tee /etc/oauth2-proxy/oauth2-proxy.cfg > /dev/null << EOF
provider = "google"
client_id = "$GOOGLE_CLIENT_ID"
client_secret = "$GOOGLE_CLIENT_SECRET"
cookie_secret = "$COOKIE_SECRET"

authenticated_emails_file = "/etc/oauth2-proxy/allowed-emails.txt"

upstreams = ["http://127.0.0.1:4096"]
http_address = "127.0.0.1:4180"

cookie_secure = true
redirect_url = "https://$DOMAIN/oauth2/callback"

# Skip auth for static assets
skip_auth_routes = [
  "^/site\\.webmanifest$",
  "^/favicon\\.ico$",
  "^/robots\\.txt$"
]

# IMPORTANT: Increase timeout for LLM requests (5 minutes)
# Default is 30s which causes 502 errors on long AI responses
upstream_timeout = "300s"

# Flush SSE/streaming responses immediately (critical for real-time updates)
flush_interval = "100ms"

# Pass headers correctly
pass_host_header = true
real_client_ip_header = "X-Real-IP"
EOF

# Create allowed emails file
echo "$ALLOWED_EMAILS" | tr ',' '\n' > /etc/oauth2-proxy/allowed-emails.txt

chmod 600 /etc/oauth2-proxy/oauth2-proxy.cfg
chmod 600 /etc/oauth2-proxy/allowed-emails.txt

echo ""
echo -e "${GREEN}Step 6: Configuring nginx...${NC}"
tee /etc/nginx/sites-available/opencode > /dev/null << EOF
upstream opencode_backend {
    server 127.0.0.1:4180 max_fails=3 fail_timeout=30s;
    keepalive 32;
    keepalive_requests 100;
    keepalive_timeout 60s;
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    server_name $DOMAIN;

    # Increase max body size for large file uploads
    client_max_body_size 500M;
    client_body_buffer_size 128k;
    
    # Connection timeouts
    client_body_timeout 300s;
    client_header_timeout 60s;

    location / {
        proxy_pass http://opencode_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        
        # Extended timeouts for long-running AI operations (5 minutes)
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        send_timeout 300s;
        
        # Disable buffering for streaming responses
        proxy_buffering off;
        proxy_request_buffering off;
        
        # Buffer sizes for large responses
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }

    listen 80;
    listen [::]:80;
}
EOF

ln -sf /etc/nginx/sites-available/opencode /etc/nginx/sites-enabled/
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
echo -e "${GREEN}Step 8: Creating systemd services...${NC}"

tee /etc/systemd/system/opencode.service > /dev/null << EOF
[Unit]
Description=OpenCode AI Server
After=network.target

[Service]
Type=simple
User=$ACTUAL_USER
WorkingDirectory=$ACTUAL_HOME
EnvironmentFile=$ACTUAL_HOME/.config/opencode/.env
ExecStart=$ACTUAL_HOME/.opencode/bin/opencode web --port 4096 --hostname 127.0.0.1
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

tee /etc/systemd/system/oauth2-proxy.service > /dev/null << 'EOF'
[Unit]
Description=OAuth2 Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/oauth2-proxy --config=/etc/oauth2-proxy/oauth2-proxy.cfg
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo ""
echo -e "${GREEN}Step 9: Starting services...${NC}"
systemctl daemon-reload
systemctl enable opencode oauth2-proxy
systemctl start opencode oauth2-proxy

echo ""
echo -e "${GREEN}Step 10: Configuring firewall...${NC}"
ufw allow 22/tcp
ufw allow 443/tcp
ufw --force enable

echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Setup complete!${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
echo "Your OpenCode server is now running at:"
echo -e "  ${YELLOW}https://$DOMAIN${NC}"
echo ""
echo "Allowed users:"
cat /etc/oauth2-proxy/allowed-emails.txt | sed 's/^/  - /'
echo ""
echo "To check service status:"
echo "  sudo systemctl status opencode oauth2-proxy nginx"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u opencode -f"
echo "  sudo journalctl -u oauth2-proxy -f"
