# ── Stage 1: dependency builder ───────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --target=/install -r requirements.txt

# ── Stage 2: final image ───────────────────────────────────────────────────────
FROM python:3.12-slim

ARG VERSION=dev
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${VERSION}

WORKDIR /app

# Non-root user with stable UID for volume-permission compatibility
RUN groupadd -r -g 1000 roonsage && useradd -r -u 1000 -g roonsage roonsage

# Data directory (SQLite + user config) owned by app user
RUN mkdir -p /app/data && chown roonsage:roonsage /app/data

# System dependencies (chromaprint for AcoustID fingerprinting)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libchromaprint-tools \
    && rm -rf /var/lib/apt/lists/*

# Copy pre-built packages from builder stage
COPY --from=builder /install /usr/local/lib/python3.12/site-packages/
COPY --from=builder /install/bin/ /usr/local/bin/

# Copy application source
COPY --chown=roonsage:roonsage backend/ ./backend/
COPY --chown=roonsage:roonsage frontend/ ./frontend/
COPY --chown=roonsage:roonsage config.example.yaml ./

EXPOSE 5765

USER roonsage

HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; import sys; sys.exit(0 if urllib.request.urlopen('http://localhost:5765/api/health').getcode() == 200 else 1)"

CMD ["sh", "-c", "python -m uvicorn backend.main:app --host 0.0.0.0 --port 5765 --workers ${UVICORN_WORKERS:-1}"]
