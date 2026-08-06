// Kindle-style highlights: anchor capture and anchor resolution
// (Slice B, 2026-08-06).
//
// Two halves of one job, kept in one file because they are two ends of
// the same rope:
//
//   * CAPTURE. [BarrioHighlightAnchorRegistry] hands the lesson card one
//     [SelectionListenerNotifier] per rendered chunk, keyed by
//     (unitId, chunkIndex). When the reader taps Highlight, the screen
//     asks the registry which chunks the live selection touched and gets
//     back ready-to-store [BarrioHighlightSegment]s.
//
//   * RESOLUTION. [BarrioHighlightPlan] turns stored highlights back
//     into per-chunk paint runs, re-anchoring by exact text when a body
//     has been regenerated and honestly orphaning what it cannot place.
//
// Chunks on both sides come from `content/barrio_body_chunks.dart`, the
// one parse the lesson card renders from, so an offset always addresses
// the characters actually on screen.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../content/barrio_body_chunks.dart';
import '../widgets/barrio_destination_scaffold.dart';
import 'barrio_highlights_service.dart';

// ---------------------------------------------------------------------------
// Marker palette
// ---------------------------------------------------------------------------

/// The wash opacity of a marker colour on the white glass card.
///
/// 0.30 for all four: the composited wash keeps body text (both
/// [BarrioColors.textSecondary] prose and [BarrioColors.textPrimary]
/// table headers) at or above the 4.5:1 AA floor, which
/// `test/barrio_highlight_render_test.dart` measures rather than
/// assumes. Steel blue is the darkest of the four and the one the
/// design plan flagged as the risk; it measures 5.14:1 against
/// textSecondary, so it keeps the shared alpha.
const double kBarrioHighlightWashAlpha = 0.30;

/// The paint behind each marker colour token.
///
/// Tokens, not ARGB ints, are what gets stored (see
/// [kBarrioHighlightColorTokens]), so a palette retune reaches every
/// highlight a reader has already made. [BarrioColors.tealWarm] is
/// deliberately absent: it is the search-hit wash, and "I marked this"
/// must not look like "your search matched here".
const Map<String, Color> kBarrioHighlightMarkerColors = <String, Color>{
  'gold': BarrioColors.gold,
  'fresh': BarrioColors.accentFresh,
  'plum': BarrioColors.accentPlum,
  'steel': BarrioColors.accentSteel,
};

/// The translucent wash for marker colour [token]. An unknown token (a
/// newer build's colour) paints in the default marker colour, so the
/// passage still reads as marked.
Color barrioHighlightWash(String token) {
  final base = kBarrioHighlightMarkerColors[token] ??
      kBarrioHighlightMarkerColors[kBarrioHighlightDefaultColor]!;
  return base.withValues(alpha: kBarrioHighlightWashAlpha);
}

// ---------------------------------------------------------------------------
// Resolution: stored highlights to per-chunk paint runs
// ---------------------------------------------------------------------------

/// One run of marked characters inside one rendered chunk.
///
/// `[start, end)` are UTF-16 offsets into that chunk's text AS RENDERED
/// NOW, which is not always what was stored: see
/// [BarrioHighlightPlan.resolve].
@immutable
class BarrioHighlightRun {
  /// The highlight this run belongs to.
  final String highlightId;

  /// Marker colour token, as stored.
  final String color;

  /// Start offset into the chunk, inclusive.
  final int start;

  /// End offset into the chunk, exclusive.
  final int end;

  const BarrioHighlightRun({
    required this.highlightId,
    required this.color,
    required this.start,
    required this.end,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BarrioHighlightRun &&
          other.highlightId == highlightId &&
          other.color == color &&
          other.start == start &&
          other.end == end;

  @override
  int get hashCode => Object.hash(highlightId, color, start, end);

  @override
  String toString() => 'BarrioHighlightRun($highlightId, $color, $start-$end)';
}

/// What one card has to paint: marked runs per rendered chunk, plus the
/// highlights this build could not place at all.
///
/// VALUE EQUALITY IS LOAD-BEARING. The lesson card memoizes its composed
/// spans and this plan is part of the memo key, so `==` must see a new
/// highlight, a recolour, and a moved offset. It compares every run of
/// every chunk: id, colour token, and both offsets.
@immutable
class BarrioHighlightPlan {
  /// Nothing marked. The plan every card without highlights carries, and
  /// the reason a curated screen renders byte-identically to before this
  /// feature existed.
  static const BarrioHighlightPlan empty = BarrioHighlightPlan._(
    <int, List<BarrioHighlightRun>>{},
    <String>[],
  );

  final Map<int, List<BarrioHighlightRun>> _byChunk;

  /// Ids of highlights whose words are no longer anywhere in this card.
  /// Kept, never painted: the review surface lists them honestly as
  /// coming from an earlier version of the manual (Slice D).
  final List<String> orphanIds;

  const BarrioHighlightPlan._(this._byChunk, this.orphanIds);

  /// True when this card has nothing to paint.
  bool get isEmpty => _byChunk.isEmpty;

  /// The marked runs of chunk [chunkIndex], in offset order, never
  /// overlapping. Empty when that chunk carries no mark.
  List<BarrioHighlightRun> forChunk(int chunkIndex) =>
      _byChunk[chunkIndex] ?? const <BarrioHighlightRun>[];

  /// Chunk indices carrying at least one run, ascending.
  Iterable<int> get markedChunks => _byChunk.keys;

  /// Resolves [highlights] against the chunks a card renders NOW.
  ///
  /// Per segment, in order:
  ///   1. the stored offsets still spell the stored words: paint there,
  ///   2. else the words are elsewhere in the same chunk: re-anchor,
  ///   3. else the words are in another chunk of this card: re-anchor,
  ///   4. else the segment is unplaceable.
  ///
  /// A highlight with even ONE unplaceable segment is orphaned WHOLE and
  /// paints nothing. Painting the half that still resolves would be a
  /// wrong claim about which words the reader marked, and the store
  /// already applies the same all-or-nothing rule to a partly corrupt
  /// entry.
  ///
  /// Where two highlights cover the same characters the NEWER one paints
  /// (stored order is oldest first, so later wins), which is what a
  /// reader means when they mark over their own mark in a new colour.
  factory BarrioHighlightPlan.resolve({
    required List<BarrioHighlight> highlights,
    required List<BarrioBodyChunk> chunks,
  }) {
    if (highlights.isEmpty || chunks.isEmpty) return empty;
    final orphans = <String>[];
    final owners = _paintOwners(highlights, chunks, orphans);
    return BarrioHighlightPlan._(
      owners.isEmpty
          ? const <int, List<BarrioHighlightRun>>{}
          : Map<int, List<BarrioHighlightRun>>.unmodifiable(_coalesce(owners)),
      List<String>.unmodifiable(orphans),
    );
  }

  /// Per chunk, which run owns each character, plus [orphans] filled in
  /// with every highlight that could not be placed.
  ///
  /// A character array rather than a range list because two marks may
  /// cover the same words and the paint side needs runs that do not
  /// overlap: writing highlights in stored order (oldest first) makes
  /// the newer one the owner wherever they meet, which is what a reader
  /// means when they mark over their own mark. The arrays are small by
  /// construction (a chunk is one paragraph, list row, or table cell)
  /// and only ever built for a card that actually has marks.
  static Map<int, List<BarrioHighlightRun?>> _paintOwners(
    List<BarrioHighlight> highlights,
    List<BarrioBodyChunk> chunks,
    List<String> orphans,
  ) {
    final owners = <int, List<BarrioHighlightRun?>>{};
    for (final highlight in highlights) {
      final placed = _placeHighlight(highlight, chunks);
      if (placed == null) {
        orphans.add(highlight.id);
        continue;
      }
      for (final (chunkIndex, start, end) in placed) {
        final run = BarrioHighlightRun(
          highlightId: highlight.id,
          color: highlight.color,
          start: start,
          end: end,
        );
        final slots = owners[chunkIndex] ??= List<BarrioHighlightRun?>.filled(
          chunks[chunkIndex].text.length,
          null,
        );
        for (var i = start; i < end; i++) {
          slots[i] = run;
        }
      }
    }
    return owners;
  }

  /// Every `(chunkIndex, start, end)` [highlight] covers on the body as
  /// it reads now, or null when even one of its segments is unplaceable.
  static List<(int, int, int)>? _placeHighlight(
    BarrioHighlight highlight,
    List<BarrioBodyChunk> chunks,
  ) {
    final placed = <(int, int, int)>[];
    for (final segment in highlight.segments) {
      final spot = _placeSegment(segment, chunks);
      if (spot == null) return null;
      placed.add((spot.$1, spot.$2, spot.$2 + segment.text.length));
    }
    return placed;
  }

  /// Per-character owners folded back into ordered, non-overlapping
  /// runs, chunk by chunk.
  static Map<int, List<BarrioHighlightRun>> _coalesce(
    Map<int, List<BarrioHighlightRun?>> owners,
  ) {
    final byChunk = <int, List<BarrioHighlightRun>>{};
    final chunkIndices = owners.keys.toList()..sort();
    for (final chunkIndex in chunkIndices) {
      final runs = _runsOf(owners[chunkIndex]!);
      if (runs.isNotEmpty) byChunk[chunkIndex] = List.unmodifiable(runs);
    }
    return byChunk;
  }

  /// One chunk's per-character owners folded into runs.
  static List<BarrioHighlightRun> _runsOf(List<BarrioHighlightRun?> slots) {
    final runs = <BarrioHighlightRun>[];
    var i = 0;
    while (i < slots.length) {
      final owner = slots[i];
      if (owner == null) {
        i++;
        continue;
      }
      final start = i;
      while (i < slots.length && identical(slots[i], owner)) {
        i++;
      }
      runs.add(BarrioHighlightRun(
        highlightId: owner.highlightId,
        color: owner.color,
        start: start,
        end: i,
      ));
    }
    return runs;
  }

  /// The `(chunkIndex, start)` where [segment]'s words sit in [chunks]
  /// today, or null when they are nowhere on this card.
  static (int, int)? _placeSegment(
    BarrioHighlightSegment segment,
    List<BarrioBodyChunk> chunks,
  ) {
    if (segment.chunk < chunks.length) {
      final text = chunks[segment.chunk].text;
      // 1: the stored offsets still spell the stored words.
      if (segment.end <= text.length &&
          text.substring(segment.start, segment.end) == segment.text) {
        return (segment.chunk, segment.start);
      }
      // 2: the words moved inside their own chunk.
      final moved = text.indexOf(segment.text);
      if (moved >= 0) return (segment.chunk, moved);
    }
    // 3: the words moved to another chunk of this card.
    for (final chunk in chunks) {
      final found = chunk.text.indexOf(segment.text);
      if (found >= 0) return (chunk.index, found);
    }
    // 4: unplaceable.
    return null;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BarrioHighlightPlan) return false;
    if (other._byChunk.length != _byChunk.length) return false;
    if (!listEquals(other.orphanIds, orphanIds)) return false;
    for (final entry in _byChunk.entries) {
      if (!listEquals(other._byChunk[entry.key], entry.value)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        _byChunk.length,
        Object.hashAll(orphanIds),
        Object.hashAllUnordered(<Object>[
          for (final entry in _byChunk.entries)
            Object.hash(entry.key, Object.hashAll(entry.value)),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Capture: one selection notifier per rendered chunk
// ---------------------------------------------------------------------------

/// One card chunk's handle on the reader's live selection.
class _Anchor {
  final String unitId;
  final int chunkIndex;
  final SelectionListenerNotifier notifier = SelectionListenerNotifier();

  _Anchor(this.unitId, this.chunkIndex);
}

/// Every rendered chunk's window onto the reader's text selection,
/// owned by the reading screen.
///
/// The lesson card asks for one [SelectionListenerNotifier] per chunk
/// and wraps that chunk's text in a `SelectionListener`. Flutter then
/// reports, per chunk, which characters of THAT chunk are selected. When
/// the reader taps Highlight, [selectionSegments] reads every chunk at
/// once, so a selection dragged across three paragraphs becomes three
/// segments of one highlight.
///
/// ONE LIVE CARD PER UNIT ID. Notifiers are keyed by
/// (unitId, chunkIndex) and Flutter asserts that a notifier is attached
/// to at most one live `SelectionListener`. The reading deck already
/// guarantees this: it keys every card on `ValueKey(unit.id)`, so two
/// cards with the same unit id can never be alive at once.
class BarrioHighlightAnchorRegistry {
  final Map<String, _Anchor> _anchors = <String, _Anchor>{};

  static String _key(String unitId, int chunkIndex) => '$unitId#$chunkIndex';

  /// The notifier for one chunk of one card. Stable across rebuilds: a
  /// `SelectionListener` re-registers when its notifier changes, so
  /// handing out a fresh one each build would churn the selection.
  SelectionListenerNotifier notifierFor(String unitId, int chunkIndex) =>
      (_anchors[_key(unitId, chunkIndex)] ??= _Anchor(unitId, chunkIndex))
          .notifier;

  /// The card the reader is selecting inside, or null when nothing is
  /// selected anywhere.
  ///
  /// The carousel keeps neighbouring pages alive, so more than one card
  /// is registered at any moment; only the one on screen can carry a
  /// selection. When more than one somehow does, the one with the most
  /// selected characters wins, which is the card the reader is actually
  /// working in.
  String? selectedUnitId() {
    String? best;
    var bestLength = 0;
    final totals = <String, int>{};
    for (final anchor in _anchors.values) {
      final range = _rangeOf(anchor);
      if (range == null) continue;
      final total =
          (totals[anchor.unitId] ?? 0) + (range.$2 - range.$1);
      totals[anchor.unitId] = total;
      if (total > bestLength) {
        bestLength = total;
        best = anchor.unitId;
      }
    }
    return best;
  }

  /// The reader's live selection inside [unitId] as storable segments,
  /// in reading order. Empty when nothing in that card is selected.
  ///
  /// [chunks] must be the chunks that card is rendering right now
  /// (`chunksForBody(unit.body)`): the offsets Flutter reports are into
  /// the chunk's own content, so the words are sliced straight out of
  /// it. A whitespace-only slice is dropped: marking a space is not a
  /// highlight.
  List<BarrioHighlightSegment> selectionSegments(
    String unitId,
    List<BarrioBodyChunk> chunks,
  ) {
    final segments = <BarrioHighlightSegment>[];
    for (final anchor in _anchors.values) {
      if (anchor.unitId != unitId) continue;
      if (anchor.chunkIndex >= chunks.length) continue;
      final range = _rangeOf(anchor);
      if (range == null) continue;
      final text = chunks[anchor.chunkIndex].text;
      // Clamped defensively. Flutter reports offsets into the flattened
      // content of the listener's subtree, which for a body chunk is the
      // chunk string 1:1 (the term-link widget spans hold exactly their
      // verbatim substring, and `barrio_highlight_render_test.dart`
      // proves the 1:1 against a real term-linked card). A clamp is
      // cheaper than trusting that forever.
      final start = range.$1.clamp(0, text.length);
      final end = range.$2.clamp(0, text.length);
      if (end <= start) continue;
      final slice = text.substring(start, end);
      if (slice.trim().isEmpty) continue;
      segments.add(BarrioHighlightSegment(
        chunk: anchor.chunkIndex,
        start: start,
        end: end,
        text: slice,
      ));
    }
    segments.sort((a, b) => a.chunk.compareTo(b.chunk));
    return segments;
  }

  /// The selected `[start, end)` of one chunk, or null when that chunk
  /// carries no real selection. Flutter reports a backwards drag with
  /// the offsets reversed, so they are ordered here.
  (int, int)? _rangeOf(_Anchor anchor) {
    if (!anchor.notifier.registered) return null;
    final range = anchor.notifier.selection.range;
    if (range == null) return null;
    final start = math.min(range.startOffset, range.endOffset);
    final end = math.max(range.startOffset, range.endOffset);
    if (end <= start) return null;
    return (start, end);
  }

  /// Drops every notifier. Called from the reading screen's `dispose`.
  /// Flutter unmounts children before their ancestors, so every
  /// `SelectionListener` has already detached by the time this runs.
  void dispose() {
    for (final anchor in _anchors.values) {
      anchor.notifier.dispose();
    }
    _anchors.clear();
  }
}
