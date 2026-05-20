// Baseline Manager screen — REGRESSION suite (R1-R10).
// Covers groups R1, R2, R3, R8, R9, R10 from the original 3,608-line
// monolith: operator-config lens / 2-state filter / pre-commit gate;
// tap-day bottom sheet + whole-day rollup + per-service toggles; band
// + per-period preview; prototype alignment; single continuous scroll
// + PLAN IMPACT dropdown; per-daypart mix-and-match band + scope label
// as header. Split out in Bucket 5b of the 2026-05-20 test-suite
// tightening audit; helpers + fixtures live in
// `baseline_manager_screen_test_helpers.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/database_helper.dart';
import 'package:forge_and_flow/services/demand_forecast_context_service.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_band.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_lens.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_day_sheet.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_calendar.dart';
import 'package:forge_and_flow/services/labor_model.dart';

import '_test_helpers/widget_pump_helpers.dart';
import 'baseline_manager_screen_test_helpers.dart';

void main() {
  int? demandCovers;

  setUp(() async {
    BaselineData.clearManagerOverride();
    BaselineManagerService.instance.serverSelectionWriter = null;
    await DatabaseHelper.instance.reseedDemo();
    await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({});
    final ctx = await DemandForecastContextService.instance.getCurrentContext();
    demandCovers = ctx.historicalWeeklyAvgCovers;
  });

  tearDown(() {
    BaselineManagerService.instance.serverSelectionWriter = null;
  });

  // ── R1 - operator-config lens, 2-state filter, pre-commit gate ────────────

  group('R1 - lens / 2-state filter / pre-commit gate', () {
    const fourPeriodDefs = <ServicePeriodDefinition>[
      ServicePeriodDefinition(
        id: 'breakfast',
        label: 'Breakfast',
        shortLabel: 'B',
        sortOrder: 1,
        startLocalTime: '07:00',
        endLocalTime: '11:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'lunch',
        label: 'Lunch',
        shortLabel: 'L',
        sortOrder: 2,
        startLocalTime: '11:00',
        endLocalTime: '15:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5],
      ),
      ServicePeriodDefinition(
        id: 'dinner',
        label: 'Dinner',
        shortLabel: 'D',
        sortOrder: 3,
        startLocalTime: '17:00',
        endLocalTime: '23:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'late_night',
        label: 'Late Night',
        shortLabel: 'LN',
        sortOrder: 4,
        startLocalTime: '23:00',
        endLocalTime: '02:00',
        rollsPastMidnight: true,
        applicableDays: [5, 6],
      ),
    ];

    testWidgets('a) lens options derive from the configured 4-period config', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
            initialDefs: fourPeriodDefs,
            initialCanOverride: true,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('WHOLE DAY'), findsOneWidget);
      expect(find.text('BREAKFAST'), findsOneWidget);
      expect(find.text('LUNCH'), findsOneWidget);
      expect(find.text('DINNER'), findsOneWidget);
      expect(find.text('LATE NIGHT'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('lens_late_night')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('lens_breakfast')),
        findsOneWidget,
      );
    });

    testWidgets('b) calendar 2-state cell filters by the active lens period', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            withPreSelected,
            initialDemandCovers: demandCovers,
            initialDefs: fourPeriodDefs,
            initialCanOverride: true,
          ),
        ),
      );
      await tester.pump();

      BoxDecoration decoFor(String date) {
        final container = tester.widget<Container>(
          find
              .descendant(
                of: find.byKey(ValueKey<String>('cal_$date')),
                matching: find.byType(Container),
              )
              .first,
        );
        return container.decoration! as BoxDecoration;
      }

      final wholeDayDinnerBorder =
          (decoFor('2026-03-06').border! as Border).top.color;
      expect(wholeDayDinnerBorder, isNot(Colors.transparent));

      await tester.tap(find.byKey(const ValueKey<String>('lens_lunch')));
      await tester.pump();
      final lunchLensDinnerBorder =
          (decoFor('2026-03-06').border! as Border).top.color;
      expect(lunchLensDinnerBorder, Colors.transparent);

      final lunchLensSelected =
          (decoFor('2026-03-16').border! as Border).top.color;
      expect(lunchLensSelected, isNot(Colors.transparent));
    });

    testWidgets('c) pre-commit gate disables commit before any selection', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
            initialDefs: fourPeriodDefs,
            initialCanOverride: false,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('override_used_notice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('done_disabled_gate')),
        findsOneWidget,
      );
      expect(find.text('OVERRIDE USED'), findsOneWidget);
      // R8: the live Done-with-count label is absent when gated.
      expect(doneButton(), findsNothing);
    });

    testWidgets('c) gate open: live commit, no disabled notice', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
            initialDefs: fourPeriodDefs,
            initialCanOverride: true,
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('override_used_notice')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('done_disabled_gate')),
        findsNothing,
      );
      expect(doneButton(), findsOneWidget);
    });
  });

  // ── R2 - tap-day bottom sheet + whole-day rollup + per-service toggles ────
  //
  // (a) period-lens tap opens a bottom sheet (not a route push) with the
  //     6 metrics + a toggle action;
  // (b) whole-day-lens tap shows a cover-weighted rollup whose CPLH
  //     equals the cover-weighted combination of that day's services
  //     (reconciliation assertion) with per-service toggles, for a
  //     4-period operator config;
  // (c) toggling in the sheet mutates the draft set and the calendar
  //     reflects it.

  group('R2 - tap-day bottom sheet + whole-day rollup', () {
    // 4-period config so nothing assumes a fixed 3-daypart shape.
    const fourPeriodDefs = <ServicePeriodDefinition>[
      ServicePeriodDefinition(
        id: 'breakfast',
        label: 'Breakfast',
        shortLabel: 'B',
        sortOrder: 1,
        startLocalTime: '07:00',
        endLocalTime: '11:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'lunch',
        label: 'Lunch',
        shortLabel: 'L',
        sortOrder: 2,
        startLocalTime: '11:00',
        endLocalTime: '15:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'dinner',
        label: 'Dinner',
        shortLabel: 'D',
        sortOrder: 3,
        startLocalTime: '17:00',
        endLocalTime: '23:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'late_night',
        label: 'Late Night',
        shortLabel: 'LN',
        sortOrder: 4,
        startLocalTime: '23:00',
        endLocalTime: '02:00',
        rollsPastMidnight: true,
        applicableDays: [5, 6],
      ),
    ];

    // One day (2026-03-20) with four distinct service shifts so the
    // cover-weighted rollup has a non-trivial denominator.
    const bShift = BaselineCandidateShift(
      recordKey: '2026-W12|Fri|breakfast',
      weekId: '2026-W12',
      weekLabel: 'Week of Mar 17',
      dayLabel: 'Fri',
      daypart: 'breakfast',
      covers: 60,
      cplh: 5.20,
      splh: 120.0,
      ppa: 18.0,
      primaryLeverId: 'cplh_up',
      isSelected: false,
      businessDate: '2026-03-20',
      actualLaborPct: 28.0,
    );
    const lShift = BaselineCandidateShift(
      recordKey: '2026-W12|Fri|lunch',
      weekId: '2026-W12',
      weekLabel: 'Week of Mar 17',
      dayLabel: 'Fri',
      daypart: 'lunch',
      covers: 150,
      cplh: 4.80,
      splh: 185.0,
      ppa: 42.0,
      primaryLeverId: 'cplh_up',
      isSelected: false,
      businessDate: '2026-03-20',
      actualLaborPct: 24.0,
    );
    const dShift = BaselineCandidateShift(
      recordKey: '2026-W12|Fri|dinner',
      weekId: '2026-W12',
      weekLabel: 'Week of Mar 17',
      dayLabel: 'Fri',
      daypart: 'dinner',
      covers: 220,
      cplh: 4.50,
      splh: 200.0,
      ppa: 46.0,
      primaryLeverId: 'cplh_up',
      isSelected: false,
      businessDate: '2026-03-20',
      actualLaborPct: 22.5,
    );
    const lnShift = BaselineCandidateShift(
      recordKey: '2026-W12|Fri|late_night',
      weekId: '2026-W12',
      weekLabel: 'Week of Mar 17',
      dayLabel: 'Fri',
      daypart: 'late_night',
      covers: 70,
      cplh: 3.90,
      splh: 150.0,
      ppa: 35.0,
      primaryLeverId: 'cplh_up',
      isSelected: false,
      businessDate: '2026-03-20',
      actualLaborPct: 30.0,
    );
    const fourServiceDay = [bShift, lShift, dShift, lnShift];

    testWidgets(
      'a) period-lens tap opens a bottom sheet (no route push) with the '
      '6 metrics + toggle',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              fourServiceDay,
              initialDemandCovers: demandCovers,
              initialDefs: fourPeriodDefs,
              initialCanOverride: true,
            ),
          ),
        );
        await tester.pump();

        // No modal route is pushed (the screen's Navigator only has the
        // home route until the sheet opens).
        expect(find.byType(BottomSheet), findsNothing);

        // R8 opens populated; clear so the period sheet shows SELECT.
        await clearAllDraft(tester);
        await tapLensChip(tester, 'dinner');
        await tapCalendarDate(tester, '2026-03-20');

        // showModalBottomSheet overlay, not a full-screen route.
        expect(find.byType(BottomSheet), findsOneWidget);
        final inSheet = find.byType(BottomSheet);
        for (final label in const [
          'CPLH',
          'COVERS',
          'SPLH',
          'PPA',
          'LABOR %',
          'LEVER',
        ]) {
          expect(
            find.descendant(of: inSheet, matching: find.text(label)),
            findsOneWidget,
            reason: '$label metric must render in the period sheet',
          );
        }
        expect(
          find.descendant(of: inSheet, matching: find.text('SELECT')),
          findsOneWidget,
        );
      },
    );

    testWidgets('b) whole-day rollup CPLH reconciles to the cover-weighted '
        'combination of that day\'s 4 services', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            fourServiceDay,
            initialDemandCovers: demandCovers,
            initialDefs: fourPeriodDefs,
            initialCanOverride: true,
          ),
        ),
      );
      await tester.pump();

      // Default lens is whole-day. Tap the 4-service day.
      await tapCalendarDate(tester, '2026-03-20');
      expect(
        find.byKey(const ValueKey<String>('whole_day_rollup_card')),
        findsOneWidget,
      );

      // Reconciliation: the rendered rollup CPLH must equal the
      // cover-weighted combination computed independently here,
      // mirroring TargetCycleDaypartPool.fromDayparts.
      final totalCovers = fourServiceDay.fold<int>(0, (s, c) => s + c.covers);
      double expectedCplh = 0;
      for (final c in fourServiceDay) {
        expectedCplh += c.cplh * (c.covers / totalCovers);
      }
      // Independent rollup model produces the same scalar.
      final rollup = WholeDayRollup.fromShifts(
        fourServiceDay,
        fohWage: MeridianConfig.fohWage,
        bohWage: MeridianConfig.bohWage,
      );
      expect(rollup.cplh, closeTo(expectedCplh, 0.0001));
      expect(rollup.totalCovers, equals(totalCovers));

      // The rendered rollup card shows that same CPLH (2 dp) and the
      // summed covers, proving the UI reconciles to per-service.
      expect(
        find.text(expectedCplh.toStringAsFixed(2), skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.text('$totalCovers', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );

      // Per-service breakdown: one row per configured period present,
      // count + labels from the resolved defs (4 here).
      final inSheet = find.byType(BottomSheet);
      for (final label in const [
        'Breakfast',
        'Lunch',
        'Dinner',
        'Late Night',
      ]) {
        expect(
          find.descendant(of: inSheet, matching: find.text(label)),
          findsOneWidget,
          reason: '$label per-service row must render',
        );
      }
    });

    testWidgets(
      'c) toggling a service in the whole-day sheet mutates the draft '
      'and the calendar reflects it (badge count)',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              fourServiceDay,
              initialDemandCovers: demandCovers,
              initialDefs: fourPeriodDefs,
              initialCanOverride: true,
            ),
          ),
        );
        await tester.pump();

        // R8 opens populated; clear to start from an empty draft.
        await clearAllDraft(tester);

        // Prototype rule: the n/total badge appears only on a SELECTED
        // day. With nothing selected the 4-service day shows no badge.
        expect(
          find.byKey(const ValueKey<String>('cal_badge_2026-03-20')),
          findsNothing,
        );

        await tapCalendarDate(tester, '2026-03-20');
        // Toggle two services; the sheet STAYS open between toggles.
        await toggleWholeDayService(tester, 'Lunch');
        expect(find.byType(BottomSheet), findsOneWidget);
        await toggleWholeDayService(tester, 'Dinner');
        expect(find.byType(BottomSheet), findsOneWidget);

        await closeSheet(tester);

        // Draft mutated: preview count is 2 and the calendar badge moves
        // to 2/4 (selection flowed only through the draft set).
        expectSelectedShiftsCount(tester, '2');
        expect(find.text('2/4'), findsOneWidget);

        // Commit proves the draft set carried the toggled keys.
        final stored = await commitDoneAndReadKeys(tester);
        expect(
          stored,
          containsAll(<String>[lShift.recordKey, dShift.recordKey]),
        );
        expect(stored, isNot(contains(bShift.recordKey)));
        expect(stored, isNot(contains(lnShift.recordKey)));
      },
    );

    test('WholeDayRollup zero-covers fallback uses an unweighted mean '
        '(mirrors TargetCycleDaypartPool)', () {
      const z1 = BaselineCandidateShift(
        recordKey: 'z|Fri|lunch',
        weekId: 'z',
        weekLabel: 'z',
        dayLabel: 'Fri',
        daypart: 'lunch',
        covers: 0,
        cplh: 4.0,
        splh: 100.0,
        ppa: 30.0,
        primaryLeverId: 'cplh_up',
        isSelected: false,
      );
      const z2 = BaselineCandidateShift(
        recordKey: 'z|Fri|dinner',
        weekId: 'z',
        weekLabel: 'z',
        dayLabel: 'Fri',
        daypart: 'dinner',
        covers: 0,
        cplh: 6.0,
        splh: 200.0,
        ppa: 50.0,
        primaryLeverId: 'cplh_up',
        isSelected: false,
      );
      final r = WholeDayRollup.fromShifts(
        [z1, z2],
        fohWage: MeridianConfig.fohWage,
        bohWage: MeridianConfig.bohWage,
      );
      expect(r.totalCovers, equals(0));
      expect(r.cplh, closeTo(5.0, 0.0001)); // (4+6)/2
      expect(r.splh, closeTo(150.0, 0.0001)); // (100+200)/2
      expect(r.ppa, closeTo(40.0, 0.0001)); // (30+50)/2
    });

    test('WholeDayRollup labor % uses the WHOLE-DAY wage on the '
        'cover-weighted rates (display only, no per-period wage)', () {
      final r = WholeDayRollup.fromShifts(
        fourServiceDay,
        fohWage: MeridianConfig.fohWage,
        bohWage: MeridianConfig.bohWage,
      );
      // Labor % is the existing whole-day shape: theoreticalLaborPct
      // of the rolled-up (cover-weighted) rates with the single
      // whole-day wage pair, never a per-period wage.
      expect(
        r.laborPct,
        closeTo(
          LaborModel.theoreticalLaborPct(
            r.cplh,
            r.splh,
            r.ppa,
            MeridianConfig.fohWage,
            MeridianConfig.bohWage,
          ),
          0.0001,
        ),
      );
    });

    test('WholeDayRollup labor % is an honest unknown without wage '
        'authority', () {
      final r = WholeDayRollup.fromShifts(
        fourServiceDay,
        fohWage: null,
        bohWage: null,
      );
      expect(r.laborPct, isNull);
    });
  });

  // ── R3 - Lean/Balanced/Generous band + per-period preview (Gap 40) ───────
  //
  // (a) each band tier derives the expected top-N-per-period recordKey
  //     set for a 4-period config (not a hardcoded 3), and the band only
  //     mutates the draft set (no persistence shape change);
  // (b) per-period preview values reflect the active period lens and use
  //     the period's OWN candidate covers, and the whole-day lens preview
  //     reconciles to the cover-weighted rollup of the per-period pieces;
  // (c) the commit path / saveSelection call shape is unchanged: the band
  //     produces only recordKeys that flow through the existing write.

  group('R3 - band + per-period preview', () {
    // 4-period config so nothing assumes a fixed 3-daypart shape.
    const fourPeriodDefs = <ServicePeriodDefinition>[
      ServicePeriodDefinition(
        id: 'breakfast',
        label: 'Breakfast',
        shortLabel: 'B',
        sortOrder: 1,
        startLocalTime: '07:00',
        endLocalTime: '11:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'lunch',
        label: 'Lunch',
        shortLabel: 'L',
        sortOrder: 2,
        startLocalTime: '11:00',
        endLocalTime: '15:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'dinner',
        label: 'Dinner',
        shortLabel: 'D',
        sortOrder: 3,
        startLocalTime: '17:00',
        endLocalTime: '23:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'late_night',
        label: 'Late Night',
        shortLabel: 'LN',
        sortOrder: 4,
        startLocalTime: '23:00',
        endLocalTime: '02:00',
        rollsPastMidnight: true,
        applicableDays: [5, 6],
      ),
    ];

    // Build a candidate pool with a known CPLH ranking per period so the
    // top-N-by-CPLH selection is fully deterministic. Three shifts in
    // each of the four configured periods (12 total). Higher CPLH = a
    // stronger shift; the band keeps the strongest N per period.
    List<BaselineCandidateShift> poolFor(String period, double base) {
      return List.generate(3, (i) {
        final cplh = base + i; // i=2 strongest, i=0 weakest
        return BaselineCandidateShift(
          recordKey: '$period|r$i',
          weekId: 'W',
          weekLabel: 'W',
          dayLabel: 'Fri',
          daypart: period,
          covers: 100 + i * 10,
          cplh: cplh,
          splh: 150.0 + i,
          ppa: 40.0 + i,
          primaryLeverId: 'cplh_up',
          isSelected: false,
          businessDate: '2026-03-2$i',
          actualLaborPct: 22.0,
        );
      });
    }

    final fourPeriodPool = <BaselineCandidateShift>[
      ...poolFor('breakfast', 5.0),
      ...poolFor('lunch', 4.0),
      ...poolFor('dinner', 4.5),
      ...poolFor('late_night', 3.0),
    ];

    // Window-valid pool: same recordKey / businessDate shape the passing
    // R1/R2 fixtures use, so saveSelection -> TargetCycleService resolves
    // these against the seeded demo 60-day window. Two shifts per period
    // on two valid business dates so the band's top-N-per-period ranking
    // is still exercised end to end through the unchanged write path.
    BaselineCandidateShift winShift(
      String week,
      String day,
      String date,
      String period,
      double cplh,
    ) {
      return BaselineCandidateShift(
        recordKey: '$week|$day|$period',
        weekId: week,
        weekLabel: 'Week of Mar',
        dayLabel: day,
        daypart: period,
        covers: 150,
        cplh: cplh,
        splh: 180.0,
        ppa: 42.0,
        primaryLeverId: 'cplh_up',
        isSelected: false,
        businessDate: date,
        actualLaborPct: 24.0,
      );
    }

    final windowValidPool = <BaselineCandidateShift>[
      for (final period in const [
        'breakfast',
        'lunch',
        'dinner',
        'late_night',
      ]) ...[
        winShift('2026-W12', 'Fri', '2026-03-20', period, 5.0),
        winShift('2026-W12', 'Mon', '2026-03-16', period, 4.0),
      ],
    ];

    Set<String> expectedTopN(int n) {
      final keys = <String>{};
      for (final period in const [
        'breakfast',
        'lunch',
        'dinner',
        'late_night',
      ]) {
        final list = fourPeriodPool.where((c) => c.daypart == period).toList()
          ..sort((a, b) {
            final cmp = b.cplh.compareTo(a.cplh);
            return cmp != 0 ? cmp : a.recordKey.compareTo(b.recordKey);
          });
        for (final c in list.take(n)) {
          keys.add(c.recordKey);
        }
      }
      return keys;
    }

    test('a) each band tier derives top-N-per-period by CPLH for a '
        '4-period config (not a hardcoded 3)', () {
      // Lean keeps the fewest, Generous the most. N is per period and
      // applied across all FOUR configured periods.
      final lean = deriveBandSelection(
        fourPeriodPool,
        fourPeriodDefs,
        StarBand.lean,
      );
      final balanced = deriveBandSelection(
        fourPeriodPool,
        fourPeriodDefs,
        StarBand.balanced,
      );
      final generous = deriveBandSelection(
        fourPeriodPool,
        fourPeriodDefs,
        StarBand.generous,
      );

      // Lean N=2 across 4 periods -> 8 keys, exactly the 2 strongest
      // (highest CPLH) shifts in each period.
      expect(lean.length, equals(StarBand.lean.nPerPeriod * 4));
      expect(lean, equals(expectedTopN(StarBand.lean.nPerPeriod)));
      // The weakest shift in every period (r0) is excluded by Lean.
      for (final period in const [
        'breakfast',
        'lunch',
        'dinner',
        'late_night',
      ]) {
        expect(lean.contains('$period|r0'), isFalse);
        expect(lean.contains('$period|r2'), isTrue); // strongest kept
      }

      // Balanced N=4 but each period only has 3 shifts: take() caps at
      // 3, so all 12 are kept (proves N is a cap, period-scoped, not a
      // hardcoded count).
      expect(balanced.length, equals(12));
      expect(balanced, equals(fourPeriodPool.map((c) => c.recordKey).toSet()));

      // Generous keeps at least as many as Balanced (here also all 12).
      expect(generous.length, greaterThanOrEqualTo(balanced.length));
      expect(generous, equals(fourPeriodPool.map((c) => c.recordKey).toSet()));
    });

    testWidgets(
      'a) applying a band in the screen only mutates the draft set and '
      'commits through the unchanged save path (no new persistence)',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              windowValidPool,
              initialDemandCovers: demandCovers,
              initialDefs: fourPeriodDefs,
              initialCanOverride: true,
            ),
          ),
        );
        await tester.pump();

        // R8: the screen OPENS POPULATED with the default Balanced
        // derivation in the draft (client-side only, no persistence).
        final derivedBalanced = deriveBandSelection(
          windowValidPool,
          fourPeriodDefs,
          StarBand.balanced,
        );
        expectSelectedShiftsCount(tester, '${derivedBalanced.length}');

        // Opening must NOT have persisted anything.
        final onOpenStored = await tester.runAsync(
          () => DatabaseHelper.instance.getBaselineSelectedRecordKeys(),
        );
        expect(onOpenStored, isEmpty);

        // The band's ONLY effect is to replace the draft set with the
        // pure derivation output. Compute the expectation independently
        // from the same window-valid pool.
        final derivedLean = deriveBandSelection(
          windowValidPool,
          fourPeriodDefs,
          StarBand.lean,
        );

        // Apply Lean -> draft becomes exactly that derived set. This
        // flows ONLY through the draft set (no persistence here yet).
        final leanChip = find.byKey(const ValueKey<String>('band_lean'));
        await tester.ensureVisible(leanChip);
        await pumpEventually(tester);
        await tester.tap(leanChip);
        await pumpEventually(tester);
        expectSelectedShiftsCount(tester, '${derivedLean.length}');

        // Commit: the exact same Set<String> recordKeys land via the
        // unchanged saveSelection path. No new column / persistence shape;
        // the band never touches the write path itself.
        final stored = await commitDoneAndReadKeys(tester);
        expect(stored, equals(derivedLean));
      },
    );

    test('b) per-period preview uses the period\'s OWN candidate covers '
        '(not a split) and whole-day reconciles to the cover-weighted '
        'rollup of the per-period pieces', () {
      // Select every shift so each period contributes its full pool.
      final selected = fourPeriodPool;

      // Per-period preview for one period: covers are the SUM of that
      // period\'s selected shifts\' own covers, never a /N split or the
      // demand-context forecast number.
      final dinnerSelected = selected
          .where((c) => c.daypart == 'dinner')
          .toList();
      final dinnerCovers = dinnerSelected.fold<int>(0, (s, c) => s + c.covers);
      final dinnerPreview = ManagerOverridePlanPreview.forPeriod(
        dinnerSelected,
        fohWage: MeridianConfig.fohWage,
        bohWage: MeridianConfig.bohWage,
      );
      expect(dinnerPreview, isNotNull);
      expect(dinnerPreview!.forecastCovers, equals(dinnerCovers));

      // Cover-weighted period PPA computed independently here; sales
      // must be period covers * period cover-weighted PPA.
      double dinnerPpa = 0;
      for (final c in dinnerSelected) {
        final w = c.covers / dinnerCovers;
        dinnerPpa += c.ppa * w;
      }
      expect(
        dinnerPreview.forecastSales,
        closeTo(dinnerCovers * dinnerPpa, 0.0001),
      );

      // Reconciliation: the whole-day cover-weighted rollup of ALL
      // selected shifts equals the cover-weighted combination of the
      // per-period pieces. The per-period factory and the existing
      // WholeDayRollup share the same cover-weighting shape, so rolling
      // the per-period covers + cover-weighted rates back up reproduces
      // the whole-day rollup scalar (one truth, not a second one).
      final rollup = WholeDayRollup.fromShifts(
        selected,
        fohWage: MeridianConfig.fohWage,
        bohWage: MeridianConfig.bohWage,
      );

      final periodIds = selected.map((c) => c.daypart).toSet().toList();
      var sumCovers = 0;
      double wCplh = 0;
      double wSplh = 0;
      double wPpa = 0;
      for (final pid in periodIds) {
        final ps = selected.where((c) => c.daypart == pid).toList();
        final pPrev = ManagerOverridePlanPreview.forPeriod(
          ps,
          fohWage: MeridianConfig.fohWage,
          bohWage: MeridianConfig.bohWage,
        )!;
        // Recover the per-period cover-weighted rates from the period
        // pool (the factory keeps them internally; covers are exposed).
        final pc = pPrev.forecastCovers;
        double pCplh = 0;
        double pSplh = 0;
        double pPpa = 0;
        for (final c in ps) {
          final w = c.covers / pc;
          pCplh += c.cplh * w;
          pSplh += c.splh * w;
          pPpa += c.ppa * w;
        }
        sumCovers += pc;
        wCplh += pCplh * pc;
        wSplh += pSplh * pc;
        wPpa += pPpa * pc;
      }
      wCplh /= sumCovers;
      wSplh /= sumCovers;
      wPpa /= sumCovers;

      expect(sumCovers, equals(rollup.totalCovers));
      expect(wCplh, closeTo(rollup.cplh, 0.0001));
      expect(wSplh, closeTo(rollup.splh, 0.0001));
      expect(wPpa, closeTo(rollup.ppa, 0.0001));
    });

    testWidgets(
      'b) period lens shows the per-period preview; whole-day lens keeps '
      'the existing cover-weighted rollup preview',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              fourPeriodPool,
              initialDemandCovers: demandCovers,
              initialDefs: fourPeriodDefs,
              initialCanOverride: true,
            ),
          ),
        );
        await tester.pump();

        // Select everything via the Generous band. R8 moved the band
        // below the summary card, so ensure it is on-screen first.
        final generousChip = find.byKey(
          const ValueKey<String>('band_generous'),
        );
        await tester.ensureVisible(generousChip);
        await pumpEventually(tester);
        await tester.tap(generousChip);
        await pumpEventually(tester);

        // R9: FORECAST COVERS lives in the collapsed PLAN IMPACT
        // dropdown; expand it so the per-period vs whole-day covers
        // comparison can read the rendered value.
        await expandPlanImpact(tester);

        // Whole-day lens (default): FORECAST COVERS is the existing
        // demand-context plan number (read from the unchanged plumbing).
        final wholeDayPreview = ManagerOverridePlanPreview.fromDraftSelection(
          fourPeriodPool,
          historicalWeeklyAvgCovers: demandCovers,
          fohWage: MeridianConfig.fohWage,
          bohWage: MeridianConfig.bohWage,
        );
        expect(wholeDayPreview, isNotNull);
        expect(
          find.text('${wholeDayPreview!.forecastCovers}', skipOffstage: false),
          findsAtLeastNWidgets(1),
        );

        // Switch to the Lunch period lens: the preview region now shows
        // the per-period covers (sum of that period\'s own candidate
        // covers), which differs from the whole-day demand number.
        await tapLensChip(tester, 'lunch');
        final lunchSelected = fourPeriodPool
            .where((c) => c.daypart == 'lunch')
            .toList();
        final lunchCovers = lunchSelected.fold<int>(0, (s, c) => s + c.covers);
        expect(
          find.text('$lunchCovers', skipOffstage: false),
          findsAtLeastNWidgets(1),
        );
        // The per-period covers are NOT a /N split of the whole-day
        // number.
        expect(lunchCovers, isNot(equals(wholeDayPreview.forecastCovers)));
      },
    );

    test('c) per-period labor dollars use the SINGLE whole-day wage pair '
        '(no per-period / cover-weighted wage)', () {
      final lunch = fourPeriodPool.where((c) => c.daypart == 'lunch').toList();
      final p = ManagerOverridePlanPreview.forPeriod(
        lunch,
        fohWage: MeridianConfig.fohWage,
        bohWage: MeridianConfig.bohWage,
      )!;
      // Labor % is theoreticalLaborPct of the period cover-weighted
      // rates with the ONE whole-day wage pair, never a per-period wage.
      final covers = lunch.fold<int>(0, (s, c) => s + c.covers);
      double cplh = 0;
      double splh = 0;
      double ppa = 0;
      for (final c in lunch) {
        final w = c.covers / covers;
        cplh += c.cplh * w;
        splh += c.splh * w;
        ppa += c.ppa * w;
      }
      expect(
        p.theoreticalLaborPct,
        closeTo(
          LaborModel.theoreticalLaborPct(
            cplh,
            splh,
            ppa,
            MeridianConfig.fohWage,
            MeridianConfig.bohWage,
          ),
          0.0001,
        ),
      );
    });

    test('forPeriod returns null when no shifts are selected', () {
      expect(
        ManagerOverridePlanPreview.forPeriod(const <BaselineCandidateShift>[]),
        isNull,
      );
    });
  });

  // ── R8 - align implemented screen to the committed prototype ─────────────
  //
  // (a) the screen opens with Balanced applied: a non-empty draft and a
  //     populated preview, with NO persistence call on open;
  // (b) the section render order matches the prototype top-to-bottom:
  //     lens, scope tag, summary card, STAR SHIFT SELECTION + band,
  //     calendar, the once-per-cycle caption, then the CANCEL / DONE bar;
  // (c) the Done label includes the live draft count;
  // (d) the calendar shows the Closed / Selected legend + the count
  //     caption, and a 4-period config drives the n/total badge total.

  group('R8 - prototype alignment', () {
    const fourPeriodDefs = <ServicePeriodDefinition>[
      ServicePeriodDefinition(
        id: 'breakfast',
        label: 'Breakfast',
        shortLabel: 'B',
        sortOrder: 1,
        startLocalTime: '07:00',
        endLocalTime: '11:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'lunch',
        label: 'Lunch',
        shortLabel: 'L',
        sortOrder: 2,
        startLocalTime: '11:00',
        endLocalTime: '15:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'dinner',
        label: 'Dinner',
        shortLabel: 'D',
        sortOrder: 3,
        startLocalTime: '17:00',
        endLocalTime: '23:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'late_night',
        label: 'Late Night',
        shortLabel: 'LN',
        sortOrder: 4,
        startLocalTime: '23:00',
        endLocalTime: '02:00',
        rollsPastMidnight: true,
        applicableDays: [5, 6],
      ),
    ];

    // One business date with all four configured services so the badge
    // denominator is the day's configured service-period count (4 here),
    // never a fixed number.
    BaselineCandidateShift svc(String period, double cplh) =>
        BaselineCandidateShift(
          recordKey: '2026-W12|Fri|$period',
          weekId: '2026-W12',
          weekLabel: 'Week of Mar',
          dayLabel: 'Fri',
          daypart: period,
          covers: 150,
          cplh: cplh,
          splh: 180.0,
          ppa: 42.0,
          primaryLeverId: 'cplh_up',
          isSelected: false,
          businessDate: '2026-03-20',
          actualLaborPct: 24.0,
        );

    final fourServiceDay = <BaselineCandidateShift>[
      svc('breakfast', 5.0),
      svc('lunch', 4.0),
      svc('dinner', 4.5),
      svc('late_night', 3.0),
    ];

    testWidgets('a) opens with Balanced applied: non-empty draft + populated '
        'preview, and NO persistence call on open', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            fourServiceDay,
            initialDemandCovers: demandCovers,
            initialDefs: fourPeriodDefs,
            initialCanOverride: true,
          ),
        ),
      );
      await tester.pump();

      final expected = deriveBandSelection(
        fourServiceDay,
        fourPeriodDefs,
        StarBand.balanced,
      );
      expect(expected, isNotEmpty);
      expectSelectedShiftsCount(tester, '${expected.length}');
      expect(find.text('--'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('band_balanced')),
        findsOneWidget,
      );

      final stored = await tester.runAsync(
        () => DatabaseHelper.instance.getBaselineSelectedRecordKeys(),
      );
      expect(
        stored,
        isEmpty,
        reason: 'opening the screen must not persist anything',
      );
    });

    testWidgets(
      'b) section render order is lens, scope tag, summary, STAR SHIFT '
      'SELECTION + band, calendar, override caption, bottom bar',
      (tester) async {
        // Tall surface so the capped top scroll region is not clipped
        // and absolute Y positions reflect the true top-to-bottom
        // section order across the whole screen.
        tester.view.physicalSize = const Size(1200, 3200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              fourServiceDay,
              initialDemandCovers: demandCovers,
              initialDefs: fourPeriodDefs,
              initialCanOverride: true,
            ),
          ),
        );
        await tester.pump();

        double topOf(Finder f) => tester.getTopLeft(f.first).dy;

        // Anchors for each section, top-to-bottom.
        final lensDy = topOf(
          find.byKey(const ValueKey<String>('lens_$kWholeDayLensId')),
        );
        // R10: the scope label is now an uppercase section header (no
        // pill / button), so the rendered text is upper-cased.
        final scopeTagDy = topOf(find.text('WHOLE DAY TARGETS'));
        final summaryDy = topOf(find.text('SELECTED SHIFTS'));
        final bandLabelDy = topOf(find.text('STAR SHIFT SELECTION'));
        final bandChipDy = topOf(
          find.byKey(const ValueKey<String>('band_balanced')),
        );
        final calendarDy = topOf(find.text('LAST 60 DAYS'));
        final captionDy = topOf(
          find.byKey(const ValueKey<String>('override_cycle_caption')),
        );
        final cancelDy = topOf(find.text('CANCEL'));

        expect(lensDy, lessThan(scopeTagDy));
        expect(scopeTagDy, lessThan(summaryDy));
        // Summary card comes BEFORE the band (the prototype order; the
        // implemented screen previously had the band first).
        expect(summaryDy, lessThan(bandLabelDy));
        expect(bandLabelDy, lessThan(bandChipDy));
        expect(bandChipDy, lessThan(calendarDy));
        expect(calendarDy, lessThan(captionDy));
        expect(captionDy, lessThan(cancelDy));
      },
    );

    testWidgets('c) Done label includes the live draft count', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            fourServiceDay,
            initialDemandCovers: demandCovers,
            initialDefs: fourPeriodDefs,
            initialCanOverride: true,
          ),
        ),
      );
      await tester.pump();

      final expected = deriveBandSelection(
        fourServiceDay,
        fourPeriodDefs,
        StarBand.balanced,
      );
      // Default Balanced count is reflected in the action label.
      expect(find.text('Done · ${expected.length}'), findsOneWidget);

      // Clearing the draft updates the label to the new count.
      await clearAllDraft(tester);
      expect(find.text('Done · 0'), findsOneWidget);
    });

    testWidgets(
      'd) calendar shows the Closed / Selected legend + count caption, '
      'and a 4-period config drives the n/total badge total',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              fourServiceDay,
              initialDemandCovers: demandCovers,
              initialDefs: fourPeriodDefs,
              initialCanOverride: true,
            ),
          ),
        );
        await tester.pump();

        // Legend pills + count caption (whole-day lens is the default).
        expect(
          find.byKey(const ValueKey<String>('cal_legend_closed')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('cal_legend_selected')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('cal_legend_count_caption')),
          findsOneWidget,
        );
        expect(find.text('Closed'), findsOneWidget);
        expect(find.text('Selected'), findsOneWidget);
        expect(find.text('Count = services kept that day'), findsOneWidget);

        // Default Balanced selects all four services on 2026-03-20, so
        // the badge total is the day's configured service-period count
        // (4), driven by the resolved defs, never a fixed number.
        expect(
          find.byKey(const ValueKey<String>('cal_badge_2026-03-20')),
          findsOneWidget,
        );
        expect(find.text('4/4'), findsOneWidget);
      },
    );
  });

  // ── R9 - single continuous scroll + PLAN IMPACT dropdown ─────────────────
  //
  // (a) the body is ONE scroll: there is exactly one SingleChildScrollView
  //     between the app bar and the bottom bar, the CalendarGrid is inside
  //     it and is NOT its own scrollable and NOT wrapped in
  //     Expanded/Flexible;
  // (b) PLAN IMPACT is collapsed by default and expands/collapses on tap
  //     (the chevron rotates);
  // (c) no regression: still opens populated, the section order holds,
  //     the Done count is live, and saveSelection is only called on Done.

  group('R9 - single continuous scroll + PLAN IMPACT dropdown', () {
    testWidgets('a) the body is a single scroll: one SingleChildScrollView, '
        'calendar is non-scrollable and not in Expanded/Flexible', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // Exactly ONE vertical page scroll between the fixed app bar
      // and the fixed bottom bar (the prototype's single `.scl`). The
      // lens chip row is a deliberate HORIZONTAL SingleChildScrollView
      // (the prototype's `.lens` strip) and is not a second page
      // scroll, so the page-scroll assertion is scoped to vertical.
      final verticalPageScroll = find.byWidgetPredicate(
        (w) => w is SingleChildScrollView && w.scrollDirection == Axis.vertical,
      );
      expect(verticalPageScroll, findsOneWidget);

      // The calendar is in the tree, inside that one vertical scroll.
      final calendar = find.byType(CalendarGrid);
      expect(calendar, findsOneWidget);
      expect(
        find.ancestor(of: calendar, matching: verticalPageScroll),
        findsOneWidget,
      );

      // The calendar is NOT its own scrollable: no Scrollable lives
      // under CalendarGrid (it lays out at intrinsic height), so the
      // single page scroll owns all scrolling, no nested conflict.
      expect(
        find.descendant(of: calendar, matching: find.byType(Scrollable)),
        findsNothing,
      );

      // The calendar is NOT flex-wrapped INSIDE the page scroll: the
      // old `Expanded(child: CalendarGrid)` split-scroll region is
      // gone. The body-level Expanded that holds the single scroll is
      // the scroll's PARENT (correct, expected) so it is excluded by
      // requiring the flex node to also be a descendant of the scroll.
      // CalendarGrid's own internal cell Expandeds are descendants of
      // the calendar, not ancestors, so they do not match here.
      // Flexible is the superclass of Expanded, so this one predicate
      // covers both.
      final flexBetweenScrollAndCalendar = find.byWidgetPredicate(
        (w) => w is Flexible,
      );
      expect(
        find.descendant(
          of: verticalPageScroll,
          matching: find.ancestor(
            of: calendar,
            matching: flexBetweenScrollAndCalendar,
          ),
        ),
        findsNothing,
      );
    });

    testWidgets('b) PLAN IMPACT is collapsed by default and toggles on tap', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // Header row is always present; metric cells are NOT in the
      // tree while collapsed.
      expect(
        find.byKey(const ValueKey<String>('plan_impact_toggle')),
        findsOneWidget,
      );
      expect(find.text('PLAN IMPACT'), findsOneWidget);
      expect(find.text('FORECAST COVERS'), findsNothing);
      expect(find.text('BLENDED WAGE'), findsNothing);

      // Tap expands inline.
      await expandPlanImpact(tester);
      expect(find.text('FORECAST COVERS'), findsOneWidget);
      expect(find.text('FORECAST SALES'), findsOneWidget);
      expect(find.text('FOH HRS'), findsOneWidget);
      expect(find.text('BOH HRS'), findsOneWidget);
      expect(find.text('LABOR %'), findsOneWidget);
      expect(find.text('BLENDED WAGE'), findsOneWidget);

      // Tapping again collapses it back.
      final toggle = find.byKey(const ValueKey<String>('plan_impact_toggle'));
      await tester.ensureVisible(toggle);
      await pumpEventually(tester);
      await tester.tap(toggle);
      await pumpEventually(tester);
      expect(find.text('FORECAST COVERS'), findsNothing);
      expect(find.text('PLAN IMPACT'), findsOneWidget);
    });

    testWidgets('c) no regression: opens populated, section order holds, Done '
        'count is live, and Done is the only write path', (tester) async {
      // Tall surface so the full single-scroll page lays out and
      // absolute Y positions reflect the true top-to-bottom order.
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // Opens populated (R8 default Balanced preserved).
      final defs = ServicePeriodDefinitionResolver.demoDefinitions;
      final expected = deriveBandSelection(
        allCandidates,
        defs,
        StarBand.balanced,
      );
      expect(expected, isNotEmpty);
      expectSelectedShiftsCount(tester, '${expected.length}');
      expect(find.text('Done · ${expected.length}'), findsOneWidget);

      // Opening the screen persists nothing.
      final storedOnOpen = await tester.runAsync(
        () => DatabaseHelper.instance.getBaselineSelectedRecordKeys(),
      );
      expect(storedOnOpen, isEmpty);

      // Section order top-to-bottom inside the single scroll:
      // lens, scope tag, summary, STAR SHIFT SELECTION + band,
      // calendar, then (fixed below) the override caption + CANCEL.
      double topOf(Finder f) => tester.getTopLeft(f.first).dy;
      final lensDy = topOf(
        find.byKey(const ValueKey<String>('lens_$kWholeDayLensId')),
      );
      // R10: the scope label renders as an uppercase section header.
      final scopeTagDy = topOf(find.text('WHOLE DAY TARGETS'));
      final summaryDy = topOf(find.text('SELECTED SHIFTS'));
      final bandLabelDy = topOf(find.text('STAR SHIFT SELECTION'));
      final calendarDy = topOf(find.text('LAST 60 DAYS'));
      final captionDy = topOf(
        find.byKey(const ValueKey<String>('override_cycle_caption')),
      );
      final cancelDy = topOf(find.text('CANCEL'));
      expect(lensDy, lessThan(scopeTagDy));
      expect(scopeTagDy, lessThan(summaryDy));
      expect(summaryDy, lessThan(bandLabelDy));
      expect(bandLabelDy, lessThan(calendarDy));
      expect(calendarDy, lessThan(captionDy));
      expect(captionDy, lessThan(cancelDy));

      // Done is still the only write path: tapping it persists the
      // current draft keys (saveSelection unchanged, called on Done).
      final stored = await commitDoneAndReadKeys(tester);
      expect(stored.toSet(), equals(expected));
    });
  });

  // ── R10 - per-daypart mix-and-match band + scope label as header ─────────
  //
  // (a) the per-period band map defaults EVERY configured period to
  //     Balanced and opens populated, with NO persistence call on open;
  // (b) on a daypart lens the control sets only that daypart's band; on
  //     the Whole day lens the control bulk-sets ALL periods' bands; both
  //     verified by the derived draft for a 4-period config;
  // (c) RESET restores all-Balanced (client-side only);
  // (d) saveSelection is still only called on DONE;
  // (e) the scope label renders as a non-interactive section header (no
  //     button / pill / tap handler).

  group('R10 - per-daypart mix-and-match band + scope label as header', () {
    const fourPeriodDefs = <ServicePeriodDefinition>[
      ServicePeriodDefinition(
        id: 'breakfast',
        label: 'Breakfast',
        shortLabel: 'B',
        sortOrder: 1,
        startLocalTime: '07:00',
        endLocalTime: '11:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'lunch',
        label: 'Lunch',
        shortLabel: 'L',
        sortOrder: 2,
        startLocalTime: '11:00',
        endLocalTime: '15:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'dinner',
        label: 'Dinner',
        shortLabel: 'D',
        sortOrder: 3,
        startLocalTime: '17:00',
        endLocalTime: '23:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'late_night',
        label: 'Late Night',
        shortLabel: 'LN',
        sortOrder: 4,
        startLocalTime: '23:00',
        endLocalTime: '02:00',
        rollsPastMidnight: true,
        applicableDays: [5, 6],
      ),
    ];

    // Window-valid pool: two shifts per configured period on two valid
    // business dates, so the band's top-N-per-period ranking is exercised
    // and saveSelection -> TargetCycleService resolves keys against the
    // seeded demo 60-day window for the Done assertion.
    BaselineCandidateShift winShift(
      String week,
      String day,
      String date,
      String period,
      double cplh,
    ) {
      return BaselineCandidateShift(
        recordKey: '$week|$day|$period',
        weekId: week,
        weekLabel: 'Week of Mar',
        dayLabel: day,
        daypart: period,
        covers: 150,
        cplh: cplh,
        splh: 180.0,
        ppa: 42.0,
        primaryLeverId: 'cplh_up',
        isSelected: false,
        businessDate: date,
        actualLaborPct: 24.0,
      );
    }

    final windowValidPool = <BaselineCandidateShift>[
      for (final period in const [
        'breakfast',
        'lunch',
        'dinner',
        'late_night',
      ]) ...[
        winShift('2026-W12', 'Fri', '2026-03-20', period, 5.0),
        winShift('2026-W12', 'Mon', '2026-03-16', period, 4.0),
      ],
    ];

    // The R10 expectation helper: union over each configured period of
    // that period's strongest N (N per THAT period's own band).
    Set<String> expectedFor(Map<String, StarBand> bandByPeriod) {
      return derivePerPeriodBandSelection(
        windowValidPool,
        fourPeriodDefs,
        bandByPeriod,
      );
    }

    // Band-distinction pool: SIX shifts per configured period with
    // strictly distinct CPLH so Lean (N=2), Balanced (N=4), and Generous
    // (N=6) each keep a different count. Used only by the lens-scoped
    // band test (b), which does not commit, so window validity is moot.
    final bandDistinctPool = <BaselineCandidateShift>[
      for (final period in const ['breakfast', 'lunch', 'dinner', 'late_night'])
        for (var i = 0; i < 6; i++)
          BaselineCandidateShift(
            recordKey: '$period|d$i',
            weekId: 'W',
            weekLabel: 'W',
            dayLabel: 'Fri',
            daypart: period,
            covers: 100 + i,
            cplh: 3.0 + i, // i=5 strongest, i=0 weakest
            splh: 150.0 + i,
            ppa: 40.0 + i,
            primaryLeverId: 'cplh_up',
            isSelected: false,
            businessDate: '2026-03-2$i',
            actualLaborPct: 22.0,
          ),
    ];

    Set<String> expectedDistinctFor(Map<String, StarBand> bandByPeriod) {
      return derivePerPeriodBandSelection(
        bandDistinctPool,
        fourPeriodDefs,
        bandByPeriod,
      );
    }

    const allBalanced = <String, StarBand>{
      'breakfast': StarBand.balanced,
      'lunch': StarBand.balanced,
      'dinner': StarBand.balanced,
      'late_night': StarBand.balanced,
    };

    testWidgets('a) per-period band map defaults all 4 configured periods to '
        'Balanced and opens populated with NO persistence call on open', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            windowValidPool,
            initialDemandCovers: demandCovers,
            initialDefs: fourPeriodDefs,
            initialCanOverride: true,
          ),
        ),
      );
      await tester.pump();

      // The on-open draft is exactly the union over all four periods
      // of each period's Balanced strongest-N (the default map).
      final expected = expectedFor(allBalanced);
      expect(expected, isNotEmpty);
      expectSelectedShiftsCount(tester, '${expected.length}');
      expect(find.text('--'), findsNothing);

      // On the default Whole day lens every period shares Balanced, so
      // the control highlights Balanced.
      expect(
        find.byKey(const ValueKey<String>('band_balanced')),
        findsOneWidget,
      );

      // CRITICAL: opening must NOT persist anything. The per-period
      // band map is ephemeral UI state; only Done writes.
      final stored = await tester.runAsync(
        () => DatabaseHelper.instance.getBaselineSelectedRecordKeys(),
      );
      expect(
        stored,
        isEmpty,
        reason: 'opening must not persist; band map is ephemeral',
      );
    });

    testWidgets(
      'b) a daypart lens sets ONLY that daypart\'s band; the Whole day '
      'lens bulk-sets ALL periods\' bands (verified by the derived draft)',
      (tester) async {
        // 6 distinct-CPLH shifts per period so Lean (2) != Balanced (4)
        // != Generous (6): the draft count is unambiguous proof of which
        // periods' bands moved.
        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              bandDistinctPool,
              initialDemandCovers: demandCovers,
              initialDefs: fourPeriodDefs,
              initialCanOverride: true,
            ),
          ),
        );
        await tester.pump();

        // Open state: every period Balanced. Whole-day draft count is
        // the all-Balanced union (4 periods * 4 = 16).
        final allBalancedSet = expectedDistinctFor(allBalanced);
        expect(find.text('Done · ${allBalancedSet.length}'), findsOneWidget);

        // Scope to the Dinner daypart lens and pick Lean. ONLY Dinner's
        // band changes; the other three stay Balanced. The full derived
        // draft must equal the mixed map (dinner Lean, rest Balanced):
        // 3*4 + 1*2 = 14, strictly fewer than the all-Balanced 16.
        await tapLensChip(tester, 'dinner');
        final leanChip = find.byKey(const ValueKey<String>('band_lean'));
        await tester.ensureVisible(leanChip);
        await pumpEventually(tester);
        await tester.tap(leanChip);
        await pumpEventually(tester);

        final mixed = <String, StarBand>{
          'breakfast': StarBand.balanced,
          'lunch': StarBand.balanced,
          'dinner': StarBand.lean,
          'late_night': StarBand.balanced,
        };
        final expectedMixed = expectedDistinctFor(mixed);
        // Assert the FULL draft via the Done count (the summary
        // re-scopes to the active Dinner lens).
        expect(find.text('Done · ${expectedMixed.length}'), findsOneWidget);
        // Only Dinner moved: the mixed draft is strictly smaller than
        // the all-Balanced default, proving it was not a global change.
        expect(expectedMixed.length, lessThan(allBalancedSet.length));
        expect(expectedMixed, isNot(equals(allBalancedSet)));

        // Now the Whole day lens + Generous: a BULK OVERRIDE that sets
        // EVERY period's band to Generous, replacing the prior mixed
        // state. Derived draft == all-Generous union (4*6 = 24).
        await tapLensChip(tester, kWholeDayLensId);
        final generousChip = find.byKey(
          const ValueKey<String>('band_generous'),
        );
        await tester.ensureVisible(generousChip);
        await pumpEventually(tester);
        await tester.tap(generousChip);
        await pumpEventually(tester);

        const allGenerous = <String, StarBand>{
          'breakfast': StarBand.generous,
          'lunch': StarBand.generous,
          'dinner': StarBand.generous,
          'late_night': StarBand.generous,
        };
        final expectedGenerous = expectedDistinctFor(allGenerous);
        expectSelectedShiftsCount(tester, '${expectedGenerous.length}');
        expect(find.text('Done · ${expectedGenerous.length}'), findsOneWidget);
        // Bulk override touched ALL periods: strictly more than the
        // prior mixed state.
        expect(expectedGenerous.length, greaterThan(expectedMixed.length));
      },
    );

    testWidgets(
      'c) RESET restores all-Balanced (client-side only, no persistence)',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              windowValidPool,
              initialDemandCovers: demandCovers,
              initialDefs: fourPeriodDefs,
              initialCanOverride: true,
            ),
          ),
        );
        await tester.pump();

        // Mix the state: Lunch lens -> Lean.
        await tapLensChip(tester, 'lunch');
        final leanChip = find.byKey(const ValueKey<String>('band_lean'));
        await tester.ensureVisible(leanChip);
        await pumpEventually(tester);
        await tester.tap(leanChip);
        await pumpEventually(tester);

        // RESET pill restores the default Balanced map and whole-day
        // lens. The draft returns to the all-Balanced union.
        await tester.tap(find.byKey(const ValueKey<String>('reset_pill')));
        await pumpEventually(tester);

        final expected = expectedFor(allBalanced);
        expectSelectedShiftsCount(tester, '${expected.length}');
        expect(
          find.byKey(const ValueKey<String>('band_balanced')),
          findsOneWidget,
        );

        // RESET is client-side only: nothing persisted.
        final stored = await tester.runAsync(
          () => DatabaseHelper.instance.getBaselineSelectedRecordKeys(),
        );
        expect(stored, isEmpty);
      },
    );

    testWidgets('d) saveSelection is still only called on DONE: the mixed '
        'per-period draft lands via the unchanged write path', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            windowValidPool,
            initialDemandCovers: demandCovers,
            initialDefs: fourPeriodDefs,
            initialCanOverride: true,
          ),
        ),
      );
      await tester.pump();

      // Mix: Breakfast lens -> Lean. No persistence until Done.
      await tapLensChip(tester, 'breakfast');
      final leanChip = find.byKey(const ValueKey<String>('band_lean'));
      await tester.ensureVisible(leanChip);
      await pumpEventually(tester);
      await tester.tap(leanChip);
      await pumpEventually(tester);

      final preDone = await tester.runAsync(
        () => DatabaseHelper.instance.getBaselineSelectedRecordKeys(),
      );
      expect(
        preDone,
        isEmpty,
        reason: 'band changes never persist before Done',
      );

      // Done writes exactly the per-period mixed draft via the
      // unchanged saveSelection path.
      final mixed = <String, StarBand>{
        'breakfast': StarBand.lean,
        'lunch': StarBand.balanced,
        'dinner': StarBand.balanced,
        'late_night': StarBand.balanced,
      };
      final stored = await commitDoneAndReadKeys(tester);
      expect(stored, equals(expectedFor(mixed)));
    });

    testWidgets('e) the scope label is a non-interactive section header: no '
        'button, no pill, no tap handler', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            windowValidPool,
            initialDemandCovers: demandCovers,
            initialDefs: fourPeriodDefs,
            initialCanOverride: true,
          ),
        ),
      );
      await tester.pump();

      // The scope label renders as an uppercase section header (the
      // text content is still driven by the resolved defs / whole-day
      // sentinel: "Whole day targets" upper-cased).
      final headerFinder = find.text('WHOLE DAY TARGETS');
      expect(headerFinder, findsOneWidget);

      // It is NOT wrapped in any tap/button affordance: no ancestor
      // GestureDetector, InkWell, or button widget.
      expect(
        find.ancestor(of: headerFinder, matching: find.byType(GestureDetector)),
        findsNothing,
      );
      expect(
        find.ancestor(of: headerFinder, matching: find.byType(InkWell)),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: headerFinder,
          matching: find.byType(ButtonStyleButton),
        ),
        findsNothing,
      );

      // It also re-scopes with the lens (text driven by resolved defs,
      // never hardcoded): a daypart lens shows that period's label.
      await tapLensChip(tester, 'late_night');
      expect(find.text('LATE NIGHT TARGETS'), findsOneWidget);
      expect(find.text('WHOLE DAY TARGETS'), findsNothing);
    });
  });
}
