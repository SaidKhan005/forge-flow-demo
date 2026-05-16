# Fix #4 Spec — Real HP#11 Effective-Value Resolution (G13 / G40 / G41 / G42)

> **STATUS UPDATE 2026-05-16 (operator decision — see register §0):** **G10/G40 data-accuracy covers/wage SOURCE scoping is ruled INTENDED, not a gap — DROPPED from this spec.** Only the timing-faking residual (**G41, G42, G13**) remains in scope, and it is **PARKED** (build deferred until operator resumes). Treat the G40/data-accuracy portions below as out-of-scope; the G41/G42/G13 design still stands.

**Date:** 2026-05-16 · **Status:** spec approved by operator (spec-first; build deferred until Fix #1 & #2 merge).
**Closes:** audit findings G13, G40, G41, G42 (`cross_surface_parity_audit_2026_05_16.md`).
**Cross-ref:** per-daypart plan Gaps 27/28/29/30/31/32/36/46/47; CLAUDE.md HP#11; `docs/contracts/core_app_architecture.md` settings layer.

## Root cause
The canonical hierarchy chain (`BusinessTimingProfilesRepository.listCandidateProfilesForLocation` → `BusinessTimingProfileResolver.resolve`) is reached only by backend sinks + the open-shift projector. Every display surface (operator-web Business setup, admin Timing / Data-Accuracy / Polling) renders HP#11 chrome from faked, synthetic, or org-unit-discarding inputs.

## 1. Canonical source of truth
- Chain (do NOT modify): `business_timing_profiles_repository.dart:60-138` (ltree ancestor CTE, ordered `scope_depth asc`) → `business_timing_profile_resolver.dart:24-132` (pure; candidates highest-scope-first; fields override field-by-field; service periods override atomically) → `EffectiveBusinessTimingProfile` (`business_timing_profile.dart:72-91`) with `inheritanceChain`/`resolvedScope`.
- Reference caller to mirror: `open_shift_snapshot_projector.dart:38-94` / `sink_business_date_projector.dart:178-243` (the ~30-line row→`BusinessTimingProfile` mapping is the blessed reuse boundary, byte-identical between the two).
- Layering: `lib/domain` is pure and importable by display layers; the **repository** is infra → Flutter clients reach it via the **proxy**. Preferred architecture: proxy returns the **full ordered candidate list with scope ancestry**; client runs the pure resolver (one resolver, no server fork).

### Backend prerequisite (THE blocking gap)
`GET /v1/operator/business-timing-profiles` (`operator_routes.dart:578-604` → `repository.listProfilesForOperator`) does NOT: run the location-specific org-unit ancestor filter; carry `locations.timezone` (hardcoded `null` at repo `:559`); carry org-unit `path`/location `org_unit_path`. Wire records `OperatorBusinessTimingProfileRecord`/`...ServicePeriodRecord` (`operator_write_contracts.dart:47-111`) DROP `applicableDays`/`shortLabel`/`sortOrder`; `_toServicePeriodWrite` hardcodes `applicableWeekdays:[1..7]`, `shortLabel:''` (`repository_operator_write_gateways.dart:228-242`). Until the proxy exposes a location-scoped, ancestor-filtered, ancestry-tagged candidate list with full service-period fields, no UI fix can show real inherited-from values.

## 2. Per-surface fix (summary; full detail below)
- **G13 (operator-web):** DELETE `business_business_timing_resolver_local.dart` (lossy duplicate; `:56` same-value heuristic mislabels overrides). Rewrite `http_business_timing_read_gateway.dart` `_projectBundle` (`:89-217`) to consume full ordered candidates → canonical resolver → per-field provenance from `inheritanceChain`. `web_business_timing_gateway.dart` `listProfiles` (`:78-106`) → location-scoped read. `business_setup_screen.dart` `_hierarchyTreeNodesFromBundle` (`:260-322`) renders real org-unit rungs; TODO `:338` closes. Fold in G45/Gap 28 (day-restricted periods round-trip).
- **G40 (admin data-accuracy + polling):** rework `admin_hierarchy_settings_scope_policy.dart` `decorate` (`:10-50`) to emit real `inheritedFromBusiness/OrgUnit/setAtScope` + real `inheritedFromLabel` instead of always `setAtScope`/static strings (`:98-123`). The `valueState`→copy mapping in `admin_route_handoff.dart:241-260` is already correct. Co-fix G10/Gap 29 (data-accuracy missing `HierarchyScopeNotice`).
- **G41 (admin timing setup):** delete hardcoded periods (`admin_timing_setup_screen.dart:211-216`), week-start (`:194`), close-rule (`:195-199`), legacy `_businessDayStart(businessDayRolloverHour)` (`:192,230-233`). Wire `_TimingSummaryCard` to resolved `EffectiveBusinessTimingProfile` via new admin route. Respect Gap 31 (shift_close_authority being deleted as operator setting — show auto-derived read-only or omit).
- **G42 (admin operator-location):** delete `_AdminTimingResolution.forScope` synthetic candidates (`:3691-3766`), `_defaultAdminTimingServicePeriods` (`:3809-3841`), `_rolloverToLocalTime` (`:3843-3846`). Wire `forScope` to real candidate list → canonical resolver → provenance from `inheritanceChain`.

## 3. Slice breakdown (independently-reviewable PRs)

| Slice | Title | Files | Depends | Conflict / gate |
|---|---|---|---|---|
| S1 (backend prereq) | Operator-web location-scoped resolution route + wire model (+ G45 day-restricted round-trip) | `tool/advisor_proxy/operator_routes.dart`, `operator_write_contracts.dart`, `repository_operator_write_gateways.dart` | none | proxy/contract-touching → **operator approval gate**. No Fix #1/#2 overlap. |
| S2 (backend prereq) | Admin cross-tenant business-timing resolution (`withSystem` location-scoped read) + data-accuracy/polling effective-source gateway | `tool/advisor_proxy/` admin routes, admin gateways, `business_timing_profiles_repository.dart` (add `withSystem` read) | none | RLS/proxy-touching → **operator approval gate**. Rebase after Fix #2 merges. |
| S3 (UI) | G13 operator-web Business setup; delete local resolver | `lib/operator_web/services/{http_business_timing_read_gateway,web_business_timing_gateway}.dart`, `business_setup_screen.dart` | S1 | operator-web non-auth → no Fix #1 collision (confirm Fix #1 doesn't touch `web_business_timing_gateway.dart`). |
| S4 (UI) | G41 + G42 admin timing surfaces | `admin_timing_setup_screen.dart`, `operator_location_admin_screen.dart` | S2 | `lib/admin/**` → after Fix #2 merges; rebase. |
| S5 (UI) | G40 admin data-accuracy + polling scope policy (+ G10/Gap 29) | `admin_hierarchy_settings_scope_policy.dart`, `per_location_data_accuracy_screen.dart`, `polling_and_pricing_admin_screen.dart` | S2 | `lib/admin/**` → after Fix #2; co-fix G10. |

Sequencing: S1/S3 (operator-web) parallelizable with Fix #2. S2/S4/S5 (admin) must rebase on Fix #2's `lib/admin/**`.

## 4. Risk & contract
- All four are HP#11 *correctness* fixes (chrome currently lies). Resolver itself unchanged (already `7.58`-clean). **S1/S2 are proxy/RLS-touching → explicit operator approval required.** No `7.58` Primary-Driver dependency (read projections, not decision logic). No `demo_*` tables, no `kDemoMode` reader branch.
- **Mandatory parity test** (per D7/G51 lesson): feed the same `(operatorId, locationId, businessDate)` through (a) `SinkBusinessDateProjector`/`PostgresOpenShiftTimingProfileSource` and (b) the new display projection; assert identical `EffectiveBusinessTimingProfile`. Plus: wire-shape test (ancestor rows in `scope_depth` order with full period fields); provenance test (3-level fixture incl. deliberate same-value override case the deleted heuristic got wrong).

## 5. Open questions for the operator (resolve before build)
1. **Gap 32 wage scope:** should G40 data-accuracy effective-value include wage-source scope, or stay covers-only with wage deferred to Gap 32? (Affects S2/S5 gateway shape.)
2. **Gap 36 enum vs keyed:** does the locked Gap 36 decision (kill legacy 3-period `Daypart` enum, backfill in Slice 2) land before S5, or must S5 tolerate the legacy enum during transition?
3. **G41/G42 read-only intent:** is admin *meant* to write business-timing cross-tenant (via `createProfileAsSystem`), or is admin intentionally read-only (operator owns timing via operator-web)? If read-only, S4 keeps the banner but makes displayed values real.
4. **S1 route placement:** extend `GET /v1/operator/business-timing-profiles` with `?locationId=` (smaller, overloads 11W.7 list route) vs new `GET /v1/operator/locations/:locationId/business-timing-resolution` (cleaner, new route + idempotency/versioning surface)?

Source agent (read-only, resumable): `a0e291471e53d475f`.
