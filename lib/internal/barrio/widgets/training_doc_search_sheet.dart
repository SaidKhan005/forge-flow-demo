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
//
// Ask flow (T9 slice 2, 2026-08-02). Typing is unchanged; SUBMITTING
// the field (the keyboard search action) asks [BarrioTrainingAnswers]
// the same text, scoped to this manual, and pins the outcome ABOVE the
// word hits:
//   * an answer is the manual's OWN sentence, quoted verbatim, with the
//     chapter and card it was cut from, and tapping it jumps there;
//   * when the manual does not answer, the sheet says exactly that and
//     offers a web search the SCREEN launches (this sheet never imports
//     url_launcher, which also keeps it testable in isolation).
// Weak matches are never dressed as answers: they route to the same
// fallback (Metric Honesty). There is no AI persona anywhere here: no
// chat bubbles, no first person, no typing indicator. This is search
// that answers with the manual's own words.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../search/barrio_training_answers.dart';
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

  /// Called with the tapped answer and the highlight query for it (its
  /// CONTENT terms only, never the question's glue words). Same
  /// contract as [onResultTap]: the caller closes the sheet, threads
  /// the terms into the cards, and jumps the deck to the answering
  /// card. Kept separate from [onResultTap] so an answer is never
  /// dressed up as a word hit it is not.
  final void Function(BarrioTrainingAnswer answer, String highlightQuery)
      onAnswerTap;

  /// Called with the raw asked question when the manual does not answer
  /// it and the reader taps "Search the web". The screen owns launching
  /// the browser; this sheet only reports the request.
  final void Function(String query) onWebSearchRequested;

  /// Keystroke debounce, mirroring the home search field (~200ms).
  final Duration debounce;

  const TrainingDocSearchSheet({
    super.key,
    required this.docId,
    required this.accent,
    required this.onResultTap,
    required this.onAnswerTap,
    required this.onWebSearchRequested,
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

  /// The submitted question the pinned block above the word hits
  /// reflects. Empty when nothing has been asked yet, and emptied again
  /// the moment the reader edits the field: an answer block must never
  /// describe a question the field no longer holds.
  String _askedQuery = '';

  /// Answer-tier results for [_askedQuery], scoped to this manual.
  /// Weak excerpts are dropped here rather than rendered quieter: a
  /// weak match shown as an answer would be dishonest, so the sheet
  /// falls back to the web offer instead (Metric Honesty).
  List<BarrioTrainingAnswer> _answers = const <BarrioTrainingAnswer>[];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    setState(() {
      // clear-button visibility tracks the live text; editing the
      // question also retires the pinned answer block above.
      if (text.trim() != _askedQuery) _retireAsk();
    });
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, () {
      if (mounted) setState(() => _query = text);
    });
  }

  /// Asks this manual the submitted question (keyboard search action).
  /// A query too short for the service to run is not asked at all and
  /// pins nothing: the sheet must never imply the manual was searched
  /// when it was not.
  void _onSubmitted(String text) {
    final asked = text.trim();
    if (asked.length < BarrioTrainingSearch.kMinQueryLength) return;
    _debounce?.cancel();
    final answers = BarrioTrainingAnswers.ask(
      asked,
      isDestinationAllowed: (id) => id == widget.docId,
    );
    setState(() {
      _query = text;
      _askedQuery = asked;
      _answers = <BarrioTrainingAnswer>[
        for (final answer in answers)
          if (answer.confidence == BarrioAnswerConfidence.answer) answer,
      ];
    });
  }

  /// Drops the pinned ask state. Call inside a [setState].
  void _retireAsk() {
    _askedQuery = '';
    _answers = const <BarrioTrainingAnswer>[];
  }

  void _clear() {
    HapticFeedback.selectionClick();
    _debounce?.cancel();
    _controller.clear();
    // Clearing restores the idle sheet immediately; no debounce out.
    setState(() {
      _query = '';
      _retireAsk();
    });
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
        borderRadius: BorderRadius.circular(BarrioRadii.card),
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
              onSubmitted: _onSubmitted,
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
                hintText: 'Search or ask this manual',
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
    // A submitted question pins its outcome above the word hits;
    // everything else is today's word search, untouched.
    if (_askedQuery.isNotEmpty) return _buildAskedBody();
    return _buildWordBody();
  }

  /// Idle and typing state: the word hits on their own.
  Widget _buildWordBody() {
    if (!_queryActive) return const SizedBox.shrink();
    final results = _results;
    if (results.isEmpty) {
      return _EmptyState(query: _trimmedQuery);
    }
    return ListView.builder(
      key: const ValueKey<String>('training_doc_search_results'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: results.length,
      itemBuilder: (context, index) => _resultRow(results[index]),
    );
  }

  /// Asked state: the answer block (or the honest fallback) pinned
  /// above the same word hits, which are never lost.
  Widget _buildAskedBody() {
    return ListView(
      key: const ValueKey<String>('training_doc_ask_results'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: <Widget>[
        ..._askedSection(),
        const SizedBox(height: 14),
        const _SectionKicker(
          label: 'WORD MATCHES',
          color: BarrioColors.textMuted,
          rule: true,
        ),
        ..._wordSection(),
      ],
    );
  }

  /// The pinned outcome of the asked question: up to
  /// [BarrioTrainingAnswers.kMaxAnswers] verbatim answer cards, or the
  /// fallback that says plainly this manual does not answer it.
  List<Widget> _askedSection() {
    if (_answers.isEmpty) {
      return <Widget>[
        _WebFallbackCard(
          accent: widget.accent,
          onSearchWeb: () => widget.onWebSearchRequested(_askedQuery),
        ),
      ];
    }
    return <Widget>[
      _SectionKicker(
        label: 'FROM THIS MANUAL',
        color: widget.accent.withValues(alpha: 0.85),
      ),
      for (final answer in _answers)
        _AnswerCard(
          key: ValueKey<String>('training_doc_answer_card_'
              '${answer.chapterIndex}_${answer.unitIndex}'),
          answer: answer,
          accent: widget.accent,
          onTap: () => widget.onAnswerTap(answer, _highlightQuery(answer)),
        ),
    ];
  }

  /// The word hits below the divider: the same rows the typing path
  /// renders, or the same honest line when the words match nothing.
  List<Widget> _wordSection() {
    final results = _results;
    if (results.isEmpty) {
      return <Widget>[_NoWordMatches(query: _trimmedQuery)];
    }
    return <Widget>[for (final result in results) _resultRow(result)];
  }

  /// One word hit, keyed by its position so rows survive a requery.
  Widget _resultRow(BarrioTrainingSearchResult result) {
    return _ResultRow(
      key: ValueKey<String>(
        'training_doc_search_row_${result.destinationId}_'
        '${result.chapterIndex}_${result.unitIndex}',
      ),
      result: result,
      accent: widget.accent,
      onTap: () => widget.onResultTap(result, _trimmedQuery),
    );
  }

  /// Highlight terms for an answer jump: the CONTENT terms that matched
  /// this unit, space-joined for the screen's existing fold-and-split.
  /// The question's glue words never travel. Falls back to the asked
  /// text only if the match list is somehow empty, so a jump never
  /// lands with nothing marked.
  String _highlightQuery(BarrioTrainingAnswer answer) =>
      answer.matchedTerms.isEmpty ? _askedQuery : answer.matchedTerms.join(' ');
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

/// Honest "nothing matched" line under the WORD MATCHES divider, when
/// the asked question's own words appear nowhere in this manual. Same
/// sentence as the standalone empty state, at list weight.
class _NoWordMatches extends StatelessWidget {
  final String query;

  const _NoWordMatches({required this.query});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      child: Text(
        "No matches for '$query' in this manual.",
        style: GoogleFonts.ibmPlexSans(
          fontSize: 13,
          color: BarrioColors.textSecondary,
        ),
      ),
    );
  }
}

/// Small all-caps kicker over a pinned block, in the same mono face the
/// result rows use for their chapter line. [rule] adds the hairline the
/// word-match divider carries.
class _SectionKicker extends StatelessWidget {
  final String label;
  final Color color;
  final bool rule;

  const _SectionKicker({
    required this.label,
    required this.color,
    this.rule = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.ibmPlexMono(
              fontSize: 10.5,
              letterSpacing: 0.8,
              color: color,
            ),
          ),
          if (rule) ...[
            const SizedBox(height: 8),
            Container(height: 1, color: const Color(0x1416243B)),
          ],
        ],
      ),
    );
  }
}

/// One answer: the manual's own words, quoted verbatim, over the
/// chapter and card they were cut from. Tapping opens that card.
class _AnswerCard extends StatelessWidget {
  final BarrioTrainingAnswer answer;
  final Color accent;
  final VoidCallback onTap;

  const _AnswerCard({
    super.key,
    required this.answer,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // One merged button per answer (same accessibility shape as a
    // result row): the excerpt and its source read as a single card,
    // introduced by what it is.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MergeSemantics(
        child: Semantics(
          button: true,
          label: 'Answer from this manual',
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: BarrioColors.shellMid.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(BarrioRadii.card),
                border: Border.all(color: accent.withValues(alpha: 0.35)),
              ),
              child: _content(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Verbatim law: the excerpt is rendered exactly as the service
        // cut it from the unit body, never trimmed or reworded. The
        // quotation marks frame it; they are not part of the source.
        Text(
          '“${answer.excerpt}”',
          style: GoogleFonts.ibmPlexSans(
            fontSize: 14,
            height: 1.45,
            color: BarrioColors.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '${answer.chapterTitle}: ${answer.unitTitle}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexMono(
            fontSize: 10.5,
            letterSpacing: 0.6,
            color: accent.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }
}

/// The fallback when this manual does not answer the asked question.
/// It says so plainly and offers the web instead; the screen owns the
/// launch, so nothing here reaches the network.
class _WebFallbackCard extends StatelessWidget {
  final Color accent;
  final VoidCallback onSearchWeb;

  const _WebFallbackCard({required this.accent, required this.onSearchWeb});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BarrioColors.shellMid.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(BarrioRadii.card),
        border: Border.all(color: const Color(0x1416243B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This manual does not answer that.',
            style: GoogleFonts.ibmPlexSans(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: BarrioColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'You can search the web instead.',
            style: GoogleFonts.ibmPlexSans(
              fontSize: 13,
              height: 1.35,
              color: BarrioColors.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          Align(alignment: Alignment.centerLeft, child: _button()),
        ],
      ),
    );
  }

  /// The label and the accessibility label are the same words, so the
  /// button excludes its child semantics instead of doubling them.
  /// `container: true` keeps it a node of its own: without it the
  /// annotation folds into the card and the whole card reads as one
  /// button, which is not what a reader can tap.
  Widget _button() {
    return Semantics(
      container: true,
      button: true,
      label: 'Search the web',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onSearchWeb,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(BarrioRadii.chip),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.travel_explore_rounded, size: 17, color: accent),
              const SizedBox(width: 8),
              Text(
                'Search the web',
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ],
          ),
        ),
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
            borderRadius: BorderRadius.circular(BarrioRadii.card),
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
