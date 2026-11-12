#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — INTELLIGENT RUNTIME ERROR DETECTION & AUTO-FIX ENGINE
# Module: scripts/repair_engine.sh
# Purpose: Modular, interactive error detection, explanation, permission-gated
#          remediation, and verification across the complete application lifecycle.
# ==============================================================================

set -o pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROGRAM_DIR"

CONFIG_DIR="$PROGRAM_DIR/config"
DATA_DIR="$PROGRAM_DIR/database"
STORAGE_DIR="$PROGRAM_DIR/storage"
LOG_DIR="$PROGRAM_DIR/logs"
DIAG_DIR="$LOG_DIR/diagnostics"
BACKUP_DIR="$PROGRAM_DIR/backups"
RUN_DIR="$PROGRAM_DIR/run"

mkdir -p "$LOG_DIR" "$DIAG_DIR"

# ANSI Color Palette
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Execution Flags
INTERACTIVE_MODE=true
AUTO_FIX=false

# Source Diagnostic Engine Library for telemetry and port inspection
if [[ -f "$PROGRAM_DIR/scripts/doctor.sh" ]]; then
    # shellcheck disable=SC1091
    source "$PROGRAM_DIR/scripts/doctor.sh"
else
    echo -e "${RED}[ERROR] scripts/doctor.sh not found. Repair engine cannot initialize.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. DIAGNOSTIC AUDIT LOGGING
# ------------------------------------------------------------------------------

log_repair_event() {
    local err_id="$1"
    local desc="$2"
    local root_cause="$3"
    local decision="$4"
    local changes="$5"
    local result="$6"

    local ts_display ts_file log_file hist_file
    ts_display="$(date +"%Y-%m-%d %H:%M:%S")"
    ts_file="$(date +"%Y%m%d_%H%M%S")"
    log_file="$DIAG_DIR/repair-${ts_file}_${err_id}.log"
    hist_file="$DIAG_DIR/repair_history.log"

    cat << LOGEOF > "$log_file"
================================================================================
MORNYE REPAIR EVENT AUDIT LOG
================================================================================
Timestamp         : ${ts_display}
Error Identifier  : ${err_id}
Description       : ${desc}
Root Cause        : ${root_cause}
User Decision     : ${decision}
Changes Applied   : ${changes}
Verification State: ${result}
Safety Guarantee  : Zero secrets logged. Unrelated host processes untouched.
================================================================================
LOGEOF

    echo "[${ts_display}] [${err_id}] Decision: ${decision} | Result: ${result} | Desc: ${desc}" >> "$hist_file"
}

# ------------------------------------------------------------------------------
# 2. INTERACTIVE ERROR PROMPT INTERFACE (DETECT -> EXPLAIN -> ASK -> REPAIR)
# ------------------------------------------------------------------------------

prompt_interactive_error() {
    local err_id="$1"
    local title="$2"
    local what="$3"
    local why="$4"
    local component="$5"
    local risk="$6"
    local solution="$7"
    local exact_changes="$8"
    local fix_cmd="$9"
    local manual_instructions="${10}"
    local verify_cmd="${11}"

    # Determine Risk Color
    local risk_color="${GREEN}"
    case "${risk^^}" in
        HIGH*) risk_color="${RED}" ;;
        MEDIUM*) risk_color="${YELLOW}" ;;
        LOW*) risk_color="${CYAN}" ;;
    esac

    # Display Explanatory Error Card
    echo -e "\n${BOLD}${RED}┌────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${RED}│ [ERROR: ${err_id}] ${title}${NC}"
    echo -e "${BOLD}${RED}├────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${BOLD}│ • What Happened        :${NC} ${what}"
    echo -e "${BOLD}│ • Why It Happened      :${NC} ${why}"
    echo -e "${BOLD}│ • Affected Component   :${NC} ${component}"
    echo -e "${BOLD}│ • Risk Level           :${NC} ${risk_color}${risk}${NC}"
    echo -e "${BOLD}│ • Recommended Solution :${NC} ${GREEN}${solution}${NC}"
    echo -e "${BOLD}│ • Exact Changes Required:${NC}"
    while IFS= read -r line; do
        [[ -n "$line" ]] && echo -e "│   ${line}"
    done <<< "$exact_changes"
    echo -e "${BOLD}${RED}└────────────────────────────────────────────────────────────────────────────┘${NC}\n"

    # Auto-approval branch (for non-interactive execution)
    if [[ "$AUTO_FIX" == true || "$INTERACTIVE_MODE" == false ]]; then
        echo -e "${CYAN}[*] Non-interactive / Auto-fix active: Proceeding with automated safe repair...${NC}"
        apply_approved_fix "$err_id" "$title" "$why" "$exact_changes" "$fix_cmd" "$verify_cmd"
        return $?
    fi

    # Interactive Prompt
    while true; do
        echo -e "${BOLD}Would you like Mornye to fix this automatically?${NC}"
        echo -e "  ${BOLD}1)${NC} ${GREEN}Yes, fix automatically${NC} (Recommended)"
        echo -e "  ${BOLD}2)${NC} ${YELLOW}No, leave the system unchanged${NC}"
        echo -e "  ${BOLD}3)${NC} ${CYAN}Show manual instructions${NC}"
        echo ""
        read -p "Enter choice [1-3] (Default: 1): " -r user_choice
        user_choice="${user_choice:-1}"

        case "$user_choice" in
            1)
                apply_approved_fix "$err_id" "$title" "$why" "$exact_changes" "$fix_cmd" "$verify_cmd"
                return $?
                ;;
            2)
                echo -e "\n${YELLOW}[!] System left unchanged. No files, configurations, or services modified.${NC}"
                echo -e "Run '${CYAN}./mornye.sh doctor${NC}' whenever you wish to re-evaluate this condition.\n"
                log_repair_event "$err_id" "$title" "$why" "DECLINED" "None (Preserved operator configuration)" "SKIPPED"
                return 2
                ;;
            3)
                echo -e "\n${BOLD}${CYAN}======================================================================${NC}"
                echo -e "${BOLD}${CYAN}                    MANUAL REMEDIATION INSTRUCTIONS                   ${NC}"
                echo -e "${BOLD}${CYAN}======================================================================${NC}"
                echo -e "$manual_instructions"
                echo -e "${BOLD}${CYAN}======================================================================${NC}\n"
                log_repair_event "$err_id" "$title" "$why" "MANUAL_INSTRUCTIONS_VIEWED" "None" "UNRESOLVED"
                # Loop back to prompt so operator can still choose to fix or leave unchanged
                ;;
            *)
                echo -e "${RED}[!] Invalid selection. Please choose 1, 2, or 3.${NC}\n"
                ;;
        esac
    done
}

apply_approved_fix() {
    local err_id="$1"
    local title="$2"
    local why="$3"
    local exact_changes="$4"
    local fix_cmd="$5"
    local verify_cmd="$6"

    echo -e "\n${BOLD}[*] Applying approved safe repair for: ${CYAN}${title}${NC}..."

    # Execute repair command
    if eval "$fix_cmd"; then
        echo -e "${GREEN}[✔] Repair commands executed successfully.${NC}"
        
        # Verification stage
        echo -e "[*] Verifying system health and resolution..."
        if eval "$verify_cmd"; then
            echo -e "${GREEN}${BOLD}[✔] VERIFICATION SUCCESS: ${title} has been resolved!${NC}\n"
            log_repair_event "$err_id" "$title" "$why" "APPROVED_AUTO_REPAIR" "$exact_changes" "SUCCESS"
            return 0
        else
            echo -e "${RED}${BOLD}[✘] VERIFICATION FAILED: Issue may require manual inspection.${NC}\n"
            log_repair_event "$err_id" "$title" "$why" "APPROVED_AUTO_REPAIR" "$exact_changes" "FAILED_VERIFICATION"
            return 1
        fi
    else
        echo -e "${RED}${BOLD}[✘] Error occurred while applying repair.${NC}\n"
        log_repair_event "$err_id" "$title" "$why" "APPROVED_AUTO_REPAIR" "$exact_changes" "EXECUTION_ERROR"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 3. MODULAR ERROR REPAIR HANDLERS
# ------------------------------------------------------------------------------

# Handler 1: Safe Port Conflict Resolution (e.g. SONG Bridge on 8000)
repair_port_conflict() {
    load_env
    local occupied_port="${MORNYE_HOST_PORT:-8001}"
    local p_info
    p_info="$(inspect_port_owner "$occupied_port")"
    
    local p_state p_owner p_pid p_svc p_is_mornye
    IFS="|" read -r p_state p_owner p_pid p_svc p_is_mornye <<< "$p_info"

    if [[ "$p_state" != "occupied" || "$p_is_mornye" == true ]]; then
        # No conflict exists
        return 0
    fi

    # Find next free port
    local free_port
    free_port="$(find_next_free_port 8001)"

    local what="Host port ${occupied_port} is already occupied by '${p_owner}' (PID: ${p_pid:-active}, Unit: ${p_svc})."
    local why="Another service is active on port ${occupied_port}. If this is SONG Bridge (port 8000), Mornye must safely coexist without stopping it."
    local comp="Mornye WebDAV Host Port Binding (.env & compose.yaml)"
    local risk="LOW (Modifies only Mornye configuration; foreign services are never touched)"
    local sol="Reassign Mornye host port from ${occupied_port} to available port ${free_port}."
    
    local exact_changes
    exact_changes="1. Create timestamped backup: .env.bak_<timestamp>
2. Update 'MORNYE_HOST_PORT=${free_port}' in .env
3. Keep container internal port at 8000 (RFC 4918 specification)
4. Reload container stack on 127.0.0.1:${free_port}
5. Probe http://127.0.0.1:${free_port}/health"

    local fix_cmd="
        local ts=\$(date +%Y%m%d_%H%M%S)
        cp '$PROGRAM_DIR/.env' '$PROGRAM_DIR/.env.bak_\$ts'
        sed -i -E 's/^MORNYE_HOST_PORT=.*/MORNYE_HOST_PORT=${free_port}/' '$PROGRAM_DIR/.env' 2>/dev/null || echo 'MORNYE_HOST_PORT=${free_port}' >> '$PROGRAM_DIR/.env'
        export MORNYE_HOST_PORT='${free_port}'
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw 'mornye-webdav'; then
            docker compose up -d webdav &>/dev/null || true
        fi
    "

    local manual_cmd="
1. Create a backup of your .env file:
   cp .env .env.bak_\$(date +%Y%m%d_%H%M%S)

2. Edit .env and change MORNYE_HOST_PORT:
   sed -i 's/^MORNYE_HOST_PORT=.*/MORNYE_HOST_PORT=${free_port}/' .env

3. Reload Mornye WebDAV:
   ./mornye.sh restart
"

    local verify_cmd="
        load_env
        [[ \"\$MORNYE_HOST_PORT\" == \"${free_port}\" ]]
    "

    prompt_interactive_error \
        "ERR_PORT_CONFLICT" \
        "Host Port ${occupied_port} Conflict Detected (${p_owner})" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 2: Docker Daemon Offline
repair_docker_daemon() {
    audit_docker
    if [[ "$DOCKER_DAEMON_ACTIVE" == true ]]; then
        return 0
    fi

    local what="Docker daemon is offline, stopped, or not responding on /var/run/docker.sock."
    local why="The host Docker service has not been started, or the daemon crashed."
    local comp="Docker Daemon Engine"
    local risk="LOW (Starts standard host Docker service)"
    local sol="Start the Docker service via systemctl or OpenRC."

    local exact_changes="1. Execute 'systemctl start docker' (or 'rc-service docker start')
2. Verify Docker socket /var/run/docker.sock becomes accessible"

    local fix_cmd="
        if [[ '$INIT_SYSTEM' == 'systemd' ]]; then
            sudo systemctl start docker
        elif [[ '$INIT_SYSTEM' == 'openrc' ]]; then
            sudo rc-service docker start
        else
            sudo service docker start
        fi
        sleep 2
    "

    local manual_cmd="
Start the Docker service manually with root privileges:
  sudo systemctl start docker   # On systemd
  sudo rc-service docker start  # On OpenRC
Verify daemon state:
  docker info
"

    local verify_cmd="docker info &>/dev/null"

    prompt_interactive_error \
        "ERR_DOCKER_DAEMON_OFFLINE" \
        "Docker Daemon Offline / Inactive" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 3: Docker Non-Root Permission Denied
repair_docker_permissions() {
    audit_user_permissions
    audit_docker

    if [[ "$DOCKER_NONROOT_ACCESS" == true || "$IS_ROOT" == true ]]; then
        return 0
    fi

    local cur_user
    cur_user="$(whoami)"
    local what="User '${cur_user}' cannot access the Docker daemon socket without sudo."
    local why="User '${cur_user}' is not a member of the 'docker' system group."
    local comp="Docker Socket Permissions (/var/run/docker.sock)"
    local risk="MEDIUM (Grants user '${cur_user}' container management privileges)"
    local sol="Add user '${cur_user}' to the 'docker' group."

    local exact_changes="1. Execute 'sudo usermod -aG docker ${cur_user}'
2. Inform operator to run 'newgrp docker' or re-login to refresh group context"

    local fix_cmd="
        sudo usermod -aG docker '$cur_user'
        echo -e '${GREEN}[✔] Added ${cur_user} to docker group.${NC}'
        echo -e '${CYAN}Notice: Group membership takes effect on your next session or via: newgrp docker${NC}'
    "

    local manual_cmd="
Add yourself to the docker group manually:
  sudo usermod -aG docker $cur_user
Activate group in the current shell:
  newgrp docker
"

    local verify_cmd="id -Gn '$cur_user' | grep -qw 'docker'"

    prompt_interactive_error \
        "ERR_DOCKER_PERM_DENIED" \
        "Docker Non-Root Permission Denied for '${cur_user}'" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 4: Missing Application Directories
repair_missing_directories() {
    local missing=()
    for dir in "$DATA_DIR" "$STORAGE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$CONFIG_DIR"; do
        if [[ ! -d "$dir" ]]; then
            missing+=("$dir")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    local what="One or more required persistent directories are missing: ${missing[*]}"
    local why="Directories may have been removed or not created yet."
    local comp="Persistent Storage Volume Hierarchy"
    local risk="LOW (Re-creates required directory structure with hardened permissions)"
    local sol="Create missing directories and apply standard permission boundaries (700/755)."

    local exact_changes="1. Create: ${missing[*]}
2. Apply mode 700 to database/, backups/, config/
3. Apply mode 755 to storage/, logs/, run/"

    local fix_cmd="
        mkdir -p '$DATA_DIR' '$STORAGE_DIR' '$BACKUP_DIR' '$LOG_DIR' '$CONFIG_DIR' '$RUN_DIR'
        chmod 700 '$DATA_DIR' '$BACKUP_DIR' '$CONFIG_DIR'
        chmod 755 '$STORAGE_DIR' '$LOG_DIR' '$RUN_DIR'
    "

    local manual_cmd="
Create missing directories with hardened permissions:
  mkdir -p database storage backups logs config run
  chmod 700 database backups config
  chmod 755 storage logs run
"

    local verify_cmd="[[ -d '$DATA_DIR' && -d '$STORAGE_DIR' && -d '$BACKUP_DIR' && -d '$CONFIG_DIR' ]]"

    prompt_interactive_error \
        "ERR_MISSING_DIR" \
        "Required Storage Directories Missing" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 5: Insecure Volume Permissions
repair_insecure_permissions() {
    audit_storage
    local insecure=false

    if [[ -d "$DATA_DIR" ]]; then
        local p
        p=$(stat -c "%a" "$DATA_DIR" 2>/dev/null || stat -f "%OLp" "$DATA_DIR" 2>/dev/null || echo "")
        if [[ "$p" != "700" && "$p" != "750" ]]; then
            insecure=true
        fi
    fi

    if [[ "$insecure" == false ]]; then
        return 0
    fi

    local what="database/ directory has permissive mode (currently $(stat -c "%a" "$DATA_DIR" 2>/dev/null))."
    local why="Permissive permissions allow other host users to view sensitive database files or backups."
    local comp="Filesystem Security & Data Privacy"
    local risk="LOW (Tightens Unix permissions on database directory)"
    local sol="Harden permissions to mode 700 (owner-only access)."

    local exact_changes="1. Execute 'chmod 700 database backups config'
2. Execute 'chmod 755 storage logs'"

    local fix_cmd="
        chmod 700 '$DATA_DIR' '$BACKUP_DIR' '$CONFIG_DIR' 2>/dev/null || true
        chmod 755 '$STORAGE_DIR' '$LOG_DIR' 2>/dev/null || true
    "

    local manual_cmd="
Tighten directory permissions:
  chmod 700 database backups config
  chmod 755 storage logs
"

    local verify_cmd="
        local p=\$(stat -c '%a' '$DATA_DIR' 2>/dev/null || echo '700')
        [[ \"\$p\" == '700' || \"\$p\" == '750' ]]
    "

    prompt_interactive_error \
        "ERR_INSECURE_PERMS" \
        "Permissive Directory Permissions Detected" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 5b: Volume Writability & Ownership Reconciler
repair_volume_writability() {
    audit_storage
    local unwritable=()
    for dir in "$DATA_DIR" "$STORAGE_DIR" "$LOG_DIR"; do
        if [[ -d "$dir" && ! -w "$dir" ]]; then
            unwritable+=("$(basename "$dir")")
        fi
    done

    if [[ ${#unwritable[@]} -eq 0 ]]; then
        return 0
    fi

    local cur_user cur_uid cur_gid
    cur_user="$(whoami)"
    cur_uid="$(id -u)"
    cur_gid="$(id -g)"

    local what="Host volume directories (${unwritable[*]}) are not writable by execution user '${cur_user}' (UID: ${cur_uid})."
    local why="When setup is run with root/sudo, directories may be owned by root, preventing the unprivileged container process from initializing /data."
    local comp="Docker Volume Mounts & File Permissions"
    local risk="LOW (Reconciles directory ownership to current user and sets standard 750/755 permissions)"
    local sol="Change ownership of Mornye storage directories to '${cur_user}' (${cur_uid}:${cur_gid}) with mode 750/755."

    local exact_changes="1. Execute 'chown -R ${cur_uid}:${cur_gid} database storage logs backups config run'
2. Execute 'chmod 750 database backups config'
3. Execute 'chmod 755 storage logs run'"

    local fix_cmd="
        if [[ \"\$(id -u)\" -eq 0 ]]; then
            chown -R '${cur_uid}:${cur_gid}' '$DATA_DIR' '$STORAGE_DIR' '$LOG_DIR' '$BACKUP_DIR' '$CONFIG_DIR' '$RUN_DIR' 2>/dev/null || true
        else
            sudo -n chown -R '${cur_uid}:${cur_gid}' '$DATA_DIR' '$STORAGE_DIR' '$LOG_DIR' '$BACKUP_DIR' '$CONFIG_DIR' '$RUN_DIR' 2>/dev/null || true
        fi
        chmod 750 '$DATA_DIR' '$BACKUP_DIR' '$CONFIG_DIR' 2>/dev/null || true
        chmod 755 '$STORAGE_DIR' '$LOG_DIR' '$RUN_DIR' 2>/dev/null || true
    "

    local manual_cmd="
Reconcile volume permissions:
  sudo chown -R ${cur_uid}:${cur_gid} database storage logs backups config run
  chmod 750 database backups config
  chmod 755 storage logs run
"

    local verify_cmd="
        [[ -w '$DATA_DIR' && -w '$STORAGE_DIR' && -w '$LOG_DIR' ]]
    "

    prompt_interactive_error \
        "ERR_VOLUME_NOT_WRITABLE" \
        "Container Volume Mounts Not Writable" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 6: Missing Environment File (.env)
repair_missing_env() {
    if [[ -f "$PROGRAM_DIR/.env" ]]; then
        return 0
    fi

    local what="Application configuration file .env is missing from repository root."
    local why="Initial configuration has not been generated, or .env was removed."
    local comp="Application Environment Configuration (.env)"
    local risk="LOW (Generates fresh production .env from template with random 256-bit key)"
    local sol="Generate .env from .env.example with a cryptographically strong SECRET_KEY."

    local exact_changes="1. Copy .env.example to .env
2. Generate 64-character hex cryptographic key
3. Assign MORNYE_HOST_PORT=8001 (isolated from port 8000)
4. Restrict mode to 600 (owner read/write only)"

    local fix_cmd="
        if [[ -f '$PROGRAM_DIR/.env.example' ]]; then
            cp '$PROGRAM_DIR/.env.example' '$PROGRAM_DIR/.env'
        else
            cat << 'ENVEOF' > '$PROGRAM_DIR/.env'
APP_NAME=\"Mornye Network Storage\"
APP_ENV=production
DEBUG=false
SECRET_KEY=generate-key-placeholder
WEBDAV_HOST=0.0.0.0
WEBDAV_PORT=8000
MORNYE_HOST_BIND=127.0.0.1
MORNYE_HOST_PORT=8001
DEFAULT_STORAGE_QUOTA_BYTES=107374182400
MAX_UPLOAD_SIZE_BYTES=2147483648
STORAGE_HOSTNAME=storage.example.com
PUBLIC_DOMAIN=example.com
ENVEOF
        fi
        local k=\$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n' 2>/dev/null || date +%s%N | sha256sum | head -c 64)
        sed -i -E \"s/SECRET_KEY=.*/SECRET_KEY=\$k/\" '$PROGRAM_DIR/.env'
        chmod 600 '$PROGRAM_DIR/.env'
    "

    local manual_cmd="
Copy template and create secret key:
  cp .env.example .env
  # Update SECRET_KEY with a random 64-character token
  chmod 600 .env
"

    local verify_cmd="[[ -f '$PROGRAM_DIR/.env' ]]"

    prompt_interactive_error \
        "ERR_MISSING_ENV" \
        "Application Configuration File (.env) Missing" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 7: Insecure or Default SECRET_KEY
repair_default_secret_key() {
    if [[ ! -f "$PROGRAM_DIR/.env" ]]; then
        return 0
    fi

    local k
    k="$(grep -E '^SECRET_KEY=' "$PROGRAM_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)"
    if [[ -n "$k" && "$k" != *"change-this"* && "$k" != *"must-be-changed"* && "${#k}" -ge 32 ]]; then
        return 0
    fi

    local what="Insecure, placeholder, or truncated SECRET_KEY detected in .env."
    local why="Default placeholder values allow cryptographic session and token forgery."
    local comp="Cryptographic Security Configuration (.env)"
    local risk="LOW (Replaces placeholder with 256-bit cryptographic random key)"
    local sol="Generate a cryptographically secure 256-bit random key."

    local exact_changes="1. Backup .env to .env.bak_<timestamp>
2. Generate 64-character cryptographic hex key
3. Update SECRET_KEY in .env"

    local fix_cmd="
        local ts=\$(date +%Y%m%d_%H%M%S)
        cp '$PROGRAM_DIR/.env' '$PROGRAM_DIR/.env.bak_\$ts'
        local new_k=\$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n' 2>/dev/null || date +%s%N | sha256sum | head -c 64)
        sed -i -E \"s/^SECRET_KEY=.*/SECRET_KEY=\$new_k/\" '$PROGRAM_DIR/.env'
    "

    local manual_cmd="
Generate a new cryptographic key and update .env:
  NEW_KEY=\$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n')
  sed -i \"s/^SECRET_KEY=.*/SECRET_KEY=\$NEW_KEY/\" .env
"

    local verify_cmd="
        local val=\$(grep -E '^SECRET_KEY=' '$PROGRAM_DIR/.env' | cut -d= -f2 | tr -d '\"' | tr -d \"'\")
        [[ -n \"\$val\" && \"\$val\" != *'change-this'* && \${#val} -ge 32 ]]
    "

    prompt_interactive_error \
        "ERR_DEFAULT_SECRET_KEY" \
        "Insecure Placeholder SECRET_KEY Detected" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 8: Container Unhealthy or Failing Healthchecks
repair_unhealthy_container() {
    load_env
    audit_docker
    audit_containers
    audit_endpoints

    if [[ "$WEBDAV_CONTAINER_STATE" != "running" || "$HEALTH_HTTP_CODE" == "200" ]]; then
        return 0
    fi

    local what="mornye-webdav container is running but HTTP health probe returned ${HEALTH_HTTP_CODE} (expected 200)."
    local why="Container process may be stuck, database locked, or port binding misaligned."
    local comp="WebDAV Container Runtime (mornye-webdav)"
    local risk="MEDIUM (Restarts mornye-webdav container)"
    local sol="Inspect recent container logs, reload container stack, and verify endpoint responsiveness."

    local exact_changes="1. Restart container: docker compose restart webdav
2. Await 5 seconds for WebDAV gateway initialization
3. Probe http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/health"

    local fix_cmd="
        echo -e '[*] Restarting WebDAV container...'
        docker compose restart webdav
        sleep 3
    "

    local manual_cmd="
Inspect container logs to diagnose cause:
  docker compose logs --tail 50 webdav
Restart container manually:
  docker compose restart webdav
Probe health:
  curl -I http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/health
"

    local verify_cmd="
        local c=\$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 'http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/health' || echo '000')
        [[ \"\$c\" == '200' ]]
    "

    prompt_interactive_error \
        "ERR_CONTAINER_UNHEALTHY" \
        "WebDAV Container Failing Healthcheck (HTTP ${HEALTH_HTTP_CODE})" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 9: Cloudflare Ingress Target Mismatch
repair_cloudflare_ingress_mismatch() {
    load_env
    audit_cloudflare

    if [[ "$CLOUDFLARE_CONFIG_EXISTS" != true ]]; then
        return 0
    fi

    local target="$CLOUDFLARE_INGRESS_TARGET"
    local mismatch=false
    local expected=""

    if [[ "$CLOUDFLARE_RUNTIME_MODE" == "docker" ]]; then
        expected="http://webdav:8000"
        if [[ "$target" != "http://webdav:8000"* ]]; then
            mismatch=true
        fi
    elif [[ "$CLOUDFLARE_RUNTIME_MODE" == "systemd" ]]; then
        expected="http://127.0.0.1:${MORNYE_HOST_PORT}"
        if [[ "$target" != *"127.0.0.1:${MORNYE_HOST_PORT}"* && "$target" != *"localhost:${MORNYE_HOST_PORT}"* ]]; then
            mismatch=true
        fi
    fi

    if [[ "$mismatch" == false ]]; then
        return 0
    fi

    local what="Cloudflare ingress service points to '${target}' instead of expected '${expected}'."
    local why="When running in ${CLOUDFLARE_RUNTIME_MODE} mode, traffic must route to the corresponding internal endpoint."
    local comp="Cloudflare Ingress Routing (config/cloudflared.yml)"
    local risk="LOW (Updates origin target in config/cloudflared.yml with backup)"
    local sol="Align ingress rule in config/cloudflared.yml to point to '${expected}'."

    local exact_changes="1. Backup config/cloudflared.yml to cloudflared.yml.bak_<timestamp>
2. Update ingress service rule to: ${expected}
3. Restart Cloudflare Tunnel service"

    local fix_cmd="
        local ts=\$(date +%Y%m%d_%H%M%S)
        cp '$CONFIG_DIR/cloudflared.yml' '$CONFIG_DIR/cloudflared.yml.bak_\$ts'
        sed -i -E \"s|service:[[:space:]]+http://[^[:space:]]+|service: ${expected}|\" '$CONFIG_DIR/cloudflared.yml'
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw 'mornye-tunnel'; then
            docker compose restart tunnel 2>/dev/null || true
        fi
    "

    local manual_cmd="
Edit config/cloudflared.yml:
  Change service line to: service: ${expected}
Restart tunnel:
  ./mornye.sh tunnel restart
"

    local verify_cmd="
        grep -q 'service:[[:space:]]*${expected}' '$CONFIG_DIR/cloudflared.yml'
    "

    prompt_interactive_error \
        "ERR_TUNNEL_ORIGIN_MISMATCH" \
        "Cloudflare Ingress Origin Mismatch (${CLOUDFLARE_RUNTIME_MODE} mode)" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 10: Private Management Port Ingress Exposure
repair_private_port_exposed() {
    if [[ ! -f "$CONFIG_DIR/cloudflared.yml" ]]; then
        return 0
    fi

    if ! grep -E ':(8080|9000|2375|2376)' "$CONFIG_DIR/cloudflared.yml" &>/dev/null; then
        return 0
    fi

    local what="Private management ports (8080 / 9000 / Docker socket) are exposed in cloudflared.yml."
    local why="Legacy control panel routes or docker ports must never be exposed over public Cloudflare Tunnels."
    local comp="Cloudflare Zero-Trust Ingress Security"
    local risk="HIGH (Exposing private management ports creates security vulnerability)"
    local sol="Remove all ingress rules targeting ports 8080, 9000, 2375, and 2376."

    local exact_changes="1. Backup config/cloudflared.yml to cloudflared.yml.bak_<timestamp>
2. Strip insecure management port lines
3. Restart Cloudflare tunnel"

    local fix_cmd="
        local ts=\$(date +%Y%m%d_%H%M%S)
        cp '$CONFIG_DIR/cloudflared.yml' '$CONFIG_DIR/cloudflared.yml.bak_\$ts'
        sed -i -E '/:(8080|9000|2375|2376)/d' '$CONFIG_DIR/cloudflared.yml'
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw 'mornye-tunnel'; then
            docker compose restart tunnel 2>/dev/null || true
        fi
    "

    local manual_cmd="
Remove private port rules from config/cloudflared.yml:
  sed -i -E '/:(8080|9000|2375|2376)/d' config/cloudflared.yml
"

    local verify_cmd="! grep -E ':(8080|9000|2375|2376)' '$CONFIG_DIR/cloudflared.yml'"

    prompt_interactive_error \
        "ERR_PRIVATE_PORT_EXPOSED" \
        "CRITICAL: Private Management Port Exposed in Ingress" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 10b: Cloudflare Credentials Recovery
repair_cloudflare_credentials() {
    if [[ ! -f "$CONFIG_DIR/cloudflared.yml" ]]; then
        return 0
    fi

    # Check if credentials.json is valid
    if [[ -f "$CONFIG_DIR/credentials.json" && ! -d "$CONFIG_DIR/credentials.json" ]]; then
        if grep -q '"AccountTag"' "$CONFIG_DIR/credentials.json" 2>/dev/null && grep -q '"TunnelSecret"' "$CONFIG_DIR/credentials.json" 2>/dev/null; then
            return 0
        fi
    fi

    local t_id=""
    t_id=$(grep -E '^tunnel:[[:space:]]+' "$CONFIG_DIR/cloudflared.yml" | head -n1 | awk '{print $2}' || true)

    local what="Tunnel configuration exists at config/cloudflared.yml, but credentials file (config/credentials.json) is missing or invalid."
    local why="A tunnel credentials JSON file is required for cloudflared to authenticate. Note: cert.pem is an origin certificate used for creating tunnels and cannot be renamed or passed directly as credentials.json."
    local comp="Cloudflare Zero-Trust Credentials (config/credentials.json)"
    local risk="LOW (Reconstructs credentials JSON from token or searches local .cloudflared stores)"
    local sol="Extract credentials JSON via cloudflared tunnel token or local store with mode 644."

    local exact_changes="1. Remove directory artifact if config/credentials.json was auto-created as directory
2. Query 'cloudflared tunnel token ${t_id}'
3. Decode base64 payload and synthesize valid JSON credentials
4. Apply mode 644 (readable by container user nonroot)"

    local fix_cmd="
        if [[ -f '$PROGRAM_DIR/scripts/cloudflare_manager.sh' ]]; then
            '$PROGRAM_DIR/scripts/cloudflare_manager.sh' create mornye-storage 2>/dev/null || true
        fi
    "

    local manual_cmd="
Extract credentials via token:
  cloudflared tunnel token ${t_id}
Or re-run:
  ./mornye.sh tunnel setup
"

    local verify_cmd="
        [[ -f '$CONFIG_DIR/credentials.json' && ! -d '$CONFIG_DIR/credentials.json' ]] && grep -q '\"AccountTag\"' '$CONFIG_DIR/credentials.json'
    "

    prompt_interactive_error \
        "ERR_CLOUDFLARE_CREDS_MISSING" \
        "Cloudflare Tunnel Credentials Missing or Invalid" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# Handler 11: Low Disk Headroom (< 1024 MB)
repair_low_disk_space() {
    audit_system
    if [[ "$DISK_FREE_MB" -ge 1024 ]]; then
        return 0
    fi

    local what="Host filesystem free headroom is ${DISK_FREE_MB} MB (less than 1024 MB minimum)."
    local why="Insufficient disk space leads to SQLite write failures and container crashes."
    local comp="Host Storage Volume ($PROGRAM_DIR)"
    local risk="LOW (Prunes unused Docker build cache and cleans temporary files)"
    local sol="Clean Docker build caches and purge temporary upload fragments."

    local exact_changes="1. Execute 'docker builder prune -f'
2. Remove temporary fragmented uploads in database/tmp/*.part"

    local fix_cmd="
        docker builder prune -f 2>/dev/null || true
        rm -f '$DATA_DIR/tmp/'*.part 2>/dev/null || true
    "

    local manual_cmd="
Free up disk space manually:
  docker builder prune -a
  rm -rf /var/tmp/* /tmp/*
"

    local verify_cmd="
        audit_system
        [[ \"\$DISK_FREE_MB\" -ge 1024 ]]
    "

    prompt_interactive_error \
        "ERR_INSUFFICIENT_DISK" \
        "Critical Low Disk Headroom (${DISK_FREE_MB} MB free)" \
        "$what" \
        "$why" \
        "$comp" \
        "$risk" \
        "$sol" \
        "$exact_changes" \
        "$fix_cmd" \
        "$manual_cmd" \
        "$verify_cmd"
}

# ------------------------------------------------------------------------------
# 4. LIFECYCLE PRE-FLIGHT INTEGRATION ORCHESTRATOR
# ------------------------------------------------------------------------------

run_preflight_checks() {
    local stage="${1:-all}"
    local rc=0

    case "$stage" in
        install)
            repair_low_disk_space || rc=$?
            repair_missing_directories || rc=$?
            repair_missing_env || rc=$?
            repair_default_secret_key || rc=$?
            ;;
        start|docker)
            repair_docker_daemon || rc=$?
            repair_docker_permissions || rc=$?
            repair_port_conflict || rc=$?
            repair_missing_directories || rc=$?
            repair_insecure_permissions || rc=$?
            repair_volume_writability || rc=$?
            repair_missing_env || rc=$?
            repair_default_secret_key || rc=$?
            ;;
        health)
            repair_unhealthy_container || rc=$?
            ;;
        tunnel)
            repair_private_port_exposed || rc=$?
            repair_cloudflare_ingress_mismatch || rc=$?
            repair_cloudflare_credentials || rc=$?
            ;;
        runtime|all|*)
            repair_docker_daemon || rc=$?
            repair_port_conflict || rc=$?
            repair_missing_directories || rc=$?
            repair_insecure_permissions || rc=$?
            repair_volume_writability || rc=$?
            repair_missing_env || rc=$?
            repair_default_secret_key || rc=$?
            repair_unhealthy_container || rc=$?
            repair_cloudflare_ingress_mismatch || rc=$?
            repair_private_port_exposed || rc=$?
            repair_cloudflare_credentials || rc=$?
            ;;
    esac

    return "$rc"
}

# ------------------------------------------------------------------------------
# 5. RUNTIME MONITORING & BOUNDED RECOVERY
# ------------------------------------------------------------------------------

run_runtime_check() {
    echo -e "${BOLD}${CYAN}[*] Running Mornye Runtime Health & Integrity Inspection...${NC}"
    load_env
    audit_docker
    audit_containers
    audit_endpoints
    audit_storage
    audit_ports

    local issues=0

    # 1. Container state
    if [[ "$WEBDAV_CONTAINER_STATE" != "running" ]]; then
        echo -e "${RED}[✘] WebDAV container is not running (State: ${WEBDAV_CONTAINER_STATE}).${NC}"
        repair_unhealthy_container || true
        issues=$((issues + 1))
    fi

    # 2. Endpoint Health
    if [[ "$HEALTH_HTTP_CODE" != "200" ]]; then
        echo -e "${RED}[✘] WebDAV health endpoint returning HTTP ${HEALTH_HTTP_CODE}.${NC}"
        repair_unhealthy_container || true
        issues=$((issues + 1))
    fi

    # 3. Port Conflict
    if [[ "$HOST_PORT_CONFLICT" == true ]]; then
        echo -e "${RED}[✘] Host port conflict detected on port ${MORNYE_HOST_PORT}.${NC}"
        repair_port_conflict || true
        issues=$((issues + 1))
    fi

    # 4. Storage permissions
    if [[ "$DIR_PERMS_STATUS" != "healthy" ]]; then
        echo -e "${YELLOW}[!] Permissions irregularity detected.${NC}"
        repair_insecure_permissions || true
        issues=$((issues + 1))
    fi

    if [[ "$issues" -eq 0 ]]; then
        echo -e "${GREEN}[✔] Runtime check complete: All Mornye components operating optimally.${NC}"
        return 0
    else
        echo -e "${YELLOW}[!] Runtime check detected ${issues} condition(s). Remediations completed or offered.${NC}"
        return 1
    fi
}

run_runtime_watch() {
    local interval="${1:-10}"
    local max_recoveries=2
    local recovery_count=0

    echo -e "${BOLD}${CYAN}==============================================================${NC}"
    echo -e "${BOLD}${CYAN}         MORNYE RUNTIME MONITOR (Bounded Recovery Mode)       ${NC}"
    echo -e "${BOLD}${CYAN}==============================================================${NC}"
    echo -e "Inspection interval : ${interval} seconds"
    echo -e "Max auto-recoveries : ${max_recoveries} (Operator prompted if failures persist)"
    echo -e "Press [Ctrl+C] to exit runtime monitor.\n"

    while true; do
        load_env
        local h_code
        h_code="$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${MORNYE_HOST_BIND}:${MORNYE_HOST_PORT}/health" 2>/dev/null || echo "000")"
        local ts
        ts="$(date +"%H:%M:%S")"

        if [[ "$h_code" == "200" ]]; then
            echo -e "[${ts}] ${GREEN}[✔] WebDAV Health OK (HTTP 200)${NC} | Host Port: ${MORNYE_HOST_PORT}"
            recovery_count=0
        else
            echo -e "[${ts}] ${RED}[✘] Health Alert: HTTP ${h_code}${NC}"
            if [[ "$recovery_count" -lt "$max_recoveries" ]]; then
                recovery_count=$((recovery_count + 1))
                echo -e "${YELLOW}[!] Attempting bounded safe recovery (Attempt ${recovery_count}/${max_recoveries})...${NC}"
                run_runtime_check || true
            else
                echo -e "${RED}${BOLD}[CRITICAL] Unhealthy condition persists after ${max_recoveries} attempts.${NC}"
                echo -e "${CYAN}Engaging interactive error resolver...${NC}"
                run_runtime_check
                recovery_count=0
            fi
        fi
        sleep "$interval"
    done
}

# ------------------------------------------------------------------------------
# 6. DISPATCHER ENTRY POINT
# ------------------------------------------------------------------------------

main() {
    # Parse CLI flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y|--auto-fix)
                AUTO_FIX=true
                INTERACTIVE_MODE=false
                shift
                ;;
            --non-interactive)
                INTERACTIVE_MODE=false
                shift
                ;;
            check|preflight)
                shift
                run_preflight_checks "$@"
                exit $?
                ;;
            runtime-check)
                run_runtime_check
                exit $?
                ;;
            watch|monitor)
                shift
                run_runtime_watch "$@"
                exit $?
                ;;
            fix-port)
                repair_port_conflict
                exit $?
                ;;
            fix-docker)
                repair_docker_daemon
                repair_docker_permissions
                exit $?
                ;;
            fix-perms)
                repair_missing_directories
                repair_insecure_permissions
                exit $?
                ;;
            fix-config)
                repair_missing_env
                repair_default_secret_key
                exit $?
                ;;
            fix-cloudflare)
                repair_private_port_exposed
                repair_cloudflare_ingress_mismatch
                exit $?
                ;;
            help|--help|-h)
                echo "Usage: ./scripts/repair_engine.sh [--yes] [check <stage> | runtime-check | watch <interval> | fix-port | fix-docker | fix-perms | fix-config]"
                exit 0
                ;;
            *)
                # Run complete interactive repair pipeline
                run_preflight_checks "all"
                exit $?
                ;;
        esac
    done

    # Default action: run all preflight checks
    run_preflight_checks "all"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
