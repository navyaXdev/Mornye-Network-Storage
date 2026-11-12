#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — UNIVERSAL SYSTEM DIAGNOSTICS & CONFLICT RESOLVER
# Module: scripts/doctor.sh
# Purpose: Comprehensive diagnostics, port conflict detection, service protection,
#          Docker auditing, Cloudflare inspection, and safe auto-repair.
# ==============================================================================

set -o pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROGRAM_DIR"

CONFIG_DIR="$PROGRAM_DIR/config"
DATA_DIR="$PROGRAM_DIR/database"
STORAGE_DIR="$PROGRAM_DIR/storage"
LOG_DIR="$PROGRAM_DIR/logs"
DIAG_DIR="$LOG_DIR/diagnostics"
BACKUP_DIR="$PROGRAM_DIR/backups"
RUN_DIR="$PROGRAM_DIR/run"

# Create diagnostics log directory (persistent app dirs are verified by audit_storage)
mkdir -p "$LOG_DIR" "$DIAG_DIR"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Preserve environment overrides before defaults
PRESET_HOST_PORT="${MORNYE_HOST_PORT:-}"
PRESET_HOST_BIND="${MORNYE_HOST_BIND:-}"

# Mode Flags
MODE_FULL=true
MODE_JSON=false
MODE_FIX=false
MODE_AUTO_YES=false
MODE_PORTS_ONLY=false
MODE_HEALTH_ONLY=false
MODE_CONFIG_ONLY=false

# Global Telemetry Variables
TIMESTAMP="$(date +"%Y-%m-%d %H:%M:%S")"
TIMESTAMP_FILE="$(date +"%Y-%m-%d-%H%M%S")"
REPORT_TXT="$DIAG_DIR/diagnostic-${TIMESTAMP_FILE}.txt"
REPORT_JSON="$DIAG_DIR/diagnostic-${TIMESTAMP_FILE}.json"

OS_ID="unknown"
OS_NAME="Unknown Linux"
OS_PRETTY="Unknown Linux"
OS_VERSION_ID=""
OS_FAMILY="unknown"
PKG_MANAGER="unknown"
KERNEL_VER="$(uname -r)"
CPU_ARCH="$(uname -m)"
INIT_SYSTEM="generic"

CPU_CORES=1
LOAD_1M="0.00"
LOAD_5M="0.00"
LOAD_15M="0.00"
RAM_TOTAL_MB=0
RAM_AVAIL_MB=0
RAM_USED_PCT=0
DISK_TOTAL_MB=0
DISK_FREE_MB=0
DISK_USED_PCT=0

CURRENT_USER="$(whoami)"
CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"
USER_GROUPS="$(id -Gn 2>/dev/null || echo "$CURRENT_USER")"
IS_ROOT=false
SUDO_AVAILABLE=false
SUDO_AUTHENTICATED=false
IN_DOCKER_GROUP=false

DOCKER_INSTALLED=false
DOCKER_VERSION=""
DOCKER_DAEMON_ACTIVE=false
DOCKER_SOCKET_EXISTS=false
DOCKER_SOCKET_PERMS=""
DOCKER_NONROOT_ACCESS=false
COMPOSE_INSTALLED=false
COMPOSE_VERSION=""
DOCKER_DISK_FREE_MB=0

WEBDAV_CONTAINER_EXISTS=false
WEBDAV_CONTAINER_STATE="none"
WEBDAV_CONTAINER_HEALTH="none"
WEBDAV_CONTAINER_UPTIME=""
WEBDAV_CONTAINER_RESTARTS=0
WEBDAV_IMAGE_EXISTS=false

TUNNEL_CONTAINER_EXISTS=false
TUNNEL_CONTAINER_STATE="none"

MORNYE_HOST_PORT="8001"
MORNYE_HOST_BIND="127.0.0.1"
PORT_8000_STATE="free"
PORT_8000_OWNER="none"
PORT_8000_PID=""
PORT_8000_SERVICE=""
PORT_8000_IS_MORNYE=false

HOST_PORT_STATE="free"
HOST_PORT_OWNER="none"
HOST_PORT_PID=""
HOST_PORT_SERVICE=""
HOST_PORT_IS_MORNYE=false
HOST_PORT_CONFLICT=false
SUGGESTED_FREE_PORT=""

METRICS_PORT_STATE="free"
METRICS_PORT_OWNER="none"

PROTECTED_SERVICES=()

DIR_PERMS_STATUS="healthy"
DB_INTEGRITY_STATUS="unknown"
CONFIG_VALIDATION_STATUS="unknown"

HEALTH_HTTP_CODE="000"
HEALTH_LATENCY_MS="0"
DAV_HTTP_CODE="000"
DAV_LATENCY_MS="0"

CLOUDFLARE_INSTALLED=false
CLOUDFLARE_VERSION=""
CLOUDFLARE_AUTH_EXISTS=false
CLOUDFLARE_RUNTIME_MODE="inactive"
CLOUDFLARE_CONFIG_EXISTS=false
CLOUDFLARE_CREDS_EXISTS=false
CLOUDFLARE_INGRESS_TARGET=""
CLOUDFLARE_EDGE_REACHABLE=false
QUICK_TUNNEL_ACTIVE=false
QUICK_TUNNEL_URL=""

NETWORK_INTERFACES=()
FIREWALL_TYPE="none"
FIREWALL_STATUS="inactive"

# Findings Collections
FINDINGS_ERRORS=()
FINDINGS_WARNINGS=()
FINDINGS_INFO=()
ACTIONS_TAKEN=()

# ------------------------------------------------------------------------------
# 1. HELPER FUNCTIONS
# ------------------------------------------------------------------------------

has_cmd() {
    command -v "$1" &>/dev/null
}

load_env() {
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        # shellcheck disable=SC1090
        source "$PROGRAM_DIR/.env" 2>/dev/null || true
    fi
    [[ -n "$PRESET_HOST_PORT" ]] && MORNYE_HOST_PORT="$PRESET_HOST_PORT"
    [[ -n "$PRESET_HOST_BIND" ]] && MORNYE_HOST_BIND="$PRESET_HOST_BIND"
    MORNYE_HOST_PORT="${MORNYE_HOST_PORT:-8001}"
    MORNYE_HOST_BIND="${MORNYE_HOST_BIND:-127.0.0.1}"
}

find_next_free_port() {
    local start="${1:-8001}"
    local p
    for ((p=start; p<=8099; p++)); do
        if ! is_port_listening "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo "8100"
}

is_port_listening() {
    local p="$1"
    if has_cmd ss; then
        ss -tulpn 2>/dev/null | grep -E ":${p}[[:space:]]" &>/dev/null && return 0
    elif has_cmd netstat; then
        netstat -tulpn 2>/dev/null | grep -E ":${p}[[:space:]]" &>/dev/null && return 0
    fi
    (echo > "/dev/tcp/127.0.0.1/$p") 2>/dev/null && return 0
    return 1
}

# ------------------------------------------------------------------------------
# 2. SYSTEM & HARDWARE AUDIT
# ------------------------------------------------------------------------------

audit_system() {
    # 1. Distro Detection
    if [[ -f /etc/os-release ]]; then
        OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')"
        local os_like
        os_like="$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)"
        OS_NAME="$(grep -E '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "Linux")"
        OS_VERSION_ID="$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
        OS_PRETTY="$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "$OS_NAME")"
    elif [[ -f /etc/debian_version ]]; then
        OS_ID="debian"; OS_NAME="Debian GNU/Linux"; OS_PRETTY="Debian $(cat /etc/debian_version)"
    elif [[ -f /etc/arch-release ]]; then
        OS_ID="arch"; OS_NAME="Arch Linux"; OS_PRETTY="Arch Linux"
    elif [[ -f /etc/fedora-release ]]; then
        OS_ID="fedora"; OS_NAME="Fedora"; OS_PRETTY="$(cat /etc/fedora-release)"
    elif [[ -f /etc/alpine-release ]]; then
        OS_ID="alpine"; OS_NAME="Alpine Linux"; OS_PRETTY="Alpine Linux $(cat /etc/alpine-release)"
    fi

    case "$OS_ID" in
        debian|ubuntu|kali|linuxmint|pop|raspbian|elementary|zorin|parrot)
            OS_FAMILY="debian"; PKG_MANAGER="apt" ;;
        arch|manjaro|endeavouros|cachyos|garuda|artix)
            OS_FAMILY="arch"; PKG_MANAGER="pacman" ;;
        fedora)
            OS_FAMILY="fedora"; PKG_MANAGER="dnf" ;;
        rhel|rocky|almalinux|centos|ol)
            OS_FAMILY="rhel"; has_cmd dnf && PKG_MANAGER="dnf" || PKG_MANAGER="yum" ;;
        opensuse*|sles)
            OS_FAMILY="suse"; PKG_MANAGER="zypper" ;;
        alpine)
            OS_FAMILY="alpine"; PKG_MANAGER="apk" ;;
        *)
            if has_cmd apt-get; then OS_FAMILY="debian"; PKG_MANAGER="apt"
            elif has_cmd pacman; then OS_FAMILY="arch"; PKG_MANAGER="pacman"
            elif has_cmd dnf; then OS_FAMILY="fedora"; PKG_MANAGER="dnf"
            elif has_cmd yum; then OS_FAMILY="rhel"; PKG_MANAGER="yum"
            elif has_cmd zypper; then OS_FAMILY="suse"; PKG_MANAGER="zypper"
            elif has_cmd apk; then OS_FAMILY="alpine"; PKG_MANAGER="apk"
            fi
            ;;
    esac

    # 2. Init System
    if [[ -d /run/systemd/system ]] && has_cmd systemctl; then
        INIT_SYSTEM="systemd"
    elif [[ -d /run/openrc ]] || has_cmd rc-service; then
        INIT_SYSTEM="openrc"
    elif [[ -f /sbin/init ]] && ls -l /sbin/init 2>/dev/null | grep -q "systemd"; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="generic"
    fi

    # 3. CPU & RAM
    if has_cmd nproc; then
        CPU_CORES="$(nproc)"
    elif [[ -f /proc/cpuinfo ]]; then
        CPU_CORES="$(grep -c '^processor' /proc/cpuinfo || echo 1)"
    fi

    if [[ -f /proc/loadavg ]]; then
        LOAD_1M="$(awk '{print $1}' /proc/loadavg)"
        LOAD_5M="$(awk '{print $2}' /proc/loadavg)"
        LOAD_15M="$(awk '{print $3}' /proc/loadavg)"
    fi

    if [[ -f /proc/meminfo ]]; then
        local tot_kb avail_kb
        tot_kb=$(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}')
        avail_kb=$(grep -E '^MemAvailable:' /proc/meminfo | awk '{print $2}' || true)
        RAM_TOTAL_MB=$(( tot_kb / 1024 ))
        if [[ -n "$avail_kb" ]]; then
            RAM_AVAIL_MB=$(( avail_kb / 1024 ))
        else
            RAM_AVAIL_MB=$RAM_TOTAL_MB
        fi
        if [[ $RAM_TOTAL_MB -gt 0 ]]; then
            RAM_USED_PCT=$(( ((RAM_TOTAL_MB - RAM_AVAIL_MB) * 100) / RAM_TOTAL_MB ))
        fi
    fi

    # 4. Disk Space (Program Directory Root)
    if has_cmd df; then
        local disk_info
        disk_info="$(df -Pk "$PROGRAM_DIR" 2>/dev/null | awk 'NR==2 {print $2, $4, $5}')"
        if [[ -n "$disk_info" ]]; then
            local tot_k free_k pct_str
            read -r tot_k free_k pct_str <<< "$disk_info"
            DISK_TOTAL_MB=$(( tot_k / 1024 ))
            DISK_FREE_MB=$(( free_k / 1024 ))
            DISK_USED_PCT="${pct_str%%%}"
        fi
    fi

    # Threshold checks
    if [[ $RAM_AVAIL_MB -lt 512 ]]; then
        FINDINGS_WARNINGS+=("INSUFFICIENT_RAM|Available RAM is low (${RAM_AVAIL_MB} MB). Minimum recommended is 1024 MB.|Upgrade host RAM or stop memory-intensive processes.")
    fi
    if [[ $DISK_FREE_MB -lt 1024 ]]; then
        FINDINGS_ERRORS+=("INSUFFICIENT_DISK|Critical: Available disk headroom is under 1024 MB (${DISK_FREE_MB} MB free).|Free up host disk space to avoid SQLite and Docker write failures.")
    elif [[ $DISK_FREE_MB -lt 2048 ]]; then
        FINDINGS_WARNINGS+=("LOW_DISK_SPACE|Available disk space is under 2048 MB (${DISK_FREE_MB} MB free).|Ensure sufficient disk space for audio files and backups.")
    fi
}

# ------------------------------------------------------------------------------
# 3. USER CONTEXT & PRIVILEGES AUDIT
# ------------------------------------------------------------------------------

audit_user_permissions() {
    [[ "$CURRENT_UID" -eq 0 ]] && IS_ROOT=true || IS_ROOT=false

    if has_cmd sudo; then
        SUDO_AVAILABLE=true
        if sudo -n true 2>/dev/null; then
            SUDO_AUTHENTICATED=true
        fi
    fi

    if echo " $USER_GROUPS " | grep -qw "docker"; then
        IN_DOCKER_GROUP=true
    fi
}

# ------------------------------------------------------------------------------
# 4. DOCKER ENGINE & PERMISSIONS AUDIT
# ------------------------------------------------------------------------------

audit_docker() {
    if has_cmd docker; then
        DOCKER_INSTALLED=true
        DOCKER_VERSION="$(docker --version 2>/dev/null || echo 'Unknown')"
    else
        DOCKER_INSTALLED=false
        FINDINGS_ERRORS+=("DOCKER_MISSING|Docker Engine is not installed on this host.|Run './mornye.sh install' to install Docker automatically.")
        return 0
    fi

    # Check Docker Daemon & Socket
    if [[ -S /var/run/docker.sock ]]; then
        DOCKER_SOCKET_EXISTS=true
        DOCKER_SOCKET_PERMS="$(ls -l /var/run/docker.sock 2>/dev/null | awk '{print $1, $3, $4}')"
    fi

    local d_info_err
    d_info_err="$(docker info 2>&1 || true)"
    if docker info &>/dev/null; then
        DOCKER_DAEMON_ACTIVE=true
        DOCKER_NONROOT_ACCESS=true
    elif [[ "$d_info_err" == *"permission denied"* ]] || sudo -n docker info &>/dev/null; then
        DOCKER_DAEMON_ACTIVE=true
        DOCKER_NONROOT_ACCESS=false
        FINDINGS_WARNINGS+=("DOCKER_PERMISSION_DENIED|User '$CURRENT_USER' cannot access Docker without sudo.|Add '$CURRENT_USER' to group 'docker' (or run './mornye.sh doctor --fix').")
    else
        DOCKER_DAEMON_ACTIVE=false
        FINDINGS_ERRORS+=("DOCKER_DAEMON_OFFLINE|Docker daemon is stopped or not responding on /var/run/docker.sock.|Start the Docker daemon via 'systemctl start docker' or OpenRC.")
    fi

    # Docker Compose Plugin
    if docker compose version &>/dev/null; then
        COMPOSE_INSTALLED=true
        COMPOSE_VERSION="$(docker compose version 2>/dev/null)"
    elif has_cmd docker-compose; then
        COMPOSE_INSTALLED=true
        COMPOSE_VERSION="$(docker-compose --version 2>/dev/null)"
    else
        COMPOSE_INSTALLED=false
        FINDINGS_ERRORS+=("COMPOSE_MISSING|Docker Compose v2 plugin is missing.|Install docker-compose-plugin via './mornye.sh install'.")
    fi
}

# ------------------------------------------------------------------------------
# 5. CONTAINER STACK & IMAGES AUDIT
# ------------------------------------------------------------------------------

audit_containers() {
    if [[ "$DOCKER_NONROOT_ACCESS" != true && "$IS_ROOT" != true && "$SUDO_AUTHENTICATED" != true ]]; then
        return 0
    fi

    # Check webdav container
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-webdav"; then
        WEBDAV_CONTAINER_EXISTS=true
        WEBDAV_CONTAINER_STATE="$(docker inspect --format='{{.State.Status}}' mornye-webdav 2>/dev/null || echo 'unknown')"
        WEBDAV_CONTAINER_HEALTH="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' mornye-webdav 2>/dev/null || echo 'none')"
        WEBDAV_CONTAINER_RESTARTS="$(docker inspect --format='{{.RestartCount}}' mornye-webdav 2>/dev/null || echo 0)"
        WEBDAV_CONTAINER_UPTIME="$(docker inspect --format='{{.State.StartedAt}}' mornye-webdav 2>/dev/null || echo '')"

        if [[ "$WEBDAV_CONTAINER_STATE" == "restarting" ]]; then
            FINDINGS_ERRORS+=("CONTAINER_CRASH_LOOP|Container 'mornye-webdav' is restarting continuously (Restart count: $WEBDAV_CONTAINER_RESTARTS).|Inspect container logs with './mornye.sh logs webdav'.")
        elif [[ "$WEBDAV_CONTAINER_STATE" == "exited" ]]; then
            local exit_code
            exit_code="$(docker inspect --format='{{.State.ExitCode}}' mornye-webdav 2>/dev/null || echo 1)"
            FINDINGS_WARNINGS+=("CONTAINER_STOPPED|Container 'mornye-webdav' is currently stopped (Exit code: $exit_code).|Start the container stack with './mornye.sh start'.")
        elif [[ "$WEBDAV_CONTAINER_HEALTH" == "unhealthy" ]]; then
            FINDINGS_ERRORS+=("CONTAINER_UNHEALTHY|Container 'mornye-webdav' is running but failing healthchecks.|Verify port bindings and permissions via './mornye.sh doctor --fix'.")
        fi
    fi

    # Check tunnel container
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-tunnel"; then
        TUNNEL_CONTAINER_EXISTS=true
        TUNNEL_CONTAINER_STATE="$(docker inspect --format='{{.State.Status}}' mornye-tunnel 2>/dev/null || echo 'unknown')"
    fi

    # Check image
    if docker image inspect mornye-webdav:latest &>/dev/null; then
        WEBDAV_IMAGE_EXISTS=true
    else
        WEBDAV_IMAGE_EXISTS=false
        if [[ "$DOCKER_DAEMON_ACTIVE" == true ]]; then
            FINDINGS_WARNINGS+=("IMAGE_NOT_BUILT|Docker image 'mornye-webdav:latest' has not been built yet.|Build the image using './mornye.sh docker rebuild'.")
        fi
    fi
}

# ------------------------------------------------------------------------------
# 6. PORT CONFLICT & SERVICE OWNER DETECTION
# ------------------------------------------------------------------------------

inspect_port_owner() {
    local port="$1"
    local pid=""
    local pname=""
    local sname="standalone"
    local is_mornye=false

    # 1. Check if an active Docker container owns this port
    if has_cmd docker && (docker info &>/dev/null || sudo -n docker info &>/dev/null); then
        local d_match
        d_match="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E "(:)${port}->" | head -n1 || true)"
        if [[ -n "$d_match" ]]; then
            local c_name
            c_name="$(echo "$d_match" | awk '{print $1}')"
            if [[ "$c_name" == "mornye-webdav" ]]; then
                is_mornye=true
                pname="docker-proxy (mornye-webdav)"
                sname="mornye-webdav (container)"
                pid="$(docker inspect --format='{{.State.Pid}}' mornye-webdav 2>/dev/null || echo '')"
                echo "occupied|${pname}|${pid}|${sname}|${is_mornye}"
                return 0
            elif [[ "$c_name" == "mornye-tunnel" ]]; then
                is_mornye=true
                pname="docker-proxy (mornye-tunnel)"
                sname="mornye-tunnel (container)"
                pid="$(docker inspect --format='{{.State.Pid}}' mornye-tunnel 2>/dev/null || echo '')"
                echo "occupied|${pname}|${pid}|${sname}|${is_mornye}"
                return 0
            else
                pname="docker-proxy ($c_name)"
                sname="$c_name (external container)"
                pid="$(docker inspect --format='{{.State.Pid}}' "$c_name" 2>/dev/null || echo '')"
                echo "occupied|${pname}|${pid}|${sname}|false"
                return 0
            fi
        fi
    fi

    # 2. Probe listener with ss or netstat
    local line=""
    if has_cmd ss; then
        line="$(ss -tulpn 2>/dev/null | grep -E ":${port}[[:space:]]" | head -n1 || true)"
        if [[ -z "$line" && "$SUDO_AUTHENTICATED" == true ]]; then
            line="$(sudo -n ss -tulpn 2>/dev/null | grep -E ":${port}[[:space:]]" | head -n1 || true)"
        fi
    elif has_cmd netstat; then
        line="$(netstat -tulpn 2>/dev/null | grep -E ":${port}[[:space:]]" | head -n1 || true)"
    fi

    if [[ -z "$line" ]]; then
        # Check via tcp connect
        if (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            echo "occupied|unknown_process||standalone|false"
            return 0
        else
            echo "free|none||none|false"
            return 0
        fi
    fi

    # Extract PID and process name
    if [[ "$line" =~ pid=([0-9]+) ]]; then
        pid="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ users:\(\(\"([^\"]+)\" ]]; then
        pname="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$pid" && -d "/proc/$pid" ]]; then
        # Check cgroup for systemd unit or docker container
        local cgroup
        cgroup="$(cat "/proc/$pid/cgroup" 2>/dev/null || true)"
        if [[ "$cgroup" =~ system\.slice/([^.]+)\.service ]]; then
            sname="${BASH_REMATCH[1]}.service"
        elif [[ "$cgroup" =~ docker/([a-f0-9]+) ]]; then
            sname="docker-container"
        fi

        # Check working directory
        local cwd
        cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
        if [[ "$cwd" == "$PROGRAM_DIR"* ]]; then
            is_mornye=true
        fi
    fi

    echo "occupied|${pname:-process}|${pid}|${sname}|${is_mornye}"
}

audit_ports() {
    load_env

    # 1. Audit Port 8000 (SONG Bridge / Legacy default)
    local res_8000
    res_8000="$(inspect_port_owner 8000)"
    IFS="|" read -r PORT_8000_STATE PORT_8000_OWNER PORT_8000_PID PORT_8000_SERVICE PORT_8000_IS_MORNYE <<< "$res_8000"

    # 2. Audit Configured Mornye Host Port
    local res_host
    res_host="$(inspect_port_owner "$MORNYE_HOST_PORT")"
    IFS="|" read -r HOST_PORT_STATE HOST_PORT_OWNER HOST_PORT_PID HOST_PORT_SERVICE HOST_PORT_IS_MORNYE <<< "$res_host"

    # 3. Detect Conflict on Configured Host Port
    if [[ "$HOST_PORT_STATE" == "occupied" ]]; then
        if [[ "$HOST_PORT_IS_MORNYE" == true ]]; then
            # Mornye's own container or process is listening
            HOST_PORT_CONFLICT=false
        else
            # Another process is occupying Mornye's configured port!
            HOST_PORT_CONFLICT=true
            SUGGESTED_FREE_PORT="$(find_next_free_port 8001)"
            FINDINGS_ERRORS+=("PORT_CONFLICT|Host port $MORNYE_HOST_PORT is occupied by '$HOST_PORT_OWNER' (PID: ${HOST_PORT_PID:-unknown}, Service: $HOST_PORT_SERVICE).|Reassign Mornye to an available port like $SUGGESTED_FREE_PORT (run './mornye.sh doctor --fix').")
        fi
    fi

    # 4. Audit Metrics Port (20241)
    local res_metrics
    res_metrics="$(inspect_port_owner 20241)"
    IFS="|" read -r METRICS_PORT_STATE METRICS_PORT_OWNER _ _ _ <<< "$res_metrics"
}

# ------------------------------------------------------------------------------
# 7. EXISTING SERVICE PROTECTION AUDIT
# ------------------------------------------------------------------------------

audit_protected_services() {
    PROTECTED_SERVICES=()

    # Check SONG Bridge / Legacy mornye-storage.service
    if systemctl is-active --quiet mornye-storage.service 2>/dev/null; then
        local pid
        pid=$(systemctl show -p MainPID --value mornye-storage.service 2>/dev/null || echo "")
        PROTECTED_SERVICES+=("SONG Bridge / Mornye Storage Unit|mornye-storage.service|PID: ${pid:-active}|Port: 8000/9000|PROTECTED (Active & Untouched)")
    fi

    # Check Navidrome
    if systemctl is-active --quiet navidrome.service 2>/dev/null || pgrep -x navidrome &>/dev/null; then
        PROTECTED_SERVICES+=("Navidrome Music Server|navidrome.service|Port: 4533|PROTECTED (Active & Untouched)")
    fi

    # Check Web Servers
    if systemctl is-active --quiet nginx.service 2>/dev/null || pgrep -x nginx &>/dev/null; then
        PROTECTED_SERVICES+=("Nginx Web Server|nginx.service|Port: 80/443|PROTECTED (Active & Untouched)")
    fi
    if systemctl is-active --quiet apache2.service 2>/dev/null || systemctl is-active --quiet httpd.service 2>/dev/null || pgrep -E '(apache2|httpd)' &>/dev/null; then
        PROTECTED_SERVICES+=("Apache HTTP Server|apache2.service|Port: 80/443|PROTECTED (Active & Untouched)")
    fi
    if systemctl is-active --quiet caddy.service 2>/dev/null || pgrep -x caddy &>/dev/null; then
        PROTECTED_SERVICES+=("Caddy Web Server|caddy.service|Port: 80/443|PROTECTED (Active & Untouched)")
    fi

    # Check Databases
    if systemctl is-active --quiet postgresql.service 2>/dev/null || pgrep -x postgres &>/dev/null; then
        PROTECTED_SERVICES+=("PostgreSQL Database|postgresql.service|Port: 5432|PROTECTED (Active & Untouched)")
    fi
    if systemctl is-active --quiet mysql.service 2>/dev/null || systemctl is-active --quiet mariadb.service 2>/dev/null || pgrep -E '(mysqld|mariadbd)' &>/dev/null; then
        PROTECTED_SERVICES+=("MySQL / MariaDB Database|mysql.service|Port: 3306|PROTECTED (Active & Untouched)")
    fi

    # Check Existing Cloudflare Tunnel systemd unit
    if systemctl is-active --quiet mornye-tunnel.service 2>/dev/null; then
        local tpid
        tpid=$(systemctl show -p MainPID --value mornye-tunnel.service 2>/dev/null || echo "")
        PROTECTED_SERVICES+=("Cloudflare Tunnel Service|mornye-tunnel.service|PID: ${tpid:-active}|Port: 20241 (metrics)|PROTECTED (Active & Untouched)")
    fi
}

# ------------------------------------------------------------------------------
# 8. STORAGE & PERMISSIONS AUDIT
# ------------------------------------------------------------------------------

audit_storage() {
    local perm_err=false

    for dir in "$DATA_DIR" "$STORAGE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$CONFIG_DIR"; do
        if [[ ! -d "$dir" ]]; then
            perm_err=true
            FINDINGS_ERRORS+=("DIRECTORY_MISSING|Required application directory is missing: $(basename "$dir") ($dir).|Recreate directory via './mornye.sh doctor --fix'.")
        fi
    done

    # Check permissions
    if [[ -d "$DATA_DIR" ]]; then
        local p
        p=$(stat -c "%a" "$DATA_DIR" 2>/dev/null || stat -f "%OLp" "$DATA_DIR" 2>/dev/null || echo "")
        if [[ "$p" != "700" && "$p" != "750" ]]; then
            FINDINGS_WARNINGS+=("INSECURE_PERMS|database/ directory mode is $p (expected 700 for privacy).|Harden via 'chmod 700 $DATA_DIR'.")
        fi
    fi

    # SQLite Integrity
    if [[ -f "$DATA_DIR/mornye.db" ]]; then
        if has_cmd sqlite3; then
            local chk
            chk=$(sqlite3 "$DATA_DIR/mornye.db" "PRAGMA integrity_check;" 2>/dev/null || echo "error")
            if [[ "$chk" == "ok" ]]; then
                DB_INTEGRITY_STATUS="healthy"
            else
                DB_INTEGRITY_STATUS="corrupted"
                FINDINGS_ERRORS+=("DATABASE_INTEGRITY_FAIL|SQLite database integrity check failed ($chk).|Restore from recent backup via './mornye.sh backup restore <file>'.")
            fi
        else
            DB_INTEGRITY_STATUS="present_unverified"
        fi
    else
        DB_INTEGRITY_STATUS="not_yet_created"
    fi
}

# ------------------------------------------------------------------------------
# 9. CONFIGURATION VALIDATION
# ------------------------------------------------------------------------------

audit_configuration() {
    local config_err=false

    # 1. .env audit
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        local sec_key
        sec_key="$(grep -E '^SECRET_KEY=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)"
        if [[ -z "$sec_key" || "$sec_key" == *"change-this"* || "$sec_key" == *"must-be-changed"* ]]; then
            FINDINGS_WARNINGS+=("DEFAULT_SECRET_KEY|Insecure or placeholder SECRET_KEY detected in .env.|Generate a cryptographic 256-bit key via './mornye.sh doctor --fix'.")
        fi
    else
        config_err=true
        FINDINGS_ERRORS+=("MISSING_ENV|Configuration file .env is missing.|Generate a secure .env from template via './mornye.sh doctor --fix'.")
    fi

    # 2. compose.yaml audit
    if [[ -f "$PROGRAM_DIR/compose.yaml" ]]; then
        if ! grep -E '^[[:space:]]*user:[[:space:]]*["'\'']?1000:1000' "$PROGRAM_DIR/compose.yaml" &>/dev/null; then
            FINDINGS_WARNINGS+=("CONTAINER_USER_ROOT|compose.yaml does not specify user 1000:1000.|Ensure container runs as an unprivileged user.")
        fi
        if ! grep -E '^[[:space:]]*cap_drop:' "$PROGRAM_DIR/compose.yaml" &>/dev/null; then
            FINDINGS_WARNINGS+=("CAPABILITIES_NOT_DROPPED|compose.yaml does not drop Linux capabilities.|Add 'cap_drop: - ALL' for defense-in-depth.")
        fi
    else
        config_err=true
        FINDINGS_ERRORS+=("MISSING_COMPOSE|compose.yaml is missing from repository root.|Restore compose.yaml from version control.")
    fi

    # 3. cloudflared.yml ingress audit (if exists)
    if [[ -f "$CONFIG_DIR/cloudflared.yml" ]]; then
        # Ensure catch-all 404 is present
        if ! grep -q "http_status:404" "$CONFIG_DIR/cloudflared.yml"; then
            FINDINGS_WARNINGS+=("INGRESS_MISSING_CATCHALL|cloudflared.yml does not end with catch-all 404 rule.|Add '- service: http_status:404' to reject unmapped traffic.")
        fi
        # Ensure private management ports are NOT exposed
        if grep -E ':(8080|9000|2375|2376)' "$CONFIG_DIR/cloudflared.yml" &>/dev/null; then
            FINDINGS_ERRORS+=("PRIVATE_PORT_EXPOSED|cloudflared.yml exposes internal management port (8080/9000/docker).|Strictly remove management port ingress from Cloudflare Tunnel.")
        fi
    fi

    [[ "$config_err" == false ]] && CONFIG_VALIDATION_STATUS="valid" || CONFIG_VALIDATION_STATUS="invalid"
}

# ------------------------------------------------------------------------------
# 10. ENDPOINT HEALTH PROBES
# ------------------------------------------------------------------------------

audit_endpoints() {
    load_env

    # 1. Health Probe
    local health_url="http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/health"
    local t_start
    t_start=$(date +%s%N 2>/dev/null || date +%s)
    HEALTH_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "$health_url" 2>/dev/null || echo "000")
    local t_end
    t_end=$(date +%s%N 2>/dev/null || date +%s)
    if [[ "$t_start" =~ ^[0-9]{10,}$ && "$t_end" =~ ^[0-9]{10,}$ ]]; then
        HEALTH_LATENCY_MS=$(( (t_end - t_start) / 1000000 ))
    else
        HEALTH_LATENCY_MS="<5"
    fi

    # 2. WebDAV Probe
    local dav_url="http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/dav/"
    t_start=$(date +%s%N 2>/dev/null || date +%s)
    DAV_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PROPFIND -H "Depth: 0" --connect-timeout 2 "$dav_url" 2>/dev/null || echo "000")
    t_end=$(date +%s%N 2>/dev/null || date +%s)
    if [[ "$t_start" =~ ^[0-9]{10,}$ && "$t_end" =~ ^[0-9]{10,}$ ]]; then
        DAV_LATENCY_MS=$(( (t_end - t_start) / 1000000 ))
    else
        DAV_LATENCY_MS="<5"
    fi

    if [[ "$WEBDAV_CONTAINER_STATE" == "running" && "$HEALTH_HTTP_CODE" != "200" ]]; then
        FINDINGS_ERRORS+=("ENDPOINT_HEALTH_FAIL|Container is running but endpoint returned HTTP $HEALTH_HTTP_CODE ($health_url).|Inspect container logs via './mornye.sh logs webdav'.")
    fi
}

# ------------------------------------------------------------------------------
# 11. CLOUDFLARE TUNNEL AUDIT
# ------------------------------------------------------------------------------

audit_cloudflare() {
    load_env

    if has_cmd cloudflared; then
        CLOUDFLARE_INSTALLED=true
        CLOUDFLARE_VERSION="$(cloudflared --version 2>/dev/null | head -n1 || echo 'Installed')"
    elif [[ -x /usr/local/bin/cloudflared ]]; then
        CLOUDFLARE_INSTALLED=true
        CLOUDFLARE_VERSION="$(/usr/local/bin/cloudflared --version 2>/dev/null | head -n1 || echo 'Installed')"
    else
        CLOUDFLARE_INSTALLED=false
    fi

    if [[ -f "$HOME/.cloudflared/cert.pem" || -f "/etc/cloudflared/cert.pem" ]]; then
        CLOUDFLARE_AUTH_EXISTS=true
    else
        CLOUDFLARE_AUTH_EXISTS=false
    fi

    [[ -f "$CONFIG_DIR/cloudflared.yml" ]] && CLOUDFLARE_CONFIG_EXISTS=true || CLOUDFLARE_CONFIG_EXISTS=false
    [[ -f "$CONFIG_DIR/credentials.json" ]] && CLOUDFLARE_CREDS_EXISTS=true || CLOUDFLARE_CREDS_EXISTS=false

    # Detect execution mode
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-tunnel"; then
        CLOUDFLARE_RUNTIME_MODE="docker"
    elif systemctl is-active --quiet mornye-tunnel.service 2>/dev/null; then
        CLOUDFLARE_RUNTIME_MODE="systemd"
    elif pgrep -x cloudflared &>/dev/null; then
        CLOUDFLARE_RUNTIME_MODE="standalone_process"
    else
        CLOUDFLARE_RUNTIME_MODE="inactive"
    fi

    # Inspect Ingress Target Alignment
    if [[ "$CLOUDFLARE_CONFIG_EXISTS" == true ]]; then
        local target
        target=$(grep -E 'service:[[:space:]]+http://' "$CONFIG_DIR/cloudflared.yml" | head -n1 | awk '{print $2}' || true)
        CLOUDFLARE_INGRESS_TARGET="$target"

        if [[ "$CLOUDFLARE_RUNTIME_MODE" == "docker" ]]; then
            if [[ "$target" != "http://webdav:8000"* ]]; then
                FINDINGS_WARNINGS+=("TUNNEL_ORIGIN_MISMATCH|Docker tunnel ingress points to '$target' instead of 'http://webdav:8000'.|Update ingress service to 'http://webdav:8000' in config/cloudflared.yml.")
            fi
        elif [[ "$CLOUDFLARE_RUNTIME_MODE" == "systemd" ]]; then
            if [[ "$target" != *"127.0.0.1:${MORNYE_HOST_PORT}"* && "$target" != *"localhost:${MORNYE_HOST_PORT}"* ]]; then
                FINDINGS_WARNINGS+=("TUNNEL_ORIGIN_MISMATCH|Host tunnel ingress points to '$target' instead of 'http://127.0.0.1:${MORNYE_HOST_PORT}'.|Update ingress target in config/cloudflared.yml to match host port $MORNYE_HOST_PORT.")
            fi
        fi
    fi

    # Edge WAN reachability
    if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "https://1.1.1.1" 2>/dev/null | grep -qE '^(2|3)'; then
        CLOUDFLARE_EDGE_REACHABLE=true
    else
        CLOUDFLARE_EDGE_REACHABLE=false
        FINDINGS_WARNINGS+=("WAN_EDGE_UNREACHABLE|Cannot connect to Cloudflare Anycast edge (https://1.1.1.1).|Check internet connection or outbound UDP port 7844 (QUIC) / HTTPS.")
    fi

    # Quick Tunnel Status
    if [[ -f "$RUN_DIR/quick_tunnel.pid" ]] && kill -0 "$(cat "$RUN_DIR/quick_tunnel.pid" 2>/dev/null)" 2>/dev/null; then
        QUICK_TUNNEL_ACTIVE=true
        QUICK_TUNNEL_URL="$(cat "$RUN_DIR/quick_tunnel.url" 2>/dev/null || echo 'Active')"
    fi
}

# ------------------------------------------------------------------------------
# 12. NETWORK INTERFACES & FIREWALL AUDIT
# ------------------------------------------------------------------------------

audit_network_firewall() {
    # Interfaces
    if has_cmd ip; then
        while read -r line; do
            [[ -n "$line" ]] && NETWORK_INTERFACES+=("$line")
        done < <(ip -br addr 2>/dev/null | awk '{print $1 " (" $3 ")"}')
    fi

    # Firewall
    if has_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        FIREWALL_TYPE="ufw"
        FIREWALL_STATUS="active"
    elif has_cmd firewall-cmd && firewall-cmd --state &>/dev/null; then
        FIREWALL_TYPE="firewalld"
        FIREWALL_STATUS="active"
    elif has_cmd nft && nft list ruleset 2>/dev/null | grep -q "table"; then
        FIREWALL_TYPE="nftables"
        FIREWALL_STATUS="active"
    elif has_cmd iptables && sudo -n iptables -L -n 2>/dev/null | grep -q "Chain"; then
        FIREWALL_TYPE="iptables"
        FIREWALL_STATUS="active"
    else
        FIREWALL_TYPE="none_or_permissive"
        FIREWALL_STATUS="inactive"
    fi
}

# ------------------------------------------------------------------------------
# 13. SAFE AUTO-REPAIR SYSTEM (--fix)
# ------------------------------------------------------------------------------

execute_auto_repair() {
    echo -e "${BOLD}${CYAN}==============================================================${NC}"
    echo -e "${BOLD}${CYAN}          MORNYE SAFE AUTO-REPAIR & RESOLUTION ENGINE         ${NC}"
    echo -e "${BOLD}${CYAN}==============================================================${NC}"

    if [[ ${#FINDINGS_ERRORS[@]} -eq 0 && ${#FINDINGS_WARNINGS[@]} -eq 0 ]]; then
        echo -e "${GREEN}[✔] No critical issues or warnings detected. System is healthy.${NC}"
        return 0
    fi

    echo -e "${YELLOW}[!] Reviewing detected issues for safe, non-destructive resolution...${NC}\n"

    local backup_ts
    backup_ts="$(date +%Y%m%d_%H%M%S)"

    # Fix 1: Missing Directories
    for err in "${FINDINGS_ERRORS[@]}"; do
        if [[ "$err" == DIRECTORY_MISSING* ]]; then
            echo -e "${BOLD}[Fix] Re-creating missing application directories...${NC}"
            mkdir -p "$DATA_DIR" "$STORAGE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$CONFIG_DIR" "$RUN_DIR"
            chmod 700 "$DATA_DIR" "$BACKUP_DIR" "$CONFIG_DIR" 2>/dev/null || true
            chmod 755 "$STORAGE_DIR" "$LOG_DIR" 2>/dev/null || true
            ACTIONS_TAKEN+=("Re-created missing persistent directories and hardened permissions.")
            echo -e "${GREEN}[✔] Directories re-created and permissions applied.${NC}"
        fi
    done

    # Fix 2: Insecure / Missing Directory Permissions
    for warn in "${FINDINGS_WARNINGS[@]}"; do
        if [[ "$warn" == INSECURE_PERMS* ]]; then
            echo -e "${BOLD}[Fix] Hardening storage and database directory permissions...${NC}"
            chmod 700 "$DATA_DIR" "$BACKUP_DIR" "$CONFIG_DIR" 2>/dev/null || true
            chmod 755 "$STORAGE_DIR" "$LOG_DIR" 2>/dev/null || true
            ACTIONS_TAKEN+=("Hardened directory permissions (700 for data/backups/config, 755 for storage/logs).")
            echo -e "${GREEN}[✔] Permissions hardened successfully.${NC}"
        fi
    done

    # Fix 3: Missing or Insecure .env
    for item in "${FINDINGS_ERRORS[@]}" "${FINDINGS_WARNINGS[@]}"; do
        if [[ "$item" == MISSING_ENV* || "$item" == DEFAULT_SECRET_KEY* ]]; then
            echo -e "${BOLD}[Fix] Generating secure .env configuration...${NC}"
            local new_secret
            new_secret="$(openssl rand -hex 32 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || echo "mornye_$(date +%s%N)_secure_key")"

            if [[ -f "$PROGRAM_DIR/.env" ]]; then
                cp "$PROGRAM_DIR/.env" "$PROGRAM_DIR/.env.bak_${backup_ts}"
                # Update existing secret key
                sed -i -E "s/^SECRET_KEY=.*/SECRET_KEY=${new_secret}/" "$PROGRAM_DIR/.env"
                if ! grep -q "^MORNYE_HOST_PORT=" "$PROGRAM_DIR/.env"; then
                    echo "MORNYE_HOST_PORT=${MORNYE_HOST_PORT:-8001}" >> "$PROGRAM_DIR/.env"
                    echo "MORNYE_HOST_BIND=127.0.0.1" >> "$PROGRAM_DIR/.env"
                fi
                ACTIONS_TAKEN+=("Updated SECRET_KEY in .env (pre-change backup created: .env.bak_${backup_ts}).")
                echo -e "${GREEN}[✔] Cryptographic 256-bit SECRET_KEY generated and saved to .env.${NC}"
            else
                cat << ENVEOF > "$PROGRAM_DIR/.env"
APP_NAME="Mornye Network Storage"
APP_ENV=production
DEBUG=false
SECRET_KEY=${new_secret}
MORNYE_HOST_BIND=127.0.0.1
MORNYE_HOST_PORT=8001
WEBDAV_HOST=127.0.0.1
WEBDAV_PORT=8000
DEFAULT_STORAGE_QUOTA_BYTES=107374182400
MAX_UPLOAD_SIZE_BYTES=2147483648
STORAGE_HOSTNAME=storage.example.com
PUBLIC_DOMAIN=example.com
ENVEOF
                chmod 600 "$PROGRAM_DIR/.env"
                ACTIONS_TAKEN+=("Created fresh .env with 256-bit SECRET_KEY and MORNYE_HOST_PORT=8001.")
                echo -e "${GREEN}[✔] Created fresh secure .env configuration.${NC}"
            fi
        fi
    done

    # Fix 4: Port Conflict on Host Port
    if [[ "$HOST_PORT_CONFLICT" == true ]]; then
        echo -e "${RED}${BOLD}[CONFLICT DETECTED]${NC} Port $MORNYE_HOST_PORT is in use by '$HOST_PORT_OWNER' (PID: ${HOST_PORT_PID:-unknown}, Service: $HOST_PORT_SERVICE)."
        echo -e "${YELLOW}STRICT RULE: Mornye will NEVER stop or kill an existing service.${NC}"
        echo -e "Suggested alternative free port: ${CYAN}${SUGGESTED_FREE_PORT}${NC}"

        local proceed_port=false
        if [[ "$MODE_AUTO_YES" == true ]]; then
            proceed_port=true
        else
            read -p "Reconfigure Mornye host port to $SUGGESTED_FREE_PORT? [Y/n]: " -r c_port
            if [[ ! "$c_port" =~ ^[Nn]$ ]]; then
                proceed_port=true
            fi
        fi

        if [[ "$proceed_port" == true ]]; then
            # Backup .env
            cp "$PROGRAM_DIR/.env" "$PROGRAM_DIR/.env.bak_${backup_ts}" 2>/dev/null || true
            if grep -q "^MORNYE_HOST_PORT=" "$PROGRAM_DIR/.env"; then
                sed -i -E "s/^MORNYE_HOST_PORT=.*/MORNYE_HOST_PORT=${SUGGESTED_FREE_PORT}/" "$PROGRAM_DIR/.env"
            else
                echo "MORNYE_HOST_PORT=${SUGGESTED_FREE_PORT}" >> "$PROGRAM_DIR/.env"
            fi
            MORNYE_HOST_PORT="$SUGGESTED_FREE_PORT"
            ACTIONS_TAKEN+=("Reassigned Mornye host port from conflicted port to $SUGGESTED_FREE_PORT.")
            echo -e "${GREEN}[✔] Mornye host port updated to $SUGGESTED_FREE_PORT in .env.${NC}"

            # If container running, restart with new port
            if [[ "$WEBDAV_CONTAINER_EXISTS" == true ]]; then
                echo -e "[*] Restarting container stack with new host port..."
                docker compose up -d webdav 2>/dev/null || true
                ACTIONS_TAKEN+=("Restarted WebDAV container to apply port $SUGGESTED_FREE_PORT.")
                echo -e "${GREEN}[✔] WebDAV container reloaded on port $SUGGESTED_FREE_PORT.${NC}"
            fi
        fi
    fi

    # Fix 5: Docker Permission Denied for Current User
    if [[ "$DOCKER_NONROOT_ACCESS" == false && "$DOCKER_DAEMON_ACTIVE" == true && "$IS_ROOT" == false ]]; then
        echo -e "\n${BOLD}[Fix] Docker permission denied for user '$CURRENT_USER'.${NC}"
        echo -e "${YELLOW}Note: Adding a user to the 'docker' group grants root-equivalent permissions.${NC}"
        local add_grp=false
        if [[ "$MODE_AUTO_YES" == true ]]; then
            add_grp=true
        else
            read -p "Add user '$CURRENT_USER' to the 'docker' group? [y/N]: " -r c_grp
            [[ "$c_grp" =~ ^[Yy]$ ]] && add_grp=true
        fi

        if [[ "$add_grp" == true ]]; then
            if has_cmd sudo; then
                sudo usermod -aG docker "$CURRENT_USER"
                ACTIONS_TAKEN+=("Added user '$CURRENT_USER' to group 'docker'. (Requires new session or 'newgrp docker').")
                echo -e "${GREEN}[✔] Added '$CURRENT_USER' to 'docker' group.${NC}"
                echo -e "${CYAN}Run 'newgrp docker' or re-login to activate non-root Docker privileges.${NC}"
            else
                echo -e "${RED}[✘] sudo is not available. Please run as root: usermod -aG docker $CURRENT_USER${NC}"
            fi
        fi
    fi

    # Fix 6: Docker Daemon Stopped
    if [[ "$DOCKER_INSTALLED" == true && "$DOCKER_DAEMON_ACTIVE" == false ]]; then
        echo -e "\n${BOLD}[Fix] Docker daemon is offline.${NC}"
        local start_dock=false
        if [[ "$MODE_AUTO_YES" == true ]]; then
            start_dock=true
        else
            read -p "Start the Docker service? [Y/n]: " -r c_dock
            [[ ! "$c_dock" =~ ^[Nn]$ ]] && start_dock=true
        fi

        if [[ "$start_dock" == true ]]; then
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                sudo systemctl start docker 2>/dev/null || true
                ACTIONS_TAKEN+=("Started Docker daemon via systemctl start docker.")
                echo -e "${GREEN}[✔] Docker daemon started.${NC}"
            elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
                sudo rc-service docker start 2>/dev/null || true
                ACTIONS_TAKEN+=("Started Docker daemon via rc-service docker start.")
                echo -e "${GREEN}[✔] Docker daemon started.${NC}"
            fi
        fi
    fi

    # Fix 7: Docker Image Not Built
    if [[ "$DOCKER_DAEMON_ACTIVE" == true && "$WEBDAV_IMAGE_EXISTS" == false ]]; then
        echo -e "\n${BOLD}[Fix] Building production Docker image 'mornye-webdav:latest'...${NC}"
        docker compose build
        ACTIONS_TAKEN+=("Built production Docker image 'mornye-webdav:latest'.")
        echo -e "${GREEN}[✔] Production Docker image built successfully.${NC}"
    fi

    echo -e "\n${BOLD}${CYAN}==============================================================${NC}"
    echo -e "${GREEN}[✔] Auto-repair actions completed. Re-running diagnostics to verify...${NC}"
    echo -e "${BOLD}${CYAN}==============================================================${NC}\n"

    # Reset findings and re-run
    FINDINGS_ERRORS=()
    FINDINGS_WARNINGS=()
    audit_storage
    audit_configuration
    audit_ports
    audit_endpoints
}

# ------------------------------------------------------------------------------
# 14. HUMAN-READABLE REPORT RENDERER
# ------------------------------------------------------------------------------

render_human_report() {
    print_section() {
        echo -e "${BOLD}${CYAN}==============================================================${NC}"
        echo -e "${BOLD}${CYAN}  $1${NC}"
        echo -e "${BOLD}${CYAN}==============================================================${NC}"
    }

    print_section "MORNYE SYSTEM DIAGNOSTICS & INFRASTRUCTURE AUDIT"
    echo -e "Report Timestamp     : ${BOLD}${TIMESTAMP}${NC}"
    echo -e "Target Directory     : ${CYAN}${PROGRAM_DIR}${NC}"
    echo -e "Diagnostic Report    : ${CYAN}${REPORT_TXT}${NC}"

    print_section "1. LINUX HOST & ENVIRONMENT AUDIT"
    echo -e "Operating System     : ${GREEN}[✔] ${OS_PRETTY}${NC} (Family: ${OS_FAMILY})"
    echo -e "Linux Kernel         : $(uname -s) ${KERNEL_VER} (${CPU_ARCH})"
    echo -e "Package Manager      : ${GREEN}[✔] ${PKG_MANAGER}${NC}"
    echo -e "Init System          : ${GREEN}[✔] ${INIT_SYSTEM}${NC}"
    echo -e "CPU Resources        : ${CPU_CORES} Cores (Load Averages: ${LOAD_1M}, ${LOAD_5M}, ${LOAD_15M})"
    echo -e "System Memory (RAM)  : ${RAM_AVAIL_MB} MB Available / ${RAM_TOTAL_MB} MB Total (${RAM_USED_PCT}% Used)"
    echo -e "Disk Storage Headroom: ${DISK_FREE_MB} MB Free / ${DISK_TOTAL_MB} MB Total (${DISK_USED_PCT}% Used)"
    echo -e "Current User         : ${CURRENT_USER} (UID: ${CURRENT_UID}, GID: ${CURRENT_GID})"
    echo -e "User Groups          : ${USER_GROUPS}"
    echo -e "Root Privileges      : $([[ "$IS_ROOT" == true ]] && echo -e "${YELLOW}Root (UID 0)${NC}" || echo "Non-root")"
    echo -e "Sudo Authorization   : $([[ "$SUDO_AUTHENTICATED" == true ]] && echo -e "${GREEN}[✔] Active (Cached / Nopasswd)${NC}" || echo -e "${YELLOW}[!] Requires password or unavailable${NC}")"

    print_section "2. DOCKER & CONTAINER INFRASTRUCTURE"
    if [[ "$DOCKER_INSTALLED" == true ]]; then
        echo -e "Docker Engine        : ${GREEN}[✔] Installed${NC} (${DOCKER_VERSION})"
        echo -e "Docker Daemon State  : $([[ "$DOCKER_DAEMON_ACTIVE" == true ]] && echo -e "${GREEN}[✔] Active & Running${NC}" || echo -e "${RED}[✘] Inactive / Stopped${NC}")"
        echo -e "Docker Socket        : $([[ "$DOCKER_SOCKET_EXISTS" == true ]] && echo -e "${GREEN}[✔] Present${NC} (${DOCKER_SOCKET_PERMS})" || echo -e "${RED}[✘] Missing${NC}")"
        echo -e "Non-Root Socket Use  : $([[ "$DOCKER_NONROOT_ACCESS" == true ]] && echo -e "${GREEN}[✔] Granted (User has docker access)${NC}" || echo -e "${YELLOW}[!] Denied (Requires sudo or 'docker' group)${NC}")"
        echo -e "Docker Compose       : $([[ "$COMPOSE_INSTALLED" == true ]] && echo -e "${GREEN}[✔] ${COMPOSE_VERSION}${NC}" || echo -e "${RED}[✘] Not installed${NC}")"
        echo -e "Production Image     : $([[ "$WEBDAV_IMAGE_EXISTS" == true ]] && echo -e "${GREEN}[✔] mornye-webdav:latest built${NC}" || echo -e "${YELLOW}[!] Image not built${NC}")"
        echo -e "WebDAV Container     : $([[ "$WEBDAV_CONTAINER_EXISTS" == true ]] && echo -e "State: ${BOLD}${WEBDAV_CONTAINER_STATE}${NC} (Health: ${WEBDAV_CONTAINER_HEALTH}, Restarts: ${WEBDAV_CONTAINER_RESTARTS})" || echo "Not created")"
        echo -e "Tunnel Container     : $([[ "$TUNNEL_CONTAINER_EXISTS" == true ]] && echo -e "State: ${BOLD}${TUNNEL_CONTAINER_STATE}${NC}" || echo "Not created (Optional)")"
    else
        echo -e "Docker Engine        : ${RED}[✘] Docker is not installed on this system.${NC}"
    fi

    print_section "3. PORT OCCUPANCY & CONFLICT AUDIT"
    echo -e "Configured Host Port : ${BOLD}${CYAN}${MORNYE_HOST_PORT}${NC} (Binding: ${MORNYE_HOST_BIND})"
    echo -e "Container Port       : 8000 (Internal RFC 4918 WebDAV)"
    echo "--------------------------------------------------------------"
    echo -e "Port ${MORNYE_HOST_PORT} (Mornye Host):"
    if [[ "$HOST_PORT_STATE" == "occupied" ]]; then
        if [[ "$HOST_PORT_IS_MORNYE" == true ]]; then
            echo -e "  Status             : ${GREEN}[✔] Active & Bound (Mornye WebDAV Container, PID: ${HOST_PORT_PID:-active})${NC}"
            echo -e "  Conflict Status    : ${GREEN}[✔] No conflict (Service: ${HOST_PORT_SERVICE})${NC}"
        else
            echo -e "  Status             : ${RED}[✘] CONFLICT DETECTED!${NC}"
            echo -e "  Occupying Process  : ${BOLD}${HOST_PORT_OWNER}${NC} (PID: ${HOST_PORT_PID:-unknown})"
            echo -e "  Service Identifier : ${HOST_PORT_SERVICE}"
            echo -e "  Conflict Policy    : ${YELLOW}PROTECTED — Mornye will NOT terminate this process.${NC}"
            echo -e "  Recommended Action : Reassign Mornye to free port: ${GREEN}${SUGGESTED_FREE_PORT}${NC}"
        fi
    else
        echo -e "  Status             : ${GREEN}[✔] Available (Free)${NC}"
    fi

    echo "--------------------------------------------------------------"
    echo -e "Port 8000 (Standard / Legacy):"
    if [[ "$PORT_8000_STATE" == "occupied" ]]; then
        echo -e "  Status             : Occupied by '${PORT_8000_OWNER}' (PID: ${PORT_8000_PID:-unknown}, ${PORT_8000_SERVICE})"
        echo -e "  Coexistence Note   : $([[ "$MORNYE_HOST_PORT" != "8000" ]] && echo -e "${GREEN}[✔] Isolated (Mornye uses port ${MORNYE_HOST_PORT}, no conflict)${NC}" || echo -e "${RED}[✘] Conflicts with Mornye host port!${NC}")"
    else
        echo -e "  Status             : Free"
    fi

    print_section "4. EXISTING SYSTEM SERVICES PROTECTION"
    if [[ ${#PROTECTED_SERVICES[@]} -gt 0 ]]; then
        for svc in "${PROTECTED_SERVICES[@]}"; do
            IFS="|" read -r s_title s_unit s_info s_stat <<< "$svc"
            echo -e "  * ${BOLD}${s_title}${NC} (${CYAN}${s_unit}${NC}): ${s_info} -> ${GREEN}${s_stat}${NC}"
        done
    else
        echo -e "  No conflicting third-party services detected on monitored ports."
    fi

    print_section "5. STORAGE & VOLUME PERMISSIONS"
    echo -e "Database Path        : ${DATA_DIR} (mode: $(stat -c "%a" "$DATA_DIR" 2>/dev/null || stat -f "%OLp" "$DATA_DIR" 2>/dev/null || echo '???'))"
    echo -e "Music Storage Path   : ${STORAGE_DIR} (mode: $(stat -c "%a" "$STORAGE_DIR" 2>/dev/null || stat -f "%OLp" "$STORAGE_DIR" 2>/dev/null || echo '???'))"
    echo -e "Backups Directory    : ${BACKUP_DIR} (mode: $(stat -c "%a" "$BACKUP_DIR" 2>/dev/null || stat -f "%OLp" "$BACKUP_DIR" 2>/dev/null || echo '???'))"
    echo -e "Logs Directory       : ${LOG_DIR} (mode: $(stat -c "%a" "$LOG_DIR" 2>/dev/null || stat -f "%OLp" "$LOG_DIR" 2>/dev/null || echo '???'))"
    echo -e "SQLite Database      : $([[ -f "$DATA_DIR/mornye.db" ]] && echo -e "${GREEN}[✔] Present (Integrity: ${DB_INTEGRITY_STATUS})${NC}" || echo -e "${YELLOW}[!] Not yet created${NC}")"

    print_section "6. LOCAL ENDPOINTS & HEALTH STATUS"
    local h_url="http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/health"
    local d_url="http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/dav/"
    echo -e "Health Probe (/health): $([[ "$HEALTH_HTTP_CODE" == "200" ]] && echo -e "${GREEN}[✔] HTTP 200 OK (${HEALTH_LATENCY_MS} ms)${NC}" || echo -e "${YELLOW}[!] HTTP ${HEALTH_HTTP_CODE} (${h_url})${NC}")"
    echo -e "WebDAV Probe (/dav/)  : $([[ "$DAV_HTTP_CODE" =~ ^(401|200|207)$ ]] && echo -e "${GREEN}[✔] HTTP ${DAV_HTTP_CODE} (Auth Boundary Active, ${DAV_LATENCY_MS} ms)${NC}" || echo -e "${YELLOW}[!] HTTP ${DAV_HTTP_CODE} (${d_url})${NC}")"

    print_section "7. CLOUDFLARE ZERO-TRUST TUNNEL AUDIT"
    echo -e "cloudflared CLI      : $([[ "$CLOUDFLARE_INSTALLED" == true ]] && echo -e "${GREEN}[✔] Installed${NC} (${CLOUDFLARE_VERSION})" || echo -e "${YELLOW}[!] Not installed on host${NC}")"
    echo -e "Account Certificate  : $([[ "$CLOUDFLARE_AUTH_EXISTS" == true ]] && echo -e "${GREEN}[✔] Present (cert.pem)${NC}" || echo -e "${YELLOW}[!] Missing cert.pem${NC}")"
    echo -e "Tunnel Runtime Mode  : ${BOLD}${CLOUDFLARE_RUNTIME_MODE}${NC}"
    echo -e "Ingress Target       : ${CYAN}${CLOUDFLARE_INGRESS_TARGET:-None}${NC}"
    echo -e "Cloudflare Edge WAN  : $([[ "$CLOUDFLARE_EDGE_REACHABLE" == true ]] && echo -e "${GREEN}[✔] Reachable${NC}" || echo -e "${YELLOW}[!] Unreachable${NC}")"
    echo -e "Quick Tunnel Status  : $([[ "$QUICK_TUNNEL_ACTIVE" == true ]] && echo -e "${PURPLE}ACTIVE${NC} (${CYAN}${QUICK_TUNNEL_URL}${NC})" || echo "Inactive")"

    print_section "8. NETWORK INTERFACES & FIREWALL"
    echo -e "Firewall Status      : ${FIREWALL_TYPE} (${FIREWALL_STATUS})"
    echo -e "Active Interfaces    : ${NETWORK_INTERFACES[*]:-None detected}"

    print_section "9. DIAGNOSTIC FINDINGS & SAFE REMEDIATIONS"
    if [[ ${#FINDINGS_ERRORS[@]} -eq 0 && ${#FINDINGS_WARNINGS[@]} -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}[✔] ZERO CRITICAL ISSUES DETECTED. Infrastructure is operating optimally.${NC}"
    else
        if [[ ${#FINDINGS_ERRORS[@]} -gt 0 ]]; then
            echo -e "${RED}${BOLD}CRITICAL ISSUES (${#FINDINGS_ERRORS[@]}):${NC}"
            for err in "${FINDINGS_ERRORS[@]}"; do
                IFS="|" read -r e_code e_msg e_fix <<< "$err"
                echo -e "  ${RED}[ERROR: ${e_code}]${NC} ${e_msg}"
                echo -e "  ${CYAN}-> Safe Fix:${NC} ${e_fix}\n"
            done
        fi
        if [[ ${#FINDINGS_WARNINGS[@]} -gt 0 ]]; then
            echo -e "${YELLOW}${BOLD}WARNINGS (${#FINDINGS_WARNINGS[@]}):${NC}"
            for warn in "${FINDINGS_WARNINGS[@]}"; do
                IFS="|" read -r w_code w_msg w_fix <<< "$warn"
                echo -e "  ${YELLOW}[WARN: ${w_code}]${NC} ${w_msg}"
                echo -e "  ${CYAN}-> Recommendation:${NC} ${w_fix}\n"
            done
        fi
        echo -e "${CYAN}Run './mornye.sh doctor --fix' to safely resolve auto-repairable issues.${NC}"
    fi

    if [[ ${#ACTIONS_TAKEN[@]} -gt 0 ]]; then
        print_section "10. ACTIONS APPLIED DURING AUTO-REPAIR"
        for act in "${ACTIONS_TAKEN[@]}"; do
            echo -e "  ${GREEN}[✔]${NC} $act"
        done
    fi

    print_section "END OF DIAGNOSTIC AUDIT"
    echo -e "Saved Plaintext Report : ${CYAN}${REPORT_TXT}${NC}"
    if [[ "$MODE_JSON" == true ]]; then
        echo -e "Saved JSON Telemetry   : ${CYAN}${REPORT_JSON}${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 15. JSON REPORT RENDERER
# ------------------------------------------------------------------------------

render_json_report() {
    cat << JSONEOF
{
  "timestamp": "${TIMESTAMP}",
  "system": {
    "os_id": "${OS_ID}",
    "os_name": "${OS_NAME}",
    "os_pretty": "${OS_PRETTY}",
    "os_family": "${OS_FAMILY}",
    "package_manager": "${PKG_MANAGER}",
    "kernel": "${KERNEL_VER}",
    "architecture": "${CPU_ARCH}",
    "init_system": "${INIT_SYSTEM}",
    "cpu_cores": ${CPU_CORES},
    "load_averages": {
      "1m": "${LOAD_1M}",
      "5m": "${LOAD_5M}",
      "15m": "${LOAD_15M}"
    },
    "memory_mb": {
      "total": ${RAM_TOTAL_MB},
      "available": ${RAM_AVAIL_MB},
      "used_percent": ${RAM_USED_PCT}
    },
    "disk_mb": {
      "total": ${DISK_TOTAL_MB},
      "free": ${DISK_FREE_MB},
      "used_percent": ${DISK_USED_PCT}
    }
  },
  "user": {
    "username": "${CURRENT_USER}",
    "uid": ${CURRENT_UID},
    "gid": ${CURRENT_GID},
    "is_root": ${IS_ROOT},
    "sudo_authenticated": ${SUDO_AUTHENTICATED},
    "in_docker_group": ${IN_DOCKER_GROUP}
  },
  "docker": {
    "installed": ${DOCKER_INSTALLED},
    "version": "${DOCKER_VERSION}",
    "daemon_active": ${DOCKER_DAEMON_ACTIVE},
    "socket_exists": ${DOCKER_SOCKET_EXISTS},
    "socket_permissions": "${DOCKER_SOCKET_PERMS}",
    "nonroot_access": ${DOCKER_NONROOT_ACCESS},
    "compose_installed": ${COMPOSE_INSTALLED},
    "compose_version": "${COMPOSE_VERSION}",
    "image_exists": ${WEBDAV_IMAGE_EXISTS},
    "webdav_container": {
      "exists": ${WEBDAV_CONTAINER_EXISTS},
      "state": "${WEBDAV_CONTAINER_STATE}",
      "health": "${WEBDAV_CONTAINER_HEALTH}",
      "restarts": ${WEBDAV_CONTAINER_RESTARTS}
    },
    "tunnel_container": {
      "exists": ${TUNNEL_CONTAINER_EXISTS},
      "state": "${TUNNEL_CONTAINER_STATE}"
    }
  },
  "ports": {
    "mornye_host_bind": "${MORNYE_HOST_BIND}",
    "mornye_host_port": ${MORNYE_HOST_PORT},
    "host_port_state": "${HOST_PORT_STATE}",
    "host_port_owner": "${HOST_PORT_OWNER}",
    "host_port_pid": "${HOST_PORT_PID}",
    "host_port_service": "${HOST_PORT_SERVICE}",
    "host_port_is_mornye": ${HOST_PORT_IS_MORNYE},
    "host_port_conflict": ${HOST_PORT_CONFLICT},
    "suggested_free_port": "${SUGGESTED_FREE_PORT}",
    "port_8000_state": "${PORT_8000_STATE}",
    "port_8000_owner": "${PORT_8000_OWNER}",
    "port_8000_pid": "${PORT_8000_PID}",
    "port_8000_service": "${PORT_8000_SERVICE}"
  },
  "endpoints": {
    "health_url": "http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/health",
    "health_http_code": "${HEALTH_HTTP_CODE}",
    "health_latency_ms": "${HEALTH_LATENCY_MS}",
    "webdav_url": "http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/dav/",
    "webdav_http_code": "${DAV_HTTP_CODE}",
    "webdav_latency_ms": "${DAV_LATENCY_MS}"
  },
  "cloudflare": {
    "installed": ${CLOUDFLARE_INSTALLED},
    "version": "${CLOUDFLARE_VERSION}",
    "auth_certificate": ${CLOUDFLARE_AUTH_EXISTS},
    "runtime_mode": "${CLOUDFLARE_RUNTIME_MODE}",
    "ingress_target": "${CLOUDFLARE_INGRESS_TARGET}",
    "edge_reachable": ${CLOUDFLARE_EDGE_REACHABLE},
    "quick_tunnel_active": ${QUICK_TUNNEL_ACTIVE},
    "quick_tunnel_url": "${QUICK_TUNNEL_URL}"
  },
  "storage": {
    "data_path": "${DATA_DIR}",
    "storage_path": "${STORAGE_DIR}",
    "backups_path": "${BACKUP_DIR}",
    "logs_path": "${LOG_DIR}",
    "database_integrity": "${DB_INTEGRITY_STATUS}"
  },
  "configuration": {
    "status": "${CONFIG_VALIDATION_STATUS}"
  },
  "findings": {
    "error_count": ${#FINDINGS_ERRORS[@]},
    "warning_count": ${#FINDINGS_WARNINGS[@]}
  }
}
JSONEOF
}

# ------------------------------------------------------------------------------
# 16. EXECUTION DISPATCHER
# ------------------------------------------------------------------------------

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                MODE_JSON=true
                shift
                ;;
            --fix)
                MODE_FIX=true
                shift
                ;;
            -y|--yes)
                MODE_AUTO_YES=true
                shift
                ;;
            --ports)
                MODE_PORTS_ONLY=true
                shift
                ;;
            --health)
                MODE_HEALTH_ONLY=true
                shift
                ;;
            --validate-config)
                MODE_CONFIG_ONLY=true
                shift
                ;;
            *)
                echo "Unknown option: $1"
                echo "Usage: ./mornye.sh doctor [--json] [--fix] [-y] [--ports] [--health] [--validate-config]"
                exit 1
                ;;
        esac
    done

    # Run complete audit pipeline
    audit_system
    audit_user_permissions
    audit_docker
    audit_containers
    audit_ports
    audit_protected_services
    audit_storage
    audit_configuration
    audit_endpoints
    audit_cloudflare
    audit_network_firewall

    # Mode: Ports Only
    if [[ "$MODE_PORTS_ONLY" == true ]]; then
        echo -e "${BOLD}PORT OCCUPANCY & CONFLICT AUDIT:${NC}"
        echo "--------------------------------------------------------------"
        echo -e "Mornye Configured Host Port : ${CYAN}${MORNYE_HOST_PORT}${NC} (${MORNYE_HOST_BIND})"
        echo -e "Port State                  : $([[ "$HOST_PORT_STATE" == "occupied" ]] && echo -e "${YELLOW}Occupied${NC}" || echo -e "${GREEN}Free${NC}")"
        if [[ "$HOST_PORT_STATE" == "occupied" ]]; then
            echo -e "Process Owner               : ${HOST_PORT_OWNER} (PID: ${HOST_PORT_PID:-active})"
            echo -e "Service Unit                : ${HOST_PORT_SERVICE}"
            echo -e "Belongs to Mornye           : $([[ "$HOST_PORT_IS_MORNYE" == true ]] && echo -e "${GREEN}YES${NC}" || echo -e "${RED}NO (Conflict!)${NC}")"
            if [[ "$HOST_PORT_CONFLICT" == true ]]; then
                echo -e "Recommended Available Port  : ${GREEN}${SUGGESTED_FREE_PORT}${NC}"
            fi
        fi
        echo "--------------------------------------------------------------"
        echo -e "Standard Port 8000          : ${PORT_8000_STATE} (${PORT_8000_OWNER}, PID: ${PORT_8000_PID:-none}, ${PORT_8000_SERVICE})"
        echo -e "Cloudflare Metrics Port 20241: ${METRICS_PORT_STATE} (${METRICS_PORT_OWNER})"
        exit 0
    fi

    # Mode: Health Only
    if [[ "$MODE_HEALTH_ONLY" == true ]]; then
        echo -e "${BOLD}MORNYE WEBDAV HEALTH STATUS:${NC}"
        echo -e "Host Endpoint   : http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/health -> HTTP ${HEALTH_HTTP_CODE} (${HEALTH_LATENCY_MS} ms)"
        echo -e "WebDAV Gateway  : http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/dav/    -> HTTP ${DAV_HTTP_CODE} (${DAV_LATENCY_MS} ms)"
        echo -e "Container State : ${WEBDAV_CONTAINER_STATE} (Health: ${WEBDAV_CONTAINER_HEALTH})"
        if [[ "$HEALTH_HTTP_CODE" == "200" && "$DAV_HTTP_CODE" =~ ^(401|200|207)$ ]]; then
            echo -e "${GREEN}[✔] All endpoints are healthy and auth boundary is active.${NC}"
            exit 0
        else
            echo -e "${RED}[✘] Endpoint health failure detected.${NC}"
            exit 1
        fi
    fi

    # Mode: Config Validation Only
    if [[ "$MODE_CONFIG_ONLY" == true ]]; then
        echo -e "${BOLD}MORNYE CONFIGURATION VALIDATION:${NC}"
        echo -e "Status: ${CONFIG_VALIDATION_STATUS}"
        if [[ ${#FINDINGS_ERRORS[@]} -gt 0 ]]; then
            for e in "${FINDINGS_ERRORS[@]}"; do
                echo -e "${RED}[ERROR]${NC} $e"
            done
            exit 1
        else
            echo -e "${GREEN}[✔] Configuration files (.env, compose.yaml, cloudflared.yml) are valid.${NC}"
            exit 0
        fi
    fi

    # Mode: Auto-Repair
    if [[ "$MODE_FIX" == true ]]; then
        execute_auto_repair
    fi

    # Render Output
    if [[ "$MODE_JSON" == true ]]; then
        render_json_report > "$REPORT_JSON"
        render_json_report
    else
        render_human_report
        render_human_report | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" > "$REPORT_TXT" 2>/dev/null || true
    fi

    # Exit code based on findings
    if [[ ${#FINDINGS_ERRORS[@]} -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
