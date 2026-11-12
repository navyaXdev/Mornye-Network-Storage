"""
tests/test_quota.py
Unit tests verifying 100 GB storage quota enforcement boundaries.
"""

import pytest
from backend.core.config import settings

def test_quota_configuration():
    """Verify default storage quota is exactly 100 GiB (107,374,182,400 bytes)."""
    expected = 100 * 1024 * 1024 * 1024
    assert settings.DEFAULT_STORAGE_QUOTA_BYTES == expected

def test_max_upload_size():
    """Verify maximum upload size per file is 2 GiB (2,147,483,648 bytes)."""
    expected = 2 * 1024 * 1024 * 1024
    assert settings.MAX_UPLOAD_SIZE_BYTES == expected
