"""
backend/auth/dependencies.py
Authentication dependencies for WebDAV and internal services.
"""

from typing import Optional
from fastapi import Request, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from backend.core.database import get_db, User
from backend.auth.security import parse_basic_auth, verify_password

async def authenticate_user(
    request: Request,
    db: AsyncSession = Depends(get_db)
) -> Optional[User]:
    """
    Authenticate request via HTTP Basic Auth header.
    Standard for WebDAV clients and streaming music players.
    """
    auth_header = request.headers.get("Authorization")
    basic_creds = parse_basic_auth(auth_header)
    if basic_creds:
        username, password = basic_creds
        stmt = select(User).where(User.username == username, User.is_active == True)
        res = await db.execute(stmt)
        user = res.scalar_one_or_none()
        if user and verify_password(password, user.password_hash):
            return user
    return None
