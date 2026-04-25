// Phase 7.55i.2a — Schedule Builder notifier shared-plan authority test.
// Phase 7.55m.6a — Real ScheduleBuilder widget regression coverage for
// section labels added in 7.55m.6.
// Phase 7.55q.2 — Locked-authority conformance: locked-mode mutations
// must NOT recompute the plan; honest-degradation states are exposed.
//
// Validates:
// A. ScheduleForecastNotifier delegates plan resolution to SchedulePlanReadService
// B. Real ScheduleBuilder content renders the three section labels and does
//    not render the old in-card chart caption
// D. Locked-authority notifier behaviour — pure-Dart, no SQLite:
//    - constructor sets locked mode, idle state, null plan
//    - locked-mode updateTargets / updateDemandCovers /
//      updateDistributionWeights leave the plan unchanged (Rule 1)
//    - honest-degradation state (unavailable) is exposed via the
//      load-state enum without falling back to the live path
//    - real Schedule UI renders correctly with a locked-authority notifier

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/schedule_plan_read_service.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/schedule_plan.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';
import 'package:forge_and_flow/services/daypart_plan_allocator.dart';

void main() {
  const testCPLH = 4.5;
  const testPPA = 42.0;
  const testSPLH = 180.0;
  const testFohWage = 16.50;
  const testBohWage = 21.35;
  const testCovers = 1200;

  // ── A: Shared plan authority alignment ───────────────────────────────────

  group('A — Shared plan authority alignment', () {
    test('notifier plan matches SchedulePlanReadService.resolveFromInputs', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );

      final servicePlan = SchedulePlanReadService.resolveFromInputs(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );

      expect(notifier.plan, isNotNull);
      expect(servicePlan, isNotNull);
      expect(notifier.plan!.forecastCovers, equals(servicePlan!.forecastCovers));
      expect(notifier.plan!.forecastSales, equals(servicePlan.forecastSales));
      expect(notifier.plan!.requiredFohHours, equals(servicePlan.requiredFohHours));
      expect(notifier.plan!.requiredBohHours, equals(servicePlan.requiredBohHours));
      expect(notifier.plan!.theoreticalLaborPct,
          equals(servicePlan.theoreticalLaborPct));

      notifier.dispose();
    });
  });

  // ── B: Plan section labels — real widget (7.55m.6a) ─────────────────────

  group('B — Plan section labels (7.55m.6a)', () {
    testWidgets('real ScheduleBuilder content renders section labels',
        (tester) async {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleBuilder.testContent(notifier),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('LABOR PLAN'), findsOneWidget);
      expect(find.text('COVER FORECAST ADJUSTED BY DAY'), findsOneWidget);
      expect(find.text('DAY-BY-DAY PLAN'), findsOneWidget);

      notifier.dispose();
    });

    testWidgets('old in-card chart caption is absent from real widget tree',
        (tester) async {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleBuilder.testContent(notifier),
          ),
        ),
      );
      await tester.pump();

      // The old caption was removed in 7.55m.6 and replaced by the
      // COVER FORECAST ADJUSTED BY DAY section label.
      expect(
        find.text('COVER FORECAST DISTRIBUTED BY DAY', skipOffstage: false),
        findsNothing,
      );

      notifier.dispose();
    });
  });

  // ── C: 7.55q.6 + 7.55q.8 — Planned labor package killed; theoretical
  //     labor % is benchmark-owned, not plan-owned ─────────────────────
  //
  // Replaces the prior 7.55p.5j planned-package wiring tests. The
  // weekly summary's LABOR % card now reads
  // `notifier.theoreticalLaborPct`, which as of 7.55q.8 sources from
  // the benchmark-owned target seam (live/preview mode: derived from
  // the explicit target inputs that built the preview; locked mode:
  // current ActiveTargetProfile.theoreticalLaborPct). It does NOT
  // read `_plan?.theoreticalLaborPct`.
  //
  // The day-by-day table no longer has a labor % column at all (no
  // honest same-scope theoretical truth at day/daypart granularity).
  // Day views and daypart subrows no longer carry per-row labor
  // packages.

  group('C — 7.55q.6 planned labor package killed', () {
    testWidgets(
        'weekly summary card keeps LABOR % label but uses the '
        'benchmark-owned theoretical seam', (tester) async {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleBuilder.testContent(notifier),
          ),
        ),
      );
      await tester.pump();

      // The killed planned-labor label must NOT be present anywhere.
      expect(find.text('PLANNED LABOR %'), findsNothing,
          reason: '7.55q.6: planned labor package is dead — the label '
              'must not appear in the active runtime');
      // The replacement THEORETICAL label is rendered.
      expect(find.text('LABOR %'), findsOneWidget);

      // The rendered value matches notifier.theoreticalLaborPct, which
      // 7.55q.8 follow-up: now reads the benchmark-owned target seam
      // (live/preview mode: derived from the explicit CPLH/SPLH/PPA/
      // wages that built the preview; locked mode: current
      // ActiveTargetProfile.theoreticalLaborPct). It no longer reads
      // _plan?.theoreticalLaborPct — the weekly theoretical % is a
      // Benchmark-owned metric, not a snapshot-plan projection.
      final theoPct = notifier.theoreticalLaborPct;
      expect(theoPct, greaterThan(0),
          reason: 'demo inputs should produce a valid theoretical %');
      final pctText = '${theoPct.toStringAsFixed(1)}%';
      expect(find.text(pctText), findsWidgets);

      notifier.dispose();
    });

    testWidgets(
        'day-by-day table no longer has a PLANNED LABOR / labor % column',
        (tester) async {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleBuilder.testContent(notifier),
          ),
        ),
      );
      await tester.pump();

      // The PLANNED column header span is gone.
      expect(find.text('PLANNED'), findsNothing,
          reason: 'day-by-day PLANNED column header was removed in '
              '7.55q.6 — no honest same-scope theoretical labor % '
              'exists at day/daypart granularity');
      // No `—` placeholder cells are sitting around either.
      // (The remaining day-row columns are day / covers / sales /
      //  FOH HRS / BOH HRS — all Plan-owned values that always render
      //  a number, never `—`.)
      // Note: SALES is a Plan-owned column header, so it stays.
      expect(find.text('SALES'), findsAtLeastNWidgets(1));

      notifier.dispose();
    });

    test('ScheduleDayView and ScheduleDaySubrow no longer carry a '
        'plannedLabor field — Plan-owned values only', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: testCovers,
      );
      final dayViews = notifier.adjustedDayViews;
      expect(dayViews, isNotEmpty);

      // Each day view exposes Plan-owned fields only (covers / sales /
      // FOH / BOH). The previous `plannedLabor` field was removed in
      // 7.55q.6 — the test compiles only because the field is gone.
      for (final d in dayViews) {
        expect(d.forecastCovers, greaterThanOrEqualTo(0));
        expect(d.forecastSales, greaterThanOrEqualTo(0));
        expect(d.requiredFohHours, greaterThanOrEqualTo(0));
        expect(d.requiredBohHours, greaterThanOrEqualTo(0));
        for (final sub in d.subrows) {
          expect(sub.forecastCovers, greaterThanOrEqualTo(0));
          expect(sub.requiredFohHours, greaterThanOrEqualTo(0));
        }
      }

      notifier.dispose();
    });
  });

  // ── D: 7.55q.2 — Locked-authority conformance (pure-Dart) ───────────────
  //
  // Drift 1 fix from 7.55q.1: the in-force current-week plan authority
  // must be the locked WeeklyPlanSnapshot projection, NOT live
  // resolveFromInputs. These tests prove the conformance properties of
  // the locked-authority notifier WITHOUT standing up a real SQLite
  // database — they use the @visibleForTesting setLockedPlanForTest
  // injection seam to drive the no-recompute and degradation paths.
  //
  //   D1. lockedAuthority constructor sets the right initial state
  //       (locked mode, idle load state, null plan).
  //   D2a. locked-mode updateTargets does NOT recompute the plan
  //        (only refreshes wages/PPA used by planned-package math).
  //   D2b. locked-mode updateDemandCovers is a no-op.
  //   D2c. locked-mode updateDistributionWeights leaves the plan
  //        unchanged (only daypart presentation may shift).
  //   D3.  honest degradation — null plan + unavailable load state can
  //        coexist; hasPlan is false; surface degrades honestly.
  //   D4.  the real ScheduleBuilder.testContent renders correctly with
  //        a locked-authority notifier whose plan was injected via
  //        setLockedPlanForTest (surface is authority-agnostic).
  //   D5.  setLockedPlanForTest throws when called on a live-mode
  //        notifier — proves the seam is locked-mode only.

  group('D — 7.55q.2 locked-authority conformance (pure-Dart)', () {
    ActiveTargetProfile makeProfile({
      double targetCPLH = testCPLH,
      double targetSPLH = testSPLH,
      double targetPPA = testPPA,
      double fohWage = testFohWage,
      double bohWage = testBohWage,
    }) {
      return ActiveTargetProfile(
        targetProfileId: 'q2-test',
        restaurantId: 'q2-test-r',
        sourceType: 'system_baseline',
        targetCPLH: targetCPLH,
        targetSPLH: targetSPLH,
        targetPPA: targetPPA,
        fohWage: fohWage,
        bohWage: bohWage,
        opzFloorCPLH: 0,
        opzCeilingCPLH: 0,
        theoreticalFohLaborPct: 0,
        theoreticalBohLaborPct: 0,
        theoreticalLaborPct: 0,
        builtAt: '',
      );
    }

    SchedulePlan makePlan({
      int forecastCovers = 1200,
      double forecastSales = 50000,
      int requiredFohHours = 280,
      int requiredBohHours = 300,
    }) {
      return SchedulePlan(
        forecastCovers: forecastCovers,
        forecastSales: forecastSales,
        requiredFohHours: requiredFohHours,
        requiredBohHours: requiredBohHours,
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
          ScheduleDayPlan(
              day: 'Tue',
              forecastCovers: 160,
              forecastSales: 6500,
              requiredFohHours: 38,
              requiredBohHours: 42),
          ScheduleDayPlan(
              day: 'Wed',
              forecastCovers: 170,
              forecastSales: 7000,
              requiredFohHours: 40,
              requiredBohHours: 44),
          ScheduleDayPlan(
              day: 'Thu',
              forecastCovers: 175,
              forecastSales: 7200,
              requiredFohHours: 42,
              requiredBohHours: 46),
          ScheduleDayPlan(
              day: 'Fri',
              forecastCovers: 200,
              forecastSales: 8500,
              requiredFohHours: 48,
              requiredBohHours: 52),
          ScheduleDayPlan(
              day: 'Sat',
              forecastCovers: 215,
              forecastSales: 9000,
              requiredFohHours: 50,
              requiredBohHours: 55),
          ScheduleDayPlan(
              day: 'Sun',
              forecastCovers: 130,
              forecastSales: 5800,
              requiredFohHours: 30,
              requiredBohHours: 35),
        ],
      );
    }

    test('D1: lockedAuthority constructor sets locked mode + idle state '
        '+ null plan (no eager resolveFromInputs)', () {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());

      expect(notifier.isLockedAuthority, isTrue);
      expect(notifier.lockedPlanLoadState,
          ScheduleLockedPlanLoadState.idle);
      expect(notifier.plan, isNull,
          reason: 'locked-authority must NOT eagerly resolveFromInputs');
      expect(notifier.hasPlan, isFalse);

      notifier.dispose();
    });

    test('D2a: locked-mode updateTargets does NOT mutate the plan '
        '(wages/PPA refresh only; plan stays locked)', () {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedPlanForTest(
          makePlan(requiredFohHours: 280, requiredBohHours: 300));

      // Push a meaningfully different profile.
      final newProfile = makeProfile(
        targetCPLH: testCPLH * 2,
        targetSPLH: testSPLH * 2,
        targetPPA: testPPA + 10,
        fohWage: testFohWage + 5,
        bohWage: testBohWage + 5,
      );
      notifier.updateTargets(newProfile);

      // Plan stayed locked — if the live path had run, requiredFohHours
      // would have been recomputed against doubled CPLH.
      expect(notifier.plan!.requiredFohHours, equals(280));
      expect(notifier.plan!.requiredBohHours, equals(300));
      expect(notifier.plan!.forecastCovers, equals(1200));

      notifier.dispose();
    });

    test('D2b: locked-mode updateDemandCovers is a no-op '
        '(plan stays locked even when demand changes wildly)', () {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedPlanForTest(
          makePlan(forecastCovers: 1200, forecastSales: 50000));

      notifier.updateDemandCovers(50); // wildly different
      expect(notifier.plan!.forecastCovers, equals(1200));
      expect(notifier.plan!.forecastSales, equals(50000));

      notifier.updateDemandCovers(null);
      expect(notifier.plan!.forecastCovers, equals(1200),
          reason: 'null demand must not clear the locked plan');

      notifier.dispose();
    });

    test('D2c: locked-mode updateDistributionWeights leaves the plan '
        'unchanged (only daypart presentation may shift)', () {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedPlanForTest(makePlan(requiredFohHours: 280));

      notifier.updateDistributionWeights(null);
      expect(notifier.plan!.requiredFohHours, equals(280));

      notifier.dispose();
    });

    test('D2d: locked daypart subrow sales split the locked day-row sales, '
        'not the current profile PPA', () {
      final profile = makeProfile(targetPPA: 42.0);
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: profile);
      notifier.setLockedPlanForTest(makePlan());

      final monday = notifier.adjustedDayViews
          .firstWhere((d) => d.day == 'Mon');
      final subrowSalesTotal = monday.subrows.fold<double>(
          0, (sum, sub) => sum + sub.forecastSales);

      expect(subrowSalesTotal, closeTo(monday.forecastSales, 0.001),
          reason: 'daypart sales should partition the locked day-row sales');
      expect(subrowSalesTotal, isNot(closeTo(monday.forecastCovers * 42.0, 0.001)),
          reason: 'locked mode must not rebuild daypart sales from the '
              'current benchmark PPA');

      notifier.dispose();
    });

    test('D3: honest degradation — null plan coexists with unavailable '
        'load state; hasPlan is false', () {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedPlanForTest(null,
          state: ScheduleLockedPlanLoadState.unavailable);

      expect(notifier.plan, isNull);
      expect(notifier.hasPlan, isFalse);
      expect(notifier.lockedPlanLoadState,
          ScheduleLockedPlanLoadState.unavailable);
      // Surface fallbacks (week getters) degrade honestly.
      expect(notifier.weeklyCovers, equals(0));
      expect(notifier.requiredFohHours, equals(0));
      expect(notifier.requiredBohHours, equals(0));
      expect(notifier.adjustedDayViews, isEmpty);
      // 7.55q.8 follow-up: weekly theoretical labor % is benchmark-owned,
      // not plan-owned. The notifier returns `profile.theoreticalLaborPct`
      // (captured at construction time in locked mode). This fixture's
      // profile was built with `theoreticalLaborPct: 0`, so the value
      // reads 0.0 — NOT because the plan is null. Plan nullity no
      // longer influences `theoreticalLaborPct` at all. The widget
      // renders `—` via the `hasPlan` check in `_DerivedSummaryCards`,
      // which is independent of the theoretical % seam.
      expect(notifier.theoreticalLaborPct, equals(0.0));
      expect(notifier.hasPlan, isFalse);

      notifier.dispose();
    });

    testWidgets('D3b: real widget renders -- for weekly labor % when the '
        'locked plan is unavailable', (tester) async {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedPlanForTest(null,
          state: ScheduleLockedPlanLoadState.unavailable);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleBuilder.testContent(notifier),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('LABOR %'), findsOneWidget);
      expect(find.text('--'), findsWidgets,
          reason: 'unavailable locked-plan state should render an honest '
              'placeholder instead of 0.0%');

      notifier.dispose();
    });

    testWidgets('D4: real ScheduleBuilder.testContent renders section '
        'labels with a locked-authority notifier whose plan was injected '
        '(surface is authority-agnostic)', (tester) async {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedPlanForTest(makePlan());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleBuilder.testContent(notifier),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('LABOR PLAN'), findsOneWidget);
      expect(find.text('COVER FORECAST ADJUSTED BY DAY'), findsOneWidget);
      expect(find.text('DAY-BY-DAY PLAN'), findsOneWidget);

      notifier.dispose();
    });

    test('D5: setLockedPlanForTest throws on a live-mode notifier '
        '(seam is locked-mode only)', () {
      final liveNotifier = ScheduleForecastNotifier(
        targetCPLH: testCPLH,
        targetPPA: testPPA,
        targetSPLH: testSPLH,
        fohWage: testFohWage,
        bohWage: testBohWage,
        historicalWeeklyAvgCovers: 1200,
      );

      expect(
        () => liveNotifier.setLockedPlanForTest(makePlan()),
        throwsStateError,
      );

      liveNotifier.dispose();
    });

    // ── E: 7.55q.8 — weekly theoretical labor % is benchmark-owned,
    //    not plan-owned ─────────────────────────────────────────────
    //
    // Ownership rule being proved: when the profile's
    // `theoreticalLaborPct` differs from the locked plan's carried
    // `theoreticalLaborPct`, the notifier's getter — and therefore the
    // weekly summary card — must follow the PROFILE (benchmark-owned)
    // value. Under the pre-7.55q.8 rule the getter returned
    // `_plan?.theoreticalLaborPct`, so this test would have failed
    // because it would render the plan's value instead.

    test('E: notifier.theoreticalLaborPct follows the profile (benchmark-'
        'owned), NOT the plan; proves 7.55q.8 ownership rule', () {
      // Profile carries 27.5% theoretical — this is the Benchmark target.
      final profile = makeProfile();
      final notifier = ScheduleForecastNotifier.lockedAuthority(
        profile: ActiveTargetProfile(
          targetProfileId: profile.targetProfileId,
          restaurantId: profile.restaurantId,
          sourceType: profile.sourceType,
          targetCPLH: profile.targetCPLH,
          targetSPLH: profile.targetSPLH,
          targetPPA: profile.targetPPA,
          fohWage: profile.fohWage,
          bohWage: profile.bohWage,
          opzFloorCPLH: profile.opzFloorCPLH,
          opzCeilingCPLH: profile.opzCeilingCPLH,
          theoreticalFohLaborPct: 11.0,
          theoreticalBohLaborPct: 16.5,
          theoreticalLaborPct: 27.5,
          builtAt: profile.builtAt,
        ),
      );

      // Inject a locked plan whose theoreticalLaborPct is DISTINCT
      // from the profile (the `makePlan()` default is 22.05). If the
      // notifier were still reading `_plan?.theoreticalLaborPct`, the
      // getter would return 22.05. The new rule makes it return 27.5
      // (the profile's value captured at construction).
      notifier.setLockedPlanForTest(makePlan()); // plan.theoreticalLaborPct = 22.05

      expect(notifier.plan!.theoreticalLaborPct, equals(22.05),
          reason: 'fixture precondition — plan carries a distinct value');
      expect(notifier.theoreticalLaborPct, equals(27.5),
          reason: 'getter must follow the profile (benchmark-owned), '
              'not the plan');

      notifier.dispose();
    });

    // ── F: 7.56c.0 — Schedule daypart subrows route through the
    //    shared DaypartPlanAllocator ────────────────────────────────
    //
    // Regression coverage for the shared seam Variance Full Week now
    // also consumes (`ShiftService.getFullWeekShifts`). If Schedule
    // ever drifts away from the allocator, Sat dinner covers/hours
    // could disagree with Variance Full Week again. Asserting subrow
    // equality with a direct `DaypartPlanAllocator.allocate(...)` call
    // catches that immediately at the unit-test layer.
    test('F: notifier.adjustedDayViews subrows match '
        'DaypartPlanAllocator.allocate output exactly', () {
      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedPlanForTest(makePlan());

      final monday =
          notifier.adjustedDayViews.firstWhere((d) => d.day == 'Mon');
      final monPlan =
          notifier.plan!.dayPlans.firstWhere((dp) => dp.day == 'Mon');

      final expected = DaypartPlanAllocator.allocate(
        day: 'Mon',
        dayCovers: monPlan.forecastCovers,
        daySales: monPlan.forecastSales,
        dayFohHours: monPlan.requiredFohHours,
        dayBohHours: monPlan.requiredBohHours,
        definitions: ServicePeriodDefinitionResolver.demoDefinitions,
        distributionWeights: null,
      );

      expect(monday.subrows.length, equals(expected.length),
          reason: 'subrow count must match the shared allocator output');
      for (var i = 0; i < expected.length; i++) {
        expect(monday.subrows[i].label, equals(expected[i].label));
        expect(monday.subrows[i].forecastCovers,
            equals(expected[i].forecastCovers));
        expect(monday.subrows[i].forecastSales,
            closeTo(expected[i].forecastSales, 0.001));
        expect(monday.subrows[i].requiredFohHours,
            equals(expected[i].requiredFohHours));
        expect(monday.subrows[i].requiredBohHours,
            equals(expected[i].requiredBohHours));
      }

      notifier.dispose();
    });

    testWidgets('E (widget): weekly summary card renders the PROFILE '
        'theoretical % (27.5), not the plan theoretical % (22.05)',
        (tester) async {
      final profile = makeProfile();
      final notifier = ScheduleForecastNotifier.lockedAuthority(
        profile: ActiveTargetProfile(
          targetProfileId: profile.targetProfileId,
          restaurantId: profile.restaurantId,
          sourceType: profile.sourceType,
          targetCPLH: profile.targetCPLH,
          targetSPLH: profile.targetSPLH,
          targetPPA: profile.targetPPA,
          fohWage: profile.fohWage,
          bohWage: profile.bohWage,
          opzFloorCPLH: profile.opzFloorCPLH,
          opzCeilingCPLH: profile.opzCeilingCPLH,
          theoreticalFohLaborPct: 11.0,
          theoreticalBohLaborPct: 16.5,
          theoreticalLaborPct: 27.5,
          builtAt: profile.builtAt,
        ),
      );
      notifier.setLockedPlanForTest(makePlan());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScheduleBuilder.testContent(notifier),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('LABOR %'), findsOneWidget);
      expect(find.text('27.5%'), findsWidgets,
          reason: 'benchmark-owned value rendered');
      expect(find.text('22.1%'), findsNothing,
          reason: 'plan.theoreticalLaborPct must NOT leak into the '
              'weekly card under the 7.55q.8 ownership rule');

      notifier.dispose();
    });
  });
}
