// Proof that the four culinary manuals' authored per-card key phrases
// really light up, including on the cards where a tap-to-define term link
// is live at the same time.
//
// WHY A RENDER TEST AND NOT JUST A DATA TEST
//
// `test/barrio_card_key_sets_test.dart` proves the DATA satisfies the
// authoring contract and `test/barrio_card_keys_term_link_test.dart`
// proves no phrase overlaps a term link. Neither pumps a widget, so
// neither can prove the phrases survive the card's five-tier span
// pipeline (`handbook_lesson_card.dart` `_composeChunk`: search wash, term
// link, numeric pop, quiz answer evidence, then key terms LAST). Every one
// of those tiers outranks key terms and drops an overlapping phrase WHOLE,
// with no error: the phrase simply never appears.
//
// WHAT IS NEW HERE, AND WHY IT NEEDED ITS OWN FILE
//
// The MENU deck is the first shipped manual that carries authored phrases
// AND live term links on the same card: 19 of its 24 cards. Until this
// slice, the term-link tier had never actually met a key phrase at render
// time anywhere in the app. `barrio_wine_card_keys_render_test.dart`
// cannot cover it, because wine is not a term-link host and its reader
// never passes an `onTermTap`. So this file pumps a real menu card WITH an
// `onTermTap` and asserts both tiers are on screen together.
//
// HOW THIS FILE AVOIDS BEING VACUOUS
//
// Three traps, all closed deliberately:
//
//   1. Passing because term links were OFF. `onTermTap` gates the whole
//      tier (`_composeChunk` line 1097). A coexistence test that forgot to
//      pass one would prove nothing. So the same card is pumped BOTH ways
//      and the term-link widgets are asserted present in one and absent in
//      the other, with the expected count taken from
//      [BarrioTermLinks.matchesIn] rather than from the key-phrase data.
//   2. Passing because the drop never happens. If a key phrase overlapping
//      a term link did NOT vanish, "the phrases coexist" would be true for
//      the wrong reason. The composition group lays a synthetic phrase over
//      a REAL link on a REAL card and asserts the deployed precedence code
//      drops it, so the positive result above means something.
//   3. Expected values that come from the path under test. The per-manual
//      render assertions compare against `kBarrioCardKeysByUnit`, which is
//      also what the renderer reads, so on their own they only prove
//      "nothing was dropped" (which is the actual risk). Two independent
//      checks sit beside them: every rendered emphasis must be a verbatim
//      substring of the card's own body (the body is the independent
//      source), and the negative controls use literals this file owns.
//
// House rule followed throughout: nothing about the corpus is hard-coded
// beyond the four doc ids this slice is about. Sampled cards, phrase
// counts, term counts, and the fallback comparison doc are all derived at
// runtime, so a content regeneration makes this file go red rather than
// quietly green.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/barrio_body_chunks.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/barrio_key_terms.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/cards/barrio_card_keys_index.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_numeric_highlight.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_term_links.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

/// The four culinary manuals this slice authored, with the coverage floor
/// each one shipped at. Floors ratchet: a manual may gain cards, never lose
/// them. The remainder in each manual is a card that honestly cannot carry
/// three phrases (a two-line title slide, a one-line lead-in, or a caption
/// row whose only other words are the quiz answer evidence).
const Map<String, int> _culinaryFloors = <String, int>{
  'training_menu_concept': 21, // of 24
  'training_coffee': 27, // of 28
  'training_tequila': 16, // of 17
  'training_drink_specs': 16, // of 16
};

/// Every unit of [docId] in reading order.
List<HandbookUnit> _unitsOf(String docId) => <HandbookUnit>[
      for (final chapter in kBarrioTrainingDocs[docId]!.chapters)
        ...chapter.units,
    ];

List<String> _authored(String unitId) =>
    kBarrioCardKeysByUnit[unitId] ?? const <String>[];

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

/// A key-term emphasis span: bold + tealInk with NO background wash
/// (`_composeSpans` `keyTermMark`). That exact combination is what
/// separates it from the search wash (tealWarm background), the numeric
/// pop (the manual's accent) and the quiz answer span (tealDeep, w600).
bool _isKeyTermSpan(TextSpan s) =>
    s.style?.color == BarrioColors.tealInk &&
    s.style?.fontWeight == FontWeight.w700 &&
    s.style?.backgroundColor == null;

Future<void> _pumpCard(
  WidgetTester tester,
  HandbookUnit unit, {
  bool withTermLinks = false,
}) async {
  tester.view.physicalSize = const Size(390, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: HandbookLessonCard(
            unit: unit,
            // Non-null is what switches the term-link tier on at all.
            onTermTap: withTermLinks ? (_) {} : null,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The key-term-emphasized wording actually on screen for [unit], in
/// reading order.
///
/// Filtered by "this styled run is verbatim body content", which is what
/// keeps a title or badge from being counted as body emphasis. The filter
/// is applied to the RUN, not to its whole chunk, deliberately: a chunk
/// that also carries a term link renders that link as a [WidgetSpan], and
/// `toPlainText()` replaces a placeholder with U+FFFC, so a chunk-level
/// substring gate would silently skip exactly the cards this file exists
/// to cover.
List<String> _renderedKeyPhrases(WidgetTester tester, HandbookUnit unit) {
  final out = <String>[];
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    for (final span in _flatten(rich.text)) {
      final text = span.text;
      if (text == null || !_isKeyTermSpan(span)) continue;
      if (!unit.body.contains(text)) continue;
      out.add(text);
    }
  }
  return out;
}

/// Every term-link widget on screen for [unit], by its stable per-term key
/// (`_termLinkSpan` keys each one
/// `barrio_term_link_<unitId>_<foldedTerm>`).
List<String> _renderedTermLinks(WidgetTester tester, HandbookUnit unit) {
  final prefix = 'barrio_term_link_${unit.id}_';
  final out = <String>[];
  for (final element in find.byType(GestureDetector).evaluate()) {
    final key = element.widget.key;
    if (key is ValueKey<String> && key.value.startsWith(prefix)) {
      out.add(key.value.substring(prefix.length));
    }
  }
  return out;
}

/// The wording that survives the FULL five-tier composition on [unit], in
/// reading order.
///
/// A faithful replay of `handbook_lesson_card.dart` `_composeChunk`, in the
/// same order and with the same `blockedRanges` threading: search wash
/// (absent at rest) -> term links -> numeric pops -> quiz answer evidence
/// -> key phrases LAST. Two threaded sets carry across the card's chunks,
/// `alreadyLinked` for term links and `alreadyUsed` for key phrases, and
/// the key-phrase cap is left at its default so the cap is the deployed
/// one.
///
/// This exists because widget sampling cannot cover 80 cards cheaply, and
/// because ONE of these tiers is a trap the authoring contract does not
/// describe: a numeric span covers its UNIT WORD as well as its digits
/// ('24 to 48 hours', '65-70 degrees Celsius'), so a phrase carrying no
/// digit at all can still be swallowed whole. Checking the phrase text for
/// digits is necessary and NOT sufficient.
List<String> _survivingPhrases(String docId, HandbookUnit unit) {
  final phrases = _authored(unit.id);
  if (phrases.isEmpty) return const <String>[];
  final evidence = barrioAnswerEvidenceForUnit(unit.id);
  final isHost = BarrioTermLinks.kHostManualIds.contains(docId);
  final linked = <String>{};
  final used = <String>{};
  final out = <String>[];
  for (final chunk in chunksForBody(unit.body)) {
    final text = chunk.text;
    final terms = isHost
        ? BarrioTermLinks.matchesIn(text, alreadyLinked: linked)
        : const <BarrioTermMatch>[];
    final numerics = BarrioNumericHighlight.matchesIn(
      text,
      blockedRanges: <List<int>>[
        for (final t in terms) <int>[t.start, t.end]
      ],
    );
    final higher = <List<int>>[
      for (final t in terms) <int>[t.start, t.end],
      for (final n in numerics) <int>[n.start, n.end],
    ];
    // Answer evidence: verbatim substrings, plain case-sensitive indexOf,
    // every occurrence, each dropped whole if it hits a higher tier
    // (`_answerEvidenceRanges`).
    final answers = <List<int>>[];
    for (final phrase in evidence) {
      if (phrase.isEmpty) continue;
      var idx = text.indexOf(phrase);
      while (idx >= 0) {
        final range = <int>[idx, idx + phrase.length];
        if (!higher.any((r) => range[0] < r[1] && range[1] > r[0])) {
          answers.add(range);
        }
        idx = text.indexOf(phrase, idx + phrase.length);
      }
    }
    for (final k in BarrioKeyTermHighlight.matchesIn(
      text,
      phrases,
      alreadyUsed: used,
      blockedRanges: <List<int>>[...higher, ...answers],
    )) {
      out.add(text.substring(k.start, k.end));
    }
  }
  return out;
}

/// The folded terms the deployed matcher claims on [body], threading one
/// `alreadyLinked` set across the card's chunks exactly as `_SpanPass`
/// does. Independent of anything in `kBarrioCardKeysByUnit`.
List<String> _matcherTermsFor(String body) {
  final linked = <String>{};
  final out = <String>[];
  for (final chunk in chunksForBody(body)) {
    for (final m
        in BarrioTermLinks.matchesIn(chunk.text, alreadyLinked: linked)) {
      out.add(m.foldedTerm);
    }
  }
  return out;
}

void main() {
  final byDoc = <String, List<HandbookUnit>>{
    for (final docId in _culinaryFloors.keys) docId: _unitsOf(docId),
  };
  final coveredByDoc = <String, List<HandbookUnit>>{
    for (final e in byDoc.entries)
      e.key: e.value.where((u) => _authored(u.id).isNotEmpty).toList(),
  };
  final uncoveredByDoc = <String, List<HandbookUnit>>{
    for (final e in byDoc.entries)
      e.key: e.value.where((u) => _authored(u.id).isEmpty).toList(),
  };

  group('the four culinary manuals actually carry authored phrases', () {
    for (final docId in _culinaryFloors.keys) {
      test('$docId meets its coverage floor and every card is accounted for',
          () {
        final units = byDoc[docId]!;
        final covered = coveredByDoc[docId]!;
        expect(units, isNotEmpty, reason: '$docId must render');
        expect(covered.length + uncoveredByDoc[docId]!.length, units.length);
        expect(covered.length, greaterThanOrEqualTo(_culinaryFloors[docId]!),
            reason: '$docId coverage fell: ${covered.length} of '
                '${units.length} cards carry an authored set. Raise the data '
                'back up, do not lower the floor.');
      });
    }

    test('none of the four has a per-manual list behind it, so an uncovered '
        'card really does render nothing', () {
      for (final docId in _culinaryFloors.keys) {
        for (final unit in byDoc[docId]!) {
          expect(barrioKeyTermsForUnit(unit.id), isEmpty,
              reason: '$docId gained a per-manual list; the fallback claims '
                  'in this file assume it has none');
        }
      }
    });
  });

  group('EVERY authored phrase survives the full five-tier composition '
      '(not just the sampled ones)', () {
    // Widget sampling below covers a dozen cards. This covers all of them,
    // and it is the only guard in the repo that binds the NUMERIC tier
    // against these phrases. The authoring contract's rule is "no digits in
    // a phrase", which is necessary but NOT sufficient: a numeric span
    // covers its unit word too, so a digit-free phrase sitting on 'hours',
    // 'days', 'degrees Celsius' or 'seconds' is dropped whole and silently.
    // On four manuals made of pours, temperatures, ratios and ageing
    // periods, that is the likeliest way this data rots.
    for (final docId in _culinaryFloors.keys) {
      test('$docId: every authored phrase on every card still renders', () {
        final failures = <String>[];
        for (final unit in coveredByDoc[docId]!) {
          final authored = _authored(unit.id);
          final surviving = _survivingPhrases(docId, unit);
          if (surviving.length == authored.length) continue;
          final lost = authored
              .where((p) => !surviving.any(
                  (s) => s.toLowerCase() == p.toLowerCase()))
              .toList();
          failures.add('${unit.id}: lost ${lost.length} of '
              '${authored.length} -> $lost');
        }
        expect(failures, isEmpty,
            reason: 'a phrase that loses to a higher tier renders NOTHING '
                'and the card silently drops that teaching:\n'
                '${failures.join('\n')}');
      });
    }

    test('the numeric tier really can eat a DIGIT-FREE phrase (so the guard '
        'above is not just restating the no-digits rule)', () {
      // Derived, not hard-coded: the first culinary card whose numeric span
      // reaches past its own digits into a unit word, and the unit word
      // itself as a digit-free phrase laid on it.
      for (final docId in _culinaryFloors.keys) {
        for (final unit in byDoc[docId]!) {
          for (final chunk in chunksForBody(unit.body)) {
            for (final n in BarrioNumericHighlight.matchesIn(chunk.text)) {
              final span = chunk.text.substring(n.start, n.end);
              final words = span.split(RegExp(r'\s+'));
              final unitWord = words.last;
              if (unitWord.contains(RegExp(r'\d')) || unitWord.length < 4) {
                continue;
              }
              // The unit word carries no digit, yet sits inside the span.
              expect(unitWord, isNot(contains(RegExp(r'\d'))));
              expect(
                BarrioKeyTermHighlight.matchesIn(chunk.text, <String>[unitWord],
                    alreadyUsed: <String>{}),
                isNotEmpty,
                reason: '"$unitWord" must match its own chunk unblocked',
              );
              expect(
                BarrioKeyTermHighlight.matchesIn(
                  chunk.text,
                  <String>[unitWord],
                  alreadyUsed: <String>{},
                  blockedRanges: <List<int>>[
                    <int>[n.start, n.end]
                  ],
                ),
                isEmpty,
                reason: '${unit.id}: "$unitWord" carries no digit but sits '
                    'inside the numeric span "$span", so the numeric tier '
                    'drops it whole. This is why the no-digits rule alone '
                    'does not protect a phrase.',
              );
              debugPrint('BARRIO CULINARY NUMERIC TRAP: ${unit.id} span '
                  '"$span" swallows the digit-free word "$unitWord".');
              return;
            }
          }
        }
      }
      fail('no culinary numeric span reaches a digit-free unit word, so this '
          'proof has nothing to run on. Investigate before deleting it.');
    });
  });

  group('authored phrases render on the card (the silent-drop guard)', () {
    for (final docId in _culinaryFloors.keys) {
      // A spread sample per manual plus, deliberately, a card that also
      // carries quiz answer evidence: that pairing is where the higher tier
      // could eat a phrase. All indices derived, so the sample follows the
      // content.
      final covered = coveredByDoc[docId]!;
      final sample = <HandbookUnit>{
        covered.first,
        covered[covered.length ~/ 2],
        covered.last,
        covered.firstWhere(
          (u) => barrioAnswerEvidenceForUnit(u.id).isNotEmpty,
          orElse: () => covered.first,
        ),
      }.toList();

      for (final unit in sample) {
        testWidgets('${unit.id} shows all of its authored phrases in reading '
            'order', (tester) async {
          final authored = _authored(unit.id);
          await _pumpCard(tester, unit);
          final rendered = _renderedKeyPhrases(tester, unit);
          expect(rendered, authored,
              reason: '${unit.id}: the rendered emphasis must be exactly the '
                  'authored phrases, in order. A missing one was dropped by '
                  'a higher-precedence tier or never matched.');
          // Independent of the key-phrase data: whatever lit up has to be
          // verbatim body wording, which is the verbatim law itself.
          for (final phrase in rendered) {
            expect(unit.body.contains(phrase), isTrue,
                reason: '${unit.id}: "$phrase" is not verbatim body text');
          }
        });
      }
    }
  });

  group('a phrase and a term link coexist on the same card (the tier this '
      'slice made live)', () {
    // The most-linked covered card in the corpus, picked at runtime. Today
    // that is a MENU card; if the glossaries or the deck change, this
    // follows them rather than rotting.
    late HandbookUnit unit;
    late List<String> matcherTerms;

    setUp(() {
      final candidates = <HandbookUnit>[
        for (final docId in _culinaryFloors.keys)
          ...coveredByDoc[docId]!
              .where((u) => _matcherTermsFor(u.body).isNotEmpty),
      ]..sort((a, b) => _matcherTermsFor(b.body)
          .length
          .compareTo(_matcherTermsFor(a.body).length));
      unit = candidates.first;
      matcherTerms = _matcherTermsFor(unit.body);
    });

    test('the fixture is real: a covered culinary card that the DEPLOYED '
        'matcher claims term links on', () {
      expect(matcherTerms, isNotEmpty,
          reason: 'no covered culinary card carries a term link, so nothing '
              'in this group is being exercised. Investigate the matcher or '
              'the glossaries; do not delete this assertion');
      expect(_authored(unit.id), hasLength(greaterThanOrEqualTo(3)));
      debugPrint('BARRIO CULINARY COEXISTENCE FIXTURE: ${unit.id} carries '
          '${matcherTerms.length} term links (${matcherTerms.join(', ')}) '
          'and ${_authored(unit.id).length} authored phrases.');
    });

    testWidgets('with onTermTap wired, BOTH tiers are on screen: every '
        'authored phrase renders AND every term link renders',
        (tester) async {
      await _pumpCard(tester, unit, withTermLinks: true);
      expect(_renderedTermLinks(tester, unit), matcherTerms,
          reason: '${unit.id}: the term-link tier must be live, and claim '
              'exactly what the matcher says it claims');
      expect(_renderedKeyPhrases(tester, unit), _authored(unit.id),
          reason: '${unit.id}: every authored phrase must survive the term '
              'link sitting beside it. A missing one was dropped WHOLE by '
              '_composeChunk and the card silently lost that teaching.');
    });

    testWidgets('the same card with onTermTap null renders NO term link, and '
        'the identical phrase set (proves the test above was not passing '
        'because the tier was off)', (tester) async {
      await _pumpCard(tester, unit);
      expect(_renderedTermLinks(tester, unit), isEmpty,
          reason: 'onTermTap gates the whole tier (_composeChunk)');
      expect(_renderedKeyPhrases(tester, unit), _authored(unit.id));
    });
  });

  group('the coexistence claim has teeth (the drop is real)', () {
    // Widget-level proof is not available for this shape: HandbookLessonCard
    // derives its phrases from the unit id via barrioCardKeysForUnit, so a
    // deliberately-colliding phrase cannot be injected without shipping bad
    // data. The precedence itself is public, so this asserts it directly, in
    // the same order and with the same blockedRanges threading that
    // `_composeChunk` uses.
    late String unitId;
    late BarrioBodyChunk chunk;
    late BarrioTermMatch link;
    late List<List<int>> blocked;

    setUp(() {
      // Prefer a MULTI-WORD link, because that is the only shape that lets a
      // whole-word phrase start INSIDE the link and finish outside it, which
      // is the partial-overlap case the second test needs. Falls back to the
      // first link of any shape.
      BarrioBodyChunk? anyChunk;
      BarrioTermMatch? anyLink;
      String? anyUnitId;
      for (final docId in _culinaryFloors.keys) {
        for (final u in coveredByDoc[docId]!) {
          final linked = <String>{};
          for (final c in chunksForBody(u.body)) {
            for (final m
                in BarrioTermLinks.matchesIn(c.text, alreadyLinked: linked)) {
              anyChunk ??= c;
              anyLink ??= m;
              anyUnitId ??= u.id;
              if (m.foldedTerm.contains(' ')) {
                unitId = u.id;
                chunk = c;
                link = m;
                blocked = <List<int>>[
                  <int>[m.start, m.end]
                ];
                return;
              }
            }
          }
        }
      }
      if (anyLink == null) fail('no covered culinary card carries a term link');
      unitId = anyUnitId!;
      chunk = anyChunk!;
      link = anyLink;
      blocked = <List<int>>[
        <int>[link.start, link.end]
      ];
    });

    test('a phrase laid exactly over a real term link is dropped WHOLE', () {
      final phrase = chunk.text.substring(link.start, link.end);
      // Sanity first: unblocked, the phrase really would render. Without
      // this, the assertion below would also pass on a phrase that simply
      // does not match.
      expect(
        BarrioKeyTermHighlight.matchesIn(chunk.text, <String>[phrase],
            alreadyUsed: <String>{}),
        isNotEmpty,
        reason: '$unitId: the fixture phrase must match its own chunk',
      );
      expect(
        BarrioKeyTermHighlight.matchesIn(chunk.text, <String>[phrase],
            alreadyUsed: <String>{}, blockedRanges: blocked),
        isEmpty,
        reason: '$unitId: the term link outranks the key phrase, so the '
            'phrase must vanish entirely rather than render partially',
      );
    });

    test('a phrase merely OVERLAPPING the link is dropped too', () {
      // Starts on the link's second word (inside it) and runs past its end,
      // so this is partial overlap rather than containment. Only reachable
      // on a multi-word link; skipped honestly rather than faked otherwise.
      final space = link.foldedTerm.indexOf(' ');
      if (space <= 0) {
        debugPrint('BARRIO CULINARY DROP GUARD: fixture link '
            '"${link.foldedTerm}" is one word; partial overlap has nothing '
            'to prove here.');
        return;
      }
      final start = link.start + space + 1;
      final tail = chunk.text.substring(start);
      final match = RegExp(r'^\S+(\s+\S+)?').firstMatch(tail);
      if (match == null) return;
      final phrase = match.group(0)!.trim();
      expect(phrase.length + start, greaterThan(link.end),
          reason: 'the fixture phrase must actually extend past the link, or '
              'this is containment again, not partial overlap');
      expect(
        BarrioKeyTermHighlight.matchesIn(chunk.text, <String>[phrase],
            alreadyUsed: <String>{}),
        isNotEmpty,
        reason: '$unitId: "$phrase" must match its own chunk unblocked',
      );
      expect(
        BarrioKeyTermHighlight.matchesIn(chunk.text, <String>[phrase],
            alreadyUsed: <String>{}, blockedRanges: blocked),
        isEmpty,
        reason: '$unitId: "$phrase" straddles the link edge; the drop-whole '
            'rule fires on ANY intersection, not just containment',
      );
    });

    test('a phrase clear of the link still renders (the guard is not just '
        'rejecting everything)', () {
      // The first word in the chunk that is long enough to match whole-word
      // and sits entirely outside the link range. Searched over the WHOLE
      // chunk, before or after: a link that ends on a comma leaves no usable
      // fragment if only the tail is considered.
      String? control;
      for (final m in RegExp(r'[A-Za-z]{4,}').allMatches(chunk.text)) {
        if (m.start < link.end && m.end > link.start) continue;
        control = m.group(0);
        break;
      }
      if (control == null) {
        debugPrint('BARRIO CULINARY DROP GUARD: fixture chunk offers no word '
            'clear of the link; positive control skipped.');
        return;
      }
      expect(
        BarrioKeyTermHighlight.matchesIn(chunk.text, <String>[control],
            alreadyUsed: <String>{}, blockedRanges: blocked),
        isNotEmpty,
        reason: '$unitId: "$control" sits clear of the link and must survive',
      );
    });
  });

  group('a card with no authored entry still takes the fallback', () {
    test('every uncovered culinary card resolves to the per-manual answer',
        () {
      var checked = 0;
      for (final docId in _culinaryFloors.keys) {
        for (final unit in uncoveredByDoc[docId]!) {
          expect(barrioCardKeysForUnit(unit.id), barrioKeyTermsForUnit(unit.id),
              reason: '${unit.id} must render the per-manual list unchanged');
          checked++;
        }
      }
      expect(checked, greaterThan(0),
          reason: 'the fallback path must still be exercised by real cards: '
              'if every culinary card became covered, move this guard rather '
              'than letting it pass on an empty loop');
    });

    testWidgets('an uncovered culinary card renders no key-term emphasis at '
        'all', (tester) async {
      final unit = uncoveredByDoc.values
          .expand((units) => units)
          .firstWhere((u) => u.body.trim().isNotEmpty);
      await _pumpCard(tester, unit);
      expect(_renderedKeyPhrases(tester, unit), isEmpty,
          reason: '${unit.id} has no authored set and its manual has no '
              'per-manual list, so nothing may light up');
    });

    test('the fallback is not vacuous: an uncovered card in a CURATED manual '
        'still gets that manual\'s non-empty list', () {
      HandbookUnit? curatedUncovered;
      for (final entry in kBarrioTrainingDocs.entries) {
        for (final chapter in entry.value.chapters) {
          for (final unit in chapter.units) {
            if (_authored(unit.id).isEmpty &&
                barrioKeyTermsForUnit(unit.id).isNotEmpty) {
              curatedUncovered = unit;
              break;
            }
          }
          if (curatedUncovered != null) break;
        }
        if (curatedUncovered != null) break;
      }
      expect(curatedUncovered, isNotNull,
          reason: 'no uncovered card left in a curated manual: the fallback '
              'claim can no longer be proved here, move this guard');
      expect(barrioCardKeysForUnit(curatedUncovered!.id),
          barrioKeyTermsForUnit(curatedUncovered.id));
      expect(barrioCardKeysForUnit(curatedUncovered.id), isNotEmpty);
    });
  });
}
