# ── Stage 1: dependency builder ───────────────────────────────────────────────
FROM python:3.12-slim AS builder

# Install uv (fast resolver) for both compile and install.
# Using the official standalone binary so we don't pull in a Python toolchain.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
        build-essential \
        libsndfile1-dev \
    && curl -LsSf https://astral.sh/uv/install.sh | sh \
    && cp /root/.local/bin/uv /usr/local/bin/uv \
    && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY requirements.in requirements.txt ./

# Recompile requirements.txt from requirements.in on every build so the lock
# stays honest. Then install into /install via uv's --target equivalent.
RUN uv pip compile requirements.in -o requirements.txt --python-version=3.12 \
    && uv pip install --target=/install --no-cache -r requirements.txt

# ── Stage 2: final image ───────────────────────────────────────────────────────
FROM python:3.12-slim

ARG VERSION=dev
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${VERSION} \
    CLAP_CACHE_DIR=/app/data/.clap_cache \
    HF_HOME=/app/data/.hf_cache \
    TRANSFORMERS_CACHE=/app/data/.hf_cache

WORKDIR /app

# Non-root user with stable UID for volume-permission compatibility
RUN groupadd -r -g 1000 roonsage && useradd -r -u 1000 -g roonsage roonsage

# Data directory (SQLite + user config) owned by app user
RUN mkdir -p /app/data /app/data/.clap_cache /app/data/.hf_cache \
    && chown -R roonsage:roonsage /app/data

# System dependencies:
#   libchromaprint-tools — AcoustID fingerprinting
#   libsndfile1, ffmpeg  — audio decoding for librosa/soundfile (audio_features worker)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libchromaprint-tools \
    libsndfile1 \
    ffmpeg \
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
