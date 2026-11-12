"""
backend/server.py
Production entrypoint for Mornye Network Storage WebDAV Engine.
"""

import sys
import asyncio
import logging
import uvicorn

from backend.core.config import settings
from webdav.webdav_app import webdav_app

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("mornye.server")

async def run_server():
    logger.info("==========================================================")
    logger.info("  MORNYE NETWORK STORAGE — DEDICATED WEBDAV ENGINE")
    logger.info("==========================================================")
    logger.info(f"[*] Local WebDAV Target: http://{settings.WEBDAV_HOST}:{settings.WEBDAV_PORT}/dav/")
    logger.info(f"[*] Public Hostname Ingress: https://{settings.STORAGE_HOSTNAME}/dav/")
    logger.info(f"[*] Quota Allocation: {settings.DEFAULT_STORAGE_QUOTA_BYTES / (1024**3):.1f} GB")
    logger.info("==========================================================")

    config = uvicorn.Config(
        app=webdav_app,
        host=settings.WEBDAV_HOST,
        port=settings.WEBDAV_PORT,
        log_level="info",
        access_log=True,
        workers=1
    )
    server = uvicorn.Server(config)
    await server.serve()

def main():
    try:
        asyncio.run(run_server())
    except (KeyboardInterrupt, SystemExit):
        logger.info("[*] Mornye WebDAV engine terminated cleanly.")
        sys.exit(0)

if __name__ == "__main__":
    main()
