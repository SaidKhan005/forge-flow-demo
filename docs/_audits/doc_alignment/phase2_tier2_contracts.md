# Phase 2 — Tier-2 Authority Contracts vs Code Alignment Audit

Audit date: 2026-05-18
Auditor: Claude doc-alignment worker (Phase 2)
Scope: Tier-2 authority contracts under `docs/contracts/**` EXCLUDING
`core_app_architecture.md` (covered by Phase 1
`docs/_audits/doc_alignment/phase1_core_app_architecture.md`).
Method: line-by-line material-claim audit vs live `lib/**` + `db/migrations/**`.
Authority order per `CLAUDE.md` "Authority Order": active prompt > Tier-2
contracts > trackers > phase docs > `CLAUDE.md`.

Classification key:
- **ALIGNED** — doc claim matches live code.
- **DRIFTED** — doc claim and code disagree on substance; both still live.
- **STALE** — doc references a path/line/state that has moved or no longer
  exists; the substance may still be correct but the citation is wrong.
- **STALE-INFO** — a time-sensitive status note in an advisory doc that has
  aged out (not code-binding).

Contracts thoroughly audited this pass (4 priority + 2 spot-validated):

1. `hardening_rls_and_repository_pattern_contract.md` — thorough
2. `phase_7_55_time_boundary_contract.md` — thorough
3. `demo_mode_contract.md` — thorough
4. `slice_runtime_acceptance_contract.md` — thorough
5. `audit_log_architecture_contract.md` — spot-validated (structural)
6. `event_outbox_contract.md` — spot-validated (structural)

Not yet audited (Phase 3 scope) — see final section.

---

## Per-contract summary

### 1. hardening_rls_and_repository_pattern_contract.md

Verdict: **Strongly ALIGNED.** 0 DRIFTED, 0 STALE on material claims.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| New wrapper migration `<ts>_hardening_auth_rls_to_wrappers.sql` exists, idempotent, single-tx | ALIGNED | 61, 86 | `db/migrations/202605020500_hardening_auth_rls_to_wrappers.sql:21-26,55-70` | none |
| All policies use 4 wrapper fns (`app_current_operator/_location/_actor_user/_acting_as_operator`), no bare `current_setting('app.*')` in bodies | ALIGNED | 70-79, 98-101 | `202605020500_...sql:80-210` (every policy uses `public.app_current_operator()` / `app_current_actor_user()`) | none |
| `tool/rls_policy_lint.dart` ~251 LOC | ALIGNED | 92 | `tool/rls_policy_lint.dart` = 251 lines | none |
| Allowlist supersedes `202604260000` via `202604280001` | ALIGNED | 106-107 | `tool/rls_policy_lint_allowlist.txt:18-19` | none |
| 13 listed service files no longer import `package:postgres` | ALIGNED | 114-132 | `Grep "import 'package:postgres'" lib/services` = 0 matches | none |
| Repositories under `lib/infrastructure/persistence/postgres/` extend `OperatorScopedRepository`; base exposes exactly `withTenant` + `withSystem` | ALIGNED | 134-162 | `lib/infrastructure/persistence/postgres/operator_scoped_repository.dart:24-55` | none |
| Sanctioned exception: `audit_logs_repository.dart` does NOT extend `OperatorScopedRepository`; cross-checks `operatorId` vs `current_setting('app.operator_id', true)` before bind; throws `AuditLogsTenantMismatchError`; accepts as-is when GUC unset | ALIGNED | 166-181 | `lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart:78` (`class AuditLogsRepository` — no extends), `:183-202` (`_assertTenantContextMatches`), `:222` (`AuditLogsTenantMismatchError`) | none |
| `tool/postgres_import_lint.dart` exists, covers `lib/services/` (only `lib/infrastructure/persistence/postgres/`, `tool/advisor_proxy/`, `test/` exempt) | ALIGNED | 183-193 | `tool/postgres_import_lint.dart:135-145` (default allowed dirs); `tool/` NOT exempt per `:20` | none |

Detail: This is a Closed contract retained as historical authority
(doc:3-13). Every material implementation claim verified against live code
holds. The sanctioned `audit_logs_repository.dart` exception is
implemented exactly as the contract prose describes (GUC compare before
SQL bind; pass-through when GUC empty/null on the system path). No drift.

### 2. phase_7_55_time_boundary_contract.md

Verdict: **Mostly ALIGNED**, 1 STALE (code-seam path list). 0 substantive
DRIFT on the binding storage/cycle rules.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Rule 5/6: `TargetCyclePolicy.needsAutoRefresh(cycle, businessDate, weekStartDay)` returns true only when `businessDate > effectiveEnd` AND `weekday(businessDate) == weekStartDay` | ALIGNED | 311-313 | `lib/domain/services/target_cycle_policy.dart:50-57` (`if (businessDate.compareTo(cycle.effectiveEnd) <= 0) return false; return _parseDate(businessDate).weekday == weekStartDay;`) | none |
| Rule 11: `TIMESTAMP WITHOUT TIME ZONE` banned in operator-scoped fact tables | ALIGNED | 410-413 | No actual `timestamp without time zone` column definitions in `db/migrations/**`; all 11 textual hits are comment/prose context (banning or referencing the rule). Fact tables use `timestamptz` (e.g. `202605131900_c_2_d_vendor_sync_outage_state.sql:135-141`) | none |
| Rule 11: source instants `TIMESTAMPTZ` + denormalized write-once `business_date DATE` alongside | ALIGNED (spot) | 398-416 | `business_date` present across fact-table migrations; spot-checked outage-state table uses `timestamptz` columns | none |
| Code seam: `business_date_authority_service.dart` lives under `lib/data/` | **STALE** | 501 | Actual: `lib/services/business_date_authority_service.dart` (moved per `CLAUDE.md` Service-Layer Split: `lib/data/` is frozen legacy, runtime orchestration moved to `lib/services/`) | Update doc "Current Code Seams" path list (`lib/data/business_date_authority_service.dart` → `lib/services/...`); likewise re-verify the other `lib/data/*` seam paths at 501-520 in Phase 3 |
| "Current Repo Reality / still implicit or missing" inventory (lines 482-495) | NOT RE-VERIFIED | 482-495 | Deferred — this is a self-declared gap list, not a guardrail; verifying each gap is a Phase 3 follow-up | Phase 3: re-verify gap list vs current state |

Detail: The two binding code-bound rules (Rule 6 cycle-refresh predicate,
Rule 11 timestamp storage) are ALIGNED. The contract's "Current Code
Seams This Contract Must Govern" section (497-525) lists `lib/data/*`
paths; at least `business_date_authority_service.dart` has moved to
`lib/services/` under the Service-Layer Split. Authority: `CLAUDE.md`
Service-Layer Split + the live tree win; the contract's path list is the
stale side. Substance of the rule is unaffected — recommend a path
refresh, not a rule change. The "still implicit or missing" inventory
(484-495) was not re-verified this pass (self-declared gap list, not a
guardrail) — flagged for Phase 3.

### 3. demo_mode_contract.md

Verdict: **ALIGNED on architecture; STALE on carve-out line citations.**
0 substantive DRIFT (HP #2 writer-side switch is honored). 2 STALE line
citations.

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| No `demo_*` SQLite or Postgres parallel tables; only sanctioned `demo_mode_state` Postgres table | ALIGNED | 75, 453-455, 483-486 | No `demo_*` SQLite CREATE TABLE; only `public.demo_mode_state` at `db/migrations/202605040000_phase_8_0_integration_framework.sql:395` (explicitly endorsed by contract) | none |
| Carve-out #1 `_demoOperatorSignInEnabled` const at `login_screen.dart:17-19` | **STALE** | 290 | Actual: `lib/screens/auth/login_screen.dart:27-28` (`const bool _demoOperatorSignInEnabled = bool.fromEnvironment('kDemoMode') || ...`); the `// kDemoMode carve-out:` comment is at `:17` | Update doc line citation to `:27-28` |
| Carve-out #2 `_demoMode` const at `app_data_status_service.dart:33`; branch `if (_demoMode && hasOpenState)` at `:153` | ALIGNED | 309-312 | `lib/services/app_data_status_service.dart:33` (const), `:153` (`if (_demoMode && hasOpenState) {`) — both exact | none |
| Carve-out #3 `_kDemoMode` const at `settings_screen.dart:31`; "Data reset" gate `:374`; "Demo date" gate `:383` | **STALE** | 339-342 | Actual: `lib/screens/settings_screen.dart:49` (const `_kDemoMode`), `:461` (`if (_kDemoMode)` → `'Data reset'` / `SettingsDataManagementSection`), `:468` (`if (_kDemoMode)` → `'Demo date'`) | Update doc line citations to `:49`, `:461`, `:468` |
| Carve-out #4 `lib/screens/settings/settings_demo_live_switch.dart` exists; runtime `demo_mode_state` fold, no `kDemoMode` | ALIGNED | 379-381 | File exists at that path | none |
| Standalone demo flavor uses `DemoAuthLoginService` (`lib/services/auth/demo_auth_login_service.dart`) | ALIGNED | 206 | File exists at that path | none |
| Proxy/server carve-out `pepper_resolver.dart:64` (`EnvPepperResolver._demoMode`) | ALIGNED | 420 | `lib/services/auth/pepper_resolver.dart:64` (`bool demoMode = const bool.fromEnvironment('kDemoMode')`) — exact | none |

Detail: The HP #2 writer-side architecture is honored — no `demo_*`
parallel tables, the only demo Postgres table (`demo_mode_state`) is the
one the contract explicitly sanctions. The substantive contract holds.
The drift is purely in line-number citations for carve-out #1 and #3:
`login_screen.dart` (doc says 17-19, code is 27-28) and
`settings_screen.dart` (doc says 31/374/383, code is 49/461/468). The
const symbols, the `// kDemoMode carve-out:` comments, and the
behavior all still exist and match the contract's described semantics —
only the numeric anchors drifted as the files grew. Carve-out #2 and the
pepper-resolver citation are byte-exact. Authority: live code wins on
line numbers; recommend a citation refresh, no architectural change.

### 4. slice_runtime_acceptance_contract.md

Verdict: **ALIGNED** (advisory process contract). 1 STALE-INFO
(time-sensitive Production1 anchor note, not code-binding).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Status: advisory pattern, NOT CI-enforced | ALIGNED | 3-17 | Matches `CLAUDE.md` "Runtime acceptance (advisory pattern, not CI-enforced)" | none |
| Referenced runbook `runbooks/browser_use_codex_acceptance_workflow.md` exists | ALIGNED | 90 | File exists | none |
| Referenced runbook `runbooks/admin_console_browser_qa_runbook.md` exists | ALIGNED | 92 | File exists | none |
| Migration drift scanner + cutoff lint tools exist (enforced gates) | ALIGNED | 236, 250 | `tool/migration_drift_scanner.dart`, `tool/migration_cutoff_lint.dart`, `scripts/postgres_staging_setup.ps1` all exist | none |
| Referenced `docs/contracts/operator_self_served_tos_contract.md` exists | ALIGNED | 213 | File exists | none |
| "Production1 is current through `202605021900_..._corpus_versions_seed_existing_chunks.sql` as of 2026-05-03; pending `202605031430_..._debug_proxy_requests_forge_admin_grant.sql`" | **STALE-INFO** | 150-158 | Both named migrations exist; but this is a 2026-05-03 deployment-anchor snapshot and the migration set has advanced well past it. Inherently time-sensitive; not code-binding. | Phase 3 (optional): refresh or remove the dated Production1 anchor note, or mark it explicitly historical |

Detail: This is an advisory process/checklist contract, deliberately not
CI-enforced (its own status banner + `CLAUDE.md` agree). It makes few
code claims; every referenced runbook, tool, and contract exists. The
only aged item is the dated "Production1 Migration Apply" anchor
(150-158), which is a status snapshot from 2026-05-03 — flagged
STALE-INFO, not drift, since the doc is advisory and the note is
explicitly time-stamped.

### 5. audit_log_architecture_contract.md (spot-validated)

Verdict: **ALIGNED** at the structural level (full line-by-line deferred
to Phase 3).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Two parallel tamper-proof chains: `audit_logs` (customer-scoped, RLS) + `auth_events_audit` (F&F-internal) | ALIGNED (structural) | 9-22 | `audit_logs` table in `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`; `auth_events_audit` in `202604250008_auth_schema_foundation.sql` | Phase 3: full per-row-field + RLS-policy line audit |
| Each table runs an independent SHA-256 `prev_row_hash → row_hash` hash chain | ALIGNED (structural) | 20-22 | `202604280005_..._audit_logs.sql:8,28,146-174` (`row_hash` = `SHA-256(prev_row_hash ...)`, `prev_row_hash bytea null`) | Phase 3: verify chain math + writer helper |

### 6. event_outbox_contract.md (spot-validated)

Verdict: **ALIGNED** at the structural level (full line-by-line deferred
to Phase 3).

| Claim | Status | Doc line | Code file:line | Action |
|---|---|---|---|---|
| Foundation slice lands `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql` + `event_outbox_repository.dart` (enqueue/claimBatch on `OperatorScopedRepository`) | ALIGNED (structural) | 31-39 | `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql` exists; `lib/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart` exists | Phase 3: verify topic shape, claim index, RLS wrapper, notify trigger line-by-line |
| Table is source of truth; `pg_notify('event_outbox', …)` is a wake-up signal only | ALIGNED (structural, consistent with `slice_runtime_acceptance_contract.md` §10a "NOTIFY is a wake-up signal only") | 12-16 | Migration present; cross-consistent with other contracts | Phase 3: confirm trigger body |

---

## Roll-up counts

| Contract | ALIGNED | DRIFTED | STALE | STALE-INFO | Coverage |
|---|---|---|---|---|---|
| hardening_rls_and_repository_pattern | 8 | 0 | 0 | 0 | Thorough |
| phase_7_55_time_boundary | 3 | 0 | 1 | 0 | Thorough (gap-list deferred) |
| demo_mode | 5 | 0 | 2 | 0 | Thorough |
| slice_runtime_acceptance | 5 | 0 | 0 | 1 | Thorough |
| audit_log_architecture | 2 | 0 | 0 | 0 | Spot (structural) |
| event_outbox | 2 | 0 | 0 | 0 | Spot (structural) |
| **Total** | **25** | **0** | **3** | **1** | — |

### Top drifts (all STALE citations; zero substantive DRIFT)

1. **demo_mode_contract.md:290** — carve-out #1 cites
   `login_screen.dart:17-19`; actual const is `:27-28` (comment at `:17`).
2. **demo_mode_contract.md:339-342** — carve-out #3 cites
   `settings_screen.dart:31/374/383`; actual is `:49/461/468`.
3. **phase_7_55_time_boundary_contract.md:501** — code-seam list cites
   `lib/data/business_date_authority_service.dart`; file moved to
   `lib/services/business_date_authority_service.dart` (Service-Layer
   Split). The other `lib/data/*` seam paths (501-520) should be
   re-verified in Phase 3.

Note: zero substantive DRIFT was found in this pass. All 3 STALE items
are line/path citations that aged as files grew or moved under the
Service-Layer Split; the underlying contract substance holds in every
case. The 1 STALE-INFO is a dated deployment-anchor note in an advisory
doc.

### Recommended actions (no code changes — doc-citation refresh only)

These are documentation citation refreshes, NOT code or contract-rule
changes. Authority order: live code wins on line/path facts; the
contracts' substantive rules are unchanged and remain authoritative.

- demo_mode_contract.md: refresh carve-out #1 / #3 line citations.
- phase_7_55_time_boundary_contract.md: refresh the "Current Code Seams"
  path list to the post-Service-Layer-Split locations.
- slice_runtime_acceptance_contract.md (optional): mark the 2026-05-03
  Production1 anchor note as historical or refresh it.

---

## Contracts NOT yet audited (Phase 3 scope)

Excluding `core_app_architecture.md` (Phase 1) and the 6 above, the
remaining `docs/contracts/*.md` were not audited this pass. Priority
hint: the code-binding ones first (schema/repo/proxy), process/spec docs
later.

Higher priority (code/schema-binding):
- advisor_conversation_log_contract.md
- audit_attribution_contract.md
- auth_permission_key_catalog.md (frozen catalog — verify vs `lib/auth/`)
- data_accuracy_settings_contract.md
- hardening_admin_cors_and_limits_contract.md
- hardening_auth_protection_contract.md
- hardening_devops_surface_contract.md
- hardening_feature_flag_idempotency_contract.md
- hardening_observability_baseline_contract.md
- hardening_production_wiring_contract.md
- hardening_test_corrections_contract.md
- integration_spine_architecture_contract.md
- metric_card_honesty_contract.md
- phase_7_55_architecture_contract.md (source of re-assembled #2 authority)
- phase_7_55_target_cycle_weekly_plan_rules.md
- phase_7_58_primary_driver_contract.md
- phase_7_61_driver_key_contract.md
- proxy_health_contract.md
- v1_launch_slos.md
- vendor_adapter_slice_contract.md
- Deeper line-by-line follow-up on the 2 spot-validated contracts:
  audit_log_architecture_contract.md, event_outbox_contract.md
- Deferred sub-item: phase_7_55_time_boundary_contract.md "Current Repo
  Reality / still implicit or missing" inventory (lines 482-495) and the
  full `lib/data/*` → `lib/services/*` seam-path re-verification (501-520)

Lower priority (process / spec / plain-english companions):
- mobile_core_business_scope_contract.md
- mobile_core_first_connection_backfill_contract.md
- mobile_core_star_target_truth_contract.md
- mobile_core_weekly_plan_server_truth_contract.md
- mobile_typography_and_spacing_contract.md
- operator_self_served_tos_contract.md
- per_vendor_doc_pack_contract.md
- phase_7_55_current_state_freshness_contract.md
- phase_7_55_plain_english_architecture.md
- team_roles_hierarchy_console_parity_contract.md
- migrations_summary.md
