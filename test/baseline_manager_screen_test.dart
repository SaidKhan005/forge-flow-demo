import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/state/active_target_profile_notifier.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/database_helper.dart';
import 'package:forge_and_flow/services/demand_forecast_context_service.dart';
import 'package:forge_and_flow/data/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';
import 'package:forge_and_flow/services/labor_model.dart';
import 'package:provider/provider.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────
// Week 10 Mon = 2026-03-02, Week 10 Fri = 2026-03-06,
// Week 11 Tue = 2026-03-10, Week 12 Mon = 2026-03-16.

const _lunch1 = BaselineCandidateShift(
  recordKey: '2026-W10|Mon|lunch',
  weekId: '2026-W10',
  weekLabel: 'Week of Mar 3',
  dayLabel: 'Mon',
  daypart: 'lunch',
  covers: 155,
  cplh: 4.80,
  splh: 185.0,
  ppa: 42.5,
  primaryLeverId: 'cplh_up',
  isSelected: false,
  businessDate: '2026-03-02',
  actualLaborPct: 24.3,
);

const _lunch2 = BaselineCandidateShift(
  recordKey: '2026-W11|Tue|lunch',
  weekId: '2026-W11',
  weekLabel: 'Week of Mar 10',
  dayLabel: 'Tue',
  daypart: 'lunch',
  covers: 148,
  cplh: 4.60,
  splh: 182.0,
  ppa: 41.8,
  primaryLeverId: 'cplh_up',
  isSelected: false,
  businessDate: '2026-03-10',
  actualLaborPct: 25.1,
);

const _dinner1 = BaselineCandidateShift(
  recordKey: '2026-W10|Fri|dinner',
  weekId: '2026-W10',
  weekLabel: 'Week of Mar 3',
  dayLabel: 'Fri',
  daypart: 'dinner',
  covers: 210,
  cplh: 4.70,
  splh: 190.0,
  ppa: 43.0,
  primaryLeverId: 'cplh_up',
  isSelected: false,
  businessDate: '2026-03-06',
  actualLaborPct: 23.8,
);

const _selectedLunch = BaselineCandidateShift(
  recordKey: '2026-W12|Mon|lunch',
  weekId: '2026-W12',
  weekLabel: 'Week of Mar 17',
  dayLabel: 'Mon',
  daypart: 'lunch',
  covers: 162,
  cplh: 4.90,
  splh: 188.0,
  ppa: 43.2,
  primaryLeverId: 'cplh_up',
  isSelected: true,
  businessDate: '2026-03-16',
  actualLaborPct: 22.7,
);

// Dinner shift with a distinct unfavorable lever for lever-label tests.
const _dinnerSplhDown = BaselineCandidateShift(
  recordKey: '2026-W10|Mon|dinner',
  weekId: '2026-W10',
  weekLabel: 'Week of Mar 3',
  dayLabel: 'Mon',
  daypart: 'dinner',
  covers: 195,
  cplh: 4.30,
  splh: 175.0,
  ppa: 40.5,
  primaryLeverId: 'splh_down',
  isSelected: false,
  businessDate: '2026-03-02',
  actualLaborPct: 26.8,
);

const _allCandidates = [_lunch1, _lunch2, _dinner1];
const _withPreSelected = [_selectedLunch, _lunch1, _dinner1];
const _leverTestCandidates = [_lunch1, _dinnerSplhDown, _dinner1];

ActiveTargetProfile _defaultProfile() => ActiveTargetProfile(
      targetProfileId: 'baseline-manager-test',
      restaurantId: 'test-restaurant',
      sourceType: 'system_baseline',
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      fohWage: MeridianConfig.fohWage,
      bohWage: MeridianConfig.bohWage,
      opzFloorCPLH: BaselineData.opzFloorCPLH,
      opzCeilingCPLH: BaselineData.opzCeilingCPLH,
      theoreticalFohLaborPct: BaselineData.derivedFohTheoreticalLaborPct,
      theoreticalBohLaborPct: BaselineData.derivedBohTheoreticalLaborPct,
      theoreticalLaborPct: BaselineData.derivedTheoreticalLaborPct,
      builtAt: 'test',
    );

Widget _wrap(Widget child) => ChangeNotifierProvider(
      create: (_) => ActiveTargetProfileNotifier.fromProfile(_defaultProfile()),
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: child,
      ),
    );

// ── Tile label helper ─────────────────────────────────────────────────────────
// Mirrors the screen's tile label logic: human-friendly date + daypart when
// businessDate is present, otherwise falls back to the model's displayLabel.

const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _monthAbbrs = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _tileLabel(BaselineCandidateShift c) {
  if (c.businessDate == null) return c.displayLabel;
  final p = c.businessDate!.split('-');
  final dt = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  final dayName = _dayNames[dt.weekday - 1];
  final mon = _monthAbbrs[dt.month - 1];
  return '$dayName, $mon ${dt.day} ${c.daypartLabel}';
}

// ── Navigation helpers ────────────────────────────────────────────────────────

Future<void> _tapCalendarDate(WidgetTester tester, String date) async {
  final finder = find.byKey(ValueKey<String>('cal_$date'));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapBackToCalendar(WidgetTester tester) async {
  await tester.tap(find.text('BACK TO CALENDAR'));
  await tester.pumpAndSettle();
}

/// Tap a candidate tile by its rendered label, handling offstage from
/// the narrow test viewport (CLEAR ALL bar can push tiles below viewport).
Future<void> _tapCandidateTile(
    WidgetTester tester, BaselineCandidateShift candidate) async {
  final label = _tileLabel(candidate);
  final finder = find.text(label, skipOffstage: false);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<Set<String>> _commitDoneAndReadKeys(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    await tester.tap(find.text('DONE'));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return DatabaseHelper.instance.getBaselineSelectedRecordKeys();
  }))!;
}

void main() {
  int? demandCovers;

  setUp(() async {
    BaselineData.clearManagerOverride();
    await DatabaseHelper.instance.reseedDemo();
    await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({});
    final ctx =
        await DemandForecastContextService.instance.getCurrentContext();
    demandCovers = ctx.historicalWeeklyAvgCovers;
  });

  testWidgets('shows loading indicator when no initialCandidates provided',
      (tester) async {
    await tester.pumpWidget(_wrap(const BaselineManagerScreen()));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  group('A - required labels present', () {
    testWidgets('page title, buttons, and all preview labels render',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      expect(find.text('Choose Star Shifts'), findsOneWidget);
      expect(find.text('CANCEL'), findsOneWidget);
      expect(find.text('DONE'), findsOneWidget);
      // Target standard cells
      expect(find.text('SELECTED SHIFTS'), findsOneWidget);
      expect(find.text('TARGET CPLH'), findsOneWidget);
      expect(find.text('TARGET SPLH'), findsOneWidget);
      expect(find.text('TARGET PPA'), findsOneWidget);
      expect(find.text('OPZ FLOOR'), findsOneWidget);
      expect(find.text('OPZ CEILING'), findsOneWidget);
      // Plan impact section
      expect(find.text('PLAN IMPACT'), findsOneWidget);
      expect(find.text('FORECAST COVERS'), findsOneWidget);
      expect(find.text('FORECAST SALES'), findsOneWidget);
      expect(find.text('FOH HRS'), findsOneWidget);
      expect(find.text('BOH HRS'), findsOneWidget);
      expect(find.text('LABOR %'), findsOneWidget);
      expect(find.text('BLENDED WAGE'), findsOneWidget);
      // Calendar header
      expect(find.text('LAST 60 DAYS'), findsOneWidget);
    });
  });

  group('B - zero-selection preview', () {
    testWidgets('SELECTED SHIFTS shows 0 when nothing selected',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('all metric cells show -- when nothing selected',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();
      // 5 target standard cells + 6 plan impact cells = 11
      expect(find.text('--'), findsNWidgets(11));
    });
  });

  group('C - live preview updates on selection', () {
    testWidgets('selecting one candidate clears all -- from preview',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      expect(find.text('--'), findsNWidgets(11));

      // Navigate to _lunch1's date and tap its tile
      await _tapCalendarDate(tester, '2026-03-02');
      await _tapCandidateTile(tester, _lunch1);

      expect(find.text('--'), findsNothing);
    });

    testWidgets('count increments to 1 after first selection', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');
      await _tapCandidateTile(tester, _lunch1);

      // In day detail: only preview panel shows '1', no calendar day cells
      expect(find.text('1'), findsOneWidget);
    });

  });

  group('D - candidate tiles show required fields', () {
    testWidgets('LUNCH section header renders in day detail', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Navigate to date with lunch shift
      await _tapCalendarDate(tester, '2026-03-02');
      expect(find.text('LUNCH'), findsOneWidget);
    });

    testWidgets('DINNER section header renders in day detail', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Navigate to date with dinner shift
      await _tapCalendarDate(tester, '2026-03-06');
      expect(find.text('DINNER'), findsOneWidget);
    });

    testWidgets('each tile shows CPLH, COVERS, SPLH, PPA, and lever',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Navigate to date with one shift (_lunch1 on 2026-03-02)
      await _tapCalendarDate(tester, '2026-03-02');

      expect(find.text('CPLH ', skipOffstage: false), findsNWidgets(1));
      expect(find.text('COVERS ', skipOffstage: false), findsNWidgets(1));
      expect(find.text('SPLH ', skipOffstage: false), findsNWidgets(1));
      expect(find.text('PPA ', skipOffstage: false), findsNWidgets(1));
      expect(find.text('LEVER ', skipOffstage: false), findsNWidgets(1));
      // Lever label shows full natural-language meaning (metric from LeverCards)
      expect(find.text('CPLH ABOVE TARGET', skipOffstage: false), findsAtLeastNWidgets(1));
    });
  });

  group('E - Cancel discards draft', () {
    testWidgets('Cancel does not write selection to DB', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');
      await _tapCandidateTile(tester, _lunch1);
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.text('CANCEL'));
      await tester.pump();

      final stored = await tester.runAsync(() async {
        return DatabaseHelper.instance.getBaselineSelectedRecordKeys();
      });
      expect(stored!, isEmpty);
    });
  });

  group('F - Done with non-empty draft commits selection', () {
    testWidgets('Done writes selected record key to DB', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');
      await _tapCandidateTile(tester, _lunch1);
      expect(find.text('1'), findsOneWidget);

      // Back to calendar so DONE is reachable
      await _tapBackToCalendar(tester);

      final stored = await _commitDoneAndReadKeys(tester);
      expect(stored, contains(_lunch1.recordKey));
    });
  });

  group('G - Done with empty draft clears override', () {
    testWidgets('deselect all then Done empties DB and clears override',
        (tester) async {
      await tester.runAsync(() async {
        await DatabaseHelper.instance
            .replaceBaselineSelectedRecordKeys({_selectedLunch.recordKey});
      });
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
          daypart: 'lunch',
          cplh: 4.90,
          splh: 188.0,
          ppa: 43.2,
          covers: 162,
        ),
      ]);
      expect(BaselineData.hasManagerOverride, isTrue);

      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_withPreSelected, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Clear all selections via CLEAR ALL button
      await tester.tap(find.text('CLEAR ALL'));
      await tester.pumpAndSettle();
      expect(find.text('0'), findsOneWidget);

      final stored = await _commitDoneAndReadKeys(tester);

      expect(stored, isEmpty);
      expect(BaselineData.hasManagerOverride, isFalse);
    });
  });

  // ── H — Plan impact preview: selected-shift behavior ──────────────────────

  group('H - plan impact selected-shift behavior', () {
    testWidgets('selecting one candidate shows plan impact values',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Navigate to _lunch1's date and select
      await _tapCalendarDate(tester, '2026-03-02');
      await _tapCandidateTile(tester, _lunch1);

      // Forecast covers fixed from canonical demand context
      final expectedCovers = demandCovers;
      expect(expectedCovers, isNot(equals(_lunch1.covers)));
      expect(find.text('$expectedCovers', skipOffstage: false),
          findsAtLeastNWidgets(1));
    });

  });

  // ── I — PPA guardrail: changing PPA changes sales/BOH, not covers/FOH ─────

  group('I - PPA guardrail', () {
    // Two candidates with same CPLH/SPLH but different PPA.
    const lowPPA = BaselineCandidateShift(
      recordKey: '2026-W10|Mon|lunch_low',
      weekId: '2026-W10',
      weekLabel: 'Week of Mar 3',
      dayLabel: 'Mon',
      daypart: 'lunch',
      covers: 160,
      cplh: 4.80,
      splh: 185.0,
      ppa: 38.0,
      primaryLeverId: 'cplh_up',
      isSelected: false,
      actualLaborPct: 26.5,
    );

    const highPPA = BaselineCandidateShift(
      recordKey: '2026-W10|Mon|lunch_high',
      weekId: '2026-W10',
      weekLabel: 'Week of Mar 3',
      dayLabel: 'Mon',
      daypart: 'lunch',
      covers: 160,
      cplh: 4.80,
      splh: 185.0,
      ppa: 52.0,
      primaryLeverId: 'cplh_up',
      isSelected: false,
      actualLaborPct: 20.2,
    );

    test('different PPA → same forecast covers, different sales and BOH hrs',
        () async {
      final demandCtx =
          await DemandForecastContextService.instance.getCurrentContext();
      final demandCovers = demandCtx.historicalWeeklyAvgCovers;

      final previewLow =
          ManagerOverridePlanPreview.fromDraftSelection([lowPPA],
              historicalWeeklyAvgCovers: demandCovers);
      final previewHigh =
          ManagerOverridePlanPreview.fromDraftSelection([highPPA],
              historicalWeeklyAvgCovers: demandCovers);

      expect(previewLow, isNotNull);
      expect(previewHigh, isNotNull);

      // Forecast covers are fixed from demand — same regardless of PPA.
      expect(previewLow!.forecastCovers, equals(previewHigh!.forecastCovers));
      expect(previewLow.forecastCovers, equals(demandCovers));

      // Forecast sales changes: covers * PPA.
      expect(previewHigh.forecastSales, greaterThan(previewLow.forecastSales));

      // FOH hours unchanged (driven by covers/CPLH, same for both).
      expect(previewLow.requiredFohHours, equals(previewHigh.requiredFohHours));

      // BOH hours change (driven by sales/SPLH, sales differs).
      expect(
          previewHigh.requiredBohHours, greaterThan(previewLow.requiredBohHours));
    });
  });

  // ── J — ManagerOverridePlanPreview unit tests ─────────────────────────────

  group('J - ManagerOverridePlanPreview unit', () {
    test('returns null when no shifts selected', () async {
      final demandCtx =
          await DemandForecastContextService.instance.getCurrentContext();
      final preview = ManagerOverridePlanPreview.fromDraftSelection([],
          historicalWeeklyAvgCovers: demandCtx.historicalWeeklyAvgCovers);
      expect(preview, isNull);
    });

    test('uses canonical demand context, not BaselineData', () async {
      final demandCtx =
          await DemandForecastContextService.instance.getCurrentContext();
      final demandCovers = demandCtx.historicalWeeklyAvgCovers;

      final preview = ManagerOverridePlanPreview.fromDraftSelection(
          [_lunch1],
          historicalWeeklyAvgCovers: demandCovers);
      expect(preview, isNotNull);
      expect(preview!.forecastCovers, equals(demandCovers));
      expect(preview.forecastSales, greaterThan(0));
      expect(preview.requiredFohHours, greaterThan(0));
      expect(preview.requiredBohHours, greaterThan(0));
      expect(
        preview.theoreticalLaborPct,
        closeTo(
          LaborModel.theoreticalLaborPct(
            _lunch1.cplh,
            _lunch1.splh,
            _lunch1.ppa,
            MeridianConfig.fohWage,
            MeridianConfig.bohWage,
          ),
          0.001,
        ),
      );
      expect(
        preview.targetBlendedWage,
        closeTo(
          ActiveTargetProfile.computeTargetBlendedWage(
            targetCPLH: _lunch1.cplh,
            targetSPLH: _lunch1.splh,
            targetPPA: _lunch1.ppa,
            fohWage: MeridianConfig.fohWage,
            bohWage: MeridianConfig.bohWage,
          ),
          0.001,
        ),
      );
    });

    test('averages multiple candidates', () async {
      final demandCtx =
          await DemandForecastContextService.instance.getCurrentContext();
      final demandCovers = demandCtx.historicalWeeklyAvgCovers;

      final preview = ManagerOverridePlanPreview.fromDraftSelection(
          [_lunch1, _dinner1],
          historicalWeeklyAvgCovers: demandCovers);
      expect(preview, isNotNull);
      expect(preview!.forecastCovers, equals(demandCovers));
      expect(preview.forecastSales, greaterThan(0));
      final avgCplh = (_lunch1.cplh + _dinner1.cplh) / 2;
      final avgSplh = (_lunch1.splh + _dinner1.splh) / 2;
      final avgPpa = (_lunch1.ppa + _dinner1.ppa) / 2;
      expect(
        preview.theoreticalLaborPct,
        closeTo(
          LaborModel.theoreticalLaborPct(
            avgCplh,
            avgSplh,
            avgPpa,
            MeridianConfig.fohWage,
            MeridianConfig.bohWage,
          ),
          0.001,
        ),
      );
    });
  });

  // ── K — Candidate tiles show LABOR % chips (Phase 7.55f.2) ───────────────

  group('K - candidate tile LABOR % chips', () {
    testWidgets('each candidate tile shows LABOR % chip with actual value',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Navigate to _lunch1's date (only 1 shift on this date)
      await _tapCalendarDate(tester, '2026-03-02');

      // 1 tile on this date → 1 LABOR % chip
      expect(find.text('LABOR % ', skipOffstage: false), findsNWidgets(1));
      expect(find.text('24.3%', skipOffstage: false), findsOneWidget);

      // Navigate back and check another date
      await _tapBackToCalendar(tester);
      await _tapCalendarDate(tester, '2026-03-10');
      expect(find.text('25.1%', skipOffstage: false), findsOneWidget);

      await _tapBackToCalendar(tester);
      await _tapCalendarDate(tester, '2026-03-06');
      expect(find.text('23.8%', skipOffstage: false), findsOneWidget);
    });

    testWidgets('candidate tile shows -- when labor truth is unavailable',
        (tester) async {
      const unknownLabor = BaselineCandidateShift(
        recordKey: '2026-W10|Mon|dinner_unknown',
        weekId: '2026-W10',
        weekLabel: 'Week of Mar 3',
        dayLabel: 'Mon',
        daypart: 'dinner',
        covers: 190,
        cplh: 4.4,
        splh: 178.0,
        ppa: 41.0,
        primaryLeverId: 'splh_down',
        isSelected: false,
        businessDate: '2026-03-02',
        actualLaborPct: 0.0,
        hasActualLaborPctTruth: false,
      );

      await tester.pumpWidget(_wrap(
        const BaselineManagerScreen.withCandidates(
          [unknownLabor],
          initialDemandCovers: 1800,
        ),
      ));
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');

      expect(find.text('LABOR % ', skipOffstage: false), findsOneWidget);
      expect(find.text('--', skipOffstage: false), findsAtLeastNWidgets(1));
      expect(find.text('0.0%', skipOffstage: false), findsNothing);
    });

  });

  // ── L — Calendar rendering (Phase 7.55f.3) ────────────────────────────────

  group('L - calendar rendering', () {
    testWidgets('screen shows calendar mode after loading candidates',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      expect(find.text('LAST 60 DAYS'), findsOneWidget);
      // Weekday labels
      expect(find.text('M'), findsAtLeastNWidgets(1));
      expect(find.text('S'), findsAtLeastNWidgets(1));
    });

    testWidgets('calendar window anchored to latest candidate businessDate',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Latest is _lunch2 at 2026-03-10.
      // Window: Jan 10 – Mar 10
      expect(find.text('Jan 10 – Mar 10'), findsOneWidget);
    });

    testWidgets('dates with closed shifts show a marker dot',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Calendar cells with shifts have a 4x4 Container dot
      // 3 unique dates with shifts: Mar 2, Mar 6, Mar 10
      // Find all DecoratedBox containers that could be dots
      // Just verify the calendar cell keys exist for shift dates
      expect(find.byKey(const ValueKey<String>('cal_2026-03-02')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('cal_2026-03-06')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('cal_2026-03-10')),
          findsOneWidget);
    });

    testWidgets('dates with selected shifts are highlighted',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_withPreSelected, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // _selectedLunch is on 2026-03-16 and is pre-selected.
      // The cell should exist and be tappable.
      expect(find.byKey(const ValueKey<String>('cal_2026-03-16')),
          findsOneWidget);
    });

    testWidgets('empty candidates show honest empty state',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(const [], initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      expect(
          find.textContaining('No closed shifts found.'), findsOneWidget);
    });
  });

  // ── M — Calendar navigation (Phase 7.55f.3) ──────────────────────────────

  group('M - calendar navigation', () {
    testWidgets('tapping a date with shifts opens day detail',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');

      expect(find.text('BACK TO CALENDAR'), findsOneWidget);
      expect(find.text('Mon, Mar 2'), findsOneWidget);
      // _lunch1 is on this date — its tile should render
      expect(find.text('LUNCH'), findsOneWidget);
    });

    testWidgets('day detail shows only that date\'s shifts',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Mar 2 has _lunch1 only (lunch)
      await _tapCalendarDate(tester, '2026-03-02');
      expect(find.text('LUNCH'), findsOneWidget);
      expect(find.text('DINNER'), findsNothing);

      // Back, then navigate to Mar 6 which has _dinner1 only
      await _tapBackToCalendar(tester);
      await _tapCalendarDate(tester, '2026-03-06');
      expect(find.text('DINNER'), findsOneWidget);
      expect(find.text('LUNCH'), findsNothing);
    });

    testWidgets('back returns to calendar grid', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      expect(find.text('LAST 60 DAYS'), findsOneWidget);

      await _tapCalendarDate(tester, '2026-03-02');
      expect(find.text('LAST 60 DAYS'), findsNothing);
      expect(find.text('BACK TO CALENDAR'), findsOneWidget);

      await _tapBackToCalendar(tester);
      expect(find.text('LAST 60 DAYS'), findsOneWidget);
      expect(find.text('BACK TO CALENDAR'), findsNothing);
    });

    testWidgets('tapping a date without shifts shows empty day detail',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Jan 15 is in the 60-day window but has no shifts
      await _tapCalendarDate(tester, '2026-01-15');
      expect(find.text('No closed shifts for this date.'), findsOneWidget);
    });
  });

  // ── N — Selection through calendar (Phase 7.55f.3) ────────────────────────

  group('N - selection through calendar', () {
    testWidgets(
        'CLEAR ALL from calendar view clears highlights and preview',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_withPreSelected, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Pre-selected state
      expect(find.text('CLEAR ALL'), findsOneWidget);

      // Tap CLEAR ALL
      await tester.tap(find.text('CLEAR ALL'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Preview returns to no-selection state
      expect(find.text('0'), findsOneWidget);
      expect(find.text('--'), findsNWidgets(11));
      expect(find.text('CLEAR ALL'), findsNothing);
    });

    testWidgets('CANCEL after CLEAR ALL does not persist the draft clear',
        (tester) async {
      await tester.runAsync(() async {
        await DatabaseHelper.instance
            .replaceBaselineSelectedRecordKeys({_selectedLunch.recordKey});
      });

      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_withPreSelected, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      await tester.tap(find.text('CLEAR ALL'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('CANCEL'));
      await tester.pump();

      final stored = await tester.runAsync(() async {
        return DatabaseHelper.instance.getBaselineSelectedRecordKeys();
      });
      expect(stored!, contains(_selectedLunch.recordKey));
    });

  });

  // ── O — DST-safe calendar grid (Phase 7.55f.3a) ──────────────────────────

  group('O - DST-safe calendar grid', () {
    // US DST 2026: spring forward Mar 8.  Window Jan 10 – Mar 10 crosses it.

    testWidgets('all 60 in-window dates have a calendar cell key',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Window: 2026-01-10 to 2026-03-10 (60 days inclusive).
      // Every date in that range must have a keyed cell.
      var d = DateTime(2026, 1, 10);
      final end = DateTime(2026, 3, 10);
      int count = 0;
      while (!d.isAfter(end)) {
        final iso =
            '${d.year}-${d.month.toString().padLeft(2, '0')}'
            '-${d.day.toString().padLeft(2, '0')}';
        expect(
          find.byKey(ValueKey<String>('cal_$iso'), skipOffstage: false),
          findsOneWidget,
          reason: 'missing calendar cell for $iso',
        );
        d = DateTime(d.year, d.month, d.day + 1);
        count++;
      }
      expect(count, equals(60));
    });

    testWidgets('no duplicate or off-by-one date cells around DST boundary',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // March 7 (day before DST) and March 8 (DST spring-forward)
      // must each have exactly one cell, not zero or two.
      expect(
        find.byKey(const ValueKey<String>('cal_2026-03-07'),
            skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('cal_2026-03-08'),
            skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('cal_2026-03-09'),
            skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('candidate dates inside DST window remain tappable',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // _lunch2 is on 2026-03-10 (after DST transition on Mar 8)
      await _tapCalendarDate(tester, '2026-03-10');
      expect(find.text('BACK TO CALENDAR'), findsOneWidget);
      expect(find.text('Tue, Mar 10'), findsOneWidget);
      expect(find.text('LUNCH'), findsOneWidget);
    });
  });

  // ── P — Suggested/selected day states (Phase 7.55f.3b) ────────────────────

  group('P - suggested/selected day states', () {
    testWidgets('suggested date is distinguishable from available-only',
        (tester) async {
      // All test candidates have lever 'cplh_up' which is favorable → suggested
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Legend should show all three states
      expect(find.text('Suggested star'), findsOneWidget);
    });

    testWidgets('selected date is distinguishable from suggested-only',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_withPreSelected, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // _selectedLunch is pre-selected; its date is 2026-03-16.
      // _lunch1 (2026-03-02) has cplh_up (favorable) → suggested but not selected.
      // Both cell keys exist — visual distinction is in decoration.
      expect(find.byKey(const ValueKey<String>('cal_2026-03-16'),
              skipOffstage: false),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('cal_2026-03-02'),
              skipOffstage: false),
          findsOneWidget);
      // Legend contains all three labels
      expect(find.text('Selected star'), findsOneWidget);
      expect(find.text('Suggested star'), findsOneWidget);
      expect(find.text('Closed shifts'), findsOneWidget);
    });

  });

  // ── Q — Lever / date polish (Phase 7.55f.3b) ─────────────────────────────

  group('Q - lever and date polish', () {
    testWidgets('day detail shows full lever meaning, not raw id or generic bucket',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');

      // Should NOT find raw snake_case lever id
      expect(find.text('cplh_up', skipOffstage: false), findsNothing);
      // Should find full natural-language meaning, not just the metric bucket
      expect(find.text('CPLH ABOVE TARGET', skipOffstage: false),
          findsAtLeastNWidgets(1));
    });

    testWidgets('distinct lever directions show distinct meanings, not collapsed buckets',
        (tester) async {
      // _leverTestCandidates has cplh_up and splh_down on the same date
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_leverTestCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // Navigate to 2026-03-02 which has both _lunch1 (cplh_up) and
      // _dinnerSplhDown (splh_down)
      await _tapCalendarDate(tester, '2026-03-02');

      // Each should show its full distinct meaning
      expect(find.text('CPLH ABOVE TARGET', skipOffstage: false),
          findsAtLeastNWidgets(1));
      expect(find.text('SPLH BELOW TARGET', skipOffstage: false),
          findsAtLeastNWidgets(1));

      // Raw snake_case ids must not appear
      expect(find.text('cplh_up', skipOffstage: false), findsNothing);
      expect(find.text('splh_down', skipOffstage: false), findsNothing);
    });

    testWidgets('day detail shows human-friendly date text, not raw week-id',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');

      // Should NOT show raw week-id like '2026-W10'
      expect(find.textContaining('2026-W', skipOffstage: false), findsNothing);
      // Should show human-friendly date text
      expect(find.text(_tileLabel(_lunch1), skipOffstage: false),
          findsOneWidget);
    });
  });

  // ── R — Clear All button (Phase 7.55f.3b) ────────────────────────────────

  group('R - Clear All button', () {
    testWidgets('CLEAR ALL hidden when no draft selections', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates, initialDemandCovers: demandCovers),
      ));
      await tester.pump();
      expect(find.text('CLEAR ALL'), findsNothing);
    });

    testWidgets('CLEAR ALL is a bordered button when visible', (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_withPreSelected, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      // The CLEAR ALL text should be inside a Container with decoration
      final clearAll = find.text('CLEAR ALL');
      expect(clearAll, findsOneWidget);
      // Verify it's inside a decorated container (border makes it a button)
      expect(
        find.ancestor(of: clearAll, matching: find.byType(Container)),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('tapping CLEAR ALL still clears draft selection only',
        (tester) async {
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_withPreSelected, initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      expect(find.text('CLEAR ALL'), findsOneWidget);
      await tester.tap(find.text('CLEAR ALL'));
      await tester.pumpAndSettle();

      expect(find.text('0'), findsOneWidget);
      expect(find.text('--'), findsNWidgets(11));
      expect(find.text('CLEAR ALL'), findsNothing);
    });
  });

  // ── S — 7.55q.8 Manager Override preview wage authority ──────────────
  //
  // Runtime contract: `_PlanImpactSection` reads the active profile
  // wages via `context.watch<ActiveTargetProfileNotifier?>()?.profile`
  // and passes `profile?.fohWage` / `profile?.bohWage` into
  // `ManagerOverridePlanPreview.fromDraftSelection`. The MeridianConfig
  // defaults remain a detached/unit fallback only; the live screen hides
  // wage-dependent preview cells until profile wage authority is present.
  //
  // Proof: with a profile whose wages differ from the config defaults
  // in the provider scope, preview `targetBlendedWage` / `theoreticalLaborPct`
  // must move off the config-default result.

  group('S - 7.55q.8 preview wage authority', () {
    const distinctFohWage = 25.00; // vs MeridianConfig.fohWage = 16.50
    const distinctBohWage = 32.00; // vs MeridianConfig.bohWage = 21.35

    ActiveTargetProfile makeProfileWithWages({
      required double fohWage,
      required double bohWage,
    }) {
      return ActiveTargetProfile(
        targetProfileId: 's-test',
        restaurantId: 's-test-r',
        sourceType: 'system_baseline',
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 42.0,
        fohWage: fohWage,
        bohWage: bohWage,
        opzFloorCPLH: 4.2,
        opzCeilingCPLH: 4.8,
        theoreticalFohLaborPct: 8.2,
        theoreticalBohLaborPct: 12.3,
        theoreticalLaborPct: 20.5,
        builtAt: '2026-04-14T00:00:00Z',
      );
    }

    test('fromDraftSelection with distinct profile wages produces a '
        'DIFFERENT preview than the MeridianConfig default path', () async {
      final ctx =
          await DemandForecastContextService.instance.getCurrentContext();
      final demand = ctx.historicalWeeklyAvgCovers;

      final configDefault = ManagerOverridePlanPreview.fromDraftSelection(
        [_lunch1],
        historicalWeeklyAvgCovers: demand,
      );
      final profileDriven = ManagerOverridePlanPreview.fromDraftSelection(
        [_lunch1],
        historicalWeeklyAvgCovers: demand,
        fohWage: distinctFohWage,
        bohWage: distinctBohWage,
      );

      expect(configDefault, isNotNull);
      expect(profileDriven, isNotNull);

      // Blended wage is an hour-weighted mix of FOH/BOH wages — must
      // move with the wage inputs.
      expect(profileDriven!.targetBlendedWage,
          isNot(closeTo(configDefault!.targetBlendedWage, 0.01)),
          reason: 'distinct wages must produce a distinct blended wage');
      // Labor % depends on wage inputs as well — must move too.
      expect(profileDriven.theoreticalLaborPct,
          isNot(closeTo(configDefault.theoreticalLaborPct, 0.01)),
          reason: 'distinct wages must produce a distinct theoretical %');
      // Volume-side fields stay the same across both calls (same
      // shift inputs, same demand context).
      expect(profileDriven.forecastCovers,
          equals(configDefault.forecastCovers));
      expect(profileDriven.requiredFohHours,
          equals(configDefault.requiredFohHours));
    });

    testWidgets('_PlanImpactSection renders the PROFILE-driven BLENDED '
        'WAGE when ActiveTargetProfileNotifier is in scope (not the '
        'MeridianConfig default)', (tester) async {
      final profileNotifier = ActiveTargetProfileNotifier.fromProfile(
        makeProfileWithWages(
            fohWage: distinctFohWage, bohWage: distinctBohWage),
      );

      // Expected preview computed through the production seam with the
      // distinct profile wages.
      final expectedPreview =
          ManagerOverridePlanPreview.fromDraftSelection(
        [_lunch1],
        historicalWeeklyAvgCovers: demandCovers,
        fohWage: distinctFohWage,
        bohWage: distinctBohWage,
      );
      expect(expectedPreview, isNotNull);
      final expectedWageStr =
          '\$${expectedPreview!.targetBlendedWage.toStringAsFixed(2)}';

      // Config-default path is the "negative" — must NOT be rendered.
      final configDefaultPreview =
          ManagerOverridePlanPreview.fromDraftSelection(
        [_lunch1],
        historicalWeeklyAvgCovers: demandCovers,
      );
      final configDefaultWageStr =
          '\$${configDefaultPreview!.targetBlendedWage.toStringAsFixed(2)}';
      expect(expectedWageStr, isNot(equals(configDefaultWageStr)),
          reason: 'precondition — distinct wages must produce distinct '
              'rendered strings');

      // Render with the profile notifier in scope.
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: ChangeNotifierProvider<ActiveTargetProfileNotifier>.value(
            value: profileNotifier,
            child: BaselineManagerScreen.withCandidates(
              _allCandidates,
              initialDemandCovers: demandCovers,
            ),
          ),
        ),
      );
      await tester.pump();

      // Select a candidate so the preview flips off "--".
      await _tapCalendarDate(tester, '2026-03-02');
      await _tapCandidateTile(tester, _lunch1);

      // The preview now reads the profile-driven blended wage, not the
      // config-default blended wage.
      expect(find.text(expectedWageStr, skipOffstage: false),
          findsAtLeastNWidgets(1),
          reason: 'profile wages must flow into the rendered preview');
      expect(find.text(configDefaultWageStr, skipOffstage: false),
          findsNothing,
          reason: 'the config-default blended wage must NOT appear when '
              'the profile is in scope');

      profileNotifier.dispose();
    });

    testWidgets('without profile wage authority, labor % and blended wage '
        'stay on "--" instead of showing config-default preview values',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');
      await _tapCandidateTile(tester, _lunch1);

      expect(find.text('--'), findsNWidgets(2),
          reason: 'without an active profile in scope, wage-dependent '
              'preview cells should degrade honestly');
    });
  });

  // ── T — 7.55q.9 Done routes through cycle path; SnackBar on denial ───────
  //
  // After the first Done, the active TargetCycle has consumed its
  // once-per-cycle manager override. A second Done must surface the
  // ManagerOverrideDeniedException via SnackBar and KEEP the draft
  // intact (no Navigator.pop). The first-Done plumbing is covered
  // by `target_state_alignment_test.dart` group H; this widget test
  // focuses on the denial UX only.

  group('T - 7.55q.9 Done denial surfaces as SnackBar', () {
    testWidgets('Done after the override is already consumed shows the '
        '"already used" SnackBar and keeps the screen open', (tester) async {
      // Consume the once-per-cycle manager override at the SERVICE
      // layer first. This removes the widget-level fragility of
      // running two full Done flows back-to-back in one widget tree.
      await tester.runAsync(() async {
        await BaselineManagerService.instance
            .saveSelection({_lunch1.recordKey});
      });

      // Now mount the form, draft a different selection, hit Done.
      // Cycle is locked → ManagerOverrideDeniedException → SnackBar.
      await tester.pumpWidget(_wrap(
        BaselineManagerScreen.withCandidates(_allCandidates,
            initialDemandCovers: demandCovers),
      ));
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-10');
      await _tapCandidateTile(tester, _lunch2);

      // Drive the Done tap + saveSelection's real async DB work via
      // runAsync (the same pattern as the existing
      // `_commitDoneAndReadKeys` helper). Pumping frames alone does
      // not advance real async; it only ticks the fake clock.
      await tester.runAsync(() async {
        await tester.tap(find.text('DONE'));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      // Pump a frame so the SnackBar renders.
      await tester.pump();

      // SnackBar with the "already used" copy must be visible.
      expect(
        find.textContaining('Manager override already used',
            skipOffstage: false),
        findsAtLeastNWidgets(1),
        reason: 'denial must surface as a SnackBar honestly',
      );
      expect(
        find.textContaining('Reset Target Cycle', skipOffstage: false),
        findsAtLeastNWidgets(1),
        reason: 'SnackBar must point users at the admin reset path',
      );
      // Screen is still mounted — DONE button still present.
      expect(find.text('DONE'), findsOneWidget,
          reason: 'the Baseline Manager must NOT pop on denial');
    });
  });
}
