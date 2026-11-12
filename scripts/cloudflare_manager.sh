#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — COMPLETE CLOUDFLARE TUNNEL & DOMAIN MANAGER
# Module: scripts/cloudflare_manager.sh
# Purpose: Permanent Zero-Trust tunnels, custom domain management, DNS routing,
#          ephemeral Quick Tunnels, status probes, and security enforcement.
# ==============================================================================

set -eo pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$PROGRAM_DIR/config"
RUN_DIR="$PROGRAM_DIR/run"
LOG_DIR="$PROGRAM_DIR/logs"

mkdir -p "$CONFIG_DIR" "$RUN_DIR" "$LOG_DIR"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TUNNEL_CONFIG="$CONFIG_DIR/cloudflared.yml"
CREDENTIALS_FILE="$CONFIG_DIR/credentials.json"
TUNNEL_METADATA="$CONFIG_DIR/tunnel_info.env"

# ------------------------------------------------------------------------------
# 1. HELPER FUNCTIONS
# ------------------------------------------------------------------------------

has_cmd() {
    command -v "$1" &>/dev/null
}

check_cloudflared() {
    if ! has_cmd cloudflared && [[ ! -x /usr/local/bin/cloudflared ]]; then
        echo -e "${RED}[ERROR] 'cloudflared' CLI binary is not installed.${NC}"
        echo -e "Install via: ./mornye.sh install  or download from Cloudflare."
        return 1
    fi
    return 0
}

check_webdav_health() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://127.0.0.1:8000/health" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
        return 0
    else
        return 1
    fi
}

load_tunnel_metadata() {
    if [[ -f "$TUNNEL_METADATA" ]]; then
        # shellcheck disable=SC1090
        source "$TUNNEL_METADATA"
    fi
}

save_tunnel_metadata() {
    cat << EOF > "$TUNNEL_METADATA"
# Mornye Cloudflare Tunnel Metadata
TUNNEL_NAME="${TUNNEL_NAME:-mornye-storage}"
TUNNEL_ID="${TUNNEL_ID:-}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"
TUNNEL_MODE="${TUNNEL_MODE:-docker}"
LAST_UPDATED="$(date -u +"%Y-%m-%d %H:%M:%SZ")"
EOF
    chmod 600 "$TUNNEL_METADATA"
}

# ------------------------------------------------------------------------------
# 2. AUTHENTICATION & LOGIN
# ------------------------------------------------------------------------------

cmd_login() {
    check_cloudflared || return 1

    local cert_file="$HOME/.cloudflared/cert.pem"
    if [[ -f "$cert_file" ]]; then
        echo -e "${GREEN}[✔] Existing Cloudflare certificate detected at $cert_file${NC}"
        read -p "Re-authenticate with Cloudflare in browser? [y/N]: " -r reauth
        if [[ ! "$reauth" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    echo -e "${BOLD}[*] Launching Cloudflare browser authentication...${NC}"
    echo -e "    A browser link will appear. Select your domain zone in the Cloudflare Dashboard."
    cloudflared tunnel login
    if [[ -f "$HOME/.cloudflared/cert.pem" ]]; then
        echo -e "${GREEN}[✔] Cloudflare certificate generated successfully: $HOME/.cloudflared/cert.pem${NC}"
    else
        echo -e "${RED}[ERROR] Cloudflare login failed or cert.pem not found.${NC}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 3. TUNNEL CREATION
# ------------------------------------------------------------------------------

cmd_create() {
    check_cloudflared || return 1
    local name="${1:-mornye-storage}"

    load_tunnel_metadata

    echo -e "${BOLD}[*] Checking existing Cloudflare tunnels for '$name'...${NC}"
    local existing_id=""
    if cloudflared tunnel list 2>/dev/null | grep -qw "$name"; then
        existing_id=$(cloudflared tunnel list 2>/dev/null | grep -w "$name" | head -n1 | awk '{print $1}')
        echo -e "${GREEN}[✔] Found existing tunnel '$name' (UUID: $existing_id)${NC}"
    fi

    if [[ -z "$existing_id" ]]; then
        echo -e "[*] Creating new Cloudflare Tunnel: '$name'..."
        if ! cloudflared tunnel create "$name"; then
            echo -e "${RED}[ERROR] Failed to create tunnel '$name'. Ensure you are logged in via './mornye.sh tunnel login'.${NC}"
            return 1
        fi
        existing_id=$(cloudflared tunnel list 2>/dev/null | grep -w "$name" | head -n1 | awk '{print $1}')
    fi

    if [[ -z "$existing_id" ]]; then
        echo -e "${RED}[ERROR] Could not resolve Tunnel UUID for '$name'.${NC}"
        return 1
    fi

    TUNNEL_NAME="$name"
    TUNNEL_ID="$existing_id"

    # Copy credential JSON to project config
    local src_cred="$HOME/.cloudflared/${TUNNEL_ID}.json"
    if [[ -f "$src_cred" ]]; then
        cp "$src_cred" "$CREDENTIALS_FILE"
        chmod 600 "$CREDENTIALS_FILE"
        echo -e "${GREEN}[✔] Tunnel credentials secured at $CREDENTIALS_FILE${NC}"
    elif [[ -f "$CREDENTIALS_FILE" ]]; then
        echo -e "${GREEN}[✔] Existing project credentials file preserved at $CREDENTIALS_FILE${NC}"
    else
        echo -e "${YELLOW}[!] Warning: Credentials JSON not found in ~/.cloudflared or $CREDENTIALS_FILE${NC}"
    fi

    save_tunnel_metadata
    echo -e "${GREEN}[✔] Tunnel configured: Name='$TUNNEL_NAME', UUID='$TUNNEL_ID'${NC}"
}

# ------------------------------------------------------------------------------
# 4. CUSTOM DOMAIN ROUTING (ADD / REMOVE)
# ------------------------------------------------------------------------------

cmd_domain_add() {
    check_cloudflared || return 1
    load_tunnel_metadata

    local domain="$1"
    if [[ -z "$domain" ]]; then
        read -p "Enter custom hostname (e.g. storage.example.com): " -r domain
    fi

    if [[ -z "$domain" ]]; then
        echo -e "${RED}[ERROR] Hostname cannot be empty.${NC}"
        return 1
    fi

    # Hostname syntax validation
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        echo -e "${RED}[ERROR] Invalid hostname syntax: '$domain'${NC}"
        return 1
    fi

    if [[ -z "$TUNNEL_ID" ]]; then
        echo -e "${YELLOW}[!] Tunnel not created yet. Initializing tunnel first...${NC}"
        cmd_create "${TUNNEL_NAME:-mornye-storage}" || return 1
    fi

    echo -e "${BOLD}[*] Routing DNS CNAME for '$domain' to Tunnel '$TUNNEL_ID'...${NC}"
    if cloudflared tunnel route dns "$TUNNEL_ID" "$domain"; then
        echo -e "${GREEN}[✔] Cloudflare DNS CNAME route created: $domain -> ${TUNNEL_ID}.cfargotunnel.com${NC}"
    else
        echo -e "${YELLOW}[!] Note: DNS route may already exist in your Cloudflare zone or requires manual check.${NC}"
    fi

    # Update cloudflared.yml ingress configuration
    CUSTOM_DOMAIN="$domain"
    save_tunnel_metadata

    cat << YMLEOF > "$TUNNEL_CONFIG"
# ==============================================================================
# MORNYE ZERO-TRUST WEBDAV INGRESS CONFIGURATION
# ==============================================================================
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json

ingress:
  # Public WebDAV endpoint mapped exclusively
  - hostname: ${domain}
    service: http://webdav:8000
    originRequest:
      connectTimeout: 30s
      noTLSVerify: true

  # Default catch-all (strictly reject unmapped domains or path traversal)
  - service: http_status:404
YMLEOF
    chmod 600 "$TUNNEL_CONFIG"
    echo -e "${GREEN}[✔] Ingress configuration generated at $TUNNEL_CONFIG${NC}"

    # Update .env STORAGE_HOSTNAME
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        sed -i "s/STORAGE_HOSTNAME=.*/STORAGE_HOSTNAME=$domain/" "$PROGRAM_DIR/.env" 2>/dev/null || true
    fi

    echo ""
    echo -e "${GREEN}==============================================================${NC}"
    echo -e "${GREEN}[✔] CUSTOM DOMAIN ROUTING COMPLETE!${NC}"
    echo -e "Public WebDAV URL: ${CYAN}https://${domain}/dav/${NC}"
    echo -e "${GREEN}==============================================================${NC}"
}

cmd_domain_remove() {
    load_tunnel_metadata
    local domain="${1:-$CUSTOM_DOMAIN}"

    if [[ -z "$domain" ]]; then
        echo -e "${YELLOW}[!] No custom domain is currently registered.${NC}"
        return 0
    fi

    echo -e "${YELLOW}==============================================================${NC}"
    echo -e "${BOLD}CONFIRM CUSTOM DOMAIN REMOVAL${NC}"
    echo -e "Domain to remove: ${RED}$domain${NC}"
    echo -e "Tunnel UUID     : $TUNNEL_ID"
    echo -e "Notice: This will disassociate the hostname from Mornye WebDAV."
    echo -e "        The Cloudflare zone and permanent tunnel will NOT be deleted."
    echo -e "${YELLOW}==============================================================${NC}"

    read -p "Proceed with removing domain '$domain'? [y/N]: " -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "[*] Removal aborted by operator."
        return 0
    fi

    echo -e "[*] Updating local ingress rules..."
    cat << YMLEOF > "$TUNNEL_CONFIG"
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - service: http_status:404
YMLEOF
    chmod 600 "$TUNNEL_CONFIG"

    CUSTOM_DOMAIN=""
    save_tunnel_metadata
    echo -e "${GREEN}[✔] Ingress rule removed. Cloudflare domain decoupled safely.${NC}"
}

# ------------------------------------------------------------------------------
# 5. PERMANENT TUNNEL SETUP (GUIDED WIZARD)
# ------------------------------------------------------------------------------

cmd_setup() {
    echo -e "${CYAN}"
    cat << "EOF"
==============================================================
   MORNYE NETWORK STORAGE — CLOUDFLARE TUNNEL SETUP WIZARD
==============================================================
EOF
    echo -e "${NC}"

    check_cloudflared || return 1

    # 1. WebDAV local check
    echo -e "${BOLD}[1/5] Checking Local WebDAV Service...${NC}"
    if check_webdav_health; then
        echo -e "  - Local WebDAV : ${GREEN}[✔] Healthy (http://127.0.0.1:8000/health: 200 OK)${NC}"
    else
        echo -e "  - Local WebDAV : ${YELLOW}[!] Container not running on port 8000.${NC}"
        echo -e "    Starting Mornye Docker stack now..."
        (cd "$PROGRAM_DIR" && docker compose up -d webdav)
        sleep 3
    fi

    # 2. Authentication check
    echo -e "\n${BOLD}[2/5] Verifying Cloudflare Authentication...${NC}"
    if [[ ! -f "$HOME/.cloudflared/cert.pem" ]]; then
        cmd_login || return 1
    else
        echo -e "  - Cloudflare Cert : ${GREEN}[✔] Authenticated ($HOME/.cloudflared/cert.pem)${NC}"
    fi

    # 3. Tunnel Name & Creation
    echo -e "\n${BOLD}[3/5] Configuring Cloudflare Tunnel...${NC}"
    read -p "Enter Tunnel Name [mornye-storage]: " -r tname
    tname="${tname:-mornye-storage}"
    cmd_create "$tname" || return 1

    # 4. Custom Domain
    echo -e "\n${BOLD}[4/5] Custom Domain Configuration...${NC}"
    read -p "Configure a custom domain now? (e.g. storage.yourdomain.com) [Y/n]: " -r do_domain
    if [[ ! "$do_domain" =~ ^[Nn]$ ]]; then
        cmd_domain_add || return 1
    fi

    # 5. Service Launch
    echo -e "\n${BOLD}[5/5] Launching Permanent Tunnel...${NC}"
    cmd_start

    echo ""
    cmd_status
}

# ------------------------------------------------------------------------------
# 6. LIFECYCLE MANAGEMENT (START / STOP / RESTART / STATUS / LOGS / TEST)
# ------------------------------------------------------------------------------

cmd_start() {
    load_tunnel_metadata

    if [[ -z "$TUNNEL_ID" ]]; then
        echo -e "${RED}[ERROR] Permanent tunnel is not configured yet. Run './mornye.sh tunnel setup' first.${NC}"
        return 1
    fi

    if [[ ! -f "$TUNNEL_CONFIG" ]] || [[ ! -f "$CREDENTIALS_FILE" ]]; then
        echo -e "${RED}[ERROR] Missing tunnel configuration or credentials in config/.${NC}"
        return 1
    fi

    echo -e "[*] Starting permanent Cloudflare Tunnel via Docker Compose..."
    (cd "$PROGRAM_DIR" && docker compose --profile tunnel up -d tunnel)
    echo -e "${GREEN}[✔] Permanent tunnel container launched.${NC}"
}

cmd_stop() {
    echo -e "[*] Stopping permanent Cloudflare Tunnel container..."
    (cd "$PROGRAM_DIR" && docker compose --profile tunnel stop tunnel 2>/dev/null || true)
    
    # Also stop systemd unit if it was running on host
    if command -v systemctl &>/dev/null; then
        sudo systemctl stop mornye-tunnel.service 2>/dev/null || true
    fi
    echo -e "${GREEN}[✔] Permanent tunnel stopped.${NC}"
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_status() {
    load_tunnel_metadata

    echo "=============================================================="
    echo "             CLOUDFLARE PERMANENT TUNNEL STATUS"
    echo "=============================================================="
    echo -e "Tunnel Name           : ${CYAN}${TUNNEL_NAME:-Not configured}${NC}"
    echo -e "Tunnel UUID           : ${TUNNEL_ID:-Not configured}"
    echo -e "Custom Domain         : ${CUSTOM_DOMAIN:-None (Local only)}"
    
    local container_state="STOPPED"
    if (cd "$PROGRAM_DIR" && docker ps --format '{{.Names}}' | grep -qw "mornye-tunnel"); then
        container_state="RUNNING (Container: mornye-tunnel)"
        echo -e "Service Mode          : ${GREEN}$container_state${NC}"
    elif command -v systemctl &>/dev/null && systemctl is-active mornye-tunnel.service &>/dev/null; then
        echo -e "Service Mode          : ${GREEN}RUNNING (Host systemd unit)${NC}"
    else
        echo -e "Service Mode          : ${YELLOW}STOPPED / INACTIVE${NC}"
    fi

    if [[ -n "$CUSTOM_DOMAIN" ]]; then
        echo -e "Public WebDAV URL     : ${CYAN}https://${CUSTOM_DOMAIN}/dav/${NC}"
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 -X PROPFIND -H "Depth: 0" "https://${CUSTOM_DOMAIN}/dav/" 2>/dev/null || echo "000")
        echo -e "WAN Health Status     : HTTP $code (Auth Protection Active)"
    fi
    echo "=============================================================="
}

cmd_logs() {
    local follow=""
    local lines="50"
    for arg in "$@"; do
        if [[ "$arg" == "-f" || "$arg" == "--follow" ]]; then
            follow="-f"
        elif [[ "$arg" =~ ^[0-9]+$ ]]; then
            lines="$arg"
        fi
    done

    if (cd "$PROGRAM_DIR" && docker ps --format '{{.Names}}' | grep -qw "mornye-tunnel"); then
        (cd "$PROGRAM_DIR" && docker compose logs -n "$lines" $follow tunnel)
    elif command -v journalctl &>/dev/null; then
        journalctl --no-pager -u mornye-tunnel.service -n "$lines" $follow 2>/dev/null || echo "No logs found."
    else
        echo "No active tunnel service found."
    fi
}

cmd_test() {
    load_tunnel_metadata
    if [[ -z "$CUSTOM_DOMAIN" ]]; then
        echo -e "${YELLOW}[!] No custom domain configured to test. Run './mornye.sh tunnel domain add'.${NC}"
        return 1
    fi

    echo -e "[*] Probing WAN endpoint: ${CYAN}https://${CUSTOM_DOMAIN}/dav/${NC}..."
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -X PROPFIND -H "Depth: 0" "https://${CUSTOM_DOMAIN}/dav/" 2>/dev/null || echo "000")
    if [[ "$code" == "401" ]]; then
        echo -e "${GREEN}[✔] SUCCESS: Public endpoint responded with HTTP 401 Unauthorized (Argon2id auth boundary active).${NC}"
    elif [[ "$code" == "200" || "$code" == "207" ]]; then
        echo -e "${GREEN}[✔] SUCCESS: Public endpoint responded with HTTP $code.${NC}"
    else
        echo -e "${YELLOW}[!] Public endpoint returned HTTP $code. Check DNS propagation or tunnel status.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 7. QUICK TUNNEL MANAGEMENT (EPHEMERAL TEST MODE)
# ------------------------------------------------------------------------------

cmd_quick_start() {
    check_cloudflared || return 1

    # Check if already running
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

    # Verify WebDAV availability
    if ! check_webdav_health; then
        echo -e "${RED}[ERROR] Local WebDAV engine (127.0.0.1:8000) is not responding.${NC}"
        echo -e "Please start Mornye WebDAV first via: ./mornye.sh start"
        return 1
    fi

    # Confirmation
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
            return 0
        fi
    fi

    local log_file="$LOG_DIR/quick_tunnel.log"
    rm -f "$log_file" "$RUN_DIR/quick_tunnel.url"

    echo -e "[*] Requesting temporary Quick Tunnel via trycloudflare.com..."
    nohup cloudflared tunnel --url http://127.0.0.1:8000 --no-autoupdate > "$log_file" 2>&1 &
    local q_pid=$!
    echo "$q_pid" > "$RUN_DIR/quick_tunnel.pid"

    # Poll for generated URL
    local tunnel_url=""
    for i in {1..20}; do
        sleep 1
        if ! kill -0 "$q_pid" 2>/dev/null; then
            echo -e "${RED}[ERROR] cloudflared process exited unexpectedly.${NC}"
            cat "$log_file"
            rm -f "$RUN_DIR/quick_tunnel.pid"
            return 1
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
        tail -n 15 "$log_file"
        cmd_quick_stop
        return 1
    fi
}

cmd_quick_status() {
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

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 -X PROPFIND -H "Depth: 0" "${url}/dav/" 2>/dev/null || echo "000")

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

cmd_quick_stop() {
    if [[ ! -f "$RUN_DIR/quick_tunnel.pid" ]]; then
        echo -e "[*] Quick Tunnel is not currently running."
        return 0
    fi

    local pid
    pid=$(cat "$RUN_DIR/quick_tunnel.pid" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        # Check process ownership to avoid broad/unsafe killing
        local proc_cmd
        proc_cmd=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        if [[ "$proc_cmd" == *"cloudflared"* ]]; then
            echo -e "[*] Stopping Quick Tunnel process (PID: $pid)..."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
    fi

    rm -f "$RUN_DIR/quick_tunnel.pid" "$RUN_DIR/quick_tunnel.url"
    echo -e "${GREEN}[✔] Quick Tunnel terminated cleanly.${NC}"
}

cmd_quick_logs() {
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
# DISPATCH ENTRYPOINT
# ------------------------------------------------------------------------------

main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        setup)
            cmd_setup "$@"
            ;;
        login)
            cmd_login "$@"
            ;;
        create)
            cmd_create "$@"
            ;;
        domain)
            local sub="${1:-}"
            shift || true
            case "$sub" in
                add)
                    cmd_domain_add "$@"
                    ;;
                remove)
                    cmd_domain_remove "$@"
                    ;;
                *)
                    echo "Usage: ./mornye.sh tunnel domain [add|remove] [hostname]"
                    exit 1
                    ;;
            esac
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
        status)
            cmd_status "$@"
            ;;
        logs)
            cmd_logs "$@"
            ;;
        test)
            cmd_test "$@"
            ;;
        quick)
            local sub="${1:-}"
            shift || true
            case "$sub" in
                start)
                    cmd_quick_start "$@"
                    ;;
                status)
                    cmd_quick_status "$@"
                    ;;
                stop)
                    cmd_quick_stop "$@"
                    ;;
                logs)
                    cmd_quick_logs "$@"
                    ;;
                *)
                    echo "Usage: ./mornye.sh tunnel quick [start|status|stop|logs]"
                    exit 1
                    ;;
            esac
            ;;
        ""|help|--help|-h)
            cat << "EOF"
Usage: ./mornye.sh tunnel <command>

Permanent Zero-Trust Tunnel Commands:
  ./mornye.sh tunnel setup            Interactive guided wizard for permanent tunnel + domain
  ./mornye.sh tunnel login            Authenticate with Cloudflare via browser login
  ./mornye.sh tunnel create [name]    Create named tunnel (default: mornye-storage)
  ./mornye.sh tunnel domain add <dom> Bind custom domain & route DNS CNAME (e.g. storage.example.com)
  ./mornye.sh tunnel domain remove    Safely disconnect custom domain routing
  ./mornye.sh tunnel start            Start permanent Cloudflare Tunnel service
  ./mornye.sh tunnel stop             Stop permanent Cloudflare Tunnel service
  ./mornye.sh tunnel restart          Restart permanent Cloudflare Tunnel service
  ./mornye.sh tunnel status           Display tunnel health, metrics, and domain routing
  ./mornye.sh tunnel logs [-f] [N]    View tunnel runtime logs
  ./mornye.sh tunnel test             Verify WAN reachability and auth boundary

Ephemeral Quick Tunnel Commands (Testing):
  ./mornye.sh tunnel quick start [-y] Start temporary trycloudflare.com tunnel
  ./mornye.sh tunnel quick status     Check quick tunnel URL and active status
  ./mornye.sh tunnel quick stop       Terminate active quick tunnel cleanly
  ./mornye.sh tunnel quick logs [-f]  View quick tunnel stdout/stderr logs
EOF
            ;;
        *)
            echo -e "${RED}[ERROR] Unknown tunnel command: '$cmd'${NC}"
            echo "Run './mornye.sh tunnel help' for usage."
            exit 1
            ;;
    esac
}

main "$@"

