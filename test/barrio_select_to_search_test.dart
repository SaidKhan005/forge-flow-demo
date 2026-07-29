// Widget tests for the 2026-07-29 manual-reader search polish:
//   1) the reading deck is wrapped in a SelectionArea whose selection
//      menu adds a "Search the web" action (select-any-word-to-search),
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

  testWidgets('long-pressing a word builds a selection menu that adds '
      'Search the web to the default items (mobile)', (tester) async {
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
      final toolbar = area.contextMenuBuilder!(
        tester.element(regionFinder),
        region,
      ) as AdaptiveTextSelectionToolbar;

      final items = toolbar.buttonItems!;
      expect(items.map((item) => item.label), contains('Search the web'),
          reason: 'the selection menu must add the web search action');
      // The platform default items (Copy, Select all) carry a button
      // type, not a literal label, and must survive ahead of the custom
      // action so the reader still gets native Copy for free.
      expect(items.map((item) => item.type),
          contains(ContextMenuButtonType.copy),
          reason: 'the default Copy item must be preserved');
      expect(items.length, greaterThanOrEqualTo(2),
          reason: 'the custom action appends to the defaults, never replaces');
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
