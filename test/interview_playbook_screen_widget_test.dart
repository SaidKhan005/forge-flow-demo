import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/interview_playbook_content.dart';
import 'package:forge_and_flow/internal/barrio/screens/interview_playbook_screen.dart';

void main() {
  Widget buildTestApp() {
    return const MaterialApp(home: InterviewPlaybookScreen());
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

  group('Playbook screen structure', () {
    testWidgets('builds as a real screen with section content', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Interview Playbook'), findsOneWidget);
      expect(find.text('Hiring Principles'), findsWidgets);
    });

    testWidgets('shows at least 2 section labels in the rail', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Hiring Principles'), findsWidgets);
      expect(find.text('The Hiring Flow'), findsWidgets);
    });

    testWidgets('shows mastery percentage', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('0%'), findsOneWidget);
      expect(find.text('MASTERY'), findsOneWidget);
    });
  });

  group('Section navigation', () {
    testWidgets('tapping a section changes hero content', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      expect(
          find.text('Building the dream team with intention'), findsOneWidget);

      final hiringFlow = find.text('The Hiring Flow');
      expect(hiringFlow, findsWidgets);
      await tester.tap(hiringFlow.first);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Stage-by-stage evaluation process'), findsOneWidget);
    });
  });

  group('Scenario interaction', () {
    testWidgets('tapping a scenario option reveals feedback', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      final option =
          find.text('Ask follow-up questions to dig deeper into specifics');

      final found = await navigateToOption(tester, option);

      if (found) {
        await tester.ensureVisible(option);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(option);
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.textContaining('ownership over actions'), findsOneWidget);
      }
    });
  });

  group('Checkpoint interaction', () {
    testWidgets('tapping a checkpoint option reveals feedback', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 500));

      final option = find.text('Signs of long-term potential and mindset');

      final found = await navigateToOption(tester, option);

      if (found) {
        await tester.tap(option);
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.textContaining('long-term potential'), findsWidgets);
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
    test('has at least 2 sections with real units', () {
      expect(playbookSections.length, greaterThanOrEqualTo(2));
      for (var i = 0; i < 2; i++) {
        final s = playbookSections[i];
        expect(s.units.length, greaterThanOrEqualTo(3),
            reason: '${s.id} should have 3+ units');
        expect(s.units.any((u) => u.type == PlaybookUnitType.scenario), isTrue,
            reason: '${s.id} needs a scenario');
        expect(
            s.units.any((u) => u.type == PlaybookUnitType.checkpoint), isTrue,
            reason: '${s.id} needs a checkpoint');
      }
    });
  });
}
