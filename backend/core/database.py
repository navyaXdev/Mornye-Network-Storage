"""
backend/core/database.py
SQLAlchemy schema and asynchronous database engine for Mornye Network Storage.
"""

import datetime
from typing import AsyncGenerator
from sqlalchemy import (
    Integer, String, BigInteger, Float, Boolean,
    DateTime, Text
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession

from backend.core.config import settings

class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(64), unique=True, index=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(String(256), nullable=False)
    role: Mapped[str] = mapped_column(String(20), default="music_user", nullable=False)
    storage_quota_bytes: Mapped[int] = mapped_column(BigInteger, default=settings.DEFAULT_STORAGE_QUOTA_BYTES, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime.datetime] = mapped_column(DateTime, default=lambda: datetime.datetime.now(datetime.timezone.utc))
    updated_at: Mapped[datetime.datetime] = mapped_column(
        DateTime,
        default=lambda: datetime.datetime.now(datetime.timezone.utc),
        onupdate=lambda: datetime.datetime.now(datetime.timezone.utc)
    )

class SystemSetting(Base):
    __tablename__ = "system_settings"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    key: Mapped[str] = mapped_column(String(100), unique=True, index=True, nullable=False)
    value: Mapped[str] = mapped_column(Text, nullable=False)
    updated_at: Mapped[datetime.datetime] = mapped_column(
        DateTime,
        default=lambda: datetime.datetime.now(datetime.timezone.utc),
        onupdate=lambda: datetime.datetime.now(datetime.timezone.utc)
    )

class StorageMetric(Base):
    __tablename__ = "storage_metrics"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    timestamp: Mapped[datetime.datetime] = mapped_column(DateTime, default=lambda: datetime.datetime.now(datetime.timezone.utc), index=True)
    used_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False)
    quota_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False)
    file_count: Mapped[int] = mapped_column(Integer, nullable=False)

class AudioMetadataCache(Base):
    __tablename__ = "audio_metadata_cache"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    filename: Mapped[str] = mapped_column(String(255), unique=True, index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(255), nullable=True)
    artist: Mapped[str] = mapped_column(String(255), nullable=True)
    album: Mapped[str] = mapped_column(String(255), nullable=True)
    genre: Mapped[str] = mapped_column(String(100), nullable=True)
    year: Mapped[int] = mapped_column(Integer, nullable=True)
    duration_seconds: Mapped[float] = mapped_column(Float, default=0.0)
    bitrate: Mapped[int] = mapped_column(Integer, default=0)
    sample_rate: Mapped[int] = mapped_column(Integer, default=0)
    channels: Mapped[int] = mapped_column(Integer, default=2)
    format: Mapped[str] = mapped_column(String(20), nullable=False)
    file_size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False)
    artwork_hash: Mapped[str] = mapped_column(String(64), nullable=True)
    last_modified: Mapped[float] = mapped_column(Float, nullable=False)
    indexed_at: Mapped[datetime.datetime] = mapped_column(DateTime, default=lambda: datetime.datetime.now(datetime.timezone.utc))

class VirtualCollection(Base):
    __tablename__ = "virtual_collections"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    path: Mapped[str] = mapped_column(String(512), unique=True, index=True, nullable=False)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    parent_path: Mapped[str] = mapped_column(String(512), index=True, nullable=False)
    owner_username: Mapped[str] = mapped_column(String(64), nullable=True)
    created_at: Mapped[datetime.datetime] = mapped_column(DateTime, default=lambda: datetime.datetime.now(datetime.timezone.utc))
    updated_at: Mapped[datetime.datetime] = mapped_column(
        DateTime,
        default=lambda: datetime.datetime.now(datetime.timezone.utc),
        onupdate=lambda: datetime.datetime.now(datetime.timezone.utc)
    )

class MusicFile(Base):
    __tablename__ = "music_files"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    virtual_path: Mapped[str] = mapped_column(String(512), unique=True, index=True, nullable=False)
    virtual_filename: Mapped[str] = mapped_column(String(255), nullable=False)
    virtual_parent_dir: Mapped[str] = mapped_column(String(512), index=True, nullable=False)
    physical_filename: Mapped[str] = mapped_column(String(255), unique=True, index=True, nullable=False)
    file_size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False)
    sha256_checksum: Mapped[str] = mapped_column(String(64), nullable=False)
    mime_type: Mapped[str] = mapped_column(String(100), nullable=False)
    owner_username: Mapped[str] = mapped_column(String(64), nullable=False, default="admin")
    created_at: Mapped[datetime.datetime] = mapped_column(DateTime, default=lambda: datetime.datetime.now(datetime.timezone.utc))
    updated_at: Mapped[datetime.datetime] = mapped_column(
        DateTime,
        default=lambda: datetime.datetime.now(datetime.timezone.utc),
        onupdate=lambda: datetime.datetime.now(datetime.timezone.utc)
    )

class RecycleBinItem(Base):
    __tablename__ = "recycle_bin_items"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    recycle_id: Mapped[str] = mapped_column(String(64), unique=True, index=True, nullable=False)
    original_virtual_path: Mapped[str] = mapped_column(String(512), nullable=False)
    original_virtual_filename: Mapped[str] = mapped_column(String(255), nullable=False)
    original_physical_filename: Mapped[str] = mapped_column(String(255), nullable=False)
    recycle_filename: Mapped[str] = mapped_column(String(255), nullable=False)
    file_size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False)
    sha256_checksum: Mapped[str] = mapped_column(String(64), nullable=False)
    mime_type: Mapped[str] = mapped_column(String(100), nullable=False)
    deleted_by_username: Mapped[str] = mapped_column(String(64), nullable=False)
    owner_username: Mapped[str] = mapped_column(String(64), nullable=False)
    deleted_at: Mapped[datetime.datetime] = mapped_column(DateTime, default=lambda: datetime.datetime.now(datetime.timezone.utc))

class AuditLog(Base):
    __tablename__ = "audit_logs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    timestamp: Mapped[datetime.datetime] = mapped_column(DateTime, default=lambda: datetime.datetime.now(datetime.timezone.utc), index=True)
    action: Mapped[str] = mapped_column(String(50), nullable=False)
    username: Mapped[str] = mapped_column(String(64), nullable=True)
    client_ip: Mapped[str] = mapped_column(String(64), nullable=True)
    target_resource: Mapped[str] = mapped_column(String(512), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    details: Mapped[str] = mapped_column(Text, nullable=True)

class StagedUpload(Base):
    """Tracks active in-flight temporary staged uploads (.part files) with their virtual folder mapping."""
    __tablename__ = "staged_uploads"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    virtual_path: Mapped[str] = mapped_column(String(512), index=True, nullable=False)
    virtual_parent_dir: Mapped[str] = mapped_column(String(512), index=True, nullable=False, default="/")
    filename: Mapped[str] = mapped_column(String(255), nullable=False, default="")
    physical_temp_filename: Mapped[str] = mapped_column(String(255), nullable=False, default="")
    file_size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    sha256_checksum: Mapped[str] = mapped_column(String(64), nullable=True)
    owner_username: Mapped[str] = mapped_column(String(64), index=True, nullable=False)
    upload_id: Mapped[str] = mapped_column(String(64), index=True, nullable=True)
    staged_filename: Mapped[str] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime.datetime] = mapped_column(DateTime, default=lambda: datetime.datetime.now(datetime.timezone.utc))
    updated_at: Mapped[datetime.datetime] = mapped_column(
        DateTime,
        default=lambda: datetime.datetime.now(datetime.timezone.utc),
        onupdate=lambda: datetime.datetime.now(datetime.timezone.utc),
        nullable=True
    )
    expires_at: Mapped[datetime.datetime] = mapped_column(DateTime, nullable=True)

class RequestMetric(Base):
    """Origin-side WebDAV aggregated request metrics per minute."""
    __tablename__ = "request_metrics"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    timestamp_minute: Mapped[datetime.datetime] = mapped_column(DateTime, index=True, nullable=False)
    is_tunnel: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    total_requests: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    count_2xx: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    count_3xx: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    count_4xx: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    count_5xx: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    count_health: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    avg_latency_ms: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)
    p95_latency_ms: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)

# Database Engine & Session Factory
engine = create_async_engine(
    settings.get_database_url(),
    echo=settings.DEBUG,
    connect_args={"check_same_thread": False}
)

AsyncSessionLocal = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,
    autocommit=False,
    autoflush=False
)

async def init_db() -> None:
    """Initialize database tables and WAL journal mode."""
    settings.ensure_directories()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        # Enable write-ahead logging for high concurrency
        await conn.exec_driver_sql("PRAGMA journal_mode=WAL;")
        await conn.exec_driver_sql("PRAGMA synchronous=NORMAL;")
        await conn.exec_driver_sql("PRAGMA foreign_keys=ON;")

        # Automatic schema migration for staged_uploads table if needed
        try:
            res = await conn.exec_driver_sql("PRAGMA table_info(staged_uploads);")
            cols = {row[1] for row in res.fetchall()}
            if cols:
                if "virtual_parent_dir" not in cols:
                    await conn.exec_driver_sql("ALTER TABLE staged_uploads ADD COLUMN virtual_parent_dir VARCHAR(512) DEFAULT '/';")
                if "filename" not in cols:
                    await conn.exec_driver_sql("ALTER TABLE staged_uploads ADD COLUMN filename VARCHAR(255) DEFAULT '';")
                if "physical_temp_filename" not in cols:
                    await conn.exec_driver_sql("ALTER TABLE staged_uploads ADD COLUMN physical_temp_filename VARCHAR(255) DEFAULT '';")
                if "updated_at" not in cols:
                    await conn.exec_driver_sql("ALTER TABLE staged_uploads ADD COLUMN updated_at DATETIME;")
                if "upload_id" not in cols:
                    await conn.exec_driver_sql("ALTER TABLE staged_uploads ADD COLUMN upload_id VARCHAR(64);")
                if "staged_filename" not in cols:
                    await conn.exec_driver_sql("ALTER TABLE staged_uploads ADD COLUMN staged_filename VARCHAR(255);")
                if "expires_at" not in cols:
                    await conn.exec_driver_sql("ALTER TABLE staged_uploads ADD COLUMN expires_at DATETIME;")
        except Exception:
            pass

async def get_db() -> AsyncGenerator[AsyncSession, None]:
    """Dependency for obtaining async database session."""
    async with AsyncSessionLocal() as session:
        try:
            yield session
        finally:
            await session.close()
