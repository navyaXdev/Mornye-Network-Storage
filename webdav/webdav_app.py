import asyncio
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select

from backend.core.config import settings
from backend.core.database import init_db, AsyncSessionLocal, SystemSetting
from backend.core.exceptions import MornyeException
from backend.storage.engine import storage_engine
from backend.services.request_metrics import WebDAVRequestMetricsMiddleware, flush_metrics_to_db
from webdav.router import webdav_router

async def periodic_metrics_flusher():
    """Background flusher for aggregated request metrics."""
    while True:
        try:
            await asyncio.sleep(60)
            await flush_metrics_to_db()
        except asyncio.CancelledError:
            break
        except Exception:
            pass

@asynccontextmanager
async def lifespan(app: FastAPI):
    settings.ensure_directories()
    await init_db()

    async with AsyncSessionLocal() as session:
        stmt = select(SystemSetting).where(SystemSetting.key == "storage_quota_bytes")
        res = await session.execute(stmt)
        setting = res.scalar_one_or_none()
        if setting:
            try:
                quota = int(setting.value)
                storage_engine.set_quota(quota)
            except ValueError:
                pass

    storage_engine.get_used_bytes(force_refresh=True)
    async with AsyncSessionLocal() as session:
        await storage_engine.sync_flat_storage_to_database(session)
        await storage_engine.cleanup_expired_staged_uploads(session)

    flusher_task = asyncio.create_task(periodic_metrics_flusher())
    try:
        yield
    finally:
        flusher_task.cancel()

# Public WebDAV Application
# ONLY exposes WebDAV endpoints. Zero admin interfaces, zero management APIs.
webdav_app = FastAPI(
    title="Mornye Public WebDAV Service",
    version=settings.APP_VERSION,
    lifespan=lifespan,
    docs_url=None,       # Disable Swagger UI on public endpoint
    redoc_url=None,      # Disable ReDoc on public endpoint
    openapi_url=None     # Disable OpenAPI schema on public endpoint
)

webdav_app.add_middleware(WebDAVRequestMetricsMiddleware)
webdav_app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@webdav_app.exception_handler(MornyeException)
async def webdav_exception_handler(request: Request, exc: MornyeException):
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.message, "error_type": exc.__class__.__name__}
    )

# Mount ONLY WebDAV router
webdav_app.include_router(webdav_router)

# Basic Health Check
@webdav_app.get("/health", tags=["Health"], include_in_schema=False)
async def health_check():
    stats = storage_engine.get_storage_stats()
    return {
        "status": "healthy",
        "service": "Mornye Public WebDAV",
        "storage": {
            "quota_gb": stats["quota_gb"],
            "used_gb": stats["used_gb"],
            "percent_used": stats["percent_used"],
            "remaining_quota_gb": stats["remaining_quota_gb"],
            "file_count": stats["file_count"]
        }
    }

# Explicit catch-all for public WebDAV port:
# Any request that is not /dav or /health is rejected with 404
@webdav_app.api_route("/{full_path:path}", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD", "PATCH"], include_in_schema=False)
async def reject_non_webdav(request: Request, full_path: str = ""):
    return JSONResponse(
        status_code=404,
        content={"detail": "Not found. This endpoint serves only Mornye WebDAV protocol at /dav/."}
    )

