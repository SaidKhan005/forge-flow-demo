// In-manual search sheet (2026-07-23 operator-approved rec #7).
//
// A bottom sheet opened from the training reader's header search icon.
// It reuses [BarrioTrainingSearch] scoped to the OPEN manual only
// (exact-substring semantics unchanged; no fuzzy or AI matching, which
// is explicitly parked). Results show the section title, card title,
// and the service's snippet with the matched words bolded. Tapping a
// result closes the sheet and hands the hit back to the screen, which
// jumps the deck in place (no remount) and threads the query into the
// cards' existing highlight rendering.
//
// Honest empty state: real matches or "No matches for '<query>' in
// this manual." Nothing is suggested, ever (Metric Honesty).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../search/barrio_training_search.dart';
import 'barrio_chapter_icons.dart';
import 'barrio_destination_scaffold.dart';
import 'barrio_row_thumbnail.dart';

/// Scoped search sheet for one open training manual.
class TrainingDocSearchSheet extends StatefulWidget {
  /// The open manual's registry id; every query is filtered to it.
  final String docId;

  final Color accent;

  /// Called with the tapped hit and the raw query text. The caller
  /// closes the sheet and jumps the deck.
  final void Function(BarrioTrainingSearchResult result, String query)
      onResultTap;

  /// Keystroke debounce, mirroring the home search field (~200ms).
  final Duration debounce;

  const TrainingDocSearchSheet({
    super.key,
    required this.docId,
    required this.accent,
    required this.onResultTap,
    this.debounce = const Duration(milliseconds: 200),
  });

  @override
  State<TrainingDocSearchSheet> createState() => _TrainingDocSearchSheetState();
}

class _TrainingDocSearchSheetState extends State<TrainingDocSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  /// The debounced query the results below reflect.
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    setState(() {}); // clear-button visibility tracks the live text
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, () {
      if (mounted) setState(() => _query = text);
    });
  }

  void _clear() {
    HapticFeedback.selectionClick();
    _debounce?.cancel();
    _controller.clear();
    // Clearing restores the idle sheet immediately; no debounce out.
    setState(() => _query = '');
  }

  String get _trimmedQuery => _query.trim();

  bool get _queryActive =>
      _trimmedQuery.length >= BarrioTrainingSearch.kMinQueryLength;

  /// In-manual hits only: the visibility hook doubles as the doc scope.
  List<BarrioTrainingSearchResult> get _results => _queryActive
      ? BarrioTrainingSearch.search(
          _trimmedQuery,
          isDestinationAllowed: (id) => id == widget.docId,
        )
      : const <BarrioTrainingSearchResult>[];

  @override
  Widget build(BuildContext context) {
    // Keyboard-aware: the field and results ride above the keyboard.
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Container(
          decoration: const BoxDecoration(
            color: BarrioColors.shellDeep,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(top: BorderSide(color: Color(0x1F16243B))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: _buildField(),
              ),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField() {
    final accent = widget.accent;
    return Container(
      decoration: BoxDecoration(
        color: BarrioColors.shellMid.withValues(alpha: 0.80),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.45), width: 1.2),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          Icon(Icons.search_rounded,
              size: 21, color: accent.withValues(alpha: 0.9)),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: _onChanged,
              autofocus: true,
              textInputAction: TextInputAction.search,
              cursorColor: accent,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 14.5,
                color: BarrioColors.textPrimary,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 15),
                hintText: 'Search this manual',
                hintStyle: GoogleFonts.ibmPlexSans(
                  fontSize: 14.5,
                  color: BarrioColors.textSecondary.withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
          if (_controller.text.isNotEmpty)
            Semantics(
              button: true,
              label: 'Clear search',
              child: GestureDetector(
                onTap: _clear,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: BarrioColors.textMuted,
                  ),
                ),
              ),
            )
          else
            const SizedBox(width: 14),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (!_queryActive) return const SizedBox.shrink();
    final results = _results;
    if (results.isEmpty) {
      return _EmptyState(query: _trimmedQuery);
    }
    return ListView.builder(
      key: const ValueKey<String>('training_doc_search_results'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: results.length,
      itemBuilder: (context, index) => _ResultRow(
        key: ValueKey<String>(
          'training_doc_search_row_${results[index].destinationId}_'
          '${results[index].chapterIndex}_${results[index].unitIndex}',
        ),
        result: results[index],
        accent: widget.accent,
        onTap: () => widget.onResultTap(results[index], _trimmedQuery),
      ),
    );
  }
}

/// Small rounded drag handle at the top of the sheet.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0x3316243B),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Honest empty state: no suggestions, no fillers.
class _EmptyState extends StatelessWidget {
  final String query;

  const _EmptyState({required this.query});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 0),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 36,
            color: BarrioColors.textMuted.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 12),
          Text(
            "No matches for '$query' in this manual.",
            textAlign: TextAlign.center,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 14,
              color: BarrioColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// One in-manual hit: section title, card title, bolded snippet.
class _ResultRow extends StatelessWidget {
  final BarrioTrainingSearchResult result;
  final Color accent;
  final VoidCallback onTap;

  const _ResultRow({
    super.key,
    required this.result,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Visual-first pass (rec #9): when the matched card carries a photo,
    // the row leads with a small thumbnail of it IN PLACE OF the chapter
    // wayfinding icon (a visual learner recognizes the real picture
    // faster than a generic glyph). A hit whose card has no photo keeps
    // the inline chapter icon exactly as before (Metric Honesty: no
    // placeholder art).
    final imageAsset = barrioUnitFirstImageAt(
      result.destinationId,
      result.chapterIndex,
      result.unitIndex,
    );
    // Accessibility (rec #12): one merged button per hit (section,
    // card title, and snippet read as one row).
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MergeSemantics(
        child: Semantics(
        button: true,
        child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: BarrioColors.shellMid.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x1416243B)),
          ),
          child: imageAsset == null
              ? _content(showChapterIcon: true)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BarrioRowThumbnail(assetPath: imageAsset),
                    const SizedBox(width: 12),
                    Expanded(child: _content(showChapterIcon: false)),
                  ],
                ),
        ),
        ),
        ),
      ),
    );
  }

  /// The result's text stack. The chapter kicker leads with the
  /// wayfinding icon only when [showChapterIcon] is true; when a
  /// thumbnail already leads the row, the photo carries the wayfinding
  /// signal and the kicker is chapter-title text alone.
  Widget _content({required bool showChapterIcon}) {
    final chapterTitle = Text(
      result.chapterTitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.ibmPlexMono(
        fontSize: 10.5,
        letterSpacing: 0.6,
        color: accent.withValues(alpha: 0.85),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showChapterIcon)
          Row(
            children: [
              // Chapter wayfinding icon (recs 2+5): search here is
              // in-manual, so the hit's CHAPTER icon disambiguates
              // (the manual icon would repeat on every row). Always
              // beside the chapter title, never replacing it: the
              // icon shape carries the signal, not color alone.
              Icon(
                barrioChapterIconAt(
                  result.destinationId,
                  result.chapterIndex,
                ),
                size: 14,
                color: accent.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 6),
              Expanded(child: chapterTitle),
            ],
          )
        else
          chapterTitle,
        const SizedBox(height: 4),
        Text(
          result.unitTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: BarrioColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        _snippetText(),
      ],
    );
  }

  Widget _snippetText() {
    final base = GoogleFonts.ibmPlexSans(
      fontSize: 12.5,
      height: 1.35,
      color: BarrioColors.textMuted,
    );
    final bold = base.copyWith(
      fontWeight: FontWeight.w700,
      color: BarrioColors.textSecondary,
    );
    return Text.rich(
      TextSpan(children: _snippetSpans(result.snippet, base, bold)),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Splits the snippet into plain and bold runs from the service's
/// match spans (offsets are valid on the original snippet text; see
/// the fold contract in barrio_training_search.dart).
List<TextSpan> _snippetSpans(
  BarrioSearchSnippet snippet,
  TextStyle base,
  TextStyle bold,
) {
  final text = snippet.text;
  final spans = <TextSpan>[];
  if (snippet.cutAtStart) spans.add(TextSpan(text: '...', style: base));
  var cursor = 0;
  for (final match in snippet.matchSpans) {
    if (match.start > cursor) {
      spans.add(
          TextSpan(text: text.substring(cursor, match.start), style: base));
    }
    spans.add(
        TextSpan(text: text.substring(match.start, match.end), style: bold));
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: base));
  }
  if (snippet.cutAtEnd) spans.add(TextSpan(text: '...', style: base));
  return spans;
}
