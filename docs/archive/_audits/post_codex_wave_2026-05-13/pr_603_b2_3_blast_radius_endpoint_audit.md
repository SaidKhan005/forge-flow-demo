# PR #603 Audit — B2.3 Default Role Catalog Blast-Radius Endpoint

**Slice:** B2.3 (Lane B — B2.2 follow-up; added 2026-05-13 per operator's "no business live yet" direction)
**Owner:** Claude
**Branch:** `claude/b2-3-blast-radius-endpoint`
**Base:** `master`
**Gate:** `auto` per ledger row B2.3 (pre-reconciled — read-only admin observability surface; zero live operators)
**Risk:** **Low** — read-only endpoint, no schema/auth/RLS surface change, single CTE round-trip
**Size:** 1597 additions / 42 deletions / 9 files (light variant audit — <20 files, <5K LoC)

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation. Pattern B exemplary (worker 14L + executor 14L). Closes B2.2 Gap 1 (numeric blast-radius counts) per the ledger entry the operator authorized in Bundle 39. Read-only endpoint reading existing tables. `runAsSystem` (admin-pool BYPASSRLS) for cross-operator aggregate matches CLAUDE.md "RLS-Ready Schema" for F&F-global tables. Single CTE pattern immune to concurrent operator-flip drift. Bleed-stop lint stays well under ceiling.

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables (worker self-audit + executor independent audit) present in PR body with file:line citations. Executor adds 3 executor-only lenses (12: CTE single-round-trip correctness; 13: bleed-stop ratchet; 14: honest-gap discipline).

## What landed

### 1. New admin endpoint (`tool/advisor_proxy/admin_default_role_catalog_routes.dart`, +117/-7)

- `GET /v1/admin/auth/role-catalogs/blast-radius?version_id=<uuid>` admits `{super_admin, ff_support}` via `kDefaultRoleCatalogAdminReadRoles` (defined at line 79)
- Returns JSON `{operator_count, location_count, user_count, version_id}`
- 3 status code paths pinned by tests: 400 (missing/malformed version_id), 404 (unknown version), 200 (happy path)

### 2. Repository read aggregate (`default_role_catalog_versions_repository.dart`, +126)

- New method via `_tenantWrapper.runAsSystem<DefaultRoleCatalogBlastRadiusCounts>` (admin-pool BYPASSRLS — required for F&F-global table aggregate)
- Single CTE:
  ```sql
  with pinned_operators as (
    select operator_id from public.operators
    where default_role_catalog_version_id = $version_id::uuid
  )
  select
    (select count(*) from pinned_operators) as operator_count,
    ...
  ```
- Three subqueries off one snapshot — concurrent operator-flip cannot create partial-result skew within a single query
- `coalesce(count, 0)` defense

### 3. Admin gateway client (`lib/admin/services/default_role_catalog_admin_gateway.dart`, +109/-6)

- HTTP wrapper for the new endpoint with proper 400/404/error code mapping
- `InMemoryDefaultRoleCatalogAdminGateway` extended for demo fallback (existing B2.2 pattern)

### 4. Publish dialog wiring (`lib/admin/screens/default_role_catalog_publish_dialog.dart`, +173/-28)

- Fires blast-radius fetch on dialog open (non-genesis publishes)
- Tri-state rendering:
  - Success → slice-specced "Affecting N businesses, M locations, P users currently following version X"
  - Zero counts (genesis / pre-first-pin) → plain-English fallback copy
  - Error → plain-English fallback + error chip surfacing proxy code for engineering support

### 5. Test coverage (31 new tests + 42 regression-checked clean)

- 19 route tests (`b2_3_default_role_catalog_blast_radius_test.dart`, NEW)
- 8 repository tests (`default_role_catalog_versions_repository_blast_radius_test.dart`, NEW)
- 4 new dialog cases + 4 pre-existing kept passing
- 21 B2.1 routes + 12 B2.1 repo + 8 admin screen regression-checked clean
- Full `flutter test test/admin/` sweep: +493 pass

### 6. Proxy dispatcher threading (`tool/advisor_proxy/advisor_proxy.dart`, +2)

- `versionIdQueryParam` threaded via default-null parameter — preserves B2.1 callsites
- Just +2 lines (no logic in the monolith; bulk in `admin_default_role_catalog_routes.dart`)

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `super_admin` + `ff_support` admit; others 403 | `admin_default_role_catalog_routes.dart:79` (`kDefaultRoleCatalogAdminReadRoles`) + 4 role-gate test cases | Set definition verified at line 79; test cases pin 200 admit / 403 deny |
| `runAsSystem` (admin-pool BYPASSRLS) for cross-operator aggregate | `default_role_catalog_versions_repository.dart:418` | F&F-global table (no `operator_id` column on `default_role_catalog_versions`); `runAsSystem` is the correct posture per CLAUDE.md "RLS-Ready Schema" |
| Single CTE — three counts off one operator snapshot | repo lines 425-430 | `with pinned_operators as (...)` defines snapshot once; three subqueries off the CTE; immune to concurrent operator-flip drift mid-query |
| Read-only — no mutation surface | route file scope | GET only; no `INSERT`/`UPDATE`/`DELETE` SQL; no `audit_logs` row emitted; `audit_logs_update_lint` disclosed clean |
| No new permission key (frozen `lib/auth/**` untouched) | diff scope | Zero changes under `lib/auth/`; role gate uses existing role catalog |
| No migration | diff scope | Zero changes under `db/migrations/`; reads existing `public.operators`, `public.locations`, `public.users` |
| Bleed-stop lint clean | `wc -l tool/advisor_proxy/advisor_proxy.dart` | 19,805 / 19,900 (headroom 95); worker's +2 LoC verified |
| Backwards-compat for B2.1 callsites | route dispatcher | `versionIdQueryParam` is default-null; existing publish/list/get callsites unaffected |
| Plain-English fallback preserved | dialog tri-state | Zero counts → fallback copy; error → fallback + error chip with proxy code |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master | ✓ — mergeable (UNKNOWN/MERGEABLE at audit start; should be CLEAN at merge) |
| Pattern B both tables present | ✓ — worker 14L + executor 14L with file:line citations |
| Role gate matches B2.1 GET posture | ✓ — `{super_admin, ff_support}` admit per 4 route test cases |
| `runAsSystem` for F&F-global aggregate | ✓ — verified at repo line 418 |
| Single CTE — three counts immune to drift | ✓ — verified at repo lines 425-430 |
| No migration, no new permission key, no audit_logs writes | ✓ — diff scope confirms |
| `versionIdQueryParam` default-null threading | ✓ — backwards-compat preserved |
| Bleed-stop lint clean post-merge | ✓ — `advisor_proxy.dart` 19,805 / 19,900 |
| Test coverage comprehensive | ✓ — 31 new + 42 regression-checked clean |
| `dart analyze --fatal-infos` clean | ✓ disclosed |
| `postgres_import_lint` clean | ✓ disclosed |
| `audit_logs_update_lint` clean | ✓ disclosed |
| No `--no-verify` traces | ✓ |
| No tracker / ledger / lane-index touches | ✓ — diff scope confirms |
| No Codex-owned conflict | ✓ — Claude lane B2.x territory |

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables present with file:line citations.

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — ledger row B2.3 pre-set to auto-gate per operator direction; PR title correctly has NO `[operator-approval-required]` prefix |
| Worker disclosure operator should know | ⚠ TWO non-blocking disclosures: (a) **5 pre-existing test failures** in `test/proxy/` reproducible on master pre-B2.3 — NOT introduced by B2.3, mirror of the A3.4 + admin_cors_bootstrap_test + B11.2.b time-bomb pattern; **investigation candidate** for closeout (could be ignored if `KNOWN_FAILING_TESTS` already tracks); (b) **user-count caveat** — `public.users` has no soft-delete/active column at current schema, so `user_count` is total users-on-file for pinned operators, not active-only. Documented in repository method dartdoc. |
| Stacked PR | ❌ — base is master |

**Decision**: per expanded policy. Read-only admin observability surface with zero live operators today. Sensitive paths (`tool/advisor_proxy/**` + repository) are pre-reconciled to auto-gate by operator direction. The two disclosures are forward-looking transparency, not regressions.

## Cross-lane notes

- **Closes B2.2 Gap 1** (numeric blast-radius counts) per the ledger entry the operator authorized in Bundle 39 ("ship now while there's zero SendGrid traffic" direction applied to B2.2 follow-ups)
- **B2.2 Gap 2** (per-role `catalog_published_at` annotation) remains **B2.4's territory** — separate slice
- **5 pre-existing test failures in `test/proxy/`** — surfaced by B2.3's full-sweep test run; not introduced by B2.3. Failing tests: `audit_chain_anchors_routes_test.dart`, `health_producers/infra_producers_test.dart`, `health_producers/rollup_producers_test.dart`, `integration_admin_proxy_gateway_kms_revision_test.dart`, `registry_proxy_health_check_store_test.dart`. **Investigation candidate** for the closeout phase — may be wall-clock time bombs (B11.2.b pattern) or stale snapshots (admin_cors_bootstrap_test pattern) or genuinely broken
- **No Codex-owned files touched**

## Findings

None blocking. The two honest disclosures are forward-looking transparency for the closeout phase.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row B2.3 — ledger row pre-reconciled to auto-gate per operator direction
- B2.2 (PR #590) audit — Gap 1 disclosure
- B2.1 (PR #584) — admin-route gateway pattern + role gate posture this slice reuses
- CLAUDE.md "Proxy & API Conventions" — read-only GET semantics
- CLAUDE.md "RLS-Ready Schema" — `runAsSystem` for F&F-global table cross-operator aggregate
- `project_ux_writing_standard.md` — plain English in fallback copy
- Operator's 2026-05-13 "no business live yet so mutations are fine" direction

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. 5 pre-existing test failures flagged as closeout-phase investigation candidate.
