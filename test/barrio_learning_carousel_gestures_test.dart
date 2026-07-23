// Widget tests for the learning-screen v2 redesign (2026-07-23,
// operator-approved Direction 1: "tap turns the page, drag scrolls the
// card" + chrome diet):
//
// - Right/left edge taps turn exactly one page.
// - A mostly-vertical drag on a long card scrolls the card and NEVER
//   turns the page (the pager only claims clearly horizontal drags).
// - A clearly horizontal fling still turns the page.
// - Card scroll offsets survive paging away and back (PageStorageKey).
// - Chapter-rail taps jump in place (same carousel State, no remount)
//   and never reset another card's scroll offset.
// - Overflowing cards show the bottom fade cue; it disappears at the
//   end of the card; short cards never show it.
//
// All at a 390x844 phone viewport. Every test asserts takeException()
// is null (overflow guard: this screen must not get denser).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/learning_carousel.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Long enough to overflow the ~500px card window at 390 wide.
final String _longBody = List.generate(
  28,
  (i) => 'Long fixture paragraph number ${i + 1} with enough words in it '
      'to wrap across a few lines on a phone width viewport.',
).join('\n\n');

/// Fixture manual: section 1 has a long overflowing card plus two short
/// cards; section 2 has two short cards (5 flat cards total, so a rail
/// jump from card 0 to section 2 disposes card 0 and exercises the
/// PageStorage offset restore).
final _fixtureDoc = BarrioTrainingDoc(
  id: 'fixture_gesture_doc',
  title: 'Gesture Fixture Manual',
  sourcePath: 'test://fixture',
  chapters: [
    HandbookChapter(
      id: 'ges_ch1',
      title: 'First Steps',
      subtitle: 'first fixture section',
      iconCodePoint: 0xe533,
      units: [
        HandbookUnit(
          id: 'ges_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Long Card',
          body: _longBody,
        ),
        const HandbookUnit(
          id: 'ges_c1_u2',
          type: HandbookUnitType.explainer,
          title: 'Short Card Two',
          body: 'Short fixture body two.',
        ),
        const HandbookUnit(
          id: 'ges_c1_u3',
          type: HandbookUnitType.explainer,
          title: 'Short Card Three',
          body: 'Short fixture body three.',
        ),
      ],
    ),
    const HandbookChapter(
      id: 'ges_ch2',
      title: 'Deep Waters',
      subtitle: 'second fixture section',
      iconCodePoint: 0xe556,
      units: [
        HandbookUnit(
          id: 'ges_c2_u1',
          type: HandbookUnitType.explainer,
          title: 'Short Card Four',
          body: 'Short fixture body four.',
        ),
        HandbookUnit(
          id: 'ges_c2_u2',
          type: HandbookUnitType.explainer,
          title: 'Short Card Five',
          body: 'Short fixture body five.',
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
    // Restore setState frame, then the hero fade + carousel entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  Finder cardScroll(int index) =>
      find.byKey(PageStorageKey<String>('learning_card_scroll_$index'));

  Finder overflowCue(int index) =>
      find.byKey(ValueKey<String>('learning_overflow_cue_$index'));

  double scrollOffset(WidgetTester tester, int index) => tester
      .state<ScrollableState>(find.descendant(
          of: cardScroll(index), matching: find.byType(Scrollable)))
      .position
      .pixels;

  double cueOpacity(WidgetTester tester, int index) =>
      tester.widget<AnimatedOpacity>(overflowCue(index)).opacity;

  Future<void> tapEdge(WidgetTester tester, {required bool right}) async {
    final rect = tester.getRect(find.byType(PageView));
    final x = right ? rect.right - 8 : rect.left + 8;
    await tester.tapAt(Offset(x, rect.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> dragCardVertically(WidgetTester tester, Offset offset) async {
    await tester.drag(cardScroll(0), offset);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a right-edge tap advances exactly one card', (tester) async {
    await pumpDoc(tester);
    expect(find.text('1 of 5'), findsOneWidget);

    await tapEdge(tester, right: true);
    expect(find.text('2 of 5'), findsOneWidget,
        reason: 'one right-edge tap must turn exactly one page');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a left-edge tap goes back one card', (tester) async {
    await pumpDoc(tester);
    await tapEdge(tester, right: true);
    expect(find.text('2 of 5'), findsOneWidget);

    await tapEdge(tester, right: false);
    expect(find.text('1 of 5'), findsOneWidget,
        reason: 'one left-edge tap must go back exactly one page');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a mostly-vertical drag scrolls the long card WITHOUT '
      'changing the page', (tester) async {
    await pumpDoc(tester);
    expect(find.text('1 of 5'), findsOneWidget);

    // Diagonal reading flick: 40px of slant against 300px of travel.
    await dragCardVertically(tester, const Offset(-40, -300));

    expect(find.text('1 of 5'), findsOneWidget,
        reason: 'a near-vertical drag must never turn the page');
    expect(scrollOffset(tester, 0), greaterThan(100),
        reason: 'the drag must have scrolled the card body');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a clearly horizontal fling changes the page',
      (tester) async {
    await pumpDoc(tester);
    expect(find.text('1 of 5'), findsOneWidget);

    await tester.fling(
        find.byType(PageView), const Offset(-250, 0), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('2 of 5'), findsOneWidget,
        reason: 'a clearly horizontal fling must still turn the page');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a card scroll offset survives paging away one card and '
      'back', (tester) async {
    await pumpDoc(tester);
    await dragCardVertically(tester, const Offset(0, -300));
    final saved = scrollOffset(tester, 0);
    expect(saved, greaterThan(100));

    await tapEdge(tester, right: true);
    expect(find.text('2 of 5'), findsOneWidget);
    await tapEdge(tester, right: false);
    expect(find.text('1 of 5'), findsOneWidget);

    expect(scrollOffset(tester, 0), closeTo(saved, 0.5),
        reason: 'paging away and back must not reset the card scroll');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rail tap jumps section in place: same carousel State, '
      'and the other card keeps its scroll offset', (tester) async {
    await pumpDoc(tester);
    await dragCardVertically(tester, const Offset(0, -300));
    final saved = scrollOffset(tester, 0);
    expect(saved, greaterThan(100));

    final stateBefore =
        tester.state<LearningCarouselState>(find.byType(LearningCarousel));

    // Jump to section 2 (card 4 of 5): far enough that card 0 gets
    // disposed, which is exactly the case the PageStorageKey covers.
    await tester.tap(find.text('Deep Waters'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('SECTION 2 OF 2'), findsOneWidget);
    expect(find.text('4 of 5'), findsOneWidget);
    final stateAfter =
        tester.state<LearningCarouselState>(find.byType(LearningCarousel));
    expect(identical(stateBefore, stateAfter), isTrue,
        reason: 'rail taps must move the deck in place, not remount it');

    // Jump back: the long card returns with its offset restored.
    await tester.tap(find.text('First Steps'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('1 of 5'), findsOneWidget);
    expect(scrollOffset(tester, 0), closeTo(saved, 0.5),
        reason: 'a rail jump must not wipe another card\'s scroll offset');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the overflow cue shows on a long card, disappears at the '
      'end, and never shows on a short card', (tester) async {
    await pumpDoc(tester);

    expect(cueOpacity(tester, 0), 1.0,
        reason: 'an overflowing card must look scrollable');

    // Scroll to the very end of the card: the cue must stand down.
    await dragCardVertically(tester, const Offset(0, -10000));
    expect(cueOpacity(tester, 0), 0.0,
        reason: 'the cue must disappear at the end of the card');

    // A short card never shows the cue (no phantom "more below").
    await tapEdge(tester, right: true);
    expect(find.text('2 of 5'), findsOneWidget);
    expect(cueOpacity(tester, 1), 0.0,
        reason: 'a card that fits must not claim more content below');
    expect(tester.takeException(), isNull);
  });
}
