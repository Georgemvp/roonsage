# RoonSage — Legacy Docker web-app (deprecated)

> ⚠️ **This stack is deprecated and no longer maintained.** It is kept here for
> reference only. The actively-developed product is the native macOS/iOS app in
> [`../native/`](../native/). See the root [README](../README.md).
>
> **Removal plan:** this directory is scheduled for deletion once the last value
> is extracted from it — namely the legacy `track_audio_features` table exported
> as the analyzer's accuracy-validation reference CSV (see `native/ROADMAP.md`).
> No native code depends on it. When deleted, also remove the now-dead
> `.github/workflows/test.yml` (it only runs on `legacy-docker/**` changes).
> Git history preserves everything.

This directory holds the original self-hosted **FastAPI web app + MCP server**:
it connected to a Roon Core as an Extension, mirrored the library into a local
SQLite cache, and exposed ~69 tools so Claude Desktop could curate playlists,
discover music, and control Roon in natural language.

## What's here

| Path | Description |
|------|-------------|
| `backend/` | FastAPI app, routes, library cache, LLM/AI, intelligence, workflows |
| `frontend/` | Vanilla HTML/CSS/JS SPA + React microfrontend (`frontend/react/`) |
| `tests/` | pytest suite (`pytest`, coverage gate ≥40%) |
| `scripts/` | `install_mcp.py`, `bundle_css.sh`, ONNX export scripts |
| `mcp_server.py` | MCP server for Claude Desktop (FastMCP over stdio) |
| `system_prompt.md` | System prompt shipped to Claude Desktop |
| `Dockerfile`, `docker-compose*.yml`, `Caddyfile`, `Modelfile*` | Container/serving stack |
| `requirements*.txt/.in`, `pyproject.toml`, `config.example.yaml` | Python deps + tooling + config template |

## Running it (for reference)

The Docker build **context is the repository root** (`..`), because the
Dockerfile also copies `../data/mood_centroids.json`, which still lives at the
repo root. The Dockerfile and compose files themselves live in this directory.

```bash
# From this directory:
cd legacy-docker
docker compose up -d --build

# Or run the dev server directly (run from the repo root so the relative
# `data/` paths resolve):
cd ..
uvicorn legacy-docker.backend.main:app --reload --port 5765   # see note below
```

> **Note:** because the backend was written to read `data/` relative to the
> current working directory, local (non-Docker) runs expect to be launched from
> a directory where a `data/` folder is reachable. Inside the container this is
> handled by the Dockerfile (`COPY data/mood_centroids.json`). This stack is
> deprecated, so these instructions are best-effort.
>
> The `.dockerignore` in this directory is written relative to the repo-root
> build context. With BuildKit it is loaded as `legacy-docker/.dockerignore`
> only when referenced as such; treat it as advisory.

## CI

Lint + tests run via `.github/workflows/test.yml` (renamed *Legacy
Docker/Python Tests*), which only triggers on changes under `legacy-docker/**`.
No Docker image is built or published in CI.

## Tests

```bash
cd legacy-docker
pip install -r requirements.txt -r requirements-dev.txt
ruff check .
pytest tests/ --cov=backend --cov-report=term-missing --cov-fail-under=40
```
