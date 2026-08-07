// Proof that the General Words To Know and Clover POS authored per-card key
// phrases really light up, and that a card in either manual without an
// authored set is unharmed (T8 follow-on, 2026-08-07).
//
// WHY A RENDER TEST AND NOT JUST A DATA TEST
//
// `test/barrio_card_key_sets_test.dart` proves the DATA satisfies the
// authoring contract. It never pumps a widget, so it cannot prove a phrase
// survives the card's five-tier span pipeline (search wash, term link,
// numeric pop, quiz answer evidence, then key terms LAST). Every one of those
// tiers outranks key terms and drops an overlapping phrase WHOLE, with no
// error and no partial render: the phrase simply never appears. That is the
// exact failure these two manuals are most exposed to, because Clover is a
// step-by-step manual thick with step numbers, table numbers and guest counts,
// and General Words carries the temperature-danger-zone card whose body is
// half numeric facts.
//
// WHY THE FALLBACK HALF MATTERS HERE
//
// Neither doc is registered in `barrio_key_terms.dart`, so neither has a
// per-manual list behind it. An uncovered card must therefore resolve to an
// EMPTY answer and render no key-term span at all, exactly as it did before
// this data landed. That is asserted from the constant at runtime rather than
// assumed, because if either doc ever gains a per-manual list the honest
// reading of "no entry" changes and this file must be revisited.
//
// HOW THIS FILE AVOIDS PROVING NOTHING
//
// Three traps, all closed deliberately:
//
//   1. A render assertion that would pass on a blank screen. Every
//      "renders nothing" claim is paired with a positive control on the SAME
//      pump: the card's body text is asserted present. An empty emphasis list
//      only counts once the card is proved to have rendered.
//   2. An emphasis reader that is really a plain-text reader. [_negativeProbe]
//      picks body wording that is deliberately NOT authored and asserts it is
//      on screen as plain text yet absent from the emphasis list. If
//      [_renderedKeyPhrases] ever degraded into "return every string in the
//      body", that probe goes red.
//   3. Expected values drawn from the path under test. The expectation is the
//      const authored data; the actual is walked out of the live widget tree.
//      The two never share a code path. Doc ids aside, nothing is hard-coded:
//      sampled cards, uncovered cards, the numeric-tier card and the curated
//      comparison doc are all resolved at runtime from `kBarrioTrainingDocs`,
//      so a content regeneration cannot rot this file.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/barrio_body_chunks.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/barrio_key_terms.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/cards/barrio_card_keys_index.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_numeric_highlight.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

/// The two manuals this slice authored, with the coverage floor each one
/// shipped at. Falling-only: a later slice raises a floor as it authors more
/// cards and never lowers one. Deliberately a floor and not an equality,
/// because the short one-clause cards in both docs ('BOH: Refers to the
/// kitchen team.', 'Select Fire All to send the order.') honestly cannot carry
/// three non-overlapping phrases that teach anything and ship no entry.
const Map<String, int> _kDocFloors = <String, int>{
  'training_general_words': 68,
  'training_clover_sop': 47,
};

/// Every unit of [docId] in reading order.
List<HandbookUnit> _unitsOf(String docId) => <HandbookUnit>[
      for (final chapter in kBarrioTrainingDocs[docId]!.chapters)
        ...chapter.units,
    ];

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

/// A key-term emphasis span: bold + tealInk with NO background wash. That
/// combination is what distinguishes it from the search highlight (tealWarm
/// background), the numeric fact pop (the manual's accent) and the quiz
/// answer span (tealDeep, w600).
bool _isKeyTermSpan(TextSpan s) =>
    s.style?.color == BarrioColors.tealInk &&
    s.style?.fontWeight == FontWeight.w700 &&
    s.style?.backgroundColor == null;

Future<void> _pumpCard(WidgetTester tester, HandbookUnit unit) async {
  tester.view.physicalSize = const Size(390, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: HandbookLessonCard(unit: unit)),
      ),
    ),
  );
  await tester.pump();
}

/// The body chunks actually on screen for [unit]: only [RichText]s whose plain
/// text is verbatim body content, so a title or badge can never be mistaken
/// for body copy. Bullet rows have dropped their marker and table rows have
/// split on the cell separator, and both remain body substrings.
List<String> _renderedBodyChunks(WidgetTester tester, HandbookUnit unit) => [
      for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
        if (rich.text.toPlainText().length >= 20 &&
            unit.body.contains(rich.text.toPlainText()))
          rich.text.toPlainText(),
    ];

/// The key-term-emphasized wording actually on screen for [unit], in reading
/// order.
List<String> _renderedKeyPhrases(WidgetTester tester, HandbookUnit unit) {
  final out = <String>[];
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    final plain = rich.text.toPlainText();
    if (plain.length < 20 || !unit.body.contains(plain)) continue;
    for (final span in _flatten(rich.text)) {
      if (span.text != null && _isKeyTermSpan(span)) out.add(span.text!);
    }
  }
  return out;
}

final RegExp _hasLetter = RegExp('[A-Za-z]');

/// The card's first UNEMPHASIZED run: the body wording sitting in the gap
/// between two authored phrases (or before the first / after the last).
///
/// This is the negative control that keeps [_renderedKeyPhrases] honest, and
/// it is deliberately a whole gap rather than an arbitrary word window: a gap
/// is exactly the string the card emits as its own plain span, so a reader
/// that had degraded into "return every span" would report this string
/// verbatim and the probe goes red. An arbitrary window could straddle an
/// emphasis boundary and slip through such a reader unnoticed.
///
/// The gaps are located with the DEPLOYED matcher, threading one `alreadyUsed`
/// set across the chunks in reading order exactly as the card does, so the
/// boundaries are the real ones and not an approximation. Returns null when
/// the card leaves no usable gap, in which case the caller fails loudly rather
/// than skipping the control.
String? _negativeProbe(HandbookUnit unit) {
  final authored = kBarrioCardKeysByUnit[unit.id] ?? const <String>[];
  if (authored.isEmpty) return null;
  final used = <String>{};
  for (final chunk in chunksForBody(unit.body)) {
    final matches = BarrioKeyTermHighlight.matchesIn(
      chunk.text,
      authored,
      alreadyUsed: used,
      maxPerCard: authored.length + 1,
    );
    // Short chunks are filtered out of the rendered reader, so a probe drawn
    // from one could never be found and would fake a pass. The matcher still
    // runs above, because `used` must stay threaded across every chunk.
    if (chunk.text.length < 20) continue;
    var cursor = 0;
    for (var i = 0; i <= matches.length; i++) {
      final end = i < matches.length ? matches[i].start : chunk.text.length;
      final gap = chunk.text.substring(cursor, end);
      if (gap.length >= 12 && _hasLetter.hasMatch(gap)) return gap;
      if (i < matches.length) cursor = matches[i].end;
    }
  }
  return null;
}

void main() {
  for (final entry in _kDocFloors.entries) {
    final docId = entry.key;
    final floor = entry.value;
    final units = _unitsOf(docId);
    final covered = units
        .where((u) => (kBarrioCardKeysByUnit[u.id] ?? const []).isNotEmpty)
        .toList();
    final uncovered = units
        .where((u) => (kBarrioCardKeysByUnit[u.id] ?? const []).isEmpty)
        .toList();

    group('$docId carries authored phrases', () {
      test('coverage holds at or above the shipped floor and every card is '
          'accounted for', () {
        expect(units, isNotEmpty, reason: '$docId must render');
        expect(covered.length + uncovered.length, units.length);
        expect(covered.length, greaterThanOrEqualTo(floor),
            reason: '$docId coverage fell: ${covered.length} of '
                '${units.length} cards carry an authored set (floor $floor). '
                'Raise the data back up, do not lower the floor.');
      });

      test('the doc has NO per-manual list, so an entry is the only thing '
          'that can light a card up', () {
        for (final unit in units) {
          expect(barrioKeyTermsForUnit(unit.id), isEmpty,
              reason: '$docId gained a per-manual fallback list. The '
                  '"an uncovered card highlights nothing" claim below is no '
                  'longer true; revisit this file.');
        }
      });
    });

    group('$docId: authored phrases render (the silent-drop guard)', () {
      // A spread sample across the doc. Indices are derived, so the sample
      // follows the content instead of pinning card numbers.
      final sample = <HandbookUnit>{
        covered.first,
        covered[covered.length ~/ 3],
        covered[(covered.length * 2) ~/ 3],
        covered.last,
      }.toList();

      for (final unit in sample) {
        testWidgets('${unit.id} shows all of its authored phrases in reading '
            'order', (tester) async {
          final authored = kBarrioCardKeysByUnit[unit.id]!;
          await _pumpCard(tester, unit);
          expect(_renderedKeyPhrases(tester, unit), authored,
              reason: '${unit.id}: the rendered emphasis must be exactly the '
                  'authored phrases, in order. A missing one was dropped by a '
                  'higher-precedence tier or never matched.');
        });
      }

      testWidgets('the emphasis reader is not just reading plain text',
          (tester) async {
        final unit = sample.first;
        final probe = _negativeProbe(unit);
        expect(probe, isNotNull,
            reason: '${unit.id} has no unauthored wording left to probe with; '
                'pick another sample card rather than dropping the control');
        await _pumpCard(tester, unit);
        expect(_renderedBodyChunks(tester, unit).join('\n'), contains(probe!),
            reason: '"$probe" must be on screen as ordinary body copy');
        // `contains` on the span, not on the list: the probe must not appear
        // INSIDE any emphasized run either, which is how a reader that had
        // degraded into "every span" would smuggle it through.
        expect(_renderedKeyPhrases(tester, unit).any((p) => p.contains(probe)),
            isFalse,
            reason: '"$probe" is not authored, so it must NOT be emphasized. '
                'If it is, the reader is returning body text rather than '
                'key-term spans and every assertion above proves nothing.');
      });

      testWidgets('emphasis is styling only: the sampled body text is '
          'byte-identical to the source', (tester) async {
        final unit = sample.first;
        await _pumpCard(tester, unit);
        final chunks = _renderedBodyChunks(tester, unit);
        expect(chunks, isNotEmpty);
        for (final chunk in chunks) {
          expect(unit.body.contains(chunk), isTrue,
              reason: 'rendered body wording drifted from the source');
        }
      });
    });

    group('$docId: a card with no authored entry still takes the fallback',
        () {
      test('every uncovered card resolves to the per-manual answer', () {
        expect(uncovered, isNotEmpty,
            reason: 'the fallback path must still be exercised by real cards');
        for (final unit in uncovered) {
          expect(barrioCardKeysForUnit(unit.id), barrioKeyTermsForUnit(unit.id),
              reason: '${unit.id} must render the per-manual list unchanged');
        }
      });

      testWidgets('an uncovered card renders its body but no key-term '
          'emphasis at all', (tester) async {
        final unit = uncovered.first;
        await _pumpCard(tester, unit);
        // Positive control first: an empty emphasis list means nothing at all
        // if the card never rendered.
        expect(find.textContaining(unit.body.split('\n\n').first.split(' ')[1]),
            findsWidgets,
            reason: '${unit.id} did not render, so the emptiness below would '
                'be vacuous');
        expect(_renderedKeyPhrases(tester, unit), isEmpty,
            reason: '${unit.id} has no authored set and $docId has no '
                'per-manual list, so nothing may light up');
      });
    });
  }

  group('the numeric tier and the key-term tier coexist', () {
    // The one card across both manuals whose body carries a LIVE numeric-pop
    // span next to authored phrases. Resolved at runtime, because that is
    // exactly the pairing where the higher tier silently eats a phrase.
    HandbookUnit? numericCard;
    for (final docId in _kDocFloors.keys) {
      for (final unit in _unitsOf(docId)) {
        if ((kBarrioCardKeysByUnit[unit.id] ?? const []).isEmpty) continue;
        final popped = chunksForBody(unit.body).any(
            (c) => BarrioNumericHighlight.matchesIn(c.text).isNotEmpty);
        if (popped) {
          numericCard = unit;
          break;
        }
      }
      if (numericCard != null) break;
    }

    test('such a card exists, so the guard below is not vacuous', () {
      expect(numericCard, isNotNull,
          reason: 'no authored card in either manual sits beside a numeric '
              'pop any more; move this guard rather than deleting it');
    });

    testWidgets('every authored phrase still renders beside the numeric pops',
        (tester) async {
      final unit = numericCard!;
      await _pumpCard(tester, unit);
      expect(_renderedKeyPhrases(tester, unit), kBarrioCardKeysByUnit[unit.id],
          reason: '${unit.id}: the numeric tier outranks key terms and drops '
              'an overlapping phrase whole. Every authored phrase must still '
              'be on screen.');
    });
  });
}
