# Audit — Demo data: per-location operational envelope

Slice: extend the per-location demo coverage envelope (already complete
for the SALES pipeline via Slice C) to the non-sales operational tables
+ a sample notification inbox.

Branch: `claude/demo-seed-multilocation-operational-envelope` ·
Base: `master` (branched at `4a8c73d7`).

Touched (seeders/fixtures + tests only — no `lib/screens/**`, Settings,
proxy, auth):

| File | Δ |
|---|---|
| `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` | +636 |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | +32 / wiring |
| `test/mock_replay_scenario_test.dart` | superseded pin updated |
| `test/shift_dashboard_notifier_cold_boot_test.dart` | superseded pin updated |
| `test/per_daypart_v1_demo_seed_multilocation_operational_envelope_test.dart` | new |
| `test/per_daypart_v1_demo_seed_cold_boot_wage_test.dart` | new |

No `db/migrations/*.sql` change — every target table/column already
exists (verified against `sqlite_database_schema.dart:240-487`). Migration
drift/cutoff lints therefore N/A (expected per prompt).

---

## (a) Slice C reconciliation — what already existed vs what this adds

**Already on master (NOT re-implemented; reused read-only):**

- `shift_records` + `week_records` for **all 4** demo locations
  (Downtown / North Loop / Riverside / Harbour) across **{12 historical
  weeks + current} × the 14 served weekly slots**, with per-location
  variance profiles — `_seedAdditionalLocationsFromReplay`
  (`sqlite_database_seed.dart:1482`), `_scaleShiftForLocation`
  (`:1281`), `_scaleWeekMapForLocation` (`:1354`), `_demoLocationProfiles`
  (`:1262`: Downtown identity, North Loop 1.22 vol, Riverside
  0.84/tighter-labor, Harbour 0.93).
- `target_cycles` / `target_cycle_dayparts` / `active_target_profiles`
  / `target_profile_versions` / `import_runs` / `raw_import_records`
  per location (`_buildLocationSeedCycle` `:1401`, `_buildDemoSeedCycle`
  `:981`). Per-period cycle bands derive from
  `MockIntegrationReplaySeed.demoDaypartTargetBand`
  (`mock_integration_replay_seed.dart:143`).
- `reservation_book_snapshots`: **Downtown only, scenario open shift,
  1 row** (`_seedReservationBookSnapshotsFromReplay` `:779`).
- `open_shift_snapshots`: **Downtown only, current week only**
  (`_seedOpenShiftSnapshotsFromReplay` `:144`).
- `weekly_plan_snapshots` + `weekly_plan_snapshot_day_dayparts`:
  **Downtown only, in-force week only** (the child table IS already
  seeded for that one snapshot — the gap brief's "child never seeded"
  was stale; `_seedWeeklyPlanSnapshotFromReplay:302`, child write
  `:561-575`).
- `wage_role_rows`: seeded **reseed-path only**, NOT cold-boot
  (`reseedMockReplayForBusinessDate` `:509`; absent from `_onCreate`).
  Per-location wage is an **intentional HP #11 design**: Downtown
  business default (`_seedDemoWageRoleRows:1133`), Riverside override
  (`_seedDemoScopeOverrideWageRows:1962`), North Loop + Harbour
  deliberately NO rows → inherit ("inherited from Business" pill).
- `app_notifications`: only `_seedDemoVarianceBreachNotification`
  (`:2110`) — Downtown, reseed-path only, conditional single row.

**This slice adds (each verified genuinely missing):**

| Gap | Reconciled scope added |
|---|---|
| 2 open_shift_snapshots | Per-location HISTORICAL `closed` snapshots for the full 12-week range, all 4 locations, values = the closed shift stamp (Promise 2). Current-week `closed`/`projected` for the 3 non-Downtown. **No 2nd `open` row** (singular live shift stays Downtown's; pinned invariant). |
| 1 reservation_book_snapshots | The FORWARD book (current-week projected/open cells) for all 4 locations, EXISTING covers→unseated ratio × each location's volume. **Closed/past cells get NO row** — reconciled honest shape (see below). |
| 3 weekly_plan_snapshots + day_dayparts | A locked plan per (location, week) for every historical week + current; per-(day,period) child rows carry the cycle per-daypart **band** targets — the Item-5 dependency. Existing in-force Downtown snapshot preserved via `(restaurant_id, week_key)` guard (Promise 2). |
| 4 wage cold-boot | Wired the EXISTING `_seedDemoWageRoleRows` + `_seedDemoScopeOverrideWageRows` into `_onCreate` (before the cycle build, mirroring the reseed order). Per-location wage story unchanged — it was already correct by HP #11 design; only the cold-boot wiring was missing. |
| 5 app_notifications | A modest deterministic 4-item sample inbox per (operator, location) using recognized catalog/legacy keys; + variance-breach now also seeded on cold-boot. Disjoint from `type='variance_breach'`. |

**Reconciled deviation from the gap brief (Authority #2 Metric Honesty
> the stale gap list):** the brief listed reservations across "12 history
weeks + current". `reservation_book_snapshots` is the **forward** book
(unseated/upcoming covers). A closed/past service has no live unseated
book; the replay generator carries zero reservation truth for historical
shifts, so deriving 12×7×3×4 historical rows via a fixed ratio would be
a *fabricated phantom metric* — explicitly forbidden by Metric Honesty /
Design Rule 2 and the "iterate cells with source truth, NOT fill every
cell" hard constraint. The pre-existing pinned `getForShift(...,'lunch')
→ null` test confirms the intended honest shape excludes closed cells.
Reservations are therefore seeded forward-only, all 4 locations. Two
pre-existing pins that encoded the *old single-row* world are updated in
lockstep and flagged below as intentional contract updates.

---

## (b) Pattern B — 14-lens self-audit

Worker column filled with file:line; independent re-read column left for
the orchestrator.

| # | Lens | Worker self-audit (file:line) | Independent re-read verdict |
|---|---|---|---|
| 1 | Slice intent — non-sales envelope derives from the existing Slice C shift set, not new constants | Orchestrator `_seedOperationalEnvelopeFromReplay` (`sqlite_database_seed.dart:2261`) calls 4 helpers; all derive from `_envelopeShiftsForLocation` (`:2240`) which returns the raw base replay for Downtown (i==0, byte-identical to `_seedDemoDataFromReplay`) and Slice C's `_scaleShiftForLocation` for i 1..3 — zero re-derivation drift. | |
| 2 | Gap 3 (highest value) — child rows carry generator per-daypart **bands**, not pooled | `_seedHistoricalWeeklyPlanSnapshotsFromReplay` (`:2454`) reads each location's hydrated cycle (`TargetCycleDao.getActiveCycle` + `getDaypartsForCycle`), and each child row's `requiredFohHours = covers / cycleDp.targetCPLH`, `forecastSales = covers × cycleDp.targetPPA` per `cycle.daypartFor(period)` — never `cycle.targetCPLH` (pool). Proof test asserts `covers/reqFoh ≈ dp.targetCPLH` and `sales/covers ≈ dp.targetPPA` per period (see (c)). | |
| 3 | HP #2 — production tables only, no `demo_*`, no `kDemoMode` reader branch | Writes only `open_shift_snapshots`/`reservation_book_snapshots`/`weekly_plan_snapshots`/`weekly_plan_snapshot_day_dayparts`/`app_notifications` (all production, schema `:240-487`). No new table; the only `kDemoMode` symbol in the file is the pre-existing `_kDemoModeWriterSwitch` (untouched). No repository/widget/service diff. | |
| 4 | HP #4 — per-(operator,location) isolation | Every insert is keyed to a single `DemoScope.locations[i].restaurantId`; loops never cross-write. Envelope test asserts `DISTINCT restaurant_id` == the 4 demo ids for every new table. | |
| 5 | Metric Honesty / Design Rule 2 — honest-degrade, no phantom rows | Reservations skip `s.status=='closed'` and `unseatedCovers<=0` (`:2378` body); weekly-plan child skips `covers<=0` (`:2454` body); open-shift historical only emits `status=='closed'` rows. Reservations forward-only (rationale above). Test asserts no reservation row predates the scenario date + closed Fri-lunch has none. | |
| 6 | Promise 2 — closed truth not rewritten | Closed open-shift snapshot copies the closed shift's own covers/PPA/CPLH/SPLH/hours/wage (`snapFor`, `:2288`). Weekly-plan `(restaurant_id, week_key)` existence guard (`:2454` body) → in-force Downtown snapshot + any prior locked week preserved unchanged. Test: same-week advance leaves in-force `generated_at` unchanged + total count stable. | |
| 7 | Determinism / NO RNG | All values pure functions of the deterministic replay; every timestamp business-date-derived literal (`${bd}T23:59:00.000Z`, `${weekEnd}T23:59:00.000Z`, `${bd}T13:00:00.000Z`) — never `DateTime.now()`. Stable sort before child emit (`:2454` body). Envelope determinism test reseeds twice → byte-identical (excluding the AUTOINCREMENT `id` surrogate + pre-existing-seeder now()-stamped `generated_at/locked_at/created_at`, documented in-test). | |
| 8 | Idempotency across cold-boot / advance / reseedDemo | open/reservation use `ConflictAlgorithm.replace` (table cleared each `reseedMockReplayForBusinessDate`); weekly-plan existence-guarded + deterministic `snapshot_id` + delete-child-by-snapshot_id; notifications `ConflictAlgorithm.ignore` on `UNIQUE(restaurant_id,event_key)` + deterministic `event_key`. Envelope + cold-boot tests assert stability. | |
| 9 | Concurrency — sibling Item-5 worker (`lib/screens/shift_dashboard.dart`) untouched | `git diff --stat`: only `sqlite_database*.dart` + 4 test files. No `lib/screens/**`. The `weekly_plan_snapshot_day_dayparts` child rows (its dependency) are seeded with the cycle bands. | |
| 10 | Production path unchanged | New seeders are demo-`restaurant_id`-scoped, invoked only from `_onCreate` / `reseedMockReplayForBusinessDate`. No proxy/sync/repository/reader altered; readers (`OpenShiftSnapshotDao`/`ReservationBookSnapshotDao`/`WeeklyPlanSnapshotDao`) query by precise scope and are unmodified. | |
| 11 | `getLatestOpenWeekId` ordering safe | Historical open-shift `updated_at` is a past business-date literal, strictly older than the existing seeder's `nowIsoUtc()` current-week rows → `updated_at DESC, week_id DESC` still resolves the live week first; the singular `status='open'` row stays Downtown's. Envelope test asserts exactly one global `open` row == Downtown. | |
| 12 | Notifications render true-to-logic | `type` ∈ {`notif.backfill.complete`,`notif.plan.updated`,`cycle_rollover`,`notif.vendor.now_available`} — all recognized by `notifications_screen.dart` `_presentationKeyFor`/`_accentFor`/`_iconFor` (catalog `notification_event_catalog.dart:90` + legacy map `:356`). Varied read/unread; training-tone copy (UX Writing Standard). Disjoint from `variance_breach`. | |
| 13 | dart analyze | `dart analyze` on all touched lib + test files → **"No issues found!"** | |
| 14 | Tests green (new + at-risk pins); pre-existing failures snapshot-baselined | New: envelope 6/6 + cold-boot-wage 1/1 green. Updated superseded pins green: `mock_replay_scenario` reservation pin, `shift_dashboard_notifier_cold_boot` same-week pin. Pre-existing master failures (baselined identical on `origin/master`, NOT regressions): `mock_replay_scenario` "benchmark_selection_summaries survive replay advance" (×1); `persistence_scope_alignment` groups K+L (×8); `current_state_alignment` B "getShiftDashboard null" + J1b (×2, byte-identical Expected/Actual on both). | |

**Pre-existing failure baseline (per Audit Baseline Test Snapshot
discipline):** each failing test above was re-run on a fresh
`origin/master` worktree and fails identically (same names, same
Expected/Actual). They are expected, not introduced by this slice.

**Intentional superseded-contract updates (flagged for operator):**

1. `mock_replay_scenario_test.dart` — `reservation snapshot follows
   scenario date/daypart` previously asserted `res.length == 1` (the
   whole table). The forward multi-location book makes that the wrong
   contract; rewritten to assert the scenario open-shift row resolves
   exactly + the book is multi-location forward-only.
2. `shift_dashboard_notifier_cold_boot_test.dart` — `cold-boot snapshot
   survives the same-week replay-advance contract` previously asserted
   Downtown `weekly_plan_snapshots.length == 1`. Gap 3 intentionally
   seeds historical depth; rewritten to assert the **in-force** snapshot
   (by `week_key`) is immutable across same-week advance and no locked
   row is rewritten (the test's real contract).

---

## (c) Proof: `weekly_plan_snapshot_day_dayparts` carries the
generator per-daypart bands (the Item-5 dependency)

`_seedHistoricalWeeklyPlanSnapshotsFromReplay`
(`sqlite_database_seed.dart:2454`) builds each child row from
`cycleDp = cycle.daypartFor(s.daypart)` where `cycle` is the location's
active `TargetCycle` hydrated via `TargetCycleDao.getDaypartsForCycle`.
Those per-period rows were built by `_buildDemoSeedCycle` /
`_buildLocationSeedCycle` from
`MockIntegrationReplaySeed.demoDaypartTargetBand`
(lunch CPLH 4.40 / dinner 4.80 / late_night 3.90, etc.) or the
recommendation cohort over the band-stamped closed shifts — i.e. the
differentiated per-daypart bands, **never** the whole-day pool
`cycle.targetCPLH`.

Child math (`:2454` body):
`forecast_sales = covers × cycleDp.targetPPA`,
`required_foh_hours = covers / cycleDp.targetCPLH`,
`required_boh_hours = sales / cycleDp.targetSPLH`,
`theoretical_*_dollars = required_*_hours × cycle.<bucket>Wage`
(Design Rule 5 — per-period hours × whole-day wage).

Guarded by
`per_daypart_v1_demo_seed_multilocation_operational_envelope_test.dart`
→ "weekly_plan_snapshot_day_dayparts — child rows carry the cycle
per-daypart band targets": for every location, every child row,
`covers / required_foh_hours ≈ cycle.daypartFor(period).targetCPLH`
(±1e-6) and `sales / covers ≈ targetPPA`, AND
`lunch.targetCPLH != dinner.targetCPLH` (differentiated, not pooled).
The cold-boot-wage test additionally asserts these child rows exist on a
true fresh-file `_onCreate` (no reseed) — Item 5 reads real per-daypart
numbers on first launch.

---

## Verification commands run (CI dark — local only, disclosed honestly)

- `flutter pub get` → Got dependencies.
- `dart analyze <all touched lib + test files>` → **No issues found!**
- `flutter test` new suites → envelope **+6 All passed**, cold-boot-wage
  **+1 All passed**.
- `flutter test` at-risk pins → `mock_replay_scenario` (updated pin
  green; 1 pre-existing fail baselined), `reservation_book_snapshot_repository`,
  `per_daypart_v1_slice3_demo_seed_snapshot`,
  `per_daypart_v1_demo_seed_per_location_data`,
  `per_daypart_v1_demo_slice_f_hp11_overrides_notifications`,
  `per_daypart_v1_demo_seed_per_period_cycle`, `demo_slice_b_driver_variance`,
  `shift_dashboard_notifier_cold_boot` (updated pin green) — all green
  except the snapshot-baselined pre-existing master failures listed in
  Lens 14.
- No `db/migrations/*.sql` change → migration drift/cutoff lints N/A.

**STOP after PR opens. Seed-touching, high-blast-radius — flag for
operator review before merge.**
