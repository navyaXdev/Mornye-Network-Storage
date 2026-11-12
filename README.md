# Mornye Network Storage

> **Enterprise-Grade Private Music Storage Engine & RFC 4918 WebDAV Server**  
> Portable, CLI-first Linux infrastructure with Docker deployment, Cloudflare Zero-Trust ingress, ephemeral Quick Tunnel testing, atomic staged uploads, and 100 GB quota enforcement.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Python 3.11+](https://img.shields.io/badge/Python-3.11%2B-green.svg)](https://www.python.org/)
[![Docker](https://img.shields.io/badge/Docker-Multi--Stage-2496ED.svg)](compose.yaml)
[![Architecture: CLI-First](https://img.shields.io/badge/Architecture-CLI--First-purple.svg)](mornye.sh)
[![WebDAV: RFC 4918](https://img.shields.io/badge/WebDAV-RFC%204918-orange.svg)](webdav/)

---

## 1. Overview

**Mornye Network Storage** is a high-performance, self-hosted private music storage system built specifically for modern Linux distributions. It is engineered from the ground up for absolute reliability, security, and portability:

- **CLI-First Operations**: Complete platform management via the unified POSIX Bash CLI (`./mornye.sh`).
- **Standardized RFC 4918 WebDAV**: Seamless two-way synchronization and streaming compatibility with all standard WebDAV clients (macOS Finder, Windows Explorer, VLC, Symfonium, Kodi, etc.).
- **Flat Physical Storage with Virtual Hierarchy**: Audio files are safely stored flat on disk while presenting an organized artist/album directory structure in WebDAV.
- **Atomic Two-Phase Uploads**: Large audio files stream into isolated `.part` temporary files and are published atomically to prevent corrupted or partial file indexing.
- **100 GB Storage Quota**: Strict enforcement of music library storage allocations with pre-flight quota boundary checks.
- **Argon2id Security**: Passwords hashed with OWASP-recommended Argon2id parameters; all administrative and WebDAV requests enforce strict authentication.
- **Zero-Trust Network Ingress**: Supports both permanent Cloudflare Named Tunnels and ephemeral account-less Quick Tunnels (`trycloudflare.com`) for temporary testing without public port forwarding.

---

## 2. Architecture

```
+-------------------------------------------------------------------------+
|                        REMOTE CLIENTS & STREAMERS                       |
|          (VLC, Symfonium, macOS Finder, Windows Explorer, cURL)         |
+-------------------------------------------------------------------------+
                                    | HTTPS (TLS 1.3)
                                    v
+-------------------------------------------------------------------------+
|                   CLOUDFLARE ZERO-TRUST INGRESS EDGE                    |
|       - Option A: Permanent Named Tunnel (storage.example.com)          |
|       - Option B: Ephemeral Quick Tunnel (*.trycloudflare.com)          |
+-------------------------------------------------------------------------+
                                    | Encrypted QUIC / HTTP/2
                                    v
+-------------------------------------------------------------------------+
|                        LINUX HOST / DOCKER ENGINE                       |
|                                                                         |
|   +-----------------------------------------------------------------+   |
|   |                  MORNYE WEBDAV ENGINE (:8000)                   |   |
|   |   - RFC 4918 Methods: PROPFIND, GET, PUT, MKCOL, MOVE, DELETE   |   |
|   |   - HTTP Basic Auth Boundary (Argon2id Password Verification)   |   |
|   |   - PureMagic Binary Header Inspection (MP3, FLAC, WAV, AAC)    |   |
|   +-----------------------------------------------------------------+   |
|                                    |                                    |
|         +--------------------------+--------------------------+         |
|         v                                                     v         |
|  +--------------------+                             +----------------+  |
|  |  SQLite Database   |                             |  Flat Storage  |  |
|  |  - mornye.db (WAL) |                             |  - audio files |  |
|  |  - virtual folders |                             |  - recycle_bin |  |
|  +--------------------+                             +----------------+  |
+-------------------------------------------------------------------------+
```

---

## 3. Supported Linux Distributions

Mornye has been verified and tested on the following operating systems:
- **Debian GNU/Linux** (12 Bookworm, testing)
- **Ubuntu Server / Desktop** (22.04 LTS, 24.04 LTS)
- **Kali GNU/Linux** (Rolling 2024+, 2026+)
- **Fedora Workstation / Server** (39+)
- **Arch Linux / Manjaro** (Rolling)

Hardware Architectures: `x86_64` (amd64), `aarch64` (ARM64), `armv7l`.

---

## 4. Quick Start & Automated Installation

The fastest way to install and configure Mornye Network Storage is via the automated installer `setup.sh`:

```bash
# 1. Clone the private repository
git clone https://github.com/navyaXdev/Mornye-Network-Storage.git
cd Mornye-Network-Storage

# 2. Make scripts executable
chmod +x setup.sh mornye.sh

# 3. Execute automated setup
./setup.sh
```

`setup.sh` automatically:
1. Detects Linux distribution and CPU architecture.
2. Checks available disk space (minimum 2 GB required).
3. Verifies Python 3, Docker, and utilities.
4. Creates persistent directories (`database/`, `storage/`, `logs/`, `backups/`).
5. Generates a cryptographically secure `.env` configuration from `.env.example`.
6. Sets strict filesystem permissions (`chmod 700` for databases and backups).
7. Validates Docker Compose configuration and offers image build.
8. Runs end-to-end diagnostic probes.

---

## 5. Docker Deployment

Mornye is container-ready out of the box with multi-stage Dockerfiles and unprivileged non-root execution (UID: 1000):

```bash
# 1. Copy environment template
cp .env.example .env

# 2. Build production image
docker compose build

# 3. Start WebDAV service in detached mode
docker compose up -d

# 4. Verify container health
docker compose ps
./mornye.sh docker health

# 5. Tail live logs
docker compose logs -f
```

Persistent data directories are mounted from the host:
- `./database` -> `/data` (SQLite database & Recycle Bin)
- `./storage`  -> `/storage` (Physical audio files)
- `./logs`     -> `/logs` (Runtime & WebDAV logs)

---

## 6. CLI Management Manual (`mornye.sh`)

Mornye includes a comprehensive, human-readable terminal CLI interface:

### General & Diagnostics
```bash
./mornye.sh doctor       # Run deep diagnostic audit on dependencies and disk
./mornye.sh status       # Display infrastructure status, ports, and quota
./mornye.sh dashboard    # Interactive real-time updating terminal dashboard
./mornye.sh version      # Show version, commit hash, and kernel details
```

### WebDAV Engine
```bash
./mornye.sh webdav status      # Inspect loopback port 8000 state
./mornye.sh webdav test        # Execute live PROPFIND auth boundary probe
./mornye.sh webdav logs 50     # View recent 50 lines of WebDAV access logs
```

### Music Catalog & Quota
```bash
./mornye.sh music list         # List indexed audio tracks across virtual folders
./mornye.sh music stats        # Display canonical storage statistics and quota
./mornye.sh music verify       # Audit physical disk files vs database SHA-256
./mornye.sh users list         # List user accounts safely (no password leaks)
./mornye.sh quota status       # Show global and per-user 100 GB allocations
./mornye.sh quota recalculate  # Synchronize and commit fresh storage metrics
```

### Hot Online Backups
```bash
./mornye.sh backup create                # Hot SQLite online backup with integrity check
./mornye.sh backup list                  # List available backups with size and timestamps
./mornye.sh backup verify backups/<file> # Verify SQLite header and page allocation
./mornye.sh backup restore backups/<file> --confirm # Restore database safely
```

### Real-Time System Telemetry
```bash
./mornye.sh monitor          # Combined CPU, RAM, Disk, and Network telemetry
./mornye.sh monitor cpu      # Per-core utilization and load averages
./mornye.sh monitor memory   # Physical RAM, cached buffers, and swap usage
./mornye.sh monitor disk     # Filesystem capacity and storage usage
./mornye.sh monitor network  # Cumulative I/O and live bandwidth transfer rates
```

---

## 7. Cloudflare Tunnel Ingress

Mornye supports two distinct ingress modes for secure WAN access without opening inbound firewall ports or configuring port forwarding:

### Mode A: Ephemeral Quick Tunnel (Temporary Testing)
Quick Tunnel generates a temporary, public `*.trycloudflare.com` URL powered by Cloudflare without requiring an account or API token:

```bash
# 1. Start temporary Quick Tunnel (prompts for exposure confirmation)
./mornye.sh tunnel quick start

# Or start non-interactively in scripts
./mornye.sh tunnel quick start --yes

# 2. View current temporary URL and process status
./mornye.sh tunnel quick status

# 3. View live Quick Tunnel logs
./mornye.sh tunnel quick logs

# 4. Stop and terminate Quick Tunnel session
./mornye.sh tunnel quick stop
```

> [!WARNING]
> Quick Tunnel URLs are temporary and ephemeral. They are intended strictly for testing and validation. WebDAV Basic Auth (Argon2id) remains enforced.

### Mode B: Permanent Zero-Trust Tunnel (Production)
For permanent production ingress under your custom domain:

1. Create a Cloudflare Tunnel in the Cloudflare Zero-Trust Dashboard or via `cloudflared tunnel create <name>`.
2. Copy `config/cloudflared.example.yml` to `config/cloudflared.yml` and provide your Tunnel UUID and credentials path:
   ```yaml
   tunnel: <your-tunnel-uuid>
   credentials-file: /etc/cloudflared/credentials.json

   ingress:
     - hostname: storage.yourdomain.com
       service: http://127.0.0.1:8000
     - service: http_status:404
   ```
3. Start the permanent tunnel daemon:
   ```bash
   ./mornye.sh tunnel start
   ./mornye.sh tunnel status
   ./mornye.sh tunnel test
   ```

---

## 8. Client Connection Guide

Connect your favorite audio player or file sync client to Mornye WebDAV:

- **Server URL**: `https://<your-hostname>/dav/` (or temporary Quick Tunnel URL)
- **Protocol**: WebDAV (HTTPS / Port 443)
- **Authentication**: HTTP Basic Auth
- **Username / Password**: Your configured Mornye user credentials

### Supported Clients:
- **Streaming Players**: Symfonium (Android), VLC (Cross-platform), Kodi, Infuse.
- **Desktop File Managers**: macOS Finder (`Cmd+K`), Windows Explorer (Map Network Drive), Linux GNOME Files / Dolphin.
- **Sync Tools**: Cyberduck, WinSCP, Rclone.

---

## 9. Security & Defense-in-Depth

1. **Local Loopback Isolation**: The WebDAV service binds strictly to `127.0.0.1:8000` (or the internal Docker network). It is never exposed directly to public WAN interfaces (`0.0.0.0`).
2. **Retired Web Management Surfaces**: Legacy web UI dashboards (ports 8080 and 9000) have been decommissioned. Only the secure RFC 4918 WebDAV engine listens for requests.
3. **Argon2id Password Hashing**: Passwords are protected using OWASP-compliant Argon2id parameters (time cost: 3, memory cost: 64 MB, parallelism: 4).
4. **Magic Bytes MIME Validation**: Audio uploads are validated via binary header signatures using `puremagic` to reject disguised executables, scripts, or non-audio files.
5. **Path Traversal Jail**: Directory traversal patterns (`..`, leading dots, null bytes) are strictly rejected.
6. **Least Privilege Container**: Runs as unprivileged user `mornye` (UID: 1000) with `cap_drop: ALL` and `no-new-privileges: true`.

---

## 10. Automated Testing

Mornye includes a comprehensive automated test suite powered by `pytest`:

```bash
# Run all tests
pytest tests/ -v

# Run live WebDAV RFC 4918 verification
python3 scripts/verify_live_service.py

# Run secret scanning audit
python3 scripts/secret_scan.py
```

---

## 11. License

Mornye Network Storage is open-source software licensed under the [MIT License](LICENSE).
