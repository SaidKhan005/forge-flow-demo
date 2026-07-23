// Chapter-end quick-check deck assembly (2026-07-23 operator-approved
// rec #4b).
//
// Builds the training reader's flat card deck for one doc: every
// chapter's verbatim content cards in reading order, then that
// chapter's quick-check quiz cards when the doc has a bank in
// [kBarrioQuizBanks]. Pure assembly, no I/O, no widget imports.
//
// Coordinate-stability contract (binding for search jumps, the A-Z
// index, resume positions, and read marks):
//   * Quiz cards are APPENDED after a chapter's content cards, never
//     interleaved, so content card k of chapter i sits at
//     `chapterStarts[i] + k` exactly as it did before quiz insertion.
//     Stored (chapter, unitInChapter) positions and search results keep
//     resolving to the same content cards.
//   * The A-Z index sheet still emits pages in the PRE-QUIZ content
//     flatten; [TrainingDeck.deckPageForContentPage] converts them.
//   * Quiz cards are not content cards: read-mark totals and reading
//     positions never count or store them (Metric Honesty: "N of M
//     cards read" keeps meaning content cards only).
// Docs without a bank build a deck identical to the plain flatten.

import '../content/company_handbook_content.dart';
import '../content/quiz/barrio_quiz_models.dart';
import '../content/training/barrio_training_doc.dart';

/// One slot in the training reader's flat deck: either a verbatim
/// content card or a chapter-end quick-check quiz card.
class TrainingDeckEntry {
  /// The content card, when this slot is a content card. Null for quiz.
  final HandbookUnit? unit;

  /// The quiz question, when this slot is a quick-check card. Null for
  /// content.
  final BarrioQuizQuestion? question;

  const TrainingDeckEntry.content(HandbookUnit this.unit) : question = null;

  const TrainingDeckEntry.quiz(BarrioQuizQuestion this.question) : unit = null;

  /// True for a quick-check quiz card.
  bool get isQuiz => question != null;
}

/// The assembled flat deck for one training doc, plus the coordinate
/// tables the reader needs to keep every pre-quiz jump target stable.
class TrainingDeck {
  /// Every deck card in reading order (content, then that chapter's
  /// quiz cards, per chapter).
  final List<TrainingDeckEntry> entries;

  /// Deck page of each chapter's first card. Because quiz cards append
  /// after content, this is also the deck page of the chapter's first
  /// CONTENT card, and content card k of chapter i lives at
  /// `chapterStarts[i] + k`.
  final List<int> chapterStarts;

  /// Page of each chapter's first card in the PRE-QUIZ content flatten
  /// (the coordinate space the A-Z index sheet emits).
  final List<int> contentStarts;

  /// Total number of CONTENT cards (the honest "M" in "N of M cards
  /// read"; quiz cards never count).
  final int contentCardCount;

  const TrainingDeck({
    required this.entries,
    required this.chapterStarts,
    required this.contentStarts,
    required this.contentCardCount,
  });

  /// Total deck cards (content + quiz).
  int get length => entries.length;

  /// Chapter that owns the deck card at [page]. A chapter's quiz cards
  /// sit before the next chapter's start, so they belong to their own
  /// chapter (the hero and rail follow them correctly).
  int chapterOf(int page) {
    var chapter = 0;
    for (var i = 0; i < chapterStarts.length; i++) {
      if (chapterStarts[i] > page) break;
      chapter = i;
    }
    return chapter;
  }

  /// Maps a page in the pre-quiz content flatten (A-Z index sheet
  /// coordinates) to its deck page. Identity for docs without a bank.
  int deckPageForContentPage(int contentPage) {
    if (contentStarts.isEmpty) return 0;
    var chapter = 0;
    for (var i = 0; i < contentStarts.length; i++) {
      if (contentStarts[i] > contentPage) break;
      chapter = i;
    }
    return chapterStarts[chapter] + (contentPage - contentStarts[chapter]);
  }
}

/// Assembles the flat deck for [doc]. [quizBanks] defaults to the real
/// registry; tests may inject fixture banks.
TrainingDeck buildTrainingDeck(
  BarrioTrainingDoc doc, {
  Map<String, BarrioQuizBank>? quizBanks,
}) {
  final bank = (quizBanks ?? kBarrioQuizBanks)[doc.id];
  final byChapter =
      bank?.questionsByChapter ?? const <String, List<BarrioQuizQuestion>>{};
  final entries = <TrainingDeckEntry>[];
  final chapterStarts = <int>[];
  final contentStarts = <int>[];
  var contentCardCount = 0;
  for (final chapter in doc.chapters) {
    chapterStarts.add(entries.length);
    contentStarts.add(contentCardCount);
    for (final unit in chapter.units) {
      entries.add(TrainingDeckEntry.content(unit));
    }
    contentCardCount += chapter.units.length;
    final questions = byChapter[chapter.id];
    if (questions != null) {
      for (final question in questions) {
        entries.add(TrainingDeckEntry.quiz(question));
      }
    }
  }
  return TrainingDeck(
    entries: entries,
    chapterStarts: chapterStarts,
    contentStarts: contentStarts,
    contentCardCount: contentCardCount,
  );
}
