---
name: next-batch
description: Resume RoonSage work — read docs/STATE.md, take the NEXT batch from ## Next, and work it incrementally. Use at session start, after /resume or compaction, or when the user says "ga verder", "volgende batch", or "fix alles" without naming a specific item. Honors ## Constraints; ships one batch, not "alles".
---

# next-batch — pick up the audit where it left off

docs/STATE.md is the source of truth for what's shipped and what's next. This skill is the
project-tuned resume; it composes with the session guardrail (docs/guardrails/SESSION.md).

## Steps

1. **Read state, first.** Read `docs/STATE.md` in full — the START-HIER block at the top,
   then `## Now`, `## Next`, `## Constraints`, and the tail of `## Done` (last shipped
   versions). If returning from compaction/resume, also honor routing row 6:
   `TRIGGER: returned from compaction -> docs/guardrails/SESSION.md` and Read it (S1 first).
2. **Pick ONE batch** from `## Next` (top of the list unless the user named a specific item).
   Do NOT attempt "alles" at once. If the user named a feature, do that one instead.
3. **Confirm it's not already done.** Several `## Next` items turned out already-shipped
   (loudness-normalisatie, share-tekst). Grep for the type/symbol before building — if it
   exists with tests, mark it done in STATE.md and move to the next item instead.
4. **Plan if it's non-trivial** (>2 file edits or >1 directory): routing row 1 →
   `docs/guardrails/PLAN.md`, post a TASK block.
5. **Implement one batch** → verify with the `native-check` skill (real exit code).
6. **Ship** with the `ship-batch` skill: commit + push + tag all three namespaces
   (v / ios-v / analyzer-v) + update STATE.md — **only if** the user has authorized
   push/tag in this conversation.
7. **Deploy** only if asked, via the `deploy-mini` skill (analyzer server only).

## Constraints to carry (from STATE.md `## Constraints`)

- Never weaken tests to make them green (hard stop).
- Never deploy the client app to the mini — analyzer server only.
- Commit + push + tag per verified batch (v + ios-v + analyzer-v) — when authorized.
- Anything the user says "niet / alleen / stop / hou" → append verbatim to STATE.md
  `## Constraints` this turn.
