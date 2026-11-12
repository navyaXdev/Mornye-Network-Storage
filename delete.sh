#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — SECURE UNINSTALLER & PURGE SYSTEM
# Module: delete.sh
# Purpose: Comprehensive, isolated, and reversible uninstallation of Mornye
#          containers, services, scheduled tasks, firewall rules, and files.
#
# Usage:
#   sudo ./delete.sh              # Mode A: Safe Uninstall (Preserves User Data)
#   sudo ./delete.sh --purge      # Mode B: Complete Purge (Removes all data)
#   sudo ./delete.sh --dry-run    # Simulation mode (0 system modifications)
#   sudo ./delete.sh --backup     # Create safety archive before proceeding
# ==============================================================================

set -o pipefail

# ------------------------------------------------------------------------------
# 1. ENVIRONMENT & PRIVILEGE DISCOVERY
# ------------------------------------------------------------------------------

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROGRAM_DIR" || exit 1

# Detect executing user and root status
CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"
REAL_USER="${SUDO_USER:-$CURRENT_USER}"

IS_ROOT=false
if [[ "$CURRENT_UID" -eq 0 ]]; then
    IS_ROOT=true
fi

# Directory Layout
CONFIG_DIR="$PROGRAM_DIR/config"
DATA_DIR="$PROGRAM_DIR/database"
STORAGE_DIR="$PROGRAM_DIR/storage"
LOG_DIR="$PROGRAM_DIR/logs"
BACKUP_DIR="$PROGRAM_DIR/backups"
RUN_DIR="$PROGRAM_DIR/run"
UNINSTALL_LOG_DIR="$LOG_DIR/uninstall"

# ANSI Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Execution State Flags
PURGE_MODE=false
DRY_RUN=false
CREATE_BACKUP_REQUESTED=false
AUTO_CONFIRM=false
CONFIRM_TOKEN=""
BACKUP_DEST=""
SKIP_BACKUP=false

# Telemetry & Audit Arrays
DISCOVERED_SERVICES=()
DISCOVERED_CONTAINERS=()
DISCOVERED_IMAGES=()
DISCOVERED_NETWORKS=()
DISCOVERED_VOLUMES=()
DISCOVERED_PROCESSES=()
DISCOVERED_CRON_JOBS=()
DISCOVERED_TIMERS=()
DISCOVERED_FIREWALL_RULES=()
PROTECTED_SERVICES=()
PRESERVED_RESOURCES=()

REMOVED_SERVICES=()
REMOVED_CONTAINERS=()
REMOVED_IMAGES=()
REMOVED_NETWORKS=()
REMOVED_VOLUMES=()
REMOVED_PROCESSES=()
REMOVED_CRON_JOBS=()
REMOVED_FIREWALL_RULES=()
DELETED_PATHS=()
ERRORS_ENCOUNTERED=()
BACKUP_CREATED_PATH=""

# ------------------------------------------------------------------------------
# 2. CLI ARGUMENT PARSING
# ------------------------------------------------------------------------------

show_usage() {
    cat << EOF
Mornye Network Storage — System Uninstaller (delete.sh)

Usage:
  sudo ./delete.sh [OPTIONS]

Options:
  --purge                 Mode B: Complete Purge. Permanently deletes databases,
                          storage, audio files, backups, config, and logs.
                          Requires typing 'DELETE MORNYE DATA' to confirm.
  --dry-run               Simulate uninstallation. Displays everything that would
                          be stopped, removed, or preserved without making changes.
  --backup [DEST]         Create safety backup archive (.tar.gz) before proceeding.
                          Optional DEST path (defaults to /tmp/mornye_backup_<timestamp>.tar.gz).
  --skip-backup           Skip the interactive backup prompt in purge mode.
  -y, --yes               Non-interactive mode for Safe Uninstall.
  --confirm=STRING        Pass confirmation token non-interactively ('DELETE MORNYE DATA').
  -h, --help              Display this help manual and exit.

Modes:
  1. Safe Uninstall (Default):
     Stops and removes Mornye Docker containers, images, networks, and services.
     PRESERVES: Database, Music Storage, Backups, and Configurations.

  2. Complete Purge (--purge):
     Removes all Mornye resources including database, storage, backups, and configs.
     Guarded by mandatory 'DELETE MORNYE DATA' typed confirmation.

Strict Isolation Guarantees:
  - SONG Bridge (mornye-storage.service on port 8000) is 100% PROTECTED.
  - Foreign Docker containers, images, networks, and volumes are PROTECTED.
  - Cloudflare Tunnel credentials and systemd services are PROTECTED.
  - System-critical roots (/, /home, /root, /var, /etc) can NEVER be deleted.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge)
            PURGE_MODE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --backup)
            CREATE_BACKUP_REQUESTED=true
            shift
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                BACKUP_DEST="$1"
                shift
            fi
            ;;
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        --confirm=*)
            CONFIRM_TOKEN="${1#*=}"
            shift
            ;;
        --force)
            AUTO_CONFIRM=true
            shift
            ;;
        --source-only)
            shift
            ;;
        -h|--help)
            show_usage
            if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
                return 0 2>/dev/null || exit 0
            fi
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] Unknown option: $1${NC}" >&2
            show_usage
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# 3. HELPER FUNCTIONS & SAFETY VALIDATIONS
# ------------------------------------------------------------------------------

has_cmd() {
    command -v "$1" &>/dev/null
}

has_docker() {
    [[ "$MORNYE_NO_DOCKER" == "1" ]] && return 1
    has_cmd docker
}

load_env() {
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        # Load environment variables safely
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            key="$(echo "$key" | tr -d ' ')"
            val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')"
            export "$key=$val" 2>/dev/null || true
        done < "$PROGRAM_DIR/.env"
    fi

    DATA_DIR="${DATA_PATH:-$PROGRAM_DIR/database}"
    STORAGE_DIR="${STORAGE_PATH:-$PROGRAM_DIR/storage}"
    LOG_DIR="${LOG_PATH:-$PROGRAM_DIR/logs}"
    BACKUP_DIR="${BACKUP_PATH:-$PROGRAM_DIR/backups}"
    CONFIG_DIR="${CONFIG_PATH:-$PROGRAM_DIR/config}"
    MORNYE_HOST_PORT="${MORNYE_HOST_PORT:-8001}"
    MORNYE_HOST_BIND="${MORNYE_HOST_BIND:-127.0.0.1}"
}

validate_safe_path() {
    local target="$1"
    if [[ -z "$target" ]]; then
        return 1
    fi

    # 1. Canonicalize parent directory and determine canonical link/file location
    local parent_dir target_name parent_canonical target_canonical
    parent_dir="$(dirname "$target")"
    target_name="$(basename "$target")"
    parent_canonical="$(realpath -m "$parent_dir" 2>/dev/null || echo "")"
    if [[ -z "$parent_canonical" ]]; then
        return 1
    fi
    target_canonical="${parent_canonical}/${target_name}"

    # Also determine fully dereferenced canonical path
    local fully_resolved
    fully_resolved="$(realpath -m "$target" 2>/dev/null || echo "")"

    # Refuse system-critical paths
    local sys_dirs=(
        "/" "/home" "/root" "/etc" "/var" "/usr" "/opt" "/tmp"
        "/boot" "/sys" "/proc" "/dev" "/bin" "/sbin" "/lib" "/lib64"
        "/mnt" "/media" "/run" "/srv"
    )
    for sdir in "${sys_dirs[@]}"; do
        if [[ "$target_canonical" == "$sdir" || "$fully_resolved" == "$sdir" ]]; then
            echo -e "${RED}[CRITICAL SAFETY] Refusing to delete system root: $target${NC}" >&2
            return 1
        fi
    done

    # Refuse user home directory
    if [[ "$target_canonical" == "$HOME" || "$target_canonical" == "/home/$CURRENT_USER" || "$target_canonical" == "/home/$REAL_USER" || \
          "$fully_resolved" == "$HOME" || "$fully_resolved" == "/home/$CURRENT_USER" || "$fully_resolved" == "/home/$REAL_USER" ]]; then
        echo -e "${RED}[CRITICAL SAFETY] Refusing to delete user home directory: $target${NC}" >&2
        return 1
    fi

    local resolved_program_dir
    resolved_program_dir="$(realpath -m "$PROGRAM_DIR" 2>/dev/null || echo "")"

    # Strict containment check:
    # 1. Genuine descendant within PROGRAM_DIR
    if [[ "$parent_canonical" == "$resolved_program_dir" || "$parent_canonical" == "$resolved_program_dir"/* ]]; then
        # Parent is within PROGRAM_DIR.
        # If target is not a symlink, ensure its fully resolved target does not escape outside PROGRAM_DIR
        if [[ ! -L "$target" ]]; then
            if [[ "$fully_resolved" != "$resolved_program_dir" && "$fully_resolved" != "$resolved_program_dir"/* ]]; then
                echo -e "${RED}[SAFETY BLOCK] Symlink escape detected in target: $target -> $fully_resolved${NC}" >&2
                return 1
            fi
        fi
        return 0
    fi

    # 2. Exact PROGRAM_DIR itself (allowed for complete purge)
    if [[ "$target_canonical" == "$resolved_program_dir" || "$fully_resolved" == "$resolved_program_dir" ]]; then
        return 0
    fi

    # 3. Allow specific verified external links
    if [[ "$target_canonical" == "/usr/local/bin/mornye" || "$target_canonical" == "/usr/bin/mornye" ]]; then
        return 0
    fi

    # 4. Allow specific verified Mornye systemd unit files
    if [[ "$target_canonical" =~ ^/etc/systemd/system/mornye.*\.service$ ]] && \
       [[ "$target_canonical" != *mornye-storage.service* ]] && \
       [[ "$target_canonical" != *mornye-tunnel.service* ]]; then
        return 0
    fi

    echo -e "${RED}[SAFETY BLOCK] Path outside verified Mornye boundary: $target${NC}" >&2
    return 1
}

safe_remove_path() {
    local p="$1"
    if [[ ! -e "$p" && ! -L "$p" ]]; then
        return 0
    fi

    # Validate safe path FIRST before unlinking or touching anything
    if ! validate_safe_path "$p"; then
        ERRORS_ENCOUNTERED+=("Blocked attempt to remove unsafe path: $p")
        return 1
    fi

    # If it is a symbolic link, remove only the link itself, never touch target
    if [[ -L "$p" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "  [DRY-RUN] Would remove symbolic link: $p"
        else
            rm -f "$p" 2>/dev/null || true
            DELETED_PATHS+=("$p (symlink)")
        fi
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  [DRY-RUN] Would remove: $p"
    else
        rm -rf "$p" 2>/dev/null || true
        DELETED_PATHS+=("$p")
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 4. SYSTEM & RESOURCE DISCOVERY
# ------------------------------------------------------------------------------

detect_environment() {
    OS_ID="unknown"
    OS_NAME="Linux"
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-$NAME}"
    fi

    INIT_SYSTEM="systemd"
    if [[ -d /run/systemd/system ]] && has_cmd systemctl; then
        INIT_SYSTEM="systemd"
    elif [[ -d /run/openrc ]] || has_cmd rc-service; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="sysvinit"
    fi
}

discover_protected_services() {
    # 1. SONG Bridge / Legacy Mornye Storage (PID 13951, port 8000)
    if systemctl is-active --quiet mornye-storage.service 2>/dev/null; then
        local pid
        pid="$(systemctl show -p MainPID --value mornye-storage.service 2>/dev/null || echo 'active')"
        PROTECTED_SERVICES+=("SONG Bridge (mornye-storage.service)|PID: $pid|Port: 8000|STATUS: Active & 100% PROTECTED")
    fi

    # 2. Legacy Cloudflare Tunnel (mornye-tunnel.service on port 20241)
    if systemctl is-active --quiet mornye-tunnel.service 2>/dev/null; then
        local t_pid
        t_pid="$(systemctl show -p MainPID --value mornye-tunnel.service 2>/dev/null || echo 'active')"
        PROTECTED_SERVICES+=("Cloudflare Tunnel Service (mornye-tunnel.service)|PID: $t_pid|Port: 20241|STATUS: Active & 100% PROTECTED")
    fi

    # 3. Navidrome Music Server
    if systemctl is-active --quiet navidrome.service 2>/dev/null || pgrep -x navidrome &>/dev/null; then
        PROTECTED_SERVICES+=("Navidrome Music Server (navidrome.service)|Port: 4533|STATUS: PROTECTED")
    fi

    # 4. Web Servers
    if systemctl is-active --quiet nginx.service 2>/dev/null || pgrep -x nginx &>/dev/null; then
        PROTECTED_SERVICES+=("Nginx Web Server|Port: 80/443|STATUS: PROTECTED")
    fi
    if systemctl is-active --quiet apache2.service 2>/dev/null || systemctl is-active --quiet httpd.service 2>/dev/null || pgrep -E '(apache2|httpd)' &>/dev/null; then
        PROTECTED_SERVICES+=("Apache HTTP Server|Port: 80/443|STATUS: PROTECTED")
    fi
    if systemctl is-active --quiet caddy.service 2>/dev/null || pgrep -x caddy &>/dev/null; then
        PROTECTED_SERVICES+=("Caddy Web Server|Port: 80/443|STATUS: PROTECTED")
    fi

    # 5. Databases
    if systemctl is-active --quiet postgresql.service 2>/dev/null || pgrep -x postgres &>/dev/null; then
        PROTECTED_SERVICES+=("PostgreSQL Database Server|Port: 5432|STATUS: PROTECTED")
    fi
    if systemctl is-active --quiet mysql.service 2>/dev/null || systemctl is-active --quiet mariadb.service 2>/dev/null || pgrep -E '(mysqld|mariadbd)' &>/dev/null; then
        PROTECTED_SERVICES+=("MySQL / MariaDB Server|Port: 3306|STATUS: PROTECTED")
    fi
}

discover_mornye_services() {
    # Check for Mornye-specific systemd units whose WorkingDirectory/ExecStart points to PROGRAM_DIR
    if [[ "$INIT_SYSTEM" == "systemd" ]] && has_cmd systemctl; then
        local units
        units="$(systemctl list-unit-files 'mornye*.service' --no-legend 2>/dev/null | awk '{print $1}' || echo '')"
        for u in $units; do
            # NEVER include protected SONG Bridge or mornye-tunnel.service
            if [[ "$u" == "mornye-storage.service" || "$u" == "mornye-tunnel.service" ]]; then
                continue
            fi
            # Verify unit working directory or execstart points to PROGRAM_DIR
            local u_wdir
            u_wdir="$(systemctl show -p WorkingDirectory --value "$u" 2>/dev/null || echo '')"
            local u_exec
            u_exec="$(systemctl show -p ExecStart --value "$u" 2>/dev/null || echo '')"
            if [[ "$u_wdir" == "$PROGRAM_DIR" || "$u_wdir" == "$PROGRAM_DIR"/* || "$u_exec" == *"$PROGRAM_DIR/"* || "$u_exec" == *"$PROGRAM_DIR "* ]]; then
                DISCOVERED_SERVICES+=("$u (systemd service)")
            fi
        done
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if [[ -f "/etc/init.d/mornye" ]] && grep -q "$PROGRAM_DIR" "/etc/init.d/mornye" 2>/dev/null; then
            DISCOVERED_SERVICES+=("mornye (openrc service)")
        fi
    fi
}

discover_mornye_processes() {
    # 1. Quick tunnel PID file
    if [[ -f "$RUN_DIR/quick_tunnel.pid" ]]; then
        local qpid
        qpid="$(cat "$RUN_DIR/quick_tunnel.pid" 2>/dev/null || echo '')"
        if [[ -n "$qpid" ]] && kill -0 "$qpid" 2>/dev/null; then
            DISCOVERED_PROCESSES+=("Quick Tunnel cloudflared (PID: $qpid)")
        fi
    fi

    # 2. Host processes originating from Mornye directory (excluding self, shell, and protected services)
    if [[ -d /proc ]]; then
        for pid_dir in /proc/[0-9]*; do
            local p
            p="$(basename "$pid_dir")"
            [[ "$p" == "$$" || "$p" == "$PPID" ]] && continue

            # Never touch protected SONG Bridge PID (13951)
            local song_pid
            song_pid="$(systemctl show -p MainPID --value mornye-storage.service 2>/dev/null || echo '')"
            [[ -n "$song_pid" && "$p" == "$song_pid" ]] && continue

            local cwd
            cwd="$(readlink -f "/proc/$p/cwd" 2>/dev/null || echo '')"
            if [[ "$cwd" == "$PROGRAM_DIR" || "$cwd" == "$PROGRAM_DIR"/* ]]; then
                local cmd
                cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || echo 'process')"
                # Check that it's a python or bash worker script inside Mornye
                if [[ "$cmd" == *"python"* || "$cmd" == *"mornye"* || "$cmd" == *"repair_engine"* ]]; then
                    DISCOVERED_PROCESSES+=("Mornye background worker (PID: $p, cmd: ${cmd:0:60})")
                fi
            fi
        done
    fi
}

discover_mornye_docker() {
    if ! has_docker; then
        return 0
    fi

    # 1. Containers matching Mornye Compose project or explicit names with working directory check
    local c_list
    c_list="$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Labels}}' 2>/dev/null || echo '')"
    while IFS='|' read -r c_name c_img c_status c_labels || [[ -n "$c_name" ]]; do
        [[ -z "$c_name" ]] && continue

        local c_proj="" c_wdir=""
        c_proj="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$c_name" 2>/dev/null || echo '')"
        c_wdir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c_name" 2>/dev/null || echo '')"

        if [[ "$c_name" == "mornye-webdav" ]]; then
            # Verify Compose working directory and project ownership
            if [[ -n "$c_wdir" && "$c_wdir" != "$PROGRAM_DIR" ]]; then
                PRESERVED_RESOURCES+=("Docker Container: $c_name (Foreign working_dir: $c_wdir)")
            elif [[ -n "$c_proj" && "$c_proj" != "mornye-network-storage" && "$c_proj" != "mornye" ]]; then
                PRESERVED_RESOURCES+=("Docker Container: $c_name (Foreign project: $c_proj)")
            else
                DISCOVERED_CONTAINERS+=("$c_name (Image: $c_img, Status: $c_status)")
            fi
        elif [[ "$c_name" == "mornye-tunnel" ]]; then
            if [[ -n "$c_wdir" && "$c_wdir" != "$PROGRAM_DIR" ]]; then
                PRESERVED_RESOURCES+=("Docker Container: $c_name (Foreign working_dir: $c_wdir)")
            elif [[ "$c_proj" == "mornye-network-storage" || "$c_proj" == "mornye" ]]; then
                DISCOVERED_CONTAINERS+=("$c_name (Compose Tunnel, Status: $c_status)")
            else
                PRESERVED_RESOURCES+=("Docker Container: $c_name (Foreign / System)")
            fi
        else
            PRESERVED_RESOURCES+=("Docker Container: $c_name (Foreign / Unrelated)")
        fi
    done <<< "$c_list"

    # 2. Images matching mornye-webdav:latest
    local img_list
    img_list="$(docker images --format '{{.Repository}}:{{.Tag}}|{{.ID}}|{{.Size}}' 2>/dev/null || echo '')"
    while IFS='|' read -r i_repo i_id i_size || [[ -n "$i_repo" ]]; do
        [[ -z "$i_repo" ]] && continue
        if [[ "$i_repo" =~ ^mornye-webdav ]]; then
            DISCOVERED_IMAGES+=("$i_repo ($i_size, ID: $i_id)")
        else
            PRESERVED_RESOURCES+=("Docker Image: $i_repo (Foreign / System)")
        fi
    done <<< "$img_list"

    # 3. Networks
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qw "mornye-net"; then
        DISCOVERED_NETWORKS+=("mornye-net (Bridge network)")
    fi

    # 4. Volumes
    local vol_list
    vol_list="$(docker volume ls --filter label=com.docker.compose.project=mornye-network-storage --format '{{.Name}}' 2>/dev/null || echo '')"
    if [[ -n "$vol_list" ]]; then
        for v in $vol_list; do
            DISCOVERED_VOLUMES+=("$v")
        done
    fi
}

discover_scheduled_tasks() {
    # 1. User crontab
    if has_cmd crontab; then
        local user_cron
        user_cron="$(crontab -l 2>/dev/null || echo '')"
        if echo "$user_cron" | grep -qE "(${PROGRAM_DIR}|mornye\.sh)"; then
            while read -r line; do
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                if echo "$line" | grep -qE "(${PROGRAM_DIR}|mornye\.sh)"; then
                    DISCOVERED_CRON_JOBS+=("User Cron: $line")
                fi
            done <<< "$user_cron"
        fi
    fi

    # 2. Systemd timers
    if [[ "$INIT_SYSTEM" == "systemd" ]] && has_cmd systemctl; then
        local timers
        timers="$(systemctl list-timers 'mornye*' --no-legend 2>/dev/null | awk '{print $NF}' || echo '')"
        for t in $timers; do
            [[ -z "$t" ]] && continue
            local unit_file
            unit_file="$(systemctl show -p FragmentPath --value "$t" 2>/dev/null || echo '')"
            if grep -q "$PROGRAM_DIR" "$unit_file" 2>/dev/null; then
                DISCOVERED_TIMERS+=("$t (systemd timer)")
            fi
        done
    fi
}

discover_firewall_rules() {
    if has_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status numbered 2>/dev/null | grep -q "$MORNYE_HOST_PORT"; then
            DISCOVERED_FIREWALL_RULES+=("UFW rule for Mornye host port: $MORNYE_HOST_PORT")
        fi
    fi
}

discover_filesystem_inventory() {
    # Calculate sizes and file counts safely
    calc_dir_stats() {
        local dir="$1"
        if [[ -d "$dir" ]]; then
            local sz
            sz="$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
            local cnt
            cnt="$(find "$dir" -type f 2>/dev/null | wc -l || echo 0)"
            echo "$sz|$cnt"
        else
            echo "0B|0"
        fi
    }

    DATA_STATS="$(calc_dir_stats "$DATA_DIR")"
    STORAGE_STATS="$(calc_dir_stats "$STORAGE_DIR")"
    BACKUP_STATS="$(calc_dir_stats "$BACKUP_DIR")"
    LOG_STATS="$(calc_dir_stats "$LOG_DIR")"
    CONFIG_STATS="$(calc_dir_stats "$CONFIG_DIR")"
}

# ------------------------------------------------------------------------------
# 5. REMOVAL PLAN PRESENTATION
# ------------------------------------------------------------------------------

display_plan() {
    local mode_str="MODE A: SAFE UNINSTALL"
    local mode_desc="Removes services, containers, networks, and images. PRESERVES database and user storage."
    if [[ "$PURGE_MODE" == true ]]; then
        mode_str="MODE B: COMPLETE PURGE (--purge)"
        mode_desc="PERMANENTLY DELETES databases, storage, music files, backups, config, and logs."
    fi

    echo -e "${BOLD}======================================================================${NC}"
    echo -e "${BOLD}         MORNYE NETWORK STORAGE — UNINSTALLATION PLAN         ${NC}"
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "Mode                 : ${CYAN}${BOLD}${mode_str}${NC}"
    echo -e "Description          : $mode_desc"
    echo -e "Target Directory     : $PROGRAM_DIR"
    echo -e "Host System          : $OS_NAME (Init: $INIT_SYSTEM, User: $CURRENT_USER)"
    echo -e "${BOLD}----------------------------------------------------------------------${NC}"

    echo -e "${BOLD}${PURPLE}1. STRICTLY PROTECTED FOREIGN SERVICES & RESOURCES (WILL NOT BE TOUCHED):${NC}"
    if [[ ${#PROTECTED_SERVICES[@]} -gt 0 ]]; then
        for p in "${PROTECTED_SERVICES[@]}"; do
            echo -e "  ${GREEN}[PROTECTED]${NC} $p"
        done
    else
        echo -e "  [i] No foreign services active on standard ports."
    fi
    if [[ ${#PRESERVED_RESOURCES[@]} -gt 0 ]]; then
        for pr in "${PRESERVED_RESOURCES[@]}"; do
            echo -e "  ${GREEN}[PROTECTED]${NC} $pr"
        done
    fi
    echo -e "  ${GREEN}[PROTECTED]${NC} Foreign Docker Containers & Volumes: Any non-Mornye resources are preserved."
    echo -e "  ${GREEN}[PROTECTED]${NC} System Packages: Docker Engine and Docker Compose will NOT be removed."

    echo -e "\n${BOLD}${RED}2. MORNYE RESOURCES TO BE STOPPED & REMOVED:${NC}"
    if [[ ${#DISCOVERED_SERVICES[@]} -gt 0 ]]; then
        for s in "${DISCOVERED_SERVICES[@]}"; do
            echo -e "  - Service: $s"
        done
    fi
    if [[ ${#DISCOVERED_PROCESSES[@]} -gt 0 ]]; then
        for pr in "${DISCOVERED_PROCESSES[@]}"; do
            echo -e "  - Process: $pr"
        done
    fi
    if [[ ${#DISCOVERED_CONTAINERS[@]} -gt 0 ]]; then
        for c in "${DISCOVERED_CONTAINERS[@]}"; do
            echo -e "  - Container: $c"
        done
    else
        echo -e "  - Containers: None running (or already removed)"
    fi
    if [[ ${#DISCOVERED_IMAGES[@]} -gt 0 ]]; then
        for img in "${DISCOVERED_IMAGES[@]}"; do
            echo -e "  - Image: $img"
        done
    fi
    if [[ ${#DISCOVERED_NETWORKS[@]} -gt 0 ]]; then
        for net in "${DISCOVERED_NETWORKS[@]}"; do
            echo -e "  - Network: $net"
        done
    fi
    if [[ ${#DISCOVERED_VOLUMES[@]} -gt 0 ]]; then
        for vol in "${DISCOVERED_VOLUMES[@]}"; do
            echo -e "  - Volume: $vol"
        done
    fi
    if [[ ${#DISCOVERED_CRON_JOBS[@]} -gt 0 ]]; then
        for cj in "${DISCOVERED_CRON_JOBS[@]}"; do
            echo -e "  - Scheduled Task: $cj"
        done
    fi
    if [[ ${#DISCOVERED_FIREWALL_RULES[@]} -gt 0 ]]; then
        for fwr in "${DISCOVERED_FIREWALL_RULES[@]}"; do
            echo -e "  - Firewall Rule: $fwr"
        done
    fi

    echo -e "\n${BOLD}${YELLOW}3. FILE & DATA RETENTION STATUS:${NC}"
    IFS='|' read -r d_sz d_cnt <<< "$DATA_STATS"
    IFS='|' read -r s_sz s_cnt <<< "$STORAGE_STATS"
    IFS='|' read -r b_sz b_cnt <<< "$BACKUP_STATS"
    IFS='|' read -r l_sz l_cnt <<< "$LOG_STATS"

    if [[ "$PURGE_MODE" == true ]]; then
        echo -e "  ${RED}[PERMANENT DELETION]${NC} Database Directory : $DATA_DIR ($d_sz, $d_cnt files)"
        echo -e "  ${RED}[PERMANENT DELETION]${NC} Storage Directory  : $STORAGE_DIR ($s_sz, $s_cnt files)"
        echo -e "  ${RED}[PERMANENT DELETION]${NC} Backups Directory  : $BACKUP_DIR ($b_sz, $b_cnt archives)"
        echo -e "  ${RED}[PERMANENT DELETION]${NC} Configuration      : $CONFIG_DIR and $PROGRAM_DIR/.env"
        echo -e "  ${RED}[PERMANENT DELETION]${NC} Logs Directory     : $LOG_DIR ($l_sz)"
    else
        echo -e "  ${GREEN}[PRESERVED]${NC} Database Directory : $DATA_DIR ($d_sz, $d_cnt files)"
        echo -e "  ${GREEN}[PRESERVED]${NC} Storage Directory  : $STORAGE_DIR ($s_sz, $s_cnt files)"
        echo -e "  ${GREEN}[PRESERVED]${NC} Backups Directory  : $BACKUP_DIR ($b_sz, $b_cnt archives)"
        echo -e "  ${GREEN}[PRESERVED]${NC} Configuration      : $CONFIG_DIR and $PROGRAM_DIR/.env"
        echo -e "  ${YELLOW}[CLEANED]${NC}   Temporary & Cache   : $RUN_DIR, .pytest_cache, __pycache__"
    fi
    echo -e "${BOLD}======================================================================${NC}"
}

# ------------------------------------------------------------------------------
# 6. OPERATOR GATE & CONFIRMATION
# ------------------------------------------------------------------------------

create_backup() {
    local dest="${1:-}"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    if [[ -z "$dest" ]]; then
        dest="/tmp/mornye_backup_${timestamp}.tar.gz"
    fi

    if [[ -e "$dest" && "$AUTO_CONFIRM" != true ]]; then
        echo -e "${YELLOW}[!] Backup destination already exists: $dest${NC}"
        read -p "Overwrite existing backup file? [y/N]: " -r ow
        if [[ ! "$ow" =~ ^[Yy]$ ]]; then
            echo -e "[*] Backup cancelled. Aborting purge to protect data."
            return 1
        fi
    fi

    echo -e "${CYAN}[*] Generating complete safety backup archive at: $dest...${NC}"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true

    local items=()
    local external_storage_detected=false
    local external_storage_path=""

    [[ -d "$DATA_DIR" && ("$DATA_DIR" == "$PROGRAM_DIR" || "$DATA_DIR" == "$PROGRAM_DIR"/*) ]] && items+=("database")

    # Check if STORAGE_DIR is internal or external
    if [[ -d "$STORAGE_DIR" ]]; then
        if [[ "$STORAGE_DIR" == "$PROGRAM_DIR" || "$STORAGE_DIR" == "$PROGRAM_DIR"/* ]]; then
            items+=("storage")
        else
            external_storage_detected=true
            external_storage_path="$STORAGE_DIR"
        fi
    fi

    [[ -d "$BACKUP_DIR" && ("$BACKUP_DIR" == "$PROGRAM_DIR" || "$BACKUP_DIR" == "$PROGRAM_DIR"/*) ]] && items+=("backups")
    [[ -d "$CONFIG_DIR" && ("$CONFIG_DIR" == "$PROGRAM_DIR" || "$CONFIG_DIR" == "$PROGRAM_DIR"/*) ]] && items+=("config")
    [[ -f "$PROGRAM_DIR/.env" ]] && items+=(".env")

    if [[ ${#items[@]} -eq 0 && "$external_storage_detected" != true ]]; then
        echo -e "${YELLOW}[!] No data directories found to back up.${NC}"
        return 0
    fi

    if [[ "$external_storage_detected" == true ]]; then
        echo -e "${YELLOW}[NOTICE] External STORAGE_PATH detected at: $external_storage_path${NC}"
        echo -e "${YELLOW}[NOTICE] External storage directory is excluded from local archive and must be backed up independently.${NC}"
    fi

    if [[ ${#items[@]} -gt 0 ]]; then
        tar -czf "$dest" -C "$PROGRAM_DIR" "${items[@]}" 2>/dev/null || {
            echo -e "${RED}[ERROR] Backup creation failed during tar execution.${NC}" >&2
            rm -f "$dest" 2>/dev/null || true
            return 1
        }
    fi

    # 1. Validate archive existence and non-zero size
    if [[ ! -f "$dest" || ! -s "$dest" ]]; then
        echo -e "${RED}[ERROR] Backup file does not exist or is empty: $dest${NC}" >&2
        rm -f "$dest" 2>/dev/null || true
        return 1
    fi

    # 2. Run tar -tzf to strictly verify gzip archive integrity
    if ! tar -tzf "$dest" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Backup archive integrity verification failed (tar -tzf failed for $dest).${NC}" >&2
        rm -f "$dest" 2>/dev/null || true
        return 1
    fi

    local bsz
    bsz="$(du -sh "$dest" 2>/dev/null | awk '{print $1}')"
    echo -e "${GREEN}[✔] Backup successfully created and integrity verified: $dest ($bsz)${NC}"
    if [[ "$external_storage_detected" == true ]]; then
        echo -e "  -> Report: External storage ($external_storage_path) was EXCLUDED from this archive."
    else
        echo -e "  -> Report: All local application data (database, storage, config, .env) verified in archive."
    fi
    BACKUP_CREATED_PATH="$dest"
    return 0
}

operator_gate() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "\n${CYAN}${BOLD}[DRY-RUN] Simulation completed. 0 system changes made.${NC}"
        echo -e "Review the plan above to see all actions that would be executed."
        exit 0
    fi

    # If standalone backup requested
    if [[ "$CREATE_BACKUP_REQUESTED" == true && "$PURGE_MODE" != true ]]; then
        create_backup "$BACKUP_DEST"
        exit $?
    fi

    if [[ "$PURGE_MODE" == true ]]; then
        # 1. Offer optional backup before purge
        if [[ "$SKIP_BACKUP" != true && "$AUTO_CONFIRM" != true ]]; then
            echo -e "\n${CYAN}Would you like to create a safety backup before purging? [Y/n]: ${NC}\c"
            read -r bk_ans
            if [[ -z "$bk_ans" || "$bk_ans" =~ ^[Yy]$ ]]; then
                echo -e "Enter backup destination file path [/tmp/mornye_backup_$(date +%Y%m%d_%H%M%S).tar.gz]: \c"
                read -r user_dest
                create_backup "$user_dest" || {
                    echo -e "${RED}[ABORTED] Backup failed. Purge halted.${NC}"
                    exit 1
                }
            fi
        fi

        # 2. Strict typed confirmation gate
        echo -e "\n${RED}${BOLD}======================================================================${NC}"
        echo -e "${RED}${BOLD}          CRITICAL: COMPLETE DATA PURGE CONFIRMATION REQUIRED         ${NC}"
        echo -e "${RED}${BOLD}======================================================================${NC}"
        echo -e "${YELLOW}This operation will permanently delete databases, user storage, music tracks,${NC}"
        echo -e "${YELLOW}recycle bin, and backups. This action CANNOT be undone.${NC}"
        echo ""
        echo -e "To confirm permanent deletion, you must type exactly: ${BOLD}${RED}DELETE MORNYE DATA${NC}"
        echo -e "Any other response (such as 'y' or 'yes') will abort the operation."
        echo ""

        if [[ -z "$CONFIRM_TOKEN" ]]; then
            IFS= read -p "Confirmation: " -r CONFIRM_TOKEN
        fi

        if [[ "$CONFIRM_TOKEN" != "DELETE MORNYE DATA" ]]; then
            echo -e "${YELLOW}[ABORTED] Confirmation token mismatch (received: '$CONFIRM_TOKEN'). No data was deleted.${NC}"
            exit 1
        fi
        echo -e "${GREEN}[✔] Confirmation token validated: 'DELETE MORNYE DATA'. Proceeding with purge...${NC}\n"
    else
        # Mode A: Safe Uninstall confirmation
        if [[ "$AUTO_CONFIRM" != true ]]; then
            echo -e "\n${CYAN}Mornye services, containers, and images will be uninstalled.${NC}"
            echo -e "${GREEN}${BOLD}YOUR USER DATA, DATABASE, AND STORAGE WILL BE PRESERVED.${NC}"
            read -p "Proceed with Safe Uninstall? [y/N]: " -r conf
            if [[ ! "$conf" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}[*] Safe uninstall cancelled by operator.${NC}"
                exit 0
            fi
        fi
    fi
}

# ------------------------------------------------------------------------------
# 7. EXECUTION STAGES
# ------------------------------------------------------------------------------

stop_mornye_processes() {
    echo -e "${CYAN}[*] Step 1: Stopping Mornye background processes...${NC}"

    # 1. Quick tunnel PID
    if [[ -f "$RUN_DIR/quick_tunnel.pid" ]]; then
        local qpid
        qpid="$(cat "$RUN_DIR/quick_tunnel.pid" 2>/dev/null || echo '')"
        if [[ -n "$qpid" ]] && kill -0 "$qpid" 2>/dev/null; then
            kill -15 "$qpid" 2>/dev/null || true
            sleep 1
            kill -9 "$qpid" 2>/dev/null || true
            REMOVED_PROCESSES+=("Quick Tunnel process (PID: $qpid)")
        fi
        rm -f "$RUN_DIR/quick_tunnel.pid" 2>/dev/null || true
    fi

    # 2. Kill background workers originated from PROGRAM_DIR (excluding self and PID 13951)
    if [[ -d /proc ]]; then
        for pid_dir in /proc/[0-9]*; do
            local p
            p="$(basename "$pid_dir")"
            [[ "$p" == "$$" || "$p" == "$PPID" ]] && continue

            local song_pid
            song_pid="$(systemctl show -p MainPID --value mornye-storage.service 2>/dev/null || echo '')"
            [[ -n "$song_pid" && "$p" == "$song_pid" ]] && continue

            local cwd
            cwd="$(readlink -f "/proc/$p/cwd" 2>/dev/null || echo '')"
            if [[ "$cwd" == "$PROGRAM_DIR" || "$cwd" == "$PROGRAM_DIR"/* ]]; then
                local cmd
                cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || echo '')"
                if [[ "$cmd" == *"repair_engine"* || "$cmd" == *"monitor"* ]]; then
                    kill -15 "$p" 2>/dev/null || true
                    REMOVED_PROCESSES+=("Mornye background worker (PID: $p)")
                fi
            fi
        done
    fi
    echo -e "${GREEN}[✔] Background processes stopped.${NC}"
}

remove_mornye_services() {
    echo -e "${CYAN}[*] Step 2: Removing Mornye-owned system services...${NC}"
    if [[ "$INIT_SYSTEM" == "systemd" ]] && has_cmd systemctl; then
        local units
        units="$(systemctl list-unit-files 'mornye*.service' --no-legend 2>/dev/null | awk '{print $1}' || echo '')"
        for u in $units; do
            # NEVER touch SONG Bridge or legacy tunnel
            if [[ "$u" == "mornye-storage.service" || "$u" == "mornye-tunnel.service" ]]; then
                continue
            fi
            local u_wdir
            u_wdir="$(systemctl show -p WorkingDirectory --value "$u" 2>/dev/null || echo '')"
            local u_exec
            u_exec="$(systemctl show -p ExecStart --value "$u" 2>/dev/null || echo '')"
            if [[ "$u_wdir" == "$PROGRAM_DIR" || "$u_wdir" == "$PROGRAM_DIR"/* || "$u_exec" == *"$PROGRAM_DIR/"* || "$u_exec" == *"$PROGRAM_DIR "* ]]; then
                echo -e "  - Stopping and disabling unit $u..."
                systemctl stop "$u" 2>/dev/null || true
                systemctl disable "$u" 2>/dev/null || true
                local u_path
                u_path="$(systemctl show -p FragmentPath --value "$u" 2>/dev/null || echo '')"
                if [[ -n "$u_path" && -f "$u_path" ]]; then
                    rm -f "$u_path" 2>/dev/null || true
                fi
                REMOVED_SERVICES+=("$u")
            fi
        done
        systemctl daemon-reload 2>/dev/null || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if [[ -f "/etc/init.d/mornye" ]] && grep -q "$PROGRAM_DIR" "/etc/init.d/mornye" 2>/dev/null; then
            rc-service mornye stop 2>/dev/null || true
            rc-update del mornye default 2>/dev/null || true
            rm -f "/etc/init.d/mornye" 2>/dev/null || true
            REMOVED_SERVICES+=("mornye (openrc)")
        fi
    fi
    echo -e "${GREEN}[✔] System services cleaned.${NC}"
}

remove_mornye_docker() {
    echo -e "${CYAN}[*] Step 3: Removing Mornye Docker resources...${NC}"
    if ! has_docker; then
        echo -e "${YELLOW}[!] Docker CLI not available. Skipping container teardown.${NC}"
        return 0
    fi

    # 1. Gracefully stop compose stack if compose.yaml exists
    if [[ -f "$PROGRAM_DIR/compose.yaml" ]]; then
        docker compose --profile tunnel down --remove-orphans 2>/dev/null || true
    fi

    # 2. Remove webdav container explicitly with ownership check
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-webdav"; then
        local c_wdir="" c_proj=""
        c_wdir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' mornye-webdav 2>/dev/null || echo '')"
        c_proj="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' mornye-webdav 2>/dev/null || echo '')"
        if [[ -n "$c_wdir" && "$c_wdir" != "$PROGRAM_DIR" ]]; then
            echo -e "${YELLOW}[!] Preserving container 'mornye-webdav': belongs to another working directory ($c_wdir).${NC}"
            PRESERVED_RESOURCES+=("mornye-webdav (Foreign working_dir: $c_wdir)")
        elif [[ -n "$c_proj" && "$c_proj" != "mornye-network-storage" && "$c_proj" != "mornye" ]]; then
            echo -e "${YELLOW}[!] Preserving container 'mornye-webdav': belongs to foreign project ($c_proj).${NC}"
            PRESERVED_RESOURCES+=("mornye-webdav (Foreign project: $c_proj)")
        else
            echo -e "  - Stopping and removing verified Mornye WebDAV container..."
            docker stop mornye-webdav 2>/dev/null || true
            docker rm -f mornye-webdav 2>/dev/null || true
            REMOVED_CONTAINERS+=("mornye-webdav")
        fi
    fi

    # 3. Remove tunnel container if labeled with mornye project
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-tunnel"; then
        local t_wdir="" t_proj=""
        t_wdir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' mornye-tunnel 2>/dev/null || echo '')"
        t_proj="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' mornye-tunnel 2>/dev/null || echo '')"
        if [[ -n "$t_wdir" && "$t_wdir" != "$PROGRAM_DIR" ]]; then
            echo -e "${YELLOW}[!] Preserving container 'mornye-tunnel': belongs to another working directory ($t_wdir).${NC}"
            PRESERVED_RESOURCES+=("mornye-tunnel (Foreign working_dir: $t_wdir)")
        elif [[ "$t_proj" == "mornye-network-storage" || "$t_proj" == "mornye" ]]; then
            docker stop mornye-tunnel 2>/dev/null || true
            docker rm -f mornye-tunnel 2>/dev/null || true
            REMOVED_CONTAINERS+=("mornye-tunnel")
        fi
    fi

    # 4. Remove Docker network mornye-net
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qw "mornye-net"; then
        docker network rm mornye-net 2>/dev/null || true
        REMOVED_NETWORKS+=("mornye-net")
    fi

    # 5. Remove Docker image mornye-webdav:latest
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qE "^mornye-webdav:(latest)?$"; then
        docker rmi -f mornye-webdav:latest 2>/dev/null || true
        REMOVED_IMAGES+=("mornye-webdav:latest")
    fi

    # 6. Remove project volumes
    local vol_list
    vol_list="$(docker volume ls --filter label=com.docker.compose.project=mornye-network-storage --format '{{.Name}}' 2>/dev/null || echo '')"
    if [[ -n "$vol_list" ]]; then
        for v in $vol_list; do
            docker volume rm -f "$v" 2>/dev/null || true
            REMOVED_VOLUMES+=("$v")
        done
    fi

    echo -e "${GREEN}[✔] Docker resources removed.${NC}"
}

remove_scheduled_tasks() {
    echo -e "${CYAN}[*] Step 4: Cleaning scheduled cron tasks and timers...${NC}"
    if has_cmd crontab; then
        local user_cron
        user_cron="$(crontab -l 2>/dev/null || echo '')"
        if echo "$user_cron" | grep -qE "(${PROGRAM_DIR}|mornye\.sh)"; then
            echo "$user_cron" | grep -v "$PROGRAM_DIR" | grep -v "mornye.sh" | crontab - 2>/dev/null || true
            REMOVED_CRON_JOBS+=("Removed Mornye crontab entries")
        fi
    fi

    if [[ "$INIT_SYSTEM" == "systemd" ]] && has_cmd systemctl; then
        local timers
        timers="$(systemctl list-timers 'mornye*' --no-legend 2>/dev/null | awk '{print $NF}' || echo '')"
        for t in $timers; do
            [[ -z "$t" ]] && continue
            local unit_file
            unit_file="$(systemctl show -p FragmentPath --value "$t" 2>/dev/null || echo '')"
            if grep -q "$PROGRAM_DIR" "$unit_file" 2>/dev/null; then
                systemctl stop "$t" 2>/dev/null || true
                systemctl disable "$t" 2>/dev/null || true
                rm -f "$unit_file" 2>/dev/null || true
            fi
        done
        systemctl daemon-reload 2>/dev/null || true
    fi
    echo -e "${GREEN}[✔] Scheduled tasks cleaned.${NC}"
}

remove_firewall_rules() {
    echo -e "${CYAN}[*] Step 5: Checking and removing Mornye firewall rules...${NC}"
    if has_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status numbered 2>/dev/null | grep -q "$MORNYE_HOST_PORT"; then
            ufw delete allow "$MORNYE_HOST_PORT" 2>/dev/null || true
            REMOVED_FIREWALL_RULES+=("UFW allow port $MORNYE_HOST_PORT")
        fi
    fi
    echo -e "${GREEN}[✔] Firewall rules verified.${NC}"
}

handle_cloudflare() {
    echo -e "${CYAN}[*] Step 6: Handling Cloudflare Tunnel integrations...${NC}"
    # Verify legacy tunnel is untouched
    if systemctl is-active --quiet mornye-tunnel.service 2>/dev/null; then
        PRESERVED_RESOURCES+=("mornye-tunnel.service (Active & Preserved)")
    fi

    # Check shared /etc/cloudflared/config.yml for Mornye-specific ingress rule
    local shared_cf="/etc/cloudflared/config.yml"
    if [[ -f "$shared_cf" ]]; then
        if grep -qE "(127\.0\.0\.1|localhost):${MORNYE_HOST_PORT}" "$shared_cf" 2>/dev/null; then
            echo -e "[*] Isolating and removing Mornye port $MORNYE_HOST_PORT from $shared_cf..."
            if [[ "$DRY_RUN" == true ]]; then
                echo -e "  [DRY-RUN] Would isolate and remove Mornye port $MORNYE_HOST_PORT from $shared_cf using structured YAML parsing"
                return 0
            fi

            # Check for Python 3 and PyYAML availability
            if ! python3 -c "import yaml" >/dev/null 2>&1; then
                echo -e "${YELLOW}[!] Python3 YAML parser (PyYAML) not available. Retaining $shared_cf without modification to prevent corruption.${NC}"
                return 0
            fi

            local bak_cf="${shared_cf}.bak_$(date +%Y%m%d_%H%M%S)"
            cp -p "$shared_cf" "$bak_cf" 2>/dev/null || true

            local tmp_cf
            tmp_cf="$(mktemp "${shared_cf}.tmp.XXXXXX" 2>/dev/null || mktemp /tmp/cf_clean.XXXXXX)"

            local py_status=0
            python3 - "$shared_cf" "$MORNYE_HOST_PORT" "$tmp_cf" << 'EOF' || py_status=$?
import sys
import yaml

src_path = sys.argv[1]
port = str(sys.argv[2])
dst_path = sys.argv[3]

try:
    with open(src_path, 'r', encoding='utf-8') as f:
        config = yaml.safe_load(f)
except Exception:
    sys.exit(2)

if not isinstance(config, dict):
    sys.exit(3)

ingress = config.get('ingress')
if not isinstance(ingress, list):
    sys.exit(4)

new_ingress = []
removed = False

for entry in ingress:
    if not isinstance(entry, dict):
        new_ingress.append(entry)
        continue

    service = str(entry.get('service', ''))
    if f":{port}" in service:
        removed = True
        continue
    new_ingress.append(entry)

if not removed:
    sys.exit(0)

if not new_ingress:
    sys.exit(5)

config['ingress'] = new_ingress

try:
    with open(dst_path, 'w', encoding='utf-8') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)
except Exception:
    sys.exit(6)

try:
    with open(dst_path, 'r', encoding='utf-8') as f:
        verify_cfg = yaml.safe_load(f)
    if not isinstance(verify_cfg, dict) or not isinstance(verify_cfg.get('ingress'), list):
        sys.exit(7)
except Exception:
    sys.exit(8)

sys.exit(10)
EOF

            if [[ $py_status -eq 10 && -s "$tmp_cf" ]]; then
                mv -f "$tmp_cf" "$shared_cf" 2>/dev/null || {
                    echo -e "${RED}[ERROR] Failed to replace $shared_cf atomically. Restoring backup...${NC}"
                    cp -pf "$bak_cf" "$shared_cf" 2>/dev/null || true
                    rm -f "$tmp_cf" 2>/dev/null || true
                    return 1
                }
                echo -e "${GREEN}[✔] Cleaned Mornye ingress from $shared_cf structurally (Backup: $bak_cf).${NC}"
            elif [[ $py_status -eq 0 ]]; then
                rm -f "$tmp_cf" 2>/dev/null || true
                echo -e "[*] No active ingress rule targeting port $MORNYE_HOST_PORT found in $shared_cf."
            else
                rm -f "$tmp_cf" 2>/dev/null || true
                echo -e "${YELLOW}[!] YAML structural processing failed (code $py_status). Retaining original $shared_cf intact.${NC}"
            fi
        fi
    fi
    echo -e "${GREEN}[✔] Cloudflare Tunnel dependencies handled safely.${NC}"
}

remove_files() {
    echo -e "${CYAN}[*] Step 7: Cleaning application files and directories...${NC}"

    # 1. CLI Symlink
    for link in /usr/local/bin/mornye /usr/bin/mornye; do
        if [[ -L "$link" ]]; then
            local tgt
            tgt="$(readlink -f "$link" 2>/dev/null || echo '')"
            if [[ "$tgt" == "$PROGRAM_DIR" || "$tgt" == "$PROGRAM_DIR"/* ]]; then
                safe_remove_path "$link"
            fi
        fi
    done

    # 2. Runtime temporary files
    safe_remove_path "$RUN_DIR"
    safe_remove_path "$PROGRAM_DIR/.pytest_cache"
    find "$PROGRAM_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

    if [[ "$PURGE_MODE" == true ]]; then
        echo -e "${RED}[*] Executing complete data purge...${NC}"
        safe_remove_path "$DATA_DIR"
        safe_remove_path "$STORAGE_DIR"
        safe_remove_path "$BACKUP_DIR"
        safe_remove_path "$CONFIG_DIR"
        safe_remove_path "$PROGRAM_DIR/.env"
        find "$PROGRAM_DIR" -maxdepth 1 -name ".env.bak_*" -exec rm -f {} + 2>/dev/null || true
        safe_remove_path "$PROGRAM_DIR/venv"
        safe_remove_path "$LOG_DIR"
    else
        echo -e "${GREEN}[✔] Preserved user database, storage, backups, and configurations.${NC}"
    fi
    echo -e "${GREEN}[✔] File removal phase complete.${NC}"
}

# ------------------------------------------------------------------------------
# 8. FINAL VERIFICATION
# ------------------------------------------------------------------------------

run_final_verification() {
    echo -e "\n${BOLD}${CYAN}[*] Step 8: Executing Post-Uninstall Verification...${NC}"
    local verif_passed=true

    # 1. Verify Mornye container stopped/removed
    if has_docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-webdav"; then
        echo -e "${RED}[✘] Mornye WebDAV container is still present.${NC}"
        verif_passed=false
    else
        echo -e "  ${GREEN}[✔] Mornye Docker containers removed.${NC}"
    fi

    # 2. Verify Mornye host port is free
    if has_cmd ss; then
        if ss -tulpn 2>/dev/null | grep -q ":${MORNYE_HOST_PORT} "; then
            echo -e "${RED}[✘] Port ${MORNYE_HOST_PORT} is still listening.${NC}"
            verif_passed=false
        else
            echo -e "  ${GREEN}[✔] Port ${MORNYE_HOST_PORT} is free.${NC}"
        fi
    fi

    # 3. Verify SONG Bridge (mornye-storage.service on port 8000) is STILL RUNNING!
    if systemctl is-active --quiet mornye-storage.service 2>/dev/null; then
        echo -e "  ${GREEN}[✔] SONG Bridge (mornye-storage.service) is ACTIVE and healthy.${NC}"
    fi

    # 4. Verify foreign services
    if systemctl is-active --quiet mornye-tunnel.service 2>/dev/null; then
        echo -e "  ${GREEN}[✔] Cloudflare Tunnel (mornye-tunnel.service) is ACTIVE.${NC}"
    fi

    if [[ "$verif_passed" == true ]]; then
        VERIFICATION_STATUS="VERIFIED_SUCCESSFUL"
        echo -e "${GREEN}${BOLD}[✔] ALL POST-UNINSTALL CHECKS PASSED.${NC}"
    else
        VERIFICATION_STATUS="VERIFICATION_WARNINGS"
        echo -e "${YELLOW}${BOLD}[!] Post-uninstall completed with warnings.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 9. REMOVAL AUDIT REPORT
# ------------------------------------------------------------------------------

generate_report() {
    local timestamp
    timestamp="$(date +%Y-%m-%d-%H%M%S)"
    local rep_file="$UNINSTALL_LOG_DIR/uninstall-${timestamp}.txt"
    local alt_rep="/tmp/mornye-uninstall-${timestamp}.txt"

    mkdir -p "$UNINSTALL_LOG_DIR" 2>/dev/null || true

    local rep_dest="$rep_file"
    if [[ ! -d "$UNINSTALL_LOG_DIR" || "$PURGE_MODE" == true ]]; then
        rep_dest="$alt_rep"
    fi

    {
        echo "======================================================================"
        echo "           MORNYE NETWORK STORAGE — UNINSTALLATION REPORT             "
        echo "======================================================================"
        echo "Timestamp          : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Uninstallation Mode: $([[ "$PURGE_MODE" == true ]] && echo "COMPLETE PURGE (--purge)" || echo "SAFE UNINSTALL")"
        echo "Target Directory   : $PROGRAM_DIR"
        echo "Host System        : $OS_NAME"
        echo "Init System        : $INIT_SYSTEM"
        echo "Executing User     : $CURRENT_USER (Sudo: $REAL_USER)"
        echo "Verification State : $VERIFICATION_STATUS"
        if [[ -n "$BACKUP_CREATED_PATH" ]]; then
            echo "Pre-Purge Backup   : $BACKUP_CREATED_PATH"
        fi
        echo "======================================================================"
        echo "1. SERVICES & PROCESSES STOPPED:"
        if [[ ${#REMOVED_SERVICES[@]} -gt 0 ]]; then
            for s in "${REMOVED_SERVICES[@]}"; do echo "  - $s"; done
        else
            echo "  - None"
        fi
        if [[ ${#REMOVED_PROCESSES[@]} -gt 0 ]]; then
            for p in "${REMOVED_PROCESSES[@]}"; do echo "  - $p"; done
        else
            echo "  - None"
        fi
        echo ""
        echo "2. DOCKER RESOURCES REMOVED:"
        echo "  - Containers: ${REMOVED_CONTAINERS[*]:-None}"
        echo "  - Images    : ${REMOVED_IMAGES[*]:-None}"
        echo "  - Networks  : ${REMOVED_NETWORKS[*]:-None}"
        echo "  - Volumes   : ${REMOVED_VOLUMES[*]:-None}"
        echo ""
        echo "3. SCHEDULED TASKS & FIREWALL:"
        echo "  - Cron Tasks: ${REMOVED_CRON_JOBS[*]:-None}"
        echo "  - Firewall  : ${REMOVED_FIREWALL_RULES[*]:-None}"
        echo ""
        echo "4. FILES & DATA AUDIT:"
        if [[ "$PURGE_MODE" == true ]]; then
            echo "  - Database Directory : PURGED ($DATA_DIR)"
            echo "  - Storage Directory  : PURGED ($STORAGE_DIR)"
            echo "  - Backups Directory  : PURGED ($BACKUP_DIR)"
            echo "  - Config & Env Files : PURGED"
        else
            echo "  - Database Directory : PRESERVED ($DATA_DIR)"
            echo "  - Storage Directory  : PRESERVED ($STORAGE_DIR)"
            echo "  - Backups Directory  : PRESERVED ($BACKUP_DIR)"
            echo "  - Config & Env Files : PRESERVED ($CONFIG_DIR, .env)"
        fi
        echo ""
        echo "5. STRICTLY PROTECTED FOREIGN SERVICES:"
        if [[ ${#PROTECTED_SERVICES[@]} -gt 0 ]]; then
            for ps in "${PROTECTED_SERVICES[@]}"; do echo "  - $ps"; done
        else
            echo "  - Standard system services verified."
        fi
        echo ""
        echo "6. ERRORS ENCOUNTERED:"
        if [[ ${#ERRORS_ENCOUNTERED[@]} -gt 0 ]]; then
            for err in "${ERRORS_ENCOUNTERED[@]}"; do echo "  - $err"; done
        else
            echo "  - Zero errors encountered."
        fi
        echo "======================================================================"
        echo "              END OF MORNYE UNINSTALLATION REPORT                     "
        echo "======================================================================"
    } > "$rep_dest" 2>/dev/null || true

    echo -e "\n${BOLD}======================================================================${NC}"
    echo -e "${GREEN}${BOLD}             MORNYE UNINSTALLATION COMPLETED                          ${NC}"
    echo -e "${BOLD}======================================================================${NC}"
    echo -e "Saved Removal Report : ${CYAN}${rep_dest}${NC}"
    if [[ -n "$BACKUP_CREATED_PATH" ]]; then
        echo -e "Safety Backup Archive: ${GREEN}${BACKUP_CREATED_PATH}${NC}"
    fi
    if [[ "$PURGE_MODE" != true ]]; then
        echo -e "\nUser Data Preserved At:"
        echo -e "  - Database : $DATA_DIR"
        echo -e "  - Storage  : $STORAGE_DIR"
        echo -e "  - Backups  : $BACKUP_DIR"
    fi
    echo -e "${BOLD}======================================================================${NC}"
}

# ------------------------------------------------------------------------------
# 10. MAIN ENTRY POINT
# ------------------------------------------------------------------------------

main() {
    load_env
    detect_environment
    discover_protected_services
    discover_mornye_services
    discover_mornye_processes
    discover_mornye_docker
    discover_scheduled_tasks
    discover_firewall_rules
    discover_filesystem_inventory

    display_plan
    operator_gate

    # Removal sequence
    stop_mornye_processes
    remove_mornye_services
    remove_mornye_docker
    remove_scheduled_tasks
    remove_firewall_rules
    handle_cloudflare
    remove_files
    run_final_verification
    generate_report
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
