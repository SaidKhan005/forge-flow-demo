// Per-Daypart Targets V1 — Slice 3: Plan tab persistence wiring.
//
// Proves the four Slice 3 properties named in the prompt:
//
//   1. Reader-swap correctness — when the locked snapshot carries
//      persisted `weekly_plan_snapshot_day_dayparts` rows,
//      `ScheduleForecastNotifier.adjustedDayViews` READS those rows
//      (lock-time-stamped values) instead of regenerating them via the
//      retired `DaypartPlanAllocator` (plan Gap 6 / Gap 12, Design
//      Rule 4).
//   2. Allocator-retirement behavior — the persisted read produces the
//      stamped values, NOT the allocator's largest-remainder split, so
//      the two are observably different and the persisted one wins.
//   3. Sentinel removal — `_bootstrapFallbackProfile()` no longer
//      carries `0`-as-null sentinels (Gap 41 / Design Rule 2); it
//      seeds honest `MeridianConfig` config defaults.
//   4. Empty-`dayDayparts` fallback — a locked snapshot with no
//      persisted per-period rows (legacy / Gap 42) degrades back to
//      the allocator so the Plan tab still renders honest sub-rows.
//
// Design Rule 2 (missing = null, never 0) is also checked: a genuine
// zero-hour persisted period stays an honest 0 and is not treated as
// "missing".

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/schedule_plan.dart';
import 'package:forge_and_flow/domain/models/weekly_plan_snapshot.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';
// ignore: deprecated_member_use_from_same_package
import 'package:forge_and_flow/services/daypart_plan_allocator.dart';

void main() {
  // Bootstrap profile used by the locked-authority constructor in
  // these tests. Per-period sub-rows are read from the injected
  // snapshot, not this profile, so its scalar fields are immaterial.
  ActiveTargetProfile makeProfile() => const ActiveTargetProfile(
        targetProfileId: 's3-test',
        restaurantId: 's3-test-r',
        sourceType: 'system_baseline',
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 42.0,
        fohWage: 16.5,
        bohWage: 21.35,
        opzFloorCPLH: 3.5,
        opzCeilingCPLH: 5.8,
        theoreticalFohLaborPct: 8.7,
        theoreticalBohLaborPct: 11.9,
        theoreticalLaborPct: 20.6,
        builtAt: '',
      );

  // A locked snapshot whose Monday business date carries two persisted
  // per-period rows whose covers/sales/hours are deliberately NOT the
  // allocator's largest-remainder split of the day total, so a passing
  // reader-swap test can only be reading the persisted rows.
  WeeklyPlanSnapshot makeSnapshot({
    List<WeeklyPlanSnapshotDayDaypart> dayDayparts = const [],
  }) {
    return WeeklyPlanSnapshot(
      snapshotId: 's3-snap',
      restaurantId: 's3-test-r',
      weekStartDate: '2026-05-11',
      weekEndDate: '2026-05-17',
      targetCycleId: 's3-cycle',
      forecastCovers: 150,
      forecastSales: 6000,
      requiredFohHours: 35,
      requiredBohHours: 40,
      theoreticalFohLaborDollars: 577.5,
      theoreticalBohLaborDollars: 854.0,
      coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      salesSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      generatedAt: '2026-05-11T00:00:00.000Z',
      lockedAt: '2026-05-11T00:00:00.000Z',
      dayRows: const [
        WeeklyPlanSnapshotDay(
          day: 'Mon',
          businessDate: '2026-05-11',
          forecastCovers: 150,
          forecastSales: 6000,
          requiredFohHours: 35,
          requiredBohHours: 40,
        ),
      ],
      dayDayparts: dayDayparts,
    );
  }

  // Persisted Monday rows. Lunch + dinner cover to 150 / sales to 6000
  // / FOH to 35 / BOH to 40 (so the whole-day row reconciles), but the
  // SPLIT is intentionally lopsided (lunch tiny, dinner large) — the
  // allocator's built-in 45/40/15 lunch/dinner/late_night proportions
  // would never produce this, which is exactly the point.
  const persistedMon = <WeeklyPlanSnapshotDayDaypart>[
    WeeklyPlanSnapshotDayDaypart(
      businessDate: '2026-05-11',
      servicePeriodId: 'lunch',
      forecastCovers: 10,
      forecastSales: 400,
      requiredFohHours: 3,
      requiredBohHours: 2,
      theoreticalFohDollars: 49.5,
      theoreticalBohDollars: 42.7,
    ),
    WeeklyPlanSnapshotDayDaypart(
      businessDate: '2026-05-11',
      servicePeriodId: 'dinner',
      forecastCovers: 140,
      forecastSales: 5600,
      requiredFohHours: 32,
      requiredBohHours: 38,
      theoreticalFohDollars: 528.0,
      theoreticalBohDollars: 811.3,
    ),
  ];

  group('Slice 3 — Plan tab persistence wiring', () {
    test(
        'reader-swap: adjustedDayViews reads the persisted day_dayparts '
        'rows, not the allocator regeneration', () {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedSnapshotForTest(
          makeSnapshot(dayDayparts: persistedMon));

      final mon =
          notifier.adjustedDayViews.firstWhere((d) => d.day == 'Mon');

      // Sub-rows are the persisted rows, ordered by service-period sort
      // order (lunch then dinner), labelled via the active definitions.
      expect(mon.subrows.length, 2);
      expect(mon.subrows[0].label,
          ServicePeriodDefinitionResolver.labelForId(
              ServicePeriodDefinitionResolver.demoDefinitions, 'lunch'));
      expect(mon.subrows[0].forecastCovers, 10);
      expect(mon.subrows[0].forecastSales, 400);
      expect(mon.subrows[0].requiredFohHours, 3);
      expect(mon.subrows[0].requiredBohHours, 2);

      expect(mon.subrows[1].label,
          ServicePeriodDefinitionResolver.labelForId(
              ServicePeriodDefinitionResolver.demoDefinitions, 'dinner'));
      expect(mon.subrows[1].forecastCovers, 140);
      expect(mon.subrows[1].forecastSales, 5600);
      expect(mon.subrows[1].requiredFohHours, 32);
      expect(mon.subrows[1].requiredBohHours, 38);

      // Day-level row still reconciles to the whole-day snapshot values.
      expect(mon.forecastCovers, 150);
      expect(mon.forecastSales, 6000);

      notifier.dispose();
    });

    test(
        'allocator-retirement: the persisted read produces values the '
        'retired allocator would NOT (lopsided split wins over the '
        'largest-remainder regeneration)', () {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedSnapshotForTest(
          makeSnapshot(dayDayparts: persistedMon));

      final mon =
          notifier.adjustedDayViews.firstWhere((d) => d.day == 'Mon');

      // What the (now retired) allocator WOULD have produced for the
      // same whole-day Monday package. Mon is a weekday so only lunch +
      // dinner apply; the built-in 0.45 / 0.40 weights split 150 covers
      // ~79 / ~71 — nothing like the persisted 10 / 140.
      // ignore: deprecated_member_use_from_same_package
      final allocated = DaypartPlanAllocator.allocate(
        day: 'Mon',
        dayCovers: 150,
        daySales: 6000,
        dayFohHours: 35,
        dayBohHours: 40,
        definitions: ServicePeriodDefinitionResolver.demoDefinitions,
        distributionWeights: null,
      );
      final allocatedLunchCovers = allocated
          .firstWhere((a) => a.daypartId == 'lunch')
          .forecastCovers;

      // The rendered lunch covers come from the persisted row (10), and
      // are observably different from the allocator regeneration.
      expect(mon.subrows[0].forecastCovers, 10);
      expect(mon.subrows[0].forecastCovers,
          isNot(equals(allocatedLunchCovers)),
          reason:
              'locked path must read the lock-time-stamped persisted '
              'row, not regenerate via the retired allocator');

      notifier.dispose();
    });

    test(
        'Design Rule 2: a genuine zero-hour persisted period stays an '
        'honest 0 (missing != 0 — and 0 is not treated as missing)', () {
      const zeroLatePeriod = WeeklyPlanSnapshotDayDaypart(
        businessDate: '2026-05-11',
        servicePeriodId: 'late_night',
        forecastCovers: 0,
        forecastSales: 0,
        requiredFohHours: 0,
        requiredBohHours: 0,
        theoreticalFohDollars: 0,
        theoreticalBohDollars: 0,
      );
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedSnapshotForTest(makeSnapshot(
          dayDayparts: [...persistedMon, zeroLatePeriod]));

      final mon =
          notifier.adjustedDayViews.firstWhere((d) => d.day == 'Mon');

      // The zero-hour late-night row is RENDERED (not dropped as if
      // "missing") and reads an honest 0 — proving 0 is a real value,
      // not a null sentinel.
      expect(mon.subrows.length, 3);
      final late = mon.subrows.firstWhere((s) =>
          s.label ==
          ServicePeriodDefinitionResolver.labelForId(
              ServicePeriodDefinitionResolver.demoDefinitions,
              'late_night'));
      expect(late.forecastCovers, 0);
      expect(late.requiredFohHours, 0);
      expect(late.requiredBohHours, 0);

      notifier.dispose();
    });

    test(
        'empty-dayDayparts fallback: a locked snapshot with no persisted '
        'per-period rows degrades to the allocator', () {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      // Legacy / Gap 42: snapshot loaded, but dayDayparts is empty.
      notifier.setLockedSnapshotForTest(makeSnapshot());

      final mon =
          notifier.adjustedDayViews.firstWhere((d) => d.day == 'Mon');

      // ignore: deprecated_member_use_from_same_package
      final expected = DaypartPlanAllocator.allocate(
        day: 'Mon',
        dayCovers: 150,
        daySales: 6000,
        dayFohHours: 35,
        dayBohHours: 40,
        definitions: ServicePeriodDefinitionResolver.demoDefinitions,
        distributionWeights: null,
      );

      expect(mon.subrows.length, expected.length);
      for (var i = 0; i < expected.length; i++) {
        expect(mon.subrows[i].label, expected[i].label);
        expect(mon.subrows[i].forecastCovers, expected[i].forecastCovers);
        expect(mon.subrows[i].forecastSales,
            closeTo(expected[i].forecastSales, 0.001));
        expect(mon.subrows[i].requiredFohHours,
            expected[i].requiredFohHours);
        expect(mon.subrows[i].requiredBohHours,
            expected[i].requiredBohHours);
      }

      notifier.dispose();
    });

    test(
        'live/preview fallback: setLockedPlanForTest (no snapshot) keeps '
        'the allocator path — back-compat with the pre-Slice-3 seam', () {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      // The legacy plan-only seam injects no snapshot at all.
      notifier.setLockedPlanForTest(_makePlan());

      final mon =
          notifier.adjustedDayViews.firstWhere((d) => d.day == 'Mon');

      // ignore: deprecated_member_use_from_same_package
      final expected = DaypartPlanAllocator.allocate(
        day: 'Mon',
        dayCovers: 150,
        daySales: 6000,
        dayFohHours: 35,
        dayBohHours: 40,
        definitions: ServicePeriodDefinitionResolver.demoDefinitions,
        distributionWeights: null,
      );
      expect(mon.subrows.length, expected.length);
      expect(mon.subrows[0].forecastCovers, expected[0].forecastCovers);

      notifier.dispose();
    });

    test(
        'sentinel removal (Gap 41 / Design Rule 2): bootstrap fallback '
        'profile carries honest MeridianConfig defaults, not 0 sentinels',
        () {
      // The bootstrap profile is the proxy-provider fallback in
      // schedule_builder.dart. Slice 3 replaced its `0 // unused on
      // locked path` sentinels with real config defaults. We assert via
      // the public ActiveTargetProfile surface that none of the
      // previously-sentinelled fields is 0.
      final profile = scheduleBootstrapFallbackProfileForTest();
      expect(profile.targetCPLH, isNonZero);
      expect(profile.targetSPLH, isNonZero);
      expect(profile.opzFloorCPLH, isNonZero);
      expect(profile.opzCeilingCPLH, isNonZero);
      expect(profile.theoreticalFohLaborPct, isNonZero);
      expect(profile.theoreticalBohLaborPct, isNonZero);
      expect(profile.theoreticalLaborPct, isNonZero);
      // Honest config-default magnitudes (MeridianConfig).
      expect(profile.targetCPLH, 4.5);
      expect(profile.targetSPLH, 180.0);
      expect(profile.opzFloorCPLH, 3.5);
      expect(profile.opzCeilingCPLH, 5.8);
      expect(profile.theoreticalLaborPct, 20.6);
    });
  });
}

final Matcher isNonZero = isNot(equals(0));

// Mirrors the existing schedule_builder_widget_test makePlan() shape
// for the live/preview fallback case.
SchedulePlan _makePlan() => SchedulePlan(
      forecastCovers: 1200,
      forecastSales: 50000,
      requiredFohHours: 280,
      requiredBohHours: 300,
      theoreticalFohLaborDollars: 4620,
      theoreticalBohLaborDollars: 6405,
      theoreticalLaborPct: 22.05,
      targetBlendedWage: 19.0,
      coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      salesSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      dayPlans: const [
        ScheduleDayPlan(
            day: 'Mon',
            forecastCovers: 150,
            forecastSales: 6000,
            requiredFohHours: 35,
            requiredBohHours: 40),
      ],
    );
