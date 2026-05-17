import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/state/active_target_profile_notifier.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/database_helper.dart';
import 'package:forge_and_flow/services/demand_forecast_context_service.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_day_sheet.dart';
import 'package:forge_and_flow/services/labor_model.dart';
import 'package:forge_and_flow/services/star_target_selection_write_service.dart';
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
  child: MaterialApp(theme: ThemeData.dark(), home: child),
);

// ── R2 navigation helpers ─────────────────────────────────────────────────────
// R2 replaced the full-screen day-detail PUSH navigation with an in-place
// `showModalBottomSheet`. Tapping a calendar day opens the sheet; there
// is no route push and no "BACK TO CALENDAR" affordance. The default
// lens ("Whole day") opens the whole-day rollup sheet; a period lens
// opens that period's single-shift sheet.

Future<void> _tapCalendarDate(WidgetTester tester, String date) async {
  final finder = find.byKey(ValueKey<String>('cal_$date'));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tap(find.text('CLOSE'));
  await tester.pumpAndSettle();
}

/// Dismiss a modal bottom sheet that has no CLOSE affordance (the
/// period-lens variant closes via its SELECT/REMOVE action; a test that
/// only wants to move on taps the scrim/barrier instead).
Future<void> _dismissModalBarrier(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

Future<void> _tapLensChip(WidgetTester tester, String lensId) async {
  await tester.tap(find.byKey(ValueKey<String>('lens_$lensId')));
  await tester.pumpAndSettle();
}

/// Toggle a service inside the open WHOLE-DAY sheet via its per-service
/// breakdown row. The sheet stays open after the toggle.
Future<void> _toggleWholeDayService(
  WidgetTester tester,
  String periodLabel,
) async {
  final row = find.descendant(
    of: find.byType(BottomSheet),
    matching: find.text(periodLabel),
  );
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

/// Finds the SELECTED SHIFTS preview-cell value. The cell renders
/// "SELECTED SHIFTS" then the count in the next Text in the same Column;
/// the calendar day-number cells also render bare digits, so count
/// assertions must be scoped here, not to a bare `find.text`.
Finder _selectedShiftsValue() {
  return find.descendant(
    of: find.ancestor(
      of: find.text('SELECTED SHIFTS'),
      matching: find.byType(Column),
    ).first,
    matching: find.byType(Text),
  );
}

void _expectSelectedShiftsCount(WidgetTester tester, String count) {
  final texts = tester.widgetList<Text>(_selectedShiftsValue()).toList();
  // [0] = label "SELECTED SHIFTS", [1] = the value.
  expect(
    texts.any((t) => t.data == count),
    isTrue,
    reason: 'SELECTED SHIFTS cell should show $count',
  );
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
    BaselineManagerService.instance.serverSelectionWriter = null;
    await DatabaseHelper.instance.reseedDemo();
    await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({});
    final ctx = await DemandForecastContextService.instance.getCurrentContext();
    demandCovers = ctx.historicalWeeklyAvgCovers;
  });

  tearDown(() {
    BaselineManagerService.instance.serverSelectionWriter = null;
  });

  testWidgets('shows loading indicator when no initialCandidates provided', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const BaselineManagerScreen()));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  group('A - required labels present', () {
    testWidgets('page title, buttons, and all preview labels render', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
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
    testWidgets('SELECTED SHIFTS shows 0 when nothing selected', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('all metric cells show -- when nothing selected', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();
      // 5 target standard cells + 6 plan impact cells = 11
      expect(find.text('--'), findsNWidgets(11));
    });
  });

  group('C - live preview updates on selection', () {
    testWidgets('selecting one candidate clears all -- from preview', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('--'), findsNWidgets(11));

      // Default whole-day lens: tap the date, toggle the lunch service
      // in the sheet, then close so the preview underneath is visible.
      await _tapCalendarDate(tester, '2026-03-02');
      await _toggleWholeDayService(tester, 'Lunch');
      await _closeSheet(tester);

      expect(find.text('--'), findsNothing);
    });

    testWidgets('count increments to 1 after first selection', (tester) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');
      await _toggleWholeDayService(tester, 'Lunch');
      await _closeSheet(tester);

      _expectSelectedShiftsCount(tester, '1');
    });
  });

  group('D - period-lens sheet shows required metrics', () {
    testWidgets('period-lens tap opens a bottom sheet with the 6 metrics', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapLensChip(tester, 'lunch');
      await _tapCalendarDate(tester, '2026-03-02');

      // The sheet is a modal overlay, not a route push.
      expect(find.byType(BottomSheet), findsOneWidget);
      final inSheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: inSheet, matching: find.text('CPLH')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('COVERS')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('SPLH')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('PPA')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('LABOR %')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('LEVER')),
        findsOneWidget,
      );
      // Primary toggle action.
      expect(
        find.descendant(of: inSheet, matching: find.text('SELECT')),
        findsOneWidget,
      );
    });

    testWidgets('period-lens sheet shows the lever full meaning', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapLensChip(tester, 'lunch');
      await _tapCalendarDate(tester, '2026-03-02');

      expect(find.text('cplh_up', skipOffstage: false), findsNothing);
      expect(
        find.text('CPLH above target', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
    });
  });

  group('E - Cancel discards draft', () {
    testWidgets('Cancel does not write selection to DB', (tester) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');
      await _toggleWholeDayService(tester, 'Lunch');
      await _closeSheet(tester);
      _expectSelectedShiftsCount(tester, '1');

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
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');
      await _toggleWholeDayService(tester, 'Lunch');
      await _closeSheet(tester);
      _expectSelectedShiftsCount(tester, '1');

      final stored = await _commitDoneAndReadKeys(tester);
      expect(stored, contains(_lunch1.recordKey));
    });
  });

  group('G - Done with empty draft clears override', () {
    testWidgets('deselect all then Done empties DB and clears override', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({
          _selectedLunch.recordKey,
        });
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

      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _withPreSelected,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // Clear all selections via CLEAR ALL button. R1 moved CLEAR ALL
      // into a scrollable band; ensure visible before tapping.
      final clearAll = find.text('CLEAR ALL');
      await tester.ensureVisible(clearAll);
      await tester.pumpAndSettle();
      await tester.tap(clearAll);
      await tester.pumpAndSettle();
      expect(find.text('0', skipOffstage: false), findsOneWidget);

      final stored = await _commitDoneAndReadKeys(tester);

      expect(stored, isEmpty);
      expect(BaselineData.hasManagerOverride, isFalse);
    });
  });

  // ── H — Plan impact preview: selected-shift behavior ──────────────────────

  group('H - plan impact selected-shift behavior', () {
    testWidgets('selecting one candidate shows plan impact values', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');
      await _toggleWholeDayService(tester, 'Lunch');
      await _closeSheet(tester);

      // Forecast covers fixed from canonical demand context
      final expectedCovers = demandCovers;
      expect(expectedCovers, isNot(equals(_lunch1.covers)));
      expect(
        find.text('$expectedCovers', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
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

    test(
      'different PPA → same forecast covers, different sales and BOH hrs',
      () async {
        final demandCtx = await DemandForecastContextService.instance
            .getCurrentContext();
        final demandCovers = demandCtx.historicalWeeklyAvgCovers;

        final previewLow = ManagerOverridePlanPreview.fromDraftSelection([
          lowPPA,
        ], historicalWeeklyAvgCovers: demandCovers);
        final previewHigh = ManagerOverridePlanPreview.fromDraftSelection([
          highPPA,
        ], historicalWeeklyAvgCovers: demandCovers);

        expect(previewLow, isNotNull);
        expect(previewHigh, isNotNull);

        // Forecast covers are fixed from demand — same regardless of PPA.
        expect(previewLow!.forecastCovers, equals(previewHigh!.forecastCovers));
        expect(previewLow.forecastCovers, equals(demandCovers));

        // Forecast sales changes: covers * PPA.
        expect(
          previewHigh.forecastSales,
          greaterThan(previewLow.forecastSales),
        );

        // FOH hours unchanged (driven by covers/CPLH, same for both).
        expect(
          previewLow.requiredFohHours,
          equals(previewHigh.requiredFohHours),
        );

        // BOH hours change (driven by sales/SPLH, sales differs).
        expect(
          previewHigh.requiredBohHours,
          greaterThan(previewLow.requiredBohHours),
        );
      },
    );
  });

  // ── J — ManagerOverridePlanPreview unit tests ─────────────────────────────

  group('J - ManagerOverridePlanPreview unit', () {
    test('returns null when no shifts selected', () async {
      final demandCtx = await DemandForecastContextService.instance
          .getCurrentContext();
      final preview = ManagerOverridePlanPreview.fromDraftSelection(
        [],
        historicalWeeklyAvgCovers: demandCtx.historicalWeeklyAvgCovers,
      );
      expect(preview, isNull);
    });

    test('uses canonical demand context, not BaselineData', () async {
      final demandCtx = await DemandForecastContextService.instance
          .getCurrentContext();
      final demandCovers = demandCtx.historicalWeeklyAvgCovers;

      final preview = ManagerOverridePlanPreview.fromDraftSelection([
        _lunch1,
      ], historicalWeeklyAvgCovers: demandCovers);
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
      final demandCtx = await DemandForecastContextService.instance
          .getCurrentContext();
      final demandCovers = demandCtx.historicalWeeklyAvgCovers;

      final preview = ManagerOverridePlanPreview.fromDraftSelection([
        _lunch1,
        _dinner1,
      ], historicalWeeklyAvgCovers: demandCovers);
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

  // ── K — Period-lens sheet shows LABOR % ──────────────────────────────────

  group('K - period-lens sheet LABOR %', () {
    testWidgets('period-lens sheet shows LABOR % with the actual value', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapLensChip(tester, 'lunch');
      await _tapCalendarDate(tester, '2026-03-02');

      // Scope to the sheet: the preview panel behind the modal also
      // carries a "LABOR %" cell.
      final inSheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: inSheet, matching: find.text('LABOR %')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('24.3%')),
        findsOneWidget,
      );

      await _dismissModalBarrier(tester);
      await _tapCalendarDate(tester, '2026-03-10');
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('25.1%'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('period-lens sheet shows -- when labor truth is unavailable', (
      tester,
    ) async {
      const unknownLabor = BaselineCandidateShift(
        recordKey: '2026-W10|Mon|lunch_unknown',
        weekId: '2026-W10',
        weekLabel: 'Week of Mar 3',
        dayLabel: 'Mon',
        daypart: 'lunch',
        covers: 190,
        cplh: 4.4,
        splh: 178.0,
        ppa: 41.0,
        primaryLeverId: 'cplh_up',
        isSelected: false,
        businessDate: '2026-03-02',
        actualLaborPct: 0.0,
        hasActualLaborPctTruth: false,
      );

      await tester.pumpWidget(
        _wrap(
          const BaselineManagerScreen.withCandidates([
            unknownLabor,
          ], initialDemandCovers: 1800),
        ),
      );
      await tester.pump();

      await _tapLensChip(tester, 'lunch');
      await _tapCalendarDate(tester, '2026-03-02');

      final inSheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: inSheet, matching: find.text('LABOR %')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('--')),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('0.0%')),
        findsNothing,
      );
    });
  });

  // ── L — Calendar rendering (Phase 7.55f.3) ────────────────────────────────

  group('L - calendar rendering', () {
    testWidgets('screen shows calendar mode after loading candidates', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('LAST 60 DAYS'), findsOneWidget);
      // Weekday labels
      expect(find.text('M'), findsAtLeastNWidgets(1));
      expect(find.text('S'), findsAtLeastNWidgets(1));
    });

    testWidgets('calendar window anchored to latest candidate businessDate', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // Latest is _lunch2 at 2026-03-10.
      // R1: window range uses the word "to", no dash separator.
      expect(find.text('Jan 10 to Mar 10'), findsOneWidget);
    });

    testWidgets('dates with closed shifts have a keyed cell', (tester) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('cal_2026-03-02')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('cal_2026-03-06')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('cal_2026-03-10')),
        findsOneWidget,
      );
    });

    testWidgets('dates with selected shifts are highlighted', (tester) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _withPreSelected,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('cal_2026-03-16')),
        findsOneWidget,
      );
    });

    testWidgets('empty candidates show honest empty state', (tester) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            const [],
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('No closed shifts found.'), findsOneWidget);
    });
  });

  // ── M — Tap-day bottom sheet (R2) ─────────────────────────────────────────

  group('M - tap-day bottom sheet', () {
    testWidgets('tapping a date opens a modal sheet, not a route push', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // The calendar header is still mounted underneath (no route swap).
      await _tapCalendarDate(tester, '2026-03-02');
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('LAST 60 DAYS'), findsOneWidget);
      // No legacy push-nav affordance.
      expect(find.text('BACK TO CALENDAR'), findsNothing);
    });

    testWidgets('whole-day sheet shows only that date\'s services', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // Mar 2 has _lunch1 only.
      await _tapCalendarDate(tester, '2026-03-02');
      final inSheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: inSheet, matching: find.text('Lunch')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('Dinner')),
        findsNothing,
      );

      await _closeSheet(tester);
      // Mar 6 has _dinner1 only.
      await _tapCalendarDate(tester, '2026-03-06');
      final inSheet2 = find.byType(BottomSheet);
      expect(
        find.descendant(of: inSheet2, matching: find.text('Dinner')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet2, matching: find.text('Lunch')),
        findsNothing,
      );
    });

    testWidgets('CLOSE dismisses the whole-day sheet, calendar remains', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');
      expect(find.byType(BottomSheet), findsOneWidget);

      await _closeSheet(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('LAST 60 DAYS'), findsOneWidget);
    });

    testWidgets('tapping a date without shifts shows empty sheet state', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapCalendarDate(tester, '2026-01-15');
      expect(find.text('No closed shifts for this date.'), findsOneWidget);
    });
  });

  // ── N — Selection through calendar (Phase 7.55f.3) ────────────────────────

  group('N - selection through calendar', () {
    testWidgets('CLEAR ALL from calendar view clears highlights and preview', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _withPreSelected,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      final clearAll = find.text('CLEAR ALL');
      expect(clearAll, findsOneWidget);
      await tester.ensureVisible(clearAll);
      await tester.pumpAndSettle();

      await tester.tap(clearAll);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('0', skipOffstage: false), findsOneWidget);
      expect(find.text('--', skipOffstage: false), findsNWidgets(11));
      expect(find.text('CLEAR ALL'), findsNothing);
    });

    testWidgets('CANCEL after CLEAR ALL does not persist the draft clear', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({
          _selectedLunch.recordKey,
        });
      });

      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _withPreSelected,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
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
    testWidgets('all 60 in-window dates have a calendar cell key', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

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

    testWidgets('no duplicate or off-by-one date cells around DST boundary', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(
          const ValueKey<String>('cal_2026-03-07'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('cal_2026-03-08'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('cal_2026-03-09'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    });

    testWidgets('candidate dates inside DST window remain tappable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // _lunch2 is on 2026-03-10 (after DST transition on Mar 8)
      await _tapCalendarDate(tester, '2026-03-10');
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Tue, Mar 10'), findsOneWidget);
    });
  });

  // ── P - R1 2-state calendar (suggested state + legend removed) ────────────

  group('P - R1 2-state calendar', () {
    testWidgets('the old suggested-state legend is gone', (tester) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Suggested star'), findsNothing);
      expect(find.text('Selected star'), findsNothing);
      expect(find.text('Closed shifts'), findsNothing);
    });

    testWidgets('selected and closed-only day cells both render', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _withPreSelected,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(
          const ValueKey<String>('cal_2026-03-16'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('cal_2026-03-02'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    });
  });

  // ── Q — Lever / date polish ──────────────────────────────────────────────

  group('Q - lever and date polish', () {
    testWidgets(
      'period-lens sheet shows full lever meaning, not raw id',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            BaselineManagerScreen.withCandidates(
              _leverTestCandidates,
              initialDemandCovers: demandCovers,
            ),
          ),
        );
        await tester.pump();

        await _tapLensChip(tester, 'dinner');
        await _tapCalendarDate(tester, '2026-03-02');

        // _dinnerSplhDown on 2026-03-02 under the dinner lens.
        expect(
          find.text('SPLH below target', skipOffstage: false),
          findsAtLeastNWidgets(1),
        );
        expect(find.text('splh_down', skipOffstage: false), findsNothing);
      },
    );

    testWidgets('whole-day sheet shows human-friendly date, not raw week-id', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-02');

      expect(find.textContaining('2026-W', skipOffstage: false), findsNothing);
      expect(find.text('Mon, Mar 2'), findsOneWidget);
    });
  });

  // ── R — Clear All button (Phase 7.55f.3b) ────────────────────────────────

  group('R - Clear All button', () {
    testWidgets('CLEAR ALL hidden when no draft selections', (tester) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('CLEAR ALL'), findsNothing);
    });

    testWidgets('CLEAR ALL is a bordered button when visible', (tester) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _withPreSelected,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      final clearAll = find.text('CLEAR ALL');
      expect(clearAll, findsOneWidget);
      expect(
        find.ancestor(of: clearAll, matching: find.byType(Container)),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('tapping CLEAR ALL still clears draft selection only', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _withPreSelected,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      final clearAll = find.text('CLEAR ALL');
      expect(clearAll, findsOneWidget);
      await tester.ensureVisible(clearAll);
      await tester.pumpAndSettle();
      await tester.tap(clearAll);
      await tester.pumpAndSettle();

      expect(find.text('0', skipOffstage: false), findsOneWidget);
      expect(find.text('--', skipOffstage: false), findsNWidgets(11));
      expect(find.text('CLEAR ALL'), findsNothing);
    });
  });

  // ── S — 7.55q.8 Manager Override preview wage authority ──────────────

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
      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();
      final demand = ctx.historicalWeeklyAvgCovers;

      final configDefault = ManagerOverridePlanPreview.fromDraftSelection([
        _lunch1,
      ], historicalWeeklyAvgCovers: demand);
      final profileDriven = ManagerOverridePlanPreview.fromDraftSelection(
        [_lunch1],
        historicalWeeklyAvgCovers: demand,
        fohWage: distinctFohWage,
        bohWage: distinctBohWage,
      );

      expect(configDefault, isNotNull);
      expect(profileDriven, isNotNull);

      expect(
        profileDriven!.targetBlendedWage,
        isNot(closeTo(configDefault!.targetBlendedWage, 0.01)),
        reason: 'distinct wages must produce a distinct blended wage',
      );
      expect(
        profileDriven.theoreticalLaborPct,
        isNot(closeTo(configDefault.theoreticalLaborPct, 0.01)),
        reason: 'distinct wages must produce a distinct theoretical %',
      );
      expect(
        profileDriven.forecastCovers,
        equals(configDefault.forecastCovers),
      );
      expect(
        profileDriven.requiredFohHours,
        equals(configDefault.requiredFohHours),
      );
    });

    testWidgets('_PlanImpactSection renders the PROFILE-driven BLENDED '
        'WAGE when ActiveTargetProfileNotifier is in scope (not the '
        'MeridianConfig default)', (tester) async {
      final profileNotifier = ActiveTargetProfileNotifier.fromProfile(
        makeProfileWithWages(
          fohWage: distinctFohWage,
          bohWage: distinctBohWage,
        ),
      );

      final expectedPreview = ManagerOverridePlanPreview.fromDraftSelection(
        [_lunch1],
        historicalWeeklyAvgCovers: demandCovers,
        fohWage: distinctFohWage,
        bohWage: distinctBohWage,
      );
      expect(expectedPreview, isNotNull);
      final expectedWageStr =
          '\$${expectedPreview!.targetBlendedWage.toStringAsFixed(2)}';

      final configDefaultPreview =
          ManagerOverridePlanPreview.fromDraftSelection([
            _lunch1,
          ], historicalWeeklyAvgCovers: demandCovers);
      final configDefaultWageStr =
          '\$${configDefaultPreview!.targetBlendedWage.toStringAsFixed(2)}';
      expect(
        expectedWageStr,
        isNot(equals(configDefaultWageStr)),
        reason:
            'precondition — distinct wages must produce distinct '
            'rendered strings',
      );

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

      await _tapCalendarDate(tester, '2026-03-02');
      await _toggleWholeDayService(tester, 'Lunch');
      await _closeSheet(tester);

      expect(
        find.text(expectedWageStr, skipOffstage: false),
        findsAtLeastNWidgets(1),
        reason: 'profile wages must flow into the rendered preview',
      );
      expect(
        find.text(configDefaultWageStr, skipOffstage: false),
        findsNothing,
        reason:
            'the config-default blended wage must NOT appear when '
            'the profile is in scope',
      );

      profileNotifier.dispose();
    });

    testWidgets('without profile wage authority, labor % and blended wage '
        'stay on "--" instead of showing config-default preview values', (
      tester,
    ) async {
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
      await _toggleWholeDayService(tester, 'Lunch');
      await _closeSheet(tester);

      expect(
        find.text('--'),
        findsNWidgets(2),
        reason:
            'without an active profile in scope, wage-dependent '
            'preview cells should degrade honestly',
      );
    });
  });

  // ── T — 7.55q.9 Done routes through cycle path; SnackBar on denial ───────

  group('T - 7.55q.9 Done denial surfaces as SnackBar', () {
    testWidgets('Done after the override is already consumed shows the '
        '"already used" SnackBar and keeps the screen open', (tester) async {
      await tester.runAsync(() async {
        await BaselineManagerService.instance.saveSelection({
          _lunch1.recordKey,
        });
      });

      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(
            _allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await _tapCalendarDate(tester, '2026-03-10');
      await _toggleWholeDayService(tester, 'Lunch');
      await _closeSheet(tester);

      await tester.runAsync(() async {
        await tester.tap(find.text('DONE'));
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      await tester.pump();

      expect(
        find.textContaining(
          'Manager override already used',
          skipOffstage: false,
        ),
        findsAtLeastNWidgets(1),
        reason: 'denial must surface as a SnackBar honestly',
      );
      expect(
        find.textContaining('Reset Target Cycle', skipOffstage: false),
        findsAtLeastNWidgets(1),
        reason: 'SnackBar must point users at the admin reset path',
      );
      expect(
        find.text('DONE'),
        findsOneWidget,
        reason: 'the Baseline Manager must NOT pop on denial',
      );
    });
  });

  group('U - server star-target write errors surface as SnackBar', () {
    testWidgets('permission denied keeps the screen open', (tester) async {
      final candidate = (await tester.runAsync(
        BaselineManagerService.instance.getCandidateShifts,
      ))!.first;
      BaselineManagerService.instance.serverSelectionWriter =
          const _FailingBaselineServerSelectionWriter(
            StarTargetSelectionWriteException(
              code: 'permission_denied',
              message: 'denied',
              statusCode: 403,
            ),
          );

      await tester.pumpWidget(
        _wrap(
          BaselineManagerScreen.withCandidates(<BaselineCandidateShift>[
            candidate,
          ], initialDemandCovers: demandCovers),
        ),
      );
      await tester.pump();

      // Use the period lens for this candidate so the single-shift
      // sheet's SELECT action toggles and auto-closes.
      await _tapLensChip(tester, candidate.daypart);
      await _tapCalendarDate(tester, candidate.businessDate!);
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('SELECT'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.text('DONE'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();

      expect(
        find.textContaining('do not have permission', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
      expect(find.text('DONE'), findsOneWidget);
      final stored = await tester.runAsync(
        DatabaseHelper.instance.getBaselineSelectedRecordKeys,
      );
      expect(stored, isEmpty);
    });
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

    testWidgets(
      'a) lens options derive from the configured 4-period config',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            BaselineManagerScreen.withCandidates(
              _allCandidates,
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
      },
    );

    testWidgets(
      'b) calendar 2-state cell filters by the active lens period',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            BaselineManagerScreen.withCandidates(
              _withPreSelected,
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

        await tester.tap(
          find.byKey(const ValueKey<String>('lens_lunch')),
        );
        await tester.pump();
        final lunchLensDinnerBorder =
            (decoFor('2026-03-06').border! as Border).top.color;
        expect(lunchLensDinnerBorder, Colors.transparent);

        final lunchLensSelected =
            (decoFor('2026-03-16').border! as Border).top.color;
        expect(lunchLensSelected, isNot(Colors.transparent));
      },
    );

    testWidgets(
      'c) pre-commit gate disables commit before any selection',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            BaselineManagerScreen.withCandidates(
              _allCandidates,
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
        expect(find.text('DONE'), findsNothing);
      },
    );

    testWidgets(
      'c) gate open: live commit, no disabled notice',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            BaselineManagerScreen.withCandidates(
              _allCandidates,
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
        expect(find.text('DONE'), findsOneWidget);
      },
    );
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
          _wrap(
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

        await _tapLensChip(tester, 'dinner');
        await _tapCalendarDate(tester, '2026-03-20');

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

    testWidgets(
      'b) whole-day rollup CPLH reconciles to the cover-weighted '
      'combination of that day\'s 4 services',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
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
        await _tapCalendarDate(tester, '2026-03-20');
        expect(
          find.byKey(const ValueKey<String>('whole_day_rollup_card')),
          findsOneWidget,
        );

        // Reconciliation: the rendered rollup CPLH must equal the
        // cover-weighted combination computed independently here,
        // mirroring TargetCycleDaypartPool.fromDayparts.
        final totalCovers =
            fourServiceDay.fold<int>(0, (s, c) => s + c.covers);
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
      },
    );

    testWidgets(
      'c) toggling a service in the whole-day sheet mutates the draft '
      'and the calendar reflects it (badge count)',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            BaselineManagerScreen.withCandidates(
              fourServiceDay,
              initialDemandCovers: demandCovers,
              initialDefs: fourPeriodDefs,
              initialCanOverride: true,
            ),
          ),
        );
        await tester.pump();

        // Whole-day badge before any selection: 0 of 4 services.
        expect(
          find.byKey(const ValueKey<String>('cal_badge_2026-03-20')),
          findsOneWidget,
        );
        expect(find.text('0/4'), findsOneWidget);

        await _tapCalendarDate(tester, '2026-03-20');
        // Toggle two services; the sheet STAYS open between toggles.
        await _toggleWholeDayService(tester, 'Lunch');
        expect(find.byType(BottomSheet), findsOneWidget);
        await _toggleWholeDayService(tester, 'Dinner');
        expect(find.byType(BottomSheet), findsOneWidget);

        await _closeSheet(tester);

        // Draft mutated: preview count is 2 and the calendar badge moves
        // to 2/4 (selection flowed only through the draft set).
        _expectSelectedShiftsCount(tester, '2');
        expect(find.text('2/4'), findsOneWidget);

        // Commit proves the draft set carried the toggled keys.
        final stored = await _commitDoneAndReadKeys(tester);
        expect(stored, containsAll(<String>[lShift.recordKey, dShift.recordKey]));
        expect(stored, isNot(contains(bShift.recordKey)));
        expect(stored, isNot(contains(lnShift.recordKey)));
      },
    );

    test(
      'WholeDayRollup zero-covers fallback uses an unweighted mean '
      '(mirrors TargetCycleDaypartPool)',
      () {
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
      },
    );

    test(
      'WholeDayRollup labor % uses the WHOLE-DAY wage on the '
      'cover-weighted rates (display only, no per-period wage)',
      () {
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
      },
    );

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
}

class _FailingBaselineServerSelectionWriter
    implements BaselineServerSelectionWriter {
  const _FailingBaselineServerSelectionWriter(this.error);

  final StarTargetSelectionWriteException error;

  @override
  Future<void> replaceSelection({
    required String restaurantId,
    required Iterable<BaselineCandidateShift> selectedCandidates,
    required Iterable<BaselineCandidateShift> previouslySelectedCandidates,
  }) async {
    throw error;
  }
}
