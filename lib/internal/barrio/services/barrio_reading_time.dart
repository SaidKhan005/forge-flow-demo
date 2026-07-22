// "The app remembers you" slice (2026-07-22): reading-time estimates.
//
// Word counts are computed at RUNTIME from the in-memory training-doc
// content (never from the generated content files themselves, which
// stay byte-identical), lazily and cached once per doc id. 200 words
// per minute, rounded, with an honest floor of "about 1 min".

import '../content/training/barrio_training_doc.dart';

/// Runtime reading-time estimates for training docs and chapters.
class BarrioReadingTime {
  BarrioReadingTime._();

  /// Average adult reading speed used for the estimate.
  static const int wordsPerMinute = 200;

  static final RegExp _whitespace = RegExp(r'\s+');

  /// Per-chapter word counts, cached once per doc id (content is
  /// compile-time const, so a doc's counts never change at runtime).
  static final Map<String, List<int>> _chapterWordsByDocId = {};

  static int _wordCount(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    return trimmed.split(_whitespace).length;
  }

  static List<int> _chapterWords(BarrioTrainingDoc doc) {
    return _chapterWordsByDocId.putIfAbsent(doc.id, () {
      return [
        for (final chapter in doc.chapters)
          chapter.units.fold<int>(
            0,
            (sum, unit) => sum + _wordCount(unit.title) + _wordCount(unit.body),
          ),
      ];
    });
  }

  static int _minutesForWords(int words) {
    final minutes = (words / wordsPerMinute).round();
    return minutes < 1 ? 1 : minutes;
  }

  /// Estimated minutes to read the whole doc (minimum 1).
  static int docMinutes(BarrioTrainingDoc doc) {
    final words = _chapterWords(doc).fold<int>(0, (sum, w) => sum + w);
    return _minutesForWords(words);
  }

  /// Estimated minutes to read chapter [chapterIndex] (minimum 1).
  /// Out-of-range indices return the floor of 1 rather than throwing.
  static int chapterMinutes(BarrioTrainingDoc doc, int chapterIndex) {
    final words = _chapterWords(doc);
    if (chapterIndex < 0 || chapterIndex >= words.length) return 1;
    return _minutesForWords(words[chapterIndex]);
  }

  /// Operator-facing label for [minutes]: 'about N min'.
  static String label(int minutes) => 'about $minutes min';
}
