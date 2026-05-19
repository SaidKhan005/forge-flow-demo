# Phase 4 — Remaining Contracts vs Code Alignment Audit

Audit date: 2026-05-18
Auditor: Claude doc-alignment worker (Phase 4)
Scope: Every `docs/contracts/*.md` NOT covered by Phase 1
(`phase1_core_app_architecture.md`), Phase 2 (`phase2_tier2_contracts.md`),
or Phase 3 (`phase3_priority_contracts.md`). Full (not spot) audits of
`event_outbox_contract.md` + `audit_log_architecture_contract.md` (Phase 2
spot-validated those structurally only). Status-narrative section of
`phase_7_55_architecture_contract.md` (doc:531-588, deferred by Phase 3).
Line-by-line material-claim audit vs live `lib/**` + `db/migrations/**` +
`tool/advisor_proxy/**`.

Authority order per `CLAUDE.md` "Authority Order": active prompt > Tier-2
canonical architecture > other Tier-2/3 contracts > trackers > phase docs
> `CLAUDE.md`. On conflict, live code/migrations win on file/line/path
facts and on shipped state; a contract whose pre-implementation "Current
Code Reality" snapshot has since been overtaken by landed code is STALE on
that narrative (code is ahead), not DRIFTED — the binding rules still hold.

Classification key (same as Phases 2-3):
- **ALIGNED** — doc claim matches live code.
- **DRIFTED** — doc claim and code disagree on substance; both still live.
- **STALE** — doc references a path/line/state that has moved or no longer
  exists, OR a status/"current reality" narrative the code has overtaken;
  the binding substance may still be correct.
- **STALE-CITATION** — narrower STALE: rule correct, only a line/path
  reference is outdated as files grew/moved.

Contracts thoroughly audited this pass (19 + 1 status-narrative section):

1. `phase_7_58_primary_driver_contract.md` — thorough (incl. V2 catalog)
2. `phase_7_61_driver_key_contract.md` — thorough
3. `phase_7_55_target_cycle_weekly_plan_rules.md` — thorough (doctrine)
4. `phase_7_55_current_state_freshness_contract.md` — thorough
5. `data_accuracy_settings_contract.md` — thorough (schema + provenance)
6. `event_outbox_contract.md` — **full** line audit (Phase 2 spot only)
7. `audit_log_architecture_contract.md` — **full** line audit (Phase 2 spot only)
8. `audit_attribution_contract.md` — thorough (schema + chain encoding)
9. `advisor_conversation_log_contract.md` — thorough (schema + repo + perm)
10. `team_roles_hierarchy_console_parity_contract.md` — thorough (W3.A table)
11. `mobile_core_business_scope_contract.md` — thorough
12. `mobile_core_star_target_truth_contract.md` — thorough
13. `mobile_core_weekly_plan_server_truth_contract.md` — thorough
14. `mobile_core_first_connection_backfill_contract.md` — thorough
15. `mobile_typography_and_spacing_contract.md` — thorough (token system)
16. `operator_self_served_tos_contract.md` — thorough
17. `v1_launch_slos.md` — thorough (spec doc; few code anchors)
18. `per_vendor_doc_pack_contract.md` — thorough (folder-shape binding)
19. `migrations_summary.md` — thorough (auto-generated index)
20. `phase_7_55_architecture_contract.md` §"Current Repo Reality" /
    §"Phase Ownership" status narrative (doc:531-588) — the part Phase 3
    explicitly deferred. Doctrine claims already validated by Phase 3.

`phase_7_55_plain_english_architecture.md` — plain-English companion
explainer to the Phase-3 structurally-validated architecture contract.
Pure doctrine prose, no independent code-binding claims; ALIGNED with its
parent. Not tabulated separately.

Phase 5 remainder: **none** — all `docs/contracts/*.md` are now covered by
Phases 1-4. See final section.

---

## Per-contract summary

### 1. phase_7_58_primary_driver_contract.md

Verdict: **Strongly ALIGNED on substance** (Single Source of Truth,
decision logic, thresholds, priority order, V2 copy catalog all
byte-aligned). 1 DRIFT (carry-forward narrative is stale — code is ahead).
Several STALE-CITATIONs (file grew ~heavily).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| `LaborModel.determineLever` is the only lever-id minter; thresholds Covers ±2% / PPA ±3% / CPLH ±5% / SPLH ±5% / wage ±3% / hours-flex ±10% | ALIGNED | 34, 47-56, 72-79 | `lib/services/labor_model.dart:248-300` (`coversDelta<-0.02`/`>0.02`, `ppaDelta ±0.03`, `cplhDelta ±0.05`, `splh/wage/flex` exactly) | none |
| `priorityOrder` tie-break list (16 ids, covers→ppa→cplh→splh→foh_wage→boh_wage→foh_hours→boh_hours) | ALIGNED | 95-106 | `labor_model.dart:213-222` `_priorityOrder` byte-identical; `_selectLever:307-318` lower-index-wins | none |
| `determineLeverGated` returns `onModelSentinel`='on_model' on empty candidates; `determineLever` keeps legacy `'covers_down'` | ALIGNED | 81-92 | `labor_model.dart:22` (`onModelSentinel='on_model'`), `:171-209` (`determineLeverGated`→`return onModelSentinel`), legacy `determineLever` preserved | none |
| 16 lever ids match `LeverCards.all`; 17th `on_model` never returned by engine | ALIGNED | 62-68 | `app_defaults.dart:375` `static const List<LeverCardData> all`; `LeverCards.lookup` returns null for `on_model` (`:415`) | none |
| V2-1 evolved copy catalog (16 single-axis + 4 cross-axis) applied byte-for-byte to Dart | ALIGNED | 372-524 | `app_defaults.dart:103-231+` (`covers_down`/`covers_up`/`ppa_*`/`cplh_*`/`splh_*` metric+wh+wd+ws strings byte-match); `cross_axis_pair_catalog.dart:87` `CrossAxisPairs` w/ 4 ids (`cplh_below_splh_above`/`cplh_on_splh_below`/`cplh_above_splh_below`/`both_below`) | none |
| Code-seam citations `labor_model.dart:99` (determineLever), `:131` (priorityOrder); `app_defaults.dart:434` (LeverCards.all) | **STALE-CITATION** | 34, 51, 63, 95 | Actual: `determineLever` at `:120`, `_priorityOrder` at `:213`, `LeverCards.all` at `:375`. Files grew; rules byte-exact | Refresh the 3 line pointers |
| "Today `variance_week_projection_read_service.dart:60-78` builds a `lastClosedLever[daypart]` map and assigns it to open/projected rows … contract bans this … `7.58.5` G.5 fold" (present-tense, pending) | **DRIFTED** (narrative; code ahead) | 203-212, 232 | `variance_week_projection_read_service.dart:171-189` — comment "7.58.5: open / projected rows return 'Not yet available' — they no longer inherit a closed daypart's lever via carry-forward"; the carry-forward map is GONE, `_driverLabel` returns `notYetOnModelLabel`. `7.58.5` already landed | Update the contract: G.5 carry-forward fold removed; the ban is honored in code, not pending. Code authoritative |

Detail: Every load-bearing engine rule (single source, six axes,
thresholds, priority order, gated/legacy split, V2 LOCKED copy catalog)
is implemented to the letter. The one real drift is a stale present-tense
narrative: the contract describes the daypart carry-forward as still
present and `7.58.5` as a pending fold, but `7.58.5` shipped and the
carry-forward was removed (open/projected rows now return "Not yet
available", honoring the contract's own ban). Doc narrative lags code.

### 2. phase_7_61_driver_key_contract.md

Verdict: **Strongly ALIGNED on key-shape rules.** 0 substantive DRIFT.
STALE-CITATIONs on producer-site line numbers.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| R-STOR-1/2/3: engine returns lowercase; `ShiftRecord.primaryLever` upper-snake; `normalizedLeverId` is the only upper→lower seam | ALIGNED | 95-105 | `shift_record.dart:372` (`normalizedLeverId => primaryLever.toLowerCase()`); upper-snake stored | none |
| R-PROD-2: lowercase→upper transform in exactly two places — `shift_service.dart:330` + `mock_integration_replay_seed.dart:364` | ALIGNED rule / **STALE-CITATION** on both line nums | 129-137 | `shift_service.dart:420` (`fact.primaryLeverId.toUpperCase()`); replay seed `.toUpperCase()` at `:1063`/`:1246` (in-file, sanctioned). Files grew | Refresh the two producer-site line pointers |
| SQLite: `shifts.primary_lever` UPPER_SNAKE TEXT NOT NULL; `week_records.primary_lever_id` lowercase TEXT NOT NULL | ALIGNED | 234-249 | `sqlite_database_schema.dart:157` (`primary_lever TEXT NOT NULL`), `:208` (`primary_lever_id TEXT NOT NULL`) | none |
| 17-token catalog (16 engine ids + `on_model` sentinel), no out-of-catalog ids | ALIGNED | 47-81 | `LeverCards.all` (16) + `on_model` handled in `LeverCards.lookup`; matches 7.58 audit | none |
| R-CONS-3: read-models on guaranteed engine output MAY `LeverCards.lookup(id)!` (used by `ShiftDashboardReadModel.buildWholeDay`) | ALIGNED | 181-187 | Consistent w/ Phase-3 metric_card audit + 7.58 R6 | none |

Detail: The key-shape contract (storage forms, the single normalize
seam, the per-column SQLite forms, the closed 17-token catalog,
producer/consumer rules) holds exactly. Only the two `.toUpperCase()`
producer-site line numbers drifted as `shift_service.dart` /
`mock_integration_replay_seed.dart` grew; the rule itself is honored.

### 3. phase_7_55_target_cycle_weekly_plan_rules.md

Verdict: **ALIGNED** (doctrine doc; no line citations to drift).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Core model: `TargetCycle` / `ActiveTargetProfile` / `DemandForecastContext` / `SchedulePlan` / `WeeklyPlanSnapshot` exist | ALIGNED | 61-141 | `lib/domain/models/{target_cycle,active_target_profile,demand_forecast_context,schedule_plan,weekly_plan_snapshot}.dart` all present | none |
| Rule A: manager override allowed once per 60-day cycle | ALIGNED | 145-149 | `target_cycle.dart:208-209` (`managerOverrideUsed` / `managerOverrideAt` fields) | none |
| Rule E: cycle refresh gates to operator `week_start_day`; cannot refresh mid-week | ALIGNED | 178-190 | `target_cycle_policy.dart:50-56` (`needsAutoRefresh`: false when `businessDate ≤ effectiveEnd`, else `weekday == weekStartDay`) — same predicate Phase 2 audited as Rule 6 | none |

Detail: Model-rule doctrine. The five core model classes exist; Rule A's
once-per-cycle override is backed by `managerOverrideUsed`/`...At`; Rule
E's mid-week-refresh ban is enforced by the `needsAutoRefresh` predicate
(cross-consistent with Phase 2's already-ALIGNED time-boundary Rule 6).

### 4. phase_7_55_current_state_freshness_contract.md

Verdict: **ALIGNED on the freshness model.** 1 STALE (a dated
"Current Open Constraint" note the schema has since closed).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Four freshness states `live` / `updated` / `stale` / `refreshing`; `refreshing` set externally, never by evaluate | ALIGNED | 67-95 | `lib/models/current_state_freshness.dart:15` `enum FreshnessState{live,updated,stale,refreshing}`; `current_state_freshness_service.dart:11` ("`refreshing` … never returned by `evaluate`"), `:50/59/67/74` map | none |
| One freshness policy through shared runtime seams (not widget-local); shared invalidation seam | ALIGNED | 163-187 | `lib/services/current_state_freshness_service.dart` + `lib/services/app_refresh_coordinator.dart` present (shared seam) | none |
| "Current Open Constraint: the pre-existing `snapshot_blended_wage` schema column gap still blocks SQLite reseed tests" | **STALE** | 217-222 | `sqlite_database_schema.dart:180` now declares `snapshot_blended_wage REAL`. The gap the note flags as open has been closed | Mark the "Current Open Constraint" note historical / resolved; freshness rules unaffected |

Detail: The freshness state machine is implemented exactly (4-state enum,
`refreshing` exclusively externally-set, shared service + refresh
coordinator). Only the dated open-constraint note aged out: the
`snapshot_blended_wage` column it says is missing now exists in schema.

### 5. data_accuracy_settings_contract.md

Verdict: **Strongly ALIGNED** (schema tables, RLS/grants, resolver
provenance strings all match real migrations + code). 1 minor DRIFT
(framework-max is an injected param, not a named constant). 1 cosmetic
schema-narrative note.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Three tables: `data_accuracy_settings`, `data_accuracy_service_period_settings`, `forge_flow_polling_tier_assignment` w/ specified columns/checks/RLS/grants | ALIGNED | 352-578 | Real migrations `202605050000_phase_8_data_accuracy_settings.sql` (RLS via `app_current_operator()`, `:126-127` grants), `202605061701_..._service_period_settings.sql`, polling-tier table in `202605050000:200-218` (`grant select` service_role / `select,insert,update` forge_admin — matches contract SQL byte-for-byte) | none |
| Covers-source resolution provenance strings (`operator_manual_entry_per_daypart`, `..._fallback_pos_not_exposed`, `vendor_<id>_covers_unavailable_app_forecast_substituted`) | ALIGNED | 589-642 | `canonical_fact_to_closed_shift_input.dart:461,540,584` byte-match | none |
| Wage-source resolution provenance (`target_wage_substituted`, `vendor_<id>_per_employee_actual_dollars`, `..._dollars_unavailable_target_wage_substituted`) + `LaborWageSourceClass` sidecar + `pos_covers_capability.dart` | ALIGNED | 655-709 | `canonical_fact_to_closed_shift_input.dart:657,701,766`; `lib/services/integration/pos_covers_capability.dart` present; `LaborWageSourceClass` referenced | none |
| Keyed `data_accuracy_service_period_settings` is the V1 path; hardcoded lunch/dinner/late_night columns rejected | ALIGNED | 337-359 | Migrations `202605170000` r5 keyed-backfill + `202605170200` r7d **drop legacy covers columns** — consistent with "not a valid new path" | none |
| `PollingCadenceResolver` clamps to `[vendorMinimum, framework_max]`; "Resolver constant `kFrameworkMaximumCadenceSeconds`" (3600s) | **DRIFTED** (mechanism) | 148-169 | `polling_cadence_resolver.dart:69,140` — framework max is an **injected parameter** `frameworkMaximumCadenceSeconds`, NOT a named const `kFrameworkMaximumCadenceSeconds`. Clamp-not-reject + `cadence_clamped` emission honored exactly (`:155-163`) | Doc: drop the "Resolver constant `kFrameworkMaximumCadenceSeconds`" wording; it is an injected bound. Substance (clamp, emit cadence_clamped) holds |
| Inline `CREATE TABLE data_accuracy_settings` shows `walk_in_handling_mode` in the create body | ALIGNED (end-state) / cosmetic note | 362-402 | Column added by a later `ALTER` (`202605080300_..._walk_in_settings.sql:14`), not the original create (`202605050000`). End-state column + check match the contract exactly | Optional: note the contract presents the consolidated final shape (built incrementally). Not drift |

Detail: A large, high-priority schema-binding contract that is clean. All
three Postgres tables exist as real migrations with the contracted
columns, checks, wrapper-only RLS, and grant posture; the covers/wage
resolver provenance strings are byte-identical in
`canonical_fact_to_closed_shift_input.dart`. The only real DRIFT is a
mechanism-detail (the contract calls the framework max a named resolver
constant; code injects it as a parameter) — clamping behavior is honored.

### 6. event_outbox_contract.md (FULL line audit — Phase 2 spot only)

Verdict: **FULLY ALIGNED. Zero DRIFT, zero STALE.**

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| 9-column schema (`id bigserial`, `operator_id uuid not null`, `topic text` 1-200 check, `payload jsonb` ≤256KiB + `jsonb_typeof='object'`, `created_at`/`picked_up_at`/`delivered_at`/`attempt_count`≥0/`last_error_at`/`last_error`) | ALIGNED | 60-77 | `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql:90-114` byte-identical | none |
| Claim index `(operator_id, picked_up_at NULLS FIRST, id)` | ALIGNED | 79-92 | `202604280003:148-149` exact | none |
| Wrapper-only RLS `event_outbox_per_tenant_select` / `_per_tenant_modify` via `app_current_operator()` | ALIGNED | 93-99 | `202604280003:214-223` exact (no bare `current_setting`) | none |
| `event_outbox_notify` trigger AFTER INSERT emits `{operator_id, topic, id}` only | ALIGNED | 101-108 | `202604280003:168-195` (`json_build_object('operator_id'..,'topic'..,'id'..)`) exact | none |
| Claim predicate: `delivered_at IS NULL AND (picked_up_at IS NULL OR picked_up_at < now()-claimReclaimAfter)`; default reclaim 5 min; outer `SELECT … ORDER BY updated.id` over `UPDATE … RETURNING`; `FOR UPDATE SKIP LOCKED` | ALIGNED | 212-255 | `event_outbox_repository.dart:190` (`defaultClaimReclaimAfter=Duration(minutes:5)`), `:200-237` (3-predicate filter, outer-SELECT id-ordering w/ the `id::text AS id` lex-sort gotcha note, `FOR UPDATE SKIP LOCKED`) | none |
| `enqueue` + `enqueueInTransaction` + `claimBatch` repo surface | ALIGNED | 178-209 | `event_outbox_repository.dart:94,152,237` present exactly | none |

Detail: The full line-by-line audit Phase 2 deferred is now complete and
the contract is implemented to the letter — schema, claim index,
wrapper-only RLS, notify trigger envelope, the 3-predicate claim filter,
the 5-minute reclaim lease, and the outer-SELECT id-ordering workaround
(including the documented `id::text` lex-sort gotcha) all match exactly.

### 7. audit_log_architecture_contract.md (FULL line audit — Phase 2 spot only)

Verdict: **ALIGNED.** 0 substantive DRIFT. 1 trivial column-name
imprecision in the prose.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Two parallel chains: `audit_logs` (operator-scoped, RLS) + `auth_events_audit` (F&F-internal); each its own SHA-256 chain; no unified chain | ALIGNED | 9-26 | `audit_logs` in `202604280005_phase_9_0sigma_f_audit_logs.sql`; `auth_events_audit` in `202604250008_auth_schema_foundation.sql:347`; independent chains | none |
| `audit_logs.operator_id` NOT NULL (DB-enforced); `auth_events_audit.operator_id` nullable | ALIGNED | 54-60 | `202604280005:158` (`operator_id uuid not null`); `202604250008:353` (`operator_id uuid null`) | none |
| Hash helper computes SHA-256 over (prev hash, payload) via pgcrypto; stores prev + this hash columns | ALIGNED rule / trivial name imprecision | 76-84 | `202604280005:174-175` columns are `prev_row_hash bytea null` / `row_hash bytea not null` (contract prose at :78 says "`prev_hash` and `this_hash` columns"; correct names used elsewhere in same doc at :21) | Optional: align the §"Hash chain mechanics" prose to the real column names `prev_row_hash`/`row_hash` |
| Authority anchors exist: 0005 / 0014 migrations, `audit_anchor/main.dart`, operator + admin audit screens | ALIGNED | 130-149 | `202604280014_..._audit_privacy_role.sql`, `tool/audit_anchor/main.dart`, `lib/operator_web/screens/audit_log_screen.dart`, `lib/admin/screens/audit_log_admin_screen.dart` all present | none |

Detail: The full audit confirms the dual-chain architecture exactly — the
NOT-NULL vs nullable `operator_id` split, the per-table SHA-256 chains,
and all named authority anchors. The only nit is a prose imprecision
(`prev_hash`/`this_hash` informal names vs the actual
`prev_row_hash`/`row_hash`) in one section; the binding substance holds.

### 8. audit_attribution_contract.md

Verdict: **FULLY ALIGNED. Zero DRIFT.**

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| `audit_logs`: `actor_kind text not null check in ('user','service')`, `actor_user_id uuid`, `actor_principal_id text`; `audit_logs_actor_shape_check` exactly-one-actor | ALIGNED | 27-72 | `202604280005:163-166,181-188` byte-identical | none |
| `auth_events_audit`: `actor_kind` w/ no paired shape CHECK (repo-enforced); `actor_service_principal_id uuid` | ALIGNED | 65-72, 120-144 | `202604280004_..._service_principals.sql:18-19` (actor_kind inline, no shape CHECK); typed uuid column | none |
| 2026-05-13 widening adds `team_member`/`forge_admin`/`service_principal` + `admin_reason`; `user`/`service` legacy aliases; `forge_admin` rows require `admin_reason` | ALIGNED | 51-57 | `202605131000_admin_audit_log_actor_reason_contract.sql:20-23` (new labels), `:32` (`add column admin_reason`), `:42-45,57` (legacy set + forge_admin gate) | none |
| Hash-chain canonical encoding: fixed column order, ASCII 0x1F (Unit Separator) delimiter | ALIGNED | 103-112 | `202604280005:258` (`delimiter text := chr(31)`), `:293-301` column order + delimiter, `:312` `digest(coalesce(prev_row_hash..)||canonical)` | none |

Detail: Every material claim verified — actor-shape CHECK, the
text-vs-uuid divergence rationale, the 2026-05-13 label widening +
`admin_reason`, and the chain canonical encoding (chr(31) Unit Separator
delimiter, fixed column order). Zero drift; the contract is exact.

### 9. advisor_conversation_log_contract.md

Verdict: **FULLY ALIGNED. Zero DRIFT.**

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Row carries `content_encrypted bytea NOT NULL`, `content_iv bytea NOT NULL`, `content_key_ref text NOT NULL`, `content_hash text NOT NULL` (SHA-256 hex) | ALIGNED | 43-66 | `202604280007_phase_9_0sigma_h_advisor_conversation_log.sql:125-127,133-134` (`content_hash ~ '^[0-9a-f]{64}$'`) | none |
| `legal_hold boolean NOT NULL DEFAULT false`; `retention_class text NOT NULL DEFAULT 'standard'` (standard/extended/legal/permanent); purge SECURITY DEFINER fn never deletes legal_hold/permanent | ALIGNED | 220-242 | `202604280007:182-185` (4-bucket check) | none |
| Permission `PermissionKeys.adminAuditPrivacyRead='admin.audit_privacy.read'` requires_mfa=true, frozen | ALIGNED | 86-121 | `lib/auth/permission_keys.dart:150` (`// MFA`), `:314` (in `all`), `:369` (in `requiresMfa`) | none |
| Repo `auditReadConversation`: `SET LOCAL ROLE audit_privacy` → SELECT encrypted cols → `RESET ROLE` → paired `audit_logs` insert, same tenant tx | ALIGNED | 157-218 | `advisor_conversation_log_repository.dart:131` (`recordTurn`), `:327` (`auditReadConversation`), `:309-318` (SET LOCAL ROLE → RESET ROLE sequence) | none |

Detail: Encryption-at-rest column shape, retention/legal-hold ledger,
the MFA-gated audit-privacy permission, and the
SET-LOCAL-ROLE/RESET-ROLE/paired-audit-insert repository sequence all
hold exactly. The contract is a precise mirror of the migration + repo.

### 10. team_roles_hierarchy_console_parity_contract.md

Verdict: **Strongly ALIGNED on the W3.A mobile-mirror posture +
parity mechanism.** STALE-CITATION on the W3.A line-number table (files
grew).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Hard Rule W3.A: mobile Settings is an unconditional read-only mirror (no `kDemoMode` branch); writes owned by Operator Web / F&F admin | ALIGNED (posture) | 42-94 | `settings_mfa_section.dart:76,87` (`viewOnly` flag), `settings_active_sessions_section.dart:144,158,427` (`viewOnly` gates revoke), `settings_screen.dart:381,396,402,549` (`viewOnly:true` + `SettingsPointerRow`); unconditional, no demo branch | none |
| W3.A suppression table line citations (`settings_mfa_section.dart:84-87`, `settings_active_sessions_section.dart:155-158`, wired at `settings_screen.dart:477-486` / `:529-540` etc.) | **STALE-CITATION** | 57-67 | Symbols/behavior present and correct; specific line ranges drifted as files grew (e.g. MFA `viewOnly` at `:76/:87` not `:84-87`; wirings at `:396/:549` not `:477-486/:529-540`) | Refresh the W3.A line-number table; posture unchanged |
| Reusable team controllers `TeamUsersListController` / `TeamInviteFormController` / `TeamScopeVisibilityPolicy` (ChangeNotifier, pure) | ALIGNED | 235 | `lib/services/team/{team_users_list_controller,team_invite_form_controller,team_scope_visibility_policy}.dart` all present | none |
| Audit-row shape: `actor_kind` `team_member`/`forge_admin`/`service_principal`, `admin_reason` required for forge_admin, hash-chain not bypassed | ALIGNED | 113-127 | Consistent with audit_attribution + audit_log_architecture audits above (same `202605131000` labels + `admin_reason`) | none |

Detail: The binding W3.A posture (mobile = deliberate production
read-only mirror, suppression hardcoded with no demo branch, writes on
Operator Web / F&F admin) is honored in code, and the reusable
controllers exist verbatim. Only the W3.A code-citation table aged out as
the settings files grew — same citation-drift pattern as Phases 2-3.

### 11. mobile_core_business_scope_contract.md

Verdict: **ALIGNED on Hard Rules + HP #11 carve-out doctrine.** 1 STALE
("Current Code Reality" snapshot the code has overtaken).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| "Current repo search found no `business_scope*` files anywhere in `lib/`; mobile … never offers a switcher" | **STALE** (code ahead) | 33-49 | `lib/domain/models/business_scope.dart`, `lib/services/scope/business_scope_repository.dart`, `lib/infrastructure/persistence/sqlite/repositories/sqlite_active_scope_repository.dart`, `advisor_proxy.dart:194-196` (`businessScopes*` route) all now exist | Mark the §"Current Code Reality" snapshot historical; the scope work landed |
| Hard Rule 9: HP #11 carve-out — mobile is single-location by design; not required to show the scoped/inherited/effective triad | ALIGNED (doctrine) | 116-134 | Consistent w/ `CLAUDE.md` HP #11 clause + memory note `project_mobile_hp11_carveout`; binding doctrine unaffected by the landed code | none |

Detail: A planning contract whose pre-implementation "Current Code
Reality" section has been overtaken — the `business_scope*` files and the
`/v1/users/.../business_scopes` route it says do not exist now do. The
Hard Rules and the HP #11 carve-out remain binding doctrine; only the
dated snapshot is stale.

### 12. mobile_core_star_target_truth_contract.md

Verdict: **ALIGNED on Hard Rules doctrine.** 1 STALE ("Current Code
Reality" snapshot overtaken).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| "Current repo search found no Postgres/proxy server owner for selected stars / target cycles / active target profiles" | **STALE** (code ahead) | 51-58 | Migration `202605061900_phase_8_star_target_truth.sql`; `selected_star_shift_repository.dart`, `target_cycle_repository.dart` (postgres) now exist | Mark the §"Current Code Reality" snapshot historical |
| Hard Rules: server-owned, RLS, operator_id-leading, once-per-cycle override server-side, separate recommended-vs-selected | ALIGNED (doctrine) | 103-120 | Consistent with the landed star/target server tables; binding rules intact | none |

Detail: Same pattern as #11 — the "no server owner" snapshot is overtaken
by the Phase 8 star/target-truth migration + Postgres repos. Hard Rules
hold as doctrine.

### 13. mobile_core_weekly_plan_server_truth_contract.md

Verdict: **ALIGNED on Hard Rules doctrine.** 1 STALE ("Current Code
Reality" snapshot overtaken).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| "Current repo search found no Postgres/proxy server owner for weekly plan snapshots / forecast context" | **STALE** (code ahead) | 49-57 | Migration `202605080100_phase_8_weekly_plan_server_truth.sql`; `weekly_plan_snapshot_repository.dart`, `forecast_context_repository.dart` (postgres) now exist | Mark the §"Current Code Reality" snapshot historical |
| Hard Rules: prior plan preserved as superseded (not deleted); FK to `target_cycles` RESTRICT; forecast_context immutable for closed dates; RLS + operator_id-leading | ALIGNED (doctrine) | 99-121 | Consistent with the landed weekly-plan server-truth migration; binding rules intact | none |

Detail: Same pattern — "no server owner" overtaken by the weekly-plan
server-truth migration + Postgres repos. Hard Rules hold as doctrine.

### 14. mobile_core_first_connection_backfill_contract.md

Verdict: **ALIGNED on Hard Rules.** 1 STALE ("missing production pieces"
list overtaken).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| "Missing production pieces: a durable first-backfill work queue / claimable job seam; backfill worker; post-commit projector" | **STALE** (code ahead) | 53-62 | Migration `202605061800_phase_8_first_connection_backfill_jobs.sql`; `lib/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository.dart` now exist | Mark the §"missing production pieces" list historical |
| Hard Rules: mobile is cache, 60-day bounded window, watermark per batch, demo flips only after first committed row, no banned Phase 8 lean-cut patterns | ALIGNED (doctrine) | 89-109 | Consistent with the landed backfill-jobs migration + repo; binding rules intact | none |

Detail: The "missing pieces" list (durable backfill queue + worker) is
overtaken by the first-connection-backfill-jobs migration + repository.
Hard Rules hold as doctrine.

### 15. mobile_typography_and_spacing_contract.md

Verdict: **ALIGNED.** Token system implemented as specified.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| 7 semantic role getters on `AppTextStyles` (`screenTitle`/`sectionHeading`/`bodyText`/`bodyStrong`/`caption`/`metricLarge`/`metricSmall`) | ALIGNED | 16-34 | `lib/theme/app_theme.dart:184` `AppTextStyles`; `:457-476` all 7 getters present | none |
| Legacy primitive names historical; `fontSize:` in `app_theme.dart` authoritative (getter→primitive aliasing sanctioned) | ALIGNED (contract self-qualifies) | 31-34 | `bodyText()=>body13(...)`, `caption()=>body11(...)` — aliasing is contract-sanctioned, not drift | none |
| `AppSpacing` 4/8pt scale (xs=4/sm=8/md=12/lg=16/xl=24/xxl=32) + `screenH`/`card`/`row` helpers | ALIGNED | 52-65 | `app_theme.dart:57-82` byte-exact | none |
| `AppRadius` (small/card/pill) + `AppDecoration` (surfaceCard/accentChip/hairline/gradientCard) + `AppDivider` | ALIGNED | 68-111 | `app_theme.dart:94` `AppRadius`, `:114` `AppDecoration`, `:158` `AppDivider` | none |

Detail: An active Tier-2 code-binding contract that is implemented as
specified — all 7 semantic roles, the 6-token spacing scale (exact px),
and the radius/decoration/divider surface system are present in
`app_theme.dart`. The getter→legacy-primitive aliasing the contract
itself sanctions (the `fontSize:` is authoritative) is not drift.

### 16. operator_self_served_tos_contract.md

Verdict: **Schema ALIGNED; the "What stays" code-anchor list is STALE
(named UI seams removed/renamed).** Worth operator attention — a binding
"infrastructure is unchanged" claim contradicted by missing seams.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| `tos_versions` + `tos_acceptances` Postgres tables per Phase 9.8 schema | ALIGNED | 11-14, 20 | `db/migrations/202605040100_phase_9_8_tos_versions.sql` present (both tables, wrapper-only RLS, operator_id-leading indexes) | none |
| "What stays (unchanged): `lib/operator_web/screens/tos_accept_screen.dart`; `OperatorWebAcceptingTos` state in `operator_web_auth_source.dart`; `tos_acceptance` refs in `my_account_screen.dart`" | **STALE** | 21-27 | No `*tos*accept*` file anywhere in `lib/`; no `OperatorWebAcceptingTos`/`TosAcceptScreen`/`tos_accept` symbol anywhere in `lib/operator_web/`; `OperatorWebAcceptingTos` absent from `operator_web_auth_source.dart`. Only the Postgres schema survives | Operator-facing: the contract asserts the clickwrap UI infra is "unchanged" but the named operator-web ToS screen + auth-source state are gone. Reconcile the §"What stays" list to the current ToS surface (or document where the click-through moved). Schema authoritative; code wins on file/symbol facts |

Detail: The schema half is solid (the 9.8 ToS migration exists with the
contracted tables). But the §"What stays" section names a clickwrap UI
infrastructure (`tos_accept_screen.dart`, `OperatorWebAcceptingTos`
state, `my_account_screen.dart` refs) as deliberately unchanged — and
none of those file/symbol anchors exist anymore. This is not mere
line-number drift: the named binding seams are absent, so the contract's
"clickwrap infrastructure is unchanged" claim is contradicted by code.
Flagged for operator attention (a Tier-2 compliance/legal contract whose
UI-seam claims no longer match the tree).

### 17. v1_launch_slos.md

Verdict: **ALIGNED** (measurement-spec doc; few code anchors, all hold).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Alert implementations under `infrastructure/monitoring/alerts/`; `audit_anchor_lag.yaml` + `vendor_adapter_error_rate.yaml` cited | ALIGNED | 6, 113, 145 | `infrastructure/monitoring/alerts/{audit_anchor_lag,vendor_adapter_error_rate,...}.yaml` all present | none |
| SLO 4 compliance-critical: anchored rows in `audit_chain_anchors` before next UTC day; `audit_anchor_lag` alert | ALIGNED | 95-118 | `audit_chain_anchors` table in `202604280005`/`202605061700_hardening_audit_anchor_daily_schedule.sql`; alert yaml present | none |

Detail: A monitoring/SLO measurement spec, not a code-shape contract. Its
few falsifiable code anchors (the alert yaml files, the
`audit_chain_anchors` table backing SLO 4) all exist; targets/budgets are
policy, not code-bindable. ALIGNED.

### 18. per_vendor_doc_pack_contract.md

Verdict: **ALIGNED** (folder-shape binding holds).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Folder shape (binding): `docs/integrations/_template/` with `api_consumed.md` / `field_mapping.md` / `oauth_shape.md` / `webhook_signature.md` / `live_verification_checklist.md` / `partnership_status.md` | ALIGNED | 17-31 | `docs/integrations/_template/` has exactly those 6 files; a real pack (`docs/integrations/quickbooks_time/`) mirrors them | none |
| `<vendor_id>` matches `connector_connection.vendor_id` / `VendorCapabilityProfile.vendorId` | ALIGNED (cross-consistent) | 33-35 | Consistent with Phase-3 integration-spine audit (`VendorCapabilityProfile.vendorId`) | none |

Detail: The binding artifact (the per-vendor doc-pack folder shape) is
present exactly as specified, and a shipped vendor pack matches the
template. ALIGNED.

### 19. migrations_summary.md

Verdict: **DRIFTED** — stale auto-generated index, ~2x out of date.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| "Migration count: **66**" + per-migration architectural index | **DRIFTED** | 9 | `db/migrations/*.sql` actually contains **139** files. The summary (auto-generated by `scripts/generate_migrations_summary.py`, a manual graph-refresh helper) has not been regenerated since the set ~doubled | Regenerate `migrations_summary.md` (run the generator). Other contracts (e.g. `team_roles_hierarchy_console_parity_contract.md:109`) cite it as the source for the `proxy_requests` UNIQUE constraint — a 2x-stale index is a real, citable doc-vs-code drift. Live migrations authoritative |

Detail: An auto-generated migration index that is materially out of date
(claims 66 migrations vs 139 on disk). It is a manual graph-refresh
helper (not auto-run, per `CLAUDE.md` knowledge-graph rules), but several
contracts cite it as an authority for migration shape, so the staleness
is operator-relevant. Not a rule violation — a stale generated artifact
that needs regeneration.

### (status-narrative) phase_7_55_architecture_contract.md §531-588

Verdict: **"Already landed" ALIGNED; "still incomplete/deferred" list
partly STALE** (the deferred work shipped). Doctrine itself was already
validated ALIGNED by Phase 3.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| "Already materially landed: TargetCycle / ActiveTargetProfile / DemandForecastContext / WeeklyPlanSnapshot / business-date authority / timing boundary" | ALIGNED | 533-541 | All model classes present (verified §3 above + Phase 3 structural pass) | none |
| "Still incomplete and intentionally deferred: persisted restaurant timing config beyond timezone; app-owned service-period definition resolver; …" | **STALE** (≥2 of 6 shipped) | 543-550 | `lib/domain/models/restaurant_timing_config.dart` + `restaurant_timing_config_repository.dart` + migration `202605060000_phase_business_timing_live_schema.sql` (persisted timing config); `lib/domain/services/service_period_definition_resolver.dart` + `next_service_period_open_resolver.dart` (app-owned resolver) all now exist | Refresh the §"still incomplete" deferred-seam list; at least the timing-config + service-period-resolver items have landed. Doctrine claims unaffected |
| §"Phase Ownership" already-landed / current-next lists (`7.55l`/`m`/`k.*`) | NOT FULLY VERIFIED (tracker-state narrative) | 552-588 | Phase/slice bookkeeping narrative, not a code-shape spec; cross-checking each slice id vs the tracker is bookkeeping, not a guardrail | Low-priority doc hygiene; not a code-binding drift |

Detail: This is the status narrative Phase 3 deferred (the doctrine was
already ALIGNED). The "already landed" list is accurate; the "still
incomplete and intentionally deferred" list has aged out for at least the
persisted-timing-config and app-owned service-period-resolver items,
which have since shipped. The §"Phase Ownership" slice-ownership lists are
tracker bookkeeping, not a code guardrail.

---

## Roll-up counts

| Contract | ALIGNED | DRIFTED | STALE / STALE-CITATION |
|---|---|---|---|
| 1. phase_7_58_primary_driver (+ V2) | 5 | 1 | 1 (citation, grouped) |
| 2. phase_7_61_driver_key | 4 | 0 | 1 (citation, grouped) |
| 3. phase_7_55_target_cycle_weekly_plan_rules | 3 | 0 | 0 |
| 4. phase_7_55_current_state_freshness | 2 | 0 | 1 |
| 5. data_accuracy_settings | 5 | 1 | 0 (1 cosmetic note) |
| 6. event_outbox (FULL) | 6 | 0 | 0 |
| 7. audit_log_architecture (FULL) | 3 | 0 | 0 (1 trivial name nit) |
| 8. audit_attribution | 4 | 0 | 0 |
| 9. advisor_conversation_log | 4 | 0 | 0 |
| 10. team_roles_hierarchy_console_parity | 3 | 0 | 1 (citation) |
| 11. mobile_core_business_scope | 1 | 0 | 1 |
| 12. mobile_core_star_target_truth | 1 | 0 | 1 |
| 13. mobile_core_weekly_plan_server_truth | 1 | 0 | 1 |
| 14. mobile_core_first_connection_backfill | 1 | 0 | 1 |
| 15. mobile_typography_and_spacing | 4 | 0 | 0 |
| 16. operator_self_served_tos | 1 | 0 | 1 (binding seams gone) |
| 17. v1_launch_slos | 2 | 0 | 0 |
| 18. per_vendor_doc_pack | 2 | 0 | 0 |
| 19. migrations_summary | 0 | 1 | 0 |
| (sn) phase_7_55_architecture §531-588 | 1 | 0 | 1 |
| **Total** | **53** | **4** | **12** |

## Top drifts (operator attention)

1. **`operator_self_served_tos_contract.md` §"What stays" names a
   clickwrap UI infrastructure that no longer exists.** The contract
   asserts `lib/operator_web/screens/tos_accept_screen.dart`, the
   `OperatorWebAcceptingTos` auth-source state, and `my_account_screen.dart`
   ToS refs are deliberately *unchanged* — none of those file/symbol
   anchors exist anywhere in `lib/` now (only the Postgres ToS schema
   survives). This is a Tier-3 compliance/legal contract whose binding
   "clickwrap infrastructure is unchanged" claim is contradicted by
   code. Recommend operator-aware reconciliation (where did the
   click-through move? is the operator-web ToS gate still wired?).

2. **`migrations_summary.md` is ~2x stale** (claims 66 migrations;
   `db/migrations/` has 139). It is an auto-generated manual
   graph-refresh helper, but multiple Tier-2 contracts cite it as the
   authority for migration shape (e.g. the `proxy_requests` UNIQUE
   constraint in `team_roles_hierarchy_console_parity_contract.md:109`).
   Recommend regenerating it (`scripts/generate_migrations_summary.py`).
   Not a rule violation — a stale generated index.

3. **`phase_7_58_primary_driver_contract.md` G.5 carry-forward narrative
   is stale (code is ahead).** The contract describes the daypart
   carry-forward as still present and `7.58.5` as a pending fold; in
   fact `7.58.5` landed and
   `variance_week_projection_read_service.dart:171-189` removed it
   (open/projected rows now return "Not yet available", honoring the
   contract's own ban). Doc narrative should catch up to the shipped
   fix. Low risk (the ban is enforced); doc-narrative drift only.

4. **`data_accuracy_settings_contract.md` framework-max mechanism
   detail.** The contract calls the polling framework maximum a named
   resolver constant `kFrameworkMaximumCadenceSeconds`; code injects it
   as a parameter `frameworkMaximumCadenceSeconds`
   (`polling_cadence_resolver.dart:69,140`). Clamp-not-reject +
   `cadence_clamped` emission are honored exactly. Pure doc wording fix.

The four mobile_core contracts + `mobile_core_business_scope` +
`phase_7_55_architecture §531-588` share a benign pattern: planning-doc
"Current Code Reality" / "still deferred" snapshots written
pre-implementation that the code has since overtaken (the deferred work
shipped). Their binding Hard Rules / doctrine remain valid; only the
dated narrative is stale, with code ahead of the doc. These are
doc-hygiene refreshes, not rule-vs-code violations.

All findings are doc-side updates or regenerations (code/migrations are
authoritative in each per `CLAUDE.md` authority order). #1 (ToS) is the
one worth explicit operator attention (compliance/legal contract,
binding UI seams absent).

## Phase 5 remainder

**Empty — Phase 4 completes the `docs/contracts/*.md` sweep.**

Cross-off accounting against the full `docs/contracts/` enumeration (38
files):

- Phase 1: `core_app_architecture.md` (1)
- Phase 2: `hardening_rls_and_repository_pattern_contract.md`,
  `phase_7_55_time_boundary_contract.md`, `demo_mode_contract.md`,
  `slice_runtime_acceptance_contract.md` (4)
- Phase 3: the 11 hardening/proxy/metric/integration contracts +
  `auth_permission_key_catalog.md` + structural pass on
  `phase_7_55_architecture_contract.md` (12)
- Phase 4 (this doc): the 19 contracts above + the
  `phase_7_55_architecture_contract.md` §531-588 status narrative Phase 3
  deferred + `phase_7_55_plain_english_architecture.md` companion (21)

1 + 4 + 12 + 21 = 38 = every `docs/contracts/*.md`. Nothing remains
unaudited. Phase 5, if run, is the doc-side reconciliation pass
(applying the fixes in Top Drifts + the citation/snapshot refreshes),
not further auditing — and the auth/compliance/proxy-adjacent items
(#1 ToS UI seams, #2 migrations_summary regeneration, the OAuth
advisory-lock carve-out carried from Phase 3) are operator-gated per
`CLAUDE.md` (auth-critical / proxy-touching change gate).
