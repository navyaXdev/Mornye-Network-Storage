# MORNYE — DOCKER DEPLOYMENT & PORTABILITY GUIDE

## 1. Overview & Architecture Objectives

Mornye v3.0 introduces an enterprise-grade containerized architecture designed for 100% deterministic, reproducible, and secure deployment across modern Linux distributions.

```
+-------------------------------------------------------------------------+
|                              WAN CLIENTS                                |
+-------------------------------------------------------------------------+
                                    | HTTPS (Port 443 / TLS 1.3)
                                    v
+-------------------------------------------------------------------------+
|                  CLOUDFLARE GLOBAL ZERO-TRUST NETWORK                   |
|                        storage.navya.dpdns.org                          |
+-------------------------------------------------------------------------+
                                    | Encrypted QUIC/HTTP2 Wire
                                    v
+-------------------------------------------------------------------------+
|                        DOCKER HOST ENVIRONMENT                          |
|                                                                         |
|  +---------------------------+       +-------------------------------+  |
|  |       mornye-tunnel       |       |         mornye-webdav         |  |
|  | (cloudflare/cloudflared)  | ----> |      (mornye-webdav:latest)   |  |
|  |  Non-root / read-only cfg |       |   Non-root UID:1000 GID:1000  |  |
|  +---------------------------+       +-------------------------------+  |
|                                                      |                  |
|                                    +-----------------+----------------+ |
|                                    | PERSISTENT VOLUMES (HOST MOUNT)  | |
|                                    | - /data     <-> ./database       | |
|                                    | - /storage  <-> ../storage       | |
|                                    | - /logs     <-> ./logs           | |
+------------------------------------+----------------------------------+-+
```

---

## 2. Multi-Distribution Prerequisites & Setup

Mornye's Docker engine supports all major POSIX-compliant Linux distributions. Follow the specific package manager instructions below to install Docker and Docker Compose.

### A. Debian / Ubuntu / Kali Linux (APT Engine)
```bash
# 1. Update package lists
sudo apt-get update

# 2. Install Docker and Compose plugin
sudo apt-get install -y docker.io docker-compose

# 3. Add current user to docker group (avoids needing root)
sudo usermod -aG docker "$USER"

# 4. Activate group membership (or re-login)
newgrp docker

# 5. Enable and start Docker daemon
sudo systemctl enable --now docker
```

### B. Fedora / RHEL / CentOS Stream (DNF Engine)
```bash
# 1. Install Docker and Compose plugin
sudo dnf install -y docker docker-compose-plugin

# 2. Add user to docker group
sudo usermod -aG docker "$USER"
newgrp docker

# 3. Enable and start Docker daemon
sudo systemctl enable --now docker
```

### C. Arch Linux / Manjaro (Pacman Engine)
```bash
# 1. Install Docker and Compose
sudo pacman -Syu --noconfirm docker docker-compose

# 2. Add user to docker group
sudo usermod -aG docker "$USER"
newgrp docker

# 3. Enable and start Docker daemon
sudo systemctl enable --now docker
```

---

## 3. Container Security Hardening

The Mornye container architecture implements strict defense-in-depth principles:

1. **Non-Root Execution**:
   - The application runner stage runs under user `mornye` (UID: 1000, GID: 1000).
   - Never runs as `root` inside the container.
2. **Capability Dropping**:
   - `cap_drop: ALL` drops all kernel capabilities.
3. **No Privilege Escalation**:
   - `no-new-privileges: true` prevents setuid/setgid privilege escalation.
4. **Private Loopback Port Binding**:
   - Port 8000 is bound strictly to `127.0.0.1:8000:8000`. It is never published to public interfaces (`0.0.0.0`).
5. **No Secret Ingestion in Images**:
   - Secrets are loaded at runtime exclusively from external `.env` or read-only volume mounts (`./cloudflare/tunnel:/etc/cloudflared:ro`).
6. **Multi-Stage Build**:
   - Build-time compilers (`gcc`, `g++`, header files) are discarded in the builder stage; only pre-compiled wheels exist in the runner stage.

---

## 4. Volume Mapping & Persistence Architecture

Containers are stateless; all production data lives in explicit host mounts:

| Host Directory | Container Mount | Persistence Role | Backup Strategy |
| :--- | :--- | :--- | :--- |
| `/home/spidyno/.song/program/database` | `/data` | SQLite database (`mornye.db`), WAL/SHM, Recycle Bin | Hot online backup via `./mornye.sh backup create` |
| `/home/spidyno/.song/storage` | `/storage` | Flat physical audio files (MP3/FLAC/WAV) | External disk sync / rsync |
| `/home/spidyno/.song/program/logs` | `/logs` | WebDAV access & runtime audit logs | Rotated logs |
| `/home/spidyno/.song/program/cloudflare/tunnel` | `/etc/cloudflared` | Read-only Cloudflare tunnel credentials and ingress config | Encrypted offsite backup |

> [!IMPORTANT]
> The **100 GB Music Storage Quota** applies strictly to `/storage` audio files tracked in the database, enforced at the application engine layer. It does not limit Docker filesystem growth.

---

## 5. Deployment & Lifecycle via CLI

All container operations are managed via `./mornye.sh`:

```bash
# 1. Diagnostic check of host dependencies
./mornye.sh doctor

# 2. Build or rebuild production images
./mornye.sh docker rebuild

# 3. Start containerized stack in background
./mornye.sh docker up

# 4. Inspect container status and health
./mornye.sh docker ps
./mornye.sh docker health

# 5. Tail container logs
./mornye.sh docker logs

# 6. Test WebDAV engine inside container
./mornye.sh webdav test

# 7. Test Cloudflare Tunnel WAN routing
./mornye.sh tunnel test
```

---

## 6. Container Health Check Verification

The WebDAV container executes `/app/docker/healthcheck.sh` every 20 seconds:
- Executes `PROPFIND` against `http://127.0.0.1:8000/dav/`.
- Validates that the engine returns `HTTP 401 Unauthorized` (auth boundary active) or `HTTP 207 Multi-Status`.
- If healthcheck fails 3 consecutive times, Docker flags the container as `unhealthy` and Compose restarts it.

