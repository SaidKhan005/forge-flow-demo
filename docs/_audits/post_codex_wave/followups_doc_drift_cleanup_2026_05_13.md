# Followups Doc Drift Cleanup — 2026-05-13

**Scope:** Three mechanical doc-drift fixes to `docs/POST_HARDENING_FOLLOWUPS.md` identified during the orchestrator's reclassification pass (no behavior change; no ledger changes).

**Verdict:** approve-for-merge (orchestrator-authored, audit-doc-attached, no slice impact).

## Fixes applied

1. **P2 kDemoMode reader-side carve-out entry** — Resolution line added matching the ✅ FIXED heading; body's stale Action items preserved above for audit trail.
2. **P3 docs/_execution retirement window** — heading flipped to "opened … ✅ FIRST SWEEP COMPLETE"; resolution line documents PR #539 → `d1c2e167` (41 archive files swept 2026-05-13).
3. **P3 monolith debt — advisor_proxy.dart line count** — refreshed 16,949 → 18,871 (A3.1 measurement); added the bleed-stop ceiling 19,071 + 200 headroom context.

## What this does NOT touch

- No new ledger rows (orchestrator reviewed every P0-P3 entry against the discipline test; remaining items have no next-3-sprint slice home).
- No new memory rules.
- No CLAUDE.md edits.
- No other content in POST_HARDENING_FOLLOWUPS.md.

## Authority anchors

- `~/.claude/projects/.../memory/feedback_followups_doc_hygiene.md` — ledger-first discipline that surfaced these doc-drift items during routine sweep.
- PR #417 (kDemoMode Carve-out #3 sign-off 2026-05-08).
- PR #539 (docs/_execution archive-file sweep 2026-05-13).
- PR #533 (A3.1 advisor_proxy.dart measurement 18,871 + bleed-stop 19,071).

## Status

Ready for orchestrator merge.
