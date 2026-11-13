# Changelog

All notable changes to Mornye Network Storage are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [3.3.0] - 2026-11-12

### Added
- **Automatic Dedicated Cloudflare Subdomain**: When configuring a custom domain in `setup.sh` or via CLI (`./mornye.sh tunnel domain add`), operators only provide their root domain (e.g. `example.com`), and Mornye automatically synthesizes and configures the dedicated subdomain: `mornye.<root-domain>`.
- **RFC 1123 Domain Normalization**: Added `format_and_validate_domain()` to automatically strip protocol schemes (`http://`, `https://`), trailing slashes, URL paths, port numbers, and leading whitespace, with strict rejection of IP addresses, single labels, and invalid TLDs.
- **Anti-Recursion Prefix Stripping**: Automatically strips leading `mornye.` prefixes (e.g., `mornye.example.com` $\to$ `example.com`), preventing duplicate nested subdomains (`mornye.mornye.example.com`).
- **Safe DNS Conflict Resolution**: Added `check_and_create_dns_route()` with automatic `--overwrite-dns` support to update existing CNAME records pointing to stale destinations without touching unrelated zone records.
- **Domain Decoupling & Reset**: Added `./mornye.sh tunnel domain reset` and updated `domain remove` to clean up ingress rules, restore default 404 catch-alls, and wipe metadata cleanly.
- **Safe Cloudflare Tunnel Uninstaller Cleanup**: Implemented interactive 3-option Cloudflare cleanup menu in `delete.sh` (Keep Tunnel, Remove Mornye Tunnel, Cancel) with UUID ownership verification and target-checked DNS deletion.
- **Automated Subdomain Test Suite**: Added `tests/test_cloudflare_subdomain.sh` covering 12 regression scenarios including domain validation, banner output, DNS conflict handling, and reboot persistence.

### Changed
- Improved `setup.sh` Stage 5 and Stage 6 to handle `--domain` and `--root-domain` arguments interchangeably and display the dedicated subdomain in final installation reports.
- Hardened `mornye.sh status` and `mornye.sh start` to display persisted Root Domain, Custom Domain, and public WebDAV URL upon service startup without re-prompting.

---

## [3.2.0] - 2026-11-12

### Added
- **WebDAV Authentication Wizard**: Interactive authentication setup stage in `setup.sh` allowing operators to enable HTTP Basic Authentication with custom or cryptographically generated 16-character passwords.
- **Argon2id Security Engine**: User authentication backed by SQLite and Argon2id password hashing adhering to OWASP recommendations ($m=65536, t=3, p=4$).
- **Authentication Management CLI**: Added `./mornye.sh auth` subcommands (`create-user`, `change-password`, `reset-password`, `auth-status`, `verify-credentials`).
- **Unauthenticated Public WAN Protection Gate**: Enforced an explicit confirmation requirement (`--confirm-unauthenticated` or typing `CONFIRM`) before unauthenticated storage can be exposed publicly via Cloudflare Tunnels.
- **Multi-Path Origin Certificate Discovery**: Automated discovery of modern Argo Tunnel Token certificates (`cert.pem`) across user home, `/root/.cloudflared`, `/etc/cloudflared`, and Mornye configuration directories.

### Fixed
- **Docker Mount Permission Denied**: Resolved `/data` mkdir permission denied errors inside the WebDAV container on modern Linux kernels by properly harmonizing host directory ownership (UID 1000) and hardening permissions (`750` for `database/`, `755` for `storage/`, `750` for `backups/`).
- **Missing Credentials JSON Synthesis**: Added automated token-based credentials JSON reconstruction from base64 tunnel tokens if credentials files are missing or misconfigured.

---

## [3.1.0] - 2026-11-12

### Added
- **Universal Linux Multi-Distribution Installer**: Native package-manager awareness across Debian, Ubuntu, Kali, Arch Linux, Fedora, Rocky Linux, openSUSE, and Alpine Linux (`installers/*.sh`).
- **Containerized Docker Runtime**: Production ASGI WebDAV stack packaged into a multi-stage `Dockerfile` and `compose.yaml` with non-root unprivileged execution (UID 1000).
- **Ephemeral Quick Tunnels**: Support for account-less, temporary `trycloudflare.com` testing tunnels via `./mornye.sh tunnel quick start`.
- **Intelligent Diagnostics & Self-Healing**: Added `./mornye.sh doctor` and `./mornye.sh doctor --fix` for automatic detection and remediation of permission issues, port conflicts, and missing directories.
- **Protected Host Coexistence**: Reallocated default host port to 8001 (internal 8000), protecting existing host daemons (e.g. SONG Bridge) from port collisions or termination.

---

## [3.0.0] - 2026-11-12

### Added
- Initial Linux CLI-first release of Mornye Network Storage.
- Standardized RFC 4918 WebDAV engine supporting `PROPFIND`, `GET`, `PUT`, `MKCOL`, `MOVE`, and `DELETE`.
- Flat physical audio file storage paired with SQLite WAL-backed virtual folder hierarchy.
- Atomic two-phase streaming uploads via `.part` temporary files to prevent incomplete file indexing.
- Library-wide 100 GB quota enforcement with pre-flight storage boundary verification.
- Unified POSIX Bash management interface (`mornye.sh`).

