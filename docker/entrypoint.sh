#!/usr/bin/env bash
# ==============================================================================
# MORNYE CONTAINER ENTRYPOINT
# ==============================================================================
set -eo pipefail

check_persistent_mounts() {
    local perm_failed=false
    local failed_paths=()

    for check_path in "${DATA_PATH:-/data}" "${STORAGE_PATH:-/storage}" "${LOG_PATH:-/logs}"; do
        if [[ -d "$check_path" && ! -w "$check_path" ]]; then
            perm_failed=true
            failed_paths+=("$check_path")
        fi
    done

    if [[ "$perm_failed" == true ]]; then
        echo "================================================================================" >&2
        echo "[!] CRITICAL PERMISSION ERROR: Persistent volume mount is not writable!" >&2
        echo "[!] Container process UID:GID : $(id -u):$(id -g) ($(id -un 2>/dev/null || echo user):$(id -gn 2>/dev/null || echo group))" >&2
        echo "[!] Unwritable directories    : ${failed_paths[*]}" >&2
        for fp in "${failed_paths[@]}"; do
            echo "    * $fp -> $(stat -c '%U:%G (mode %a)' "$fp" 2>/dev/null || ls -ld "$fp" 2>/dev/null || echo "inaccessible")" >&2
        done
        echo "" >&2
        echo "[!] Host system remediation command:" >&2
        echo "    sudo chown -R $(id -u):$(id -g) database storage logs" >&2
        echo "    sudo chmod 750 database storage logs" >&2
        echo "================================================================================" >&2
        # Pause to prevent high-frequency container restart loop in Docker
        sleep 10
        exit 1
    fi
}

# Verify mounts before any operation
check_persistent_mounts

if [[ $# -gt 0 ]]; then
    mkdir -p "${DATA_PATH:-/data}/cache" "${DATA_PATH:-/data}/tmp" "${DATA_PATH:-/data}/recycle_bin" "${STORAGE_PATH:-/storage}" "${LOG_PATH:-/logs}" 2>/dev/null || true
    exec "$@"
fi

echo "[*] Mornye Container Bootstrapping..."
echo "[*] Architecture: $(uname -m), Kernel: $(uname -r)"
echo "[*] Container Execution User: $(id -un 2>/dev/null || echo user) (UID: $(id -u), GID: $(id -g))"

# Ensure persistent directory structure exists safely
mkdir -p "${DATA_PATH:-/data}/cache" 2>/dev/null || true
mkdir -p "${DATA_PATH:-/data}/tmp" 2>/dev/null || true
mkdir -p "${DATA_PATH:-/data}/recycle_bin" 2>/dev/null || true
mkdir -p "${STORAGE_PATH:-/storage}" 2>/dev/null || true
mkdir -p "${LOG_PATH:-/logs}" 2>/dev/null || true

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
