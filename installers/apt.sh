#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — PACKAGE INSTALLER: APT (DEBIAN / UBUNTU / KALI)
# Module: installers/apt.sh
# Supported Distros: Debian 12/13, Ubuntu 22.04/24.04/26.04, Kali, Mint, Pop!_OS
# ==============================================================================

set -eo pipefail

has_apt_candidate() {
    local pkg="$1"
    local cand
    cand=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')
    if [[ -n "$cand" && "$cand" != "(none)" ]]; then
        return 0
    fi
    return 1
}

mod_detect() {
    command -v apt-get &>/dev/null && command -v apt-cache &>/dev/null
}

mod_refresh() {
    log_info "Refreshing APT package indices..."
    $SUDO_PREFIX apt-get update -y --quiet
}

mod_install_deps() {
    local req_tools=("curl" "git" "jq" "openssl" "rsync")
    local req_pkgs=("ca-certificates" "procps")
    local missing_pkgs=()

    for tool in "${req_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_pkgs+=("$tool")
        fi
    done

    # UUID generation tool
    if ! command -v uuidgen &>/dev/null; then
        missing_pkgs+=("uuid-runtime")
    fi

    # Core certs
    if [[ ! -f /etc/ssl/certs/ca-certificates.crt ]]; then
        missing_pkgs+=("ca-certificates")
    fi

    # SQLite CLI
    if ! command -v sqlite3 &>/dev/null; then
        missing_pkgs+=("sqlite3")
    fi

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log_info "Installing missing system utilities: ${missing_pkgs[*]}..."
        DEBIAN_FRONTEND=noninteractive $SUDO_PREFIX apt-get install -y --no-install-recommends "${missing_pkgs[@]}"
        log_ok "Base utilities installed successfully."
    else
        log_ok "All required base utilities already installed."
    fi
    return 0
}

mod_install_docker() {
    if command -v docker &>/dev/null && (docker info >/dev/null 2>&1 || $SUDO_PREFIX docker info >/dev/null 2>&1); then
        log_ok "Docker Engine already operational: $(docker --version)"
        return 0
    fi

    log_info "Resolving Docker Engine package for Debian/Ubuntu family..."
    local docker_pkgs=()

    if has_apt_candidate "docker.io"; then
        docker_pkgs+=("docker.io")
        if has_apt_candidate "docker-cli"; then
            docker_pkgs+=("docker-cli")
        fi
    elif has_apt_candidate "docker-ce"; then
        docker_pkgs+=("docker-ce" "docker-ce-cli" "containerd.io")
    fi

    if [[ ${#docker_pkgs[@]} -gt 0 ]]; then
        log_info "Installing '${docker_pkgs[*]}' via APT..."
        DEBIAN_FRONTEND=noninteractive $SUDO_PREFIX apt-get install -y --no-install-recommends "${docker_pkgs[@]}"
    else
        log_info "Configuring official Docker repository..."
        $SUDO_PREFIX install -m 0755 -d /etc/apt/keyrings
        local distro_base="debian"
        if [[ "$OS_ID" == "ubuntu" ]]; then
            distro_base="ubuntu"
        fi
        $SUDO_PREFIX curl -fsSL "https://download.docker.com/linux/${distro_base}/gpg" -o /etc/apt/keyrings/docker.asc
        $SUDO_PREFIX chmod a+r /etc/apt/keyrings/docker.asc
        
        local repo_codename="${OS_CODENAME:-bookworm}"
        if [[ "$OS_ID" =~ ^(kali|parrot)$ || "$repo_codename" =~ ^(trixie|sid|testing|unstable)$ ]]; then
            repo_codename="bookworm"
        fi
        echo "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro_base} ${repo_codename} stable" | \
            $SUDO_PREFIX tee /etc/apt/sources.list.d/docker.list >/dev/null
        
        if $SUDO_PREFIX apt-get update -y --quiet; then
            DEBIAN_FRONTEND=noninteractive $SUDO_PREFIX apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io || true
        else
            $SUDO_PREFIX rm -f /etc/apt/sources.list.d/docker.list
        fi
    fi

    # Ensure CLI package is present
    if ! command -v docker &>/dev/null && command -v dockerd &>/dev/null && has_apt_candidate "docker-cli"; then
        DEBIAN_FRONTEND=noninteractive $SUDO_PREFIX apt-get install -y --no-install-recommends docker-cli
    fi

    # Enable and start service
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

    log_info "Resolving Docker Compose v2 candidate..."
    if has_apt_candidate "docker-compose-plugin"; then
        DEBIAN_FRONTEND=noninteractive $SUDO_PREFIX apt-get install -y --no-install-recommends docker-compose-plugin || true
    elif has_apt_candidate "docker-compose-v2"; then
        DEBIAN_FRONTEND=noninteractive $SUDO_PREFIX apt-get install -y --no-install-recommends docker-compose-v2 || true
    elif has_apt_candidate "docker-compose"; then
        DEBIAN_FRONTEND=noninteractive $SUDO_PREFIX apt-get install -y --no-install-recommends docker-compose || true
        if [[ -x /usr/bin/docker-compose ]]; then
            $SUDO_PREFIX mkdir -p /usr/local/lib/docker/cli-plugins /usr/lib/docker/cli-plugins
            $SUDO_PREFIX ln -sf /usr/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
            $SUDO_PREFIX ln -sf /usr/bin/docker-compose /usr/lib/docker/cli-plugins/docker-compose
        fi
    else
        log_info "Installing official Docker Compose v2 standalone plugin from GitHub..."
        local c_arch="$CPU_ARCH"
        case "$c_arch" in
            amd64) c_arch="x86_64" ;;
            arm64) c_arch="aarch64" ;;
        esac
        local plugin_url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${c_arch}"
        local dest_plugin="/usr/local/lib/docker/cli-plugins/docker-compose"
        $SUDO_PREFIX mkdir -p /usr/local/lib/docker/cli-plugins /usr/local/bin
        if $SUDO_PREFIX curl -fsSL "$plugin_url" -o "$dest_plugin"; then
            $SUDO_PREFIX chmod +x "$dest_plugin"
            $SUDO_PREFIX ln -sf "$dest_plugin" /usr/local/bin/docker-compose
        fi
    fi

    if docker compose version &>/dev/null || $SUDO_PREFIX docker compose version &>/dev/null; then
        local c_ver
        c_ver="$(docker compose version 2>/dev/null || $SUDO_PREFIX docker compose version 2>/dev/null)"
        log_ok "Docker Compose v2 successfully installed: $c_ver"
    else
        log_err "Failed to configure Docker Compose v2."
        return 1
    fi
}

mod_install_cloudflared() {
    if command -v cloudflared &>/dev/null || [[ -x /usr/local/bin/cloudflared ]]; then
        log_ok "cloudflared CLI already available: $(cloudflared --version 2>/dev/null | head -n1)"
        return 0
    fi

    log_info "Downloading official cloudflared debian package..."
    local tmp_deb
    tmp_deb=$(mktemp --suffix=.deb)
    local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${DEB_ARCH}.deb"
    if curl -fsSL "$cf_url" -o "$tmp_deb"; then
        $SUDO_PREFIX dpkg -i "$tmp_deb" || $SUDO_PREFIX apt-get install -f -y
        rm -f "$tmp_deb"
        log_ok "cloudflared successfully installed: $(cloudflared --version 2>/dev/null | head -n1)"
    else
        rm -f "$tmp_deb"
        log_warn "Could not download cloudflared package. Quick Tunnel will remain unavailable."
        return 1
    fi
}

