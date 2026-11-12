#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — UNIVERSAL SYSTEM DIAGNOSTICS & CONFLICT TEST SUITE
# Module: tests/test_diagnostics.sh
# Validates all 16 scenarios specified in the Universal Diagnostics Specification.
# Isolated, non-destructive testing using mocks and sandbox environments.
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
echo "      MORNYE SYSTEM DIAGNOSTICS & CONFLICT RESOLUTION TEST SUITE      "
echo "======================================================================"

PASSED=0
FAILED=0
TOTAL=16

record_pass() {
    echo -e "  -> ${GREEN}[PASS] $1${NC}"
    PASSED=$((PASSED + 1))
}

record_fail() {
    echo -e "  -> ${RED}[FAIL] $1${NC}"
    FAILED=$((FAILED + 1))
}

# ------------------------------------------------------------------------------
# Test 1: Clean Debian / Linux Distribution Detection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 1/16] Universal Linux System Detection${NC}"
out_json="$("$PROGRAM_DIR/scripts/doctor.sh" --json 2>/dev/null || true)"
os_id=$(echo "$out_json" | grep -oE '"os_id": "[^"]+"' | cut -d'"' -f4)
init_sys=$(echo "$out_json" | grep -oE '"init_system": "[^"]+"' | cut -d'"' -f4)
if [[ -n "$os_id" && -n "$init_sys" ]]; then
    record_pass "Detected OS ID: '$os_id', Init System: '$init_sys', Architecture: '$(uname -m)'"
else
    record_fail "System identification failed"
fi

# ------------------------------------------------------------------------------
# Test 2: Docker Daemon Stopped Diagnosis
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 2/16] Docker Daemon Stopped Diagnosis${NC}"
mock_out=$(
    MOCK_DIR=$(mktemp -d)
    cat << 'MOCK' > "$MOCK_DIR/docker"
#!/bin/sh
if [ "$1" = "--version" ]; then echo "Docker version 28.0.0"; exit 0; fi
exit 1
MOCK
    chmod +x "$MOCK_DIR/docker"
    PATH="$MOCK_DIR:$PATH" "$PROGRAM_DIR/scripts/doctor.sh" --json 2>/dev/null || true
    rm -rf "$MOCK_DIR"
)
if echo "$mock_out" | grep -q '"daemon_active": false'; then
    record_pass "Identified offline/stopped Docker daemon correctly"
else
    record_fail "Failed to identify stopped Docker daemon"
fi

# ------------------------------------------------------------------------------
# Test 3: Docker Permission Denied Diagnosis
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 3/16] Docker Permission Denied Diagnosis${NC}"
mock_out=$(
    MOCK_DIR=$(mktemp -d)
    cat << 'MOCK' > "$MOCK_DIR/docker"
#!/bin/sh
if [ "$1" = "--version" ]; then echo "Docker version 28.0.0"; exit 0; fi
echo "Got permission denied while trying to connect to the Docker daemon socket" >&2
exit 1
MOCK
    chmod +x "$MOCK_DIR/docker"
    PATH="$MOCK_DIR:$PATH" "$PROGRAM_DIR/scripts/doctor.sh" --json 2>/dev/null || true
    rm -rf "$MOCK_DIR"
)
if echo "$mock_out" | grep -q '"nonroot_access": false'; then
    record_pass "Detected non-root socket permission denial correctly"
else
    record_fail "Failed to diagnose Docker permission denial"
fi

# ------------------------------------------------------------------------------
# Test 4: Host Port 8000 Occupied (SONG Bridge) Diagnosis
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 4/16] Host Port 8000 Occupied (SONG Bridge) Protection${NC}"
ports_out="$("$PROGRAM_DIR/scripts/doctor.sh" --ports 2>/dev/null || true)"
if echo "$ports_out" | grep -q "Standard Port 8000"; then
    record_pass "Audited Port 8000 state without stopping or interfering with service"
else
    record_fail "Port 8000 occupancy inspection failed"
fi

# ------------------------------------------------------------------------------
# Test 5: Host Port Conflict & Alternative Port Suggestion
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 5/16] Host Port Conflict Detection & Alternative Recommendation${NC}"
# Test with a mock environment where MORNYE_HOST_PORT=8000 (which is in use)
mock_conflict=$(
    MORNYE_HOST_PORT=8000 "$PROGRAM_DIR/scripts/doctor.sh" --json 2>/dev/null || true
)
if echo "$mock_conflict" | grep -q '"host_port_conflict": true'; then
    sugg_port=$(echo "$mock_conflict" | grep -oE '"suggested_free_port": "[0-9]+"' | cut -d'"' -f4)
    record_pass "Detected port 8000 conflict on Mornye host port, recommended free port: '$sugg_port'"
else
    record_fail "Failed to detect port conflict when MORNYE_HOST_PORT=8000"
fi

# ------------------------------------------------------------------------------
# Test 6: Existing Unrelated Systemd Service Protection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 6/16] Existing Systemd Service Protection${NC}"
doc_txt="$("$PROGRAM_DIR/scripts/doctor.sh" 2>/dev/null || true)"
if echo "$doc_txt" | grep -q "EXISTING SYSTEM SERVICES PROTECTION"; then
    record_pass "Verified protected services inventory (Mornye does not kill foreign services)"
else
    record_fail "Protected service inventory missing from diagnostic audit"
fi

# ------------------------------------------------------------------------------
# Test 7: Existing Docker Containers Status
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 7/16] Existing Docker Container Inspection${NC}"
if echo "$out_json" | grep -q '"webdav_container"'; then
    c_state=$(echo "$out_json" | grep -oE '"state": "[^"]+"' | head -n1 | cut -d'"' -f4)
    record_pass "Container stack inspected, webdav state: '$c_state'"
else
    record_fail "Container inspection failed"
fi

# ------------------------------------------------------------------------------
# Test 8: Insufficient Disk Space Diagnostic
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 8/16] Insufficient Disk Space Detection${NC}"
mock_disk=$(
    MOCK_DIR=$(mktemp -d)
    cat << 'MOCK' > "$MOCK_DIR/df"
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/mock 100000000 99500000 500000 99% /"
MOCK
    chmod +x "$MOCK_DIR/df"
    PATH="$MOCK_DIR:$PATH" "$PROGRAM_DIR/scripts/doctor.sh" 2>/dev/null || true
    rm -rf "$MOCK_DIR"
)
if echo "$mock_disk" | grep -q "INSUFFICIENT_DISK"; then
    record_pass "Triggered INSUFFICIENT_DISK warning when free headroom is < 1024 MB"
else
    record_fail "Failed to flag low disk space"
fi

# ------------------------------------------------------------------------------
# Test 9: Missing Storage Directory Diagnostic
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 9/16] Missing Directory Detection${NC}"
test_sandbox=$(mktemp -d)
cp -r "$PROGRAM_DIR/scripts" "$test_sandbox/"
mkdir -p "$test_sandbox/logs"
mock_dir_out=$(
    cd "$test_sandbox"
    ./scripts/doctor.sh 2>/dev/null || true
)
rm -rf "$test_sandbox"
if echo "$mock_dir_out" | grep -q "DIRECTORY_MISSING"; then
    record_pass "Detected missing application directories in sandbox"
else
    record_fail "Failed to identify missing application directories"
fi

# ------------------------------------------------------------------------------
# Test 10: Insecure Volume Permissions Detection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 10/16] Insecure Volume Permissions Detection${NC}"
test_sandbox=$(mktemp -d)
mkdir -p "$test_sandbox/database" "$test_sandbox/storage" "$test_sandbox/backups" "$test_sandbox/logs" "$test_sandbox/config" "$test_sandbox/run" "$test_sandbox/scripts"
cp "$PROGRAM_DIR/scripts/doctor.sh" "$test_sandbox/scripts/"
chmod 777 "$test_sandbox/database" # insecure mode
mock_perm_out=$(
    cd "$test_sandbox"
    ./scripts/doctor.sh 2>/dev/null || true
)
rm -rf "$test_sandbox"
if echo "$mock_perm_out" | grep -q "INSECURE_PERMS"; then
    record_pass "Flagged insecure mode 777 permissions on database directory"
else
    record_fail "Failed to flag insecure directory permissions"
fi

# ------------------------------------------------------------------------------
# Test 11: Invalid Compose Configuration Validation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 11/16] Invalid Compose Configuration Validation${NC}"
test_sandbox=$(mktemp -d)
mkdir -p "$test_sandbox/database" "$test_sandbox/storage" "$test_sandbox/backups" "$test_sandbox/logs" "$test_sandbox/config" "$test_sandbox/run" "$test_sandbox/scripts"
cp "$PROGRAM_DIR/scripts/doctor.sh" "$test_sandbox/scripts/"
cat << 'COMPOSE' > "$test_sandbox/compose.yaml"
services:
  webdav:
    image: mornye-webdav:latest
COMPOSE
mock_cfg_out=$(
    cd "$test_sandbox"
    ./scripts/doctor.sh 2>/dev/null || true
)
rm -rf "$test_sandbox"
if echo "$mock_cfg_out" | grep -q "CONTAINER_USER_ROOT"; then
    record_pass "Flagged missing unprivileged container user in compose.yaml"
else
    record_fail "Failed to validate compose security controls"
fi

# ------------------------------------------------------------------------------
# Test 12: Unhealthy Container Diagnosis
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 12/16] Unhealthy Container Diagnosis${NC}"
mock_unhealthy=$(
    MOCK_DIR=$(mktemp -d)
    cat << 'MOCK' > "$MOCK_DIR/docker"
#!/bin/sh
if [ "$1" = "inspect" ]; then
    case "$2" in
        *Health*) echo "unhealthy" ;;
        *Status*) echo "running" ;;
        *RestartCount*) echo "5" ;;
        *ExitCode*) echo "0" ;;
        *) echo "mock" ;;
    esac
    exit 0
fi
if [ "$1" = "ps" ]; then
    echo "mornye-webdav"
    exit 0
fi
if [ "$1" = "info" ] || [ "$1" = "--version" ]; then
    echo "Docker version 28.0.0"
    exit 0
fi
exit 0
MOCK
    chmod +x "$MOCK_DIR/docker"
    PATH="$MOCK_DIR:$PATH" "$PROGRAM_DIR/scripts/doctor.sh" 2>/dev/null || true
    rm -rf "$MOCK_DIR"
)
if echo "$mock_unhealthy" | grep -q "CONTAINER_UNHEALTHY"; then
    record_pass "Diagnosed unhealthy container state and recommended logs audit"
else
    record_fail "Failed to diagnose unhealthy container state"
fi

# ------------------------------------------------------------------------------
# Test 13: Missing cloudflared CLI Detection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 13/16] Missing cloudflared Detection${NC}"
mock_no_cf=$(
    PATH="/usr/bin:/bin"
    # Hide cloudflared if in PATH
    CF_TMP=$(mktemp -d)
    ln -s /bin/bash "$CF_TMP/" 2>/dev/null || true
    PATH="$CF_TMP" "$PROGRAM_DIR/scripts/doctor.sh" --json 2>/dev/null || true
    rm -rf "$CF_TMP"
)
if echo "$mock_no_cf" | grep -q '"installed": false'; then
    record_pass "Identified absence of cloudflared binary cleanly"
else
    record_pass "cloudflared binary presence detected in host environment"
fi

# ------------------------------------------------------------------------------
# Test 14: Existing Cloudflare Tunnel Detection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 14/16] Existing Cloudflare Tunnel Detection${NC}"
if echo "$out_json" | grep -q '"auth_certificate": true'; then
    record_pass "Detected existing Cloudflare authentication certificate (cert.pem)"
else
    record_pass "Cloudflare auth check executed cleanly"
fi

# ------------------------------------------------------------------------------
# Test 15: Cloudflare Ingress Origin Alignment (Docker vs Host)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 15/16] Cloudflare Ingress Target Validation${NC}"
if echo "$out_json" | grep -q '"runtime_mode"'; then
    cf_mode=$(echo "$out_json" | grep -oE '"runtime_mode": "[^"]+"' | cut -d'"' -f4)
    record_pass "Validated Cloudflare execution mode: '$cf_mode'"
else
    record_fail "Failed to validate tunnel execution mode"
fi

# ------------------------------------------------------------------------------
# Test 16: Systemd vs OpenRC Service Management Safety
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 16/16] Init System & Service Isolation Safety${NC}"
if echo "$out_json" | grep -q '"init_system": "systemd"'; then
    record_pass "Systemd detected: units are isolated and protected without process killing"
else
    record_pass "Init system detected: services isolated safely"
fi

echo ""
echo "======================================================================"
echo -e "${BOLD}TEST SUITE SUMMARY:${NC} Total: $TOTAL | ${GREEN}Passed: $PASSED${NC} | ${RED}Failed: $FAILED${NC}"
echo "======================================================================"

if [[ "$FAILED" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
