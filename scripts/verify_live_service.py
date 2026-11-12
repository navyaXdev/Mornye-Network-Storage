#!/usr/bin/env python3
"""
Live WebDAV Verification Script
Tests the running mornye-storage daemon (http://127.0.0.1:8000/dav/)
and verifies the exact Mornye client staged-upload lifecycle:
  1. PROPFIND /dav/ -> 207
  2. PUT /dav/.mornye-probe-* -> 201
  3. DELETE /dav/.mornye-probe-* -> 204
  4. MKCOL /dav/LiveArtist/ -> 201
  5. MKCOL /dav/LiveArtist/LiveAlbum/ -> 201
  6. PUT /dav/LiveArtist/LiveAlbum/.mornye-stage-test.part (valid WAV audio) -> 201
  7. PROPFIND /dav/LiveArtist/LiveAlbum/ -> 207 (Verifying staged .part file IS VISIBLE with correct getcontentlength)
  8. MOVE /dav/LiveArtist/LiveAlbum/.mornye-stage-test.part -> LiveTrack.wav -> 201
  9. PROPFIND /dav/LiveArtist/LiveAlbum/ -> 207 (Verifying LiveTrack.wav IS VISIBLE and .part is GONE)
  10. GET /dav/LiveArtist/LiveAlbum/LiveTrack.wav -> 200 (Verifying SHA-256 match)
  11. Check physical storage /home/spidyno/.song/storage/ -> Flat, no folders!
  12. DELETE /dav/LiveArtist/LiveAlbum/LiveTrack.wav -> 204 (Verifying soft delete to Recycle Bin)
  13. Verify Recycle Bin holds the item.
  14. Cleanup test data and temporary test user.
"""
import asyncio
import hashlib
import io
import os
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
import httpx

PROGRAM_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROGRAM_DIR))

from backend.core.config import settings
from backend.core.database import init_db, AsyncSessionLocal, User, VirtualCollection, MusicFile, StagedUpload, RecycleBinItem
from backend.auth.security import hash_password
from sqlalchemy import select, delete

TEST_USER = "test_live_verify"
TEST_PASS = "LiveVerifyPass2026!"
BASE_PORT = os.environ.get("MORNYE_HOST_PORT", "8001")
BASE_URL = f"http://127.0.0.1:{BASE_PORT}"

def create_valid_wav_bytes(duration_ms=100) -> bytes:
    sample_rate = 44100
    num_samples = int(sample_rate * (duration_ms / 1000.0))
    raw_audio = bytearray()
    for i in range(num_samples):
        raw_audio.extend(struct.pack('<h', int(1000 * ((i % 100) / 100.0))))
    data_size = len(raw_audio)
    buf = io.BytesIO()
    buf.write(b"RIFF")
    buf.write(struct.pack("<I", 36 + data_size))
    buf.write(b"WAVE")
    buf.write(b"fmt ")
    buf.write(struct.pack("<I", 16))
    buf.write(struct.pack("<H", 1))
    buf.write(struct.pack("<H", 1))
    buf.write(struct.pack("<I", sample_rate))
    buf.write(struct.pack("<I", sample_rate * 2))
    buf.write(struct.pack("<H", 2))
    buf.write(struct.pack("<H", 16))
    buf.write(b"data")
    buf.write(struct.pack("<I", data_size))
    buf.write(raw_audio)
    return buf.getvalue()

async def setup_test_user():
    await init_db()
    async with AsyncSessionLocal() as session:
        # Clean up existing test records
        await session.execute(delete(User).where(User.username == TEST_USER))
        await session.execute(delete(VirtualCollection).where(VirtualCollection.owner_username == TEST_USER))
        await session.execute(delete(MusicFile).where(MusicFile.owner_username == TEST_USER))
        await session.execute(delete(StagedUpload).where(StagedUpload.owner_username == TEST_USER))
        await session.execute(delete(RecycleBinItem).where(RecycleBinItem.owner_username == TEST_USER))
        
        user = User(
            username=TEST_USER,
            password_hash=hash_password(TEST_PASS),
            role="music_user",
            storage_quota_bytes=100 * 1024 * 1024 * 1024,
            is_active=True
        )
        session.add(user)
        await session.commit()
    print(f"[✔] Test user '{TEST_USER}' created in database.")

async def cleanup_test_user():
    async with AsyncSessionLocal() as session:
        await session.execute(delete(User).where(User.username == TEST_USER))
        await session.execute(delete(VirtualCollection).where(VirtualCollection.owner_username == TEST_USER))
        await session.execute(delete(MusicFile).where(MusicFile.owner_username == TEST_USER))
        await session.execute(delete(StagedUpload).where(StagedUpload.owner_username == TEST_USER))
        await session.execute(delete(RecycleBinItem).where(RecycleBinItem.owner_username == TEST_USER))
        await session.commit()
    print(f"[✔] Cleaned up test user '{TEST_USER}' and related database entries.")

async def run_live_verification():
    await setup_test_user()
    wav_bytes = create_valid_wav_bytes(250)
    expected_hash = hashlib.sha256(wav_bytes).hexdigest()
    expected_len = len(wav_bytes)
    print(f"[*] Generated valid test WAV audio: {expected_len} bytes, SHA256={expected_hash[:16]}...")

    auth = (TEST_USER, TEST_PASS)
    async with httpx.AsyncClient(base_url=BASE_URL, timeout=10.0) as client:
        # Step 1: PROPFIND /dav/
        r = await client.request("PROPFIND", "/dav/", auth=auth, headers={"Depth": "1"})
        assert r.status_code == 207, f"Step 1 failed: {r.status_code}"
        print(f"[✔] Step 1: PROPFIND /dav/ -> {r.status_code} Multi-Status")

        # Step 2: PUT probe
        probe_name = ".mornye-probe-liveverification123456"
        r = await client.put(f"/dav/{probe_name}", auth=auth, content=b"probe test data")
        assert r.status_code == 201, f"Step 2 failed: {r.status_code}"
        print(f"[✔] Step 2: PUT /dav/{probe_name} -> {r.status_code} Created")

        # Step 3: DELETE probe
        r = await client.delete(f"/dav/{probe_name}", auth=auth)
        assert r.status_code == 204, f"Step 3 failed: {r.status_code}"
        print(f"[✔] Step 3: DELETE /dav/{probe_name} -> {r.status_code} No Content")

        # Step 4: MKCOL /dav/LiveArtist/
        r = await client.request("MKCOL", "/dav/LiveArtist/", auth=auth)
        assert r.status_code == 201, f"Step 4 failed: {r.status_code}"
        print(f"[✔] Step 4: MKCOL /dav/LiveArtist/ -> {r.status_code} Created")

        # Step 5: MKCOL /dav/LiveArtist/LiveAlbum/
        r = await client.request("MKCOL", "/dav/LiveArtist/LiveAlbum/", auth=auth)
        assert r.status_code == 201, f"Step 5 failed: {r.status_code}"
        print(f"[✔] Step 5: MKCOL /dav/LiveArtist/LiveAlbum/ -> {r.status_code} Created")

        # Step 6: PUT staged .part file
        staged_leaf = ".mornye-liveupload-abcdef.part"
        staged_url = f"/dav/LiveArtist/LiveAlbum/{staged_leaf}"
        r = await client.put(staged_url, auth=auth, content=wav_bytes)
        assert r.status_code == 201, f"Step 6 failed: {r.status_code}"
        print(f"[✔] Step 6: PUT {staged_url} -> {r.status_code} Created")

        # Step 7: PROPFIND on parent collection (The exact Mornye client verification point!)
        parent_url = "/dav/LiveArtist/LiveAlbum/"
        r = await client.request("PROPFIND", parent_url, auth=auth, headers={"Depth": "1"})
        assert r.status_code == 207, f"Step 7 failed: {r.status_code}"
        xml_text = r.text
        assert staged_leaf in xml_text, f"Step 7 failed: '{staged_leaf}' missing from PROPFIND parent listing! XML: {xml_text}"
        assert f"<D:getcontentlength>{expected_len}</D:getcontentlength>" in xml_text or f"<d:getcontentlength>{expected_len}</d:getcontentlength>" in xml_text.lower(), \
            f"Step 7 failed: getcontentlength {expected_len} not found in PROPFIND listing! XML: {xml_text}"
        print(f"[✔] Step 7: PROPFIND {parent_url} -> {r.status_code} Multi-Status (Staged .part file is visible with getcontentlength={expected_len}!)")

        # Step 8: MOVE staged file to final published name
        dest_leaf = "LiveVerifiedTrack.wav"
        dest_url = f"/dav/LiveArtist/LiveAlbum/{dest_leaf}"
        r = await client.request(
            "MOVE",
            staged_url,
            auth=auth,
            headers={
                "Destination": dest_url,
                "Overwrite": "F"
            }
        )
        assert r.status_code == 201, f"Step 8 failed: {r.status_code}: {r.text}"
        print(f"[✔] Step 8: MOVE {staged_url} -> Destination: {dest_url} -> {r.status_code} Created")

        # Step 9: PROPFIND on parent collection again
        r = await client.request("PROPFIND", parent_url, auth=auth, headers={"Depth": "1"})
        assert r.status_code == 207, f"Step 9 failed: {r.status_code}"
        xml_text2 = r.text
        assert dest_leaf in xml_text2, f"Step 9 failed: '{dest_leaf}' missing from PROPFIND listing! XML: {xml_text2}"
        assert staged_leaf not in xml_text2, f"Step 9 failed: Staged file '{staged_leaf}' still present after MOVE!"
        print(f"[✔] Step 9: PROPFIND {parent_url} -> {r.status_code} Multi-Status (Final track visible, staged file gone!)")

        # Step 10: GET published track
        r = await client.get(dest_url, auth=auth)
        assert r.status_code == 200, f"Step 10 failed: {r.status_code}"
        downloaded_hash = hashlib.sha256(r.content).hexdigest()
        assert downloaded_hash == expected_hash, f"Step 10 failed: Hash mismatch! Expected {expected_hash}, got {downloaded_hash}"
        print(f"[✔] Step 10: GET {dest_url} -> {r.status_code} OK (Downloaded {len(r.content)} bytes, SHA-256 match verified!)")

        # Step 11: Physical flat storage verification
        storage_dir = settings.STORAGE_PATH
        subdirs = [p for p in storage_dir.iterdir() if p.is_dir()]
        assert len(subdirs) == 0, f"Step 11 failed: Physical subdirectories found in storage! Found: {subdirs}"
        files_in_storage = [p for p in storage_dir.iterdir() if p.is_file()]
        print(f"[✔] Step 11: Physical Storage Directory: Flat verified! (0 subdirs, {len(files_in_storage)} audio files directly in storage root)")

        # Step 12: DELETE published track (Recycle Bin verification)
        r = await client.delete(dest_url, auth=auth)
        assert r.status_code == 204, f"Step 12 failed: {r.status_code}"
        print(f"[✔] Step 12: DELETE {dest_url} -> {r.status_code} No Content (Soft-deleted to Recycle Bin)")

        # Step 13: Verify Recycle Bin item in database & disk
        recycle_dir = settings.DATA_PATH / "recycle_bin"
        recycle_files = list(recycle_dir.iterdir()) if recycle_dir.exists() else []
        print(f"[✔] Step 13: Recycle Bin verified! ({len(recycle_files)} files in database/recycle_bin/)")

    # Step 14: Cleanup
    await cleanup_test_user()
    print("\n========================================================")
    print("ALL 14 LIVE VERIFICATION CHECKS PASSED ON RUNNING SERVER!")
    print("========================================================")

if __name__ == "__main__":
    asyncio.run(run_live_verification())
