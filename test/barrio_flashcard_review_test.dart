// Widget tests for the flashcard review mode (operator rec #5,
// 2026-07-23), all at a 390x844 phone viewport.
//
// Review screen: front shows the term (and the picture variant), tap
// flips to the VERBATIM body, "See it again" recycles the card to
// later in the deck, the end state reports honest counts, reshuffle
// restarts, exit pops.
//
// Home shelf entry: the prominent Flashcards pill renders only on the
// three glossary manuals (2026-07-26: relabeled from REVIEW and made
// prominent; the combined REVIEW BOTH header pill was removed by
// operator request), and a resolver-hidden manual gets no flashcard
// entry at all.
//
// The shelf runs looping bubble animations: NEVER pumpAndSettle in
// the shelf tests; pump explicit durations only. Every test asserts
// takeException() is null (overflow guard).

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destination_visibility_resolver.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_flashcard_review_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_flashcard_deck.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_shelf.dart';

/// B18 resolver that denies a fixed id set: proves review entries are
/// gated by the resolver, not the preview role.
class _DenyIdsResolver implements BarrioDestinationVisibilityResolver {
  final Set<String> denied;

  const _DenyIdsResolver(this.denied);

  @override
  bool isVisible(BarrioDestination destination) =>
      !denied.contains(destination.id);
}

const _kFixtureCards = <BarrioFlashcard>[
  BarrioFlashcard(
    id: 'fx1',
    term: 'FIXTURE ONE',
    body: 'First fixture definition body, word for word.',
  ),
  BarrioFlashcard(
    id: 'fx2',
    term: 'FIXTURE TWO',
    body: 'Second fixture definition body.',
  ),
  BarrioFlashcard(
    id: 'fx3',
    term: 'FIXTURE THREE',
    body: 'Third fixture definition body.',
  ),
  BarrioFlashcard(
    id: 'fx4',
    term: 'FIXTURE FOUR',
    body: 'Fourth fixture definition body.',
  ),
  BarrioFlashcard(
    id: 'fx5',
    term: 'FIXTURE FIVE',
    body: 'Fifth fixture definition body.',
  ),
];

const _kFixtureDeck = BarrioFlashcardDeck(
  id: 'fixture_deck',
  title: 'Fixture Deck',
  cards: _kFixtureCards,
);

/// One-card deck with a picture (missing asset: the card's errorBuilder
/// icon fallback keeps tests byte-free, same as the home bubbles).
const _kPictureDeck = BarrioFlashcardDeck(
  id: 'picture_deck',
  title: 'Picture Deck',
  cards: [
    BarrioFlashcard(
      id: 'pic1',
      term: 'PICTURE TERM',
      body: 'Definition behind the picture card.',
      imageAssetPath: 'assets/internal/barrio/training/fixture/missing.webp',
      imageCaption: 'Fixture picture caption',
    ),
  ],
);

void main() {
  const phoneSize = Size(390, 844);
  const seed = 7;

  /// The exact order the screen will show under [seed]: the screen's
  /// session shuffles with the same seedable function.
  final expectedOrder =
      shuffleBarrioFlashcards(_kFixtureCards, Random(seed));

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpReview(
    WidgetTester tester, {
    BarrioFlashcardDeck deck = _kFixtureDeck,
  }) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: BarrioFlashcardReviewScreen(
          deck: deck,
          accent: BarrioColors.tealWarm,
          shuffleSeed: seed,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> tapButton(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump(const Duration(milliseconds: 80));
  }

  group('review screen', () {
    testWidgets('front shows the term and honest counter, not the body',
        (tester) async {
      await pumpReview(tester);
      final first = expectedOrder.first;

      expect(find.text(first.term), findsOneWidget);
      expect(find.text(first.body), findsNothing,
          reason: 'the definition stays hidden until the flip');
      expect(find.text('Card 1 of 5'), findsOneWidget);
      expect(find.textContaining('queued to repeat'), findsNothing,
          reason: 'no phantom zero repeat counter');
      expect(find.text('Tap to flip'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('picture variant: front carries the image, back carries '
        'the caption with the verbatim body', (tester) async {
      await pumpReview(tester, deck: _kPictureDeck);

      expect(find.text('PICTURE TERM'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget,
          reason: 'a card with a source picture shows it on the front');
      expect(find.text('Fixture picture caption'), findsNothing);

      await tester.tap(find.text('PICTURE TERM'));
      await tester.pump(); // start the flip ticker
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Definition behind the picture card.'), findsOneWidget,
          reason: 'the back shows the verbatim definition');
      expect(find.text('Fixture picture caption'), findsOneWidget,
          reason: 'the literal source caption rides with the definition');
      expect(find.byType(Image), findsNothing,
          reason: 'the back is text only');
      expect(tester.takeException(), isNull);
    });

    testWidgets('tap flips to the verbatim body and tapping again flips '
        'back', (tester) async {
      await pumpReview(tester);
      final first = expectedOrder.first;

      await tester.tap(find.text(first.term));
      await tester.pump(); // start the flip ticker
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(first.body), findsOneWidget,
          reason: 'the body is the unit text, unchanged');

      await tester.tap(find.text(first.body));
      await tester.pump(); // start the reverse flip ticker
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(first.body), findsNothing);
      expect(find.text(first.term), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('See it again recycles the card to later in the deck with '
        'honest repeat counters', (tester) async {
      await pumpReview(tester);
      final order = expectedOrder;

      // Recycle the first card: it must come back after 3 other cards.
      await tapButton(tester, 'See it again');
      expect(find.text(order[1].term), findsOneWidget);
      expect(find.text('Card 2 of 5'), findsOneWidget);
      expect(find.text('1 queued to repeat'), findsOneWidget);
      expect(find.text('REPEAT'), findsNothing);

      await tapButton(tester, 'Got it'); // order[1]
      await tapButton(tester, 'Got it'); // order[2]
      await tapButton(tester, 'Got it'); // order[3]

      expect(find.text(order[0].term), findsOneWidget,
          reason: 'the recycled card returns later in the deck');
      expect(find.text('REPEAT'), findsOneWidget,
          reason: 'a repeat appearance is labeled honestly');
      expect(find.text('Card 4 of 5'), findsOneWidget,
          reason: 'a repeat never advances the distinct-card counter');
      expect(tester.takeException(), isNull);
    });

    testWidgets('end state reports honest counts, reshuffles, and exits',
        (tester) async {
      await pumpReview(tester);

      // One recycle + finish everything.
      await tapButton(tester, 'See it again');
      for (var i = 0; i < 5; i++) {
        await tapButton(tester, 'Got it');
      }

      expect(find.text('Deck finished: 5 cards, 1 repeated.'), findsOneWidget,
          reason: 'the finish line reports what actually happened');
      expect(find.text('Shuffle again'), findsOneWidget);
      expect(find.text('Exit'), findsOneWidget);

      await tapButton(tester, 'Shuffle again');
      expect(find.text('Card 1 of 5'), findsOneWidget,
          reason: 'reshuffle starts a fresh pass over the same deck');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a pass with no repeats omits the repeat count entirely',
        (tester) async {
      await pumpReview(tester);
      for (var i = 0; i < 5; i++) {
        await tapButton(tester, 'Got it');
      }
      expect(find.text('Deck finished: 5 cards.'), findsOneWidget,
          reason: 'no phantom "0 repeated"');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Exit pops back to the previous screen', (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('base screen'))),
        ),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const BarrioFlashcardReviewScreen(
            deck: _kPictureDeck,
            shuffleSeed: 1,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(BarrioFlashcardReviewScreen), findsOneWidget);

      await tapButton(tester, 'Got it');
      await tapButton(tester, 'Exit');
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(BarrioFlashcardReviewScreen), findsNothing);
      expect(find.text('base screen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('home shelf review entry', () {
    Future<void> pumpShelf(
      WidgetTester tester, {
      BarrioDestinationVisibilityResolver? resolver,
    }) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: BarrioHomeShelf(
              destinations:
                  barrioDestinations.where((d) => d.showOnHomeHub).toList(),
              visibilityResolver: resolver,
              onDestinationTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1000));
    }

    Future<void> scrollTo(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(
        finder,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    /// Parks [sectionTitle] near the top, then drags its horizontal
    /// bubble row leftward until [target] is built (or drags run out).
    Future<void> dragRowUntil(
      WidgetTester tester,
      String sectionTitle,
      Finder target,
    ) async {
      await scrollTo(tester, find.text(sectionTitle));
      final headerY = tester.getCenter(find.text(sectionTitle)).dy;
      await tester.drag(
          find.byType(CustomScrollView), Offset(0, 300.0 - headerY));
      await tester.pump(const Duration(milliseconds: 60));
      var attempts = 0;
      while (target.evaluate().isEmpty && attempts < 14) {
        final rowPoint = Offset(
            195, tester.getCenter(find.text(sectionTitle)).dy + 88);
        await tester.dragFrom(rowPoint, const Offset(-240, 0));
        await tester.pump(const Duration(milliseconds: 60));
        attempts++;
      }
    }

    testWidgets('the three glossary manuals carry a prominent Flashcards '
        'pill; narrative manuals do not; the combined header pill is gone',
        (tester) async {
      await pumpShelf(tester);

      await scrollTo(tester, find.text('Food & Drink'));
      expect(find.byKey(const Key('barrio_review_pill_combined')),
          findsNothing,
          reason: 'the combined REVIEW BOTH header pill was removed');
      expect(find.text('REVIEW BOTH'), findsNothing,
          reason: 'the REVIEW BOTH wording is gone');
      expect(
          find.byKey(const Key('barrio_review_pill_training_tequila')),
          findsNothing,
          reason: 'narrative manuals get no flashcard entry');

      await dragRowUntil(
        tester,
        'Food & Drink',
        find.byKey(const Key('barrio_review_pill_training_latin_dishes')),
      );
      expect(
          find.byKey(const Key('barrio_review_pill_training_latin_dishes')),
          findsOneWidget);
      // The visible label is the clear 'Flashcards' wording (relabeled
      // from the old 'REVIEW' 2026-07-26).
      expect(
          find.descendant(
            of: find.byKey(
                const Key('barrio_review_pill_training_latin_dishes')),
            matching: find.text('Flashcards'),
          ),
          findsOneWidget,
          reason: 'the pill reads Flashcards, not REVIEW');

      await dragRowUntil(
        tester,
        'Food & Drink',
        find.byKey(
            const Key('barrio_review_pill_training_latin_ingredients')),
      );
      expect(
          find.byKey(
              const Key('barrio_review_pill_training_latin_ingredients')),
          findsOneWidget);

      await dragRowUntil(
        tester,
        'Service & Hospitality',
        find.byKey(const Key('barrio_review_pill_training_general_words')),
      );
      expect(
          find.byKey(const Key('barrio_review_pill_training_general_words')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a resolver-hidden manual gets no flashcard entry; the '
        'visible half keeps its own', (tester) async {
      await pumpShelf(
        tester,
        resolver: const _DenyIdsResolver({'training_latin_dishes'}),
      );

      await dragRowUntil(
          tester, 'Food & Drink', find.text('Latin Dishes'));
      expect(find.text('Latin Dishes'), findsOneWidget,
          reason: 'the dimmed bubble itself still renders');
      expect(
          find.byKey(const Key('barrio_review_pill_training_latin_dishes')),
          findsNothing,
          reason: 'a hidden manual gets no flashcard entry');

      await dragRowUntil(
        tester,
        'Food & Drink',
        find.byKey(
            const Key('barrio_review_pill_training_latin_ingredients')),
      );
      expect(
          find.byKey(
              const Key('barrio_review_pill_training_latin_ingredients')),
          findsOneWidget,
          reason: 'the visible manual keeps its own review entry');
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a manual Flashcards pill pushes its deck',
        (tester) async {
      await pumpShelf(tester);

      const pillKey =
          Key('barrio_review_pill_training_latin_ingredients');
      await dragRowUntil(tester, 'Food & Drink', find.byKey(pillKey));
      await tester.tap(find.byKey(pillKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(BarrioFlashcardReviewScreen), findsOneWidget);
      expect(find.text('Latin Ingredients'), findsOneWidget,
          reason: 'the deck carries the manual label as its title');
      expect(find.text('Card 1 of 54'), findsOneWidget,
          reason: 'honest counter over the 54-term glossary');
      expect(tester.takeException(), isNull);

      // Dispose the covered shelf's looping animations cleanly.
      await tester.pumpWidget(const SizedBox());
    });
  });
}
