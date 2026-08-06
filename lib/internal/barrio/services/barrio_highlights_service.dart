// Kindle-style highlights and notes: local persistence
// (Slice A, 2026-08-05).
//
// Follows the same shared_preferences patterns as
// BarrioBookmarksService and BarrioReadingProgressService: facts only,
// device-local, never demo-aware, and every method swallows
// platform-store failures (a device without a working preferences store
// reads as "no highlights" and writes are no-ops).
//
// A highlight is one marked passage inside one training card. It is
// anchored by:
//   * the doc it lives in (carried by the storage key, so a reader load
//     stays O(one doc)),
//   * the card's stable unit id (content coordinates, the same ids read
//     marks use, so a chapter insert or reorder cannot move it),
//   * one segment per rendered chunk the selection touched, each with
//     `[start, end)` UTF-16 offsets into that chunk plus the exact
//     highlighted words.
// Chunks come from `content/barrio_body_chunks.dart`, the shared parser
// the lesson card renders from, so an offset always addresses the
// characters actually on screen.
//
// Storage: one JSON-encoded list per doc under
// `barrio_highlights_<docId>` (the per-doc pattern from
// BarrioReadingProgressService), in save order, oldest first.
//
// Colours are stored as TOKEN NAMES ('gold', 'fresh', 'plum', 'steel'),
// never ARGB ints, so a future palette retune reaches every stored
// highlight. The teal wash is deliberately not a marker colour: it
// already means "search hit" and the two meanings must stay distinct.
//
// Forward compatibility. Every entry carries an integer `v`. An entry
// this build cannot read decodes to null and is skipped for rendering,
// but it is PRESERVED unchanged on every rewrite (content and order):
// an older build can never destroy a newer build's highlights, and it
// can never edit or delete one either. A highlight whose unit id or
// offsets no longer resolve is likewise kept in storage (the bookmarks
// rule: it stays so it reappears if content returns).

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// The four marker colour tokens, in picker order. Stored as names so a
/// palette retune propagates; consumers map a token to a wash colour.
const List<String> kBarrioHighlightColorTokens = <String>[
  'gold',
  'fresh',
  'plum',
  'steel',
];

/// The marker colour a fresh reader gets, and the fallback for any
/// token this build does not recognise.
const String kBarrioHighlightDefaultColor = 'gold';

/// Whether [token] is a marker colour this build knows how to paint.
bool isBarrioHighlightColor(String token) =>
    kBarrioHighlightColorTokens.contains(token);

/// [token] when this build can paint it, otherwise the default marker
/// colour (a newer build's colour still renders as a highlight).
String barrioHighlightColorOrDefault(String token) =>
    isBarrioHighlightColor(token) ? token : kBarrioHighlightDefaultColor;

/// One marked run inside one rendered body chunk.
///
/// [start] and [end] are UTF-16 offsets into the chunk string produced
/// by `chunksForBody`; [text] is the exact highlighted words, kept so a
/// regenerated body can be re-anchored (exact offsets first, then a
/// search for these words) instead of silently painting the wrong
/// passage.
class BarrioHighlightSegment {
  /// 0-based index of the rendered chunk this run sits in.
  final int chunk;

  /// Start offset, inclusive.
  final int start;

  /// End offset, exclusive.
  final int end;

  /// The exact highlighted words as they read when the mark was made.
  final String text;

  const BarrioHighlightSegment({
    required this.chunk,
    required this.start,
    required this.end,
    required this.text,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'chunk': chunk,
        'start': start,
        'end': end,
        'text': text,
      };

  /// Parses one stored segment; null on any malformation so a corrupt
  /// value reads as "not a highlight" instead of crashing.
  static BarrioHighlightSegment? decode(Object? raw) {
    if (raw is! Map) return null;
    final chunk = raw['chunk'];
    final start = raw['start'];
    final end = raw['end'];
    final text = raw['text'];
    if (chunk is! int || start is! int || end is! int || text is! String) {
      return null;
    }
    if (chunk < 0 || start < 0 || end <= start || text.isEmpty) return null;
    return BarrioHighlightSegment(
      chunk: chunk,
      start: start,
      end: end,
      text: text,
    );
  }
}

/// One highlight: a marked passage in one card, with an optional note.
class BarrioHighlight {
  /// The schema version this build writes and can read.
  static const int kCurrentVersion = 1;

  /// Schema version of this entry. Always [kCurrentVersion] for a
  /// decoded highlight: an unknown version never decodes.
  final int version;

  /// Stable local id, `h_<millis>_<rand>`. Unique per device.
  final String id;

  /// The card this passage lives in (content coordinates).
  final String unitId;

  /// Marker colour token. May be a token this build cannot paint (a
  /// newer build's colour); [barrioHighlightColorOrDefault] resolves it.
  final String color;

  /// The reader's note, or empty when they have not written one.
  final String note;

  /// When the mark was made.
  final DateTime createdAt;

  /// One segment per rendered chunk the selection touched, in reading
  /// order. Never empty.
  final List<BarrioHighlightSegment> segments;

  const BarrioHighlight({
    required this.id,
    required this.unitId,
    required this.color,
    required this.note,
    required this.createdAt,
    required this.segments,
    this.version = kCurrentVersion,
  });

  /// A fresh highlight with a new local id. [now] and [random] are
  /// injectable for tests; production callers omit them.
  factory BarrioHighlight.create({
    required String unitId,
    required List<BarrioHighlightSegment> segments,
    String color = kBarrioHighlightDefaultColor,
    String note = '',
    DateTime? now,
    Random? random,
  }) {
    final stamp = now ?? DateTime.now();
    return BarrioHighlight(
      id: newId(now: stamp, random: random),
      unitId: unitId,
      color: color,
      note: note,
      createdAt: stamp,
      segments: segments,
    );
  }

  /// A new local highlight id: `h_<millis>_<rand>`.
  static String newId({DateTime? now, Random? random}) {
    final millis = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final tail = (random ?? Random()).nextInt(10000).toString().padLeft(4, '0');
    return 'h_${millis}_$tail';
  }

  /// The whole marked passage as one string: every segment's words in
  /// reading order, single-space joined (segments come from separate
  /// paragraphs, bullets, or table cells, so they never abut).
  String get plainText => segments.map((s) => s.text).join(' ');

  /// Whether the reader has written a note on this highlight.
  bool get hasNote => note.trim().isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'v': version,
        'id': id,
        'unitId': unitId,
        'color': color,
        'note': note,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'segments': <Object?>[for (final s in segments) s.toJson()],
      };

  /// Parses one stored entry; null when this build cannot read it,
  /// either because the entry is malformed or because its `v` is from a
  /// newer build. A null entry is skipped for rendering and PRESERVED
  /// in storage (see [BarrioHighlightsService]).
  static BarrioHighlight? decode(Object? raw) {
    if (raw is! Map) return null;
    if (raw['v'] != kCurrentVersion) return null;
    final id = _text(raw['id']);
    final unitId = _text(raw['unitId']);
    final color = _text(raw['color']);
    final createdAt = raw['createdAt'];
    final segments = _decodeSegments(raw['segments']);
    if (id == null || unitId == null || color == null) return null;
    if (createdAt is! int || createdAt <= 0) return null;
    if (segments == null) return null;
    final note = raw['note'];
    return BarrioHighlight(
      version: kCurrentVersion,
      id: id,
      unitId: unitId,
      color: color,
      note: note is String ? note : '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      segments: segments,
    );
  }

  /// [value] when it is a non-empty string, else null.
  static String? _text(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  /// The stored segment list, or null when it is missing, empty, or
  /// carries even one unreadable segment. One bad segment makes the
  /// WHOLE entry unreadable on purpose: a partly painted highlight
  /// would be a wrong claim about which words the reader marked.
  static List<BarrioHighlightSegment>? _decodeSegments(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final segments = <BarrioHighlightSegment>[];
    for (final rawSegment in raw) {
      final segment = BarrioHighlightSegment.decode(rawSegment);
      if (segment == null) return null;
      segments.add(segment);
    }
    return segments;
  }
}

/// Local persistence for training-reader highlights and their notes.
class BarrioHighlightsService {
  BarrioHighlightsService._();

  /// Preference key holding the last marker colour the reader picked.
  static const String kLastColorKey = 'barrio_highlight_last_color';

  /// Preference key holding the highlight list for [docId].
  static String keyFor(String docId) => 'barrio_highlights_$docId';

  /// Every readable highlight in [docId], oldest first. Empty when the
  /// doc has none, the stored value is unreadable, or the store is
  /// unavailable.
  static Future<List<BarrioHighlight>> getForDoc(String docId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _readable(_storedEntries(prefs, docId));
    } catch (_) {
      return const <BarrioHighlight>[];
    }
  }

  /// Highlights for every doc in [docIds] (the caller passes the
  /// training-doc registry keys; the service stays content-agnostic).
  /// Only docs with at least one readable highlight carry an entry, so
  /// "no entry" honestly means "nothing highlighted".
  static Future<Map<String, List<BarrioHighlight>>> loadAll(
    Iterable<String> docIds,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final out = <String, List<BarrioHighlight>>{};
      for (final docId in docIds) {
        final list = _readable(_storedEntries(prefs, docId));
        if (list.isNotEmpty) out[docId] = list;
      }
      return out;
    } catch (_) {
      return const <String, List<BarrioHighlight>>{};
    }
  }

  /// Saves [highlight] to [docId]. Idempotent: an id already stored
  /// writes nothing.
  static Future<void> add(String docId, BarrioHighlight highlight) async {
    await _mutate(docId, (entries) {
      for (final entry in entries) {
        if (entry is Map && entry['id'] == highlight.id) return false;
      }
      entries.add(highlight.toJson());
      return true;
    });
  }

  /// Repaints one highlight. An unknown colour token, an unknown id, or
  /// an entry this build cannot read writes nothing.
  static Future<void> setColor(String docId, String id, String color) async {
    if (!isBarrioHighlightColor(color)) return;
    await _mutate(docId, (entries) => _patch(entries, id, 'color', color));
  }

  /// Writes (or clears, with an empty string) the note on one
  /// highlight. An unknown id, or an entry this build cannot read,
  /// writes nothing.
  static Future<void> setNote(String docId, String id, String note) async {
    await _mutate(docId, (entries) => _patch(entries, id, 'note', note));
  }

  /// Removes one highlight. An unknown id writes nothing. Entries this
  /// build cannot read are never removed: they are not shown, so no
  /// reader could have asked for their deletion.
  static Future<void> remove(String docId, String id) async {
    await _mutate(docId, (entries) {
      final keep = <Object?>[
        for (final entry in entries)
          if (!_isReadableEntryWithId(entry, id)) entry,
      ];
      if (keep.length == entries.length) return false;
      entries
        ..clear()
        ..addAll(keep);
      return true;
    });
  }

  /// The marker colour the reader picked last, defaulting to
  /// [kBarrioHighlightDefaultColor] on a fresh device, an unreadable
  /// value, or an unavailable store.
  static Future<String> getLastColor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(kLastColorKey);
      if (stored == null || !isBarrioHighlightColor(stored)) {
        return kBarrioHighlightDefaultColor;
      }
      return stored;
    } catch (_) {
      return kBarrioHighlightDefaultColor;
    }
  }

  /// Remembers the marker colour the reader just used. An unknown token
  /// writes nothing.
  static Future<void> setLastColor(String token) async {
    if (!isBarrioHighlightColor(token)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kLastColorKey, token);
    } catch (_) {
      // Persistence unavailable: writes are no-ops.
    }
  }

  /// The stored entry list for [docId] exactly as written, including
  /// entries this build cannot read. A value that is not a JSON list
  /// reads as an empty list; a store-level read failure surfaces to the
  /// caller, which swallows it (there is exactly one guard per method).
  static List<Object?> _storedEntries(SharedPreferences prefs, String docId) {
    final raw = prefs.getString(keyFor(docId));
    if (raw == null || raw.isEmpty) return <Object?>[];
    try {
      final decoded = json.decode(raw);
      return decoded is List ? List<Object?>.from(decoded) : <Object?>[];
    } catch (_) {
      return <Object?>[];
    }
  }

  /// The subset of [entries] this build can paint, in stored order.
  static List<BarrioHighlight> _readable(List<Object?> entries) {
    final out = <BarrioHighlight>[];
    for (final entry in entries) {
      final highlight = BarrioHighlight.decode(entry);
      if (highlight != null) out.add(highlight);
    }
    return out;
  }

  /// Reads the whole stored list, hands it to [change], and writes it
  /// back only when [change] reports a real edit. Entries [change] does
  /// not touch (including every unknown-version entry) are written back
  /// exactly as they were read, so an older build can never destroy a
  /// newer build's highlights. Store failures are no-ops.
  static Future<void> _mutate(
    String docId,
    bool Function(List<Object?> entries) change,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = _storedEntries(prefs, docId);
      if (!change(entries)) return;
      if (entries.isEmpty) {
        await prefs.remove(keyFor(docId));
        return;
      }
      await prefs.setString(keyFor(docId), json.encode(entries));
    } catch (_) {
      // Persistence unavailable: writes are no-ops.
    }
  }

  /// Sets [field] on the readable entry with [id]. Returns whether
  /// anything actually changed.
  static bool _patch(
    List<Object?> entries,
    String id,
    String field,
    Object? value,
  ) {
    for (final entry in entries) {
      if (!_isReadableEntryWithId(entry, id)) continue;
      final map = entry as Map;
      if (map[field] == value) return false;
      map[field] = value;
      return true;
    }
    return false;
  }

  /// Whether [entry] is a highlight this build can actually read (and
  /// therefore show) carrying [id]. An unknown-version or malformed
  /// entry never matches, so an edit or a removal can never touch it.
  static bool _isReadableEntryWithId(Object? entry, String id) =>
      BarrioHighlight.decode(entry)?.id == id;
}
