// "The app remembers you" slice (2026-07-22, operator-approved):
// local reading memory for the Barrio training reader.
//
// One small persistence service over shared_preferences (the same
// lightweight local store BarrioStreakService already uses). It
// remembers, per training doc:
//   * the last reading position (chapter + card within the chapter),
//   * the set of cards that have actually been read (settled on
//     screen), stored as the cards' stable unit ids,
// plus a single "most recently read doc" pointer that drives the home
// screen's Continue Reading card.
//
// Metric Honesty: this service records facts only ("this card was on
// screen"), never claims ("completed", "learned"). Consumers must not
// render progress for docs with no recorded reads (no phantom zeroes).
//
// All state is LOCAL to the device. Readers never branch on kDemoMode
// and this service is not demo-aware in any way.
//
// Every method swallows platform-store failures and degrades to
// fresh-state behavior: a device (or test harness) without a working
// preferences store reads as "nothing read yet" and writes are no-ops.

import 'package:shared_preferences/shared_preferences.dart';

import 'barrio_refresher_scheduler.dart';

/// A saved reading position inside one training doc.
class BarrioReadingPosition {
  /// 0-based chapter (section) index. Consumers clamp against the
  /// current doc shape before use (content can change between builds).
  final int chapterIndex;

  /// 0-based card index within [chapterIndex]. Consumers clamp.
  final int unitInChapter;

  const BarrioReadingPosition({
    required this.chapterIndex,
    required this.unitInChapter,
  });
}

/// One read-only snapshot of everything the home screen needs:
/// the most recently read doc + its saved position, and the persisted
/// read-card id sets per doc (only docs with at least one read card
/// carry an entry, so "no entry" honestly means "untouched").
class BarrioReadingSnapshot {
  final String? lastDocId;
  final BarrioReadingPosition? lastPosition;
  final Map<String, Set<String>> readUnitIds;

  const BarrioReadingSnapshot({
    this.lastDocId,
    this.lastPosition,
    this.readUnitIds = const {},
  });

  static const BarrioReadingSnapshot empty = BarrioReadingSnapshot();
}

/// Local persistence for training-reader positions and read marks.
class BarrioReadingProgressService {
  BarrioReadingProgressService._();

  static const String _kLastDocKey = 'barrio_reading_last_doc';

  /// Preference key holding the saved position for [docId].
  static String positionKeyFor(String docId) => 'barrio_reading_pos_$docId';

  /// Preference key holding the read-card unit-id list for [docId].
  static String readCardsKeyFor(String docId) => 'barrio_reading_read_$docId';

  /// Preference key holding the finishedAt epoch-millis for [docId]
  /// (spaced refresher, rec #11): when the read-mark set first covered
  /// ALL content cards. Write-once; re-reading never resets it.
  static String finishedKeyFor(String docId) =>
      'barrio_reading_finished_$docId';

  /// Preference key holding the lastRefreshedAt epoch-millis for
  /// [docId]: when a refresher for the manual was last completed.
  static String refreshedAtKeyFor(String docId) =>
      'barrio_refresher_last_$docId';

  /// Preference key holding the completed-refresher count for [docId].
  static String refreshCountKeyFor(String docId) =>
      'barrio_refresher_count_$docId';

  /// Saves the last settled position for [docId] and marks it the most
  /// recently read doc.
  static Future<void> savePosition(
    String docId,
    int chapterIndex,
    int unitInChapter,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        positionKeyFor(docId),
        '$chapterIndex:$unitInChapter',
      );
      await prefs.setString(_kLastDocKey, docId);
    } catch (_) {
      // Persistence unavailable: writes are no-ops.
    }
  }

  /// Returns the saved position for [docId], or null when the doc has
  /// never been read (or the stored value is unreadable).
  static Future<BarrioReadingPosition?> getPosition(String docId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _parsePosition(prefs.getString(positionKeyFor(docId)));
    } catch (_) {
      return null;
    }
  }

  /// Records that the card [unitId] of [docId] settled on screen.
  /// Idempotent: an already-read card writes nothing.
  static Future<void> markCardRead(String docId, String unitId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = readCardsKeyFor(docId);
      final list = prefs.getStringList(key) ?? const <String>[];
      if (list.contains(unitId)) return;
      await prefs.setStringList(key, <String>[...list, unitId]);
    } catch (_) {
      // Persistence unavailable: writes are no-ops.
    }
  }

  /// The set of read-card unit ids for [docId]. Empty when untouched.
  static Future<Set<String>> getReadUnitIds(String docId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(readCardsKeyFor(docId));
      return list == null ? <String>{} : list.toSet();
    } catch (_) {
      return <String>{};
    }
  }

  /// Records that [docId]'s read-mark set first covered ALL content
  /// cards (spaced refresher, rec #11). Write-once: an existing
  /// finishedAt is NEVER overwritten, so re-reading a finished manual
  /// does not reset its refresher schedule. [now] is injectable for
  /// tests; production callers omit it.
  static Future<void> recordFinished(String docId, {DateTime? now}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = finishedKeyFor(docId);
      if (prefs.getInt(key) != null) return;
      await prefs.setInt(
        key,
        (now ?? DateTime.now()).millisecondsSinceEpoch,
      );
    } catch (_) {
      // Persistence unavailable: writes are no-ops.
    }
  }

  /// Records that a refresher for [docId] was completed: stamps
  /// lastRefreshedAt and advances the completed count (which moves the
  /// spacing from 3 to 10 to 30 days). Records a fact only; no mastery
  /// claim. [now] is injectable for tests.
  static Future<void> recordRefreshCompleted(
    String docId, {
    DateTime? now,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        refreshedAtKeyFor(docId),
        (now ?? DateTime.now()).millisecondsSinceEpoch,
      );
      final count = prefs.getInt(refreshCountKeyFor(docId)) ?? 0;
      await prefs.setInt(refreshCountKeyFor(docId), count + 1);
    } catch (_) {
      // Persistence unavailable: writes are no-ops.
    }
  }

  /// The recorded refresher facts for [docId]. Fresh or unreadable
  /// state reads as [BarrioRefresherState.empty] (never due).
  static Future<BarrioRefresherState> getRefresherState(String docId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _refresherStateOf(prefs, docId);
    } catch (_) {
      return BarrioRefresherState.empty;
    }
  }

  /// Refresher facts for every doc in [docIds] (the caller passes the
  /// training-doc registry keys; the service stays content-agnostic).
  /// Only docs with a recorded finishedAt carry a non-empty state.
  static Future<Map<String, BarrioRefresherState>> loadRefresherStates(
    Iterable<String> docIds,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return <String, BarrioRefresherState>{
        for (final docId in docIds) docId: _refresherStateOf(prefs, docId),
      };
    } catch (_) {
      return const <String, BarrioRefresherState>{};
    }
  }

  static BarrioRefresherState _refresherStateOf(
    SharedPreferences prefs,
    String docId,
  ) {
    final count = prefs.getInt(refreshCountKeyFor(docId)) ?? 0;
    return BarrioRefresherState(
      finishedAt: _readMillis(prefs, finishedKeyFor(docId)),
      lastRefreshedAt: _readMillis(prefs, refreshedAtKeyFor(docId)),
      completedRefreshers: count < 0 ? 0 : count,
    );
  }

  /// Parses a stored epoch-millis int; null on any malformation so a
  /// corrupt value reads as "never recorded" instead of crashing.
  static DateTime? _readMillis(SharedPreferences prefs, String key) {
    try {
      final value = prefs.getInt(key);
      if (value == null || value <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(value);
    } catch (_) {
      return null;
    }
  }

  /// The most recently read doc id, or null when nothing has been read.
  static Future<String?> getLastDocId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kLastDocKey);
    } catch (_) {
      return null;
    }
  }

  /// Loads one aggregate snapshot for the home screen. [docIds] is the
  /// universe of docs to inspect (the caller passes the training-doc
  /// registry keys; the service stays content-agnostic).
  static Future<BarrioReadingSnapshot> loadSnapshot(
    Iterable<String> docIds,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final readUnitIds = <String, Set<String>>{};
      for (final docId in docIds) {
        final list = prefs.getStringList(readCardsKeyFor(docId));
        if (list != null && list.isNotEmpty) {
          readUnitIds[docId] = list.toSet();
        }
      }
      final lastDocId = prefs.getString(_kLastDocKey);
      final lastPosition = lastDocId == null
          ? null
          : _parsePosition(prefs.getString(positionKeyFor(lastDocId)));
      return BarrioReadingSnapshot(
        lastDocId: lastDocId,
        lastPosition: lastPosition,
        readUnitIds: readUnitIds,
      );
    } catch (_) {
      return BarrioReadingSnapshot.empty;
    }
  }

  /// Parses a stored `'chapter:unit'` string; null on any malformation
  /// so a corrupt value reads as "never read" instead of crashing.
  static BarrioReadingPosition? _parsePosition(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(':');
    if (parts.length != 2) return null;
    final chapter = int.tryParse(parts[0]);
    final unit = int.tryParse(parts[1]);
    if (chapter == null || unit == null || chapter < 0 || unit < 0) {
      return null;
    }
    return BarrioReadingPosition(chapterIndex: chapter, unitInChapter: unit);
  }
}
