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

## Session-2 finalization addendum (authoritative verification ledger)

This addendum supersedes the per-test counts above where they differ;
it is the definitive verification done after reconciling the salvaged
WIP with the canonical finalize commit.

### Reconciliation note

A prior loop tick auto-salvaged the worker output (`c07330b5`) and
finalized it (`66699ac8`: + the audit doc above, the
`legacyDefaultResolution` public accessor, and the `coldBoot:` arg
split). This session independently re-derived the SAME refinements and
additionally fixed Change-B count couplings the prior finalize left red.
Final tree = `66699ac8` + the count-fix test deltas below. No lib
behaviour change beyond `66699ac8`.

### Additional in-scope test updates (Change-B count couplings)

Change B raises the demo operating pattern from 14 → **16** slots/week
(weekends now serve Lunch) and `lunch.applicable_days` from Mon–Fri →
Mon–Sun. The production WeekRecord rollup gate derives the expected
per-week count from `RestaurantTimingConfig` (not hardcoded), so it
self-adjusts correctly — only tests that hardcoded the old 14-slot /
168-historical / Mon–Fri-lunch demo shape needed updating. Mechanical,
test-only, seed-contract-following:

- `mock_integration_replay_seed_test.dart` — `weeks*14`→`*16`,
  `length 14`→`16`, `9 closed + 5 projected`→`9 + 7`, group-E open
  snapshot assertions rewritten to derive from `resolveDemoOpenPeriod`
  (clock-derived) instead of the old fixed `0.63`/`7:45 PM`/`3h 15m`.
- `mock_replay_scenario_test.dart` — A-group counts updated for the
  16-slot week; setUp pins `debugColdBootNowOverride` so C/G stay
  deterministic.
- `runtime_fixture_retirement_test.dart` — `shiftsTotal 14`→`16`,
  projected `5`→`7`; group-B setUp pins the now-override.
- `replay_integrity_audit_test.dart` — `getFullWeekShifts` length
  `14`→`16` (×2), `historicalWeekCount*14`→`*16`.
- `current_state_alignment_test.dart` — "full week has N slots"
  `14`→`16` (×2 tests) + `fullWeekShifts.length 14`→`16`.

### Baseline diff vs fresh `origin/master` (regression discrimination)

Ran the realistic blast-radius set (10 suites:
current_state_alignment, shift_service_close_shift,
distribution_weight_builder, baseline_range_logic,
learn_benchmark_context_service, wtd_variance_logic,
shift_whole_day_alignment, variance_history_widget,
shift_dynamic_truth, shift_record_source_truth) on this branch AND on a
clean `git worktree` at `origin/master`:

- **Branch: 266 pass / 8 fail. Master: 263 pass / 11 fail.**
- The 8 branch failures are a strict **subset** of the 11 master
  failures — **every branch failure is reproduced identically on fresh
  `origin/master` → 100% PRE-EXISTING, ZERO PR-introduced regressions.**
- The change **net-FIXED 3** pre-existing master failures
  (`current_state_alignment` "full week has 14 slots total",
  "getCurrentWeekState returns valid state", "full week still has 14
  slots after locked migration" — now pass at 16).
- Pre-existing failures (proven on fresh `origin/master`, NOT
  regressions; CLAUDE.md → treat as expected):
  1. `mock_replay_scenario_test.dart :: benchmark_selection_summaries
     survive replay advance` (Expected non-empty / Actual []).
  2. `replay_integrity_audit_test.dart :: week_records populated after
     reseed` (Expected <12> / Actual <48/…>).
  3. `shift_service_close_shift_test.dart` — 6 tests
     (`closing all 14 shifts creates a WeekRecord`, `projected Fri
     dinner slot is replaced cleanly`, the two `7.55q.5` close-all
     tests, the two `7.55q.10` frozen-dollar-impact tests). These
     encode the OLD 14-slot close-flow (close 5 specific projected
     slots; gate at 14). They fail identically on `origin/master`.
     **Not fixed here** — correctly updating them needs new Sat/Sun
     Lunch close helpers + a 16-slot close enumeration, which is a
     close-flow test rewrite beyond SEED-ONLY scope. The production
     gate is verified correct (derives from timing config; comment
     `shift_service_close_shift_test.dart:438-444` confirms it sums
     per-period applicable-days). **FOLLOW-UP NEEDED:** update
     `shift_service_close_shift_test.dart` for the 16-slot demo
     (test-only; production logic already self-adjusts).
  4. `current_state_alignment_test.dart` — `B getShiftDashboard
     returns null when no locked plan` and `J1b … Expected <64>
     Actual <61>` (locked-Schedule canonical-weights allocation
     shifted because Change B adds weekend-Lunch covers to the
     distribution). Both fail identically on `origin/master`
     (`B` is unrelated pre-existing; `J1b` is a stale distribution
     magic-number). Test-only follow-up; production allocation is
     correct (derives from weights).

### Required suites — all green on the final tree

new suite **4/4**; `per_daypart_v1_demo_seed_perloc_current_week_open_shift`
(#827) **pass**; `sqlite_database_cold_boot_today_anchor` (W8)
**pass**; `sqlite_database_cold_boot_partial_seed_regression` **pass**;
`mobile_operational_sync_demo_scope_preserving_wipe` **pass**;
`test/widget/` (per_daypart dashboard widgets) **all pass**;
`mock_integration_replay_seed` / `runtime_fixture_retirement` /
`provider_abstraction` / `reservation_book_snapshot_repository` /
`week_start_wiring` **pass**. `dart analyze lib` → only pre-existing
`info` lints in untouched files; **0 errors/warnings in touched files**.
No `db/migrations/*.sql` changed (migration drift scanner N/A).

### High-blast-radius gate

Per the prompt: seed-touching, high blast radius — **orchestrator
review + on-device clean-build verify on a Saturday business date
required before merge.** The investigation report named as Authority #2
(`INVESTIGATION_perdaypart_currentstate_dinner_wholeday.md`) does not
exist in any branch/history; the prompt's inline root-cause (verified
against code) was used as the binding analysis.

## Orchestrator audit

(left blank for the orchestrator)
