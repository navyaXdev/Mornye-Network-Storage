#!/usr/bin/env bash
# ==============================================================================
# MORNYE CONTAINER ENTRYPOINT
# ==============================================================================
set -eo pipefail

echo "[*] Mornye Container Bootstrapping..."
echo "[*] Architecture: $(uname -m), Kernel: $(uname -r)"

# Ensure persistent directory structure exists
mkdir -p "${DATA_PATH:-/data}/cache"
mkdir -p "${DATA_PATH:-/data}/tmp"
mkdir -p "${DATA_PATH:-/data}/recycle_bin"
mkdir -p "${STORAGE_PATH:-/storage}"
mkdir -p "${LOG_PATH:-/logs}"

# Initialize database schema if not present
echo "[*] Verifying database schema at ${DATABASE_URL:-sqlite+aiosqlite:////data/mornye.db}..."
python3 -c "
import asyncio
from backend.core.database import init_db
asyncio.run(init_db())
print('[✔] SQLite schema verified and ready.')
" || {
    echo "[!] Warning: Database pre-check encountered an issue, proceeding to server lifespan startup."
}

echo "[*] Launching Mornye WebDAV Engine on 0.0.0.0:${WEBDAV_PORT:-8000}..."
exec python3 -m backend.server
