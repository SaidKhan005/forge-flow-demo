// Unit tests for the flashcard deck builder + in-session review queue
// (operator rec #5, 2026-07-23).
//
// Pins: (1) doc flattening carries every unit verbatim with its first
// image, (2) only the three glossary manuals build decks, (3) the
// combined deck is exactly both manuals' units, (4) the seedable
// shuffle is deterministic and lossless, (5) "See it again" recycles a
// card kSeeAgainGap later with honest counters, (6) edge behavior at
// the deck tail and on empty decks.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_flashcard_deck.dart';

BarrioFlashcard _card(String id) =>
    BarrioFlashcard(id: id, term: 'Term $id', body: 'Body $id');

void main() {
  group('deck builder', () {
    test('flattens every ingredients unit in order with the first image '
        'and caption', () {
      final doc = kBarrioTrainingDocs['training_latin_ingredients']!;
      final units = doc.chapters.expand((c) => c.units).toList();
      final cards = barrioFlashcardsFromDoc(doc);

      expect(cards.length, units.length);
      expect(cards.length, 54, reason: 'the ingredients glossary has 54 terms');
      for (var i = 0; i < units.length; i++) {
        expect(cards[i].id, units[i].id);
        expect(cards[i].term, units[i].title, reason: 'term is verbatim');
        expect(cards[i].body, units[i].body, reason: 'body is verbatim');
        if (units[i].images.isEmpty) {
          expect(cards[i].imageAssetPath, isNull);
          expect(cards[i].imageCaption, isNull);
        } else {
          expect(cards[i].imageAssetPath, units[i].images.first.assetPath);
          expect(cards[i].imageCaption, units[i].images.first.caption);
        }
      }
    });

    test('general words deck has 92 term cards, each picture matching its '
        'source card', () {
      final doc = kBarrioTrainingDocs['training_general_words']!;
      final units = [for (final c in doc.chapters) ...c.units];
      final deck = barrioFlashcardDeckForManual(
        'training_general_words',
        title: 'Words To Know',
      );
      expect(deck, isNotNull);
      expect(deck!.cards.length, 92);
      // Build 32 gave part of this glossary real photographs, so the deck
      // is a mix: a card shows a picture when, and only when, its source
      // card carries a real photo. Diagram pictograms stay out of the deck
      // (a pictogram is not a photo of the thing), so those fronts are the
      // branded definition card (FC-2), never a blank frame.
      expect(deck.cards.length, units.length);
      for (var i = 0; i < deck.cards.length; i++) {
        expect(deck.cards[i].imageAssetPath, units[i].firstPhoto?.assetPath,
            reason: '${units[i].title} matches its source card');
      }
      expect(deck.cards.any((c) => c.imageAssetPath != null), isTrue,
          reason: 'sanity: build 32 gave some of these terms pictures');
    });

    test('every flashcard manual id builds a deck; other manuals do not', () {
      for (final id in kBarrioFlashcardManualIds) {
        expect(barrioFlashcardDeckForManual(id, title: 'x'), isNotNull,
            reason: '$id must build a deck');
      }
      expect(
        barrioFlashcardDeckForManual('training_tequila', title: 'x'),
        isNull,
        reason: 'narrative manuals are not flashcard decks',
      );
      expect(
        barrioFlashcardDeckForManual('forge_and_flow', title: 'x'),
        isNull,
      );
    });

    test('combined deck contains exactly both manuals units', () {
      final deck = barrioCombinedDishesIngredientsDeck();
      final expectedIds = <String>[
        for (final docId in kBarrioCombinedFlashcardManualIds)
          for (final chapter in kBarrioTrainingDocs[docId]!.chapters)
            for (final unit in chapter.units) unit.id,
      ];

      expect(deck.title, 'Dishes + Ingredients');
      expect(deck.cards.length, expectedIds.length);
      expect(deck.cards.length, 59 + 54,
          reason: '59 dishes + 54 ingredients, nothing else');
      expect(deck.cards.map((c) => c.id).toList(), expectedIds,
          reason: 'exactly both manuals units, no extras, no losses');
    });
  });

  group('seedable shuffle', () {
    test('same seed yields the same order; the input is not mutated', () {
      final deck = barrioCombinedDishesIngredientsDeck();
      final before = deck.cards.map((c) => c.id).toList();

      final a = shuffleBarrioFlashcards(deck.cards, Random(42));
      final b = shuffleBarrioFlashcards(deck.cards, Random(42));

      expect(a.map((c) => c.id).toList(), b.map((c) => c.id).toList(),
          reason: 'a fixed seed is deterministic');
      expect(deck.cards.map((c) => c.id).toList(), before,
          reason: 'the canonical deck order is never mutated');
    });

    test('different seeds yield different orders; no card lost or '
        'duplicated', () {
      final deck = barrioCombinedDishesIngredientsDeck();
      final a = shuffleBarrioFlashcards(deck.cards, Random(1));
      final b = shuffleBarrioFlashcards(deck.cards, Random(2));

      expect(a.map((c) => c.id).toList(),
          isNot(equals(b.map((c) => c.id).toList())),
          reason: 'different seeds reorder a 113-card deck');
      expect(a.map((c) => c.id).toSet(),
          deck.cards.map((c) => c.id).toSet(),
          reason: 'shuffle is lossless');
      expect(a.length, deck.cards.length);
    });
  });

  group('review session', () {
    test('See it again recycles the card kSeeAgainGap later with honest '
        'counters', () {
      final session = BarrioFlashcardSession(
        [_card('a'), _card('b'), _card('c'), _card('d'), _card('e')],
      );
      expect(session.totalCards, 5);
      expect(session.current!.id, 'a');
      expect(session.introducedCount, 1);
      expect(session.currentIsRepeat, isFalse);
      expect(session.queuedRepeatCount, 0);

      // a -> see it again: comes back after b, c, d (gap 3), before e.
      session.markSeeAgain();
      expect(session.current!.id, 'b');
      expect(session.introducedCount, 2);
      expect(session.queuedRepeatCount, 1,
          reason: 'the recycled a waits behind the current card');
      expect(session.repeatedCardCount, 1);

      session.markGotIt(); // b
      session.markGotIt(); // c
      expect(session.current!.id, 'd');
      expect(session.introducedCount, 4);

      session.markGotIt(); // d
      expect(session.current!.id, 'a',
          reason: 'the recycled card returns exactly gap cards later');
      expect(session.currentIsRepeat, isTrue);
      expect(session.introducedCount, 4,
          reason: 'a repeat appearance never advances Card X of N');
      expect(session.queuedRepeatCount, 0,
          reason: 'the showing repeat is no longer queued');

      session.markGotIt(); // a (second pass)
      expect(session.current!.id, 'e');
      expect(session.introducedCount, 5);

      session.markGotIt(); // e
      expect(session.isFinished, isTrue);
      expect(session.current, isNull);
      expect(session.repeatedCardCount, 1,
          reason: 'one distinct card was repeated');
    });

    test('See it again near the deck tail reappears immediately', () {
      final session = BarrioFlashcardSession([_card('a'), _card('b')]);
      session.markGotIt(); // a
      expect(session.current!.id, 'b');

      session.markSeeAgain(); // b is the only card left
      expect(session.isFinished, isFalse);
      expect(session.current!.id, 'b',
          reason: 'with nothing after it, the card comes right back');
      expect(session.currentIsRepeat, isTrue);

      session.markGotIt();
      expect(session.isFinished, isTrue);
      expect(session.repeatedCardCount, 1);
    });

    test('repeating the same card twice counts one distinct repeat', () {
      final session = BarrioFlashcardSession([_card('a'), _card('b')]);
      session.markSeeAgain(); // a
      session.markGotIt(); // b
      session.markSeeAgain(); // a again
      session.markGotIt(); // a
      expect(session.isFinished, isTrue);
      expect(session.repeatedCardCount, 1,
          reason: 'M counts distinct cards, not repeat taps');
    });

    test('empty deck is finished immediately and marks are safe no-ops', () {
      final session = BarrioFlashcardSession(const []);
      expect(session.isFinished, isTrue);
      expect(session.current, isNull);
      expect(session.introducedCount, 0);
      session.markGotIt();
      session.markSeeAgain();
      expect(session.isFinished, isTrue);
    });
  });
}
