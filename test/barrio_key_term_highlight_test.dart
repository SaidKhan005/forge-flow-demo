// Tests for the key-term color emphasis pilot (2026-07-28).
//
// A research-backed, author-CURATED pilot gated to ONE manual, "The Three
// Pillars of Hospitality" (doc id `training_three_pillars`): a small set of
// unambiguous domain concepts render bold + BarrioColors.tealInk (an
// AA-compliant deep teal on cream, 5.18:1) so the text-heavy reading cards
// become more scannable. Every OTHER doc shows no key-term highlighting.
//
// Two layers are proven here:
//   * The pure matcher [BarrioKeyTermHighlight.matchesIn] on crafted
//     strings: whole-word (case-insensitive) matching, the hard
//     per-card density cap, first-occurrence-per-card, longest-wins at a
//     tie, overlap dropping, and verbatim substring preservation.
//   * The rendering card [HandbookLessonCard] on real + crafted Three
//     Pillars units and a non-pilot unit: the term renders as w700 +
//     tealInk, only the pilot manual highlights (the gate), the cap and
//     first-occurrence hold at render time, and the visible text stays
//     byte-identical to the source body (verbatim law: styling only).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/barrio_key_terms.dart';
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

  group('barrioKeyTermsForUnit (pilot gate)', () {
    test('only Three Pillars units return curated terms; all else empty', () {
      expect(barrioKeyTermsForUnit('training_three_pillars_c0_u0'), isNotEmpty);
      expect(barrioKeyTermsForUnit('training_three_pillars_c2_u5'), isNotEmpty);
      // Every other doc returns an empty list (the gate).
      expect(barrioKeyTermsForUnit('training_food_safety_c0_u0'), isEmpty);
      expect(barrioKeyTermsForUnit('training_strong_foundation_c0_u0'), isEmpty);
      expect(barrioKeyTermsForUnit('training_coffee_c1_u2'), isEmpty);
      expect(barrioKeyTermsForUnit(''), isEmpty);
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
        'a non-Three-Pillars unit renders NO key-term highlight even when its '
        'body is full of curated words (the gate), body stays verbatim',
        (tester) async {
      const nonPilot = HandbookUnit(
        id: 'training_strong_foundation_c0_u0',
        type: HandbookUnitType.explainer,
        title: 'Foundation',
        body: 'Great service and food and hospitality shape the atmosphere '
            'and set the standards here.',
      );
      // Sanity: the gate returns no terms for this doc.
      expect(barrioKeyTermsForUnit(nonPilot.id), isEmpty);

      await _pumpCard(tester, nonPilot);

      final rich = _bodyRich(tester, 'shape the atmosphere');
      expect(rich.text.toPlainText(), nonPilot.body,
          reason: 'the body text is unchanged');
      expect(_flatten(rich.text).where(_isKeyTermSpan), isEmpty,
          reason: 'no key-term emphasis outside the Three Pillars pilot');
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
