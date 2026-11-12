"""
backend/core/config.py
Configuration and environment management for Mornye Network Storage.
"""

import os
from pathlib import Path
from typing import Optional
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field

class Settings(BaseSettings):
    # Application Information
    APP_NAME: str = "Mornye Network Storage"
    APP_VERSION: str = "3.0.0"
    APP_ENV: str = "production"
    DEBUG: bool = False

    # Base Root Directory
    BASE_DIR: Path = Path(__file__).resolve().parent.parent.parent

    # WebDAV Engine Network Configuration
    WEBDAV_HOST: str = "127.0.0.1"
    WEBDAV_PORT: int = 8000

    # Storage Paths
    DATA_PATH: Path = Field(default_factory=lambda: Path(__file__).resolve().parent.parent.parent / "database")
    STORAGE_PATH: Path = Field(default_factory=lambda: Path(__file__).resolve().parent.parent.parent / "storage")
    LOG_PATH: Path = Field(default_factory=lambda: Path(__file__).resolve().parent.parent.parent / "logs")
    BACKUP_PATH: Path = Field(default_factory=lambda: Path(__file__).resolve().parent.parent.parent / "backups")
    RUN_PATH: Path = Field(default_factory=lambda: Path(__file__).resolve().parent.parent.parent / "run")
    TMP_PATH: Path = Field(default_factory=lambda: Path(__file__).resolve().parent.parent.parent / "database" / "tmp")
    CACHE_PATH: Path = Field(default_factory=lambda: Path(__file__).resolve().parent.parent.parent / "database" / "cache")
    RECYCLE_BIN_PATH: Path = Field(default_factory=lambda: Path(__file__).resolve().parent.parent.parent / "database" / "recycle_bin")

    # Security & Tokens
    SECRET_KEY: str = "mornye-change-this-secret-key-in-production-random-64-hex"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60 * 24

    # Storage Quotas (100 GB Mandatory Limit)
    DEFAULT_STORAGE_QUOTA_BYTES: int = 100 * 1024 * 1024 * 1024 # 100 GiB
    MAX_UPLOAD_SIZE_BYTES: int = 2 * 1024 * 1024 * 1024 # 2 GiB per file

    # Cloudflare Hostnames
    PUBLIC_DOMAIN: str = "example.com"
    STORAGE_HOSTNAME: str = "storage.example.com"

    # Database Connection
    DATABASE_URL: Optional[str] = None

    model_config = SettingsConfigDict(
        env_file=str(Path(__file__).resolve().parent.parent.parent / ".env"),
        env_file_encoding="utf-8",
        extra="ignore"
    )

    def get_database_url(self) -> str:
        if self.DATABASE_URL:
            return self.DATABASE_URL
        db_file = self.DATA_PATH / "mornye.db"
        return f"sqlite+aiosqlite:///{db_file.as_posix()}"

    def ensure_directories(self) -> None:
        """Create and verify all program internal directories."""
        self.DATA_PATH.mkdir(parents=True, exist_ok=True)
        self.STORAGE_PATH.mkdir(parents=True, exist_ok=True)
        self.LOG_PATH.mkdir(parents=True, exist_ok=True)
        self.BACKUP_PATH.mkdir(parents=True, exist_ok=True)
        self.RUN_PATH.mkdir(parents=True, exist_ok=True)
        (self.DATA_PATH / "cache").mkdir(parents=True, exist_ok=True)
        (self.DATA_PATH / "tmp").mkdir(parents=True, exist_ok=True)
        (self.DATA_PATH / "recycle_bin").mkdir(parents=True, exist_ok=True)

settings = Settings()
