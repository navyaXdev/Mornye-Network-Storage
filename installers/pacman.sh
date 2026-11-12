#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — PACKAGE INSTALLER: PACMAN (ARCH / MANJARO / ENDEAVOUR)
# Module: installers/pacman.sh
# Supported Distros: Arch Linux, Manjaro, EndeavourOS, CachyOS, Garuda
# ==============================================================================

set -eo pipefail

mod_detect() {
    command -v pacman &>/dev/null
}

mod_refresh() {
    log_info "Refreshing Pacman database..."
    $SUDO_PREFIX pacman -Sy --noconfirm --quiet
}

mod_install_deps() {
    local req_pkgs=("curl" "git" "jq" "openssl" "rsync" "ca-certificates" "procps-ng" "util-linux" "sqlite")
    local missing_pkgs=()

    for pkg in "${req_pkgs[@]}"; do
        if ! pacman -Qi "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log_info "Installing required packages via Pacman: ${missing_pkgs[*]}..."
        $SUDO_PREFIX pacman -S --noconfirm --needed "${missing_pkgs[@]}"
        log_ok "Base utilities installed successfully."
    else
        log_ok "All required base utilities already installed."
    fi
}

mod_install_docker() {
    if command -v docker &>/dev/null && (docker info >/dev/null 2>&1 || $SUDO_PREFIX docker info >/dev/null 2>&1); then
        log_ok "Docker Engine already operational: $(docker --version)"
        return 0
    fi

    log_info "Installing Docker Engine via Pacman..."
    $SUDO_PREFIX pacman -S --noconfirm --needed docker

    service_enable_and_start "docker"
    log_ok "Docker Engine installed and service initialized."
}

mod_install_compose() {
    if docker compose version &>/dev/null || $SUDO_PREFIX docker compose version &>/dev/null; then
        local c_ver
        c_ver="$(docker compose version 2>/dev/null || $SUDO_PREFIX docker compose version 2>/dev/null)"
        log_ok "Docker Compose v2 operational: $c_ver"
        return 0
    fi

    log_info "Installing Docker Compose v2 via Pacman..."
    if $SUDO_PREFIX pacman -S --noconfirm --needed docker-compose 2>/dev/null; then
        # On Arch, docker-compose package provides both /usr/bin/docker-compose and CLI plugin
        if [[ -x /usr/bin/docker-compose ]] && [[ ! -f /usr/local/lib/docker/cli-plugins/docker-compose ]]; then
            $SUDO_PREFIX mkdir -p /usr/local/lib/docker/cli-plugins
            $SUDO_PREFIX ln -sf /usr/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
        fi
    else
        log_info "Downloading official Docker Compose standalone plugin..."
        local c_arch="$CPU_ARCH"
        case "$c_arch" in
            amd64) c_arch="x86_64" ;;
            arm64) c_arch="aarch64" ;;
        esac
        local plugin_url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${c_arch}"
        local dest_plugin="/usr/local/lib/docker/cli-plugins/docker-compose"
        $SUDO_PREFIX mkdir -p /usr/local/lib/docker/cli-plugins /usr/local/bin
        $SUDO_PREFIX curl -fsSL "$plugin_url" -o "$dest_plugin"
        $SUDO_PREFIX chmod +x "$dest_plugin"
        $SUDO_PREFIX ln -sf "$dest_plugin" /usr/local/bin/docker-compose
    fi

    if docker compose version &>/dev/null || $SUDO_PREFIX docker compose version &>/dev/null; then
        local c_ver
        c_ver="$(docker compose version 2>/dev/null || $SUDO_PREFIX docker compose version 2>/dev/null)"
        log_ok "Docker Compose v2 ready: $c_ver"
    else
        log_err "Failed to configure Docker Compose v2 on Arch Linux."
        return 1
    fi
}

mod_install_cloudflared() {
    if command -v cloudflared &>/dev/null || [[ -x /usr/local/bin/cloudflared ]]; then
        log_ok "cloudflared CLI already available: $(cloudflared --version 2>/dev/null | head -n1)"
        return 0
    fi

    log_info "Installing cloudflared via Pacman repository..."
    if $SUDO_PREFIX pacman -S --noconfirm --needed cloudflared 2>/dev/null; then
        log_ok "cloudflared installed via Arch official repository."
        return 0
    fi

    log_info "Fallback: downloading official cloudflared binary from Cloudflare release..."
    local cf_arch="amd64"
    case "$CPU_ARCH" in
        aarch64|arm64) cf_arch="arm64" ;;
        armv7l|armhf) cf_arch="arm" ;;
    esac
    local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    if $SUDO_PREFIX curl -fsSL "$cf_url" -o /usr/local/bin/cloudflared; then
        $SUDO_PREFIX chmod +x /usr/local/bin/cloudflared
        log_ok "cloudflared installed successfully: $(/usr/local/bin/cloudflared --version 2>/dev/null | head -n1)"
    else
        log_warn "Failed to download cloudflared binary. Quick Tunnel will remain unavailable."
        return 1
    fi
}

