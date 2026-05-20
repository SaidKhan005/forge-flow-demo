// Baseline Manager screen — CORE behavior tests.
// Covers groups A-H from the original 3,608-line monolith: required
// labels, opens-populated (R8 default Balanced), live preview, period-
// lens metrics, Cancel, Done (commit/clear-override), plan-impact
// selected-shift behavior. Split out in Bucket 5b of the 2026-05-20
// test-suite tightening audit; helpers + fixtures live in the sibling
// `baseline_manager_screen_test_helpers.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/database_helper.dart';
import 'package:forge_and_flow/services/demand_forecast_context_service.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';
import 'package:forge_and_flow/screens/baseline_manager/baseline_manager_band.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';

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

  testWidgets('shows loading indicator when no initialCandidates provided', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const BaselineManagerScreen()));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  group('A - required labels present', () {
    testWidgets('page title, buttons, and all preview labels render', (
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

      expect(find.text('Choose Star Shifts'), findsOneWidget);
      expect(find.text('CANCEL'), findsOneWidget);
      // R8: Done button label includes the live draft count.
      expect(doneButton(), findsOneWidget);
      // R8: app-bar RESET pill + once-per-cycle caption above the bar.
      expect(find.byKey(const ValueKey<String>('reset_pill')), findsOneWidget);
      expect(find.text('ONE OVERRIDE PER 60 DAY CYCLE'), findsOneWidget);
      // R8: calendar legend pills + count caption.
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
      // R8: STAR SHIFT SELECTION section label above the band.
      expect(find.text('STAR SHIFT SELECTION'), findsOneWidget);
      // Target standard cells
      expect(find.text('SELECTED SHIFTS'), findsOneWidget);
      expect(find.text('TARGET CPLH'), findsOneWidget);
      expect(find.text('TARGET SPLH'), findsOneWidget);
      expect(find.text('TARGET PPA'), findsOneWidget);
      expect(find.text('OPZ FLOOR'), findsOneWidget);
      expect(find.text('OPZ CEILING'), findsOneWidget);
      // R9: PLAN IMPACT header is always visible; it is a collapsed
      // dropdown by default. Its six metric cells render only after the
      // dropdown is expanded.
      expect(find.text('PLAN IMPACT'), findsOneWidget);
      expect(find.text('FORECAST COVERS'), findsNothing);
      await expandPlanImpact(tester);
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

  group('B - opens populated (R8 default Balanced)', () {
    testWidgets(
      'screen opens with Balanced applied: non-empty draft, populated '
      'preview, and NO persistence call on open',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              allCandidates,
              initialDemandCovers: demandCovers,
            ),
          ),
        );
        await tester.pump();

        // The default Balanced selection the screen applies on open is
        // exactly deriveBandSelection(..., balanced) over the same pool.
        final defs = ServicePeriodDefinitionResolver.demoDefinitions;
        final expected = deriveBandSelection(
          allCandidates,
          defs,
          StarBand.balanced,
        );
        expect(expected, isNotEmpty);

        // Draft is non-empty: SELECTED SHIFTS shows the derived count,
        // not 0, on entry.
        expectSelectedShiftsCount(tester, '${expected.length}');
        expect(find.text('0'), findsNothing);

        // Preview is populated, not the empty-state dashes.
        expect(find.text('--'), findsNothing);

        // Balanced band chip is highlighted.
        expect(
          find.byKey(const ValueKey<String>('band_balanced')),
          findsOneWidget,
        );

        // CRITICAL: opening the screen must NOT persist anything. The
        // selected-record-keys store is still empty until the operator
        // taps Done.
        final stored = await tester.runAsync(
          () => DatabaseHelper.instance.getBaselineSelectedRecordKeys(),
        );
        expect(stored, isEmpty);
      },
    );

    testWidgets(
      'CLEAR ALL still reaches the honest empty state (-- everywhere)',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              allCandidates,
              initialDemandCovers: demandCovers,
            ),
          ),
        );
        await tester.pump();

        final clearAll = find.text('CLEAR ALL');
        await tester.ensureVisible(clearAll);
        await pumpEventually(tester);
        await tester.tap(clearAll);
        await pumpEventually(tester);

        expect(find.text('0', skipOffstage: false), findsOneWidget);
        // R9: PLAN IMPACT is collapsed by default; expand it so the
        // empty-state sentinel count covers the plan-impact cells too.
        await expandPlanImpact(tester);
        // 5 target standard cells + 6 plan impact cells = 11
        expect(find.text('--', skipOffstage: false), findsNWidgets(11));
      },
    );
  });

  group('C - live preview updates on selection', () {
    testWidgets('selecting one candidate clears all -- from preview', (
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

      // R8 opens populated; clear to reach the empty preview first.
      await clearAllDraft(tester);
      // R9: expand the PLAN IMPACT dropdown so all 11 sentinel cells
      // (5 standard + 6 plan impact) are in the tree.
      await expandPlanImpact(tester);
      expect(find.text('--'), findsNWidgets(11));

      // Default whole-day lens: tap the date, toggle the lunch service
      // in the sheet, then close so the preview underneath is visible.
      await tapCalendarDate(tester, '2026-03-02');
      await toggleWholeDayService(tester, 'Lunch');
      await closeSheet(tester);

      // Dropdown stays expanded across the selection round-trip.
      expect(find.text('--'), findsNothing);
    });

    testWidgets('count increments to 1 after first selection', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // R8 opens populated; clear to start from zero.
      await clearAllDraft(tester);
      expectSelectedShiftsCount(tester, '0');

      await tapCalendarDate(tester, '2026-03-02');
      await toggleWholeDayService(tester, 'Lunch');
      await closeSheet(tester);

      expectSelectedShiftsCount(tester, '1');
    });
  });

  group('D - period-lens sheet shows required metrics', () {
    testWidgets('period-lens tap opens a bottom sheet with the 6 metrics', (
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

      // R8 opens populated; clear so the period-lens sheet shows the
      // unselected SELECT action rather than REMOVE STAR.
      await clearAllDraft(tester);
      await tapLensChip(tester, 'lunch');
      await tapCalendarDate(tester, '2026-03-02');

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
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await tapLensChip(tester, 'lunch');
      await tapCalendarDate(tester, '2026-03-02');

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
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // R8 opens populated; clear so the single-toggle count is exact.
      await clearAllDraft(tester);
      await tapCalendarDate(tester, '2026-03-02');
      await toggleWholeDayService(tester, 'Lunch');
      await closeSheet(tester);
      expectSelectedShiftsCount(tester, '1');

      await tester.tap(find.text('CANCEL'));
      await tester.pump();

      final stored = await tester.runAsync(() async {
        return DatabaseHelper.instance.getBaselineSelectedRecordKeys();
      });
      expect(stored!, isEmpty);
    });
  });

  group('F - Done with non-empty draft commits selection', () {
    testWidgets(
      'Done warns before saving when a selectable period has no star shift',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            BaselineManagerScreen.withCandidates(
              allCandidates,
              initialDemandCovers: demandCovers,
            ),
          ),
        );
        await tester.pump();

        await clearAllDraft(tester);
        await tapCalendarDate(tester, '2026-03-02');
        await toggleWholeDayService(tester, 'Lunch');
        await closeSheet(tester);

        await tester.tap(doneButton());
        await pumpEventually(tester);

        expect(find.text('Some periods have no star shifts'), findsOneWidget);
        expect(
          find.text(
            'Periods without selected star shifts will keep their existing target fallback. Continue only if that is intentional.',
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('Go back'));
        await pumpEventually(tester);
        final beforeContinue = await tester.runAsync(
          DatabaseHelper.instance.getBaselineSelectedRecordKeys,
        );
        expect(beforeContinue, isEmpty);

        final stored = await commitDoneAndReadKeys(tester);
        expect(stored, contains(lunch1.recordKey));
      },
    );

    testWidgets('Done writes selected record key to DB', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // R8 opens populated; clear so the single-toggle count is exact.
      await clearAllDraft(tester);
      await tapCalendarDate(tester, '2026-03-02');
      await toggleWholeDayService(tester, 'Lunch');
      await closeSheet(tester);
      expectSelectedShiftsCount(tester, '1');

      final stored = await commitDoneAndReadKeys(tester);
      expect(stored, contains(lunch1.recordKey));
    });
  });

  group('G - Done with empty draft clears override', () {
    testWidgets('deselect all then Done empties DB and clears override', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({
          selectedLunch.recordKey,
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
        wrap(
          BaselineManagerScreen.withCandidates(
            withPreSelected,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // Clear all selections via CLEAR ALL button. R1 moved CLEAR ALL
      // into a scrollable band; ensure visible before tapping.
      final clearAll = find.text('CLEAR ALL');
      await tester.ensureVisible(clearAll);
      await pumpEventually(tester);
      await tester.tap(clearAll);
      await pumpEventually(tester);
      expect(find.text('0', skipOffstage: false), findsOneWidget);

      final stored = await commitDoneAndReadKeys(tester);

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
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await tapCalendarDate(tester, '2026-03-02');
      await toggleWholeDayService(tester, 'Lunch');
      await closeSheet(tester);
      // R9: forecast covers lives in the collapsed PLAN IMPACT dropdown.
      await expandPlanImpact(tester);

      // Forecast covers fixed from canonical demand context
      final expectedCovers = demandCovers;
      expect(expectedCovers, isNot(equals(lunch1.covers)));
      expect(
        find.text('$expectedCovers', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
    });
  });
}
