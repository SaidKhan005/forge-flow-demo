# Advisor-Proxy Split — Plan (stub)

Status: Planned (sequencing TBD; tracked here so cross-cutting
proxy-monolith debt has a single home)
Owner: To be assigned when `tool/advisor_proxy/advisor_proxy.dart`
splits formally enter a phase.

## Why This Doc Exists

`tool/advisor_proxy/advisor_proxy.dart` is the largest file in the
repo (16,949 lines as of 2026-05-08, +2,449 since 2026-05-06). It
holds request handling for every proxy route, is touched by nearly
every CODE_HEALTH wave, and reaccumulates debt faster than those
waves can clear it. The split is a multi-phase effort that needs its
own plan separate from any single feature lane.

This stub captures pre-split cleanup items that don't fit cleanly
into other phase docs. As the split formally lands, this file expands
into a real route-by-route migration plan; until then, it's a holding
pen for cross-cutting work.

## Pre-Split Cleanup

Items below must close before — or as part of — the formal split.
Each is too small to deserve its own slice, too AI-freeze-adjacent or
proxy-internal to belong elsewhere.

### `tool/advisor_proxy/advisor_proxy.dart` — 16 bare catches in request-handling path

Origin: 2026-05-08 audit-additions sweep
(`docs/POST_HARDENING_FOLLOWUPS.md`). PR
[#420](https://github.com/SaidKhan005/forge-flow-demo/pull/420) closed
the analogous bare-catch tail in 3 sibling files
(`auth_session_notifier.dart`, `tenant_transaction.dart`,
`package_postgres_executor.dart` — 11 sites total) using the same
typed-arms pattern that landed in CODE_HEALTH Wave 5
([#364](https://github.com/SaidKhan005/forge-flow-demo/pull/364)).

The 16 advisor-proxy sites were intentionally deferred because the
monolith is too risky for a one-shot agent — line numbers drift
heavily as other lanes touch the file, and a single bad rebase could
silently revert one of the typed arms.

Affected lines (as of 2026-05-08):
`1319, 1352, 1429, 1661, 1698, 1789, 1944, 1974, 1980, 1997, 2306,
2540, 2618, 5143, 5221, 5274`.

Fix shape (same as PR #420):

- Replace `} catch (_) {` with `} on TimeoutException catch (e, st) {
  ... } on Exception catch (e, st) { ... } on Object catch (e, st) {
  ... }`.
- Each arm logs through the project `log()` helper from
  `lib/services/observability/log.dart` with a stable event name
  derived from the surrounding method.
- Preserve the existing rethrow / swallow semantics per arm — the
  audit confirms current behavior is intentional, only the silent-
  failure visibility is the bug.

Sequencing options:

1. As part of the first split slice — natural fit because each split
   slice extracts a route group and can fix the catches in that group
   as it goes.
2. As a one-shot lane against current `master` if the split is more
   than a sprint away.

Reviewer's call when the split phase opens.

## Out of Scope For This Stub

- The actual route-by-route split plan (lands when the split phase
  opens; at that point this stub becomes the first section).
- `lib/admin/admin_routes.dart` — the sibling 2,204-line monolith
  noted in POST_HARDENING_FOLLOWUPS P3. That has its own debt curve;
  separate phase doc when sequenced.
- AI-freeze items (placeholder prompt strings at lines 9105-9106).
  Tracked under `docs/phases/phase_11b/phase_11b_advisor_ux_plan.md`
  "Freeze-thaw pre-conditions" — they unfreeze on the AI lane, not
  the proxy-split lane.

## Cross-References

- `docs/POST_HARDENING_FOLLOWUPS.md` — P3 monolith debt entry +
  bare-catch P2 entry pointer
- PR #420 — typed-arms pattern reference (3 sibling files)
- PR #364 — original Wave 5 LB3 fix that established the pattern
