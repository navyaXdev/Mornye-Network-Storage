"""
Mornye Music Statistics Service — Single Source of Truth
Canonical calculations for active tracks, bytes, Recycle Bin, orphaned files, missing files, and quotas.
"""

import shutil
from pathlib import Path
from typing import Dict, Any, List, Optional
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from backend.core.config import settings
from backend.core.database import MusicFile, RecycleBinItem, User, SystemSetting

class MusicStatsService:
    @staticmethod
    async def get_canonical_stats(
        db: AsyncSession,
        storage_path: Optional[Path] = None,
        recycle_path: Optional[Path] = None
    ) -> Dict[str, Any]:
        """
        Compute canonical music catalog and storage metrics.
        Definitions:
          - ACTIVE TRACKS: Valid active database records whose physical files exist on disk.
          - RECYCLE BIN: Soft-deleted database records and their quarantined physical files.
          - ORPHANED FILES: Physical audio files on disk without a matching active or quarantined DB record.
          - MISSING FILES: Active database records whose expected physical file is missing from disk.
        """
        storage_dir = Path(storage_path or settings.STORAGE_PATH).resolve()
        recycle_dir = Path(recycle_path or settings.RECYCLE_BIN_PATH).resolve()

        # 1. Physical storage scanning
        physical_storage_files = {}
        if storage_dir.exists():
            for entry in storage_dir.iterdir():
                if entry.is_file() and not entry.name.startswith("."):
                    try:
                        physical_storage_files[entry.name] = entry.stat().st_size
                    except OSError:
                        pass

        # 2. Physical recycle bin scanning
        physical_recycle_files = {}
        if recycle_dir.exists():
            for entry in recycle_dir.iterdir():
                if entry.is_file() and not entry.name.startswith("."):
                    try:
                        physical_recycle_files[entry.name] = entry.stat().st_size
                    except OSError:
                        pass

        # 3. Query Active Music Files from Database
        stmt_music = select(MusicFile)
        res_music = await db.execute(stmt_music)
        db_music_files = res_music.scalars().all()

        # 4. Query Quarantined Items from Database
        stmt_recycle = select(RecycleBinItem)
        res_recycle = await db.execute(stmt_recycle)
        db_recycle_items = res_recycle.scalars().all()

        # 5. Query Users & Quota Settings
        stmt_users = select(User).order_by(User.id.asc())
        res_users = await db.execute(stmt_users)
        users = res_users.scalars().all()

        # Retrieve configured quota (DB system_settings or config default)
        stmt_quota = select(SystemSetting).where(SystemSetting.key == "storage_quota_bytes")
        res_quota = await db.execute(stmt_quota)
        setting_quota = res_quota.scalar_one_or_none()
        if setting_quota and setting_quota.value.isdigit():
            quota_bytes = int(setting_quota.value)
        else:
            quota_bytes = settings.DEFAULT_STORAGE_QUOTA_BYTES

        # 6. Correlate Active Files vs Physical Disk
        active_tracks = []
        missing_files = []
        active_bytes = 0
        user_track_counts: Dict[str, int] = {u.username: 0 for u in users}
        user_track_bytes: Dict[str, int] = {u.username: 0 for u in users}

        for mf in db_music_files:
            phys_name = mf.physical_filename or mf.virtual_filename
            if phys_name in physical_storage_files:
                # Valid active track
                active_tracks.append(mf)
                file_size = physical_storage_files[phys_name]
                active_bytes += file_size
                owner = mf.owner_username or "unknown"
                user_track_counts[owner] = user_track_counts.get(owner, 0) + 1
                user_track_bytes[owner] = user_track_bytes.get(owner, 0) + file_size
            else:
                # DB record exists but physical file is missing
                missing_files.append(phys_name)

        # 7. Identify Orphaned Physical Files
        db_physical_filenames = {mf.physical_filename for mf in db_music_files if mf.physical_filename}
        db_physical_filenames.update({mf.virtual_filename for mf in db_music_files if mf.virtual_filename})
        orphaned_files = [fname for fname in physical_storage_files if fname not in db_physical_filenames]

        # 8. Correlate Recycle Bin Items
        active_recycle_items = []
        missing_recycle_files = []
        recycle_bytes = 0
        for item in db_recycle_items:
            rec_name = item.recycle_filename
            if rec_name in physical_recycle_files:
                active_recycle_items.append(item)
                recycle_bytes += physical_recycle_files[rec_name]
            else:
                missing_recycle_files.append(rec_name)

        # 9. Storage Calculations
        total_active_tracks = len(active_tracks)
        total_physical_files = len(physical_storage_files)
        total_physical_bytes = sum(physical_storage_files.values())
        total_deleted_tracks = len(db_recycle_items)

        # Used bytes reflects active audio files stored
        used_bytes = active_bytes if total_active_tracks > 0 else total_physical_bytes
        remaining_quota_bytes = max(0, quota_bytes - used_bytes)
        used_percentage = round((used_bytes / quota_bytes) * 100, 2) if quota_bytes > 0 else 0.0

        # Host disk metrics (strictly isolated from music quota)
        try:
            disk_usage = shutil.disk_usage(str(storage_dir))
            host_disk_total = disk_usage.total
            host_disk_free = disk_usage.free
            host_disk_used = disk_usage.used
        except Exception:
            host_disk_total = 0
            host_disk_free = 0
            host_disk_used = 0

        # Per-user statistics
        user_stats = []
        for u in users:
            u_quota = u.storage_quota_bytes or settings.DEFAULT_STORAGE_QUOTA_BYTES
            u_used = user_track_bytes.get(u.username, 0)
            u_count = user_track_counts.get(u.username, 0)
            u_rem = max(0, u_quota - u_used)
            u_pct = round((u_used / u_quota) * 100, 1) if u_quota > 0 else 0.0
            user_stats.append({
                "id": u.id,
                "username": u.username,
                "role": u.role,
                "is_active": u.is_active,
                "created_at": u.created_at,
                "storage_quota_bytes": u_quota,
                "used_bytes": u_used,
                "remaining_bytes": u_rem,
                "usage_percentage": u_pct,
                "track_count": u_count
            })

        active_users_count = sum(1 for u in users if u.is_active)

        return {
            # Canonical Metrics
            "total_active_tracks": total_active_tracks,
            "total_active_bytes": active_bytes,
            "total_deleted_tracks": total_deleted_tracks,
            "recycle_bin_bytes": recycle_bytes,
            "total_physical_files": total_physical_files,
            "total_physical_bytes": total_physical_bytes,
            "missing_files_count": len(missing_files),
            "missing_files": missing_files,
            "orphaned_files_count": len(orphaned_files),
            "orphaned_files": orphaned_files,

            # Quota Metrics
            "quota_bytes": quota_bytes,
            "quota_gb": round(quota_bytes / (1024 ** 3), 2),
            "used_bytes": used_bytes,
            "used_gb": round(used_bytes / (1024 ** 3), 4),
            "remaining_quota_bytes": remaining_quota_bytes,
            "remaining_quota_gb": round(remaining_quota_bytes / (1024 ** 3), 4),
            "used_percentage": used_percentage,
            "percent_used": used_percentage,
            "free_bytes": remaining_quota_bytes,
            "free_gb": round(remaining_quota_bytes / (1024 ** 3), 4),

            # User & System Metrics
            "active_users": active_users_count,
            "total_users": len(users),
            "user_stats": user_stats,

            # Host Partition Metrics (Separated from Mornye Quota)
            "physical_disk_total_bytes": host_disk_total,
            "physical_disk_free_bytes": host_disk_free,
            "physical_disk_used_bytes": host_disk_used,

            # Comprehensive Backward-Compatibility Aliases
            "track_count": total_active_tracks,
            "file_count": total_active_tracks,
            "total_tracks": total_active_tracks,
            "total_count": total_active_tracks,
            "total": total_active_tracks,
            "quarantined_count": total_deleted_tracks,
            "reserved_bytes": 0
        }
