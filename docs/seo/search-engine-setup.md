# Search Engine Registration & Global Indexing Setup Guide

This guide provides instructions for the project administrator (**NavyaXdev**) to register and verify the official Mornye Network Storage website (`https://navyaxdev.github.io/Mornye-Network-Storage/`) across major search engines and developer discovery platforms.

---

> [!IMPORTANT]
> **Zero Credential Commitment Policy**: Never commit real site verification tokens, API secret keys, or private DNS tokens to the Git repository. Use environment secrets or manual console verification.

---

## 1. Google Search Console Verification

Google Search Console (GSC) is the primary tool for monitoring organic search performance on Google Search.

### Step 1: Add URL Prefix Property
1. Navigate to [Google Search Console](https://search.google.com/search-console).
2. Click **Add Property** in the property dropdown.
3. Select **URL prefix** and enter:
   ```text
   https://navyaxdev.github.io/Mornye-Network-Storage/
   ```
4. Click **Continue**.

### Step 2: Verification Methods
Choose one of the following methods supported by GitHub Pages:
- **HTML Tag Method (Recommended):**
  1. Copy the meta tag provided by GSC:
     ```html
     <meta name="google-site-verification" content="<YOUR_VERIFICATION_TOKEN_HERE>" />
     ```
  2. Add this meta tag into the `<head>` section of `site/index.html`.
  3. Commit and push the change to trigger the GitHub Actions deployment workflow.
  4. Return to GSC and click **Verify**.

- **HTML File Upload:**
  1. Download the `google<token>.html` file provided by GSC.
  2. Place it directly inside `site/` (e.g., `site/google<token>.html`).
  3. Deploy to GitHub Pages and click **Verify**.

### Step 3: Submit Canonical Sitemap
1. Once verified, open the **Sitemaps** tab on the left sidebar.
2. In the **Add a new sitemap** field, enter:
   ```text
   sitemap.xml
   ```
   *(Full URL: `https://navyaxdev.github.io/Mornye-Network-Storage/sitemap.xml`)*
3. Click **Submit**. Verify that the status shows **Success**.

### Step 4: Validate Rich Results
Test structured data with Google's official tool:
- [Google Rich Results Test](https://search.google.com/test/rich-results)
- Test URLs:
  - Homepage: `https://navyaxdev.github.io/Mornye-Network-Storage/` (Validates `SoftwareApplication`, `Person`, `WebSite`)
  - FAQ: `https://navyaxdev.github.io/Mornye-Network-Storage/faq/` (Validates `FAQPage`)
  - Guides: `https://navyaxdev.github.io/Mornye-Network-Storage/guides/what-is-mornye-network-storage/` (Validates `TechArticle`, `BreadcrumbList`)

---

## 2. Bing Webmaster Tools & IndexNow

Bing Webmaster Tools powers search results for Microsoft Bing, Yahoo Search, and DuckDuckGo.

### Step 1: Add Property or Import from GSC
1. Navigate to [Bing Webmaster Tools](https://www.bing.com/webmasters).
2. Sign in and select **Import from Google Search Console** (fastest and automatic) or select **Add your site manually** using `https://navyaxdev.github.io/Mornye-Network-Storage/`.
3. If adding manually, add the Bing verification meta tag to `site/index.html`.

### Step 2: Submit Sitemap
1. Navigate to **Sitemaps** &rarr; **Submit sitemap**.
2. Submit:
   ```text
   https://navyaxdev.github.io/Mornye-Network-Storage/sitemap.xml
   ```

### Step 3: Instant Indexing via IndexNow
IndexNow enables instant crawling of updated content across Bing, Yandex, and Seznam:
1. Generate an IndexNow key (a 32-character hexadecimal string) or use the Bing Webmaster Tools API.
2. Place a file named `<key>.txt` containing only the key into `site/` (e.g. `site/<key>.txt`).
3. Whenever an article or release is updated, notify the IndexNow endpoint:
   ```bash
   curl -X POST "https://api.indexnow.org/indexnow" \
     -H "Content-Type: application/json; charset=utf-8" \
     -d '{
       "host": "navyaxdev.github.io",
       "key": "<YOUR_INDEXNOW_KEY>",
       "keyLocation": "https://navyaxdev.github.io/Mornye-Network-Storage/<key>.txt",
       "urlList": [
         "https://navyaxdev.github.io/Mornye-Network-Storage/",
         "https://navyaxdev.github.io/Mornye-Network-Storage/download/"
       ]
     }'
   ```

---

## 3. GitHub Search Engine & Developer Discovery

GitHub's internal search algorithm indexes repository metadata, topics, README content, and release descriptions.

### Repository Optimization Checklist:
- [x] **Description**: Up to date, under 350 characters, containing core search keywords.
- [x] **Repository Homepage**: Set to `https://navyaxdev.github.io/Mornye-Network-Storage/`.
- [x] **Topics (20)**: `argon2id`, `cloud-storage`, `cloudflare-tunnel`, `debian`, `docker`, `docker-compose`, `file-server`, `kali-linux`, `linux`, `nas`, `network-storage`, `open-source`, `private-cloud`, `python`, `self-hosted`, `storage-server`, `ubuntu`, `webdav`, `webdav-server`, `zero-trust`.
- [x] **Social Preview Image**: 1280x640 PNG uploaded to GitHub repository Settings &rarr; General &rarr; Social preview.
- [x] **GitHub Releases**: Semantic version tags (e.g. `v3.3.0`) with structured release notes.
- [x] **Citation Metadata**: `CITATION.cff` for academic and software index attribution.

---

## 4. Ongoing SEO Maintenance Checklist

| Task | Frequency | Target Goal |
|---|---|---|
| **Sitemap Audit** | Monthly / on new release | Ensure all new guide URLs are present with updated `<lastmod>`. |
| **GSC Coverage Inspection** | Bi-weekly | Check for crawl errors, 404s, or mobile usability warnings. |
| **Keyword Position Tracking** | Monthly | Track rankings for `Mornye Network Storage`, `Mornye WebDAV`, `Kali Linux storage server`. |
| **SEO Automated CI Gate** | On every push/PR | Run `python3 scripts/seo_audit.py` to prevent title/description regressions. |

