# PROJECT.md — RoonSage project rules

Transported verbatim from the pre-kit CLAUDE.md (snapshot `CLAUDE.md.pre-migration-20260706-1444`, git 9a6b20f).
Everything else in that snapshot described the deprecated **legacy-docker** stack and was dropped at
the user's direction (2026-07-06); git history and the snapshot retain the full original.

## Repository structure (READ FIRST)
The repository now has two tracks:

- **`native/`** — the **primary product**: native macOS & iOS apps (Swift/SwiftUI).
  Shared SPM package (`native/RoonSage` — RoonSageCore/UI/MCP/AudioAnalysis/Analyzer),
  the protocol package (`native/RoonProtocol`), the iOS app (`native/iosapp`, xcodegen),
  the analyzer, build scripts (`native/scripts/`) and docs (`native/ROADMAP.md`,
  `native/SIGNING.md`). These apps use their own **GRDB** database and do **not**
  need the Python backend. CI: `.github/workflows/native-tests.yml` (primary) +
  the `release-macos`/`release-ios`/`release-analyzer` tag-triggered workflows.
- **`legacy-docker/`** — the **deprecated** Docker/FastAPI web app + MCP server,
  being decommissioned and kept for reference only. CI: `.github/workflows/test.yml`
  (path-filtered to `legacy-docker/**`).

> ⚠️ The "Project Overview", "Commands", "Architecture", and convention sections
> **below describe the legacy Docker/Python stack**, whose source now lives under
> `legacy-docker/`. Every relative path mentioned below (`backend/`, `frontend/`,
> `mcp_server.py`, `tests/`, `requirements*.txt`, `pyproject.toml`,
> `system_prompt.md`, `scripts/`, `config.example.yaml`, the `Dockerfile` and
> `docker-compose*.yml`) is now under `legacy-docker/`. Runtime `data/` stays at
> the repo root. Prefer working in `native/` unless a legacy reference fix is
> explicitly requested.

## Roon API constraints
Product/domain constraints that also apply to the native stack (originally documented against the
legacy Python backend — treat the file/symbol names as legacy references, the behaviour as real):
### Roon API constraints (NOT bugs — work around them)

- **No user ratings**: `user_rating` is always `None`. Any `min_rating` filter code has been removed.
- **No play counts via Roon**: `view_count` is hardcoded to `0`. Play counts come from the local `listening_history` table (logged by `roon_intelligence._log_listen`) + LB/LF stats.
- **No playlist creation via Roon Extension API**: use `qobuz_api.py` (direct Qobuz JSON API) for playlist save. `app_id` is auto-detected — never hardcode.
- **No direct track queries**: every library access goes through Browse hierarchy (Root → Library → Albums → tracks per album).
- **Metadata parsed from subtitle strings**: `"Artist • Year • Genre"` split on `•`. Fragile — defend against missing fields.
- **ARC zones invisible**: Roon ARC playback is not observable from the Extension API.
- **Single-session Browse API**: concurrent browse calls on the same hierarchy interfere. All Roon Browse sequences must be serialized — `_browse_lock` (and the album/genre variants) on `RoonClient` exists for this reason. Don't bypass it.
- **`hierarchy: "search"` (global search) returns ephemeral item keys**. They expire as soon as another browse/search call mutates session state. For Qobuz global-search fallback, `qobuz_browser.py` generates a synthetic key `qobuz_search::{url-encoded artist}::{url-encoded title}`; `roon_playback.play_tracks` detects this prefix and re-issues a fresh search at playback time. Don't try to "fix" this by storing the real key.

## Native build & release
> Authored (not transported) 2026-07-06, verified against the code that day. Native is the primary
> product; there is **no Docker/Python in this path**. Recheck a fact before relying on it if the
> tree has moved on.

**Packages & products** (`native/RoonSage/Package.swift`, platforms macOS 14 / iOS 17):
- Libraries: `RoonSageCore`, `RoonSageUI`, `AudioAnalysis`, `AnalyzerCore`.
- Executables: `RoonSage` (Mac app), `roonsage-mcp`, `roonsage-analyzer` (CLI analyzer), `RoonSageAnalyzerApp` (GUI analyzer). Second package: `native/RoonProtocol`.

**Build / test / lint** (each `cd`s into the package):
- `cd native/RoonProtocol && swift test` and `cd native/RoonSage && swift test`.
- Release-build sanity (CI runs this; a debug `swift test` can pass while release fails): `cd native/RoonSage && swift build -c release --product RoonSage`. The full CI release step also builds `--product RoonSageAnalyzerApp roonsage-analyzer roonsage-mcp`.
- Lint gate: `swiftlint lint --config .swiftlint.yml`.
- iOS: `cd native/iosapp && xcodegen generate` regenerates `RoonSageiOS.xcodeproj` from `project.yml` (bundle prefix `com.roonsage`, product `RoonSage`) — never hand-edit the `.xcodeproj`. Simulator build via `xcodebuild -project RoonSageiOS.xcodeproj -scheme RoonSageiOS`.

**Release DMGs & signing** (`native/SIGNING.md`, `native/scripts/`):
- `native/scripts/build-release.sh [version]` → signed+notarized `RoonSage.app` + DMG (bundle id `com.roonsage.native`); ad-hoc fallback when Apple creds absent. `native/scripts/build-analyzer-release.sh [version]` → `RoonSage Analyzer.app`.
- **Tag namespaces are interleaved and the scripts filter by prefix**: app `vX.Y.Z`, iOS `ios-vX.Y.Z`, analyzer `analyzer-vX.Y.Z`. An unfiltered `git describe` stamps the wrong version — never remove the `--match` filter.

**Runtime topology** (server-of-record):
- The **analyzer app is the server of record** — it runs the Roon sync + settings + analyses on the **Mac mini** and exposes two token-gated HTTP servers: **:5767** library share (`RoonSageCore/LibraryShareServer.swift`) and **:5766** analyzer/audio (`AnalyzerCore/HTTPServer.swift`). Mac + iOS apps are thin clients that pull over the network; playback stays per-device.
- Clients find the mini via Bonjour `_roonsage._tcp` + `/health` (its LAN IP shifts on DHCP, so never hardcode it). Reachable over LAN and ZeroTier.
- **Local analyzer install must be Developer-ID signed** — an ad-hoc build hangs on a keychain prompt and never binds. A stale client token is the #1 "won't connect" cause (diagnose via `roonsage.log`, fix in-app Settings → Server).
