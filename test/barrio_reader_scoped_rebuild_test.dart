// Regression tests for the "Fast reader" performance pass (premium
// performance audit A2, A4, A8).
//
// These lock in behaviour that is invisible on screen but expensive when it
// regresses, so a future change cannot quietly put it back:
//
//   1. A2/A8 (screen): a card settling never rebuilds the reading deck. The
//      hero and the chapter rail listen to notifiers instead, so the
//      TrainingDocScreen build that used to run on every swipe (and with it
//      the whole carousel subtree) does not run at all.
//   2. A8 (carousel unit): turning a page does not re-invoke the card
//      builder for a page that was already built. The two chevrons and the
//      position label are the only things that react.
//   3. A4 (span cache): the memoized body-span pass is keyed on every input
//      that can change its output, so changing the highlight query changes
//      the rendered spans, and coming back to the first query reproduces
//      the first spans exactly. A stale span run would be a correctness
//      bug, not a perf one.
//   4. A4 (term links): the bucketed first-character index finds the same
//      first whole-word occurrences the old per-term sweep found, with the
//      same longest-first precedence and the same first-occurrence-per-card
//      bookkeeping.
//   5. A1 (decode size): a reader picture decodes at its on-screen width,
//      not at the 1400px source width.
//   6. A4 (cache lifetime): a cached span run closes over the composing
//      screen's onTermTap, and the cache is process-lifetime, so popping a
//      reader must drop the entries keyed on that screen. Proved through a
//      real route push/pop, plus a structural guard so a screen added later
//      cannot wire onTermTap and forget to clear.
//
// All widget tests at a 390x844 phone viewport; takeException() asserted
// null.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_term_links.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/learning_carousel.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _phoneSize = Size(390, 844);

/// Three single-card sections, so one edge tap crosses a section boundary
/// and the hero has to follow.
final _fixtureDoc = BarrioTrainingDoc(
  id: 'scoped_rebuild_fixture',
  title: 'Scoped Rebuild Fixture',
  sourcePath: 'test://scoped-rebuild',
  chapters: const [
    HandbookChapter(
      id: 'sr_ch1',
      title: 'First',
      subtitle: 'first fixture section',
      iconCodePoint: 0xe533,
      units: [
        HandbookUnit(
          id: 'sr_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Card One',
          body: 'Fixture body one.',
        ),
      ],
    ),
    HandbookChapter(
      id: 'sr_ch2',
      title: 'Second',
      subtitle: 'second fixture section',
      iconCodePoint: 0xe556,
      units: [
        HandbookUnit(
          id: 'sr_c2_u1',
          type: HandbookUnitType.explainer,
          title: 'Card Two',
          body: 'Fixture body two.',
        ),
      ],
    ),
    HandbookChapter(
      id: 'sr_ch3',
      title: 'Third',
      subtitle: 'third fixture section',
      iconCodePoint: 0xe556,
      units: [
        HandbookUnit(
          id: 'sr_c3_u1',
          type: HandbookUnitType.explainer,
          title: 'Card Three',
          body: 'Fixture body three.',
        ),
      ],
    ),
  ],
);

/// A one-card manual under a CULINARY host id, so the reader wires
/// `onTermTap` and the body composes a real tappable term-link span
/// ('ceviche' is a card in the Latin dishes glossary). That is the only
/// shape that puts a screen callback inside the body-span cache.
const BarrioTrainingDoc _hostManualDoc = BarrioTrainingDoc(
  id: 'training_menu_concept',
  title: 'Span Release Fixture',
  sourcePath: 'test://span-release',
  chapters: [
    HandbookChapter(
      id: 'sr_host_ch1',
      title: 'Only Section',
      subtitle: 'fixture section',
      iconCodePoint: 0xe533,
      units: [
        HandbookUnit(
          id: 'sr_host_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Fixture Card',
          body: 'Our kitchen loves ceviche in the summer.',
        ),
      ],
    ),
  ],
);

/// One card whose body carries a phrase the search highlight can mark.
const HandbookUnit _highlightUnit = HandbookUnit(
  id: 'span_cache_fixture_c0_u0',
  type: HandbookUnitType.explainer,
  title: 'Span Cache Card',
  body: 'The plancha sears the marinade quickly. '
      'A second sentence keeps the marinade honest.',
);

/// A flat signature of every styled span currently on screen: the text of
/// each run plus the weight, color and wash that carry the highlight tiers.
/// Two renders that produce the same signature rendered the same spans.
List<String> _spanSignature(WidgetTester tester) {
  final signature = <String>[];
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final root = text.textSpan;
    if (root == null) continue;
    root.visitChildren((span) {
      if (span is TextSpan) {
        final style = span.style;
        signature.add('${span.text}|${style?.fontWeight}|${style?.color}'
            '|${style?.backgroundColor}');
      }
      return true;
    });
  }
  return signature;
}

Future<void> _pumpHighlightCard(
  WidgetTester tester,
  List<String> highlightTerms,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: BarrioColors.shellDeep,
        body: SingleChildScrollView(
          child: HandbookLessonCard(
            unit: _highlightUnit,
            highlightTerms: highlightTerms,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'a card settle rebuilds the hero and rail but not the reading deck',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    expect(find.text('SECTION 1 OF 3'), findsOneWidget);
    // The deck widget INSTANCE is the probe: TrainingDocScreen builds a new
    // LearningCarousel every time its own build runs, so an unchanged
    // instance proves the screen did not rebuild.
    final deckBefore =
        tester.widget<LearningCarousel>(find.byType(LearningCarousel));

    final pager = tester.getRect(find.byType(PageView));
    await tester.tapAt(Offset(pager.right - 8, pager.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('SECTION 2 OF 3'), findsOneWidget,
        reason: 'the hero followed the settled card');
    expect(find.text('2 of 3'), findsOneWidget,
        reason: 'the position label followed the settled card');
    expect(
      identical(
        deckBefore,
        tester.widget<LearningCarousel>(find.byType(LearningCarousel)),
      ),
      isTrue,
      reason: 'the settle must not rebuild TrainingDocScreen, and so must '
          'not rebuild the carousel subtree under it',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('turning a page does not re-invoke the card builder for a page '
      'that is already built', (tester) async {
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final builds = <int, int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: BarrioColors.shellDeep,
          body: LearningCarousel(
            cardCount: 6,
            accent: BarrioColors.tealWarm,
            cardBuilder: (context, index) {
              builds[index] = (builds[index] ?? 0) + 1;
              return Center(child: Text('card $index'));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final firstCardBuilds = builds[0]!;
    expect(firstCardBuilds, greaterThan(0));
    expect(find.text('1 of 6'), findsOneWidget);

    final pager = tester.getRect(find.byType(PageView));
    await tester.tapAt(Offset(pager.right - 8, pager.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('2 of 6'), findsOneWidget,
        reason: 'the edge tap turned exactly one page');
    expect(builds[0], firstCardBuilds,
        reason: 'the settle only toggles the chevrons and the label; it must '
            'not rebuild the deck and re-run every live card builder');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reader picture decodes at its on-screen width, not the '
      'source resolution', (tester) async {
    // A real 390x844 logical phone at devicePixelRatio 2.
    tester.view.physicalSize = _phoneSize * 2;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: BarrioColors.shellDeep,
          body: SingleChildScrollView(
            child: HandbookLessonCard(
              unit: const HandbookUnit(
                id: 'cache_width_fixture_c0_u0',
                type: HandbookUnitType.explainer,
                title: 'Picture Card',
                body: 'Fixture body with a picture above it.',
                images: [
                  HandbookUnitImage(
                    assetPath:
                        'assets/internal/barrio/training/fixture/01.webp',
                    afterParagraph: -1,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<ResizeImage>(),
        reason: 'perf audit A1: the reader picture must decode at display '
            'size, not at the 1400px source width');
    final resize = provider as ResizeImage;
    expect(resize.imageProvider, isA<AssetImage>());
    // The card is inset from a 390dp viewport, so at devicePixelRatio 2 the
    // decode lands well under the source width with room to spare.
    expect(resize.width, isNotNull);
    expect(resize.width!, greaterThan(0));
    expect(resize.width!, lessThan(1400),
        reason: 'a display-size decode must be smaller than the source');
    expect(tester.takeException(), isNull);
  });

  group('body span cache is released with the screen', () {
    testWidgets('popping the reader drops the cache entries keyed on that '
        "screen's callback", (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = _phoneSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // A real route, pushed and popped, so this exercises the dispose
      // wiring end to end rather than just calling the clear function.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TrainingDocScreen(doc: _hostManualDoc),
                  ),
                ),
                child: const Text('open reader'),
              ),
            ),
          ),
        ),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));

      await tester.tap(find.text('open reader'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(find.byType(TrainingDocScreen), findsOneWidget);

      // The screen's own tear-off, taken from the card it built. This is
      // the exact object the cache key holds and the term-link span closes
      // over, so it is the right thing to hunt for afterwards.
      final owner = tester
          .widget<HandbookLessonCard>(find.byType(HandbookLessonCard).first)
          .onTermTap;
      expect(owner, isNotNull,
          reason: 'a culinary host manual wires tap-to-define, which is what '
              'puts a screen callback into the span cache');
      expect(
        find.byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('barrio_term_link_')),
        findsWidgets,
        reason: 'the body really did compose a tappable term-link span, so a '
            'cached span run closes over this screen',
      );
      expect(barrioDebugBodySpanCacheOwners(), contains(owner),
          reason: 'the composed spans are memoized under this screen; without '
              'this the pop assertion below would pass vacuously');

      navigator.pop();
      await tester.pumpAndSettle();

      expect(find.byType(TrainingDocScreen), findsNothing);
      expect(barrioDebugBodySpanCacheOwners(), isNot(contains(owner)),
          reason: 'a popped reader must not stay reachable from the '
              'process-lifetime span cache');
      expect(barrioDebugBodySpanCacheOwners(), isEmpty,
          reason: 'no screen callback survives in the cache at all');
      expect(tester.takeException(), isNull);
    });

    test('every reader screen that wires onTermTap also clears the cache '
        'on dispose', () {
      // Structural guard, not a style rule: a cached span run closes over
      // the `onTermTap` it was composed with, so a screen that hands one to
      // a lesson card owns the job of dropping those entries when it goes
      // away. The next slice on this file adds more state behind those
      // closures, so the rule has to outlive this PR.
      final screens = Directory('lib/internal/barrio/screens')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      final offenders = <String>[];
      var checked = 0;
      for (final screen in screens) {
        final source = screen.readAsStringSync();
        if (!source.contains('onTermTap:')) continue;
        checked++;
        if (!source.contains('barrioClearBodySpanCache()')) {
          offenders.add(screen.path);
        }
      }
      expect(checked, greaterThan(0),
          reason: 'sanity: at least one screen wires tap-to-define, so this '
              'guard is actually looking at something');
      expect(offenders, isEmpty,
          reason: 'these screens pass onTermTap into a lesson card but never '
              'call barrioClearBodySpanCache(), so a popped route stays '
              'reachable from the span cache');
    });
  });

  group('body span cache', () {
    testWidgets('changing the highlight query changes the rendered spans, and '
        'returning to the first query reproduces them exactly',
        (tester) async {
      tester.view.physicalSize = _phoneSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpHighlightCard(tester, const <String>['plancha']);
      final planchaSpans = _spanSignature(tester);
      expect(planchaSpans, isNotEmpty,
          reason: 'the query highlight produced styled spans');
      expect(planchaSpans.any((s) => s.startsWith('plancha|')), isTrue);

      await _pumpHighlightCard(tester, const <String>['marinade']);
      final marinadeSpans = _spanSignature(tester);
      expect(marinadeSpans, isNot(equals(planchaSpans)),
          reason: 'a cache keyed on the query must not serve the old spans');
      expect(marinadeSpans.any((s) => s.startsWith('marinade|')), isTrue);
      expect(marinadeSpans.any((s) => s.startsWith('plancha|')), isFalse,
          reason: 'the previous query no longer highlights anything');

      await _pumpHighlightCard(tester, const <String>['plancha']);
      expect(_spanSignature(tester), equals(planchaSpans),
          reason: 'the cache hit reproduces the first run byte for byte');
      expect(tester.takeException(), isNull);
    });

    testWidgets('clearing the query drops every highlight span',
        (tester) async {
      tester.view.physicalSize = _phoneSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pumpHighlightCard(tester, const <String>['plancha']);
      expect(_spanSignature(tester), isNotEmpty);

      await _pumpHighlightCard(tester, const <String>[]);
      expect(_spanSignature(tester), isEmpty,
          reason: 'an unstyled body renders as a plain Text, not a span run');
      expect(find.textContaining('plancha'), findsWidgets,
          reason: 'the verbatim words are still on screen');
      expect(tester.takeException(), isNull);
    });
  });

  group('term-link bucket index', () {
    test('finds the first whole-word occurrence and honours the '
        'first-occurrence-per-card set', () {
      final linked = <String>{};
      const body = 'Our kitchen loves ceviche in the summer. A good ceviche '
          'starts with the freshest fish available that day.';

      final first = BarrioTermLinks.matchesIn(body, alreadyLinked: linked);
      final ceviche =
          first.where((m) => m.foldedTerm == 'ceviche').toList(growable: false);
      expect(ceviche, hasLength(1),
          reason: 'a term repeated in one chunk links only its first use');
      expect(ceviche.single.start, body.indexOf('ceviche'));
      expect(linked, contains('ceviche'));

      // Second chunk of the SAME card: the threaded set suppresses it.
      final second = BarrioTermLinks.matchesIn(body, alreadyLinked: linked);
      expect(second.where((m) => m.foldedTerm == 'ceviche'), isEmpty,
          reason: 'the already-linked set carries across the card\'s chunks');
    });

    test('never matches inside a longer word', () {
      final matches = BarrioTermLinks.matchesIn(
        'The cevicheria down the street is packed.',
        alreadyLinked: <String>{},
      );
      expect(matches.where((m) => m.foldedTerm == 'ceviche'), isEmpty);
    });

    test('a blocked occurrence is dropped without consuming the term', () {
      final linked = <String>{};
      const body = 'Our kitchen loves ceviche in the summer.';
      final start = body.indexOf('ceviche');
      final matches = BarrioTermLinks.matchesIn(
        body,
        alreadyLinked: linked,
        blockedRanges: <List<int>>[
          <int>[start, start + 'ceviche'.length],
        ],
      );
      expect(matches.where((m) => m.foldedTerm == 'ceviche'), isEmpty);
      expect(linked, isNot(contains('ceviche')),
          reason: 'a later clean occurrence on the card may still link');
    });

    test('accepted matches never overlap and stay in reading order', () {
      final matches = BarrioTermLinks.matchesIn(
        'A ceviche, then a tostada, then more ceviche and a torta.',
        alreadyLinked: <String>{},
      );
      for (var i = 1; i < matches.length; i++) {
        expect(matches[i].start, greaterThanOrEqualTo(matches[i - 1].end));
      }
    });
  });
}
