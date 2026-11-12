import urllib.parse
import uuid
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, Request, Response, Depends, status
from fastapi.responses import StreamingResponse, PlainTextResponse, Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from backend.core.config import settings
from backend.core.database import get_db, User, StagedUpload
from backend.auth.dependencies import authenticate_user, ANONYMOUS_USER
from backend.storage.engine import storage_engine
from backend.storage import diagnostics
from backend.storage.validator import (
    sanitize_filename,
    normalize_virtual_path,
    split_virtual_path
)
from webdav.xml_builder import (
    build_multistatus_response,
    build_virtual_multistatus_response,
    format_rfc1123
)
from backend.core.exceptions import (
    QuotaExceededException,
    NonAudioFileException,
    StorageSecurityException,
    FileNotFoundStorageException,
    DuplicateFileException,
    DirectoryCreationForbiddenException
)

webdav_router = APIRouter()

WEBDAV_ALLOWED_METHODS = "OPTIONS, GET, HEAD, PROPFIND, PUT, DELETE, MOVE, MKCOL"
WEBDAV_HEADERS = {
    "DAV": "1, 2",
    "MS-Author-Via": "DAV",
    "Allow": WEBDAV_ALLOWED_METHODS,
    "Accept-Ranges": "bytes"
}

def verify_user_access(user: Optional[User]) -> Optional[Response]:
    """Helper to verify user is authenticated, active, and has music storage permissions."""
    if not settings.WEBDAV_AUTH_ENABLED and user is None:
        user = ANONYMOUS_USER

    if not user:
        return Response(
            content="Authentication Required",
            status_code=status.HTTP_401_UNAUTHORIZED,
            headers={
                "WWW-Authenticate": 'Basic realm="Mornye Music WebDAV"',
                **WEBDAV_HEADERS
            }
        )
    if not user.is_active or user.role not in ["admin", "music_user"]:
        return Response(
            content="Forbidden: Insufficient permissions for music storage",
            status_code=status.HTTP_403_FORBIDDEN,
            headers=WEBDAV_HEADERS
        )
    return None

@webdav_router.api_route("/dav", methods=["OPTIONS"], include_in_schema=False)
@webdav_router.api_route("/dav/", methods=["OPTIONS"], include_in_schema=False)
@webdav_router.api_route("/dav/{path:path}", methods=["OPTIONS"], include_in_schema=False)
async def dav_options(request: Request):
    """WebDAV capability discovery."""
    return Response(
        status_code=status.HTTP_200_OK,
        headers=WEBDAV_HEADERS
    )

@webdav_router.api_route("/dav", methods=["MKCOL"], include_in_schema=False)
@webdav_router.api_route("/dav/", methods=["MKCOL"], include_in_schema=False)
@webdav_router.api_route("/dav/{path:path}", methods=["MKCOL"], include_in_schema=False)
async def dav_mkcol(request: Request, path: str = "", db: AsyncSession = Depends(get_db)):
    """
    Handle WebDAV MKCOL for virtual collection creation.
    Does NOT create physical directories in storage/. Backed by database metadata.
    RFC 4918 Section 9.3.1: Returns 201 Created on success, 405 if already exists.
    """
    user = await authenticate_user(request, db)
    auth_err = verify_user_access(user)
    if auth_err:
        return auth_err

    clean_path = urllib.parse.unquote(path).strip("/")
    if not clean_path:
        return Response(
            content="Cannot create collection at root",
            status_code=status.HTTP_405_METHOD_NOT_ALLOWED,
            headers=WEBDAV_HEADERS
        )

    try:
        norm_path = normalize_virtual_path(clean_path)
    except StorageSecurityException as e:
        return Response(content=str(e), status_code=status.HTTP_403_FORBIDDEN, headers=WEBDAV_HEADERS)

    try:
        await storage_engine.create_virtual_collection(norm_path, user.username, db)
        return Response(status_code=status.HTTP_201_CREATED, headers=WEBDAV_HEADERS)
    except DuplicateFileException:
        # RFC 4918 Section 9.3.1: MKCOL on an existing mapped URL must return 405
        return Response(
            content="Virtual collection or resource already exists",
            status_code=status.HTTP_405_METHOD_NOT_ALLOWED,
            headers=WEBDAV_HEADERS
        )
    except StorageSecurityException as e:
        return Response(content=str(e), status_code=status.HTTP_403_FORBIDDEN, headers=WEBDAV_HEADERS)

@webdav_router.api_route("/dav", methods=["PROPFIND"], include_in_schema=False)
@webdav_router.api_route("/dav/", methods=["PROPFIND"], include_in_schema=False)
@webdav_router.api_route("/dav/{path:path}", methods=["PROPFIND"], include_in_schema=False)
async def dav_propfind(request: Request, path: str = "", db: AsyncSession = Depends(get_db)):
    """
    Handle WebDAV PROPFIND requests for:
    - Root collection
    - Virtual directories (e.g. /dav/LuisFonsiVEVO/)
    - Virtual audio files (e.g. /dav/LuisFonsiVEVO/Despacito.mp3)
    - Connection probes (.mornye-probe-*)
    RFC 4918: Returns 207 Multi-Status XML or 404 Not Found if resource does not exist.
    """
    user = await authenticate_user(request, db)
    auth_err = verify_user_access(user)
    if auth_err:
        return auth_err

    clean_path = urllib.parse.unquote(path).strip("/")
    depth = request.headers.get("Depth", "1")

    # Check for path traversal or null bytes
    if ".." in clean_path or "\x00" in clean_path:
        return Response(
            content="Forbidden: Subdirectories or traversal detected",
            status_code=status.HTTP_403_FORBIDDEN,
            headers=WEBDAV_HEADERS
        )

    # 1. Handle Mornye Connection Probe PROPFIND
    if storage_engine.is_mornye_probe(clean_path):
        if storage_engine.probe_exists(clean_path):
            probe_bytes = storage_engine.get_probe_bytes(clean_path) or b""
            probe_info = {
                "filename": clean_path,
                "file_size_bytes": len(probe_bytes),
                "last_modified": 0,
                "mime_type": "application/octet-stream",
                "extension": ""
            }
            xml_body = build_multistatus_response([probe_info], base_prefix="/dav/", is_collection_root=False)
            return Response(
                content=xml_body,
                status_code=status.HTTP_207_MULTI_STATUS,
                media_type="application/xml; charset=utf-8",
                headers=WEBDAV_HEADERS
            )
        return Response(content="Probe Not Found", status_code=status.HTTP_404_NOT_FOUND, headers=WEBDAV_HEADERS)

    # 2. Virtual Directory / Collection / File PROPFIND
    try:
        norm_path = normalize_virtual_path(clean_path)
    except StorageSecurityException as e:
        return Response(content=str(e), status_code=status.HTTP_403_FORBIDDEN, headers=WEBDAV_HEADERS)

    result = await storage_engine.list_virtual_collection(norm_path, db, owner_username=user.username)
    if not result:
        return Response(content="Resource Not Found", status_code=status.HTTP_404_NOT_FOUND, headers=WEBDAV_HEADERS)

    if result["is_collection"]:
        if depth == "0":
            xml_body = build_virtual_multistatus_response(
                self_href=result["href"],
                self_displayname=result["displayname"],
                is_collection=True,
                child_collections=[],
                child_files=[]
            )
        else:
            xml_body = build_virtual_multistatus_response(
                self_href=result["href"],
                self_displayname=result["displayname"],
                is_collection=True,
                child_collections=result.get("collections", []),
                child_files=result.get("files", [])
            )
    else:
        xml_body = build_virtual_multistatus_response(
            self_href=result["href"],
            self_displayname=result["displayname"],
            is_collection=False,
            self_file_info=result["file"]
        )

    # Diagnostic logging for PROPFIND
    req_id = uuid.uuid4().hex[:12]
    if result.get("is_collection"):
        cols = [c["name"] for c in result.get("collections", [])]
        files = result.get("files", [])
        diagnostics.record_propfind_event(
            request_id=req_id,
            path=clean_path,
            depth=depth,
            is_collection=True,
            child_collections=cols,
            child_files=files,
            status_code=status.HTTP_207_MULTI_STATUS
        )

    return Response(
        content=xml_body,
        status_code=status.HTTP_207_MULTI_STATUS,
        media_type="application/xml; charset=utf-8",
        headers=WEBDAV_HEADERS
    )

@webdav_router.api_route("/dav", methods=["GET", "HEAD"], include_in_schema=False)
@webdav_router.api_route("/dav/", methods=["GET", "HEAD"], include_in_schema=False)
@webdav_router.api_route("/dav/{path:path}", methods=["GET", "HEAD"], include_in_schema=False)
async def dav_get_head(request: Request, path: str = "", db: AsyncSession = Depends(get_db)):
    """
    Stream audio file or retrieve headers with HTTP byte-range support.
    Resolves virtual path to physical flat storage file.
    """
    user = await authenticate_user(request, db)
    auth_err = verify_user_access(user)
    if auth_err:
        return auth_err

    clean_path = urllib.parse.unquote(path).strip("/")
    if not clean_path:
        return PlainTextResponse("Mornye WebDAV Storage Root (Flat Music Storage)", headers=WEBDAV_HEADERS)

    if ".." in clean_path or "\x00" in clean_path:
        return Response(
            content="Forbidden: Subdirectories or traversal detected",
            status_code=status.HTTP_403_FORBIDDEN,
            headers=WEBDAV_HEADERS
        )

    # 1. Mornye Connection Probe GET / HEAD
    if storage_engine.is_mornye_probe(clean_path):
        content = storage_engine.get_probe_bytes(clean_path)
        if content is not None:
            headers = {
                **WEBDAV_HEADERS,
                "Content-Type": "application/octet-stream",
                "Content-Length": str(len(content))
            }
            if request.method == "HEAD":
                return Response(status_code=status.HTTP_200_OK, headers=headers)
            return Response(content=content, status_code=status.HTTP_200_OK, headers=headers)
        return Response(content="Probe Not Found", status_code=status.HTTP_404_NOT_FOUND, headers=WEBDAV_HEADERS)

    # 2. Staged Part File GET / HEAD
    leaf_name = split_virtual_path(clean_path)[1]
    if storage_engine.is_staged_part_file(leaf_name) or storage_engine.is_staged_part_file(clean_path):
        staged_key = leaf_name if storage_engine.is_staged_part_file(leaf_name) else clean_path
        if await storage_engine.staged_file_exists(staged_key, owner_username=user.username, virtual_path=clean_path, db=db):
            stmt = select(StagedUpload).where(
                StagedUpload.virtual_path == normalize_virtual_path(clean_path),
                StagedUpload.owner_username == user.username
            )
            res = await db.execute(stmt)
            staged_rec = res.scalar_one_or_none()
            if staged_rec:
                staged_file = (storage_engine.staged_path / staged_rec.physical_temp_filename).resolve()
            else:
                staged_file = (storage_engine.staged_path / staged_key).resolve()

            if staged_file.exists():
                headers = {
                    **WEBDAV_HEADERS,
                    "Content-Type": "application/octet-stream",
                    "Content-Length": str(staged_file.stat().st_size)
                }
                if request.method == "HEAD":
                    return Response(status_code=status.HTTP_200_OK, headers=headers)
                return Response(content=staged_file.read_bytes(), status_code=status.HTTP_200_OK, headers=headers)
        return Response(content="Staged File Not Found", status_code=status.HTTP_404_NOT_FOUND, headers=WEBDAV_HEADERS)

    # 3. Virtual Audio File GET / HEAD with Byte-Range Streaming
    try:
        norm_path = normalize_virtual_path(clean_path)
        range_header = request.headers.get("Range")
        chunk_gen, start, end, total, mime, code = await storage_engine.get_virtual_range_stream(norm_path, range_header, db)

        content_length = (end - start) + 1
        headers = {
            **WEBDAV_HEADERS,
            "Content-Type": mime,
            "Content-Length": str(content_length),
            "Accept-Ranges": "bytes",
        }

        if code == 206:
            headers["Content-Range"] = f"bytes {start}-{end}/{total}"

        if request.method == "HEAD":
            return Response(status_code=code, headers=headers)

        return StreamingResponse(
            chunk_gen,
            status_code=code,
            headers=headers,
            media_type=mime
        )
    except FileNotFoundStorageException:
        return Response(content="File Not Found", status_code=status.HTTP_404_NOT_FOUND, headers=WEBDAV_HEADERS)
    except StorageSecurityException as e:
        return Response(content=str(e), status_code=status.HTTP_403_FORBIDDEN, headers=WEBDAV_HEADERS)

@webdav_router.api_route("/dav/{path:path}", methods=["PUT"], include_in_schema=False)
async def dav_put(request: Request, path: str, db: AsyncSession = Depends(get_db)):
    """
    Upload an audio file or handle Mornye staged / probe uploads via WebDAV.
    Supports virtual directory hierarchy while keeping storage flat.
    Enforces:
    - 100 GB music storage quota.
    - Valid audio binary signatures (magic bytes).
    - No actual subdirectories on disk.
    """
    user = await authenticate_user(request, db)
    auth_err = verify_user_access(user)
    if auth_err:
        return auth_err

    clean_path = urllib.parse.unquote(path).strip("/")
    if not clean_path:
        return Response(content="Cannot PUT to root collection", status_code=status.HTTP_405_METHOD_NOT_ALLOWED, headers=WEBDAV_HEADERS)

    if ".." in clean_path or "\x00" in clean_path:
        return Response(
            content="Directory traversal is prohibited",
            status_code=status.HTTP_403_FORBIDDEN,
            headers=WEBDAV_HEADERS
        )

    content_length_hdr = request.headers.get("Content-Length")
    expected_size = int(content_length_hdr) if content_length_hdr and content_length_hdr.isdigit() else None

    async def body_stream():
        async for chunk in request.stream():
            yield chunk

    # 1. Mornye Connection Probe (.mornye-probe-<hash>)
    if storage_engine.is_mornye_probe(clean_path):
        stats = storage_engine.get_storage_stats()
        if stats["remaining_quota_bytes"] <= 0:
            return Response(
                content="Storage quota exceeded: 100 GB music storage limit reached",
                status_code=status.HTTP_507_INSUFFICIENT_STORAGE,
                headers=WEBDAV_HEADERS
            )
        probe_content = await request.body()
        storage_engine.write_probe(clean_path, probe_content)
        return Response(status_code=status.HTTP_201_CREATED, headers=WEBDAV_HEADERS)

    # 2. Mornye Staged Part File (.<audio>.part)
    leaf_name = split_virtual_path(clean_path)[1]
    if storage_engine.is_staged_part_file(leaf_name):
        req_id = uuid.uuid4().hex[:12]
        client_ip = request.client.host if request.client else "unknown"
        diagnostics.record_upload_start(
            request_id=req_id,
            method="PUT",
            path=clean_path,
            content_length=expected_size,
            transfer_encoding=request.headers.get("Transfer-Encoding"),
            client_ip=client_ip
        )
        try:
            bytes_written, sha256_hash, staged_file = await storage_engine.write_staged_stream(
                filename=leaf_name,
                stream_chunks=body_stream(),
                expected_size=expected_size,
                owner_username=user.username,
                virtual_path=clean_path,
                db=db
            )
            diagnostics.record_upload_complete(
                request_id=req_id,
                path=clean_path,
                staged_filename=leaf_name,
                file_path=staged_file,
                bytes_written=bytes_written,
                expected_size=expected_size,
                sha256_checksum=sha256_hash,
                response_status=status.HTTP_201_CREATED
            )
            return Response(status_code=status.HTTP_201_CREATED, headers=WEBDAV_HEADERS)
        except QuotaExceededException as e:
            diagnostics.record_upload_failed(req_id, clean_path, str(e), 0, status.HTTP_507_INSUFFICIENT_STORAGE)
            return Response(content=str(e), status_code=status.HTTP_507_INSUFFICIENT_STORAGE, headers=WEBDAV_HEADERS)
        except StorageSecurityException as e:
            diagnostics.record_upload_failed(req_id, clean_path, str(e), 0, status.HTTP_403_FORBIDDEN)
            return Response(content=str(e), status_code=status.HTTP_403_FORBIDDEN, headers=WEBDAV_HEADERS)
        except Exception as e:
            diagnostics.record_upload_failed(req_id, clean_path, str(e), 0, status.HTTP_500_INTERNAL_SERVER_ERROR)
            return Response(content=f"Upload failed: {str(e)}", status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, headers=WEBDAV_HEADERS)

    # 3. Direct Audio File Upload to Virtual Path
    try:
        await storage_engine.write_virtual_audio_stream(
            virtual_path=clean_path,
            stream_chunks=body_stream(),
            owner_username=user.username,
            db=db,
            expected_size=expected_size,
            overwrite=True
        )
        return Response(status_code=status.HTTP_201_CREATED, headers=WEBDAV_HEADERS)
    except QuotaExceededException as e:
        return Response(content=str(e), status_code=status.HTTP_507_INSUFFICIENT_STORAGE, headers=WEBDAV_HEADERS)
    except NonAudioFileException as e:
        return Response(content=str(e), status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, headers=WEBDAV_HEADERS)
    except StorageSecurityException as e:
        return Response(content=str(e), status_code=status.HTTP_403_FORBIDDEN, headers=WEBDAV_HEADERS)
    except Exception as e:
        return Response(content=f"Upload failed: {str(e)}", status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, headers=WEBDAV_HEADERS)

@webdav_router.api_route("/dav/{path:path}", methods=["DELETE"], include_in_schema=False)
async def dav_delete(request: Request, path: str, db: AsyncSession = Depends(get_db)):
    """
    Handle WebDAV DELETE:
    - Connection probes -> deleted immediately.
    - Staged .part files -> deleted immediately.
    - Active music files -> SOFT DELETE into Recycle Bin!
      File is moved to database/recycle_bin/, disappearing from active music library.
    """
    user = await authenticate_user(request, db)
    auth_err = verify_user_access(user)
    if auth_err:
        return auth_err

    clean_path = urllib.parse.unquote(path).strip("/")
    if not clean_path:
        return Response(content="Cannot DELETE storage root", status_code=status.HTTP_405_METHOD_NOT_ALLOWED, headers=WEBDAV_HEADERS)

    if ".." in clean_path or "\x00" in clean_path:
        return Response(
            content="Forbidden: Subdirectories or traversal detected",
            status_code=status.HTTP_403_FORBIDDEN,
            headers=WEBDAV_HEADERS
        )

    # 1. Mornye Connection Probe deletion
    if storage_engine.is_mornye_probe(clean_path):
        storage_engine.delete_probe(clean_path)
        return Response(status_code=status.HTTP_204_NO_CONTENT, headers=WEBDAV_HEADERS)

    # 2. Staged Part File deletion
    leaf_name = split_virtual_path(clean_path)[1]
    if storage_engine.is_staged_part_file(leaf_name):
        req_id = uuid.uuid4().hex[:12]
        deleted, size_bytes, checksum = await storage_engine.delete_staged_file(
            filename=leaf_name,
            owner_username=user.username,
            virtual_path=clean_path,
            db=db
        )
        diagnostics.record_delete_staged(
            request_id=req_id,
            path=clean_path,
            staged_filename=leaf_name,
            file_path=storage_engine.staged_path / leaf_name,
            existed_before_delete=deleted,
            file_size_before_delete=size_bytes,
            sha256_before_delete=checksum
        )
        return Response(status_code=status.HTTP_204_NO_CONTENT, headers=WEBDAV_HEADERS)
        return Response(status_code=status.HTTP_204_NO_CONTENT, headers=WEBDAV_HEADERS)

    # 3. Soft Delete Active Music File into Recycle Bin
    try:
        await storage_engine.soft_delete_file(clean_path, user.username, db)
        return Response(status_code=status.HTTP_204_NO_CONTENT, headers=WEBDAV_HEADERS)
    except FileNotFoundStorageException:
        return Response(content="File Not Found", status_code=status.HTTP_404_NOT_FOUND, headers=WEBDAV_HEADERS)
    except StorageSecurityException as e:
        return Response(content=str(e), status_code=status.HTTP_403_FORBIDDEN, headers=WEBDAV_HEADERS)

@webdav_router.api_route("/dav/{path:path}", methods=["MOVE"], include_in_schema=False)
async def dav_move(request: Request, path: str, db: AsyncSession = Depends(get_db)):
    """
    Handle WebDAV MOVE for:
    1. Publishing Mornye staged transfers (MOVE .<name>.part -> <name>) per RFC 4918 Section 9.9.3.
    2. Virtual file renaming and re-parenting.
    Strictly adheres to Overwrite header (F -> 412 Precondition Failed if destination exists).
    """
    user = await authenticate_user(request, db)
    auth_err = verify_user_access(user)
    if auth_err:
        return auth_err

    destination = request.headers.get("Destination")
    if not destination:
        return Response(content="Missing Destination header", status_code=status.HTTP_400_BAD_REQUEST, headers=WEBDAV_HEADERS)

    parsed_dest = urllib.parse.urlparse(destination)
    dest_path = urllib.parse.unquote(parsed_dest.path)

    # Normalize destination path
    if dest_path.startswith("/dav/"):
        dest_virtual = "/" + dest_path[5:].lstrip("/")
    elif dest_path.startswith("/dav"):
        dest_virtual = "/" + dest_path[4:].lstrip("/")
    else:
        dest_virtual = "/" + dest_path.lstrip("/")

    if ".." in dest_virtual or "\x00" in dest_virtual:
        return Response(
            content="Destination traversal is prohibited",
            status_code=status.HTTP_403_FORBIDDEN,
            headers=WEBDAV_HEADERS
        )

    overwrite_hdr = request.headers.get("Overwrite", "T").upper()
    overwrite = (overwrite_hdr != "F")

    source_path = urllib.parse.unquote(path).strip("/")
    if ".." in source_path or "\x00" in source_path:
        return Response(
            content="Source traversal detected",
            status_code=status.HTTP_403_FORBIDDEN,
            headers=WEBDAV_HEADERS
        )

    leaf_source = split_virtual_path(source_path)[1]

    # Case A: Source is a staged part file (Mornye staged transfer publishing)
    if storage_engine.is_staged_part_file(leaf_source):
        staged_key = leaf_source
        if not await storage_engine.staged_file_exists(staged_key, owner_username=user.username, virtual_path=source_path, db=db):
            return Response(content="Staged file not found", status_code=status.HTTP_404_NOT_FOUND, headers=WEBDAV_HEADERS)

        # Check if destination exists
        dest_norm = normalize_virtual_path(dest_virtual)
        dest_info = await storage_engine.list_virtual_collection(dest_norm, db, owner_username=user.username)
        if dest_info and not overwrite:
            return Response(
                content="Precondition Failed: Destination already exists and Overwrite is F",
                status_code=status.HTTP_412_PRECONDITION_FAILED,
                headers=WEBDAV_HEADERS
            )

        try:
            await storage_engine.commit_virtual_staged_file(
                staged_filename=staged_key,
                dest_virtual_path=dest_virtual,
                owner_username=user.username,
                db=db,
                source_virtual_path=source_path,
                overwrite=overwrite
            )
            status_code = status.HTTP_204_NO_CONTENT if dest_info else status.HTTP_201_CREATED
            diagnostics.record_move_event(
                request_id=uuid.uuid4().hex[:12],
                source_path=source_path,
                dest_path=dest_virtual,
                overwrite=overwrite,
                status_code=status_code,
                details=f"Committed staged transfer {staged_key} to {dest_virtual}"
            )
            return Response(status_code=status_code, headers=WEBDAV_HEADERS)
        except DuplicateFileException:
            return Response(
                content="Precondition Failed: Destination already exists and Overwrite is F",
                status_code=status.HTTP_412_PRECONDITION_FAILED,
                headers=WEBDAV_HEADERS
            )
        except (QuotaExceededException, NonAudioFileException, StorageSecurityException) as e:
            diagnostics.record_move_event(
                request_id=uuid.uuid4().hex[:12],
                source_path=source_path,
                dest_path=dest_virtual,
                overwrite=overwrite,
                status_code=e.status_code,
                details=f"MOVE failed: {str(e)}"
            )
            return Response(content=str(e), status_code=e.status_code, headers=WEBDAV_HEADERS)

    # Case B: Standard virtual file rename / move
    try:
        norm_src = normalize_virtual_path(source_path)
        norm_dest = normalize_virtual_path(dest_virtual)

        dest_info = await storage_engine.list_virtual_collection(norm_dest, db)
        if dest_info and not overwrite:
            return Response(
                content="Precondition Failed: Destination already exists and Overwrite is F",
                status_code=status.HTTP_412_PRECONDITION_FAILED,
                headers=WEBDAV_HEADERS
            )

        # Update in database
        stmt = select(MusicFile).where(MusicFile.virtual_path == norm_src)
        res = await db.execute(stmt)
        record = res.scalar_one_or_none()
        if not record:
            return Response(content="Source File Not Found", status_code=status.HTTP_404_NOT_FOUND, headers=WEBDAV_HEADERS)

        new_parent, new_leaf = split_virtual_path(norm_dest)
        sanitize_filename(new_leaf)

        if new_parent != "/":
            await storage_engine.ensure_virtual_collection_exists(new_parent, user.username, db)

        record.virtual_path = norm_dest
        record.virtual_filename = new_leaf
        record.virtual_parent_dir = new_parent
        await db.commit()

        status_code = status.HTTP_204_NO_CONTENT if dest_info else status.HTTP_201_CREATED
        return Response(status_code=status_code, headers=WEBDAV_HEADERS)
    except (FileNotFoundStorageException, DuplicateFileException, StorageSecurityException, NonAudioFileException) as e:
        return Response(content=str(e), status_code=e.status_code, headers=WEBDAV_HEADERS)

@webdav_router.api_route("/dav/{path:path}", methods=["COPY"], include_in_schema=False)
async def dav_copy(request: Request):
    """COPY is rejected."""
    return Response(
        content="COPY method is not supported.",
        status_code=status.HTTP_405_METHOD_NOT_ALLOWED,
        headers=WEBDAV_HEADERS
    )
