# Security Policy

## 1. Supported Versions

Security updates and patches are actively applied to the following release branches:

| Version | Supported | Status |
| :--- | :--- | :--- |
| **v3.3.x** | :white_check_mark: | Current Active Release |
| **v3.2.x** | :white_check_mark: | Critical Security Patches Only |
| **v3.1.x** | :x: | End of Life (Upgrade Recommended) |
| **< v3.0.0**| :x: | Unsupported Legacy |

---

## 2. Reporting a Vulnerability

The maintainers of Mornye Network Storage take security seriously. If you discover a security vulnerability, **please do NOT report it publicly via GitHub Issues or public discussions.**

### Private Disclosure Channels

Please report vulnerabilities privately via one of the following methods:

1. **GitHub Private Vulnerability Reporting**:
   Navigate to the [Security Advisories](https://github.com/navyaXdev/Mornye-Network-Storage/security/advisories/new) tab on GitHub and submit a private report.
2. **Direct Maintainer Contact**:
   Contact the creator and maintainer **NavyaXdev** directly via GitHub profile: [https://github.com/navyaXdev](https://github.com/navyaXdev).

### What to Include
To help us triage and resolve the issue quickly, please provide:
- A clear description of the vulnerability and potential impact.
- Step-by-step reproduction instructions or a minimal proof of concept (PoC).
- Affected components (e.g. WebDAV engine, Cloudflare manager, Docker configuration, authentication module).
- Operating system, Docker version, and kernel architecture.
- Any suggested remediations or patches if available.

### Response Timeline
- **Initial Acknowledgment**: Within 48 hours.
- **Triage & Assessment**: Within 5 business days.
- **Patch & Advisory Release**: Coordinated with the reporter before public disclosure.

---

## 3. Core Security Architecture & Invariants

Mornye is built with strict defense-in-depth principles:

1. **Argon2id Authentication Boundary**:
   - WebDAV Basic Authentication uses the modern Argon2id password hashing algorithm with OWASP-recommended parameters ($m=65536, t=3, p=4$).
   - Plaintext passwords are never committed to version control, never printed in terminal installation summaries, and never written to container logs.
2. **Zero-Trust Network Ingress**:
   - Cloudflare Tunnels route traffic strictly through encrypted outbound QUIC / HTTP/2 tunnels.
   - Ingress configuration maps exclusively to the internal container WebDAV port (`http://webdav:8000`) on an isolated Docker bridge network (`mornye-net`).
   - Management ports (e.g. 8080/9000) are never exposed via tunnel ingress rules.
   - Host port 8001 is bound to `127.0.0.1` by default, preventing unintended LAN exposure.
3. **Non-Root Execution**:
   - The production container image runs under an unprivileged `mornye` user (UID: 1000, GID: 1000).
   - Host storage directories enforce permission boundaries (`750` for `database/`, `755` for `storage/`, `750` for `backups/`).
4. **Secret Scanning in CI**:
   - Automated secret scanners (`scripts/secret_scan.py`) run on every pull request and pre-commit hook to verify that zero credentials, private keys, or API tokens enter the repository.

