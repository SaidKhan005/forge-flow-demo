// Phase 7.13 — Variance Visual Widget Tests
//
// Verifies that the Variance screen exposes all required structural
// sections and metric labels after the Phase 7.13 coaching layout cleanup.
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
import 'package:forge_flow_demo/data/shift_data_source.dart';
import 'package:forge_flow_demo/data/week_data_notifier.dart';
import 'package:forge_flow_demo/screens/variance_report.dart';

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
    testWidgets('WEEK-TO-DATE vs BASELINE section is present', (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump(); // first frame
      await tester.pump(); // WeekDataNotifier resolves
      expect(find.text('WEEK-TO-DATE vs BASELINE'), findsOneWidget);
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
    Future<void> _loadThisWeek(WidgetTester tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();
    }

    testWidgets('CONDITIONS group label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('CONDITIONS'), findsAtLeastNWidgets(1));
    });

    testWidgets('EXECUTION group label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('EXECUTION'), findsAtLeastNWidgets(1));
    });

    testWidgets('OUTCOMES group label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('OUTCOMES'), findsAtLeastNWidgets(1));
    });
  });

  // ── D: WTD table — metric labels ────────────────────────────────────────

  group('D — WTD metric labels', () {
    Future<void> _loadThisWeek(WidgetTester tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      await tester.pump();
    }

    testWidgets('Covers label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('Covers'), findsAtLeastNWidgets(1));
    });

    testWidgets('PPA label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('PPA'), findsAtLeastNWidgets(1));
    });

    testWidgets('CPLH label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('CPLH'), findsAtLeastNWidgets(1));
    });

    testWidgets('SPLH label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('SPLH'), findsAtLeastNWidgets(1));
    });

    testWidgets('Blended Wage label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('Blended Wage'), findsAtLeastNWidgets(1));
    });

    testWidgets('FOH Hours label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('FOH Hours'), findsAtLeastNWidgets(1));
    });

    testWidgets('BOH Hours label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('BOH Hours'), findsAtLeastNWidgets(1));
    });

    testWidgets('FOH Labor % label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('FOH Labor %'), findsAtLeastNWidgets(1));
    });

    testWidgets('BOH Labor % label appears', (tester) async {
      await _loadThisWeek(tester);
      expect(find.text('BOH Labor %'), findsAtLeastNWidgets(1));
    });

    testWidgets('Total Labor % label appears', (tester) async {
      await _loadThisWeek(tester);
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
}
