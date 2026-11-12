#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — UNIFIED INFRASTRUCTURE & MANAGEMENT CLI
# Version: 3.1.0
# Description: Authoritative management console for containerized WebDAV storage,
#              Cloudflare Zero-Trust ingress, Quick Tunnels, Docker, and backups.
# ==============================================================================

set -eo pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROGRAM_DIR"

CLI_DIR="$PROGRAM_DIR/cli"
DATA_DIR="$PROGRAM_DIR/database"
STORAGE_DIR="$PROGRAM_DIR/storage"
LOG_DIR="$PROGRAM_DIR/logs"
BACKUP_DIR="$PROGRAM_DIR/backups"
RUN_DIR="$PROGRAM_DIR/run"
CONFIG_DIR="$PROGRAM_DIR/config"
SCRIPTS_DIR="$PROGRAM_DIR/scripts"

mkdir -p "$LOG_DIR" "$RUN_DIR" "$DATA_DIR" "$STORAGE_DIR" "$BACKUP_DIR" "$CONFIG_DIR"

# Python execution resolution (Host fallback only; container is primary)
PYTHON_BIN="python3"
if [[ -f "$PROGRAM_DIR/venv/bin/python3" ]]; then
    PYTHON_BIN="$PROGRAM_DIR/venv/bin/python3"
fi

# Visual Styling & ANSI Palette
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
==========================================================
 __  __  ____  _____  _   ___     ______
|  \/  |/ __ \|  _  \| \ | \ \   / /  __|
| \  / | |  | | |_| ||  \| |\ \_/ /| |__ 
| |\/| | |  | |    _/| . ` | \   / |  __| 
| |  | | |__| | |\ \ | |\  |  | |  | |___ 
|_|  |_|\____/|_| \_\|_| \_|  |_|  |_____|
Network Storage & RFC 4918 WebDAV Infrastructure v3.1
==========================================================
EOF
    echo -e "${NC}"
}

has_cmd() {
    command -v "$1" &>/dev/null
}

# Execute Python CLI operators inside Docker container (or run fallback)
run_cli_op() {
    local script_name="$1"
    shift
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-webdav"; then
        docker compose exec -T webdav python3 "/app/cli/$script_name" "$@"
    elif has_cmd docker && docker image inspect mornye-webdav:latest &>/dev/null; then
        docker compose run --rm -T --no-deps webdav python3 "/app/cli/$script_name" "$@"
    elif [[ -x "$PYTHON_BIN" && -f "$CLI_DIR/$script_name" ]]; then
        PYTHONPATH="$PROGRAM_DIR" "$PYTHON_BIN" "$CLI_DIR/$script_name" "$@"
    else
        echo -e "${RED}[ERROR] Mornye WebDAV container is not running and no local runtime available.${NC}"
        echo -e "Launch the container stack first with: ./mornye.sh start"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 1. GENERAL INFORMATION & DIAGNOSTICS
# ------------------------------------------------------------------------------

cmd_help() {
    print_banner
    echo -e "${BOLD}USAGE:${NC} ./mornye.sh [command] [subcommand] [options]"
    echo ""
    echo -e "${BOLD}LIFECYCLE MANAGEMENT:${NC}"
    echo -e "  ${CYAN}install${NC}                     Automated multi-distribution installer & setup wizard"
    echo -e "  ${CYAN}start${NC}                       Start containerized Mornye WebDAV stack and tunnel"
    echo -e "  ${CYAN}stop${NC}                        Gracefully stop Mornye services and containers"
    echo -e "  ${CYAN}restart${NC}                     Gracefully restart container stack"
    echo -e "  ${CYAN}update${NC}                      Backup database, pull changes, rebuild container & restart"
    echo -e "  ${CYAN}uninstall${NC}                   Remove containers and configs (preserves database/storage)"
    echo ""
    echo -e "${BOLD}OBSERVABILITY & DIAGNOSTICS:${NC}"
    echo -e "  ${CYAN}status${NC}                      Show unified status of containers, endpoints, tunnel & disk"
    echo -e "  ${CYAN}doctor${NC}                      Comprehensive diagnostic probe (distro, docker, network, DB)"
    echo -e "  ${CYAN}dashboard${NC}                   Interactive real-time terminal monitoring dashboard"
    echo -e "  ${CYAN}version${NC}                     Display release version, commit hash, and container state"
    echo -e "  ${CYAN}help${NC}                        Show this comprehensive command manual"
    echo ""
    echo -e "${BOLD}DOCKER CONTAINER OPERATIONS:${NC}"
    echo -e "  ${CYAN}docker status${NC}               Inspect Docker daemon version and system resources"
    echo -e "  ${CYAN}docker ps${NC}                   List active Mornye container instances"
    echo -e "  ${CYAN}docker up${NC}                   Launch containerized stack in background"
    echo -e "  ${CYAN}docker down${NC}                 Stop and remove containerized stack"
    echo -e "  ${CYAN}docker rebuild${NC}              Rebuild production multi-stage Docker image"
    echo -e "  ${CYAN}docker logs${NC}                 Tail real-time logs from container services"
    echo -e "  ${CYAN}docker health${NC}               Run Docker container health probe"
    echo ""
    echo -e "${BOLD}WEBDAV STORAGE ENGINE:${NC}"
    echo -e "  ${CYAN}webdav status${NC}               Inspect WebDAV port 8000 state and protocol configuration"
    echo -e "  ${CYAN}webdav test${NC}                 Execute live PROPFIND probe verifying auth boundary"
    echo -e "  ${CYAN}webdav logs [-f] [N]${NC}        View recent WebDAV access logs (default: 50 lines)"
    echo ""
    echo -e "${BOLD}CLOUDFLARE ZERO-TRUST TUNNEL (WAN INGRESS):${NC}"
    echo -e "  ${CYAN}tunnel setup${NC}                Interactive guided wizard for permanent tunnel & custom domain"
    echo -e "  ${CYAN}tunnel login${NC}                Authenticate host with Cloudflare via browser login"
    echo -e "  ${CYAN}tunnel create [name]${NC}        Create named tunnel (default: mornye-storage)"
    echo -e "  ${CYAN}tunnel domain add <dom>${NC}     Bind custom domain & configure DNS CNAME routing"
    echo -e "  ${CYAN}tunnel domain remove${NC}        Safely disconnect custom domain routing"
    echo -e "  ${CYAN}tunnel start${NC}                Start permanent Cloudflare Tunnel daemon"
    echo -e "  ${CYAN}tunnel stop${NC}                 Stop permanent Cloudflare Tunnel daemon"
    echo -e "  ${CYAN}tunnel restart${NC}              Restart permanent Cloudflare Tunnel daemon"
    echo -e "  ${CYAN}tunnel status${NC}               Display HA edge connections, latency and domain routing"
    echo -e "  ${CYAN}tunnel logs [-f] [N]${NC}        Inspect permanent tunnel journal/process logs"
    echo -e "  ${CYAN}tunnel test${NC}                 Perform live WAN handshake probe to Cloudflare Edge"
    echo ""
    echo -e "${BOLD}CLOUDFLARE QUICK TUNNEL (EPHEMERAL TESTING):${NC}"
    echo -e "  ${CYAN}tunnel quick start [-y]${NC}     Launch temporary trycloudflare.com testing tunnel"
    echo -e "  ${CYAN}tunnel quick status${NC}         Display temporary Quick Tunnel URL and process status"
    echo -e "  ${CYAN}tunnel quick stop${NC}           Terminate active Quick Tunnel test session"
    echo -e "  ${CYAN}tunnel quick logs [-f] [N]${NC}  Inspect temporary Quick Tunnel connection logs"
    echo ""
    echo -e "${BOLD}MUSIC CATALOG & STORAGE:${NC}"
    echo -e "  ${CYAN}music list${NC}                  List all indexed audio files and owner mappings"
    echo -e "  ${CYAN}music stats${NC}                 Calculate canonical storage metrics and quota usage"
    echo -e "  ${CYAN}music verify${NC}                Audit physical disk files against SQLite SHA-256 hashes"
    echo ""
    echo -e "${BOLD}USERS & STORAGE QUOTA:${NC}"
    echo -e "  ${CYAN}users list${NC}                  Display user accounts safely (no passwords/hashes)"
    echo -e "  ${CYAN}quota status${NC}                Display global and per-user 100 GB quota allocations"
    echo -e "  ${CYAN}quota recalculate${NC}           Recalculate storage metrics and commit snapshot"
    echo ""
    echo -e "${BOLD}DATABASE BACKUP & RECOVERY:${NC}"
    echo -e "  ${CYAN}backup create${NC}               Execute hot online SQLite backup with integrity check"
    echo -e "  ${CYAN}backup list${NC}                 List available recovery backups with size and dates"
    echo -e "  ${CYAN}backup verify <file>${NC}        Verify SQLite header, pages, and PRAGMA integrity"
    echo -e "  ${CYAN}backup restore <file>${NC}       Safely restore database (creates pre-restore safety copy)"
    echo ""
    echo -e "${BOLD}SYSTEM TELEMETRY & LOGS:${NC}"
    echo -e "  ${CYAN}monitor [all|cpu|mem|disk|net]${NC} Real-time Linux kernel telemetry"
    echo -e "  ${CYAN}logs [all|webdav|tunnel] [-f] [N]${NC} Unified log viewer"
    echo ""
}

cmd_version() {
    local git_rev="release"
    if has_cmd git && [[ -d "$PROGRAM_DIR/.git" ]]; then
        git_rev=$(git rev-parse --short HEAD 2>/dev/null || echo "release")
    fi
    echo -e "${BOLD}Mornye Network Storage Platform${NC}"
    echo -e "Version     : 3.1.0 (${CYAN}${git_rev}${NC})"
    echo -e "Architecture: $(uname -m), Kernel: $(uname -r)"
    echo -e "Runtime     : Docker-Only (Host-Independent, Zero Host Python)"
    if has_cmd docker; then
        echo -e "Docker      : $(docker --version 2>/dev/null || echo 'Not installed')"
        echo -e "Compose     : $(docker compose version 2>/dev/null || echo 'Compose plugin not found')"
    fi
}

cmd_doctor() {
    echo -e "${BOLD}==============================================================${NC}"
    echo -e "${BOLD}          MORNYE INFRASTRUCTURE DIAGNOSTIC DOCTOR             ${NC}"
    echo -e "${BOLD}==============================================================${NC}"
    
    # 1. Host OS & Distro Detection
    if [[ -f /etc/os-release ]]; then
        local os_name
        os_name=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
        echo -e "Host OS             : ${GREEN}[✔] $os_name${NC}"
    else
        echo -e "Host OS             : ${YELLOW}[!] Unknown Linux distribution${NC}"
    fi
    echo -e "Kernel Release      : $(uname -r) ($(uname -m))"
    echo -e "Operator Context    : $(whoami) (UID: $(id -u), GID: $(id -g))"

    # 2. Package Manager
    local detected_pm="none"
    for pm in apt pacman dnf yum zypper apk; do
        if has_cmd "$pm"; then
            detected_pm="$pm"
            break
        fi
    done
    echo -e "Package Manager     : ${GREEN}[✔] $detected_pm${NC}"

    # 3. Docker Engine & Compose
    if has_cmd docker; then
        if docker info &>/dev/null; then
            echo -e "Docker Engine       : ${GREEN}[✔] Running ($(docker --version))${NC}"
        else
            echo -e "Docker Engine       : ${YELLOW}[!] Installed but daemon is not responding${NC}"
        fi
    else
        echo -e "Docker Engine       : ${RED}[✘] Missing (Run './mornye.sh install')${NC}"
    fi

    if docker compose version &>/dev/null; then
        echo -e "Docker Compose V2   : ${GREEN}[✔] $(docker compose version)${NC}"
    else
        echo -e "Docker Compose V2   : ${YELLOW}[!] Compose plugin missing${NC}"
    fi

    # 4. Cloudflare CLI
    if has_cmd cloudflared; then
        echo -e "Cloudflare Binary   : ${GREEN}[✔] $(cloudflared --version 2>/dev/null | head -n1)${NC}"
    elif [[ -x /usr/local/bin/cloudflared ]]; then
        echo -e "Cloudflare Binary   : ${GREEN}[✔] $(/usr/local/bin/cloudflared --version 2>/dev/null | head -n1)${NC}"
    else
        echo -e "Cloudflare Binary   : ${YELLOW}[!] cloudflared not installed on host${NC}"
    fi

    # 5. Cloudflare Auth Certificate
    if [[ -f "$HOME/.cloudflared/cert.pem" ]]; then
        echo -e "Cloudflare Auth     : ${GREEN}[✔] Certificate present ($HOME/.cloudflared/cert.pem)${NC}"
    else
        echo -e "Cloudflare Auth     : ${YELLOW}[!] No cert.pem found (Login via './mornye.sh tunnel login')${NC}"
    fi

    # 6. Persistent Directories & Permissions
    echo "--------------------------------------------------------------"
    echo -e "${BOLD}Storage Paths & Permissions Audit:${NC}"
    for dir in "$DATA_DIR" "$STORAGE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$CONFIG_DIR"; do
        if [[ -d "$dir" ]]; then
            local perms
            perms=$(stat -c "%a" "$dir" 2>/dev/null || stat -f "%OLp" "$dir" 2>/dev/null || echo "???")
            echo -e "  $(basename "$dir") Path : ${GREEN}[✔] Accessible (${dir}, mode: $perms)${NC}"
        else
            echo -e "  $(basename "$dir") Path : ${YELLOW}[!] Missing (${dir})${NC}"
        fi
    done

    # 7. Database Integrity
    echo "--------------------------------------------------------------"
    echo -e "${BOLD}Database Integrity Audit:${NC}"
    if [[ -f "$DATA_DIR/mornye.db" ]]; then
        local chk
        chk=$(run_cli_op "backup_ops.py" verify "$DATA_DIR/mornye.db" 2>/dev/null | grep -E "PRAGMA Integrity" || echo "")
        if [[ -n "$chk" ]]; then
            echo -e "  Database File     : ${GREEN}[✔] $chk${NC}"
        else
            echo -e "  Database File     : ${GREEN}[✔] File present ($DATA_DIR/mornye.db)${NC}"
        fi
    else
        echo -e "  Database File     : ${YELLOW}[!] Database not yet created ($DATA_DIR/mornye.db)${NC}"
    fi

    # 8. WebDAV Endpoint Health
    echo "--------------------------------------------------------------"
    echo -e "${BOLD}Local Network Reachability:${NC}"
    local webdav_code
    webdav_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://127.0.0.1:8000/health" 2>/dev/null || echo "000")
    if [[ "$webdav_code" == "200" ]]; then
        echo -e "  WebDAV Loopback   : ${GREEN}[✔] Healthy (HTTP 200 on 127.0.0.1:8000/health)${NC}"
    else
        echo -e "  WebDAV Loopback   : ${YELLOW}[!] Offline or unreachable (HTTP $webdav_code)${NC}"
    fi

    # 9. Cloudflare Edge WAN reachability
    local cf_edge
    cf_edge=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "https://1.1.1.1" 2>/dev/null || echo "000")
    if [[ "$cf_edge" =~ ^[23] ]]; then
        echo -e "  WAN Edge Reach    : ${GREEN}[✔] Internet & Cloudflare Edge reachability OK${NC}"
    else
        echo -e "  WAN Edge Reach    : ${YELLOW}[!] WAN connectivity probe returned HTTP $cf_edge${NC}"
    fi

    echo "=============================================================="
    echo -e "${GREEN}[✔] Diagnostics complete.${NC}"
}

cmd_status() {
    print_banner
    echo -e "${BOLD}INFRASTRUCTURE STATUS OVERVIEW:${NC}"
    echo "----------------------------------------------------------"
    
    # 1. Docker Containers
    if has_cmd docker; then
        local webdav_status="STOPPED"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-webdav"; then
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' mornye-webdav 2>/dev/null || echo "running")
            webdav_status="${GREEN}RUNNING (${health})${NC}"
        fi
        echo -e "Mornye WebDAV Container : $webdav_status"

        local tunnel_container_status="STOPPED"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-tunnel"; then
            tunnel_container_status="${GREEN}RUNNING${NC}"
        fi
        echo -e "Mornye Tunnel Container : $tunnel_container_status"
    fi

    # 2. Systemd Tunnel Status (if applicable)
    if systemctl is-active --quiet mornye-tunnel.service 2>/dev/null; then
        echo -e "Systemd Tunnel Service  : ${GREEN}ACTIVE (mornye-tunnel.service)${NC}"
    fi

    # 3. Permanent Tunnel Info
    if [[ -f "$CONFIG_DIR/tunnel_info.env" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_DIR/tunnel_info.env"
        echo ""
        echo -e "${BOLD}Permanent Tunnel Configuration:${NC}"
        echo -e "  Tunnel Name   : ${CYAN}${TUNNEL_NAME:-mornye-storage}${NC}"
        echo -e "  Tunnel UUID   : ${CYAN}${TUNNEL_ID:-None}${NC}"
        echo -e "  Custom Domain : ${CYAN}${CUSTOM_DOMAIN:-None configured}${NC}"
        echo -e "  Runtime Mode  : ${TUNNEL_MODE:-docker}"
    fi

    # 4. Quick Tunnel Status
    if [[ -f "$RUN_DIR/quick_tunnel.pid" ]] && kill -0 "$(cat "$RUN_DIR/quick_tunnel.pid" 2>/dev/null)" 2>/dev/null; then
        local q_url
        q_url=$(cat "$RUN_DIR/quick_tunnel.url" 2>/dev/null || echo "Establishing...")
        echo ""
        echo -e "Cloudflare Quick Tunnel : ${PURPLE}ACTIVE (Test Mode)${NC}"
        echo -e "  Temporary URL         : ${CYAN}${q_url}${NC}"
    fi

    # 5. Active Port Bindings
    echo ""
    echo -e "${BOLD}Active Port Listeners:${NC}"
    if has_cmd ss; then
        ss -tulpn | grep -E '8000|20241|20242' || echo "  No Mornye listeners detected on host ports."
    elif has_cmd netstat; then
        netstat -tulpn | grep -E '8000|20241|20242' || echo "  No Mornye listeners detected on host ports."
    fi

    # 6. WebDAV Probe
    echo ""
    local webdav_code
    webdav_code=$(curl -s -o /dev/null -w "%{http_code}" -X PROPFIND -H "Depth: 0" "http://127.0.0.1:8000/dav/" 2>/dev/null || echo "000")
    if [[ "$webdav_code" =~ ^(207|401)$ ]]; then
        echo -e "WebDAV Endpoint Health  : ${GREEN}ONLINE (HTTP $webdav_code Auth Protected)${NC}"
    elif [[ "$webdav_code" == "000" ]]; then
        echo -e "WebDAV Endpoint Health  : ${RED}OFFLINE${NC}"
    else
        echo -e "WebDAV Endpoint Health  : ${YELLOW}HTTP $webdav_code${NC}"
    fi

    # 7. Storage & Quota Stats
    if [[ -f "$DATA_DIR/mornye.db" ]]; then
        echo ""
        cmd_music stats 2>/dev/null || true
    fi
}

cmd_dashboard() {
    while true; do
        clear
        cmd_status
        echo ""
        echo -e "${CYAN}Press [Ctrl+C] to exit real-time monitoring dashboard...${NC}"
        sleep 3
    done
}

# ------------------------------------------------------------------------------
# 2. LIFECYCLE MANAGEMENT (DOCKER-FIRST)
# ------------------------------------------------------------------------------

cmd_start() {
    echo -e "${BOLD}[*] Starting Mornye Services...${NC}"
    if ! has_cmd docker; then
        echo -e "${RED}[ERROR] Docker is not installed on this host.${NC}"
        echo -e "Run './mornye.sh install' to install Docker and dependencies automatically."
        exit 1
    fi

    # Check for docker tunnel profile
    local compose_args=()
    if [[ -f "$CONFIG_DIR/tunnel_info.env" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_DIR/tunnel_info.env"
        if [[ "${TUNNEL_MODE:-}" == "docker" && -f "$CONFIG_DIR/cloudflared.yml" && -f "$CONFIG_DIR/credentials.json" ]]; then
            echo -e "[*] Cloudflare Tunnel configured in Docker mode; activating profile 'tunnel'..."
            compose_args+=(--profile tunnel)
        fi
    fi

    echo -e "[*] Launching container stack via Docker Compose..."
    docker compose "${compose_args[@]}" up -d

    echo -e "[*] Awaiting WebDAV container readiness..."
    local healthy=false
    for i in {1..20}; do
        sleep 1
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' mornye-webdav 2>/dev/null || echo "starting")
        if [[ "$status" == "healthy" ]]; then
            healthy=true
            break
        fi
    done

    if [[ "$healthy" == true ]]; then
        echo -e "${GREEN}[✔] Mornye WebDAV Engine is ONLINE and HEALTHY (http://127.0.0.1:8000/dav/).${NC}"
    else
        echo -e "${YELLOW}[!] Mornye WebDAV container started (status: ${status:-unknown}).${NC}"
    fi

    # If tunnel mode is systemd, start systemd service
    if [[ -f "$CONFIG_DIR/tunnel_info.env" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_DIR/tunnel_info.env"
        if [[ "${TUNNEL_MODE:-}" == "systemd" ]]; then
            if systemctl list-unit-files mornye-tunnel.service &>/dev/null; then
                sudo systemctl start mornye-tunnel.service 2>/dev/null || true
                echo -e "${GREEN}[✔] Cloudflare Tunnel (systemd) started.${NC}"
            fi
        fi
    fi
}

cmd_stop() {
    echo -e "${BOLD}[*] Stopping Mornye Services...${NC}"
    # Stop Quick Tunnel if running
    if [[ -f "$SCRIPTS_DIR/cloudflare_manager.sh" ]]; then
        "$SCRIPTS_DIR/cloudflare_manager.sh" quick stop &>/dev/null || true
    fi

    # Stop systemd tunnel if active
    if systemctl is-active --quiet mornye-tunnel.service 2>/dev/null; then
        sudo systemctl stop mornye-tunnel.service 2>/dev/null || true
    fi

    # Stop Docker stack
    if has_cmd docker; then
        docker compose --profile tunnel down 2>/dev/null || docker compose down 2>/dev/null || true
    fi
    echo -e "${GREEN}[✔] Mornye services stopped cleanly.${NC}"
}

cmd_restart() {
    echo -e "${BOLD}[*] Restarting Mornye Services...${NC}"
    cmd_stop
    sleep 1
    cmd_start
    echo -e "${GREEN}[✔] Mornye services restarted successfully.${NC}"
}

cmd_update() {
    echo -e "${BOLD}==============================================================${NC}"
    echo -e "${BOLD}               MORNYE SAFE UPDATE PROCEDURE                   ${NC}"
    echo -e "${BOLD}==============================================================${NC}"

    # Stage 1: Safety Database Backup
    echo -e "${BOLD}[Stage 1/5] Creating pre-update safety backup...${NC}"
    cmd_backup create || {
        echo -e "${YELLOW}[!] Warning: Pre-update backup encountered an issue. Proceeding with caution.${NC}"
    }

    # Stage 2: Git Pull (if in a Git repository)
    echo -e "${BOLD}[Stage 2/5] Checking for latest release updates...${NC}"
    if has_cmd git && [[ -d "$PROGRAM_DIR/.git" ]]; then
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
        echo -e "[*] Pulling latest changes from branch '${current_branch}'..."
        git pull origin "$current_branch" || echo -e "${YELLOW}[!] Git pull failed; proceeding with existing local files.${NC}"
    else
        echo -e "[*] Not a Git clone or Git unavailable; skipping source pull."
    fi

    # Stage 3: Docker Rebuild
    echo -e "${BOLD}[Stage 3/5] Rebuilding production container image...${NC}"
    if has_cmd docker; then
        docker compose build --no-cache
    else
        echo -e "${RED}[ERROR] Docker is not installed. Cannot rebuild image.${NC}"
        exit 1
    fi

    # Stage 4: Restart Containers
    echo -e "${BOLD}[Stage 4/5] Relaunching containerized stack...${NC}"
    cmd_restart

    # Stage 5: Schema & Health Check
    echo -e "${BOLD}[Stage 5/5] Auditing schema and health status...${NC}"
    sleep 2
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://127.0.0.1:8000/health" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
        echo -e "${GREEN}[✔] Update completed successfully! Mornye WebDAV is healthy.${NC}"
    else
        echo -e "${YELLOW}[!] Update finished, but health endpoint returned HTTP $code.${NC}"
    fi
}

cmd_uninstall() {
    echo -e "${RED}${BOLD}==============================================================${NC}"
    echo -e "${RED}${BOLD}               MORNYE UNINSTALLATION WIZARD                   ${NC}"
    echo -e "${RED}${BOLD}==============================================================${NC}"
    echo -e "${YELLOW}This procedure will remove Mornye container instances and runtime state.${NC}"
    echo -e "${GREEN}${BOLD}YOUR MUSIC STORAGE, DATABASE, AND BACKUPS WILL BE PRESERVED.${NC}"
    echo ""
    read -p "Are you sure you want to uninstall Mornye services? [y/N]: " -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "[*] Uninstallation cancelled by operator."
        exit 0
    fi

    echo -e "[*] Stopping running services and containers..."
    cmd_stop

    if has_cmd docker; then
        echo -e "[*] Removing Docker Compose stack and networks..."
        docker compose --profile tunnel down -v --remove-orphans 2>/dev/null || true

        read -p "Remove Mornye Docker images from local storage? [y/N]: " -r rm_img
        if [[ "$rm_img" =~ ^[Yy]$ ]]; then
            docker rmi -f mornye-webdav:latest 2>/dev/null || true
            echo -e "${GREEN}[✔] Docker image mornye-webdav:latest removed.${NC}"
        fi
    fi

    # Remove temporary run files
    rm -rf "$RUN_DIR"/* 2>/dev/null || true
    echo -e "${GREEN}==============================================================${NC}"
    echo -e "${GREEN}[✔] Mornye services successfully uninstalled.${NC}"
    echo -e "User data preserved at:"
    echo -e "  - Storage Directory : $STORAGE_DIR"
    echo -e "  - Database Directory: $DATA_DIR"
    echo -e "  - Backups Directory : $BACKUP_DIR"
    echo -e "${GREEN}==============================================================${NC}"
}

# ------------------------------------------------------------------------------
# 3. DOCKER MANAGEMENT COMMANDS
# ------------------------------------------------------------------------------

cmd_docker() {
    local sub="${1:-status}"
    shift || true

    case "$sub" in
        status)
            if has_cmd docker; then
                docker info 2>/dev/null | grep -E 'Server Version|Operating System|CPUs|Total Memory'
            else
                echo -e "${RED}[ERROR] Docker is not installed on this host.${NC}"
                exit 1
            fi
            ;;
        ps)
            docker compose ps
            ;;
        up)
            echo -e "[*] Launching containerized stack..."
            docker compose up -d
            ;;
        down)
            echo -e "[*] Stopping containerized stack..."
            docker compose down
            ;;
        rebuild)
            echo -e "[*] Rebuilding Mornye Docker image..."
            docker compose build --no-cache
            ;;
        logs)
            docker compose logs -f "$@"
            ;;
        health)
            if docker ps --format '{{.Names}}' | grep -q 'mornye-webdav'; then
                docker inspect --format='{{json .State.Health}}' mornye-webdav 2>/dev/null || echo "Healthcheck not active"
            else
                echo "Container mornye-webdav is not running."
            fi
            ;;
        *)
            echo "Usage: ./mornye.sh docker [status|ps|up|down|rebuild|logs|health]"
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 4. WEBDAV OPERATIONS
# ------------------------------------------------------------------------------

cmd_webdav() {
    local sub="${1:-status}"
    shift || true

    case "$sub" in
        status)
            run_cli_op "webdav_ops.py" status
            ;;
        test)
            run_cli_op "webdav_ops.py" test
            ;;
        logs)
            local follow=""
            local lines="50"
            for arg in "$@"; do
                if [[ "$arg" == "-f" || "$arg" == "--follow" ]]; then
                    follow="-f"
                elif [[ "$arg" =~ ^[0-9]+$ ]]; then
                    lines="$arg"
                fi
            done
            if has_cmd docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-webdav"; then
                docker compose logs $follow --tail="$lines" webdav
            elif [[ -f "$LOG_DIR/webdav_access.log" ]]; then
                tail -n "$lines" $follow "$LOG_DIR/webdav_access.log"
            elif [[ -f "$LOG_DIR/server.log" ]]; then
                tail -n "$lines" $follow "$LOG_DIR/server.log"
            else
                echo -e "${YELLOW}[!] No WebDAV logs found.${NC}"
            fi
            ;;
        *)
            echo "Usage: ./mornye.sh webdav [status|test|logs]"
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 5. CLOUDFLARE TUNNEL (DELEGATED TO scripts/cloudflare_manager.sh)
# ------------------------------------------------------------------------------

cmd_tunnel() {
    if [[ -f "$SCRIPTS_DIR/cloudflare_manager.sh" ]]; then
        exec "$SCRIPTS_DIR/cloudflare_manager.sh" "$@"
    else
        echo -e "${RED}[ERROR] scripts/cloudflare_manager.sh not found.${NC}"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 6. MUSIC CATALOG COMMANDS
# ------------------------------------------------------------------------------

cmd_music() {
    local sub="${1:-stats}"
    shift || true

    case "$sub" in
        list)
            run_cli_op "music_ops.py" list "$@"
            ;;
        stats)
            run_cli_op "music_ops.py" stats "$@"
            ;;
        verify)
            run_cli_op "music_ops.py" verify "$@"
            ;;
        *)
            echo "Usage: ./mornye.sh music [list|stats|verify]"
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 7. USERS & QUOTA COMMANDS
# ------------------------------------------------------------------------------

cmd_users() {
    local sub="${1:-list}"
    shift || true

    case "$sub" in
        list)
            run_cli_op "user_ops.py" list "$@"
            ;;
        *)
            echo "Usage: ./mornye.sh users list"
            exit 1
            ;;
    esac
}

cmd_quota() {
    local sub="${1:-status}"
    shift || true

    case "$sub" in
        status)
            run_cli_op "user_ops.py" status "$@"
            ;;
        recalculate)
            run_cli_op "user_ops.py" recalculate "$@"
            ;;
        *)
            echo "Usage: ./mornye.sh quota [status|recalculate]"
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 8. BACKUP & RECOVERY COMMANDS
# ------------------------------------------------------------------------------

cmd_backup() {
    local sub="${1:-list}"
    shift || true

    case "$sub" in
        create)
            run_cli_op "backup_ops.py" create "$@"
            ;;
        list)
            run_cli_op "backup_ops.py" list "$@"
            ;;
        verify)
            run_cli_op "backup_ops.py" verify "$@"
            ;;
        restore)
            run_cli_op "backup_ops.py" restore "$@"
            ;;
        *)
            echo "Usage: ./mornye.sh backup [create|list|verify|restore]"
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 9. SYSTEM MONITORING COMMANDS
# ------------------------------------------------------------------------------

cmd_monitor() {
    local sub="${1:-all}"
    shift || true
    run_cli_op "system_ops.py" "$sub" "$@"
}

# ------------------------------------------------------------------------------
# 10. UNIFIED LOGS VIEWER
# ------------------------------------------------------------------------------

cmd_logs() {
    local target="all"
    local follow=""
    local lines="50"

    for arg in "$@"; do
        if [[ "$arg" == "webdav" || "$arg" == "tunnel" || "$arg" == "backend" || "$arg" == "all" ]]; then
            target="$arg"
        elif [[ "$arg" == "-f" || "$arg" == "--follow" ]]; then
            follow="-f"
        elif [[ "$arg" =~ ^[0-9]+$ ]]; then
            lines="$arg"
        fi
    done

    case "$target" in
        webdav)
            if has_cmd docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-webdav"; then
                docker compose logs $follow --tail="$lines" webdav
            elif [[ -f "$LOG_DIR/webdav_access.log" ]]; then
                tail -n "$lines" $follow "$LOG_DIR/webdav_access.log"
            elif [[ -f "$LOG_DIR/server.log" ]]; then
                tail -n "$lines" $follow "$LOG_DIR/server.log"
            else
                echo -e "${YELLOW}[!] No WebDAV logs found.${NC}"
            fi
            ;;
        tunnel)
            if has_cmd docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-tunnel"; then
                docker compose logs $follow --tail="$lines" tunnel
            elif [[ -f "$SCRIPTS_DIR/cloudflare_manager.sh" ]]; then
                "$SCRIPTS_DIR/cloudflare_manager.sh" logs $follow "$lines"
            else
                journalctl --no-pager -u mornye-tunnel.service -n "$lines" $follow 2>/dev/null || true
            fi
            ;;
        *)
            if has_cmd docker && docker compose ps --services 2>/dev/null | grep -qw "webdav"; then
                docker compose logs $follow --tail="$lines"
            elif [[ -f "$LOG_DIR/server.log" ]]; then
                tail -n "$lines" $follow "$LOG_DIR/server.log"
            else
                echo -e "${YELLOW}[!] No active logs found.${NC}"
            fi
            ;;
    esac
}

# ------------------------------------------------------------------------------
# MAIN ROUTING DISPATCHER
# ------------------------------------------------------------------------------

main() {
    if [[ $# -eq 0 ]]; then
        cmd_help
        exit 0
    fi

    local category="$1"
    shift

    case "$category" in
        help|--help|-h)
            cmd_help
            ;;
        version|--version|-v)
            cmd_version
            ;;
        doctor)
            cmd_doctor
            ;;
        status)
            cmd_status
            ;;
        dashboard)
            cmd_dashboard
            ;;
        install|setup)
            if [[ -f "$PROGRAM_DIR/setup.sh" ]]; then
                exec "$PROGRAM_DIR/setup.sh" "$@"
            else
                echo -e "${RED}[ERROR] setup.sh not found.${NC}"
                exit 1
            fi
            ;;
        start)
            cmd_start "$@"
            ;;
        stop)
            cmd_stop "$@"
            ;;
        restart)
            cmd_restart "$@"
            ;;
        update)
            cmd_update "$@"
            ;;
        uninstall)
            cmd_uninstall "$@"
            ;;
        docker)
            cmd_docker "$@"
            ;;
        webdav)
            cmd_webdav "$@"
            ;;
        tunnel)
            cmd_tunnel "$@"
            ;;
        music)
            cmd_music "$@"
            ;;
        users)
            cmd_users "$@"
            ;;
        quota)
            cmd_quota "$@"
            ;;
        backup)
            cmd_backup "$@"
            ;;
        restore)
            cmd_backup restore "$@"
            ;;
        logs)
            cmd_logs "$@"
            ;;
        monitor)
            cmd_monitor "$@"
            ;;
        *)
            echo -e "${RED}Unknown command: $category${NC}"
            echo "Run './mornye.sh help' for usage instructions."
            exit 1
            ;;
    esac
}

main "$@"
