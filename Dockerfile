FROM python:3.14.3-slim

ARG VERSION=dev
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${VERSION}

WORKDIR /app

# Create a non-root user with specific UID for easier host permission matching
RUN groupadd -r -g 1000 roonsageappuser && useradd -r -u 1000 -g roonsageappuser roonsageappuser

# Create data directory with correct ownership (for volume mounts)
RUN mkdir -p /app/data && chown roonsageappuser:roonsageappuser /app/data

# Install system dependencies (chromaprint for AcoustID fingerprinting)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libchromaprint-tools \
    && rm -rf /var/lib/apt/lists/*

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code with ownership
COPY --chown=roonsageappuser:roonsageappuser backend/ ./backend/
COPY --chown=roonsageappuser:roonsageappuser frontend/ ./frontend/

# Expose port
EXPOSE 5765

# Switch to non-root user
USER roonsageappuser

# Healthcheck
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; import sys; code = urllib.request.urlopen('http://localhost:5765/api/health').getcode(); sys.exit(0 if code == 200 else 1)"

# Run the application
CMD ["sh", "-c", "uvicorn backend.main:app --host 0.0.0.0 --port 5765 --workers ${UVICORN_WORKERS:-1}"]
