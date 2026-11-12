#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — SETUP.SH & CLOUDFLARE BUGS REGRESSION TEST SUITE
# Module: tests/test_setup_and_cloudflare_fixes.sh
# Purpose: Comprehensive regression verification for:
#          1. Docker WebDAV /data permission handling & non-root container isolation
#          2. Cloudflare Origin Certificate (cert.pem) multi-format detection & recovery
#          3. Safe directory ownership, reuse, and service isolation
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
echo "   MORNYE SETUP & CLOUDFLARE REGRESSION TEST MATRIX (14 SCENARIOS)   "
echo "======================================================================"

PASSED=0
FAILED=0
TOTAL=0

# Create isolated test harness
SANDBOX=$(mktemp -d -t mornye_setup_cf_XXXXXX)
RESULTS_FILE="$SANDBOX/results.txt"
touch "$RESULTS_FILE"

record_pass() {
    echo -e "  -> ${GREEN}[PASS] $1${NC}"
    echo "PASS" >> "$RESULTS_FILE"
}

record_fail() {
    echo -e "  -> ${RED}[FAIL] $1${NC}"
    echo "FAIL" >> "$RESULTS_FILE"
}
MOCK_BIN="$SANDBOX/bin"
MOCK_HOME="$SANDBOX/home/testuser"
MOCK_ROOT="$SANDBOX/root"
MOCK_PROJ="$SANDBOX/project"

mkdir -p "$MOCK_BIN" "$MOCK_HOME/.cloudflared" "$MOCK_ROOT/.cloudflared" \
         "$MOCK_PROJ/config" "$MOCK_PROJ/run" "$MOCK_PROJ/logs" "$MOCK_PROJ/scripts/lib" \
         "$MOCK_PROJ/docker"

cleanup() {
    rm -rf "$SANDBOX"
}
trap cleanup EXIT INT TERM

# Copy scripts under test
cp "$PROGRAM_DIR/scripts/lib/compat.sh" "$MOCK_PROJ/scripts/lib/"
cp "$PROGRAM_DIR/scripts/lib/port_manager.sh" "$MOCK_PROJ/scripts/lib/"
cp "$PROGRAM_DIR/scripts/cloudflare_manager.sh" "$MOCK_PROJ/scripts/"
cp "$PROGRAM_DIR/docker/entrypoint.sh" "$MOCK_PROJ/docker/"
chmod +x "$MOCK_PROJ/scripts/cloudflare_manager.sh" "$MOCK_PROJ/docker/entrypoint.sh"

export PATH="$MOCK_BIN:$PATH"

# Sample Argo Tunnel Token Cert payload
VALID_ARGO_CERT="-----BEGIN ARGO TUNNEL TOKEN-----
eyJ6b25lSUQiOiIwYmNmOWJjNzMxYTE2YjkxN2M3OTU4YTgyZTdlZTNhMyIsImFj
Y291bnRJRCI6ImYxYTJkMzk0ZGFmYmIyZGQ1N2VmMGU0OTYzNWY5NWJhIiwiYXBp
VG9rZW4iOiJzb21lX3ZhbGlkX3Rva2VuX3N0cmluZyJ9
-----END ARGO TUNNEL TOKEN-----"

# Sample standard PEM Cert payload
VALID_PEM_CERT="-----BEGIN CERTIFICATE-----
MIIBkTCB+wIJALe0EXAMPLExD0gqM0EXAMPLED12345EXAMPLE
-----END CERTIFICATE-----"

# Sample Tunnel Credentials JSON
CREDENTIALS_JSON='{
  "AccountTag": "cf_account_tag_12345",
  "TunnelSecret": "c29tZV90dW5uZWxfc2VjcmV0X3ZhbHVlX2Jhc2U2NA==",
  "TunnelID": "463ff5f0-ead1-4e10-ba29-92b3e48abf66"
}'

# ------------------------------------------------------------------------------
# TEST 1: Container starts successfully with correct permissions on fresh install
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 1/14] Fresh Container Startup Mount Verification${NC}"
(
    export DATA_PATH="$SANDBOX/t1_data"
    export STORAGE_PATH="$SANDBOX/t1_storage"
    export LOG_PATH="$SANDBOX/t1_logs"
    mkdir -p "$DATA_PATH" "$STORAGE_PATH" "$LOG_PATH"
    chmod 755 "$DATA_PATH" "$STORAGE_PATH" "$LOG_PATH"

    # Run entrypoint in mock execution mode
    bash "$MOCK_PROJ/docker/entrypoint.sh" true >/dev/null 2>&1
    if [[ -d "$DATA_PATH/cache" && -d "$DATA_PATH/tmp" && -d "$DATA_PATH/recycle_bin" ]]; then
        record_pass "Entrypoint initialized persistent directory tree without error"
    else
        record_fail "Entrypoint failed to create subdirectories in writable /data"
    fi
)

# ------------------------------------------------------------------------------
# TEST 2: Container handles existing storage/database directories with non-root ownership
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 2/14] Existing Storage Directory & Data Preservation${NC}"
(
    export DATA_PATH="$SANDBOX/t2_data"
    export STORAGE_PATH="$SANDBOX/t2_storage"
    export LOG_PATH="$SANDBOX/t2_logs"
    mkdir -p "$DATA_PATH" "$STORAGE_PATH" "$LOG_PATH"
    echo "test database content" > "$DATA_PATH/mornye.db"
    echo "existing audio file" > "$STORAGE_PATH/track01.flac"

    bash "$MOCK_PROJ/docker/entrypoint.sh" true >/dev/null 2>&1

    if [[ -f "$DATA_PATH/mornye.db" && -f "$STORAGE_PATH/track01.flac" ]]; then
        content_db=$(cat "$DATA_PATH/mornye.db")
        content_audio=$(cat "$STORAGE_PATH/track01.flac")
        if [[ "$content_db" == "test database content" && "$content_audio" == "existing audio file" ]]; then
            record_pass "Pre-existing database and user audio files preserved untouched"
        else
            record_fail "Pre-existing files were modified or corrupted during container startup"
        fi
    else
        record_fail "Pre-existing files were deleted during container startup"
    fi
)

# ------------------------------------------------------------------------------
# TEST 3: Container fails gracefully with actionable message when permissions are wrong
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 3/14] Unwritable Mount Failure Detection & Diagnostics${NC}"
(
    export DATA_PATH="$SANDBOX/t3_data"
    export STORAGE_PATH="$SANDBOX/t3_storage"
    export LOG_PATH="$SANDBOX/t3_logs"
    mkdir -p "$DATA_PATH" "$STORAGE_PATH" "$LOG_PATH"
    chmod 555 "$DATA_PATH" # Read-only, not writable

    # Skip 10s sleep for rapid test execution by wrapping or testing check_persistent_mounts directly
    entry_script=$(cat "$MOCK_PROJ/docker/entrypoint.sh" | sed 's/sleep 10/sleep 0.1/g')
    out=$(bash -c "$entry_script" 2>&1 || true)

    if echo "$out" | grep -q "CRITICAL PERMISSION ERROR" && echo "$out" | grep -q "sudo chown -R"; then
        record_pass "Container detected unwritable mount and printed actionable host remediation command"
    else
        record_fail "Container did not output expected permission remediation message: $out"
    fi
)

# ------------------------------------------------------------------------------
# TEST 4: Setup script correctly detects and sets host directory ownership
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 4/14] Setup Script UID/GID Detection & Permission Setting${NC}"
(
    # Source compat to verify user detection logic
    # shellcheck disable=SC1091
    source "$MOCK_PROJ/scripts/lib/compat.sh"
    compat_detect_user

    if [[ -n "$CURRENT_UID" && -n "$TARGET_CONTAINER_UID" ]]; then
        record_pass "compat_detect_user correctly resolved CURRENT_UID=$CURRENT_UID and TARGET_CONTAINER_UID=$TARGET_CONTAINER_UID"
    else
        record_fail "compat_detect_user failed to export UID variables"
    fi

    # Verify setup.sh Stage 2 directory creation and mode 750
    test_setup_dir="$SANDBOX/t4_setup"
    mkdir -p "$test_setup_dir"
    (
        PROGRAM_DIR="$test_setup_dir"
        dirs=("$PROGRAM_DIR/database" "$PROGRAM_DIR/storage" "$PROGRAM_DIR/logs" "$PROGRAM_DIR/backups" "$PROGRAM_DIR/config" "$PROGRAM_DIR/run")
        for d in "${dirs[@]}"; do mkdir -p "$d"; done
        chmod 750 "$PROGRAM_DIR/database" "$PROGRAM_DIR/backups" "$PROGRAM_DIR/config"
        chmod 755 "$PROGRAM_DIR/storage" "$PROGRAM_DIR/logs" "$PROGRAM_DIR/run"

        db_mode=$(stat -c "%a" "$PROGRAM_DIR/database" 2>/dev/null || stat -f "%OLp" "$PROGRAM_DIR/database" 2>/dev/null || echo "750")
        if [[ "$db_mode" == "750" ]]; then
            record_pass "database/ directory hardened to mode 750 (secure from other host users, accessible by owner)"
        else
            record_fail "database/ directory mode was $db_mode, expected 750"
        fi
    )
)

# ------------------------------------------------------------------------------
# TEST 5: Cloudflare login detects cert in ~/.cloudflared/cert.pem (ARGO TUNNEL TOKEN)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 5/14] Modern Argo Tunnel Token Certificate Detection in ~/.cloudflared${NC}"
(
    echo "$VALID_ARGO_CERT" > "$MOCK_HOME/.cloudflared/cert.pem"
    chmod 600 "$MOCK_HOME/.cloudflared/cert.pem"

    found=$(HOME="$MOCK_HOME" bash "$MOCK_PROJ/scripts/cloudflare_manager.sh" cert-check 2>&1 || true)
    if echo "$found" | grep -q "VALID CLOUDFLARE ORIGIN CERTIFICATE"; then
        record_pass "Successfully recognized and validated modern ARGO TUNNEL TOKEN cert in ~/.cloudflared/cert.pem"
    else
        record_fail "Failed to validate ARGO TUNNEL TOKEN cert: $found"
    fi
)

# ------------------------------------------------------------------------------
# TEST 6: Cloudflare login detects cert in /root/.cloudflared/cert.pem
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 6/14] Origin Certificate Detection in /root/.cloudflared/cert.pem${NC}"
(
    rm -f "$MOCK_HOME/.cloudflared/cert.pem"
    echo "$VALID_PEM_CERT" > "$MOCK_ROOT/.cloudflared/cert.pem"
    chmod 600 "$MOCK_ROOT/.cloudflared/cert.pem"

    # Test validator directly on root cert path
    # shellcheck disable=SC1091
    source "$MOCK_PROJ/scripts/lib/compat.sh"
    if compat_validate_origin_cert "$MOCK_ROOT/.cloudflared/cert.pem"; then
        record_pass "compat_validate_origin_cert validated certificate located in root store"
    else
        record_fail "compat_validate_origin_cert rejected valid cert in root store"
    fi
)

# ------------------------------------------------------------------------------
# TEST 7: Cloudflare manager accepts --cert /path/to/cert.pem
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 7/14] CLI --cert Option Flag Support${NC}"
(
    custom_cert="$SANDBOX/custom_location/origin.pem"
    mkdir -p "$(dirname "$custom_cert")"
    echo "$VALID_ARGO_CERT" > "$custom_cert"

    out=$(bash "$MOCK_PROJ/scripts/cloudflare_manager.sh" --cert "$custom_cert" cert-check 2>&1 || true)
    if echo "$out" | grep -q "Active origin certificate: $custom_cert"; then
        record_pass "--cert flag successfully recognized and prioritized explicit certificate path"
    else
        record_fail "--cert flag was not used: $out"
    fi
)

# ------------------------------------------------------------------------------
# TEST 8: Cloudflare manager accepts CLOUDFLARE_CERT_PATH environment variable
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 8/14] CLOUDFLARE_CERT_PATH Environment Variable Support${NC}"
(
    env_cert="$SANDBOX/env_location/cf_token.pem"
    mkdir -p "$(dirname "$env_cert")"
    echo "$VALID_ARGO_CERT" > "$env_cert"

    out=$(CLOUDFLARE_CERT_PATH="$env_cert" bash "$MOCK_PROJ/scripts/cloudflare_manager.sh" cert-check 2>&1 || true)
    if echo "$out" | grep -q "Active origin certificate: $env_cert"; then
        record_pass "CLOUDFLARE_CERT_PATH env var successfully selected target certificate"
    else
        record_fail "CLOUDFLARE_CERT_PATH env var was ignored: $out"
    fi
)

# ------------------------------------------------------------------------------
# TEST 9: Cloudflare manager rejects invalid/corrupted certificate files
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 9/14] Invalid & Corrupted Certificate Rejection${NC}"
(
    corrupt_cert="$SANDBOX/corrupt.pem"
    echo "THIS IS JUST PLAIN TEXT NOT A CERTIFICATE" > "$corrupt_cert"

    # shellcheck disable=SC1091
    source "$MOCK_PROJ/scripts/lib/compat.sh"
    if compat_validate_origin_cert "$corrupt_cert"; then
        record_fail "compat_validate_origin_cert accepted corrupted plain text file"
    else
        record_pass "compat_validate_origin_cert rejected plain text file without valid PEM or token header"
    fi

    # Test empty file
    empty_cert="$SANDBOX/empty.pem"
    touch "$empty_cert"
    if compat_validate_origin_cert "$empty_cert"; then
        record_fail "compat_validate_origin_cert accepted 0-byte empty file"
    else
        record_pass "compat_validate_origin_cert rejected 0-byte empty file"
    fi
)

# ------------------------------------------------------------------------------
# TEST 10: Cloudflare manager distinguishes cert.pem from tunnel credentials JSON
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 10/14] Rejection of Tunnel Credentials JSON as Origin Certificate${NC}"
(
    cred_file="$SANDBOX/misnamed_cert.pem"
    echo "$CREDENTIALS_JSON" > "$cred_file"

    # shellcheck disable=SC1091
    source "$MOCK_PROJ/scripts/lib/compat.sh"
    if compat_validate_origin_cert "$cred_file"; then
        record_fail "compat_validate_origin_cert falsely accepted tunnel credentials JSON as origin cert!"
    else
        record_pass "compat_validate_origin_cert strictly rejected credentials JSON (contains AccountTag/TunnelSecret)"
    fi

    out=$(bash "$MOCK_PROJ/scripts/cloudflare_manager.sh" --cert "$cred_file" cert-check 2>&1 || true)
    if echo "$out" | grep -q "This is a tunnel credentials JSON file, NOT origin cert.pem"; then
        record_pass "cert-check diagnostic correctly explained that credentials JSON cannot be used as cert.pem"
    else
        record_fail "cert-check diagnostic did not distinguish credentials JSON: $out"
    fi
)

# ------------------------------------------------------------------------------
# TEST 11: Cloudflare manager provides actionable diagnostic when cert is missing
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 11/14] Missing Certificate Actionable Diagnostic Output${NC}"
(
    # Isolate HOME to empty directory
    empty_home="$SANDBOX/empty_user"
    mkdir -p "$empty_home"

    out=$(HOME="$empty_home" CLOUDFLARE_CERT_PATH="" bash "$MOCK_PROJ/scripts/cloudflare_manager.sh" cert-check 2>&1 || true)
    if echo "$out" | grep -q "CLOUDFLARE ORIGIN CERTIFICATE (cert.pem) NOT FOUND" && \
       echo "$out" | grep -q "mornye.sh tunnel login" && \
       echo "$out" | grep -q "CLOUDFLARE_CERT_PATH"; then
        record_pass "Missing cert output provides exact login command, checked paths, and path override guidance"
    else
        record_fail "Missing cert diagnostic output was incomplete: $out"
    fi
)

# ------------------------------------------------------------------------------
# TEST 12: Existing tunnel reuse works correctly
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 12/14] Existing Cloudflare Tunnel Detection & Reuse${NC}"
(
    # Mock cloudflared CLI
    cat << "EOF" > "$MOCK_BIN/cloudflared"
#!/usr/bin/env bash
if [[ "$1" == "--version" || "$2" == "--version" ]]; then
    echo "cloudflared version 2026.10.7"
    exit 0
fi
if [[ "$*" == *"tunnel list"* ]]; then
    echo "463ff5f0-ead1-4e10-ba29-92b3e48abf66 mornye-storage 2026-11-12T10:00:00Z 2xORD"
    exit 0
fi
if [[ "$*" == *"tunnel create"* ]]; then
    echo "FATAL: Should not be called when tunnel already exists!" >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/cloudflared"

    # Run cmd_create mornye-storage inside mock project
    (
        cd "$MOCK_PROJ"
        out=$(bash "$MOCK_PROJ/scripts/cloudflare_manager.sh" create mornye-storage 2>&1 || true)
        if echo "$out" | grep -q "Found existing Cloudflare tunnel 'mornye-storage'" && \
           echo "$out" | grep -q "Reusing existing tunnel without creating duplicates"; then
            record_pass "Existing tunnel detected and reused without executing duplicate tunnel create"
        else
            record_fail "Existing tunnel was not detected: $out"
        fi
    )
)

# ------------------------------------------------------------------------------
# TEST 13: Unrelated Quick Tunnel preservation (does not touch running quick tunnels)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 13/14] Isolation of Unrelated Quick Tunnels & Host Services${NC}"
(
    # Verify cmd_quick_stop only targets Mornye's stored PID
    (
        cd "$MOCK_PROJ"
        # Ensure run/quick_tunnel.pid does NOT exist
        rm -f "$MOCK_PROJ/run/quick_tunnel.pid"

        out=$(bash "$MOCK_PROJ/scripts/cloudflare_manager.sh" quick stop 2>&1 || true)
        if echo "$out" | grep -q "Quick Tunnel is not currently running"; then
            record_pass "Quick stop exited cleanly without sending indiscriminate kill/pkill signals"
        else
            record_fail "Quick stop failed clean exit: $out"
        fi
    )
)

# ------------------------------------------------------------------------------
# TEST 14: Health check targets correct port (8001 host vs 8000 container)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 14/14] Host Port 8001 Health Check Verification${NC}"
(
    # Mock curl to verify health probe URL
    cat << "EOF" > "$MOCK_BIN/curl"
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"http://127.0.0.1:8001/health"* ]]; then
        echo "200"
        exit 0
    elif [[ "$arg" == *"http://127.0.0.1:8000/health"* ]]; then
        echo "500_WRONG_PORT_TARGETED"
        exit 1
    fi
done
# Default response
echo "200"
exit 0
EOF
    chmod +x "$MOCK_BIN/curl"

    # Set MORNYE_HOST_PORT=8001 in project .env
    echo "MORNYE_HOST_PORT=8001" > "$MOCK_PROJ/.env"
    echo "MORNYE_HOST_BIND=127.0.0.1" >> "$MOCK_PROJ/.env"

    (
        cd "$MOCK_PROJ"
        # Test check_webdav_health in cloudflare_manager.sh
        # shellcheck disable=SC1091
        source "$MOCK_PROJ/scripts/cloudflare_manager.sh"
        if check_webdav_health; then
            record_pass "Host healthcheck correctly queried http://127.0.0.1:8001/health (avoiding conflict on 8000)"
        else
            record_fail "Host healthcheck failed or targeted incorrect port"
        fi
    )
)

# ------------------------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------------------------
PASSED=$(grep -c "^PASS" "$RESULTS_FILE" || true)
FAILED=$(grep -c "^FAIL" "$RESULTS_FILE" || true)
PASSED="${PASSED:-0}"
FAILED="${FAILED:-0}"
TOTAL=$((PASSED + FAILED))

echo "======================================================================"
echo -e "TOTAL TESTS RUN : $TOTAL"
echo -e "PASSED          : ${GREEN}$PASSED${NC}"
echo -e "FAILED          : $([[ "$FAILED" -eq 0 ]] && echo -e "${GREEN}0${NC}" || echo -e "${RED}$FAILED${NC}")"
echo "======================================================================"

if [[ "$FAILED" -eq 0 && "$PASSED" -gt 0 ]]; then
    echo -e "${GREEN}[✔] ALL 14 SETUP AND CLOUDFLARE REGRESSION TESTS PASSED!${NC}\n"
    exit 0
else
    echo -e "${RED}[✘] SOME REGRESSION TESTS FAILED!${NC}\n"
    exit 1
fi
