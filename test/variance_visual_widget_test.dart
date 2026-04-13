// Phase 7.13 + 7.55m.4 — Variance Visual Widget Tests
//
// Verifies that the Variance screen exposes all required structural
// sections and metric labels after the Phase 7.13 coaching layout cleanup.
//
// 7.55m.4 adds driver parity audit tests (group F) proving the shared
// lever engine can yield different results from different scopes and that
// Full Week open/projected rows use the ON_MODEL placeholder.
//
// Tests are intentionally structure-focused (labels, sections, navigation)
// and avoid golden snapshots or style assertions.
//
// Uses StaticShiftDataSource to avoid sqflite I/O and the runAsync /
// google_fonts incompatibility. Static source data is synchronous internally
// so providers load after normal pump() cycles.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/data/shift_data_source.dart';
import 'package:forge_and_flow/data/week_data_notifier.dart';
import 'package:forge_and_flow/models/current_week_state.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/screens/variance_report.dart';
import 'package:forge_and_flow/services/labor_model.dart';

// ── Test harness ──────────────────────────────────────────────────────────────

Widget _buildVarianceReport() => MultiProvider(
      providers: [
        ChangeNotifierProvider<WeekDataNotifier>(
          create: (_) => WeekDataNotifier(const StaticShiftDataSource()),
        ),
        Provider<ShiftDataSource>(
          create: (_) => const StaticShiftDataSource(),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: VarianceReport()),
      ),
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── A: Screen chrome — always-visible labels ─────────────────────────────

  group('A — screen chrome', () {
    testWidgets('Variance title is present', (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      expect(find.text('Variance'), findsAtLeastNWidgets(1));
    });

    testWidgets('This Week tab label is present', (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      expect(find.text('This Week'), findsAtLeastNWidgets(1));
    });

    testWidgets('History tab label is present', (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      expect(find.text('History'), findsAtLeastNWidgets(1));
    });

    testWidgets('Learn tab label is present', (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      expect(find.text('Learn'), findsAtLeastNWidgets(1));
    });
  });

  // ── B: This Week tab — section labels ────────────────────────────────────

  group('B — This Week section labels', () {
    testWidgets('WEEK-TO-DATE vs LOCKED PLAN section is present', (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump(); // first frame
      await tester.pump(); // WeekDataNotifier resolves
      expect(find.text('WEEK-TO-DATE vs LOCKED PLAN'), findsOneWidget);
    });

    testWidgets('FULL WEEK PROJECTION section is present', (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();
      expect(find.text('FULL WEEK PROJECTION'), findsOneWidget);
    });

    testWidgets('PRIMARY DRIVER section label is present', (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();
      expect(find.text('PRIMARY DRIVER'), findsOneWidget);
    });
  });

  // ── C: WTD table — coaching group labels ─────────────────────────────────

  group('C — WTD coaching group labels', () {
    Future<void> loadThisWeek(WidgetTester tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();
    }

    testWidgets('CONDITIONS group label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('CONDITIONS'), findsAtLeastNWidgets(1));
    });

    testWidgets('EXECUTION group label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('EXECUTION'), findsAtLeastNWidgets(1));
    });

    testWidgets('OUTCOMES group label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('OUTCOMES'), findsAtLeastNWidgets(1));
    });
  });

  // ── D: WTD table — metric labels ────────────────────────────────────────

  group('D — WTD metric labels', () {
    Future<void> loadThisWeek(WidgetTester tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();
    }

    testWidgets('Covers label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('Covers'), findsAtLeastNWidgets(1));
    });

    testWidgets('PPA label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('PPA'), findsAtLeastNWidgets(1));
    });

    testWidgets('CPLH label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('CPLH'), findsAtLeastNWidgets(1));
    });

    testWidgets('SPLH label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('SPLH'), findsAtLeastNWidgets(1));
    });

    testWidgets('Blended Wage label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('Blended Wage'), findsAtLeastNWidgets(1));
    });

    testWidgets('FOH Hours label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('FOH Hours'), findsAtLeastNWidgets(1));
    });

    testWidgets('BOH Hours label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('BOH Hours'), findsAtLeastNWidgets(1));
    });

    testWidgets('FOH Labor % label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('FOH Labor %'), findsAtLeastNWidgets(1));
    });

    testWidgets('BOH Labor % label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('BOH Labor %'), findsAtLeastNWidgets(1));
    });

    testWidgets('Total Labor % label appears', (tester) async {
      await loadThisWeek(tester);
      expect(find.text('Total Labor %'), findsAtLeastNWidgets(1));
    });
  });

  // ── E: History tab — section label ───────────────────────────────────────

  group('E — History tab section', () {
    testWidgets('Previous Weeks label is present after switching to History tab',
        (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();

      // Navigate to History tab — pumpAndSettle lets the tab animation
      // complete and the FutureBuilder's Future.wait resolve.
      await tester.tap(find.text('History').first);
      await tester.pumpAndSettle();

      expect(find.text('Previous Weeks'), findsOneWidget);
    });
  });

  // ── F: Driver parity audit (7.55m.4) ──────────────────────────────────

  group('F — driver parity audit', () {
    test('shared engine can yield different levers from different scopes', () {
      // Simulate Shift scope: whole-day current-state where covers are
      // light today but CPLH is fine.
      final shiftLever = LaborModel.determineLever(
        actualCovers: 80,
        forecastCovers: 100, // 20% below → covers_down
        avgCPLH: 4.50,
        avgPPA: 42.0,
        targetCPLH: 4.58,
        targetPPA: 41.50,
      );

      // Simulate Variance WTD scope: across the week, covers recovered
      // but CPLH drifted below target.
      final varianceLever = LaborModel.determineLever(
        actualCovers: 950,
        forecastCovers: 960, // ~1% below → below threshold
        avgCPLH: 4.10,
        avgPPA: 41.50,
        targetCPLH: 4.58, // ~10.5% below → cplh_down
        targetPPA: 41.50,
      );

      // They should differ — Shift sees covers_down, Variance sees cplh_down.
      expect(shiftLever, 'covers_down');
      expect(varianceLever, 'cplh_down');
      expect(shiftLever, isNot(varianceLever));
    });

    test('same inputs produce same lever (engine is deterministic)', () {
      const inputs = (
        actualCovers: 100,
        forecastCovers: 120,
        avgCPLH: 4.50,
        avgPPA: 42.0,
        targetCPLH: 4.58,
        targetPPA: 41.50,
      );

      final lever1 = LaborModel.determineLever(
        actualCovers: inputs.actualCovers,
        forecastCovers: inputs.forecastCovers,
        avgCPLH: inputs.avgCPLH,
        avgPPA: inputs.avgPPA,
        targetCPLH: inputs.targetCPLH,
        targetPPA: inputs.targetPPA,
      );

      final lever2 = LaborModel.determineLever(
        actualCovers: inputs.actualCovers,
        forecastCovers: inputs.forecastCovers,
        avgCPLH: inputs.avgCPLH,
        avgPPA: inputs.avgPPA,
        targetCPLH: inputs.targetCPLH,
        targetPPA: inputs.targetPPA,
      );

      expect(lever1, lever2);
    });

    test('Full Week open/projected rows use ON_MODEL placeholder', () {
      final profile = ActiveTargetProfile(
        targetProfileId: 'test_active',
        restaurantId: 'demo_restaurant_001',
        sourceType: 'system_baseline',
        targetCPLH: 4.58,
        targetSPLH: 180.0,
        targetPPA: 41.50,
        fohWage: 16.50,
        bohWage: 21.35,
        opzFloorCPLH: 3.50,
        opzCeilingCPLH: 5.80,
        theoreticalFohLaborPct: 8.63,
        theoreticalBohLaborPct: 11.86,
        theoreticalLaborPct: 20.48,
        builtAt: '2026-03-27T19:42:00',
      );
      final snapshot = OpenShiftSnapshot(
        restaurantId: 'demo_restaurant_001',
        weekId: '2026-W13',
        dayLabel: 'Sat',
        daypart: 'dinner',
        status: 'projected',
        businessDate: '2026-03-28',
        forecastCovers: 110,
        currentCovers: 0,
        scheduledFohHours: 24,
        scheduledBohHours: 10,
        currentPPA: 0,
        currentCPLH: 0,
        currentSPLH: 0,
        blendedWage: 18.0,
        updatedAt: '2026-03-27T19:42:00',
      );

      final record = CurrentWeekState.shiftRecordFromSnapshot(snapshot, profile);

      // Open/projected rows get the ON_MODEL placeholder, not a real lever.
      expect(record.primaryLever, 'ON_MODEL');
      expect(record.status, 'projected');
    });

    test('Full Week open row also uses ON_MODEL placeholder', () {
      final profile = ActiveTargetProfile(
        targetProfileId: 'test_active',
        restaurantId: 'demo_restaurant_001',
        sourceType: 'system_baseline',
        targetCPLH: 4.58,
        targetSPLH: 180.0,
        targetPPA: 41.50,
        fohWage: 16.50,
        bohWage: 21.35,
        opzFloorCPLH: 3.50,
        opzCeilingCPLH: 5.80,
        theoreticalFohLaborPct: 8.63,
        theoreticalBohLaborPct: 11.86,
        theoreticalLaborPct: 20.48,
        builtAt: '2026-03-27T19:42:00',
      );
      final snapshot = OpenShiftSnapshot(
        restaurantId: 'demo_restaurant_001',
        weekId: '2026-W13',
        dayLabel: 'Fri',
        daypart: 'dinner',
        status: 'open',
        businessDate: '2026-03-27',
        forecastCovers: 100,
        currentCovers: 63,
        scheduledFohHours: 22,
        scheduledBohHours: 9,
        currentPPA: 43.50,
        currentCPLH: 2.86,
        currentSPLH: 130.0,
        blendedWage: 18.0,
        updatedAt: '2026-03-27T19:42:00',
      );

      final record = CurrentWeekState.shiftRecordFromSnapshot(snapshot, profile);

      expect(record.primaryLever, 'ON_MODEL');
      expect(record.status, 'open');

      // 7.55m.4a: the open row carries live partial actuals that deviate
      // from target, proving ON_MODEL is a placeholder — not a claim that
      // the row is neutral. Row-scope driver detection is not yet modeled.
      expect(record.cplh, 2.86); // well below targetCPLH 4.58
      expect(record.covers, 63); // partial — below forecastCovers 100
    });
  });

  // ── G: Full Week Projection read model (7.55k.4) ──────────────────────

  group('G — projection read model in widget tree', () {
    testWidgets('FULL WEEK PROJECTION section still renders after read-service migration',
        (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();
      expect(find.text('FULL WEEK PROJECTION'), findsOneWidget);
    });

    testWidgets('projected-row copy says weekly plan, not 60-day baseline',
        (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();

      // Scroll down to reach the Full Week section and expand a day
      // that has projected rows. In StaticShiftDataSource, Sat is projected.
      await tester.scrollUntilVisible(
        find.text('FULL WEEK PROJECTION'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      // Find and tap the Sat day row to expand it
      final satFinder = find.text('Sat');
      if (satFinder.evaluate().isNotEmpty) {
        await tester.tap(satFinder.first);
        await tester.pump();

        // Verify updated projected copy
        expect(
          find.text(
              'Projected from weekly plan. Actuals populate when shift closes.'),
          findsWidgets,
        );
        expect(
          find.text(
              'Projected from 60-day baseline. Actuals populate when shift closes.'),
          findsNothing,
        );
      }
    });

    testWidgets('plan label appears instead of baseline on covers',
        (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();

      await tester.scrollUntilVisible(
        find.text('FULL WEEK PROJECTION'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      final satFinder = find.text('Sat');
      if (satFinder.evaluate().isNotEmpty) {
        await tester.tap(satFinder.first);
        await tester.pump();

        // Should say (plan), not (baseline)
        expect(find.textContaining('(plan)'), findsWidgets);
        expect(find.textContaining('(baseline)'), findsNothing);
      }
    });
  });

  // ── H: Mixed day-row and open-header honesty (7.55k.4a) ────────────────

  group('H — mixed-row and open-header honesty', () {
    testWidgets('mixed closed+projected day shows status summary',
        (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();

      // Scroll to the Full Week section.
      await tester.scrollUntilVisible(
        find.text('FULL WEEK PROJECTION'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      // In StaticShiftDataSource, Fri has closed lunch + projected dinner
      // (mock replay business date is Friday). That makes Fri a mixed day.
      // The status summary "1 closed, 1 projected" should be visible.
      expect(
        find.textContaining('closed'),
        findsWidgets,
        reason: 'mixed day row should render status summary with "closed"',
      );
    });

    testWidgets('open-row detail does not use CURRENT as header',
        (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();

      await tester.scrollUntilVisible(
        find.text('FULL WEEK PROJECTION'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      // Expand Fri to see the projected dinner detail
      final friFinder = find.text('Fri');
      if (friFinder.evaluate().isNotEmpty) {
        await tester.tap(friFinder.first);
        await tester.pump();

        // The open/projected row header should NOT say CURRENT
        expect(find.text('CURRENT'), findsNothing);
      }
    });

    testWidgets('projected row detail header says PROJECTED',
        (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();

      await tester.scrollUntilVisible(
        find.text('FULL WEEK PROJECTION'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      // Expand Sat (all projected in static data)
      final satFinder = find.text('Sat');
      if (satFinder.evaluate().isNotEmpty) {
        await tester.tap(satFinder.first);
        await tester.pump();

        expect(find.text('PROJECTED'), findsWidgets);
      }
    });
  });
}
