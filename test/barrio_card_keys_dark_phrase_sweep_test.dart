// Corpus-wide dark-phrase sweep: does every authored per-card key phrase
// in `kBarrioCardKeysByUnit` actually put ink on the screen?
//
// WHY THIS EXISTS
//
// A key phrase that carries no digits can still render NOTHING. The
// numeric-pop tier claims a number token TOGETHER WITH ITS UNIT WORD
// ('59 to 77 degrees Fahrenheit' is one span), and the key-term tier is
// the lowest of the five, so a digit-free phrase like 'Fahrenheit for
// Arabica' that reaches into that span is dropped WHOLE and silently.
// The same silent drop happens against a tap-to-define term link, a quiz
// answer-evidence span, and a sibling phrase on the same card.
//
// `test/barrio_card_key_sets_test.dart` is the corpus-wide contract test
// and it stays GREEN against exactly that bug: it chunks with the naive
// `body.split('\n\n')` rather than the render-space `chunksForBody`, it
// never builds the numeric, term-link or answer tiers at all, and it
// enforces the blunt "no digits in the phrase" rule, which is necessary
// and not sufficient. Three later guards DO run the real pipeline, but
// each is scoped to the manuals its own slice authored:
//
//   * `barrio_card_keys_latin_push_test.dart`: latin dishes, latin
//     ingredients, push SOP. Its own header says widening the stricter
//     checks to "the other 1,070 already-landed phrases is a different
//     slice".
//   * `barrio_words_clover_card_keys_render_test.dart`: general words,
//     Clover SOP.
//   * `barrio_culinary_card_keys_render_test.dart`: menu deck, coffee,
//     tequila, drink specs.
//
// (`barrio_wine_card_keys_render_test.dart` covers wine, but only for
// answer evidence plus a widget sample; it never builds the numeric
// tier, so wine's phrases reach the numeric trap for the first time
// here.)
//
// This file is that different slice: EVERY entry in
// `kBarrioCardKeysByUnit`, every manual, through the shipped matchers.
//
// NO REIMPLEMENTED MATCHERS
//
// Every step below calls the deployed code:
//   * `chunksForBody` for render-space chunking (bullet markers
//     stripped, numbered markers dropped, table cells split and
//     trimmed),
//   * `BarrioTermLinks.matchesIn` with the `alreadyLinked` set threaded
//     across a card's chunks, gated on `kHostManualIds` exactly as
//     `training_doc_screen.dart` gates `onTermTap`,
//   * `BarrioNumericHighlight.matchesIn`,
//   * `barrioAnswerEvidenceForUnit`, matched the way
//     `_answerEvidenceRanges` matches it (verbatim, case-sensitive
//     `indexOf`, every occurrence),
//   * `BarrioKeyTermHighlight.matchesIn` with the deployed
//     `kBarrioKeyTermCardCap` and the `alreadyUsed` set threaded across
//     the card's chunks,
//   * `BarrioTrainingSearch.fold` for the rendered/dark bookkeeping, so
//     "did it render" is decided by the same folded-term identity the
//     matcher itself uses.
// A hand-rolled regex would give a confidently wrong number, which is
// worse than not measuring.
//
// HOW THIS FILE AVOIDS PASSING WHILE CHECKING NOTHING
//
//   1. SCOPE. Manuals, cards and phrases each have a pinned floor, and
//      the per-manual floors come from the sibling guards' own shipped
//      numbers ([_kSiblingGuardCardFloors]), fixed by other slices in
//      other files against other assertions. A broken walk cannot move
//      them.
//   2. TIER LIVENESS. Each of the three content tiers is asserted to
//      claim a non-zero number of spans on authored cards, and the
//      numeric tier is additionally asserted to reach past its digits
//      into a digit-free unit word somewhere in the corpus. A sweep
//      whose tiers were silently empty would report zero dark phrases
//      for the wrong reason; that is the exact shape of guard this repo
//      shipped three of this week.
//   3. INJECTION. The last group feeds deliberately dark phrases through
//      [_darkIn], the SAME function the corpus walk calls, and asserts
//      each comes back attributed to the right tier: the canonical
//      `Fahrenheit for Arabica` numeric shape, a term link, an answer
//      span, a sibling collision, and an absent phrase. Every fixture is
//      built at runtime from real corpus content.
//   4. POSITIVE CONTROL. A phrase clear of every tier is asserted to
//      survive, so the injections above are not passing because the
//      sweep rejects everything.
//
// House rule followed throughout: nothing about the corpus is hard-coded
// except the pinned floors, which are ratchets.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/barrio_body_chunks.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/barrio_key_terms.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/cards/barrio_card_keys_index.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_numeric_highlight.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_term_links.dart';

/// Which tier swallowed a phrase, in the precedence order the card
/// applies them (`handbook_lesson_card.dart` `_composeChunk`).
enum _Killer {
  /// The phrase never whole-word matches in ANY render-space chunk.
  noMatch,

  /// A tap-to-define term link claimed those characters.
  termLink,

  /// A numeric fact token claimed them (this is the digit-free trap).
  numeric,

  /// Quiz answer evidence claimed them.
  answer,

  /// An earlier phrase on the same card claimed them.
  sibling,

  /// The card already emphasized [kBarrioKeyTermCardCap] spans.
  cap,
}

/// One authored phrase that renders nothing, and why.
class _Dark {
  final String docId;
  final String unitId;
  final String phrase;
  final _Killer killer;

  /// The span that swallowed it, for the repair note. Empty for
  /// [_Killer.noMatch] and [_Killer.cap].
  final String blocker;

  const _Dark(this.docId, this.unitId, this.phrase, this.killer, this.blocker);

  @override
  String toString() => '$unitId :: "$phrase" -> ${killer.name}'
      '${blocker.isEmpty ? '' : ' (blocked by "$blocker")'}';
}

/// The higher-tier ranges of one render-space chunk, already threaded.
class _ChunkTiers {
  final String text;
  final List<List<int>> terms;
  final List<List<int>> numerics;
  final List<List<int>> answers;
  const _ChunkTiers(this.text, this.terms, this.numerics, this.answers);

  /// Every range that outranks a key phrase in this chunk.
  List<List<int>> get higher => <List<int>>[...terms, ...numerics, ...answers];
}

bool _hits(int start, int end, List<List<int>> ranges) {
  for (final r in ranges) {
    if (start < r[1] && end > r[0]) return true;
  }
  return false;
}

/// The four higher tiers of one card, chunk by chunk, exactly as
/// `_composeChunk` builds them and in the same order.
///
/// The search wash is the fifth and highest tier. It is empty here on
/// purpose: the sweep measures the card AT REST, the state the reader is
/// in whenever they are not mid-search, and a live search only ever
/// blocks MORE. A phrase dark at rest is dark always.
List<_ChunkTiers> _tiersOf(String docId, HandbookUnit unit) {
  final evidence = barrioAnswerEvidenceForUnit(unit.id);
  // `training_doc_screen.dart` passes `onTermTap` only for these doc
  // ids, and a null `onTermTap` switches the whole tier off.
  final isHost = BarrioTermLinks.kHostManualIds.contains(docId);
  final linked = <String>{};
  final out = <_ChunkTiers>[];
  for (final chunk in chunksForBody(unit.body)) {
    final text = chunk.text;
    final terms = <List<int>>[
      if (isHost)
        for (final t in BarrioTermLinks.matchesIn(text, alreadyLinked: linked))
          <int>[t.start, t.end],
    ];
    final numerics = <List<int>>[
      for (final n
          in BarrioNumericHighlight.matchesIn(text, blockedRanges: terms))
        <int>[n.start, n.end],
    ];
    final higher = <List<int>>[...terms, ...numerics];
    // `_answerEvidenceRanges`: verbatim substrings, plain case-sensitive
    // `indexOf`, EVERY occurrence, each dropped whole if it hits a
    // higher tier.
    final answers = <List<int>>[];
    for (final phrase in evidence) {
      if (phrase.isEmpty) continue;
      var idx = text.indexOf(phrase);
      while (idx >= 0) {
        if (!_hits(idx, idx + phrase.length, higher)) {
          answers.add(<int>[idx, idx + phrase.length]);
        }
        idx = text.indexOf(phrase, idx + phrase.length);
      }
    }
    out.add(_ChunkTiers(text, terms, numerics, answers));
  }
  return out;
}

/// One card's key-term pass: what rendered, and where.
class _RenderPass {
  /// The folded terms that really put ink on the screen. Folded, not
  /// lower-cased, because that is the identity
  /// [BarrioKeyTermHighlight] itself books against.
  final Set<String> renderedFolded = <String>{};

  /// Accepted key-term ranges per chunk index, for sibling attribution.
  final Map<int, List<List<int>>> acceptedByChunk = <int, List<List<int>>>{};

  /// `alreadyUsed` size at the moment each chunk started, so a
  /// cap-induced drop can be told apart from an overlap-induced one.
  final List<int> usedAtChunkStart = <int>[];
}

/// A faithful replay of `_composeChunk`'s key-term tier: the same
/// `blockedRanges`, the same `alreadyUsed` set carried across the card's
/// chunks in reading order, and the deployed [kBarrioKeyTermCardCap].
_RenderPass _renderPass(List<_ChunkTiers> tiers, List<String> phrases) {
  final pass = _RenderPass();
  final used = <String>{};
  for (var c = 0; c < tiers.length; c++) {
    pass.usedAtChunkStart.add(used.length);
    final matches = BarrioKeyTermHighlight.matchesIn(
      tiers[c].text,
      phrases,
      alreadyUsed: used,
      blockedRanges: tiers[c].higher,
    );
    for (final m in matches) {
      pass.renderedFolded.add(m.foldedTerm);
      (pass.acceptedByChunk[c] ??= <List<int>>[]).add(<int>[m.start, m.end]);
    }
  }
  return pass;
}

/// Every phrase of [phrases] that renders nothing on [unit], with the
/// tier that killed it.
///
/// A phrase is dark when NO chunk of the card renders it. Attribution
/// walks the chunks in reading order and reports the reason at the first
/// chunk where the deployed matcher would have offered a candidate: that
/// is the first place the card tried and failed. (A blocked key-term
/// candidate is NOT consumed, so the card keeps trying later chunks; a
/// dark phrase is therefore one that lost in every chunk that offered
/// it.)
List<_Dark> _darkIn(String docId, HandbookUnit unit, List<String> phrases) {
  if (phrases.isEmpty) return const <_Dark>[];
  final tiers = _tiersOf(docId, unit);
  final pass = _renderPass(tiers, phrases);
  final dark = <_Dark>[];
  for (final phrase in phrases) {
    final folded = BarrioTrainingSearch.fold(phrase.trim());
    if (pass.renderedFolded.contains(folded)) continue;
    dark.add(_attribute(docId, unit, phrase, tiers, pass));
  }
  return dark;
}

/// The authored phrases of [unit] that render nothing.
List<_Dark> _darkPhrasesOf(String docId, HandbookUnit unit) => _darkIn(
      docId,
      unit,
      kBarrioCardKeysByUnit[unit.id] ?? const <String>[],
    );

_Dark _attribute(
  String docId,
  HandbookUnit unit,
  String phrase,
  List<_ChunkTiers> tiers,
  _RenderPass pass,
) {
  for (var c = 0; c < tiers.length; c++) {
    // The deployed matcher, unblocked, offers at most ONE candidate per
    // chunk: the phrase's first whole-word occurrence there. That is
    // exactly the position the real pass tried.
    final solo = BarrioKeyTermHighlight.matchesIn(
      tiers[c].text,
      <String>[phrase],
      alreadyUsed: <String>{},
      maxPerCard: 1,
    );
    if (solo.isEmpty) continue;
    final start = solo.first.start;
    final end = solo.first.end;
    String blocker(List<List<int>> ranges) {
      for (final r in ranges) {
        if (start < r[1] && end > r[0]) {
          return tiers[c].text.substring(r[0], r[1]);
        }
      }
      return '';
    }

    if (_hits(start, end, tiers[c].terms)) {
      return _Dark(
          docId, unit.id, phrase, _Killer.termLink, blocker(tiers[c].terms));
    }
    if (_hits(start, end, tiers[c].numerics)) {
      return _Dark(
          docId, unit.id, phrase, _Killer.numeric, blocker(tiers[c].numerics));
    }
    if (_hits(start, end, tiers[c].answers)) {
      return _Dark(
          docId, unit.id, phrase, _Killer.answer, blocker(tiers[c].answers));
    }
    final accepted = pass.acceptedByChunk[c] ?? const <List<int>>[];
    if (_hits(start, end, accepted)) {
      return _Dark(docId, unit.id, phrase, _Killer.sibling, blocker(accepted));
    }
    if (pass.usedAtChunkStart[c] >= kBarrioKeyTermCardCap) {
      return _Dark(docId, unit.id, phrase, _Killer.cap, '');
    }
  }
  return _Dark(docId, unit.id, phrase, _Killer.noMatch, '');
}

/// Every card in the corpus that carries an authored phrase set, grouped
/// by the doc id that owns it. Derived at runtime from
/// [kBarrioTrainingDocs]: no doc id, unit id, or count is hard-coded.
Map<String, List<HandbookUnit>> _authoredCardsByDoc() {
  final out = <String, List<HandbookUnit>>{};
  for (final entry in kBarrioTrainingDocs.entries) {
    for (final chapter in entry.value.chapters) {
      for (final unit in chapter.units) {
        if ((kBarrioCardKeysByUnit[unit.id] ?? const <String>[]).isEmpty) {
          continue;
        }
        (out[entry.key] ??= <HandbookUnit>[]).add(unit);
      }
    }
  }
  return out;
}

/// Shipped per-manual coverage floors, copied from the sibling guards
/// that own each manual. This is the INDEPENDENT anchor for "the walk
/// visited real data": the numbers were fixed by other slices, in other
/// files, against other assertions, so a bug in this file's walk cannot
/// move them.
///
///   * `barrio_culinary_card_keys_render_test.dart` `_culinaryFloors`
///   * `barrio_words_clover_card_keys_render_test.dart` `_kDocFloors`
///   * `barrio_wine_card_keys_render_test.dart` (wine floor, 200)
const Map<String, int> _kSiblingGuardCardFloors = <String, int>{
  'training_menu_concept': 21,
  'training_coffee': 27,
  'training_tequila': 16,
  'training_drink_specs': 16,
  'training_general_words': 68,
  'training_clover_sop': 47,
  'training_wine': 200,
};

/// The manuals a sibling guard already sweeps through the real pipeline.
/// Used only for the reporting split ("first time through the full
/// pipeline"), never to skip anything: this file sweeps all 24.
const Set<String> _kSiblingSweptManuals = <String>{
  'training_latin_dishes',
  'training_latin_ingredients',
  'training_push_sop',
  'training_general_words',
  'training_clover_sop',
  'training_menu_concept',
  'training_coffee',
  'training_tequila',
  'training_drink_specs',
};

/// Ratchets for the walk itself. Falling-only: raise them as the corpus
/// grows, never lower one to turn a red run green.
const int _kMinManualsWalked = 20;
const int _kMinCardsWalked = 1300;
const int _kMinPhrasesWalked = 6600;

/// The first authored card whose numeric span reaches PAST its digits
/// into a digit-free unit word, plus the phrase that shape produces.
/// This is the `Fahrenheit for Arabica` fixture, built from real content
/// so it cannot drift into a synthetic that the deployed matcher would
/// never see.
class _NumericTrap {
  final String docId;
  final HandbookUnit unit;
  final String chunkText;
  final String span;

  /// A digit-free phrase that starts on the span's unit word. Whole-word
  /// matchable, and it reaches into the numeric span, so the numeric
  /// tier must drop it whole.
  final String phrase;

  const _NumericTrap(
      this.docId, this.unit, this.chunkText, this.span, this.phrase);
}

final RegExp _digit = RegExp(r'\d');

/// Builds the numeric trap fixture from the corpus, or null if the
/// corpus offers none (the caller fails loudly rather than skipping).
_NumericTrap? _findNumericTrap(Map<String, List<HandbookUnit>> byDoc) {
  for (final docId in byDoc.keys) {
    for (final unit in byDoc[docId]!) {
      for (final tiers in _tiersOf(docId, unit)) {
        for (final range in tiers.numerics) {
          final text = tiers.text;
          final span = text.substring(range[0], range[1]);
          // The unit word is whatever follows the span's last separator.
          final sep = span.lastIndexOf(RegExp(r'[\s-]'));
          if (sep < 0) continue;
          final unitStart = range[0] + sep + 1;
          final unitWord = text.substring(unitStart, range[1]);
          if (_digit.hasMatch(unitWord)) continue;
          if (unitWord.replaceAll(RegExp('[^A-Za-z]'), '').length < 4) continue;
          // Extend past the span by one or two words, so the phrase
          // straddles the span edge exactly like 'Fahrenheit for
          // Arabica' does, rather than merely sitting inside it.
          final after = RegExp(r'^(?:\s+[A-Za-z]+){1,2}')
              .firstMatch(text.substring(range[1]));
          final phrase = after == null
              ? unitWord
              : text.substring(unitStart, range[1] + after.end);
          if (_digit.hasMatch(phrase)) continue;
          return _NumericTrap(docId, unit, text, span, phrase);
        }
      }
    }
  }
  return null;
}

void main() {
  final byDoc = _authoredCardsByDoc();
  final docIds = byDoc.keys.toList()..sort();

  group('the sweep visited real data (a guard that checks nothing passes)',
      () {
    test('manuals, cards, and phrases all clear their pinned floors', () {
      var cards = 0;
      var phrases = 0;
      var firstSweptCards = 0;
      var firstSweptPhrases = 0;
      for (final docId in docIds) {
        for (final unit in byDoc[docId]!) {
          final n = kBarrioCardKeysByUnit[unit.id]!.length;
          cards++;
          phrases += n;
          if (!_kSiblingSweptManuals.contains(docId)) {
            firstSweptCards++;
            firstSweptPhrases += n;
          }
        }
      }
      debugPrint('BARRIO DARK SWEEP SCOPE: ${docIds.length} manuals, '
          '$cards authored cards, $phrases authored phrases. Of those, '
          '$firstSweptPhrases phrases on $firstSweptCards cards across '
          '${docIds.length - _kSiblingSweptManuals.length} manuals reach the '
          'full five-tier pipeline for the first time here.');
      expect(docIds.length, greaterThanOrEqualTo(_kMinManualsWalked),
          reason: 'the walk found only ${docIds.length} manuals with authored '
              'phrases; it is not seeing the corpus');
      expect(cards, greaterThanOrEqualTo(_kMinCardsWalked));
      expect(phrases, greaterThanOrEqualTo(_kMinPhrasesWalked));
      expect(firstSweptPhrases, greaterThan(0),
          reason: 'this file exists to cover the manuals the sibling guards '
              'do not; if that set is empty it has nothing left to add');
    });

    test('every manual the sibling guards pinned is present at its own '
        'shipped floor', () {
      for (final entry in _kSiblingGuardCardFloors.entries) {
        final units = byDoc[entry.key] ?? const <HandbookUnit>[];
        expect(units.length, greaterThanOrEqualTo(entry.value),
            reason: '${entry.key}: this sweep sees ${units.length} authored '
                'cards but the guard that owns that manual pins '
                '${entry.value}. Either coverage fell or this walk is broken.');
      }
    });

    test('every authored unit id resolves to a rendered card, so nothing is '
        'silently skipped', () {
      final rendered = <String>{
        for (final doc in kBarrioTrainingDocs.values)
          for (final chapter in doc.chapters)
            for (final unit in chapter.units) unit.id,
      };
      for (final unitId in kBarrioCardKeysByUnit.keys) {
        expect(rendered.contains(unitId), isTrue,
            reason: '$unitId is authored but never rendered');
      }
      final walked = <String>{
        for (final units in byDoc.values)
          for (final unit in units) unit.id,
      };
      expect(walked.length, kBarrioCardKeysByUnit.length,
          reason: 'the walk must visit every authored entry exactly once');
    });
  });

  group('the tiers are LIVE in this sweep (not silently empty)', () {
    late int termSpans;
    late int numericSpans;
    late int answerSpans;
    late int chunks;
    late int abuttingNumeric;

    setUpAll(() {
      termSpans = 0;
      numericSpans = 0;
      answerSpans = 0;
      chunks = 0;
      abuttingNumeric = 0;
      for (final docId in docIds) {
        for (final unit in byDoc[docId]!) {
          final phrases = kBarrioCardKeysByUnit[unit.id]!;
          for (final t in _tiersOf(docId, unit)) {
            chunks++;
            termSpans += t.terms.length;
            numericSpans += t.numerics.length;
            answerSpans += t.answers.length;
            if (t.numerics.isEmpty) continue;
            // How close the corpus actually comes: an authored phrase
            // whose span stops within two characters of a numeric span.
            // One word of authoring drift and it would be dark.
            for (final phrase in phrases) {
              final solo = BarrioKeyTermHighlight.matchesIn(
                  t.text, <String>[phrase],
                  alreadyUsed: <String>{}, maxPerCard: 1);
              if (solo.isEmpty) continue;
              for (final n in t.numerics) {
                final gap = solo.first.start >= n[1]
                    ? solo.first.start - n[1]
                    : (solo.first.end <= n[0] ? n[0] - solo.first.end : -1);
                if (gap >= 0 && gap <= 2) abuttingNumeric++;
              }
            }
          }
        }
      }
      debugPrint('BARRIO DARK SWEEP TIERS: over $chunks render-space chunks '
          'the tiers claimed $termSpans term links, $numericSpans numeric '
          'pops, $answerSpans answer-evidence spans; $abuttingNumeric '
          'authored phrases stop within two characters of a numeric span.');
    });

    test('the sweep sees render-space chunks, not one blob per card', () {
      expect(chunks, greaterThan(_kMinCardsWalked),
          reason: 'fewer chunks than cards means chunksForBody is not being '
              'walked');
    });

    test('the term-link tier claims spans on authored host-manual cards', () {
      expect(termSpans, greaterThan(0),
          reason: 'no term link anywhere: either kHostManualIds stopped '
              'matching the doc ids or the tier is switched off in this sweep, '
              'and every termLink attribution below is unreachable');
    });

    test('the numeric tier claims spans on authored cards', () {
      expect(numericSpans, greaterThan(0),
          reason: 'no numeric pop anywhere: the trap this file exists to catch '
              'could not fire');
    });

    test('numeric spans really do sit right beside authored phrases, so a '
        'clean sweep is a result and not an absence of contact', () {
      expect(abuttingNumeric, greaterThan(0),
          reason: 'not one authored phrase in the corpus comes within two '
              'characters of a numeric span. Either the recipe and '
              'temperature manuals stopped carrying numbers or this walk is '
              'not reaching them, and "zero dark phrases" would mean nothing.');
    });

    test('the answer-evidence tier claims spans on authored cards', () {
      expect(answerSpans, greaterThan(0),
          reason: 'no answer evidence anywhere on an authored card');
    });
  });

  group('every authored phrase in the corpus renders (per manual)', () {
    for (final docId in docIds) {
      test('$docId: no phrase is dark', () {
        final dark = <_Dark>[
          for (final unit in byDoc[docId]!) ..._darkPhrasesOf(docId, unit),
        ];
        expect(dark, isEmpty,
            reason: '$docId: ${dark.length} authored phrase(s) render NOTHING. '
                'A phrase that loses to a higher tier is dropped WHOLE and the '
                'card silently loses that teaching:\n${dark.join('\n')}');
      });
    }
  });

  group('corpus total', () {
    test('the whole authored corpus is dark-free, with a per-tier report', () {
      final dark = <_Dark>[];
      var phrases = 0;
      for (final docId in docIds) {
        for (final unit in byDoc[docId]!) {
          phrases += kBarrioCardKeysByUnit[unit.id]!.length;
          dark.addAll(_darkPhrasesOf(docId, unit));
        }
      }
      final byKiller = <_Killer, int>{};
      final byManual = <String, int>{};
      for (final d in dark) {
        byKiller[d.killer] = (byKiller[d.killer] ?? 0) + 1;
        byManual[d.docId] = (byManual[d.docId] ?? 0) + 1;
      }
      debugPrint('BARRIO DARK SWEEP RESULT: ${dark.length} of $phrases '
          'authored phrases render nothing.');
      for (final e in byManual.entries) {
        debugPrint('  manual ${e.key}: ${e.value}');
      }
      for (final e in byKiller.entries) {
        debugPrint('  tier ${e.key.name}: ${e.value}');
      }
      for (final d in dark) {
        debugPrint('  $d');
      }
      expect(dark, isEmpty,
          reason: '${dark.length} authored phrases across the corpus render '
              'nothing. Re-author or drop them:\n${dark.join('\n')}');
    });
  });

  group('the sweep can go RED (injected dark phrases, real corpus content)',
      () {
    // Every fixture below goes through [_darkIn], the SAME function the
    // corpus walk calls, so these prove the walk itself, not a parallel
    // copy of it.

    test('the canonical numeric trap: a DIGIT-FREE phrase reaching into a '
        'numeric span is reported dark, attributed to the numeric tier', () {
      final trap = _findNumericTrap(byDoc);
      expect(trap, isNotNull,
          reason: 'no authored card has a numeric span reaching a digit-free '
              'unit word, so the trap this whole file is about has nothing to '
              'run on. Investigate before deleting this assertion.');
      final t = trap!;
      debugPrint('BARRIO DARK SWEEP INJECTION (numeric): ${t.unit.id} span '
          '"${t.span}" swallows the digit-free phrase "${t.phrase}".');
      expect(_digit.hasMatch(t.phrase), isFalse,
          reason: 'the fixture must carry no digits, or it would be caught by '
              'the existing no-digits rule and prove nothing new');
      // Sanity: unblocked, this phrase really would render. Without this
      // the assertion below would also pass on a phrase that simply does
      // not match.
      expect(
        BarrioKeyTermHighlight.matchesIn(t.chunkText, <String>[t.phrase],
            alreadyUsed: <String>{}),
        isNotEmpty,
        reason: '"${t.phrase}" must match its own chunk when nothing blocks it',
      );
      final dark = _darkIn(t.docId, t.unit, <String>[t.phrase]);
      expect(dark, hasLength(1),
          reason: '"${t.phrase}" must come back dark from the real walk');
      expect(dark.single.killer, _Killer.numeric);
      expect(dark.single.blocker, t.span);
    });

    test('a phrase laid over a real term link is reported dark, attributed '
        'to the term-link tier', () {
      String? docId;
      HandbookUnit? unit;
      String? phrase;
      outer:
      for (final id in docIds) {
        if (!BarrioTermLinks.kHostManualIds.contains(id)) continue;
        for (final u in byDoc[id]!) {
          for (final t in _tiersOf(id, u)) {
            for (final r in t.terms) {
              docId = id;
              unit = u;
              phrase = t.text.substring(r[0], r[1]);
              break outer;
            }
          }
        }
      }
      expect(phrase, isNotNull,
          reason: 'no authored host-manual card carries a term link; the '
              'term-link attribution branch is unreachable');
      final dark = _darkIn(docId!, unit!, <String>[phrase!]);
      debugPrint('BARRIO DARK SWEEP INJECTION (term link): ${unit.id} '
          '"$phrase".');
      expect(dark, hasLength(1));
      expect(dark.single.killer, _Killer.termLink);
    });

    test('a phrase laid over real quiz answer evidence is reported dark, '
        'attributed to the answer tier', () {
      String? docId;
      HandbookUnit? unit;
      String? phrase;
      outer:
      for (final id in docIds) {
        for (final u in byDoc[id]!) {
          for (final t in _tiersOf(id, u)) {
            for (final r in t.answers) {
              final candidate = t.text.substring(r[0], r[1]);
              // Must be whole-word matchable on its own, or the phrase
              // would be reported noMatch instead of answer.
              final solo = BarrioKeyTermHighlight.matchesIn(
                  t.text, <String>[candidate],
                  alreadyUsed: <String>{}, maxPerCard: 1);
              if (solo.isEmpty || solo.first.start != r[0]) continue;
              docId = id;
              unit = u;
              phrase = candidate;
              break outer;
            }
          }
        }
      }
      expect(phrase, isNotNull,
          reason: 'no authored card carries a word-aligned answer-evidence '
              'span; the answer attribution branch is unreachable');
      final dark = _darkIn(docId!, unit!, <String>[phrase!]);
      debugPrint('BARRIO DARK SWEEP INJECTION (answer): ${unit.id} '
          '"$phrase".');
      expect(dark, hasLength(1));
      expect(dark.single.killer, _Killer.answer);
    });

    test('two phrases claiming the same words: the loser is reported dark, '
        'attributed to the sibling tier', () {
      // 'A B' plus 'B C' over a real three-word run, the shape the
      // per-manual lists produce ('average guest' + 'guest check').
      String? docId;
      HandbookUnit? unit;
      List<String>? pair;
      outer:
      for (final id in docIds) {
        for (final u in byDoc[id]!) {
          for (final t in _tiersOf(id, u)) {
            if (t.higher.isNotEmpty) continue; // keep the fixture clean
            final words = RegExp('[A-Za-z]{4,}').allMatches(t.text).toList();
            for (var i = 0; i + 2 < words.length; i++) {
              // Consecutive in the source, so 'A B' and 'B C' really do
              // overlap on B.
              if (words[i + 1].start != words[i].end + 1) continue;
              if (words[i + 2].start != words[i + 1].end + 1) continue;
              final ab = t.text.substring(words[i].start, words[i + 1].end);
              final bc =
                  t.text.substring(words[i + 1].start, words[i + 2].end);
              docId = id;
              unit = u;
              pair = <String>[ab, bc];
              break outer;
            }
          }
        }
      }
      expect(pair, isNotNull,
          reason: 'no authored card offers three consecutive words to build '
              'the overlap fixture from');
      final dark = _darkIn(docId!, unit!, pair!);
      debugPrint('BARRIO DARK SWEEP INJECTION (sibling): ${unit.id} '
          '"${pair[0]}" + "${pair[1]}".');
      expect(dark, hasLength(1),
          reason: 'exactly one of the colliding pair renders');
      expect(dark.single.killer, _Killer.sibling);
    });

    test('a phrase absent from the body is reported dark, attributed to '
        'noMatch', () {
      final docId = docIds.first;
      final unit = byDoc[docId]!.first;
      const absent = 'zzqq no such wording on this card';
      final dark = _darkIn(docId, unit, <String>[absent]);
      expect(dark, hasLength(1));
      expect(dark.single.killer, _Killer.noMatch);
    });

    test('POSITIVE CONTROL: a phrase clear of every tier is NOT reported '
        'dark (the sweep is not just rejecting everything)', () {
      String? docId;
      HandbookUnit? unit;
      String? phrase;
      outer:
      for (final id in docIds) {
        for (final u in byDoc[id]!) {
          final tiers = _tiersOf(id, u);
          for (final t in tiers) {
            if (t.text.length < 40) continue;
            for (final m
                in RegExp('[A-Za-z]{5,} [A-Za-z]{5,}').allMatches(t.text)) {
              if (_hits(m.start, m.end, t.higher)) continue;
              docId = id;
              unit = u;
              phrase = m.group(0);
              break outer;
            }
          }
        }
      }
      expect(phrase, isNotNull,
          reason: 'no authored card offers a two-word run clear of every '
              'higher tier; the positive control cannot be built');
      debugPrint('BARRIO DARK SWEEP POSITIVE CONTROL: ${unit!.id} '
          '"$phrase".');
      expect(_darkIn(docId!, unit, <String>[phrase!]), isEmpty,
          reason: '"$phrase" sits clear of every tier and must render');
    });
  });
}
