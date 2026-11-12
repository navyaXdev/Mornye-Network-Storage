#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — CENTRALIZED SYSTEM COMPATIBILITY ENGINE
# Module: scripts/lib/compat.sh
# Purpose: Single source of truth for distribution detection, package management,
#          init system abstraction, user/privilege boundaries, and telemetry.
#
# Supported Distributions:
#   - Debian 12 (Bookworm), Debian 13 (Trixie), Ubuntu 20.04/22.04/24.04/rolling,
#     Kali Linux, Linux Mint, Pop!_OS, Parrot OS (APT)
#   - Arch Linux, Manjaro, EndeavourOS, CachyOS (Pacman)
#   - Fedora 39, 40, 41 (DNF)
#   - RHEL 8/9, Rocky Linux 8/9, AlmaLinux 8/9, CentOS Stream (DNF/YUM)
#   - openSUSE Leap 15.6, openSUSE Tumbleweed (Zypper)
#   - Alpine Linux 3.19, 3.20, Edge (APK)
# ==============================================================================

# Guard against multiple inclusions
if [[ -n "${MORNYE_COMPAT_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
MORNYE_COMPAT_LOADED=1

# ANSI Color Palette
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_PURPLE='\033[0;35m'
COLOR_CYAN='\033[0;36m'
COLOR_BOLD='\033[1m'
COLOR_NC='\033[0m'

# Telemetry & Identity Globals
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

CURRENT_USER=""
CURRENT_UID=1000
CURRENT_GID=1000
REAL_USER=""
REAL_USER_HOME=""
IS_ROOT=false
SUDO_PREFIX=""
SUDO_KEEPALIVE_PID=""

# Logging Helpers
log_compat_info()  { echo -e "  ${COLOR_BLUE}[INFO]${COLOR_NC} $*"; }
log_compat_ok()    { echo -e "  ${COLOR_GREEN}[✔]${COLOR_NC} $*"; }
log_compat_warn()  { echo -e "  ${COLOR_YELLOW}[!]${COLOR_NC} $*"; }
log_compat_err()   { echo -e "  ${COLOR_RED}[✘]${COLOR_NC} $*"; }
log_compat_step()  { echo -e "\n${COLOR_BOLD}${COLOR_CYAN}$*${COLOR_NC}"; }

# ------------------------------------------------------------------------------
# 1. DISTRIBUTION & ARCHITECTURE DETECTION
# ------------------------------------------------------------------------------

compat_detect_system() {
    CPU_ARCH="$(uname -m 2>/dev/null || echo "unknown")"
    KERNEL_VER="$(uname -r 2>/dev/null || echo "unknown")"

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
        i386|i686)
            DEB_ARCH="i386"
            RPM_ARCH="i686"
            ;;
        *)
            DEB_ARCH="$CPU_ARCH"
            RPM_ARCH="$CPU_ARCH"
            ;;
    esac

    # Inspect /etc/os-release
    if [[ -f /etc/os-release ]]; then
        OS_ID="$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'"'" | tr '[:upper:]' '[:lower:]' || echo "unknown")"
        OS_ID_LIKE="$(grep -E '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'"'" | tr '[:upper:]' '[:lower:]' || true)"
        OS_NAME="$(grep -E '^NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'"'" || echo "Linux")"
        OS_VERSION_ID="$(grep -E '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'"'" || true)"
        OS_CODENAME="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'"'" || true)"
        OS_PRETTY="$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"'"'" || echo "$OS_NAME")"
    elif [[ -f /etc/debian_version ]]; then
        OS_ID="debian"
        OS_NAME="Debian GNU/Linux"
        OS_PRETTY="Debian $(cat /etc/debian_version 2>/dev/null)"
        OS_FAMILY="debian"
        PKG_MANAGER="apt"
    elif [[ -f /etc/arch-release ]]; then
        OS_ID="arch"
        OS_NAME="Arch Linux"
        OS_PRETTY="Arch Linux"
        OS_FAMILY="arch"
        PKG_MANAGER="pacman"
    elif [[ -f /etc/fedora-release ]]; then
        OS_ID="fedora"
        OS_NAME="Fedora"
        OS_PRETTY="$(cat /etc/fedora-release 2>/dev/null)"
        OS_FAMILY="fedora"
        PKG_MANAGER="dnf"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="rhel"
        OS_NAME="Red Hat Enterprise Linux"
        OS_PRETTY="$(cat /etc/redhat-release 2>/dev/null)"
        OS_FAMILY="rhel"
        PKG_MANAGER="dnf"
    elif [[ -f /etc/SuSE-release ]] || [[ -f /etc/suse-release ]]; then
        OS_ID="opensuse"
        OS_NAME="openSUSE"
        OS_PRETTY="openSUSE"
        OS_FAMILY="suse"
        PKG_MANAGER="zypper"
    elif [[ -f /etc/alpine-release ]]; then
        OS_ID="alpine"
        OS_NAME="Alpine Linux"
        OS_PRETTY="Alpine Linux $(cat /etc/alpine-release 2>/dev/null)"
        OS_FAMILY="alpine"
        PKG_MANAGER="apk"
    fi

    # Determine Family & Primary Package Manager
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
            if command -v dnf &>/dev/null; then
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
            # Fallback to ID_LIKE inspection
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
                    if command -v dnf &>/dev/null; then
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
                    # Binary existence heuristics
                    if command -v apt-get &>/dev/null; then
                        OS_FAMILY="debian"
                        PKG_MANAGER="apt"
                    elif command -v pacman &>/dev/null; then
                        OS_FAMILY="arch"
                        PKG_MANAGER="pacman"
                    elif command -v dnf &>/dev/null; then
                        OS_FAMILY="fedora"
                        PKG_MANAGER="dnf"
                    elif command -v yum &>/dev/null; then
                        OS_FAMILY="rhel"
                        PKG_MANAGER="yum"
                    elif command -v zypper &>/dev/null; then
                        OS_FAMILY="suse"
                        PKG_MANAGER="zypper"
                    elif command -v apk &>/dev/null; then
                        OS_FAMILY="alpine"
                        PKG_MANAGER="apk"
                    else
                        OS_FAMILY="generic"
                        PKG_MANAGER="unknown"
                    fi
                    ;;
            esac
            ;;
    esac

    # Determine Init System
    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
        INIT_SYSTEM="systemd"
    elif [[ -d /run/openrc ]] || command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    elif [[ -f /sbin/init ]] && ls -l /sbin/init 2>/dev/null | grep -q "systemd"; then
        INIT_SYSTEM="systemd"
    elif command -v service &>/dev/null; then
        INIT_SYSTEM="sysvinit"
    else
        INIT_SYSTEM="generic"
    fi

    compat_detect_user
}

# ------------------------------------------------------------------------------
# 2. USER & PRIVILEGE DISCOVERY
# ------------------------------------------------------------------------------

compat_detect_user() {
    CURRENT_USER="$(id -un 2>/dev/null || whoami 2>/dev/null || echo "unknown")"
    CURRENT_UID="$(id -u 2>/dev/null || echo 1000)"
    CURRENT_GID="$(id -g 2>/dev/null || echo 1000)"

    if [[ "$CURRENT_UID" -eq 0 ]]; then
        IS_ROOT=true
        SUDO_PREFIX=""
        # If running via sudo, determine original invoking user
        if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            REAL_USER="$SUDO_USER"
            REAL_USER_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$SUDO_USER")"
            REAL_UID="$(id -u "$SUDO_USER" 2>/dev/null || echo 1000)"
            REAL_GID="$(id -g "$SUDO_USER" 2>/dev/null || echo 1000)"
            TARGET_CONTAINER_UID="$REAL_UID"
            TARGET_CONTAINER_GID="$REAL_GID"
        else
            REAL_USER="root"
            REAL_USER_HOME="${HOME:-/root}"
            REAL_UID=0
            REAL_GID=0
            TARGET_CONTAINER_UID="${MORNYE_UID:-1000}"
            TARGET_CONTAINER_GID="${MORNYE_GID:-1000}"
        fi
    else
        IS_ROOT=false
        SUDO_PREFIX="sudo"
        REAL_USER="$CURRENT_USER"
        REAL_USER_HOME="${HOME:-/home/$CURRENT_USER}"
        REAL_UID="$CURRENT_UID"
        REAL_GID="$CURRENT_GID"
        TARGET_CONTAINER_UID="$CURRENT_UID"
        TARGET_CONTAINER_GID="$CURRENT_GID"
    fi

    export CURRENT_USER CURRENT_UID CURRENT_GID REAL_USER REAL_USER_HOME REAL_UID REAL_GID TARGET_CONTAINER_UID TARGET_CONTAINER_GID IS_ROOT SUDO_PREFIX
}

# ------------------------------------------------------------------------------
# 2.1 CLOUDFLARE ORIGIN CERTIFICATE & TOKEN VALIDATION
# ------------------------------------------------------------------------------

# Validate Cloudflare Origin Certificate / Login Token
# Returns 0 if valid origin cert / token, 1 otherwise
compat_validate_origin_cert() {
    local cert_file="$1"
    [[ -z "$cert_file" ]] && return 1

    # Check if readable directly
    if [[ -f "$cert_file" && -r "$cert_file" ]]; then
        [[ ! -s "$cert_file" ]] && return 1 # Reject empty files
        # Strictly reject tunnel credentials JSON files
        if grep -q '"AccountTag"' "$cert_file" 2>/dev/null && grep -q '"TunnelSecret"' "$cert_file" 2>/dev/null; then
            return 1
        fi
        # Validate modern token or legacy PEM headers
        if grep -qE "BEGIN (ARGO TUNNEL TOKEN|CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY)" "$cert_file" 2>/dev/null; then
            return 0
        fi
        # Validate raw JSON token payload
        if grep -q '"apiToken"' "$cert_file" 2>/dev/null && grep -q '"accountID"' "$cert_file" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    # If file exists on host but requires root read privileges
    if command -v sudo &>/dev/null && sudo -n test -f "$cert_file" 2>/dev/null; then
        local sz
        sz=$(sudo -n wc -c < "$cert_file" 2>/dev/null || echo 0)
        [[ "$sz" -eq 0 ]] && return 1
        if sudo -n grep -q '"AccountTag"' "$cert_file" 2>/dev/null && sudo -n grep -q '"TunnelSecret"' "$cert_file" 2>/dev/null; then
            return 1
        fi
        if sudo -n grep -qE "BEGIN (ARGO TUNNEL TOKEN|CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY)" "$cert_file" 2>/dev/null; then
            return 0
        fi
        if sudo -n grep -q '"apiToken"' "$cert_file" 2>/dev/null && sudo -n grep -q '"accountID"' "$cert_file" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    return 1
}

# Search standard candidate locations for valid Cloudflare origin certificate
compat_find_origin_cert() {
    local explicit_path="${CLOUDFLARE_CERT_PATH:-}"
    if [[ -n "$explicit_path" ]]; then
        if compat_validate_origin_cert "$explicit_path"; then
            echo "$explicit_path"
            return 0
        else
            return 1
        fi
    fi

    local candidates=(
        "${HOME}/.cloudflared/cert.pem"
        "${REAL_USER_HOME:-}/.cloudflared/cert.pem"
        "/root/.cloudflared/cert.pem"
        "/etc/cloudflared/cert.pem"
        "${PROGRAM_DIR:-.}/config/cert.pem"
    )

    for c in "${candidates[@]}"; do
        if [[ -n "$c" ]] && compat_validate_origin_cert "$c"; then
            echo "$c"
            return 0
        fi
    done

    return 1
}

compat_check_root() {
    compat_detect_user
    [[ "$IS_ROOT" == true ]]
}

compat_request_sudo() {
    if [[ "$IS_ROOT" == true ]]; then
        return 0
    fi

    if ! command -v sudo &>/dev/null; then
        log_compat_err "'sudo' is not installed on this system. Please run as root or install sudo."
        return 1
    fi

    if sudo -n true 2>/dev/null; then
        return 0
    fi

    if [[ "${NON_INTERACTIVE:-false}" == true || "${DEBIAN_FRONTEND:-}" == "noninteractive" ]] && [[ ! -t 0 ]]; then
        if ! sudo -n true 2>/dev/null; then
            log_compat_err "Sudo password required but standard input is non-interactive."
            return 1
        fi
        return 0
    fi

    echo -e "${COLOR_YELLOW}[!] Administrative privileges required for system configuration.${COLOR_NC}"
    echo -e "[*] Requesting sudo credentials..."
    if ! sudo -v; then
        log_compat_err "Sudo authorization failed."
        return 1
    fi

    # Background keepalive while script runs
    (while true; do sudo -n true 2>/dev/null; sleep 45; kill -0 "$$" 2>/dev/null || exit; done) &
    SUDO_KEEPALIVE_PID=$!
    return 0
}

compat_cleanup_sudo() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

compat_is_in_docker_group() {
    local target_user="${1:-$CURRENT_USER}"
    if id -nG "$target_user" 2>/dev/null | grep -qw "docker"; then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# 3. UNIFIED PACKAGE MANAGEMENT ABSTRACTION
# ------------------------------------------------------------------------------

compat_pkg_refresh() {
    case "$PKG_MANAGER" in
        apt)
            $SUDO_PREFIX apt-get update -y --quiet
            ;;
        pacman)
            $SUDO_PREFIX pacman -Sy --noconfirm --quiet
            ;;
        dnf)
            $SUDO_PREFIX dnf makecache --quiet
            ;;
        yum)
            $SUDO_PREFIX yum makecache --quiet
            ;;
        zypper)
            $SUDO_PREFIX zypper --quiet refresh
            ;;
        apk)
            $SUDO_PREFIX apk update --quiet
            ;;
        *)
            log_compat_warn "Unknown package manager: cannot refresh indices."
            return 1
            ;;
    esac
}

compat_pkg_has_candidate() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apt)
            local cand
            cand=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')
            [[ -n "$cand" && "$cand" != "(none)" ]]
            ;;
        pacman)
            pacman -Si "$pkg" &>/dev/null
            ;;
        dnf)
            dnf list --available "$pkg" &>/dev/null
            ;;
        yum)
            yum list available "$pkg" &>/dev/null
            ;;
        zypper)
            zypper search --match-exact "$pkg" &>/dev/null
            ;;
        apk)
            apk info -e "$pkg" &>/dev/null || apk search -e "$pkg" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

compat_pkg_is_installed() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apt)
            dpkg -s "$pkg" 2>/dev/null | grep -q "Status: install ok installed"
            ;;
        pacman)
            pacman -Q "$pkg" &>/dev/null
            ;;
        dnf|yum)
            rpm -q "$pkg" &>/dev/null
            ;;
        zypper)
            rpm -q "$pkg" &>/dev/null
            ;;
        apk)
            apk info -e "$pkg" &>/dev/null
            ;;
        *)
            command -v "$pkg" &>/dev/null
            ;;
    esac
}

compat_pkg_install() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0

    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive $SUDO_PREFIX apt-get install -y --no-install-recommends "${pkgs[@]}"
            ;;
        pacman)
            $SUDO_PREFIX pacman -S --noconfirm --needed "${pkgs[@]}"
            ;;
        dnf)
            $SUDO_PREFIX dnf install -y "${pkgs[@]}"
            ;;
        yum)
            $SUDO_PREFIX yum install -y "${pkgs[@]}"
            ;;
        zypper)
            $SUDO_PREFIX zypper --non-interactive install --no-recommends "${pkgs[@]}"
            ;;
        apk)
            $SUDO_PREFIX apk add --no-cache "${pkgs[@]}"
            ;;
        *)
            log_compat_err "Cannot install packages: Package manager '$PKG_MANAGER' not supported."
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 4. UNIFIED INIT & SERVICE MANAGEMENT ABSTRACTION
# ------------------------------------------------------------------------------

compat_service_is_active() {
    local svc="$1"
    case "$INIT_SYSTEM" in
        systemd)
            systemctl is-active --quiet "$svc" 2>/dev/null
            ;;
        openrc)
            rc-service "$svc" status 2>/dev/null | grep -q "started"
            ;;
        sysvinit)
            service "$svc" status &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

compat_service_start() {
    local svc="$1"
    case "$INIT_SYSTEM" in
        systemd)
            $SUDO_PREFIX systemctl start "$svc" 2>/dev/null || true
            ;;
        openrc)
            $SUDO_PREFIX rc-service "$svc" start 2>/dev/null || true
            ;;
        sysvinit)
            $SUDO_PREFIX service "$svc" start 2>/dev/null || true
            ;;
    esac
}

compat_service_stop() {
    local svc="$1"
    case "$INIT_SYSTEM" in
        systemd)
            $SUDO_PREFIX systemctl stop "$svc" 2>/dev/null || true
            ;;
        openrc)
            $SUDO_PREFIX rc-service "$svc" stop 2>/dev/null || true
            ;;
        sysvinit)
            $SUDO_PREFIX service "$svc" stop 2>/dev/null || true
            ;;
    esac
}

compat_service_restart() {
    local svc="$1"
    case "$INIT_SYSTEM" in
        systemd)
            $SUDO_PREFIX systemctl restart "$svc" 2>/dev/null || true
            ;;
        openrc)
            $SUDO_PREFIX rc-service "$svc" restart 2>/dev/null || true
            ;;
        sysvinit)
            $SUDO_PREFIX service "$svc" restart 2>/dev/null || true
            ;;
    esac
}

compat_service_enable() {
    local svc="$1"
    case "$INIT_SYSTEM" in
        systemd)
            $SUDO_PREFIX systemctl enable "$svc" 2>/dev/null || true
            ;;
        openrc)
            $SUDO_PREFIX rc-update add "$svc" default 2>/dev/null || true
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 5. HARDWARE & WAN TELEMETRY
# ------------------------------------------------------------------------------

compat_audit_resources() {
    local check_dir="${1:-.}"

    # Compute Cores
    if command -v nproc &>/dev/null; then
        CPU_CORES=$(nproc)
    elif [[ -f /proc/cpuinfo ]]; then
        CPU_CORES=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    else
        CPU_CORES=1
    fi

    # RAM (in MB)
    if [[ -f /proc/meminfo ]]; then
        local tot_kb avail_kb
        tot_kb=$(grep -E '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')
        avail_kb=$(grep -E '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}' || true)
        if [[ -n "$tot_kb" && "$tot_kb" =~ ^[0-9]+$ ]]; then
            RAM_TOTAL_MB=$(( tot_kb / 1024 ))
        fi
        if [[ -n "$avail_kb" && "$avail_kb" =~ ^[0-9]+$ ]]; then
            RAM_AVAIL_MB=$(( avail_kb / 1024 ))
        else
            RAM_AVAIL_MB="$RAM_TOTAL_MB"
        fi
    fi

    # Free Disk Space (MB)
    if command -v df &>/dev/null; then
        local free_kb
        free_kb=$(df -k "$check_dir" 2>/dev/null | awk 'NR==2 {print $4}' || true)
        if [[ -n "$free_kb" && "$free_kb" =~ ^[0-9]+$ ]]; then
            DISK_FREE_MB=$(( free_kb / 1024 ))
        fi
    fi
}

compat_check_wan() {
    if curl -s --connect-timeout 3 -I "https://1.1.1.1" >/dev/null 2>&1 \
       || curl -s --connect-timeout 3 -I "https://github.com" >/dev/null 2>&1 \
       || curl -s --connect-timeout 3 -I "https://cloudflare.com" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Auto-execute detection on inclusion
compat_detect_system

