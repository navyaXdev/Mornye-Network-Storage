# Mornye Network Storage — Custom Domain Setup Guide

Complete step-by-step instructions for mapping a custom domain or subdomain to your Mornye Network Storage instance via Cloudflare Zero-Trust Tunnel.

---

## 1. Prerequisites

Before binding a custom domain, ensure:
1. You own a domain name (e.g. `example.com`).
2. The domain is registered in Cloudflare and its DNS is actively managed by Cloudflare nameservers.
3. You have logged into Cloudflare on the Mornye host via:
   ```bash
   ./mornye.sh tunnel login
   ```
4. A named tunnel exists (e.g. `mornye-storage`):
   ```bash
   ./mornye.sh tunnel create mornye-storage
   ```

---

## 2. Binding Your Custom Domain

To route a domain or subdomain (e.g., `storage.example.com`) to Mornye WebDAV, execute:

```bash
./mornye.sh tunnel domain add storage.example.com
```

### What Happens Automatically:
1. **Domain Format Validation**: Validates that the input is a valid RFC 1035 fully qualified domain name (FQDN).
2. **Cloudflare DNS CNAME Provisioning**: Executes `cloudflared tunnel route dns <tunnel-uuid> <hostname>`. Cloudflare automatically creates a proxied CNAME record pointing your domain to `<tunnel-uuid>.cfargotunnel.com`.
3. **Ingress Configuration Synthesis**: Updates `config/cloudflared.yml` to insert the new hostname ingress rule:
   ```yaml
   ingress:
     - hostname: storage.example.com
       service: http://webdav:8000
     - service: http_status:404
   ```
4. **Daemon Reload**: Gracefully reloads the active tunnel daemon (`mornye-tunnel`) to apply the new route without downtime.

---

## 3. Disconnecting or Removing a Domain

If you need to unbind a custom domain or change your routing:

```bash
./mornye.sh tunnel domain remove
```

This procedure safely resets `config/cloudflared.yml` to internal loopback only and reloads the tunnel service.

---

## 4. End-to-End Verification

Verify that your custom domain is publicly routing and protected by authentication:

```bash
# Run automated CLI probe
./mornye.sh tunnel test
```

### Manual Verification with cURL:
```bash
# PROPFIND probe to public custom domain
curl -i -X PROPFIND -H "Depth: 0" https://storage.example.com/dav/
```
Expected output:
```http
HTTP/2 401 Unauthorized
WWW-Authenticate: Basic realm="Mornye WebDAV"
```
The HTTP 401 response confirms that Cloudflare TLS termination, DNS Anycast routing, and origin basic authentication are fully functional.

---

## 5. Connecting WebDAV Clients

Once your custom domain is active, configure your client applications using the credentials created in Mornye:

### Windows 10 / 11 File Explorer
1. Open **File Explorer** and select **This PC**.
2. Click **Add a network location** from the top ribbon.
3. Enter the URL:
   ```text
   https://storage.example.com/dav/
   ```
4. Enter your Mornye username and password.

### macOS Finder
1. In **Finder**, press `Command + K` (Connect to Server).
2. Enter the Server Address:
   ```text
   https://storage.example.com/dav/
   ```
3. Enter your Mornye credentials when prompted.

### Dedicated WebDAV Clients (Cyberduck, WinSCP, rclone)
- **Protocol**: WebDAV (HTTPS)
- **Server / Host**: `storage.example.com`
- **Port**: `443`
- **Path**: `/dav/`
- **Username / Password**: Your configured Mornye user credentials

