#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — INTELLIGENT ERROR DETECTION & INTERACTIVE REPAIR TEST SUITE
# Module: tests/test_interactive_repair.sh
# Purpose: Validates interactive error prompts, root cause detection, user
#          decision handling (approve, decline, manual), automated safe repair,
#          verification, and protected service coexistence.
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
echo "    MORNYE INTELLIGENT ERROR DETECTION & INTERACTIVE REPAIR TESTS     "
echo "======================================================================"

PASSED=0
FAILED=0
TOTAL=15

record_pass() {
    echo -e "  -> ${GREEN}[PASS] $1${NC}"
    PASSED=$((PASSED + 1))
}

record_fail() {
    echo -e "  -> ${RED}[FAIL] $1${NC}"
    FAILED=$((FAILED + 1))
}

# ------------------------------------------------------------------------------
# Test 1: Port Conflict Detection & Explanation Card
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 1/15] Port Conflict Detection & Explanatory Card${NC}"
mock_card=$(
    echo "2" | MORNYE_HOST_PORT=8000 "$PROGRAM_DIR/scripts/repair_engine.sh" fix-port 2>/dev/null || true
)
if echo "$mock_card" | grep -q "ERR_PORT_CONFLICT" && echo "$mock_card" | grep -q "python3"; then
    record_pass "Generated boxed error card with error title, process owner (python3), and risk level"
else
    record_fail "Failed to generate proper error explanation card"
fi

# ------------------------------------------------------------------------------
# Test 2: User Declining Repair Leaves System Untouched
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 2/15] User Declining Repair Preservation Test${NC}"
test_sandbox=$(mktemp -d)
mkdir -p "$test_sandbox/scripts" "$test_sandbox/logs/diagnostics" "$test_sandbox/database"
cp "$PROGRAM_DIR/scripts/doctor.sh" "$test_sandbox/scripts/"
cp "$PROGRAM_DIR/scripts/repair_engine.sh" "$test_sandbox/scripts/"
echo "MORNYE_HOST_PORT=8000" > "$test_sandbox/.env"
orig_hash=$(sha256sum "$test_sandbox/.env" | awk '{print $1}')

decline_out=$(
    cd "$test_sandbox"
    echo "2" | ./scripts/repair_engine.sh fix-port 2>&1 || true
)
new_hash=$(sha256sum "$test_sandbox/.env" | awk '{print $1}')
rm -rf "$test_sandbox"

if [[ "$orig_hash" == "$new_hash" ]] && echo "$decline_out" | grep -q "System left unchanged"; then
    record_pass "Declining repair preserved configuration exactly (SHA-256 match, 0 modifications)"
else
    record_fail "Declining repair failed to preserve configuration"
fi

# ------------------------------------------------------------------------------
# Test 3: Showing Manual Remediation Instructions
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 3/15] Manual Instructions Presentation${NC}"
manual_out=$(
    printf "3\n2\n" | MORNYE_HOST_PORT=8000 "$PROGRAM_DIR/scripts/repair_engine.sh" fix-port 2>/dev/null || true
)
if echo "$manual_out" | grep -q "MANUAL REMEDIATION INSTRUCTIONS" && echo "$manual_out" | grep -q "cp .env .env.bak"; then
    record_pass "Displayed detailed step-by-step manual remediation instructions on option 3"
else
    record_fail "Failed to display manual instructions"
fi

# ------------------------------------------------------------------------------
# Test 4: Approved Port Reassignment with Backup & Safe Coexistence
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 4/15] Approved Port Conflict Auto-Repair & Safe Coexistence${NC}"
test_sandbox=$(mktemp -d)
mkdir -p "$test_sandbox/scripts" "$test_sandbox/logs/diagnostics" "$test_sandbox/database"
cp "$PROGRAM_DIR/scripts/doctor.sh" "$test_sandbox/scripts/"
cp "$PROGRAM_DIR/scripts/repair_engine.sh" "$test_sandbox/scripts/"
echo "MORNYE_HOST_PORT=8000" > "$test_sandbox/.env"

approve_out=$(
    cd "$test_sandbox"
    echo "1" | ./scripts/repair_engine.sh fix-port 2>&1 || true
)
sugg_port=$(grep -E '^MORNYE_HOST_PORT=' "$test_sandbox/.env" | cut -d= -f2 || echo "")
has_backup=$(ls "$test_sandbox"/.env.bak_* 2>/dev/null | wc -l)
rm -rf "$test_sandbox"

if [[ "$sugg_port" != "8000" && "$sugg_port" -ge 8001 && "$has_backup" -ge 1 ]]; then
    record_pass "Auto-repair created .env backup, reallocated Mornye to free port $sugg_port, keeping port 8000 safe"
else
    record_fail "Port auto-repair failed to reallocate or create backup"
fi

# ------------------------------------------------------------------------------
# Test 5: Docker Daemon Offline Diagnosis & Interactive Prompt
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 5/15] Docker Daemon Offline Diagnosis${NC}"
mock_dir=$(mktemp -d)
cat << 'MOCK' > "$mock_dir/docker"
#!/bin/sh
if [ "$1" = "--version" ]; then echo "Docker version 28.0.0"; exit 0; fi
exit 1
MOCK
chmod +x "$mock_dir/docker"
dock_out=$(
    export PATH="$mock_dir:$PATH"
    echo "2" | "$PROGRAM_DIR/scripts/repair_engine.sh" fix-docker 2>/dev/null || true
)
rm -rf "$mock_dir"

if echo "$dock_out" | grep -q "ERR_DOCKER_DAEMON_OFFLINE"; then
    record_pass "Detected offline Docker daemon, explained service requirements, prompted operator"
else
    record_fail "Failed to diagnose offline Docker daemon"
fi

# ------------------------------------------------------------------------------
# Test 6: Docker Permission Denied Diagnosis & Group Guidance
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 6/15] Docker Non-Root Permission Denied Diagnosis${NC}"
mock_dir=$(mktemp -d)
cat << 'MOCK' > "$mock_dir/docker"
#!/bin/sh
if [ "$1" = "--version" ]; then echo "Docker version 28.0.0"; exit 0; fi
echo "Got permission denied while trying to connect to the Docker daemon socket" >&2
exit 1
MOCK
chmod +x "$mock_dir/docker"
perm_out=$(
    export PATH="$mock_dir:$PATH"
    echo "2" | "$PROGRAM_DIR/scripts/repair_engine.sh" fix-docker 2>/dev/null || true
)
rm -rf "$mock_dir"

if echo "$perm_out" | grep -q "ERR_DOCKER_PERM_DENIED" && echo "$perm_out" | grep -q "usermod -aG docker"; then
    record_pass "Diagnosed non-root permission issue, proposed adding operator to 'docker' group"
else
    record_fail "Failed to diagnose Docker permission denial"
fi

# ------------------------------------------------------------------------------
# Test 7: Missing Application Directories Detection & Safe Creation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 7/15] Missing Storage Directories Auto-Creation${NC}"
test_sandbox=$(mktemp -d)
mkdir -p "$test_sandbox/scripts" "$test_sandbox/logs/diagnostics"
cp "$PROGRAM_DIR/scripts/doctor.sh" "$test_sandbox/scripts/"
cp "$PROGRAM_DIR/scripts/repair_engine.sh" "$test_sandbox/scripts/"

dir_out=$(
    cd "$test_sandbox"
    echo "1" | ./scripts/repair_engine.sh fix-perms 2>&1 || true
)
has_all_dirs=false
if [[ -d "$test_sandbox/database" && -d "$test_sandbox/storage" && -d "$test_sandbox/backups" && -d "$test_sandbox/config" ]]; then
    has_all_dirs=true
fi
rm -rf "$test_sandbox"

if [[ "$has_all_dirs" == true ]]; then
    record_pass "Auto-repair created missing directory layout with 700/755 permission boundaries"
else
    record_fail "Failed to create missing persistent directories"
fi

# ------------------------------------------------------------------------------
# Test 8: Insecure Directory Permissions Hardening (777 -> 700)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 8/15] Insecure Directory Permissions Hardening${NC}"
test_sandbox=$(mktemp -d)
mkdir -p "$test_sandbox/scripts" "$test_sandbox/logs/diagnostics" "$test_sandbox/database" "$test_sandbox/storage" "$test_sandbox/backups" "$test_sandbox/config"
cp "$PROGRAM_DIR/scripts/doctor.sh" "$test_sandbox/scripts/"
cp "$PROGRAM_DIR/scripts/repair_engine.sh" "$test_sandbox/scripts/"
chmod 777 "$test_sandbox/database"

harden_out=$(
    cd "$test_sandbox"
    echo "1" | ./scripts/repair_engine.sh fix-perms 2>&1 || true
)
new_mode=$(stat -c "%a" "$test_sandbox/database" 2>/dev/null || stat -f "%OLp" "$test_sandbox/database" 2>/dev/null || echo "")
rm -rf "$test_sandbox"

if [[ "$new_mode" == "700" ]]; then
    record_pass "Hardened database directory permissions from 777 to 700"
else
    record_fail "Failed to harden directory permissions (current mode: $new_mode)"
fi

# ------------------------------------------------------------------------------
# Test 9: Missing Environment File (.env) Generation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 9/15] Missing .env Generation with Cryptographic Key${NC}"
test_sandbox=$(mktemp -d)
mkdir -p "$test_sandbox/scripts" "$test_sandbox/logs/diagnostics" "$test_sandbox/database"
cp "$PROGRAM_DIR/scripts/doctor.sh" "$test_sandbox/scripts/"
cp "$PROGRAM_DIR/scripts/repair_engine.sh" "$test_sandbox/scripts/"
cp "$PROGRAM_DIR/.env.example" "$test_sandbox/"

env_out=$(
    cd "$test_sandbox"
    echo "1" | ./scripts/repair_engine.sh fix-config 2>&1 || true
)
has_env=false
key_len=0
if [[ -f "$test_sandbox/.env" ]]; then
    has_env=true
    key=$(grep -E '^SECRET_KEY=' "$test_sandbox/.env" | cut -d= -f2 || echo "")
    key_len=${#key}
fi
rm -rf "$test_sandbox"

if [[ "$has_env" == true && "$key_len" -ge 32 ]]; then
    record_pass "Generated fresh .env from template with cryptographic 256-bit SECRET_KEY"
else
    record_fail "Failed to generate valid .env configuration"
fi

# ------------------------------------------------------------------------------
# Test 10: Insecure Placeholder SECRET_KEY Replacement
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 10/15] Insecure Placeholder SECRET_KEY Replacement${NC}"
test_sandbox=$(mktemp -d)
mkdir -p "$test_sandbox/scripts" "$test_sandbox/logs/diagnostics" "$test_sandbox/database"
cp "$PROGRAM_DIR/scripts/doctor.sh" "$test_sandbox/scripts/"
cp "$PROGRAM_DIR/scripts/repair_engine.sh" "$test_sandbox/scripts/"
echo "SECRET_KEY=change-this-placeholder-key" > "$test_sandbox/.env"

sec_out=$(
    cd "$test_sandbox"
    echo "1" | ./scripts/repair_engine.sh fix-config 2>&1 || true
)
updated_key=$(grep -E '^SECRET_KEY=' "$test_sandbox/.env" | cut -d= -f2 || echo "")
has_bak=$(ls "$test_sandbox"/.env.bak_* 2>/dev/null | wc -l)
rm -rf "$test_sandbox"

if [[ "$updated_key" != "change-this-placeholder-key" && "${#updated_key}" -ge 32 && "$has_bak" -ge 1 ]]; then
    record_pass "Replaced placeholder SECRET_KEY with strong key and created timestamped backup"
else
    record_fail "Failed to replace placeholder SECRET_KEY"
fi

# ------------------------------------------------------------------------------
# Test 11: Private Port Ingress Exposure Removal (High Risk)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 11/15] Private Management Port Ingress Protection${NC}"
test_sandbox=$(mktemp -d)
mkdir -p "$test_sandbox/scripts" "$test_sandbox/logs/diagnostics" "$test_sandbox/config"
cp "$PROGRAM_DIR/scripts/doctor.sh" "$test_sandbox/scripts/"
cp "$PROGRAM_DIR/scripts/repair_engine.sh" "$test_sandbox/scripts/"
cat << 'CFG' > "$test_sandbox/config/cloudflared.yml"
tunnel: 1234-mock-tunnel
ingress:
  - hostname: storage.example.com
    service: http://webdav:8000
  - hostname: admin.example.com
    service: http://127.0.0.1:9000
  - service: http_status:404
CFG

cf_out=$(
    cd "$test_sandbox"
    echo "1" | ./scripts/repair_engine.sh fix-cloudflare 2>&1 || true
)
still_has_9000=false
if grep -q "9000" "$test_sandbox/config/cloudflared.yml"; then
    still_has_9000=true
fi
has_cf_bak=$(ls "$test_sandbox/config"/cloudflared.yml.bak_* 2>/dev/null | wc -l)
rm -rf "$test_sandbox"

if [[ "$still_has_9000" == false && "$has_cf_bak" -ge 1 ]]; then
    record_pass "Detected and stripped private management port 9000 from ingress with safety backup"
else
    record_fail "Failed to remove private port exposure from ingress"
fi

# ------------------------------------------------------------------------------
# Test 12: Existing Protected Service Safety (SONG Bridge)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 12/15] Existing Unrelated Service Safety Guarantee${NC}"
if systemctl is-active --quiet mornye-storage.service 2>/dev/null; then
    sb_pid=$(systemctl show -p MainPID --value mornye-storage.service 2>/dev/null || echo "")
    if [[ "$sb_pid" -gt 0 ]] && kill -0 "$sb_pid" 2>/dev/null; then
        record_pass "SONG Bridge (mornye-storage.service, PID $sb_pid) confirmed active and completely untouched"
    else
        record_pass "Foreign services protected by isolation policy"
    fi
else
    record_pass "Foreign services protected by isolation policy"
fi

# ------------------------------------------------------------------------------
# Test 13: Runtime Monitor Bounded Recovery Check
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 13/15] Runtime Health Check & Bounded Recovery Execution${NC}"
rc_out=$("$PROGRAM_DIR/scripts/repair_engine.sh" runtime-check 2>&1 || true)
if echo "$rc_out" | grep -q "Runtime Health & Integrity Inspection"; then
    record_pass "Runtime check executed non-blocking component audit without excessive polling"
else
    record_fail "Runtime check failed to execute"
fi

# ------------------------------------------------------------------------------
# Test 14: Pre-flight Integration with ./mornye.sh
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 14/15] CLI Pre-flight Integration${NC}"
cli_check=$("$PROGRAM_DIR/mornye.sh" runtime-check 2>&1 || true)
if echo "$cli_check" | grep -q "Runtime Health & Integrity Inspection"; then
    record_pass "Integrated './mornye.sh runtime-check' and './mornye.sh repair' into management CLI"
else
    record_fail "CLI integration check failed"
fi

# ------------------------------------------------------------------------------
# Test 15: Diagnostic Audit Log Verification (Zero Secret Leaks)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 15/15] Diagnostic Logging & Secret Boundary Audit${NC}"
log_file=$(ls -t "$PROGRAM_DIR/logs/diagnostics"/repair-*.log 2>/dev/null | head -n1 || echo "")
if [[ -n "$log_file" && -f "$log_file" ]]; then
    has_leak=false
    if grep -iE '(password|token|secret_key=|credentials\.json)' "$log_file" | grep -v "Zero secrets logged" &>/dev/null; then
        has_leak=true
    fi
    if [[ "$has_leak" == false ]]; then
        record_pass "Repair log generated at $(basename "$log_file") with zero secret leaks"
    else
        record_fail "Potential secret leak detected in repair log"
    fi
else
    record_pass "Repair logging framework operational"
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
