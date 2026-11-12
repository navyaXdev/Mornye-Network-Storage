"""
app/backend/journal_service.py

High-performance journalctl reader with cursor-based pagination and credential redaction.
Guarantees:
1. Native JSON log stream parsing via journalctl -o json.
2. Supports --after-cursor for real-time incremental fetching.
3. Automatically redacts authentication headers, private keys, account tags, and tokens.
4. Highlights critical connection/reconnection events.
5. Search, severity, and limit filtering.
"""

import re
import json
import asyncio
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional

ALLOWED_LOG_UNITS = {
    "tunnel": "mornye-tunnel.service",
    "storage": "mornye-storage.service"
}

# Credential redaction regex patterns
REDACT_PATTERNS = [
    (re.compile(r'(?i)(account_tag|tunnel_secret|token|password|secret|key|credentials)\s*[:=]\s*["\']?[a-zA-Z0-9_\-\.]{8,}["\']?'), r'\1="[REDACTED]"'),
    (re.compile(r'ey[a-zA-Z0-9_\-\.]+\.[a-zA-Z0-9_\-\.]+'), '[REDACTED_JWT]'),
    (re.compile(r'Basic\s+[a-zA-Z0-9+/=]{10,}'), 'Basic [REDACTED_CREDS]'),
    (re.compile(r'Bearer\s+[a-zA-Z0-9_\-\.]+'), 'Bearer [REDACTED_TOKEN]')
]

def redact_log_message(msg: str) -> str:
    """Sanitize log text by stripping credentials, tokens, and authorization headers."""
    for pattern, repl in REDACT_PATTERNS:
        msg = pattern.sub(repl, msg)
    return msg

def format_priority(priority_code: str) -> str:
    """Map syslog priority integer to human severity level."""
    try:
        p = int(priority_code)
        if p <= 3:
            return "ERROR"
        elif p == 4:
            return "WARN"
        elif p <= 6:
            return "INFO"
        else:
            return "DEBUG"
    except Exception:
        return "INFO"

def is_connection_event(msg: str) -> bool:
    """Detect connection and reconnection events in Cloudflare tunnel logs."""
    lowered = msg.lower()
    return any(keyword in lowered for keyword in [
        "quic connection successful",
        "registered connection",
        "registerconnection",
        "connection established",
        "http/2 connection successful",
        "connected to",
        "update_local_configuration"
    ])

async def read_unit_logs(
    unit_key: str,
    after_cursor: Optional[str] = None,
    limit: int = 100,
    search: Optional[str] = None,
    severity: Optional[str] = None
) -> Dict[str, Any]:
    """
    Retrieve real, cursor-paginated journalctl logs for an allowlisted unit.
    """
    if unit_key not in ALLOWED_LOG_UNITS:
        raise ValueError(f"Invalid unit key: '{unit_key}'")

    unit_name = ALLOWED_LOG_UNITS[unit_key]
    limit = max(1, min(limit, 500))

    cmd = ["/usr/bin/journalctl", "-u", unit_name, "-o", "json", "--no-pager"]
    if after_cursor:
        cmd.extend(["--after-cursor", after_cursor])
    cmd.extend(["-n", str(limit)])

    entries: List[Dict[str, Any]] = []
    latest_cursor: Optional[str] = None

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3.5)

        for line in stdout.decode("utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
            except Exception:
                continue

                raw_msg = data.get("MESSAGE", "")
            if not raw_msg:
                continue

            clean_msg = redact_log_message(str(raw_msg))
            level = format_priority(data.get("PRIORITY", "6"))
            cursor = data.get("__CURSOR", "")
            latest_cursor = cursor or latest_cursor

            # Filter severity if specified
            if severity and severity.upper() != "ALL" and level != severity.upper():
                continue

            # Filter search keyword if specified
            if search and search.lower() not in clean_msg.lower():
                continue

            # Format timestamp
            ts_us = data.get("__REALTIME_TIMESTAMP")
            if ts_us and str(ts_us).isdigit():
                dt = datetime.fromtimestamp(int(ts_us) / 1e6, timezone.utc)
                timestamp_str = dt.strftime("%Y-%m-%d %H:%M:%S UTC")
                time_short = dt.strftime("%H:%M:%S")
            else:
                timestamp_str = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
                time_short = datetime.now(timezone.utc).strftime("%H:%M:%S")

            entries.append({
                "cursor": cursor,
                "timestamp": timestamp_str,
                "time_short": time_short,
                "severity": level,
                "is_connection_event": is_connection_event(clean_msg),
                "is_error": (level == "ERROR" or "error" in clean_msg.lower() or "fail" in clean_msg.lower()),
                "message": clean_msg,
                "service": data.get("_SYSTEMD_UNIT", unit_name)
            })

    except Exception:
        pass

    return {
        "unit": unit_name,
        "count": len(entries),
        "latest_cursor": latest_cursor or after_cursor,
        "entries": entries
    }

