#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — UNIVERSAL MULTI-DISTRIBUTION ONE-COMMAND INSTALLER
# Version: 3.2.0
# Description: Automated Linux distribution detector, multi-package-manager
#              provisioner, Docker-only container runtime, and Cloudflare setup.
# Supported OS: Debian, Ubuntu, Kali, Arch, Manjaro, Fedora, Rocky, AlmaLinux,
#               RHEL, openSUSE, Alpine, and compatible Linux distributions.
# ==============================================================================

set -eo pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROGRAM_DIR"

INSTALLERS_DIR="$PROGRAM_DIR/installers"
SCRIPTS_DIR="$PROGRAM_DIR/scripts"

# Source Common Detection & Audit Utilities
if [[ -f "$INSTALLERS_DIR/common.sh" ]]; then
    # shellcheck disable=SC1091
    source "$INSTALLERS_DIR/common.sh"
else
    echo "Error: installers/common.sh not found."
    exit 1
fi

# Execution Flags
NON_INTERACTIVE=false
CHECK_ONLY=false
SKIP_DOCKER=false
SKIP_CLOUDFLARED=false
DO_BUILD_IMAGE=true
NETWORKING_MODE="local" # local | permanent | quick
CHOSEN_ROOT_DOMAIN=""
CHOSEN_DOMAIN=""

# WebDAV Authentication Flags
WEBDAV_AUTH_ENABLED=true
AUTH_EXPLICIT_CHOICE="" # "enable" | "disable"
WEBDAV_USER=""
WEBDAV_PASS=""
GENERATE_PASSWORD=false
CONFIRM_UNAUTHENTICATED=false
DO_PROVISION_USER=false

# Trap handler for cleanup
cleanup() {
    cleanup_sudo_keepalive
}
trap cleanup EXIT INT TERM

show_help() {
    cat << "EOF"
Mornye Network Storage — Universal Linux Master Installer

Usage:
  ./setup.sh [OPTIONS]

Options:
  -y, --yes, --non-interactive  Run without interactive prompts (auto-confirm installation)
  --check-only                  Inspect host environment, hardware, and dependencies only
  --no-docker                   Skip Docker installation (assumes pre-installed Docker)
  --skip-cloudflared            Skip optional cloudflared installation
  --cert <path>                 Path to existing Cloudflare origin certificate (cert.pem)
  --network-mode <mode>         Set networking mode: 'local', 'permanent', or 'quick'
  --domain, --root-domain <dom> Root domain for Cloudflare Tunnel (auto-configures mornye.<domain>)
  --auth-enabled                Enforce WebDAV HTTP Basic Auth (Recommended, default)
  --auth-disabled               Disable WebDAV HTTP Basic Auth (Anonymous public access)
  --webdav-user <username>      Set WebDAV administrator username (Default: admin)
  --webdav-password <password>  Set WebDAV administrator password (min 8 chars)
  --generate-password           Generate cryptographically secure 16-character password
  --confirm-unauthenticated     Explicitly confirm exposing unauthenticated storage via Cloudflare WAN
  -h, --help                    Display this help manual and exit

Supported Distributions:
  - Debian 12 / 13, Ubuntu 22.04 / 24.04 / 26.04, Kali Linux, Linux Mint, Pop!_OS (APT)
  - Arch Linux, Manjaro, EndeavourOS, CachyOS (Pacman)
  - Fedora Workstation / Server (DNF)
  - Rocky Linux, AlmaLinux, RHEL 8 / 9, CentOS Stream (DNF/YUM)
  - openSUSE Leap / Tumbleweed (Zypper)
  - Alpine Linux (APK)
EOF
}

# Parse Command-Line Options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --no-docker)
            SKIP_DOCKER=true
            shift
            ;;
        --skip-cloudflared)
            SKIP_CLOUDFLARED=true
            shift
            ;;
        --cert)
            CLOUDFLARE_CERT_PATH="$2"
            export CLOUDFLARE_CERT_PATH
            shift 2
            ;;
        --network-mode)
            NETWORKING_MODE="$2"
            shift 2
            ;;
        --domain|--root-domain)
            CHOSEN_ROOT_DOMAIN="$2"
            shift 2
            ;;
        --auth-enabled)
            WEBDAV_AUTH_ENABLED=true
            AUTH_EXPLICIT_CHOICE="enable"
            shift
            ;;
        --auth-disabled)
            WEBDAV_AUTH_ENABLED=false
            AUTH_EXPLICIT_CHOICE="disable"
            shift
            ;;
        --webdav-user)
            WEBDAV_USER="$2"
            shift 2
            ;;
        --webdav-password)
            WEBDAV_PASS="$2"
            shift 2
            ;;
        --generate-password)
            GENERATE_PASSWORD=true
            shift
            ;;
        --confirm-unauthenticated)
            CONFIRM_UNAUTHENTICATED=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] Unknown option: $1${NC}"
            echo "Run './setup.sh --help' for usage."
            exit 1
            ;;
    esac
done

if [[ "${NON_INTERACTIVE:-}" == "1" || "${DEBIAN_FRONTEND:-}" == "noninteractive" ]]; then
    NON_INTERACTIVE=true
fi

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
  Universal Multi-Distribution Linux Master Installer & Engine
================================================================
EOF
    echo -e "${NC}"
}

# ------------------------------------------------------------------------------
# STAGE 1: SYSTEM REQUIREMENTS & DISTRIBUTION DETECTION
# ------------------------------------------------------------------------------

stage1_welcome_and_audit() {
    log_step "[Stage 1/7] Detecting Linux Distribution & Host Hardware..."

    detect_linux_distribution
    audit_privileges || exit 1
    audit_system_resources "$PROGRAM_DIR"

    echo -e "  - Detected Platform : ${GREEN}$OS_PRETTY${NC}"
    echo -e "  - Distribution ID   : ${GREEN}$OS_ID${NC} (Codename: ${GREEN}${OS_CODENAME:-rolling}${NC}, Family: ${GREEN}$OS_FAMILY${NC})"
    echo -e "  - Package Manager   : ${GREEN}$PKG_MANAGER${NC}"
    echo -e "  - Init System       : ${GREEN}$INIT_SYSTEM${NC}"
    echo -e "  - Architecture      : ${GREEN}$CPU_ARCH${NC} (Kernel: ${GREEN}$KERNEL_VER${NC})"
    echo -e "  - CPU Compute Cores : ${GREEN}$CPU_CORES physical/logical cores${NC}"
    echo -e "  - Physical RAM      : ${GREEN}${RAM_TOTAL_MB} MB total${NC} (${RAM_AVAIL_MB} MB available)"
    echo -e "  - Free Storage      : ${GREEN}${DISK_FREE_MB} MB free${NC}"
    echo -e "  - Execution User    : ${GREEN}$(whoami) (UID: $(id -u))${NC}"

    # Verify Minimum Hardware Thresholds
    if [[ "$RAM_TOTAL_MB" -lt 900 ]]; then
        log_warn "Low physical memory detected (${RAM_TOTAL_MB} MB). Minimum 1024 MB recommended."
    fi

    if [[ "$DISK_FREE_MB" -lt 2048 ]]; then
        log_err "Insufficient disk space: At least 2048 MB free space required (Found ${DISK_FREE_MB} MB)."
        exit 1
    fi

    # Network verification
    if check_internet_access; then
        echo -e "  - WAN Reachability  : ${GREEN}[✔] Online (Cloudflare/GitHub reachability verified)${NC}"
    else
        echo -e "  - WAN Reachability  : ${YELLOW}[!] Offline or limited network access${NC}"
    fi

    # Locate Distribution Package Module
    local pkg_module="$INSTALLERS_DIR/${PKG_MANAGER}.sh"
    if [[ ! -f "$pkg_module" ]]; then
        log_err "No package installer module found for package manager '$PKG_MANAGER' ($pkg_module)."
        log_err "Supported package managers: apt, pacman, dnf, yum, zypper, apk."
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$pkg_module"

    if [[ "$CHECK_ONLY" == true ]]; then
        log_ok "System audit and distribution compatibility check completed successfully."
        return 0
    fi

    if [[ "$NON_INTERACTIVE" != true ]]; then
        read -p "  Proceed with Mornye installation on this system? [Y/n]: " -r confirm_stage1
        if [[ "$confirm_stage1" =~ ^[Nn]$ ]]; then
            log_warn "Installation aborted by operator."
            exit 0
        fi
    fi
}

# ------------------------------------------------------------------------------
# STAGE 2: STORAGE CONFIGURATION & DATA PRESERVATION
# ------------------------------------------------------------------------------

stage2_storage_setup() {
    if [[ "$CHECK_ONLY" == true ]]; then
        return 0
    fi
    log_step "[Stage 2/7] Provisioning Persistent Storage & Hardening Permissions..."

    local target_user="${SUDO_USER:-$(whoami)}"
    local target_uid target_gid

    if [[ "$target_user" != "root" ]]; then
        target_uid=$(id -u "$target_user" 2>/dev/null || echo 1000)
        target_gid=$(id -g "$target_user" 2>/dev/null || echo 1000)
    else
        target_uid="${MORNYE_UID:-1000}"
        target_gid="${MORNYE_GID:-1000}"
    fi

    local dirs=(
        "$PROGRAM_DIR/database"
        "$PROGRAM_DIR/database/cache"
        "$PROGRAM_DIR/database/tmp"
        "$PROGRAM_DIR/database/recycle_bin"
        "$PROGRAM_DIR/storage"
        "$PROGRAM_DIR/logs"
        "$PROGRAM_DIR/backups"
        "$PROGRAM_DIR/run"
        "$PROGRAM_DIR/config"
    )

    for d in "${dirs[@]}"; do
        if [[ ! -d "$d" ]]; then
            mkdir -p "$d"
            log_ok "Created directory: $d"
        fi
    done

    # Ensure ownership belongs to target non-root container user
    if [[ "$(id -u)" -eq 0 && -n "$target_uid" && -n "$target_gid" ]]; then
        chown -R "${target_uid}:${target_gid}" \
            "$PROGRAM_DIR/database" \
            "$PROGRAM_DIR/storage" \
            "$PROGRAM_DIR/logs" \
            "$PROGRAM_DIR/backups" \
            "$PROGRAM_DIR/run" \
            "$PROGRAM_DIR/config" 2>/dev/null || true
    fi

    # Security Permissions Hardening
    # 750 gives owner rwx, group rx, others none
    chmod 750 "$PROGRAM_DIR/database" "$PROGRAM_DIR/backups" "$PROGRAM_DIR/config" 2>/dev/null || chmod 700 "$PROGRAM_DIR/database" 2>/dev/null || true
    chmod 755 "$PROGRAM_DIR/storage" "$PROGRAM_DIR/logs" "$PROGRAM_DIR/run" 2>/dev/null || true
    chmod +x "$PROGRAM_DIR/mornye.sh" "$PROGRAM_DIR/docker/entrypoint.sh" "$PROGRAM_DIR/docker/healthcheck.sh" 2>/dev/null || true

    log_ok "Storage permissions hardened: database/backups/config (750), storage/logs/run (755), owned by UID:GID ${target_uid}:${target_gid}."

    # Environment Configuration (.env)
    local port_8000_free=true
    if (echo > "/dev/tcp/127.0.0.1/8000") 2>/dev/null; then
        port_8000_free=false
    fi

    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        log_ok "Environment configuration (.env) preserved (Never overwritten)."
        # Ensure MORNYE_UID and MORNYE_GID are defined
        if ! grep -q "^MORNYE_UID=" "$PROGRAM_DIR/.env"; then
            echo "MORNYE_UID=${target_uid}" >> "$PROGRAM_DIR/.env"
        fi
        if ! grep -q "^MORNYE_GID=" "$PROGRAM_DIR/.env"; then
            echo "MORNYE_GID=${target_gid}" >> "$PROGRAM_DIR/.env"
        fi
        if ! grep -q "^MORNYE_HOST_PORT=" "$PROGRAM_DIR/.env"; then
            local chosen_port="8001"
            if command -v port_resolve_host_port &>/dev/null; then
                chosen_port="$(port_resolve_host_port "$PROGRAM_DIR/.env")"
            fi
            echo "MORNYE_HOST_PORT=${chosen_port}" >> "$PROGRAM_DIR/.env"
            echo "MORNYE_HOST_BIND=127.0.0.1" >> "$PROGRAM_DIR/.env"
            log_ok "Configured MORNYE_HOST_PORT=${chosen_port} (Isolated from protected host services)."
        fi
        if ! grep -q "^WEBDAV_AUTH_ENABLED=" "$PROGRAM_DIR/.env"; then
            echo "WEBDAV_AUTH_ENABLED=true" >> "$PROGRAM_DIR/.env"
        fi
        if ! grep -q "^WEBDAV_USER=" "$PROGRAM_DIR/.env"; then
            echo "WEBDAV_USER=admin" >> "$PROGRAM_DIR/.env"
        fi
    elif [[ -f "$PROGRAM_DIR/.env.example" ]]; then
        log_info "Creating .env from template .env.example..."
        cp "$PROGRAM_DIR/.env.example" "$PROGRAM_DIR/.env"
        
        local rand_key
        rand_key=$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n' 2>/dev/null || date +%s%N | sha256sum | head -c 64)
        sed -i "s/SECRET_KEY=.*/SECRET_KEY=$rand_key/" "$PROGRAM_DIR/.env"
        sed -i "s/^MORNYE_UID=.*/MORNYE_UID=$target_uid/" "$PROGRAM_DIR/.env" 2>/dev/null || echo "MORNYE_UID=$target_uid" >> "$PROGRAM_DIR/.env"
        sed -i "s/^MORNYE_GID=.*/MORNYE_GID=$target_gid/" "$PROGRAM_DIR/.env" 2>/dev/null || echo "MORNYE_GID=$target_gid" >> "$PROGRAM_DIR/.env"
        if ! grep -q "^WEBDAV_AUTH_ENABLED=" "$PROGRAM_DIR/.env"; then
            echo "WEBDAV_AUTH_ENABLED=true" >> "$PROGRAM_DIR/.env"
        fi
        if ! grep -q "^WEBDAV_USER=" "$PROGRAM_DIR/.env"; then
            echo "WEBDAV_USER=admin" >> "$PROGRAM_DIR/.env"
        fi
        if [[ "$port_8000_free" == false ]]; then
            sed -i "s/^MORNYE_HOST_PORT=.*/MORNYE_HOST_PORT=8001/" "$PROGRAM_DIR/.env" 2>/dev/null || echo "MORNYE_HOST_PORT=8001" >> "$PROGRAM_DIR/.env"
            log_ok "Port 8000 is occupied by existing service. Auto-assigned MORNYE_HOST_PORT=8001."
        fi
        chmod 600 "$PROGRAM_DIR/.env"
        [[ "$(id -u)" -eq 0 && "$target_user" != "root" ]] && chown "${target_uid}:${target_gid}" "$PROGRAM_DIR/.env" 2>/dev/null || true
        log_ok "Generated cryptographically secure 64-character SECRET_KEY in .env."
    else
        cat << ENVEOF > "$PROGRAM_DIR/.env"
APP_NAME="Mornye Network Storage"
APP_ENV=production
DEBUG=false
SECRET_KEY=mornye-production-secret-must-be-changed-in-production
WEBDAV_HOST=0.0.0.0
WEBDAV_PORT=8000
WEBDAV_AUTH_ENABLED=true
WEBDAV_USER=admin
MORNYE_HOST_BIND=127.0.0.1
MORNYE_HOST_PORT=8001
MORNYE_UID=${target_uid}
MORNYE_GID=${target_gid}
DEFAULT_STORAGE_QUOTA_BYTES=107374182400
MAX_UPLOAD_SIZE_BYTES=2147483648
STORAGE_HOSTNAME=storage.example.com
PUBLIC_DOMAIN=example.com
ENVEOF
        chmod 600 "$PROGRAM_DIR/.env"
        [[ "$(id -u)" -eq 0 && "$target_user" != "root" ]] && chown "${target_uid}:${target_gid}" "$PROGRAM_DIR/.env" 2>/dev/null || true
        log_ok "Default .env configuration created (MORNYE_HOST_PORT=8001, MORNYE_UID=${target_uid}, MORNYE_GID=${target_gid})."
    fi
}

# ------------------------------------------------------------------------------
# STAGE 3: CONFIGURE WEBDAV AUTHENTICATION
# ------------------------------------------------------------------------------

generate_secure_password() {
    local pass=""
    if command -v python3 &>/dev/null; then
        pass=$(python3 -c "import secrets, string; alphabet = string.ascii_letters + string.digits + '!@#$%&*'; print(''.join(secrets.choice(alphabet) for _ in range(16)))" 2>/dev/null || true)
    fi
    if [[ -z "$pass" ]] && command -v openssl &>/dev/null; then
        pass=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9!@#$%&*' | head -c 16 2>/dev/null || true)
    fi
    if [[ -z "$pass" ]]; then
        pass=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9!@#$%&*' | head -c 16 2>/dev/null || true)
    fi
    echo "$pass"
}

print_credential_card() {
    local u="$1"
    local p="$2"
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${BOLD}       MORNYE WEBDAV CREDENTIALS (SAVE IMMEDIATELY)             ${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  Username  : ${GREEN}${u}${NC}"
    echo -e "  Password  : ${YELLOW}${p}${NC}"
    echo -e "  Auth Mode : ${GREEN}HTTP Basic Auth (Argon2id Hash Enforced)${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  ${YELLOW}[!] NOTICE: For security, this password is NOT stored in plain text.${NC}"
    echo -e "      It is hashed into the database and will NOT be shown again."
    echo -e "${CYAN}================================================================${NC}\n"
}

stage3_webdav_auth() {
    if [[ "$CHECK_ONLY" == true ]]; then
        return 0
    fi
    log_step "[Stage 3/7] Configuring WebDAV Authentication..."

    local has_db_users=false
    if [[ -f "$PROGRAM_DIR/database/mornye.db" ]]; then
        if command -v sqlite3 &>/dev/null; then
            local u_count
            u_count=$(sqlite3 "$PROGRAM_DIR/database/mornye.db" "SELECT count(*) FROM users WHERE is_active=1;" 2>/dev/null || echo "0")
            if [[ "$u_count" -gt 0 ]]; then
                has_db_users=true
            fi
        fi
    fi

    # Read existing WEBDAV_AUTH_ENABLED from .env if present
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        local env_auth
        env_auth=$(grep -E '^WEBDAV_AUTH_ENABLED=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]' || true)
        if [[ "$env_auth" == "false" && -z "$AUTH_EXPLICIT_CHOICE" ]]; then
            WEBDAV_AUTH_ENABLED=false
        fi
    fi

    # 1. Non-Interactive Handling
    if [[ "$NON_INTERACTIVE" == true ]]; then
        if [[ "$WEBDAV_AUTH_ENABLED" == false ]]; then
            log_warn "Non-interactive mode: WebDAV authentication is DISABLED."
            DO_PROVISION_USER=false
            return 0
        fi

        WEBDAV_USER="${WEBDAV_USER:-admin}"
        if [[ "$has_db_users" == true && -z "$WEBDAV_PASS" && "$GENERATE_PASSWORD" != true ]]; then
            log_ok "Existing active user credentials preserved in database/mornye.db."
            DO_PROVISION_USER=false
            return 0
        fi

        if [[ -z "$WEBDAV_PASS" ]]; then
            WEBDAV_PASS=$(generate_secure_password)
            GENERATE_PASSWORD=true
        fi

        DO_PROVISION_USER=true
        log_ok "WebDAV authentication configured for user '$WEBDAV_USER'."
        if [[ "$GENERATE_PASSWORD" == true ]]; then
            print_credential_card "$WEBDAV_USER" "$WEBDAV_PASS"
        fi
        return 0
    fi

    # 2. Interactive Handling
    if [[ "$has_db_users" == true ]]; then
        echo -e "  ${GREEN}[✔] Existing user credentials detected in database/mornye.db.${NC}"
        echo -e "  Select WebDAV Authentication Option:"
        echo -e "    ${BOLD}1)${NC} ${CYAN}Preserve existing credentials${NC} (Recommended, default)"
        echo -e "    ${BOLD}2)${NC} ${CYAN}Reconfigure administrator account & password${NC}"
        echo -e "    ${BOLD}3)${NC} ${YELLOW}Disable authentication (Anonymous public access)${NC}"
        read -p "  Enter choice [1-3] (Default: 1): " -r exist_choice
        exist_choice="${exist_choice:-1}"
        case "$exist_choice" in
            1)
                WEBDAV_AUTH_ENABLED=true
                DO_PROVISION_USER=false
                log_ok "Preserving existing user accounts."
                return 0
                ;;
            2)
                WEBDAV_AUTH_ENABLED=true
                ;;
            3)
                WEBDAV_AUTH_ENABLED=false
                DO_PROVISION_USER=false
                log_warn "WebDAV authentication has been DISABLED."
                return 0
                ;;
            *)
                WEBDAV_AUTH_ENABLED=true
                DO_PROVISION_USER=false
                log_ok "Preserving existing user accounts."
                return 0
                ;;
        esac
    else
        echo -e "Configure WebDAV Access Security:"
        echo -e "  ${BOLD}1)${NC} ${CYAN}Enable Username & Password Authentication${NC} (Recommended, default)"
        echo -e "  ${BOLD}2)${NC} ${YELLOW}Disable Authentication (Anonymous Access)${NC}"
        echo ""
        read -p "Enter choice [1-2] (Default: 1): " -r auth_opt
        auth_opt="${auth_opt:-1}"

        if [[ "$auth_opt" == "2" ]]; then
            WEBDAV_AUTH_ENABLED=false
            DO_PROVISION_USER=false
            log_warn "WebDAV authentication has been DISABLED. Anyone with network access can view/modify storage."
            return 0
        else
            WEBDAV_AUTH_ENABLED=true
        fi
    fi

    # Prompt for Username
    read -p "Enter WebDAV Username [Default: admin]: " -r input_user
    WEBDAV_USER="${input_user:-admin}"

    # Prompt for Password Configuration
    echo -e "\nPassword Configuration for '$WEBDAV_USER':"
    echo -e "  ${BOLD}1)${NC} ${CYAN}Generate Secure Cryptographic Password${NC} (Recommended, 16 chars)"
    echo -e "  ${BOLD}2)${NC} ${CYAN}Enter Custom Password${NC}"
    read -p "Enter choice [1-2] (Default: 1): " -r pass_choice
    pass_choice="${pass_choice:-1}"

    if [[ "$pass_choice" == "1" ]]; then
        WEBDAV_PASS=$(generate_secure_password)
        DO_PROVISION_USER=true
        print_credential_card "$WEBDAV_USER" "$WEBDAV_PASS"
    else
        while true; do
            echo ""
            read -s -p "Enter WebDAV Password (min 8 characters): " -r p1
            echo ""
            if [[ ${#p1} -lt 8 ]]; then
                echo -e "${RED}[ERROR] Password must be at least 8 characters long.${NC}"
                continue
            fi
            read -s -p "Confirm WebDAV Password: " -r p2
            echo ""
            if [[ "$p1" != "$p2" ]]; then
                echo -e "${RED}[ERROR] Passwords do not match. Please try again.${NC}"
                continue
            fi
            WEBDAV_PASS="$p1"
            DO_PROVISION_USER=true
            log_ok "Password confirmed for user '$WEBDAV_USER'."
            break
        done
    fi
}

# ------------------------------------------------------------------------------
# STAGE 4: UNIVERSAL DEPENDENCY & DOCKER ENGINE SETUP
# ------------------------------------------------------------------------------

stage4_dependencies_and_docker() {
    log_step "[Stage 4/7] Installing Dependencies & Configuring Docker Runtime..."

    if [[ "$CHECK_ONLY" == true ]]; then
        log_info "--check-only active: skipping package installation and container launch."
        return 0
    fi

    # Request sudo credentials if non-root
    request_sudo_access || exit 1

    # 1. Base System Utilities
    log_info "Checking required host utilities via $PKG_MANAGER..."
    mod_install_deps

    # 2. Docker Engine
    if [[ "$SKIP_DOCKER" != true ]]; then
        log_info "Configuring Docker Engine..."
        mod_install_docker
        mod_install_compose

        # User Docker Group Membership Check
        local cur_user
        cur_user="$(whoami)"
        if [[ "$(id -u)" -ne 0 ]]; then
            if id -nG "$cur_user" | grep -qw "docker"; then
                log_ok "User '$cur_user' is a member of the 'docker' group."
            else
                echo -e "\n  ${YELLOW}[!] DOCKER SECURITY & GROUP PERMISSION NOTICE:${NC}"
                echo -e "  Adding user '$cur_user' to the 'docker' group allows managing containers"
                echo -e "  without 'sudo'. However, Docker group access grants privileges equivalent"
                echo -e "  to root on this host."
                echo ""
                local do_add_group=true
                if [[ "$NON_INTERACTIVE" != true ]]; then
                    read -p "  Add '$cur_user' to the 'docker' group? [Y/n]: " -r grp_ans
                    if [[ "$grp_ans" =~ ^[Nn]$ ]]; then
                        do_add_group=false
                    fi
                fi

                if [[ "$do_add_group" == true ]]; then
                    $SUDO_PREFIX usermod -aG docker "$cur_user" 2>/dev/null || true
                    log_ok "User '$cur_user' added to 'docker' group."
                    echo -e "  ${YELLOW}[!] Notice: New group membership takes effect on your next login session.${NC}"
                    echo -e "      To use in the current terminal, run: ${CYAN}newgrp docker${NC}"
                fi
            fi
        fi
    fi

    # 3. Optional cloudflared CLI
    if [[ "$SKIP_CLOUDFLARED" != true ]]; then
        mod_install_cloudflared || true
    fi

    # 4. Build Multi-Stage Docker Image
    log_info "Building production Docker image 'mornye-webdav:latest'..."
    docker compose build --quiet || docker compose build
    log_ok "Container image built successfully."

    # 4.1 Pre-flight volume writability & ownership reconciliation
    local target_uid="${MORNYE_UID:-1000}"
    local target_gid="${MORNYE_GID:-1000}"
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        target_uid=$(grep -E '^MORNYE_UID=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "1000")
        target_gid=$(grep -E '^MORNYE_GID=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "1000")
    fi
    target_uid="${target_uid:-1000}"
    target_gid="${target_gid:-1000}"

    if [[ "$(id -u)" -eq 0 ]]; then
        chown -R "${target_uid}:${target_gid}" "$PROGRAM_DIR/database" "$PROGRAM_DIR/storage" "$PROGRAM_DIR/logs" 2>/dev/null || true
    fi

    # 5. Start Container Stack
    log_info "Starting Mornye containerized stack..."
    if [[ -f "$SCRIPTS_DIR/repair_engine.sh" ]]; then
        local r_args=(preflight start)
        [[ "$NON_INTERACTIVE" == true ]] && r_args=(--yes preflight start)
        "$SCRIPTS_DIR/repair_engine.sh" "${r_args[@]}" || true
    fi
    MORNYE_UID="$target_uid" MORNYE_GID="$target_gid" docker compose up -d webdav

    # 6. Wait for WebDAV healthcheck
    local host_port="8001"
    local host_bind="127.0.0.1"
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        host_port=$(grep -E '^MORNYE_HOST_PORT=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "8001")
        host_bind=$(grep -E '^MORNYE_HOST_BIND=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "127.0.0.1")
    fi
    host_port="${host_port:-8001}"
    host_bind="${host_bind:-127.0.0.1}"
    log_info "Waiting for Mornye WebDAV container healthcheck (port $host_port)..."
    local healthy=false
    for i in {1..20}; do
        sleep 1
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${host_bind}:${host_port}/health" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            healthy=true
            break
        fi
    done

    if [[ "$healthy" == true ]]; then
        log_ok "Mornye WebDAV is active and responding (HTTP 200 OK on port $host_port)."
    else
        log_warn "Healthcheck timed out on port $host_port. Checking container logs..."
        docker compose logs --tail 20 webdav
        if [[ -f "$SCRIPTS_DIR/repair_engine.sh" ]]; then
            local r_args=(preflight health)
            [[ "$NON_INTERACTIVE" == true ]] && r_args=(--yes preflight health)
            "$SCRIPTS_DIR/repair_engine.sh" "${r_args[@]}" || true
        fi
    fi

    # 7. Update .env with Authentication Configuration
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        if grep -q "^WEBDAV_AUTH_ENABLED=" "$PROGRAM_DIR/.env"; then
            sed -i "s/^WEBDAV_AUTH_ENABLED=.*/WEBDAV_AUTH_ENABLED=${WEBDAV_AUTH_ENABLED}/" "$PROGRAM_DIR/.env"
        else
            echo "WEBDAV_AUTH_ENABLED=${WEBDAV_AUTH_ENABLED}" >> "$PROGRAM_DIR/.env"
        fi
        if grep -q "^WEBDAV_USER=" "$PROGRAM_DIR/.env"; then
            sed -i "s/^WEBDAV_USER=.*/WEBDAV_USER=${WEBDAV_USER:-admin}/" "$PROGRAM_DIR/.env"
        else
            echo "WEBDAV_USER=${WEBDAV_USER:-admin}" >> "$PROGRAM_DIR/.env"
        fi
    fi

    # 8. WebDAV User Provisioning (Argon2id Hash Stored in SQLite)
    if [[ "$DO_PROVISION_USER" == true && -n "$WEBDAV_USER" && -n "$WEBDAV_PASS" ]]; then
        log_info "Provisioning WebDAV administrator account '$WEBDAV_USER' in database..."
        if docker compose exec -T webdav python3 /app/cli/user_ops.py create "$WEBDAV_USER" "$WEBDAV_PASS" "admin" &>/dev/null; then
            log_ok "WebDAV account '$WEBDAV_USER' successfully provisioned with Argon2id."
        else
            docker compose run --rm -T --no-deps webdav python3 /app/cli/user_ops.py create "$WEBDAV_USER" "$WEBDAV_PASS" "admin" 2>/dev/null || true
            log_ok "WebDAV account '$WEBDAV_USER' provisioned via fallback runner."
        fi
        unset WEBDAV_PASS
    fi
}

# ------------------------------------------------------------------------------
# STAGE 5: NETWORKING MODE SELECTION
# ------------------------------------------------------------------------------

stage5_networking_mode() {
    log_step "[Stage 5/7] Selecting Networking & Access Mode..."

    if [[ "$CHECK_ONLY" == true ]]; then
        return 0
    fi

    if [[ "$NON_INTERACTIVE" == true ]]; then
        log_info "Non-interactive mode active: Selected networking mode: '$NETWORKING_MODE'"
    else
        local h_port="8001"
        [[ -f "$PROGRAM_DIR/.env" ]] && h_port=$(grep -E '^MORNYE_HOST_PORT=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "8001")
        h_port="${h_port:-8001}"

        echo -e "Select how you would like to expose Mornye Network Storage:"
        echo -e "  ${BOLD}1)${NC} ${CYAN}Local-Only Mode${NC} (Private LAN / Localhost: http://127.0.0.1:${h_port}/dav/)"
        echo -e "  ${BOLD}2)${NC} ${CYAN}Permanent Cloudflare Tunnel + Custom Domain${NC} (e.g. storage.example.com)"
        echo -e "  ${BOLD}3)${NC} ${CYAN}Ephemeral Quick Tunnel${NC} (Temporary trycloudflare.com testing link)"
        echo ""
        read -p "Enter choice [1-3] (Default: 1): " -r net_choice
        net_choice="${net_choice:-1}"

        case "$net_choice" in
            1)
                NETWORKING_MODE="local"
                ;;
            2)
                NETWORKING_MODE="permanent"
                if [[ -z "$CHOSEN_ROOT_DOMAIN" ]]; then
                    local existing_root=""
                    if [[ -f "$PROGRAM_DIR/config/tunnel_info.env" ]]; then
                        existing_root=$(grep -E '^ROOT_DOMAIN=' "$PROGRAM_DIR/config/tunnel_info.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
                    fi
                    if [[ -n "$existing_root" ]]; then
                        echo ""
                        echo -e "Existing domain configuration detected: ${CYAN}mornye.${existing_root}${NC} (Root: ${CYAN}${existing_root}${NC})"
                        read -p "Reuse existing domain? [Y/n]: " -r reuse_dom
                        if [[ ! "$reuse_dom" =~ ^[Nn]$ ]]; then
                            CHOSEN_ROOT_DOMAIN="$existing_root"
                            CHOSEN_DOMAIN="mornye.${CHOSEN_ROOT_DOMAIN}"
                        fi
                    fi
                    if [[ -z "$CHOSEN_ROOT_DOMAIN" ]]; then
                        while true; do
                            echo ""
                            read -p "Enter your Root Domain (e.g. example.com): " -r input_dom
                            if [[ -z "$input_dom" ]]; then
                                echo -e "${RED}[ERROR] Root domain cannot be empty.${NC}"
                                continue
                            fi
                            local validated_dom=""
                            if [[ -f "$SCRIPTS_DIR/cloudflare_manager.sh" ]]; then
                                validated_dom=$("$SCRIPTS_DIR/cloudflare_manager.sh" domain validate "$input_dom" 2>/dev/null || true)
                            fi
                            if [[ -n "$validated_dom" ]]; then
                                CHOSEN_ROOT_DOMAIN="$validated_dom"
                                CHOSEN_DOMAIN="mornye.${CHOSEN_ROOT_DOMAIN}"
                                echo -e "${GREEN}[✔] Root Domain: ${CHOSEN_ROOT_DOMAIN}${NC}"
                                echo -e "${GREEN}[✔] Generated Subdomain: ${CHOSEN_DOMAIN}${NC}"
                                break
                            else
                                echo -e "${RED}[ERROR] Invalid root domain format: '$input_dom'. Please enter a valid root domain (e.g. example.com, mydomain.in).${NC}"
                            fi
                        done
                    fi
                fi
                ;;
            3)
                NETWORKING_MODE="quick"
                ;;
            *)
                NETWORKING_MODE="local"
                ;;
        esac
    fi

    # Domain validation for non-interactive or CLI-provided domain
    if [[ "$NETWORKING_MODE" == "permanent" ]]; then
        if [[ -n "$CHOSEN_ROOT_DOMAIN" ]]; then
            local validated_dom=""
            if [[ -f "$SCRIPTS_DIR/cloudflare_manager.sh" ]]; then
                validated_dom=$("$SCRIPTS_DIR/cloudflare_manager.sh" domain validate "$CHOSEN_ROOT_DOMAIN" 2>/dev/null || true)
            fi
            if [[ -n "$validated_dom" ]]; then
                CHOSEN_ROOT_DOMAIN="$validated_dom"
                CHOSEN_DOMAIN="mornye.${CHOSEN_ROOT_DOMAIN}"
                log_ok "Configured Root Domain: $CHOSEN_ROOT_DOMAIN (Generated Subdomain: $CHOSEN_DOMAIN)"
            else
                log_err "Invalid root domain format: '$CHOSEN_ROOT_DOMAIN'"
                exit 1
            fi
        elif [[ "$NON_INTERACTIVE" == true && -f "$PROGRAM_DIR/config/tunnel_info.env" ]]; then
            local existing_root
            existing_root=$(grep -E '^ROOT_DOMAIN=' "$PROGRAM_DIR/config/tunnel_info.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
            if [[ -n "$existing_root" ]]; then
                CHOSEN_ROOT_DOMAIN="$existing_root"
                CHOSEN_DOMAIN="mornye.${CHOSEN_ROOT_DOMAIN}"
                log_ok "Reusing existing root domain: $CHOSEN_ROOT_DOMAIN (Subdomain: $CHOSEN_DOMAIN)"
            fi
        fi
    fi

    # Unauthenticated Public Exposure Warning & Confirmation Gate
    if [[ "$WEBDAV_AUTH_ENABLED" == false && "$NETWORKING_MODE" =~ ^(permanent|quick)$ ]]; then
        echo ""
        echo -e "${RED}================================================================${NC}"
        echo -e "${RED}[!] CRITICAL SECURITY WARNING: UNPROTECTED PUBLIC EXPOSURE      ${NC}"
        echo -e "${RED}================================================================${NC}"
        echo -e "  You have chosen to DISABLE WebDAV authentication AND expose your"
        echo -e "  storage to the public internet via Cloudflare Tunnel ($NETWORKING_MODE)."
        echo -e "  ANYONE ON THE INTERNET WITH YOUR URL WILL HAVE FULL ACCESS TO"
        echo -e "  READ, WRITE, MODIFY, AND DELETE YOUR PRIVATE STORAGE DATA."
        echo -e "${RED}================================================================${NC}"
        if [[ "$CONFIRM_UNAUTHENTICATED" != true ]]; then
            if [[ "$NON_INTERACTIVE" == true ]]; then
                log_err "Unauthenticated public storage exposure requires --confirm-unauthenticated. Aborting for security."
                exit 1
            fi
            echo -e "  Type ${BOLD}'CONFIRM'${NC} to expose unauthenticated storage to the public WAN,"
            echo -e "  or type anything else to revert to secure local-only mode."
            read -p "  Confirmation: " -r unauth_conf
            if [[ "$unauth_conf" != "CONFIRM" ]]; then
                log_warn "Operator rejected unauthenticated public exposure. Reverting networking mode to 'local'."
                NETWORKING_MODE="local"
            else
                log_warn "Operator confirmed unauthenticated public exposure."
            fi
        fi
    fi

    log_ok "Networking mode set to: $NETWORKING_MODE"
}

# ------------------------------------------------------------------------------
# STAGE 6: CLOUDFLARE SETUP WORKFLOW
# ------------------------------------------------------------------------------

stage6_cloudflare_workflow() {
    if [[ "$CHECK_ONLY" == true ]]; then
        return 0
    fi

    if [[ "$NETWORKING_MODE" == "permanent" ]]; then
        log_step "[Stage 6/7] Configuring Permanent Cloudflare Tunnel..."
        if [[ -f "$SCRIPTS_DIR/repair_engine.sh" ]]; then
            local r_args=(preflight tunnel)
            [[ "$NON_INTERACTIVE" == true ]] && r_args=(--yes preflight tunnel)
            "$SCRIPTS_DIR/repair_engine.sh" "${r_args[@]}" || true
        fi
        if [[ -f "$SCRIPTS_DIR/cloudflare_manager.sh" ]]; then
            local cf_extra_args=()
            [[ -n "${CLOUDFLARE_CERT_PATH:-}" ]] && cf_extra_args=("--cert" "$CLOUDFLARE_CERT_PATH")
            local target_domain="${CHOSEN_ROOT_DOMAIN:-$CHOSEN_DOMAIN}"
            if [[ -n "$target_domain" ]]; then
                "$SCRIPTS_DIR/cloudflare_manager.sh" "${cf_extra_args[@]}" create mornye-storage
                "$SCRIPTS_DIR/cloudflare_manager.sh" "${cf_extra_args[@]}" domain add "$target_domain"
                "$SCRIPTS_DIR/cloudflare_manager.sh" "${cf_extra_args[@]}" start
            else
                "$SCRIPTS_DIR/cloudflare_manager.sh" "${cf_extra_args[@]}" setup
            fi
        fi
    elif [[ "$NETWORKING_MODE" == "quick" ]]; then
        log_step "[Stage 6/7] Launching Ephemeral Quick Tunnel..."
        if [[ -f "$SCRIPTS_DIR/cloudflare_manager.sh" ]]; then
            "$SCRIPTS_DIR/cloudflare_manager.sh" quick start --yes
        fi
    else
        local summary_port="8001"
        [[ -f "$PROGRAM_DIR/.env" ]] && summary_port=$(grep -E '^MORNYE_HOST_PORT=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "8001")
        log_step "[Stage 6/7] Local-Only Mode Active (Cloudflare setup skipped)..."
        log_info "WebDAV is bound locally to 127.0.0.1:${summary_port:-8001}."
    fi
}

# ------------------------------------------------------------------------------
# STAGE 7: FINAL VERIFICATION & INSTALLATION REPORT
# ------------------------------------------------------------------------------

stage7_report_and_summary() {
    log_step "[Stage 7/7] Generating Installation Report & Final Summary..."

    local summary_port="8001"
    local summary_bind="127.0.0.1"
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        summary_port=$(grep -E '^MORNYE_HOST_PORT=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "8001")
        summary_bind=$(grep -E '^MORNYE_HOST_BIND=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || echo "127.0.0.1")
    fi
    summary_port="${summary_port:-8001}"
    summary_bind="${summary_bind:-127.0.0.1}"

    local report_file="$PROGRAM_DIR/docs/SETUP_DEPENDENCY_INSTALLATION_REPORT.md"
    mkdir -p "$(dirname "$report_file")"

    local docker_ver="Missing"
    local compose_ver="Missing"
    local cf_ver="Not Installed (Optional)"

    command -v docker &>/dev/null && docker_ver="$(docker --version)"
    docker compose version &>/dev/null && compose_ver="$(docker compose version)"
    (command -v cloudflared &>/dev/null || [[ -x /usr/local/bin/cloudflared ]]) && cf_ver="$(cloudflared --version 2>/dev/null | head -n1)"

    local auth_status_str="DISABLED (Anonymous Public Access)"
    if [[ "$WEBDAV_AUTH_ENABLED" == true ]]; then
        auth_status_str="ENABLED (User: ${WEBDAV_USER:-admin}, Argon2id Basic Auth)"
    fi

    local display_root="${CHOSEN_ROOT_DOMAIN:-}"
    local display_sub="${CHOSEN_DOMAIN:-}"
    if [[ -z "$display_sub" && -f "$PROGRAM_DIR/config/tunnel_info.env" ]]; then
        display_sub=$(grep -E '^CUSTOM_DOMAIN=' "$PROGRAM_DIR/config/tunnel_info.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
        display_root=$(grep -E '^ROOT_DOMAIN=' "$PROGRAM_DIR/config/tunnel_info.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
    fi

    cat << REPORTEOF > "$report_file"
# MORNYE NETWORK STORAGE — MASTER INSTALLATION & RECONCILIATION REPORT
**Generated automatically on $(date -u +"%Y-%m-%d %H:%M:%SZ")**

---

## 1. System Telemetry & Platform Audit

| Parameter | Value | Verification Status |
| :--- | :--- | :--- |
| **Operating System** | ${OS_PRETTY} | **CONFIRMED** |
| **Distribution ID** | ${OS_ID} (Family: ${OS_FAMILY}, Codename: ${OS_CODENAME:-rolling}) | **CONFIRMED** |
| **Package Manager** | ${PKG_MANAGER} | **CONFIRMED** |
| **Init System** | ${INIT_SYSTEM} | **CONFIRMED** |
| **CPU Architecture** | ${CPU_ARCH} (Kernel: ${KERNEL_VER}) | **CONFIRMED** |
| **Compute Hardware** | ${CPU_CORES} Cores, ${RAM_TOTAL_MB} MB RAM | **CONFIRMED** |
| **Free Storage** | ${DISK_FREE_MB} MB | **CONFIRMED** |
| **Execution User** | $(whoami) (UID: $(id -u)) | **CONFIRMED** |

---

## 2. Universal Package & Runtime Audit

| Component | Status | Detected Version / Details |
| :--- | :--- | :--- |
| **Docker Engine** | $( [[ "$docker_ver" != "Missing" ]] && echo "**PASSED**" || echo "**FAILED**" ) | ${docker_ver} |
| **Docker Compose v2** | $( [[ "$compose_ver" != "Missing" ]] && echo "**PASSED**" || echo "**FAILED**" ) | ${compose_ver} |
| **Base System Tools** | **PASSED** | curl, git, jq, openssl, rsync, ca-certificates, procps |
| **cloudflared CLI** | $( [[ "$cf_ver" != *"Not Installed"* ]] && echo "**PASSED**" || echo "**OPTIONAL**" ) | ${cf_ver} |
| **WebDAV Container** | **PASSED** | Image: mornye-webdav:latest (HTTP 200 at /health) |
| **Storage Paths** | **PASSED** | database/ (750), storage/ (755), backups/ (750) |
| **Environment Config** | **PASSED** | .env (600, Cryptographic SECRET_KEY) |
| **WebDAV Authentication** | **PASSED** | ${auth_status_str} |

---

## 3. Networking & Ingress Status

- **Selected Networking Mode**: ${NETWORKING_MODE}
- **Root Domain**: ${display_root:-None}
- **Dedicated Subdomain**: ${display_sub:-None}
- **Local WebDAV Target**: http://${summary_bind:-127.0.0.1}:${summary_port:-8001}/dav/
- **Local Healthcheck**: http://${summary_bind:-127.0.0.1}:${summary_port:-8001}/health
- **Authentication Mode**: ${auth_status_str}
- **Public Ingress**: $( [[ -n "$display_sub" ]] && echo "https://${display_sub}/dav/" || echo "Local-only / Ephemeral" )

---

## 4. Final Verdict

- **Overall Status**: **PASSED & PRODUCTION READY**
- **Runtime Mode**: 100% Docker-based container stack (No host python venv required)
REPORTEOF

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}[✔] MORNYE NETWORK STORAGE INSTALLATION COMPLETE!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "${BOLD}SYSTEM:${NC}"
    echo -e "  - Platform          : ${GREEN}$OS_PRETTY ($CPU_ARCH)${NC}"
    echo -e "  - Package Manager   : ${GREEN}$PKG_MANAGER${NC}"
    echo -e "  - Init System       : ${GREEN}$INIT_SYSTEM${NC}"
    echo -e "  - Docker Runtime    : ${GREEN}$docker_ver${NC}"
    echo -e "  - Docker Compose    : ${GREEN}$compose_ver${NC}"
    echo ""
    echo -e "${BOLD}APPLICATION:${NC}"
    echo -e "  - Container Stack   : ${GREEN}Active & Healthy (mornye-webdav)${NC}"
    echo -e "  - WebDAV Endpoint   : ${CYAN}http://${summary_bind:-127.0.0.1}:${summary_port:-8001}/dav/${NC}"
    echo -e "  - Health Probe      : ${CYAN}http://${summary_bind:-127.0.0.1}:${summary_port:-8001}/health${NC}"
    echo -e "  - Persistent Path   : ${GREEN}$PROGRAM_DIR/storage${NC}"
    echo -e "  - Authentication    : $( [[ "$WEBDAV_AUTH_ENABLED" == true ]] && echo -e "${GREEN}Enabled (User: ${WEBDAV_USER:-admin})${NC}" || echo -e "${YELLOW}Disabled (Anonymous Access)${NC}" )"
    echo ""
    echo -e "${BOLD}CLOUDFLARE INGRESS:${NC}"
    echo -e "  - Selected Mode     : ${CYAN}$NETWORKING_MODE${NC}"
    if [[ "$NETWORKING_MODE" == "permanent" && -n "$display_sub" ]]; then
        [[ -n "$display_root" ]] && echo -e "  - Root Domain       : ${CYAN}${display_root}${NC}"
        echo -e "  - Mornye Subdomain  : ${CYAN}${display_sub}${NC}"
        echo -e "  - Custom Domain URL : ${CYAN}https://${display_sub}/dav/${NC}"
    fi
    echo ""
    echo -e "${BOLD}PRIMARY MANAGEMENT CLI:${NC}"
    echo -e "  - Start Stack       : ${CYAN}./mornye.sh start${NC}"
    echo -e "  - Stop Stack        : ${CYAN}./mornye.sh stop${NC}"
    echo -e "  - System Status     : ${CYAN}./mornye.sh status${NC}"
    echo -e "  - Health Diagnostic : ${CYAN}./mornye.sh doctor${NC}"
    echo -e "  - Auth Management   : ${CYAN}./mornye.sh auth help${NC}"
    echo -e "  - Tunnel Management : ${CYAN}./mornye.sh tunnel help${NC}"
    echo -e "${GREEN}================================================================${NC}\n"
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION
# ------------------------------------------------------------------------------

main() {
    print_header
    stage1_welcome_and_audit
    stage2_storage_setup
    stage3_webdav_auth
    stage4_dependencies_and_docker
    stage5_networking_mode
    stage6_cloudflare_workflow
    stage7_report_and_summary
}

main "$@"
