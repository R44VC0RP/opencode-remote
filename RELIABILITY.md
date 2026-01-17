# Reliability & Preventative Measures

This document outlines the reliability features and preventative measures built into the OpenCode server setup.

## Automatic Service Recovery

### systemd Service Configuration

Both OpenCode and OAuth2 Proxy services are configured with automatic restart capabilities:

- **Restart Policy**: `Restart=always` - Services automatically restart on any failure
- **Restart Delay**: `RestartSec=10` - 10 second delay between restart attempts
- **Burst Limit**: `StartLimitBurst=5` - Allow up to 5 rapid restarts before giving up
- **No Rate Limiting**: `StartLimitIntervalSec=0` - Never give up trying to start

### Resource Limits

**OpenCode Service:**
- Max Memory: 2GB (prevents runaway memory usage)
- Max Open Files: 65536 (handles many concurrent connections)
- Watchdog: 60 seconds (automatic restart if unresponsive)

**OAuth2 Proxy:**
- Max Open Files: 65536

## Health Monitoring

### Automated Health Checks

A systemd timer runs health checks every 5 minutes to ensure services stay healthy.

**What it checks:**
1. OpenCode service is running
2. OAuth2 Proxy service is running  
3. OpenCode health endpoint responds
4. OAuth2 Proxy ping endpoint responds
5. Memory usage warnings

## nginx Error Prevention

### Upstream Configuration

- Marks backends as failed after 3 consecutive failures
- Waits 30 seconds before retrying failed backends
- Uses connection pooling with 32 keepalive connections

### Error Handling

- **Automatic Retry**: Retries failed requests automatically
- **Handled Errors**: 502, 503, 504, timeouts, invalid headers
- **Max Retries**: 2 attempts per request

## Security

### Note on Server Password

OpenCode does NOT use a server password in this setup. OAuth2 Proxy handles all authentication.

### Multi-Layer Authentication

1. **nginx**: SSL/TLS termination
2. **OAuth2 Proxy**: Google OAuth authentication
3. **OpenCode**: No additional auth (relies on OAuth2 Proxy)

## Common Issues & Prevention

### 502 Bad Gateway

**Prevention:**
- nginx upstream configuration retries failed requests
- Health check timer restarts failed services automatically
- systemd watchdog restarts unresponsive services

### WebSocket Disconnections

**Prevention:**
- 300 second read timeout for long-lived connections
- HTTP/1.1 upgrade header support
- Connection pooling reduces new connection overhead

## Monitoring Commands

```bash
# Check service status
sudo systemctl status opencode oauth2-proxy nginx

# View logs
sudo journalctl -u opencode -f
sudo journalctl -u oauth2-proxy -f
sudo tail -f /var/log/nginx/error.log
```
