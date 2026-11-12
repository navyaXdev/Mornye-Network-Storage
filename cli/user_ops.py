#!/usr/bin/env python3
"""
cli/user_ops.py
User and Quota operations for Mornye Bash CLI.
Strict rule: Zero display of passwords, hashes, or secret material.
"""

import sys
import asyncio
from pathlib import Path

PROGRAM_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROGRAM_DIR))

from backend.core.config import settings
from backend.core.database import AsyncSessionLocal, User, MusicFile, StorageMetric
from sqlalchemy import select, func
from datetime import datetime, timezone

def format_bytes(b: int) -> str:
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if b < 1024.0:
            return f"{b:.2f} {unit}"
        b /= 1024.0
    return f"{b:.2f} PB"

async def list_users():
    async with AsyncSessionLocal() as session:
        stmt = select(User).order_by(User.id.asc())
        res = await session.execute(stmt)
        users = res.scalars().all()

        print(f"{'ID':<4} | {'USERNAME':<15} | {'ROLE':<12} | {'QUOTA':<10} | {'ACTIVE':<8}")
        print("-" * 60)
        for u in users:
            q_val = getattr(u, "allocated_quota_bytes", getattr(u, "storage_quota_bytes", settings.DEFAULT_STORAGE_QUOTA_BYTES))
            quota_str = format_bytes(q_val)
            active_str = "YES" if u.is_active else "NO"
            print(f"{u.id:<4} | {u.username:<15} | {u.role:<12} | {quota_str:<10} | {active_str:<8}")

async def quota_status():
    async with AsyncSessionLocal() as session:
        # Sum total active music files
        stmt_files = select(
            func.count(MusicFile.id),
            func.coalesce(func.sum(MusicFile.file_size_bytes), 0)
        )
        res_files = await session.execute(stmt_files)
        total_tracks, total_bytes = res_files.one()

        quota = settings.DEFAULT_STORAGE_QUOTA_BYTES
        used_pct = (total_bytes / quota * 100.0) if quota > 0 else 0.0
        free_bytes = max(0, quota - total_bytes)

        print("=" * 60)
        print("                 MORNYE STORAGE QUOTA AUDIT")
        print("=" * 60)
        print(f"Allocated Quota Limit  : {format_bytes(quota)} ({quota} bytes)")
        print(f"Total Used Space       : {format_bytes(total_bytes)} ({total_bytes} bytes)")
        print(f"Available Free Space   : {format_bytes(free_bytes)} ({free_bytes} bytes)")
        print(f"Utilization Rate       : {used_pct:.2f}%")
        print(f"Indexed Audio Files    : {total_tracks} tracks")
        print("-" * 60)
        
        # User breakdown
        res_users = await session.execute(select(User))
        for u in res_users.scalars().all():
            print(f"User: {u.username} (Role: {u.role}, Allocated: {format_bytes(u.storage_quota_bytes)})")
        print("=" * 60)

async def recalculate_quota():
    print("[*] Recalculating storage quota and usage metrics from live database records...")
    async with AsyncSessionLocal() as session:
        stmt = select(
            func.count(MusicFile.id),
            func.coalesce(func.sum(MusicFile.file_size_bytes), 0)
        )
        res = await session.execute(stmt)
        count, total_bytes = res.one()

        quota = settings.DEFAULT_STORAGE_QUOTA_BYTES
        metric = StorageMetric(
            timestamp=datetime.now(timezone.utc),
            used_bytes=total_bytes,
            quota_bytes=quota,
            file_count=count
        )
        session.add(metric)
        await session.commit()

        print(f"[✔] Quota recalculation complete: {count} tracks totaling {format_bytes(total_bytes)}.")
        print(f"[✔] StorageMetric snapshot committed to SQLite.")

def main():
    if len(sys.argv) < 2:
        print("Usage: user_ops.py [list|quota|recalc]")
        sys.exit(1)

    cmd = sys.argv[1].lower()
    if cmd == "list":
        asyncio.run(list_users())
    elif cmd in ["quota", "status"]:
        asyncio.run(quota_status())
    elif cmd in ["recalc", "recalculate"]:
        asyncio.run(recalculate_quota())
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()

