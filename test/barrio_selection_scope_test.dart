// Perf audit A9, measured and REJECTED: the reading deck's
// [SelectionArea] must stay ABOVE the pager, not inside the card
// builder.
//
// A9 proposed scoping the deck's one SelectionArea to the current card
// so fewer text spans register with a SelectionRegistrar. Building it
// (one SelectionArea per page, keyed per index, with the tap-away
// Listener and the toolbar's clearSelection moved along with it) turned
// four reading gestures red, because a [SelectableRegion] is not just a
// registrar: it plants a RawGestureDetector carrying a
// TapAndHorizontalDragGestureRecognizer, a LongPressGestureRecognizer
// and a right-click TapGestureRecognizer
// (`selectable_region.dart:634-712`, `:1948-1950`). Today those sit
// ABOVE the carousel's `_StronglyHorizontalDragRecognizer` and its
// invisible edge tap zones, so the deeper reading gestures are added to
// the arena first and win. Move the area into the card and the order
// flips: the card's own selection recognizers win the sweep instead.
// That is the #1483 lesson exactly, one layer up.
//
// Measured on this tree (see the PR body for the full table). The
// heaviest authored card in the corpus, `jim_taylor_labor_model`
// chapter 3 unit 1 (51 chunks), opened as the visible page: the single
// region registers 61 selectable paragraphs across the 3 live cards.
// Per-card scoping splits that into 4 / 53 / 3, so the visible card's
// own registrar only drops 61 to 53. The neighbours were never the
// cost; the table-heavy card the audit worried about IS the cost, and
// scoping does not move it.
//
// So this file does not test a change. It locks the arrangement that
// was measured to be the right one. Re-applied against the rejected
// per-card build, the first three tests go red and the last two stay
// green, which is the honest shape of the finding: per-card scoping
// does NOT break highlight capture, the anchor registry, or the menu
// actions. It breaks the page turn. The highlight and menu tests are
// here because they are new coverage either way: every test in this
// file runs with more than one card alive, which the single-card
// fixtures in `barrio_highlight_reader_test.dart` and
// `barrio_select_to_search_test.dart` cannot exercise, and no existing
// test creates a highlight through the menu and then remounts the
// manual to prove it came back.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_highlight_anchors.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_highlights_service.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _firstPara = 'Serve the guest before you clear the table, and keep '
    'the pass moving while the window is full.';
const _secondPara = 'Then reset the setting for the next party so the room '
    'never waits on a table that is already free.';

/// Four cards in one section. The visible card carries two long
/// paragraphs and every neighbour carries one short line, so the
/// registry's "most selected characters wins" tie break
/// ([BarrioHighlightAnchorRegistry.selectedUnitId]) resolves to the
/// visible card without the test having to guess.
const _fixtureDoc = BarrioTrainingDoc(
  id: 'fixture_selection_scope_doc',
  title: 'Selection Scope Fixture',
  sourcePath: 'test://fixture',
  chapters: <HandbookChapter>[
    HandbookChapter(
      id: 'sel_ch1',
      title: 'Only Section',
      subtitle: 'fixture section',
      iconCodePoint: 0xe533,
      units: <HandbookUnit>[
        HandbookUnit(
          id: 'sel_c1_u0',
          type: HandbookUnitType.explainer,
          title: 'Service',
          body: '$_firstPara\n\n$_secondPara',
        ),
        HandbookUnit(
          id: 'sel_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Card Two',
          body: 'Short two.',
        ),
        HandbookUnit(
          id: 'sel_c1_u2',
          type: HandbookUnitType.explainer,
          title: 'Card Three',
          body: 'Short three.',
        ),
        HandbookUnit(
          id: 'sel_c1_u3',
          type: HandbookUnitType.explainer,
          title: 'Card Four',
          body: 'Short four.',
        ),
      ],
    ),
  ],
);

/// Every body run the reader is showing, as (text, style) pairs. Same
/// probe as `barrio_highlight_reader_test.dart`: body prose is the
/// 1.62 line-height style at one of the two body sizes.
List<(String, TextStyle?)> _bodyRuns(WidgetTester tester) {
  final out = <(String, TextStyle?)>[];
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final span = text.textSpan;
    final rootStyle = text.style ?? (span is TextSpan ? span.style : null);
    if (rootStyle == null || rootStyle.height != 1.62) continue;
    if (rootStyle.fontSize != 13.5 && rootStyle.fontSize != 12.5) continue;
    if (text.data != null) {
      out.add((text.data!, rootStyle));
      continue;
    }
    if (span is! TextSpan) continue;
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan && child.text != null) {
        out.add((child.text!, rootStyle.merge(child.style)));
      }
    }
  }
  return out;
}

/// The washed (marked) runs, in reading order.
List<String> _washedTexts(WidgetTester tester) => <String>[
      for (final run in _bodyRuns(tester))
        if (run.$2?.backgroundColor != null) run.$1,
    ];

void main() {
  const phoneSize = Size(390, 844);

  Future<void> pumpReader(WidgetTester tester) async {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
    );
    await tester.pumpAndSettle();
  }

  /// A real, live selection over the text of the VISIBLE card.
  ///
  /// A reader makes one with a long-press and a drag. A widget test
  /// cannot drag across a scrollable without tripping a framework
  /// assertion in `_ScrollableSelectionContainerDelegate` that predates
  /// this screen, so `selectAll` is used: the same public entry point
  /// the framework's own toolbar calls, landing in the same place.
  /// Pass [withMenu] to float the reader's selection menu too.
  ///
  /// Deliberately reached through the region that OWNS the visible
  /// card rather than through `find.byType(SelectableRegion)`, so these
  /// tests keep working whatever the region count is and fail on
  /// behaviour instead of on a finder that found two of something.
  Future<void> selectVisibleCard(
    WidgetTester tester, {
    bool withMenu = false,
  }) async {
    final region = find.ancestor(
      of: find.byWidgetPredicate(
        (w) => w is HandbookLessonCard && w.unit.id == 'sel_c1_u0',
      ),
      matching: find.byType(SelectableRegion),
    );
    expect(region, findsWidgets,
        reason: 'the visible card must sit inside a selection region');
    // Nearest enclosing region first.
    tester
        .state<SelectableRegionState>(region.first)
        .selectAll(withMenu ? SelectionChangedCause.toolbar : null);
    await tester.pumpAndSettle();
  }

  /// Taps INSIDE the card content, in the carousel's invisible edge tap
  /// band but clear of the 30px chevron gutters, in the card's top
  /// badge band. Same probe as `barrio_content_card_edge_tap_test.dart`.
  Future<void> tapCardEdgeZone(
    WidgetTester tester, {
    required bool right,
  }) async {
    final rect = tester.getRect(find.byType(PageView));
    final x = right ? rect.right - 62 : rect.left + 62;
    await tester.tapAt(Offset(x, rect.top + 36));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Captures the URL the reader hands to url_launcher, so the two
  /// outbound menu actions can be proved end to end rather than by
  /// their labels. Returns the list the handler fills in.
  List<String> captureLaunchedUrls(WidgetTester tester) {
    final launched = <String>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        if (call.method == 'launch') {
          launched.add((call.arguments as Map<Object?, Object?>)['url']!
              as String);
        }
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    return launched;
  }

  setUp(() {
    barrioClearBodySpanCache();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('the deck has ONE selection region and it sits above the '
      'pager, with several cards live', (tester) async {
    await pumpReader(tester);

    final liveCards = tester
        .widgetList<HandbookLessonCard>(find.byType(HandbookLessonCard))
        .length;
    expect(liveCards, greaterThan(1),
        reason: 'the pager keeps neighbours alive, so this fixture is a '
            'real multi-card deck and the single-region claim below is '
            'not trivially true');

    expect(find.byType(SelectableRegion), findsOneWidget,
        reason: 'perf audit A9: ONE region for the whole deck. A region '
            'per card plants selection recognizers below the pager and '
            'starves the edge tap zones and the horizontal drag');
    expect(
      find.descendant(
        of: find.byType(SelectableRegion),
        matching: find.byType(PageView),
      ),
      findsOneWidget,
      reason: 'the region must be an ANCESTOR of the pager so the '
          'carousel gestures are added to the arena first and win',
    );
    expect(
      find
          .descendant(
            of: find.byType(SelectableRegion),
            matching: find.byType(HandbookLessonCard),
          )
          .evaluate()
          .length,
      liveCards,
      reason: 'every live card sits under the same one region',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an in-card edge tap still turns the page while a selection '
      'is live', (tester) async {
    await pumpReader(tester);
    expect(find.text('1 of 4'), findsOneWidget);
    await selectVisibleCard(tester);

    await tapCardEdgeZone(tester, right: true);
    expect(find.text('2 of 4'), findsOneWidget,
        reason: 'the edge tap zone must still win the arena with a live '
            'selection on the card');

    await tapCardEdgeZone(tester, right: false);
    expect(find.text('1 of 4'), findsOneWidget,
        reason: 'the left band stays live too');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a clearly horizontal fling still turns the page while a '
      'selection is live', (tester) async {
    await pumpReader(tester);
    expect(find.text('1 of 4'), findsOneWidget);
    await selectVisibleCard(tester);

    // Flung from ON the card's body text, not from the pager's centre:
    // the centre of a short card is empty space below the content,
    // where no selection recognizer sits and the drag would prove
    // nothing about the arena.
    await tester.flingFrom(
      tester.getCenter(find.text(_firstPara)),
      const Offset(-250, 0),
      1200,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('2 of 4'), findsOneWidget,
        reason: 'the pager drag must still beat the selection region\'s '
            'own horizontal drag recognizer');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Highlight marks the visible card across both its paragraphs '
      'and the mark survives a remount', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpReader(tester);
      expect(_washedTexts(tester), isEmpty);

      await selectVisibleCard(tester, withMenu: true);
      await tester.tap(find.text('Highlight'));
      await tester.pumpAndSettle();

      // One highlight, attributed to the VISIBLE card even though the
      // neighbours are alive and registered, carrying one segment per
      // rendered chunk.
      final prefs = await SharedPreferences.getInstance();
      final raw =
          prefs.getString(BarrioHighlightsService.keyFor(_fixtureDoc.id));
      expect(raw, isNotNull, reason: 'the mark must reach the device store');
      final entries = json.decode(raw!) as List<Object?>;
      expect(entries, hasLength(1));
      final stored = BarrioHighlight.decode(entries.single)!;
      expect(stored.unitId, 'sel_c1_u0',
          reason: 'the card the reader is working in, not a neighbour');
      expect(stored.segments.map((s) => s.chunk).toList(), <int>[0, 1],
          reason: 'one segment per rendered chunk, in reading order');
      expect(_firstPara, contains(stored.segments[0].text));
      expect(_secondPara, contains(stored.segments[1].text));

      // Painted right away.
      final marked = _washedTexts(tester);
      expect(marked, <String>[
        stored.segments[0].text,
        stored.segments[1].text,
      ]);

      // Remount the manual from scratch: the mark comes back painted on
      // exactly the same words, read back out of the store rather than
      // out of this screen's memory.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();
      expect(find.byType(TrainingDocScreen), findsNothing);
      await tester.pumpWidget(
        const MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
      );
      await tester.pumpAndSettle();

      expect(_washedTexts(tester), marked,
          reason: 'a highlight that does not survive closing the manual '
              'is not a highlight');
      expect(
        _bodyRuns(tester)
            .firstWhere((r) => r.$1 == marked.first)
            .$2
            ?.backgroundColor,
        barrioHighlightWash(kBarrioHighlightDefaultColor),
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Ask chat and Search the web carry the selected words out of '
      'the reader', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final launched = captureLaunchedUrls(tester);
      await pumpReader(tester);

      await selectVisibleCard(tester, withMenu: true);
      await tester.tap(find.text('Ask chat'));
      await tester.pumpAndSettle();
      expect(launched, hasLength(1), reason: 'Ask chat must open something');
      expect(
        Uri.parse(launched.single).queryParameters.values.join(' '),
        contains(_firstPara),
        reason: 'the words the reader selected must reach the chat query',
      );

      await selectVisibleCard(tester, withMenu: true);
      await tester.tap(find.text('Search the web'));
      await tester.pumpAndSettle();
      expect(launched, hasLength(2),
          reason: 'Search the web must open something too');
      final search = Uri.parse(launched.last);
      expect(search.host, 'www.google.com');
      expect(search.queryParameters['q'], contains(_firstPara),
          reason: 'the words the reader selected must reach the search');
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
