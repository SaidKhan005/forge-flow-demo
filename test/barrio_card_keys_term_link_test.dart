// Guard: an authored key phrase never collides with a tap-to-define term
// link (T8 follow-on, 2026-08-06).
//
// WHY THIS EXISTS
//
// The reading card composes five styling tiers, highest precedence first:
// search wash, term links, numeric pops, quiz answer evidence, then the
// curated key phrases (`handbook_lesson_card.dart` `_composeChunk`). Each
// lower tier is handed the higher tiers' ranges as `blockedRanges` and
// DROPS ANY OVERLAP WHOLE. So a key phrase that overlaps a term link does
// not render partially and does not warn: it renders NOTHING, silently,
// and the card quietly loses one of its 3 to 6 pieces of teaching.
//
// `barrio_card_key_sets_test.dart` already binds the authored phrases
// against three of the four tiers that outrank them: numeric pops (the
// no-digits rule), quiz answer evidence (the no-teal-on-teal rule), and
// the search wash (transient and query-driven, so the mechanism guards it
// rather than the data). Term links were the gap. This file closes it.
//
// SCOPE. Term links are live only on the four culinary manuals in
// [BarrioTermLinks.kHostManualIds], and only when the reader passes an
// `onTermTap` (`training_doc_screen.dart:766` gates on exactly that set).
// A phrase on any other manual can never meet a term link, so the guard
// iterates the host manuals only, resolved from the constant at runtime.
//
// THIS IS A REGRESSION GUARD, NOT A REPAIR. Measured at the time of
// writing: zero collisions. No content was changed to make that true, and
// the reason it is true is STRUCTURAL rather than careful authoring, which
// is worth stating plainly because it is also the reason the risk is real:
//
//   * term links fire on the menu deck only (19 of its 24 cards, 39 spans,
//     18 distinct terms) and on no card of coffee, tequila, or food
//     safety, exactly as `barrio_term_links.dart` records from its
//     2026-07-23 dump;
//   * the authored phrases on host manuals are ALL on food safety (82
//     cards, 395 phrases), where nothing links.
//
// The two populations are on disjoint manuals today. The day the menu deck
// gets authored, that changes hard: its live terms are 'salsa', 'ceviche',
// 'mole', 'tortilla', 'al pastor' and the like, which is precisely the
// vocabulary an author would reach for as key phrases. This guard is
// written now so that day is a red test rather than a silent loss.
//
// HOW IT AVOIDS BEING VACUOUS
//
// Three traps, all avoided deliberately:
//
//   1. Approximating the matcher. The term registry is not "the glossary
//      titles": it is those titles run through `_termsOfTitle`
//      (parenthetical stripped, '/' variants split, folded, 4-letter
//      floor, continuation cards skipped), matched longest-first out of
//      first-code-unit buckets, whole-word, with ONE `alreadyLinked` set
//      threaded across the card's chunks in reading order. A hand-rolled
//      "does the body contain a glossary word" check would claim a
//      different span set and prove nothing about what renders. So this
//      file calls [BarrioTermLinks.matchesIn] itself, over the real
//      [chunksForBody] chunks, threading the set exactly as
//      `_SpanPass.linked` is threaded.
//   2. Letting the tiers cancel the collision out. Both matchers accept
//      `blockedRanges`, and feeding either tier's spans to the other would
//      make the loser yield, the overlap disappear, and this file pass
//      against genuinely broken data. Both sides are therefore computed
//      UNBLOCKED: each tier's spans are where it WANTS to render, and the
//      guard asserts those two wish-lists are disjoint. See
//      [_termLinkSpans] and [_keyPhraseSpans].
//   3. Going green because it iterated nothing. Today the main assertion
//      has no authored card that carries a term link, so on its own it
//      would be trivially true. Two groups below fix that: one takes a
//      REAL host card that really does link, builds a phrase over that
//      real linked span, and asserts the guard reports it; the other
//      proves red-and-green on synthetic bodies. A guard that cannot be
//      shown to fail is not a guard.
//
// House rule followed throughout: nothing about the corpus is hard-coded.
// Host ids, registry terms, unit ids, bodies, and counts are all derived
// at runtime, so a content regeneration cannot rot this file into a green
// no-op; it makes it go red instead.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/barrio_body_chunks.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/barrio_key_terms.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/cards/barrio_card_keys_index.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_term_links.dart';

/// One styled span: `[start, end)` inside the rendered chunk numbered
/// [chunk], plus what claimed it (a phrase, or a folded registry term) so
/// a failure names both sides of the collision.
class _Span {
  final int chunk;
  final int start;
  final int end;
  final String label;

  const _Span(this.chunk, this.start, this.end, this.label);

  bool intersects(_Span other) =>
      chunk == other.chunk && start < other.end && end > other.start;
}

/// A card that sits on a term-link host manual, with whatever per-card
/// phrases it has been authored (empty when it has none).
class _HostCard {
  final String docId;
  final String unitId;
  final HandbookUnit unit;
  final List<String> phrases;

  const _HostCard(this.docId, this.unitId, this.unit, this.phrases);

  bool get isAuthored => phrases.isNotEmpty;
}

/// Every card on every term-link host manual, in corpus order.
///
/// Derived from [BarrioTermLinks.kHostManualIds] and the live doc
/// registry: a manual added to (or removed from) the host set is picked up
/// here with no edit to this file.
List<_HostCard> _hostCards() {
  final cards = <_HostCard>[];
  for (final docId in BarrioTermLinks.kHostManualIds) {
    final doc = kBarrioTrainingDocs[docId];
    if (doc == null) continue;
    for (final chapter in doc.chapters) {
      for (final unit in chapter.units) {
        cards.add(_HostCard(
          docId,
          unit.id,
          unit,
          kBarrioCardKeysByUnit[unit.id] ?? const <String>[],
        ));
      }
    }
  }
  return cards;
}

/// Every term-link span the DEPLOYED matcher claims on [body].
///
/// Faithful to the render in three ways that all change the answer:
///   * the chunks come from [chunksForBody], the single body parse the
///     card renders off, so a bullet has already lost its '- ', a numbered
///     step its 'N. ', and a table row is already split and trimmed;
///   * one `alreadyLinked` set is threaded across those chunks in reading
///     order, exactly as `_SpanPass.linked` is threaded through the card's
///     `_bodyText` calls, so a term links only once per card;
///   * `blockedRanges` is left EMPTY. The only tier above term links is
///     the search wash, which is transient and absent at rest, and passing
///     the key-phrase spans here would be the vacuity trap: the term link
///     would yield, the collision would vanish, and this file would pass
///     against colliding data.
List<_Span> _termLinkSpans(String body) {
  final linked = <String>{};
  final spans = <_Span>[];
  for (final chunk in chunksForBody(body)) {
    for (final match in BarrioTermLinks.matchesIn(
      chunk.text,
      alreadyLinked: linked,
    )) {
      spans.add(_Span(chunk.index, match.start, match.end, match.foldedTerm));
    }
  }
  return spans;
}

/// Every span the authored [phrases] WANT to claim on [body].
///
/// Same real matcher and same chunk parse the card uses, with the same
/// `alreadyUsed` threading. Two deliberate choices:
///   * `blockedRanges` is EMPTY, for the reason in [_termLinkSpans]: a
///     phrase blocked by a term link is precisely the failure being
///     hunted, so it must still appear here to be caught.
///   * `maxPerCard` is lifted above the phrase count. The authoring
///     contract caps a card at [kBarrioKeyTermCardCap] phrases so the
///     render cap never truncates in practice; lifting it means a
///     colliding phrase is reported even when it sits last in the list.
List<_Span> _keyPhraseSpans(String body, List<String> phrases) {
  final used = <String>{};
  final spans = <_Span>[];
  for (final chunk in chunksForBody(body)) {
    for (final match in BarrioKeyTermHighlight.matchesIn(
      chunk.text,
      phrases,
      alreadyUsed: used,
      maxPerCard: phrases.length + 1,
    )) {
      spans.add(_Span(
        chunk.index,
        match.start,
        match.end,
        chunk.text.substring(match.start, match.end),
      ));
    }
  }
  return spans;
}

/// Human-readable collisions between the two tiers' wish-lists on one
/// body. Empty means every authored phrase survives to render.
List<String> _collisions(String body, List<String> phrases) {
  final termSpans = _termLinkSpans(body);
  if (termSpans.isEmpty) return const <String>[];
  final report = <String>[];
  for (final phrase in _keyPhraseSpans(body, phrases)) {
    for (final term in termSpans) {
      if (phrase.intersects(term)) {
        report.add('"${phrase.label}" overlaps term link "${term.label}" '
            'in rendered chunk ${phrase.chunk}');
      }
    }
  }
  return report;
}

void main() {
  final hostCards = _hostCards();
  final authored = hostCards.where((c) => c.isAuthored).toList();
  final linking =
      hostCards.where((c) => _termLinkSpans(c.unit.body).isNotEmpty).toList();

  group('authored key phrases never collide with a term link', () {
    test('no phrase on a host manual overlaps a tap-to-define span', () {
      final failures = <String>[];
      for (final card in authored) {
        for (final collision in _collisions(card.unit.body, card.phrases)) {
          failures.add('${card.unitId}: $collision');
        }
      }
      expect(failures, isEmpty,
          reason: 'a key phrase overlapping a term link is dropped WHOLE at '
              'render (handbook_lesson_card.dart `_composeChunk`), so the '
              'card silently loses that teaching. Re-word the phrase to sit '
              'clear of the linked term:\n${failures.join('\n')}');
    });

    test('the corpus this guard runs over is real (registry populated, host '
        'manuals present, term links firing on shipped content)', () {
      final registry = BarrioTermLinks.registry();
      expect(registry, isNotEmpty,
          reason: 'an empty term registry would make every assertion in this '
              'file trivially true');
      expect(hostCards, isNotEmpty,
          reason: 'no host manual resolved from kHostManualIds');
      expect(linking, isNotEmpty,
          reason: 'the matcher claims no span anywhere on the four host '
              'manuals, so nothing in this file is being exercised against '
              'real content. Investigate the matcher or the glossaries; do '
              'not delete this assertion');

      // Honest exposure report: today the authored cards and the linking
      // cards are on disjoint manuals, so the main assertion above is
      // structurally quiet. It binds the moment they overlap.
      final linkingIds = <String>{for (final c in linking) c.unitId};
      final exposed = authored.where((c) => linkingIds.contains(c.unitId));
      final phraseCount =
          authored.fold<int>(0, (sum, c) => sum + c.phrases.length);
      final spanCount = linking.fold<int>(
          0, (sum, c) => sum + _termLinkSpans(c.unit.body).length);
      final authoredDocs = <String>{for (final c in authored) c.docId};
      final linkingDocs = <String>{for (final c in linking) c.docId};
      debugPrint('BARRIO TERM-LINK vs KEY-PHRASE GUARD: '
          '${registry.length} registry terms. '
          '${linking.length} of ${hostCards.length} host cards carry '
          '$spanCount term-link spans (${linkingDocs.join(', ')}). '
          '${authored.length} host cards carry $phraseCount authored phrases '
          '(${authoredDocs.join(', ')}). '
          '${exposed.length} cards carry BOTH and are the live surface of '
          'this guard.');
    });
  });

  group('the guard goes red on REAL corpus content', () {
    // The strongest non-vacuity proof available without shipping bad data:
    // a real shipped card, its real body, its real linked span, and a
    // phrase drawn from that body. If the guard is blind, this goes green
    // and the failure is loud.
    late _HostCard card;
    late _Span link;

    setUp(() {
      card = linking.first;
      link = _termLinkSpans(card.unit.body).first;
    });

    test('a phrase equal to the linked term on that card is REPORTED', () {
      final chunk = chunksForBody(card.unit.body)[link.chunk];
      final phrase = chunk.text.substring(link.start, link.end);
      // Guard the guard: the phrase must actually render somewhere, or an
      // empty collision list would mean nothing.
      expect(_keyPhraseSpans(card.unit.body, <String>[phrase]), isNotEmpty,
          reason: 'the fixture phrase must match its own card body');
      expect(_collisions(card.unit.body, <String>[phrase]), isNotEmpty,
          reason: 'on ${card.unitId} the phrase "$phrase" sits exactly on the '
              'term link "${link.label}"; the guard must catch it');
    });

    test('a phrase elsewhere on the same real card is NOT reported', () {
      // Positive control on the same body: the helper must discriminate,
      // not simply fire on every card that has a link. The phrase is the
      // first word of a chunk that carries no link at all.
      final clean = chunksForBody(card.unit.body).firstWhere(
        (c) => !_termLinkSpans(card.unit.body).any((s) => s.chunk == c.index),
        orElse: () => chunksForBody(card.unit.body).first,
      );
      final word = clean.text.split(RegExp(r'\s+')).firstWhere(
            (w) => w.length > 3 && RegExp(r'^[A-Za-z]+$').hasMatch(w),
            orElse: () => '',
          );
      if (word.isEmpty) {
        debugPrint('BARRIO TERM-LINK GUARD: ${card.unitId} offered no clean '
            'control word; skipped.');
        return;
      }
      expect(_collisions(card.unit.body, <String>[word]), isEmpty,
          reason: '"$word" is clear of every link on ${card.unitId}');
    });

    test('every real linking card yields a reportable collision when a '
        'phrase is laid over its link', () {
      // Not just the first card: the whole linking population. This is what
      // proves the guard would bite across the manual that actually carries
      // the risk, rather than in one lucky spot.
      var proven = 0;
      for (final c in linking) {
        final spans = _termLinkSpans(c.unit.body);
        if (spans.isEmpty) continue;
        final chunk = chunksForBody(c.unit.body)[spans.first.chunk];
        final phrase = chunk.text.substring(spans.first.start, spans.first.end);
        expect(_collisions(c.unit.body, <String>[phrase]), isNotEmpty,
            reason: '${c.unitId}: laying "$phrase" over its own term link '
                'must report');
        proven++;
      }
      expect(proven, linking.length);
      debugPrint('BARRIO TERM-LINK GUARD: red proven on all $proven linking '
          'host cards.');
    });
  });

  group('the guard goes red on synthetic fixtures (shape coverage)', () {
    // Shapes the corpus does not currently offer: partial overlap, and a
    // same-offset span in a different chunk. The term is picked from the
    // live registry at runtime so the fixtures cannot drift from what the
    // matcher links.
    final longestTerm = (BarrioTermLinks.registry().keys.toList()
          ..sort((a, b) => b.length.compareTo(a.length)))
        .first;
    final body = 'The kitchen folds $longestTerm through the sauce before it '
        'goes out.\n\nService checks every dish before it leaves the pass.';

    test('the fixture really does link, and only once (otherwise it proves '
        'nothing)', () {
      final spans = _termLinkSpans(body);
      expect(spans, hasLength(1),
          reason: '"$longestTerm" must be the sole link in the fixture; a new '
              'glossary term colliding with the fixture wording shows up '
              'here rather than silently weakening it');
      expect(spans.first.label, longestTerm);
    });

    test('a phrase covering the linked term is REPORTED', () {
      expect(_collisions(body, <String>['folds $longestTerm through']),
          isNotEmpty,
          reason: 'the phrase swallows the whole linked span; at render the '
              'term link wins and this phrase would vanish');
    });

    test('a phrase merely touching the linked term is REPORTED', () {
      // Partial overlap, not containment: the drop-whole rule fires on any
      // intersection, so the guard has to as well.
      expect(_collisions(body, <String>['kitchen folds $longestTerm']),
          isNotEmpty);
    });

    test('a clean phrase in the same body is NOT reported', () {
      expect(_collisions(body, <String>['before it goes out']), isEmpty,
          reason: 'a positive control: the helper must not fire on a phrase '
              'that sits clear of the link');
    });

    test('a phrase in a DIFFERENT chunk is not a collision', () {
      // Spans are compared chunk-wise, exactly as the render composes them.
      expect(_collisions(body, <String>['leaves the pass']), isEmpty);
    });
  });

  group('matcher behaviours the span set depends on', () {
    test('4-letter floor: a short glossary title is never registered', () {
      final short = BarrioTermLinks.registry().keys.where((t) {
        var letters = 0;
        for (final u in t.codeUnits) {
          if ((u >= 0x61 && u <= 0x7A) || (u >= 0x30 && u <= 0x39)) letters++;
        }
        return letters < BarrioTermLinks.kMinTermLetters;
      });
      expect(short, isEmpty,
          reason: 'the floor is what keeps short Spanish words from linking '
              'all over the culinary manuals, and therefore what keeps this '
              'guard from over-reporting');
    });

    test('first-occurrence-per-card: a term repeated across chunks links '
        'once, in the first chunk', () {
      final term = BarrioTermLinks.registry().keys.first;
      final body = 'We prep the $term at open.\n\nWe plate the $term at close.';
      final spans = _termLinkSpans(body);
      expect(spans, hasLength(1),
          reason: 'one alreadyLinked set is threaded across the card, so the '
              'second occurrence is never claimed. A phrase over that second '
              'occurrence is therefore SAFE, and the guard must agree with '
              'the render rather than over-report');
      expect(spans.first.chunk, 0);
    });

    test('longest-match-first: where two registry terms nest, the longer one '
        'claims the span', () {
      final terms = BarrioTermLinks.registry().keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      // A real nested pair, if the glossaries ship one (the library
      // documents 'SALSA INGLESA' over 'SALSA'). Skipped honestly rather
      // than faked when the corpus has none.
      String? longer;
      String? shorter;
      for (final long in terms) {
        for (final short in terms) {
          if (long.length <= short.length) continue;
          if (long.startsWith('$short ')) {
            longer = long;
            shorter = short;
            break;
          }
        }
        if (longer != null) break;
      }
      if (longer == null) {
        debugPrint('BARRIO TERM-LINK GUARD: no nested term pair in the live '
            'registry; longest-match-first has nothing to prove here.');
        return;
      }
      final spans = _termLinkSpans('The cook reaches for $longer today.');
      expect(spans, hasLength(1));
      expect(spans.first.label, longer,
          reason: 'the shorter "$shorter" must not steal the span');
    });
  });
}
