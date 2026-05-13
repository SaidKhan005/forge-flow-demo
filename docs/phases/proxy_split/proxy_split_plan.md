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

## Seam Map — Cluster Summary (A3.1)

Slice A3.1 (2026-05-12) shipped a full cluster-level seam map for the
monolith plus a CI bleed-stop lint. The seam map proper lives at
`docs/_audits/code_health/a3_advisor_proxy_seam_map.md`; the 25-step
extraction sequence the seam map is consumed by lives at
`docs/_audits/code_health/a3_proxy_monolith_decomposition.md`. The
cluster table is reproduced here so this plan doc carries the at-a-
glance view future split work needs.

**Snapshot:** 2026-05-12, master commit `6ab8f73c` (post-PR-#522
A11.1 session-record-gauge merge),
`tool/advisor_proxy/advisor_proxy.dart` = 18,871 lines. The
bleed-stop lint (`tool/advisor_proxy_size_lint.dart`) caps the file
at 19,071 lines (+200 headroom) and ratchets DOWN as decomposition
lands.

| #  | Cluster                                              | Start | End   | LoC   | Future extraction target                                   |
| -: | ---------------------------------------------------- | ----: | ----: | ----: | ---------------------------------------------------------- |
|  1 | File header + imports                                |     1 |   256 |   256 | stays in `advisor_proxy.dart`                              |
|  2 | Config + secrets + vendor app credentials            |   257 |  1120 |   864 | `config/proxy_config.dart`                                 |
|  3 | JWT verification (claims, Firebase, OperatorContext) |  1122 |  2291 | 1,170 | `jwt/` sub-tree (Decomp Step 12)                           |
|  4 | Policy / usage / SP issuance / accounting            |  2292 |  3670 | 1,379 | `policy/` + `routes/service_principals.dart` (Steps 10/13) |
|  5 | Health surface (registry, dependency probe)          |  3671 |  5596 | 1,926 | `health/` sub-tree (Step 15)                               |
|  6 | LLM provider plumbing (Anthropic / Gemini / pipeline)|  5597 |  6514 |   918 | `llm/` sub-tree (Step 14)                                  |
|  7 | Auth lockout + A11.1 session-record-gauge            |  6516 |  7060 |   545 | `routes/auth_lockout.dart` (Step 6) + `_shared/session_record_gauge.dart` carve-out |
|  8 | Path constants + admin gateway abstractions          |  7061 |  8511 | 1,451 | `routes/_paths.dart` (Step 0) + admin gateway homes        |
|  9 | `routeRequest` mega-function                         |  8512 | 14910 | 6,399 | `routes/*.dart` per family (Steps 2-9, 11, 16-24)          |
| 10 | Top-level `_routeXxxAdmin` delegates                 | 14911 | 17391 | 2,481 | `routes/admin_*.dart` (Steps 16-22)                        |
| 11 | Predicate matchers + helpers + scope guards          | 17392 | 18581 | 1,190 | `routes/_shared/` (Step 1) + `routes/auth_team_admin.dart` (Step 23) |
| 12 | CORS + JSON body + response writer tail              | 18582 | 18871 |   290 | `routes/_shared/{cors,response,json_body}.dart` (Step 1)   |

**Total:** 12 clusters, 18,871 lines.

For per-cluster anchor markers, drain ordering aligned to the 25
Decomp steps, the bleed-stop ratchet rule, and the cluster → Decomp
step cross-reference, see
`docs/_audits/code_health/a3_advisor_proxy_seam_map.md`.

## Cross-References

- `docs/POST_HARDENING_FOLLOWUPS.md` — P3 monolith debt entry +
  bare-catch P2 entry pointer
- PR #420 — typed-arms pattern reference (3 sibling files)
- PR #364 — original Wave 5 LB3 fix that established the pattern
- `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` — A3.1
  seam map proper (cluster table + bleed-stop policy + Decomp
  cross-reference)
- `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` —
  the 25-step extraction sequence the seam map is consumed by
- `tool/advisor_proxy_size_lint.dart` — A3.1 bleed-stop lint
