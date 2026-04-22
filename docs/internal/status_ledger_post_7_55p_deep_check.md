# Status Ledger - Post-7.55p Deep Check

Updated: 2026-04-15
Owner: Codex
Purpose: durable status reference for the user's long-running "did we actually do this?" checklist.

This ledger is a repo-grounded reference note, not a new planning authority.
Use `PROJECT_TRACKER.md` and `docs/DATA_ALIGNMENT_TRACKER.md` for sequencing.

## Sources Checked

- `PROJECT_TRACKER.md`
- `docs/archive/phases/7_55p/phase_7_55p_2_variance_wtd_full_week_alignment.md`
- `docs/archive/phases/7_55p/phase_7_55p_3_dollar_impact_accumulation_model.md`
- `docs/archive/phases/7_55p/phase_7_55p_4d_notifications.md`
- `docs/archive/phases/7_55p/phase_7_55p_5_benchmark_opz_graph_honesty_audit.md`
- `docs/archive/phases/7_55p/phase_7_55p_5c_target_labor_package_contract.md`
- `docs/archive/phases/7_55p/phase_7_55p_5d_variance_theoretical_package_wiring.md`
- `docs/archive/phases/7_55p/phase_7_55p_5e_blended_wage_refinement_testing.md`
- `docs/phases/7_55q/phase_7_55q_1_architecture_conformance_contract_and_drift_codification.md`
- `docs/archive/phases/7_55i/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md`
- `docs/archive/phases/7_55j/phase_7_55j_1_codebase_feature_inventory.md`
- `lib/screens/variance_report.dart`
- `lib/services/variance_week_projection_read_service.dart`
- `lib/models/week_data.dart`
- `lib/models/shift_record.dart`

## Architecture Override

As of `7.55q.1`, this ledger no longer treats any of the following as
acceptable or "close enough" runtime truth:

- a second competing current-week live plan authority
- per-surface benchmark target recomputation
- mixed benchmark/plan authorities on non-closed Variance rows
- History week targets re-modeled from actuals
- fake blended-wage math

If an older note in this ledger implied one of those was acceptable, it is now
killed from the active interpretation and superseded by the conformance rules
in `docs/phases/7_55q/phase_7_55q_1_architecture_conformance_contract_and_drift_codification.md`.

## A. After 7.55p.2

### Variance WTD / Full Week Requests

#### Done

| Request | Notes |
|---|---|
| WTD FOH/BOH target hours should match the plan | WTD target hours now read locked plan-to-date hours only. Honest degradation applies when locked hours are unavailable. |
| Remove collapsed `cvr` label | Collapsed Full Week rows no longer show `cvr`. |
| Remove `1 closed / 1 open / 1 projected` collapsed text | Status chips/icons remain; summary text was removed from collapsed day rows. |
| Change Full Week expanded row label to just `Period - Closed/Open/Projected` | Expanded Full Week daypart detail labels now show just the period plus row state, without repeating day names or cover counts in the badge. |
| Carry forward primary lever from last closed daypart | `VarianceWeekProjectionReadService` carries the last closed lever by daypart. |
| Blended wage row matches the shared benchmark target object | Non-closed Variance rows now read the shared benchmark target seam for blended wage; closed rows stay locked closed truth. |
| FOH/BOH non-closed target rows align with the locked weekly plan / shared benchmark objects | Non-closed Variance rows now read plan-owned volume metrics and benchmark-owned rate metrics 1:1. |

#### Killed

| Request | Notes |
|---|---|
| Older "mixed but intentional" target-package interpretation | Superseded by the `7.55q` architecture-conformance lane. The app no longer treats per-surface recomputation or mixed live-plan / benchmark ownership as acceptable. |

#### Still Open

| Request | Notes |
|---|---|
| Full capitalization consistency audit like `Target` | Local cleanup landed in Variance / Plan / Benchmark, but no repo-wide naming/copy audit has happened yet. This belongs with the later `7.55o.6` polish lane. |

### Current Architecture Read

The old transition wording is no longer the right frame here. `7.55q` is
landed through `7.55q.9`, so the active interpretation is now simply:

- one locked weekly plan object decides the in-force week
- one shared benchmark target object owns non-volume target standards
- non-closed Variance rows read those two objects 1:1
- closed Full Week rows stay locked closed-truth comparisons

## B. After 7.55p.3

| Request | Status | Notes |
|---|---|---|
| Hide `covers WTD` and `run rate` | Done | Dollar Impact card no longer shows them. |
| Reframe as accumulation through latest closed day | Done | Card now shows accumulation through the latest closed business date. |
| Week / month / 60-day / annualized views | Done | All four windows landed. |

### Clarifier

Week, month, and 60-day are separate accumulation windows. Annualized is
derived from the 60-day window. They are not literally one tally feeding
the next, except for annualized.

## C. After 7.55p.4d

| Request | Status | Notes |
|---|---|---|
| Persist passive notifications for new week / 60-day rollover | Done | Landed in `7.55p.4d1`. |
| App-side freshness protection so stale data does not masquerade as live | Mostly done | Resume refresh, boundary invalidation, import/write propagation, freshness UI, and passive notifications are in place. |
| Audit true live freshness end to end with real connectors | Open | Real vendor/webhook/poll latency, timestamp truth, and degraded-state behavior still need connector-backed verification. |

### Practical Meaning

The app-side freshness rails are mostly in place. The remaining freshness
risk is in real vendor integration behavior, not basic in-app policy.

## D. After 7.55p.5

| Request | Status | Notes |
|---|---|---|
| Benchmark range should be tighter | Research says no | `7.55p.5b` concluded the visible width is honest selected-range truth; the remaining problem is the recommended selector. |
| Shift `20.3%` vs Benchmark `20.5%` mismatch | Closed under `7.55q.7` | Shift whole-day target labor now reads `profile.theoreticalLaborPct` 1:1. Any visible gap on Shift is actual-vs-target variance or later `10.5` scope, not target-source drift. |
| Benchmark should show FOH / BOH breakdown under theoretical output | Done | Benchmark now shows FOH / BOH / total theoretical %. |
| Benchmark theoretical package should feed to Variance | Done through `7.55q.4` | Non-closed WTD / Full Week rows now read the current benchmark target object 1:1; closed Full Week rows stay locked historical truth. |
| Blended wage needs refinement and testing | Done through `7.55q.3` / `7.55q.5` / `7.55q.7` | Benchmark and WTD share the active-profile seam, History uses weighted preserved locked hours, and Shift whole-day now reads the same benchmark seam for target blended wage. Closed/open exceptions keep their documented contracts. |
| Planned labor % by day | Killed in `7.55q.6` | Planned labor package is dead. Schedule day-level labor % was removed rather than backfilled with fake same-scope theoretical values. |
| Planned labor % by daypart | Killed in `7.55q.6` | Same rule: no live planned-labor concept remains, and daypart labor % was removed rather than invented from whole-week theoretical truth. |
| Planned labor % for Full Week projection | Killed in `7.55q.6` | There is no live planned-labor contract anymore. Surviving labor-target displays are theoretical-only. |

### Important Clarifier

`7.55p.5` cleaned up:

- Benchmark/Shift theoretical vs planned ownership
- Variance theoretical-package ownership
- blended-wage formula consistency

That earlier planned-labor lane is now superseded. `7.55q.6` killed the
planned labor package completely:

- no live "planned labor %" concept remains
- surviving labor-target displays are theoretical-only
- Schedule day/daypart labor % columns were removed instead of replaced with
  fake same-scope theoretical values

What remains open is the later Learn compatibility cleanup, the `10.5`
live service-period/daypart-aware Shift lane, and the `7.55o.*`
refactor/polish work. The core q-lane cleanup for one locked weekly
plan, one shared benchmark target object, preserved History truth, and
no planned-labor concept is now landed.

## E. After 7.55o.6

### Done In The Current UX Shell Pass

- app shell header unification landed:
  - shared `AppScreenHeader`
  - fixed-height sticky headers across Shift / Variance / Plan / Benchmark
  - dedicated header action pills for Settings + Notifications
  - shared gradient / bottom-slot language
  - fade-on-scroll shell behavior
- Shift header/live-time polish landed:
  - restaurant-name title
  - live business date + service period line
  - live clock + freshness chip
  - overflow fix for narrow layouts
  - FOH Productivity CPLH formatting cleanup
  - stronger sales-progress bar readability
- Variance / History shell cleanup landed:
  - Dollar Impact section labeling
  - PROJ TOTAL row label spacing cleanup
  - collapsed day-row cover clutter removed
  - History week tile simplification
  - `Most Common Leak` subtitle cleanup
  - redundant History supporting rows removed
- Learn tab visual rebuild landed:
  - hero strip
  - chapter rail
  - swipeable carousel
  - card-sequenced leak/wins coaching structure
  - `Coach Next Week` footer kept below the carousel
- Plan shell cleanup landed:
  - `Weekly Operating Plan` header treatment
  - `NEXT WEEK PROJECTIONS` header pills
  - `LABOR PLAN` rename
  - section-label styling aligned with Variance
  - top forecast card row removed
  - chart legend moved out of the bar field
- Benchmark shell cleanup landed:
  - `60 Day Benchmark` header treatment
  - total-covers count moved to a header pill
  - inline summary cards removed
  - `CPLH RANGE & TARGET` extracted to a shared section-label pattern
- Settings visual rework landed:
  - restaurant hero card
  - unified section headers
  - Data Status / Mock Replay card polish
  - action-tile treatment
  - wage-mix redesign
  - pinned save bar in the editor
  - footer cleanup
- cross-cutting card language / accent-stripe / gradient-shell uplift landed across
  Settings, Plan, Benchmark, Dollar Impact, and Learn

### Still Open

- full naming consistency audit across every screen
- full extra-language / copy-shedding pass across every screen
- workflow automation / AI introduction pass
- deeper refactor / decoupling review beyond the landed shell pass

The broad shell/header/polish pass is no longer open. What remains is the
cleanup/audit work that goes beyond the already-landed visual and layout pass.

## F. After 7.55j.4 / Pre-Phase-8 Readiness Check

| Question | Status | Notes |
|---|---|---|
| Is all demo data gone? | No | Bridge/demo/runtime compatibility seams still exist. |
| Is the SQL-backed simulation stronger than before? | Yes | Replay- and SQLite-backed proofs are much stronger now. |
| Are we truly integration-ready with simple swaps? | No | Tracker explicitly says not to describe the current state that way. |
| Is the architecture direction broadly aligned with the daypart checkpoint? | Yes | App-owned service-period mapping + whole-day Shift until `10.5` remains the direction. |
| Is History a literal 1:1 trickle from This Week, and Learn a literal 1:1 trickle from History? | No, but directionally yes | Same architecture spine, but not a literal UI-to-UI trickle. History materializes closed truth; Learn studies closed truth plus benchmark context. |

### Learn Migration Clarifier

Learn is still partially migrated:

- Repeatable Wins is evidence-backed
- Benchmark Set / Recurring Leak / Coach Next Week still use compatibility seams

### History Clarifier

History conformance landed in `7.55q.5`:

- week target hours now preserve locked week truth instead of being re-modeled from actuals
- week detail now shows hour-weighted blended wage instead of a simple average
- legacy rows without preserved plan hours degrade honestly with `—`

## G. After 10.5

These items are still future work owned by `10.5`:

- full driver-scenario matrix for testing
- highlight behavior for positive cases
- whether green highlight states should appear
- final primary-driver linkage and teaching behavior
- live service-period/daypart-aware Shift behavior

## H. Meridian / Demo / Bridge Usage Still In The Repo

Representative remaining bridge/demo usage:

| Area | Current bridge/demo usage |
|---|---|
| Historical actual labor fallback | `ShiftRecord` now degrades missing labor dollars to `0` instead of reconstructing `MeridianConfig` wage truth; downstream evidence surfaces still need to avoid treating that fallback as real vendor labor evidence. |
| Historical week defaults | `WeekRecord` now degrades missing stored blended-wage truth honestly instead of reconstructing `MeridianConfig` wage defaults. |
| Benchmark / manager override bridge | `BaselineData` and `MeridianConfig` still support parts of the Benchmark/override path. |
| Schedule fallback | `schedule_builder.dart` still has profile-not-loaded fallback reads. |
| Static/test compatibility source | `shift_data_source.dart` still uses `BaselineData` / `MeridianConfig` in compatibility paths. |
| Current-state replay simulation | `open_shift_snapshots` and `reservation_book_snapshots` are still replay-seeded in the demo/runtime simulation path. |

Use `docs/archive/phases/7_55j/phase_7_55j_1_codebase_feature_inventory.md` as the
most complete inventory of these seams.

## I. Plain-English Algorithm Request

| Request | Status | Notes |
|---|---|---|
| "Can we have an English version of the smart algos?" | Partial | Plain-English architecture docs exist, but there is not yet one unified plain-English explainer pack for derivations, benchmark setting, and recommendation logic. |

## J. Currently Unowned Gaps

These items are still open, but they do not currently have an explicit owner
in the active queued lanes (`7.55q`, `7.55o`, `7.55j.3`, `7.55j.4`, `10.5`,
Phase 8, or Phase 9). Keep them visible here until they are assigned.

| Gap | Current status | Representative evidence |
|---|---|---|
| Full timezone conversion for business-date / timing boundaries | Open and unowned; read-only Timing Authority is visible in Settings, but editable timezone authority is still deferred | `phase_7_55n_10_boundary_invalidation_refresh.md`, `phase_7_55n_12_vendor_live_data_capability_audit.md`, `phase_7_55n_13_proof_blocker_cleanup.md`, `shift_boundary_resolver.dart`, `settings_screen.dart` |
| Non-locked WTD path still uses `weekId`-based membership | Open and unowned | `shift_service.dart` top-of-file note; `phase_7_55n_4_week_start_wiring.md`; `phase_7_55n_5_service_period_close_vs_shift_finalization.md` |
| Learn partial-migration cleanup for `Benchmark Set` / `Recurring Leak` / `Coach Next Week` | Open and unowned | this ledger Sections F and G; `phase_7_55q_1_architecture_conformance_contract_and_drift_codification.md` |
| Dev-only audit panel still reads repositories directly | Open and unowned | `lib/widgets/data_alignment_audit_panel.dart` still reads `SqliteRestaurantScopeRepository` and `SqliteTargetProfileRepository` directly; wrap with a thin read service when assigned |
| Persisted timing / service-period wiring closeout | Partial and unowned | `settings_screen.dart` now shows a read-only Timing Authority summary, but editable timing controls are still missing and some callers still rely on `ServicePeriodDefinitionResolver.demoDefinitions` |
| UTC metadata timestamp normalization sweep | Partial and unowned | `UtcMetadataTimestamp.nowIsoUtc()` is adopted in some services; raw `DateTime.now().toUtc().toIso8601String()` still appears in `WageStandardContextService`, `ShiftDashboardNotifier`, `AppDataStatusService`, and related DAO/service paths |
| Audit panel cycle/week provenance columns | Open and unowned | `phase_7_55j_1_codebase_feature_inventory.md` notes the audit surface still does not expose cycle/week columns |
| Historical actual fallback cleanup for wages/labor dollars when stored values are absent | Open and unowned | `phase_7_55p_5f1_wage_mix_setup_ux_and_authority_verification.md`; `ShiftRecord` / `WeekRecord` fallback debt also noted in Section H |
| Wage-mix role templates / quick-setup presets | Open and unowned | `phase_7_55p_5f1_wage_mix_setup_ux_and_authority_verification.md` |
| One unified plain-English derivations / benchmark / recommendation explainer | Open and unowned | this ledger Section I |
| Live-doc cleanup for stale or superseded notes | Open and unowned | `docs/README.md` is cleaner now; remaining debt is stale post-fix notes and tracker/phase wording drift in some live docs |

## K. What To Revisit Later

Revisit this ledger:

1. before or during the resumed `7.55o.*` naming/polish/settings lane after `7.55q.1` through `7.55q.9`
2. before `7.55j.4` / the pre-Phase-8 readiness answer
3. when deciding whether to create a plain-English derivations explainer
4. when assigning owners to the unowned gaps in Section J
