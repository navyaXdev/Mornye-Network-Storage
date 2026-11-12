# Mornye Network Storage — Cloudflare Custom Subdomain Integration

## Overview

Mornye Network Storage features an automated Zero-Trust ingress subsystem powered by Cloudflare Tunnel. When exposing your private WebDAV storage to the internet using your own domain, Mornye automatically creates, configures, and routes a dedicated subdomain:

$$\text{mornye}.\langle\text{root-domain}\rangle$$

### Examples

| User Input (Root Domain) | Generated Subdomain | Public Storage URL |
| :--- | :--- | :--- |
| `example.com` | `mornye.example.com` | `https://mornye.example.com/dav/` |
| `mydomain.in` | `mornye.mydomain.in` | `https://mornye.mydomain.in/dav/` |
| `example.org` | `mornye.example.org` | `https://mornye.example.org/dav/` |
| `navya.dev` | `mornye.navya.dev` | `https://mornye.navya.dev/dav/` |

The operator only provides the root domain; Mornye automatically handles subdomain synthesis, RFC 1123 normalization, DNS CNAME provisioning, origin request TLS settings, and WAN endpoint verification.

---

## Architecture & Security Model

```
               [ Internet User / Mobile Device ]
                              │
                      HTTPS / Port 443
               (Edge TLS provisioned by Cloudflare)
                              ▼
            ┌───────────────────────────────────┐
            │   Cloudflare Global Edge Network  │
            │   DNS: mornye.<root-domain> CNAME │
            │   Target: <tunnel-id>.cfargotunnel│
            └─────────────────┬─────────────────┘
                              │
                Encrypted Zero-Trust Tunnel
                (Outbound QUIC / HTTP/2 to Edge)
                              │
                              ▼
                   [ Host Container Stack ]
            ┌───────────────────────────────────┐
            │   mornye-tunnel (cloudflared)     │
            │   Config: /etc/cloudflared/       │
            │   Credentials: credentials.json   │
            └─────────────────┬─────────────────┘
                              │
                    Docker Network: mornye-net
                    http://webdav:8000
                              │
                              ▼
            ┌───────────────────────────────────┐
            │   mornye-webdav (ASGI Engine)     │
            │   - HTTP Basic Auth (Argon2id)    │
            │   - RFC 4918 WebDAV Storage       │
            │   - Host Port 8001 (Isolated)     │
            └───────────────────────────────────┘
```

### Security & Isolation Invariants
1. **Origin Port Security**: Ingress routes exclusively map `mornye.<root-domain>` to `http://webdav:8000` inside the internal Docker bridge network (`mornye-net`).
2. **Zero Port Forwarding**: No inbound ports (80 or 443) require opening on your home or router firewall.
3. **Protected Coexistence**: Unrelated host services (`mornye-storage.service` on 8000, `mornye-tunnel.service` on 20241, Navidrome on 4533) are never stopped, restarted, or modified.
4. **Credential Isolation**: Tunnel credentials (`config/credentials.json`) are separated from Cloudflare account origin certificates (`cert.pem`).
5. **Argon2id Authentication Boundary**: Public WAN endpoints are strictly protected by WebDAV Basic Authentication before access to filesystem data is granted.

---

## Cloudflare Prerequisites

Before configuring a custom domain in Mornye, ensure:
1. **Cloudflare Account**: An active Cloudflare account at [dash.cloudflare.com](https://dash.cloudflare.com).
2. **Zone Added**: Your root domain (e.g., `example.com`) is active in Cloudflare and using Cloudflare nameservers.
3. **Origin Certificate (`cert.pem`)**: Created by running `./mornye.sh tunnel login` or `cloudflared tunnel login`. The certificate is searched across:
   - User home: `~/.cloudflared/cert.pem`
   - Explicit CLI flag: `--cert /path/to/cert.pem`
   - Environment variable: `CLOUDFLARE_CERT_PATH=/path/to/cert.pem`
   - Sudo / root home: `/root/.cloudflared/cert.pem`
   - System store: `/etc/cloudflared/cert.pem`
   - Mornye configuration: `config/cert.pem`

---

## Installation & Configuration

### Interactive Setup Wizard
During setup, select Option 2 when prompted for the networking mode:
```text
Select how you would like to expose Mornye Network Storage:
  1) Local-Only Mode (Private LAN / Localhost: http://127.0.0.1:8001/dav/)
  2) Permanent Cloudflare Tunnel + Custom Domain (e.g. storage.example.com)
  3) Ephemeral Quick Tunnel (Temporary trycloudflare.com testing link)

Enter choice [1-3] (Default: 1): 2

Enter your Root Domain (e.g. example.com): example.com
[✔] Root Domain: example.com
[✔] Generated Subdomain: mornye.example.com
```

### Configuration Progress Banner
During tunnel and DNS setup, Mornye prints the following progress:
```text
========================================
       Mornye Network Storage
========================================

Cloudflare Domain Configuration

Root Domain: example.com
Generated Subdomain: mornye.example.com

Configuring Cloudflare Tunnel...
Creating DNS Record...
Configuring HTTPS...
Verifying Connection...

SUCCESS!

Your Mornye Network Storage URL:
https://mornye.example.com

========================================
```

### Non-Interactive / Automated Setup
Run setup with `--domain` or `--root-domain`:
```bash
./setup.sh --yes --network-mode permanent --domain example.com
```

---

## CLI Management Commands

All custom domain operations can be managed via `./mornye.sh`:

```bash
# Add or update custom domain (auto-configures mornye.<domain>)
./mornye.sh tunnel domain add example.com

# Inspect tunnel and domain routing status
./mornye.sh tunnel status

# Test WAN connectivity and HTTP status code
./mornye.sh tunnel test

# View tunnel runtime logs
./mornye.sh tunnel logs -f

# Decouple domain and revert to local-only mode
./mornye.sh tunnel domain remove

# Complete reset of domain configuration
./mornye.sh tunnel domain reset
```

---

## Configuration Persistence

Domain configurations are saved permanently to disk and automatically restored across system reboots:
- **`config/tunnel_info.env`**:
  ```ini
  TUNNEL_NAME="mornye-storage"
  TUNNEL_ID="463ff5f0-ead1-4e10-ba29-92b3e48abf66"
  ROOT_DOMAIN="example.com"
  CUSTOM_DOMAIN="mornye.example.com"
  TUNNEL_MODE="docker"
  ```
- **`.env`**:
  ```ini
  STORAGE_HOSTNAME=mornye.example.com
  CLOUDFLARE_ROOT_DOMAIN=example.com
  CLOUDFLARE_DOMAIN=mornye.example.com
  ```

When `./mornye.sh start` is run, it detects the persisted configuration, starts the tunnel container, and displays the public URL:
```text
[✔] Mornye Public URL: https://mornye.example.com/dav/
```

---

## Troubleshooting & Diagnostics

### 1. `cert.pem not found`
Run the diagnostic check:
```bash
./mornye.sh tunnel cert-check
```
If missing, authenticate with Cloudflare:
```bash
./mornye.sh tunnel login
```
Or specify an existing certificate:
```bash
export CLOUDFLARE_CERT_PATH=/path/to/cert.pem
```

### 2. `DNS record already exists / conflict`
Mornye automatically detects existing DNS records and applies `--overwrite-dns` to re-point `mornye.<root-domain>` to your tunnel without affecting any other DNS records in your zone.

### 3. `Domain is not associated with your Cloudflare account`
Verify that:
- Your domain is visible in your Cloudflare dashboard.
- You selected the zone corresponding to this domain during `tunnel login`.

### 4. `HTTP 401 Unauthorized on WAN probe`
This is the **expected and correct behavior** when WebDAV authentication is enabled. It confirms that the tunnel is online, DNS is resolved, and Argon2id password protection is actively shielding your storage.
