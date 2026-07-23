// Widget + pure tests for the training reader's two header navigation
// features (2026-07-23 operator-approved):
//   * rec #7: in-manual search sheet (exact-substring, scoped to the
//     open doc, honest empty state, jump in place with highlighting),
//   * rec #6: A-Z term index sheet on exactly the three TERM manuals,
//     with "(cont.)" runs listed once under the base title.
//
// All widget tests run at a 390x844 phone viewport and assert
// takeException() is null (overflow guard: the header and sheets must
// not get denser). Explicit pumps only, mirroring the other Barrio
// suites.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_reading_progress_service.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_training_deck.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/learning_carousel.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_index_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kSearchLabel = 'Search this manual';
const _kIndexLabel = 'Jump to a term';

const _kGlossaryIds = <String>[
  'training_latin_ingredients',
  'training_latin_dishes',
  'training_general_words',
];

List<HandbookUnit> _flatUnitsOf(BarrioTrainingDoc doc) =>
    [for (final c in doc.chapters) ...c.units];

int _flatPageOf(BarrioTrainingDoc doc, int chapterIndex, int unitIndex) {
  var page = 0;
  for (var i = 0; i < chapterIndex; i++) {
    page += doc.chapters[i].units.length;
  }
  return page + unitIndex;
}

void main() {
  const phoneSize = Size(390, 844);

  Future<void> pumpDoc(WidgetTester tester, String docId) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: TrainingDocScreen(doc: kBarrioTrainingDocs[docId]!)),
    );
    // Restore setState frame, then the hero fade + carousel entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  Future<void> openSheet(WidgetTester tester, String tooltip) async {
    await tester.tap(find.byTooltip(tooltip));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  group('in-manual search (rec #7)', () {
    testWidgets('the header search icon opens the scoped search sheet',
        (tester) async {
      await pumpDoc(tester, 'training_tequila');

      expect(find.byTooltip(_kSearchLabel), findsOneWidget,
          reason: 'every manual carries the quiet header search icon');

      await openSheet(tester, _kSearchLabel);
      expect(find.byType(TextField), findsOneWidget,
          reason: 'the sheet opens with its own search field');
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing (debounced) surfaces in-doc matches; a term that '
        'lives only in another manual gets the honest empty state',
        (tester) async {
      // Service preconditions keep this test self-validating.
      final inDoc = BarrioTrainingSearch.search(
        'mezcal',
        isDestinationAllowed: (id) => id == 'training_tequila',
      );
      expect(inDoc, isNotEmpty,
          reason: 'sanity: mezcal must match inside Tequila Training');
      expect(
        BarrioTrainingSearch.search(
          'empanadas',
          isDestinationAllowed: (id) => id == 'training_tequila',
        ),
        isEmpty,
        reason: 'sanity: empanadas must NOT match inside Tequila Training',
      );
      expect(BarrioTrainingSearch.search('empanadas'), isNotEmpty,
          reason: 'sanity: empanadas exists in another manual, so the '
              'empty state below proves the doc scoping');

      await pumpDoc(tester, 'training_tequila');
      await openSheet(tester, _kSearchLabel);

      await tester.enterText(find.byType(TextField), 'mezcal');
      await tester.pump(const Duration(milliseconds: 100));
      final resultsList =
          find.byKey(const ValueKey<String>('training_doc_search_results'));
      expect(resultsList, findsNothing,
          reason: 'results wait for the ~200ms debounce window');
      await tester.pump(const Duration(milliseconds: 150));
      expect(resultsList, findsOneWidget);
      expect(
        find.descendant(
            of: resultsList, matching: find.text(inDoc.first.unitTitle)),
        findsWidgets,
        reason: 'the top in-doc hit renders its card title',
      );

      await tester.enterText(find.byType(TextField), 'empanadas');
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.text("No matches for 'empanadas' in this manual."),
        findsOneWidget,
        reason: 'cross-manual terms get the honest in-manual empty state',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a result jumps the deck in place to the exact '
        'card, highlights the term, and records the read mark',
        (tester) async {
      final doc = kBarrioTrainingDocs['training_tequila']!;
      final flatUnits = _flatUnitsOf(doc);
      final hit = BarrioTrainingSearch.search(
        'mezcal',
        isDestinationAllowed: (id) => id == 'training_tequila',
      ).first;
      final page = _flatPageOf(doc, hit.chapterIndex, hit.unitIndex);
      expect(page, greaterThan(0),
          reason: 'sanity: the jump target must not be the landing card');

      await pumpDoc(tester, 'training_tequila');
      final stateBefore =
          tester.state<LearningCarouselState>(find.byType(LearningCarousel));

      await openSheet(tester, _kSearchLabel);
      await tester.enterText(find.byType(TextField), 'mezcal');
      await tester.pump(const Duration(milliseconds: 250));

      final resultsList =
          find.byKey(const ValueKey<String>('training_doc_search_results'));
      await tester.tap(
        find
            .descendant(of: resultsList, matching: find.text(hit.unitTitle))
            .first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('${page + 1} of ${flatUnits.length}'), findsOneWidget,
          reason: 'the deck must land on the exact matched card');
      final stateAfter =
          tester.state<LearningCarouselState>(find.byType(LearningCarousel));
      expect(identical(stateBefore, stateAfter), isTrue,
          reason: 'search jumps move the deck in place, never remount it');

      final card = tester.widget<HandbookLessonCard>(
        find.byKey(ValueKey(flatUnits[page].id)),
      );
      expect(card.highlightTerms, contains('mezcal'),
          reason: 'the query threads into the card highlight rendering');

      // Jumps record read marks exactly like tap-zone turns.
      final position =
          await BarrioReadingProgressService.getPosition('training_tequila');
      expect(position!.chapterIndex, hit.chapterIndex);
      expect(position.unitInChapter, hit.unitIndex);
      expect(
        await BarrioReadingProgressService.getReadUnitIds('training_tequila'),
        contains(flatUnits[page].id),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('dismissing the sheet without a tap leaves the deck where '
        'the reader left it', (tester) async {
      final total = _flatUnitsOf(kBarrioTrainingDocs['training_tequila']!)
          .length;
      await pumpDoc(tester, 'training_tequila');
      expect(find.text('1 of $total'), findsOneWidget);

      await openSheet(tester, _kSearchLabel);
      await tester.enterText(find.byType(TextField), 'mezcal');
      await tester.pump(const Duration(milliseconds: 250));

      // Swipe the sheet down instead of tapping a result.
      await tester.tapAt(const Offset(195, 40)); // barrier above the sheet
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(TextField), findsNothing,
          reason: 'the sheet is gone');
      expect(find.text('1 of $total'), findsOneWidget,
          reason: 'the deck stays exactly where it was');
      expect(tester.takeException(), isNull);
    });
  });

  group('A-Z term index (rec #6)', () {
    testWidgets('the index icon shows on exactly the three TERM manuals '
        'and never on a narrative manual', (tester) async {
      for (final docId in _kGlossaryIds) {
        await pumpDoc(tester, docId);
        expect(find.byTooltip(_kIndexLabel), findsOneWidget,
            reason: '$docId is a TERM glossary and carries the index icon');
        expect(tester.takeException(), isNull);
      }

      await pumpDoc(tester, 'training_tequila');
      expect(find.byTooltip(_kIndexLabel), findsNothing,
          reason: 'narrative manuals show no index icon');
      expect(find.byTooltip(_kSearchLabel), findsOneWidget,
          reason: 'the search icon still shows on narrative manuals');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the index lists a "(cont.)" run once and tapping the '
        'entry jumps in place to the first card of the run',
        (tester) async {
      final doc = kBarrioTrainingDocs['training_latin_dishes']!;
      final flatUnits = _flatUnitsOf(doc);
      // The dishes manual carries chapter-end quick-check quiz cards
      // (rec #4b), so the footer counts the extended deck; entry pages
      // stay in the pre-quiz content flatten and convert stably.
      final deck = buildTrainingDeck(doc);
      final cevichePage = flatUnits.indexWhere((u) => u.title == 'CEVICHE');
      expect(cevichePage, greaterThanOrEqualTo(0));
      expect(
        flatUnits.indexWhere((u) => u.title == 'CEVICHE (cont.)'),
        cevichePage + 1,
        reason: 'sanity: CEVICHE is a split run in the dishes glossary',
      );

      await pumpDoc(tester, 'training_latin_dishes');
      final stateBefore =
          tester.state<LearningCarouselState>(find.byType(LearningCarousel));
      await openSheet(tester, _kIndexLabel);

      final indexList =
          find.byKey(const ValueKey<String>('training_doc_index_list'));
      expect(indexList, findsOneWidget);
      await tester.scrollUntilVisible(
        find.descendant(of: indexList, matching: find.text('CEVICHE')),
        200,
        scrollable: find
            .descendant(of: indexList, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('CEVICHE'), findsOneWidget,
          reason: 'a split run is listed ONCE under its base title');
      expect(find.textContaining('(cont.)'), findsNothing,
          reason: 'continuation cards never appear as their own entries');

      await tester.tap(find.text('CEVICHE'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.text(
          '${deck.deckPageForContentPage(cevichePage) + 1} of ${deck.length}',
        ),
        findsOneWidget,
        reason: 'the jump lands on the FIRST card of the run',
      );
      final stateAfter =
          tester.state<LearningCarouselState>(find.byType(LearningCarousel));
      expect(identical(stateBefore, stateAfter), isTrue,
          reason: 'index jumps move the deck in place, never remount it');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the 92-term glossary index scrolls to its last entry '
        'under letter headers without layout errors', (tester) async {
      final doc = kBarrioTrainingDocs['training_general_words']!;
      final groups = buildTrainingIndexGroups(doc);
      final lastEntry = groups.last.entries.last;

      await pumpDoc(tester, 'training_general_words');
      await openSheet(tester, _kIndexLabel);

      final indexList =
          find.byKey(const ValueKey<String>('training_doc_index_list'));
      expect(find.text('#'), findsOneWidget,
          reason: "86'D and 911 group under a leading # header");

      await tester.scrollUntilVisible(
        find.descendant(of: indexList, matching: find.text(lastEntry.title)),
        300,
        scrollable: find
            .descendant(of: indexList, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.descendant(of: indexList, matching: find.text(lastEntry.title)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('buildTrainingIndexGroups (pure)', () {
    test('every glossary entry is unique, sorted, and never a "(cont.)" '
        'title; totals match the deduplicated deck', () {
      for (final docId in _kGlossaryIds) {
        final doc = kBarrioTrainingDocs[docId]!;
        final flatUnits = _flatUnitsOf(doc);
        final groups = buildTrainingIndexGroups(doc);
        final entries = [for (final g in groups) ...g.entries];

        final expectedBases = <String>{
          for (final u in flatUnits)
            u.title.replaceFirst(RegExp(r'\s*\(cont\.\)\s*$'), '').trim(),
        };
        expect(entries.length, expectedBases.length,
            reason: '$docId: one entry per unique base title');
        expect(entries.map((e) => e.title).toSet(), expectedBases);
        for (final entry in entries) {
          expect(entry.title.endsWith('(cont.)'), isFalse);
          expect(flatUnits[entry.page].title, startsWith(entry.title),
              reason: '$docId: each entry jumps to a card of its own run');
        }

        final folded = [
          for (final e in entries) BarrioTrainingSearch.fold(e.title),
        ];
        expect(folded, orderedEquals([...folded]..sort()),
            reason: '$docId: entries are alphabetical after folding');
      }
    });

    test('digit-led terms group under a leading # header; letter groups '
        'follow in order', () {
      final groups = buildTrainingIndexGroups(
        kBarrioTrainingDocs['training_general_words']!,
      );
      expect(groups.first.letter, '#');
      expect(
        groups.first.entries.map((e) => e.title),
        containsAll(<String>["86'D", '911']),
      );
      final letters = groups.skip(1).map((g) => g.letter).toList();
      expect(letters, orderedEquals([...letters]..sort()),
          reason: 'letter headers are alphabetical');
      expect(letters.toSet().length, letters.length,
          reason: 'one group per letter');
    });

    test('a split run keeps the first card of the run as its jump target',
        () {
      final doc = kBarrioTrainingDocs['training_latin_dishes']!;
      final flatUnits = _flatUnitsOf(doc);
      final entries = [
        for (final g in buildTrainingIndexGroups(doc)) ...g.entries,
      ];
      final ceviche = entries.singleWhere((e) => e.title == 'CEVICHE');
      expect(
        ceviche.page,
        flatUnits.indexWhere((u) => u.title == 'CEVICHE'),
      );
      final empanadas = entries.singleWhere((e) => e.title == 'EMPANADAS');
      expect(
        empanadas.page,
        flatUnits.indexWhere((u) => u.title == 'EMPANADAS'),
      );
    });
  });
}
