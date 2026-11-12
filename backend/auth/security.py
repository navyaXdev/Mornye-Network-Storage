"""
backend/auth/security.py
Argon2id password hashing and HTTP Basic Auth parsing for Mornye Network Storage.
"""

import base64
from typing import Optional, Tuple
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHashError

# Argon2id password hasher (OWASP recommended parameters)
ph = PasswordHasher(
    time_cost=3,
    memory_cost=65536, # 64 MB RAM
    parallelism=4,
    hash_len=32,
    salt_len=16
)

def hash_password(password: str) -> str:
    """Hash password using Argon2id."""
    return ph.hash(password)

def verify_password(plain_password: str, hashed_password: str) -> bool:
    """Verify password against Argon2id hash."""
    try:
        return ph.verify(hashed_password, plain_password)
    except (VerifyMismatchError, InvalidHashError):
        return False

def parse_basic_auth(auth_header: Optional[str]) -> Optional[Tuple[str, str]]:
    """
    Parse HTTP Basic Auth header: 'Basic <base64(username:password)>'.
    Essential for RFC 4918 WebDAV authentication.
    """
    if not auth_header:
        return None
    header_clean = auth_header.strip()
    parts = header_clean.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "basic":
        return None
    try:
        encoded = parts[1].strip()
        decoded_bytes = base64.b64decode(encoded)
        try:
            decoded = decoded_bytes.decode("utf-8")
        except UnicodeDecodeError:
            decoded = decoded_bytes.decode("latin1", errors="replace")
        if ":" in decoded:
            username, password = decoded.split(":", 1)
            return username, password
    except Exception:
        pass
    return None
