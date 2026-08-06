// Kindle-style highlights, Slice B: anchor resolution, the marker
// palette, and the second-pass wash the lesson card paints.
//
// WHAT THESE TESTS ARE GUARDING, and why each one can actually rot:
//
//  1. THE OVERLAY IS NOT A SIXTH TIER. The card's five emphasis tiers
//     (search wash, term links, numeric pops, quiz answer evidence,
//     curated key terms) are a strict precedence contest: a lower-tier
//     phrase overlapping a higher one is dropped WHOLE and renders
//     nothing, silently. If the marker wash ever joined that contest,
//     marking an emphasized phrase would either lose the mark or lose
//     the emphasis, with no error anywhere. So the wash is tested
//     against each of the five tiers individually, asserting both that
//     the tier kept its own styling and that the wash arrived.
//
//  2. THE SPAN MEMO CACHE. Composed body spans are memoized per card
//     and the wash is composed in that same pass, so the resolved
//     highlight plan has to be part of the cache key. Without it a mark
//     made right now hits a warm entry and does not appear until
//     something else evicts it. The cache test deliberately WARMS the
//     entry first, then adds the highlight, then checks the very next
//     frame.
//
//  3. LEGIBILITY. A wash sits between the reader and the words. Every
//     marker colour is measured, composited over the real card surface,
//     against both body text colours.
//
//  4. VERBATIM LAW. Nothing here may change a single character of a
//     body. Every render assertion re-reads the plain text.
//
// Fixtures for the tiers keyed by unit id (answer evidence, curated key
// terms) are picked at RUNTIME by scanning the shipped corpus for the
// densest real card, never named, so content regeneration cannot make
// this file quietly stop testing anything.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/barrio_body_chunks.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/highlight/cards/barrio_card_keys_index.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_highlight_anchors.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_highlights_service.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_term_links.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Every unit of every shipped training manual, in registry order.
Iterable<HandbookUnit> _allUnits() => kBarrioTrainingDocs.values
    .expand((doc) => doc.chapters)
    .expand((chapter) => chapter.units);

/// Cards a widget test can pump cheaply: an explainer always renders its
/// body, and a picture-free card keeps the test off the asset bundle.
Iterable<HandbookUnit> _pumpableUnits() => _allUnits().where((unit) =>
    unit.type == HandbookUnitType.explainer &&
    unit.images.isEmpty &&
    unit.body.trim().isNotEmpty &&
    unit.body.length <= 3000);

/// A highlight over `[start, end)` of chunk [chunk] of [unit].
BarrioHighlight _highlightOver(
  HandbookUnit unit,
  int chunk,
  int start,
  int end, {
  String color = 'gold',
  String id = 'h_test_0001',
}) {
  final text = chunksForBody(unit.body)[chunk].text;
  return BarrioHighlight(
    id: id,
    unitId: unit.id,
    color: color,
    note: '',
    createdAt: DateTime.fromMillisecondsSinceEpoch(1722400000000),
    segments: <BarrioHighlightSegment>[
      BarrioHighlightSegment(
        chunk: chunk,
        start: start,
        end: end,
        text: text.substring(start, end),
      ),
    ],
  );
}

/// A highlight over the first occurrence of [phrase] in chunk [chunk].
BarrioHighlight _highlightPhrase(
  HandbookUnit unit,
  int chunk,
  String phrase, {
  String color = 'gold',
  String id = 'h_test_0001',
}) {
  final text = chunksForBody(unit.body)[chunk].text;
  final start = text.indexOf(phrase);
  expect(start, greaterThanOrEqualTo(0),
      reason: 'fixture sanity: chunk $chunk must contain "$phrase"');
  return _highlightOver(unit, chunk, start, start + phrase.length,
      color: color, id: id);
}

Future<void> _pump(
  WidgetTester tester,
  Widget child,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
  );
  await tester.pump();
}

/// Every leaf run the card actually rendered for its body, as
/// (text, resolved style) pairs in reading order.
///
/// Reads both shapes the card emits: a plain `Text` for an unstyled
/// chunk, and a `Text.rich` whose root span carries the body style with
/// the composed runs beneath it. Term links are inline widgets, so their
/// inner `Text` shows up here as its own run, which is exactly where the
/// wash has to land for them.
List<(String, TextStyle?)> _bodyRuns(WidgetTester tester) {
  final out = <(String, TextStyle?)>[];
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final span = text.textSpan;
    final rootStyle = text.style ?? (span is TextSpan ? span.style : null);
    if (rootStyle == null || rootStyle.height != 1.62) continue;
    if (rootStyle.fontSize != 13.5 && rootStyle.fontSize != 12.5) continue;
    if (text.data != null) {
      out.add((text.data!, rootStyle));
      continue;
    }
    if (span is! TextSpan) continue;
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan && child.text != null) {
        out.add((child.text!, rootStyle.merge(child.style)));
      }
      // A term link's inner Text is visited on its own by this loop.
    }
  }
  return out;
}

/// The runs whose text sits inside [phrase] (a phrase may be split into
/// several runs by a mark boundary).
List<(String, TextStyle?)> _runsWithin(
  List<(String, TextStyle?)> runs,
  String phrase,
) =>
    <(String, TextStyle?)>[
      for (final run in runs)
        if (run.$1.isNotEmpty && phrase.contains(run.$1)) run,
    ];

/// Every rendered body character, in order: the verbatim-law probe.
String _renderedText(WidgetTester tester) =>
    _bodyRuns(tester).map((r) => r.$1).join();

// --- contrast ---------------------------------------------------------------

double _channel(int value) {
  final c = value / 255.0;
  return c <= 0.03928
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(Color color) {
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  return 0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// A single-word glossary term that reads the same folded as written,
/// so a fixture body can carry it verbatim and still match. Picked at
/// runtime from the shipped registry: no term is ever named here.
String? _plainAsciiTerm() {
  final plain = RegExp(r'^[a-z]{4,}$');
  for (final term in BarrioTermLinks.registry().keys) {
    if (plain.hasMatch(term)) return term;
  }
  return null;
}

/// The opaque colour the eye sees where a marker wash covers body text:
/// the wash over the white glass card over the cream page.
Color _compositedWash(String token) => Color.alphaBlend(
      barrioHighlightWash(token),
      Color.alphaBlend(BarrioColors.glassFill, BarrioColors.shellDeep),
    );

void main() {
  // -------------------------------------------------------------------------
  // Anchor resolution
  // -------------------------------------------------------------------------
  group('BarrioHighlightPlan: placing stored marks on the body as it reads '
      'now', () {
    const body = 'Serve the guest first.\n\nThen clear the plates.';
    final chunks = chunksForBody(body);

    BarrioHighlight stored(
      int chunk,
      int start,
      int end,
      String text, {
      String id = 'h_1',
      String color = 'gold',
    }) =>
        BarrioHighlight(
          id: id,
          unitId: 'u1',
          color: color,
          note: '',
          createdAt: DateTime.fromMillisecondsSinceEpoch(1),
          segments: <BarrioHighlightSegment>[
            BarrioHighlightSegment(
                chunk: chunk, start: start, end: end, text: text),
          ],
        );

    test('stored offsets that still spell the stored words paint there', () {
      final plan = BarrioHighlightPlan.resolve(
        highlights: <BarrioHighlight>[stored(0, 10, 15, 'guest')],
        chunks: chunks,
      );
      expect(plan.forChunk(0), <BarrioHighlightRun>[
        const BarrioHighlightRun(
            highlightId: 'h_1', color: 'gold', start: 10, end: 15),
      ]);
      expect(plan.orphanIds, isEmpty);
    });

    test('words that moved inside their own chunk are re-anchored', () {
      // The card body grew a word, so the stored offsets now point at
      // the wrong characters. The stored words are still there.
      final grown = chunksForBody('Always serve the guest first.');
      final plan = BarrioHighlightPlan.resolve(
        highlights: <BarrioHighlight>[stored(0, 10, 15, 'guest')],
        chunks: grown,
      );
      expect(plan.forChunk(0).single.start, 17);
      expect(plan.forChunk(0).single.end, 22);
      expect(grown.first.text.substring(17, 22), 'guest');
      expect(plan.orphanIds, isEmpty);
    });

    test('words that moved to another chunk are re-anchored there', () {
      final reordered = chunksForBody('Then clear.\n\nServe the guest first.');
      final plan = BarrioHighlightPlan.resolve(
        highlights: <BarrioHighlight>[stored(0, 10, 15, 'guest')],
        chunks: reordered,
      );
      expect(plan.forChunk(0), isEmpty);
      expect(plan.forChunk(1).single.start,
          reordered[1].text.indexOf('guest'));
      expect(plan.orphanIds, isEmpty);
    });

    test('words no longer anywhere on the card are orphaned, not guessed',
        () {
      final plan = BarrioHighlightPlan.resolve(
        highlights: <BarrioHighlight>[stored(0, 10, 15, 'guest')],
        chunks: chunksForBody('A completely rewritten card body.'),
      );
      expect(plan.isEmpty, isTrue, reason: 'nothing may paint');
      expect(plan.orphanIds, <String>['h_1']);
    });

    test('one unplaceable segment orphans the WHOLE highlight', () {
      final half = BarrioHighlight(
        id: 'h_2',
        unitId: 'u1',
        color: 'gold',
        note: '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1),
        segments: const <BarrioHighlightSegment>[
          BarrioHighlightSegment(
              chunk: 0, start: 10, end: 15, text: 'guest'),
          BarrioHighlightSegment(
              chunk: 1, start: 0, end: 4, text: 'words that are gone'),
        ],
      );
      final plan = BarrioHighlightPlan.resolve(
        highlights: <BarrioHighlight>[half],
        chunks: chunks,
      );
      expect(plan.isEmpty, isTrue,
          reason: 'painting half a mark is a wrong claim about what was '
              'marked, so nothing paints');
      expect(plan.orphanIds, <String>['h_2']);
    });

    test('where two marks overlap, the newer one paints', () {
      final plan = BarrioHighlightPlan.resolve(
        highlights: <BarrioHighlight>[
          stored(0, 6, 15, 'the guest', id: 'older', color: 'gold'),
          stored(0, 10, 21, 'guest first', id: 'newer', color: 'plum'),
        ],
        chunks: chunks,
      );
      expect(plan.forChunk(0), <BarrioHighlightRun>[
        const BarrioHighlightRun(
            highlightId: 'older', color: 'gold', start: 6, end: 10),
        const BarrioHighlightRun(
            highlightId: 'newer', color: 'plum', start: 10, end: 21),
      ]);
    });

    test('equality sees a new mark, a recolour, and a moved offset', () {
      BarrioHighlightPlan planOf(List<BarrioHighlight> hs) =>
          BarrioHighlightPlan.resolve(highlights: hs, chunks: chunks);
      final base = planOf(<BarrioHighlight>[stored(0, 10, 15, 'guest')]);

      expect(
        base,
        equals(planOf(<BarrioHighlight>[stored(0, 10, 15, 'guest')])),
        reason: 'same marks must hit the span cache',
      );
      expect(base, isNot(equals(BarrioHighlightPlan.empty)),
          reason: 'a new mark must miss the cache');
      expect(
        base,
        isNot(equals(planOf(
            <BarrioHighlight>[stored(0, 10, 15, 'guest', color: 'plum')]))),
        reason: 'a recolour must miss the cache',
      );
      expect(
        base,
        isNot(equals(planOf(<BarrioHighlight>[stored(0, 4, 9, 'the g')]))),
        reason: 'a moved offset must miss the cache',
      );
      expect(
        base,
        isNot(equals(planOf(
          <BarrioHighlight>[stored(0, 10, 15, 'guest', id: 'other')],
        ))),
        reason: 'a different mark id must miss the cache',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Marker palette legibility
  // -------------------------------------------------------------------------
  group('marker palette', () {
    test('the four markers are the four stored tokens, teal excluded', () {
      expect(kBarrioHighlightMarkerColors.keys.toList(),
          kBarrioHighlightColorTokens);
      expect(
        kBarrioHighlightMarkerColors.values,
        isNot(contains(BarrioColors.tealWarm)),
        reason: 'tealWarm is the search-hit wash: "I marked this" must not '
            'look like "your search matched here"',
      );
    });

    test('every marker wash keeps body text at or above AA 4.5:1', () {
      final measured = <String, String>{};
      for (final token in kBarrioHighlightColorTokens) {
        final surface = _compositedWash(token);
        final secondary = _contrast(surface, BarrioColors.textSecondary);
        final primary = _contrast(surface, BarrioColors.textPrimary);
        measured[token] = 'secondary ${secondary.toStringAsFixed(2)}:1, '
            'primary ${primary.toStringAsFixed(2)}:1';
        expect(secondary, greaterThanOrEqualTo(4.5),
            reason: '$token wash against body prose (measured $measured)');
        expect(primary, greaterThanOrEqualTo(4.5),
            reason: '$token wash against table headers (measured $measured)');
      }
      printOnFailure('measured marker contrast: $measured');
    });

    test('a marked search hit stays legible where the two washes stack', () {
      // The search wash paints ON TOP of the marker wash, and its text
      // is textPrimary. This is the only place two backgrounds meet.
      for (final token in kBarrioHighlightColorTokens) {
        final stacked = Color.alphaBlend(
          BarrioColors.tealWarm.withValues(alpha: 0.28),
          _compositedWash(token),
        );
        expect(_contrast(stacked, BarrioColors.textPrimary),
            greaterThanOrEqualTo(4.5),
            reason: 'search wash over the $token marker');
      }
    });

    test('an unknown colour token still paints, in the default marker', () {
      expect(barrioHighlightWash('a-newer-builds-colour'),
          barrioHighlightWash(kBarrioHighlightDefaultColor));
    });
  });

  // -------------------------------------------------------------------------
  // The overlay against each of the five emphasis tiers
  // -------------------------------------------------------------------------
  group('the marker wash coexists with every emphasis tier', () {
    testWidgets('tier 1: a search hit keeps its teal wash and bold navy',
        (tester) async {
      const unit = HandbookUnit(
        id: 'hl_search_u1',
        type: HandbookUnitType.explainer,
        title: 'Search tier',
        body: 'The tequila arrives cold and the guest is served.',
      );
      await _pump(
        tester,
        HandbookLessonCard(
          unit: unit,
          highlightTerms: const <String>['tequila'],
          highlights: <BarrioHighlight>[
            _highlightPhrase(unit, 0, 'tequila arrives'),
          ],
        ),
      );

      final hit = _runsWithin(_bodyRuns(tester), 'tequila').single;
      expect(hit.$2?.fontWeight, FontWeight.w700,
          reason: 'the search tier keeps its bold');
      expect(hit.$2?.color, BarrioColors.textPrimary,
          reason: 'the search tier keeps its navy');
      // Two washes, one background: the marker composites UNDERNEATH.
      expect(hit.$2?.backgroundColor,
          Color.alphaBlend(BarrioColors.tealWarm.withValues(alpha: 0.28),
              barrioHighlightWash('gold')));
      expect(_renderedText(tester), contains(unit.body));
    });

    testWidgets('tier 2: a term link keeps its dotted underline and gains '
        'the wash', (tester) async {
      final term = _plainAsciiTerm();
      if (term == null) {
        markTestSkipped('no plain-ASCII term in the glossary registry');
        return;
      }
      final unit = HandbookUnit(
        id: 'hl_term_u1',
        type: HandbookUnitType.explainer,
        title: 'Term tier',
        body: 'Every server should recognise $term on the menu today.',
      );
      await _pump(
        tester,
        HandbookLessonCard(
          unit: unit,
          onTermTap: (_) {},
          highlights: <BarrioHighlight>[
            _highlightPhrase(unit, 0, 'recognise $term on'),
          ],
        ),
      );

      final link = _bodyRuns(tester).firstWhere((r) => r.$1 == term,
          orElse: () => throw StateError('no term link rendered for $term'));
      expect(link.$2?.decoration, TextDecoration.underline,
          reason: 'the term-link tier keeps its dotted underline');
      expect(link.$2?.decorationStyle, TextDecorationStyle.dotted);
      expect(link.$2?.backgroundColor, barrioHighlightWash('gold'),
          reason: 'a marked term link takes the wash whole: half a washed '
              'link would read as a rendering bug');
      expect(_renderedText(tester), contains('recognise'));
    });

    testWidgets('tier 3: a numeric fact pop keeps its accent bold',
        (tester) async {
      const unit = HandbookUnit(
        id: 'hl_numeric_u1',
        type: HandbookUnitType.explainer,
        title: 'Numeric tier',
        body: 'Hold the cold line at 4 degrees C for the whole service.',
      );
      await _pump(
        tester,
        HandbookLessonCard(
          unit: unit,
          highlights: <BarrioHighlight>[
            _highlightPhrase(unit, 0, 'at 4 degrees C for'),
          ],
        ),
      );

      final pop = _runsWithin(_bodyRuns(tester), '4 degrees C')
          .firstWhere((r) => r.$1.contains('degrees'));
      expect(pop.$2?.fontWeight, FontWeight.w700,
          reason: 'the numeric tier keeps its bold');
      expect(pop.$2?.backgroundColor, barrioHighlightWash('gold'));
      expect(_renderedText(tester), contains(unit.body));
    });

    testWidgets('tier 4: quiz answer evidence keeps its teal wording',
        (tester) async {
      // Runtime fixture: a real card whose words a chapter-end quiz
      // answer quotes.
      HandbookUnit? unit;
      String? phrase;
      for (final candidate in _pumpableUnits()) {
        final evidence = barrioAnswerEvidenceForUnit(candidate.id);
        if (evidence.isEmpty) continue;
        final chunks = chunksForBody(candidate.body);
        if (chunks.isEmpty) continue;
        final hit = evidence.firstWhere(
          (e) => chunks.first.text.contains(e),
          orElse: () => '',
        );
        if (hit.isEmpty) continue;
        unit = candidate;
        phrase = hit;
        break;
      }
      if (unit == null || phrase == null) {
        markTestSkipped('no shipped card quotes quiz answer evidence in its '
            'first chunk');
        return;
      }

      await _pump(
        tester,
        HandbookLessonCard(
          unit: unit,
          highlights: <BarrioHighlight>[_highlightPhrase(unit, 0, phrase)],
        ),
      );

      final answer = _bodyRuns(tester).firstWhere((r) => r.$1 == phrase,
          orElse: () => throw StateError('answer evidence did not render as '
              'its own run in ${unit!.id}'));
      expect(answer.$2?.color, BarrioColors.tealDeep,
          reason: 'the answer tier keeps its teal wording');
      expect(answer.$2?.fontWeight, FontWeight.w600);
      expect(answer.$2?.backgroundColor, barrioHighlightWash('gold'));
    });

    testWidgets('tier 5: curated key terms keep their bold tealInk, on the '
        'densest authored card in the corpus', (tester) async {
      // Runtime fixture, deliberately the WORST case: 863 cards now
      // carry authored per-card key phrases, and a card dense with them
      // is where an overlay that fought the tiers would show up first.
      HandbookUnit? unit;
      var bestKeys = 0;
      for (final candidate in _pumpableUnits()) {
        final keys = barrioCardKeysForUnit(candidate.id);
        if (keys.isEmpty) continue;
        final chunks = chunksForBody(candidate.body);
        if (chunks.isEmpty) continue;
        final present =
            keys.where((k) => chunks.first.text.contains(k)).length;
        if (present > bestKeys) {
          bestKeys = present;
          unit = candidate;
        }
      }
      if (unit == null) {
        markTestSkipped('no shipped card carries curated key terms');
        return;
      }
      final keys = barrioCardKeysForUnit(unit.id);
      final chunk = chunksForBody(unit.body).first;
      final marked =
          keys.firstWhere((k) => chunk.text.contains(k), orElse: () => '');
      expect(marked, isNotEmpty, reason: 'fixture sanity');

      // Mark the WHOLE first chunk: every key term on it is covered.
      await _pump(
        tester,
        HandbookLessonCard(
          unit: unit,
          highlights: <BarrioHighlight>[
            _highlightOver(unit, 0, 0, chunk.text.length),
          ],
        ),
      );

      final runs = _bodyRuns(tester);
      final emphasized = runs
          .where((r) => r.$2?.color == BarrioColors.tealInk)
          .toList();
      expect(emphasized, isNotEmpty,
          reason: 'sanity: the picked card really emphasizes key terms '
              '(${unit.id}, $bestKeys present)');
      for (final run in emphasized) {
        expect(run.$2?.fontWeight, FontWeight.w700,
            reason: 'the key-term tier keeps its bold');
        expect(run.$2?.backgroundColor, barrioHighlightWash('gold'),
            reason: 'every emphasized phrase under the mark is washed too');
      }
      // Verbatim law: a fully marked chunk still reads word for word.
      expect(runs.map((r) => r.$1).join(), contains(chunk.text));
      // And every run of the marked chunk carries the wash, emphasized
      // or not.
      final chunkRuns = _runsWithin(runs, chunk.text);
      expect(chunkRuns, isNotEmpty);
      for (final run in chunkRuns) {
        expect(run.$2?.backgroundColor, isNotNull,
            reason: 'no gap may be left unwashed inside the marked run');
      }
    });
  });

  // -------------------------------------------------------------------------
  // The span memo cache
  // -------------------------------------------------------------------------
  group('the span memo cache cannot hide a new mark', () {
    testWidgets('a mark added against a WARM cache paints on the very next '
        'frame', (tester) async {
      barrioClearBodySpanCache();
      addTearDown(barrioClearBodySpanCache);

      const unit = HandbookUnit(
        id: 'hl_cache_u1',
        type: HandbookUnitType.explainer,
        title: 'Cache',
        body: 'Chill the glass before you pour the drink.',
      );

      // Frame 1: no marks. This RECORDS the card's span pass, so the
      // entry is warm and a second build with the same key would replay
      // it without composing anything.
      await _pump(tester, const HandbookLessonCard(unit: unit));
      expect(
        _bodyRuns(tester).every((r) => r.$2?.backgroundColor == null),
        isTrue,
        reason: 'sanity: nothing is washed before the reader marks anything',
      );

      // Frame 2: the reader marks a phrase. Same unit, same body, same
      // everything the OLD cache key held.
      await _pump(
        tester,
        HandbookLessonCard(
          unit: unit,
          highlights: <BarrioHighlight>[
            _highlightPhrase(unit, 0, 'Chill the glass'),
          ],
        ),
      );

      final washed = _runsWithin(_bodyRuns(tester), 'Chill the glass');
      expect(washed, isNotEmpty);
      expect(
        washed
            .every((r) => r.$2?.backgroundColor == barrioHighlightWash('gold')),
        isTrue,
        reason: 'the resolved highlight plan is part of the span cache key, '
            'so a mark made right now misses the warm entry and recomposes',
      );
    });

    testWidgets('a recolour against a warm cache repaints on the next frame',
        (tester) async {
      barrioClearBodySpanCache();
      addTearDown(barrioClearBodySpanCache);

      const unit = HandbookUnit(
        id: 'hl_cache_u2',
        type: HandbookUnitType.explainer,
        title: 'Recolour',
        body: 'Chill the glass before you pour the drink.',
      );

      await _pump(
        tester,
        HandbookLessonCard(
          unit: unit,
          highlights: <BarrioHighlight>[
            _highlightPhrase(unit, 0, 'Chill the glass', color: 'gold'),
          ],
        ),
      );
      await _pump(
        tester,
        HandbookLessonCard(
          unit: unit,
          highlights: <BarrioHighlight>[
            _highlightPhrase(unit, 0, 'Chill the glass', color: 'plum'),
          ],
        ),
      );

      final washed = _runsWithin(_bodyRuns(tester), 'Chill the glass');
      expect(washed, isNotEmpty);
      expect(
        washed
            .every((r) => r.$2?.backgroundColor == barrioHighlightWash('plum')),
        isTrue,
        reason: 'the colour token is part of the cache key',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Cards that carry no marks
  // -------------------------------------------------------------------------
  group('a card with no highlights renders exactly as before', () {
    testWidgets('no wash, and no SelectionListener in the tree',
        (tester) async {
      barrioClearBodySpanCache();
      addTearDown(barrioClearBodySpanCache);

      // The richest real card in the corpus: prose, a list or a table,
      // key terms, numeric pops, the lot.
      HandbookUnit? unit;
      var bestChunks = 0;
      for (final candidate in _pumpableUnits()) {
        final count = chunksForBody(candidate.body).length;
        if (count > bestChunks) {
          bestChunks = count;
          unit = candidate;
        }
      }
      expect(unit, isNotNull, reason: 'sanity: the corpus has cards');

      await _pump(tester, HandbookLessonCard(unit: unit!));

      expect(find.byType(SelectionListener), findsNothing,
          reason: 'a curated screen passes no registry, so the card must add '
              'nothing at all to the tree');
      for (final run in _bodyRuns(tester)) {
        expect(run.$2?.backgroundColor, isNull,
            reason: 'no wash may appear on an unmarked card');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('passing an empty highlight list changes nothing',
        (tester) async {
      barrioClearBodySpanCache();
      addTearDown(barrioClearBodySpanCache);

      const unit = HandbookUnit(
        id: 'hl_empty_u1',
        type: HandbookUnitType.explainer,
        title: 'Empty',
        body: 'Opening prose.\n\n- A bullet\n\n1. A step\n\nA | B',
      );

      await _pump(tester, const HandbookLessonCard(unit: unit));
      final before = _bodyRuns(tester);

      await _pump(
        tester,
        const HandbookLessonCard(unit: unit, highlights: <BarrioHighlight>[]),
      );
      final after = _bodyRuns(tester);

      expect(after.map((r) => r.$1).toList(), before.map((r) => r.$1).toList());
      expect(after.map((r) => r.$2).toList(), before.map((r) => r.$2).toList());
    });
  });

  // -------------------------------------------------------------------------
  // Capture: what the reader selected becomes what gets stored
  // -------------------------------------------------------------------------
  group('BarrioHighlightAnchorRegistry', () {
    testWidgets('a registry wraps every rendered chunk, and selection '
        'offsets are 1:1 with the chunk even across a term link',
        (tester) async {
      final term = _plainAsciiTerm();
      if (term == null) {
        markTestSkipped('no plain-ASCII term in the glossary registry');
        return;
      }
      final unit = HandbookUnit(
        id: 'hl_anchor_u1',
        type: HandbookUnitType.explainer,
        title: 'Anchors',
        body: 'A server learns $term early.\n\nThen everything else.',
      );
      final chunks = chunksForBody(unit.body);
      final registry = BarrioHighlightAnchorRegistry();
      addTearDown(registry.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SelectionArea(
              child: SingleChildScrollView(
                child: HandbookLessonCard(
                  unit: unit,
                  onTermTap: (_) {},
                  anchorRegistry: registry,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SelectionListener), findsNWidgets(chunks.length),
          reason: 'one listener per rendered chunk');

      // Select the whole region, the way "Select all" would.
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll();
      await tester.pump();

      final segments = registry.selectionSegments(unit.id, chunks);
      expect(segments.length, chunks.length,
          reason: 'every chunk reports its own slice of the selection');
      for (final segment in segments) {
        final text = chunks[segment.chunk].text;
        expect(segment.start, 0);
        expect(segment.end, text.length,
            reason: 'the reported offsets must be 1:1 with the chunk string, '
                'including the term-link widget span, whose flattened '
                'content is exactly its verbatim substring');
        expect(segment.text, text);
      }
      expect(registry.selectedUnitId(), unit.id);
    });

    testWidgets('nothing selected means no segments and no card',
        (tester) async {
      const unit = HandbookUnit(
        id: 'hl_anchor_u2',
        type: HandbookUnitType.explainer,
        title: 'Idle',
        body: 'Nothing is selected here.',
      );
      final registry = BarrioHighlightAnchorRegistry();
      addTearDown(registry.dispose);

      await _pump(
        tester,
        SelectionArea(
          child: HandbookLessonCard(unit: unit, anchorRegistry: registry),
        ),
      );

      expect(registry.selectedUnitId(), isNull);
      expect(
        registry.selectionSegments(unit.id, chunksForBody(unit.body)),
        isEmpty,
      );
    });
  });
}
