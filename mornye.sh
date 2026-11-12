#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — UNIFIED INFRASTRUCTURE & MANAGEMENT CLI
# Version: 3.0.0
# Description: Authoritative management console for WebDAV storage, Cloudflare
#              Zero-Trust ingress, Quick Tunnels, Docker, backups, and telemetry.
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

mkdir -p "$LOG_DIR" "$RUN_DIR" "$DATA_DIR" "$STORAGE_DIR" "$BACKUP_DIR"

# Python execution resolution
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
Network Storage & RFC 4918 WebDAV Infrastructure v3.0
==========================================================
EOF
    echo -e "${NC}"
}

has_cmd() {
    command -v "$1" &>/dev/null
}

run_cli_op() {
    local script_name="$1"
    shift
    if [[ ! -f "$CLI_DIR/$script_name" ]]; then
        echo -e "${RED}[ERROR] CLI operator not found: $CLI_DIR/$script_name${NC}"
        exit 1
    fi
    PYTHONPATH="$PROGRAM_DIR" "$PYTHON_BIN" "$CLI_DIR/$script_name" "$@"
}

# ------------------------------------------------------------------------------
# 1. GENERAL INFORMATION COMMANDS
# ------------------------------------------------------------------------------

cmd_help() {
    print_banner
    echo -e "${BOLD}USAGE:${NC} ./mornye.sh [command] [subcommand] [options]"
    echo ""
    echo -e "${BOLD}AVAILABLE COMMANDS:${NC}"
    echo -e "  ${CYAN}help${NC}                        Show this comprehensive command manual"
    echo -e "  ${CYAN}version${NC}                     Display release version, commit, and runtime engine"
    echo -e "  ${CYAN}doctor${NC}                      Execute diagnostic checks across dependencies and disk"
    echo -e "  ${CYAN}status${NC}                      Show unified infrastructure status overview and ports"
    echo -e "  ${CYAN}dashboard${NC}                   Interactive real-time monitoring dashboard"
    echo ""
    echo -e "${BOLD}LIFECYCLE MANAGEMENT:${NC}"
    echo -e "  ${CYAN}install${NC}                     Automated environment installer for host system"
    echo -e "  ${CYAN}setup${NC}                       Initialize persistent storage, databases, and config"
    echo -e "  ${CYAN}start${NC}                       Start Mornye WebDAV service and ingress"
    echo -e "  ${CYAN}stop${NC}                        Gracefully stop Mornye services"
    echo -e "  ${CYAN}restart${NC}                     Gracefully restart Mornye services"
    echo -e "  ${CYAN}update${NC}                      Pull latest release and migrate schema safely"
    echo -e "  ${CYAN}uninstall${NC}                   Remove application components (preserves user data)"
    echo ""
    echo -e "${BOLD}DOCKER OPERATIONS:${NC}"
    echo -e "  ${CYAN}docker status${NC}               Inspect Docker daemon and container status"
    echo -e "  ${CYAN}docker ps${NC}                   List active Mornye container instances"
    echo -e "  ${CYAN}docker up${NC}                   Launch containerized stack in background"
    echo -e "  ${CYAN}docker down${NC}                 Stop and remove containerized stack"
    echo -e "  ${CYAN}docker rebuild${NC}              Rebuild production multi-stage Docker image"
    echo -e "  ${CYAN}docker logs${NC}                 Tail real-time logs from container services"
    echo -e "  ${CYAN}docker health${NC}               Run continuous Docker container health probe"
    echo ""
    echo -e "${BOLD}WEBDAV STORAGE ENGINE:${NC}"
    echo -e "  ${CYAN}webdav status${NC}               Inspect WebDAV port 8000 state and protocol configuration"
    echo -e "  ${CYAN}webdav test${NC}                 Execute live PROPFIND probe verifying auth boundary"
    echo -e "  ${CYAN}webdav logs [-f] [N]${NC}        View recent WebDAV access logs (default: 50 lines)"
    echo ""
    echo -e "${BOLD}CLOUDFLARE TUNNEL INGRESS:${NC}"
    echo -e "  ${CYAN}tunnel status${NC}               Display HA edge connections and smoothed RTT latency"
    echo -e "  ${CYAN}tunnel test${NC}                 Perform live WAN handshake probe to Cloudflare Edge"
    echo -e "  ${CYAN}tunnel start${NC}                Start permanent Zero-Trust tunnel daemon"
    echo -e "  ${CYAN}tunnel stop${NC}                 Stop permanent Zero-Trust tunnel daemon"
    echo -e "  ${CYAN}tunnel restart${NC}              Restart permanent Zero-Trust tunnel daemon"
    echo -e "  ${CYAN}tunnel logs [-f] [N]${NC}        Inspect permanent tunnel journal/process logs"
    echo ""
    echo -e "${BOLD}CLOUDFLARE QUICK TUNNEL (TEST MODE):${NC}"
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
    echo -e "  ${CYAN}logs [all|webdav|tunnel|backend] [-f] [N]${NC} Unified log viewer"
    echo ""
}

cmd_version() {
    local git_rev="release"
    if has_cmd git && [[ -d "$PROGRAM_DIR/.git" ]]; then
        git_rev=$(git rev-parse --short HEAD 2>/dev/null || echo "release")
    fi
    echo -e "${BOLD}Mornye Network Storage Platform${NC}"
    echo -e "Version     : 3.0.0 (${CYAN}${git_rev}${NC})"
    echo -e "Architecture: $(uname -m), Kernel: $(uname -r)"
    echo -e "Python      : $("$PYTHON_BIN" --version 2>&1 || echo 'Not found')"
    echo -e "Platform    : Linux CLI-First & Containerized Infrastructure"
}

cmd_doctor() {
    echo -e "${BOLD}Running Mornye Infrastructure Diagnostics...${NC}"
    echo "----------------------------------------------------------"
    
    # Check OS
    if [[ -f /etc/os-release ]]; then
        local os_name
        os_name=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
        echo -e "Host OS             : ${GREEN}[✔] $os_name${NC}"
    else
        echo -e "Host OS             : ${YELLOW}[!] Unknown Linux distribution${NC}"
    fi

    echo -e "Kernel Release      : $(uname -r) ($(uname -m))"
    echo -e "User Context        : $(whoami) (UID: $(id -u), GID: $(id -g))"

    # Check Python
    if "$PYTHON_BIN" -c "import sys; exit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null; then
        echo -e "Python 3 Engine     : ${GREEN}[✔] $("$PYTHON_BIN" --version)${NC}"
    else
        echo -e "Python 3 Engine     : ${RED}[✘] Requires Python 3.10+${NC}"
    fi

    # Check Git
    if has_cmd git; then
        echo -e "Git Version Control : ${GREEN}[✔] $(git --version)${NC}"
    else
        echo -e "Git Version Control : ${YELLOW}[!] Git CLI not installed${NC}"
    fi

    # Check Cloudflared
    if has_cmd cloudflared; then
        echo -e "Cloudflare Binary   : ${GREEN}[✔] $(cloudflared --version 2>/dev/null | head -n1)${NC}"
    else
        echo -e "Cloudflare Binary   : ${YELLOW}[!] cloudflared binary not found${NC}"
    fi

    # Check Docker
    if has_cmd docker; then
        echo -e "Docker Engine       : ${GREEN}[✔] $(docker --version)${NC}"
    else
        echo -e "Docker Engine       : ${YELLOW}[!] Not installed on host${NC}"
        echo -e "                      Install command: sudo apt-get install -y docker.io docker-compose"
    fi

    # Check Docker Compose
    if docker compose version &>/dev/null; then
        echo -e "Docker Compose V2   : ${GREEN}[✔] $(docker compose version)${NC}"
    elif has_cmd docker-compose; then
        echo -e "Docker Compose V1   : ${GREEN}[✔] $(docker-compose --version)${NC}"
    else
        echo -e "Docker Compose      : ${YELLOW}[!] Compose plugin not found${NC}"
    fi

    # Check SQLite Database
    if [[ -f "$DATA_DIR/mornye.db" ]]; then
        local chk
        chk=$(sqlite3 "$DATA_DIR/mornye.db" "PRAGMA integrity_check;" 2>/dev/null || echo "error")
        if [[ "$chk" == "ok" ]]; then
            echo -e "SQLite Database     : ${GREEN}[✔] Integrity Healthy ($DATA_DIR/mornye.db)${NC}"
        else
            echo -e "SQLite Database     : ${RED}[✘] Integrity Check Failed ($chk)${NC}"
        fi
    else
        echo -e "SQLite Database     : ${YELLOW}[!] Database file not found ($DATA_DIR/mornye.db)${NC}"
    fi

    # Check Storage directory
    if [[ -d "$STORAGE_DIR" ]]; then
        echo -e "Music Storage Path  : ${GREEN}[✔] Accessible ($STORAGE_DIR)${NC}"
    else
        echo -e "Music Storage Path  : ${YELLOW}[!] Missing ($STORAGE_DIR)${NC}"
    fi

    echo "----------------------------------------------------------"
    echo -e "${GREEN}[✔] Diagnostics complete.${NC}"
}

cmd_status() {
    print_banner
    echo -e "${BOLD}INFRASTRUCTURE STATUS OVERVIEW:${NC}"
    echo "----------------------------------------------------------"
    
    # 1. Systemd / Process Status
    if systemctl is-active --quiet mornye-storage.service 2>/dev/null; then
        echo -e "Mornye Storage Service : ${GREEN}ACTIVE (systemd: mornye-storage.service)${NC}"
    elif pgrep -f "backend.server" &>/dev/null || pgrep -f "app.backend.server" &>/dev/null; then
        echo -e "Mornye Storage Service : ${GREEN}ACTIVE (standalone process)${NC}"
    else
        echo -e "Mornye Storage Service : ${RED}STOPPED${NC}"
    fi

    if systemctl is-active --quiet mornye-tunnel.service 2>/dev/null; then
        echo -e "Cloudflare Tunnel (WAN): ${GREEN}ACTIVE (systemd: mornye-tunnel.service)${NC}"
    else
        echo -e "Cloudflare Tunnel (WAN): ${YELLOW}INACTIVE / STOPPED${NC}"
    fi

    # Quick Tunnel status check
    if [[ -f "$RUN_DIR/quick_tunnel.pid" ]] && kill -0 "$(cat "$RUN_DIR/quick_tunnel.pid" 2>/dev/null)" 2>/dev/null; then
        local q_url
        q_url=$(cat "$RUN_DIR/quick_tunnel.url" 2>/dev/null || echo "Establishing...")
        echo -e "Cloudflare Quick Tunnel: ${PURPLE}ACTIVE (Test Mode)${NC}"
        echo -e "  Temporary URL        : ${CYAN}${q_url}${NC}"
    fi

    echo ""
    echo -e "${BOLD}Active Port Bindings:${NC}"
    if has_cmd ss; then
        ss -tulpn | grep -E '8000|20241|20242' || echo "  No Mornye listeners detected."
    elif has_cmd netstat; then
        netstat -tulpn | grep -E '8000|20241|20242' || echo "  No Mornye listeners detected."
    fi

    echo ""
    # 2. Storage & Quota Stats
    if [[ -f "$DATA_DIR/mornye.db" ]]; then
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
# 2. LIFECYCLE COMMANDS
# ------------------------------------------------------------------------------

cmd_start() {
    echo -e "[*] Starting Mornye Services..."
    if systemctl list-unit-files mornye-storage.service &>/dev/null; then
        sudo systemctl start mornye-storage.service 2>/dev/null || true
    else
        nohup "$PYTHON_BIN" -m backend.server > "$LOG_DIR/server.log" 2>&1 &
        echo $! > "$RUN_DIR/server.pid"
    fi
    echo -e "${GREEN}[✔] Services start signal issued.${NC}"
}

cmd_stop() {
    echo -e "[*] Stopping Mornye Services..."
    if systemctl list-unit-files mornye-storage.service &>/dev/null; then
        sudo systemctl stop mornye-storage.service 2>/dev/null || true
    fi
    if [[ -f "$RUN_DIR/server.pid" ]]; then
        kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
        rm -f "$RUN_DIR/server.pid"
    fi
    cmd_tunnel_quick_stop
    echo -e "${GREEN}[✔] Services stopped.${NC}"
}

cmd_restart() {
    echo -e "[*] Restarting Mornye Services..."
    cmd_stop
    sleep 1
    cmd_start
    echo -e "${GREEN}[✔] Services restarted successfully.${NC}"
}

# ------------------------------------------------------------------------------
# 3. DOCKER COMMANDS
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
# 4. WEBDAV COMMANDS
# ------------------------------------------------------------------------------

cmd_webdav() {
    local sub="$1"
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
            if [[ -f "$LOG_DIR/webdav_access.log" ]]; then
                tail -n "$lines" $follow "$LOG_DIR/webdav_access.log"
            elif [[ -f "$LOG_DIR/server.log" ]]; then
                tail -n "$lines" $follow "$LOG_DIR/server.log"
            else
                journalctl --no-pager -u mornye-storage.service -n "$lines" $follow 2>/dev/null || true
            fi
            ;;
        *)
            echo "Usage: ./mornye.sh webdav [status|test|logs]"
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 5. CLOUDFLARE PERMANENT TUNNEL COMMANDS
# ------------------------------------------------------------------------------

cmd_tunnel() {
    local sub="$1"
    shift || true

    case "$sub" in
        quick)
            cmd_tunnel_quick "$@"
            ;;
        status)
            run_cli_op "tunnel_ops.py" status
            ;;
        test)
            run_cli_op "tunnel_ops.py" test
            ;;
        start)
            sudo systemctl start mornye-tunnel.service 2>/dev/null || true
            echo -e "${GREEN}[✔] Tunnel start signal issued.${NC}"
            ;;
        stop)
            sudo systemctl stop mornye-tunnel.service 2>/dev/null || true
            echo -e "${GREEN}[✔] Tunnel stopped.${NC}"
            ;;
        restart)
            sudo systemctl restart mornye-tunnel.service 2>/dev/null || true
            echo -e "${GREEN}[✔] Tunnel restarted.${NC}"
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
            journalctl --no-pager -u mornye-tunnel.service -n "$lines" $follow 2>/dev/null || true
            ;;
        ""|help|--help|-h)
            echo "=============================================================="
            echo "             MORNYE TUNNEL MANAGEMENT USAGE"
            echo "=============================================================="
            echo "Permanent Tunnel Commands (Production):"
            echo "  ./mornye.sh tunnel start        Start mornye-tunnel.service"
            echo "  ./mornye.sh tunnel stop         Stop mornye-tunnel.service"
            echo "  ./mornye.sh tunnel restart      Restart mornye-tunnel.service"
            echo "  ./mornye.sh tunnel status       Check permanent tunnel telemetry & metrics"
            echo "  ./mornye.sh tunnel test         Probe WAN endpoint reachability"
            echo "  ./mornye.sh tunnel logs [-f]    View permanent tunnel service logs"
            echo ""
            echo "Cloudflare Quick Tunnel Commands (Ephemeral Testing):"
            echo "  ./mornye.sh tunnel quick start  Start temporary trycloudflare.com tunnel"
            echo "  ./mornye.sh tunnel quick status Check quick tunnel URL and WAN health"
            echo "  ./mornye.sh tunnel quick stop   Terminate active quick tunnel"
            echo "  ./mornye.sh tunnel quick logs   View quick tunnel output logs"
            echo "=============================================================="
            ;;
        *)
            echo -e "${RED}[ERROR] Unknown tunnel command: '$sub'${NC}"
            echo "Usage: ./mornye.sh tunnel [start|stop|restart|status|test|logs|quick]"
            echo "Run './mornye.sh tunnel' or './mornye.sh tunnel help' for detailed usage."
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 6. CLOUDFLARE QUICK TUNNEL (TEST MODE)
# ------------------------------------------------------------------------------

cmd_tunnel_quick() {
    local sub="$1"
    shift || true

    case "$sub" in
        start)
            cmd_tunnel_quick_start "$@"
            ;;
        status)
            cmd_tunnel_quick_status
            ;;
        stop)
            cmd_tunnel_quick_stop
            ;;
        logs)
            cmd_tunnel_quick_logs "$@"
            ;;
        ""|help|--help|-h)
            echo "=============================================================="
            echo "          CLOUDFLARE QUICK TUNNEL (TEST MODE) USAGE"
            echo "=============================================================="
            echo "Commands:"
            echo "  ./mornye.sh tunnel quick start [-y]  Start temporary trycloudflare.com tunnel"
            echo "  ./mornye.sh tunnel quick status      Show quick tunnel URL and health status"
            echo "  ./mornye.sh tunnel quick stop        Terminate active quick tunnel"
            echo "  ./mornye.sh tunnel quick logs [-f]   View quick tunnel output logs"
            echo "=============================================================="
            ;;
        *)
            echo -e "${RED}[ERROR] Unknown quick tunnel command: '$sub'${NC}"
            echo "Usage: ./mornye.sh tunnel quick [start|status|stop|logs]"
            exit 1
            ;;
    esac
}

cmd_tunnel_quick_start() {
    # 1. Dependency check
    if ! has_cmd cloudflared; then
        echo -e "${RED}[ERROR] 'cloudflared' binary is not installed.${NC}"
        echo -e "Install via: sudo apt-get install -y cloudflared (or download from Cloudflare)"
        exit 1
    fi

    # 2. Check if already running
    if [[ -f "$RUN_DIR/quick_tunnel.pid" ]]; then
        local pid
        pid=$(cat "$RUN_DIR/quick_tunnel.pid" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            local existing_url
            existing_url=$(cat "$RUN_DIR/quick_tunnel.url" 2>/dev/null || echo "Unknown URL")
            echo -e "${YELLOW}[!] Quick Tunnel is already active (PID: $pid).${NC}"
            echo -e "Temporary URL: ${CYAN}${existing_url}${NC}"
            return 0
        fi
    fi

    # 3. Check WebDAV local target availability
    local webdav_code
    webdav_code=$(curl -s -o /dev/null -w "%{http_code}" -X PROPFIND -H "Depth: 0" "http://127.0.0.1:8000/dav/" 2>/dev/null || echo "000")
    if [[ "$webdav_code" == "000" ]]; then
        echo -e "${RED}[ERROR] Local WebDAV engine (127.0.0.1:8000) is not responding.${NC}"
        echo -e "Please start Mornye WebDAV first via: ./mornye.sh start"
        exit 1
    fi

    # 4. Exposure Warning & Confirmation
    local auto_confirm=false
    for arg in "$@"; do
        if [[ "$arg" == "-y" || "$arg" == "--yes" ]]; then
            auto_confirm=true
        fi
    done

    echo -e "${YELLOW}"
    echo "=============================================================="
    echo "               CLOUDFLARE QUICK TUNNEL WARNING"
    echo "=============================================================="
    echo "Quick Tunnel exposes your local Mornye WebDAV service"
    echo "(127.0.0.1:8000) publicly via a temporary trycloudflare.com URL."
    echo ""
    echo "Security Status:"
    echo "  - Target Origin      : http://127.0.0.1:8000/dav/"
    echo "  - Authentication     : HTTP Basic Auth (Argon2id) ACTIVE"
    echo "  - Management Ports   : Port 8080/9000 strictly CLOSED / unexposed"
    echo "  - Permanence         : EPHEMERAL (Temporary test session only)"
    echo "=============================================================="
    echo -e "${NC}"

    if [[ "$auto_confirm" != true ]]; then
        read -p "Proceed with temporary Quick Tunnel test? [y/N]: " -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "[*] Quick Tunnel start aborted by operator."
            exit 0
        fi
    fi

    # 5. Launch process
    local log_file="$LOG_DIR/quick_tunnel.log"
    rm -f "$log_file" "$RUN_DIR/quick_tunnel.url"

    echo -e "[*] Requesting temporary Quick Tunnel via trycloudflare.com..."
    nohup cloudflared tunnel --url http://127.0.0.1:8000 --no-autoupdate > "$log_file" 2>&1 &
    local q_pid=$!
    echo "$q_pid" > "$RUN_DIR/quick_tunnel.pid"

    # 6. Poll for generated URL
    local tunnel_url=""
    for i in {1..20}; do
        sleep 1
        if ! kill -0 "$q_pid" 2>/dev/null; then
            echo -e "${RED}[ERROR] cloudflared process exited unexpectedly.${NC}"
            cat "$log_file"
            rm -f "$RUN_DIR/quick_tunnel.pid"
            exit 1
        fi

        tunnel_url=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log_file" | head -n1 || true)
        if [[ -n "$tunnel_url" ]]; then
            break
        fi
    done

    if [[ -n "$tunnel_url" ]]; then
        echo "$tunnel_url" > "$RUN_DIR/quick_tunnel.url"
        echo ""
        echo -e "${GREEN}==============================================================${NC}"
        echo -e "${GREEN}[✔] Cloudflare Quick Tunnel successfully established!${NC}"
        echo "--------------------------------------------------------------"
        echo -e "Temporary Public URL : ${CYAN}${tunnel_url}/dav/${NC}"
        echo -e "Process ID (PID)     : ${q_pid}"
        echo -e "Target Origin        : http://127.0.0.1:8000"
        echo -e "Auth Protection      : Argon2id Basic Authentication"
        echo -e "Session Status       : ACTIVE & ROUTING"
        echo "--------------------------------------------------------------"
        echo -e "${YELLOW}Note: This URL is temporary. Use './mornye.sh tunnel quick stop' to close.${NC}"
        echo -e "${GREEN}==============================================================${NC}"
    else
        echo -e "${RED}[ERROR] Timed out waiting for trycloudflare.com URL.${NC}"
        echo -e "Recent log output:"
        tail -n 15 "$log_file"
        cmd_tunnel_quick_stop
        exit 1
    fi
}

cmd_tunnel_quick_status() {
    if [[ ! -f "$RUN_DIR/quick_tunnel.pid" ]]; then
        echo -e "Cloudflare Quick Tunnel: ${YELLOW}INACTIVE${NC}"
        return 0
    fi

    local pid
    pid=$(cat "$RUN_DIR/quick_tunnel.pid" 2>/dev/null || true)
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        echo -e "Cloudflare Quick Tunnel: ${YELLOW}INACTIVE (Stale state cleaned)${NC}"
        rm -f "$RUN_DIR/quick_tunnel.pid" "$RUN_DIR/quick_tunnel.url"
        return 0
    fi

    local url
    url=$(cat "$RUN_DIR/quick_tunnel.url" 2>/dev/null || echo "Unknown URL")

    # Probe live URL
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PROPFIND -H "Depth: 0" "${url}/dav/" 2>/dev/null || echo "000")

    echo "=============================================================="
    echo "             CLOUDFLARE QUICK TUNNEL STATUS"
    echo "=============================================================="
    echo -e "Process State         : ${GREEN}ACTIVE${NC} (PID: $pid)"
    echo -e "Temporary Public URL  : ${CYAN}${url}/dav/${NC}"
    echo -e "Target Local Origin   : http://127.0.0.1:8000"
    echo -e "WAN Endpoint Status   : HTTP $http_code (Auth Boundary Active)"
    echo -e "Mode                  : Ephemeral / Non-permanent testing"
    echo "=============================================================="
}

cmd_tunnel_quick_stop() {
    if [[ ! -f "$RUN_DIR/quick_tunnel.pid" ]]; then
        echo -e "[*] Quick Tunnel is not currently running."
        return 0
    fi

    local pid
    pid=$(cat "$RUN_DIR/quick_tunnel.pid" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        echo -e "[*] Stopping Quick Tunnel process (PID: $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
        for i in {1..5}; do
            if kill -0 "$pid" 2>/dev/null; then
                sleep 0.5
            else
                break
            fi
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi

    rm -f "$RUN_DIR/quick_tunnel.pid" "$RUN_DIR/quick_tunnel.url"
    echo -e "${GREEN}[✔] Quick Tunnel terminated cleanly.${NC}"
}

cmd_tunnel_quick_logs() {
    local follow=""
    local lines="50"
    for arg in "$@"; do
        if [[ "$arg" == "-f" || "$arg" == "--follow" ]]; then
            follow="-f"
        elif [[ "$arg" =~ ^[0-9]+$ ]]; then
            lines="$arg"
        fi
    done

    local log_file="$LOG_DIR/quick_tunnel.log"
    if [[ -f "$log_file" ]]; then
        tail -n "$lines" $follow "$log_file"
    else
        echo -e "${YELLOW}[!] No Quick Tunnel log file found at $log_file.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 7. MUSIC CATALOG COMMANDS
# ------------------------------------------------------------------------------

cmd_music() {
    local sub="$1"
    shift || true

    case "$sub" in
        list)
            run_cli_op "music_ops.py" list
            ;;
        stats)
            run_cli_op "music_ops.py" stats
            ;;
        verify)
            run_cli_op "music_ops.py" verify
            ;;
        *)
            echo "Usage: ./mornye.sh music [list|stats|verify]"
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 8. USERS & QUOTA COMMANDS
# ------------------------------------------------------------------------------

cmd_users() {
    local sub="$1"
    shift || true

    case "$sub" in
        list)
            run_cli_op "user_ops.py" list
            ;;
        *)
            echo "Usage: ./mornye.sh users list"
            exit 1
            ;;
    esac
}

cmd_quota() {
    local sub="$1"
    shift || true

    case "$sub" in
        status)
            run_cli_op "user_ops.py" status
            ;;
        recalculate)
            run_cli_op "user_ops.py" recalculate
            ;;
        *)
            echo "Usage: ./mornye.sh quota [status|recalculate]"
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 9. BACKUP & RECOVERY COMMANDS
# ------------------------------------------------------------------------------

cmd_backup() {
    local sub="$1"
    shift || true

    case "$sub" in
        create)
            run_cli_op "backup_ops.py" create
            ;;
        list)
            run_cli_op "backup_ops.py" list
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
# 10. SYSTEM MONITORING COMMANDS
# ------------------------------------------------------------------------------

cmd_monitor() {
    local sub="${1:-all}"
    shift || true
    run_cli_op "system_ops.py" "$sub"
}

# ------------------------------------------------------------------------------
# 11. LOGS COMMANDS
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
            cmd_webdav logs $follow "$lines"
            ;;
        tunnel)
            cmd_tunnel logs $follow "$lines"
            ;;
        backend)
            if [[ -f "$LOG_DIR/server.log" ]]; then
                tail -n "$lines" $follow "$LOG_DIR/server.log"
            else
                journalctl --no-pager -u mornye-storage.service -n "$lines" $follow 2>/dev/null || true
            fi
            ;;
        *)
            if [[ -f "$LOG_DIR/server.log" ]]; then
                tail -n "$lines" $follow "$LOG_DIR/server.log"
            else
                journalctl --no-pager -u mornye-storage.service -u mornye-tunnel.service -n "$lines" $follow 2>/dev/null || true
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
            cmd_start
            ;;
        stop)
            cmd_stop
            ;;
        restart)
            cmd_restart
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

