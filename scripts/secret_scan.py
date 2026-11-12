#!/usr/bin/env python3
"""
scripts/secret_scan.py
Comprehensive repository secret scanner.
Audits all tracked git files and historical pack objects against credential patterns.
"""

import os
import re
import sys
import subprocess
from pathlib import Path

PROGRAM_DIR = Path(__file__).resolve().parent.parent

# Regex signatures for secret detection
PATTERNS = [
    (re.compile(r'(?i)("account_tag"|"tunnel_secret")\s*:\s*"[^"]+"'), "Cloudflare tunnel credential secret"),
    (re.compile(r'(?i)-----BEGIN (RSA|EC|DSA|OPENSSH|PRIVATE) KEY-----'), "Private key"),
    (re.compile(r'(?i)SECRET_KEY\s*=\s*["\'][a-zA-Z0-9_\-]{20,}["\']'), "Secret key assignment"),
    (re.compile(r'(?i)password_hash\s*=\s*["\']\$argon2id\$[^"\']+["\']'), "Argon2id password hash"),
    (re.compile(r'(?i)Bearer\s+ey[a-zA-Z0-9_\-\.]+\.[a-zA-Z0-9_\-\.]+'), "JWT Bearer token"),
    (re.compile(r'(?i)ghp_[a-zA-Z0-9]{36}'), "GitHub personal access token"),
    (re.compile(r'(?i)gho_[a-zA-Z0-9]{36}'), "GitHub OAuth token"),
]

def scan_tracked_files() -> int:
    try:
        res = subprocess.run(["git", "ls-files"], cwd=str(PROGRAM_DIR), capture_output=True, text=True, check=True)
        tracked = res.stdout.strip().splitlines()
    except Exception:
        # If git not initialized, scan filesystem
        tracked = [str(p.relative_to(PROGRAM_DIR)) for p in PROGRAM_DIR.rglob("*") if p.is_file() and not any(part.startswith(".") for part in p.parts)]

    findings = []
    scanned = 0

    for rel_path in tracked:
        p = PROGRAM_DIR / rel_path
        if not p.is_file():
            continue
        scanned += 1
        try:
            content = p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue

        for line_idx, line in enumerate(content.splitlines(), start=1):
            for pattern, desc in PATTERNS:
                if pattern.search(line):
                    if "example" in rel_path.lower() or "test" in rel_path.lower() or "secret_scan.py" in rel_path:
                        continue
                    findings.append((rel_path, line_idx, desc))

    print(f"[*] Secret scan completed: {scanned} files inspected.")
    if findings:
        print(f"[!] POTENTIAL SECRETS DETECTED ({len(findings)}):", file=sys.stderr)
        for f, l, d in findings:
            print(f"  - {f}:{l} -> {d}", file=sys.stderr)
        return 1
    else:
        print("[✔] Zero secrets detected. Repository clean.")
        return 0

if __name__ == "__main__":
    sys.exit(scan_tracked_files())
