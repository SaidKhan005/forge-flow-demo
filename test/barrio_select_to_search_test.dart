// Widget tests for the 2026-07-29 manual-reader search polish:
//   1) the reading deck is wrapped in a SelectionArea whose selection
//      menu offers only "Ask chat" and "Search the web"
//      (select-any-word action),
//   2) the header search actions grew to a 28px glyph on a 48px tap
//      target (bigger search buttons).
//
// The gesture-coexistence proof (tap-to-advance, swipe, card scroll,
// rail jump, term-link taps, image zoom all still work under the
// SelectionArea) lives in the existing reader suites, which run against
// this same screen: barrio_learning_carousel_gestures_test.dart,
// barrio_content_card_edge_tap_test.dart, barrio_term_popover_test.dart,
// and barrio_training_photo_grid_test.dart.
//
// All at a 390x844 phone viewport; every test asserts takeException()
// is null (overflow guard: the header must not get denser).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/learning_carousel.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fixtureBody =
    'Amatitan is a town in Jalisco tied to the history of tequila.';

const _fixtureDoc = BarrioTrainingDoc(
  id: 'fixture_select_search_doc',
  title: 'Select Search Fixture',
  sourcePath: 'test://fixture',
  chapters: [
    HandbookChapter(
      id: 'ss_ch1',
      title: 'Only Section',
      subtitle: 'fixture section',
      iconCodePoint: 0xe533,
      units: [
        HandbookUnit(
          id: 'ss_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Amatitan',
          body: _fixtureBody,
        ),
        HandbookUnit(
          id: 'ss_c1_u2',
          type: HandbookUnitType.explainer,
          title: 'Card Two',
          body: 'Second short fixture body.',
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
      const MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  testWidgets('long-pressing a word builds a selection menu with only '
      'Ask chat and Search the web (mobile)', (tester) async {
    // Reset the platform override in a finally so the foundation-var
    // invariant check (which runs before addTearDown) never trips.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpDoc(tester);
      // Drain any pending reader async (streak/progress services) so a
      // late frame never clears the selection out from under the menu.
      await tester.pumpAndSettle();

      // Long-press a word to establish a real, non-empty selection: the
      // gesture the reader uses. A deliberate press-and-hold past the
      // long-press threshold (then settle) makes the selection land. The
      // OS selection toolbar renders in a platform overlay that is not
      // findable in the VM test binding, so the menu itself is asserted
      // by invoking the wired builder against the live selection state
      // (the same call Flutter makes to show it).
      final gesture =
          await tester.startGesture(tester.getCenter(find.text(_fixtureBody)));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await tester.pumpAndSettle();

      final regionFinder = find.byType(SelectableRegion);
      final region = tester.state<SelectableRegionState>(regionFinder);
      final area = tester.widget<SelectionArea>(
        find.ancestor(
          of: find.byType(LearningCarousel),
          matching: find.byType(SelectionArea),
        ),
      );
      // Branded menu (2026-07-31 operator request): the generic system
      // popup was replaced with the Barrio glass surface, so the builder
      // now returns a TextSelectionToolbar carrying our own action
      // widgets rather than an AdaptiveTextSelectionToolbar of
      // buttonItems. The contract under test is unchanged: exactly two
      // actions, and none of the native defaults.
      final menu = area.contextMenuBuilder!(
        tester.element(regionFinder),
        region,
      );
      expect(menu, isA<TextSelectionToolbar>(),
          reason: 'the reader floats its own branded selection surface');
      final toolbar = menu as TextSelectionToolbar;
      expect(toolbar.children.length, 2,
          reason: 'exactly two actions: Ask chat and Search the web');

      // Render the actions on their own to read their labels: the live
      // toolbar draws in a platform overlay the test binding cannot find.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(mainAxisSize: MainAxisSize.min, children: toolbar.children),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Ask chat'), findsOneWidget);
      expect(find.text('Search the web'), findsOneWidget);
      // Operator curation (2026-07-29): the native Copy / Select all
      // defaults stay dropped.
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Select all'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the reading deck is wrapped in a SelectionArea wired for '
      'select-to-search', (tester) async {
    await pumpDoc(tester);

    final selectionArea = tester.widget<SelectionArea>(
      find.ancestor(
        of: find.byType(LearningCarousel),
        matching: find.byType(SelectionArea),
      ),
    );
    expect(selectionArea.contextMenuBuilder, isNotNull,
        reason: 'the deck must add a Search the web item to the menu');
    expect(selectionArea.onSelectionChanged, isNotNull,
        reason: 'selection changes must feed the Search the web action');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the header search actions are a 28px glyph on a 48px tap '
      'target', (tester) async {
    await pumpDoc(tester);

    for (final tooltip in const ['Search this manual', 'Search the web']) {
      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.iconSize, 28,
          reason: '$tooltip icon must step up from 22 to 28');
      expect(button.constraints?.minWidth, 48,
          reason: '$tooltip must keep a comfortable 48px tap target');
      expect(button.constraints?.minHeight, 48,
          reason: '$tooltip must keep a comfortable 48px tap target');
    }
    expect(tester.takeException(), isNull);
  });
}
