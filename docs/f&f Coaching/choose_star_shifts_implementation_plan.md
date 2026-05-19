# Choose Star Shifts — End-to-End Implementation Plan

Status: ACTIVE — 2026-05-16
Mockup: `docs/f&f Coaching/choose_star_shifts_prototype.html` (live reference, 4-period operator to stress de-hardcode)
Authoritative phase doc: `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` — these slices append there as **R1–R6 (Choose Star Shifts redesign)**. This is NOT a parallel plan; the redesign reuses the landed per-period spine and the existing manager-override write path. Hard Promise: no parallel target stacks.

## 1. Baseline (from deep audit, file:line verified)

The per-daypart direction is **substantially LANDED** (plan slices 0,1,1.5,2,2.5,3,4,5,6,S0 all merged):

- Per-period persistence: `db/migrations/202605160000_per_daypart_v1_per_period_target_persistence.sql` (`target_cycle_dayparts`, RLS-enabled, operator-leading indexes, wrapper-fn policies, `timestamptz`).
- Write path is per-period: `lib/services/target_cycle_service.dart:280-365` builds `cycleDayparts` + `TargetCycleDaypartPool.fromDayparts` (`:515`); whole-day parent IS the cover-weighted rollup (Design Rule 4), enforced by the Slice 6 pool-consistency check `lib/services/data_alignment_audit_read_service.dart:543-577`.
- `ActiveTargetProfile` carries `List<ActiveTargetProfileDaypart>` + `daypartFor()` (`lib/domain/models/active_target_profile.dart:124,149`).
- Operator-configured periods resolve via `RestaurantTimingConfigReadService.getActiveTimingConfig().servicePeriodDefinitions` → `ServicePeriodDefinitionResolver` (canonical pattern already used at `lib/services/benchmark_tracker_read_service.dart:86-90`).
- Slice 1.5 boundary mismatch (plan Gap 20) is RESOLVED — aggregator delegates to `DaypartBucketer` (`lib/services/integration/canonical_fact_to_closed_shift_input.dart:1110,1158`); no false pool-consistency drift.

Conclusion: redesign = UI re-composition + thread resolved `defs` + extend preview to per-period + surface the existing once-per-cycle gate + close the deferred Gap 27/36 schema debt. No new backend math.

## 2. Hard constraints (NO-GO if violated — audit every slice)

1. **No parallel stack (HP).** The Lean/Balanced/Generous band may ONLY produce a `Set<String> recordKey` fed to the unchanged `BaselineManagerService.saveSelection` → `TargetCycleService.applyManagerOverrideCycle` → `_writeReplacementCycle` (`lib/services/baseline_manager_service.dart:319-401`, `lib/services/target_cycle_service.dart:253-366`). No `strictness` column, no second pool formula, no second persistence shape.
2. **No hardcoded dayparts anywhere.** Every period iteration/label/order/count derives from `ServicePeriodDefinitionResolver.ordered(config.servicePeriodDefinitions)`. No `['lunch','dinner','late_night']`, no `enum Daypart`, no `/3`/`/N` covers split.
3. **Whole day = cover-weighted rollup, read not recomputed.** Display reads the existing pool (`TargetCycleDaypartPool.fromDayparts` / `ActiveTargetProfile` parent scalars). Covers/hours/sales sum; CPLH/SPLH/PPA cover-weighted.
4. **Wage whole-day only (Design Rule 5).** Per-period labor $ = period hours × whole-day wage. No per-period/cover-weighted wage.
5. **HP#2 / RLS / time:** no `kDemoMode` reader branch; writes stay operator/location scoped via existing path; no new tables outside the gated R5 keyed-table backfill.
6. **Once-per-cycle gate** (`TargetCyclePolicy.canManagerOverride`, `lib/domain/services/target_cycle_policy.dart:29-30`) surfaced BEFORE commit, exception catch kept as backstop.

## 3. Slices

| Slice | Scope | Primary files | Depends-on | Lane | Gate |
|---|---|---|---|---|---|
| **R1** Lens + timing-config wiring + calendar de-hardcode + pre-commit gate (R4 folded in) | Load timing config in screen `initState`; operator-config-driven daypart lens re-scoping calendar (2 states closed/selected) + summary together; thread resolved `defs` killing `baseline_manager_service.dart:131`, `baseline_manager_screen.dart:136`, `baseline_manager_day_detail.dart:89`; read active cycle + `canManagerOverride` and render gate state before selection | `lib/screens/baseline_manager_screen.dart`, `lib/screens/baseline_manager/baseline_manager_calendar.dart`, `lib/screens/baseline_manager/baseline_manager_day_detail.dart`, new `lib/screens/baseline_manager/baseline_manager_lens.dart`, `lib/screens/baseline_manager/baseline_manager_actions.dart`, `lib/services/baseline_manager_service.dart:131` | Plan Slice 1 (landed) | A | auto (no schema/RLS/proxy) |
| **R2** Tap-day bottom-sheet + per-service rollup + per-period toggles | Replace `DayDetail` push-nav with `showModalBottomSheet`; whole-day tap renders per-service rollup header (cover-weighted, reuse pool shape) + per-period keep toggles | `lib/screens/baseline_manager_screen.dart`, `lib/screens/baseline_manager/baseline_manager_day_detail.dart` | R1 (same screen state + `defs`) | A (serialized after R1) | auto |
| **R3** Lean/Balanced/Generous band + per-period preview (closes plan Gap 40) | Band = top-N-per-configured-period recordKey selector → mutates `_draftKeys` only, commits through unchanged path; extend `ManagerOverridePlanPreview` to per-period shape with covers from timing-config splits (no `/N`) | `lib/screens/baseline_manager_screen.dart`, `lib/screens/baseline_manager/baseline_manager_preview.dart`, `lib/screens/baseline_manager/baseline_manager_actions.dart` | R1, R2 | A (serialized after R2) | auto (verify HP no-parallel-stack in audit) |
| **R5** Gap 27/36 de-hardcode + keyed-table backfill | Replace `enum Daypart` with resolver-keyed `servicePeriodId`; migrate 4 covers UIs; backfill `covers_source_{lunch,dinner,late_night}` → existing `data_accuracy_service_period_settings`; drop legacy columns | `lib/domain/models/data_accuracy_settings.dart`, `lib/.../covers_source_toggle.dart`, `covers_manual_entry_card.dart`, `covers_historical_seed_card.dart`, `settings_covers_setup_section.dart`, new backfill+drop migration | independent of R1–R3 | B (parallel) | **OPERATOR-GATED — schema-touching (column drop + backfill migration)** |
| **R6** 4-period demo operator (optional, proves de-hardcode in demo) | Add an N-period (4) demo operator/location so lens/calendar/breakdown/band exercise non-default periods | `lib/dev/mock_integration_replay_seed.dart`, `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart`, demo timing config | Plan Slice 1 (landed) | C (parallel, data-only) | auto (data only, no schema) |
| **R7** Hard-drop legacy covers_source columns (full cleanup, operator-requested follow-up) | Migrate the remaining legacy-column readers, then DROP `covers_source_{lunch,dinner,late_night}` from `data_accuracy_settings`: (1) `tool/advisor_proxy/proxy_bootstrap.dart` sync upsert + admin override SQL, (2) `public.effective_data_accuracy_settings_v` view (defined in `202605121200_admin_hierarchy_scoped_data_polling.sql`, also coalesces HP #11 `data_accuracy_scoped_overrides`), (3) the sync DTO + admin gateway hierarchy surface; then a drop migration | `tool/advisor_proxy/proxy_bootstrap.dart`, the `effective_data_accuracy_settings_v` view migration, admin hierarchy data-accuracy surface, new drop migration | R5 (landed) | independent lane | **OPERATOR-GATED — schema-touching AND proxy-touching (per CLAUDE.md, highest gate); sequence after the proxy/view/hierarchy reader migrations** |

## 4. Execution

- **Lane A (serialized, same files):** R1 → R2 → R3. Dispatch R1 now; R2/R3 only after the prior PR merges (they mutate `baseline_manager_screen.dart` + siblings — parallelizing them self-conflicts).
- **Lane B:** R5 — dispatched only after explicit operator approval (schema-touching per CLAUDE.md). After any `db/migrations/*.sql` change the agent runs `tool/migration_drift_scanner.dart --fix --strict-docs` then `tool/migration_cutoff_lint.dart` (house rule).
- **Lane C:** R6 — independent, data-only, parallel with Lane A.
- Every agent contract: install hooks (step 0) → branch → implement → self-audit (Pattern B, file:line) → `dart analyze` → commit + push → open PR → STOP. No merge, no tracker edits, no `--no-verify`. Orchestrator audits the PR diff against this plan + contracts, then merges (R5 merge needs operator sign-off).
- Audit artifacts: `docs/_audits/per_daypart_v1/landed/pr_<n>_<topic>.md`.

## 5. Acceptance

- Lens/calendar/summary/breakdown/band all driven by `servicePeriodDefinitions`; a 4-period operator renders correctly end to end (no `enum Daypart`, no `['lunch','dinner','late_night']`, no `/3`).
- Band commit produces only selected recordKeys through the existing override path; pool-consistency check (`data_alignment_audit_read_service.dart:543-577`) stays green.
- Whole-day numbers equal the cover-weighted rollup of per-period; wage whole-day only.
- Once-per-cycle gate visible before commit; denial still safe.
- `dart analyze` clean on changed files; targeted widget/logic tests for lens scoping + band→recordKey derivation + per-period preview.
