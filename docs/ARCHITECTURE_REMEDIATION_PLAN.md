# MORNYE NETWORK STORAGE — ARCHITECTURE REMEDIATION PLAN
**Document Version:** 4.0.0  
**Classification:** Technical Architecture & Implementation Blueprint  
**Status:** Approved for Implementation  
**Audience:** Systems Engineers, DevSecOps, Platform Maintainers  

---

## 1. DESIGN PRINCIPLES & REMEDIATION OBJECTIVES

The remediation strategy transitions Mornye Network Storage from fragmented utility scripts into a cohesive, modular systems engineering platform. The design is anchored by five fundamental principles:

1. **Strict Service Isolation:**  
   Mornye is a guest on the host system. It must never commandeer, restart, modify, or terminate existing host services (such as SONG Bridge, host Cloudflare Tunnels, Navidrome, Caddy, or Nginx).
2. **Deterministic Port Differentiation:**  
   Internal container ports (`8000`), host loopback ports (`8001`), and external gateway domains are strictly decoupled. No component may assume that host port 8000 is available.
3. **Cryptographic & Credential Rigor:**  
   Cloudflare origin certificates (`cert.pem`), tunnel credential files (`<UUID>.json`), and base64 tokens are treated as distinct cryptographic artifacts with specific functions and permission requirements.
4. **Universal Linux Abstraction:**  
   Operating system detection, package management (`apt`, `dnf`, `yum`, `pacman`, `zypper`, `apk`), init systems (`systemd`, `openrc`), and execution permissions are unified in a single, well-tested compatibility library.
5. **Fail-Safe Self-Healing:**  
   Error detection is embedded across all lifecycle stages. Auto-repair is permission-gated with clear risk assessments and automated configuration rollbacks.

---

## 2. TARGET ARCHITECTURAL TOPOLOGY

The target runtime architecture ensures strict boundary separation between host processes and Mornye containerized workloads:

```
+---------------------------------------------------------------------------------------+
| HOST SYSTEM (Debian 12/13, Ubuntu, Kali, Arch, Fedora, RHEL, openSUSE, Alpine)        |
|                                                                                       |
|  [EXISTING PROTECTED HOST SERVICES - STRICTLY UNTOUCHED]                              |
|  - SONG Bridge: mornye-storage.service (0.0.0.0:8000)                                 |
|  - Existing Host Tunnel: mornye-tunnel.service (metrics: 20241)                       |
|  - Navidrome Music Server: navidrome.service (0.0.0.0:4533)                           |
|  - Host Reverse Proxy: Caddy / Nginx (80/443)                                         |
|                                                                                       |
|  [MORNYE RUNTIME STACK - ISOLATED BRIDGE NETWORK (mornye-net)]                        |
|                                                                                       |
|  +---------------------------+             +---------------------------------------+  |
|  | Container: mornye-webdav  |             | Container: mornye-tunnel              |  |
|  | Image: mornye-webdav      |             | Image: cloudflare/cloudflared:latest  |  |
|  | User: 1000:1000 (mornye)  |             | User: nonroot (UID 65532)             |  |
|  | Internal Port: 8000       |             | Config: /etc/cloudflared/config.yml   |  |
|  | Volumes:                  |             | Creds:  /etc/cloudflared/creds.json   |  |
|  |   ./database -> /data     |             | Target: http://webdav:8000            |  |
|  |   ./storage  -> /storage  |             +---------------------------------------+  |
|  |   ./logs     -> /logs     |                                 ^                      |
|  +---------------------------+                                 |                      |
|             ^                                                  |                      |
|             | (Host Loopback Binding: 127.0.0.1:8001:8000)     |                      |
|             v                                                  v                      |
|  +---------------------------------------------------------------------------------+  |
|  | WAN Cloudflare Edge: https://<domain>/dav/ -> Zero-Trust Encrypted Ingress      |  |
|  +---------------------------------------------------------------------------------+  |
+---------------------------------------------------------------------------------------+
```

---

## 3. COMPONENT REMEDIATION SPECIFICATIONS

### 3.1 Centralized System Compatibility Engine (`scripts/lib/compat.sh`)
Create a shared, modular engine consumed by `setup.sh`, `mornye.sh`, `delete.sh`, `doctor.sh`, and `repair_engine.sh`:
- **Distribution Detection:** Parse `/etc/os-release` and family fallbacks to identify Debian, Ubuntu, Kali, Mint, Arch, Manjaro, Fedora, RHEL, Rocky, AlmaLinux, openSUSE, and Alpine.
- **Package Manager Abstraction:**
  - `compat_pkg_install <package...>`: Dispatches to `apt-get`, `dnf`, `yum`, `pacman -S`, `zypper in`, or `apk add`.
  - `compat_pkg_refresh`: Updates package indices with distro-appropriate flags.
  - `compat_pkg_candidate_exists <pkg>`: Checks package availability.
- **Init System Abstraction:**
  - `compat_service_start / stop / restart / is_active / enable`: Handles `systemctl` vs `rc-service` vs standalone fallbacks.
- **Privilege & User Identity Management:**
  - Resolve `$SUDO_USER` vs root vs current user.
  - Determine actual user home directory (`/home/$SUDO_USER` when run under sudo).
  - Check and handle Docker group membership with security warnings.

### 3.2 Centralized Port & Network Manager (`scripts/lib/port_manager.sh`)
- Determine default host port (`8001`) vs container port (`8000`).
- Inspect port occupancy via `ss`, `netstat`, `lsof`, or `/proc/net/tcp`.
- Classify port owners: Mornye container proxy vs Mornye host process vs foreign protected service.
- Prevent binding to host port 8000 if occupied by SONG Bridge (`mornye-storage.service`).
- Allocate collision-free alternative ports dynamically if `8001` is occupied.

### 3.3 Redesigned Cloudflare Tunnel Manager (`scripts/cloudflare_manager.sh`)
- **Origin Certificate vs. Credentials Separation:**
  - Enforce clear distinction: `cert.pem` is strictly used for authentication against Cloudflare API/login.
  - Never copy, symlink, or rename `cert.pem` to `credentials.json`.
  - Reject passing `cert.pem` to `--credentials-file`.
- **Existing Tunnel Discovery & Token Recovery:**
  - When configuring a tunnel named `mornye-storage`, query `cloudflared tunnel list` to find existing UUID (`463ff5f0-ead1-4e10-ba29-92b3e48abf66`).
  - Do NOT create a duplicate tunnel if one already exists.
  - If credentials JSON (`<UUID>.json`) is missing locally, execute `cloudflared tunnel token <UUID>` to retrieve the base64 token.
  - Decode the token (`{"a":"AccountTag","t":"TunnelID","s":"TunnelSecret"}`) to reconstruct a valid credentials JSON file.
- **Container Mounting & Permission Alignment:**
  - Before starting the container, verify that `config/credentials.json` exists as a regular file. If missing, abort or recover BEFORE Docker creates a directory.
  - Set permissions `644` on `config/credentials.json` so the unprivileged `nonroot` container user (UID 65532) can read it.
- **Protected Service Safeguards:**
  - Strip all commands that stop or restart `mornye-tunnel.service` on the host.
  - Mornye's tunnel is managed strictly via `docker compose --profile tunnel [up|down|restart]`.
- **Structural YAML Management:**
  - Manage `config/cloudflared.yml` using a Python YAML helper to guarantee valid indentation and preserve ingress ordering (path match -> hostname match -> catch-all `http_status:404`).

### 3.4 Docker & Compose Orchestration Hardening
- Automatic detection of `docker compose` (v2 plugin) with fallback to `docker-compose` (standalone).
- Enforce non-root execution (`mornye:mornye` UID 1000 in WebDAV container; `nonroot` in cloudflared container).
- Add labels `com.docker.compose.project=mornye` to all created resources for deterministic lifecycle discovery.

### 3.5 Interactive Self-Healing & Preflight Checks
- Consolidate error detection in `scripts/repair_engine.sh`:
  - Port conflict resolution (re-allocating host port, leaving port 8000 safe).
  - Docker daemon recovery and user group membership.
  - Missing directory creation with `700`/`755` permissions.
  - Secret key rotation from insecure placeholders.
  - Cloudflare credentials validation and recovery.
- Embed pre-flight hooks into `setup.sh` stages and `mornye.sh` lifecycle commands.

---

## 4. REAL-WORLD REGRESSION SCENARIO SPECIFICATION
**(Debian 13 Second-System Fixture)**

An automated test fixture (`tests/test_cloudflare_second_system.sh`) must simulate the exact second-system environment:
1. **Host Environment:** Debian GNU/Linux 13 (Trixie), x86_64, Docker 26.1.5, Compose 2.26.1, cloudflared 2026.10.7.
2. **Host Port State:** Port 8000 occupied by SONG Bridge (`mornye-storage.service`). Port 20241 occupied by host Cloudflare Tunnel (`mornye-tunnel.service`).
3. **Cloudflare State:** Login certificate present at `/root/.cloudflared/cert.pem` and `~/.cloudflared/cert.pem`. Tunnel `mornye-storage` (UUID `463ff5f0-ead1-4e10-ba29-92b3e48abf66`) exists in Cloudflare account. Domain `navya.dpdns.org` is assigned. Local credentials JSON is absent.
4. **Validation Criteria:**
   - Detect existing tunnel and avoid creating duplicate `mornye-storage`.
   - Prevent copying `cert.pem` to `credentials.json`.
   - Extract credentials via `cloudflared tunnel token` and generate valid `config/credentials.json`.
   - Ensure `config/credentials.json` is a file with `644` permissions, never a directory.
   - Verify `mornye-storage.service` (port 8000) and `mornye-tunnel.service` (port 20241) remain running and untouched.
   - Verify `cloudflared.yml` ingress routes to `http://webdav:8000` (in container mode) or `http://127.0.0.1:8001` (in host mode), ending with `http_status:404`.

---

## 5. IMPLEMENTATION STAGES & GATES

| Stage | Focus Area | Deliverables | Verification Gate |
|---|---|---|---|
| **Stage 1** | System Compatibility Engine | `scripts/lib/compat.sh` | Cross-distro matrix tests pass across Debian, Ubuntu, Kali, Arch, Fedora, RHEL, SUSE, Alpine |
| **Stage 2** | Port & Network Manager | `scripts/lib/port_manager.sh` | Port isolation tests verify SONG Bridge (8000) is protected and host port 8001 is mapped |
| **Stage 3** | Cloudflare Manager Redesign | `scripts/cloudflare_manager.sh` | Unit tests verify token recovery, YAML structural validity, and zero interference with host tunnel |
| **Stage 4** | Docker & Service Hardening | `compose.yaml`, `setup.sh`, `mornye.sh` | Container healthcheck passes; non-root permissions verified |
| **Stage 5** | Self-Healing & Diagnostics | `scripts/doctor.sh`, `scripts/repair_engine.sh` | `test_diagnostics.sh` and `test_interactive_repair.sh` pass with zero regressions |
| **Stage 6** | Debian 13 Regression Fixture | `tests/test_cloudflare_second_system.sh` | All fixture tests pass against simulated Debian 13 multi-tenant environment |
| **Stage 7** | Verification & Audit Sign-Off | All documentation updated | Complete regression suite passes |

