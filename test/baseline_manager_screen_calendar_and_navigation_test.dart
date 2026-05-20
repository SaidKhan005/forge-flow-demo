// Baseline Manager screen — CALENDAR and NAVIGATION tests.
// Covers groups L-U from the original 3,608-line monolith: calendar
// rendering, tap-day bottom sheet, selection through calendar, DST-safe
// grid, R1 2-state calendar, lever/date polish, Clear All button,
// 7.55q.8 preview wage authority, Done denial SnackBar, and server
// star-target write-error SnackBar. Split out in Bucket 5b of the
// 2026-05-20 test-suite tightening audit; helpers + fixtures live in
// `baseline_manager_screen_test_helpers.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/state/active_target_profile_notifier.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/database_helper.dart';
import 'package:forge_and_flow/services/demand_forecast_context_service.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';
import 'package:forge_and_flow/services/star_target_selection_write_service.dart';
import 'package:provider/provider.dart';

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

  // ── L — Calendar rendering (Phase 7.55f.3) ────────────────────────────────

  group('L - calendar rendering', () {
    testWidgets('screen shows calendar mode after loading candidates', (
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

      expect(find.text('LAST 60 DAYS'), findsOneWidget);
      // Weekday labels
      expect(find.text('M'), findsAtLeastNWidgets(1));
      expect(find.text('S'), findsAtLeastNWidgets(1));
    });

    testWidgets('calendar window anchored to latest candidate businessDate', (
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

      // Latest is lunch2 at 2026-03-10.
      // R1: window range uses the word "to", no dash separator.
      expect(find.text('Jan 10 to Mar 10'), findsOneWidget);
    });

    testWidgets('dates with closed shifts have a keyed cell', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
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
        wrap(
          BaselineManagerScreen.withCandidates(
            withPreSelected,
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
        wrap(
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
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // The calendar header is still mounted underneath (no route swap).
      await tapCalendarDate(tester, '2026-03-02');
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('LAST 60 DAYS'), findsOneWidget);
      // No legacy push-nav affordance.
      expect(find.text('BACK TO CALENDAR'), findsNothing);
    });

    testWidgets('whole-day sheet shows only that date\'s services', (
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

      // Mar 2 has lunch1 only.
      await tapCalendarDate(tester, '2026-03-02');
      final inSheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: inSheet, matching: find.text('Lunch')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('Dinner')),
        findsNothing,
      );

      await closeSheet(tester);
      // Mar 6 has dinner1 only.
      await tapCalendarDate(tester, '2026-03-06');
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
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await tapCalendarDate(tester, '2026-03-02');
      expect(find.byType(BottomSheet), findsOneWidget);

      await closeSheet(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('LAST 60 DAYS'), findsOneWidget);
    });

    testWidgets('tapping a date without shifts shows empty sheet state', (
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

      await tapCalendarDate(tester, '2026-01-15');
      expect(find.text('No closed shifts for this date.'), findsOneWidget);
    });
  });

  // ── N — Selection through calendar (Phase 7.55f.3) ────────────────────────

  group('N - selection through calendar', () {
    testWidgets('CLEAR ALL from calendar view clears highlights and preview', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            withPreSelected,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      final clearAll = find.text('CLEAR ALL');
      expect(clearAll, findsOneWidget);
      await tester.ensureVisible(clearAll);
      await pumpEventually(tester);

      await tester.tap(clearAll);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('0', skipOffstage: false), findsOneWidget);
      // R9: PLAN IMPACT is collapsed by default; expand it so all 11
      // empty-state sentinels (5 standard + 6 plan impact) are present.
      await expandPlanImpact(tester);
      expect(find.text('--', skipOffstage: false), findsNWidgets(11));
      expect(find.text('CLEAR ALL'), findsNothing);
    });

    testWidgets('CANCEL after CLEAR ALL does not persist the draft clear', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({
          selectedLunch.recordKey,
        });
      });

      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            withPreSelected,
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
      expect(stored!, contains(selectedLunch.recordKey));
    });
  });

  // ── O — DST-safe calendar grid (Phase 7.55f.3a) ──────────────────────────

  group('O - DST-safe calendar grid', () {
    testWidgets('all 60 in-window dates have a calendar cell key', (
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
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
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
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // lunch2 is on 2026-03-10 (after DST transition on Mar 8)
      await tapCalendarDate(tester, '2026-03-10');
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Tue, Mar 10'), findsOneWidget);
    });
  });

  // ── P - R1 2-state calendar (suggested state + legend removed) ────────────

  group('P - R1 2-state calendar', () {
    testWidgets('the old suggested-state legend is gone', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
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
        wrap(
          BaselineManagerScreen.withCandidates(
            withPreSelected,
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
    testWidgets('period-lens sheet shows full lever meaning, not raw id', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            leverTestCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await tapLensChip(tester, 'dinner');
      await tapCalendarDate(tester, '2026-03-02');

      // dinnerSplhDown on 2026-03-02 under the dinner lens.
      expect(
        find.text('SPLH below target', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
      expect(find.text('splh_down', skipOffstage: false), findsNothing);
    });

    testWidgets('whole-day sheet shows human-friendly date, not raw week-id', (
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

      expect(find.textContaining('2026-W', skipOffstage: false), findsNothing);
      expect(find.text('Mon, Mar 2'), findsOneWidget);
    });
  });

  // ── R — Clear All button (Phase 7.55f.3b) ────────────────────────────────

  group('R - Clear All button', () {
    testWidgets('CLEAR ALL hidden when no draft selections', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // R8 opens populated (default Balanced), so CLEAR ALL is visible
      // on entry. It only disappears once the draft is emptied.
      expect(find.text('CLEAR ALL'), findsOneWidget);
      await clearAllDraft(tester);
      expect(find.text('CLEAR ALL'), findsNothing);
    });

    testWidgets('CLEAR ALL is a bordered button when visible', (tester) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            withPreSelected,
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
        wrap(
          BaselineManagerScreen.withCandidates(
            withPreSelected,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      final clearAll = find.text('CLEAR ALL');
      expect(clearAll, findsOneWidget);
      await tester.ensureVisible(clearAll);
      await pumpEventually(tester);
      await tester.tap(clearAll);
      await pumpEventually(tester);

      expect(find.text('0', skipOffstage: false), findsOneWidget);
      // R9: PLAN IMPACT is collapsed by default; expand it so all 11
      // empty-state sentinels (5 standard + 6 plan impact) are present.
      await expandPlanImpact(tester);
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
        lunch1,
      ], historicalWeeklyAvgCovers: demand);
      final profileDriven = ManagerOverridePlanPreview.fromDraftSelection(
        [lunch1],
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
        [lunch1],
        historicalWeeklyAvgCovers: demandCovers,
        fohWage: distinctFohWage,
        bohWage: distinctBohWage,
      );
      expect(expectedPreview, isNotNull);
      final expectedWageStr =
          '\$${expectedPreview!.targetBlendedWage.toStringAsFixed(2)}';

      final configDefaultPreview =
          ManagerOverridePlanPreview.fromDraftSelection([
            lunch1,
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
              allCandidates,
              initialDemandCovers: demandCovers,
            ),
          ),
        ),
      );
      await tester.pump();

      // R8 opens populated; clear so only lunch1 is in the draft and
      // the rendered preview matches the expectation computed above.
      await clearAllDraft(tester);
      await tapCalendarDate(tester, '2026-03-02');
      await toggleWholeDayService(tester, 'Lunch');
      await closeSheet(tester);
      // R9: BLENDED WAGE lives in the collapsed PLAN IMPACT dropdown.
      await expandPlanImpact(tester);

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
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // R8 opens populated; clear so only the single toggled shift
      // drives the preview and exactly the 2 wage-dependent cells stay
      // on the honest "--" sentinel.
      await clearAllDraft(tester);
      await tapCalendarDate(tester, '2026-03-02');
      await toggleWholeDayService(tester, 'Lunch');
      await closeSheet(tester);
      // R9: the wage-dependent cells live in the collapsed PLAN IMPACT
      // dropdown; expand it so the honest sentinels are in the tree.
      await expandPlanImpact(tester);

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
          lunch1.recordKey,
        });
      });

      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      // R8 opens populated; the draft is non-empty regardless, so the
      // cycle (override) write path still runs on Done.
      await tapCalendarDate(tester, '2026-03-10');
      await toggleWholeDayService(tester, 'Lunch');
      await closeSheet(tester);

      await tester.runAsync(() async {
        await tester.tap(doneButton());
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
        doneButton(),
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
          const FailingBaselineServerSelectionWriter(
            StarTargetSelectionWriteException(
              code: 'permission_denied',
              message: 'denied',
              statusCode: 403,
            ),
          );

      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(<BaselineCandidateShift>[
            candidate,
          ], initialDemandCovers: demandCovers),
        ),
      );
      await tester.pump();

      // R8 opens populated; clear so the single-shift period sheet
      // shows the unselected SELECT action.
      await clearAllDraft(tester);

      // Use the period lens for this candidate so the single-shift
      // sheet's SELECT action toggles and auto-closes.
      await tapLensChip(tester, candidate.daypart);
      await tapCalendarDate(tester, candidate.businessDate!);
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('SELECT'),
        ),
      );
      await pumpEventually(tester);

      await tester.runAsync(() async {
        await tester.tap(doneButton());
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();

      expect(
        find.textContaining('do not have permission', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
      expect(doneButton(), findsOneWidget);
      final stored = await tester.runAsync(
        DatabaseHelper.instance.getBaselineSelectedRecordKeys,
      );
      expect(stored, isEmpty);
    });
  });
}
