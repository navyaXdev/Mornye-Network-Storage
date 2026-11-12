import os
import hashlib
from pathlib import Path
from typing import Dict, Any, Optional
import mutagen
from mutagen.id3 import ID3, APIC
from mutagen.flac import FLAC, Picture
from mutagen.mp4 import MP4, MP4Cover
from backend.core.config import settings

def extract_artwork(audio, cache_dir: Path) -> Optional[str]:
    """
    Extract embedded artwork and save it to program/database/cache/artwork/{hash}.jpg.
    Returns the SHA256 hash or None if no artwork is embedded.
    Ensures that NO artwork files are ever placed in storage/.
    """
    artwork_bytes: Optional[bytes] = None
    
    try:
        # ID3 (MP3, AIFF)
        if hasattr(audio, "tags") and audio.tags:
            for tag in audio.tags.values():
                if isinstance(tag, APIC):
                    artwork_bytes = tag.data
                    break

        # FLAC
        if artwork_bytes is None and isinstance(audio, FLAC) and audio.pictures:
            artwork_bytes = audio.pictures[0].data

        # MP4 / M4A
        if artwork_bytes is None and isinstance(audio, MP4) and "covr" in audio:
            covers = audio["covr"]
            if covers:
                artwork_bytes = bytes(covers[0])
    except Exception:
        artwork_bytes = None

    if artwork_bytes:
        art_hash = hashlib.sha256(artwork_bytes).hexdigest()
        art_file = cache_dir / f"{art_hash}.jpg"
        if not art_file.exists():
            art_file.write_bytes(artwork_bytes)
        return art_hash

    return None

def extract_metadata(file_path: Path) -> Dict[str, Any]:
    """
    Extract audio tags, duration, bitrate, and embedded artwork.
    """
    stat = file_path.stat()
    file_size = stat.st_size
    mtime = stat.st_mtime
    ext = file_path.suffix.lower()

    meta: Dict[str, Any] = {
        "filename": file_path.name,
        "title": file_path.stem,
        "artist": "Unknown Artist",
        "album": "Unknown Album",
        "genre": "",
        "year": None,
        "duration_seconds": 0.0,
        "bitrate": 0,
        "sample_rate": 0,
        "channels": 2,
        "format": ext.replace(".", "").upper(),
        "file_size_bytes": file_size,
        "artwork_hash": None,
        "last_modified": mtime
    }

    try:
        audio = mutagen.File(str(file_path))
        if audio is not None:
            # Audio info
            if hasattr(audio, "info") and audio.info is not None:
                info = audio.info
                meta["duration_seconds"] = float(getattr(info, "length", 0.0))
                meta["bitrate"] = int(getattr(info, "bitrate", 0))
                meta["sample_rate"] = int(getattr(info, "sample_rate", 0))
                meta["channels"] = int(getattr(info, "channels", 2))

            # Tags
            if hasattr(audio, "tags") and audio.tags is not None:
                tags = audio.tags
                
                # Helper to extract first tag string
                def get_tag_value(keys):
                    for k in keys:
                        if k in tags:
                            val = tags[k]
                            if isinstance(val, (list, tuple)) and len(val) > 0:
                                return str(val[0])
                            return str(val)
                    return None

                title = get_tag_value(["TIT2", "title", "\xa9nam", "TITLE"])
                if title:
                    meta["title"] = title

                artist = get_tag_value(["TPE1", "artist", "\xa9ART", "ARTIST"])
                if artist:
                    meta["artist"] = artist

                album = get_tag_value(["TALB", "album", "\xa9alb", "ALBUM"])
                if album:
                    meta["album"] = album

                genre = get_tag_value(["TCON", "genre", "\xa9gen", "GENRE"])
                if genre:
                    meta["genre"] = genre

                year_str = get_tag_value(["TDRC", "date", "\xa9day", "DATE", "TYER"])
                if year_str:
                    try:
                        meta["year"] = int(str(year_str)[:4])
                    except ValueError:
                        pass

            # Extract artwork into cache directory
            artwork_cache_dir = settings.CACHE_PATH / "artwork"
            artwork_cache_dir.mkdir(parents=True, exist_ok=True)
            meta["artwork_hash"] = extract_artwork(audio, artwork_cache_dir)

    except Exception:
        # In case mutagen fails on a malformed tag, fallback to basic file info
        pass

    return meta

