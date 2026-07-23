// Bookmarks + Saved shelf (operator-approved rec #8, 2026-07-23).
//
// Local persistence for saved training cards, following the same
// shared_preferences patterns as BarrioReadingProgressService: facts
// only, device-local, never demo-aware, and every method swallows
// platform-store failures (a device without a working preferences
// store reads as "nothing saved" and writes are no-ops).
//
// A bookmark is a (docId, chapterIndex, unitInChapter) tuple in
// CONTENT-CARD coordinates: the pre-quiz flatten the whole reader
// already stores for positions and search jumps, which
// TrainingDeck.deckPageForContentPage keeps stable when quiz cards are
// present (#1483 coordinate-stability contract). Quiz cards are never
// bookmarkable.
//
// Storage: one string list under [kBookmarksKey], each entry
// 'docId:chapterIndex:unitInChapter', in save order (oldest first).
// A bookmark whose manual is hidden for the viewer (B18) or whose
// coordinates no longer resolve is simply not RENDERED by consumers;
// it stays in storage so it reappears if visibility or content
// returns.

import 'package:shared_preferences/shared_preferences.dart';

/// One saved card in content-card coordinates.
class BarrioBookmark {
  final String docId;
  final int chapterIndex;
  final int unitInChapter;

  const BarrioBookmark({
    required this.docId,
    required this.chapterIndex,
    required this.unitInChapter,
  });

  /// The stored string form: 'docId:chapterIndex:unitInChapter'.
  String get storageKey => '$docId:$chapterIndex:$unitInChapter';

  /// Parses a stored entry; null on any malformation so a corrupt
  /// value reads as "not saved" instead of crashing.
  static BarrioBookmark? decode(String raw) {
    final lastColon = raw.lastIndexOf(':');
    if (lastColon <= 0) return null;
    final midColon = raw.lastIndexOf(':', lastColon - 1);
    if (midColon <= 0) return null;
    final docId = raw.substring(0, midColon);
    final chapter = int.tryParse(raw.substring(midColon + 1, lastColon));
    final unit = int.tryParse(raw.substring(lastColon + 1));
    if (docId.isEmpty || chapter == null || unit == null) return null;
    if (chapter < 0 || unit < 0) return null;
    return BarrioBookmark(
      docId: docId,
      chapterIndex: chapter,
      unitInChapter: unit,
    );
  }
}

/// Local persistence for saved training cards.
class BarrioBookmarksService {
  BarrioBookmarksService._();

  /// Preference key holding the saved-card entry list.
  static const String kBookmarksKey = 'barrio_bookmarks';

  /// All saved cards in save order (oldest first). Empty when nothing
  /// is saved or the store is unavailable.
  static Future<List<BarrioBookmark>> getAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(kBookmarksKey) ?? const <String>[];
      return <BarrioBookmark>[
        for (final entry in raw)
          if (BarrioBookmark.decode(entry) != null)
            BarrioBookmark.decode(entry)!,
      ];
    } catch (_) {
      return const <BarrioBookmark>[];
    }
  }

  /// The saved (chapterIndex, unitInChapter) local keys
  /// ('chapter:unit') for one doc, for cheap card-toggle lookups.
  static Future<Set<String>> localKeysFor(String docId) async {
    final all = await getAll();
    return <String>{
      for (final b in all)
        if (b.docId == docId) '${b.chapterIndex}:${b.unitInChapter}',
    };
  }

  /// Saves a card. Idempotent: an already saved card writes nothing.
  static Future<void> add(
    String docId,
    int chapterIndex,
    int unitInChapter,
  ) async {
    final bookmark = BarrioBookmark(
      docId: docId,
      chapterIndex: chapterIndex,
      unitInChapter: unitInChapter,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(kBookmarksKey) ?? const <String>[];
      if (list.contains(bookmark.storageKey)) return;
      await prefs.setStringList(
        kBookmarksKey,
        <String>[...list, bookmark.storageKey],
      );
    } catch (_) {
      // Persistence unavailable: writes are no-ops.
    }
  }

  /// Removes a saved card. Removing an absent card writes nothing.
  static Future<void> remove(
    String docId,
    int chapterIndex,
    int unitInChapter,
  ) async {
    final key = BarrioBookmark(
      docId: docId,
      chapterIndex: chapterIndex,
      unitInChapter: unitInChapter,
    ).storageKey;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(kBookmarksKey) ?? const <String>[];
      if (!list.contains(key)) return;
      await prefs.setStringList(
        kBookmarksKey,
        <String>[
          for (final entry in list)
            if (entry != key) entry,
        ],
      );
    } catch (_) {
      // Persistence unavailable: writes are no-ops.
    }
  }
}
