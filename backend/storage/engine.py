import os
import shutil
import asyncio
import uuid
import datetime
import hashlib
from pathlib import Path
from typing import Dict, Any, List, Optional, Tuple, AsyncGenerator, Generator
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, delete, update

from backend.core.config import settings
from backend.core.database import VirtualCollection, MusicFile, RecycleBinItem, AuditLog, StagedUpload
from backend.core.exceptions import (
    StorageSecurityException,
    QuotaExceededException,
    FileNotFoundStorageException,
    DuplicateFileException,
    DirectoryCreationForbiddenException,
    NonAudioFileException
)
from backend.storage.validator import (
    sanitize_filename,
    inspect_audio_signature,
    get_mime_type_for_filename,
    is_mornye_probe_filename,
    is_staged_part_filename,
    compute_sha256,
    normalize_virtual_path,
    split_virtual_path,
    generate_flat_physical_filename
)
from backend.storage.metadata import extract_metadata

class StorageEngine:
    """
    Dedicated Custom Storage Engine for Mornye Private Music Storage.
    Enforces:
    1. Absolute physical flat storage in storage/ (zero physical subdirectories).
    2. Virtual Directory layer backed by database metadata (RFC 4918 compatible).
    3. Proper Recycle Bin (soft delete to database/recycle_bin/).
    4. Strict 100 GB music storage quota enforcement across all upload paths.
    5. HTTP byte-range streaming without RAM buffering.
    6. Staged .part transfers and connection probe isolation.
    """

    def __init__(self, storage_path: Optional[Path] = None):
        self.storage_path = (storage_path or settings.STORAGE_PATH).resolve()
        self.tmp_path = settings.TMP_PATH.resolve()
        self.probes_path = (self.tmp_path / "probes").resolve()
        self.staged_path = (self.tmp_path / "staged").resolve()
        self.recycle_bin_path = settings.RECYCLE_BIN_PATH.resolve()
        self.quota_bytes = settings.DEFAULT_STORAGE_QUOTA_BYTES
        
        # Concurrency protection
        self._lock = asyncio.Lock()
        self._reserved_bytes: int = 0
        self._cached_used_bytes: Optional[int] = None
        self._last_recalc_time: float = 0

    def ensure_directories(self) -> None:
        self.storage_path.mkdir(parents=True, exist_ok=True)
        self.tmp_path.mkdir(parents=True, exist_ok=True)
        self.probes_path.mkdir(parents=True, exist_ok=True)
        self.staged_path.mkdir(parents=True, exist_ok=True)
        self.recycle_bin_path.mkdir(parents=True, exist_ok=True)

    def set_quota(self, new_quota_bytes: int) -> None:
        """Update quota allocation (Admin operation)."""
        if new_quota_bytes <= 0:
            raise ValueError("Storage quota must be greater than zero")
        self.quota_bytes = new_quota_bytes

    def resolve_safe_path(self, filename: str) -> Path:
        """
        Resolve and strictly validate that a physical file path is directly inside storage_path.
        Rejects directory traversal, subdirectories, and symlinks pointing outside.
        """
        clean_name = sanitize_filename(filename)
        candidate = (self.storage_path / clean_name).resolve()

        if candidate.parent != self.storage_path:
            raise StorageSecurityException(f"Path jail violation: '{filename}' attempts to access outside storage root")

        if candidate.is_symlink():
            target = candidate.resolve()
            if target.parent != self.storage_path:
                raise StorageSecurityException(f"Symlink jail violation: '{filename}' points outside storage root")

        return candidate

    # --- Mornye Probes & Staged Transfers ---

    def is_mornye_probe(self, filename: str) -> bool:
        """Check if filename is a Mornye connection probe: .mornye-probe-<hash>"""
        return is_mornye_probe_filename(filename)

    def is_staged_part_file(self, filename: str) -> bool:
        """Check if filename is an in-flight Mornye staged part file: .<name>.part"""
        return is_staged_part_filename(filename)

    def write_probe(self, filename: str, content: bytes) -> None:
        """Write temporary probe file in program/database/tmp/probes/."""
        if not self.is_mornye_probe(filename):
            raise StorageSecurityException(f"Invalid probe filename: '{filename}'")
        self.ensure_directories()
        probe_file = (self.probes_path / filename).resolve()
        if probe_file.parent != self.probes_path:
            raise StorageSecurityException("Probe path violation")
        probe_file.write_bytes(content)

    def delete_probe(self, filename: str) -> bool:
        """Delete temporary probe file."""
        if not self.is_mornye_probe(filename):
            raise StorageSecurityException(f"Invalid probe filename: '{filename}'")
        self.ensure_directories()
        probe_file = (self.probes_path / filename).resolve()
        if probe_file.parent != self.probes_path:
            raise StorageSecurityException("Probe path violation")
        if probe_file.exists():
            probe_file.unlink()
            return True
        return False

    def probe_exists(self, filename: str) -> bool:
        """Check if temporary probe exists."""
        if not self.is_mornye_probe(filename):
            return False
        self.ensure_directories()
        probe_file = (self.probes_path / filename).resolve()
        return probe_file.parent == self.probes_path and probe_file.exists()

    def get_probe_bytes(self, filename: str) -> Optional[bytes]:
        """Read temporary probe file content."""
        if not self.is_mornye_probe(filename):
            return None
        self.ensure_directories()
        probe_file = (self.probes_path / filename).resolve()
        if probe_file.parent == self.probes_path and probe_file.exists():
            return probe_file.read_bytes()
        return None

    async def write_staged_stream(
        self,
        filename: str,
        stream_chunks: AsyncGenerator[bytes, None],
        expected_size: Optional[int] = None,
        owner_username: str = "navya",
        virtual_path: str = "",
        db: Optional[AsyncSession] = None
    ) -> Tuple[int, str, Path]:
        """
        Stream upload chunks into temporary staged location in program/database/tmp/staged/.
        Enforces 100 GB quota chunk-by-chunk and computes SHA-256 in real-time.
        Registers virtual parent directory and filename in database metadata for PROPFIND visibility.
        Returns (bytes_written, sha256_checksum, staged_file_path).
        """
        if not self.is_staged_part_file(filename):
            raise StorageSecurityException(f"Invalid staged part filename: '{filename}'")
        self.ensure_directories()

        if virtual_path:
            norm_virtual = normalize_virtual_path(virtual_path)
            parent_dir, leaf_name = split_virtual_path(norm_virtual)
            path_token = hashlib.sha256(norm_virtual.encode()).hexdigest()[:8]
            physical_temp_filename = f"{owner_username}_{path_token}_{leaf_name}"
        else:
            norm_virtual = f"/{filename}"
            parent_dir = "/"
            leaf_name = filename
            physical_temp_filename = f"{owner_username}_{filename}"

        staged_file = (self.staged_path / physical_temp_filename).resolve()
        if staged_file.parent != self.staged_path:
            raise StorageSecurityException("Staged path violation")

        reservation = expected_size if expected_size and expected_size > 0 else 0
        if reservation > 0:
            await self.reserve_quota(reservation)

        bytes_written = 0
        hasher = hashlib.sha256()
        try:
            with open(staged_file, "wb") as f:
                async for chunk in stream_chunks:
                    if chunk:
                        bytes_written += len(chunk)
                        hasher.update(chunk)
                        current_used = self.get_used_bytes()
                        if (current_used + bytes_written) > self.quota_bytes:
                            raise QuotaExceededException(
                                "Storage quota exceeded during streaming: 100 GB music limit reached."
                            )
                        f.write(chunk)
                f.flush()

            sha256_hex = hasher.hexdigest()

            # Register in database if session provided
            if db:
                stmt = select(StagedUpload).where(
                    StagedUpload.virtual_path == norm_virtual,
                    StagedUpload.owner_username == owner_username
                )
                res = await db.execute(stmt)
                staged_record = res.scalar_one_or_none()
                now = datetime.datetime.now(datetime.timezone.utc)
                if staged_record:
                    staged_record.file_size_bytes = bytes_written
                    staged_record.sha256_checksum = sha256_hex
                    staged_record.physical_temp_filename = physical_temp_filename
                    staged_record.updated_at = now
                else:
                    staged_record = StagedUpload(
                        virtual_path=norm_virtual,
                        virtual_parent_dir=parent_dir,
                        filename=leaf_name,
                        physical_temp_filename=physical_temp_filename,
                        file_size_bytes=bytes_written,
                        sha256_checksum=sha256_hex,
                        owner_username=owner_username,
                        created_at=now,
                        updated_at=now
                    )
                    db.add(staged_record)
                await db.commit()

            return bytes_written, sha256_hex, staged_file
        finally:
            if reservation > 0:
                await self.release_quota_reservation(reservation)

    async def delete_staged_file(
        self,
        filename: str,
        owner_username: Optional[str] = None,
        virtual_path: Optional[str] = None,
        db: Optional[AsyncSession] = None
    ) -> Tuple[bool, int, Optional[str]]:
        """
        Delete temporary staged part file and remove its database metadata.
        Returns (deleted, size_bytes, sha256_checksum).
        """
        if not self.is_staged_part_file(filename):
            return False, 0, None
        self.ensure_directories()

        deleted_size = 0
        deleted_checksum = None
        found = False

        if db and (virtual_path or owner_username):
            stmt = select(StagedUpload)
            if virtual_path:
                stmt = stmt.where(StagedUpload.virtual_path == normalize_virtual_path(virtual_path))
            else:
                stmt = stmt.where(StagedUpload.filename == filename)
            if owner_username:
                stmt = stmt.where(StagedUpload.owner_username == owner_username)

            res = await db.execute(stmt)
            record = res.scalar_one_or_none()
            if record:
                target_file = (self.staged_path / record.physical_temp_filename).resolve()
                if target_file.parent == self.staged_path and target_file.exists():
                    deleted_size = target_file.stat().st_size
                    deleted_checksum = compute_sha256(target_file)
                    target_file.unlink()
                    found = True
                await db.delete(record)
                await db.commit()
                return True, deleted_size, deleted_checksum

        # Fallback to direct filename on disk
        target_file = (self.staged_path / filename).resolve()
        if target_file.parent == self.staged_path and target_file.exists():
            deleted_size = target_file.stat().st_size
            deleted_checksum = compute_sha256(target_file)
            target_file.unlink()
            found = True

        return found, deleted_size, deleted_checksum

    async def staged_file_exists(
        self,
        filename: str,
        owner_username: Optional[str] = None,
        virtual_path: Optional[str] = None,
        db: Optional[AsyncSession] = None
    ) -> bool:
        """Check if staged part file exists on disk and in database metadata."""
        if not self.is_staged_part_file(filename):
            return False
        self.ensure_directories()

        if db and (virtual_path or owner_username):
            stmt = select(StagedUpload)
            if virtual_path:
                stmt = stmt.where(StagedUpload.virtual_path == normalize_virtual_path(virtual_path))
            else:
                stmt = stmt.where(StagedUpload.filename == filename)
            if owner_username:
                stmt = stmt.where(StagedUpload.owner_username == owner_username)

            res = await db.execute(stmt)
            record = res.scalar_one_or_none()
            if record:
                target_file = (self.staged_path / record.physical_temp_filename).resolve()
                return target_file.parent == self.staged_path and target_file.exists()

        target_file = (self.staged_path / filename).resolve()
        return target_file.parent == self.staged_path and target_file.exists()

    # --- Storage Usage & Metrics ---

    def get_used_bytes(self, force_refresh: bool = False) -> int:
        """
        Calculate or return cached used storage bytes in storage/.
        Enforces absolute flat rule: storage contains ONLY flat files.
        """
        self.ensure_directories()
        if self._cached_used_bytes is not None and not force_refresh:
            return self._cached_used_bytes

        total = 0
        for entry in self.storage_path.iterdir():
            if entry.is_dir():
                raise DirectoryCreationForbiddenException(f"Found forbidden subdirectory '{entry.name}' in storage root")
            if entry.is_file() and not entry.name.startswith("."):
                total += entry.stat().st_size

        self._cached_used_bytes = total
        return total

    def get_storage_stats(self) -> Dict[str, Any]:
        """
        Return comprehensive storage metrics including 100 GB quota details,
        used bytes, remaining quota, percentage, and physical OS disk space.
        """
        used = self.get_used_bytes()
        quota = self.quota_bytes
        remaining_quota = max(0, quota - used)
        percent_used = round((used / quota) * 100, 2) if quota > 0 else 0.0

        disk_usage = shutil.disk_usage(self.storage_path)
        file_count = sum(1 for entry in self.storage_path.iterdir() if entry.is_file() and not entry.name.startswith("."))

        return {
            "quota_bytes": quota,
            "quota_gb": round(quota / (1024 ** 3), 2),
            "used_bytes": used,
            "used_gb": round(used / (1024 ** 3), 4),
            "remaining_quota_bytes": remaining_quota,
            "remaining_quota_gb": round(remaining_quota / (1024 ** 3), 4),
            "percent_used": percent_used,
            "reserved_bytes": self._reserved_bytes,
            "file_count": file_count,
            "track_count": file_count,
            "total_tracks": file_count,
            "total_count": file_count,
            "total": file_count,
            "free_bytes": remaining_quota,
            "free_gb": round(remaining_quota / (1024 ** 3), 4),
            "physical_disk_total_bytes": disk_usage.total,
            "physical_disk_free_bytes": disk_usage.free,
            "physical_disk_used_bytes": disk_usage.used
        }

    def list_audio_files(self) -> List[Dict[str, Any]]:
        """List all audio files in the flat physical storage directory."""
        self.ensure_directories()
        files = []
        for entry in self.storage_path.iterdir():
            if entry.is_file() and not entry.name.startswith("."):
                stat = entry.stat()
                files.append({
                    "filename": entry.name,
                    "file_size_bytes": stat.st_size,
                    "last_modified": stat.st_mtime,
                    "mime_type": get_mime_type_for_filename(entry.name),
                    "extension": entry.suffix.lower()
                })
        return sorted(files, key=lambda x: x["filename"].lower())

    def delete_audio_file(self, filename: str) -> bool:
        """Delete an audio file from storage and free up quota."""
        safe_path = self.resolve_safe_path(filename)
        if not safe_path.exists() or not safe_path.is_file():
            raise FileNotFoundStorageException(f"Audio file '{filename}' not found")

        file_size = safe_path.stat().st_size
        safe_path.unlink()

        if self._cached_used_bytes is not None:
            self._cached_used_bytes = max(0, self._cached_used_bytes - file_size)

        return True

    def rename_audio_file(self, old_name: str, new_name: str, overwrite: bool = False) -> Dict[str, Any]:
        """
        Rename an audio file within the flat storage root.
        Does NOT alter quota (same file data).
        Rejects directory moves or path traversal.
        """
        old_path = self.resolve_safe_path(old_name)
        new_path = self.resolve_safe_path(new_name)

        if not old_path.exists() or not old_path.is_file():
            raise FileNotFoundStorageException(f"Original file '{old_name}' not found")

        if new_path.exists() and not overwrite and old_path != new_path:
            raise DuplicateFileException(f"Target filename '{new_name}' already exists in storage")

        if new_path.exists() and overwrite and old_path != new_path:
            new_size = new_path.stat().st_size
            new_path.unlink()
            if self._cached_used_bytes is not None:
                self._cached_used_bytes -= new_size

        shutil.move(str(old_path), str(new_path))
        meta = extract_metadata(new_path)
        return meta

    async def write_audio_stream(
        self,
        filename: str,
        stream_chunks: AsyncGenerator[bytes, None],
        expected_size: Optional[int] = None,
        overwrite: bool = False
    ) -> Dict[str, Any]:
        """
        Direct audio upload stream to storage/.
        Validates audio signature, enforces 100 GB quota, and computes SHA-256.
        """
        sanitize_filename(filename)
        safe_path = self.resolve_safe_path(filename)
        if safe_path.exists() and not overwrite:
            raise DuplicateFileException(f"File '{filename}' already exists in storage")

        reservation = expected_size if expected_size and expected_size > 0 else 0
        if reservation > 0:
            await self.reserve_quota(reservation)

        temp_file = self.tmp_path / f"upload_{os.urandom(8).hex()}_{filename}"
        bytes_written = 0
        try:
            with open(temp_file, "wb") as f:
                async for chunk in stream_chunks:
                    if chunk:
                        bytes_written += len(chunk)
                        current_used = self.get_used_bytes()
                        if (current_used + bytes_written) > self.quota_bytes:
                            raise QuotaExceededException(
                                "Storage quota exceeded during streaming: 100 GB music limit reached."
                            )
                        f.write(chunk)

            if bytes_written == 0:
                raise NonAudioFileException("Uploaded audio file is empty (0 bytes)")

            inspect_audio_signature(temp_file)
            shutil.move(str(temp_file), str(safe_path))
            self.get_used_bytes(force_refresh=True)
            meta = extract_metadata(safe_path)
            return meta
        finally:
            if reservation > 0:
                await self.release_quota_reservation(reservation)
            if temp_file.exists():
                try:
                    temp_file.unlink()
                except Exception:
                    pass



    async def reserve_quota(self, expected_size: int) -> None:
        """Check and atomically reserve quota for an in-flight upload."""
        async with self._lock:
            current_used = self.get_used_bytes()
            projected_total = current_used + self._reserved_bytes + expected_size
            if projected_total > self.quota_bytes:
                remaining = max(0, self.quota_bytes - (current_used + self._reserved_bytes))
                raise QuotaExceededException(
                    f"Storage quota exceeded: 100 GB music storage limit reached. "
                    f"Requested {expected_size} bytes, but only {remaining} bytes remaining."
                )
            self._reserved_bytes += expected_size

    async def release_quota_reservation(self, reserved_size: int) -> None:
        """Release temporary quota reservation."""
        async with self._lock:
            self._reserved_bytes = max(0, self._reserved_bytes - reserved_size)

    # --- Virtual Directory Operations (Backed by Database Metadata) ---

    async def create_virtual_collection(
        self,
        virtual_path: str,
        owner_username: str,
        db: AsyncSession
    ) -> bool:
        """
        Create a virtual directory collection.
        Does NOT create physical directories on disk. Backed by database metadata.
        """
        norm_path = normalize_virtual_path(virtual_path)
        if norm_path == "/":
            raise DuplicateFileException("Root collection already exists")

        # Check if already exists in virtual_collections
        stmt = select(VirtualCollection).where(VirtualCollection.path == norm_path)
        res = await db.execute(stmt)
        if res.scalar_one_or_none():
            raise DuplicateFileException(f"Virtual collection '{norm_path}' already exists")

        # Check if a music file exists at that path
        stmt_file = select(MusicFile).where(MusicFile.virtual_path == norm_path)
        res_file = await db.execute(stmt_file)
        if res_file.scalar_one_or_none():
            raise DuplicateFileException(f"A file already exists at '{norm_path}'")

        parent_dir, leaf_name = split_virtual_path(norm_path)
        if parent_dir != "/":
            await self.ensure_virtual_collection_exists(parent_dir, owner_username, db)

        col = VirtualCollection(
            path=norm_path,
            name=leaf_name,
            parent_path=parent_dir,
            owner_username=owner_username,
            created_at=datetime.datetime.now(datetime.timezone.utc)
        )
        db.add(col)

        audit = AuditLog(
            action="MKCOL",
            username=owner_username,
            target_resource=norm_path,
            status="SUCCESS",
            details="Created virtual collection"
        )
        db.add(audit)
        await db.commit()
        return True

    async def ensure_virtual_collection_exists(
        self,
        collection_path: str,
        owner_username: str,
        db: AsyncSession
    ) -> None:
        """Recursively ensure intermediate virtual collections exist."""
        norm = normalize_virtual_path(collection_path)
        if norm == "/":
            return

        parts = norm.strip("/").split("/")
        current = ""
        for part in parts:
            parent = current if current else "/"
            current = f"{current}/{part}"
            stmt = select(VirtualCollection).where(VirtualCollection.path == current)
            res = await db.execute(stmt)
            if not res.scalar_one_or_none():
                col = VirtualCollection(
                    path=current,
                    name=part,
                    parent_path=parent,
                    owner_username=owner_username,
                    created_at=datetime.datetime.now(datetime.timezone.utc)
                )
                db.add(col)
                await db.commit()

    async def list_virtual_collection(
        self,
        virtual_path: str,
        db: AsyncSession,
        owner_username: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """
        Query virtual directory hierarchy for PROPFIND.
        Returns: Dict describing collection and its children, or single file info, or None if not found.
        Includes active in-flight staged uploads (.part files) scoped to the authenticated owner.
        """
        norm = normalize_virtual_path(virtual_path)

        # 1. Root Collection
        if norm == "/":
            stmt_col = select(VirtualCollection).where(VirtualCollection.parent_path == "/")
            res_col = await db.execute(stmt_col)
            cols = res_col.scalars().all()

            stmt_files = select(MusicFile).where(MusicFile.virtual_parent_dir == "/")
            res_files = await db.execute(stmt_files)
            files = res_files.scalars().all()

            stmt_staged = select(StagedUpload).where(StagedUpload.virtual_parent_dir == "/")
            if owner_username:
                stmt_staged = stmt_staged.where(StagedUpload.owner_username == owner_username)
            res_staged = await db.execute(stmt_staged)
            staged_files = res_staged.scalars().all()

            files_list = [
                {
                    "filename": f.virtual_filename,
                    "href": f"/dav{f.virtual_path}",
                    "file_size_bytes": f.file_size_bytes,
                    "last_modified": f.created_at.timestamp() if f.created_at else 0,
                    "mime_type": f.mime_type
                }
                for f in files
            ]
            for s in staged_files:
                files_list.append({
                    "filename": s.filename,
                    "href": f"/dav{s.virtual_path}",
                    "file_size_bytes": s.file_size_bytes,
                    "last_modified": s.created_at.timestamp() if s.created_at else 0,
                    "mime_type": "application/octet-stream",
                    "is_staged": True
                })

            return {
                "is_collection": True,
                "href": "/dav/",
                "displayname": "Mornye Storage Root",
                "collections": [{"name": c.name, "href": f"/dav{c.path}/"} for c in cols],
                "files": files_list
            }

        # 2. Check if norm is a Virtual Collection
        stmt_col = select(VirtualCollection).where(VirtualCollection.path == norm)
        res_col = await db.execute(stmt_col)
        target_col = res_col.scalar_one_or_none()

        if target_col:
            stmt_sub = select(VirtualCollection).where(VirtualCollection.parent_path == norm)
            res_sub = await db.execute(stmt_sub)
            sub_cols = res_sub.scalars().all()

            stmt_f = select(MusicFile).where(MusicFile.virtual_parent_dir == norm)
            res_f = await db.execute(stmt_f)
            child_files = res_f.scalars().all()

            stmt_staged = select(StagedUpload).where(StagedUpload.virtual_parent_dir == norm)
            if owner_username:
                stmt_staged = stmt_staged.where(StagedUpload.owner_username == owner_username)
            res_staged = await db.execute(stmt_staged)
            staged_files = res_staged.scalars().all()

            files_list = [
                {
                    "filename": f.virtual_filename,
                    "href": f"/dav{f.virtual_path}",
                    "file_size_bytes": f.file_size_bytes,
                    "last_modified": f.created_at.timestamp() if f.created_at else 0,
                    "mime_type": f.mime_type
                }
                for f in child_files
            ]
            for s in staged_files:
                files_list.append({
                    "filename": s.filename,
                    "href": f"/dav{s.virtual_path}",
                    "file_size_bytes": s.file_size_bytes,
                    "last_modified": s.created_at.timestamp() if s.created_at else 0,
                    "mime_type": "application/octet-stream",
                    "is_staged": True
                })

            return {
                "is_collection": True,
                "href": f"/dav{norm}/",
                "displayname": target_col.name,
                "collections": [{"name": c.name, "href": f"/dav{c.path}/"} for c in sub_cols],
                "files": files_list
            }

        # 3. Check if norm is a Music File
        stmt_file = select(MusicFile).where(MusicFile.virtual_path == norm)
        res_file = await db.execute(stmt_file)
        target_file = res_file.scalar_one_or_none()

        if target_file:
            return {
                "is_collection": False,
                "href": f"/dav{target_file.virtual_path}",
                "displayname": target_file.virtual_filename,
                "file": {
                    "filename": target_file.virtual_filename,
                    "href": f"/dav{target_file.virtual_path}",
                    "file_size_bytes": target_file.file_size_bytes,
                    "last_modified": target_file.created_at.timestamp() if target_file.created_at else 0,
                    "mime_type": target_file.mime_type,
                    "physical_filename": target_file.physical_filename
                }
            }

        # 4. Check if norm is an active Staged Upload
        stmt_staged_single = select(StagedUpload).where(StagedUpload.virtual_path == norm)
        if owner_username:
            stmt_staged_single = stmt_staged_single.where(StagedUpload.owner_username == owner_username)
        res_staged_single = await db.execute(stmt_staged_single)
        target_staged = res_staged_single.scalar_one_or_none()
        if target_staged:
            return {
                "is_collection": False,
                "href": f"/dav{target_staged.virtual_path}",
                "displayname": target_staged.filename,
                "file": {
                    "filename": target_staged.filename,
                    "href": f"/dav{target_staged.virtual_path}",
                    "file_size_bytes": target_staged.file_size_bytes,
                    "last_modified": target_staged.created_at.timestamp() if target_staged.created_at else 0,
                    "mime_type": "application/octet-stream",
                    "is_staged": True
                }
            }

        return None

    # --- Virtual Audio Uploads & Publishing ---

    async def write_virtual_audio_stream(
        self,
        virtual_path: str,
        stream_chunks: AsyncGenerator[bytes, None],
        owner_username: str,
        db: AsyncSession,
        expected_size: Optional[int] = None,
        overwrite: bool = False
    ) -> MusicFile:
        """
        Direct audio upload to virtual path.
        Saves physically flat in storage/. Validates audio signature and quota.
        """
        norm_path = normalize_virtual_path(virtual_path)
        parent_dir, leaf_name = split_virtual_path(norm_path)
        sanitize_filename(leaf_name)

        stmt = select(MusicFile).where(MusicFile.virtual_path == norm_path)
        res = await db.execute(stmt)
        existing_file = res.scalar_one_or_none()
        if existing_file and not overwrite:
            raise DuplicateFileException(f"Music file '{norm_path}' already exists in library")

        reservation = expected_size if expected_size and expected_size > 0 else 0
        if reservation > 0:
            await self.reserve_quota(reservation)

        temp_file = self.tmp_path / f"upload_{os.urandom(8).hex()}_{leaf_name}"
        bytes_written = 0

        try:
            with open(temp_file, "wb") as f:
                async for chunk in stream_chunks:
                    if chunk:
                        bytes_written += len(chunk)
                        current_used = self.get_used_bytes()
                        if (current_used + bytes_written) > self.quota_bytes:
                            raise QuotaExceededException(
                                "Storage quota exceeded during streaming: 100 GB music limit reached."
                            )
                        f.write(chunk)

            if bytes_written == 0:
                raise NonAudioFileException("Uploaded audio file is empty (0 bytes)")

            inspect_audio_signature(temp_file)
            checksum = compute_sha256(temp_file)
            mime_type = get_mime_type_for_filename(leaf_name)

            physical_name = generate_flat_physical_filename(norm_path)
            final_physical_path = (self.storage_path / physical_name).resolve()

            old_size = 0
            if final_physical_path.exists():
                old_size = final_physical_path.stat().st_size
                final_physical_path.unlink()

            shutil.move(str(temp_file), str(final_physical_path))

            if parent_dir != "/":
                await self.ensure_virtual_collection_exists(parent_dir, owner_username, db)

            if existing_file:
                existing_file.file_size_bytes = bytes_written
                existing_file.sha256_checksum = checksum
                existing_file.mime_type = mime_type
                existing_file.physical_filename = physical_name
                existing_file.updated_at = datetime.datetime.now(datetime.timezone.utc)
                music_record = existing_file
            else:
                music_record = MusicFile(
                    virtual_path=norm_path,
                    virtual_filename=leaf_name,
                    virtual_parent_dir=parent_dir,
                    physical_filename=physical_name,
                    file_size_bytes=bytes_written,
                    sha256_checksum=checksum,
                    mime_type=mime_type,
                    owner_username=owner_username,
                    created_at=datetime.datetime.now(datetime.timezone.utc)
                )
                db.add(music_record)

            audit = AuditLog(
                action="UPLOAD",
                username=owner_username,
                target_resource=norm_path,
                status="SUCCESS",
                details=f"Size: {bytes_written} bytes, Checksum: {checksum}, Physical: {physical_name}"
            )
            db.add(audit)
            await db.commit()
            await db.refresh(music_record)

            if self._cached_used_bytes is not None:
                self._cached_used_bytes = self._cached_used_bytes - old_size + bytes_written
            else:
                self.get_used_bytes(force_refresh=True)

            extract_metadata(final_physical_path)
            return music_record

        finally:
            if reservation > 0:
                await self.release_quota_reservation(reservation)
            if temp_file.exists():
                try:
                    temp_file.unlink()
                except Exception:
                    pass

    async def commit_virtual_staged_file(
        self,
        staged_filename: str,
        dest_virtual_path: str,
        owner_username: str,
        db: AsyncSession,
        source_virtual_path: Optional[str] = None,
        overwrite: bool = False
    ) -> MusicFile:
        """
        Publish Mornye staged part file into its final virtual destination.
        Physically flat in storage/. Validates audio signature and quota.
        Cleans up staged metadata from staged_uploads table.
        """
        if not self.is_staged_part_file(staged_filename):
            raise StorageSecurityException(f"Invalid staged part filename: '{staged_filename}'")

        # Locate staged file via database metadata
        staged_record = None
        if source_virtual_path:
            norm_src = normalize_virtual_path(source_virtual_path)
            stmt = select(StagedUpload).where(
                StagedUpload.virtual_path == norm_src,
                StagedUpload.owner_username == owner_username
            )
            res = await db.execute(stmt)
            staged_record = res.scalar_one_or_none()

        if not staged_record:
            stmt = select(StagedUpload).where(
                StagedUpload.filename == staged_filename,
                StagedUpload.owner_username == owner_username
            )
            res = await db.execute(stmt)
            staged_record = res.scalar_one_or_none()

        if staged_record:
            staged_file = (self.staged_path / staged_record.physical_temp_filename).resolve()
        else:
            staged_file = (self.staged_path / staged_filename).resolve()

        if not staged_file.exists() or not staged_file.is_file():
            raise FileNotFoundStorageException(f"Staged file '{staged_filename}' not found")

        norm_dest = normalize_virtual_path(dest_virtual_path)
        parent_dir, leaf_name = split_virtual_path(norm_dest)
        sanitize_filename(leaf_name)

        stmt = select(MusicFile).where(MusicFile.virtual_path == norm_dest)
        res = await db.execute(stmt)
        existing_file = res.scalar_one_or_none()
        if existing_file and not overwrite:
            raise DuplicateFileException(f"Destination '{norm_dest}' already exists in library")

        staged_size = staged_file.stat().st_size
        if staged_size == 0:
            if staged_file.exists():
                staged_file.unlink()
            if staged_record:
                await db.delete(staged_record)
                await db.commit()
            raise NonAudioFileException("Uploaded audio file is empty (0 bytes)")

        try:
            inspect_audio_signature(staged_file)
        except Exception:
            if staged_file.exists():
                staged_file.unlink()
            if staged_record:
                await db.delete(staged_record)
                await db.commit()
            raise

        checksum = compute_sha256(staged_file)
        mime_type = get_mime_type_for_filename(leaf_name)

        current_used = self.get_used_bytes()
        dest_size = existing_file.file_size_bytes if existing_file else 0
        projected = current_used - dest_size + staged_size
        if projected > self.quota_bytes:
            if staged_file.exists():
                staged_file.unlink()
            if staged_record:
                await db.delete(staged_record)
                await db.commit()
            raise QuotaExceededException("Storage quota exceeded: 100 GB music storage limit reached")

        physical_name = generate_flat_physical_filename(norm_dest)
        final_physical_path = (self.storage_path / physical_name).resolve()

        old_size = 0
        if final_physical_path.exists():
            old_size = final_physical_path.stat().st_size
            final_physical_path.unlink()

        shutil.move(str(staged_file), str(final_physical_path))

        if parent_dir != "/":
            await self.ensure_virtual_collection_exists(parent_dir, owner_username, db)

        if existing_file:
            existing_file.file_size_bytes = staged_size
            existing_file.sha256_checksum = checksum
            existing_file.mime_type = mime_type
            existing_file.physical_filename = physical_name
            existing_file.updated_at = datetime.datetime.now(datetime.timezone.utc)
            music_record = existing_file
        else:
            music_record = MusicFile(
                virtual_path=norm_dest,
                virtual_filename=leaf_name,
                virtual_parent_dir=parent_dir,
                physical_filename=physical_name,
                file_size_bytes=staged_size,
                sha256_checksum=checksum,
                mime_type=mime_type,
                owner_username=owner_username,
                created_at=datetime.datetime.now(datetime.timezone.utc)
            )
            db.add(music_record)

        if staged_record:
            await db.delete(staged_record)

        audit = AuditLog(
            action="UPLOAD_COMMITTED",
            username=owner_username,
            target_resource=norm_dest,
            status="SUCCESS",
            details=f"Published staged transfer: {staged_filename} -> {norm_dest}, Physical: {physical_name}"
        )
        db.add(audit)
        await db.commit()
        await db.refresh(music_record)

        if self._cached_used_bytes is not None:
            self._cached_used_bytes = self._cached_used_bytes - old_size + staged_size
        else:
            self.get_used_bytes(force_refresh=True)

        extract_metadata(final_physical_path)
        return music_record

    async def cleanup_expired_staged_uploads(self, db: AsyncSession, max_age_hours: int = 24) -> int:
        """Clean up orphaned staged upload files and DB records older than max_age_hours."""
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=max_age_hours)
        stmt = select(StagedUpload).where(StagedUpload.created_at < cutoff)
        res = await db.execute(stmt)
        expired = res.scalars().all()
        count = 0
        for item in expired:
            target_file = (self.staged_path / item.physical_temp_filename).resolve()
            if target_file.parent == self.staged_path and target_file.exists():
                try:
                    target_file.unlink()
                except Exception:
                    pass
            await db.delete(item)
            count += 1
        if count > 0:
            await db.commit()
        return count

        extract_metadata(final_physical_path)
        return music_record

    # --- Recycle Bin (Soft Delete & Restore) ---

    async def soft_delete_file(
        self,
        virtual_path: str,
        deleted_by: str,
        db: AsyncSession
    ) -> RecycleBinItem:
        """
        Soft-delete a music file into the Recycle Bin.
        Moves physical file to database/recycle_bin/ and records metadata in database.
        Storage directory remains strictly flat.
        """
        norm_path = normalize_virtual_path(virtual_path)
        stmt = select(MusicFile).where(MusicFile.virtual_path == norm_path)
        res = await db.execute(stmt)
        file_record = res.scalar_one_or_none()

        if not file_record:
            raise FileNotFoundStorageException(f"Audio file '{virtual_path}' not found in library")

        physical_file = (self.storage_path / file_record.physical_filename).resolve()
        if not physical_file.exists() or not physical_file.is_file():
            await db.delete(file_record)
            await db.commit()
            raise FileNotFoundStorageException(f"Physical audio file for '{virtual_path}' not found on disk")

        recycle_id = uuid.uuid4().hex
        recycle_filename = f"{recycle_id}_{file_record.physical_filename}"
        recycle_target = (self.recycle_bin_path / recycle_filename).resolve()

        # Atomically move from storage/ to recycle_bin/
        shutil.move(str(physical_file), str(recycle_target))

        checksum = file_record.sha256_checksum or compute_sha256(recycle_target)

        recycle_item = RecycleBinItem(
            recycle_id=recycle_id,
            original_virtual_path=file_record.virtual_path,
            original_virtual_filename=file_record.virtual_filename,
            original_physical_filename=file_record.physical_filename,
            recycle_filename=recycle_filename,
            file_size_bytes=file_record.file_size_bytes,
            sha256_checksum=checksum,
            mime_type=file_record.mime_type,
            deleted_by_username=deleted_by,
            owner_username=file_record.owner_username,
            deleted_at=datetime.datetime.now(datetime.timezone.utc)
        )
        db.add(recycle_item)
        await db.delete(file_record)

        audit = AuditLog(
            action="SOFT_DELETE",
            username=deleted_by,
            target_resource=norm_path,
            status="SUCCESS",
            details=f"Recycle ID: {recycle_id}, Size: {recycle_item.file_size_bytes} bytes, Checksum: {checksum}"
        )
        db.add(audit)
        await db.commit()
        await db.refresh(recycle_item)

        if self._cached_used_bytes is not None:
            self._cached_used_bytes = max(0, self._cached_used_bytes - recycle_item.file_size_bytes)

        return recycle_item

    async def restore_recycle_item(
        self,
        recycle_id: str,
        restored_by: str,
        db: AsyncSession
    ) -> MusicFile:
        """
        Restore an item from Recycle Bin back into active storage.
        Guarantees quota check, checksum verification, and collision protection.
        """
        stmt = select(RecycleBinItem).where(RecycleBinItem.recycle_id == recycle_id)
        res = await db.execute(stmt)
        item = res.scalar_one_or_none()

        if not item:
            raise FileNotFoundStorageException(f"Recycle bin item '{recycle_id}' not found")

        recycle_file = (self.recycle_bin_path / item.recycle_filename).resolve()
        if not recycle_file.exists() or not recycle_file.is_file():
            raise FileNotFoundStorageException(f"Recycle bin data file '{item.recycle_filename}' missing on disk")

        # Quota check
        current_used = self.get_used_bytes()
        if (current_used + item.file_size_bytes) > self.quota_bytes:
            raise QuotaExceededException("Cannot restore: 100 GB music storage quota would be exceeded")

        # Virtual path collision resolution
        target_virtual_path = item.original_virtual_path
        existing_stmt = select(MusicFile).where(MusicFile.virtual_path == target_virtual_path)
        existing_res = await db.execute(existing_stmt)
        if existing_res.scalar_one_or_none():
            parent_dir, leaf = split_virtual_path(target_virtual_path)
            stem = Path(leaf).stem
            ext = Path(leaf).suffix
            target_virtual_path = f"{parent_dir}/{stem}_restored{ext}".replace("//", "/")

        # Physical file collision resolution
        physical_name = item.original_physical_filename
        target_physical = (self.storage_path / physical_name).resolve()
        if target_physical.exists():
            stem = Path(physical_name).stem
            ext = Path(physical_name).suffix
            physical_name = f"{stem}_restored_{uuid.uuid4().hex[:6]}{ext}"
            target_physical = (self.storage_path / physical_name).resolve()

        # Atomically move from recycle_bin/ back to storage/
        shutil.move(str(recycle_file), str(target_physical))

        actual_checksum = compute_sha256(target_physical)
        if item.sha256_checksum and actual_checksum != item.sha256_checksum:
            shutil.move(str(target_physical), str(recycle_file))
            raise StorageSecurityException("Restored file checksum mismatch: file corruption detected")

        parent_dir, leaf = split_virtual_path(target_virtual_path)
        if parent_dir != "/":
            await self.ensure_virtual_collection_exists(parent_dir, restored_by, db)

        restored_music = MusicFile(
            virtual_path=target_virtual_path,
            virtual_filename=leaf,
            virtual_parent_dir=parent_dir,
            physical_filename=physical_name,
            file_size_bytes=item.file_size_bytes,
            sha256_checksum=actual_checksum,
            mime_type=item.mime_type,
            owner_username=item.owner_username,
            created_at=datetime.datetime.now(datetime.timezone.utc)
        )
        db.add(restored_music)
        await db.delete(item)

        audit = AuditLog(
            action="RESTORE",
            username=restored_by,
            target_resource=target_virtual_path,
            status="SUCCESS",
            details=f"Restored from Recycle ID: {recycle_id}, Checksum: {actual_checksum}"
        )
        db.add(audit)
        await db.commit()
        await db.refresh(restored_music)

        if self._cached_used_bytes is not None:
            self._cached_used_bytes += item.file_size_bytes

        return restored_music

    async def permanent_delete_recycle_item(
        self,
        recycle_id: str,
        admin_user: str,
        db: AsyncSession
    ) -> bool:
        """
        Permanently destroy an item in the Recycle Bin.
        STRICTLY requires administrator authorization.
        """
        stmt = select(RecycleBinItem).where(RecycleBinItem.recycle_id == recycle_id)
        res = await db.execute(stmt)
        item = res.scalar_one_or_none()

        if not item:
            raise FileNotFoundStorageException(f"Recycle bin item '{recycle_id}' not found")

        recycle_file = (self.recycle_bin_path / item.recycle_filename).resolve()
        if recycle_file.exists() and recycle_file.is_file():
            recycle_file.unlink()

        target_path = item.original_virtual_path
        await db.delete(item)

        audit = AuditLog(
            action="PERMANENT_DELETE",
            username=admin_user,
            target_resource=target_path,
            status="SUCCESS",
            details=f"Permanently destroyed Recycle ID: {recycle_id}"
        )
        db.add(audit)
        await db.commit()
        return True

    # --- HTTP Range Streaming ---

    def get_range_stream(
        self,
        filename: str,
        range_header: Optional[str] = None
    ) -> Tuple[Generator[bytes, None, None], int, int, int, str, int]:
        """
        Process HTTP byte-range requests for low-RAM streaming and Mornye seeking.
        Returns: (chunk_generator, start_byte, end_byte, total_size, mime_type, status_code)
        """
        safe_path = self.resolve_safe_path(filename)
        if not safe_path.exists() or not safe_path.is_file():
            raise FileNotFoundStorageException(f"Audio file '{filename}' not found")

        total_size = safe_path.stat().st_size
        mime_type = get_mime_type_for_filename(safe_path.name)

        start = 0
        end = total_size - 1
        status_code = 200

        if range_header and range_header.startswith("bytes="):
            range_val = range_header.replace("bytes=", "").strip()
            parts = range_val.split("-")
            
            if len(parts) == 2:
                if parts[0] and parts[1]:
                    start = int(parts[0])
                    end = min(int(parts[1]), total_size - 1)
                elif parts[0] and not parts[1]:
                    start = int(parts[0])
                    end = total_size - 1
                elif not parts[0] and parts[1]:
                    suffix_length = int(parts[1])
                    start = max(0, total_size - suffix_length)
                    end = total_size - 1

            if start <= end and start < total_size:
                status_code = 206
            else:
                start = 0
                end = total_size - 1

        def chunk_generator():
            with open(safe_path, "rb") as f:
                f.seek(start)
                bytes_left = (end - start) + 1
                chunk_size = 64 * 1024 # 64 KB chunks
                while bytes_left > 0:
                    read_len = min(chunk_size, bytes_left)
                    data = f.read(read_len)
                    if not data:
                        break
                    bytes_left -= len(data)
                    yield data

        return chunk_generator(), start, end, total_size, mime_type, status_code

    async def get_virtual_range_stream(
        self,
        virtual_path: str,
        range_header: Optional[str],
        db: AsyncSession
    ) -> Tuple[Generator[bytes, None, None], int, int, int, str, int]:
        """Resolve virtual path and stream audio file."""
        norm_path = normalize_virtual_path(virtual_path)
        stmt = select(MusicFile).where(MusicFile.virtual_path == norm_path)
        res = await db.execute(stmt)
        record = res.scalar_one_or_none()

        if not record:
            raise FileNotFoundStorageException(f"Music file '{virtual_path}' not found")

        return self.get_range_stream(record.physical_filename, range_header)

    async def sync_flat_storage_to_database(self, db: AsyncSession) -> None:
        """
        Scan physical storage directory and ensure all flat audio files are indexed
        in the virtual music_files table.
        """
        self.ensure_directories()
        for entry in self.storage_path.iterdir():
            if entry.is_file() and not entry.name.startswith("."):
                stmt = select(MusicFile).where(MusicFile.physical_filename == entry.name)
                res = await db.execute(stmt)
                if not res.scalar_one_or_none():
                    vpath = f"/{entry.name}"
                    stat = entry.stat()
                    try:
                        csum = compute_sha256(entry)
                    except Exception:
                        csum = ""
                    mime = get_mime_type_for_filename(entry.name)
                    record = MusicFile(
                        virtual_path=vpath,
                        virtual_filename=entry.name,
                        virtual_parent_dir="/",
                        physical_filename=entry.name,
                        file_size_bytes=stat.st_size,
                        sha256_checksum=csum,
                        mime_type=mime,
                        owner_username="navya",
                        created_at=datetime.datetime.now(datetime.timezone.utc)
                    )
                    db.add(record)
        await db.commit()

storage_engine = StorageEngine()
