#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — CENTRALIZED PORT & NETWORK MANAGER
# Module: scripts/lib/port_manager.sh
# Purpose: Authoritative port allocation, process owner discovery, collision
#          avoidance, and strict protection for coexisting host services.
# ==============================================================================

# Guard against multiple inclusions
if [[ -n "${MORNYE_PORT_MANAGER_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
MORNYE_PORT_MANAGER_LOADED=1

# Source compatibility engine if available
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$LIB_DIR/compat.sh" ]]; then
    # shellcheck disable=SC1091
    source "$LIB_DIR/compat.sh"
fi

DEFAULT_MORNYE_HOST_PORT=8001
DEFAULT_MORNYE_HOST_BIND="127.0.0.1"
DEFAULT_CONTAINER_PORT=8000

# Known protected host services that Mornye must NEVER commandeer or terminate
PROTECTED_PORTS=(8000 20241 4533 8088 80 443)

# ------------------------------------------------------------------------------
# 1. PORT OCCUPANCY & PROCESS OWNER INSPECTION
# ------------------------------------------------------------------------------

# Returns pipe-delimited string: state|owner|pid|service|is_mornye
port_inspect() {
    local target_port="$1"
    local p_state="free"
    local p_owner="none"
    local p_pid=""
    local p_service="none"
    local p_is_mornye=false

    # Method 1: ss (Socket Statistics)
    if command -v ss &>/dev/null; then
        local ss_line
        ss_line=$(ss -tlpn 2>/dev/null | grep -E ":${target_port}[[:space:]]" | head -n1 || true)
        if [[ -n "$ss_line" ]]; then
            p_state="occupied"
            local proc_field
            proc_field=$(echo "$ss_line" | grep -oE 'users:\(\([^)]+\)\)' || true)
            if [[ -n "$proc_field" ]]; then
                p_owner=$(echo "$proc_field" | grep -oE '"[^"]+"' | head -n1 | tr -d '"' || echo "active_daemon")
                p_pid=$(echo "$proc_field" | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2 || echo "")
            else
                p_owner="active_daemon"
            fi
        fi
    fi

    # Method 2: lsof fallback
    if [[ "$p_state" == "free" ]] && command -v lsof &>/dev/null; then
        local lsof_line
        lsof_line=$(lsof -nP -iTCP:"$target_port" -sTCP:LISTEN 2>/dev/null | tail -n +2 | head -n1 || true)
        if [[ -n "$lsof_line" ]]; then
            p_state="occupied"
            p_owner=$(echo "$lsof_line" | awk '{print $1}')
            p_pid=$(echo "$lsof_line" | awk '{print $2}')
        fi
    fi

    # Method 3: /dev/tcp socket connection probe fallback
    if [[ "$p_state" == "free" ]]; then
        if (echo > "/dev/tcp/127.0.0.1/${target_port}") 2>/dev/null; then
            p_state="occupied"
            p_owner="active_listener"
        fi
    fi

    # Classify Process Ownership & Service Name
    if [[ "$p_state" == "occupied" ]]; then
        if [[ -n "$p_pid" ]] && [[ -f "/proc/$p_pid/cmdline" ]]; then
            local cmdline
            cmdline=$(tr '\0' ' ' < "/proc/$p_pid/cmdline" 2>/dev/null || true)
            
            # Check if owned by SONG Bridge (mornye-storage.service)
            if [[ "$target_port" == "8000" ]] || [[ "$cmdline" == *"mornye-storage"* ]] || [[ "$cmdline" == *"uvicorn"* && "$target_port" == "8000" ]]; then
                p_service="mornye-storage.service (SONG Bridge)"
            # Check if owned by Navidrome
            elif [[ "$target_port" == "4533" ]] || [[ "$cmdline" == *"navidrome"* ]]; then
                p_service="navidrome.service (Music Server)"
            # Check if owned by host Cloudflare Tunnel
            elif [[ "$target_port" == "20241" ]] || [[ "$cmdline" == *"mornye-tunnel"* && "$target_port" == "20241" ]]; then
                p_service="mornye-tunnel.service (Host Cloudflare Metrics)"
            # Check if owned by Mornye WebDAV Container Proxy
            elif [[ "$p_owner" == *"docker-proxy"* ]]; then
                if docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E ":${target_port}->8000" | grep -qw "mornye-webdav"; then
                    p_is_mornye=true
                    p_service="mornye-webdav (Docker Container)"
                    p_owner="docker-proxy (mornye-webdav)"
                fi
            elif [[ "$cmdline" == *"backend.server"* || "$cmdline" == *"webdav_app"* ]]; then
                p_is_mornye=true
                p_service="mornye-webdav (Local Python Engine)"
            fi
        fi

        # Systemd Unit Lookup
        if [[ -n "$p_pid" ]] && [[ "$p_service" == "none" ]] && command -v systemctl &>/dev/null; then
            local unit_name
            unit_name=$(systemctl status "$p_pid" 2>/dev/null | head -n1 | awk '{print $2}' || true)
            if [[ -n "$unit_name" ]]; then
                p_service="$unit_name"
            fi
        fi
    fi

    echo "${p_state}|${p_owner}|${p_pid}|${p_service}|${p_is_mornye}"
}

# ------------------------------------------------------------------------------
# 2. COLLISION AVOIDANCE & FREE PORT ALLOCATION
# ------------------------------------------------------------------------------

port_is_free() {
    local target_port="$1"
    local p_info
    p_info="$(port_inspect "$target_port")"
    local p_state
    IFS="|" read -r p_state _ _ _ _ <<< "$p_info"
    [[ "$p_state" == "free" ]]
}

port_find_next_free() {
    local start_port="${1:-8001}"
    local candidate="$start_port"
    local max_port=$(( start_port + 100 ))

    while [[ "$candidate" -le "$max_port" ]]; do
        # Check against protected ports list
        local is_protected=false
        for pp in "${PROTECTED_PORTS[@]}"; do
            if [[ "$candidate" -eq "$pp" ]]; then
                is_protected=true
                break
            fi
        done

        if [[ "$is_protected" == false ]] && port_is_free "$candidate"; then
            echo "$candidate"
            return 0
        fi
        candidate=$(( candidate + 1 ))
    done

    # Fallback to random unprivileged port
    echo 8080
}

# Resolves host port safely from .env or selects free port avoiding port 8000
port_resolve_host_port() {
    local env_file="${1:-.env}"
    local host_port=""

    if [[ -f "$env_file" ]]; then
        host_port=$(grep -E '^MORNYE_HOST_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 | tr -d '"'"'" | tr -d ' ' || true)
    fi

    if [[ -z "$host_port" ]]; then
        host_port="$DEFAULT_MORNYE_HOST_PORT"
    fi

    # Inspect current binding
    local p_info
    p_info="$(port_inspect "$host_port")"
    local p_state p_owner p_pid p_svc p_is_mornye
    IFS="|" read -r p_state p_owner p_pid p_svc p_is_mornye <<< "$p_info"

    # If occupied by non-Mornye process, allocate next free port
    if [[ "$p_state" == "occupied" && "$p_is_mornye" == false ]]; then
        local alternative
        alternative="$(port_find_next_free 8001)"
        echo "$alternative"
    else
        echo "$host_port"
    fi
}

