"""
app/backend/system_service.py

Native, isolated system management service for Mornye Admin Panel.
Provides direct, in-process implementations of:
- Hardware resource telemetry & sensors (CPU, RAM, Disk I/O, Network, Sensors, Uptime).
- 5-Service Supervisor & process diagnostics (PIDs, RSS memory, systemctl health).
- Strictly allowlisted service action execution (mornye-storage, mornye-tunnel).
- High-speed journalctl operational log retrieval.
- Database & configuration backup creation, archive verification, and safety-guarded restore.
- Central audit and security event logging.

Security Guarantees:
1. Zero arbitrary shell invocation (executes fixed arg lists with shell=False).
2. Strict allowlists for services and actions.
3. Path traversal defense on all archive and log operations.
4. Clean client error reporting (never exposes tracebacks or returns 500 for client faults).
"""

import os
import re
import sys
import time
import json
import psutil
import socket
import subprocess
from pathlib import Path
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional

from backend.core.config import settings

# Strict allowlist of managed systemd units
ALLOWED_SERVICES = {
    "storage": "mornye-storage.service",
    "webdav": "mornye-storage.service",
    "tunnel": "mornye-tunnel.service"
}

ALLOWED_ACTIONS = {"start", "stop", "restart", "status"}

SAFE_FILENAME_REGEX = re.compile(r"^[a-zA-Z0-9_\-\.]+\.tar\.gz$")
AUDIT_LOG_FILE = settings.LOG_PATH / "audit.log"


# ==============================================================================
# 1. HARDWARE & HOST TELEMETRY
# ==============================================================================

def format_uptime(seconds: int) -> str:
    """Format uptime in human-readable notation."""
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, secs = divmod(remainder, 60)
    if days > 0:
        return f"{days}d {hours}h {minutes}m"
    if hours > 0:
        return f"{hours}h {minutes}m"
    return f"{minutes}m {secs}s"


def format_rate_human(bps: float) -> str:
    """Format network transfer speed in human-readable notation."""
    if bps < 1024:
        return f"{int(bps)} B/s"
    elif bps < 1024 * 1024:
        return f"{bps / 1024:.1f} KB/s"
    else:
        return f"{bps / (1024 * 1024):.2f} MB/s"


# Module-level network transfer rate tracking state
_last_net_sample: Dict[str, Any] = {
    "time": 0.0,
    "bytes_sent": 0,
    "bytes_recv": 0,
    "rate_sent_kbps": 0.0,
    "rate_recv_kbps": 0.0,
    "rate_sent_human": "0.0 KB/s",
    "rate_recv_human": "0.0 KB/s"
}


def get_system_overview() -> Dict[str, Any]:
    """Retrieve verified hardware telemetry via psutil with high-accuracy rates."""
    global _last_net_sample

    # CPU metrics: overall, per-core, logical and physical count
    cpu_pct = round(psutil.cpu_percent(interval=0.05), 1)
    logical_cores = psutil.cpu_count(logical=True) or 1
    physical_cores = psutil.cpu_count(logical=False) or logical_cores
    per_core_pct = [round(p, 1) for p in psutil.cpu_percent(interval=None, percpu=True)]
    load_avg = os.getloadavg() if hasattr(os, "getloadavg") else (0.0, 0.0, 0.0)

    # CPU Status threshold
    if cpu_pct >= 85.0:
        cpu_status = "CRITICAL"
    elif cpu_pct >= 60.0:
        cpu_status = "ELEVATED"
    else:
        cpu_status = "NORMAL"

    # Memory
    mem = psutil.virtual_memory()
    mem_used_mb = round(mem.used / (1024**2), 1)
    mem_avail_mb = round(mem.available / (1024**2), 1)
    mem_total_mb = round(mem.total / (1024**2), 1)
    mem_pct = round(mem.percent, 1)

    if mem_pct >= 85.0:
        mem_status = "CRITICAL"
    elif mem_pct >= 70.0:
        mem_status = "ELEVATED"
    else:
        mem_status = "NORMAL"

    # Disk & Mountpoint detection
    storage_path = str(settings.STORAGE_PATH)
    mount_point = "/"
    device = "unknown"
    fstype = "unknown"
    try:
        parts = psutil.disk_partitions(all=False)
        matching = [p for p in parts if storage_path.startswith(p.mountpoint)]
        if matching:
            best = max(matching, key=lambda p: len(p.mountpoint))
            mount_point = best.mountpoint
            device = best.device
            fstype = best.fstype
        else:
            mount_point = "/"
            device = parts[0].device if parts else "/dev/sda1"
            fstype = parts[0].fstype if parts else "ext4"
    except Exception:
        pass

    try:
        disk = psutil.disk_usage(storage_path)
    except Exception:
        disk = psutil.disk_usage("/")

    disk_pct = round(disk.percent, 1)
    if disk_pct >= 90.0:
        disk_status = "CRITICAL"
    elif disk_pct >= 75.0:
        disk_status = "WARNING"
    else:
        disk_status = "NORMAL"

    # Disk I/O
    disk_io = {"read_bytes": 0, "write_bytes": 0, "read_mb": 0.0, "write_mb": 0.0}
    try:
        dio = psutil.disk_io_counters()
        if dio:
            disk_io = {
                "read_bytes": dio.read_bytes,
                "write_bytes": dio.write_bytes,
                "read_mb": round(dio.read_bytes / (1024**2), 2),
                "write_mb": round(dio.write_bytes / (1024**2), 2)
            }
    except Exception:
        pass

    # Thermal Sensors
    temps = []
    try:
        if hasattr(psutil, "sensors_temperatures"):
            st = psutil.sensors_temperatures()
            for name, entries in (st or {}).items():
                for entry in entries:
                    temps.append({
                        "sensor": name,
                        "label": entry.label or name,
                        "current_c": entry.current,
                        "high_c": entry.high,
                        "critical_c": entry.critical
                    })
    except Exception:
        pass

    # Boot time & Uptime
    boot_time = psutil.boot_time()
    uptime_sec = int(time.time() - boot_time)

    # Network I/O with Real-time Rate Tracking
    net = psutil.net_io_counters()
    now = time.time()
    if _last_net_sample["time"] > 0 and now > _last_net_sample["time"]:
        dt = max(0.1, now - _last_net_sample["time"])
        rate_sent_bps = max(0.0, (net.bytes_sent - _last_net_sample["bytes_sent"]) / dt)
        rate_recv_bps = max(0.0, (net.bytes_recv - _last_net_sample["bytes_recv"]) / dt)
        _last_net_sample["rate_sent_kbps"] = round(rate_sent_bps / 1024, 1)
        _last_net_sample["rate_recv_kbps"] = round(rate_recv_bps / 1024, 1)
        _last_net_sample["rate_sent_human"] = format_rate_human(rate_sent_bps)
        _last_net_sample["rate_recv_human"] = format_rate_human(rate_recv_bps)
    _last_net_sample["time"] = now
    _last_net_sample["bytes_sent"] = net.bytes_sent
    _last_net_sample["bytes_recv"] = net.bytes_recv

    return {
        "cpu": {
            "percent": cpu_pct,
            "cores": logical_cores,
            "logical_cores": logical_cores,
            "physical_cores": physical_cores,
            "per_core": per_core_pct,
            "status": cpu_status,
            "load_1m": round(load_avg[0], 2),
            "load_5m": round(load_avg[1], 2),
            "load_15m": round(load_avg[2], 2)
        },
        "memory": {
            "total_bytes": mem.total,
            "used_bytes": mem.used,
            "available_bytes": mem.available,
            "percent": mem_pct,
            "status": mem_status,
            "total_mb": mem_total_mb,
            "used_mb": mem_used_mb,
            "free_mb": mem_avail_mb,
            "total_gb": round(mem.total / (1024**3), 2),
            "used_gb": round(mem.used / (1024**3), 2),
            "free_gb": round(mem.available / (1024**3), 2)
        },
        "disk": {
            "mount_point": mount_point,
            "device": device,
            "fstype": fstype,
            "total_bytes": disk.total,
            "used_bytes": disk.used,
            "free_bytes": disk.free,
            "percent": disk_pct,
            "status": disk_status,
            "total_gb": round(disk.total / (1024**3), 2),
            "used_gb": round(disk.used / (1024**3), 2),
            "free_gb": round(disk.free / (1024**3), 2)
        },
        "uptime": {
            "seconds": uptime_sec,
            "formatted": format_uptime(uptime_sec)
        },
        "network": {
            "bytes_sent": net.bytes_sent,
            "bytes_recv": net.bytes_recv,
            "sent_mb": round(net.bytes_sent / (1024**2), 2),
            "recv_mb": round(net.bytes_recv / (1024**2), 2),
            "rate_recv_kbps": _last_net_sample["rate_recv_kbps"],
            "rate_sent_kbps": _last_net_sample["rate_sent_kbps"],
            "rate_recv_human": _last_net_sample["rate_recv_human"],
            "rate_sent_human": _last_net_sample["rate_sent_human"]
        },
        "cpu_percent": cpu_pct,
        "memory_percent": mem_pct,
        "memory_used_mb": int(mem.used / (1024**2)),
        "memory_total_mb": int(mem.total / (1024**2)),
        "uptime_seconds": uptime_sec,
        "storage_mount": mount_point,
        "disk_io": disk_io,
        "sensors": {
            "temperatures": temps,
            "has_sensors": bool(temps),
            "status": ("Optimal" if all(t.get("current_c", 0) < 80 for t in temps) else "Elevated") if temps else "Not available on this hardware"
        }
    }


# ==============================================================================
# 2. SERVICE SUPERVISOR & PROCESS MANAGEMENT
# ==============================================================================

def get_service_status(service_key: str) -> Dict[str, Any]:
    """Retrieve verified status of an allowlisted systemd service."""
    if service_key not in ALLOWED_SERVICES:
        raise ValueError(f"Service '{service_key}' is not in allowlist")

    unit_name = ALLOWED_SERVICES[service_key]
    
    # Check is-active (try unprivileged first, then sudo)
    res_active = subprocess.run(
        ["/usr/bin/systemctl", "is-active", unit_name],
        capture_output=True,
        text=True,
        timeout=5
    )
    if res_active.returncode != 0 and "inactive" not in res_active.stdout:
        res_active = subprocess.run(
            ["sudo", "-n", "/usr/bin/systemctl", "is-active", unit_name],
            capture_output=True,
            text=True,
            timeout=5
        )
    state = res_active.stdout.strip() or "inactive"
    is_active = (state == "active")

    # Get status details
    res_status = subprocess.run(
        ["/usr/bin/systemctl", "status", unit_name, "--no-pager", "-n", "10"],
        capture_output=True,
        text=True,
        timeout=5
    )
    if res_status.returncode != 0 and not res_status.stdout.strip():
        res_status = subprocess.run(
            ["sudo", "-n", "/usr/bin/systemctl", "status", unit_name, "--no-pager", "-n", "10"],
            capture_output=True,
            text=True,
            timeout=5
        )

    return {
        "service": service_key,
        "unit": unit_name,
        "active": is_active,
        "state": state,
        "output": res_status.stdout.strip() or res_status.stderr.strip()
    }


def execute_service_action(service_key: str, action: str, admin_user: Optional[Any] = None) -> Dict[str, Any]:
    """
    Execute a strictly allowlisted action on an allowlisted service.
    Zero arbitrary shell execution.
    """
    if service_key not in ALLOWED_SERVICES:
        raise ValueError(f"Service '{service_key}' is not in allowlist")
    
    if action not in ALLOWED_ACTIONS:
        raise ValueError(f"Action '{action}' is not permitted")

    unit_name = ALLOWED_SERVICES[service_key]

    if action == "status":
        return get_service_status(service_key)

    # First attempt native systemctl execution
    cmd = ["sudo", "-n", "/usr/bin/systemctl", action, unit_name]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=15)

    if res.returncode != 0:
        err = res.stderr.strip() or f"systemctl {action} exited with code {res.returncode}"
        # If blocked by systemd NoNewPrivileges sandbox, check if control center daemon is available
        if "no new privileges" in err.lower() and admin_user is not None:
            try:
                import httpx
                from backend.auth.security import create_access_token
                token = create_access_token({"sub": admin_user.username, "role": admin_user.role, "scope": "control_center"})
                with httpx.Client(base_url="http://127.0.0.1:9000", timeout=10.0) as cc_client:
                    resp = cc_client.post(
                        f"/api/services/{service_key}/{action}",
                        headers={"Authorization": f"Bearer {token}"},
                        json={"confirmed": True}
                    )
                    if resp.status_code == 200:
                        return get_service_status(service_key)
            except Exception:
                pass
        raise RuntimeError(err)

    time.sleep(1) # Allow systemd to settle
    return get_service_status(service_key)


def get_all_services_status() -> Dict[str, Any]:
    """Comprehensive status for all 5 Mornye infrastructure services."""
    current_pid = os.getpid()
    admin_mem_mb = 0.0
    try:
        proc = psutil.Process(current_pid)
        admin_mem_mb = round(proc.memory_info().rss / (1024**2), 1)
    except Exception:
        pass

    # Check Control Center status (pid file and loopback socket)
    cc_active = False
    cc_pid = None
    cc_mem_mb = 0.0
    try:
        pid_file = settings.BASE_DIR / "control_center.pid"
        if pid_file.exists():
            candidate_pid = int(pid_file.read_text().strip())
            if psutil.pid_exists(candidate_pid):
                cproc = psutil.Process(candidate_pid)
                if "python" in cproc.name().lower() or "uvicorn" in cproc.name().lower():
                    cc_active = True
                    cc_pid = candidate_pid
                    cc_mem_mb = round(cproc.memory_info().rss / (1024**2), 1)
    except Exception:
        pass

    # Check WebDAV port
    webdav_listening = False
    try:
        with socket.create_connection(("127.0.0.1", settings.WEBDAV_PORT), timeout=0.3):
            webdav_listening = True
    except Exception:
        pass

    # Check storage and tunnel systemd units
    storage_info = get_service_status("storage")
    tunnel_info = get_service_status("tunnel")

    services_list = [
        {
            "key": "storage",
            "name": "Mornye Core Storage Engine & API",
            "unit": "mornye-storage.service",
            "active": storage_info.get("active", True),
            "state": storage_info.get("state", "active"),
            "port": settings.ADMIN_PORT,
            "managed": True,
            "can_restart": True,
            "can_start": True,
            "can_stop": True,
            "description": "Storage daemon, REST API on port 8080, and WebDAV engine."
        },
        {
            "key": "tunnel",
            "name": "Cloudflare Zero-Trust Tunnel",
            "unit": "mornye-tunnel.service",
            "active": tunnel_info.get("active", True),
            "state": tunnel_info.get("state", "active"),
            "port": None,
            "managed": True,
            "can_restart": True,
            "can_start": True,
            "can_stop": True,
            "description": "Encrypted ingress routing WAN WebDAV traffic to 127.0.0.1:8000."
        },
        {
            "key": "webdav",
            "name": "WebDAV Distributed Sync Engine",
            "unit": "mornye-storage.service",
            "active": webdav_listening or storage_info.get("active", True),
            "state": "active" if (webdav_listening or storage_info.get("active")) else "inactive",
            "port": settings.WEBDAV_PORT,
            "managed": False,
            "can_restart": False,
            "can_start": False,
            "can_stop": False,
            "description": f"RFC 4918 WebDAV engine listening on 127.0.0.1:{settings.WEBDAV_PORT}."
        },
        {
            "key": "admin",
            "name": "Mornye Luxury Admin Panel Console",
            "unit": "mornye-storage.service",
            "active": True,
            "state": "active",
            "port": settings.ADMIN_PORT,
            "pid": current_pid,
            "memory_mb": admin_mem_mb,
            "managed": False,
            "can_restart": False,
            "can_start": False,
            "can_stop": False,
            "description": f"React Single Page Application and Admin API on 127.0.0.1:{settings.ADMIN_PORT}."
        },
        {
            "key": "control_center",
            "name": "Control Center Daemon (Migration Supervisor)",
            "unit": "control-center.sh",
            "active": cc_active,
            "state": "active" if cc_active else "stopped",
            "port": 9000,
            "pid": cc_pid,
            "memory_mb": cc_mem_mb,
            "managed": False,
            "can_restart": False,
            "can_start": False,
            "can_stop": False,
            "description": "Local privileged supervisor on port 9000 (pre-retirement state)."
        }
    ]

    return {
        "services": services_list,
        "storage": storage_info,
        "tunnel": tunnel_info,
        "webdav": {
            "name": "Mornye WebDAV Server",
            "port": settings.WEBDAV_PORT,
            "active": webdav_listening,
            "state": "active" if webdav_listening else "inactive",
            "public_url": f"https://{settings.STORAGE_HOSTNAME}/dav/",
            "unit": "mornye-storage.service"
        },
        "admin": {
            "name": "Mornye Admin Panel",
            "port": settings.ADMIN_PORT,
            "active": True,
            "pid": current_pid,
            "memory_mb": admin_mem_mb
        },
        "control_center": {
            "name": "Control Center Supervisor",
            "port": 9000,
            "active": cc_active,
            "pid": cc_pid,
            "memory_mb": cc_mem_mb
        }
    }


# ==============================================================================
# 3. OPERATIONAL JOURNALCTL LOG READER
# ==============================================================================

def read_service_logs(
    service_key: str,
    lines: int = 100,
    level_filter: Optional[str] = None,
    search: Optional[str] = None
) -> List[Dict[str, Any]]:
    """Retrieve recent journalctl logs for an allowlisted service."""
    if service_key not in ALLOWED_SERVICES:
        raise ValueError(f"Invalid service for logs: '{service_key}'")

    unit_name = ALLOWED_SERVICES[service_key]
    num_lines = min(max(10, lines), 1000)

    # First attempt direct unprivileged journalctl
    cmd = ["/usr/bin/journalctl", "-u", unit_name, "-n", str(num_lines), "--no-pager"]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    
    if res.returncode != 0 or not res.stdout.strip():
        # Fallback to sudo -n
        cmd_sudo = ["sudo", "-n", "/usr/bin/journalctl", "-u", unit_name, "-n", str(num_lines), "--no-pager"]
        res = subprocess.run(cmd_sudo, capture_output=True, text=True, timeout=10)

    raw_lines = res.stdout.strip().splitlines()
    parsed_logs = []

    for raw in raw_lines:
        raw_clean = raw.strip()
        if not raw_clean:
            continue

        # Classify level
        lvl = "INFO"
        lower = raw_clean.lower()
        if "error" in lower or "failed" in lower or "fatal" in lower:
            lvl = "ERROR"
        elif "warn" in lower:
            lvl = "WARN"

        if level_filter and level_filter.upper() != "ALL" and lvl != level_filter.upper():
            continue

        if search and search.lower() not in raw_clean.lower():
            continue

        parsed_logs.append({
            "raw": raw_clean,
            "level": lvl
        })

    return parsed_logs


# ==============================================================================
# 4. BACKUPS & DISASTER RECOVERY LIFECYCLE
# ==============================================================================

def sanitize_archive_filename(filename: str) -> str:
    """Validate archive filename to prevent directory traversal and arbitrary paths."""
    raw = filename.strip()
    if "/" in raw or "\\" in raw or ".." in raw:
        raise ValueError(f"Security hazard: path traversal characters detected in filename: '{filename}'")
    safe_name = os.path.basename(raw).strip()
    if not safe_name or not SAFE_FILENAME_REGEX.match(safe_name):
        raise ValueError(f"Invalid backup archive filename: '{filename}'. Must match name.tar.gz")
    return safe_name


def list_backups() -> List[Dict[str, Any]]:
    """List all available backup archives in backups/."""
    backup_dir = settings.BACKUP_PATH
    backup_dir.mkdir(parents=True, exist_ok=True)
    backups = []
    
    for f in backup_dir.glob("*.tar.gz"):
        stat = f.stat()
        backups.append({
            "filename": f.name,
            "size_bytes": stat.st_size,
            "size_mb": round(stat.st_size / (1024**2), 2),
            "created_at": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(stat.st_mtime)),
            "mtime": stat.st_mtime
        })

    return sorted(backups, key=lambda x: x["mtime"], reverse=True)


def create_backup_archive() -> Dict[str, Any]:
    """Create timestamped application configuration and database backup."""
    backup_dir = settings.BACKUP_PATH
    backup_dir.mkdir(parents=True, exist_ok=True)
    
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    archive_name = f"mornye_backup_{timestamp}.tar.gz"
    archive_path = backup_dir / archive_name

    program_dir = settings.BASE_DIR
    cmd = [
        "tar", "-czf", str(archive_path),
        "-C", str(program_dir),
        "database/mornye.db",
        ".env",
        "config",
        "cloudflare/tunnel/config.yml"
    ]
    subprocess.run(cmd, check=True)
    stat = archive_path.stat()

    archive_info = {
        "filename": archive_name,
        "size_bytes": stat.st_size,
        "size_mb": round(stat.st_size / (1024**2), 2),
        "created_at": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(stat.st_mtime))
    }
    return archive_info


def verify_backup_archive(filename: str) -> Dict[str, Any]:
    """Verify tar.gz archive integrity using tar -tzf."""
    safe_name = sanitize_archive_filename(filename)
    archive_path = settings.BACKUP_PATH / safe_name
    
    if not archive_path.exists() or not archive_path.is_file():
        raise FileNotFoundError(f"Backup file '{safe_name}' does not exist")

    # Verify with tar -tzf
    cmd = ["tar", "-tzf", str(archive_path)]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    
    if res.returncode != 0:
        err_msg = res.stderr.strip() or "Corrupted tar.gz archive"
        raise ValueError(f"Archive verification failed: {err_msg}")

    contents = [x.strip() for x in res.stdout.strip().splitlines() if x.strip()]
    
    # Path traversal validation on archive contents
    for item in contents:
        if ".." in item or item.startswith("/"):
            raise ValueError(f"Security hazard: archive contains insecure path '{item}'")

    return {
        "valid": True,
        "filename": safe_name,
        "files_contained": contents
    }


def restore_backup_archive(filename: str, target_dir: Optional[Path] = None) -> Dict[str, Any]:
    """
    Restore database and configurations from an archive.
    Validates archive contents before extracting.
    """
    verification = verify_backup_archive(filename)
    safe_name = verification["filename"]
    archive_path = settings.BACKUP_PATH / safe_name

    dest_dir = target_dir or settings.BASE_DIR

    cmd = ["tar", "-xzf", str(archive_path), "-C", str(dest_dir)]
    subprocess.run(cmd, check=True)

    return {"status": "success", "restored_file": safe_name}


def delete_backup_archive(filename: str) -> Dict[str, Any]:
    """Delete a backup archive."""
    safe_name = sanitize_archive_filename(filename)
    path = settings.BACKUP_PATH / safe_name
    if not path.exists():
        raise FileNotFoundError(f"Backup file '{safe_name}' does not exist")

    path.unlink()
    return {"status": "success", "deleted": safe_name}


# ==============================================================================
# 5. SECURITY & AUDIT EVENT RECORDER
# ==============================================================================

def ensure_audit_log():
    """Ensure audit log file exists with restricted permissions."""
    settings.LOG_PATH.mkdir(parents=True, exist_ok=True)
    if not AUDIT_LOG_FILE.exists():
        AUDIT_LOG_FILE.touch(mode=0o600, exist_ok=True)


def log_audit_event(
    action: str,
    user: str,
    ip: str,
    details: str = "",
    status: str = "SUCCESS"
) -> Dict[str, Any]:
    """Record an administrative or security action in audit.log."""
    ensure_audit_log()
    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "action": action,
        "user": user,
        "ip": ip,
        "status": status,
        "details": details
    }
    
    try:
        with open(AUDIT_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception as e:
        print(f"Failed to write audit log: {e}", file=sys.stderr)

    return entry


def get_audit_events(limit: int = 100, search: Optional[str] = None) -> List[Dict[str, Any]]:
    """Retrieve recent audit events in reverse chronological order."""
    ensure_audit_log()
    events = []
    
    if not AUDIT_LOG_FILE.exists():
        return []

    try:
        with open(AUDIT_LOG_FILE, "r", encoding="utf-8") as f:
            lines = f.readlines()
        
        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
                if search:
                    term = search.lower()
                    if not (term in data.get("action", "").lower() or
                            term in data.get("user", "").lower() or
                            term in data.get("details", "").lower() or
                            term in data.get("ip", "").lower()):
                        continue
                events.append(data)
                if len(events) >= limit:
                    break
            except json.JSONDecodeError:
                continue
    except Exception:
        pass

    return events
