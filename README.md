# OpenCode Server Setup with Google OAuth

This guide walks you through setting up an optimized OpenCode server with Google OAuth authentication on Ubuntu. The setup includes performance optimizations specifically for AI coding agents.

## Architecture

```
┌─────────────┐      HTTPS       ┌─────────────────────────────────────┐
│  Browser    │◄───────────────►│  Your Server                        │
│             │                  │  ┌───────────┐    ┌──────────────┐ │
└─────────────┘                  │  │  nginx    │───►│ OAuth2 Proxy │ │
                                 │  │  :443     │    │ :4180        │ │
                                 │  └───────────┘    └──────┬───────┘ │
                                 │                          │         │
                                 │                   ┌──────▼───────┐ │
                                 │                   │ OpenCode Web │ │
                                 │                   │ :4096        │ │
                                 │                   └──────────────┘ │
                                 └─────────────────────────────────────┘
```

## Performance Optimizations

This setup includes several optimizations for running AI coding agents:

- **HTTP/2**: Enabled for multiplexed connections and reduced latency
- **Streaming AI Responses**: Proxy buffering disabled for real-time streaming
- **Large Request Support**: 500MB maximum body size for large file uploads
- **Extended Timeouts**: 5-minute timeouts for long-running AI operations
- **gzip Compression**: 60-80% bandwidth reduction for text content
- **Permissive CSP**: Allows WASM modules for terminal support (ghostty-web)
- **Optimized Buffers**: 128k-256k buffers for handling large AI responses

## Prerequisites

- Ubuntu 24.x server with root access
- A domain name pointed to your server's IP
- Google Cloud Console account (for OAuth credentials)
- Your LLM API key (Anthropic, OpenAI, Zen, etc.)

## Quick Start

```bash
# Clone this repo
git clone https://github.com/yourusername/opencode-server-setup.git
cd opencode-server-setup

# Edit the config
nano config.env

# Run the setup script
chmod +x setup.sh
sudo ./setup.sh
```

## Manual Setup

### Step 1: Create Google OAuth Credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
2. Create a new project (or select existing)
3. Go to **APIs & Services** → **OAuth consent screen** → Configure
4. Go to **Credentials** → **Create Credentials** → **OAuth 2.0 Client ID**
5. Select **Web application**
6. Add authorized redirect URI: `https://YOUR_DOMAIN/oauth2/callback`
7. Save your **Client ID** and **Client Secret**

### Step 2: Install OpenCode

```bash
curl -fsSL https://opencode.ai/install | bash
```

Verify installation:
```bash
~/.opencode/bin/opencode --version
```

### Step 3: Install nginx

```bash
sudo apt update
sudo apt install -y nginx
sudo systemctl enable nginx
```

### Step 4: Install OAuth2 Proxy

```bash
cd /tmp
wget https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v7.6.0/oauth2-proxy-v7.6.0.linux-amd64.tar.gz
tar -xzf oauth2-proxy-v7.6.0.linux-amd64.tar.gz
sudo mv oauth2-proxy-v7.6.0.linux-amd64/oauth2-proxy /usr/local/bin/
rm -rf oauth2-proxy-v7.6.0.linux-amd64*
```

### Step 5: Configure OpenCode

```bash
mkdir -p ~/.config/opencode

# Create config file
cat > ~/.config/opencode/opencode.json << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "server": {
    "port": 4096,
    "hostname": "127.0.0.1"
  },
  "autoupdate": false
}
EOF

# Create environment file with your API key
cat > ~/.config/opencode/.env << 'EOF'
ZEN_API_KEY=your-api-key-here
EOF

chmod 600 ~/.config/opencode/.env
```

### Step 6: Configure OAuth2 Proxy

```bash
sudo mkdir -p /etc/oauth2-proxy

# Generate a cookie secret
COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '\n' | head -c 32)
echo "Cookie secret: $COOKIE_SECRET"

# Create config file (replace placeholders)
sudo tee /etc/oauth2-proxy/oauth2-proxy.cfg > /dev/null << EOF
provider = "google"
client_id = "YOUR_GOOGLE_CLIENT_ID"
client_secret = "YOUR_GOOGLE_CLIENT_SECRET"
cookie_secret = "$COOKIE_SECRET"

authenticated_emails_file = "/etc/oauth2-proxy/allowed-emails.txt"

upstreams = ["http://127.0.0.1:4096"]
http_address = "127.0.0.1:4180"

cookie_secure = true
redirect_url = "https://YOUR_DOMAIN/oauth2/callback"
EOF

# Create allowed emails list
sudo tee /etc/oauth2-proxy/allowed-emails.txt > /dev/null << EOF
your-email@gmail.com
EOF

sudo chmod 600 /etc/oauth2-proxy/oauth2-proxy.cfg
sudo chmod 600 /etc/oauth2-proxy/allowed-emails.txt
```

### Step 7: Configure nginx with Performance Optimizations

```bash
sudo tee /etc/nginx/sites-available/opencode > /dev/null << 'NGINX'
server {
    server_name YOUR_DOMAIN;

    # Enable HTTP/2
    http2 on;

    # Increase max body size for large file uploads and AI responses
    client_max_body_size 500M;
    
    # Optimize buffer sizes for large AI responses
    client_body_buffer_size 128k;
    
    location / {
        proxy_pass http://127.0.0.1:4180;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support with longer timeouts
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Extended timeouts for long-running AI operations
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        send_timeout 300s;
        
        # Disable proxy buffering for streaming AI responses
        proxy_buffering off;
        proxy_request_buffering off;
        
        # Increase buffer sizes
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        
        # Permissive CSP for WASM terminal
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self' 'unsafe-inline' 'unsafe-eval'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data:; style-src 'self' 'unsafe-inline' data:; img-src 'self' data: blob: https:; font-src 'self' data: blob:; connect-src 'self' data: blob: wss: ws: https: http:; worker-src 'self' blob: data:; child-src 'self' blob: data:; frame-src 'self' blob: data:; manifest-src 'self';" always;
    }

    # Enable gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject image/svg+xml application/manifest+json;
    gzip_disable "msie6";

    listen 80;
    listen [::]:80;
}
NGINX

sudo ln -sf /etc/nginx/sites-available/opencode /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### Step 8: Get SSL Certificate

```bash
# Temporarily allow port 80 for certificate verification
sudo ufw allow 80/tcp

sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d YOUR_DOMAIN

# Close port 80 after getting certificate
sudo ufw delete allow 80/tcp
```

### Step 9: Create systemd Services

```bash
# OpenCode service
sudo tee /etc/systemd/system/opencode.service > /dev/null << EOF
[Unit]
Description=OpenCode AI Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME
EnvironmentFile=$HOME/.config/opencode/.env
ExecStart=$HOME/.opencode/bin/opencode web --port 4096 --hostname 127.0.0.1
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# OAuth2 Proxy service
sudo tee /etc/systemd/system/oauth2-proxy.service > /dev/null << 'EOF'
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
```

### Step 10: Start Services

```bash
sudo systemctl daemon-reload
sudo systemctl enable opencode oauth2-proxy
sudo systemctl start opencode oauth2-proxy
```

### Step 11: Configure Firewall

```bash
sudo ufw allow 22/tcp   # SSH
sudo ufw allow 443/tcp  # HTTPS
sudo ufw --force enable
```

## Verification

1. Check service status:
   ```bash
   sudo systemctl status opencode oauth2-proxy nginx
   ```

2. Visit `https://YOUR_DOMAIN` in your browser
3. You should be redirected to Google login
4. After authentication, you'll see the OpenCode web UI

## Troubleshooting

### Check logs

```bash
# OpenCode logs
sudo journalctl -u opencode -f

# OAuth2 Proxy logs  
sudo journalctl -u oauth2-proxy -f

# nginx logs
sudo tail -f /var/log/nginx/error.log
```

### Common issues

**502 Bad Gateway**: OpenCode service not running
```bash
sudo systemctl restart opencode
```

**403 Forbidden after Google login**: Email not in allowed list
```bash
sudo nano /etc/oauth2-proxy/allowed-emails.txt
sudo systemctl restart oauth2-proxy
```

**SSL certificate issues**: Run certbot again
```bash
sudo ufw allow 80/tcp
sudo certbot --nginx -d YOUR_DOMAIN
sudo ufw delete allow 80/tcp
```

**CSP Errors**: The setup includes a permissive CSP policy for WASM support. If you see CSP errors, verify the nginx config includes the CSP headers.

## Adding More Users

Edit the allowed emails file:
```bash
sudo nano /etc/oauth2-proxy/allowed-emails.txt
```

Add one email per line, then restart:
```bash
sudo systemctl restart oauth2-proxy
```

## Updating OpenCode

```bash
curl -fsSL https://opencode.ai/install | bash
sudo systemctl restart opencode
```

## Performance Notes

### Streaming Responses
The setup disables proxy buffering to enable real-time streaming of AI responses. This provides a better user experience when interacting with the AI coding agent.

### Large File Support
The 500MB request size limit allows uploading and analyzing large codebases and files.

### Extended Timeouts
5-minute timeouts prevent disconnections during:
- Long-running code analysis
- Large file processing
- Complex refactoring operations
- Extended AI conversations

### Compression
gzip compression reduces bandwidth usage by 60-80% for text-based content (code, JSON, HTML).

## Security Notes

- OpenCode listens only on localhost (127.0.0.1)
- All external traffic goes through OAuth2 Proxy
- Only whitelisted Google accounts can access
- HTTPS is enforced via nginx + Let's Encrypt
- Only ports 22 (SSH) and 443 (HTTPS) are open
- The permissive CSP is required for WASM terminal support

## License

MIT
