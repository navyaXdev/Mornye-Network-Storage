#!/usr/bin/env python3
"""
cli/backup_ops.py
Backup and recovery operations for Mornye Bash CLI.
Guarantees online SQLite safety and integrity verification.
"""

import os
import sys
import shutil
import sqlite3
from pathlib import Path
from datetime import datetime

PROGRAM_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROGRAM_DIR))

from backend.core.config import settings

def format_bytes(b: int) -> str:
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if b < 1024.0:
            return f"{b:.2f} {unit}"
        b /= 1024.0
    return f"{b:.2f} PB"

def create_backup():
    db_path = settings.DATA_PATH / "mornye.db"
    if not db_path.exists():
        print(f"[ERROR] Database file not found at {db_path}!")
        sys.exit(1)

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_dir = settings.BASE_DIR / "backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    dst_file = backup_dir / f"mornye.db.backup_{ts}"

    print(f"[*] Starting online SQLite backup of {db_path}...")
    conn_src = sqlite3.connect(str(db_path))
    conn_dst = sqlite3.connect(str(dst_file))
    with conn_dst:
        conn_src.backup(conn_dst)
    conn_dst.close()
    conn_src.close()

    # Integrity verification
    c = sqlite3.connect(str(dst_file)).cursor()
    c.execute("PRAGMA integrity_check;")
    res = c.fetchone()[0]
    if res != "ok":
        print(f"[ERROR] Backup integrity check failed: {res}")
        sys.exit(1)

    # Mirror to outside backup dir
    out_dir = Path("/home/spidyno/.song/backups")
    if out_dir.exists():
        out_dst = out_dir / f"mornye_backup_outside_{ts}.db"
        shutil.copy2(dst_file, out_dst)
        print(f"[✔] Mirrored to outside safety path: {out_dst}")

    print(f"[✔] Online backup created successfully: {dst_file}")
    print(f"[✔] File size: {format_bytes(dst_file.stat().st_size)} ({dst_file.stat().st_size} bytes)")
    print(f"[✔] Integrity check: PRAGMA integrity_check -> {res}")

def list_backups():
    dirs = [
        settings.BASE_DIR / "backups",
        Path("/home/spidyno/.song/backups")
    ]
    found = []
    for d in dirs:
        if d.exists():
            for f in d.glob("*"):
                if f.is_file() and ("backup" in f.name.lower() or f.suffix in [".db", ".bak"]):
                    found.append(f)

    if not found:
        print("[INFO] No backup files found in backup locations.")
        return

    # Sort newest first
    found.sort(key=lambda x: x.stat().st_mtime, reverse=True)

    print(f"{'FILENAME':<48} | {'SIZE':<10} | {'MODIFIED'}")
    print("-" * 80)
    for f in found:
        dt = datetime.fromtimestamp(f.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")
        print(f"{f.name:<48} | {format_bytes(f.stat().st_size):<10} | {dt}")

def verify_backup(target_path_str: str):
    target = Path(target_path_str)
    if not target.exists():
        # Check inside backups/
        candidate = settings.BASE_DIR / "backups" / target_path_str
        if candidate.exists():
            target = candidate
        else:
            print(f"[ERROR] Backup file '{target_path_str}' not found!")
            sys.exit(1)

    print(f"[*] Verifying SQLite backup integrity: {target}")
    try:
        conn = sqlite3.connect(str(target))
        cur = conn.cursor()
        cur.execute("PRAGMA integrity_check;")
        res = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM users;")
        user_cnt = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM music_files;")
        music_cnt = cur.fetchone()[0]
        conn.close()

        print(f"[✔] Integrity result : {res}")
        print(f"[✔] Users count      : {user_cnt}")
        print(f"[✔] Tracks count     : {music_cnt}")
        print(f"[✔] Backup size      : {format_bytes(target.stat().st_size)}")
        if res == "ok":
            print("[✔] Backup is valid, consistent, and ready for restoration.")
        else:
            print("[ERROR] Backup integrity compromised.")
            sys.exit(1)
    except Exception as e:
        print(f"[ERROR] Verification failed: {e}")
        sys.exit(1)

def restore_backup(target_path_str: str, force: bool = False):
    if not force:
        print("[ERROR] Restore requires explicit confirmation flag --confirm.")
        sys.exit(1)

    target = Path(target_path_str)
    if not target.exists():
        candidate = settings.BASE_DIR / "backups" / target_path_str
        if candidate.exists():
            target = candidate
        else:
            print(f"[ERROR] Backup file '{target_path_str}' not found!")
            sys.exit(1)

    # 1. First verify target backup integrity
    try:
        c_test = sqlite3.connect(str(target)).cursor()
        c_test.execute("PRAGMA integrity_check;")
        if c_test.fetchone()[0] != "ok":
            print("[ERROR] Target backup failed integrity check. Aborting restore.")
            sys.exit(1)
    except Exception as e:
        print(f"[ERROR] Target backup cannot be opened: {e}. Aborting restore.")
        sys.exit(1)

    # 2. Create safety pre-restore backup of current db
    current_db = settings.DATA_PATH / "mornye.db"
    if current_db.exists():
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        safety_path = settings.BASE_DIR / "backups" / f"mornye.db.pre_restore_safety_{ts}"
        print(f"[*] Creating pre-restore safety copy at {safety_path}...")
        conn_c = sqlite3.connect(str(current_db))
        conn_s = sqlite3.connect(str(safety_path))
        with conn_s:
            conn_c.backup(conn_s)
        conn_s.close()
        conn_c.close()

    # 3. Restore target into active database
    print(f"[*] Restoring {target} into {current_db}...")
    conn_src = sqlite3.connect(str(target))
    conn_dst = sqlite3.connect(str(current_db))
    with conn_dst:
        conn_src.backup(conn_dst)
    conn_dst.close()
    conn_src.close()

    # 4. Final integrity check
    conn_chk = sqlite3.connect(str(current_db))
    c_final = conn_chk.cursor()
    c_final.execute("PRAGMA integrity_check;")
    chk = c_final.fetchone()[0]
    conn_chk.close()

    if chk == "ok":
        print(f"[✔] Database restored successfully and verified (PRAGMA integrity_check: {chk}).")
    else:
        print(f"[ERROR] Restored database integrity check failed: {chk}")
        sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print("Usage: backup_ops.py [create|list|verify <path>|restore <path> --confirm]")
        sys.exit(1)

    cmd = sys.argv[1].lower()
    if cmd == "create":
        create_backup()
    elif cmd == "list":
        list_backups()
    elif cmd == "verify":
        if len(sys.argv) < 3:
            print("Usage: backup_ops.py verify <backup_file>")
            sys.exit(1)
        verify_backup(sys.argv[2])
    elif cmd == "restore":
        if len(sys.argv) < 3:
            print("Usage: backup_ops.py restore <backup_file> [--confirm]")
            sys.exit(1)
        confirm = ("--confirm" in sys.argv)
        restore_backup(sys.argv[2], force=confirm)
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()
