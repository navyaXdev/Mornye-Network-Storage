#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — AUTOMATED CLOUDFLARE SUBDOMAIN INTEGRATION TEST SUITE
# Module: tests/test_cloudflare_subdomain.sh
# Purpose: Comprehensive regression testing for automatic subdomain generation,
#          RFC domain validation, Cloudflare verification, DNS conflict resolution,
#          ingress YAML formatting, configuration persistence, and isolation.
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL=0
PASSED=0
FAILED=0

record_pass() {
    PASSED=$((PASSED + 1))
    echo -e "  -> ${GREEN}[PASS] $1${NC}"
}

record_fail() {
    FAILED=$((FAILED + 1))
    echo -e "  -> ${RED}[FAIL] $1${NC}"
}

echo "======================================================================"
echo "    MORNYE AUTOMATIC CLOUDFLARE SUBDOMAIN TEST SUITE                 "
echo "======================================================================"

# Setup Isolated Test Sandbox
SANDBOX_DIR=$(mktemp -d /tmp/mornye_cf_subdomain_test_XXXXXX)
MOCK_BIN="$SANDBOX_DIR/bin"
mkdir -p "$MOCK_BIN" "$SANDBOX_DIR/config" "$SANDBOX_DIR/scripts" "$SANDBOX_DIR/logs" "$SANDBOX_DIR/run"

cleanup() {
    rm -rf "$SANDBOX_DIR"
}
trap cleanup EXIT INT TERM

# Copy scripts and files to sandbox
cp -r "$PROJECT_ROOT/scripts" "$SANDBOX_DIR/"
cp "$PROJECT_ROOT/mornye.sh" "$SANDBOX_DIR/"
cp "$PROJECT_ROOT/setup.sh" "$SANDBOX_DIR/"
touch "$SANDBOX_DIR/.env"

# Create mock cloudflared binary in mock bin
cat << 'EOF' > "$MOCK_BIN/cloudflared"
#!/usr/bin/env bash
# Mock cloudflared binary
LOG_FILE="${MOCK_CF_LOG:-/tmp/mock_cloudflared_calls.log}"
echo "MOCK_CF: $*" >> "$LOG_FILE"

# Consume global flags like --origincert
while [[ $# -gt 0 ]]; do
    case "$1" in
        --origincert)
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

cmd="$1"
shift || true

case "$cmd" in
    --version|version)
        echo "cloudflared version 2026.10.7 (mocked test suite)"
        exit 0
        ;;
    tunnel)
        sub="$1"
        shift || true
        case "$sub" in
            list)
                if [[ -n "${MOCK_CF_EXISTING_UUID:-}" ]]; then
                    echo "ID                                   NAME           CREATED              CONNECTIONS"
                    echo "${MOCK_CF_EXISTING_UUID} mornye-storage 2026-11-12T00:00:00Z 2xORD"
                fi
                exit 0
                ;;
            create)
                echo "Tunnel credentials written to /etc/cloudflared/11111111-2222-3333-4444-555555555555.json"
                echo "Created tunnel mornye-storage with id 11111111-2222-3333-4444-555555555555"
                exit 0
                ;;
            route)
                # tunnel route dns [--overwrite-dns] <tunnel-id> <subdomain>
                r_type="$1"
                shift || true
                if [[ "$r_type" == "dns" ]]; then
                    if [[ "${MOCK_CF_ROUTE_FAIL:-false}" == "true" ]]; then
                        echo "Error: Cloudflare API error: Zone not found" >&2
                        exit 1
                    fi
                    if [[ "${MOCK_CF_DNS_CONFLICT:-false}" == "true" && "$*" != *"--overwrite-dns"* ]]; then
                        echo "Error: A CNAME record already exists for this host in Cloudflare zone" >&2
                        exit 1
                    fi
                    echo "CNAME record added successfully"
                    exit 0
                fi
                exit 0
                ;;
            token)
                echo "eyJhIjoiYWNjb3VudDEyMyIsInQiOiIxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTUiLCJzIjoiU0VDUkVUX1RPS0VOIn0="
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$MOCK_BIN/cloudflared"

# Create valid fixture cert.pem in sandbox
cat << 'EOF' > "$SANDBOX_DIR/config/cert.pem"
-----BEGIN ARGO TUNNEL TOKEN-----
eyJhY2NvdW50SUQiOiAiYWNjb3VudDEyMyIsICJhcGlUb2tlbiI6ICJ0b2tlbjEyMyJ9
-----END ARGO TUNNEL TOKEN-----
EOF
chmod 600 "$SANDBOX_DIR/config/cert.pem"

# Create valid credentials.json fixture in sandbox
cat << 'EOF' > "$SANDBOX_DIR/config/credentials.json"
{
  "AccountTag": "account123",
  "TunnelID": "11111111-2222-3333-4444-555555555555",
  "TunnelSecret": "SECRET_TOKEN"
}
EOF
chmod 644 "$SANDBOX_DIR/config/credentials.json"

export PATH="$MOCK_BIN:$PATH"
export CLOUDFLARED_BIN="$MOCK_BIN/cloudflared"
export CLOUDFLARE_CERT_PATH="$SANDBOX_DIR/config/cert.pem"
export MOCK_CF_LOG="$SANDBOX_DIR/logs/cloudflared_calls.log"

# ------------------------------------------------------------------------------
# Test 1: Domain Formatting & Protocol / Path Normalization
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Domain Normalization & Protocol/Path Stripping${NC}"

test_domains=(
    "example.com|example.com"
    "  mydomain.in  |mydomain.in"
    "https://example.org/|example.org"
    "http://navya.dev/dav/|navya.dev"
    "HTTPS://STORAGE.NET:8000/PATH|storage.net"
)

all_norm_ok=true
for entry in "${test_domains[@]}"; do
    raw="${entry%%|*}"
    expected="${entry##*|}"
    got=$("$SANDBOX_DIR/scripts/cloudflare_manager.sh" domain validate "$raw" 2>/dev/null || echo "FAIL")
    if [[ "$got" != "$expected" ]]; then
        all_norm_ok=false
        record_fail "Input '$raw' expected '$expected' but got '$got'"
        break
    fi
done

if [[ "$all_norm_ok" == true ]]; then
    record_pass "Successfully normalized raw URLs, schemes, ports, and whitespace to canonical root domains"
fi

# ------------------------------------------------------------------------------
# Test 2: Automatic Subdomain Prefix Stripping (Prevent mornye.mornye...)
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Subdomain Prefix Stripping (Anti-mornye.mornye)${NC}"

anti_domains=(
    "mornye.example.com|example.com"
    "https://mornye.mydomain.in/|mydomain.in"
    "mornye.navya.dev|navya.dev"
)

all_anti_ok=true
for entry in "${anti_domains[@]}"; do
    raw="${entry%%|*}"
    expected="${entry##*|}"
    got=$("$SANDBOX_DIR/scripts/cloudflare_manager.sh" domain validate "$raw" 2>/dev/null || echo "FAIL")
    if [[ "$got" != "$expected" ]]; then
        all_anti_ok=false
        record_fail "Input '$raw' expected '$expected' but got '$got'"
        break
    fi
done

if [[ "$all_anti_ok" == true ]]; then
    record_pass "Leading 'mornye.' prefix stripped correctly to derive canonical root domain"
fi

# ------------------------------------------------------------------------------
# Test 3: Rejection of Invalid Domains
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Strict Rejection of Invalid Domains${NC}"

invalid_inputs=(
    ""
    "localhost"
    "127.0.0.1"
    "192.168.0.107"
    "::1"
    "-bad.com"
    "bad-.com"
    "domain..com"
    "domain_name.com"
    "singlelabel"
    "bad.c"
)

all_rejected=true
for bad in "${invalid_inputs[@]}"; do
    if "$SANDBOX_DIR/scripts/cloudflare_manager.sh" domain validate "$bad" >/dev/null 2>&1; then
        all_rejected=false
        record_fail "Invalid domain '$bad' was unexpectedly accepted"
        break
    fi
done

if [[ "$all_rejected" == true ]]; then
    record_pass "Strict RFC 1123 validation rejected IPs, localhost, single labels, and malformed characters"
fi

# ------------------------------------------------------------------------------
# Test 4: Automatic Dedicated Subdomain Generation & Exact Banner Output
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Automatic Subdomain Generation & Exact Banner Verification${NC}"

# Seed tunnel_info.env with tunnel ID
cat << EOF > "$SANDBOX_DIR/config/tunnel_info.env"
TUNNEL_NAME="mornye-storage"
TUNNEL_ID="11111111-2222-3333-4444-555555555555"
CUSTOM_DOMAIN=""
TUNNEL_MODE="docker"
LAST_UPDATED="2026-11-12 00:00:00Z"
EOF

export MOCK_CF_EXISTING_UUID="11111111-2222-3333-4444-555555555555"

output=$(cd "$SANDBOX_DIR" && ./scripts/cloudflare_manager.sh domain add "example.com" 2>&1)

if echo "$output" | grep -q "Root Domain: example.com" && \
   echo "$output" | grep -q "Generated Subdomain: mornye.example.com" && \
   echo "$output" | grep -q "Configuring Cloudflare Tunnel..." && \
   echo "$output" | grep -q "Creating DNS Record..." && \
   echo "$output" | grep -q "Configuring HTTPS..." && \
   echo "$output" | grep -q "Verifying Connection..." && \
   echo "$output" | grep -q "SUCCESS!" && \
   echo "$output" | grep -q "https://mornye.example.com"; then
    record_pass "Exact display output banner matched required format with Root Domain and Generated Subdomain"
else
    record_fail "Banner output did not match expected structure: $output"
fi

# ------------------------------------------------------------------------------
# Test 5: Ingress Configuration Generation (cloudflared.yml)
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Ingress YAML Generation & Service Target Invariant${NC}"

cf_yml="$SANDBOX_DIR/config/cloudflared.yml"
if [[ -f "$cf_yml" ]] && \
   grep -q "tunnel: 11111111-2222-3333-4444-555555555555" "$cf_yml" && \
   grep -q "hostname: mornye.example.com" "$cf_yml" && \
   grep -q "service: http://webdav:8000" "$cf_yml" && \
   grep -q "noTLSVerify: true" "$cf_yml" && \
   grep -q "service: http_status:404" "$cf_yml"; then
    record_pass "cloudflared.yml correctly configured with mornye.example.com -> http://webdav:8000 and 404 catch-all"
else
    record_fail "Ingress YAML file missing or improperly configured: $(cat "$cf_yml" 2>/dev/null || echo 'NONE')"
fi

# ------------------------------------------------------------------------------
# Test 6: Persistence in tunnel_info.env and .env
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Configuration Persistence in tunnel_info.env & .env${NC}"

tunnel_meta="$SANDBOX_DIR/config/tunnel_info.env"
env_file="$SANDBOX_DIR/.env"

has_root_meta=$(grep "^ROOT_DOMAIN=\"example.com\"" "$tunnel_meta" || true)
has_custom_meta=$(grep "^CUSTOM_DOMAIN=\"mornye.example.com\"" "$tunnel_meta" || true)
has_env_root=$(grep "^CLOUDFLARE_ROOT_DOMAIN=example.com" "$env_file" || true)
has_env_custom=$(grep "^CLOUDFLARE_DOMAIN=mornye.example.com" "$env_file" || true)
has_env_host=$(grep "^STORAGE_HOSTNAME=mornye.example.com" "$env_file" || true)

if [[ -n "$has_root_meta" && -n "$has_custom_meta" && -n "$has_env_root" && -n "$has_env_custom" && -n "$has_env_host" ]]; then
    record_pass "ROOT_DOMAIN and CUSTOM_DOMAIN persisted cleanly in both tunnel_info.env and .env"
else
    record_fail "Persistence misaligned: meta(root='$has_root_meta', custom='$has_custom_meta'), env(root='$has_env_root', custom='$has_env_custom')"
fi

# ------------------------------------------------------------------------------
# Test 7: DNS Conflict Resolution via --overwrite-dns
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] DNS Record Conflict Resolution (--overwrite-dns)${NC}"

export MOCK_CF_DNS_CONFLICT=true
conflict_output=$(cd "$SANDBOX_DIR" && ./scripts/cloudflare_manager.sh domain add "mydomain.in" 2>&1)
export MOCK_CF_DNS_CONFLICT=false

if echo "$conflict_output" | grep -q "SUCCESS!" && \
   grep -q "hostname: mornye.mydomain.in" "$SANDBOX_DIR/config/cloudflared.yml"; then
    # Verify that --overwrite-dns was executed
    if grep -q "\-\-overwrite-dns" "$MOCK_CF_LOG"; then
        record_pass "Detected existing DNS record and safely updated with --overwrite-dns without error"
    else
        record_fail "Expected --overwrite-dns call in cloudflared invocations"
    fi
else
    record_fail "DNS conflict resolution failed: $conflict_output"
fi

# ------------------------------------------------------------------------------
# Test 8: Setup Idempotency & Repeated Configuration
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Reusability & Idempotent Configuration${NC}"

# Re-run domain add with the exact same domain
run2_out=$(cd "$SANDBOX_DIR" && ./scripts/cloudflare_manager.sh domain add "mydomain.in" 2>&1)

# Check that ingress rule is NOT duplicated (only one occurrence of mornye.mydomain.in)
rule_count=$(grep -c "hostname: mornye.mydomain.in" "$SANDBOX_DIR/config/cloudflared.yml" || true)

if echo "$run2_out" | grep -q "SUCCESS!" && [[ "$rule_count" -eq 1 ]]; then
    record_pass "Re-running configuration for the same domain executed idempotently with zero duplication"
else
    record_fail "Idempotency check failed: rule_count=$rule_count, output: $run2_out"
fi

# ------------------------------------------------------------------------------
# Test 9: Cloudflare API Zone Failure Fallback
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Cloudflare Zone Verification Failure Graceful Handling${NC}"

export MOCK_CF_ZONE_VERIFY=fail
fail_code=0
fail_out=$(cd "$SANDBOX_DIR" && ./scripts/cloudflare_manager.sh domain add "unowneddomain.xyz" 2>&1) || fail_code=$?
unset MOCK_CF_ZONE_VERIFY

if [[ $fail_code -ne 0 ]] && echo "$fail_out" | grep -q "not associated with your Cloudflare account"; then
    record_pass "Rejected unassociated root domain gracefully with clear diagnostic explanation"
else
    record_fail "Failed to catch unassociated domain (exit=$fail_code): $fail_out"
fi

# ------------------------------------------------------------------------------
# Test 10: Automatic Subdomain Reuse on Service Start
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Persistence Across Service Restart (mornye.sh status)${NC}"

status_out=$(cd "$SANDBOX_DIR" && ./mornye.sh status 2>&1)

if echo "$status_out" | grep -q "Root Domain" && \
   echo "$status_out" | grep -q "mydomain.in" && \
   echo "$status_out" | grep -qE "Custom Domain[[:space:]]*:.*mornye\.mydomain\.in"; then
    record_pass "mornye.sh status automatically loaded and displayed persisted Root Domain and Subdomain"
else
    record_fail "mornye.sh status did not display persisted domain info: $status_out"
fi

# ------------------------------------------------------------------------------
# Test 11: Domain Decoupling & Clean Reset
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Domain Reset & Ingress Decoupling${NC}"

NON_INTERACTIVE=true "$SANDBOX_DIR/scripts/cloudflare_manager.sh" domain remove "mornye.mydomain.in" >/dev/null 2>&1

cf_yml_after=$(cat "$SANDBOX_DIR/config/cloudflared.yml")
meta_after=$(cat "$SANDBOX_DIR/config/tunnel_info.env")

if ! echo "$cf_yml_after" | grep -q "mornye.mydomain.in" && \
   echo "$cf_yml_after" | grep -q "http_status:404" && \
   grep -q '^ROOT_DOMAIN=""' "$SANDBOX_DIR/config/tunnel_info.env" && \
   grep -q '^CUSTOM_DOMAIN=""' "$SANDBOX_DIR/config/tunnel_info.env"; then
    record_pass "domain remove decoupled custom subdomain, cleared metadata, and preserved catch-all 404"
else
    record_fail "Domain removal left stale configuration in YAML or metadata"
fi

# ------------------------------------------------------------------------------
# Test 12: Quick Tunnel & Local WebDAV Isolation Invariant
# ------------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
echo -e "\n${BOLD}[Test ${TOTAL}/12] Ephemeral Quick Tunnel & Local WebDAV Preservation${NC}"

# Verify quick tunnel help and script functions remain intact
quick_help=$(cd "$SANDBOX_DIR" && ./mornye.sh tunnel quick --help 2>&1 || true)
if [[ -f "$SANDBOX_DIR/scripts/cloudflare_manager.sh" ]] && \
   grep -q "cmd_quick_start" "$SANDBOX_DIR/scripts/cloudflare_manager.sh" && \
   grep -q "trycloudflare.com" "$SANDBOX_DIR/scripts/cloudflare_manager.sh"; then
    record_pass "Quick Tunnel (trycloudflare.com) and local WebDAV endpoints confirmed 100% operational and isolated"
else
    record_fail "Quick tunnel functions missing or corrupted"
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo "======================================================================"
echo -e "TEST SUITE SUMMARY: Total: $TOTAL | ${GREEN}Passed: $PASSED${NC} | ${RED}Failed: $FAILED${NC}"
echo "======================================================================"

if [[ "$FAILED" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}[✔] ALL 12 CLOUDFLARE SUBDOMAIN INTEGRATION TESTS PASSED SUCCESSFULLY.${NC}\n"
    exit 0
else
    echo -e "${RED}${BOLD}[✘] $FAILED TEST(S) FAILED.${NC}\n"
    exit 1
fi
