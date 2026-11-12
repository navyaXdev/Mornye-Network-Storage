# MORNYE NETWORK STORAGE — DEPENDENCY INSTALLATION REPORT
**Generated automatically by setup.sh on 2026-11-12 08:24:49Z**

---

## 1. Host Platform & Environment Telemetry

| Parameter | Value |
| :--- | :--- |
| **Operating System** | Kali GNU/Linux (kali-rolling) |
| **OS Distribution ID** | kali (2026.3) |
| **CPU Architecture** | x86_64 (Debian package arch: amd64) |
| **Kernel Version** | 7.1.5+kali-amd64 |
| **Execution User** | spidyno (UID: 1000) |
| **Working Directory** | /home/spidyno/.song/Mornye-Network-Storage |
| **Internet Reachability** | Online (Verified) |

---

## 2. Dependency Audit & Package Status

| Component | Status | Detected Version / Details |
| :--- | :--- | :--- |
| **Python 3 Engine** | **PASSED** | 3.14.8 |
| **Python Virtualenv** | **PASSED** | /home/spidyno/.song/Mornye-Network-Storage/venv |
| **Git Version Control** | **PASSED** | git version 2.53.0 |
| **SQLite3 CLI** | **PASSED** | SQLite 3.53.4 |
| **cURL HTTP Utility** | **PASSED** | curl 8.22.0 |
| **OpenSSL Cryptography** | **PASSED** | OpenSSL 3.6.5 |
| **CA Certificates** | **PASSED** | /etc/ssl/certs/ca-certificates.crt |
| **Core Utilities** | **PASSED** | bash, procps, util-linux, rsync, jq |
| **Docker Engine** | **PASSED** | Docker version 28.5.2+dfsg4, build 9cc6dea35e9a963f281434761c656fba4ac43aed |
| **Docker Compose v2** | **PASSED** | Docker Compose version 2.40.3-3 |
| **cloudflared (Opt)** | **PASSED** | cloudflared version 2026.10.7 (built 2026-10-30-17:05 UTC) |

---

## 3. Installed Packages During Setup

No new packages required installation (all prerequisites pre-installed).

---

## 4. Docker Service & Daemon Configuration

- **Docker Service Active**: active
- **Docker Group Membership**: Active (UID in docker group)
- **Compose Version**: Docker Compose version 2.40.3-3
- **Security Check**: Docker socket permissions preserved securely.

---

## 5. Application Database & Storage Preservation

- **Storage Directory**: `/home/spidyno/.song/Mornye-Network-Storage/storage` (Permissions: 755)
- **Database Directory**: `/home/spidyno/.song/Mornye-Network-Storage/database` (Permissions: 700)
- **Database Status**: Preserved & Intact (Never overwritten)
- **Environment Configuration**: `/home/spidyno/.song/Mornye-Network-Storage/.env` (Permissions: 600, Random 64-char SECRET_KEY)
- **Physical Music Files**: 100% preserved.
- **Recycle Bin Records**: 100% preserved.

---

## 6. Final Reconciliation Verdict

- **Required Dependency Errors**: 0
- **Optional Warnings**: 0
- **Overall Setup Status**: **PASSED & READY**

