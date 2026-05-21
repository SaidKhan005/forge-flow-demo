// Phase 7.55o.6 — SQLite demo + mock-replay seed helpers (split index).
//
// Part of sqlite_database.dart. This file was a 3,867-line god-object
// (code_hardening_plan 2026-05-21 §4.4 #3). It has been mechanically
// decomposed by table family into the `seed/` sibling part files listed
// below; every seeder kept its exact name + signature and was moved
// verbatim, so the demo-writer output is byte-for-byte unchanged (HP #2:
// demo data = standard SQLite tables under `DemoScope.restaurantId`;
// demo and prod read the same path). The orchestration that calls these
// seeders lives in `sqlite_database.dart` (`_onCreate` /
// `reseedMockReplayForBusinessDate`) and is untouched.
//
// Family parts (all `part of '../sqlite_database.dart'`):
//   seed/seed_locked_targets.dart          — `_backfillLockedTargets`,
//       `_isNoneConnectedDemoLocation` (shared honest-empty predicate).
//   seed/seed_open_shift_snapshots.dart    — `_buildCurrentWeekOpenShiftSnapshots`,
//       `_seedOpenShiftSnapshotsFromReplay`.
//   seed/seed_weekly_plan_snapshots.dart   — `_seedWeeklyPlanSnapshotFromReplay`,
//       `_buildSeedDayDaypartRows`, `_resolveSeedDemandWeeklyCovers`,
//       `_subtractIsoDays` (shared), `_buildSeedDistributionWeights`.
//   seed/seed_reservation_book.dart        — `_seedReservationBookSnapshotsFromReplay`.
//   seed/seed_restaurant_and_timing.dart   — `_seedDemoRestaurant`,
//       `_seedDemoTimingConfig`, `_demoParseHm`, `resolveDemoOpenPeriod`,
//       `seedTimeOpenPeriodResolution`, the demo service-period consts.
//   seed/seed_target_profile_and_cycle.dart — `_seedDemoActiveTargetProfile`,
//       `_loadSeedAuthorityProfile`, `_ensureDemoSeedCycle`,
//       `_buildDemoSeedDayparts`, `_buildDemoSeedCycle`,
//       `_seedRecommendationCandidates`, `_weightedAvgFromRows`,
//       `_seedDemoWageRoleRows`, `_addIsoDays` (shared).
//   seed/seed_additional_locations.dart    — per-location scaling
//       (`_DemoLocationProfile`, `_scaleShiftForLocation`,
//       `_scaleWeekMapForLocation`, `_buildLocationSeedCycle`,
//       `_seedAdditionalLocationsFromReplay`, `_round2`).
//   seed/seed_replay_entry.dart            — `_seedDemoDataFromReplay`,
//       `_seedDemoVendorIntegrationModeStateSource`, `_deterministicHash`
//       (shared), `_ensureDemoRestaurant`.
//   seed/seed_scope_overrides.dart         — Slice F HP #11 overrides
//       (`_seedDemoScopeOverrideTimingConfig`,
//       `_seedDemoScopeOverrideWageRows`,
//       `_seedDemoScopeOverrideDataAccuracy`).
//   seed/seed_four_period.dart             — R6 four-period proof location
//       (`_seedDemoFourPeriodTimingConfig`,
//       `_seedDemoFourPeriodClosedShifts`).
//   seed/seed_notifications.dart           — `_seedDemoVarianceBreachNotification`,
//       `_businessDateFromWeekId`.
//   seed/seed_operational_envelope.dart    — `_seedOperationalEnvelopeFromReplay`
//       and its per-location snapshot/reservation/weekly-plan/notice
//       seeders.

part of 'sqlite_database.dart';
