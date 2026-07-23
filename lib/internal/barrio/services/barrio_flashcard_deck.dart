// Flashcard review decks for the glossary manuals (operator-approved
// rec #5, 2026-07-23). The three TERM-card manuals (Latin Ingredients,
// Latin Dishes, Words To Know) are already flashcard-shaped: every unit
// is a term title plus a verbatim definition body, and most carry a
// source picture. This service flattens those docs into decks for
// `BarrioFlashcardReviewScreen` and runs the in-session review queue.
//
// Retrieval-practice posture: the session is memory-free by design.
// "Got it" is the reader's own claim, not an app metric; nothing about
// mastery is persisted anywhere (Metric Honesty: the session only
// counts what actually happened inside itself, and forgets on exit).

import 'dart:math';

import '../content/training/barrio_training_doc.dart';
import '../content/training/training_docs.dart';

/// Destination ids of the manuals that have a flashcard deck. Only
/// these three are flashcard-shaped (term + verbatim definition per
/// card); the narrative manuals are not deck material.
const Set<String> kBarrioFlashcardManualIds = <String>{
  'training_latin_ingredients',
  'training_latin_dishes',
  'training_general_words',
};

/// The combined interleaved deck (evidence-backed interleaving of the
/// two food glossaries). Order here is the canonical pre-shuffle
/// concatenation order; the session always shuffles before showing.
const List<String> kBarrioCombinedFlashcardManualIds = <String>[
  'training_latin_dishes',
  'training_latin_ingredients',
];

/// Stable id for the combined deck (not a destination id on purpose:
/// the combined deck is a review surface, not a manual).
const String kBarrioCombinedFlashcardDeckId =
    'barrio_flashcards_dishes_ingredients';

/// Operator-facing title of the combined deck.
const String kBarrioCombinedFlashcardDeckTitle = 'Dishes + Ingredients';

/// One review card: the term on the front, the verbatim definition on
/// the back. Content is carried from the source unit unchanged.
class BarrioFlashcard {
  /// Stable id: the source `HandbookUnit.id`.
  final String id;

  /// Front of the card: the term, verbatim unit title.
  final String term;

  /// Back of the card: the verbatim unit body, unchanged.
  final String body;

  /// Front picture: the unit's first image asset, when it has one.
  final String? imageAssetPath;

  /// Literal source caption for [imageAssetPath]; shown with the
  /// definition on the back. Null when the source carries none.
  final String? imageCaption;

  const BarrioFlashcard({
    required this.id,
    required this.term,
    required this.body,
    this.imageAssetPath,
    this.imageCaption,
  });
}

/// A named deck in canonical (pre-shuffle) order. The review screen
/// shuffles a copy per session; the deck itself stays stable.
class BarrioFlashcardDeck {
  final String id;
  final String title;
  final List<BarrioFlashcard> cards;

  const BarrioFlashcardDeck({
    required this.id,
    required this.title,
    required this.cards,
  });
}

/// Flattens a training doc into cards, chapter order preserved. Every
/// unit becomes one card; the first unit image (when present) rides on
/// the card front with its caption on the back.
List<BarrioFlashcard> barrioFlashcardsFromDoc(BarrioTrainingDoc doc) {
  return <BarrioFlashcard>[
    for (final chapter in doc.chapters)
      for (final unit in chapter.units)
        BarrioFlashcard(
          id: unit.id,
          term: unit.title,
          body: unit.body,
          imageAssetPath:
              unit.images.isEmpty ? null : unit.images.first.assetPath,
          imageCaption: unit.images.isEmpty ? null : unit.images.first.caption,
        ),
  ];
}

/// Deck for a single glossary manual, or null when [destinationId] is
/// not one of the three flashcard manuals (or is missing from the
/// training registry). [title] is the operator-facing deck name (the
/// shelf passes the destination label).
BarrioFlashcardDeck? barrioFlashcardDeckForManual(
  String destinationId, {
  required String title,
}) {
  if (!kBarrioFlashcardManualIds.contains(destinationId)) return null;
  final doc = kBarrioTrainingDocs[destinationId];
  if (doc == null) return null;
  return BarrioFlashcardDeck(
    id: destinationId,
    title: title,
    cards: barrioFlashcardsFromDoc(doc),
  );
}

/// The combined Dishes + Ingredients deck: exactly both manuals' units,
/// nothing else. Interleaving happens at shuffle time.
BarrioFlashcardDeck barrioCombinedDishesIngredientsDeck() {
  return BarrioFlashcardDeck(
    id: kBarrioCombinedFlashcardDeckId,
    title: kBarrioCombinedFlashcardDeckTitle,
    cards: <BarrioFlashcard>[
      for (final docId in kBarrioCombinedFlashcardManualIds)
        ...barrioFlashcardsFromDoc(kBarrioTrainingDocs[docId]!),
    ],
  );
}

/// Seedable shuffle: the same [rng] seed always yields the same order
/// (deterministic for tests); the input list is never mutated.
List<BarrioFlashcard> shuffleBarrioFlashcards(
  List<BarrioFlashcard> cards,
  Random rng,
) {
  return List<BarrioFlashcard>.of(cards)..shuffle(rng);
}

/// One in-session review pass over a shuffled deck.
///
/// The queue starts as the shuffled deck. "Got it" retires the front
/// card; "See it again" recycles it [kSeeAgainGap] cards later (or to
/// the end when fewer remain), marked as a repeat appearance. Session
/// state only; nothing here is ever persisted.
class BarrioFlashcardSession {
  /// How many other cards show before a recycled card comes back.
  static const int kSeeAgainGap = 3;

  /// Unique cards in the deck (repeats never inflate this).
  final int totalCards;

  final List<_BarrioQueuedCard> _queue;
  final Set<String> _introducedIds = <String>{};
  final Set<String> _repeatedIds = <String>{};

  BarrioFlashcardSession(List<BarrioFlashcard> deckOrder)
      : totalCards = deckOrder.length,
        _queue = <_BarrioQueuedCard>[
          for (final card in deckOrder) _BarrioQueuedCard(card, isRepeat: false),
        ] {
    _noteCurrentIntroduced();
  }

  /// The card currently showing, or null when the deck is finished.
  BarrioFlashcard? get current => _queue.isEmpty ? null : _queue.first.card;

  /// True when the showing card is a recycled ("See it again") pass.
  bool get currentIsRepeat => _queue.isNotEmpty && _queue.first.isRepeat;

  bool get isFinished => _queue.isEmpty;

  /// Honest "Card X of N" numerator: how many distinct cards have been
  /// shown so far (a repeat appearance does not advance it).
  int get introducedCount => _introducedIds.length;

  /// Recycled cards still waiting behind the current one.
  int get queuedRepeatCount {
    var count = 0;
    for (var i = 1; i < _queue.length; i++) {
      if (_queue[i].isRepeat) count++;
    }
    return count;
  }

  /// Distinct cards the reader asked to see again at least once.
  int get repeatedCardCount => _repeatedIds.length;

  /// Retires the front card. "Got it" is the reader's claim; the
  /// session just moves on.
  void markGotIt() {
    if (_queue.isEmpty) return;
    _queue.removeAt(0);
    _noteCurrentIntroduced();
  }

  /// Recycles the front card to later in the deck.
  void markSeeAgain() {
    if (_queue.isEmpty) return;
    final entry = _queue.removeAt(0);
    _repeatedIds.add(entry.card.id);
    _queue.insert(
      min(kSeeAgainGap, _queue.length),
      _BarrioQueuedCard(entry.card, isRepeat: true),
    );
    _noteCurrentIntroduced();
  }

  void _noteCurrentIntroduced() {
    final card = current;
    if (card != null) _introducedIds.add(card.id);
  }
}

class _BarrioQueuedCard {
  final BarrioFlashcard card;
  final bool isRepeat;

  const _BarrioQueuedCard(this.card, {required this.isRepeat});
}
