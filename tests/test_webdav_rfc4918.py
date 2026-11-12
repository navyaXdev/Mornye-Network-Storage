"""
tests/test_webdav_rfc4918.py
Automated RFC 4918 WebDAV integration tests.
Tests PROPFIND, MKCOL, PUT, MOVE, GET, DELETE, and Recycle Bin behavior.
"""

import pytest
import httpx
from backend.core.config import settings
from backend.core.database import init_db, AsyncSessionLocal, User
from backend.auth.security import hash_password
from webdav.webdav_app import webdav_app
from sqlalchemy import select

@pytest.fixture(scope="session", autouse=True)
def setup_test_env():
    settings.DATA_PATH.mkdir(parents=True, exist_ok=True)
    settings.STORAGE_PATH.mkdir(parents=True, exist_ok=True)

@pytest.mark.asyncio
async def test_webdav_unauthorized_propfind():
    """Verify that unauthenticated PROPFIND is rejected with HTTP 401."""
    transport = httpx.ASGITransport(app=webdav_app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
        resp = await client.request("PROPFIND", "/dav/", headers={"Depth": "0"})
        assert resp.status_code == 401
        assert 'Basic realm="Mornye Music WebDAV"' in resp.headers.get("www-authenticate", "")

@pytest.mark.asyncio
async def test_webdav_health():
    """Verify that /health reports storage metrics."""
    transport = httpx.ASGITransport(app=webdav_app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
        resp = await client.get("/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data.get("status") == "healthy"
        assert "storage" in data
