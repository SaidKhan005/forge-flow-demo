// Prompt 7.12 — Shift Visual Widget Tests
//
// Verifies that the polished Shift screen still exposes the required
// structure and key visible labels after the visual pass.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_flow_demo/data/meridian_data.dart';
import 'package:forge_flow_demo/data/shift_data_source.dart';
import 'package:forge_flow_demo/data/week_data_notifier.dart';
import 'package:forge_flow_demo/screens/shift_dashboard.dart';

Widget _buildShiftDashboard() => ChangeNotifierProvider<WeekDataNotifier>(
      create: (_) => WeekDataNotifier(const StaticShiftDataSource()),
      child: const MaterialApp(
        home: Scaffold(body: ShiftDashboard()),
      ),
    );

void main() {
  // ── A: core sections render ──────────────────────────────────────────────

  group('A — core sections', () {
    testWidgets('restaurant name is present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text(MeridianConfig.restaurantName, skipOffstage: false),
          findsOneWidget);
    });

    testWidgets('daypart and day are present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text(
              '${ShiftSnapshot.daypart} \u00b7 ${ShiftSnapshot.day}',
              skipOffstage: false),
          findsOneWidget);
    });

    testWidgets('time and service elapsed are present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text(
              '${ShiftSnapshot.time} \u00b7 ${ShiftSnapshot.serviceElapsed}',
              skipOffstage: false),
          findsOneWidget);
    });

    testWidgets('LABOR % VARIANCE header is present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text('LABOR % VARIANCE', skipOffstage: false),
          findsOneWidget);
    });
  });

  // ── B: OPZ widget key pieces ─────────────────────────────────────────────

  group('B — OPZ widget', () {
    testWidgets('OPZ status label exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      final label =
          BaselineData.opzStatusLabelForCplh(ShiftSnapshot.actualCPLH);
      expect(find.text(label, skipOffstage: false), findsOneWidget);
    });

    testWidgets('CPLH label exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text('CPLH', skipOffstage: false),
          findsAtLeastNWidgets(1));
    });

    testWidgets('target value exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text(BaselineData.derivedTargetCPLH.toStringAsFixed(2),
              skipOffstage: false),
          findsAtLeastNWidgets(1));
    });

    testWidgets('ceiling value exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text(BaselineData.opzCeilingCPLH.toStringAsFixed(2),
              skipOffstage: false),
          findsAtLeastNWidgets(1));
    });
  });

  // ── C: metric cards render ───────────────────────────────────────────────

  group('C — metric cards', () {
    testWidgets('COVERS card exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text('COVERS', skipOffstage: false), findsAtLeastNWidgets(1));
    });

    testWidgets('PPA card exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text('PPA', skipOffstage: false), findsAtLeastNWidgets(1));
    });

    testWidgets('CPLH card exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text('CPLH', skipOffstage: false), findsAtLeastNWidgets(1));
    });

    testWidgets('SPLH card exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text('SPLH', skipOffstage: false), findsAtLeastNWidgets(1));
    });

    testWidgets('BLENDED WAGE card exists', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text('BLENDED WAGE', skipOffstage: false),
          findsAtLeastNWidgets(1));
    });
  });

  // ── D: teaching container ────────────────────────────────────────────────

  group('D — teaching container', () {
    testWidgets('active lever whatHappened text is present', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(
          find.text(ShiftSnapshot.primaryLeverCard.whatHappened,
              skipOffstage: false),
          findsOneWidget);
    });
  });

  // ── E: hero truth intact ─────────────────────────────────────────────────

  group('E — hero truth', () {
    test('exactly one hero card in ShiftMetrics.cards', () {
      final heroes = ShiftMetrics.cards.where((c) => c.isHero).toList();
      expect(heroes.length, equals(1));
    });

    testWidgets('DRIVER badge renders for hero card', (tester) async {
      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();
      expect(find.text('DRIVER', skipOffstage: false),
          findsAtLeastNWidgets(1));
    });
  });
}
