import json
import logging
import shutil
import hashlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Dict, Any, List
from backend.core.config import settings

logger = logging.getLogger("mornye.diagnostics")

DIAGNOSTICS_LOG_FILE = settings.LOG_PATH / "staged_diagnostics.log"
EVIDENCE_DIR = settings.DATA_PATH / "tmp" / "staged_evidence"

def ensure_diagnostics_dirs() -> None:
    settings.LOG_PATH.mkdir(parents=True, exist_ok=True)
    EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)

def append_diagnostic_event(event: Dict[str, Any]) -> None:
    ensure_diagnostics_dirs()
    event["timestamp"] = datetime.now(timezone.utc).isoformat()
    line = json.dumps(event)
    
    # Write to dedicated diagnostic log file
    try:
        with open(DIAGNOSTICS_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception as e:
        logger.error(f"Failed to append to staged_diagnostics.log: {e}")

    # Output to logger / systemd journal
    logger.info(f"[STAGED_DIAG] {event.get('action')} - req={event.get('request_id')} path={event.get('path')} status={event.get('status', 'N/A')} bytes={event.get('bytes_written', event.get('file_size_bytes', 0))} details={event.get('details', '')}")

def record_upload_start(
    request_id: str,
    method: str,
    path: str,
    content_length: Optional[int],
    transfer_encoding: Optional[str],
    client_ip: str
) -> None:
    append_diagnostic_event({
        "action": "UPLOAD_STARTED",
        "request_id": request_id,
        "method": method,
        "path": path,
        "content_length_header": content_length,
        "transfer_encoding_header": transfer_encoding,
        "client_ip": client_ip,
        "status": "IN_PROGRESS"
    })

def record_upload_complete(
    request_id: str,
    path: str,
    staged_filename: str,
    file_path: Path,
    bytes_written: int,
    expected_size: Optional[int],
    sha256_checksum: str,
    response_status: int
) -> None:
    ensure_diagnostics_dirs()
    evidence_copy_path = None
    if file_path.exists():
        timestamp_prefix = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        evidence_file = EVIDENCE_DIR / f"{timestamp_prefix}_{request_id}_{staged_filename}"
        try:
            shutil.copy2(file_path, evidence_file)
            evidence_copy_path = str(evidence_file)
        except Exception as e:
            logger.warning(f"Failed to preserve evidence copy: {e}")

    append_diagnostic_event({
        "action": "UPLOAD_COMPLETED",
        "request_id": request_id,
        "path": path,
        "staged_filename": staged_filename,
        "bytes_written": bytes_written,
        "expected_size": expected_size,
        "size_matches_expected": (bytes_written == expected_size) if expected_size is not None else None,
        "sha256": sha256_checksum,
        "evidence_saved_to": evidence_copy_path,
        "status": "COMPLETED",
        "response_status": response_status
    })

def record_upload_failed(
    request_id: str,
    path: str,
    error: str,
    bytes_written: int,
    status_code: int
) -> None:
    append_diagnostic_event({
        "action": "UPLOAD_FAILED",
        "request_id": request_id,
        "path": path,
        "bytes_written": bytes_written,
        "error": error,
        "status": "FAILED",
        "response_status": status_code
    })

def record_delete_staged(
    request_id: str,
    path: str,
    staged_filename: str,
    file_path: Path,
    existed_before_delete: bool,
    file_size_before_delete: int,
    sha256_before_delete: Optional[str]
) -> None:
    append_diagnostic_event({
        "action": "STAGED_DELETE_REQUESTED",
        "request_id": request_id,
        "path": path,
        "staged_filename": staged_filename,
        "existed_on_disk": existed_before_delete,
        "file_size_bytes": file_size_before_delete,
        "sha256": sha256_before_delete,
        "status": "DELETED",
        "response_status": 204
    })

def record_propfind_event(
    request_id: str,
    path: str,
    depth: str,
    is_collection: bool,
    child_collections: List[str],
    child_files: List[Dict[str, Any]],
    status_code: int
) -> None:
    append_diagnostic_event({
        "action": "PROPFIND_SERVED",
        "request_id": request_id,
        "path": path,
        "depth": depth,
        "is_collection": is_collection,
        "child_collections": child_collections,
        "child_file_names": [f.get("filename") for f in child_files],
        "child_files_count": len(child_files),
        "status": "SERVED",
        "response_status": status_code
    })

def record_move_event(
    request_id: str,
    source_path: str,
    dest_path: str,
    overwrite: bool,
    status_code: int,
    details: str = ""
) -> None:
    append_diagnostic_event({
        "action": "MOVE_OPERATION",
        "request_id": request_id,
        "source": source_path,
        "destination": dest_path,
        "overwrite": overwrite,
        "details": details,
        "response_status": status_code
    })

