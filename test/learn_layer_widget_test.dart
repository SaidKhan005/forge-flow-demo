// Phase 7.14 — Learn Layer Widget Tests
//
// Verifies that the Learn tab renders all required sections, labels, and
// fields using the same StaticShiftDataSource pattern as the existing
// Variance widget tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/data/shift_data_source.dart';
import 'package:forge_and_flow/data/week_data_notifier.dart';
import 'package:forge_and_flow/screens/variance_report.dart';

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

Future<void> _openLearnTab(WidgetTester tester) async {
  await tester.pumpWidget(_buildVarianceReport());
  await tester.pump();
  await tester.pump();
  await tester.tap(find.text('Learn').first);
  await tester.pumpAndSettle();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(() {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
  });

  tearDown(() {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
  });

  // ── A: Learn tab exists ──────────────────────────────────────────────────

  group('A — Learn tab exists', () {
    testWidgets('Learn tab label is present', (tester) async {
      await tester.pumpWidget(_buildVarianceReport());
      await tester.pump();
      expect(find.text('Learn'), findsAtLeastNWidgets(1));
    });
  });

  // ── B: switching to Learn shows required sections ────────────────────────

  group('B — Learn section labels', () {
    testWidgets('BENCHMARK SET section is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('BENCHMARK SET'), findsOneWidget);
    });

    testWidgets('RECURRING LEAK section is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('RECURRING LEAK'), findsOneWidget);
    });

    testWidgets('REPEATABLE WINS section is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('REPEATABLE WINS'), findsOneWidget);
    });

    testWidgets('COACH NEXT WEEK section is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('COACH NEXT WEEK'), findsOneWidget);
    });
  });

  // ── C: Learn benchmark fields render ──────────────────────────────────────

  group('C — benchmark fields', () {
    testWidgets('SOURCE label is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('SOURCE'), findsAtLeastNWidgets(1));
    });

    testWidgets('STAR SHIFTS label is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('STAR SHIFTS'), findsAtLeastNWidgets(1));
    });

    testWidgets('TARGET CPLH label is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('TARGET CPLH'), findsAtLeastNWidgets(1));
    });

    testWidgets('TARGET SPLH label is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('TARGET SPLH'), findsAtLeastNWidgets(1));
    });

    testWidgets('TARGET PPA label is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('TARGET PPA'), findsAtLeastNWidgets(1));
    });

    testWidgets('RANGE QUALITY label is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('RANGE QUALITY'), findsAtLeastNWidgets(1));
    });
  });

  // ── D: Learn history-derived fields render ────────────────────────────────

  group('D — history-derived fields', () {
    testWidgets('LEAK REPEATS label is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('LEAK REPEATS'), findsAtLeastNWidgets(1));
    });

    testWidgets('REPEATS IN label is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('REPEATS IN'), findsAtLeastNWidgets(1));
    });

    testWidgets('BENCHMARK DAYPARTS label is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('BENCHMARK DAYPARTS'), findsAtLeastNWidgets(1));
    });
  });

  // ── E: manager override changes Learn source label ────────────────────────

  group('E — manager override in Learn', () {
    testWidgets('override active shows MANAGER STAR SHIFTS', (tester) async {
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.5, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.3, splh: 177, ppa: 43, covers: 228,
            isSelected: true),
      ]);

      await _openLearnTab(tester);
      expect(find.text('MANAGER STAR SHIFTS'), findsAtLeastNWidgets(1));

      BaselineData.clearManagerOverride();
    });
  });

  // ── F: Recurring Leak exposes deeper lever-card sections ─────────────────

  group('F — Recurring Leak depth', () {
    testWidgets('WHAT HAPPENED section is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('WHAT HAPPENED'), findsAtLeastNWidgets(1));
    });

    testWidgets('WHAT TO DO section is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('WHAT TO DO'), findsAtLeastNWidgets(1));
    });

    testWidgets('WHAT TO STUDY section is present in Recurring Leak',
        (tester) async {
      await _openLearnTab(tester);
      expect(find.text('WHAT TO STUDY'), findsAtLeastNWidgets(1));
    });
  });

  // ── G: Repeatable Wins exposes benchmark-pattern depth ───────────────────

  group('G — Repeatable Wins depth', () {
    testWidgets('WIN REPEATS label is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('WIN REPEATS'), findsAtLeastNWidgets(1));
    });

    testWidgets('BENCHMARK DAYPARTS label is present in Wins card',
        (tester) async {
      await _openLearnTab(tester);
      expect(find.text('BENCHMARK DAYPARTS'), findsAtLeastNWidgets(1));
    });

    testWidgets('WHAT HELD section is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('WHAT HELD'), findsAtLeastNWidgets(1));
    });

    testWidgets('WHAT TO PROTECT section is present', (tester) async {
      await _openLearnTab(tester);
      expect(find.text('WHAT TO PROTECT'), findsAtLeastNWidgets(1));
    });

    testWidgets('WHAT TO STUDY section is present in Wins card',
        (tester) async {
      await _openLearnTab(tester);
      // WHAT TO STUDY appears in both Recurring Leak and Repeatable Wins
      expect(find.text('WHAT TO STUDY'), findsAtLeastNWidgets(2));
    });
  });
}
