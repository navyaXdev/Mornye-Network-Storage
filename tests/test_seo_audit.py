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
