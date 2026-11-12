#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — PACKAGE INSTALLER: YUM (LEGACY RHEL / CENTOS)
# Module: installers/yum.sh
# Supported Distros: RHEL 7, CentOS 7, Oracle Linux 7
# ==============================================================================

set -eo pipefail

mod_detect() {
    command -v yum &>/dev/null
}

mod_refresh() {
    log_info "Refreshing YUM metadata cache..."
    $SUDO_PREFIX yum makecache --quiet
}

mod_install_deps() {
    local req_pkgs=("curl" "git" "jq" "openssl" "rsync" "ca-certificates" "procps-ng" "util-linux" "sqlite")
    local missing_pkgs=()

    for pkg in "${req_pkgs[@]}"; do
        if ! rpm -q "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log_info "Installing missing dependencies via YUM: ${missing_pkgs[*]}..."
        $SUDO_PREFIX yum install -y "${missing_pkgs[@]}"
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

    log_info "Configuring Docker YUM repository..."
    $SUDO_PREFIX yum install -y yum-utils
    $SUDO_PREFIX yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true

    log_info "Installing Docker Engine packages via YUM..."
    $SUDO_PREFIX yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true

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

    if docker compose version &>/dev/null || $SUDO_PREFIX docker compose version &>/dev/null; then
        local c_ver
        c_ver="$(docker compose version 2>/dev/null || $SUDO_PREFIX docker compose version 2>/dev/null)"
        log_ok "Docker Compose v2 ready: $c_ver"
    else
        log_err "Failed to configure Docker Compose v2 via YUM."
        return 1
    fi
}

mod_install_cloudflared() {
    if command -v cloudflared &>/dev/null || [[ -x /usr/local/bin/cloudflared ]]; then
        log_ok "cloudflared CLI already available: $(cloudflared --version 2>/dev/null | head -n1)"
        return 0
    fi

    log_info "Downloading official standalone cloudflared binary..."
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

