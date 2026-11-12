#!/usr/bin/env python3
"""
cli/music_ops.py
Music operations for Mornye Bash CLI.
Uses existing backend models and storage services.
"""

import sys
import asyncio
import hashlib
from pathlib import Path

PROGRAM_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROGRAM_DIR))

from backend.core.config import settings
from backend.core.database import AsyncSessionLocal, MusicFile
from backend.services.music_stats_service import MusicStatsService
from sqlalchemy import select

def format_bytes(b: int) -> str:
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if b < 1024.0:
            return f"{b:.2f} {unit}"
        b /= 1024.0
    return f"{b:.2f} PB"

async def list_music():
    async with AsyncSessionLocal() as session:
        stmt = select(MusicFile).order_by(MusicFile.id.asc())
        res = await session.execute(stmt)
        files = res.scalars().all()

        if not files:
            print("[INFO] No music files recorded in database.")
            return

        print(f"{'ID':<4} | {'VIRTUAL PATH':<35} | {'SIZE':<10} | {'OWNER':<10} | {'STATUS'}")
        print("-" * 75)
        for f in files:
            size_str = format_bytes(f.file_size_bytes)
            status = "ACTIVE"
            print(f"{f.id:<4} | {f.virtual_path:<35} | {size_str:<10} | {f.owner_username:<10} | {status}")

async def stats_music():
    async with AsyncSessionLocal() as session:
        stats = await MusicStatsService.get_canonical_stats(session)
        print("=" * 60)
        print("               MORNYE MUSIC STORAGE STATISTICS")
        print("=" * 60)
        print(f"Total Active Tracks       : {stats['total_active_tracks']}")
        print(f"Used Storage              : {format_bytes(stats['total_active_bytes'])} ({stats['total_active_bytes']} bytes)")
        print(f"Quota Allocated           : {format_bytes(stats['quota_bytes'])} ({stats['quota_bytes']} bytes)")
        print(f"Quota Utilization         : {stats['used_percentage']:.2f}%")
        print(f"Free Storage Remaining    : {format_bytes(stats['free_bytes'])}")
        print(f"Physical Files in Storage : {stats['total_physical_files']}")
        print(f"Physical Storage Size     : {format_bytes(stats['total_physical_bytes'])}")
        print(f"Quarantined in Recycle Bin: {stats['total_deleted_tracks']} files ({format_bytes(stats['recycle_bin_bytes'])})")
        print(f"Integrity Status          : {'HEALTHY & CONSISTENT' if stats['missing_files_count'] == 0 else 'WARNING (Missing files detected)'}")
        print("=" * 60)

async def verify_music():
    storage_dir = settings.STORAGE_PATH
    print(f"[*] Auditing physical music repository: {storage_dir}")
    if not storage_dir.exists():
        print(f"[ERROR] Storage directory {storage_dir} does not exist!")
        sys.exit(1)

    async with AsyncSessionLocal() as session:
        stmt = select(MusicFile)
        res = await session.execute(stmt)
        db_files = {f.physical_filename: f for f in res.scalars().all()}

    physical_files = list(storage_dir.glob("*"))
    physical_map = {f.name: f for f in physical_files if f.is_file()}

    print(f"[*] Database track records : {len(db_files)}")
    print(f"[*] Physical storage files : {len(physical_map)}")
    print("-" * 65)

    all_ok = True
    for phys_name, db_file in db_files.items():
        if phys_name not in physical_map:
            print(f"[MISSING] DB entry '{db_file.virtual_path}' -> physical file '{phys_name}' not found!")
            all_ok = False
            continue

        p_file = physical_map[phys_name]
        actual_size = p_file.stat().st_size
        if actual_size != db_file.file_size_bytes:
            print(f"[SIZE MISMATCH] '{phys_name}': DB={db_file.file_size_bytes}B, Disk={actual_size}B")
            all_ok = False
        else:
            print(f"[VERIFIED] {db_file.virtual_path} ({format_bytes(actual_size)}) - OK")

    for phys_name in physical_map:
        if phys_name not in db_files:
            print(f"[ORPHAN] Physical file '{phys_name}' is not indexed in database.")
            all_ok = False

    if all_ok:
        print("[✔] 100% Music Storage Integrity Verified. All tracks match physical disk files.")
    else:
        print("[!] Warnings found during music storage integrity verification.")

def main():
    if len(sys.argv) < 2:
        print("Usage: music_ops.py [list|stats|verify]")
        sys.exit(1)

    cmd = sys.argv[1].lower()
    if cmd == "list":
        asyncio.run(list_music())
    elif cmd == "stats":
        asyncio.run(stats_music())
    elif cmd == "verify":
        asyncio.run(verify_music())
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()
