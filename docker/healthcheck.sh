#!/usr/bin/env bash
# ==============================================================================
# MORNYE CONTAINER HEALTHCHECK
# ==============================================================================
set -eo pipefail

PORT="${WEBDAV_PORT:-8000}"

# Probe WebDAV endpoint with PROPFIND or GET /health
if curl -s -f -o /dev/null -X PROPFIND -H "Depth: 0" "http://127.0.0.1:${PORT}/dav/" || \
   curl -s -f -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null; then
    exit 0
fi

# Also accept 401 Unauthorized for /dav/ as healthy (indicates WebDAV authentication is active and listening)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PROPFIND -H "Depth: 0" "http://127.0.0.1:${PORT}/dav/" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "200" || "$HTTP_CODE" == "207" ]]; then
    exit 0
fi

exit 1
