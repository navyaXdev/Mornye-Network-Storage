# Mornye Network Storage — Cloudflare Tunnel Troubleshooting Guide

Diagnostic procedures, common error code resolutions, and recovery playbooks for Cloudflare Zero-Trust WAN tunnels.

---

## 1. Quick Diagnostic Checklist

When experiencing tunnel or ingress connectivity issues, run the following diagnostic commands in order:

```bash
# 1. Check end-to-end system and dependency diagnostics
./mornye.sh doctor

# 2. Check local WebDAV container and endpoint status
./mornye.sh status

# 3. Check Cloudflare tunnel daemon state and edge connections
./mornye.sh tunnel status

# 4. Tail real-time tunnel logs for connection anomalies
./mornye.sh tunnel logs -f 30

# 5. Execute live WAN reachability handshake probe
./mornye.sh tunnel test
```

---

## 2. Error Matrix & Resolution Playbooks

### HTTP 502 Bad Gateway
```text
Cloudflare Error: 502 Bad Gateway
Host Error: Unable to connect to origin WebDAV server
```
- **Root Cause**: The Cloudflare tunnel daemon is active and talking to Cloudflare Edge, but it cannot connect to the origin WebDAV server on `http://127.0.0.1:8000` (or `http://webdav:8000`).
- **Resolution**:
  1. Verify if the WebDAV container is running:
     ```bash
     ./mornye.sh docker ps
     ```
  2. If stopped, start the container stack:
     ```bash
     ./mornye.sh start
     ```
  3. Test local loopback reachability directly on the host:
     ```bash
     curl -i http://127.0.0.1:8000/health
     ```
  4. If running in Docker mode, ensure both `webdav` and `tunnel` share the same network bridge (`mornye-net`).

---

### Cloudflare Error 1033 (Argo Tunnel Error)
```text
Error 1033: Argo Tunnel error
You've requested a page on a website that is on the Cloudflare network.
Cloudflare is currently unable to resolve your requested domain via Argo Tunnel.
```
- **Root Cause**: The tunnel daemon is not running on the host, has crashed, or is unable to maintain an outbound connection to Cloudflare's Edge Anycast nodes.
- **Resolution**:
  1. Inspect tunnel status:
     ```bash
     ./mornye.sh tunnel status
     ```
  2. If inactive or stopped, restart the tunnel:
     ```bash
     ./mornye.sh tunnel restart
     ```
  3. Check outbound WAN network connectivity to Cloudflare:
     ```bash
     curl -s -o /dev/null -w "%{http_code}" https://1.1.1.1
     ```
  4. Tail logs to identify authentication or connection drops:
     ```bash
     ./mornye.sh tunnel logs 50
     ```

---

### Cloudflare Error 1016 (Origin DNS Error)
```text
Error 1016: Origin DNS error
Cloudflare is unable to resolve the origin hostname.
```
- **Root Cause**: The DNS record for your custom domain is missing or does not point to the tunnel's canonical target (`<tunnel-uuid>.cfargotunnel.com`).
- **Resolution**:
  1. Re-route the DNS record using the CLI:
     ```bash
     ./mornye.sh tunnel domain add storage.example.com
     ```
  2. Verify DNS resolution from an external resolver:
     ```bash
     dig storage.example.com CNAME
     ```
     Ensure the answer section returns `<UUID>.cfargotunnel.com`.

---

### Cloudflare Error 522 / 524 (Connection Timed Out)
```text
Error 524: A timeout occurred
The origin web server did not respond within the Cloudflare timeout window.
```
- **Root Cause**: Firewall or router is dropping outbound UDP packets for QUIC protocol (port 7844) or edge routing is experiencing high latency.
- **Resolution**:
  1. Verify outbound firewall allows UDP port 7844 or TCP port 443.
  2. Inspect smoothed round-trip time (RTT) in `./mornye.sh tunnel status`.
  3. If your network blocks UDP/QUIC, force the tunnel to use HTTP/2:
     Add `--protocol http2` to the cloudflared run command.

---

### Certificate / Authentication Errors (`cert.pem`)
```text
Cannot find tunnel certificate at ~/.cloudflared/cert.pem
Authentication error: failed to verify origin certificate
```
- **Root Cause**: The Cloudflare OAuth authentication certificate is missing or file permissions prevent the current user from reading it.
- **Resolution**:
  1. Check if the certificate exists:
     ```bash
     ls -la ~/.cloudflared/cert.pem
     ```
  2. Correct permissions:
     ```bash
     chmod 600 ~/.cloudflared/cert.pem
     ```
  3. If missing or invalid, re-run login:
     ```bash
     ./mornye.sh tunnel login
     ```

---

### Docker Service DNS Resolution: `dial tcp: lookup webdav`
```text
cloudflared: dial tcp: lookup webdav on 127.0.0.11:53: no such host
```
- **Root Cause**: The tunnel container cannot resolve the hostname `webdav` because the WebDAV service is not attached to the `mornye-net` bridge network or is named differently.
- **Resolution**:
  1. Verify both containers are part of the network:
     ```bash
     docker network inspect mornye-net
     ```
  2. Ensure the container name is `mornye-webdav` and service name in `compose.yaml` is `webdav`.
  3. Restart the stack using:
     ```bash
     ./mornye.sh restart
     ```

