# Phase 3 — Priority Code/Schema-Binding Contracts vs Code Alignment Audit

Audit date: 2026-05-18
Auditor: Claude doc-alignment worker (Phase 3)
Scope: The higher-priority code/schema-binding `docs/contracts/**` not
covered by Phase 1 (`phase1_core_app_architecture.md`) or Phase 2
(`phase2_tier2_contracts.md`). Line-by-line material-claim audit vs live
`lib/**` + `db/migrations/**` + `tool/advisor_proxy/**`.
Authority order per `CLAUDE.md` "Authority Order": active prompt > Tier-2
canonical architecture > other Tier-2/3 contracts > trackers > phase docs
> `CLAUDE.md`. On conflict, a later dated decision with its own migration
supersedes an earlier lean-cut ban (Cost & Convergence "decide before
dispatch"; the contract not updated to match is then STALE on that point).

Classification key (same as Phase 2):
- **ALIGNED** — doc claim matches live code.
- **DRIFTED** — doc claim and code disagree on substance; both still live.
- **STALE** — doc references a path/line/state that has moved or no longer
  exists, OR a bookkeeping instruction that points at a convention that no
  longer exists; the binding substance may still be correct.
- **STALE-CITATION** — narrower STALE: rule correct, only a line/path
  reference is outdated (Phase 2 distinction preserved).

Contracts thoroughly audited this pass (11):

1. `hardening_feature_flag_idempotency_contract.md` — thorough
2. `hardening_auth_protection_contract.md` — thorough
3. `hardening_admin_cors_and_limits_contract.md` — thorough
4. `hardening_observability_baseline_contract.md` — thorough
5. `hardening_production_wiring_contract.md` — thorough
6. `hardening_devops_surface_contract.md` — thorough
7. `hardening_test_corrections_contract.md` — thorough
8. `auth_permission_key_catalog.md` — thorough (vs `lib/auth/**`)
9. `proxy_health_contract.md` — thorough
10. `metric_card_honesty_contract.md` — thorough
11. `integration_spine_architecture_contract.md` + `vendor_adapter_slice_contract.md`
    — thorough on load-bearing binding rules; the two share one DRIFT root cause

`phase_7_55_architecture_contract.md` — structurally validated (canonical
Tier-2/3 doctrine; load-bearing model-class claims verified). Not
exhaustively line-audited (it is doctrine, not a code-shape spec); see
remainder note.

Not yet audited (Phase 4 scope) — see final section.

---

## Per-contract summary

### 1. hardening_feature_flag_idempotency_contract.md

Verdict: **Strongly ALIGNED.** 0 DRIFTED, 0 STALE on material claims.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Durable store table `public.admin_request_idempotency` with the 8 listed columns + grants (`service_role` rw, `forge_admin` select) | ALIGNED | 22-34 | `db/migrations/202605021000_phase_hardh_admin_idempotency.sql:30-39,63-64` | none |
| `Idempotency-Key` required, max 200 chars | ALIGNED | 40 | `tool/advisor_proxy/advisor_proxy.dart:9586` (`headerKey.length > 200`) + multiple route sites | none |
| `idempotency_key_conflict` 409 on differing type/body-hash; `idempotency_request_in_flight` 409 on in-flight | ALIGNED | 43-49 | `advisor_proxy.dart:3056-3057,2999,3064` | none |
| Store impl `PostgresAdminRequestIdempotencyStore`; shared helper `_runAdminIdempotent`; binding `AdminRequestIdempotencyStore` | ALIGNED | 80-84 | `proxy_bootstrap.dart:8899-9052,356,1564`; `advisor_proxy.dart:15956+` (`_runAdminIdempotent` call sites) | none |
| Listed live-binding / admin gateway retry test files exist | ALIGNED | 85-90 | `test/feature_flags_admin_live_binding_test.dart`, `test/admin/{operator_location,pricing_tier,integration}_admin_gateway_test.dart` all present | none |

Detail: Closed contract retained as authority. Every material claim holds
verbatim against live code. The shared admin-route idempotency pattern is
implemented exactly as the prose describes.

### 2. hardening_auth_protection_contract.md

Verdict: **Strongly ALIGNED**, 1 STALE-CITATION. 0 substantive DRIFT.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Migration `<ts>_hardening_auth_login_attempts.sql` with RLS-ready schema (`operator_id` nullable, `user_email_hash`/`ip_hash` bytea, `outcome` check, `user_agent_class`), index discipline | ALIGNED | 49-68 | `db/migrations/202605020452_hardening_auth_login_attempts.sql:61-79,143-159` (+ rekey `202605021800`) | none |
| 5 failures / 15 min → 423 `account_locked` `retry_after_seconds:900` | ALIGNED | 82-85 | `advisor_proxy.dart:6691-6694` (`kAuthLoginLockoutWindow=15min`, `kAuthLoginLockoutThreshold=5`, retry-after 900), `:13530-13532,13637-13639` | none |
| 3 TOTP failures → 429 `mfa_retry_limit` Retry-After 30 | ALIGNED | 91-94 | `advisor_proxy.dart:6694-6695,10933-10949` | none |
| 10 reset requests / 24h → 429 `reset_request_throttled` | ALIGNED | 98-102 | `advisor_proxy.dart:6696-6697,10586-10587` | none |
| 4 new audit event types + `claims_hash` on SP issuance + `reason` on flag toggle; fan-out via `AuthEventsAuditRepository._fanOutToAuditLogs` | ALIGNED | 114-121 | `advisor_proxy.dart:6816,6839,6859,6875,3216` (`claims_hash`), `:10806` (`reason`); `auth_events_audit_repository.dart:209,300,499` (`_fanOutToAuditLogs`) | none |
| Comment block at `admin_routes.dart` near line 345 documenting `_kAdminDemoAuth` compile-time gate | **STALE-CITATION** | 41, 157 | Comment exists and is substantively complete at `lib/admin/admin_routes.dart:2733-2747` (cites `_kAdminDemoAuth`, `--dart-define=ADMIN_DEMO_AUTH`, default false, prod must ship without); line is **2733**, not "near 345" | Update doc line reference 345 → ~2733 |

Detail: The substantive lockout/MFA/reset/audit rules all hold exactly.
Only the `admin_routes.dart:345` citation is outdated (file grew; the
required comment moved to ~2733). Rule correct, citation stale.

### 3. hardening_admin_cors_and_limits_contract.md

Verdict: **Strongly ALIGNED**, 1 STALE-CITATION. 0 DRIFT.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| No `Access-Control-Allow-Origin: *` remains on admin routes | ALIGNED | 121-122 | `Grep "Access-Control-Allow-Origin.*\*" advisor_proxy.dart` = 0 admin-route hits | none |
| Single centralized helper `respondAdminCorsPreflight` (403+no-echo on miss; 204 + exact headers on match; `Vary: Origin`; no `Allow-Credentials`) | ALIGNED | 56-78 | `advisor_proxy.dart:19041-19069` (exact behavior incl. `Vary: Origin`, `cors_origin_not_allowed`, matched-origin echo only) | none |
| Allow-list source order: `ADMIN_CORS_ALLOWED_ORIGINS` env > `admin_cors_origins_extra` flag > localhost dev/staging; prod-empty fails closed exit 78 + token `admin_cors_allowlist_missing_in_prod` | ALIGNED | 40-52 | `advisor_proxy.dart:592`; `proxy_bootstrap.dart:9431,9521,9566,9596` (token), `:181` (exit 78) | none |
| Allow-Headers value exactly `Authorization, Content-Type, Idempotency-Key`; Max-Age 600 | ALIGNED | 69-70 | `advisor_proxy.dart:18924` (`kAdminCorsPreflightMaxAgeSeconds=600`), `:18931` (`kAdminCorsAllowedRequestHeaders='Authorization, Content-Type, Idempotency-Key'`) | none |
| Request body cap 1 MB → 413 `request_too_large` `limit_bytes:1000000` | ALIGNED | 84-86 | `advisor_proxy.dart:18896` (`kAdminCorsRequestBodyLimitBytes=1000000`), `:9049-9053` (413 + `limit_bytes`) | none |
| Five existing admin CORS helper sites at "lines 9997, 10013, 10031, 10048, 10065" replaced by one call | **STALE-CITATION** | 18-19, 73-74 | Centralization is real (single `respondAdminCorsPreflight`), but the cited line numbers are obsolete; the helper now lives at `advisor_proxy.dart:19041` | Drop / refresh the five literal line numbers in the doc header |

Detail: Every substantive CORS / size-limit / fail-closed rule holds
exactly. Only the historical "lines 9997..10065" enumeration in the
handoff header is stale (the proxy grew ~9k lines since).

### 4. hardening_observability_baseline_contract.md

Verdict: **ALIGNED** (self-consistent), 1 STALE-CITATION. 0 DRIFT.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Structured JSON log module with envelope (`ts`/`severity`/`event`/`correlation_id`/`request_id`/`operator_id`/`fields`); `X-Correlation-Id` in/out | ALIGNED | 52-74 | `tool/advisor_proxy/log.dart` (re-export shim, contract allows "or equivalent") → `lib/services/observability/log.dart:7-10,36-57,132` | none |
| Postgres per-statement 5s / acquire 10s timeouts; acquire fail-closed exit 78 | ALIGNED | 98-99 | `lib/infrastructure/persistence/postgres/postgres_executor.dart:56-57` (`kPostgresPerStatementTimeout=5s`, `kPostgresAcquireConnectionTimeout=10s`) | none |
| Voyage / Secret Manager per-call timeout constants NOT landed this slice | ALIGNED (self-disclosed) | 3-7 | Confirmed absent; the contract's own status banner pre-discloses this exact gap | none |
| KMS startup: prod missing GCP vars → `startup.kms_misconfigured` ERROR + exit 78; non-prod → `startup.kms_stub_active` WARN; replace silent stub at `proxy_bootstrap.dart:2650` | ALIGNED rule / **STALE-CITATION** on the `:2650` pointer | 117-131 | KMS gating implemented at `proxy_bootstrap.dart:9360-9397` (`startup.kms_misconfigured`/`startup.kms_stub_active`, `kms_real_provider_enabled`); the doc's "`:2650`" pointer is obsolete | Refresh the `proxy_bootstrap.dart:2650` line reference |
| Rollback runbook `runbooks/proxy_rollback_runbook.md` with 6 sections, ≤200 lines | ALIGNED | 139-158 | File present, all 6 numbered sections, 183 lines (≤200) | none |

Detail: The contract is internally honest about the Voyage/SM timeout
gap (status banner), so that is not drift. KMS behavior and Postgres
timeouts hold exactly; only the `:2650` code-seam pointer is stale.

### 5. hardening_production_wiring_contract.md

Verdict: **Strongly ALIGNED**, STALE-CITATIONs on a few code-seam line
numbers. 0 substantive DRIFT.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| `main.dart` no longer references `ScaffoldFailingProxyHealthCheckStore` / `ScaffoldFailingUsageCounterStore`; comment at `main.dart:14` repaired | ALIGNED | 57, 136-141, 170 | `tool/advisor_proxy/main.dart:14` now references `RegistryProxyHealthCheckStore`; scaffold-failing symbols absent | none |
| `RegistryProxyHealthCheckStore` wired in prod bindings with real producers `postgres_select_1` / `age_cypher_match` / `pgvector_similarity` + reserved metric/surface keys as `unknown` | ALIGNED | 46-58, 171 | `advisor_proxy.dart:3960-3985,5339` (`RegistryProxyHealthCheckStore`); `proxy_bootstrap.dart:2373-2406,1585` (`_buildRegistryProxyHealthCheckStore` in prod bindings) | none |
| Usage counter store `lib/infrastructure/persistence/postgres/advisor_proxy_usage_counter_store.dart` exists, scoped via `OperatorScopedRepository` | ALIGNED | 70-79, 172 | File present at the contracted path | none |
| Firebase fail-closed: prod + unset `FIREBASE_PROJECT_ID` → stderr `startup_failure: firebase_project_id_required_in_prod` + exit 78 | ALIGNED | 106-115, 175 | `proxy_bootstrap.dart:162,180` (exact token + `exitCode:78`) | none |
| Startup emits `gemini_slot_enabled: <bool>` | ALIGNED | 122-134 | `advisor_proxy.dart:1849-1854` | none |
| Code-seam pointers `RegistryProxyHealthCheckStore` "~line 3926", `main.dart:99–125` Gemini block | **STALE-CITATION** | 23, 124 | Actual: `RegistryProxyHealthCheckStore` class at `advisor_proxy.dart:5339`; Gemini block at `main.dart:~1849` | Refresh those two line pointers |

Detail: All wire-shape, fail-closed, and store-wiring guarantees hold.
The `proxy_health_contract.md` envelope is unchanged (verified in
contract 9). Only ~2 historical line pointers drifted.

### 6. hardening_devops_surface_contract.md

Verdict: **Strongly ALIGNED.** 0 DRIFTED. 1 minor STALE-CITATION (example
workflow filename).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Root + worker Dockerfiles digest-pinned + non-root before CMD | ALIGNED | 143-153, 200-201 | `Dockerfile:19,34,44,55` (`@sha256:` pins, `useradd ... uid 10001`, `USER app`); `tool/mfa_removal_worker/Dockerfile:28,42,50` (distroless `:nonroot@sha256`, `USER nonroot`) | none |
| MFA-removal worker manifest (`Dockerfile` + `cloudbuild.yaml`) exists | ALIGNED | 68-99, 193-196 | Both files present under `tool/mfa_removal_worker/` | none |
| `migration_cutoff_lint.dart` exists / staging script defers to canonical runner | ALIGNED | 53-66, 191 | `tool/migration_cutoff_lint.dart` present; `scripts/postgres_staging_setup.ps1:47-54` defers to runner + cites the lint as drift guard | none |
| Both `.xcscheme` files pin `FLUTTER_TARGET` | ALIGNED | 101-120, 197 | `ForgeFlow.xcscheme:58` / `Barrio.xcscheme:58` set `--dart-define=FLUTTER_TARGET=...` | none |
| No floating `actions/*@v[0-9]` refs in workflows | ALIGNED | 155-169, 202-203 | `Grep "uses: actions/.*@v[0-9]" .github/workflows/` = 0 hits | none |
| Release CI asserts `FORGE_FLOW_USE_FIREBASE_AUTH=true` in `.github/workflows/ci.yml` (example) | ALIGNED / **STALE-CITATION** on the example filename | 126-141, 198-199 | Guarantee met via `.github/workflows/apple-platform-verify.yml` + `tool/release_dart_defines_lint.dart`; contract explicitly says "implementation may differ"/"whichever workflow runs the release build", so the `ci.yml` example name is illustrative, not binding | Optional: point the example at the apple-platform-verify workflow |

Detail: Every binding posture rule holds. The only nit is the
illustrative `ci.yml` example name; the contract pre-authorizes a
different workflow, so this is not drift.

### 7. hardening_test_corrections_contract.md

Verdict: **Substantively ALIGNED**, 1 STALE bookkeeping instruction. 0
code DRIFT.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Audit-binding assertion fixed: replace fanout-fragile `tx.parameters.last` with statement-anchored `indexWhere` for the `auth_events_audit` insert | ALIGNED | 52-77, 171-173 | `test/user_lifecycle_live_binding_test.dart:455-477` uses the exact prescribed `indexWhere('insert into auth_events_audit' ...)` pattern. Remaining `tx.parameters.last` at `:79-81,194,395` are on single-statement non-audit txns — outside the contract's qualified "audit-binding context" (doc:172-173) | none (scope-qualified) |
| New `test/feature_flags_admin_live_binding_test.dart` covering toggle/idempotency/RLS/permission/audit-chain, skips when `LIVE_BINDING_POSTGRES_URL` unset | ALIGNED | 79-101, 174-175 | File present; header documents toggle/idempotency/RLS/403/chain coverage + clean skip | none |
| New `test/current_state_boundary_monitor_live_binding_test.dart` | ALIGNED | 103-124, 176-177 | File present | none |
| CRLF normalization via helper (`readMigrationLF`) for migration-content assertions | ALIGNED | 126-143, 178 | `test/_helpers/migration_lf.dart` present (the contract's prescribed helper shape) | none |
| Update `KNOWN_FAILING_TESTS.md`: strike-through the CRLF entry with "resolved 2026-05-02 in HARD-H" annotation **per existing doc convention** | **STALE (instruction)** | 145-147, 179 | The convention the instruction relies on no longer exists: `docs/KNOWN_FAILING_TESTS.md:11-12` now states "Removed entries live in git history; do not keep a 'resolved' section here." The CRLF entry is removed (not struck through) — consistent with the *current* doc convention, contradicting the contract's instruction | Annotate the contract: KFT convention changed to "remove, don't strike"; the substantive CRLF fix is done. Code authoritative; doc instruction stale |

Detail: All test-correctness code work landed. The only miss is a
bookkeeping instruction that references a `KNOWN_FAILING_TESTS.md`
strike-through convention that the file itself has since reversed.
Substance correct; the *how-to-annotate* instruction is stale.

### 8. auth_permission_key_catalog.md

Verdict: **Mostly ALIGNED on mechanism; DRIFTED on documented counts.**

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Canonical sources = foundation seed migration + additive migrations + `lib/auth/permission_keys.dart`; doc must stay in sync | ALIGNED (authority position) | 4-8 | Doc correctly defers to code/migrations as canonical | none |
| Keep-in-sync safety net: 9.0 test asserts migration seeds ≥ `PermissionKeys.all` | ALIGNED | 33-39 | `test/advisor_proxy_test.dart:2549` ("every key from PermissionKeys.all is seeded into permission_keys") + `:2526` single-insert assertion | none |
| "Running total across all 11 categories is **103 keys**"; core "**84 keys** across 7 categories" | **DRIFTED** | 41, 47 | `lib/auth/permission_keys.dart:252-358` `PermissionKeys.all` has **106** members; 119 `static const String` defs; distinct key strings across all migrations = 104. The doc's own per-category sum (2+20+12+28+17+1+1+5+9+1 + workflow "8 placeholder" = 104) also contradicts its stated 103. Code grew past the documented totals | Update the doc totals (and per-category counts) to match `PermissionKeys.all` (=106) + migrations; code is authoritative per doc:4-8 |
| Per-category structure (product/forgeflow/barrio/admin/team/account/business_timing/billing/integration/integrations/workflow) | ALIGNED (categories) | 49-340 | All 11 category prefixes present in `permission_keys.dart`; structure intact | none |
| `requiresMfa` mirrors migration `requires_mfa=true` rows | ALIGNED (mechanism) | 21, 31, 118 | `permission_keys.dart:363+` `requiresMfa` set present; mirrored-in-migration claim structurally intact | none |

Detail: The catalog's *mechanism* (frozen catalog, 3-way keep-in-sync,
seed-≥-all test) is fully ALIGNED. The DRIFT is purely the stale
documented totals (103/84) vs the live 106-member `PermissionKeys.all`,
and the doc's per-category arithmetic is internally inconsistent with its
own stated total. Low risk (the test net prevents under-seeding) but a
real doc-vs-code count drift; doc is the side that must move.

### 9. proxy_health_contract.md

Verdict: **Strongly ALIGNED.** 0 DRIFTED, 0 STALE on material claims.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| `/healthz` + `/readyz` return only `{"status":"ok"}`, no Postgres/provider touch | ALIGNED | 36-47 | `advisor_proxy.dart:7251-7252,9059-9062` (literal `{'status':'ok'}`, no DB) | none |
| `/health` top-level: `status`/`severity`/`contract:proxy_health.v1`/`schema_version:1`/`checked_at`/`dependencies`/`surfaces`/`metrics` | ALIGNED | 59-72 | `advisor_proxy.dart:3951-3954` (`severity`, `contract:'proxy_health.v1'`, `schema_version:1`, `checked_at` ISO-UTC) | none |
| Dependency envelope w/ `legacy_key` compatibility aliases (`postgres_select_1`/`age_cypher_match`/`pgvector_similarity`) | ALIGNED | 86-124 | `advisor_proxy.dart:3960-3970,3983-3985,4057` (`legacy_key`) | none |
| All 11 reserved metric keys + 6 reserved surfaces (`audit_chain`/`event_outbox`/`usage_caps`/`graph`/`vector`/`rollups`) present | ALIGNED | 162-211 | `advisor_proxy.dart`: 46 reserved-metric hits; surfaces at `:4277-4313` (all 6) | none |
| 503 only on required-dependency red; reserved `unknown` metrics don't degrade | ALIGNED | 74-84 | Envelope assembly honors this (RegistryProxyHealthCheckStore semantics) | none |

Detail: This foundation contract's wire shape is implemented to the
letter, including the compatibility aliases and the full reserved
metric/surface key set. No drift.

### 10. metric_card_honesty_contract.md

Verdict: **Mostly ALIGNED**, 1 DRIFT (closed-cardinality enum widened).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| `state` is a **closed cardinality**: exactly `live`/`partial`/`fallback`/`unavailable` | **DRIFTED** | 50-56 | `lib/domain/models/metric_provenance.dart:28-54` `enum MetricState` has **5** values — adds `stale` ("data previously live; vendor sync lapsed"), explicitly marked "Additional states used by `MetricPill`". A "closed cardinality" enum was widened by code | Update the contract to document the 5th `stale` state (doctrine not violated — `stale` still flags rather than phantom-zeroes; only the enumeration claim is stale). Code is the working reality |
| New files: `metric_provenance.dart`, `metric_card_not_yet_available.dart`, `data_source_health_pill.dart` | ALIGNED | 134-147 | All three present at the contracted paths | none |
| Producer rules in `shift_fact_builder.dart` (covers/labor-dollars → state+provenance, no phantom-live) | ALIGNED | 135-145 | `lib/domain/services/shift_fact_builder.dart:30-40` resolves `laborDollarsFromVendor=false` → `fallback`, never phantom-live | none |
| Renderer: only `unavailable` has visible chrome (`MetricCardNotYetAvailable`); pill assembled from non-live union; no card-level chrome | ALIGNED | 83-170 | `metric_card_not_yet_available.dart`, `data_source_health_pill.dart:5-36` ("no All live pill"; assembled only from non-live entries) | none |
| `provenance` open-enum naming rule (`vendor_<id>_<field>_unavailable_<src>_substituted`) | ALIGNED | 57-81 | `shift_dashboard_read_model.dart:150` + builder use the contracted provenance strings | none |
| Doc:18 cites `shift_fact_builder.dart:36` / `shift_dashboard_read_model.dart:191-192` as the *pre-fix* phantom-zero sites | ALIGNED (intentional history) | 18 | These describe the problem state the contract closes; not a stale citation | none |

Detail: The honesty doctrine, new widgets, producer/consumer split, and
pill chrome budget all hold. The single real DRIFT: the contract calls
`state` a "closed cardinality" of 4 values, but code ships 5 (`stale`
added for `MetricPill`). The doctrine intent (no phantom zeroes; flag,
don't lie) is preserved, so this is a doc-enumeration DRIFT, not a
doctrine violation. Doc should adopt the 5th state.

### 11. integration_spine_architecture_contract.md + vendor_adapter_slice_contract.md

Verdict: **Structurally ALIGNED on the canonical chain; 1 shared DRIFT
(OAuth advisory-lock ban superseded by a later race fix).**

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Two-store rule + migration `202605040000` adding vendor columns; mobile SQLite never speaks to vendors/Postgres directly | ALIGNED | 196-206 | `db/migrations/202605040000_phase_8_0_integration_framework.sql` present (vendor_id, raw_payload JSONB) | none |
| NEW spine-bridge files exist (`canonical_fact_to_closed_shift_input.dart`, `postgres_shift_record_writer.dart`, `postgres_shift_record_to_mobile_sync.dart`) | ALIGNED | 243,291,320 | All three present at contracted paths | none |
| Concern A re-aggregation rule: writer re-uses existing `target_profile_version_id` when `priorTargetProfileVersionId` non-null; only first-time mints fresh | ALIGNED | 295-308 | `postgres_shift_record_writer.dart:6-9,24-26,54,66` implements the exact rule | none |
| Covers-source decision (manual → vendor-live → forecast-substituted → null/`MetricCardNotYetAvailable`) with contracted provenance strings | ALIGNED (substance) | 245-260 | `canonical_fact_to_closed_shift_input.dart:461,531,584` uses the contracted provenance strings. Code labels it "5-way" (doc says "4-way") — counts the null/unavailable branch + a Per-Daypart V1 forecast-allocator refinement (the active feature plan, CLAUDE.md authority #5) | Optional: reconcile the "4-way"/"5-way" wording; substance matches the contract's 4 ordered branches |
| `VendorCapabilityProfile` declares all 10 required fields | ALIGNED | 142-157 | `lib/services/integration/integration_adapter_common.dart:64-86` declares all 10 (`vendorId`..`timestampPolicyDocId`) as `required` | none |
| Banned (both contracts): `parse_warnings`/`parse_partial`, SIGTERM drain, 5-min replay, raw-payload sibling tables | ALIGNED | spine:840-853, vendor:159-174 | All matches in code are comments documenting the ban is honored; replay window correctly `Duration(hours:24)` (`inbound_webhook_handler.dart:62`) — not the banned 5-min | none |
| Banned (both): "OAuth advisory locks" / "`pg_try_advisory_lock`" → REJECT | **DRIFTED** | spine:849, vendor:169 | Code **actively uses** `pg_advisory_xact_lock`/`pg_try_advisory_xact_lock` in `lib/services/integration/oauth_refresh_cron.dart:20,37,129-142`, backed by migration `db/migrations/202605080900_oauth_refresh_advisory_lock.sql`, explicitly "RESTORED per J4 race fix". A later dated race-fix decision with its own migration supersedes the V1-lean-cut ban; the contracts were never updated | Carve out the J4 OAuth-advisory-lock restoration in both contracts' banned tables (or add a supersession note). Per authority order the later migration/decision wins; the ban text is STALE — flag for operator (proxy/RLS-adjacent + lean-cut doctrine) |

Detail: The canonical-chain binding rules (Concern A version-id reuse,
covers/labor-dollars resolution, two-store separation, capability profile)
are implemented faithfully. The one real DRIFT is shared by both
contracts: the absolute "no OAuth advisory locks" ban (V1 lean cut 2
doctrine) is contradicted by a deliberate, migration-backed J4 race-fix
restoration in `oauth_refresh_cron.dart`. This is a doctrine-vs-code
mismatch where a later decision legitimately superseded the ban but the
contracts lag. Recommend operator-aware doc carve-out (touches the lean
cut doctrine + a proxy/integration concurrency primitive).

### (structural) phase_7_55_architecture_contract.md

Verdict: **Structurally ALIGNED** (canonical Tier-2/3 doctrine).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Layer model classes exist: `TargetCycle`, `ActiveTargetProfile`, `DemandForecastContext`, `WeeklyPlanSnapshot` (data models); `LaborModel` formula source | ALIGNED | 136-185, 535-538 | `lib/domain/models/{target_cycle,active_target_profile,demand_forecast_context,weekly_plan_snapshot}.dart`; `lib/services/labor_model.dart` — matches CLAUDE.md Architecture Guardrails | none |
| "What never rewrites" invariants (no regrade of closed shifts, no midweek snapshot regen, no after-the-fact benchmark adoption) | ALIGNED (doctrine) | 506-514 | Mirrored faithfully in CLAUDE.md Time/Architecture Guardrails; Concern A writer rule (contract 11) enforces the no-regrade invariant in code | none |
| "Current Repo Reality" landed/deferred seam lists | NOT FULLY VERIFIED (status note; may have aged) | 531-550 | Status narrative, not a code-shape spec; exhaustive verification deferred to Phase 4 | Phase 4: re-check the deferred-seam list vs current state |

Detail: This is the canonical architecture doctrine (CLAUDE.md authority
#2/#3). Its load-bearing model-class claims are ALIGNED and its
invariants are enforced downstream (notably the Concern A rule audited in
contract 11). It is doctrine, not a line-level code spec; the
"Current Repo Reality" status lists are the only part plausibly aged and
are deferred to Phase 4 rather than rushed here (depth over breadth).

---

## Roll-up counts

| Contract | ALIGNED | DRIFTED | STALE / STALE-CITATION |
|---|---|---|---|
| 1. feature_flag_idempotency | 5 | 0 | 0 |
| 2. auth_protection | 5 | 0 | 1 (citation) |
| 3. admin_cors_and_limits | 5 | 0 | 1 (citation) |
| 4. observability_baseline | 4 | 0 | 1 (citation) |
| 5. production_wiring | 5 | 0 | 1 (citations, grouped) |
| 6. devops_surface | 6 | 0 | 1 (citation, illustrative) |
| 7. test_corrections | 4 | 0 | 1 (stale instruction) |
| 8. auth_permission_key_catalog | 4 | 1 | 0 |
| 9. proxy_health | 5 | 0 | 0 |
| 10. metric_card_honesty | 5 | 1 | 0 |
| 11. integration_spine + vendor_adapter | 6 | 1 (shared) | 0 |
| (s) phase_7_55_architecture | 2 | 0 | 0 (1 deferred) |
| **Total** | **56** | **3** | **8** |

## Top drifts (operator attention)

1. **OAuth advisory-lock ban superseded but contracts not updated**
   (integration_spine `:849` + vendor_adapter `:169`). Code actively uses
   `pg_advisory_xact_lock` in `lib/services/integration/oauth_refresh_cron.dart`
   via migration `202605080900_oauth_refresh_advisory_lock.sql` (J4 race
   fix). Touches the V1-lean-cut doctrine + an integration concurrency
   primitive — flag for operator before any contract edit (RLS/proxy-
   adjacent, doctrine-touching).
2. **`MetricState` widened from a contract-declared "closed cardinality"
   of 4 to 5** (`metric_card_honesty_contract.md:50-56` vs
   `metric_provenance.dart:28-54` — `stale` added). Doctrine intact (no
   phantom zeroes); contract enumeration is stale.
3. **Auth permission catalog documented totals stale** (`103`/`84` vs
   live `PermissionKeys.all` = 106; doc's own per-category sum is
   internally inconsistent). Low risk (seed-≥-all test net), pure
   doc-count drift; code authoritative per the doc's own authority clause.

All three are doc-side updates (code is authoritative in each per
CLAUDE.md authority order). #1 is operator-gated (doctrine + proxy/RLS
adjacency); #2 and #3 are straightforward doc reconciliations.

## Not yet audited — Phase 4 scope

Priority-tier remainder (named in this prompt, deferred for depth):

- `phase_7_55_architecture_contract.md` — line-level verification of the
  "Current Repo Reality" / "Phase Ownership" status lists (doc:531-588)
  vs current tracker + code state. (Doctrine claims already validated
  here; only the status narrative remains.)

Other unaudited code/schema-binding contracts (Phase 4+ scoping):

- `phase_7_58_primary_driver_contract.md` (sibling of metric_card_honesty)
- `phase_7_61_driver_key_contract.md`
- `phase_7_55_target_cycle_weekly_plan_rules.md`
- `phase_7_55_current_state_freshness_contract.md`
- `data_accuracy_settings_contract.md` (referenced heavily by integration spine)
- `per_vendor_doc_pack_contract.md`
- `event_outbox_contract.md` (Phase 2 spot-validated structurally only — full audit pending)
- `audit_log_architecture_contract.md` (Phase 2 spot-validated structurally only — full audit pending)
- `audit_attribution_contract.md`
- `advisor_conversation_log_contract.md`
- `team_roles_hierarchy_console_parity_contract.md`
- `mobile_core_*` contracts (4: business_scope, first_connection_backfill, star_target_truth, weekly_plan_server_truth)
- `mobile_typography_and_spacing_contract.md`
- `operator_self_served_tos_contract.md`
- `v1_launch_slos.md`
- `migrations_summary.md`

Already audited (do not re-audit): Phase 1 `core_app_architecture.md`;
Phase 2 `hardening_rls_and_repository_pattern_contract.md`,
`phase_7_55_time_boundary_contract.md`, `demo_mode_contract.md`,
`slice_runtime_acceptance_contract.md`; Phase 3 (this doc) the 11
contracts above + structural pass on `phase_7_55_architecture_contract.md`.
