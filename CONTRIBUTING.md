# Contributing to Mornye Network Storage

Thank you for your interest in contributing to **Mornye Network Storage**! As an open-source, community-driven project created and maintained by **NavyaXdev**, we welcome contributions ranging from bug fixes and documentation enhancements to architecture improvements and multi-distribution support.

---

## 1. Code of Conduct

All contributors, maintainers, and community members are expected to uphold the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). Please ensure all interactions remain respectful, constructive, and inclusive.

---

## 2. Getting Started

### Prerequisites
Before contributing code, ensure you have:
- A Linux environment (Debian, Ubuntu, Kali, Arch, Fedora, openSUSE, or Alpine) or a Linux VM / WSL2.
- **Git** (`git --version`)
- **Docker Engine** ($\ge 24.0$) and **Docker Compose v2** (`docker compose version`)
- **Python** ($\ge 3.11$) for backend test suites and linting
- Optional: `cloudflared` CLI for Zero-Trust tunnel testing

### Fork and Clone
```bash
# 1. Fork the repository on GitHub: https://github.com/navyaXdev/Mornye-Network-Storage
# 2. Clone your fork locally
git clone https://github.com/<your-username>/Mornye-Network-Storage.git
cd Mornye-Network-Storage

# 3. Add upstream remote
git remote add upstream https://github.com/navyaXdev/Mornye-Network-Storage.git
git fetch upstream
```

---

## 3. Development Workflow

1. **Create a Feature Branch**:
   ```bash
   git checkout -b feat/my-improvement
   # or
   git checkout -b fix/issue-description
   ```

2. **Local Development**:
   - The core WebDAV ASGI engine resides in `webdav/` and `backend/`.
   - The CLI manager is `mornye.sh`.
   - The universal installer is `setup.sh`.
   - Ingress and Cloudflare managers reside in `scripts/cloudflare_manager.sh`.
   - Uninstallation and purge mechanisms reside in `delete.sh`.

3. **Running the Stack Locally**:
   ```bash
   cp .env.example .env
   docker compose build
   docker compose up -d
   ./mornye.sh health
   ```

---

## 4. Testing & Verification

Every pull request must pass the automated test suite before merging. Run tests locally:

```bash
# Core RFC 4918 WebDAV and Quota tests (inside container)
docker exec mornye-webdav pytest tests/test_webdav_rfc4918.py tests/test_quota.py

# Cloudflare custom subdomain regression tests
bash tests/test_cloudflare_subdomain.sh

# Cloudflare Second-System invariant suite
bash tests/test_cloudflare_second_system.sh

# Setup & Cloudflare permission matrix
bash tests/test_setup_and_cloudflare_fixes.sh

# WebDAV Argon2id Authentication suite
bash tests/test_webdav_auth.sh

# Diagnostics & self-healing tests
bash tests/test_diagnostics.sh
bash tests/test_interactive_repair.sh

# Uninstaller safety and purge suite
bash tests/test_uninstaller.sh

# Pre-commit secret scanning
python3 scripts/secret_scan.py
```

---

## 5. Coding Standards

- **Bash Scripts (`mornye.sh`, `setup.sh`, `delete.sh`)**:
  - Follow POSIX shell conventions where applicable.
  - Enforce `set -eo pipefail` for fail-fast error handling.
  - Quote all variables (`"$VAR"`) to prevent word-splitting and globbing.
  - Maintain idempotent execution (re-running a script should not duplicate configurations).
  - Use `dos2unix` to guarantee Unix LF line endings.
- **Python (`backend/`, `webdav/`, `cli/`)**:
  - Follow PEP 8 guidelines.
  - Avoid storing plaintext credentials in configuration or memory.
  - Use Argon2id for password hashing.
  - Ensure compatibility with Python 3.11+.

---

## 6. Commit Guidelines

We follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

- `feat: add automatic Cloudflare custom subdomain configuration`
- `fix: resolve docker webdav permissions and cloudflare cert detection`
- `docs: improve WebDAV Windows connection guide`
- `test: add unit tests for quota enforcement boundary`
- `refactor: optimize database WAL checkpoint handling`

---

## 7. Submitting a Pull Request

1. Ensure all local tests pass with 0 failures.
2. Run `python3 scripts/secret_scan.py` to confirm no secrets, `.env` values, or credentials are staged.
3. Push your branch to your fork:
   ```bash
   git push origin feat/my-improvement
   ```
4. Open a Pull Request against `main` on `navyaXdev/Mornye-Network-Storage`.
5. Complete the PR template checklist. Maintainers will review your submission promptly.

---

## 8. License

By contributing to Mornye Network Storage, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).

