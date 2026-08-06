// Kindle-style highlights, Slice D: the review sheet and the marker
// toolbar.
//
// WHAT THESE TESTS GUARD, and how each one could rot into a guard that
// passes while proving nothing:
//
//  1. READING ORDER. The grouping fixture feeds marks in an order that
//     is NOT the answer, and the test asserts that fact first. A build
//     that simply echoed its input would satisfy a lazier test.
//
//  2. WHERE A ROW POINTS. The expected content page comes from a
//     separate three-line walk over the fixture in this file, not from
//     the function under test, so both would have to be wrong the same
//     way to pass.
//
//  3. THE JUMP SURVIVES QUIZ CARDS. The jump fixture borrows a real quiz
//     bank so quick-check cards genuinely land in the deck, and the test
//     asserts a quiz card really does sit at the target's UNCONVERTED
//     page before it taps. Without that assertion the test would pass on
//     a manual with no quiz cards at all, where the conversion is the
//     identity and nothing is being proved.
//
//  4. NOTHING IS BEHIND AN OVERFLOW. Slice B's toolbar silently pushed
//     "Search the web" off a 390dp phone. The toolbar test measures the
//     union of every control's rect at 360dp instead of trusting that
//     they rendered, so a control laid out past the screen edge fails
//     even though it exists in the tree.
//
//  5. THE HEADER'S TITLE BUDGET. The fourth header icon is rationed on
//     measured grounds, so the measurement lives here rather than in a
//     comment.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_highlights_service.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_training_deck.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_highlight_actions_sheet.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_highlight_note_sheet.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_highlights_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

HandbookUnit _unit(String id, String title, String body) => HandbookUnit(
      id: id,
      type: HandbookUnitType.explainer,
      title: title,
      body: body,
    );

HandbookChapter _chapter(String id, String title, List<HandbookUnit> units) =>
    HandbookChapter(
      id: id,
      title: title,
      subtitle: 'fixture section',
      iconCodePoint: 0xe533,
      units: units,
    );

const String _openingTitle = 'Opening The Room';
const String _serviceTitle = 'Service';
const String _closingTitle = 'Closing';

/// Three uneven sections, so a build that assumed a fixed cards-per-
/// section stride would land on the wrong card.
final BarrioTrainingDoc _sheetDoc = BarrioTrainingDoc(
  id: 'fixture_hl_sheet_doc',
  title: 'Sheet Fixture',
  sourcePath: 'test://fixture',
  chapters: <HandbookChapter>[
    _chapter('hs_c1', _openingTitle, <HandbookUnit>[
      _unit('hs_c1_u1', 'Doors', 'Unlock the front door at four.'),
      _unit('hs_c1_u2', 'Lights', 'Bring the dining room lights up slowly.'),
    ]),
    _chapter('hs_c2', _serviceTitle, <HandbookUnit>[
      _unit('hs_c2_u1', 'Greeting', 'Greet a table within thirty seconds.'),
      _unit('hs_c2_u2', 'Water', 'Pour water before you take a drink order.'),
      _unit('hs_c2_u3', 'Checks', 'Drop the check once plates are cleared.'),
    ]),
    _chapter('hs_c3', _closingTitle, <HandbookUnit>[
      _unit('hs_c3_u1', 'Sweep', 'Sweep under every banquette.'),
    ]),
  ],
);

/// One mark on [unitId] covering [text]. Offsets are left at the front of
/// the chunk on purpose: the resolver re-anchors by the stored words, and
/// that is the path a real regenerated body takes.
BarrioHighlight _mark(
  String id,
  String unitId,
  String text, {
  String color = 'gold',
  String note = '',
}) =>
    BarrioHighlight(
      id: id,
      unitId: unitId,
      color: color,
      note: note,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1722400000000),
      segments: <BarrioHighlightSegment>[
        BarrioHighlightSegment(chunk: 0, start: 0, end: text.length, text: text),
      ],
    );

/// The page of [unitId] in the pre-quiz content flatten, walked here so
/// the expectation never borrows the arithmetic under test.
int _contentPageOf(BarrioTrainingDoc doc, String unitId) {
  var page = 0;
  for (final chapter in doc.chapters) {
    for (final unit in chapter.units) {
      if (unit.id == unitId) return page;
      page++;
    }
  }
  return -1;
}

/// Every listed mark id, group by group, in the order the sheet lists it.
List<String> _listedIds(List<TrainingHighlightGroup> groups) => <String>[
      for (final group in groups)
        for (final entry in group.entries) entry.highlight.id,
    ];

TrainingHighlightEntry _entryFor(
  List<TrainingHighlightGroup> groups,
  String id,
) =>
    groups
        .expand((g) => g.entries)
        .firstWhere((e) => e.highlight.id == id);

void main() {
  // -------------------------------------------------------------------------
  // Grouping: the pure builder
  // -------------------------------------------------------------------------

  group('marks are grouped by section in reading order', () {
    // Stored order (oldest first) is deliberately close to backwards.
    final storedOrder = <BarrioHighlight>[
      _mark('h_closing', 'hs_c3_u1', 'every banquette'),
      _mark('h_lights', 'hs_c1_u2', 'lights up slowly'),
      _mark('h_water', 'hs_c2_u2', 'Pour water'),
      _mark('h_drink', 'hs_c2_u2', 'a drink order'),
      _mark('h_doors', 'hs_c1_u1', 'the front door'),
    ];

    test('sections come back in deck order, not in the order marked', () {
      final groups = buildTrainingHighlightGroups(
        doc: _sheetDoc,
        highlights: storedOrder,
      );

      expect(
        groups.map((g) => g.title).toList(),
        <String>[_openingTitle, _serviceTitle, _closingTitle],
        reason: 'sections list in the order the manual reads them',
      );
      // Only sections carrying a mark appear, and every mark is listed.
      expect(groups.every((g) => g.entries.isNotEmpty), isTrue);
      expect(_listedIds(groups), hasLength(storedOrder.length));

      const expectedOrder = <String>[
        'h_doors', // section 1, card 1
        'h_lights', // section 1, card 2
        'h_water', // section 2, card 2, marked first
        'h_drink', // section 2, card 2, marked second
        'h_closing', // section 3, card 1
      ];
      expect(_listedIds(groups), expectedOrder);
      // The guard bites only because the answer is not the input: a
      // build that echoed its argument would satisfy the length and
      // membership checks above but not this one.
      expect(
        expectedOrder,
        isNot(storedOrder.map((h) => h.id).toList()),
        reason: 'the fixture must not already be in the answer order',
      );
    });

    test('two marks on the same card keep the order they were made', () {
      final groups = buildTrainingHighlightGroups(
        doc: _sheetDoc,
        highlights: storedOrder,
      );
      final service = groups.firstWhere((g) => g.title == _serviceTitle);
      expect(
        service.entries.map((e) => e.highlight.id).toList(),
        <String>['h_water', 'h_drink'],
      );
      // Both point at the same card, because they are on the same card.
      expect(service.entries.first.contentPage,
          service.entries.last.contentPage);
    });

    test('each row points at the card its mark actually lives on', () {
      final groups = buildTrainingHighlightGroups(
        doc: _sheetDoc,
        highlights: storedOrder,
      );
      const expectedUnits = <String, String>{
        'h_doors': 'hs_c1_u1',
        'h_lights': 'hs_c1_u2',
        'h_water': 'hs_c2_u2',
        'h_drink': 'hs_c2_u2',
        'h_closing': 'hs_c3_u1',
      };
      expectedUnits.forEach((id, unitId) {
        final entry = _entryFor(groups, id);
        expect(entry.contentPage, _contentPageOf(_sheetDoc, unitId),
            reason: '$id must point at $unitId');
        expect(entry.isFromEarlierVersion, isFalse);
      });
      // The reader-facing position label counts from one.
      expect(_entryFor(groups, 'h_water').positionLabel,
          'SECTION 2 · CARD 2');
      expect(_entryFor(groups, 'h_closing').positionLabel,
          'SECTION 3 · CARD 1');
      // Sections are uneven on purpose, so the labels cannot all be
      // right by accident of a fixed stride.
      expect(_sheetDoc.chapters.map((c) => c.units.length).toSet(),
          hasLength(greaterThan(1)));
    });

    test('an empty mark list produces no groups at all', () {
      expect(
        buildTrainingHighlightGroups(
            doc: _sheetDoc, highlights: const <BarrioHighlight>[]),
        isEmpty,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Orphans
  // -------------------------------------------------------------------------

  group('marks this build cannot place are listed, never hidden', () {
    // Three marks, all naming section 2 card 1 or a card that is gone.
    final marks = <BarrioHighlight>[
      // The card itself is no longer in the manual.
      _mark('h_card_gone', 'hs_c9_u9', 'a card that was cut'),
      // The card is here; these words are not.
      _mark('h_words_gone', 'hs_c2_u1', 'words from an older draft',
          note: 'still worth keeping'),
      // Same card, words that are still on it.
      _mark('h_still_here', 'hs_c2_u1', 'thirty seconds'),
    ];

    test('they land in a final group with the earlier-version wording', () {
      final groups =
          buildTrainingHighlightGroups(doc: _sheetDoc, highlights: marks);

      expect(groups.last.title, kBarrioEarlierVersionGroupTitle);
      expect(groups.last.isFromEarlierVersion, isTrue);
      expect(
        groups.last.entries.map((e) => e.highlight.id).toList(),
        <String>['h_card_gone', 'h_words_gone'],
        reason: 'both kinds of unplaceable mark, in stored order',
      );
      for (final entry in groups.last.entries) {
        expect(entry.contentPage, isNull, reason: 'there is nowhere to jump');
        expect(entry.positionLabel, isNull);
        expect(entry.isFromEarlierVersion, isTrue);
      }
      // The reader's own words and note survive: the point of keeping it.
      expect(_entryFor(groups, 'h_words_gone').highlight.note,
          'still worth keeping');
    });

    test('a placeable mark on the SAME card still lists under its section',
        () {
      final groups =
          buildTrainingHighlightGroups(doc: _sheetDoc, highlights: marks);
      final service = groups.firstWhere((g) => g.title == _serviceTitle);
      expect(
        service.entries.map((e) => e.highlight.id).toList(),
        <String>['h_still_here'],
        reason: 'orphaning is decided per mark, not per card',
      );
      expect(service.entries.single.contentPage,
          _contentPageOf(_sheetDoc, 'hs_c2_u1'));
      expect(groups.where((g) => g.isFromEarlierVersion), hasLength(1));
    });

    test('a manual with only unplaceable marks lists them and nothing else',
        () {
      final groups = buildTrainingHighlightGroups(
        doc: _sheetDoc,
        highlights: <BarrioHighlight>[marks.first],
      );
      expect(groups, hasLength(1));
      expect(groups.single.title, kBarrioEarlierVersionGroupTitle);
    });
  });

  // -------------------------------------------------------------------------
  // The sheet itself
  // -------------------------------------------------------------------------

  group('the sheet shows what a row promises', () {
    final marks = <BarrioHighlight>[
      _mark('h_noted', 'hs_c2_u2', 'Pour water',
          color: 'plum', note: 'Ask about allergies at the same time.'),
      _mark('h_plain', 'hs_c3_u1', 'every banquette'),
      _mark('h_gone', 'hs_c9_u9', 'a card that was cut', note: 'keep this'),
    ];

    late List<int> tappedPages;
    late List<String> managedIds;

    Future<void> pumpSheet(WidgetTester tester) async {
      tappedPages = <int>[];
      managedIds = <String>[];
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrainingDocHighlightsSheet(
              doc: _sheetDoc,
              accent: Colors.teal,
              highlights:
                  ValueNotifier<List<BarrioHighlight>>(marks),
              onEntryTap: tappedPages.add,
              onManageTap: managedIds.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a row carries the words, the note and the position',
        (tester) async {
      await pumpSheet(tester);

      expect(find.text('Your highlights'), findsOneWidget);
      expect(find.text('3 highlights'), findsOneWidget);
      expect(find.text('Pour water'), findsOneWidget);
      expect(find.text('Ask about allergies at the same time.'),
          findsOneWidget);
      expect(
        find.text('SECTION 2 · CARD 2'),
        findsOneWidget,
        reason: 'the honest position of the card the mark lives on',
      );
      // Section headings, uppercased for the house mono label idiom.
      expect(find.text(_serviceTitle.toUpperCase()), findsOneWidget);
      expect(find.text(_closingTitle.toUpperCase()), findsOneWidget);
      expect(find.text(kBarrioEarlierVersionGroupTitle.toUpperCase()),
          findsOneWidget);
      // A section with no marks is not claimed to have any.
      expect(find.text(_openingTitle.toUpperCase()), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a row asks for its card, by content page',
        (tester) async {
      await pumpSheet(tester);

      await tester.tap(find.byKey(const ValueKey<String>(
          'barrio_highlight_row_h_noted')));
      await tester.pump();
      expect(tappedPages, <int>[_contentPageOf(_sheetDoc, 'hs_c2_u2')]);

      await tester.tap(find.byKey(const ValueKey<String>(
          'barrio_highlight_row_h_plain')));
      await tester.pump();
      expect(tappedPages.last, _contentPageOf(_sheetDoc, 'hs_c3_u1'));
      // Two different cards, so the second tap proves the page is read
      // off the row and not returned as a constant.
      expect(tappedPages.first, isNot(tappedPages.last));
    });

    testWidgets('an earlier-version row offers no jump but still manages',
        (tester) async {
      await pumpSheet(tester);

      // Its words and its note are both on screen.
      expect(find.text('a card that was cut'), findsOneWidget);
      expect(find.text('keep this'), findsOneWidget);
      // No position label anywhere in its group.
      expect(find.text('SECTION 1 · CARD 1'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey<String>('barrio_highlight_row_h_gone')),
      );
      await tester.pump();
      expect(tappedPages, isEmpty, reason: 'there is nowhere to jump to');

      // It can still be managed: an orphan is the reader's own note.
      await tester.tap(
        find.byKey(const ValueKey<String>('barrio_highlight_manage_h_gone')),
      );
      await tester.pump();
      expect(managedIds, <String>['h_gone']);
    });

    testWidgets('the trailing icon manages the row without jumping',
        (tester) async {
      await pumpSheet(tester);
      await tester.tap(find.byKey(
          const ValueKey<String>('barrio_highlight_manage_h_noted')));
      await tester.pump();
      expect(managedIds, <String>['h_noted']);
      expect(tappedPages, isEmpty,
          reason: 'the manage icon is not the row');
    });
  });

  // -------------------------------------------------------------------------
  // The reader end to end
  // -------------------------------------------------------------------------

  group('the reader', () {
    /// A manual that really does grow quick-check cards: its id and its
    /// chapter ids are a registered quiz bank's, so [buildTrainingDeck]
    /// appends that bank's questions after each section's content.
    final quizDoc = BarrioTrainingDoc(
      id: 'training_coffee',
      title: 'Coffee Fixture',
      sourcePath: 'test://fixture',
      chapters: <HandbookChapter>[
        _chapter('training_coffee_c0', 'Beans', <HandbookUnit>[
          _unit('qz_c0_u0', 'Origin', 'Beans arrive green and unroasted.'),
          _unit('qz_c0_u1', 'Roast', 'A darker roast tastes of the roast.'),
        ]),
        _chapter('training_coffee_c1', 'Pulling A Shot', <HandbookUnit>[
          _unit('qz_c1_u0', 'Dose', 'Weigh every dose before you tamp it.'),
          _unit('qz_c1_u1', 'Time', 'Watch the clock as the shot runs.'),
        ]),
      ],
    );

    /// A TERM glossary carrying the corpus's longest title, so the header
    /// budget is measured against the worst real case.
    final termDoc = BarrioTrainingDoc(
      id: 'training_latin_ingredients',
      title: 'Latin American Words To Know: Ingredients',
      sourcePath: 'test://fixture',
      chapters: <HandbookChapter>[
        _chapter('li_c0', 'A To C', <HandbookUnit>[
          _unit('li_c0_u0', 'Achiote', 'Achiote is a red seed used to colour.'),
          _unit('li_c0_u1', 'Cotija', 'Cotija is a salty crumbling cheese.'),
        ]),
      ],
    );

    void seed(BarrioTrainingDoc doc, List<BarrioHighlight> marks) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        BarrioHighlightsService.keyFor(doc.id):
            json.encode(<Object?>[for (final m in marks) m.toJson()]),
      });
    }

    Future<void> pumpReader(
      WidgetTester tester,
      BarrioTrainingDoc doc, {
      Size size = const Size(390, 844),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: TrainingDocScreen(doc: doc)),
      );
      await tester.pumpAndSettle();
    }

    setUp(() {
      barrioClearBodySpanCache();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    testWidgets('an unmarked manual offers no "Your highlights" icon',
        (tester) async {
      await pumpReader(tester, _sheetDoc);
      expect(find.byTooltip('Your highlights'), findsNothing,
          reason: 'no door to an empty room');
      // The other header actions are untouched by the rationing, so this
      // is not passing because the whole bar failed to render.
      expect(find.byTooltip('Search this manual'), findsOneWidget);
      expect(find.byTooltip('Search the web'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the header icon appears once the manual holds a mark, and '
        'opens the list', (tester) async {
      seed(_sheetDoc, <BarrioHighlight>[
        _mark('h_header', 'hs_c2_u2', 'Pour water'),
      ]);
      await pumpReader(tester, _sheetDoc);
      expect(find.byTooltip('Your highlights'), findsOneWidget);

      await tester.tap(find.byTooltip('Your highlights'));
      await tester.pumpAndSettle();
      expect(find.byType(TrainingDocHighlightsSheet), findsOneWidget);
      expect(find.text('1 highlight'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tapped row lands on the right card with quiz cards in the '
        'deck', (tester) async {
      // The deck is read here, independently of the sheet, so the
      // expectation below is not the conversion under test.
      final deck = buildTrainingDeck(quizDoc);
      final contentPage = _contentPageOf(quizDoc, 'qz_c1_u0');
      final deckPage =
          deck.entries.indexWhere((e) => e.unit?.id == 'qz_c1_u0');
      expect(deck.entries.any((e) => e.isQuiz), isTrue,
          reason: 'the fixture must really carry quick-check cards, or the '
              'conversion this test exists for is the identity');
      expect(deck.entries[contentPage].isQuiz, isTrue,
          reason: 'a quiz card must sit at the UNCONVERTED page, so a '
              'missing conversion lands somewhere visibly wrong');
      expect(deckPage, isNot(contentPage));

      seed(quizDoc, <BarrioHighlight>[
        _mark('h_jump', 'qz_c1_u0', 'Weigh every dose'),
      ]);
      await pumpReader(tester, quizDoc);
      expect(find.text('1 of ${deck.length}'), findsOneWidget,
          reason: 'the reader opens on the first card');

      await tester.tap(find.byTooltip('Your highlights'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('barrio_highlight_row_h_jump')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TrainingDocHighlightsSheet), findsNothing,
          reason: 'a tapped row closes the sheet');
      expect(find.text('${deckPage + 1} of ${deck.length}'), findsOneWidget,
          reason: 'the deck landed on the marked card, past the quiz cards');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a recolour from the list reaches the list underneath',
        (tester) async {
      seed(_sheetDoc, <BarrioHighlight>[
        _mark('h_live', 'hs_c2_u2', 'Pour water'),
      ]);
      await pumpReader(tester, _sheetDoc);
      await tester.tap(find.byTooltip('Your highlights'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(
          const ValueKey<String>('barrio_highlight_manage_h_live')));
      await tester.pumpAndSettle();
      expect(find.byType(BarrioHighlightActionsSheet), findsOneWidget);
      expect(find.byType(TrainingDocHighlightsSheet), findsOneWidget,
          reason: 'the manage sheet opens ON TOP of the list');

      await tester.tap(
        find.byKey(const ValueKey<String>('barrio_highlight_color_steel')),
      );
      await tester.pumpAndSettle();

      // The store is the independent witness: the screen's own state
      // could be right while nothing was written, or the other way.
      final prefs = await SharedPreferences.getInstance();
      final stored = (json.decode(
        prefs.getString(BarrioHighlightsService.keyFor(_sheetDoc.id))!,
      ) as List<Object?>)
          .map(BarrioHighlight.decode)
          .toList();
      expect(stored.single!.color, 'steel');
      expect(stored.single!.color, isNot('gold'),
          reason: 'the fixture pen must differ from the one picked, or the '
              'assertion above would pass with the pick ignored');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a note written from the list shows up in the list, live',
        (tester) async {
      const note = 'Ask about allergies at the same time.';
      seed(_sheetDoc, <BarrioHighlight>[
        _mark('h_note', 'hs_c2_u2', 'Pour water'),
      ]);
      await pumpReader(tester, _sheetDoc);
      await tester.tap(find.byTooltip('Your highlights'));
      await tester.pumpAndSettle();
      expect(find.text(note), findsNothing, reason: 'nothing written yet');

      await tester.tap(find.byKey(
          const ValueKey<String>('barrio_highlight_manage_h_note')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          const ValueKey<String>('barrio_highlight_note_action')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('barrio_highlight_note_field')),
        note,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('barrio_highlight_note_save')),
      );
      await tester.pumpAndSettle();

      // The list is the surface that has to have noticed: it is a route
      // BELOW the two sheets that just closed, so a `setState` on the
      // reading screen alone would never have reached it.
      expect(find.byType(TrainingDocHighlightsSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TrainingDocHighlightsSheet),
          matching: find.text(note),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('removing from the list closes it, so the Undo is reachable',
        (tester) async {
      seed(_sheetDoc, <BarrioHighlight>[
        _mark('h_bye', 'hs_c2_u2', 'Pour water'),
      ]);
      await pumpReader(tester, _sheetDoc);
      await tester.tap(find.byTooltip('Your highlights'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
          const ValueKey<String>('barrio_highlight_manage_h_bye')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(
          const ValueKey<String>('barrio_highlight_remove_action')));
      await tester.pumpAndSettle();

      expect(find.byType(BarrioHighlightActionsSheet), findsNothing);
      expect(find.byType(TrainingDocHighlightsSheet), findsNothing,
          reason: 'a SnackBar sits UNDER a modal sheet: an Undo offered '
              'with the list still open could not be taken');
      expect(find.text('Highlight removed.'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'Undo').hitTestable(),
          findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(BarrioHighlightsService.keyFor(_sheetDoc.id)),
          contains('h_bye'),
          reason: 'Undo puts the very same record back');
      expect(tester.takeException(), isNull);
    });

    // -----------------------------------------------------------------------
    // The marker toolbar
    // -----------------------------------------------------------------------

    /// Floats the reader's own selection menu with both paragraphs of the
    /// open card selected. A widget test cannot long-press and drag across
    /// a scrollable (it trips a framework assertion in
    /// `_ScrollableSelectionContainerDelegate` with or without this
    /// feature), so this uses the same public entry point the framework
    /// itself uses and lands in the same place, per Slice B.
    Future<void> floatMenu(WidgetTester tester) async {
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll(SelectionChangedCause.toolbar);
      await tester.pumpAndSettle();
    }

    testWidgets('every marker and every action is reachable at 360dp, the '
        'narrowest phone', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpReader(tester, _sheetDoc, size: const Size(360, 780));
        await floatMenu(tester);

        final controls = <String, Finder>{
          for (final token in kBarrioHighlightColorTokens)
            '$token marker':
                find.byKey(ValueKey<String>('barrio_marker_dot_$token')),
          for (final label in const <String>[
            'Add note',
            'Highlight',
            'Ask chat',
            'Search the web',
          ])
            label: find.ancestor(
              of: find.text(label),
              matching: find.byType(TextButton),
            ),
        };

        Rect? bounds;
        final tops = <String, double>{};
        controls.forEach((name, finder) {
          expect(finder.hitTestable(), findsOneWidget,
              reason: '"$name" must be on the toolbar and tappable, not '
                  'behind an overflow and not off the screen');
          final rect = tester.getRect(finder);
          tops[name] = rect.top;
          bounds = bounds == null ? rect : bounds!.expandToInclude(rect);
        });

        // Laid out inside the 360dp screen, within the 8px-a-side screen
        // padding Flutter's own selection toolbar keeps.
        expect(bounds!.left, greaterThanOrEqualTo(0.0));
        expect(bounds!.right, lessThanOrEqualTo(360.0));
        expect(bounds!.width, lessThanOrEqualTo(344.0),
            reason: 'measured toolbar width was ${bounds!.width}');

        // Two rows, and the right controls on each: the four pens plus
        // "Add note" above, Slice B's three actions below.
        final penTop = tops['gold marker']!;
        for (final token in kBarrioHighlightColorTokens) {
          expect(tops['$token marker'], penTop);
        }
        expect(tops['Add note'], lessThan(tops['Highlight']!));
        expect(tops['Ask chat'], tops['Highlight']);
        expect(tops['Search the web'], tops['Highlight']);
        expect(tops['Highlight']! > penTop, isTrue,
            reason: 'the actions row sits under the pens row');

        // Nothing was hidden to make room.
        expect(find.byIcon(Icons.more_vert), findsNothing);

        // The glass pill hugs its rows instead of spanning the screen.
        // A bare divider or any other childless full-width widget in the
        // column would silently stretch it to the full 344, and nothing
        // else in this test would notice.
        final surface = tester.getSize(find
            .ancestor(
              of: find.byKey(
                  const ValueKey<String>('barrio_marker_dot_gold')),
              matching: find.byWidgetPredicate((w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration! as BoxDecoration).color ==
                      BarrioColors.glassFill),
            )
            .first);
        // Two pixels wider than its content: the surface's own 1px
        // border, each side.
        expect(surface.width, closeTo(bounds!.width + 2, 0.5),
            reason: 'measured surface ${surface.width} against content '
                '${bounds!.width}');
        expect(surface.width, lessThan(344.0));
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a marker dot marks the selection in that colour and keeps '
        'it as the reader\'s pen', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpReader(tester, _sheetDoc);
        expect(find.byTooltip('Your highlights'), findsNothing);
        await floatMenu(tester);
        await tester.tap(
          find.byKey(const ValueKey<String>('barrio_marker_dot_plum')),
        );
        await tester.pumpAndSettle();

        // The header opens up the moment the manual has something to
        // show, without waiting for the manual to be reopened.
        expect(find.byTooltip('Your highlights'), findsOneWidget);

        final prefs = await SharedPreferences.getInstance();
        final raw =
            prefs.getString(BarrioHighlightsService.keyFor(_sheetDoc.id));
        expect(raw, isNotNull, reason: 'the mark must reach the store');
        final stored = BarrioHighlight.decode(
          (json.decode(raw!) as List<Object?>).single,
        )!;
        expect(stored.color, 'plum',
            reason: 'the pen that was tapped, not the default');
        expect(stored.color, isNot(kBarrioHighlightDefaultColor),
            reason: 'the fixture pen must differ from the default, or the '
                'assertion above would pass with the colour ignored');
        expect(await BarrioHighlightsService.getLastColor(), 'plum',
            reason: 'reaching for a pen is choosing it');
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('"Add note" marks the selection and opens the note editor '
        'on it', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpReader(tester, _sheetDoc);
        await floatMenu(tester);
        await tester.tap(find.text('Add note'));
        await tester.pumpAndSettle();

        expect(find.byType(BarrioHighlightNoteSheet), findsOneWidget,
            reason: 'the reader who reached for a note wanted to write');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(BarrioHighlightsService.keyFor(_sheetDoc.id)),
            isNotNull,
            reason: 'and the passage is marked, not just noted');
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // -----------------------------------------------------------------------
    // The header's title budget
    // -----------------------------------------------------------------------

    testWidgets('four header icons fit a TERM manual at 360dp', (tester) async {
      seed(termDoc, <BarrioHighlight>[
        _mark('h_term', 'li_c0_u0', 'a red seed'),
      ]);
      await pumpReader(tester, termDoc, size: const Size(360, 780));

      for (final tooltip in const <String>[
        'Search this manual',
        'Search the web',
        'Jump to a term',
        'Your highlights',
      ]) {
        expect(find.byTooltip(tooltip).hitTestable(), findsOneWidget,
            reason: '"$tooltip" must stay on the bar');
      }
      // Four buttons, all inside the bar, none overlapping the next.
      final rects = <Rect>[
        for (final tooltip in const <String>[
          'Search this manual',
          'Search the web',
          'Jump to a term',
          'Your highlights',
        ])
          tester.getRect(find.byTooltip(tooltip)),
      ];
      for (var i = 1; i < rects.length; i++) {
        expect(rects[i].left, greaterThanOrEqualTo(rects[i - 1].right),
            reason: 'header buttons must not overlap');
      }
      expect(rects.last.right, lessThanOrEqualTo(360.0));
      for (final rect in rects) {
        expect(rect.width, greaterThanOrEqualTo(48.0),
            reason: 'the Material tap-target floor is not traded for room');
      }
      // THE TITLE BUDGET, MEASURED. On a 360dp phone the bar leaves the
      // manual title, in order: 160px at two icons, 112px at three
      // (today's TERM header), 64px at four (this slice, and only once
      // the reader has marked something in a glossary), 16px at five.
      // Sixteen is nonsense, which is why a fifth icon is not a thing a
      // future slice may quietly add: it has to move something off the
      // bar first (the A-Z index onto the hero eyebrow row, beside the
      // flashcards chip, is the proposed home).
      //
      // 64 is tight and honestly reported rather than dressed up. A TERM
      // title is the longest in the corpus and already truncated at
      // three icons: "Latin American Words To Know: Ingredients" does not
      // fit 112px either, and the two Latin glossaries are already
      // indistinguishable by their header at 360dp. This guard holds the
      // line where it still means something.
      final title = tester.getRect(find.text(termDoc.title));
      expect(title.width, greaterThan(60.0),
          reason: 'measured title width was ${title.width}');
      expect(title.right, lessThanOrEqualTo(rects.first.left),
          reason: 'the title must not run under the buttons');
      expect(tester.takeException(), isNull,
          reason: 'no RenderFlex overflow in the app bar');
    });
  });
}
