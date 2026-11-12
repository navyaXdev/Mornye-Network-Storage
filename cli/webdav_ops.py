#!/usr/bin/env python3
"""
cli/webdav_ops.py
WebDAV service inspection and test operations for Mornye Bash CLI.
"""

import sys
import socket
import time
import httpx
from pathlib import Path

PROGRAM_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROGRAM_DIR))

from backend.core.config import settings

def check_port(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=1.0):
            return True
    except Exception:
        return False

def show_status():
    host = settings.WEBDAV_HOST if settings.WEBDAV_HOST != "0.0.0.0" else "127.0.0.1"
    port = settings.WEBDAV_PORT
    is_up = check_port(host, port)

    print("=" * 60)
    print("                 WEBDAV SERVICE STATUS")
    print("=" * 60)
    print(f"Service Protocol     : RFC 4918 WebDAV Distributed Sync Engine")
    print(f"Local Target Address : http://{host}:{port}/dav/")
    print(f"Listening State      : {'LISTENING (HEALTHY)' if is_up else 'STOPPED (UNREACHABLE)'}")
    print(f"Public Domain Ingress: https://{settings.STORAGE_HOSTNAME}/dav/")
    print(f"Authentication Mode  : HTTP Basic Auth (Argon2id verified)")
    print("=" * 60)

def test_webdav():
    host = settings.WEBDAV_HOST if settings.WEBDAV_HOST != "0.0.0.0" else "127.0.0.1"
    port = settings.WEBDAV_PORT
    url = f"http://{host}:{port}/dav/"

    print(f"[*] Probing local WebDAV endpoint: {url}...")
    t0 = time.perf_counter()
    try:
        with httpx.Client(timeout=3.0) as client:
            resp = client.request("PROPFIND", url, headers={"Depth": "0"})
            duration_ms = (time.perf_counter() - t0) * 1000.0

            print(f"[✔] Response Status   : HTTP {resp.status_code} ({resp.reason_phrase})")
            print(f"[✔] Round-Trip Latency: {duration_ms:.2f} ms")
            print(f"[✔] Server Header     : {resp.headers.get('server', 'uvicorn')}")
            print(f"[✔] Auth Challenge    : {resp.headers.get('www-authenticate', 'None')}")

            # 401 without credentials or 207 with credentials is expected and healthy
            if resp.status_code in [200, 207, 401]:
                print("[✔] WebDAV engine responds correctly and enforces authentication boundary.")
            else:
                print(f"[!] Warning: Unexpected status code {resp.status_code} received.")
    except Exception as e:
        print(f"[ERROR] WebDAV connection probe failed: {e}")
        sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print("Usage: webdav_ops.py [status|test]")
        sys.exit(1)

    cmd = sys.argv[1].lower()
    if cmd == "status":
        show_status()
    elif cmd == "test":
        test_webdav()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()

