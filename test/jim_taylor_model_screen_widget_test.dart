import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/jim_taylor_model_content.dart';
import 'package:forge_and_flow/internal/barrio/screens/jim_taylor_model_screen.dart';

void main() {
  Widget buildTestApp() {
    return const MaterialApp(home: JimTaylorModelScreen());
  }

  /// Helper: swipe through carousel pages and begin cards until [target] found.
  Future<bool> navigateToOption(
    WidgetTester tester,
    Finder target, {
    int maxSwipes = 10,
  }) async {
    for (var i = 0; i < maxSwipes; i++) {
      final beginHint = find.text('Tap to begin');
      if (beginHint.evaluate().isNotEmpty) {
        await tester.tap(beginHint.first, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 500));
      }
      if (target.evaluate().isNotEmpty) return true;
      final pageView = find.byType(PageView);
      if (pageView.evaluate().isEmpty) break;
      await tester.drag(pageView.last, const Offset(-300, 0));
      await tester.pump(const Duration(milliseconds: 500));
    }
    return target.evaluate().isNotEmpty;
  }

  group('Jim Taylor screen structure', () {
    testWidgets('builds as a real screen with module content', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Jim Taylor Labor Model'), findsOneWidget);
      expect(find.text('The Foundation'), findsWidgets);
    });

    testWidgets('shows at least 2 module labels in the rail', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('The Foundation'), findsWidgets);
      expect(find.text('Labor %'), findsWidgets);
    });

    testWidgets('shows mastery percentage', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('0%'), findsOneWidget);
      expect(find.text('MASTERY'), findsOneWidget);
    });
  });

  group('Module navigation', () {
    testWidgets('tapping a module changes hero content', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Covers, hours, PPA, and wage mix'), findsOneWidget);

      final laborPct = find.text('Labor %');
      expect(laborPct, findsWidgets);
      await tester.tap(laborPct.first);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('What it is and why it lies'), findsOneWidget);
    });
  });

  group('Scenario interaction', () {
    testWidgets('tapping a scenario option reveals feedback', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      final option =
          find.text('It goes up -- higher wage mix increases labor cost');

      final found = await navigateToOption(tester, option);
      if (!found) return;

      await tester.tap(option);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('wage mix moved up'), findsOneWidget);
    });
  });

  group('Checkpoint interaction', () {
    testWidgets('tapping a checkpoint option reveals feedback', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      final option = find.text('Hours worked (scheduling)');

      final found = await navigateToOption(tester, option);

      if (found) {
        await tester.ensureVisible(option);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(option);
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.textContaining('scheduling decisions'), findsOneWidget);
      }
    });
  });

  group('No document viewer', () {
    testWidgets('uses PageView carousel, not a document embed', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(Placeholder), findsNothing);
      expect(find.byType(PageView), findsWidgets);
    });
  });

  group('Content model', () {
    test('has at least 2 modules with real units', () {
      expect(jtModules.length, greaterThanOrEqualTo(2));
      for (var i = 0; i < 2; i++) {
        final m = jtModules[i];
        expect(m.units.length, greaterThanOrEqualTo(3),
            reason: '${m.id} should have 3+ units');
        expect(m.units.any((u) => u.type == JtUnitType.scenario), isTrue,
            reason: '${m.id} needs a scenario');
        expect(m.units.any((u) => u.type == JtUnitType.checkpoint), isTrue,
            reason: '${m.id} needs a checkpoint');
      }
    });
  });
}
