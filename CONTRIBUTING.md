# Contributing to RoonSage

Thanks for considering a contribution. RoonSage is a self-hosted app and the bar for a good contribution is: **does it work reliably on someone else's machine?**

## Before you start

- Open an issue first for non-trivial changes so we can align on approach.
- Check existing issues/PRs to avoid duplicate work.

## Setup

```bash
git clone https://github.com/Georgemvp/roon-mediasage.git
cd roon-mediasage
pip install -r requirements.txt -r requirements-dev.txt
cp .env.example .env   # then fill in ROON_HOST + an LLM key
```

Run the dev server:
```bash
uvicorn backend.main:app --reload --port 5765 --workers 1
```

## Tests and lint

CI will reject PRs that fail either gate:

```bash
# Lint (must be clean)
python3 -m ruff check .

# Tests with coverage
pytest --cov=backend --cov-report=term-missing --cov-fail-under=40
```

Add tests for new backend logic in `tests/`. The test suite runs against an in-memory SQLite DB — no Roon Core needed.

## Code style

- **Python**: PEP 8, type hints on all functions, Pydantic models for every API contract. Line length 100, `ruff` config in `pyproject.toml`.
- **JavaScript**: ES6+, no framework, module pattern. One file per view in `frontend/modules/`.
- **No comments that explain what the code does** — only comments that explain *why* (hidden constraints, workarounds, non-obvious invariants).

## Architecture rules

- **New backend endpoint** → add to the correct `routes/*.py`, add Pydantic models to `models.py`, expose in `mcp_server.py` if relevant to Claude Desktop, update `system_prompt.md` if it changes a flow.
- **DB schema change** → edit `backend/db.py` (`init_schema` handles incremental `ALTER TABLE` migrations).
- **Roon Browse code** → always respect `_browse_lock`. Read `CLAUDE.md` for the full list of Roon API constraints before touching this.
- **Do not add** error handling, fallbacks, or feature flags for scenarios that can't happen in practice.

## Pull requests

- Keep PRs focused — one feature or fix per PR.
- Include a short description of *why* the change is needed, not just what it does.
- Screenshots for UI changes.
- If you're adding a new external service integration, make it fully optional (env vars, no hard dependency at import time).

## Roon API gotchas

The Roon Extension API has several hard constraints that look like bugs but aren't — read `CLAUDE.md` before working on anything Roon-adjacent. The short version:

- No user ratings, no play counts via Roon, no playlist creation via Extension API.
- Browse hierarchy calls must be serialized via `_browse_lock`.
- `hierarchy: "search"` returns ephemeral keys — don't store them.
