// Tap-to-define popover tests (operator-approved rec #9, 2026-07-23):
//   * a known TERM in a culinary host card is tappable and opens the
//     definition sheet with the VERBATIM glossary body;
//   * 'Open in manual' deep-links to the term's own glossary card;
//   * first-occurrence-per-card linking (a repeated term links once);
//   * search-highlighted spans show highlights, never popover styling;
//   * no links in TERM manuals or non-culinary manuals (handbook);
//   * pure registry guards: >= 4 letters, variants, longest-first.
//
// All widget tests at a 390x844 phone viewport with explicit pumps;
// takeException() asserted null.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_term_links.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_term_definition_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Any rendered term link (key prefix match).
final Finder _anyTermLink = find.byWidgetPredicate((w) =>
    w.key is ValueKey<String> &&
    (w.key! as ValueKey<String>).value.startsWith('barrio_term_link_'));

/// Fixture card body with the same term twice.
const String _twiceBody =
    'Our kitchen loves ceviche in the summer. A good ceviche starts '
    'with the freshest fish available that day.';

/// A doc with one explainer card, under any [id] (the term-link host
/// gate is the doc id, so fixtures can stand in for real manuals).
BarrioTrainingDoc _docWithId(String id) => BarrioTrainingDoc(
      id: id,
      title: 'Fixture Manual $id',
      sourcePath: 'test://fixture',
      chapters: const [
        HandbookChapter(
          id: 'tp_ch1',
          title: 'Only Section',
          subtitle: 'fixture section',
          iconCodePoint: 0xe533,
          units: [
            HandbookUnit(
              id: 'tp_c1_u1',
              type: HandbookUnitType.explainer,
              title: 'Fixture Card',
              body: _twiceBody,
            ),
          ],
        ),
      ],
    );

void main() {
  const phoneSize = Size(390, 844);

  Future<void> pumpDoc(
    WidgetTester tester,
    BarrioTrainingDoc doc, {
    String? highlightQuery,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: TrainingDocScreen(doc: doc, highlightQuery: highlightQuery),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  /// The CEVICHE glossary card and its content coordinates.
  (HandbookUnit, int, int) cevicheCard() {
    final dishes = kBarrioTrainingDocs['training_latin_dishes']!;
    for (var c = 0; c < dishes.chapters.length; c++) {
      final units = dishes.chapters[c].units;
      for (var u = 0; u < units.length; u++) {
        if (units[u].title == 'CEVICHE') return (units[u], c, u);
      }
    }
    fail('CEVICHE card not found in the dishes glossary');
  }

  group('real menu manual', () {
    testWidgets('a known term is tappable, opens the sheet with the '
        'verbatim definition, and Open in manual deep-links to the '
        'term card', (tester) async {
      final cevicheUnit = cevicheCard().$1;
      final menu = kBarrioTrainingDocs['training_menu_concept']!;
      await pumpDoc(tester, menu);

      // The Ceviches card (card 0) mentions ceviche twice: exactly ONE
      // link renders (first occurrence per card).
      final link = find.byKey(const ValueKey<String>(
          'barrio_term_link_training_menu_concept_c0_u0_ceviche'));
      expect(link, findsOneWidget,
          reason: 'the first ceviche occurrence links, the second not');

      await tester.tap(link);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(BarrioTermDefinitionSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BarrioTermDefinitionSheet),
          matching: find.text('CEVICHE'),
        ),
        findsOneWidget,
        reason: 'the sheet shows the term title',
      );
      expect(
        find.descendant(
          of: find.byType(BarrioTermDefinitionSheet),
          matching: find.text(cevicheUnit.body),
        ),
        findsOneWidget,
        reason: 'the definition body is VERBATIM, word for word',
      );

      await tester.tap(find.text('Open in manual'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.byType(BarrioTermDefinitionSheet), findsNothing);
      expect(find.byKey(ValueKey(cevicheUnit.id)), findsOneWidget,
          reason: 'Open in manual lands on the exact glossary card');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('longest match wins where terms overlap and every other '
        'card term links its first occurrence', (tester) async {
      final menu = kBarrioTrainingDocs['training_menu_concept']!;
      await pumpDoc(tester, menu);

      // Card 0 also carries salsa, aji amarillo, and aguachile.
      for (final term in ['salsa', 'aji amarillo', 'aguachile']) {
        expect(
          find.byKey(ValueKey<String>(
              'barrio_term_link_training_menu_concept_c0_u0_$term')),
          findsOneWidget,
          reason: '$term links exactly once on the Ceviches card',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('fixture hosts', () {
    testWidgets('a repeated term links only its first occurrence in a '
        'coffee card', (tester) async {
      await pumpDoc(tester, _docWithId('training_coffee'));

      expect(
        find.byKey(
            const ValueKey<String>('barrio_term_link_tp_c1_u1_ceviche')),
        findsOneWidget,
      );
      expect(_anyTermLink, findsOneWidget,
          reason: 'the second occurrence renders as plain verbatim text');
      expect(tester.takeException(), isNull);
    });

    testWidgets('search-highlighted spans show highlights, not popover '
        'styling', (tester) async {
      await pumpDoc(
        tester,
        _docWithId('training_coffee'),
        highlightQuery: 'ceviche',
      );

      expect(_anyTermLink, findsNothing,
          reason: 'a card opened via search shows highlights on the '
              'matched words, never term-link styling on them');
      expect(tester.takeException(), isNull);
    });

    testWidgets('no term links outside the culinary hosts (handbook id)',
        (tester) async {
      await pumpDoc(tester, _docWithId('company_handbook'));

      expect(_anyTermLink, findsNothing,
          reason: 'the handbook and labor manuals never host links');
      expect(tester.takeException(), isNull);
    });
  });

  group('TERM manuals never link', () {
    testWidgets('the dishes glossary itself renders no term links',
        (tester) async {
      await pumpDoc(tester, kBarrioTrainingDocs['training_latin_dishes']!);

      expect(_anyTermLink, findsNothing,
          reason: 'a TERM manual never links inside itself');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a TERM manual body mentioning another term still '
        'renders no links (glossaries are not hosts)', (tester) async {
      await pumpDoc(
          tester, kBarrioTrainingDocs['training_latin_ingredients']!);

      expect(_anyTermLink, findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('BarrioTermLinks (pure)', () {
    test('registry: ceviche resolves to the dishes glossary card with '
        'its content coordinates', () {
      final (unit, chapter, unitIndex) = cevicheCard();
      final card = BarrioTermLinks.registry()['ceviche'];
      expect(card, isNotNull);
      expect(card!.docId, 'training_latin_dishes');
      expect(card.chapterIndex, chapter);
      expect(card.unitInChapter, unitIndex);
      expect(identical(card.unit, unit), isTrue);
    });

    test('registry guards: every term has at least 4 letters and slash '
        'titles register both variants on one card', () {
      final reg = BarrioTermLinks.registry();
      for (final term in reg.keys) {
        final letters =
            term.codeUnits.where((u) => u >= 0x61 && u <= 0x7A).length;
        expect(letters, greaterThanOrEqualTo(4),
            reason: '"$term" must carry at least 4 letters');
      }
      expect(reg['maize'], isNotNull);
      expect(reg['el maiz'], isNotNull);
      expect(identical(reg['maize']!.unit, reg['el maiz']!.unit), isTrue,
          reason: 'MAIZE/EL MAIZ variants share one glossary card');
    });

    test('matching: whole words only, longest match wins, and '
        'alreadyLinked suppresses repeats', () {
      final linked = <String>{};
      // 'salsa inglesa' contains 'salsa': the longer term wins.
      final overlap = BarrioTermLinks.matchesIn(
        'A dash of salsa inglesa finishes it.',
        alreadyLinked: linked,
      );
      expect(overlap.map((m) => m.foldedTerm), ['salsa inglesa']);

      // 'salsa' was NOT consumed by the drop: it may link later.
      final later = BarrioTermLinks.matchesIn(
        'Now plain salsa on its own.',
        alreadyLinked: linked,
      );
      expect(later.map((m) => m.foldedTerm), ['salsa']);

      // A linked term never links again in the same card.
      final repeat = BarrioTermLinks.matchesIn(
        'More salsa again.',
        alreadyLinked: linked,
      );
      expect(repeat, isEmpty);

      // Substrings inside words never match ('cevicheria' vs ceviche).
      final partial = BarrioTermLinks.matchesIn(
        'The cevicheria was busy.',
        alreadyLinked: <String>{},
      );
      expect(partial, isEmpty);
    });

    test('blocked ranges drop the styled occurrence without consuming '
        'the term', () {
      final linked = <String>{};
      const text = 'ceviche first, then ceviche again.';
      // Block the first occurrence (a search highlight over it).
      final matches = BarrioTermLinks.matchesIn(
        text,
        alreadyLinked: linked,
        blockedRanges: const [
          [0, 7],
        ],
      );
      expect(matches, isEmpty,
          reason: 'only the FIRST occurrence may link; blocked means '
              'no link in this chunk');
      expect(linked, isEmpty,
          reason: 'a blocked occurrence must not consume the term');
    });
  });
}
