"""
tests/test_seo_audit.py
Regression tests for SEO Quality Audit and Google verification file exemptions.
"""

import os
import sys
from pathlib import Path
import pytest

# Ensure scripts directory is in python path
ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT_DIR / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from seo_audit import is_google_verification_file, run_audit, SITE_DIR

def test_is_google_verification_file_pattern():
    """Verify that Google verification files are correctly identified by filename and content."""
    # Standard Google hex verification filename
    assert is_google_verification_file("google8c9daff4dd10440f.html", "google-site-verification: google8c9daff4dd10440f.html")
    assert is_google_verification_file("/site/google1234567890abcdef.html", "")
    assert is_google_verification_file("google-token-test.html", "google-site-verification: test")
    
    # Standard HTML pages should NOT be identified as verification files
    assert not is_google_verification_file("index.html", "<html><head><title>Test</title></head></html>")
    assert not is_google_verification_file("features/index.html", "<html>...</html>")
    assert not is_google_verification_file("404.html", "<html>...</html>")

def test_live_site_audit_passes_with_google_verification():
    """Verify that the existing repository site/ folder passes the SEO audit with 0 errors."""
    success = run_audit(exit_on_finish=False)
    assert success is True, "SEO audit failed on existing site/ repository"

def test_google_verification_exemption_regression():
    """Regression test: Ensure adding a new Google verification file does not fail the SEO audit."""
    test_verification_file = Path(SITE_DIR) / "google_canary_regression_test.html"
    try:
        test_verification_file.write_text("google-site-verification: google_canary_regression_test.html", encoding="utf-8")
        success = run_audit(exit_on_finish=False)
        assert success is True, "SEO audit must pass when Google verification file is present"
    finally:
        if test_verification_file.exists():
            test_verification_file.unlink()

def test_broken_html_page_still_fails_audit():
    """Ensure that the SEO audit still catches broken non-verification HTML files missing meta tags."""
    broken_file = Path(SITE_DIR) / "broken_test_page.html"
    try:
        # Create HTML missing title, description, canonical, OG tags
        broken_file.write_text("<html><body><h1>Missing Meta Tags</h1></body></html>", encoding="utf-8")
        success = run_audit(exit_on_finish=False)
        assert success is False, "SEO audit must fail when an invalid HTML page is present"
    finally:
        if broken_file.exists():
            broken_file.unlink()

def test_relative_asset_paths_and_internal_links_resolve():
    """Ensure that all HTML pages use relative paths that resolve to actual files without hardcoded /Mornye-Network-Storage/ prefixes."""
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
            
            # Find all href and src attributes
            tags = re.findall(r'(?:href|src)=["\']([^"\']+)["\']', content)
            for target in tags:
                if target.startswith(('http://', 'https://', 'mailto:', 'tel:', '#', 'javascript:')):
                    continue
                # Ensure no hardcoded subpath
                assert not target.startswith('/Mornye-Network-Storage/'), f"[{rel_html}] Has hardcoded /Mornye-Network-Storage/ in {target}"
                
                # In 404.html, paths are relative to base
                if rel_html == '404.html':
                    clean = target.split('#')[0].split('?')[0]
                    if clean.startswith('./'):
                        clean = clean[2:]
                    if clean in ('', '/'):
                        target_file = os.path.join(SITE_DIR, 'index.html')
                    elif clean.endswith('/'):
                        target_file = os.path.join(SITE_DIR, clean.strip('/'), 'index.html')
                    else:
                        target_file = os.path.join(SITE_DIR, clean)
                else:
                    clean = target.split('#')[0].split('?')[0]
                    if clean.endswith('/'):
                        target_file = os.path.normpath(os.path.join(dir_of_file, clean, 'index.html'))
                    elif clean in ('', '.'):
                        target_file = os.path.normpath(os.path.join(dir_of_file, 'index.html'))
                    else:
                        target_file = os.path.normpath(os.path.join(dir_of_file, clean))
                        if os.path.isdir(target_file):
                            target_file = os.path.join(target_file, 'index.html')
                
                assert os.path.exists(target_file), f"[{rel_html}] Link target '{target}' resolves to missing file: {target_file}"
                verified += 1
    assert verified > 300, f"Expected >300 relative assets/links verified, got {verified}"

def test_homepage_google_site_verification_meta_tag():
    """Verify that site/index.html includes the required Google Search Console verification meta tag."""
    homepage_path = Path(SITE_DIR) / "index.html"
    assert homepage_path.exists(), "site/index.html must exist"
    content = homepage_path.read_text(encoding="utf-8")
    expected_meta = '<meta name="google-site-verification" content="lDMOKFi9WK_pAPEJ3o0gVjCKM1wT-JbVlFQXy7G2v5M" />'
    assert expected_meta in content, f"Missing Google Search Console verification meta tag in {homepage_path}"

