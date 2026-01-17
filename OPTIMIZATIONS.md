# OpenCode Server Performance Optimizations

Applied on: 2026-01-17

## Issues Fixed

### 1. Content Security Policy (CSP) Errors
**Problem**: ghostty-web WASM terminal was blocked by strict CSP policy
**Solution**: Added permissive CSP headers allowing data: and blob: URIs for WASM

### 2. Request Body Size Limit
**Problem**: nginx rejecting requests >1MB ("client intended to send too large body")
**Solution**: Increased to 500MB for large file uploads and AI responses

### 3. Duplicate nginx Configuration
**Problem**: Conflicting server configs causing warnings
**Solution**: Removed duplicate `opencode` symlink

## Performance Optimizations Applied

### nginx Configuration (/etc/nginx/sites-available/open.ryan.ceo)

#### HTTP/2 Protocol
- **Enabled HTTP/2** for multiplexing and faster concurrent requests
- Reduces latency for multiple resource requests

#### Request Handling
- `client_max_body_size 500M` - Support large file uploads and responses
- `client_body_buffer_size 128k` - Optimized buffer for large AI responses

#### Proxy Configuration
- `proxy_buffering off` - **Disabled buffering for real-time AI streaming**
- `proxy_request_buffering off` - Allows streaming of large requests
- `proxy_buffer_size 128k` - Increased for large response headers
- `proxy_buffers 4 256k` - 4x 256KB buffers for response body
- `proxy_busy_buffers_size 256k` - Optimized busy buffer size

#### Timeout Settings (Extended for Long AI Operations)
- `proxy_connect_timeout 300s` - 5 minutes to establish connection
- `proxy_send_timeout 300s` - 5 minutes to send request
- `proxy_read_timeout 300s` - 5 minutes to read response
- `send_timeout 300s` - 5 minutes for client to accept response

#### Compression (gzip)
- **Enabled gzip compression** for text-based resources
- `gzip_comp_level 6` - Balanced compression (6/9)
- Compresses: JSON, JavaScript, CSS, HTML, fonts, SVG
- **Reduces bandwidth usage by ~60-80%** for text content

#### Content Security Policy
- Allows `data:` and `blob:` for WASM modules
- Permits `unsafe-eval` for WASM execution
- Supports WebSocket connections (wss:, ws:)

### OpenCode Configuration (~/.config/opencode/opencode.json)
- `autoupdate: false` - Prevents automatic updates during sessions
- Listens on 127.0.0.1:4096 (localhost only, secured by OAuth2 Proxy)

## Performance Benefits

1. **Streaming AI Responses**: Disabled buffering enables real-time streaming
2. **Large File Support**: 500MB limit supports uploading/analyzing large codebases
3. **Extended Timeouts**: 5-minute timeouts prevent premature disconnections during long operations
4. **HTTP/2**: Multiplexing reduces latency for concurrent requests
5. **Compression**: gzip reduces bandwidth by 60-80% for text resources
6. **WebSocket Optimization**: Extended read timeout (300s) for long-lived connections

## Monitoring Commands

Check service status:
```bash
sudo systemctl status opencode oauth2-proxy nginx
```

View logs:
```bash
# OpenCode logs
sudo journalctl -u opencode -f

# OAuth2 Proxy logs
sudo journalctl -u oauth2-proxy -f

# nginx error logs
sudo tail -f /var/log/nginx/error.log

# nginx access logs
sudo tail -f /var/log/nginx/access.log
```

Test nginx config:
```bash
sudo nginx -t
```

Reload nginx after changes:
```bash
sudo systemctl reload nginx
```

## Next Steps (Optional)

### 1. Rate Limiting (if needed)
Add to nginx config to prevent abuse:
```nginx
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
location / {
    limit_req zone=api burst=20 nodelay;
    ...
}
```

### 2. Caching Static Assets
If OpenCode serves static files:
```nginx
location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
}
```

### 3. Connection Pooling
Already optimized via HTTP/2 keep-alive

### 4. Monitoring
Consider adding:
- Prometheus + Grafana for metrics
- nginx status module for real-time stats
- Log aggregation (ELK stack or Loki)

## Configuration Files

- nginx: `/etc/nginx/sites-available/open.ryan.ceo`
- OpenCode: `~/.config/opencode/opencode.json`
- OAuth2 Proxy: `/etc/oauth2-proxy/oauth2-proxy.cfg`
- systemd services: `/etc/systemd/system/{opencode,oauth2-proxy}.service`
