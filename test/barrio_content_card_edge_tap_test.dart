// Regression test for the #1483-audit edge-tap bug (fixed this slice):
// HandbookLessonCard's onTapCancel was unconditionally non-null, so a
// TapGestureRecognizer registered even on explainer (non-interactive)
// cards and starved the #1481 carousel edge tap zones everywhere the
// card content sat under them. The #1481 suite could not catch it: its
// edge taps landed in the chevron gutter OUTSIDE the card content.
//
// These taps land INSIDE the card content, in the invisible edge tap
// band, on a REAL content card (explainer unit): the tap must reach
// the carousel's zone and turn exactly one page. Quiz-card edge-tap
// behavior stays covered by barrio_quiz_checkpoint_widget_test.dart.
//
// All at a 390x844 phone viewport; every test asserts takeException()
// is null.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fixtureDoc = BarrioTrainingDoc(
  id: 'fixture_edge_tap_doc',
  title: 'Edge Tap Fixture Manual',
  sourcePath: 'test://fixture',
  chapters: [
    HandbookChapter(
      id: 'edge_ch1',
      title: 'Only Section',
      subtitle: 'fixture section',
      iconCodePoint: 0xe533,
      units: [
        HandbookUnit(
          id: 'edge_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Card One',
          body: 'A short explainer body that sits fully under the edge '
              'tap bands on a phone width viewport.',
        ),
        HandbookUnit(
          id: 'edge_c1_u2',
          type: HandbookUnitType.explainer,
          title: 'Card Two',
          body: 'Second short fixture body.',
        ),
        HandbookUnit(
          id: 'edge_c1_u3',
          type: HandbookUnitType.explainer,
          title: 'Card Three',
          body: 'Third short fixture body.',
        ),
      ],
    ),
  ],
);

void main() {
  const phoneSize = Size(390, 844);

  Future<void> pumpDoc(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  /// Taps INSIDE the card content, within the carousel's invisible
  /// edge tap band but clearly left/right of the 30px chevron gutters
  /// (x offset 62 from the PageView edge, same probe as the quiz
  /// suite), in the card's badge/title band near the top so the tap
  /// is guaranteed to sit ON the card, not below a short card.
  Future<void> tapCardEdgeZone(WidgetTester tester,
      {required bool right}) async {
    final rect = tester.getRect(find.byType(PageView));
    final x = right ? rect.right - 62 : rect.left + 62;
    await tester.tapAt(Offset(x, rect.top + 36));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('an edge tap ON an explainer content card advances exactly '
      'one page (onTapCancel no longer registers a recognizer)',
      (tester) async {
    await pumpDoc(tester);
    expect(find.text('1 of 3'), findsOneWidget);

    await tapCardEdgeZone(tester, right: true);
    expect(find.text('2 of 3'), findsOneWidget,
        reason: 'a right in-card edge tap on a content card must turn '
            'exactly one page: the explainer card must register NO tap '
            'recognizer that could starve the zone');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a left in-card edge tap on a content card goes back one '
      'page', (tester) async {
    await pumpDoc(tester);
    await tapCardEdgeZone(tester, right: true);
    expect(find.text('2 of 3'), findsOneWidget);

    await tapCardEdgeZone(tester, right: false);
    expect(find.text('1 of 3'), findsOneWidget,
        reason: 'the left band on a content card must also stay live');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap in the middle of a content card never turns the '
      'page', (tester) async {
    await pumpDoc(tester);
    final rect = tester.getRect(find.byType(PageView));

    // Same on-card band as the edge probes, horizontally centered:
    // over content, outside both edge tap zones.
    await tester.tapAt(Offset(rect.center.dx, rect.top + 36));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('1 of 3'), findsOneWidget,
        reason: 'the center of the card is not an edge tap zone');
    expect(tester.takeException(), isNull);
  });
}
