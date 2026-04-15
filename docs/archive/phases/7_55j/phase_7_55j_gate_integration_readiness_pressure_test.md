# Phase 7.55j.gate - Integration Readiness Pressure Test

Updated: 2026-04-12
Owner: Codex planning / tracker truth
Status: Gate run complete â€” verdict recorded

## Purpose

This gate sits after `7.55j.2` and before `7.55l.0`.

It exists to answer one question honestly before more architecture work lands:

```text
Are we actually ready for simple-swap live integrations,
or are we only integration-shaped so far?
```

## Gate Inputs

This verdict is grounded in:

- `docs/archive/phases/7_55j/phase_7_55j_1_codebase_feature_inventory.md` â€” 11-surface repo walk
- `docs/archive/phases/7_55j/phase_7_55j_2_required_capability_matrix.md` â€” capability requirements
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md` â€” target architecture rules
- `docs/archive/phases/7_55i/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md` â€” earlier checkpoint
- `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md` â€” planned implementation
- Live grep evidence from the current `lib/` tree (2026-04-11)

---

## Questions This Gate Must Answer

### 1. Is the app fully aligned through real SQL simulation?

**Answer: Partially â€” not yet.**

What is real today:

- Closed shift data flows through `shift_records` table, repositories,
  services, notifiers, and UI. This path is real SQL.
- `ActiveTargetProfile` is persisted in SQLite and consumed from the
  repository by most runtime services.
- `DemandForecastContext` (v1) is repository-backed from closed shift
  history. Real SQL query, not fixture.
- `SchedulePlan` resolves from repository-backed demand + persisted profile +
  data-driven distribution weights. Real services, real inputs.
- `WageStandardContext` resolves through the integration-first waterfall
  with real SQLite-backed wage role rows. Real SQL.
- `ReservationBookSnapshot` is persisted in SQLite with source provenance
  fields already present. Schema is Phase 8R-ready.
- Import tracking (`import_runs`, `raw_import_records`) uses real schema.

What is not yet real:

- **All operational data originates from `MockIntegrationReplaySeed`**.
  32 references across 6 files. The replay generator populates every
  operational table at bootstrap and reseed. No live vendor transport
  exists. The SQL path is real, but the data entering it is synthetic.
- **`BaselineData` in-memory globals are still primed at bootstrap** via
  `primeManagerOverride()` and read by 13 files (88 occurrences).
  This is a compatibility bridge, not SQL-backed truth.
  The canonical authority is the persisted `ActiveTargetProfile`, but
  benchmark display, Learn, and some Schedule/Audit paths still read
  the in-memory bridge instead.
- **`MeridianConfig` static defaults are still fallback values** in 12
  files (58 occurrences). These are hardcoded constants, not
  restaurant-scoped configuration.
- **`buildActiveTargetProfileFromBaseline()`** still reads from
  `BaselineData` in-memory globals to construct the persisted profile.
  7 call sites. This bridge method is the glue between the old
  in-memory state and the new persisted path.

**Short version**: the downstream SQL path is real. The upstream data
entering it is not. The in-memory bridge layer is still load-bearing.

### 2. Is the app ready for simple-swap live integrations?

**Answer: No â€” not yet.**

A "simple swap" means: replace `MockIntegrationReplaySeed` with a live
POS/labor adapter, feed the same canonical models, and the rest of the
app works without structural changes.

Why the swap is not simple today:

1. **No `TargetCycle` exists.** Standards are derived live from
   `BaselineData` globals each time the app starts or the manager
   overrides. There is no persisted 60-day locked cycle. A live
   integration would feed closed shifts, but the app has no mechanism
   to lock standards for 60 days and keep them stable while new shifts
   arrive.

2. **No `WeeklyPlanSnapshot` exists.** The operating week's plan is
   resolved live from current demand + current targets + current weights
   each time it is requested. Variance and History compare against this
   live-resolved plan, which means the comparison target can shift as
   new data arrives. A live integration needs a locked weekly plan so
   Variance and History compare against a stable reference.

3. **`DemandForecastContext` is v1 only.** It computes the 60-day
   average from closed shifts but does not include the fixed 3-week
   recent trend. This means weekly demand allocation is a flat average,
   not a smoothed baseline-plus-trend. A live integration would feed
   more granular recent history, but the app cannot yet use it to refine
   the weekly demand spread.

4. **`BaselineData` bridge is still load-bearing (partially retired).**
   Learn no longer reads `BaselineData` in production runtime â€” Learn's
   benchmark context now resolves from persisted cycle/profile/summary
   authority (retired in 7.55l.8aâ€“8d1). Schedule has a 3-read fallback
   (`schedule_builder.dart:381-385`). Data Audit displays 5 reads as a
   "BASELINE" comparison column. The bootstrap path
   (`primeManagerOverride`) primes `BaselineData` from persisted
   selections on every app start. Swapping transport alone would leave
   the remaining non-Learn bridge reads orphaned or incorrect.

5. **`MeridianConfig` is still the wage/target fallback.** Week records,
   shift records, and the `StaticShiftDataSource` test source all use
   `MeridianConfig` constants as constructor defaults and zero-hour
   fallbacks. With live transport, these defaults could silently mask
   missing vendor data instead of failing visibly.

6. **Distribution weights are loaded live, not locked.** Day allocation
   loads from the most recent 8 completed weeks on each request. With
   live data arriving continuously, the allocation weights can shift
   between requests within the same week. The target architecture locks
   day allocation inside the `WeeklyPlanSnapshot`.

**Short version**: the app is integration-shaped, not integration-finished.
The internal data flow from SQLite to UI is correct. The runtime
architecture that makes integration data behave correctly â€” locked
standards, locked weekly plans, retired bridges â€” is not in place.

### 3. Does the earlier checkpoint still hold?

**Answer: Yes, as seam guidance â€” not as the full runtime architecture.**

The `phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md` confirmed:

- app-owned service-period definitions: **still holds**
- timestamp bucketing instead of vendor-native dayparts: **still holds**
- integration-first wage authority with app fallback: **still holds** â€”
  `WageStandardContextService` implements the waterfall
- Shift whole-day until Phase 10.5: **still holds**

The checkpoint's vendor capability snapshot (Toast, Square, 7shifts,
Clover) remains valid reference material for Phase 8 vendor profiling.

What changed since the checkpoint:

- The `TargetCycle + WeeklyPlanSnapshot` planning rules now sit above the
  checkpoint. The checkpoint guides seam design; the cycle/week rules
  govern runtime behavior.
- The checkpoint assumed `7.55i.3` would be the last app-side seam before
  Phase 8. In practice, `7.55l` is now the required implementation lane
  between the completed seams and actual integration readiness.
- The checkpoint's architecture decisions are correct input to `7.55l`,
  but `7.55l` is what makes them runtime-real.

**Hierarchy**:

```text
docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md  (runtime architecture rules)
  â”œâ”€â”€ this gate verdict  (readiness assessment)
  â”œâ”€â”€ docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md  (implementation plan)
  â””â”€â”€ docs/archive/phases/7_55i/phase_7_55i_pre_7_55i3_integration_daypart_checkpoint.md  (seam guidance)
```

---

## Pressure-Test Categories

### Green â€” Already Good

These are closed or architecturally correct today:

| Item | Evidence |
|---|---|
| Canonical demand authority | `DemandForecastContext` v1 exists, repository-backed, consumed by Schedule + Audit. 10 files. |
| Shared SchedulePlan authority | `SchedulePlanReadService` centralizes plan resolution (7.55i.2). 10 files. |
| Wage authority with integration-first waterfall | `WageStandardContextService` implements 5-level precedence. 10 files. Labor seams are clean for Phase 8. |
| App-side SQLite/repository/notifier/UI flow | Closed shifts â†’ repositories â†’ services â†’ notifiers â†’ UI is a real persisted path, not in-memory. |
| ActiveTargetProfile as persisted standard | Persisted in `active_target_profiles` table, consumed by 23 files. Canonical authority. |
| Daypart checkpoint still valid as seam guidance | App-owned service periods, timestamp bucketing, integration-first wages all confirmed. |
| Shift whole-day until Phase 10.5 | No live daypart Shift work needed before Phase 10.5. |
| Reservation schema Phase 8R-ready | `reservation_book_snapshots` table has `sourceSystem`, `sourceServiceId`, `lastEventAt` fields. |
| Import tracking schema exists | `import_runs` and `raw_import_records` tables already present. |
| No UX change required | All planned architecture work is internal; no manager-facing workflow change. |

### Yellow â€” Bridge or Demo Transport Still Present

These are functional but not integration-clean:

| Item | Scope | Risk |
|---|---|---|
| **`BaselineData` in-memory bridge** | 88 occurrences across 13 files | Most significant remaining bridge. Learn reads 6 globals. Benchmark display reads ~15. `buildActiveTargetProfileFromBaseline()` reads 6. Schedule fallback reads 3. Audit reads 5. |
| **`MeridianConfig` static defaults** | 58 occurrences across 12 files | Hardcoded constants used as constructor defaults and fallbacks. Not restaurant-scoped. Could mask missing vendor data in production. |
| **`primeManagerOverride()` at bootstrap** | Called at app start in `forge_flow_bootstrap.dart` | Primes in-memory `BaselineData` from persisted selection. Temporary compat bridge. |
| **`buildActiveTargetProfileFromBaseline()`** | 7 call sites in 3 files | Reads `BaselineData` globals to construct persisted profile. Should be replaced by `TargetCycle` projection. |
| **`StaticShiftDataSource` test bridge** | 9 BaselineData reads + 11 MeridianConfig reads | Test-only source, not production runtime. But it demonstrates how deeply BaselineData/MeridianConfig are embedded in the contract assumptions. |
| **Schedule `BaselineData` fallback** | `schedule_builder.dart:381-385` | 3 target + 2 wage reads when profile isn't ready. Would fire in production if profile load is slow. |
| **Learn production BaselineData reads** | ~~`learn_teaching_analyzer.dart`~~ | **Closed (7.55l.8aâ€“8d1).** Learn benchmark context now resolves from persisted cycle/profile/summary authority. `LearnTeachingAnalyzer` no longer reads `BaselineData`. Remaining Learn bridge is limited to explicit bridge-only mode (widget tests) and genuine no-profile bootstrap. |
| **`MockIntegrationReplaySeed` demo transport** | 32 occurrences across 6 files | All operational data originates from the deterministic replay generator. No live vendor data enters the system. |
| **`mock_replay_state` table** | Used for scenario date control | Demo-only table used to parameterize the mock business date. Not present in production architecture. |
| **Static `open_shift_snapshots`** | Seeded once, never updated | No live POS feed. Shift dashboard actuals are frozen at bootstrap time. |
| **Static `reservation_book_snapshots`** | Seeded once, never updated | No live reservation feed. "In the books" is frozen at bootstrap time. |
| **Distribution weights live-loaded** | `SchedulePlanReadService.loadDistributionWeights()` | Loaded from recent 8 weekIds on each request. Not locked for the week. |

### Red â€” Final Architecture Still Missing

These are the blockers. Without them, live transport cannot produce correct
downstream behavior:

| Item | Why It Blocks | Owning Phase |
|---|---|---|
| **`TargetCycle` not implemented** | Standards cannot lock for 60 days. New closed shifts arriving from a live integration would cause targets to drift daily instead of staying stable for coaching and accountability. Manager override has no cycle boundary. | `7.55l.1` + `7.55l.2` |
| **`TargetCycle` persistence not implemented** | No `target_cycles` SQLite table. No cycle auto-refresh at the 60-day boundary. No once-per-cycle override rule enforcement. | `7.55l.2` |
| **`ActiveTargetProfile` not yet a cycle projection** | `ActiveTargetProfile` exists and is consumed, but it is built from `BaselineData` bridge globals via `buildActiveTargetProfileFromBaseline()`, not projected from a locked `TargetCycle`. | `7.55l.4` |
| **`DemandForecastContext` v2 not implemented** | Only level 1 baseline (60-day average). No fixed 3-week recent trend. Weekly demand allocation is a flat average, not a smoothed spread. | `7.55l.5` |
| **Weekly demand/day allocation not explicit** | Day allocation comes from live-loaded distribution weights, not from explicit weekly plan generation rules. The baseline-plus-trend smoothing rule is not implemented. | `7.55l.3` |
| **`WeeklyPlanSnapshot` not implemented** | No `weekly_plan_snapshots` SQLite table. No auto-generation at week start. No auto-lock. The weekly plan is resolved live and can shift between requests. | `7.55l.6` |
| **Consumer migration not done** | Schedule, Shift, Variance, History, and Audit do not read from the cycle/week model. They read live-resolved values. | `7.55l.7` |
| ~~**Learn bridge retirement not done**~~ | **Closed (7.55l.8aâ€“8d1).** Learn production runtime now resolves from persisted cycle/profile/summary authority. `LearnTeachingAnalyzer` no longer reads `BaselineData`. Remaining bridge surfaces are intentionally narrow (widget test bridge-only mode and no-profile bootstrap). See `docs/archive/phases/7_55l/phase_7_55l_8_learn_bridge_closeout.md`. | `7.55l.8` |

---

## Overall Readiness Verdict

```text
SIMPLE-SWAP INTEGRATION READY: NO

Integration-shaped is not yet integration-finished.
```

The app has the right internal data flow from SQLite to UI. The seams are
correct. The missing piece is the runtime architecture that makes live data
behave correctly:

1. Locked 60-day `TargetCycle` so standards do not drift daily
2. Rolling `DemandForecastContext` v2 so demand uses baseline + trend
3. Locked `WeeklyPlanSnapshot` so Variance and History compare against
   a stable reference
4. Consumer migration so all surfaces read from the cycle/week model
5. ~~Bridge retirement so `BaselineData` and `MeridianConfig` are no longer
   load-bearing in production paths~~ â€” **Learn bridge retirement closed
   (7.55l.8aâ€“8d1).** Non-Learn `BaselineData` / `MeridianConfig` bridges
   remain (Schedule fallback, Audit display, bootstrap priming).

Items 1â€“4 are owned by `7.55l` and remain open. Item 5 is partially
closed: Learn production runtime no longer reads `BaselineData`.
See `docs/archive/phases/7_55l/phase_7_55l_8_learn_bridge_closeout.md`.

---

## Handoff Into 7.55l

### What 7.55l receives from 7.55j

1. **Feature inventory** (`7.55j.1`): 11-surface map of every operational
   truth consumer, including bridge/demo dependency counts and owning phases
2. **Capability matrix** (`7.55j.2`): per-surface integration requirements
   with blocked-vs-degrade judgments and freshness tiers
3. **This gate verdict** (`7.55j.gate`): explicit red/yellow/green assessment
   with the honest "not ready" answer and measurable blocker list

### What 7.55l must deliver before Phase 8

The red blockers above are the `7.55l` work breakdown:

| 7.55l Slice | Closes Red Blocker |
|---|---|
| `7.55l.0` | Planning cleanup and handoff |
| `7.55l.1` | TargetCycle contract |
| `7.55l.2` | TargetCycle persistence + auto-refresh |
| `7.55l.3` | Weekly demand/day allocation rules |
| `7.55l.4` | ActiveTargetProfile as TargetCycle projection |
| `7.55l.5` | Rolling DemandForecastContext v2 |
| `7.55l.6` | WeeklyPlanSnapshot contract + auto-lock persistence |
| `7.55l.7` | Consumer migration |
| `7.55l.8` | ~~Learn migration + bridge retirement~~ â€” **Complete (7.55l.8aâ€“8d1)** |

### What has landed since this gate

- **`7.55l` complete** â€” `TargetCycle`, `WeeklyPlanSnapshot`,
  `DemandForecastContext` v2, `ActiveTargetProfile` as cycle projection,
  consumer migration, and Learn bridge retirement have all landed. The red
  blockers identified by this gate are now closed.
- **`7.55k` complete** (`7.55k.1`â€“`7.55k.8`) â€” evidence-backed History
  benchmarks, Learn Repeatable Wins, interim visibility policy, and
  integration implications have landed. See
  `docs/archive/phases/7_55k/phase_7_55k_8_integration_implications.md` for the
  proven downstream integration requirements.

### What remains before Phase 8

1. `7.55j.3` â€” Vendor Endpoint Checklist Template (should consume `7.55k.8`
   proven requirements)
2. `7.55j.4` â€” Gap Report
3. `7.55n` â€” Restaurant timing + service-period runtime foundation
4. `7.55o` â€” File extraction / engineering hygiene

Then Phase 8 can begin vendor-specific connector work with:
- a locked runtime architecture (`7.55l` landed)
- evidence-backed downstream requirements (`7.55k` landed)
- an explicit requirements map (`7.55j.2` updated)
- a per-vendor checklist template (`7.55j.3` still ahead)
- remaining bridge-era reads isolated to yellow-tier items

### Gate re-evaluation

`7.55l` is now complete. All red blockers identified by this gate have been
closed: `TargetCycle` (`7.55l.1`â€“`7.55l.2`), `ActiveTargetProfile` as cycle
projection (`7.55l.4`), `DemandForecastContext` v2 (`7.55l.5`),
`WeeklyPlanSnapshot` (`7.55l.6`), consumer migration (`7.55l.7`), and Learn
bridge retirement (`7.55l.8`).

`7.55k` is also now complete (`7.55k.1`â€“`7.55k.8`). Evidence-backed
downstream requirements are documented and fed back into this inventory.

Remaining yellow-tier items (non-Learn `BaselineData` bridge reads,
`MeridianConfig` fallback reads, `MockIntegrationReplaySeed` demo transport)
persist as documented bridge/demo dependencies. These do not block
integration readiness but should be cleaned up or isolated before or during
Phase 8 connector work.

The simple-swap readiness verdict should be re-evaluated once `7.55n`
(timing foundation) and `7.55o` (engineering hygiene) complete. At that point
the answer may change from NO to conditional YES with documented remaining
demo-transport-only items.

---

## Quantitative Summary

| Category | Count | Detail |
|---|---|---|
| Green items | 10 | Canonical demand, plan, wage, profile, schema, UX |
| Yellow items | 12 | BaselineData (88 refs), MeridianConfig (58 refs), replay (32 refs), bridges |
| Red items | **All closed** (8/8) | `TargetCycle` (`7.55l.1`â€“`7.55l.2`), `ActiveTargetProfile` projection (`7.55l.4`), `DemandForecastContext` v2 (`7.55l.5`), `WeeklyPlanSnapshot` (`7.55l.6`), consumer migration (`7.55l.7`), Learn bridge retirement (`7.55l.8`). All landed. |
| Files with BaselineData bridge reads | 13 | Production + test |
| Files with MeridianConfig fallback reads | 12 | Production + test |
| Files with MockIntegrationReplaySeed refs | 6 | Demo transport |
| Files referencing TargetCycle or WeeklyPlanSnapshot | 0 at gate time | **Now implemented.** `TargetCycle` (`7.55l.1`â€“`7.55l.4`), `WeeklyPlanSnapshot` (`7.55l.6`), consumer migration (`7.55l.7`), and Learn bridge retirement (`7.55l.8`) have all landed. |
| `7.55l` slices needed before re-evaluation | 9 at gate time | **All complete.** `7.55l.0`â€“`7.55l.8` have landed. See `docs/archive/phases/7_55l/phase_7_55l_target_cycle_weekly_plan_implementation.md`. |

---

## Closeout

This gate is complete:

- [x] The repo has an explicit simple-swap readiness verdict: **NO**
- [x] The remaining bridge/demo blockers are named (12 yellow items)
- [x] The missing cycle/week architecture blockers are named (8 original red items; 1 closed â€” Learn bridge retirement)
- [x] The handoff into `7.55l` is unambiguous
- [x] The earlier checkpoint's status is recorded: valid seam guidance
      under the newer cycle/week architecture
