# Mornye Network Storage Documentation Hub

Welcome to the official technical documentation directory for **Mornye Network Storage**, an open-source, self-hosted network storage system and RFC 4918 WebDAV server engineered by **NavyaXdev**.

---

## 1. Quick Links

- [Official Documentation Website](https://navyaxdev.github.io/Mornye-Network-Storage/)
- [GitHub Repository](https://github.com/navyaXdev/Mornye-Network-Storage)
- [Release Notes](releases/v3.3.0-release-notes.md)
- [Search Engine & SEO Setup Guide](seo/search-engine-setup.md)

---

## 2. Core Architecture & Operating Guides

| Guide | Description |
| :--- | :--- |
| [Installation Manual](INSTALLATION.md) | Universal installation steps, interactive prompts, and non-interactive flags across all distributions. |
| [CLI Management Manual](MORNYE_CLI_MANUAL.md) | Complete command reference for `./mornye.sh` (lifecycle, auth, quota, diagnostics, and storage). |
| [Docker Deployment Guide](DOCKER_DEPLOYMENT_GUIDE.md) | Multi-stage Docker containerization, `compose.yaml` profiles, and volume mount configurations. |
| [Docker Architecture Reference](DOCKER_ARCHITECTURE.md) | In-depth breakdown of non-root container user mapping (UID 1000) and persistent filesystem layouts. |
| [Docker Setup Instructions](DOCKER_SETUP.md) | Quickstart guide for setting up and running Mornye via Docker and Docker Compose. |
| [Supported Linux Distributions](SUPPORTED_LINUX.md) | Compatibility matrix covering Debian, Ubuntu, Kali, Arch Linux, Fedora, Rocky, openSUSE, and Alpine. |

---

## 3. Cloudflare Zero-Trust & Remote Access

| Guide | Description |
| :--- | :--- |
| [Cloudflare Custom Subdomain](CLOUDFLARE_CUSTOM_DOMAIN.md) | Automated synthesis of `mornye.<root-domain>`, DNS CNAME routing, `--overwrite-dns` conflict handling, and edge TLS. |
| [Cloudflare Tunnel Architecture](CLOUDFLARE_TUNNEL.md) | Overview of Permanent Zero-Trust tunnels vs Ephemeral Quick Tunnels (`trycloudflare.com`). |
| [Custom Domain Setup](CUSTOM_DOMAIN_SETUP.md) | Step-by-step walkthrough for configuring custom domains and origin certificates (`cert.pem`). |
| [Tunnel Troubleshooting](TUNNEL_TROUBLESHOOTING.md) | Diagnostic solutions for certificate discovery, missing credentials, DNS conflicts, and WAN probes. |

---

## 4. Diagnostics, Self-Healing & Security

| Guide | Description |
| :--- | :--- |
| [Universal Diagnostics Report](UNIVERSAL_DIAGNOSTICS_REPORT.md) | Technical report on the 16-scenario system diagnostic engine (`./mornye.sh doctor`). |
| [Interactive Auto-Fix Report](INTERACTIVE_AUTO_FIX_REPORT.md) | Autonomous self-healing implementation for resolving port conflicts and permission issues. |
| [Security Audit Report](SECURITY_AUDIT_REPORT.md) | Comprehensive vulnerability assessment, defense-in-depth principles, and threat models. |
| [Security Remediation Report](SECURITY_REMEDIATION_REPORT.md) | Implementation report on Argon2id hashing, non-root user execution, and secret isolation. |
| [Uninstaller System Report](UNINSTALLER_SYSTEM_REPORT.md) | Documentation of `delete.sh` safe uninstall, complete purge, pre-purge safety backups, and tunnel cleanup. |

---

## 5. Discoverability & Search Registration

- [Search Engine Registration & Verification Guide](seo/search-engine-setup.md): Complete instructions for Google Search Console, Bing Webmaster Tools, IndexNow, and indexing verification.

