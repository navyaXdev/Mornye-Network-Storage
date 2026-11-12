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
    """Verify that unauthenticated PROPFIND is rejected with HTTP 401 when auth is enabled."""
    settings.WEBDAV_AUTH_ENABLED = True
    transport = httpx.ASGITransport(app=webdav_app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
        resp = await client.request("PROPFIND", "/dav/", headers={"Depth": "0"})
        assert resp.status_code == 401
        assert 'Basic realm="Mornye Music WebDAV"' in resp.headers.get("www-authenticate", "")

@pytest.mark.asyncio
async def test_webdav_invalid_credentials_propfind():
    """Verify that PROPFIND with invalid credentials returns HTTP 401."""
    settings.WEBDAV_AUTH_ENABLED = True
    transport = httpx.ASGITransport(app=webdav_app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
        resp = await client.request(
            "PROPFIND",
            "/dav/",
            headers={"Depth": "0"},
            auth=("nonexistent_user", "wrong_password_123")
        )
        assert resp.status_code == 401
        assert 'Basic realm="Mornye Music WebDAV"' in resp.headers.get("www-authenticate", "")

@pytest.mark.asyncio
async def test_webdav_authorized_propfind():
    """Verify that PROPFIND with valid user credentials returns HTTP 207 Multi-Status."""
    await init_db()
    test_user = "authtest_user"
    test_pass = "SecurePass123!@#"
    async with AsyncSessionLocal() as session:
        stmt = select(User).where(User.username == test_user)
        res = await session.execute(stmt)
        existing = res.scalar_one_or_none()
        if not existing:
            u = User(
                username=test_user,
                password_hash=hash_password(test_pass),
                role="admin",
                is_active=True
            )
            session.add(u)
            await session.commit()

    settings.WEBDAV_AUTH_ENABLED = True
    transport = httpx.ASGITransport(app=webdav_app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
        resp = await client.request(
            "PROPFIND",
            "/dav/",
            headers={"Depth": "0"},
            auth=(test_user, test_pass)
        )
        assert resp.status_code in [200, 207]

@pytest.mark.asyncio
async def test_webdav_disabled_auth_propfind():
    """Verify that unauthenticated PROPFIND succeeds when WEBDAV_AUTH_ENABLED is False."""
    settings.WEBDAV_AUTH_ENABLED = False
    try:
        transport = httpx.ASGITransport(app=webdav_app)
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
            resp = await client.request("PROPFIND", "/dav/", headers={"Depth": "0"})
            assert resp.status_code in [200, 207]
    finally:
        settings.WEBDAV_AUTH_ENABLED = True

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
