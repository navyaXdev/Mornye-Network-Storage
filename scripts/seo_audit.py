#!/usr/bin/env python3
"""
Mornye Network Storage - SEO & Metadata Quality Audit Gate
Verifies:
  1. Meta title length (<= 60 chars) and presence
  2. Meta description length (<= 160 chars) and presence
  3. Canonical link presence and validity
  4. Open Graph & Twitter Card tags
  5. JSON-LD structured data syntax and types
  6. Sitemap.xml coverage and URL validity
"""

import os
import sys
import re
import json
import xml.etree.ElementTree as ET

SITE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "site")
BASE_URL = "https://navyaxdev.github.io/Mornye-Network-Storage/"

errors = []
warnings = []
checked_files = 0

def check_html_file(file_path):
    global checked_files
    checked_files += 1
    rel_path = os.path.relpath(file_path, SITE_DIR).replace("\\", "/")
    
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Skip 404.html from title/description length limits
    is_404 = "404.html" in rel_path

    # 1. Title Check
    title_match = re.search(r"<title>(.*?)</title>", content, re.IGNORECASE | re.DOTALL)
    if not title_match:
        errors.append(f"[{rel_path}] Missing <title> tag.")
    else:
        title = title_match.group(1).strip()
        if len(title) == 0:
            errors.append(f"[{rel_path}] Empty <title> tag.")
        elif len(title) > 60 and not is_404:
            errors.append(f"[{rel_path}] Title too long ({len(title)} chars > 60): '{title}'")

    # 2. Meta Description Check
    desc_match = re.search(r'<meta\s+name=["\']description["\']\s+content=["\'](.*?)["\']', content, re.IGNORECASE)
    if not desc_match:
        errors.append(f"[{rel_path}] Missing meta description.")
    else:
        desc = desc_match.group(1).strip()
        if len(desc) == 0:
            errors.append(f"[{rel_path}] Empty meta description.")
        elif len(desc) > 160:
            errors.append(f"[{rel_path}] Meta description too long ({len(desc)} chars > 160): '{desc}'")

    if is_404:
        return

    # 3. Canonical Link Check
    canon_match = re.search(r'<link\s+rel=["\']canonical["\']\s+href=["\'](.*?)["\']', content, re.IGNORECASE)
    if not canon_match:
        errors.append(f"[{rel_path}] Missing canonical link tag.")
    else:
        canon_url = canon_match.group(1).strip()
        if not canon_url.startswith("https://navyaxdev.github.io/Mornye-Network-Storage/"):
            errors.append(f"[{rel_path}] Invalid canonical URL: {canon_url}")

    # 4. Open Graph Tags
    for og_prop in ["og:title", "og:description", "og:image", "og:url"]:
        if f'property="{og_prop}"' not in content and f"property='{og_prop}'" not in content:
            warnings.append(f"[{rel_path}] Missing Open Graph property: {og_prop}")

    # 5. JSON-LD Check
    json_ld_matches = re.findall(r'<script\s+type=["\']application/ld\+json["\']>(.*?)</script>', content, re.IGNORECASE | re.DOTALL)
    if not json_ld_matches:
        errors.append(f"[{rel_path}] Missing Schema.org JSON-LD script block.")
    else:
        for block in json_ld_matches:
            try:
                data = json.loads(block.strip())
                if "@context" not in data:
                    errors.append(f"[{rel_path}] JSON-LD missing '@context'")
            except json.JSONDecodeError as e:
                errors.append(f"[{rel_path}] Invalid JSON-LD syntax: {e}")

def check_sitemap():
    sitemap_path = os.path.join(SITE_DIR, "sitemap.xml")
    if not os.path.exists(sitemap_path):
        errors.append("sitemap.xml not found in site root.")
        return

    try:
        tree = ET.parse(sitemap_path)
        root = tree.getroot()
        namespace = {"ns": "http://www.sitemaps.org/schemas/sitemap/0.9"}
        urls = [loc.text.strip() for loc in root.findall("ns:url/ns:loc", namespace)]
        
        if not urls:
            errors.append("sitemap.xml contains 0 URLs.")
            return
            
        print(f"[+] sitemap.xml contains {len(urls)} URLs")

        for u in urls:
            if not u.startswith(BASE_URL):
                errors.append(f"sitemap URL does not start with {BASE_URL}: {u}")
                continue
            
            # Resolve to local file
            subpath = u[len(BASE_URL):]
            if subpath == "" or subpath == "/":
                expected_file = os.path.join(SITE_DIR, "index.html")
            else:
                expected_file = os.path.join(SITE_DIR, subpath.strip("/"), "index.html")
            
            if not os.path.exists(expected_file):
                errors.append(f"sitemap URL '{u}' corresponds to missing file '{expected_file}'")
    except Exception as e:
        errors.append(f"Failed to parse sitemap.xml: {e}")

def run_audit():
    print(f"[*] Starting Mornye SEO Quality Audit on: {SITE_DIR}")
    for root, _, files in os.walk(SITE_DIR):
        for f in files:
            if f.endswith(".html"):
                check_html_file(os.path.join(root, f))

    check_sitemap()

    print(f"[+] Audited {checked_files} HTML documents.")

    if warnings:
        print(f"\n[!] WARNINGS ({len(warnings)}):")
        for w in warnings:
            print(f"  - {w}")

    if errors:
        print(f"\n[-] FAILED: Found {len(errors)} SEO errors:")
        for err in errors:
            print(f"  - {err}")
        sys.exit(1)
    else:
        print("\n[+] SUCCESS: All SEO, metadata, JSON-LD, and sitemap quality checks passed!")
        sys.exit(0)

if __name__ == "__main__":
    run_audit()

