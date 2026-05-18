# Phase 1 Doc-Alignment Audit — `core_app_architecture.md` vs code

Status: **Audit-only** (no code or contract edits made)
Date: 2026-05-18
Auditor: Claude doc-alignment worker (Phase 1)
Authority doc under audit: `docs/contracts/core_app_architecture.md` (660 lines)

Authority order for "which is right" on conflict (per CLAUDE.md):
active prompt > `docs/contracts/core_app_architecture.md` > other
`docs/contracts/**` > trackers > phase docs > CLAUDE.md.

---

## Summary

| Status   | Count |
|----------|-------|
| ALIGNED  | 22    |
| DRIFTED  | 4     |
| STALE    | 0     |
| **Total**| **26**|

Headline: the canonical architecture doc is **substantially accurate**.
Every layer (1-12), the three hard promises, the integration spine, the
two-store model, hierarchy-scoped settings, and the accuracy seams are
represented in real code. The drifts are all *narrow factual lag*, not
structural: the doc froze a snapshot (Updated 2026-05-06) and code has
since moved on a few specific details (7shifts wage class, a 5th metric
state, a provenance string suffix, a service-period rename).

Nothing here is a contract violation by the code; the recommended
actions are doc-side corrections to keep the canonical doc honest.

---

## Summary table (claim → status → evidence → action)

| # | Doc claim (line) | Status | Code evidence (file:line) | Recommended action |
|---|---|---|---|---|
| 1 | Three canonical fact shapes: `ShiftRecord`, `OpenShiftSnapshot`, `ReservationBookSnapshot` (L171-173, 251-253) | ALIGNED | `lib/models/shift_record.dart:7`; `lib/domain/models/open_shift_snapshot.dart:7`; `lib/domain/models/reservation_book_snapshot.dart:8` | None |
| 2 | Per-vendor canonical Postgres fact rows `cover_facts`, `labor_punches`, `reservation_facts` (L254-255) | ALIGNED | `db/migrations/202605061650_phase_8_legacy_fact_tables_postgres_create.sql:324,412,510` (`create table ... public.cover_facts/labor_punches/reservation_facts`); `shift_records` at :163 | None |
| 3 | Layer 4 wage source: 7shifts default = `perEmployeeWithRates`; "NO Wave B vendor confirmed in `perEmployeeWithDollars` today" (L289-296) | **DRIFTED** | `lib/services/integration/labor_wage_source_class.dart:89` maps `kSevenShiftsVendorId → LaborWageSourceClass.perEmployeeWithDollars` (the `/reports/hours_and_wages` upgrade was wired) | Update doc L289-296: 7shifts now resolves to `perEmployeeWithDollars`; the "no Wave B vendor confirmed" sentence is stale. Authority: code conflicts with the canonical doc; canonical doc is #2 in authority order but it documents an *outdated* state — recommend doc be corrected to match landed code. Also flag the file's own stale docstring (lines 32-36, 70-73) as a separate code-comment cleanup. |
| 4 | `ForecastDemandSource` enum values: 5 listed; "no `vendorProvidedForecast` enum value" (L327-339) | ALIGNED | `lib/domain/models/schedule_forecast_demand.dart:5-21` — exactly `appDerivedFromHistoricalAverage`, `appDerivedFromCoversAndPpa`, `appDerivedFromReservationAndWalkInModel`, `demoFallback`, `unavailable`; no vendor-provided value | None |
| 5 | Promise 3 / metric state ∈ {`live`,`partial`,`fallback`,`unavailable`} (L215) | **DRIFTED** | `lib/domain/models/metric_provenance.dart:28-58` — `enum MetricState` has a **5th value `stale`** (data previously live; vendor sync lapsed) | Update doc L215 to list 5 states `{live, partial, fallback, unavailable, stale}` (or explicitly note `stale` as an extension). Authority: canonical doc is incomplete vs code; recommend doc add `stale`. |
| 6 | Accuracy-seam provenance string `operator_manual_entry` (L482) | **DRIFTED** (minor) | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:461-462,540-541` — provenance value is `operator_manual_entry_per_daypart` / `operator_manual_entry_fallback_pos_not_exposed`; `sourceSystem` is `operator_manual_entry` | Update doc L482 to use the actual provenance strings (or clarify it lists the source-system, not the provenance). |
| 7 | Covers source per-(operator, location, service_period); legacy `daypart` labels are display aliases only (L470-472) | ALIGNED | `lib/domain/models/data_accuracy_settings.dart:219-223` — keyed `covers_source_per_service_period` jsonb is "sole source"; legacy `covers_source_lunch/_dinner/_late_night` columns "no longer" used | None (note: doc still uses the word "daypart"; product has renamed to "service period" — see #8) |
| 8 | Layer 9 / accuracy seams use "service period" terminology; doc still says "daypart" in places (L362-364, L470-471, "Legacy `daypart`") | **DRIFTED** (terminology) | Code uses `servicePeriod` / `service_period` as primary (`lib/screens/shift_dashboard.dart:302` `_servicePeriodSlivers`; `data_accuracy_settings.dart` `covers_source_per_service_period`); `daypart` retained only as legacy/display alias | The doc is internally inconsistent: Layer 9 already says "service-period" but Accuracy seams (L470) and provenance string `operator_manual_entry_per_daypart` keep "daypart". Recommend a doc pass standardizing on "service period" with "daypart" called out only as the legacy display alias. |
| 9 | `ReservationBookSnapshot` is a canonical fact shape (L173, 252) | ALIGNED (with nuance) | Model `lib/domain/models/reservation_book_snapshot.dart:8` + SQLite DAO + domain repo exist; **no Postgres `create table reservation_book_snapshots`** — Postgres canonical row is `reservation_facts` which aggregates into the snapshot (`db/migrations/...legacy_fact_tables...sql:510`). Consistent with doc L254-256 ("`reservation_facts` ... aggregate into the three shapes above") | None — by design, not drift. Optional doc clarification that `ReservationBookSnapshot` is an aggregate read-shape, Postgres truth is `reservation_facts`. |
| 10 | Layer 2: UI never reads vendor payload shape; canonical truth layer (L257-259) | ALIGNED | Vendor sinks all extend `OperatorScopedRepository` and write canonical tables (`lib/infrastructure/persistence/postgres/*_postgres_sink.dart`); UI reads via SQLite read models | None |
| 11 | Layer 4: `TargetCycle` locked 60-day; manager can override once per cycle (L267-281) | ALIGNED | `lib/domain/models/target_cycle.dart:1` ("locked 60-day standards cycle"), `:208-209` `managerOverrideUsed`/`managerOverrideAt`; `target_cycle_repository.dart:677` `TargetCycleManagerOverrideAlreadyUsed` exception enforces once-per-cycle | None |
| 12 | Layer 5: `ActiveTargetProfile` runtime projection of active cycle (L313-317) | ALIGNED | `lib/domain/models/active_target_profile.dart:104`; projector `lib/domain/services/target_cycle_active_target_profile_projector.dart:14`; notifier `lib/state/active_target_profile_notifier.dart:15` | None |
| 13 | Layer 6: demand forecast F&F-computed, never vendor-supplied (L319-343) | ALIGNED | `lib/services/demand_forecast_context_service.dart:45`; `ForecastDemandSource` enum has no vendor value (see #4) | None |
| 14 | Layer 7: `SchedulePlan` resolved from standards + demand + distribution (L345-350) | ALIGNED | `lib/domain/models/schedule_plan.dart:49`; `lib/domain/services/schedule_plan_resolver.dart:13` | None |
| 15 | Layer 8: `WeeklyPlanSnapshot` locked week-in-force, one per business week (L351-358) | ALIGNED | `lib/domain/models/weekly_plan_snapshot.dart:139`; policy `lib/domain/services/weekly_plan_snapshot_policy.dart:11` | None |
| 16 | Layer 9: Shift default = Whole Day; service-period views alongside; Whole Day rolls up from buckets (L360-370) | ALIGNED | `lib/screens/shift_dashboard.dart:275` `_wholeDaySlivers`, `:302` `_servicePeriodSlivers`, `:1775` "Unified selector for the Shift rollup and configured service periods"; `ServicePeriodAccumulator` :331 | None |
| 17 | Layers 10-12: Variance / History / Learn read seams (closed-truth, provenance) | ALIGNED | `lib/services/history_pattern_builder.dart`, `lib/services/learn_repeatable_wins_read_service.dart`, `lib/models/history_pattern_record.dart` exist; closed-truth aggregates present | None |
| 18 | Integration spine: vendor payload → canonical facts → `ClosedShiftInput` → `ShiftFactBuilder` → `ShiftFact`/`ShiftRecord` → Postgres → SQLite (L408-418) | ALIGNED | `lib/domain/models/closed_shift_input.dart`; `lib/domain/services/shift_fact_builder.dart`; `lib/domain/models/shift_fact.dart`; aggregator `lib/services/integration/canonical_fact_to_closed_shift_input.dart` | None |
| 19 | Two-store reality: Postgres canonical (RLS via `OperatorScopedRepository.withTenant`), SQLite mobile read store (L420-428) | ALIGNED | `lib/infrastructure/persistence/postgres/operator_scoped_repository.dart:6-11,34` `withTenant` + `SET LOCAL app.operator_id/location_id/user_id`; SQLite DAOs under `lib/infrastructure/persistence/sqlite/dao/` | None |
| 20 | Demo data = standard tables under `DemoScope.restaurantId = 'demo_restaurant_001'`, no `demo_*` tables (HP#2, referenced via doc demo framing) | ALIGNED | `lib/infrastructure/persistence/sqlite/sqlite_database.dart:82-85` `class DemoScope { static const restaurantId = 'demo_restaurant_001'; }`; defaults reused in `closed_shift_input.dart:82`, `shift_fact.dart:87` | None |
| 21 | Hierarchy-scoped settings resolve business→org-unit→location, lowest configured wins (L432-454) | ALIGNED | `data_accuracy_settings.dart` carries per-(operator, location) + per-service-period scope keys; vendor connections location-bound (matches L450-454 integration exception) | None |
| 22 | Accuracy seams: 3 sanctioned (wage source, covers source, polling tier) (L457-483) | ALIGNED | `lib/domain/models/data_accuracy_settings.dart:22` `enum CoversSource {vendor, forecast, manual}`; `:58` `enum WageSource {vendor, manualMix}`; `:17` polling tier via `forge_flow_polling_tier_assignment` | None |
| 23 | Provenance contract: `DaypartPatternSummary` is an aggregate from closed facts, not a single business-date fact (L551-552) | ALIGNED | `lib/models/daypart_pattern_summary.dart`; builder `lib/services/daypart_pattern_summary_builder.dart` | None |
| 24 | Promise 1: vendor payload normalized; later integrations replace transport only (L163-175) | ALIGNED | Per-vendor `*_postgres_sink.dart` all write the same canonical tables; UI path unchanged | None |
| 25 | Promise 2: locked truth (closed shifts / weekly snapshot / cycle-week provenance) never rewritten; re-aggregation preserves original `target_profile_version_id` (L176-198) | ALIGNED | `postgres_shift_record_writer.dart:30` preserves `operator_manual_entry` provenance; `target_snapshot.dart` carries locked snapshot; manager-override-once enforced (#11). (Spine-level Concern A enforcement is in scope of the integration spine contract, not this doc's Phase 1 surface.) | None |
| 26 | Promise 3 narrative: live/closed/projected/fallback distinguishable; renderer switches on state; `unavailable` → `MetricCardNotYetAvailable` (L200-227) | ALIGNED (see #5 for the enum-count drift) | `metric_provenance.dart:12-13` ("normal `MetricCardWidget` ... or `MetricCardNotYetAvailable`"); state-driven render confirmed | Covered by #5 |

---

## Per-section detail

### Why-this-doc / North-Star pipeline / Big Idea (L30-159)
Narrative and the mermaid flowchart. No falsifiable code claim; the
five-stage shape (Source / Standards / Plan / Operate / Learn) is
faithfully realized by the layer classes audited below. **ALIGNED**
(framing only).

### The Three Hard Promises (L161-227)
- Promise 1 (#24), Promise 2 (#25): **ALIGNED**.
- Promise 3 (#26): narrative **ALIGNED**, but the explicit state set
  `{live, partial, fallback, unavailable}` at L215 is **DRIFTED** — code
  carries a 5th `stale` state (#5). The doc's L221-226 service-period
  bucketing rule ("Live service-period rows are not UI slices of an
  already-rounded whole-day row ... Whole Day is then a rollup") is
  **ALIGNED** with `shift_dashboard.dart` rollup/selector code (#16).

### Layer Contract L1-12 (L230-405)
- Layer 1 (source ownership): narrative, no class to falsify. ALIGNED.
- Layer 2: **ALIGNED** (#1, #2, #10).
- Layer 3 (60-day benchmark from closed truth): benchmark read services
  exist (`history_benchmark_daypart_read_service.dart`); closed-only
  input is the documented design. ALIGNED.
- Layer 4: **DRIFTED** on the 7shifts wage-class detail (#3). The
  four-class enum itself and the manual-mix override are **ALIGNED**
  (`labor_wage_source_class.dart:37-56`; `WageSource.manualMix`).
- Layers 5-8: **ALIGNED** (#12-#15).
- Layer 9: **ALIGNED** (#16); terminology drift tracked in #8.
- Layers 10-12: **ALIGNED** (#17).

### Integration spine (L408-430)
**ALIGNED** (#18, #19). Builder chain and two-store model present and
named exactly as the doc states.

### Hierarchy-scoped settings (L432-454)
**ALIGNED** (#21). The integration location-bound exception (L450-454)
matches the vendor-connection scoping in code/contract.

### Accuracy seams (L457-483)
Three seams **ALIGNED** (#22, #7). Two doc-side issues:
- Provenance string `operator_manual_entry` at L482 lags the actual
  `operator_manual_entry_per_daypart` value (#6).
- "daypart" terminology vs code's "service period" (#8).

### Ownership / separation / provenance / cadence / never-rewrites (L487-580)
Tables restate the layer contract. No new falsifiable claims beyond
those already covered. `DaypartPatternSummary` aggregate claim
**ALIGNED** (#23). Cadence and never-rewrites tables are consistent with
the locked-cycle / locked-weekly-snapshot code already verified.

### One-Sentence Contract / Cross-references / Appendices (L582-661)
Restatement and pointers. Appendices A/B are verbatim-preservation
pointers to source contracts (out of Phase 1 code-vs-doc scope; they are
doc-vs-doc). ALIGNED as pointers.

---

## Top 5 drifts (recommended doc corrections, ranked)

1. **#3 — 7shifts wage class** (L289-296): doc says 7shifts =
   `perEmployeeWithRates` and "no Wave B vendor confirmed in
   `perEmployeeWithDollars`"; code maps 7shifts → `perEmployeeWithDollars`
   (`labor_wage_source_class.dart:89`). The `/reports/hours_and_wages`
   upgrade landed; doc + the file's own docstring are both stale.
2. **#5 — metric state count** (L215): doc lists 4 states; code's
   `MetricState` enum has 5 (`stale` added,
   `metric_provenance.dart:51-58`). Promise 3 wording understates the
   model.
3. **#8 — daypart vs service period terminology**: doc is internally
   inconsistent (Layer 9 says "service period"; Accuracy seams + a
   provenance string still say "daypart"). Recommend one standardizing
   pass with "daypart" flagged only as the legacy display alias.
4. **#6 — provenance string** (L482): doc cites bare
   `operator_manual_entry`; actual provenance values are
   `operator_manual_entry_per_daypart` /
   `operator_manual_entry_fallback_pos_not_exposed`
   (`canonical_fact_to_closed_shift_input.dart:461,540`).
5. *(No 5th true drift.)* Honorable mention — #9: clarify in the doc
   that `ReservationBookSnapshot` is an aggregate read-shape and the
   Postgres canonical row is `reservation_facts` (currently ALIGNED but
   easy to misread as a missing table).

## Notes on authority resolution

For every DRIFTED row the conflict is between the canonical doc (#2 in
authority order) and *landed code*. The doc outranks phase docs and
CLAUDE.md, but in each case here the doc documents an **outdated**
state while the code reflects an intentionally-landed later change
(7shifts upgrade lane, `stale` state addition, per-daypart provenance
suffix, service-period rename). Recommended resolution is **doc-side
correction to match code** — not code rollback. No code or contract
edits were made in this audit (audit-only contract).
