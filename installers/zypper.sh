#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — PACKAGE INSTALLER: ZYPPER (OPENSUSE / SUSE)
# Module: installers/zypper.sh
# Supported Distros: openSUSE Leap, openSUSE Tumbleweed, SLES
# ==============================================================================

set -eo pipefail

mod_detect() {
    command -v zypper &>/dev/null
}

mod_refresh() {
    log_info "Refreshing Zypper repositories..."
    $SUDO_PREFIX zypper --non-interactive refresh --quiet
}

mod_install_deps() {
    local req_pkgs=("curl" "git" "jq" "openssl" "rsync" "ca-certificates" "procps" "util-linux" "sqlite3")
    local missing_pkgs=()

    for pkg in "${req_pkgs[@]}"; do
        if ! rpm -q "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log_info "Installing missing dependencies via Zypper: ${missing_pkgs[*]}..."
        $SUDO_PREFIX zypper --non-interactive install --no-recommends "${missing_pkgs[@]}"
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

    log_info "Installing Docker Engine via Zypper..."
    $SUDO_PREFIX zypper --non-interactive install --no-recommends docker

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

    log_info "Resolving Docker Compose v2 via Zypper..."
    if $SUDO_PREFIX zypper --non-interactive install --no-recommends docker-compose 2>/dev/null; then
        if [[ -x /usr/bin/docker-compose ]]; then
            $SUDO_PREFIX mkdir -p /usr/local/lib/docker/cli-plugins
            $SUDO_PREFIX ln -sf /usr/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
        fi
    else
        log_info "Installing official Docker Compose standalone plugin..."
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
        log_err "Failed to configure Docker Compose v2 via Zypper."
        return 1
    fi
}

mod_install_cloudflared() {
    if command -v cloudflared &>/dev/null || [[ -x /usr/local/bin/cloudflared ]]; then
        log_ok "cloudflared CLI already available: $(cloudflared --version 2>/dev/null | head -n1)"
        return 0
    fi

    log_info "Installing official standalone cloudflared binary..."
    local cf_arch="amd64"
    case "$CPU_ARCH" in
        aarch64|arm64) cf_arch="arm64" ;;
    esac
    local bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    if $SUDO_PREFIX curl -fsSL "$bin_url" -o /usr/local/bin/cloudflared; then
        $SUDO_PREFIX chmod +x /usr/local/bin/cloudflared
        log_ok "cloudflared installed successfully: $(/usr/local/bin/cloudflared --version 2>/dev/null | head -n1)"
    else
        log_warn "Failed to install cloudflared. Quick Tunnel will remain unavailable."
        return 1
    fi
}

