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

## 3. Universal Linux Compatibility

Mornye features native package-manager awareness across all major Linux distributions:
- **Debian / Ubuntu / Kali / Mint**: APT package manager (`installers/apt.sh`)
- **Arch Linux / Manjaro / EndeavourOS**: Pacman package manager (`installers/pacman.sh`)
- **Fedora / RHEL / Rocky / AlmaLinux**: DNF & YUM package managers (`installers/dnf.sh`, `installers/yum.sh`)
- **openSUSE Leap / Tumbleweed**: Zypper package manager (`installers/zypper.sh`)
- **Alpine Linux**: APK package manager with OpenRC support (`installers/apk.sh`)

Hardware Architectures: `x86_64` (amd64), `aarch64` (ARM64), `armv7l` (armhf).  
All 8 distributions pass automated continuous container verification (100% pass rate). See [SUPPORTED_LINUX.md](docs/SUPPORTED_LINUX.md) for full details.

---

## 4. One-Command Automated Installation

Mornye installs with a single command on any supported Linux distribution:

```bash
# 1. Clone the repository
git clone https://github.com/navyaXdev/Mornye-Network-Storage.git
cd Mornye-Network-Storage

# 2. Make executable
chmod +x setup.sh mornye.sh

# 3. Launch the 6-stage automated setup wizard
./mornye.sh install
```

The universal installer (`setup.sh`) automatically:
1. Detects distribution, package manager, architecture, and init system.
2. Audits system resources (minimum 1 GB RAM, 2 GB disk).
3. Installs missing packages, Docker Engine, Docker Compose plugin, and `cloudflared`.
4. Provisions persistent volumes (`database/`, `storage/`, `logs/`, `backups/`, `config/`) with strict permission hardening (`chmod 700`).
5. Generates cryptographically secure secrets in `.env`.
6. Builds the production `mornye-webdav` container image.
7. Offers interactive network selection (Local, Permanent Cloudflare Tunnel, or Ephemeral Quick Tunnel).
8. Runs end-to-end health verification probes and exports a report.

See [INSTALLATION.md](docs/INSTALLATION.md) for full options and non-interactive flags.

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

### Universal System Diagnostics & Self-Healing
```bash
./mornye.sh doctor                 # Run full 11-category system & conflict diagnostic
./mornye.sh doctor --json          # Output machine-readable JSON telemetry
./mornye.sh doctor --fix           # Interactively auto-repair permissions, ports, & config
./mornye.sh doctor --fix -y        # Non-interactive auto-repair with automatic pre-change backups
./mornye.sh ports                  # Inspect port occupancy, PID, process owner, & conflicts
./mornye.sh health                 # Probe container /health & /dav/ HTTP response & latency
./mornye.sh config validate        # Validate .env, compose.yaml security, & Cloudflare ingress
./mornye.sh status                 # Display infrastructure status, host port, & quota
./mornye.sh dashboard              # Interactive real-time updating terminal dashboard
./mornye.sh version                # Show version, commit hash, and kernel details
```

### Port Configuration & Protected Coexistence
Mornye binds its host port according to `.env` (`MORNYE_HOST_PORT=8001`, default `127.0.0.1`), while the container internal WebDAV port remains strictly on `8000`. This allows Mornye to run simultaneously alongside existing services on port 8000 (such as SONG Bridge or legacy daemons) with zero interference and zero service termination.

### WebDAV Engine
```bash
./mornye.sh webdav status          # Inspect loopback port binding and container state
./mornye.sh webdav test            # Execute live PROPFIND auth boundary probe
./mornye.sh webdav logs 50         # View recent 50 lines of WebDAV access logs
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

### Mode B: Permanent Zero-Trust Tunnel (Automatic Dedicated Subdomain)
For permanent production ingress under your custom domain, Mornye automatically creates and routes a dedicated subdomain (`mornye.<root-domain>`):

```bash
# 1. Run guided setup wizard (prompts for root domain, e.g. example.com)
./mornye.sh tunnel setup

# Or configure domain directly (automatically creates mornye.<domain>):
./mornye.sh tunnel domain add example.com

# 2. Inspect tunnel status and domain routing
./mornye.sh tunnel status

# 3. Test WAN connectivity and Argon2id boundary
./mornye.sh tunnel test

# 4. Decouple domain or reset configuration
./mornye.sh tunnel domain remove
./mornye.sh tunnel domain reset
```

When you enter `example.com`, Mornye automatically generates and configures `mornye.example.com`, provisions the DNS CNAME record, configures Edge SSL, and verifies connectivity.

See [CLOUDFLARE_CUSTOM_DOMAIN.md](docs/CLOUDFLARE_CUSTOM_DOMAIN.md) for the complete architecture and troubleshooting guide.

---

## 8. Documentation Index

Comprehensive guides for operators and administrators:

| Document | Description |
|---|---|
| [**docs/INSTALLATION.md**](docs/INSTALLATION.md) | Universal multi-distribution installation guide & 6-stage lifecycle wizard |
| [**docs/SUPPORTED_LINUX.md**](docs/SUPPORTED_LINUX.md) | Distribution compatibility matrix (APT, Pacman, DNF, Zypper, APK) & test results |
| [**docs/DOCKER_SETUP.md**](docs/DOCKER_SETUP.md) | Hardened container architecture, profiles, volume persistence, and security |
| [**docs/CLOUDFLARE_TUNNEL.md**](docs/CLOUDFLARE_TUNNEL.md) | Zero-Trust network ingress, credentials, systemd/docker modes, and CLI commands |
| [**docs/CUSTOM_DOMAIN_SETUP.md**](docs/CUSTOM_DOMAIN_SETUP.md) | Domain binding, Cloudflare DNS CNAME routing, and WebDAV client integration |
| [**docs/TUNNEL_TROUBLESHOOTING.md**](docs/TUNNEL_TROUBLESHOOTING.md) | Error diagnosis (502, 1033, 1016, 524) and recovery playbooks |
| [**docs/MORNYE_CLI_MANUAL.md**](docs/MORNYE_CLI_MANUAL.md) | Complete CLI reference manual for all `./mornye.sh` subcommands |

---

## 9. Client Connection Guide

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

## 10. Uninstallation & Data Purge (`delete.sh`)

Mornye includes a dedicated root-level uninstaller (`delete.sh`) engineered with strict resource isolation to cleanly tear down Mornye services while guaranteeing foreign applications and services remain 100% operational.

### A. Safe Uninstall (Default Mode)
Stops and removes Mornye Docker containers, images, bridge networks, and services while **preserving all user music, databases, and backups**:

```bash
# Interactive Safe Uninstall
sudo ./delete.sh

# Or via Mornye CLI
./mornye.sh uninstall
```

- **What Gets Removed**: Container `mornye-webdav`, network `mornye-net`, image `mornye-webdav:latest`, Mornye background workers, temporary runtime files (`run/*`, caches).
- **What Gets Preserved**:
  - `database/`: SQLite database file `mornye.db` and WAL journals.
  - `storage/`: All uploaded audio tracks and metadata.
  - `backups/`: Historical backup archives.
  - `config/` & `.env`: All configuration settings and Cloudflare credentials.
- **Reinstalling**: Run `./mornye.sh start` to instantly redeploy the container stack over existing data.

### B. Complete Purge Mode (`--purge`)
Permanently removes all Mornye-owned resources including data volumes, storage, and databases:

```bash
sudo ./delete.sh --purge
```

- **Strict Confirmation Gate**: Destructive purge cannot be triggered by accident. You must type the exact confirmation string:
  ```
  DELETE MORNYE DATA
  ```
  *(Simple `y` / `yes` answers are rejected).*
- **What Gets Deleted**:
  - Databases (`database/`)
  - Music storage (`storage/`)
  - Backups (`backups/`)
  - Configuration (`config/`, `.env`, `.env.bak_*`)
  - Logs (`logs/`)
  - Mornye Docker volumes and images.
- **Pre-Purge Safety Backup**: Before purging, `delete.sh` prompts to create an archive of your data. You can also create a standalone archive anytime:
  ```bash
  sudo ./delete.sh --backup /path/to/archive.tar.gz
  ```
- **Recovery Limitations**: Purged data cannot be recovered once deleted unless a pre-purge backup archive was generated.

### C. Dry-Run Simulation Mode (`--dry-run`)
Inspect the complete uninstallation plan without modifying anything on your system:

```bash
sudo ./delete.sh --dry-run
# Or in purge mode
sudo ./delete.sh --purge --dry-run
```

### D. Strict Resource Isolation & Safety Guarantees
- **SONG Bridge (`mornye-storage.service` on port 8000)**: 100% PROTECTED. Never terminated or altered.
- **Foreign Services & Applications**: Navidrome, Nginx, Apache, Caddy, PostgreSQL, MySQL, and existing Cloudflare tunnels are isolated and untouched.
- **Foreign Docker Containers**: Unrelated containers, images, and volumes are preserved. `docker system prune` is never executed.
- **System Roots Protection**: Strict boundary checks reject deletion of system paths (`/`, `/home`, `/etc`, `/var`, `/usr`, `/opt`).
- **Symlink Escape Protection**: Symbolic links are removed without following or altering external targets.

---

## 11. Automated Testing

Mornye includes a comprehensive automated test suite powered by `pytest` and dedicated bash harnesses:

```bash
# 1. Run uninstaller isolation and purge test suite (15 scenarios)
bash tests/test_uninstaller.sh

# 2. Run runtime error auto-repair test suite (15 scenarios)
bash tests/test_interactive_repair.sh

# 3. Run universal system diagnostics test suite (16 scenarios)
bash tests/test_diagnostics.sh

# 4. Run live WebDAV RFC 4918 verification (14 live steps)
python3 scripts/verify_live_service.py

# 5. Run secret scanning audit
python3 scripts/secret_scan.py
```

---

## 12. License

Mornye Network Storage is open-source software licensed under the [MIT License](LICENSE).
