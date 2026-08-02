// Tests for the key-term color emphasis (2026-07-28 pilot; rolled out to all
// prose manuals 2026-07-29).
//
// A research-backed, author-CURATED emphasis: a small set of unambiguous
// domain concepts render bold + BarrioColors.tealInk (a bold, vivid
// AA-compliant deep teal on cream, 4.74:1) so the text-heavy reading cards
// become more scannable. The pilot proved the look on "The Three Pillars of
// Hospitality" (`training_three_pillars`); the rollout adds a curated list for
// every prose reading manual. Non-prose docs (glossary decks, SOP/screenshot
// manuals, recipe cards, menu slides, picture-first docs) stay uncurated and
// show no highlighting.
//
// Three layers are proven here:
//   * The pure matcher [BarrioKeyTermHighlight.matchesIn] on crafted
//     strings: whole-word (case-insensitive) matching, the hard
//     per-card density cap, first-occurrence-per-card, longest-wins at a
//     tie, overlap dropping, and verbatim substring preservation.
//   * The per-manual lookup [barrioKeyTermsForUnit]: prose manuals return a
//     non-empty curated list, non-prose docs return empty, and a sampled term
//     from a rolled-out manual really matches (whole-word) in its body prose.
//     Since T8 (2026-08-02) the card asks [barrioCardKeysForUnit] instead,
//     which answers with a card's own authored phrases when it has them and
//     falls back to this per-manual list when it does not; the registry
//     ships empty, so the two lookups agree everywhere today (exhaustively
//     proved in `test/barrio_card_key_sets_test.dart`).
//   * The rendering card [HandbookLessonCard] on real + crafted Three
//     Pillars units and an uncurated unit: the term renders as w700 +
//     tealInk, only curated manuals highlight, the cap and first-occurrence
//     hold at render time, and the visible text stays byte-identical to the
//     source body (verbatim law: styling only).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/barrio_key_terms.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/cards/barrio_card_keys_index.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

// A real Three Pillars intro card: its body introduces the pillars, so it
// carries six curated terms (hospitality, three pillars, food, service,
// atmosphere, guest experience), several of them repeated.
const _pilotUnitId = 'training_three_pillars_c0_u0';
const _pilotNeedle = 'intertwine to create';

HandbookUnit _realUnit(String id) => kBarrioTrainingDocs.values
    .expand((d) => d.chapters)
    .expand((c) => c.units)
    .firstWhere((u) => u.id == id);

/// Whether [term] matches whole-word in any unit body of [docId] via the real
/// render-time matcher (coverage b: proves a curated term is not dead weight).
bool _termMatchesInDocBody(String docId, String term) {
  final doc = kBarrioTrainingDocs[docId]!;
  for (final ch in doc.chapters) {
    for (final u in ch.units) {
      final m = BarrioKeyTermHighlight.matchesIn(
        u.body, [term], alreadyUsed: <String>{});
      if (m.isNotEmpty) return true;
    }
  }
  return false;
}

/// Every leaf [TextSpan] under [span], in reading order.
List<TextSpan> _flatten(InlineSpan span) {
  final out = <TextSpan>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      out.add(s);
      for (final child in s.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(span);
  return out;
}

/// A key-term emphasis span: bold + tealInk with NO background wash. This
/// distinguishes it from the search highlight (tealWarm background), the
/// numeric fact pop (the manual's accent color), and the quiz answer span
/// (tealDeep, weight w600).
bool _isKeyTermSpan(TextSpan s) =>
    s.style?.color == BarrioColors.tealInk &&
    s.style?.fontWeight == FontWeight.w700 &&
    s.style?.backgroundColor == null;

/// The body RichText of the card: the one whose plain text carries the body
/// prose (found by a distinctive fragment so it is never the title or badge).
RichText _bodyRich(WidgetTester tester, String needle) {
  return tester
      .widgetList<RichText>(find.byType(RichText))
      .firstWhere((rt) => rt.text.toPlainText().contains(needle));
}

Future<void> _pumpCard(WidgetTester tester, HandbookUnit unit) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: HandbookLessonCard(unit: unit),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('BarrioKeyTermHighlight.matchesIn (pure matcher, crafted strings)', () {
    test('whole-word matching: "service"/"food" never match inside a word',
        () {
      // "serviceable" and "foodborne" must NOT match; the standalone words
      // "service" and "food" must.
      const text =
          'A serviceable foodborne note, yet great service and fresh food win.';
      final used = <String>{};
      final matches = BarrioKeyTermHighlight.matchesIn(
        text,
        const ['service', 'food'],
        alreadyUsed: used,
      );
      expect(matches, hasLength(2),
          reason: 'exactly the two standalone whole words match');
      // Each matched substring is the exact original (verbatim, styling only).
      for (final m in matches) {
        expect(text.substring(m.start, m.end), anyOf('service', 'food'));
      }
      // The matched offsets are the standalone words, not the earlier
      // "serviceable"/"foodborne" occurrences.
      expect(text.substring(matches.first.start, matches.first.end), 'service');
      expect(text.substring(matches.last.start, matches.last.end), 'food');
      expect(used, {'service', 'food'});
    });

    test('hard per-card cap: at most kBarrioKeyTermCardCap spans accepted', () {
      const text =
          'hospitality service atmosphere ambiance lighting cleanliness '
          'communication attentiveness presentation';
      final used = <String>{};
      final matches = BarrioKeyTermHighlight.matchesIn(
        text,
        const [
          'hospitality',
          'service',
          'atmosphere',
          'ambiance',
          'lighting',
          'cleanliness',
          'communication',
          'attentiveness',
          'presentation',
        ],
        alreadyUsed: used,
      );
      expect(kBarrioKeyTermCardCap, 6);
      expect(matches, hasLength(kBarrioKeyTermCardCap),
          reason: 'nine distinct terms are present but the cap holds at six');
      // The cap keeps the FIRST six by position; the rest are dropped.
      expect(matches.map((m) => text.substring(m.start, m.end)).toList(), [
        'hospitality',
        'service',
        'atmosphere',
        'ambiance',
        'lighting',
        'cleanliness',
      ]);
      expect(used, hasLength(6));
    });

    test('first-occurrence-per-card: repeats stay plain within and across '
        'chunks via the threaded set', () {
      final used = <String>{};
      // Within one chunk, "atmosphere" appears twice: only the first matches.
      const chunk1 = 'The atmosphere and the atmosphere again, plus service.';
      final m1 = BarrioKeyTermHighlight.matchesIn(
        chunk1,
        const ['atmosphere', 'service'],
        alreadyUsed: used,
      );
      expect(m1.map((m) => chunk1.substring(m.start, m.end)),
          ['atmosphere', 'service']);
      expect(m1.where((m) => chunk1.substring(m.start, m.end) == 'atmosphere'),
          hasLength(1),
          reason: 'the second "atmosphere" in the same chunk stays plain');
      // A later chunk of the SAME card: both terms are already used, so
      // neither re-emphasizes.
      const chunk2 = 'Again the atmosphere shapes the service here.';
      final m2 = BarrioKeyTermHighlight.matchesIn(
        chunk2,
        const ['atmosphere', 'service'],
        alreadyUsed: used,
      );
      expect(m2, isEmpty,
          reason: 'first-occurrence-per-card: no term repeats on the card');
    });

    test('longest-wins at a tie: "food quality" beats "food"', () {
      const text = 'Food quality is the standard here.';
      final used = <String>{};
      final matches = BarrioKeyTermHighlight.matchesIn(
        text,
        const ['food', 'food quality'],
        alreadyUsed: used,
      );
      expect(matches, hasLength(1),
          reason: 'the overlapping shorter "food" is dropped');
      expect(text.substring(matches.first.start, matches.first.end),
          'Food quality',
          reason: 'the multi-word phrase wins and keeps the original case');
    });

    test('blockedRanges: a term overlapping a higher-precedence span is '
        'dropped whole', () {
      const text = 'Great service defines the atmosphere.';
      final serviceStart = text.indexOf('service');
      final used = <String>{};
      final matches = BarrioKeyTermHighlight.matchesIn(
        text,
        const ['service', 'atmosphere'],
        alreadyUsed: used,
        blockedRanges: [
          [serviceStart, serviceStart + 'service'.length],
        ],
      );
      expect(matches.map((m) => text.substring(m.start, m.end)), ['atmosphere'],
          reason: 'the blocked "service" is dropped; "atmosphere" survives');
    });

    test('case-insensitive match keeps the exact original casing', () {
      const text = 'Hospitality is color.';
      final used = <String>{};
      final matches = BarrioKeyTermHighlight.matchesIn(
        text,
        const ['hospitality'],
        alreadyUsed: used,
      );
      expect(matches, hasLength(1));
      expect(text.substring(matches.first.start, matches.first.end),
          'Hospitality',
          reason: 'the styled range is verbatim: capital H preserved');
    });
  });

  group('barrioKeyTermsForUnit (per-manual rollout)', () {
    test('the Three Pillars pilot list is preserved', () {
      expect(barrioKeyTermsForUnit('training_three_pillars_c0_u0'), isNotEmpty);
      expect(barrioKeyTermsForUnit('training_three_pillars_c2_u5'), isNotEmpty);
    });

    test('every rolled-out prose manual returns a curated list (coverage a: '
        'many more than two newly-added manuals are non-empty)', () {
      // The newly-added prose manuals (all EXCEPT the original pilot). Each
      // must return a non-empty curated list now that the gate is per-manual.
      const rolledOut = <String>[
        'company_handbook',
        'interview_playbook',
        'jim_taylor_labor_model',
        'training_strong_foundation',
        'training_table_manicuring',
        'training_suggestive_selling',
        'training_labour_cost',
        'training_food_safety',
        'training_cheers_responsibility',
        'training_mastering_metrics',
        'training_bold_by_design',
        'training_host_manual',
        'training_bar_manual',
      ];
      for (final docId in rolledOut) {
        final terms = barrioKeyTermsForUnit('${docId}_c0_u0');
        expect(terms, isNotEmpty, reason: '$docId should be curated now');
        // Quality bar mirrors the pilot: ~10 to 18 curated terms.
        expect(terms.length, inInclusiveRange(10, 18),
            reason: '$docId list is $terms');
      }
    });

    test('non-prose docs stay uncurated and the empty/unknown ids are empty',
        () {
      // Deliberately SKIPPED docs: glossary term-card decks, SOP/screenshot
      // manuals, recipe cards, menu slides, and picture-first docs.
      for (final docId in const <String>[
        'training_latin_dishes',
        'training_latin_ingredients',
        'training_general_words',
        'training_clover_sop',
        'training_push_sop',
        'training_drink_specs',
        'training_menu_concept',
        'training_tequila',
        'training_coffee',
      ]) {
        expect(barrioKeyTermsForUnit('${docId}_c1_u2'), isEmpty,
            reason: '$docId is intentionally not curated');
      }
      expect(barrioKeyTermsForUnit(''), isEmpty);
      expect(barrioKeyTermsForUnit('some_unknown_doc_c0_u0'), isEmpty);
    });

    test('coverage b: a sampled term from a rolled-out manual really matches '
        '(whole-word) in that manual body prose', () {
      // (docId, a curated term expected to appear verbatim in the body).
      const samples = <List<String>>[
        ['training_food_safety', 'food safety'],
        ['company_handbook', 'workplace harassment'],
        ['training_bold_by_design', 'productivity zone'],
        ['training_bar_manual', 'barrio legado'],
      ];
      for (final s in samples) {
        final docId = s[0], term = s[1];
        // The reader hands this exact term list to the matcher for the doc.
        expect(barrioKeyTermsForUnit('${docId}_c0_u0'), contains(term),
            reason: '$term should be curated for $docId');
        expect(_termMatchesInDocBody(docId, term), isTrue,
            reason: '"$term" must match whole-word somewhere in $docId body');
      }
    });

    test('T8 swap: the card lookup [barrioCardKeysForUnit] returns exactly '
        'the per-manual terms while no per-card set is authored', () {
      // The renderer reads barrioCardKeysForUnit now. On the pilot card, on
      // a crafted id inside a curated doc, and on an uncurated doc, the new
      // lookup must be indistinguishable from the old one, or the swap
      // changed the screen. Ids come from the real registry so a content
      // regeneration cannot rot this.
      final sampled = <String>[
        _pilotUnitId,
        for (final doc in kBarrioTrainingDocs.values)
          if (doc.chapters.isNotEmpty && doc.chapters.first.units.isNotEmpty)
            doc.chapters.first.units.first.id,
      ];
      for (final unitId in sampled) {
        expect(barrioCardKeysForUnit(unitId), barrioKeyTermsForUnit(unitId),
            reason: '$unitId must render the same terms after the swap');
      }
      expect(barrioCardKeysForUnit('some_unknown_doc_c0_u0'), isEmpty);
    });
  });

  group('HandbookLessonCard rendering', () {
    testWidgets(
        'a real Three Pillars card renders curated terms as w700 + tealInk, '
        'first-occurrence only, within the six-per-card cap, verbatim body',
        (tester) async {
      final unit = _realUnit(_pilotUnitId);
      // Sanity: the reader looks the terms up itself for this unit.
      expect(barrioKeyTermsForUnit(unit.id), isNotEmpty);

      await _pumpCard(tester, unit);

      final rich = _bodyRich(tester, _pilotNeedle);
      // Verbatim law: the concatenated visible text equals the source body.
      expect(rich.text.toPlainText(), unit.body);

      final keySpans = _flatten(rich.text).where(_isKeyTermSpan).toList();
      expect(keySpans, isNotEmpty, reason: 'the pilot card is highlighted');
      expect(keySpans.length, lessThanOrEqualTo(kBarrioKeyTermCardCap),
          reason: 'the hard per-card density cap holds');
      final emphasized =
          keySpans.map((s) => s.text!.toLowerCase()).toSet();
      expect(
          emphasized,
          {
            'hospitality',
            'three pillars',
            'food',
            'service',
            'atmosphere',
            'guest experience',
          },
          reason: 'the six intro-card domain concepts are emphasized');
      // First-occurrence-per-card: "food" appears twice in the body but is
      // emphasized exactly once.
      expect(unit.body.split('food').length - 1, greaterThanOrEqualTo(2),
          reason: 'guard: "food" really does repeat in the body');
      expect(
          keySpans.where((s) => s.text!.toLowerCase() == 'food'), hasLength(1),
          reason: 'only the first "food" is emphasized; the repeat stays plain');
    });

    testWidgets(
        'an uncurated (non-prose) unit renders NO key-term highlight even when '
        'its body is full of curated words, body stays verbatim',
        (tester) async {
      // training_coffee is a deliberately-skipped picture-first doc, so it
      // returns no curated terms even though the body is full of them.
      const uncurated = HandbookUnit(
        id: 'training_coffee_c0_u0',
        type: HandbookUnitType.explainer,
        title: 'Coffee',
        body: 'Great service and food and hospitality shape the atmosphere '
            'and set the standards here.',
      );
      // Sanity: the lookup returns no terms for this uncurated doc.
      expect(barrioKeyTermsForUnit(uncurated.id), isEmpty);

      await _pumpCard(tester, uncurated);

      final rich = _bodyRich(tester, 'shape the atmosphere');
      expect(rich.text.toPlainText(), uncurated.body,
          reason: 'the body text is unchanged');
      expect(_flatten(rich.text).where(_isKeyTermSpan), isEmpty,
          reason: 'no key-term emphasis on an uncurated (non-prose) doc');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a crafted Three Pillars-id card enforces the six-cap and '
        'first-occurrence at render time, body stays verbatim',
        (tester) async {
      // Twelve distinct curated terms in order, plus a repeated
      // "hospitality" at the end. The cap keeps the first six; the rest
      // (and the repeat) stay plain.
      const crafted = HandbookUnit(
        id: 'training_three_pillars_crafted',
        type: HandbookUnitType.explainer,
        title: 'Crafted',
        body: 'hospitality and service shape the atmosphere and ambiance. '
            'Good lighting and cleanliness support communication and '
            'attentiveness. The food and its presentation and reputation and '
            'standards matter. Yet hospitality endures.',
      );

      await _pumpCard(tester, crafted);

      final rich = _bodyRich(tester, 'shape the atmosphere');
      expect(rich.text.toPlainText(), crafted.body,
          reason: 'styling only: the crafted body is byte-identical');

      final keySpans = _flatten(rich.text).where(_isKeyTermSpan).toList();
      expect(keySpans, hasLength(kBarrioKeyTermCardCap),
          reason: 'twelve distinct terms present, capped at six');
      expect(keySpans.map((s) => s.text!.toLowerCase()).toList(), [
        'hospitality',
        'service',
        'atmosphere',
        'ambiance',
        'lighting',
        'cleanliness',
      ]);
      // Beyond-cap terms stay plain, and the repeated "hospitality" is
      // emphasized exactly once.
      final emphasized = keySpans.map((s) => s.text!.toLowerCase()).toList();
      expect(emphasized.contains('communication'), isFalse,
          reason: 'the seventh term is past the cap');
      expect(emphasized.where((t) => t == 'hospitality'), hasLength(1),
          reason: 'first-occurrence: the repeated hospitality is not restyled');
      expect(tester.takeException(), isNull);
    });
  });
}
