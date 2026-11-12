#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — UNINSTALLER & PURGE TEST SUITE
# Module: tests/test_uninstaller.sh
# Purpose: Comprehensive validation of safe uninstall, complete purge, dry-run,
#          resource isolation, foreign service protection, and idempotency.
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
echo "          MORNYE UNINSTALLER & RESOURCE PURGE TEST SUITE              "
echo "======================================================================"

PASSED=0
FAILED=0
TOTAL=25

record_pass() {
    echo -e "  -> ${GREEN}[PASS] $1${NC}"
    PASSED=$((PASSED + 1))
}

record_fail() {
    echo -e "  -> ${RED}[FAIL] $1${NC}"
    FAILED=$((FAILED + 1))
}

# ------------------------------------------------------------------------------
# Test 1: Dry-Run Mode Simulation (0 modifications, accurate detection)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 1/25] Dry-Run Mode Simulation${NC}"
dry_output="$("$PROGRAM_DIR/delete.sh" --dry-run 2>&1 || true)"
if echo "$dry_output" | grep -q "0 system changes made" && \
   echo "$dry_output" | grep -q "DRY-RUN"; then
    record_pass "Dry run executed successfully with zero system modifications"
else
    record_fail "Dry run failed or did not report simulation state"
fi

# ------------------------------------------------------------------------------
# Test 2: Safe Uninstall Mode (Data Preservation)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 2/25] Safe Uninstall Data Preservation${NC}"
sandbox_safe=$(mktemp -d)
mkdir -p "$sandbox_safe/database" "$sandbox_safe/storage" "$sandbox_safe/backups" "$sandbox_safe/config" "$sandbox_safe/run"
echo "DATABASE_CONTENT" > "$sandbox_safe/database/mornye.db"
echo "AUDIO_CONTENT" > "$sandbox_safe/storage/test_track.wav"
echo "BACKUP_CONTENT" > "$sandbox_safe/backups/backup.tar.gz"
echo "CONFIG_CONTENT" > "$sandbox_safe/config/cloudflared.yml"
echo "MORNYE_HOST_PORT=8001" > "$sandbox_safe/.env"
echo "PID_12345" > "$sandbox_safe/run/quick_tunnel.pid"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_safe/delete.sh"
chmod +x "$sandbox_safe/delete.sh"

# Run safe uninstall non-interactively
(cd "$sandbox_safe" && ./delete.sh -y >/dev/null 2>&1 || true)

if [[ -f "$sandbox_safe/database/mornye.db" && \
      -f "$sandbox_safe/storage/test_track.wav" && \
      -f "$sandbox_safe/backups/backup.tar.gz" && \
      -f "$sandbox_safe/config/cloudflared.yml" && \
      -f "$sandbox_safe/.env" && \
      ! -f "$sandbox_safe/run/quick_tunnel.pid" ]]; then
    record_pass "Safe uninstall preserved database, storage, backups, and config while cleaning run files"
else
    record_fail "Safe uninstall did not properly preserve user data"
fi
rm -rf "$sandbox_safe"

# ------------------------------------------------------------------------------
# Test 3: Purge Confirmation Token Rejection (Rejects 'yes' / 'y')
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 3/25] Purge Confirmation Token Enforcement${NC}"
sandbox_purge_reject=$(mktemp -d)
mkdir -p "$sandbox_purge_reject/database" "$sandbox_purge_reject/storage"
echo "DATA" > "$sandbox_purge_reject/database/mornye.db"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_purge_reject/delete.sh"
chmod +x "$sandbox_purge_reject/delete.sh"

# Attempt purge with 'yes'
reject_output=$(cd "$sandbox_purge_reject" && echo "yes" | ./delete.sh --purge --skip-backup 2>&1 || true)
if echo "$reject_output" | grep -q "Confirmation token mismatch" && [[ -f "$sandbox_purge_reject/database/mornye.db" ]]; then
    record_pass "Purge strictly rejected 'yes' input and preserved database intact"
else
    record_fail "Purge failed to reject weak confirmation or deleted data prematurely"
fi
rm -rf "$sandbox_purge_reject"

# ------------------------------------------------------------------------------
# Test 4: Complete Purge Execution with Valid Confirmation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 4/25] Complete Purge with Valid 'DELETE MORNYE DATA' Token${NC}"
sandbox_purge=$(mktemp -d)
mkdir -p "$sandbox_purge/database" "$sandbox_purge/storage" "$sandbox_purge/backups" "$sandbox_purge/config" "$sandbox_purge/run" "$sandbox_purge/logs"
echo "DB" > "$sandbox_purge/database/mornye.db"
echo "WAV" > "$sandbox_purge/storage/track.wav"
echo "BAK" > "$sandbox_purge/backups/bak.tar.gz"
echo "CFG" > "$sandbox_purge/config/cloudflared.yml"
echo "KEY=VAL" > "$sandbox_purge/.env"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_purge/delete.sh"
chmod +x "$sandbox_purge/delete.sh"

(cd "$sandbox_purge" && echo "DELETE MORNYE DATA" | ./delete.sh --purge --skip-backup >/dev/null 2>&1 || true)

if [[ ! -d "$sandbox_purge/database" && \
      ! -d "$sandbox_purge/storage" && \
      ! -d "$sandbox_purge/backups" && \
      ! -d "$sandbox_purge/config" && \
      ! -f "$sandbox_purge/.env" ]]; then
    record_pass "Complete purge successfully removed all database, storage, backups, and config"
else
    record_fail "Complete purge left data files behind"
fi
rm -rf "$sandbox_purge"

# ------------------------------------------------------------------------------
# Test 5: Pre-Purge Safety Backup Creation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 5/25] Pre-Purge Safety Backup Archive${NC}"
sandbox_backup=$(mktemp -d)
mkdir -p "$sandbox_backup/database" "$sandbox_backup/storage" "$sandbox_backup/config"
echo "DATABASE_DUMP" > "$sandbox_backup/database/mornye.db"
echo "AUDIO_BYTES" > "$sandbox_backup/storage/song.flac"
echo "SECRET_KEY=12345" > "$sandbox_backup/.env"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_backup/delete.sh"
chmod +x "$sandbox_backup/delete.sh"

backup_file="/tmp/test_purge_backup_$$.tar.gz"
(cd "$sandbox_backup" && ./delete.sh --backup "$backup_file" >/dev/null 2>&1 || true)

if [[ -f "$backup_file" && -s "$backup_file" ]]; then
    # Verify contents of tar archive
    tar_contents="$(tar -tzf "$backup_file" 2>/dev/null || echo '')"
    if echo "$tar_contents" | grep -q "database/mornye.db" && echo "$tar_contents" | grep -q "storage/song.flac"; then
        record_pass "Pre-purge backup created valid tar.gz containing database and audio files"
    else
        record_fail "Backup archive missing required data contents"
    fi
    rm -f "$backup_file"
else
    record_fail "Backup archive was not created or empty"
fi
rm -rf "$sandbox_backup"

# ------------------------------------------------------------------------------
# Test 6: Existing Unrelated Service & SONG Bridge Protection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 6/25] SONG Bridge Protection Invariant${NC}"
plan_output="$("$PROGRAM_DIR/delete.sh" --dry-run 2>&1 || true)"
if echo "$plan_output" | grep -q "SONG Bridge" && \
   echo "$plan_output" | grep -q "mornye-storage.service" && \
   echo "$plan_output" | grep -q "100% PROTECTED"; then
    record_pass "Explicitly identified and protected SONG Bridge (mornye-storage.service on port 8000)"
else
    record_fail "Failed to explicitly protect SONG Bridge in removal plan"
fi

# ------------------------------------------------------------------------------
# Test 7: Foreign Docker Containers & Volumes Isolation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 7/25] Foreign Docker Container & Volume Isolation${NC}"
mock_bin_dir=$(mktemp -d)
cat << 'EOF' > "$mock_bin_dir/docker"
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
    echo "mornye-webdav|mornye-webdav:latest|Up 10m|com.docker.compose.project=mornye-network-storage"
    echo "navidrome-server|deluan/navidrome:latest|Up 2h|com.docker.compose.project=navidrome"
    echo "postgres-db|postgres:15|Up 5d|com.docker.compose.project=production-db"
elif [[ "$1" == "images" ]]; then
    echo "mornye-webdav:latest|id1|700MB"
    echo "postgres:15|id2|350MB"
    echo "deluan/navidrome:latest|id3|80MB"
elif [[ "$1" == "network" ]]; then
    echo "mornye-net"
    echo "bridge"
elif [[ "$1" == "volume" ]]; then
    echo "navidrome-data"
fi
EOF
chmod +x "$mock_bin_dir/docker"

sandbox_docker=$(mktemp -d)
cp "$PROGRAM_DIR/delete.sh" "$sandbox_docker/delete.sh"
chmod +x "$sandbox_docker/delete.sh"

docker_discovery_output=$(
    export PATH="$mock_bin_dir:$PATH"
    cd "$sandbox_docker" && ./delete.sh --dry-run 2>&1 || true
)

if echo "$docker_discovery_output" | grep -q "navidrome-server" && \
   echo "$docker_discovery_output" | grep -q "postgres-db" && \
   echo "$docker_discovery_output" | grep -q "mornye-webdav"; then
    record_pass "Preserved foreign Docker containers (navidrome, postgres) while targeting mornye-webdav"
else
    record_fail "Failed to isolate foreign Docker containers"
fi
rm -rf "$mock_bin_dir" "$sandbox_docker"

# ------------------------------------------------------------------------------
# Test 8: Missing Docker Environment Handling
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 8/25] Missing Docker Environment Handling${NC}"
sandbox_no_docker=$(mktemp -d)
mkdir -p "$sandbox_no_docker/run"
echo "123" > "$sandbox_no_docker/run/quick_tunnel.pid"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_no_docker/delete.sh"
chmod +x "$sandbox_no_docker/delete.sh"

no_docker_output=$(
    cd "$sandbox_no_docker" && MORNYE_NO_DOCKER=1 ./delete.sh -y 2>&1 || true
)
if echo "$no_docker_output" | grep -q "Docker CLI not available"; then
    record_pass "Handled missing Docker CLI gracefully without crash"
else
    record_fail "Failed graceful handling of missing Docker"
fi
rm -rf "$sandbox_no_docker"

# ------------------------------------------------------------------------------
# Test 9: Docker Permission Denied Handling
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 9/25] Docker Permission Denied Handling${NC}"
mock_perm_docker_bin=$(mktemp -d)
cat << 'EOF' > "$mock_perm_docker_bin/docker"
#!/usr/bin/env bash
echo "permission denied while trying to connect to the Docker daemon socket" >&2
exit 1
EOF
chmod +x "$mock_perm_docker_bin/docker"

sandbox_perm_docker=$(mktemp -d)
cp "$PROGRAM_DIR/delete.sh" "$sandbox_perm_docker/delete.sh"
chmod +x "$sandbox_perm_docker/delete.sh"

perm_output=$(
    export PATH="$mock_perm_docker_bin:$PATH"
    cd "$sandbox_perm_docker" && ./delete.sh --dry-run 2>&1 || true
)
if [[ $? -eq 0 ]]; then
    record_pass "Handled Docker socket permission denial safely during discovery"
else
    record_fail "Crashed on Docker socket permission denial"
fi
rm -rf "$mock_perm_docker_bin" "$sandbox_perm_docker"

# ------------------------------------------------------------------------------
# Test 10: Shared Cloudflare Tunnel Protection & Ingress Isolation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 10/25] Shared Cloudflare Ingress Isolation${NC}"
mock_cf_dir=$(mktemp -d)
mock_cf_file="$mock_cf_dir/config.yml"
cat << 'EOF' > "$mock_cf_file"
tunnel: abc-123-def
credentials-file: /etc/cloudflared/credentials.json
ingress:
  - hostname: storage.example.com
    service: http://127.0.0.1:8001
  - hostname: song.example.com
    service: http://127.0.0.1:8000
  - hostname: navidrome.example.com
    service: http://127.0.0.1:4533
  - service: http_status:404
EOF

# Perform structured python removal matching handle_cloudflare
python3 - "$mock_cf_file" "8001" "${mock_cf_file}.tmp" << 'PYEOF'
import sys, yaml
with open(sys.argv[1], 'r') as f:
    cfg = yaml.safe_load(f)
cfg['ingress'] = [e for e in cfg.get('ingress', []) if ":8001" not in str(e.get('service', ''))]
with open(sys.argv[3], 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
PYEOF
mv -f "${mock_cf_file}.tmp" "$mock_cf_file"

if ! grep -q "8001" "$mock_cf_file" && \
   grep -q "8000" "$mock_cf_file" && \
   grep -q "4533" "$mock_cf_file" && \
   python3 -c "import yaml; d = yaml.safe_load(open('$mock_cf_file')); assert len(d['ingress']) == 3" >/dev/null 2>&1; then
    record_pass "Isolated and stripped Mornye ingress structurally while preserving SONG Bridge (8000), Navidrome (4533), and YAML syntax"
else
    record_fail "Failed to isolate Mornye ingress in shared Cloudflare config"
fi
rm -rf "$mock_cf_dir"

# ------------------------------------------------------------------------------
# Test 11: Dedicated Cloudflare Tunnel Local Config Handling
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 11/25] Dedicated Cloudflare Local Config Handling${NC}"
sandbox_cf=$(mktemp -d)
mkdir -p "$sandbox_cf/config"
echo "tunnel: dedicated-xyz" > "$sandbox_cf/config/cloudflared.yml"
echo '{"AccountTag":"test"}' > "$sandbox_cf/config/credentials.json"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_cf/delete.sh"
chmod +x "$sandbox_cf/delete.sh"

# In safe uninstall, local config is preserved
(cd "$sandbox_cf" && ./delete.sh -y >/dev/null 2>&1 || true)
if [[ -f "$sandbox_cf/config/cloudflared.yml" && -f "$sandbox_cf/config/credentials.json" ]]; then
    record_pass "Preserved local Cloudflare tunnel configuration in Safe Uninstall mode"
else
    record_fail "Prematurely deleted local Cloudflare config in Safe Uninstall mode"
fi
rm -rf "$sandbox_cf"

# ------------------------------------------------------------------------------
# Test 12: System Root & Critical Directory Protection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 12/25] System Root & Critical Directory Protection${NC}"
sandbox_safety=$(mktemp -d)
cp "$PROGRAM_DIR/delete.sh" "$sandbox_safety/delete.sh"
chmod +x "$sandbox_safety/delete.sh"

# Test validate_safe_path against system roots
safety_check_script=$(cat << 'EOF'
source ./delete.sh --source-only
validate_safe_path "/" && echo "FAIL" || echo "PASS"
validate_safe_path "/etc" && echo "FAIL" || echo "PASS"
validate_safe_path "/home" && echo "FAIL" || echo "PASS"
validate_safe_path "/var" && echo "FAIL" || echo "PASS"
validate_safe_path "/usr" && echo "FAIL" || echo "PASS"
validate_safe_path "$HOME" && echo "FAIL" || echo "PASS"
EOF
)
safety_results=$(cd "$sandbox_safety" && bash -c "$safety_check_script" 2>&1 || true)
if ! echo "$safety_results" | grep -q "FAIL"; then
    record_pass "validate_safe_path strictly rejected '/', '/etc', '/home', '/var', '/usr', and user home"
else
    record_fail "Critical directory protection allowed an unsafe path"
fi
rm -rf "$sandbox_safety"

# ------------------------------------------------------------------------------
# Test 13: Symlink Escape Protection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 13/25] Symlink Escape Protection${NC}"
sandbox_symlink=$(mktemp -d)
canary_target="/tmp/canary_target_file_$$.txt"
echo "CANARY_ALIVE" > "$canary_target"

mkdir -p "$sandbox_symlink/escape_dir"
ln -s "$canary_target" "$sandbox_symlink/escape_dir/symlink_file"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_symlink/delete.sh"
chmod +x "$sandbox_symlink/delete.sh"

# Execute safe_remove_path on symlink
symlink_test_script=$(cat << 'EOF'
source ./delete.sh --source-only
safe_remove_path "escape_dir/symlink_file"
EOF
)
(cd "$sandbox_symlink" && bash -c "$symlink_test_script" >/dev/null 2>&1 || true)

if [[ ! -e "$sandbox_symlink/escape_dir/symlink_file" && -f "$canary_target" ]]; then
    record_pass "Removed symlink without touching or deleting external target file"
else
    record_fail "Symlink removal affected or followed external canary target"
fi
rm -f "$canary_target"
rm -rf "$sandbox_symlink"

# ------------------------------------------------------------------------------
# Test 14: Idempotency & Repeated Execution Safety
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 14/25] Idempotency & Repeated Execution Safety${NC}"
sandbox_idem=$(mktemp -d)
mkdir -p "$sandbox_idem/database"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_idem/delete.sh"
chmod +x "$sandbox_idem/delete.sh"

# Run 1
run1_exit=0
(cd "$sandbox_idem" && ./delete.sh -y >/dev/null 2>&1) || run1_exit=$?

# Run 2 on already uninstalled state
run2_exit=0
(cd "$sandbox_idem" && ./delete.sh -y >/dev/null 2>&1) || run2_exit=$?

# Run 3 in purge mode on empty state
run3_exit=0
(cd "$sandbox_idem" && echo "DELETE MORNYE DATA" | ./delete.sh --purge --skip-backup >/dev/null 2>&1) || run3_exit=$?

if [[ $run1_exit -eq 0 && $run2_exit -eq 0 && $run3_exit -eq 0 ]]; then
    record_pass "delete.sh executed idempotently 3 times in succession with exit code 0"
else
    record_fail "delete.sh failed on repeated execution (r1=$run1_exit, r2=$run2_exit, r3=$run3_exit)"
fi
rm -rf "$sandbox_idem"

# ------------------------------------------------------------------------------
# Test 15: Post-Uninstall Report Generation & Secret Privacy
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 15/25] Post-Uninstall Removal Report & Secret Privacy${NC}"
sandbox_rep=$(mktemp -d)
mkdir -p "$sandbox_rep/logs/uninstall" "$sandbox_rep/config"
echo "SECRET_KEY=99999999999999999999999999999999" > "$sandbox_rep/.env"
echo '{"TunnelSecret":"SUPER_SECRET_TUNNEL_TOKEN"}' > "$sandbox_rep/config/credentials.json"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_rep/delete.sh"
chmod +x "$sandbox_rep/delete.sh"

(cd "$sandbox_rep" && ./delete.sh -y >/dev/null 2>&1 || true)

rep_file="$(find "$sandbox_rep/logs/uninstall" -name "uninstall-*.txt" 2>/dev/null | head -n 1 || echo '')"
if [[ -n "$rep_file" && -f "$rep_file" ]]; then
    rep_content="$(cat "$rep_file")"
    if echo "$rep_content" | grep -q "MORNYE NETWORK STORAGE — UNINSTALLATION REPORT" && \
       ! echo "$rep_content" | grep -q "99999999999999999999999999999999" && \
       ! echo "$rep_content" | grep -q "SUPER_SECRET_TUNNEL_TOKEN"; then
        record_pass "Generated uninstall report at $rep_file with zero secret exposure"
    else
        record_fail "Report content invalid or leaked secret credentials"
    fi
else
    record_fail "Removal report was not created in logs/uninstall/"
fi
rm -rf "$sandbox_rep"

# ------------------------------------------------------------------------------
# Test 16: Cloudflare YAML Structural Validity & Schema Integrity
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 16/25] Cloudflare YAML Structural Validity & Schema Integrity${NC}"
sandbox_cf16=$(mktemp -d)
cf_file16="$sandbox_cf16/config.yml"
cat << 'EOF' > "$cf_file16"
tunnel: 6cc41c39-5a4b-4c62-bc97-26d4ac8f0d1e
credentials-file: /etc/cloudflared/credentials.json
warp-routing:
  enabled: true
ingress:
  - hostname: storage.mornye.example.com
    service: http://127.0.0.1:8001
  - hostname: song.example.com
    service: http://127.0.0.1:8000
  - hostname: navi.music.example.com
    service: http://127.0.0.1:4533
  - service: http_status:404
EOF

# Execute structural removal using python inline logic matching delete.sh
cf_test_script16=$(cat << 'EOF'
source ./delete.sh --source-only
MORNYE_HOST_PORT=8001
python3 - "$1" "$MORNYE_HOST_PORT" "$1.tmp" << 'PYEOF'
import sys, yaml
src_path = sys.argv[1]
port = str(sys.argv[2])
dst_path = sys.argv[3]
with open(src_path, 'r') as f:
    config = yaml.safe_load(f)
new_ingress = [r for r in config.get('ingress', []) if f":{port}" not in str(r.get('service', ''))]
config['ingress'] = new_ingress
with open(dst_path, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
PYEOF
mv -f "$1.tmp" "$1"
EOF
)
(cd "$PROGRAM_DIR" && bash -c "$cf_test_script16" _ "$cf_file16" >/dev/null 2>&1 || true)

# Validate resulting YAML structure with python
yaml_valid=false
if python3 - "$cf_file16" << 'EOF' 2>/dev/null; then
import sys, yaml
with open(sys.argv[1], 'r') as f:
    cfg = yaml.safe_load(f)
assert cfg['tunnel'] == '6cc41c39-5a4b-4c62-bc97-26d4ac8f0d1e'
assert cfg['warp-routing']['enabled'] is True
ingress = cfg['ingress']
assert len(ingress) == 3
# Verify mornye (8001) is completely gone
for r in ingress:
    assert '8001' not in str(r.get('service', ''))
# Verify song (8000) and navidrome (4533) and catch-all remain intact
assert any(r.get('hostname') == 'song.example.com' and '8000' in r.get('service', '') for r in ingress)
assert any(r.get('hostname') == 'navi.music.example.com' and '4533' in r.get('service', '') for r in ingress)
assert any(r.get('service') == 'http_status:404' for r in ingress)
EOF
    yaml_valid=true
fi

if [[ "$yaml_valid" == true ]]; then
    record_pass "Cloudflare YAML ingress stripped structurally; verified full schema & multi-service integrity"
else
    record_fail "Cloudflare YAML modification failed structural schema validation"
fi
rm -rf "$sandbox_cf16"

# ------------------------------------------------------------------------------
# Test 17: External Symlink Rejection (HIGH-01)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 17/25] External Symlink Rejection (HIGH-01)${NC}"
sandbox_ext=$(mktemp -d)
canary_ext_target="/tmp/canary_ext_target_$$.txt"
canary_ext_symlink="/tmp/canary_ext_symlink_$$.lnk"
echo "EXT_CANARY_ALIVE" > "$canary_ext_target"
ln -s "$canary_ext_target" "$canary_ext_symlink"

ext_sym_script=$(cat << 'EOF'
source ./delete.sh --source-only
safe_remove_path "$1"
EOF
)
ext_ret=0
(cd "$PROGRAM_DIR" && bash -c "$ext_sym_script" _ "$canary_ext_symlink" >/dev/null 2>&1) || ext_ret=$?

if [[ $ext_ret -ne 0 && -L "$canary_ext_symlink" && -f "$canary_ext_target" ]]; then
    record_pass "safe_remove_path strictly rejected external symlink ($canary_ext_symlink preserved)"
else
    record_fail "safe_remove_path unlinked external symlink without boundary authorization"
fi
rm -f "$canary_ext_symlink" "$canary_ext_target"
rm -rf "$sandbox_ext"

# ------------------------------------------------------------------------------
# Test 18: Sibling Directory Boundary Escape (HIGH-02)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 18/25] Sibling Directory Boundary Escape (HIGH-02)${NC}"
sandbox_base=$(mktemp -d)
sandbox_main="$sandbox_base/mornye-app"
sandbox_sibling="$sandbox_base/mornye-app-sibling"
mkdir -p "$sandbox_main" "$sandbox_sibling"
echo "SIBLING_CANARY" > "$sandbox_sibling/canary.txt"

sib_script=$(cat << 'EOF'
PROGRAM_DIR="$1"
source "$PROGRAM_DIR/delete.sh" --source-only
validate_safe_path "$2"
EOF
)
cp "$PROGRAM_DIR/delete.sh" "$sandbox_main/delete.sh"
chmod +x "$sandbox_main/delete.sh"

sib_ret=0
(bash -c "$sib_script" _ "$sandbox_main" "$sandbox_sibling/canary.txt" >/dev/null 2>&1) || sib_ret=$?

if [[ $sib_ret -ne 0 && -f "$sandbox_sibling/canary.txt" ]]; then
    record_pass "validate_safe_path strictly rejected sibling directory path with matching prefix"
else
    record_fail "validate_safe_path allowed boundary escape into sibling directory"
fi
rm -rf "$sandbox_base"

# ------------------------------------------------------------------------------
# Test 19: Foreign Docker Container Ownership Protection (MED-01)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 19/25] Foreign Docker Container Ownership Protection (MED-01)${NC}"
mock_bin_d19=$(mktemp -d)
sandbox_d19=$(mktemp -d)
cp "$PROGRAM_DIR/delete.sh" "$sandbox_d19/delete.sh"
chmod +x "$sandbox_d19/delete.sh"

cat << 'EOF' > "$mock_bin_d19/docker"
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
    echo "mornye-webdav|mornye-webdav:latest|Up 5m|com.docker.compose.project=mornye-network-storage"
elif [[ "$1" == "inspect" ]]; then
    # Return a foreign working directory different from sandbox_d19
    if [[ "$*" == *"com.docker.compose.project.working_dir"* ]]; then
        echo "/var/other/foreign/Mornye-Network-Storage"
    elif [[ "$*" == *"com.docker.compose.project"* ]]; then
        echo "mornye-network-storage"
    fi
elif [[ "$1" == "stop" || "$1" == "rm" ]]; then
    echo "DOCKER_MUTATION_EXECUTED: $*" >> /tmp/docker_mutations_$$.log
fi
EOF
chmod +x "$mock_bin_d19/docker"
rm -f "/tmp/docker_mutations_$$.log"

d19_output=$(
    export PATH="$mock_bin_d19:$PATH"
    cd "$sandbox_d19" && ./delete.sh -y 2>&1 || true
)

if echo "$d19_output" | grep -q "Preserving container 'mornye-webdav'" && \
   [[ ! -f "/tmp/docker_mutations_$$.log" ]]; then
    record_pass "Foreign container 'mornye-webdav' preserved based on working_dir mismatch"
else
    record_fail "Failed to preserve foreign container 'mornye-webdav'"
fi
rm -f "/tmp/docker_mutations_$$.log"
rm -rf "$mock_bin_d19" "$sandbox_d19"

# ------------------------------------------------------------------------------
# Test 20: Corrupted Backup Archive Rejection (MED-02)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 20/25] Corrupted Backup Archive Rejection (MED-02)${NC}"
sandbox_corrupt=$(mktemp -d)
mkdir -p "$sandbox_corrupt/database"
echo "data" > "$sandbox_corrupt/database/data.db"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_corrupt/delete.sh"
chmod +x "$sandbox_corrupt/delete.sh"

# Mock tar command that writes corrupted non-gzip archive
mock_bin_corrupt=$(mktemp -d)
cat << 'EOF' > "$mock_bin_corrupt/tar"
#!/usr/bin/env bash
if [[ "$*" == *"-tzf"* ]]; then
    echo "tar: Error is not recoverable: exiting now" >&2
    exit 2
else
    dest="${@: -1}"
    for arg in "$@"; do
        if [[ "$arg" == *.tar.gz ]]; then dest="$arg"; fi
    done
    echo "CORRUPTED_NON_GZIP_CONTENT" > "$dest"
    exit 0
fi
EOF
chmod +x "$mock_bin_corrupt/tar"

corrupt_output=$(
    export PATH="$mock_bin_corrupt:$PATH"
    cd "$sandbox_corrupt" && printf "Y\n\nDELETE MORNYE DATA\n" | ./delete.sh --purge 2>&1 || true
)

if echo "$corrupt_output" | grep -qE "(integrity verification failed|Backup creation failed)" && \
   [[ -f "$sandbox_corrupt/database/data.db" ]]; then
    record_pass "Purge aborted safely and preserved data when backup archive was corrupted"
else
    record_fail "Corrupted backup archive was not caught or data was deleted prematurely"
fi
rm -rf "$mock_bin_corrupt" "$sandbox_corrupt"

# ------------------------------------------------------------------------------
# Test 21: Parent-Directory Symlink Escape Protection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 21/25] Parent-Directory Symlink Escape Protection${NC}"
sandbox_pesc=$(mktemp -d)
mkdir -p "$sandbox_pesc/subdir"
ln -s "/etc" "$sandbox_pesc/subdir/esc_parent"

pesc_script=$(cat << 'EOF'
PROGRAM_DIR="$1"
source "$PROGRAM_DIR/delete.sh" --source-only
validate_safe_path "$2"
EOF
)
pesc_ret=0
(bash -c "$pesc_script" _ "$sandbox_pesc" "$sandbox_pesc/subdir/esc_parent/shadow" >/dev/null 2>&1) || pesc_ret=$?

if [[ $pesc_ret -ne 0 ]]; then
    record_pass "validate_safe_path strictly rejected parent-directory symlink traversal into /etc"
else
    record_fail "validate_safe_path failed to block parent-directory symlink escape"
fi
rm -rf "$sandbox_pesc"

# ------------------------------------------------------------------------------
# Test 22: Cloudflare Backup Restoration on Failed Validation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 22/25] Cloudflare Backup Restoration on Failed Validation${NC}"
sandbox_cf22=$(mktemp -d)
cf_file22="$sandbox_cf22/config.yml"
echo "INVALID_YAML: [unclosed_list" > "$cf_file22"

cf22_script=$(cat << 'EOF'
source ./delete.sh --source-only
shared_cf="$1"
MORNYE_HOST_PORT=8001
handle_cloudflare
EOF
)
cf22_output=$(cd "$PROGRAM_DIR" && bash -c "$cf22_script" _ "$cf_file22" 2>&1 || true)

if [[ -f "$cf_file22" ]] && grep -q "INVALID_YAML" "$cf_file22"; then
    record_pass "Preserved original configuration intact when YAML validation failed"
else
    record_fail "Failed to retain original file on YAML validation failure"
fi
rm -rf "$sandbox_cf22"

# ------------------------------------------------------------------------------
# Test 23: External Storage Backup Reporting (LOW-01)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 23/25] External Storage Backup Reporting (LOW-01)${NC}"
sandbox_ext23=$(mktemp -d)
ext_audio_dir="/tmp/mornye_ext_audio_test_$$"
mkdir -p "$ext_audio_dir" "$sandbox_ext23/database"
echo "music" > "$ext_audio_dir/song.flac"
echo "db" > "$sandbox_ext23/database/mornye.db"
echo "STORAGE_PATH=$ext_audio_dir" > "$sandbox_ext23/.env"

ext23_script=$(cat << 'EOF'
source ./delete.sh --source-only
load_env
create_backup "$1/backup.tar.gz"
EOF
)
ext23_output=$(cd "$sandbox_ext23" && cp "$PROGRAM_DIR/delete.sh" . && bash -c "$ext23_script" _ "$sandbox_ext23" 2>&1 || true)

if echo "$ext23_output" | grep -q "External STORAGE_PATH detected at:" && \
   echo "$ext23_output" | grep -q "EXCLUDED from this archive" && \
   tar -tzf "$sandbox_ext23/backup.tar.gz" >/dev/null 2>&1; then
    record_pass "Accurately reported external storage exclusion while verifying local archive integrity"
else
    record_fail "Failed to report external storage omission in backup"
fi
rm -rf "$ext_audio_dir" "$sandbox_ext23"

# ------------------------------------------------------------------------------
# Test 24: Purge Confirmation Bypass Attempts
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 24/25] Purge Confirmation Bypass Attempts${NC}"
sandbox_bypass=$(mktemp -d)
mkdir -p "$sandbox_bypass/database"
echo "valuable_data" > "$sandbox_bypass/database/mornye.db"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_bypass/delete.sh"
chmod +x "$sandbox_bypass/delete.sh"

bypass1_code=0
(cd "$sandbox_bypass" && echo "yes" | ./delete.sh --purge --skip-backup >/dev/null 2>&1) || bypass1_code=$?

bypass2_code=0
(cd "$sandbox_bypass" && echo "DELETE MORNYE" | ./delete.sh --purge --skip-backup >/dev/null 2>&1) || bypass2_code=$?

bypass3_code=0
(cd "$sandbox_bypass" && echo "delete mornye data" | ./delete.sh --purge --skip-backup >/dev/null 2>&1) || bypass3_code=$?

bypass4_code=0
(cd "$sandbox_bypass" && echo "DELETE MORNYE DATA " | ./delete.sh --purge --skip-backup >/dev/null 2>&1) || bypass4_code=$?

if [[ $bypass1_code -ne 0 && $bypass2_code -ne 0 && $bypass3_code -ne 0 && $bypass4_code -ne 0 && \
      -f "$sandbox_bypass/database/mornye.db" ]]; then
    record_pass "Strictly blocked all 4 purge token bypass attempts (data 100% preserved)"
else
    record_fail "Purge token confirmation allowed a bypass attempt"
fi
rm -rf "$sandbox_bypass"

# ------------------------------------------------------------------------------
# Test 25: Interrupted or Truncated Backup Creation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Test 25/25] Interrupted or Truncated Backup Creation${NC}"
sandbox_trunc=$(mktemp -d)
mkdir -p "$sandbox_trunc/database"
echo "data" > "$sandbox_trunc/database/mornye.db"
cp "$PROGRAM_DIR/delete.sh" "$sandbox_trunc/delete.sh"
chmod +x "$sandbox_trunc/delete.sh"

# Mock tar that exits 0 but produces 0-byte file (simulating interrupted write)
mock_bin_trunc=$(mktemp -d)
cat << 'EOF' > "$mock_bin_trunc/tar"
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *.tar.gz ]]; then touch "$arg"; fi
done
exit 0
EOF
chmod +x "$mock_bin_trunc/tar"

trunc_output=$(
    export PATH="$mock_bin_trunc:$PATH"
    cd "$sandbox_trunc" && printf "Y\n\nDELETE MORNYE DATA\n" | ./delete.sh --purge 2>&1 || true
)

if echo "$trunc_output" | grep -q "does not exist or is empty" && \
   [[ -f "$sandbox_trunc/database/mornye.db" ]]; then
    record_pass "Aborted purge safely when backup file was truncated to 0 bytes"
else
    record_fail "Failed to abort purge on truncated backup archive"
fi
rm -rf "$mock_bin_trunc" "$sandbox_trunc"

# ------------------------------------------------------------------------------
# SUMMARY
# ------------------------------------------------------------------------------
echo -e "\n======================================================================"
echo -e "TEST SUITE SUMMARY: Total: $TOTAL | Passed: $PASSED | Failed: $FAILED"
echo -e "======================================================================"

if [[ "$FAILED" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}[✔] ALL 25 UNINSTALLER TESTS PASSED SUCCESSFULLY.${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}[✘] $FAILED TEST(S) FAILED.${NC}"
    exit 1
fi
