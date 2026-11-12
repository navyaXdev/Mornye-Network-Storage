#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — AUTOMATED SYSTEM SETUP & DEPLOYMENT SCRIPT
# Version: 3.0.0
# Supported Operating Systems: Debian 12+, Ubuntu 22.04/24.04, Kali Linux 2024+
# Architecture Support: x86_64, aarch64, arm64
# ==============================================================================

set -eo pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROGRAM_DIR"

# ANSI Terminal Formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo -e "${CYAN}"
    cat << "EOF"
================================================================
   __  __  ____  _____  _   ___     ______
  |  \/  |/ __ \|  _  \| \ | \ \   / /  __|
  | \  / | |  | | |_| ||  \| |\ \_/ /| |__ 
  | |\/| | |  | |    _/| . ` | \   / |  __| 
  | |  | | |__| | |\ \ | |\  |  | |  | |___ 
  |_|  |_|\____/|_| \_\|_| \_|  |_|  |_____|
  Automated Infrastructure Installation & Provisioning Engine
================================================================
EOF
    echo -e "${NC}"
}

# ------------------------------------------------------------------------------
# 1. ENVIRONMENT & HARDWARE DETECTION
# ------------------------------------------------------------------------------

detect_platform() {
    echo -e "${BOLD}[1/8] Inspecting Host Platform & Kernel...${NC}"

    ARCH="$(uname -m)"
    KERNEL="$(uname -r)"
    echo -e "  - CPU Architecture : ${GREEN}$ARCH${NC}"
    echo -e "  - Kernel Version   : ${GREEN}$KERNEL${NC}"

    case "$ARCH" in
        x86_64|amd64|aarch64|arm64)
            ;;
        *)
            echo -e "${YELLOW}  [!] Notice: Architecture '$ARCH' is experimental. Recommended: x86_64 or aarch64.${NC}"
            ;;
    esac

    DISTRO="unknown"
    DISTRO_ID="unknown"
    if [[ -f /etc/os-release ]]; then
        DISTRO="$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')"
        DISTRO_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
        echo -e "  - Detected OS      : ${GREEN}$DISTRO${NC} (id: $DISTRO_ID)"
    else
        echo -e "${YELLOW}  [!] Warning: /etc/os-release not detected. Continuing with standard POSIX assumptions.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 2. PERMISSIONS & DISK CAPACITY AUDIT
# ------------------------------------------------------------------------------

audit_permissions_and_storage() {
    echo -e "\n${BOLD}[2/8] Auditing Permissions and Disk Capacity...${NC}"

    CURRENT_USER="$(whoami)"
    USER_ID="$(id -u)"
    echo -e "  - Execution User   : ${GREEN}$CURRENT_USER (UID: $USER_ID)${NC}"

    if [[ "$USER_ID" -eq 0 ]]; then
        echo -e "${YELLOW}  [!] Warning: Running setup directly as root. Application files will be set to UID 1000 for container parity.${NC}"
    fi

    # Disk Space Check (Minimum 2 GB required)
    AVAILABLE_KB=$(df -k "$PROGRAM_DIR" | awk 'NR==2 {print $4}')
    AVAILABLE_MB=$(( AVAILABLE_KB / 1024 ))
    echo -e "  - Available Disk   : ${GREEN}${AVAILABLE_MB} MB free${NC}"

    if [[ "$AVAILABLE_MB" -lt 2048 ]]; then
        echo -e "${RED}[ERROR] Insufficient disk space: At least 2048 MB free disk space required.${NC}"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 3. PREREQUISITES & DEPENDENCY DETECTION
# ------------------------------------------------------------------------------

check_dependencies() {
    echo -e "\n${BOLD}[3/8] Inspecting Software Dependencies...${NC}"

    MISSING_PKGS=()

    # Python 3 Check
    if command -v python3 &>/dev/null; then
        PY_VER=$(python3 -c "import sys; print('.'.join(map(str, sys.version_info[:3])))")
        echo -e "  - Python 3 Engine  : ${GREEN}[✔] Python $PY_VER${NC}"
    else
        echo -e "  - Python 3 Engine  : ${RED}[✘] Missing${NC}"
        MISSING_PKGS+=("python3" "python3-pip" "python3-venv")
    fi

    # SQLite3 CLI
    if command -v sqlite3 &>/dev/null; then
        echo -e "  - SQLite3 Engine   : ${GREEN}[✔] $(sqlite3 --version | cut -d' ' -f1)${NC}"
    else
        echo -e "  - SQLite3 Engine   : ${YELLOW}[!] CLI tool missing${NC}"
        MISSING_PKGS+=("sqlite3")
    fi

    # Curl
    if command -v curl &>/dev/null; then
        echo -e "  - cURL Utility     : ${GREEN}[✔] Installed${NC}"
    else
        echo -e "  - cURL Utility     : ${RED}[✘] Missing${NC}"
        MISSING_PKGS+=("curl")
    fi

    # Docker Engine
    DOCKER_AVAILABLE=false
    if command -v docker &>/dev/null; then
        DOCKER_AVAILABLE=true
        echo -e "  - Docker Engine    : ${GREEN}[✔] $(docker --version)${NC}"
    else
        echo -e "  - Docker Engine    : ${YELLOW}[!] Not installed on host${NC}"
    fi

    # Docker Compose
    COMPOSE_AVAILABLE=false
    if docker compose version &>/dev/null; then
        COMPOSE_AVAILABLE=true
        echo -e "  - Docker Compose   : ${GREEN}[✔] $(docker compose version)${NC}"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_AVAILABLE=true
        echo -e "  - Docker Compose   : ${GREEN}[✔] $(docker-compose --version)${NC}"
    else
        echo -e "  - Docker Compose   : ${YELLOW}[!] Compose plugin missing${NC}"
    fi

    # Guidance for Missing Host Tools
    if [[ ${#MISSING_PKGS[@]} -gt 0 || "$DOCKER_AVAILABLE" != true ]]; then
        echo -e "\n${YELLOW}=== INSTALLATION GUIDANCE FOR MISSING PREREQUISITES ===${NC}"
        case "$DISTRO_ID" in
            debian|ubuntu|kali)
                echo -e "Execute the following commands to install required packages:"
                echo -e "  ${CYAN}sudo apt-get update${NC}"
                echo -e "  ${CYAN}sudo apt-get install -y ${MISSING_PKGS[*]} docker.io docker-compose${NC}"
                echo -e "  ${CYAN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
                ;;
            fedora|rhel|centos)
                echo -e "Execute the following commands to install required packages:"
                echo -e "  ${CYAN}sudo dnf install -y python3 python3-pip sqlite curl docker docker-compose-plugin${NC}"
                echo -e "  ${CYAN}sudo systemctl enable --now docker && sudo usermod -aG docker \$USER${NC}"
                ;;
            arch|manjaro)
                echo -e "Execute the following commands to install required packages:"
                echo -e "  ${CYAN}sudo pacman -Syu --noconfirm python python-pip sqlite curl docker docker-compose${NC}"
                echo -e "  ${CYAN}sudo systemctl enable --now docker && sudo usermod -aG docker \$USER${NC}"
                ;;
            *)
                echo -e "Please install the missing tools using your system's package manager: ${MISSING_PKGS[*]}"
                ;;
        esac
        echo -e "========================================================\n"
    fi
}

# ------------------------------------------------------------------------------
# 4. DIRECTORY STRUCTURE & PERMISSIONS
# ------------------------------------------------------------------------------

provision_directories() {
    echo -e "${BOLD}[4/8] Provisioning Persistent Storage & Safe Permissions...${NC}"

    DIRS=(
        "$PROGRAM_DIR/database"
        "$PROGRAM_DIR/database/cache"
        "$PROGRAM_DIR/database/tmp"
        "$PROGRAM_DIR/database/recycle_bin"
        "$PROGRAM_DIR/storage"
        "$PROGRAM_DIR/logs"
        "$PROGRAM_DIR/backups"
        "$PROGRAM_DIR/run"
    )

    for d in "${DIRS[@]}"; do
        if [[ ! -d "$d" ]]; then
            mkdir -p "$d"
            echo -e "  - Created directory: ${GREEN}$d${NC}"
        fi
    done

    # Secure permissions: 700 for databases & backups, 755 for storage and logs
    chmod 700 "$PROGRAM_DIR/database" "$PROGRAM_DIR/backups"
    chmod 755 "$PROGRAM_DIR/storage" "$PROGRAM_DIR/logs" "$PROGRAM_DIR/run"
    chmod +x "$PROGRAM_DIR/mornye.sh" "$PROGRAM_DIR/docker/entrypoint.sh" "$PROGRAM_DIR/docker/healthcheck.sh" 2>/dev/null || true

    echo -e "  - Security permissions set: ${GREEN}[✔] Verified${NC}"
}

# ------------------------------------------------------------------------------
# 5. ENVIRONMENT INITIALIZATION
# ------------------------------------------------------------------------------

configure_environment() {
    echo -e "\n${BOLD}[5/8] Validating Application Configuration...${NC}"

    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        echo -e "  - Environment file : ${GREEN}[✔] .env exists (never overwritten)${NC}"
    elif [[ -f "$PROGRAM_DIR/.env.example" ]]; then
        echo -e "  - Environment file : ${YELLOW}[!] Creating .env from .env.example...${NC}"
        cp "$PROGRAM_DIR/.env.example" "$PROGRAM_DIR/.env"
        
        # Generate random 64-character hex secret key
        RANDOM_KEY=$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n' 2>/dev/null || date +%s%N | sha256sum | head -c 64)
        sed -i "s/SECRET_KEY=.*/SECRET_KEY=$RANDOM_KEY/" "$PROGRAM_DIR/.env"
        chmod 600 "$PROGRAM_DIR/.env"
        echo -e "  - Secret Key       : ${GREEN}[✔] Cryptographic SECRET_KEY generated${NC}"
    else
        echo -e "  - Environment file : ${YELLOW}[!] Generating default .env template...${NC}"
        cat << "ENVEOF" > "$PROGRAM_DIR/.env"
APP_NAME="Mornye Network Storage"
APP_ENV=production
DEBUG=false
SECRET_KEY=mornye-production-secret-must-be-changed-in-production
WEBDAV_HOST=127.0.0.1
WEBDAV_PORT=8000
DEFAULT_STORAGE_QUOTA_BYTES=107374182400
MAX_UPLOAD_SIZE_BYTES=2147483648
STORAGE_HOSTNAME=storage.example.com
PUBLIC_DOMAIN=example.com
ENVEOF
        chmod 600 "$PROGRAM_DIR/.env"
    fi
}

# ------------------------------------------------------------------------------
# 6. DOCKER BUILD / VALIDATION
# ------------------------------------------------------------------------------

build_and_validate_docker() {
    echo -e "\n${BOLD}[6/8] Validating Docker Configuration...${NC}"

    if [[ "$DOCKER_AVAILABLE" == true && "$COMPOSE_AVAILABLE" == true ]]; then
        echo -e "  - Validating compose.yaml syntax..."
        if docker compose config &>/dev/null; then
            echo -e "  - Compose Syntax   : ${GREEN}[✔] Valid${NC}"
            
            read -p "  Build production Docker image now? [Y/n]: " -r do_build
            if [[ ! "$do_build" =~ ^[Nn]$ ]]; then
                echo -e "  - Building image 'mornye-webdav:latest'..."
                docker compose build
                echo -e "  - Container Build  : ${GREEN}[✔] Complete${NC}"
            fi
        else
            echo -e "  - Compose Syntax   : ${YELLOW}[!] compose.yaml validation warning${NC}"
        fi
    else
        echo -e "  - Docker Engine    : ${YELLOW}[!] Skipped (Docker not installed on host)${NC}"
        echo -e "    Note: Mornye can run natively via './mornye.sh start' or systemd."
    fi
}

# ------------------------------------------------------------------------------
# 7. SERVICE LAUNCH & VERIFICATION
# ------------------------------------------------------------------------------

verify_health() {
    echo -e "\n${BOLD}[7/8] Executing Infrastructure Health Probe...${NC}"
    ./mornye.sh doctor
}

# ------------------------------------------------------------------------------
# 8. SUMMARY & NEXT STEPS
# ------------------------------------------------------------------------------

print_summary() {
    echo -e "\n${GREEN}================================================================${NC}"
    echo -e "${GREEN}[✔] MORNYE NETWORK STORAGE SETUP SUCCESSFULLY COMPLETED!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "${BOLD}Local Endpoints:${NC}"
    echo -e "  - WebDAV Root Path : ${CYAN}http://127.0.0.1:8000/dav/${NC}"
    echo -e "  - Service Health   : ${CYAN}http://127.0.0.1:8000/health${NC}"
    echo ""
    echo -e "${BOLD}Primary Management Commands:${NC}"
    echo -e "  - Infrastructure Status : ${CYAN}./mornye.sh status${NC}"
    echo -e "  - WebDAV Diagnostics   : ${CYAN}./mornye.sh webdav test${NC}"
    echo -e "  - Music Catalog & Quota : ${CYAN}./mornye.sh music stats${NC}"
    echo -e "  - Hot Database Backup   : ${CYAN}./mornye.sh backup create${NC}"
    echo -e "  - Start Quick Tunnel    : ${CYAN}./mornye.sh tunnel quick start${NC}"
    echo -e "  - Stop Quick Tunnel     : ${CYAN}./mornye.sh tunnel quick stop${NC}"
    echo ""
    echo -e "${BOLD}Deployment Options:${NC}"
    echo -e "  - Docker Stack          : ${CYAN}./mornye.sh docker up${NC}"
    echo -e "  - Native Host Daemon    : ${CYAN}./mornye.sh start${NC}"
    echo -e "${GREEN}================================================================${NC}\n"
}

main() {
    print_header
    detect_platform
    audit_permissions_and_storage
    check_dependencies
    provision_directories
    configure_environment
    build_and_validate_docker
    verify_health
    print_summary
}

main "$@"
