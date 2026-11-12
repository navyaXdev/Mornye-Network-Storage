#!/usr/bin/env python3
"""
cli/user_ops.py
User and Authentication operations for Mornye Bash CLI.
Strict rule: Zero display of passwords, hashes, or secret material in logs.
"""

import sys
import re
import secrets
import string
import asyncio
from pathlib import Path

PROGRAM_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROGRAM_DIR))

from backend.core.config import settings
from backend.core.database import AsyncSessionLocal, User, MusicFile, StorageMetric, init_db
from backend.auth.security import hash_password, verify_password
from sqlalchemy import select, func
from datetime import datetime, timezone

def format_bytes(b: int) -> str:
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if b < 1024.0:
            return f"{b:.2f} {unit}"
        b /= 1024.0
    return f"{b:.2f} PB"

def generate_secure_password(length: int = 16) -> str:
    """Generate cryptographically strong alphanumeric password with symbols."""
    alphabet = string.ascii_letters + string.digits + "!@#%&*-_=+"
    while True:
        pw = ''.join(secrets.choice(alphabet) for _ in range(length))
        # Ensure at least one uppercase, lowercase, digit, and special char
        if (any(c.islower() for c in pw) and
            any(c.isupper() for c in pw) and
            any(c.isdigit() for c in pw) and
            any(c in "!@#%&*-_=+" for c in pw)):
            return pw

async def ensure_db():
    try:
        await init_db()
    except Exception:
        pass

async def list_users():
    await ensure_db()
    async with AsyncSessionLocal() as session:
        stmt = select(User).order_by(User.id.asc())
        res = await session.execute(stmt)
        users = res.scalars().all()

        print(f"{'ID':<4} | {'USERNAME':<15} | {'ROLE':<12} | {'QUOTA':<10} | {'ACTIVE':<8}")
        print("-" * 60)
        for u in users:
            q_val = getattr(u, "storage_quota_bytes", settings.DEFAULT_STORAGE_QUOTA_BYTES)
            quota_str = format_bytes(q_val)
            active_str = "YES" if u.is_active else "NO"
            print(f"{u.id:<4} | {u.username:<15} | {u.role:<12} | {quota_str:<10} | {active_str:<8}")

async def has_users():
    await ensure_db()
    async with AsyncSessionLocal() as session:
        stmt = select(func.count(User.id)).where(User.is_active == True)
        res = await session.execute(stmt)
        count = res.scalar() or 0
        if count > 0:
            print("YES")
            sys.exit(0)
        else:
            print("NO")
            sys.exit(1)

async def get_first_username():
    await ensure_db()
    async with AsyncSessionLocal() as session:
        stmt = select(User.username).where(User.is_active == True).order_by(User.id.asc()).limit(1)
        res = await session.execute(stmt)
        username = res.scalar_one_or_none()
        if username:
            print(username)
            sys.exit(0)
        else:
            sys.exit(1)

async def create_user(username: str, password: str, role: str = "admin"):
    await ensure_db()
    username = username.strip()
    if not username or not re.match(r'^[a-zA-Z0-9_\-\.]{3,32}$', username):
        print(f"[ERROR] Invalid username '{username}'. Must be 3-32 characters (alphanumeric, _, -, .).", file=sys.stderr)
        sys.exit(1)

    if not password or len(password) < 8:
        print("[ERROR] Password must be at least 8 characters in length.", file=sys.stderr)
        sys.exit(1)

    hashed = hash_password(password)

    async with AsyncSessionLocal() as session:
        stmt = select(User).where(User.username == username)
        res = await session.execute(stmt)
        user = res.scalar_one_or_none()

        now = datetime.now(timezone.utc)
        if user:
            user.password_hash = hashed
            user.role = role
            user.is_active = True
            user.updated_at = now
            action = "updated"
        else:
            user = User(
                username=username,
                password_hash=hashed,
                role=role,
                storage_quota_bytes=settings.DEFAULT_STORAGE_QUOTA_BYTES,
                is_active=True,
                created_at=now,
                updated_at=now
            )
            session.add(user)
            action = "created"

        await session.commit()
        print(f"[✔] WebDAV user '{username}' successfully {action} (Role: {role}).")

async def change_password(username: str, new_password: str):
    await ensure_db()
    username = username.strip()
    if not new_password or len(new_password) < 8:
        print("[ERROR] Password must be at least 8 characters in length.", file=sys.stderr)
        sys.exit(1)

    hashed = hash_password(new_password)

    async with AsyncSessionLocal() as session:
        stmt = select(User).where(User.username == username)
        res = await session.execute(stmt)
        user = res.scalar_one_or_none()

        if not user:
            print(f"[ERROR] User '{username}' does not exist.", file=sys.stderr)
            sys.exit(1)

        user.password_hash = hashed
        user.is_active = True
        user.updated_at = datetime.now(timezone.utc)
        await session.commit()
        print(f"[✔] Password updated successfully for WebDAV user '{username}'.")

async def reset_password(username: str, custom_pass: str = None):
    username = username.strip()
    new_pw = custom_pass if custom_pass else generate_secure_password(16)
    await change_password(username, new_pw)

    print("\n" + "=" * 64)
    print("      MORNYE WEBDAV CREDENTIALS RESET CONFIRMATION")
    print("=" * 64)
    print(f"Username     : {username}")
    print(f"New Password : {new_pw}")
    print("=" * 64)
    print("Notice: Store these credentials securely. Passwords are never")
    print("logged or recoverable in plaintext once this terminal closes.")
    print("=" * 64 + "\n")

async def auth_status():
    await ensure_db()
    auth_enabled = settings.WEBDAV_AUTH_ENABLED
    async with AsyncSessionLocal() as session:
        stmt = select(User).order_by(User.id.asc())
        res = await session.execute(stmt)
        users = res.scalars().all()

        print("==============================================================")
        print("             MORNYE WEBDAV AUTHENTICATION STATUS")
        print("==============================================================")
        if auth_enabled:
            print("Authentication Mode   : ENABLED (HTTP Basic Auth Required)")
        else:
            print("Authentication Mode   : DISABLED (Unauthenticated Public Storage)")

        print(f"Configured Users      : {len(users)} user(s)")
        for u in users:
            status_str = "ACTIVE" if u.is_active else "INACTIVE"
            q_str = format_bytes(u.storage_quota_bytes)
            print(f"  * {u.username:<16} (Role: {u.role:<10}, Quota: {q_str}, State: {status_str})")

        print("Security Standard     : Argon2id (OWASP Recommended Parameters)")
        print("==============================================================")

async def verify_credentials(username: str, password: str):
    await ensure_db()
    async with AsyncSessionLocal() as session:
        stmt = select(User).where(User.username == username, User.is_active == True)
        res = await session.execute(stmt)
        user = res.scalar_one_or_none()
        if user and verify_password(password, user.password_hash):
            print("AUTH_OK")
            sys.exit(0)
        else:
            print("AUTH_FAILED")
            sys.exit(1)

async def quota_status():
    async with AsyncSessionLocal() as session:
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
        print("Usage: user_ops.py [list|has-users|get-first|create|change-password|reset-password|auth-status|verify|quota|recalc]")
        sys.exit(1)

    cmd = sys.argv[1].lower()
    if cmd == "list":
        asyncio.run(list_users())
    elif cmd in ["has-users", "has_users"]:
        asyncio.run(has_users())
    elif cmd in ["get-first", "get_first", "first-user"]:
        asyncio.run(get_first_username())
    elif cmd == "create":
        if len(sys.argv) < 4:
            print("Usage: user_ops.py create <username> <password> [role]", file=sys.stderr)
            sys.exit(1)
        role = sys.argv[4] if len(sys.argv) > 4 else "admin"
        asyncio.run(create_user(sys.argv[2], sys.argv[3], role))
    elif cmd in ["change-password", "change_password", "change"]:
        if len(sys.argv) < 4:
            print("Usage: user_ops.py change-password <username> <new_password>", file=sys.stderr)
            sys.exit(1)
        asyncio.run(change_password(sys.argv[2], sys.argv[3]))
    elif cmd in ["reset-password", "reset_password", "reset"]:
        if len(sys.argv) < 3:
            print("Usage: user_ops.py reset-password <username> [new_password]", file=sys.stderr)
            sys.exit(1)
        custom = sys.argv[3] if len(sys.argv) > 3 else None
        asyncio.run(reset_password(sys.argv[2], custom))
    elif cmd in ["auth-status", "auth_status"]:
        asyncio.run(auth_status())
    elif cmd in ["verify", "verify-credentials"]:
        if len(sys.argv) < 4:
            print("Usage: user_ops.py verify <username> <password>", file=sys.stderr)
            sys.exit(1)
        asyncio.run(verify_credentials(sys.argv[2], sys.argv[3]))
    elif cmd in ["quota", "status"]:
        asyncio.run(quota_status())
    elif cmd in ["recalc", "recalculate"]:
        asyncio.run(recalculate_quota())
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
