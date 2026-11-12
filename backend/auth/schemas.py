"""
backend/auth/schemas.py
Pydantic schemas for authentication and user models.
"""

from pydantic import BaseModel, ConfigDict
from typing import Optional

class UserOut(BaseModel):
    id: int
    username: str
    role: str
    is_active: bool
    allocated_quota_bytes: int

    model_config = ConfigDict(from_attributes=True)
