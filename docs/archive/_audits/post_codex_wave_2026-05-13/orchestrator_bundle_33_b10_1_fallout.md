# Orchestrator Bundle 33 — B10.1 Fallout Cleanup

**Slice:** orchestrator follow-up (B10.1 audit miss correction)
**Owner:** orchestrator
**Branch:** `claude/orchestrator-bundle-33-b10-1-fallout`
**Base:** `master`
**Trigger:** A3.4 worker honest disclosures (PR #581) surfaced 2 issues my B10.1 audit (PR #576) missed

## Verdict

**approve-for-merge** (self-audit) — minimal-scope cleanup, 2 files, behavior-preserving.

## What landed in this bundle

### 1. Raise `kAdvisorProxyMaxLines` ceiling: 19,071 → 19,600

`tool/advisor_proxy_size_lint.dart:72`

Why: B10.1 (PR #576) added ~400 lines to `advisor_proxy.dart` for vendor-applicability route handlers + super_admin gates + idempotency stores. The B10.1 worker did NOT raise the ceiling; I (orchestrator) didn't catch this in my B10.1 audit. Master post-B10.1 was 19,458 / 19,071 (387 over ceiling — bleed-stop lint would FAIL on master).

After A3.4 (PR #581) landed +78 more lines: master is 19,543 / 19,600 with new ceiling — clean.

Why 19,600 (not higher): per A3.4 worker's recommendation. Maintains tight-ratchet discipline; 57 headroom is consistent with A3.2/A3.3 ratchet pattern. Future bleeds need explicit raises per the seam-map "Section 2 — Bleed-stop policy" rule.

### 2. Type the B10.1 carry-forward bare-catch at line 14109

`tool/advisor_proxy/advisor_proxy.dart:14109`

Was bare `} catch (_)` inside vendor-applicability admin route's `integrationAdminActorResolver.resolveActorUserId` block. Worker correctly didn't touch in A3.4 per "no silent scope expansion" discipline (B10.1 introduced this site AFTER A3.4 was scoped). Now narrowed to `} on Exception catch (_)` with 7-line rationale comment naming concrete throw classes (`PgException`, `TimeoutException`, `IOException`, JWT/claim Exception subtypes) + addendum C4 invariant.

Same idiom as A3.4's 26 sites. `Error`-class throws propagate to `runZonedGuarded` per addendum C4.

## Files changed

- `tool/advisor_proxy_size_lint.dart`: 1 line change (ceiling 19071 → 19600)
- `tool/advisor_proxy/advisor_proxy.dart`: 8 lines (catch keyword + 7-line rationale comment)

**Total**: +8 / -1 / 2 files

## Verification

| Check | Result |
|---|---|
| `dart run tool/advisor_proxy_size_lint.dart` | **clean — 19,543 / 19,600 (headroom 57)** |
| `dart analyze --fatal-infos tool/advisor_proxy/advisor_proxy.dart tool/advisor_proxy_size_lint.dart` | **No issues found** |
| Bare-catch grep on `advisor_proxy.dart` post-edit | **2 hits** (2426 + 7107) — both intentional retentions; carry-forward at 14109 NOW typed |

## What this does NOT address (deferred)

- **admin_cors_bootstrap_test pre-existing failures** (5 failures, reproducible on master `9ed941ad`+) — needs investigation; probably B10.1 fallout but root-cause unclear. Filed for separate orchestrator slice or operator decision.

## Cross-lane note

None. Bundle is orchestrator-owned cleanup of B10.1 (Codex) + A3.4 (Claude) fallout. No live worker has these files checked out.

## Findings

None blocking. Bundle restores master to a clean lint state and types the one carry-forward bare-catch that completes the A3.x sweep semantically (final site that couldn't land in A3.4 due to scope discipline).

## Authority anchors

- PR #581 (A3.4) worker honest disclosures — surfaced both issues
- PR #576 (B10.1) audit doc — my miss, corrected by this bundle
- `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` "Section 2 — Bleed-stop policy" — ratchet doctrine
- CLAUDE.md "addendum C4 — no silent failures" — typed-catch invariant
- `docs/_audits/post_codex_wave/pr_581_a3_4_bare_catch_typing_chunk_3_audit.md` — explicit follow-up list

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. Self-audit clean.
