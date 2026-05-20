// Shared fixtures and navigation helpers for the baseline_manager_screen_*
// widget-test files. Extracted in Bucket 5b of the 2026-05-20 test-suite
// tightening audit when `test/baseline_manager_screen_test.dart` (3,608
// lines) was split into four focused files: core (A-H), preview+override
// (I-K), calendar+navigation (L-U), and regression-suite (R1-R10). The
// helpers below were verbatim file-private declarations in the original
// monolith; they are promoted to library-public so each split file can
// import a single source of truth instead of duplicating ~280 LOC.
//
// Bounded-pump helpers (`pumpEventually`, `pumpUntil`) deliberately are
// NOT redeclared here. The split files import them from the existing
// shared helper at `test/_test_helpers/widget_pump_helpers.dart` (PR
// #1111, Bucket 4c) so the migration to bounded pumps stays single-source.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/state/active_target_profile_notifier.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/database_helper.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/services/star_target_selection_write_service.dart';
import 'package:provider/provider.dart';

import '_test_helpers/widget_pump_helpers.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────
// Week 10 Mon = 2026-03-02, Week 10 Fri = 2026-03-06,
// Week 11 Tue = 2026-03-10, Week 12 Mon = 2026-03-16.

const lunch1 = BaselineCandidateShift(
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

const lunch2 = BaselineCandidateShift(
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

const dinner1 = BaselineCandidateShift(
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

const selectedLunch = BaselineCandidateShift(
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
const dinnerSplhDown = BaselineCandidateShift(
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

const allCandidates = [lunch1, lunch2, dinner1];
const withPreSelected = [selectedLunch, lunch1, dinner1];
const leverTestCandidates = [lunch1, dinnerSplhDown, dinner1];

ActiveTargetProfile defaultProfile() => ActiveTargetProfile(
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

Widget wrap(Widget child) => ChangeNotifierProvider(
  create: (_) => ActiveTargetProfileNotifier.fromProfile(defaultProfile()),
  child: MaterialApp(theme: ThemeData.dark(), home: child),
);

// ── R2 navigation helpers ─────────────────────────────────────────────────────
// R2 replaced the full-screen day-detail PUSH navigation with an in-place
// `showModalBottomSheet`. Tapping a calendar day opens the sheet; there
// is no route push and no "BACK TO CALENDAR" affordance. The default
// lens ("Whole day") opens the whole-day rollup sheet; a period lens
// opens that period's single-shift sheet.

Future<void> tapCalendarDate(WidgetTester tester, String date) async {
  final finder = find.byKey(ValueKey<String>('cal_$date'));
  await tester.ensureVisible(finder);
  await pumpEventually(tester);
  await tester.tap(finder);
  await pumpEventually(tester);
}

Future<void> closeSheet(WidgetTester tester) async {
  await tester.tap(find.text('CLOSE'));
  await pumpEventually(tester);
}

/// Dismiss a modal bottom sheet that has no CLOSE affordance (the
/// period-lens variant closes via its SELECT/REMOVE action; a test that
/// only wants to move on taps the scrim/barrier instead).
Future<void> dismissModalBarrier(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await pumpEventually(tester);
}

/// R8: the screen opens populated with the default Balanced selection.
/// Tests that exercise selection-from-empty first clear the draft via
/// the CLEAR ALL control to reach the honest empty state.
Future<void> clearAllDraft(WidgetTester tester) async {
  final clearAll = find.text('CLEAR ALL');
  await tester.ensureVisible(clearAll);
  await pumpEventually(tester);
  await tester.tap(clearAll);
  await pumpEventually(tester);
}

/// R9: PLAN IMPACT is a tap-to-expand dropdown that is COLLAPSED by
/// default. Tests that assert on the six plan-impact metric cells must
/// open the dropdown first (the header row is always visible; the metric
/// grid is only in the tree when open).
Future<void> expandPlanImpact(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey<String>('plan_impact_toggle'));
  await tester.ensureVisible(toggle);
  await pumpEventually(tester);
  await tester.tap(toggle);
  await pumpEventually(tester);
}

Future<void> tapLensChip(WidgetTester tester, String lensId) async {
  final chip = find.byKey(ValueKey<String>('lens_$lensId'));
  // R8 added an app-bar RESET pill + once-per-cycle caption and the
  // CLEAR ALL clear path can leave the capped top scroll region
  // offset; make the lens chip on-screen before tapping so the tap
  // always lands (an off-target tap would silently leave the lens on
  // whole-day and open the wrong sheet).
  await tester.ensureVisible(chip);
  await pumpEventually(tester);
  await tester.tap(chip);
  await pumpEventually(tester);
}

/// Toggle a service inside the open WHOLE-DAY sheet via its per-service
/// breakdown row. The sheet stays open after the toggle.
Future<void> toggleWholeDayService(
  WidgetTester tester,
  String periodLabel,
) async {
  final row = find.descendant(
    of: find.byType(BottomSheet),
    matching: find.text(periodLabel),
  );
  await tester.ensureVisible(row);
  await pumpEventually(tester);
  await tester.tap(row);
  await pumpEventually(tester);
}

/// Finds the SELECTED SHIFTS preview-cell value. The cell renders
/// "SELECTED SHIFTS" then the count in the next Text in the same Column;
/// the calendar day-number cells also render bare digits, so count
/// assertions must be scoped here, not to a bare `find.text`.
Finder selectedShiftsValue() {
  return find.descendant(
    of: find
        .ancestor(
          of: find.text('SELECTED SHIFTS'),
          matching: find.byType(Column),
        )
        .first,
    matching: find.byType(Text),
  );
}

void expectSelectedShiftsCount(WidgetTester tester, String count) {
  final texts = tester.widgetList<Text>(selectedShiftsValue()).toList();
  // [0] = label "SELECTED SHIFTS", [1] = the value.
  expect(
    texts.any((t) => t.data == count),
    isTrue,
    reason: 'SELECTED SHIFTS cell should show $count',
  );
}

/// R8: the primary action label is now `Done · {draft count}` (matches
/// the committed prototype). The once-per-cycle caption above the bar is
/// `ONE OVERRIDE PER 60 DAY CYCLE` (no "Done"), so a Done-prefixed text
/// match uniquely targets the action button.
Finder doneButton() => find.textContaining('Done ·');

Future<Set<String>> commitDoneAndReadKeys(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(doneButton());
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await pumpEventually(tester);
  final continueButton = find.text('Continue');
  if (continueButton.evaluate().isNotEmpty) {
    await tester.runAsync(() async {
      await tester.tap(continueButton);
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await pumpEventually(tester);
  } else {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
  }
  return (await tester.runAsync(
    DatabaseHelper.instance.getBaselineSelectedRecordKeys,
  ))!;
}

/// Test double used by group U (server star-target write errors). Promoted
/// to public so the calendar+navigation split file can construct it
/// without re-declaring the test class.
class FailingBaselineServerSelectionWriter
    implements BaselineServerSelectionWriter {
  const FailingBaselineServerSelectionWriter(this.error);

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
