# ==============================================================================
# MORNYE NETWORK STORAGE — PRODUCTION MULTI-STAGE DOCKERFILE
# Portable, lightweight, non-root, reproducible Linux container image
# ==============================================================================

# Stage 1: Build Wheels
FROM python:3.11-slim-bookworm AS builder

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    libffi-dev \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt


# Stage 2: Minimal Production Runtime
FROM python:3.11-slim-bookworm AS runner

# Install only essential runtime tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    libmagic1 \
    sqlite3 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Security: Create non-root system user and group (uid 1000 matches host user)
RUN groupadd -g 1000 mornye && \
    useradd -u 1000 -g mornye -m -s /bin/bash mornye

WORKDIR /app

# Install compiled wheels from builder stage
COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir /wheels/* && rm -rf /wheels

# Set up runtime directories with non-root ownership
RUN mkdir -p /data /storage /logs /app /data/cache /data/tmp /data/recycle_bin && \
    chown -R mornye:mornye /data /storage /logs /app

# Copy application source code
COPY --chown=mornye:mornye . /app/
RUN chmod +x /app/docker/entrypoint.sh /app/docker/healthcheck.sh /app/mornye.sh

# Environment defaults (can be overridden by compose.yaml or .env)
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app \
    DATA_PATH=/data \
    STORAGE_PATH=/storage \
    LOG_PATH=/logs \
    DATABASE_URL=sqlite+aiosqlite:////data/mornye.db \
    WEBDAV_HOST=0.0.0.0 \
    WEBDAV_PORT=8000

# Switch to non-root user
USER mornye:mornye

# WebDAV port only
EXPOSE 8000

# Continuous Container Healthcheck
HEALTHCHECK --interval=20s --timeout=5s --start-period=10s --retries=3 \
    CMD /app/docker/healthcheck.sh

ENTRYPOINT ["/app/docker/entrypoint.sh"]
