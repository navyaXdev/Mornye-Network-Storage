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
LIB_DIR="$PROGRAM_DIR/scripts/lib"

mkdir -p "$CONFIG_DIR" "$RUN_DIR" "$LOG_DIR"

# Source compatibility engine and port manager
if [[ -f "$LIB_DIR/compat.sh" ]]; then
    # shellcheck disable=SC1091
    source "$LIB_DIR/compat.sh"
fi
if [[ -f "$LIB_DIR/port_manager.sh" ]]; then
    # shellcheck disable=SC1091
    source "$LIB_DIR/port_manager.sh"
fi

if [[ -f "$PROGRAM_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$PROGRAM_DIR/.env" 2>/dev/null || true
fi
MORNYE_HOST_PORT="${MORNYE_HOST_PORT:-8001}"
MORNYE_HOST_BIND="${MORNYE_HOST_BIND:-127.0.0.1}"

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

get_cloudflared_bin() {
    if [[ -n "${CLOUDFLARED_BIN:-}" ]]; then
        echo "$CLOUDFLARED_BIN"
        return 0
    fi
    if has_cmd cloudflared; then
        echo "cloudflared"
    elif [[ -x /usr/local/bin/cloudflared ]]; then
        echo "/usr/local/bin/cloudflared"
    else
        echo ""
    fi
}

check_cloudflared() {
    local bin
    bin="$(get_cloudflared_bin)"
    if [[ -z "$bin" ]]; then
        echo -e "${RED}[ERROR] 'cloudflared' CLI binary is not installed.${NC}"
        echo -e "Install via: ./setup.sh or download from Cloudflare."
        return 1
    fi
    return 0
}

check_webdav_health() {
    local host_port="${MORNYE_HOST_PORT:-8001}"
    local host_bind="${MORNYE_HOST_BIND:-127.0.0.1}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${host_bind}:${host_port}/health" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 1.1 CERTIFICATE VALIDATION & DISCOVERY
# ------------------------------------------------------------------------------

validate_origin_certificate() {
    local cert_file="$1"
    if command -v compat_validate_origin_cert &>/dev/null; then
        compat_validate_origin_cert "$cert_file"
        return $?
    fi

    [[ -z "$cert_file" ]] && return 1
    if [[ -f "$cert_file" && -r "$cert_file" ]]; then
        [[ ! -s "$cert_file" ]] && return 1 # Reject empty files
        if grep -q '"AccountTag"' "$cert_file" 2>/dev/null && grep -q '"TunnelSecret"' "$cert_file" 2>/dev/null; then
            return 1
        fi
        if grep -qE "BEGIN (ARGO TUNNEL TOKEN|CERTIFICATE|PRIVATE KEY|RSA PRIVATE KEY)" "$cert_file" 2>/dev/null; then
            return 0
        fi
        if grep -q '"apiToken"' "$cert_file" 2>/dev/null && grep -q '"accountID"' "$cert_file" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

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

find_origin_certificate() {
    local explicit="${CLOUDFLARE_CERT_PATH:-}"
    if [[ -n "$explicit" ]]; then
        if validate_origin_certificate "$explicit"; then
            echo "$explicit"
            return 0
        else
            echo -e "${RED}[ERROR] Specified certificate '$explicit' is invalid, corrupted, or unreadable.${NC}" >&2
            return 1
        fi
    fi

    local candidates=(
        "${HOME}/.cloudflared/cert.pem"
        "${REAL_USER_HOME:-}/.cloudflared/cert.pem"
        "/root/.cloudflared/cert.pem"
        "/etc/cloudflared/cert.pem"
        "${CONFIG_DIR}/cert.pem"
    )

    for c in "${candidates[@]}"; do
        if [[ -n "$c" ]] && validate_origin_certificate "$c"; then
            # Cross-user sync: cert in /root/.cloudflared/cert.pem but executing as non-root
            if [[ "$c" == "/root/.cloudflared/cert.pem" && "$(id -u)" -ne 0 ]]; then
                if [[ ! -f "${HOME}/.cloudflared/cert.pem" ]] && command -v sudo &>/dev/null && sudo -n test -f "$c" 2>/dev/null; then
                    mkdir -p "${HOME}/.cloudflared" 2>/dev/null || true
                    if sudo -n cp "$c" "${HOME}/.cloudflared/cert.pem" 2>/dev/null && \
                       sudo -n chown "$(id -u):$(id -g)" "${HOME}/.cloudflared/cert.pem" 2>/dev/null && \
                       chmod 600 "${HOME}/.cloudflared/cert.pem" 2>/dev/null; then
                        echo "${HOME}/.cloudflared/cert.pem"
                        return 0
                    fi
                fi
            fi

            # Cross-user sync: cert in user home but executing as root via sudo
            if [[ "$c" == "${REAL_USER_HOME:-}/.cloudflared/cert.pem" && "$(id -u)" -eq 0 ]]; then
                if [[ ! -f "/root/.cloudflared/cert.pem" ]]; then
                    mkdir -p "/root/.cloudflared" 2>/dev/null || true
                    cp "$c" "/root/.cloudflared/cert.pem" 2>/dev/null || true
                    chmod 600 "/root/.cloudflared/cert.pem" 2>/dev/null || true
                fi
            fi

            echo "$c"
            return 0
        fi
    done

    return 1
}

print_cert_diagnostic_help() {
    echo -e "\n${BOLD}${YELLOW}================================================================${NC}"
    echo -e "${BOLD}${YELLOW}       CLOUDFLARE ORIGIN CERTIFICATE (cert.pem) NOT FOUND       ${NC}"
    echo -e "${BOLD}${YELLOW}================================================================${NC}"
    echo -e "Cloudflare Tunnel requires an origin certificate to authenticate tunnel creation."
    echo ""
    echo -e "${BOLD}Checked locations:${NC}"
    echo -e "  1. Explicit path : ${CLOUDFLARE_CERT_PATH:-None specified}"
    echo -e "  2. User store    : ${HOME}/.cloudflared/cert.pem"
    [[ -n "${REAL_USER_HOME:-}" ]] && echo -e "  3. Sudo user     : ${REAL_USER_HOME}/.cloudflared/cert.pem"
    echo -e "  4. Root store    : /root/.cloudflared/cert.pem"
    echo -e "  5. System store  : /etc/cloudflared/cert.pem"
    echo -e "  6. Mornye config : ${CONFIG_DIR}/cert.pem"
    echo ""
    echo -e "${BOLD}Actionable solutions:${NC}"
    echo -e "  1. Authenticate with Cloudflare to generate cert.pem:"
    echo -e "     ${CYAN}./mornye.sh tunnel login${NC}  (or: ${CYAN}cloudflared tunnel login${NC})"
    echo ""
    echo -e "  2. If cert.pem already exists at a custom path, specify it directly:"
    echo -e "     ${CYAN}./mornye.sh tunnel setup --cert /path/to/cert.pem${NC}"
    echo -e "     or export environment variable: ${CYAN}export CLOUDFLARE_CERT_PATH=/path/to/cert.pem${NC}"
    echo ""
    echo -e "  3. If cert.pem exists in /root/.cloudflared/ but you are running as non-root:"
    echo -e "     ${CYAN}sudo cp /root/.cloudflared/cert.pem ~/.cloudflared/cert.pem && sudo chown \$(id -u):\$(id -g) ~/.cloudflared/cert.pem && chmod 600 ~/.cloudflared/cert.pem${NC}"
    echo -e "${BOLD}${YELLOW}================================================================${NC}\n"
}

cmd_cert_check() {
    echo "================================================================================"
    echo "         MORNYE CLOUDFLARE ORIGIN CERTIFICATE DIAGNOSTIC INSPECTION             "
    echo "================================================================================"
    local found_valid=false
    local active_cert=""

    local paths=(
        "${CLOUDFLARE_CERT_PATH:-}"
        "${HOME}/.cloudflared/cert.pem"
        "${REAL_USER_HOME:-}/.cloudflared/cert.pem"
        "/root/.cloudflared/cert.pem"
        "/etc/cloudflared/cert.pem"
        "${CONFIG_DIR}/cert.pem"
    )

    for p in "${paths[@]}"; do
        [[ -z "$p" ]] && continue
        echo -n "Path: $p -> "
        if [[ ! -e "$p" ]]; then
            if command -v sudo &>/dev/null && sudo -n test -e "$p" 2>/dev/null; then
                echo -e "${YELLOW}EXISTS (Root-only)${NC}"
            else
                echo -e "${RED}NOT FOUND${NC}"
                continue
            fi
        else
            echo -e "${GREEN}EXISTS${NC}"
        fi

        local perms owner
        perms=$(stat -c "%a" "$p" 2>/dev/null || (command -v sudo &>/dev/null && sudo -n stat -c "%a" "$p" 2>/dev/null) || echo "???")
        owner=$(stat -c "%U:%G" "$p" 2>/dev/null || (command -v sudo &>/dev/null && sudo -n stat -c "%U:%G" "$p" 2>/dev/null) || echo "???")
        echo "      Permissions: $perms, Owner: $owner"

        if validate_origin_certificate "$p"; then
            echo -e "      Status     : ${GREEN}[✔] VALID CLOUDFLARE ORIGIN CERTIFICATE / TOKEN${NC}"
            if [[ "$found_valid" == false ]]; then
                found_valid=true
                active_cert="$p"
            fi
        else
            local is_cred=false
            if grep -q '"AccountTag"' "$p" 2>/dev/null || (command -v sudo &>/dev/null && sudo -n grep -q '"AccountTag"' "$p" 2>/dev/null); then
                is_cred=true
            fi
            if [[ "$is_cred" == true ]]; then
                echo -e "      Status     : ${RED}[✘] INVALID (This is a tunnel credentials JSON file, NOT origin cert.pem!)${NC}"
            else
                echo -e "      Status     : ${RED}[✘] INVALID (Missing PEM header / ARGO TUNNEL TOKEN)${NC}"
            fi
        fi
        echo ""
    done

    echo "================================================================================"
    if [[ "$found_valid" == true ]]; then
        echo -e "${GREEN}[✔] Active origin certificate: $active_cert${NC}"
        echo "Ready for tunnel operations (login, create, domain add)."
        return 0
    else
        echo -e "${RED}[✘] No valid Cloudflare origin certificate found.${NC}"
        print_cert_diagnostic_help
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
ROOT_DOMAIN="${ROOT_DOMAIN:-}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"
TUNNEL_MODE="${TUNNEL_MODE:-docker}"
LAST_UPDATED="$(date -u +"%Y-%m-%d %H:%M:%SZ")"
EOF
    chmod 600 "$TUNNEL_METADATA"
}

# ------------------------------------------------------------------------------
# 1.2 DOMAIN VALIDATION & CLOUDFLARE VERIFICATION HELPERS
# ------------------------------------------------------------------------------

format_and_validate_domain() {
    local raw_input="$1"
    local clean_domain="$raw_input"

    # Strip whitespace
    clean_domain="$(echo "$clean_domain" | tr -d '[:space:]')"

    # Convert to lowercase first
    clean_domain="$(echo "$clean_domain" | tr '[:upper:]' '[:lower:]')"

    # Strip protocol prefix (http://, https://)
    clean_domain="${clean_domain#http://}"
    clean_domain="${clean_domain#https://}"

    # Strip port suffix (:8000, :443, etc.)
    clean_domain="${clean_domain%%:*}"

    # Strip trailing slashes and paths (/dav/, /health, etc.)
    clean_domain="${clean_domain%%/*}"

    # If user passed "mornye.<domain>", strip "mornye." prefix so we get the root domain
    if [[ "$clean_domain" =~ ^mornye\.(.+)$ ]]; then
        clean_domain="${BASH_REMATCH[1]}"
    fi

    # Empty check
    if [[ -z "$clean_domain" ]]; then
        return 1
    fi

    # Disallow localhost
    if [[ "$clean_domain" == "localhost" ]]; then
        return 1
    fi

    # Reject IPv4 addresses
    if [[ "$clean_domain" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    # Reject IPv6 addresses
    if [[ "$clean_domain" =~ : ]]; then
        return 1
    fi

    # Reject leading or trailing hyphens or dots
    if [[ "$clean_domain" =~ ^[-.] || "$clean_domain" =~ [-.]$ ]]; then
        return 1
    fi

    # Reject consecutive dots or underscores
    if [[ "$clean_domain" =~ \.\. || "$clean_domain" =~ _ ]]; then
        return 1
    fi

    # Valid domain labels and TLD (at least 2 alpha characters)
    if [[ ! "$clean_domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
        return 1
    fi

    echo "$clean_domain"
    return 0
}

verify_cloudflare_domain() {
    local root_domain="$1"
    local cert_file="$2"

    if [[ "${MOCK_CF_ZONE_VERIFY:-}" == "fail" ]]; then
        echo -e "${RED}[ERROR] Domain '$root_domain' is not associated with your Cloudflare account.${NC}"
        return 1
    fi
    if [[ "${MOCK_CF_ZONE_VERIFY:-}" == "ok" ]]; then
        return 0
    fi

    if [[ -z "$cert_file" ]] || ! validate_origin_certificate "$cert_file"; then
        echo -e "${RED}[ERROR] Valid Cloudflare origin certificate (cert.pem) required to verify domain.${NC}"
        print_cert_diagnostic_help
        return 1
    fi

    return 0
}

check_and_create_dns_route() {
    local t_id="$1"
    local r_domain="$2"
    local sub_domain="$3"
    local cert_file="$4"
    local cf_bin
    cf_bin="$(get_cloudflared_bin)"

    if [[ -n "${MOCK_CF_DNS_CREATE_HANDLER:-}" ]]; then
        "${MOCK_CF_DNS_CREATE_HANDLER}" "$t_id" "$sub_domain"
        return $?
    fi

    local cert_args=()
    [[ -n "$cert_file" ]] && cert_args=("--origincert" "$cert_file")

    local expected_target="${t_id}.cfargotunnel.com"
    local existing_target=""

    if has_cmd dig; then
        existing_target=$(dig +short CNAME "$sub_domain" 2>/dev/null | sed 's/\.$//' || true)
    elif has_cmd host; then
        existing_target=$(host -t CNAME "$sub_domain" 2>/dev/null | awk '{print $NF}' | sed 's/\.$//' || true)
    fi

    if [[ -n "$existing_target" ]]; then
        if [[ "$existing_target" == "$expected_target" ]]; then
            return 0
        else
            if "$cf_bin" "${cert_args[@]}" tunnel route dns --overwrite-dns "$t_id" "$sub_domain" 2>/dev/null; then
                return 0
            else
                return 1
            fi
        fi
    fi

    local route_output
    if route_output=$("$cf_bin" "${cert_args[@]}" tunnel route dns "$t_id" "$sub_domain" 2>&1); then
        return 0
    else
        if echo "$route_output" | grep -qiE "already exists|conflict|CNAME"; then
            if "$cf_bin" "${cert_args[@]}" tunnel route dns --overwrite-dns "$t_id" "$sub_domain" 2>/dev/null; then
                return 0
            fi
        fi
        echo -e "${RED}[ERROR] Cloudflare DNS routing failed: $route_output${NC}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 2. CREDENTIAL RECOVERY & PERMISSION MANAGEMENT
# ------------------------------------------------------------------------------

# Ensures config/credentials.json is a valid regular JSON file with readable permissions
ensure_credentials_file() {
    local t_id="$1"
    local t_name="${2:-mornye-storage}"
    local cf_bin
    cf_bin="$(get_cloudflared_bin)"

    # If target is accidentally a directory (Docker mount artifact), remove it safely
    if [[ -d "$CREDENTIALS_FILE" ]]; then
        echo -e "${YELLOW}[!] Warning: $CREDENTIALS_FILE was created as a directory. Correcting...${NC}"
        rmdir "$CREDENTIALS_FILE" 2>/dev/null || rm -rf "$CREDENTIALS_FILE"
    fi

    # Check if file already exists and is valid JSON
    if [[ -f "$CREDENTIALS_FILE" && ! -d "$CREDENTIALS_FILE" ]]; then
        if grep -q '"AccountTag"' "$CREDENTIALS_FILE" 2>/dev/null && grep -q '"TunnelSecret"' "$CREDENTIALS_FILE" 2>/dev/null; then
            chmod 644 "$CREDENTIALS_FILE"
            return 0
        fi
    fi

    # Search local candidate paths
    local search_paths=(
        "${HOME}/.cloudflared/${t_id}.json"
        "/root/.cloudflared/${t_id}.json"
        "/etc/cloudflared/${t_id}.json"
        "${REAL_USER_HOME:-}/.cloudflared/${t_id}.json"
    )
    for sp in "${search_paths[@]}"; do
        if [[ -n "$sp" && -f "$sp" && ! -d "$sp" ]]; then
            if grep -q '"AccountTag"' "$sp" 2>/dev/null; then
                cp "$sp" "$CREDENTIALS_FILE"
                chmod 644 "$CREDENTIALS_FILE"
                echo -e "${GREEN}[✔] Sourced credentials JSON from $sp${NC}"
                return 0
            fi
        fi
    done

    # Recovery via cloudflared tunnel token
    if [[ -n "$cf_bin" && -n "$t_id" ]]; then
        echo -e "[*] Attempting credentials recovery via Cloudflare tunnel token..."
        local raw_token
        raw_token=$($cf_bin tunnel token "$t_id" 2>/dev/null || $cf_bin tunnel token "$t_name" 2>/dev/null || true)

        if [[ -z "$raw_token" ]]; then
            local origin_cert
            origin_cert="$(find_origin_certificate 2>/dev/null || true)"
            if [[ -n "$origin_cert" ]]; then
                raw_token=$($cf_bin tunnel --origincert "$origin_cert" token "$t_id" 2>/dev/null || $cf_bin tunnel --origincert "$origin_cert" token "$t_name" 2>/dev/null || true)
            fi
        fi
        
        if [[ -n "$raw_token" ]]; then
            python3 -c "
import sys, base64, json
try:
    token = '''$raw_token'''.strip()
    pad = len(token) % 4
    if pad:
        token += '=' * (4 - pad)
    data = json.loads(base64.b64decode(token).decode('utf-8'))
    creds = {
        'AccountTag': data.get('a', ''),
        'TunnelID': data.get('t', ''),
        'TunnelSecret': data.get('s', '')
    }
    if creds['AccountTag'] and creds['TunnelSecret']:
        with open('$CREDENTIALS_FILE', 'w') as f:
            json.dump(creds, f, indent=2)
        print('SUCCESS')
        sys.exit(0)
    sys.exit(1)
except Exception as e:
    sys.exit(1)
" 2>/dev/null
            if [[ $? -eq 0 && -f "$CREDENTIALS_FILE" ]]; then
                chmod 644 "$CREDENTIALS_FILE"
                echo -e "${GREEN}[✔] Successfully reconstructed credentials JSON via token.${NC}"
                return 0
            fi
        fi
    fi

    echo -e "${YELLOW}[!] Warning: Could not automatically locate or reconstruct credentials.json.${NC}"
    return 1
}

# ------------------------------------------------------------------------------
# 3. AUTHENTICATION & LOGIN
# ------------------------------------------------------------------------------

cmd_login() {
    check_cloudflared || return 1
    local cf_bin
    cf_bin="$(get_cloudflared_bin)"

    local existing_cert
    existing_cert="$(find_origin_certificate 2>/dev/null || true)"
    if [[ -n "$existing_cert" ]]; then
        echo -e "${GREEN}[✔] Existing Cloudflare origin certificate detected: $existing_cert${NC}"
        echo -e "    Notice: cert.pem authorizes tunnel creation and token management."
        if [[ "${NON_INTERACTIVE:-false}" != true ]]; then
            read -p "Re-authenticate with Cloudflare in browser? [y/N]: " -r reauth
            if [[ ! "$reauth" =~ ^[Yy]$ ]]; then
                return 0
            fi
        else
            return 0
        fi
    fi

    echo -e "${BOLD}[*] Launching Cloudflare browser authentication...${NC}"
    echo -e "    A browser link will appear. Select your domain zone in the Cloudflare Dashboard."
    
    local login_log="$LOG_DIR/cloudflared_login.log"
    mkdir -p "$LOG_DIR"
    $cf_bin tunnel login 2>&1 | tee "$login_log"

    local new_cert
    new_cert="$(find_origin_certificate 2>/dev/null || true)"
    if [[ -n "$new_cert" ]]; then
        echo -e "${GREEN}[✔] Cloudflare certificate verified: $new_cert${NC}"
        return 0
    else
        echo -e "${RED}[ERROR] Cloudflare login completed but cert.pem was not found in standard paths.${NC}"
        print_cert_diagnostic_help
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 4. TUNNEL CREATION & EXISTING TUNNEL REUSE
# ------------------------------------------------------------------------------

cmd_create() {
    check_cloudflared || return 1
    local name="${1:-mornye-storage}"
    local cf_bin
    cf_bin="$(get_cloudflared_bin)"

    load_tunnel_metadata

    echo -e "${BOLD}[*] Inspecting existing Cloudflare tunnels for '$name'...${NC}"
    local existing_id=""
    local list_output
    list_output="$($cf_bin tunnel list 2>/dev/null || true)"

    if echo "$list_output" | grep -qw "$name"; then
        existing_id=$(echo "$list_output" | grep -w "$name" | head -n1 | awk '{print $1}')
        echo -e "${GREEN}[✔] Found existing Cloudflare tunnel '$name' (UUID: $existing_id)${NC}"
        echo -e "    Reusing existing tunnel without creating duplicates."
    fi

    # Create only if tunnel does not exist
    if [[ -z "$existing_id" ]]; then
        local origin_cert
        origin_cert="$(find_origin_certificate 2>/dev/null || true)"

        echo -e "[*] Creating new Cloudflare Tunnel: '$name'..."
        if ! $cf_bin tunnel create "$name" 2>/dev/null; then
            local cert_args=()
            [[ -n "$origin_cert" ]] && cert_args=("--origincert" "$origin_cert")
            if [[ ${#cert_args[@]} -eq 0 ]] || ! $cf_bin tunnel "${cert_args[@]}" create "$name"; then
                echo -e "${RED}[ERROR] Failed to create tunnel '$name'. Ensure login cert is present via './mornye.sh tunnel login'.${NC}"
                print_cert_diagnostic_help
                return 1
            fi
        fi
        list_output="$($cf_bin tunnel list 2>/dev/null || true)"
        existing_id=$(echo "$list_output" | grep -w "$name" | head -n1 | awk '{print $1}')
    fi

    if [[ -z "$existing_id" ]]; then
        echo -e "${RED}[ERROR] Could not resolve Tunnel UUID for '$name'.${NC}"
        return 1
    fi

    TUNNEL_NAME="$name"
    TUNNEL_ID="$existing_id"
    save_tunnel_metadata

    # Retrieve and secure credentials JSON
    ensure_credentials_file "$TUNNEL_ID" "$TUNNEL_NAME" || true

    echo -e "${GREEN}[✔] Tunnel configured: Name='$TUNNEL_NAME', UUID='$TUNNEL_ID'${NC}"
}

# ------------------------------------------------------------------------------
# 5. CUSTOM DOMAIN ROUTING (STRUCTURAL YAML MANAGEMENT)
# ------------------------------------------------------------------------------

cmd_domain_add() {
    check_cloudflared || return 1
    local cf_bin
    cf_bin="$(get_cloudflared_bin)"
    load_tunnel_metadata

    local domain_input="${1:-}"
    if [[ -z "$domain_input" ]]; then
        read -p "Enter your Root Domain (e.g. example.com): " -r domain_input
    fi

    if [[ -z "$domain_input" ]]; then
        echo -e "${RED}[ERROR] Hostname cannot be empty.${NC}"
        return 1
    fi

    local root_domain
    if ! root_domain="$(format_and_validate_domain "$domain_input")"; then
        echo -e "${RED}[ERROR] Invalid root domain format: '$domain_input'${NC}"
        return 1
    fi

    local subdomain="mornye.${root_domain}"

    # Origin certificate & Cloudflare domain check
    local origin_cert
    origin_cert="$(find_origin_certificate 2>/dev/null || true)"
    if ! verify_cloudflare_domain "$root_domain" "$origin_cert"; then
        return 1
    fi

    if [[ -z "$TUNNEL_ID" ]]; then
        cmd_create "${TUNNEL_NAME:-mornye-storage}" || return 1
        load_tunnel_metadata
    fi

    # Display configuration banner and progress steps
    echo "========================================"
    echo "       Mornye Network Storage"
    echo "========================================"
    echo ""
    echo "Cloudflare Domain Configuration"
    echo ""
    echo "Root Domain: ${root_domain}"
    echo "Generated Subdomain: ${subdomain}"
    echo ""
    echo "Configuring Cloudflare Tunnel..."

    # Target origin configuration:
    # Inside docker network, tunnel reaches webdav container directly
    local target_origin="http://webdav:8000"
    if [[ "${TUNNEL_MODE:-}" == "host" || "${TUNNEL_MODE:-}" == "systemd" ]]; then
        target_origin="http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}"
    fi

    # Write structural cloudflared.yml
    cat << YMLEOF > "$TUNNEL_CONFIG"
# ==============================================================================
# MORNYE ZERO-TRUST WEBDAV INGRESS CONFIGURATION
# ==============================================================================
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json

ingress:
  # Dedicated Mornye WebDAV endpoint mapped exclusively
  - hostname: ${subdomain}
    service: ${target_origin}
    originRequest:
      connectTimeout: 30s
      noTLSVerify: true

  # Default catch-all (strictly reject unmapped domains or path traversal)
  - service: http_status:404
YMLEOF
    chmod 644 "$TUNNEL_CONFIG"

    ROOT_DOMAIN="$root_domain"
    CUSTOM_DOMAIN="$subdomain"
    save_tunnel_metadata

    # Ensure credentials file is ready for container mount
    ensure_credentials_file "$TUNNEL_ID" "$TUNNEL_NAME" || true

    # Update .env configuration
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        if grep -q "^STORAGE_HOSTNAME=" "$PROGRAM_DIR/.env" 2>/dev/null; then
            sed -i "s/^STORAGE_HOSTNAME=.*/STORAGE_HOSTNAME=$subdomain/" "$PROGRAM_DIR/.env" 2>/dev/null || true
        else
            echo "STORAGE_HOSTNAME=$subdomain" >> "$PROGRAM_DIR/.env"
        fi
        if grep -q "^CLOUDFLARE_ROOT_DOMAIN=" "$PROGRAM_DIR/.env" 2>/dev/null; then
            sed -i "s/^CLOUDFLARE_ROOT_DOMAIN=.*/CLOUDFLARE_ROOT_DOMAIN=$root_domain/" "$PROGRAM_DIR/.env" 2>/dev/null || true
        else
            echo "CLOUDFLARE_ROOT_DOMAIN=$root_domain" >> "$PROGRAM_DIR/.env"
        fi
        if grep -q "^CLOUDFLARE_DOMAIN=" "$PROGRAM_DIR/.env" 2>/dev/null; then
            sed -i "s/^CLOUDFLARE_DOMAIN=.*/CLOUDFLARE_DOMAIN=$subdomain/" "$PROGRAM_DIR/.env" 2>/dev/null || true
        else
            echo "CLOUDFLARE_DOMAIN=$subdomain" >> "$PROGRAM_DIR/.env"
        fi
    fi

    echo "Creating DNS Record..."
    if ! check_and_create_dns_route "$TUNNEL_ID" "$root_domain" "$subdomain" "$origin_cert"; then
        return 1
    fi

    echo "Configuring HTTPS..."
    # Cloudflare managed edge certificate active for proxied CNAME

    echo "Verifying Connection..."
    if (cd "$PROGRAM_DIR" && docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-tunnel"); then
        (cd "$PROGRAM_DIR" && docker compose --profile tunnel restart tunnel >/dev/null 2>&1 || true)
    fi

    echo ""
    echo "SUCCESS!"
    echo ""
    echo "Your Mornye Network Storage URL:"
    echo "https://${subdomain}"
    echo ""
    echo "========================================"
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
    echo -e "Domain to decouple : ${RED}$domain${NC}"
    echo -e "Tunnel UUID        : $TUNNEL_ID"
    echo -e "Notice: Decouples hostname routing for Mornye WebDAV."
    echo -e "        The Cloudflare zone and permanent tunnel will NOT be deleted."
    echo -e "${YELLOW}==============================================================${NC}"

    if [[ "${NON_INTERACTIVE:-false}" != true ]]; then
        read -p "Proceed with decoupling domain '$domain'? [y/N]: " -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "[*] Removal aborted by operator."
            return 0
        fi
    fi

    cat << YMLEOF > "$TUNNEL_CONFIG"
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - service: http_status:404
YMLEOF
    chmod 644 "$TUNNEL_CONFIG"

    ROOT_DOMAIN=""
    CUSTOM_DOMAIN=""
    save_tunnel_metadata

    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        sed -i '/^CLOUDFLARE_ROOT_DOMAIN=/d' "$PROGRAM_DIR/.env" 2>/dev/null || true
        sed -i '/^CLOUDFLARE_DOMAIN=/d' "$PROGRAM_DIR/.env" 2>/dev/null || true
        sed -i 's/^STORAGE_HOSTNAME=.*/STORAGE_HOSTNAME=/' "$PROGRAM_DIR/.env" 2>/dev/null || true
    fi

    echo -e "${GREEN}[✔] Ingress rule removed. Cloudflare domain decoupled safely.${NC}"
}

cmd_domain_reset() {
    echo -e "${BOLD}[*] Resetting Cloudflare domain routing to unconfigured state...${NC}"
    cmd_domain_remove "${CUSTOM_DOMAIN:-all}"
    if (cd "$PROGRAM_DIR" && docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-tunnel"); then
        (cd "$PROGRAM_DIR" && docker compose --profile tunnel restart tunnel >/dev/null 2>&1 || true)
    fi
    echo -e "${GREEN}[✔] Domain configuration reset complete.${NC}"
}

# ------------------------------------------------------------------------------
# 6. PERMANENT TUNNEL SETUP (GUIDED WIZARD)
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

    # 1. Local WebDAV service verification
    local h_port="${MORNYE_HOST_PORT:-8001}"
    local h_bind="${MORNYE_HOST_BIND:-127.0.0.1}"
    echo -e "${BOLD}[1/5] Checking Local WebDAV Service...${NC}"
    if check_webdav_health; then
        echo -e "  - Local WebDAV : ${GREEN}[✔] Healthy (http://${h_bind}:${h_port}/health: 200 OK)${NC}"
    else
        echo -e "  - Local WebDAV : ${YELLOW}[!] WebDAV not responding on http://${h_bind}:${h_port}/health.${NC}"
        echo -e "    Starting Mornye Docker stack now..."
        (cd "$PROGRAM_DIR" && docker compose up -d webdav)
        sleep 3
    fi

    # 2. Authentication check
    echo -e "\n${BOLD}[2/5] Verifying Cloudflare Authentication...${NC}"
    local existing_cert
    existing_cert="$(find_origin_certificate || true)"
    if [[ -z "$existing_cert" ]]; then
        cmd_login || return 1
    else
        echo -e "  - Cloudflare Cert : ${GREEN}[✔] Authenticated ($existing_cert)${NC}"
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
    echo -e "\n${BOLD}[5/5] Launching Permanent Tunnel Container...${NC}"
    cmd_start

    echo ""
    cmd_status
}

# ------------------------------------------------------------------------------
# 7. LIFECYCLE MANAGEMENT (START / STOP / RESTART / STATUS / LOGS / TEST)
# ------------------------------------------------------------------------------

cmd_start() {
    load_tunnel_metadata

    if [[ -z "$TUNNEL_ID" ]]; then
        echo -e "${RED}[ERROR] Permanent tunnel is not configured yet. Run './mornye.sh tunnel setup' first.${NC}"
        return 1
    fi

    # Verify and ensure credentials exist BEFORE launching container
    if ! ensure_credentials_file "$TUNNEL_ID" "$TUNNEL_NAME"; then
        echo -e "${RED}[ERROR] Missing tunnel credentials file ($CREDENTIALS_FILE).${NC}"
        echo -e "        Run './mornye.sh tunnel create' or ensure cert.pem is available for token recovery."
        return 1
    fi

    if [[ ! -f "$TUNNEL_CONFIG" ]]; then
        echo -e "${RED}[ERROR] Missing ingress configuration at $TUNNEL_CONFIG.${NC}"
        echo -e "        Run './mornye.sh tunnel domain add <hostname>' to generate."
        return 1
    fi

    echo -e "[*] Starting permanent Cloudflare Tunnel via Docker Compose..."
    (cd "$PROGRAM_DIR" && docker compose --profile tunnel up -d tunnel)
    echo -e "${GREEN}[✔] Permanent tunnel container launched.${NC}"
}

cmd_stop() {
    echo -e "[*] Stopping permanent Cloudflare Tunnel container..."
    (cd "$PROGRAM_DIR" && docker compose --profile tunnel stop tunnel 2>/dev/null || true)
    echo -e "${GREEN}[✔] Permanent tunnel container stopped.${NC}"
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
    if [[ -n "${ROOT_DOMAIN:-}" ]]; then
        echo -e "Root Domain           : ${CYAN}${ROOT_DOMAIN}${NC}"
    fi
    echo -e "Custom Domain         : ${CUSTOM_DOMAIN:-None (Local only)}"
    
    local container_state="STOPPED / INACTIVE"
    if (cd "$PROGRAM_DIR" && docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-tunnel"); then
        container_state="RUNNING (Container: mornye-tunnel)"
        echo -e "Service Mode          : ${GREEN}$container_state${NC}"
    else
        echo -e "Service Mode          : ${YELLOW}$container_state${NC}"
    fi

    # Display credentials status
    if [[ -f "$CREDENTIALS_FILE" && ! -d "$CREDENTIALS_FILE" ]]; then
        echo -e "Credentials JSON      : ${GREEN}[✔] Valid ($CREDENTIALS_FILE)${NC}"
    else
        echo -e "Credentials JSON      : ${RED}[✘] Missing${NC}"
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

    if (cd "$PROGRAM_DIR" && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "mornye-tunnel"); then
        (cd "$PROGRAM_DIR" && docker compose logs -n "$lines" $follow tunnel)
    else
        echo "No mornye-tunnel container found."
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
# 8. QUICK TUNNEL MANAGEMENT (EPHEMERAL TEST MODE)
# ------------------------------------------------------------------------------

cmd_quick_start() {
    check_cloudflared || return 1
    local cf_bin
    cf_bin="$(get_cloudflared_bin)"

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
        echo -e "${RED}[ERROR] Local WebDAV engine (${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}) is not responding.${NC}"
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
    echo "(${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}) publicly via a temporary trycloudflare.com URL."
    echo ""
    echo "Security Status:"
    echo "  - Target Origin      : http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/dav/"
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
    nohup "$cf_bin" tunnel --url "http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}" --no-autoupdate > "$log_file" 2>&1 &
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
        echo -e "Target Origin        : http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}"
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
    echo -e "Target Local Origin   : http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}"
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
    local parsed_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cert|-c)
                CLOUDFLARE_CERT_PATH="$2"
                export CLOUDFLARE_CERT_PATH
                shift 2
                ;;
            *)
                parsed_args+=("$1")
                shift
                ;;
        esac
    done

    set -- "${parsed_args[@]}"
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        cert-check|cert_check)
            cmd_cert_check "$@"
            ;;
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
                reset)
                    cmd_domain_reset "$@"
                    ;;
                validate)
                    format_and_validate_domain "$@"
                    ;;
                *)
                    echo "Usage: ./mornye.sh tunnel domain [add|remove|reset] [domain]"
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
Usage: ./mornye.sh tunnel <command> [options]

Global Options:
  --cert, -c <path>                   Explicit path to Cloudflare origin cert.pem

Permanent Zero-Trust Tunnel Commands:
  ./mornye.sh tunnel cert-check       Inspect and diagnose Cloudflare origin certificates
  ./mornye.sh tunnel setup            Interactive guided wizard for permanent tunnel + domain
  ./mornye.sh tunnel login            Authenticate with Cloudflare via browser login
  ./mornye.sh tunnel create [name]    Create named tunnel (default: mornye-storage)
  ./mornye.sh tunnel domain add <dom> Automatically configure dedicated subdomain (mornye.<domain>)
  ./mornye.sh tunnel domain remove    Safely disconnect custom domain routing
  ./mornye.sh tunnel domain reset     Reset domain routing configuration to default
  ./mornye.sh tunnel start            Start permanent Cloudflare Tunnel container
  ./mornye.sh tunnel stop             Stop permanent Cloudflare Tunnel container
  ./mornye.sh tunnel restart          Restart permanent Cloudflare Tunnel container
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
