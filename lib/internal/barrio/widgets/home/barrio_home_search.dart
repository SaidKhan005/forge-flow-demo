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
// Lives under widgets/home so the UX no-em-dash lint root covers every
// operator-facing string here.

import 'dart:async';

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
    final accent = focused ? BarrioColors.tealWarm : BarrioColors.textMuted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: focused
                ? BarrioColors.tealWarm.withValues(alpha: 0.55)
                : const Color(0x2EFFFFFF),
          ),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: BarrioColors.tealWarm.withValues(alpha: 0.18),
                    blurRadius: 14,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(Icons.search_rounded, size: 20, color: accent),
            const SizedBox(width: 10),
            Expanded(child: _buildTextField()),
            if (_controller.text.isNotEmpty)
              GestureDetector(
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
        contentPadding: const EdgeInsets.symmetric(vertical: 13),
        hintText: 'Search the training library',
        hintStyle: GoogleFonts.ibmPlexSans(
          fontSize: 14.5,
          color: BarrioColors.textMuted.withValues(alpha: 0.8),
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
class BarrioHomeSearchResults extends StatelessWidget {
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

  /// Resolver-first, preview-role-fallback visibility, mirroring
  /// `BarrioHomeShelf._isDestVisible`. A doc with no destination entry
  /// can never be opened, so it never renders.
  bool _isAllowed(String destinationId) {
    final dest = _kDestinationById[destinationId];
    if (dest == null) return false;
    final resolver = visibilityResolver;
    if (resolver != null) return resolver.isVisible(dest);
    return previewRole.isIntendedFor(dest);
  }

  @override
  Widget build(BuildContext context) {
    final results =
        BarrioTrainingSearch.search(query, isDestinationAllowed: _isAllowed);
    if (results.isEmpty) {
      return SliverToBoxAdapter(child: _EmptyState(query: query));
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
            onTap: () => onResultTap(result, destination),
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
        // Same near-opaque dark card as the result rows: the empty
        // state also sits over the photo's lightest scrim zone.
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        decoration: BoxDecoration(
          color: BarrioColors.shellMid.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x24FFFFFF)),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            // Near-opaque dark card: the rows sit over the home photo,
            // whose scrim is lightest mid-screen, so a translucent wash
            // is unreadable there (operator report 2026-07-11).
            color: BarrioColors.shellMid.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x24FFFFFF)),
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
