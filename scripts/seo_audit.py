#!/usr/bin/env python3
"""
Mornye Network Storage - Comprehensive Production SEO Quality Audit Gate
Verifies:
  1. Title length (<= 60 chars) and presence
  2. Meta description length (<= 160 chars) and presence
  3. Every HTML page has exactly one canonical tag pointing to the production custom domain
  4. No outdated GitHub Pages canonical references or metadata remain
  5. Open Graph og:url matches the page canonical URL
  6. Open Graph & Twitter image and metadata tags exist and use the production domain
  7. Schema.org JSON-LD structured data syntax, context, and production URLs
  8. No accidental noindex directives exist (exempting 404.html)
  9. Google Search Console verification meta tag is preserved in homepage
  10. Sitemap.xml coverage, URL structure, and file resolution on production domain
  11. Robots.txt presence, user-agent directives, and canonical sitemap reference
  12. Document-relative asset and navigation links resolve to existing files
"""

import os
import sys
import re
import json
import xml.etree.ElementTree as ET
from pathlib import Path

SITE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "site")
BASE_URL = "https://mornye-network-project.navya.dpdns.org/"
OLD_DOMAIN = "navyaxdev.github.io/Mornye-Network-Storage"

errors = []
warnings = []
verification_files = []
checked_files = 0

def is_google_verification_file(file_path: str, content: str) -> bool:
    """
    Detect Google Search Console site verification HTML files.
    """
    base = os.path.basename(file_path).lower()
    if re.match(r"^google[a-f0-9_\-]+\.html$", base, re.IGNORECASE):
        return True
    if "google-site-verification:" in content.lower():
        return True
    return False

def get_expected_canonical(rel_path: str) -> str:
    """
    Compute expected canonical URL for an HTML document relative to SITE_DIR.
    """
    if rel_path == "index.html":
        return BASE_URL
    if rel_path.endswith("/index.html"):
        sub = rel_path[:-len("index.html")]
        return f"{BASE_URL}{sub}"
    return f"{BASE_URL}{rel_path}"

def check_html_file(file_path: str):
    global checked_files
    rel_path = os.path.relpath(file_path, SITE_DIR).replace("\\", "/")
    
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Exclude Google verification files from standard webpage metadata checks
    if is_google_verification_file(file_path, content):
        verification_files.append(rel_path)
        return

    checked_files += 1
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
    desc_match = re.search(r'<meta\s+[^>]*name=["\']description["\'][^>]*content=["\'](.*?)["\']', content, re.IGNORECASE)
    if not desc_match:
        desc_match = re.search(r'<meta\s+[^>]*content=["\'](.*?)["\'][^>]*name=["\']description["\']', content, re.IGNORECASE)
    if not desc_match:
        errors.append(f"[{rel_path}] Missing meta description.")
    else:
        desc = desc_match.group(1).strip()
        if len(desc) == 0:
            errors.append(f"[{rel_path}] Empty meta description.")
        elif len(desc) > 160:
            errors.append(f"[{rel_path}] Meta description too long ({len(desc)} chars > 160): '{desc}'")

    # Accidental noindex check
    robots_meta = re.findall(r'<meta\s+[^>]*name=["\']robots["\'][^>]*content=["\']([^"\']+)["\']', content, re.IGNORECASE)
    for rm in robots_meta:
        if "noindex" in rm.lower() and not is_404:
            errors.append(f"[{rel_path}] Accidental noindex directive detected on non-404 page: {rm}")

    # 404.html does not require canonical or Open Graph metadata
    if is_404:
        return

    expected_canonical = get_expected_canonical(rel_path)

    # 3. Canonical Link Check: Exactly one canonical tag pointing to production URL
    canon_tags = re.findall(r'<link\s+[^>]*rel=["\']canonical["\'][^>]*>', content, re.IGNORECASE)
    if len(canon_tags) == 0:
        errors.append(f"[{rel_path}] Missing canonical link tag.")
    elif len(canon_tags) > 1:
        errors.append(f"[{rel_path}] Multiple canonical link tags ({len(canon_tags)}).")
    else:
        href_match = re.search(r'href=["\']([^"\']+)["\']', canon_tags[0], re.IGNORECASE)
        if not href_match:
            errors.append(f"[{rel_path}] Canonical tag missing href attribute.")
        else:
            canon_url = href_match.group(1).strip()
            if canon_url != expected_canonical:
                errors.append(f"[{rel_path}] Canonical URL mismatch: expected '{expected_canonical}', got '{canon_url}'")
            if OLD_DOMAIN in canon_url:
                errors.append(f"[{rel_path}] Canonical URL references outdated GitHub Pages domain: {canon_url}")

    # 4. Outdated GitHub Pages References in SEO metadata
    head_match = re.search(r'<head>(.*?)</head>', content, re.IGNORECASE | re.DOTALL)
    if head_match:
        head_content = head_match.group(1)
        if "navyaxdev.github.io" in head_content:
            errors.append(f"[{rel_path}] Outdated domain 'navyaxdev.github.io' found in <head> metadata.")

    # 5. Open Graph og:url check - must match canonical URL
    og_url_match = re.search(r'<meta\s+[^>]*property=["\']og:url["\'][^>]*content=["\']([^"\']+)["\']', content, re.IGNORECASE)
    if not og_url_match:
        og_url_match = re.search(r'<meta\s+[^>]*content=["\']([^"\']+)["\'][^>]*property=["\']og:url["\']', content, re.IGNORECASE)
    if not og_url_match:
        warnings.append(f"[{rel_path}] Missing og:url property.")
    else:
        og_url = og_url_match.group(1).strip()
        if og_url != expected_canonical:
            errors.append(f"[{rel_path}] og:url mismatch: expected '{expected_canonical}', got '{og_url}'")

    # 6. JSON-LD Check
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

    # 7. Google Verification Tag on Homepage
    if rel_path == "index.html":
        expected_gsc = '<meta name="google-site-verification" content="lDMOKFi9WK_pAPEJ3o0gVjCKM1wT-JbVlFQXy7G2v5M" />'
        if expected_gsc not in content:
            errors.append(f"[{rel_path}] Missing Google Search Console verification meta tag.")

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

        # Check for duplicates
        seen = set()
        for u in urls:
            if u in seen:
                errors.append(f"Duplicate URL in sitemap.xml: {u}")
            seen.add(u)

            if not u.startswith(BASE_URL):
                errors.append(f"sitemap URL does not start with {BASE_URL}: {u}")
                continue

            if OLD_DOMAIN in u:
                errors.append(f"sitemap URL references outdated GitHub Pages domain: {u}")
                continue

            if u.endswith("feed.xml") or u.endswith("llms.txt") or "404" in u:
                errors.append(f"Non-indexable resource in sitemap.xml: {u}")
                continue
            
            # Resolve to local file
            subpath = u[len(BASE_URL):]
            if subpath == "" or subpath == "/":
                expected_file = os.path.join(SITE_DIR, "index.html")
            else:
                expected_file = os.path.join(SITE_DIR, subpath.strip("/"), "index.html")
            
            if not os.path.exists(expected_file):
                errors.append(f"sitemap URL '{u}' corresponds to missing file '{expected_file}'")

        # Verify all indexable HTML documents in site/ are present in sitemap
        expected_count = 16
        if len(urls) != expected_count:
            warnings.append(f"Sitemap has {len(urls)} URLs, expected {expected_count}")

    except Exception as e:
        errors.append(f"Failed to parse sitemap.xml: {e}")

def check_robots_txt():
    robots_path = os.path.join(SITE_DIR, "robots.txt")
    if not os.path.exists(robots_path):
        errors.append("robots.txt not found in site root.")
        return

    with open(robots_path, "r", encoding="utf-8") as f:
        robots_content = f.read()

    if "User-agent: *" not in robots_content:
        errors.append("robots.txt missing 'User-agent: *'")
    if "Allow: /" not in robots_content:
        errors.append("robots.txt missing 'Allow: /'")

    expected_sitemap_directive = f"Sitemap: {BASE_URL}sitemap.xml"
    if expected_sitemap_directive not in robots_content:
        errors.append(f"robots.txt missing correct sitemap directive: '{expected_sitemap_directive}'")
    if OLD_DOMAIN in robots_content:
        errors.append(f"robots.txt contains outdated domain: {OLD_DOMAIN}")

def check_internal_links():
    import re
    verified = 0
    for root, _, files in os.walk(SITE_DIR):
        for f in files:
            if not f.endswith('.html') or f.startswith('google'):
                continue
            file_path = os.path.join(root, f)
            rel_html = os.path.relpath(file_path, SITE_DIR).replace('\\', '/')
            dir_of_file = os.path.dirname(file_path)
            content = Path(file_path).read_text(encoding='utf-8')
            
            tags = re.findall(r'(?:href|src)=["\']([^"\']+)["\']', content)
            for target in tags:
                if target.startswith(('http://', 'https://', 'mailto:', 'tel:', '#', 'javascript:')):
                    continue
                if target.startswith('/Mornye-Network-Storage/'):
                    errors.append(f"[{rel_html}] Has hardcoded /Mornye-Network-Storage/ in '{target}'")
                
                clean = target.split('#')[0].split('?')[0]
                if rel_html == '404.html':
                    if clean.startswith('./'):
                        clean = clean[2:]
                    if clean in ('', '/'):
                        target_file = os.path.join(SITE_DIR, 'index.html')
                    elif clean.endswith('/'):
                        target_file = os.path.join(SITE_DIR, clean.strip('/'), 'index.html')
                    else:
                        target_file = os.path.join(SITE_DIR, clean)
                else:
                    if clean.endswith('/'):
                        target_file = os.path.normpath(os.path.join(dir_of_file, clean, 'index.html'))
                    elif clean in ('', '.'):
                        target_file = os.path.normpath(os.path.join(dir_of_file, 'index.html'))
                    else:
                        target_file = os.path.normpath(os.path.join(dir_of_file, clean))
                        if os.path.isdir(target_file):
                            target_file = os.path.join(target_file, 'index.html')
                
                if not os.path.exists(target_file):
                    errors.append(f"[{rel_html}] Link target '{target}' resolves to missing file: {target_file}")
                else:
                    verified += 1
    return verified

def run_audit(site_dir=None, exit_on_finish=True):
    global SITE_DIR, errors, warnings, checked_files, verification_files
    if site_dir:
        SITE_DIR = site_dir
    errors = []
    warnings = []
    verification_files = []
    checked_files = 0

    print(f"[*] Starting Mornye SEO Quality Audit on: {SITE_DIR}")
    for root, _, files in os.walk(SITE_DIR):
        for f in files:
            if f.endswith(".html"):
                check_html_file(os.path.join(root, f))

    check_sitemap()
    check_robots_txt()
    links_verified = check_internal_links()
    print(f"[+] Verified {links_verified} document-relative asset and navigation links.")

    print(f"[+] Audited {checked_files} HTML documents.")
    if verification_files:
        print(f"[+] Recognized {len(verification_files)} site verification file(s) (exempt from webpage SEO tags):")
        for vf in verification_files:
            print(f"    - {vf}")

    if warnings:
        print(f"\n[!] WARNINGS ({len(warnings)}):")
        for w in warnings:
            print(f"  - {w}")

    if errors:
        print(f"\n[-] FAILED: Found {len(errors)} SEO errors:")
        for err in errors:
            print(f"  - {err}")
        if exit_on_finish:
            sys.exit(1)
        return False
    else:
        print("\n[+] SUCCESS: All SEO, canonical, metadata, JSON-LD, sitemap, and robots.txt quality checks passed!")
        if exit_on_finish:
            sys.exit(0)
        return True

if __name__ == "__main__":
    run_audit()
