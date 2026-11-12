# MORNYE — TERMINAL MANAGEMENT CLI REFERENCE MANUAL

**Binary:** `/home/spidyno/.song/program/mornye.sh`  
**Compatibility Alias:** `/home/spidyno/.song/program/admin-panel.sh`  
**Architecture:** CLI-First, Non-root Linux Operations, Portable Python Backend Engine  
**Release Version:** 3.0.0

---

## 1. Introduction & CLI Philosophy

The Mornye Terminal Management CLI (`mornye.sh`) is the primary administrative interface for Mornye infrastructure:
- **CLI-First Architecture:** Replaces browser-based admin portals with terminal operations.
- **Backend Model Binding:** Python CLI engines (`cli/*_ops.py`) bind directly to application models, eliminating fragile shell string manipulation.
- **Data Protection Guarantee:** Never exposes passwords, Argon2id hashes, or API secrets.
- **Disaster Recovery Safeguards:** Any destructive action (e.g. database restore, service uninstall) requires explicit confirmation flags (`--confirm`).

---

## 2. Command Reference

### 2.1 General Operations

| Command | Description | Example Output / Action |
|---|---|---|
| `./mornye.sh help` | Displays full interactive manual and command tree. | Visual ASCII banner and categorized help menus. |
| `./mornye.sh version` | Prints engine version, Python runtime, and license. | `Mornye Terminal Infrastructure CLI v3.0.0` |
| `./mornye.sh doctor` | Audits Linux distribution, kernel, dependencies, database health, and storage paths. | Reports distribution (Kali/Debian), Python, Git, SQLite `PRAGMA integrity_check`, Docker availability. |
| `./mornye.sh status` | System-wide status overview: systemd services, listening ports, and storage metrics. | Active status of `mornye-storage.service`, ports 8000/8080/20241, storage counters. |
| `./mornye.sh dashboard` | Full-screen live operational ASCII mission console. | Real-time WebDAV, Tunnel, and hardware resource gauges. |

---

### 2.2 Lifecycle & Service Management

| Command | Description | Guardrails & Actions |
|---|---|---|
| `./mornye.sh install` | Auto-detects Linux distribution (`apt`, `dnf`, `pacman`) and installs required packages. | Installs Docker, Compose, curl, sqlite3, ffmpeg, libmagic1. |
| `./mornye.sh setup` | Initializes persistent directory tree (`cache`, `tmp`, `recycle_bin`) and template `.env`. | Sets strict directory permissions (`chmod 700 database`). |
| `./mornye.sh start` | Starts Mornye WebDAV engine and Cloudflare Tunnel services. | Dispatches systemd start commands or launches direct container. |
| `./mornye.sh stop` | Gracefully terminates active background processes. | Issues graceful SIGTERM. |
| `./mornye.sh restart` | Gracefully restarts active daemons. | Seamlessly reloads WebDAV and Cloudflare processes. |
| `./mornye.sh update` | Pulls latest Docker container images and reloads. | Pulls upstream base layers and initiates zero-downtime rebuild. |
| `./mornye.sh uninstall` | Removes background service units and launchers. | **Safety Enforced:** Prompts for typed `UNINSTALL`. Database and music files are **never** deleted. |

---

### 2.3 Docker Container Operations

| Command | Description | Target Container |
|---|---|---|
| `./mornye.sh docker status` | Shows Docker daemon version and active container counts. | `mornye-webdav`, `mornye-tunnel` |
| `./mornye.sh docker ps` | Filters and lists running Mornye container instances. | Process table with port mappings. |
| `./mornye.sh docker logs` | Follows combined container stdout/stderr log stream. | Streams real-time container output. |
| `./mornye.sh docker rebuild` | Rebuilds container images from local `Dockerfile` without cache. | Compiles wheels and refreshes runtime container. |
| `./mornye.sh docker pull` | Pulls upstream images (`cloudflare/cloudflared:latest`). | Updates container base images. |
| `./mornye.sh docker health` | Queries container continuous healthcheck status. | Returns `healthy` or `unhealthy`. |

---

### 2.4 WebDAV Storage Engine

| Command | Description | Technical Action |
|---|---|---|
| `./mornye.sh webdav status` | Verifies loopback listening state, port 8000, and protocols. | Confirms socket binding and public endpoint URL. |
| `./mornye.sh webdav test` | Executes live RFC 4918 `PROPFIND` request with `Depth: 0`. | Validates HTTP 401 Basic Auth challenge or HTTP 207 response with round-trip latency. |
| `./mornye.sh webdav logs` | Tails dedicated WebDAV access and transfer logs. | Follows `webdav_access.log` or systemd journal. |

---

### 2.5 Cloudflare Zero-Trust Tunnel

| Command | Description | Sourced Telemetry |
|---|---|---|
| `./mornye.sh tunnel status` | Inspects live HA connections, edge POPs (BOM), RTT, and proxied counts. | Scrapes Prometheus endpoint (`127.0.0.1:20241/metrics`). |
| `./mornye.sh tunnel test` | Performs real-time WAN handshake probe to `https://storage.navya.dpdns.org/dav/`. | Measures end-to-end TLS handshake latency and edge Ray ID. |
| `./mornye.sh tunnel start` | Starts Cloudflare tunnel daemon. | Launches systemd unit or container. |
| `./mornye.sh tunnel stop` | Stops Cloudflare tunnel daemon. | Safely disconnects tunnel sessions. |
| `./mornye.sh tunnel restart`| Restarts Cloudflare tunnel daemon. | Reconnects HA edge sessions. |
| `./mornye.sh tunnel logs` | Streams live tunnel journalctl or container logs. | Redacts secrets and highlights QUIC connections. |
| `./mornye.sh tunnel quick start [-y]` | Launches ephemeral trycloudflare.com testing tunnel. | Prominently warns of public exposure; requires confirmation. |
| `./mornye.sh tunnel quick status` | Displays active Quick Tunnel PID and temporary URL. | Real-time HTTP probe validating auth boundary. |
| `./mornye.sh tunnel quick stop` | Gracefully terminates active Quick Tunnel process. | Cleans up runtime PID and URL state files. |
| `./mornye.sh tunnel quick logs [-f] [N]` | Tails recent Quick Tunnel connection logs. | Displays trycloudflare.com negotiation events. |

---

### 2.6 Music Catalog & Storage

| Command | Description | Output Columns |
|---|---|---|
| `./mornye.sh music list` | Lists all indexed audio files across virtual folders. | `ID`, `VIRTUAL PATH`, `SIZE`, `OWNER`, `STATUS` |
| `./mornye.sh music stats` | Computes canonical catalog and storage metrics. | Active tracks, used storage, quota %, recycle bin. |
| `./mornye.sh music verify` | Audits physical files on disk vs database records. | Validates file existence and SHA-256 checksums. |

---

### 2.7 Users & Quota Enforcement

| Command | Description | Security Guarantee |
|---|---|---|
| `./mornye.sh users list` | Lists user accounts, roles (`admin`, `music_user`), and quota allocations. | **Zero password or hash exposure.** |
| `./mornye.sh quota status` | Displays system-wide quota consumption and user allocations. | Formatted in GB/MB with utilization percentages. |
| `./mornye.sh quota recalculate`| Re-indexes physical files and writes a fresh `StorageMetric` entry. | Synchronizes database quota counters. |

---

### 2.8 Backup & Disaster Recovery

| Command | Description | Integrity Verification |
|---|---|---|
| `./mornye.sh backup create` | Executes online SQLite backup to `backups/` and `/home/spidyno/.song/backups/`. | Automatically runs `PRAGMA integrity_check;`. |
| `./mornye.sh backup list` | Lists available backups sorted newest first with size and dates. | Displays in-tree and external backup copies. |
| `./mornye.sh backup verify <file>` | Runs deep integrity audit on specified backup file. | Reports table counts and PRAGMA status. |
| `./mornye.sh restore <file> --confirm`| Restores database from verified backup. | **Safety Enforced:** Creates pre-restore safety copy first. |

---

### 2.9 System Monitoring

| Command | Metric | Source |
|---|---|---|
| `./mornye.sh monitor` | Comprehensive hardware overview. | Combined CPU, RAM, Disk, Network. |
| `./mornye.sh monitor cpu` | CPU % per core, frequency, load averages (1/5/15m). | `psutil.cpu_percent`, `getloadavg()` |
| `./mornye.sh monitor memory` | Total, used, free RAM, cached buffers, and swap. | `psutil.virtual_memory()` |
| `./mornye.sh monitor disk` | Storage mount point capacity, used, and free space. | `psutil.disk_usage()` on `/home/spidyno/.song/storage` |
| `./mornye.sh monitor network` | Total bytes sent/received and live bandwidth rates. | `psutil.net_io_counters()` |

