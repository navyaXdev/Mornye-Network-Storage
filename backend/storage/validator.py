import os
import re
import hashlib
import mimetypes
from pathlib import Path
from typing import Tuple, Optional
from backend.core.exceptions import NonAudioFileException, StorageSecurityException

# Supported audio extensions (lowercase)
SUPPORTED_AUDIO_EXTENSIONS = {
    ".mp3",
    ".flac",
    ".wav",
    ".m4a",
    ".aac",
    ".ogg",
    ".opus",
    ".wma",
    ".aiff",
    ".aif",
    ".alac"
}

# Standard MIME type mappings
AUDIO_MIME_TYPES = {
    ".mp3": "audio/mpeg",
    ".flac": "audio/flac",
    ".wav": "audio/wav",
    ".m4a": "audio/mp4",
    ".aac": "audio/aac",
    ".ogg": "audio/ogg",
    ".opus": "audio/opus",
    ".wma": "audio/x-ms-wma",
    ".aiff": "audio/aiff",
    ".aif": "audio/aiff",
    ".alac": "audio/mp4"
}

# Dangerous non-audio magic signatures to explicitly blacklist
DISALLOWED_SIGNATURES = [
    (0, b"MZ", "Windows Executable/DLL"),
    (0, b"\x7fELF", "Linux ELF Executable"),
    (0, b"PK\x03\x04", "ZIP / Archive / Office Document"),
    (0, b"PK\x05\x06", "Empty ZIP Archive"),
    (0, b"Rar!\x1a\x07", "RAR Archive"),
    (0, b"7z\xbc\xaf\x27\x1c", "7-Zip Archive"),
    (0, b"\x1f\x8b", "GZIP Archive"),
    (0, b"BZh", "BZIP2 Archive"),
    (0, b"%PDF", "PDF Document"),
    (0, b"\x89PNG\r\n\x1a\n", "PNG Image"),
    (0, b"\xff\xd8\xff", "JPEG Image"),
    (0, b"GIF87a", "GIF Image"),
    (0, b"GIF89a", "GIF Image"),
    (0, b"\x1a\x45\xdf\xa3", "Matroska / MKV / WebM Video"),
    (0, b"#!\x2f", "Shell / Bash Script"),
    (0, b"<?php", "PHP Script"),
    (0, b"<html", "HTML Document"),
    (0, b"<!DOCTYPE", "HTML Document"),
    (0, b"<svg", "SVG Image Document"),
]

def get_mime_type_for_filename(filename: str) -> str:
    ext = Path(filename).suffix.lower()
    return AUDIO_MIME_TYPES.get(ext, "application/octet-stream")

def sanitize_filename(filename: str) -> str:
    """
    Sanitize and validate an audio filename.
    Rejects paths containing directories, slashes, backslashes, path traversal, or null bytes.
    Ensures storage stays strictly flat.
    """
    if not filename:
        raise StorageSecurityException("Filename cannot be empty")
    
    # Check for path traversal or directory separators
    if "/" in filename or "\\" in filename or ".." in filename or "\x00" in filename:
        raise StorageSecurityException(f"Invalid filename '{filename}': Directory separators and traversal are forbidden")
    
    # Strip any leading/trailing whitespace or dots
    clean_name = filename.strip()
    if clean_name.startswith("."):
        raise StorageSecurityException("Hidden files (starting with dot) are forbidden in storage")
    
    # Validate extension
    ext = Path(clean_name).suffix.lower()
    if ext not in SUPPORTED_AUDIO_EXTENSIONS:
        raise NonAudioFileException(f"Extension '{ext}' is not a supported audio format. Allowed: {sorted(list(SUPPORTED_AUDIO_EXTENSIONS))}")
    
    return clean_name

def inspect_audio_signature(file_path: Path) -> Tuple[bool, str, str]:
    """
    Inspect the binary header / magic bytes of a file to confirm it is a valid audio file.
    Returns: (is_valid, detected_format, detected_mime)
    """
    if not file_path.exists() or file_path.stat().st_size == 0:
        raise NonAudioFileException("File is empty or does not exist")
    
    file_size = file_path.stat().st_size
    read_size = min(4096, file_size)
    
    with open(file_path, "rb") as f:
        header = f.read(read_size)
    
    # Check for blacklisted signatures
    for offset, sig, desc in DISALLOWED_SIGNATURES:
        if len(header) >= offset + len(sig):
            if header[offset:offset+len(sig)] == sig:
                raise NonAudioFileException(f"Upload rejected: detected forbidden file type ({desc})")

    # Check for RIFF AVI Video vs RIFF WAVE Audio
    if header.startswith(b"RIFF") and len(header) >= 12:
        riff_type = header[8:12]
        if riff_type == b"WAVE":
            return True, "WAV", "audio/wav"
        elif riff_type == b"AVI ":
            raise NonAudioFileException("Upload rejected: detected AVI Video file, not audio")
        elif riff_type == b"WEBP":
            raise NonAudioFileException("Upload rejected: detected WEBP Image file, not audio")
        else:
            raise NonAudioFileException(f"Upload rejected: unsupported RIFF container ({riff_type.decode('latin1', errors='ignore')})")

    # Check FLAC (starts with 'fLaC')
    if header.startswith(b"fLaC"):
        return True, "FLAC", "audio/flac"

    # Check MP3: ID3v2 tag (starts with 'ID3')
    if header.startswith(b"ID3"):
        return True, "MP3", "audio/mpeg"

    # Check MP3: MPEG sync frame (starts with 0xFF followed by 0xE0-0xFF)
    if len(header) >= 2 and header[0] == 0xFF and (header[1] & 0xE0) == 0xE0:
        # MPEG audio sync word
        layer = (header[1] >> 1) & 0x03
        if layer != 0: # Layer I, II, or III (Layer III is MP3)
            return True, "MP3", "audio/mpeg"

    # Check OGG / OPUS (starts with 'OggS')
    if header.startswith(b"OggS"):
        # Check if Opus or Vorbis
        if b"OpusHead" in header:
            return True, "OPUS", "audio/opus"
        return True, "OGG", "audio/ogg"

    # Check MP4 / M4A / AAC / ALAC (ISO Base Media container)
    if len(header) >= 12 and header[4:8] == b"ftyp":
        brand = header[8:12]
        # Common audio brands: M4A , M4B , isom, mp42, dash
        # We also inspect if it contains audio tracks via mutagen or standard brands
        if brand in [b"M4A ", b"M4B ", b"alac", b"mp42", b"isom", b"dash"]:
            return True, "M4A", "audio/mp4"

    # Check Raw AAC ADTS (starts with 0xFF and 0xF0-0xF9)
    if len(header) >= 2 and header[0] == 0xFF and (header[1] & 0xF6) == 0xF0:
        return True, "AAC", "audio/aac"

    # Check WMA / ASF (starts with ASF GUID)
    asf_guid = b"\x30\x26\xb2\x75\x8e\x66\xcf\x11"
    if header.startswith(asf_guid):
        return True, "WMA", "audio/x-ms-wma"

    # Check AIFF (starts with 'FORM' and has 'AIFF' or 'AIFC' at offset 8)
    if header.startswith(b"FORM") and len(header) >= 12:
        form_type = header[8:12]
        if form_type in [b"AIFF", b"AIFC"]:
            return True, "AIFF", "audio/aiff"

    # If magic header is not explicitly matched, attempt Mutagen inspection as fallback
    try:
        import mutagen
        audio = mutagen.File(str(file_path))
        if audio is not None and hasattr(audio, "info") and audio.info is not None:
            # Verified valid audio file
            ext = file_path.suffix.lower()
            mime = AUDIO_MIME_TYPES.get(ext, "audio/mpeg")
            return True, ext.replace(".", "").upper(), mime
    except Exception:
        pass

    raise NonAudioFileException(
        "Upload rejected: Binary signature verification failed. File does not contain legitimate audio headers."
    )

def is_mornye_probe_filename(filename: str) -> bool:
    """
    Check if a filename is a temporary Mornye connection write/delete probe.
    Pattern: .mornye-probe-<hash/token>
    """
    if not filename:
        return False
    clean = filename.strip()
    return bool(re.match(r"^\.mornye-probe-[a-zA-Z0-9_\-]+$", clean))

def is_staged_part_filename(filename: str) -> bool:
    """
    Check if a filename is an in-flight staged part file for Mornye transfers.
    Matches:
    - .mornye-<hex/token>.part or mornye-<hex/token>.part (Mornye hash-based staging)
    - .<audio_name>.part or <audio_name>.part (Audio extension based staging)
    """
    if not filename:
        return False
    clean = filename.strip()
    if not clean.endswith(".part"):
        return False
    
    # 1. Mornye hash-based staging: .mornye-<token>.part
    if re.match(r"^\.?mornye-[a-zA-Z0-9_\-]+\.part$", clean):
        return True

    # 2. Audio extension based staging: .<name>.<ext>.part
    target = clean[:-5].lstrip(".")
    if not target or "/" in target or "\\" in target or ".." in target or "\x00" in target:
        return False
    ext = Path(target).suffix.lower()
    return ext in SUPPORTED_AUDIO_EXTENSIONS

def compute_sha256(file_path: Path) -> str:
    """Compute SHA-256 checksum of a file in 64 KB streaming chunks."""
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()

def normalize_virtual_path(path: str) -> str:
    """
    Normalize and validate a virtual WebDAV path.
    Rejects directory traversal (..), null bytes (\x00), and malformed segments.
    Always returns leading slash, e.g. '/LuisFonsiVEVO/Despacito.mp3' or '/'.
    """
    if not path:
        return "/"
    
    clean = path.replace("\\", "/").strip()
    if "\x00" in clean:
        raise StorageSecurityException("Null bytes are forbidden in virtual paths")
    
    raw_parts = [p.strip() for p in clean.split("/") if p.strip()]
    safe_parts = []
    for part in raw_parts:
        if part == "..":
            raise StorageSecurityException(f"Path traversal detected in virtual path: '{path}'")
        if part == ".":
            continue
        if "\x00" in part or "\\" in part:
            raise StorageSecurityException(f"Invalid characters in virtual path: '{part}'")
        safe_parts.append(part)
        
    if not safe_parts:
        return "/"
        
    return "/" + "/".join(safe_parts)

def split_virtual_path(normalized_path: str) -> Tuple[str, str]:
    """
    Split normalized virtual path into (parent_virtual_dir, leaf_name).
    e.g. '/LuisFonsiVEVO/song.mp3' -> ('/LuisFonsiVEVO', 'song.mp3')
    e.g. '/LuisFonsiVEVO' -> ('/', 'LuisFonsiVEVO')
    e.g. '/' -> ('/', '')
    """
    norm = normalize_virtual_path(normalized_path)
    if norm == "/":
        return "/", ""
    parts = norm.strip("/").split("/")
    leaf = parts[-1]
    if len(parts) == 1:
        return "/", leaf
    parent = "/" + "/".join(parts[:-1])
    return parent, leaf

def generate_flat_physical_filename(virtual_path: str) -> str:
    """
    Generate a safe, flat filename to store inside /home/spidyno/.song/storage/.
    The storage directory NEVER contains folders. All virtual hierarchy is flattened.
    e.g. '/song.mp3' -> 'song.mp3'
    e.g. '/LuisFonsiVEVO/Despacito.mp3' -> 'LuisFonsiVEVO__Despacito.mp3'
    e.g. '/Artist/Album/Track.flac' -> 'Artist__Album__Track.flac'
    """
    norm = normalize_virtual_path(virtual_path)
    parts = norm.strip("/").split("/")
    if not parts or parts == [""]:
        raise StorageSecurityException("Cannot generate physical filename for root path")
    
    sanitized_parts = []
    for p in parts:
        clean_part = re.sub(r'[^\w\s\.\-]', '_', p).strip()
        if not clean_part:
            clean_part = "unnamed"
        sanitized_parts.append(clean_part)
        
    flat_name = "__".join(sanitized_parts)
    flat_name = flat_name.lstrip(".")
    if not flat_name:
        flat_name = "audio.mp3"
        
    return flat_name


