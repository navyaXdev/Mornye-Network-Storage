# MORNYE — DOCKER & CONTAINER INFRASTRUCTURE ARCHITECTURE

**Specification Version:** 3.0.0  
**Target Environments:** Debian 12 / Kali GNU/Linux / Ubuntu 22.04+ / RHEL / Arch Linux  
**CPU Architectures:** `x86_64` (AMD64), `aarch64` (ARM64)  
**Security Posture:** Non-root execution (`uid:1000`), Loopback-only port binding, Dropped Linux capabilities (`cap_drop: ALL`), No-new-privileges

---

## 1. Architectural Overview & Design Principles

The Mornye container architecture transforms the self-hosted music infrastructure into a portable, reproducible, non-root container deployment:
1. **Separation of Concerns:** The core WebDAV storage engine runs inside a hardened Python 3.11 container (`mornye-webdav`), while Cloudflare Zero-Trust WAN ingress runs in an official isolated daemon container (`mornye-tunnel`).
2. **Persistent External Volumes:** The SQLite database, physical music storage, Recycle Bin, and application logs are kept strictly outside disposable container layers on the host filesystem.
3. **Loopback-Only Binding:** WebDAV binds to `127.0.0.1:8000` (or the private Docker bridge network `mornye-net`). Ports are never published to public `0.0.0.0`.
4. **Admin Panel Retirement:** The browser-based React Admin Panel (port 8080) is retired from external network exposure. All operations are controlled authoritatively via the `mornye.sh` Bash CLI.

```
                      +---------------------------------------+
                      |         PUBLIC WAN INGRESS            |
                      |   https://storage.navya.dpdns.org     |
                      +-------------------+-------------------+
                                          |
                                          | Encrypted QUIC/TLS 1.3
                                          v
                      +---------------------------------------+
                      |       mornye-tunnel Container         |
                      |    (cloudflare/cloudflared:latest)    |
                      +-------------------+-------------------+
                                          |
                                          | Docker Bridge Network (mornye-net)
                                          | http://webdav:8000
                                          v
                      +---------------------------------------+
                      |       mornye-webdav Container         |
                      |      (mornye-webdav:latest)           |
                      |      Python 3.11 Slim, Non-root       |
                      +-------------------+-------------------+
                                          |
        +---------------------------------+---------------------------------+
        |                                 |                                 |
        v                                 v                                 v
+---------------+                 +---------------+                 +---------------+
| /data Volume  |                 |/storage Volume|                 | /logs Volume  |
|  (mornye.db,  |                 | (Physical MP3 |                 |  (Runtime     |
|  cache, tmp)  |                 |  audio files) |                 |  audit logs)  |
+---------------+                 +---------------+                 +---------------+
```

---

## 2. Multi-Stage Container Design (`Dockerfile`)

### 2.1 Stage 1: Build Wheels (`builder`)
- **Base Image:** `python:3.11-slim-bookworm`
- **Build Packages:** `gcc`, `g++`, `libffi-dev`, `python3-dev`
- **Output:** Pre-compiled wheels in `/wheels`
- **Optimization:** Prevents shipping heavy compilers and build headers in the final runtime container.

### 2.2 Stage 2: Minimal Runtime (`runner`)
- **Base Image:** `python:3.11-slim-bookworm`
- **Runtime Packages:** `curl` (healthchecks), `libmagic1` (MIME detection), `sqlite3` (database queries), `ffmpeg` (audio metadata extraction)
- **User Context:** Non-root `mornye:mornye` (`uid=1000`, `gid=1000`), matching standard Linux host operator accounts.
- **Continuous Healthcheck:**
  ```dockerfile
  HEALTHCHECK --interval=20s --timeout=5s --start-period=10s --retries=3 \
      CMD /app/docker/healthcheck.sh
  ```
- **Entrypoint:** `/app/docker/entrypoint.sh` initializes runtime directory structure (`/data/cache`, `/data/tmp`, `/data/recycle_bin`) and verifies SQLite schema before launching Uvicorn.

---

## 3. Multi-Container Orchestration (`compose.yaml`)

```yaml
services:
  webdav:
    build:
      context: .
      dockerfile: Dockerfile
    image: mornye-webdav:latest
    container_name: mornye-webdav
    restart: unless-stopped
    user: "1000:1000"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    volumes:
      - ${DATA_PATH:-./database}:/data
      - ${STORAGE_PATH:-../storage}:/storage
      - ${LOG_PATH:-./logs}:/logs
    environment:
      - SECRET_KEY=${SECRET_KEY}
      - DEFAULT_STORAGE_QUOTA_BYTES=${DEFAULT_STORAGE_QUOTA_BYTES:-107374182400}
      - APP_ENV=production
      - WEBDAV_HOST=0.0.0.0
      - WEBDAV_PORT=8000
      - DATA_PATH=/data
      - STORAGE_PATH=/storage
      - LOG_PATH=/logs
      - DATABASE_URL=sqlite+aiosqlite:////data/mornye.db
    ports:
      - "127.0.0.1:8000:8000"
    networks:
      - mornye-net

  tunnel:
    image: cloudflare/cloudflared:latest
    container_name: mornye-tunnel
    restart: unless-stopped
    user: "nonroot"
    command: tunnel --no-autoupdate --config /etc/cloudflared/config.yml run
    volumes:
      - ./cloudflare/tunnel:/etc/cloudflared:ro
    depends_on:
      webdav:
        condition: service_healthy
    networks:
      - mornye-net

networks:
  mornye-net:
    name: mornye-net
    driver: bridge
```

---

## 4. Persistent Volume & Storage Quota Architecture

1. **Database Persistence:**
   - SQLite is NOT containerized as an external database service. It remains an embedded SQLite database file stored at `/home/spidyno/.song/program/database/mornye.db` and mounted into `/data/mornye.db`.
   - SQLite WAL (`-wal`) and Shared Memory (`-shm`) files are safely handled on the host filesystem with atomic transactions.
2. **100 GB Music Quota Isolation:**
   - The 100 GB (`107,374,182,400 bytes`) quota is enforced at the application layer through database model queries (`MusicFile` table) and verified against physical disk files in `/storage/`.
   - Quota limits apply strictly to Mornye audio storage, never restricting the host or container filesystem.
3. **Recycle Bin Quarantine:**
   - Deleted files are moved to `/data/recycle_bin/` and indexed in `recycle_bin_items`. They remain retrievable through the CLI (`./mornye.sh music list`, `./mornye.sh music stats`).

---

## 5. Multi-Distribution Support Matrix

| Distribution | Package Manager | Prerequisites Installation Command |
|---|---|---|
| **Kali Linux / Debian 12** | `apt` | `sudo apt-get update && sudo apt-get install -y docker.io docker-compose curl sqlite3 ffmpeg libmagic1 python3-venv` |
| **Ubuntu 22.04 / 24.04** | `apt` | `sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 curl sqlite3 ffmpeg libmagic1 python3-venv` |
| **Fedora / RHEL 9** | `dnf` | `sudo dnf install -y docker docker-compose curl sqlite ffmpeg-free python3-virtualenv` |
| **Arch Linux / Manjaro** | `pacman` | `sudo pacman -Syu --noconfirm docker docker-compose curl sqlite ffmpeg` |

*(Note: In all distributions, non-root container management is enabled via `sudo usermod -aG docker $USER`).*

