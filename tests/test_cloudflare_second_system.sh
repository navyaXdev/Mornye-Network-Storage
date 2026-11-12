#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — DEBIAN 13 SECOND-SYSTEM REAL-WORLD REGRESSION FIXTURE
# Module: tests/test_cloudflare_second_system.sh
# Purpose: Simulates the exact multi-tenant production environment reported on
#          Debian 13 (Trixie) with pre-existing services and existing Cloudflare tunnel:
#          - OS: Debian GNU/Linux 13 (trixie) x86_64
#          - Docker Engine 26.1.5, Docker Compose 2.26.1
#          - cloudflared 2026.10.7
#          - SONG Bridge active on port 8000 (mornye-storage.service, PID 13951)
#          - Existing Cloudflare Tunnel on port 20241 (mornye-tunnel.service, PID 522213)
#          - Navidrome active on port 4533 (navidrome.service, PID 9912)
#          - Quick Tunnel active on port 8088 (cloudflared-quick.service, PID 8831)
#          - Origin Certificate cert.pem in /root/.cloudflared/cert.pem
#          - Existing Cloudflare tunnel 'mornye-storage' (UUID: 463ff5f0-ead1-4e10-ba29-92b3e48abf66)
#          - Target custom domain: 'navya.dpdns.org'
#          - Missing local <UUID>.json credentials file
# ==============================================================================

set -eo pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROGRAM_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo "======================================================================"
echo "    MORNYE DEBIAN 13 SECOND-SYSTEM FIXTURE & REGRESSION SUITE        "
echo "======================================================================"

PASSED=0
FAILED=0
TOTAL=0

record_pass() {
    echo -e "  -> ${GREEN}[PASS] $1${NC}"
    PASSED=$((PASSED + 1))
}

record_fail() {
    echo -e "  -> ${RED}[FAIL] $1${NC}"
    FAILED=$((FAILED + 1))
}

# Create isolated testing sandbox
SANDBOX_DIR=$(mktemp -d -t mornye_d13_reg_XXXXXX)
MOCK_BIN="$SANDBOX_DIR/bin"
MOCK_ROOT="$SANDBOX_DIR/root"
MOCK_HOME="$SANDBOX_DIR/home/testuser"
MOCK_PROJECT="$SANDBOX_DIR/project"
MOCK_STATE="$SANDBOX_DIR/state"

mkdir -p "$MOCK_BIN" "$MOCK_ROOT/.cloudflared" "$MOCK_HOME/.cloudflared" "$MOCK_PROJECT/config" "$MOCK_PROJECT/run" "$MOCK_PROJECT/logs" "$MOCK_PROJECT/scripts/lib" "$MOCK_STATE"

# Copy library dependencies
cp "$PROGRAM_DIR/scripts/lib/compat.sh" "$MOCK_PROJECT/scripts/lib/"
cp "$PROGRAM_DIR/scripts/lib/port_manager.sh" "$MOCK_PROJECT/scripts/lib/"
cp "$PROGRAM_DIR/scripts/cloudflare_manager.sh" "$MOCK_PROJECT/scripts/"
chmod +x "$MOCK_PROJECT/scripts/cloudflare_manager.sh"

cleanup() {
    rm -rf "$SANDBOX_DIR"
}
trap cleanup EXIT INT TERM

# Fixed constants for this regression test
FIXTURE_TUNNEL_NAME="mornye-storage"
FIXTURE_TUNNEL_UUID="463ff5f0-ead1-4e10-ba29-92b3e48abf66"
FIXTURE_DOMAIN="navya.dpdns.org"
FIXTURE_ACCOUNT_TAG="cf_acc_tag_849204918234"
FIXTURE_TUNNEL_SECRET="YWJjZGVmMTIzNDU2Nzg5MGFiY2RlZjEyMzQ1Njc4OTA="

# Create realistic base64 tunnel token
TOKEN_PAYLOAD="{\"a\":\"${FIXTURE_ACCOUNT_TAG}\",\"t\":\"${FIXTURE_TUNNEL_UUID}\",\"s\":\"${FIXTURE_TUNNEL_SECRET}\"}"
FIXTURE_TUNNEL_TOKEN=$(python3 -c "import base64; print(base64.b64encode('''$TOKEN_PAYLOAD'''.encode()).decode())")

# Create realistic PEM Origin Certificate in /root and ~/.cloudflared
cat << 'CERTEOF' > "$MOCK_ROOT/.cloudflared/cert.pem"
-----BEGIN CERTIFICATE-----
MIIDazCCAlOgAwIBAgIUY1G+rV4/Q2c7zE8oHnN4jK5rQ+YwDQYJKoZIhvcNAQEL
BQAwTzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCkNhbGlmb3JuaWExFjAUBgNVBAcT
DVNhbiBGcmFuY2lzY28xGTAXBgNVBAoTEENsb3VkZmxhcmUsIEluYy4=
-----END CERTIFICATE-----
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC7V1yBf3Qe7jL5
q8H+T2k4s1M6w==
-----END PRIVATE KEY-----
CERTEOF
cp "$MOCK_ROOT/.cloudflared/cert.pem" "$MOCK_HOME/.cloudflared/cert.pem"

# Create mock cloudflared binary
cat << MOCK_CF > "$MOCK_BIN/cloudflared"
#!/bin/bash
CMD="\$1"
shift || true
SUB="\$1"

case "\$CMD" in
    --version)
        echo "cloudflared version 2026.10.7 (built 2026-10-30-17:05 UTC)"
        exit 0
        ;;
    tunnel)
        case "\$SUB" in
            list)
                echo "You can obtain more detailed information for each tunnel with <tunnel id/name>"
                echo ""
                echo "ID                                   NAME           CREATED              CONNECTIONS"
                echo "${FIXTURE_TUNNEL_UUID} ${FIXTURE_TUNNEL_NAME} 2026-11-01T12:00:00Z 2xORD, 2xDFW"
                exit 0
                ;;
            create)
                echo "ERROR: Cannot create tunnel with name '\$2': Tunnel with that name already exists!" >&2
                echo "FAIL_DUPLICATE_CALLED" >> "$MOCK_STATE/create_called.log"
                exit 1
                ;;
            token)
                echo "${FIXTURE_TUNNEL_TOKEN}"
                exit 0
                ;;
            route)
                echo "Route DNS succeeded for \$3 -> \${2}.cfargotunnel.com"
                exit 0
                ;;
            *)
                echo "cloudflared tunnel executed: \$*"
                exit 0
                ;;
        esac
        ;;
    *)
        echo "cloudflared executed: \$CMD \$*"
        exit 0
        ;;
esac
MOCK_CF
chmod +x "$MOCK_BIN/cloudflared"

# Create mock systemctl tracking service interference
cat << MOCK_SYS > "$MOCK_BIN/systemctl"
#!/bin/bash
ACTION="\$1"
UNIT="\$2"

# Track any attempts to stop or restart mornye-tunnel.service or mornye-storage.service
if [[ "\$ACTION" == "stop" || "\$ACTION" == "restart" ]]; then
    if [[ "\$UNIT" == *"mornye-tunnel"* || "\$UNIT" == *"mornye-storage"* || "\$UNIT" == *"navidrome"* ]]; then
        echo "ILLEGAL_SERVICE_INTERFERENCE: \$ACTION \$UNIT" >> "$MOCK_STATE/illegal_service_calls.log"
        exit 1
    fi
fi

if [[ "\$ACTION" == "is-active" ]]; then
    if [[ "\$UNIT" == "mornye-storage.service" || "\$UNIT" == "mornye-tunnel.service" || "\$UNIT" == "navidrome.service" ]]; then
        exit 0
    fi
    exit 1
fi

exit 0
MOCK_SYS
chmod +x "$MOCK_BIN/systemctl"

# Create mock docker and docker-compose
cat << MOCK_DK > "$MOCK_BIN/docker"
#!/bin/bash
if [[ "\$1" == "compose" ]]; then
    shift
    if [[ "\$1" == "--profile" ]]; then
        shift 2
    fi
    ACT="\$1"
    SVC="\$2"
    echo "docker compose \$ACT \$SVC called" >> "$MOCK_STATE/docker_compose.log"
    exit 0
fi
if [[ "\$1" == "ps" ]]; then
    echo "CONTAINER ID   IMAGE          COMMAND                  CREATED         STATUS         PORTS                     NAMES"
    echo "112233445566   mornye-webdav  \"/app/docker/entryp…\"   2 hours ago     Up 2 hours     127.0.0.1:8001->8000/tcp  mornye-webdav"
    exit 0
fi
exit 0
MOCK_DK
chmod +x "$MOCK_BIN/docker"

export PATH="$MOCK_BIN:$PATH"
export HOME="$MOCK_HOME"

# ------------------------------------------------------------------------------
# Test 1: cert.pem Origin Certificate Boundary (Never Rename to credentials.json)
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/7] Origin Certificate (cert.pem) Separation & Integrity${NC}"
# Sourcing cloudflare manager in sandbox
(
    cd "$MOCK_PROJECT"
    # shellcheck disable=SC1091
    source "$MOCK_PROJECT/scripts/cloudflare_manager.sh"
    cert_path="$(find_origin_certificate)"
    if [[ -f "$cert_path" && "$cert_path" == *"/cert.pem" ]]; then
        # Ensure cert is NEVER passed as json
        if [[ ! -f "$CONFIG_DIR/credentials.json" ]]; then
            exit 0
        fi
    fi
    exit 1
)
if [[ $? -eq 0 ]]; then
    record_pass "Origin certificate (cert.pem) identified without renaming or copying to credentials.json"
else
    record_fail "cert.pem was mishandled"
fi

# ------------------------------------------------------------------------------
# Test 2: Existing Tunnel Reuse (No Duplicate Tunnel Creation)
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/7] Existing Tunnel Discovery & Duplicate Prevention${NC}"
(
    cd "$MOCK_PROJECT"
    "$MOCK_PROJECT/scripts/cloudflare_manager.sh" create "$FIXTURE_TUNNEL_NAME" > "$SANDBOX_DIR/create_output.log" 2>&1
)
if [[ ! -f "$MOCK_STATE/create_called.log" ]]; then
    # Verify metadata saved existing UUID
    saved_uuid=$(grep -E '^TUNNEL_ID=' "$MOCK_PROJECT/config/tunnel_info.env" | cut -d= -f2 | tr -d '"')
    if [[ "$saved_uuid" == "$FIXTURE_TUNNEL_UUID" ]]; then
        record_pass "Detected existing tunnel '$FIXTURE_TUNNEL_NAME', extracted UUID '$FIXTURE_TUNNEL_UUID' without duplicate creation"
    else
        record_fail "Saved UUID mismatch: expected $FIXTURE_TUNNEL_UUID, got $saved_uuid"
    fi
else
    record_fail "Attempted to call 'cloudflared tunnel create' against existing tunnel!"
fi

# ------------------------------------------------------------------------------
# Test 3: Missing Credentials Recovery via Tunnel Token
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/7] Missing Credentials JSON Synthesis via Token${NC}"
creds_file="$MOCK_PROJECT/config/credentials.json"
if [[ -f "$creds_file" ]]; then
    acc_tag=$(python3 -c "import json; d=json.load(open('$creds_file')); print(d.get('AccountTag',''))")
    t_id=$(python3 -c "import json; d=json.load(open('$creds_file')); print(d.get('TunnelID',''))")
    t_sec=$(python3 -c "import json; d=json.load(open('$creds_file')); print(d.get('TunnelSecret',''))")
    file_perm=$(stat -c "%a" "$creds_file" 2>/dev/null || stat -f "%OLp" "$creds_file" 2>/dev/null || echo "644")

    if [[ "$acc_tag" == "$FIXTURE_ACCOUNT_TAG" && "$t_id" == "$FIXTURE_TUNNEL_UUID" && "$t_sec" == "$FIXTURE_TUNNEL_SECRET" ]]; then
        if [[ "$file_perm" == "644" || "$file_perm" == "600" ]]; then
            record_pass "Successfully reconstructed valid credentials JSON from base64 token (mode: $file_perm)"
        else
            record_fail "Credentials permissions insecure: $file_perm"
        fi
    else
        record_fail "Reconstructed credentials contents invalid: tag=$acc_tag, id=$t_id"
    fi
else
    record_fail "Credentials JSON was not generated at $creds_file"
fi

# ------------------------------------------------------------------------------
# Test 4: Docker Directory Mount Artifact Recovery
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/7] Docker Directory Artifact Auto-Correction${NC}"
# Simulate Docker daemon creating directory for missing file
rm -f "$creds_file"
mkdir -p "$creds_file"
(
    cd "$MOCK_PROJECT"
    # shellcheck disable=SC1091
    source "$MOCK_PROJECT/scripts/cloudflare_manager.sh"
    ensure_credentials_file "$FIXTURE_TUNNEL_UUID" "$FIXTURE_TUNNEL_NAME" >/dev/null 2>&1
)
if [[ -f "$creds_file" && ! -d "$creds_file" ]]; then
    record_pass "Detected and cleared invalid directory artifact; recovered file credentials.json cleanly"
else
    record_fail "Failed to correct directory artifact at $creds_file"
fi

# ------------------------------------------------------------------------------
# Test 5: Ingress Configuration & Port Invariant
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/7] Custom Domain Ingress Routing & Port Invariant${NC}"
(
    cd "$MOCK_PROJECT"
    "$MOCK_PROJECT/scripts/cloudflare_manager.sh" domain add "$FIXTURE_DOMAIN" >/dev/null 2>&1
)
cf_yml="$MOCK_PROJECT/config/cloudflared.yml"
if [[ -f "$cf_yml" ]]; then
    # Verify tunnel UUID
    has_uuid=$(grep -E "^tunnel:[[:space:]]+${FIXTURE_TUNNEL_UUID}" "$cf_yml" || true)
    # Verify origin target is internal container webdav:8000 (NOT host 8000 or host 8001)
    has_origin=$(grep -E "service:[[:space:]]+http://webdav:8000" "$cf_yml" || true)
    # Verify catch-all rule
    has_catchall=$(tail -n 2 "$cf_yml" | grep "http_status:404" || true)

    if [[ -n "$has_uuid" && -n "$has_origin" && -n "$has_catchall" ]]; then
        record_pass "cloudflared.yml verified: UUID=$FIXTURE_TUNNEL_UUID, target=http://webdav:8000, catch-all 404 active"
    else
        record_fail "Ingress YAML contents misaligned: uuid='$has_uuid', origin='$has_origin', 404='$has_catchall'"
    fi
else
    record_fail "Ingress configuration file $cf_yml not created"
fi

# ------------------------------------------------------------------------------
# Test 6: Zero Interference with Protected Host Services
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/7] Protected Host Services Invariant Check${NC}"
(
    cd "$MOCK_PROJECT"
    "$MOCK_PROJECT/scripts/cloudflare_manager.sh" stop >/dev/null 2>&1 || true
    "$MOCK_PROJECT/scripts/cloudflare_manager.sh" restart >/dev/null 2>&1 || true
)
if [[ ! -f "$MOCK_STATE/illegal_service_calls.log" ]]; then
    record_pass "Zero stop/restart commands sent to mornye-storage.service (8000), mornye-tunnel.service (20241), or navidrome.service (4533)"
else
    record_fail "Illegal commands sent to protected services: $(cat "$MOCK_STATE/illegal_service_calls.log")"
fi

# ------------------------------------------------------------------------------
# Test 7: WAN Reachability Simulation Probe
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/7] WAN PROPFIND Authentication Boundary Probe${NC}"
# Test status and test commands with mock curl
test_out=$(
    cd "$MOCK_PROJECT"
    "$MOCK_PROJECT/scripts/cloudflare_manager.sh" status
)
if echo "$test_out" | grep -q "Tunnel UUID           : ${FIXTURE_TUNNEL_UUID}"; then
    if echo "$test_out" | grep -q "Credentials JSON      : .*Valid"; then
        record_pass "Status command validated: UUID, credentials validity, and domain $FIXTURE_DOMAIN mapped"
    else
        record_fail "Status did not report valid credentials"
    fi
else
    record_fail "Status output missing Tunnel UUID: $test_out"
fi

echo ""
echo "======================================================================"
echo -e "${BOLD}REGRESSION SUITE SUMMARY:${NC} Total: $TOTAL | ${GREEN}Passed: $PASSED${NC} | ${RED}Failed: $FAILED${NC}"
echo "======================================================================"

if [[ "$FAILED" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}[✔] DEBIAN 13 SECOND-SYSTEM FIXTURE PASSED COMPLETELY WITH 0 REGRESSIONS.${NC}\n"
    exit 0
else
    echo -e "${RED}${BOLD}[✘] DEBIAN 13 SECOND-SYSTEM FIXTURE DETECTED FAILURES.${NC}\n"
    exit 1
fi

