# Full Operational Demo-Data Spec — Forge & Flow

**Status:** Spec / research output. No production code changed by this document.
**Created:** 2026-05-15
**Owner:** Operator (Vanessa). Output of the "demo build is the whole-app test surface" directive.
**Authority position:** Below `CLAUDE.md` → Demo Mode, `docs/contracts/demo_mode_contract.md`, and `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`. Above the worker slice prompts this spec emits.

---

## 0. Problem statement & baseline reality

The operator runs the demo build (`--dart-define=kDemoMode=true`) as the acceptance surface for the entire app. The demand: demo data must exercise **every surface, true to the app's real logic** — "nothing not covered."

The current seed is degenerate in ways that hide app behavior behind a passing walkthrough:

1. **Single restaurant, single location, no hierarchy.** `_seedDemoRestaurant` (`lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:649-665`) inserts exactly one `restaurant_locations` row (`DemoScope.restaurantId = 'demo_restaurant_001'`, `displayName = 'Barrio Legado'`, tz `America/St_Johns`, defined `lib/infrastructure/persistence/sqlite/sqlite_database.dart:39-43`). No `org_units`, no business→region→district→location tree, no second location. Every HP #11 scope/inherited/effective surface renders trivially or empty.
2. **Primary driver never varies ("all covers covers covers").** The operator observed History showing `covers` on every row. Root cause: `MockIntegrationReplaySeed._generateShift` (`lib/dev/mock_integration_replay_seed.dart:317-483`) scales sales-side actuals (covers, PPA) but holds wages at target and CPLH at a single `_weekCPLHScales` band, so `LaborModel.determineLever` (`lib/services/labor_model.dart:99-202`) almost always returns the `covers_*` axis or the empty-candidate fallback `'covers_down'` (`labor_model.dart:187`). The 16-lever catalog (`LeverCards.all`, `lib/domain/constants/app_defaults.dart:434-451`) is real and threshold-driven; the seed simply never moves the other axes past their thresholds.
3. **Per-period targets identical across periods.** Tracked separately by the per-daypart V1 plan. Slice 1 (the `target_cycle_dayparts` data layer) has merged (`target_cycle_dao.dart:33-63`, `sqlite_database_migrations.dart:325-342`); the in-flight "per-period cycle rows" fix worker (branch `claude/per-daypart-fix-demo-seed-per-period-cycle`) makes the seed cycle's `dayparts` differentiated. This spec sequences **after** that lands.
4. **Vendor integration demo state is invisible.** No `demo_mode_state` rows seeded per (operator, location, category); the Integrations surface and `DemoModeBanner` have nothing to render. `IntegrationCategory` = `{ pos, labor, reservation }` (`lib/services/integration/integration_adapter_common.dart:15`); `ConnectionStatus` = `{ connected, disconnected, error }` (`:218`).
5. **History/Variance flatness.** `_weekCoverScales` / `_weekPPAShifts` / `_weekCPLHScales` (`mock_integration_replay_seed.dart:168-176`) are 8-element bands — only ~8 historical weeks, low amplitude, and no period-resolution variance, so History grades and Variance deltas look synthetic.

This spec defines the demo data shape that makes every surface fully operational **and correct-looking**, the gap table against current seed code, the demo-contract compliance proof, and a chunked implementation plan.

---

## 1. Surface inventory × data requirements

Legend: **Shape** = the demo rows/values required; **True-to-logic** = what makes it correct, not merely non-empty.

### 1.1 Mobile — Shift dashboard

| Surface | Shape required | True-to-logic |
|---|---|---|
| Shift whole-day card (Outputs / Inputs / FOH Productivity) | One open shift snapshot for the current scenario day+daypart (`_seedOpenShiftSnapshotsFromReplay`); whole-day rollup of the day's period buckets | Whole-day numbers must equal the cover-weighted rollup of the period rows (Layer 9 / Promise 3). The open shift's `primaryLever` must reflect a non-trivial driver in some scenario days (not always `covers_down`). |
| Shift per-daypart cards (lunch / dinner / late_night) — Slice 4 full-parity card | Per-period `shift_records` rows for the open day; per-period `target_cycle_dayparts` rows; per-period `weekly_plan_snapshot_day_dayparts` rows for scheduled/needed/excess | Each period card reads ITS period's target + plan row. lunch ≠ dinner ≠ late_night targets (CPLH 4.40 / 4.80 / 3.90 etc., `mock_integration_replay_seed.dart:80-104`). At least one period in the demo week should show a different primary driver than the others (e.g. dinner `ppa_up`, late_night `cplh_down`). |
| Primary Driver chip | `shift_records.primary_lever` populated via `LaborModel.determineLever` round-trip (already wired) | Across the 60+ closed days, the distribution of drivers must span ≥6 of the 16 levers (see §2a). The chip must never be a hand-coded constant. |
| App data status badge | Open shift snapshot present → carve-out #2 renders `DEMO` | Label-only; freshness math identical. No new branch. |

### 1.2 Mobile — Variance tab

| Surface | Shape | True-to-logic |
|---|---|---|
| Variance "This Week" / WTD vs Plan (1st table) | Current-week `shift_records` (closed days closed, future days projected); locked `weekly_plan_snapshots` + `weekly_plan_snapshot_day_dayparts` | WTD compare uses period-tagged actuals vs period-accurate targets rolled to the day (Decision 6). Deltas must be non-zero and vary by day. |
| Variance History (per-week list) | 60+ days = ≥9 full `week_records` rows with realistic week-to-week variance | Each week graded against the cycle in force; `dollarGap`, `monthDollarImpact`, `sixtyDayDollarImpact` populated (`_deriveWeekRecord`, `mock_integration_replay_seed.dart:496-614`). Variance must show real deltas, not a flat line. |
| Variance Full Week Projection (2nd table) | Non-closed daypart rows | Per-period theoretical % from per-period profile rows (Slice 5); wages whole-day. Projected rows must differ per period. |
| Variance Learn tab | History summary with detectable repeating patterns at period resolution | Gap 39: narration must be able to say "Friday dinner: covers down" — requires per-period leak frequency. The seed must produce a *recurring* per-(day, period) leak (e.g. Friday dinner consistently PPA-down) so `LearnTeachingAnalyzer` (`lib/services/learn_teaching_analyzer.dart:42-125`) has a real pattern to surface, plus at least one benchmark (favorable) pattern. |

### 1.3 Mobile — Plan tab

| Surface | Shape | True-to-logic |
|---|---|---|
| Weekly Operating Plan — day rows | Locked `weekly_plan_snapshots` for current week (`_seedWeeklyPlanSnapshotFromReplay`) | Day rows: Day · Covers · Sales · FOH Hrs · BOH Hrs (Decision 5). Demand-derived, locked values, not regenerated on render. |
| Plan — expanded per-daypart sub-rows | `weekly_plan_snapshot_day_dayparts` rows per (date, period) | Sub-rows render persisted locked values (Slice 3), not `DaypartPlanAllocator` regeneration. Sub-row covers/sales/hours must sum to the day row. lunch/dinner/late_night differ. |

### 1.4 Mobile — Benchmark tab

| Surface | Shape | True-to-logic |
|---|---|---|
| CPLH Range & Target widget | Active `target_cycles` row (pooled scalars) | Pooled CPLH = cover-weighted Σ(period CPLH). Pool-consistency must hold by construction. |
| Daypart Breakdown table (Slice 2) | `target_cycle_dayparts` rows + Whole Day rollup row | Columns: Daypart · Avg Covers · Target CPLH · Target SPLH · Target PPA · OPZ Range. Period rows differ; Whole Day row = the widget's pooled value 1:1. |
| Operating Wage Mix + Theoretical %: The Floor strip (Slice 2) | `target_cycles.foh_wage/boh_wage`; theoretical % from pool | Wages whole-day (Decision 11). FOH wage 16.50 / BOH 21.35 (`mock_integration_replay_seed.dart:122-124`) — but should be derived from seeded `wage_role_rows` so the wage waterfall is exercised (see §2 wage authority). |
| Baseline Manager — candidate cohort + star-shift selector | ≥60 days of closed `shift_records` grouped by daypart; `selected_star_shift_decisions` empty initially (operator picks) | Day-detail screen groups by daypart with sticky headers. The candidate cohort must be rich enough that picking stars in one period visibly moves that period's target and the pooled rollup (override cascade, plan §"CPLH override authority cascade"). At least one period must have enough variance that star selection changes the recommendation meaningfully. |
| Baseline Manager preview (draft → confirm) | Preview math per-period (Gap 40) | Preview shows per-period numbers consistent with post-write cycle shape. |

### 1.5 Mobile — Settings

| Surface | Shape | True-to-logic |
|---|---|---|
| Settings → Setup (Covers / Timing / Wage authority) | `restaurant_timing_configs` row with 3+ service periods + `service_period_definitions_json`; `data_accuracy_service_period_settings` keyed rows; `wage_role_rows` for FOH/BOH blend | Timing config already seeded (`_seedDemoTimingConfig`, `sqlite_database_seed.dart:667-714`) with lunch/dinner/late_night incl. `applicable_days`, `rolls_past_midnight` for late_night. Covers-source + manual-covers must have a keyed row per configured period (Gap 27/36). Wage rows must drive the blended wage shown in Benchmark (not the `MeridianConfig` fallback). |
| Settings → Integrations (mobile fold) | `demo_mode_state` rows per (operator, location, category) | At least one connected (POS) and one error/needs-reauth (reservation) state per location so the fold renders meaningful state. Master Demo→Live switch (carve-out #4) reads `hasDemoCategories`. |
| Settings → Data (Data reset / Demo date — carve-out #3) | `mock_replay_state` row (already seeded `sqlite_database.dart:115-118`) | Demo-date advance must regenerate coherent data for any date (already supported via `generateForDate`). |
| Settings → Account / MFA / Active Sessions | Authenticated demo operator session | These render identically in demo/prod. Active Sessions should show ≥1 session; MFA factors optionally seeded for a fuller walkthrough. |
| Settings → Data freshness / Wage authority / Team / Permissions / FF Support | Same reads as prod | HP #11: scope chip / inherited-from / effective value must render — requires the org hierarchy from §2c. Today these are trivial because there is one location. |

### 1.6 Mobile — Locations / scope drawer & Notifications

| Surface | Shape | True-to-logic |
|---|---|---|
| Location / scope drawer | Multiple `restaurant_locations` rows + `BusinessScope` list (`RestaurantScopeNotifier`, `lib/state/restaurant_scope_notifier.dart:26-56`) | `availableScopes` must contain >1 location so the drawer is a real switcher. `activeLocationId` resolves to the selected location; each location must have its own seeded operational data so switching changes the dashboard. |
| Notifications | Seeded notification/alert rows (if a notifications table exists) or derived alerts from variance breaches | At least one location with a variance breach so the notifications surface is non-empty and true to the alert logic. |

### 1.7 Operator-Web console (HP #11 scope/inherited/effective)

The web console uses in-memory demo gateways (`demo_*` gateway impls, allowed per contract §"Acceptable patterns"). Demo hierarchy fixture lives in `lib/operator_web/services/demo_team_fixtures.dart` — currently "Demo Bistro": corp → East Region (Downtown, North Loop) → West Region (Riverside), 2 org units, 3 locations. This is richer than the mobile SQLite seed.

| Surface | Shape | True-to-logic |
|---|---|---|
| Hierarchy screen / org-unit tree | Corp → ≥2 regions → ≥1 district → ≥3 locations | Tree depth ≥3 so inheritance is demonstrable. Must align with the mobile SQLite hierarchy (§2c) so the two consoles tell the same story. |
| Business setup / Locations | Each location bound to an org unit | Location→org-unit binding editable (location-bound integrations, HP #11). |
| Roles | Seeded role catalog + ≥1 custom role holder | Every non-admin seeded role + one custom role (already in fixture). |
| Wage authority | Business-default + ≥1 location override | Currently hardcoded to `HierarchyScopeLevel.location` (Gap 32). Demo should show an effective-value-with-inherited-source render at ≥2 scope levels. |
| Data accuracy | Per-period covers source + scope notice | Gap 29: no `HierarchyScopeNotice` today. Demo data should be shaped so that once the notice lands, inheritance is visible (operator default + 1 location override). |
| Vendor integrations | Per-location vendor connections with mixed states | ≥1 connected, ≥1 needs-reauth/error, ≥1 disconnected across locations. |
| Audit log | ~50 entries across 30 days (in fixture) | Hierarchy-scoped filter must return different sets per scope node. |

---

## 2. True-to-logic requirements (explicit)

### 2a. Primary driver MUST vary across shifts/dayparts

**The 16-lever catalog** (`LeverCards.all`, `app_defaults.dart:434-451`): `covers_down/up`, `ppa_down/up`, `cplh_down/up`, `splh_down/up`, `foh_wage_down/up`, `boh_wage_down/up`, `foh_hours_over/under`, `boh_hours_over/under`. Selection is **largest-absolute-deviation-wins** with thresholds (covers ±2%, cplh/splh ±5%, ppa/wage ±3%, hours-flex ±10%) and tie-break priority covers > ppa > cplh > splh > foh_wage > boh_wage (`labor_model.dart:88-91, 121-202`). Empty-candidate fallback = `'covers_down'` (`:187`).

**Why the demo is degenerate:** the seed scales only covers + PPA on the sales side, holds wages at target (wage axes never fire), and applies one CPLH band per week (CPLH axis rarely crosses ±5%). Result: covers/ppa dominate, and many shifts hit the empty fallback `covers_down`.

**Required distribution** (deterministic, no RNG — vary by week×day×daypart indices). Across the 60+ closed days × 3 periods (~155+ closed rows), the seeded driver mix must span at least these, each appearing on multiple distinct (day, period) cells so History/Learn can detect recurrence:

| Lever | How to induce in seed | Target share |
|---|---|---|
| `covers_down` / `covers_up` | actual vs forecast covers delta (already present) | ~25% |
| `ppa_down` / `ppa_up` | per-period PPA jitter past ±3% (extend `_daypartPPAOffset` + a per-week PPA band) | ~20% |
| `cplh_down` / `cplh_up` | actual CPLH band ±>5% on some weeks/periods (widen `_weekCPLHScales` amplitude + per-period CPLH jitter) | ~18% |
| `splh_down` / `splh_up` | scale BOH hours independently so SPLH crosses ±5% (new per-period BOH-hours jitter) | ~12% |
| `foh_wage_up` / `foh_wage_down` | seed `wage_role_rows` with blended FOH wage ≠ target on some periods (>±3%) | ~10% |
| `boh_wage_up` / `boh_wage_down` | same for BOH | ~7% |
| `foh_hours_over/under`, `boh_hours_over/under` | seed scheduled hours ≠ model hours by >±10% on a subset | ~8% |

Constraint: variation stays deterministic and operationally plausible (no impossible covers/PPA). The recurring per-(day, period) leak required by Learn (§1.2) is layered ON TOP of this distribution (e.g. Friday dinner always lands `ppa_down` so Learn can narrate it).

### 2b. Per-period targets differentiated

Already partially true via `target_cycle_dayparts` (Slice 1 merged). The seed cycle's `dayparts` list must be non-empty and differentiated: lunch CPLH 4.40 / dinner 4.80 / late_night 3.90; SPLH 165/200/150; PPA 40.50/43.00/38.50; OPZ floor/ceiling per period (`mock_integration_replay_seed.dart:80-104`). The in-flight per-period cycle worker is the dependency; this spec's reseed builds on its output. Whole-day pooled scalars on `target_cycles` must equal the cover-weighted Σ of period rows (Design Rule 4 / pool-consistency).

### 2c. Full org hierarchy — concrete demo proposal

Recommend a **1 business → 2 regions → 1 district → 4 locations** shape. Demonstrates every inheritance path without being unwieldy:

```
Barrio Hospitality Group           (corp / business root)
├── East Region                    (region)
│   ├── Barrio Legado — Downtown    (location)   ← keep DemoScope.restaurantId = 'demo_restaurant_001'
│   └── Barrio Legado — North Loop  (location, in a district)
│       └── Metro District          (district)  ← North Loop sits under this
└── West Region                     (region)
    ├── Barrio Legado — Riverside   (location)
    └── Barrio Legado — Harbour     (location)
```

- 4 `restaurant_locations` rows (mobile SQLite) + `org_units` rows aligning to the operator-web fixture so both consoles agree.
- **HP #11 override examples, one per scope level:**
  - Business scope: default FOH/BOH wage set at Barrio Hospitality Group.
  - Region scope: East Region overrides timing (different week-start or service-period set).
  - District scope: Metro District overrides a data-accuracy covers-source.
  - Location scope: Riverside overrides wages (location wins over business default); Harbour inherits unchanged so the "inherited from Business" pill is exercised.
- Each location gets its OWN seeded operational data (shifts, weeks, cycle, plan) so the scope drawer is a true switcher. Downtown stays the rich 60+-day scenario; the other three get smaller but coherent data sets (≥30 days each) so switching is meaningful without 4× the seed volume.

`DemoScope.restaurantId` stays `'demo_restaurant_001'` for Downtown (backward-compat with every existing test asserting that id). New locations get new restaurant_ids under the same operator/business.

### 2d. 60+ days of closed history with realistic variance

Replace the 8-element `_weekCoverScales` / `_weekPPAShifts` / `_weekCPLHScales` bands with ≥10–12 historical weeks (≥70–84 days) and:
- Higher amplitude week-to-week (±8–12% covers, ±$2–3 PPA, ±6–10% CPLH) so Variance shows real deltas.
- A seasonal/trend component (e.g. gentle upward covers trend + a slow week) so History grading isn't flat.
- Per-period variance (lunch flatter, dinner more volatile, late_night noisiest) so per-period History grades differ.
- Keep determinism: derive all variation from (weekIndex, dayIndex, periodIndex) — no RNG (preserve the `mock_integration_replay_seed.dart` no-randomness invariant, file header line 14).

### 2e. Learn patterns detectable at period resolution (Gap 39)

The seed must embed at least:
- One recurring **leak** at period resolution: e.g. Friday dinner lands `ppa_down` ≥6 of the last 8 Fridays → Learn narrates "Friday dinner: covers/PPA down."
- One recurring **benchmark** (favorable) pattern: e.g. Tuesday lunch consistently within OPZ with strong CPLH → "Tuesday lunch is a benchmark."
- A cross-axis pair (Gap 39 `crossAxisPairs`): e.g. Saturday late_night pairs `covers_up` + `splh_down`.
This requires the §2a driver distribution to be *deliberately recurring on specific (day, period) cells*, not just statistically spread.

### 2f. Multiple vendor types with mixed states

Seed `demo_mode_state` rows per (operator, location, category) across `{pos, labor, reservation}`:
- Downtown: POS `connected` + `is_demo=true` (first backfill not yet), labor `connected`, reservation `error` (needs reauth) — exercises the master Demo→Live switch refusal + banner.
- Riverside: POS `connected` with `is_demo=false` (simulates a location already flipped to live) so the Demo→Live one-way semantics are demonstrable.
- Harbour: all categories `disconnected` (`is_demo=true`) — clean demo state.
Plus operator-web vendor connection fixtures mirroring this (mixed connected / needs-reauth / disconnected).

### 2g. Demo-switch states

`demo_mode_state` is Postgres-side in production; in the demo build the mobile fold reads `DemoModeStateNotifier.snapshot`. Seed the demo gateway/fixture so `hasDemoCategories` is true for at least one location (switch visible) and false for one (switch shows already-live). No `kDemoMode` reader branch — this is fixture data into the existing gateway, contract §"Acceptable patterns".

---

## 3. Gap table — current seed vs required

| # | Surface affected | Current seed (file:line) | Degenerate / missing | Required delta |
|---|---|---|---|---|
| G1 | Hierarchy, scope drawer, all HP #11 web/mobile surfaces | `sqlite_database_seed.dart:649-665` `_seedDemoRestaurant` inserts ONE `restaurant_locations` row; no `org_units` | No business/region/district/location tree; one location | Seed 4 locations + org-unit tree per §2c; align with `demo_team_fixtures.dart` |
| G2 | Shift driver chip, History, Learn | `mock_integration_replay_seed.dart:317-483` scales covers/PPA only; wages = target; one CPLH band | Driver collapses to `covers_*` / fallback `covers_down` (`labor_model.dart:187`) | Per §2a: per-period wage rows, independent BOH-hours + CPLH + scheduled-hours jitter so ≥6 lever families fire |
| G3 | Benchmark daypart table, Shift period cards | `target_cycle_dayparts` writer wired (`target_cycle_dao.dart:33-63`); seed cycle `dayparts` populated by in-flight worker | Until that worker lands, period rows may be empty → falls back to pool (Gap 42) | Build reseed AFTER the per-period cycle worker; assert non-empty differentiated `dayparts` |
| G4 | Variance History, Variance deltas | `mock_integration_replay_seed.dart:113-176` 8-week bands, low amplitude, no per-period variance | Flat history; deltas look synthetic | ≥10–12 weeks, higher amplitude, per-period + trend variance (§2d) |
| G5 | Learn narration (Gap 39) | No recurring per-(day, period) pattern engineered | Learn shows generic / "no pattern yet" | Engineer recurring period-level leak + benchmark + cross-axis pair (§2e) |
| G6 | Settings Integrations, Demo→Live switch, DemoModeBanner | No `demo_mode_state` rows seeded anywhere | Integration fold + banner render empty | Seed per-(O,L,category) states, mixed (§2f, §2g) |
| G7 | Wage authority (mobile + web), wage axis levers | `_buildDemoSeedCycle` falls back to `MeridianConfig.fohWage/bohWage` when `wage_role_rows` empty (`sqlite_database_seed.dart:765-836`) | Wage waterfall never exercised; wage levers never fire | Seed `wage_role_rows` with blended wages that deviate from target on some periods |
| G8 | Per-location operational data | Only `DemoScope.restaurantId` gets shifts/weeks/cycle/plan | New locations would be empty shells; scope drawer switch shows nothing | Seed coherent (smaller) data sets for the 3 new locations |
| G9 | Notifications | No alert/notification rows | Notifications surface empty | Seed ≥1 variance-breach-derived alert (or notification rows if table exists) |
| G10 | Multi-location HP #11 overrides | No scope-level override rows (timing/wage/data-accuracy at business/region/district) | Inheritance pills can't render real inherited-vs-effective | Seed one override at each scope level (§2c) |

---

## 4. Demo-contract compliance checklist

Every proposed addition is verified against `docs/contracts/demo_mode_contract.md` and CLAUDE.md → Demo Mode:

| Requirement | Compliance |
|---|---|
| Writes through existing tables only | ✅ All additions write `restaurant_locations`, `org_units`, `shift_records`, `week_records`, `target_cycles`, `target_cycle_dayparts`, `weekly_plan_snapshots`, `weekly_plan_snapshot_day_dayparts`, `wage_role_rows`, `data_accuracy_service_period_settings`, `import_runs`, `raw_import_records`, `restaurant_timing_configs`, `demo_mode_state`. All exist for production. |
| No `demo_*` tables | ✅ Zero new `demo_*` tables. New locations use new `restaurant_id` values under `restaurant_id`-scoped existing tables. `org_units` is the production hierarchy table. |
| No new `kDemoMode` reader branch | ✅ All data flows through `MockReplayDataSourceProvider` → `_seedDemoDataFromReplay` (and the existing seed helpers `_seedDemoRestaurant`, `_seedDemoTimingConfig`, `_seedDemoActiveTargetProfile`, `_ensureDemoSeedCycle`, `_backfillLockedTargets`, `_seed*FromReplay`). Readers (repositories/services/widgets) unchanged. The 4 blessed carve-outs are untouched. |
| Demo data round-trips production DAOs | ✅ Cycle writes via `SqliteTargetCycleRepository`/`target_cycle_dao.upsertCycle`; shifts via `shift_records` upsert path; the per-period cycle worker already uses the production DAO. |
| Schema changes required? | ❌ **None.** `org_units` (`db/migrations/202604280002_phase_9_0sigma_c_org_units.sql`), `target_cycle_dayparts` (`sqlite_database_migrations.dart:325-342`), `demo_mode_state`, multi-row `restaurant_locations`, `wage_role_rows`, keyed `data_accuracy_service_period_settings` all already exist for production. The hierarchy is purely *seeding more rows into production tables*. |
| Determinism preserved | ✅ All new variation derived from indices, no RNG (`mock_integration_replay_seed.dart` header invariant). |
| Backward compat | ✅ `DemoScope.restaurantId = 'demo_restaurant_001'` preserved for Downtown so `test/persistence_scope_alignment_test.dart` and `test/integration/demo_mode_writer_side_test.dart` keep passing. |

**One watch item (not a violation):** the SQLite demo has no `org_units` table today (it's a Postgres production table; the mobile app derives scope from `restaurant_locations` + `BusinessScope`). Verify during implementation whether mobile hierarchy is expressed via a SQLite hierarchy table or only via `restaurant_locations` + the operator-web fixture. If mobile has no local org_units table, the multi-location requirement is satisfied by multiple `restaurant_locations` rows + `BusinessScope` list; the org tree lives in the operator-web demo gateway fixture. Either way: no `demo_*` table, no new reader branch. Confirm in Slice A audit.

---

## 5. Chunked implementation plan

Each slice is independently dispatchable, <~6 files where possible, `worktree → PR → STOP` (CLAUDE.md agent-led rule). **Hard sequencing constraint:** `mock_integration_replay_seed.dart` and `sqlite_database_seed.dart` are touched by the in-flight per-period cycle worker (branch `claude/per-daypart-fix-demo-seed-per-period-cycle`). **No slice below dispatches until that PR merges**, and Slice B+ build on its `cycle.dayparts`-populated baseline.

### Slice A — Multi-location + org hierarchy seed (foundation)
**Files:** `sqlite_database_seed.dart` (`_seedDemoRestaurant`, `_ensureDemoRestaurant`), `sqlite_database.dart` (`DemoScope` → add location constants / a `DemoScope` location list), `restaurant_scope_notifier.dart` (verify `availableScopes` populates from seeded rows — read-only check), operator-web `demo_team_fixtures.dart` (align org tree).
**Scope:** Seed 4 `restaurant_locations`; align operator-web org-unit fixture to the §2c tree; ensure scope drawer surfaces all 4. No operational data yet for new locations (Slice C).
**Depends on:** in-flight per-period cycle worker merged. **Blocks:** C, E, F.

### Slice B — Driver variance overhaul (the "all covers covers covers" fix)
**Files:** `mock_integration_replay_seed.dart` (`_generateShift`, the week/period variation bands, new per-period BOH-hours / CPLH / scheduled-hours jitter), `sqlite_database_seed.dart` (`_seedRecommendationCandidates` / wage-row seeding hook).
**Scope:** Implement §2a distribution + §2d amplitude/trend + seed `wage_role_rows` (§2g/G7) so wage levers can fire. Keep determinism. Add a unit test asserting ≥6 lever families appear across the closed cohort and that `covers_down` is no longer >50%.
**Depends on:** per-period cycle worker (shares the same files). **Blocks:** D.

### Slice C — Per-location operational data
**Files:** `sqlite_database_seed.dart` (extend `_seedDemoDataFromReplay` / seed helpers to loop over the 4 locations), `mock_integration_replay_seed.dart` (parameterize by location for the 3 smaller data sets).
**Scope:** Each new location gets a coherent ≥30-day data set (shifts, week_records, cycle, locked plan, snapshots) so the scope drawer is a real switcher and each location's dashboard is fully operational.
**Depends on:** Slice A + Slice B. **Blocks:** E.

### Slice D — Learn per-period pattern engineering (Gap 39 narration)
**Files:** `mock_integration_replay_seed.dart` (engineer recurring per-(day, period) leak + benchmark + cross-axis pair on top of Slice B's distribution), test for `LearnTeachingAnalyzer` narration ("Friday dinner: …").
**Scope:** Guarantee a detectable recurring period-level leak, a benchmark pattern, and a cross-axis pair so Learn narrates at period resolution. Folds in the now-in-scope Gap 39 narration verification.
**Depends on:** Slice B. **Blocks:** none.

### Slice E — `demo_mode_state` + vendor integration states
**Files:** demo gateway / fixture for `demo_mode_state` (the Postgres-side `DemoModeStateGateway` demo impl), operator-web vendor connection fixture, `sqlite_database_seed.dart` if mobile fold needs a seed hook.
**Scope:** Seed per-(O,L,category) demo states (§2f/§2g): mixed connected / error-needs-reauth / disconnected; one location already flipped to live. Exercises Integrations fold, `DemoModeBanner`, master Demo→Live switch + its Live→Demo refusal.
**Depends on:** Slice A (needs the 4 locations). **Blocks:** none.

### Slice F — HP #11 scope-level overrides + notifications
**Files:** `sqlite_database_seed.dart` (seed timing/wage/data-accuracy override rows at business/region/district scope), operator-web demo gateways for wage/data-accuracy scope, notification/alert seed (or variance-derived alert verification).
**Scope:** One override per scope level (§2c) so every HP #11 inherited/effective pill renders real inheritance; ≥1 notification/alert from a seeded variance breach.
**Depends on:** Slice A. **Blocks:** none.

### Sequencing summary

```
[in-flight per-period cycle worker] ──► A ──► C ──► E
                                   └──► B ──► D
                                        A ──► F
```

A and B can run in parallel after the per-period worker merges (different concerns; B may rebase on A or vice versa — coordinate the shared `mock_integration_replay_seed.dart` edits; recommend A first, then B rebases). C depends on A+B. D depends on B. E and F depend on A.

---

## 6. Acceptance — "nothing not covered"

Demo is fully operational when, end-to-end on the demo build:
1. Scope drawer switches between ≥4 locations; each location's Shift/Variance/Plan/Benchmark surfaces are non-empty and internally consistent.
2. History shows ≥6 distinct primary drivers across rows (not "all covers"); per-period History grades differ by period.
3. Variance shows non-flat week-to-week deltas; WTD vs Plan deltas vary by day.
4. Learn narrates at least one period-resolution leak ("Friday dinner: …"), one benchmark, one cross-axis pair.
5. Benchmark daypart table shows differentiated lunch/dinner/late_night targets; Whole Day rollup = the CPLH widget value 1:1.
6. Settings Integrations fold + DemoModeBanner render real per-(O,L,category) state; master Demo→Live switch behaves (refuses Live→Demo).
7. Every HP #11 surface (web + mobile) renders a real scope chip + inherited source + effective value, driven by seeded overrides at business/region/district/location.
8. Demo-mode-writer-side test, persistence-scope-alignment test, and migration drift scanner stay green; zero `demo_*` tables; zero new `kDemoMode` reader branches.
