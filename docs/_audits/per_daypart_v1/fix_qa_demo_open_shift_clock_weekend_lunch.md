# Audit — Fix: demo open-shift clock-derived + weekend Lunch (salvaged WIP, verified)

Branch: `claude/fix-demo-open-shift-clock-weekend-lunch`
Salvage commit: `c07330b5` (worker WIP, preserved in history — not rewritten)
Finalize/verify commit: this commit (analyze + tests green; 3 PR-introduced compile errors fixed in-scope)

## Defect (device-reproduced 2026-05-16, Sat ~09:25)

The demo seed hardcoded `openShiftDaypart='dinner'` with a fabricated
`0.63` / `7:45 PM` / `3h 15m` mid-service snapshot that never consulted
the clock. Consequences:

- Dinner always rendered the location's WHOLE-DAY total as a "live"
  snapshot even before Dinner opened (Metric-Honesty / Design Rule 2
  violation — a not-yet-open period showed a fabricated live bar).
- Sat/Sun had NO Lunch slot, so a Saturday's only seeded actuals were
  the one open-Dinner row; Whole-Day collapsed to ≡ Dinner.

## Fix shipped

- **Change A** — open service period is derived from the
  restaurant-local clock at seed time, injectable via the test seam
  `SqliteDatabase.debugColdBootNowOverride` (static `String?`).
  Demo/device falls back to the real `DateTime.now()` so a true
  Saturday 09:25 (before Lunch) shows NO open shift.
- **Change B** — Saturday AND Sunday now serve a Lunch period like a
  real restaurant; weekend Lunch covers flow through the same
  deterministic per-location envelope and the existing `'lunch'`
  per-period band.

## Verification finding (PR-introduced, fixed in-scope)

The salvaged WIP did **not compile** — `flutter analyze` surfaced 3
errors, all PR-introduced, all fixed strictly within seed/db-helper
scope (HP #2 + Time Guardrails honored, no DDL, no reader branch):

1. `sqlite_database.dart:369` referenced
   `MockIntegrationReplaySeed.legacyDefaultResolution`, but the seed
   library only defined the file-private `_legacyDefaultResolution`
   (cross-library access of a `_`-prefixed member is impossible).
   → Added a public getter `legacyDefaultResolution` on
   `MockIntegrationReplaySeed` (`mock_integration_replay_seed.dart:459`)
   that returns the existing `_legacyDefaultResolution`. No behaviour
   change — pure visibility shim.
2. `sqlite_database.dart:443` (cold-boot fresh-schema seed) omitted the
   `required bool coldBoot` argument. → Passed `coldBoot: true` (this
   is the genuine fresh-launch path → real clock decides the open
   period; the defect fix).
3. `sqlite_database.dart:810` (`reseedMockReplayForBusinessDate`,
   reseed/advance path) omitted the same required argument. → Passed
   `coldBoot: false` (explicit demo-operator advance → deterministic
   legacy resolution when no clock anchor injected, so the demo
   affordance + bare-`reseedDemo()` tests stay stable).

After the fixes: `flutter analyze` on all 7 touched files →
**"No issues found!"**

## Pattern B lens table

| Lens | Worker (verify/finalize executor) — file:line | Orchestrator |
|---|---|---|
| Change A: clock-derived open period | `sqlite_database.dart:333-369` `_openPeriodResolutionForSeed` selects time-of-day by precedence (now-override → legacy date-only → cold-boot real clock → reseed legacy default); date stays the W8/reseed anchor. Resolver `sqlite_database_seed.dart:1035` `resolveDemoOpenPeriod` walks `_kDemoDowntownServicePeriods`, returns active period or `null`. Cold-boot wiring `sqlite_database.dart:441-446` (`coldBoot: true`); reseed wiring `sqlite_database.dart:805-810` (`coldBoot: false`). | |
| Change B: weekends serve Lunch | `mock_integration_replay_seed.dart` `_dayLabels` now `('Sat','lunch'),('Sat','dinner'),('Sat','late_night')` + `('Sun','lunch'),('Sun','dinner')`; `serviceSplits` Sat `{lunch:0.30,dinner:0.55,late_night:0.15}`, Sun `{lunch:0.45,dinner:0.55}`; scenario index map adds the two weekend-lunch slots while preserving the anti-degeneracy invariant (Sun dinner axis unchanged). Same DAOs/tables, no DDL. | |
| `debugColdBootNowOverride` test seam | `sqlite_database.dart:292` static `String?`; consumed at `:295` (`_coldBootAnchorIsoDate`, business-date-aware via `BusinessDateResolver`) and `:342` (`_openPeriodResolutionForSeed`). `null` in prod/demo → real clock. | |
| Test: new suite | `test/per_daypart_v1_demo_open_shift_clock_and_weekend_lunch_test.dart` (316 LoC). Group A pins Sat 09:25 → asserts `res.openDaypart isNull`, all periods `projected`, Whole-Day Sat = Σ(Lunch+Dinner) `> dinnerCovers`, ≥3 Sat periods. Group A second test pins Sat 19:45 → Dinner open w/ clock-derived progress (`165/360`), Lunch `closed`. Group B asserts Sat AND Sun Lunch rows w/ covers>0, per-location-distinct covers, per-period Lunch band, weekend-Lunch locked-plan child rows, two-reseed determinism. **4/4 pass.** | |
| Test: existing seed/replay suites | `mock_integration_replay_seed_test.dart` (back-compat byte-stability via untouched `_legacyDefaultResolution` default) **13/13 pass**; `runtime_fixture_retirement_test.dart` **15/15 pass**; `mock_replay_scenario_test.dart` **33 pass / 1 fail** (the 1 fail is pre-existing — see baseline below). | |
| Verify fix: visibility shim | `mock_integration_replay_seed.dart:459` `static OpenPeriodResolution get legacyDefaultResolution => _legacyDefaultResolution;` — pure accessor, zero behaviour change. | |
| Verify fix: coldBoot args | `sqlite_database.dart:445` `coldBoot: true` (cold-boot path); `:810` `coldBoot: false` (reseed path). Matches the documented semantics at `:317-332`. | |

## Compliance lines

- **HP #2 (writer/seed-side only):** CONFIRMED. Full diff scanned — no
  `kDemoMode` reader branch, no new `demo_*` SQLite table. Seed writes
  the same production DAOs/tables; `resolveDemoOpenPeriod` returns a
  value object consumed only by the writer path. The visibility-shim
  fix adds a getter to an existing dev seed class — no reader fork.
- **Time Guardrails:** CONFIRMED. `resolveDemoOpenPeriod`
  (`sqlite_database_seed.dart:1041`) anchors via
  `BusinessDateResolver.resolve(... businessDayStartLocalTime:
  _kDemoBusinessDayStartLocalTime)` — restaurant-local, business-date
  anchored (demo 04:00 start), no UTC/server clock. The seeded business
  **date** is unchanged (W8 today-anchor / reseed `isoDate` still
  wins); only the time-of-day used to pick the open period is sourced
  from the clock. No seeded VALUE calls `DateTime.now()` (deterministic
  given the injected anchor).
- **Metric Honesty / Design Rule 2:** CONFIRMED. When no period is in
  progress (`active == null`, e.g. Sat 09:25 before Lunch),
  `resolveDemoOpenPeriod` returns `openDaypart: null` and all snapshot
  fields `null` (`sqlite_database_seed.dart:1089-1097`) — no fabricated
  `0.63` / `7:45 PM` / 0-anchored "live" bar. The new test's Group A
  asserts the period renders `projected`, not a phantom live snapshot.
- **No SQLite DDL:** CONFIRMED. WIP diff + the 3 in-scope fixes contain
  no `CREATE/ALTER/DROP TABLE`, no `ADD COLUMN`, no `CREATE INDEX`, no
  `.sql` file changes.

## Per-(location, day-of-week) before → after

| Day | Before (hardcoded) | After (clock-derived + weekend Lunch) |
|---|---|---|
| **Sat 09:25** (defect repro) | Dinner hardcoded "open"; fabricated `0.63`/`7:45 PM`/`3h 15m`; NO Lunch slot; Whole-Day ≡ Dinner (= the whole-day total shown as a live bar) | NO open shift (`openDaypart=null`); Lunch/Dinner/LateNight all `projected`; Lunch slot present; Whole-Day Sat = Σ(Lunch+Dinner) **>** Dinner-only |
| **Sat 19:45** | Dinner "open" w/ fabricated constants | Dinner open w/ clock-derived progress (`165/360 ≈ 0.458`, `7:45 PM`, `2h 45m`); Lunch `closed` (ended 15:00); LateNight `projected`; Lunch slot present |
| **Sun (any time)** | Dinner only (1.0 split); NO Lunch | Lunch + Dinner (`{lunch:0.45, dinner:0.55}`); open period follows the real clock |
| Mon–Thu | lunch + dinner (unchanged) | lunch + dinner; open period clock-derived (legacy default 19:45→Dinner only when no anchor injected, e.g. bare reseed/advance) |
| Fri | lunch + dinner + late_night (unchanged) | same periods; open period clock-derived |

## Baseline discrimination (CI-dark honest disclosure)

`mock_replay_scenario_test.dart` →
`E — replay-stable locked artifacts survive replay advance >
benchmark_selection_summaries survive replay advance` FAILS
(`Expected: non-empty / Actual: []`, `test:507`).

Reproduced on a clean `git worktree` at `origin/master`
(`b204e074`) — **fails identically with the same error and line**.
The WIP's diff to `mock_replay_scenario_test.dart` only touches lines
~27–120; the failing test (494–530) and `benchmark_selection_summaries`
are untouched by this slice. **Classification: PRE-EXISTING master
failure, NOT PR-introduced.** Out of scope for this fix (it is not a
seed open-period / weekend-Lunch concern). Not in
`docs/KNOWN_FAILING_TESTS.md` as of this commit — flagged for the
orchestrator to triage/log separately; not forced here.

All other tests in scope pass: new suite 4/4, replay-seed 13/13,
fixture-retirement 15/15, scenario 33/1 (the 1 = the pre-existing
failure above).

## Orchestrator audit

(left blank for the orchestrator)
