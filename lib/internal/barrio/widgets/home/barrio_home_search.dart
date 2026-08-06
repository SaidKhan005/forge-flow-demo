// Barrio home training search (Barrio Training Media + Search V1,
// Wave B; plan: docs/phases/barrio_training_media_search_v1/
// barrio_training_media_search_v1_plan.md).
//
// Two widgets:
//   * [BarrioHomeSearchField]: the glass search field rendered under
//     the brand header. Debounces keystrokes (~200ms) and reports the
//     raw text via [BarrioHomeSearchField.onQueryChanged]. No looping
//     animation; the only motion is a one-shot focus-border tween.
//   * [BarrioHomeSearchResults]: the sliver the shelf shows instead of
//     the center bubble + category sections while a query is active.
//     B18: results filter through the same resolver-first,
//     preview-role-fallback visibility the shelf bubbles use, so a
//     result the user cannot open never renders.
//
// Cost posture (audit A3, 2026-07-31): searching is expensive enough
// that it must happen exactly once per query, never once per frame.
//   * The field warms the folded corpus from a post-frame callback at
//     mount, so the first keystroke never pays to fold the whole
//     registry (A3.1).
//   * The results sliver memoizes the hit list (A3.2). It used to call
//     `BarrioTrainingSearch.search` straight out of `build`, so every
//     unrelated home rebuild (a reading-progress future landing, an
//     app-lifecycle change) re-ran the whole scan.
//   * Snippets are built inside the item builder, not up front: the
//     service defers them and only a rendered row reads one (A3.3).
//
// Lives under widgets/home so the UX no-em-dash lint root covers every
// operator-facing string here.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/barrio_destination_visibility_resolver.dart';
import '../../routes/barrio_destinations.dart';
import '../../routes/barrio_preview_role.dart';
import '../../search/barrio_training_search.dart';
import '../barrio_destination_scaffold.dart';
import 'barrio_home_destination_visuals.dart';

/// Destination lookup for icon, accent, and visibility resolution.
final Map<String, BarrioDestination> _kDestinationById =
    <String, BarrioDestination>{
  for (final dest in barrioDestinations) dest.id: dest,
};

// ---------------------------------------------------------------------------
// Search field
// ---------------------------------------------------------------------------

/// Glass search field for the home screen: rounded dark glass, subtle
/// border, teal accent when focused, IBM Plex Sans input, magnifier
/// icon, and a clear button while non-empty.
class BarrioHomeSearchField extends StatefulWidget {
  /// Called with the raw field text after the debounce window (or
  /// immediately when cleared). The caller trims and applies the
  /// minimum-length rule.
  final ValueChanged<String> onQueryChanged;

  final Duration debounce;

  const BarrioHomeSearchField({
    super.key,
    required this.onQueryChanged,
    this.debounce = const Duration(milliseconds: 200),
  });

  @override
  State<BarrioHomeSearchField> createState() => _BarrioHomeSearchFieldState();
}

class _BarrioHomeSearchFieldState extends State<BarrioHomeSearchField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
    // A3.1: fold the corpus off the first frame, in chunks, so typing
    // never pays for it. The field mounts with the home screen, so
    // this is the home screen's own post-frame slot. Fire and forget:
    // warmUp is idempotent, and a query that beats it to the corpus
    // simply folds the rest itself.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(BarrioTrainingSearch.warmUp());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onChanged(String text) {
    setState(() {}); // clear-button visibility tracks the live text
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, () {
      if (mounted) widget.onQueryChanged(text);
    });
  }

  void _clear() {
    HapticFeedback.selectionClick();
    _debounce?.cancel();
    _controller.clear();
    setState(() {});
    // Clearing restores the shelf immediately; no debounce on the way out.
    widget.onQueryChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focusNode.hasFocus;
    // Visually prominent at rest (operator request 2026-07-11): dark
    // card base, teal border and glow always on, brighter when focused.
    final accent =
        BarrioColors.tealWarm.withValues(alpha: focused ? 1.0 : 0.75);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          // The one deliberately lighter glass rung: a field, not a
          // surface, so a little cream reads through (was shellMid@0.80).
          color: BarrioColors.glassFillSoft,
          borderRadius: BorderRadius.circular(BarrioRadii.card),
          border: Border.all(
            color: BarrioColors.tealWarm
                .withValues(alpha: focused ? 0.65 : 0.35),
            width: 1.2,
          ),
          // Neutral lift (no teal glow) — the focused teal border carries the
          // accent; the shadow language stays consistent with the cards.
          boxShadow: barrioSoftShadow(
            y: 6,
            blur: focused ? 18 : 12,
            opacity: focused ? 0.12 : 0.08,
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(Icons.search_rounded, size: 21, color: accent),
            const SizedBox(width: 10),
            Expanded(child: _buildTextField()),
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
      ),
    );
  }

  Widget _buildTextField() {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      onChanged: _onChanged,
      textInputAction: TextInputAction.search,
      cursorColor: BarrioColors.tealWarm,
      style: GoogleFonts.ibmPlexSans(
        fontSize: 14.5,
        color: BarrioColors.textPrimary,
      ),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 15),
        hintText: 'Search the training library',
        hintStyle: GoogleFonts.ibmPlexSans(
          fontSize: 14.5,
          color: BarrioColors.textSecondary.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// The search-results sliver shown in place of the center bubble and
/// category sections while a query is active.
class BarrioHomeSearchResults extends StatefulWidget {
  /// Trimmed query, at least [BarrioTrainingSearch.kMinQueryLength]
  /// characters (the caller enforces the minimum).
  final String query;

  final BarrioPreviewRole previewRole;

  /// B18 production hook; when non-null it overrides [previewRole],
  /// exactly like the shelf bubbles.
  final BarrioDestinationVisibilityResolver? visibilityResolver;

  final void Function(
    BarrioTrainingSearchResult result,
    BarrioDestination destination,
  ) onResultTap;

  const BarrioHomeSearchResults({
    super.key,
    required this.query,
    required this.onResultTap,
    this.previewRole = BarrioPreviewRole.admin,
    this.visibilityResolver,
  });

  @override
  State<BarrioHomeSearchResults> createState() =>
      _BarrioHomeSearchResultsState();
}

class _BarrioHomeSearchResultsState extends State<BarrioHomeSearchResults> {
  /// The query [_results] answers, or null before the first search.
  String? _memoQuery;

  /// The visible destination set [_results] were filtered against.
  Set<String> _memoAllowed = const <String>{};

  List<BarrioTrainingSearchResult> _results =
      const <BarrioTrainingSearchResult>[];

  /// Resolver-first, preview-role-fallback visibility, mirroring
  /// `BarrioHomeShelf._isDestVisible`. A doc with no destination entry
  /// can never be opened, so it never renders.
  bool _isAllowed(String destinationId) {
    final dest = _kDestinationById[destinationId];
    if (dest == null) return false;
    final resolver = widget.visibilityResolver;
    if (resolver != null) return resolver.isVisible(dest);
    return widget.previewRole.isIntendedFor(dest);
  }

  /// The destination ids visible right now.
  ///
  /// This is the memo key rather than the resolver object because the
  /// home screen builds a fresh
  /// `PermissionContextBarrioVisibilityResolver` on every build, so
  /// comparing resolver identity would miss every time and the memo
  /// would never hold. Resolving the ~30 destinations up front is
  /// cheap, exact, and re-runs the scan only when what the user may
  /// open actually changed. It is also strictly fewer resolver calls
  /// than the old path, which asked once per corpus unit.
  Set<String> _allowedDestinationIds() {
    return <String>{
      for (final id in _kDestinationById.keys)
        if (_isAllowed(id)) id,
    };
  }

  /// Memoized hit list: the scan runs only when the query or the
  /// visible destination set changed (audit A3.2).
  List<BarrioTrainingSearchResult> _resultsFor(Set<String> allowed) {
    if (_memoQuery == widget.query && setEquals(_memoAllowed, allowed)) {
      return _results;
    }
    _memoQuery = widget.query;
    _memoAllowed = allowed;
    // `allowed.contains` answers exactly what `_isAllowed` answers: an
    // id outside the destination registry is in neither.
    _results = BarrioTrainingSearch.search(
      widget.query,
      isDestinationAllowed: allowed.contains,
    );
    return _results;
  }

  @override
  Widget build(BuildContext context) {
    final results = _resultsFor(_allowedDestinationIds());
    if (results.isEmpty) {
      return SliverToBoxAdapter(child: _EmptyState(query: widget.query));
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      sliver: SliverList.builder(
        itemCount: results.length,
        itemBuilder: (context, index) {
          final result = results[index];
          final destination = _kDestinationById[result.destinationId]!;
          return _SearchResultRow(
            result: result,
            accent: barrioHomeAccentFor(result.destinationId),
            onTap: () => widget.onResultTap(result, destination),
          );
        },
      ),
    );
  }
}

/// Honest empty state: real matches or nothing, no suggestions.
class _EmptyState extends StatelessWidget {
  final String query;

  const _EmptyState({required this.query});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 56, 20, 0),
      child: Container(
        // Same near-opaque white card as the result rows, with a
        // hairline navy edge so it reads on the cream backdrop.
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        decoration: BoxDecoration(
          color: BarrioColors.glassFill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x1416243B)),
        ),
        child: Column(
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 36,
              color: BarrioColors.textMuted.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 12),
            Text(
              "No matches for '$query'",
              textAlign: TextAlign.center,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 14,
                color: BarrioColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One result row: accent icon chip, doc title, section title, and the
/// snippet with matched words bolded.
class _SearchResultRow extends StatelessWidget {
  final BarrioTrainingSearchResult result;
  final Color accent;
  final VoidCallback onTap;

  const _SearchResultRow({
    required this.result,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Accessibility (rec #12): one merged button per hit (manual,
    // section, and snippet read as one row).
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MergeSemantics(
        child: Semantics(
          button: true,
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                // Near-opaque white card with a hairline navy edge so
                // each result row reads cleanly on the cream backdrop.
                color: BarrioColors.glassFill,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0x1416243B)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _iconChip(context),
                  const SizedBox(width: 12),
                  Expanded(child: _texts()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconChip(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.40)),
      ),
      child: Center(
        child: barrioHomeIconWidgetFor(
          context,
          result.destinationId,
          22,
          accent,
          false,
        ),
      ),
    );
  }

  Widget _texts() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          result.docTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.playfairDisplay(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: BarrioColors.textPrimary,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          result.chapterTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexMono(
            fontSize: 10.5,
            letterSpacing: 0.6,
            color: accent.withValues(alpha: 0.85),
          ),
        ),
        const SizedBox(height: 6),
        _snippetText(),
      ],
    );
  }

  Widget _snippetText() {
    // A3.3: reading `result.snippet` is what builds it. This runs
    // inside the sliver's item builder, so only the handful of rows
    // actually on screen ever compute a snippet window.
    final snippet = result.snippet;
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
      TextSpan(children: _snippetSpans(snippet, base, bold)),
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
      spans.add(TextSpan(text: text.substring(cursor, match.start), style: base));
    }
    spans.add(TextSpan(text: text.substring(match.start, match.end), style: bold));
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: base));
  }
  if (snippet.cutAtEnd) spans.add(TextSpan(text: '...', style: base));
  return spans;
}
