#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — UNIVERSAL LINUX INSTALLER: COMMON UTILITIES
# Module: installers/common.sh
# Purpose: Distribution detection, init system identification, hardware audit,
#          privilege verification, and cross-distribution helpers.
# ==============================================================================

set -eo pipefail

# ANSI Color Palette
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$PROGRAM_DIR/scripts/lib/compat.sh" ]]; then
    # shellcheck disable=SC1091
    source "$PROGRAM_DIR/scripts/lib/compat.sh"
fi

# Telemetry Globals
OS_ID="unknown"
OS_ID_LIKE=""
OS_NAME="Unknown Linux"
OS_VERSION_ID=""
OS_CODENAME=""
OS_PRETTY="Unknown Linux"
OS_FAMILY="unknown"
PKG_MANAGER="unknown"
INIT_SYSTEM="unknown"
CPU_ARCH=""
DEB_ARCH=""
RPM_ARCH=""
KERNEL_VER=""
CPU_CORES=1
RAM_TOTAL_MB=0
RAM_AVAIL_MB=0
DISK_FREE_MB=0
IS_ROOT=false
SUDO_PREFIX=""
SUDO_KEEPALIVE_PID=""

log_info() {
    echo -e "  ${BLUE}[INFO]${NC} $*"
}

log_ok() {
    echo -e "  ${GREEN}[✔]${NC} $*"
}

log_warn() {
    echo -e "  ${YELLOW}[!]${NC} $*"
}

log_err() {
    echo -e "  ${RED}[✘]${NC} $*"
}

log_step() {
    echo -e "\n${BOLD}${CYAN}$*${NC}"
}

# ------------------------------------------------------------------------------
# 1. DISTRIBUTION DETECTION ENGINE
# ------------------------------------------------------------------------------

detect_linux_distribution() {
    CPU_ARCH="$(uname -m)"
    KERNEL_VER="$(uname -r)"

    # Architecture normalization
    case "$CPU_ARCH" in
        x86_64|amd64)
            DEB_ARCH="amd64"
            RPM_ARCH="x86_64"
            ;;
        aarch64|arm64)
            DEB_ARCH="arm64"
            RPM_ARCH="aarch64"
            ;;
        armv7l|armhf)
            DEB_ARCH="armhf"
            RPM_ARCH="armhfp"
            ;;
        *)
            DEB_ARCH="$CPU_ARCH"
            RPM_ARCH="$CPU_ARCH"
            ;;
    esac

    # Inspect /etc/os-release (Standard POSIX distribution identity)
    if [ -f /etc/os-release ]; then
        # Source in subshell to avoid polluting namespace
        OS_ID="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')"
        OS_ID_LIKE="$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)"
        OS_NAME="$(grep -E '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "Linux")"
        OS_VERSION_ID="$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
        OS_CODENAME="$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
        OS_PRETTY="$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "$OS_NAME")"
    elif [ -f /etc/debian_version ]; then
        OS_ID="debian"
        OS_NAME="Debian GNU/Linux"
        OS_PRETTY="Debian $(cat /etc/debian_version)"
    elif [ -f /etc/arch-release ]; then
        OS_ID="arch"
        OS_NAME="Arch Linux"
        OS_PRETTY="Arch Linux"
    elif [ -f /etc/fedora-release ]; then
        OS_ID="fedora"
        OS_NAME="Fedora"
        OS_PRETTY="$(cat /etc/fedora-release)"
    elif [ -f /etc/alpine-release ]; then
        OS_ID="alpine"
        OS_NAME="Alpine Linux"
        OS_PRETTY="Alpine Linux $(cat /etc/alpine-release)"
    fi

    # Determine Family & Package Manager
    case "$OS_ID" in
        debian|ubuntu|kali|linuxmint|pop|raspbian|elementary|zorin|parrot)
            OS_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        arch|manjaro|endeavouros|cachyos|garuda|artix)
            OS_FAMILY="arch"
            PKG_MANAGER="pacman"
            ;;
        fedora)
            OS_FAMILY="fedora"
            PKG_MANAGER="dnf"
            ;;
        rhel|rocky|almalinux|centos|ol)
            OS_FAMILY="rhel"
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        opensuse*|sles)
            OS_FAMILY="suse"
            PKG_MANAGER="zypper"
            ;;
        alpine)
            OS_FAMILY="alpine"
            PKG_MANAGER="apk"
            ;;
        *)
            case "$OS_ID_LIKE" in
                *debian*|*ubuntu*)
                    OS_FAMILY="debian"
                    PKG_MANAGER="apt"
                    ;;
                *arch*)
                    OS_FAMILY="arch"
                    PKG_MANAGER="pacman"
                    ;;
                *rhel*|*fedora*|*centos*)
                    OS_FAMILY="rhel"
                    if command -v dnf >/dev/null 2>&1; then
                        PKG_MANAGER="dnf"
                    else
                        PKG_MANAGER="yum"
                    fi
                    ;;
                *suse*)
                    OS_FAMILY="suse"
                    PKG_MANAGER="zypper"
                    ;;
                *)
                    # Fallback detection based on available package manager binaries
                    if command -v apt-get >/dev/null 2>&1; then
                        OS_FAMILY="debian"
                        PKG_MANAGER="apt"
                    elif command -v pacman >/dev/null 2>&1; then
                        OS_FAMILY="arch"
                        PKG_MANAGER="pacman"
                    elif command -v dnf >/dev/null 2>&1; then
                        OS_FAMILY="fedora"
                        PKG_MANAGER="dnf"
                    elif command -v yum >/dev/null 2>&1; then
                        OS_FAMILY="rhel"
                        PKG_MANAGER="yum"
                    elif command -v zypper >/dev/null 2>&1; then
                        OS_FAMILY="suse"
                        PKG_MANAGER="zypper"
                    elif command -v apk >/dev/null 2>&1; then
                        OS_FAMILY="alpine"
                        PKG_MANAGER="apk"
                    fi
                    ;;
            esac
            ;;
    esac

    # Determine Init System
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif [ -d /run/openrc ] || command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    elif [ -f /sbin/init ] && ls -l /sbin/init 2>/dev/null | grep -q "systemd"; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="generic"
    fi
}

# ------------------------------------------------------------------------------
# 2. PRIVILEGES & SUDO HANDLING
# ------------------------------------------------------------------------------

audit_privileges() {
    local uid
    uid="$(id -u)"
    if [[ "$uid" -eq 0 ]]; then
        IS_ROOT=true
        SUDO_PREFIX=""
    else
        IS_ROOT=false
        SUDO_PREFIX="sudo"
        if ! command -v sudo &>/dev/null; then
            log_err "Non-root execution detected and 'sudo' is not installed."
            log_err "Please run as root or install sudo."
            return 1
        fi
    fi
    return 0
}

request_sudo_access() {
    if [[ "$IS_ROOT" == true ]]; then
        return 0
    fi

    if sudo -n true 2>/dev/null; then
        return 0
    fi

    if [[ "${NON_INTERACTIVE:-false}" == true ]] && [[ ! -t 0 ]]; then
        log_warn "Sudo authorization required in non-interactive session."
        if ! sudo -n true 2>/dev/null; then
            log_err "Sudo password required but stdin is non-interactive. Cannot proceed."
            return 1
        fi
        return 0
    fi

    echo -e "${YELLOW}[!] Root authorization required for package and container configuration.${NC}"
    echo -e "[*] Requesting sudo credentials..."
    if ! sudo -v; then
        log_err "Sudo authentication failed."
        return 1
    fi

    # Start background keepalive
    (while true; do sudo -n true 2>/dev/null; sleep 45; kill -0 "$$" 2>/dev/null || exit; done) &
    SUDO_KEEPALIVE_PID=$!
    return 0
}

cleanup_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 3. SYSTEM REQUIREMENTS & HARDWARE AUDIT
# ------------------------------------------------------------------------------

audit_system_resources() {
    # CPU Cores
    if command -v nproc &>/dev/null; then
        CPU_CORES=$(nproc)
    elif [[ -f /proc/cpuinfo ]]; then
        CPU_CORES=$(grep -c '^processor' /proc/cpuinfo || echo 1)
    fi

    # RAM (in MB)
    if [[ -f /proc/meminfo ]]; then
        local total_kb avail_kb
        total_kb=$(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}')
        avail_kb=$(grep -E '^MemAvailable:' /proc/meminfo | awk '{print $2}' || true)
        RAM_TOTAL_MB=$(( total_kb / 1024 ))
        if [[ -n "$avail_kb" ]]; then
            RAM_AVAIL_MB=$(( avail_kb / 1024 ))
        else
            RAM_AVAIL_MB=$RAM_TOTAL_MB
        fi
    fi

    # Disk Space (Target directory)
    local check_dir="${1:-.}"
    if command -v df &>/dev/null; then
        local free_kb
        free_kb=$(df -k "$check_dir" | awk 'NR==2 {print $4}')
        DISK_FREE_MB=$(( free_kb / 1024 ))
    fi
}

check_internet_access() {
    if curl -s --connect-timeout 4 -I "https://cloudflare.com" >/dev/null 2>&1 \
       || curl -s --connect-timeout 4 -I "https://github.com" >/dev/null 2>&1 \
       || curl -s --connect-timeout 4 -I "https://1.1.1.1" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 4. SERVICE MANAGEMENT ABSTRACTION (systemd vs OpenRC vs Direct)
# ------------------------------------------------------------------------------

service_enable_and_start() {
    local svc_name="$1"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        $SUDO_PREFIX systemctl enable "$svc_name" 2>/dev/null || true
        $SUDO_PREFIX systemctl start "$svc_name" 2>/dev/null || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        $SUDO_PREFIX rc-update add "$svc_name" default 2>/dev/null || true
        $SUDO_PREFIX rc-service "$svc_name" start 2>/dev/null || true
    elif command -v service &>/dev/null; then
        $SUDO_PREFIX service "$svc_name" start 2>/dev/null || true
    fi
}

service_is_active() {
    local svc_name="$1"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active "$svc_name" &>/dev/null
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc_name" status &>/dev/null
    elif command -v service &>/dev/null; then
        service "$svc_name" status &>/dev/null
    else
        return 1
    fi
}
