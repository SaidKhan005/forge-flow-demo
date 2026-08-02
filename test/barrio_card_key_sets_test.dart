// Guards for the per-CARD key-phrase mechanism (T8 slice 1, 2026-08-02).
//
// Slice 1 ships the MECHANISM with no data: `kBarrioCardKeysByUnit` is
// empty, so `barrioCardKeysForUnit` falls back to the per-manual
// `barrioKeyTermsForUnit` for every card and today's rendering is
// unchanged. Two jobs here:
//
//   * FALLBACK PROOF (today): every rendered card gets byte-identical
//     terms from the new lookup and the old one, curated docs still return
//     their list, uncurated docs still return nothing. This is what makes
//     the renderer swap a provable no-op.
//   * CONTRACT GUARDS (bind when data lands): every authored phrase must
//     match whole-word in ITS OWN card's body, resolve to a real unit, not
//     overlap a sibling phrase, come in reading order, sit inside one
//     rendered chunk, number 3 to 6, carry no digits / em dash /
//     boilerplate, and not collide with the card's quiz answer evidence.
//     They iterate the registry, so they are quiet today and hard-binding
//     the moment a phrase is authored.
//
// Because the guards are quiet on an empty registry, the last group proves
// the guards THEMSELVES work: it runs the same helpers over synthetic
// fixtures (including the real fragmentation shape that today's per-manual
// lists produce: 'average guest' + 'guest check' colliding inside 'average
// guest check') and asserts they reject bad data.
//
// House rule followed throughout: nothing about the corpus is hard-coded.
// Doc ids, unit ids, bodies, titles, and the curated/uncurated split are
// all derived at runtime from `kBarrioTrainingDocs`, so a content
// regeneration cannot silently rot these tests.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/barrio_key_terms.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/cards/barrio_card_keys_index.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';

/// Coverage ratchet: the number of cards that MUST carry an authored
/// per-card phrase set. Falling-only - the authoring slice raises this as
/// docs land and it never goes back down. 0 today (mechanism-only slice).
const int kBarrioCardKeysCoverageFloor = 0;

/// Cards are keyed by unit id; a unit plus the doc/chapter it belongs to.
class _Card {
  final String docId;
  final BarrioTrainingDoc doc;
  final HandbookChapter chapter;
  final HandbookUnit unit;
  const _Card(this.docId, this.doc, this.chapter, this.unit);
}

/// Every rendered card in the corpus, keyed by unit id (derived at runtime:
/// no doc list, unit id, or count is ever hard-coded in this file).
Map<String, _Card> _allCards() {
  final cards = <String, _Card>{};
  for (final entry in kBarrioTrainingDocs.entries) {
    for (final chapter in entry.value.chapters) {
      for (final unit in chapter.units) {
        cards[unit.id] = _Card(entry.key, entry.value, chapter, unit);
      }
    }
  }
  return cards;
}

/// One rendered phrase occurrence: which body chunk it landed in and the
/// `[start, end)` range inside that chunk.
class _Hit {
  final int chunk;
  final int start;
  final int end;
  const _Hit(this.chunk, this.start, this.end);

  bool intersects(_Hit other) =>
      chunk == other.chunk && start < other.end && end > other.start;
}

/// The card's body chunks, exactly as `HandbookLessonCard` splits them
/// (`_UnitBody.build`: `unit.body.split('\n\n')`). A phrase that straddles
/// a chunk boundary can never render, so every guard works chunk-wise.
List<String> _chunks(String body) => body.split('\n\n');

/// Where a single [phrase] would actually render inside [body], or null if
/// it never matches. Uses the real render-time matcher, so whole-word,
/// case-insensitive, and diacritic-folded semantics are the deployed ones.
_Hit? _soloHit(String body, String phrase) {
  final chunks = _chunks(body);
  for (var c = 0; c < chunks.length; c++) {
    final matches = BarrioKeyTermHighlight.matchesIn(
      chunks[c],
      [phrase],
      alreadyUsed: <String>{},
      maxPerCard: 1,
    );
    if (matches.isNotEmpty) {
      return _Hit(c, matches.first.start, matches.first.end);
    }
  }
  return null;
}

/// Every phrase that would really render for a card, threading ONE
/// already-used set through the chunks in reading order exactly like the
/// card does. A phrase missing from the result either never matches or was
/// dropped for overlapping an earlier sibling.
List<String> _renderedPhrases(String body, List<String> phrases) {
  final used = <String>{};
  final rendered = <String>[];
  for (final chunk in _chunks(body)) {
    final matches = BarrioKeyTermHighlight.matchesIn(
      chunk,
      phrases,
      alreadyUsed: used,
      // Cardinality is guarded separately; here we want to see every phrase
      // that WOULD render, not the density cap's truncation.
      maxPerCard: phrases.length + 1,
    );
    for (final m in matches) {
      rendered.add(chunk.substring(m.start, m.end));
    }
  }
  return rendered;
}

/// Pairs of phrases whose rendered ranges collide inside the same chunk
/// (the 'average guest' + 'guest check' fragmentation shape).
List<List<String>> _overlappingPairs(String body, List<String> phrases) {
  final hits = <String, _Hit>{};
  for (final p in phrases) {
    final hit = _soloHit(body, p);
    if (hit != null) hits[p] = hit;
  }
  final bad = <List<String>>[];
  final keys = hits.keys.toList();
  for (var i = 0; i < keys.length; i++) {
    for (var j = i + 1; j < keys.length; j++) {
      if (hits[keys[i]]!.intersects(hits[keys[j]]!)) {
        bad.add([keys[i], keys[j]]);
      }
    }
  }
  return bad;
}

/// The card's quiz answer-evidence ranges, matched the way the card matches
/// them (verbatim substrings, plain case-sensitive `indexOf`).
List<_Hit> _answerHits(String body, List<String> evidence) {
  final hits = <_Hit>[];
  final chunks = _chunks(body);
  for (var c = 0; c < chunks.length; c++) {
    for (final phrase in evidence) {
      if (phrase.isEmpty) continue;
      final idx = chunks[c].indexOf(phrase);
      if (idx >= 0) hits.add(_Hit(c, idx, idx + phrase.length));
    }
  }
  return hits;
}

/// Boilerplate a phrase may never be: the doc title, any chapter title, the
/// card's own title, or the brand name on its own. Lower-cased for
/// comparison; derived from the corpus, never hard-coded.
Set<String> _boilerplateFor(_Card card) => <String>{
      card.doc.title.toLowerCase().trim(),
      card.unit.title.toLowerCase().trim(),
      for (final ch in card.doc.chapters) ch.title.toLowerCase().trim(),
      'barrio legado',
    };

void main() {
  final cards = _allCards();

  group('fallback proof (the renderer swap is a no-op today)', () {
    test('every card with no authored set returns EXACTLY the per-manual '
        'terms, and the covered/uncovered split accounts for every card',
        () {
      var fellBack = 0;
      var covered = 0;
      for (final unitId in cards.keys) {
        final authored = kBarrioCardKeysByUnit[unitId];
        if (authored != null && authored.isNotEmpty) {
          covered++;
          continue;
        }
        fellBack++;
        expect(barrioCardKeysForUnit(unitId), barrioKeyTermsForUnit(unitId),
            reason: 'uncovered card $unitId must render the per-manual list '
                'unchanged (this is the whole regression guarantee)');
      }
      expect(fellBack + covered, cards.length,
          reason: 'every rendered card is either authored or falls back');
    });

    test('with the registry empty, EVERY card in the corpus takes the '
        'fallback (self-disables once authoring starts)', () {
      if (kBarrioCardKeysByUnit.isNotEmpty) {
        // Data has landed; the permanent per-card law above covers it.
        return;
      }
      for (final entry in cards.entries) {
        expect(barrioCardKeysForUnit(entry.key), barrioKeyTermsForUnit(entry.key),
            reason: '${entry.key} must be byte-identical before and after '
                'the lookup swap');
      }
    });

    test('a curated doc still highlights and an uncurated doc still does '
        'not (both docs picked at runtime, never hard-coded)', () {
      final curated = cards.values.firstWhere(
          (c) => barrioKeyTermsForUnit(c.unit.id).isNotEmpty,
          orElse: () => throw StateError('no curated doc in the corpus'));
      final uncurated = cards.values.firstWhere(
          (c) => barrioKeyTermsForUnit(c.unit.id).isEmpty,
          orElse: () => throw StateError('no uncurated doc in the corpus'));

      expect(barrioCardKeysForUnit(curated.unit.id), isNotEmpty,
          reason: '${curated.docId} is curated: it must still get terms');
      expect(barrioCardKeysForUnit(uncurated.unit.id), isEmpty,
          reason: '${uncurated.docId} is uncurated: it must stay unhighlighted');
    });

    test('unknown and empty unit ids stay empty (no crash, no highlight)',
        () {
      expect(barrioCardKeysForUnit(''), isEmpty);
      expect(barrioCardKeysForUnit('no_such_doc_c0_u0'), isEmpty);
    });
  });

  group('authoring contract (quiet on empty data, hard-binding once authored)',
      () {
    test('every registry key resolves to a real card in kBarrioTrainingDocs',
        () {
      for (final unitId in kBarrioCardKeysByUnit.keys) {
        expect(cards.containsKey(unitId), isTrue,
            reason: '$unitId is not a rendered unit id');
      }
    });

    test('cardinality: 3 to kBarrioKeyTermCardCap phrases per card', () {
      for (final entry in kBarrioCardKeysByUnit.entries) {
        expect(entry.value.length, inInclusiveRange(3, kBarrioKeyTermCardCap),
            reason: '${entry.key} has ${entry.value.length} phrases');
        expect(entry.value.toSet(), hasLength(entry.value.length),
            reason: '${entry.key} repeats a phrase');
      }
    });

    test('verbatim: every phrase matches whole-word inside its OWN card body',
        () {
      for (final entry in kBarrioCardKeysByUnit.entries) {
        final card = cards[entry.key];
        if (card == null) continue; // reported by the key-validity guard
        for (final phrase in entry.value) {
          expect(_soloHit(card.unit.body, phrase), isNotNull,
              reason: '"$phrase" never matches in ${entry.key}');
        }
      }
    });

    test('one chunk: no phrase straddles a paragraph or a table cell', () {
      for (final entry in kBarrioCardKeysByUnit.entries) {
        for (final phrase in entry.value) {
          expect(phrase.contains('\n'), isFalse,
              reason: '"$phrase" (${entry.key}) spans a line break');
          expect(phrase.contains(' | '), isFalse,
              reason: '"$phrase" (${entry.key}) spans a table cell boundary');
          expect(phrase.trim(), phrase,
              reason: '"$phrase" (${entry.key}) has edge whitespace');
        }
      }
    });

    test('non-overlap: two phrases on one card never claim the same words',
        () {
      for (final entry in kBarrioCardKeysByUnit.entries) {
        final card = cards[entry.key];
        if (card == null) continue;
        expect(_overlappingPairs(card.unit.body, entry.value), isEmpty,
            reason: '${entry.key} fragments its own body (the "average '
                'guest" + "guest check" failure shape)');
        // Belt and braces: with the real threading, every authored phrase
        // actually renders. A short result means one was dropped.
        expect(_renderedPhrases(card.unit.body, entry.value),
            hasLength(entry.value.length),
            reason: '${entry.key}: a phrase would not render');
      }
    });

    test('reading order: phrases are listed in body position order', () {
      for (final entry in kBarrioCardKeysByUnit.entries) {
        final card = cards[entry.key];
        if (card == null) continue;
        var lastChunk = -1;
        var lastStart = -1;
        for (final phrase in entry.value) {
          final hit = _soloHit(card.unit.body, phrase);
          if (hit == null) continue; // reported by the verbatim guard
          final inOrder = hit.chunk > lastChunk ||
              (hit.chunk == lastChunk && hit.start > lastStart);
          expect(inOrder, isTrue,
              reason: '${entry.key}: "$phrase" is out of reading order');
          lastChunk = hit.chunk;
          lastStart = hit.start;
        }
      }
    });

    test('no digits: numbers belong to the numeric-pop tier, not this one',
        () {
      final digit = RegExp(r'\d');
      for (final entry in kBarrioCardKeysByUnit.entries) {
        for (final phrase in entry.value) {
          expect(digit.hasMatch(phrase), isFalse,
              reason: '"$phrase" (${entry.key}) carries a numeric fact token; '
                  'the numeric tier already owns numbers');
        }
      }
    });

    test('no em dash inside a phrase (UX no-em-dash law)', () {
      for (final entry in kBarrioCardKeysByUnit.entries) {
        for (final phrase in entry.value) {
          expect(phrase.contains('—'), isFalse,
              reason: '"$phrase" (${entry.key}) contains an em dash');
        }
      }
    });

    test('no boilerplate: never a doc, chapter, or card title, never the '
        'brand name alone', () {
      for (final entry in kBarrioCardKeysByUnit.entries) {
        final card = cards[entry.key];
        if (card == null) continue;
        final banned = _boilerplateFor(card);
        for (final phrase in entry.value) {
          expect(banned.contains(phrase.toLowerCase().trim()), isFalse,
              reason: '"$phrase" (${entry.key}) is boilerplate, not teaching');
        }
      }
    });

    test('no teal-on-teal: a phrase never collides with that card\'s quiz '
        'answer evidence', () {
      for (final entry in kBarrioCardKeysByUnit.entries) {
        final card = cards[entry.key];
        if (card == null) continue;
        final evidence = barrioAnswerEvidenceForUnit(entry.key);
        if (evidence.isEmpty) continue;
        final answerHits = _answerHits(card.unit.body, evidence);
        for (final phrase in entry.value) {
          final hit = _soloHit(card.unit.body, phrase);
          if (hit == null) continue;
          expect(answerHits.any(hit.intersects), isFalse,
              reason: '"$phrase" (${entry.key}) overlaps quiz answer '
                  'evidence; the answer tier outranks it and would drop it');
        }
      }
    });
  });

  group('coverage ratchet', () {
    test('authored cards never go backwards', () {
      final covered = kBarrioCardKeysByUnit.keys
          .where((id) =>
              cards.containsKey(id) && kBarrioCardKeysByUnit[id]!.isNotEmpty)
          .length;
      final highlightable = cards.values
          .where((c) => barrioKeyTermsForUnit(c.unit.id).isNotEmpty)
          .length;
      final pct = cards.isEmpty ? 0 : (covered * 100 / cards.length).round();
      debugPrint('BARRIO CARD KEYS COVERAGE: $covered of ${cards.length} '
          'rendered cards authored ($pct%); $highlightable cards are in '
          'curated (highlighting) manuals; floor is '
          '$kBarrioCardKeysCoverageFloor.');
      expect(covered, greaterThanOrEqualTo(kBarrioCardKeysCoverageFloor),
          reason: 'coverage fell below the ratchet floor: raise the data back '
              'up, do not lower the floor');
    });
  });

  group('the guards themselves work (synthetic fixtures, not corpus data)',
      () {
    // Authored here rather than sampled from the corpus so a content
    // regeneration can never change what these prove.
    const body = 'The average guest check is total sales divided by the '
        'cover count.\n\nA higher figure lifts revenue with no extra covers.';

    test('overlap detector catches the real fragmentation shape', () {
      expect(_overlappingPairs(body, ['average guest', 'guest check']),
          isNotEmpty,
          reason: 'the two phrases claim the same words in "average guest '
              'check"');
      expect(_renderedPhrases(body, ['average guest', 'guest check']),
          hasLength(1),
          reason: 'only one of the colliding pair would ever render');
    });

    test('a clean, non-overlapping, in-order set passes every mechanical '
        'guard', () {
      const good = ['average guest check', 'total sales', 'cover count'];
      expect(_overlappingPairs(body, good), isEmpty);
      expect(_renderedPhrases(body, good), hasLength(good.length));
      var lastStart = -1;
      for (final phrase in good) {
        final hit = _soloHit(body, phrase)!;
        expect(hit.chunk, 0);
        expect(hit.start, greaterThan(lastStart));
        lastStart = hit.start;
      }
    });

    test('a phrase absent from the body is rejected', () {
      expect(_soloHit(body, 'labor percentage'), isNull);
      // Whole-word: a phrase inside a longer word does not count.
      expect(_soloHit(body, 'cove'), isNull);
    });

    test('a phrase straddling the chunk boundary never renders', () {
      expect(_soloHit(body, 'cover count. A higher'), isNull,
          reason: 'the card renders the two paragraphs as separate chunks');
    });

    test('reading-order and chunk helpers see the second paragraph', () {
      final hit = _soloHit(body, 'extra covers')!;
      expect(hit.chunk, 1, reason: 'the phrase lives in the second chunk');
    });
  });
}
