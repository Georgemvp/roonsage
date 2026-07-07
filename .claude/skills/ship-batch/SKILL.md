---
name: ship-batch
description: Ship ONE verified RoonSage batch end-to-end — build → test → commit → push → tag all THREE version namespaces (v / ios-v / analyzer-v) → update docs/STATE.md. Use when the user says "ship it", "commit and tag", or asks to release the change you just made. Do ONE batch, not "everything" at once. Push/tag ONLY when the user asked for it in this conversation.
---

# ship-batch — one verified RoonSage batch, all the way out

The project ships incrementally: **one batch → build/test → commit + push + tag → STATE.md**.
Do a single batch, never bundle "alles" together. The three tag namespaces are interleaved
and must move together — forgetting one is the recurring mistake.

## Preconditions

- The change is complete and you know exactly which files it touched.
- `git push` / `gh` is only legal if the user asked for a push in THIS conversation — quote
  their words beside the command (hard stop). If they didn't, commit locally and report.

## Steps

1. **Verify — real exit code** (see the `native-check` skill):
   ```
   cd native/RoonSage && swift build && swift test
   ```
   Record `N tests, 0 failures`. Red? Quote it, propose, wait — never weaken a test.
2. **Pick the next version numbers.** Bump each namespace by one patch from the latest of
   its OWN prefix:
   ```
   git tag --sort=-creatordate | grep -E '^v'          | head -1   # app     → next vX.Y.Z
   git tag --sort=-creatordate | grep -E '^ios-v'      | head -1   # iOS     → next ios-vX.Y.Z
   git tag --sort=-creatordate | grep -E '^analyzer-v' | head -1   # analyzer→ next analyzer-vX.Y.Z
   ```
   Keep steps small (4-component patch bumps) — the user prefers small iterative tags.
3. **Commit** (Conventional Commits, matching recent `feat(native): …` / `fix(native): …`
   style). End the body with the Co-Authored-By trailer.
4. **Push** (only if authorized — see Preconditions):
   ```
   git push
   ```
5. **Tag all three and push the tags** — the release scripts filter `git describe` by
   prefix, so every namespace needs its own tag or the wrong version gets stamped:
   ```
   git tag vX.Y.Z && git tag ios-vX.Y.Z && git tag analyzer-vX.Y.Z
   git push --tags
   ```
   Tagging triggers `.github/workflows/release-{macos,ios,analyzer}.yml`.
6. **Update docs/STATE.md** in the same turn: move the batch into `## Done` with a
   `RESULT: <commit> <versions> <N tests>` line, and update `## Now` / `## Next`.

## Deploy

Tags build release artifacts in CI; they do NOT deploy to the Mac mini. To put the
**analyzer server** live on the mini, use the `deploy-mini` skill. **Never** deploy the
client app to the mini (hard constraint).
