// Widget tests for the chapter-rail swipe-follow behavior (2026-07-26
// operator request "as we scroll through cards horizontally the chapters
// at the top also move along").
//
// The rail is a horizontally scrolling strip. Before this pass it
// highlighted the active chapter but never scrolled itself, so swiping
// the deck into a chapter whose tile was off-screen left the active tile
// stranded out of view. Now, whenever the active chapter changes, the
// rail brings the active tile into view (centered as far as the scroll
// extent allows). Reduce-motion jumps instead of animating.
//
// Coverage:
//   1. Rail unit: activating an off-screen chapter scrolls the rail so
//      that tile becomes visible (animated glide).
//   2. Rail unit: with reduce-motion the reveal is an instant jump, not
//      a running animation.
//   3. Screen level: swiping the deck (edge taps) into a later chapter
//      scrolls the rail so the newly active tile is on-screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_chapter_rail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Nine single-card chapters: far more tiles than fit a phone width, so
/// the last several tiles sit off-screen at scroll offset 0.
const List<String> _titles = <String>[
  'Alpha',
  'Bravo',
  'Charlie',
  'Delta',
  'Echo',
  'Foxtrot',
  'Golf',
  'Hotel',
  'India',
];

List<HandbookChapter> _buildChapters() => [
      for (var i = 0; i < _titles.length; i++)
        HandbookChapter(
          id: 'ch_$i',
          title: _titles[i],
          subtitle: 'section ${i + 1}',
          iconCodePoint: 0xe533,
          units: [
            HandbookUnit(
              id: 'ch_${i}_u0',
              type: HandbookUnitType.explainer,
              title: _titles[i],
              body: 'Body for ${_titles[i]}.',
            ),
          ],
        ),
    ];

void main() {
  const phoneSize = Size(390, 844);
  final chapters = _buildChapters();

  Widget railHarness({required int activeIndex, bool reduceMotion = false}) {
    return MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: Scaffold(
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HandbookChapterRail(
                    chapters: chapters,
                    activeIndex: activeIndex,
                    completedChapterIds: const <String>{},
                    activeAccent: BarrioColors.tealWarm,
                    onChapterTap: (_) {},
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  double railOffset(WidgetTester tester) => tester
      .state<ScrollableState>(find.descendant(
        of: find.byType(HandbookChapterRail),
        matching: find.byType(Scrollable),
      ))
      .position
      .pixels;

  // Scoped to the rail so a card whose title matches a chapter title
  // never confuses the finder.
  double tileLeft(WidgetTester tester, String title) => tester
      .getTopLeft(find.descendant(
        of: find.byType(HandbookChapterRail),
        matching: find.text(title),
      ))
      .dx;

  testWidgets('activating an off-screen chapter scrolls the rail so its '
      'tile becomes visible', (tester) async {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(railHarness(activeIndex: 0));
    await tester.pumpAndSettle();

    expect(railOffset(tester), 0,
        reason: 'the rail opens at its start with chapter 0 active');
    final lastTitle = _titles.last;
    expect(tileLeft(tester, lastTitle), greaterThan(phoneSize.width),
        reason: 'the last tile starts off the right edge');

    // The deck swiped all the way into the last chapter: the rail must
    // follow so the last tile is no longer stranded off-screen.
    await tester.pumpWidget(railHarness(activeIndex: chapters.length - 1));
    await tester.pumpAndSettle();

    expect(railOffset(tester), greaterThan(0),
        reason: 'the rail scrolled to reveal the active tile');
    final revealedLeft = tileLeft(tester, lastTitle);
    expect(revealedLeft, lessThan(phoneSize.width),
        reason: 'the active tile is now within the viewport');
    expect(revealedLeft, greaterThanOrEqualTo(0),
        reason: 'the active tile is fully on-screen');
  });

  testWidgets('reduce-motion reveals the active tile with an instant jump, '
      'not a running animation', (tester) async {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(railHarness(activeIndex: 0, reduceMotion: true));
    await tester.pumpAndSettle();
    expect(railOffset(tester), 0);

    await tester.pumpWidget(
      railHarness(activeIndex: chapters.length - 1, reduceMotion: true),
    );
    // A single pump runs the post-frame reveal. With reduce-motion the
    // scroll move is Duration.zero, so the offset lands at its final
    // value immediately rather than gliding over several frames. (The
    // tile-highlight AnimatedContainer still animates; only the scroll
    // must jump, so we compare the scroll offset, not hasRunningAnimations.)
    await tester.pump();
    final immediate = railOffset(tester);

    await tester.pumpAndSettle();
    final settled = railOffset(tester);

    expect(settled, greaterThan(0),
        reason: 'reduce-motion still brings the active tile into view');
    expect(immediate, settled,
        reason: 'reduce-motion jumps the scroll to its final offset at once');
    expect(tileLeft(tester, _titles.last), lessThan(phoneSize.width),
        reason: 'the active tile is visible after the instant jump');
  });

  testWidgets('swiping the deck into a later chapter scrolls the rail so '
      'the active tile is visible', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final doc = BarrioTrainingDoc(
      id: 'rail_follow_fixture',
      title: 'Rail Follow Fixture',
      sourcePath: 'test://rail-follow',
      chapters: chapters,
    );

    await tester.pumpWidget(MaterialApp(home: TrainingDocScreen(doc: doc)));
    // setState frame, then the hero fade + carousel entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text('SECTION 1 OF 9'), findsOneWidget);
    expect(railOffset(tester), 0,
        reason: 'the rail starts pinned to its left edge');
    // The chapter we will swipe into starts off-screen.
    expect(tileLeft(tester, 'Echo'), greaterThan(phoneSize.width),
        reason: 'the target chapter tile is off-screen before swiping');

    // Swipe the deck forward four cards (edge taps): each card is its
    // own chapter, so this lands on chapter 5 ("Echo").
    Future<void> tapRightEdge() async {
      final rect = tester.getRect(find.byType(PageView));
      await tester.tapAt(Offset(rect.right - 8, rect.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    for (var i = 0; i < 4; i++) {
      await tapRightEdge();
    }
    await tester.pumpAndSettle();

    expect(find.text('SECTION 5 OF 9'), findsOneWidget,
        reason: 'four forward swipes reach the fifth chapter');
    expect(railOffset(tester), greaterThan(0),
        reason: 'the rail followed the deck into the off-screen chapter');
    final echoLeft = tileLeft(tester, 'Echo');
    expect(echoLeft, lessThan(phoneSize.width),
        reason: 'the newly active tile is now on-screen');
    expect(echoLeft, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });
}
