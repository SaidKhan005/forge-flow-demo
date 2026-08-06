import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'barrio_chapter_icons.dart';
import 'barrio_destination_scaffold.dart';
import '../content/company_handbook_content.dart';

/// Constant icon lookup for handbook chapter rail icons.
/// Maps each known iconCodePoint to its tree-shake-friendly Icons constant
/// so that release builds can eliminate unused glyphs from MaterialIcons.
/// Generated chapters all carry the generator's placeholder code point,
/// which is deliberately NOT in this map: they resolve through the
/// curated chapter icon map instead (visual wayfinding, recs 2+5).
const _chapterIcons = <int, IconData>{
  0xe533: Icons.restaurant_menu,
  0xe556: Icons.schedule,
  0xe4d9: Icons.policy,
  0xea21: Icons.groups,
  0xe305: Icons.health_and_safety,
};

/// Horizontal chapter selector rail for the Company Handbook screen.
///
/// Active chapter uses the destination's accent color with a subtle glow.
/// Inactive chapters are light glass tiles on the cream shell.
///
/// Accessibility pass (rec #12, 2026-07-24): the rail height grows with
/// the effective text scale instead of clipping its tiles. The formula
/// is anchored so the 1.0x heights are exactly the pre-pass constants
/// (72, or 86 with the minutes line): fixed chrome (padding, icon row,
/// gaps, centering slack) plus the scaled text-line allocations.
///
/// Swipe-follow pass (2026-07-26 operator request "as we scroll through
/// cards horizontally the chapters at the top also move along"): when
/// the active chapter changes (deck swipe, tap-zone turn, rail tap, or
/// resume restore) the rail animate-scrolls so the active tile is
/// brought into view (centered as far as the scroll extent allows).
/// The rail is now stateful so it can own that scroll behavior; it is
/// backed by a non-lazy [SingleChildScrollView] so every tile stays
/// laid out and therefore has a live [BuildContext] for
/// [Scrollable.ensureVisible] to target even while off-screen.
class HandbookChapterRail extends StatefulWidget {
  final List<HandbookChapter> chapters;
  final int activeIndex;
  final Set<String> completedChapterIds;
  final Color activeAccent;
  final ValueChanged<int> onChapterTap;

  /// Optional per-chapter reading-time estimates in minutes, parallel
  /// to [chapters]. When provided, each tile appends a quiet
  /// 'about N min' line and the rail grows to fit it. Null (the
  /// default) keeps the rail exactly as before.
  final List<int>? chapterMinutes;

  const HandbookChapterRail({
    super.key,
    required this.chapters,
    required this.activeIndex,
    required this.completedChapterIds,
    required this.activeAccent,
    required this.onChapterTap,
    this.chapterMinutes,
  });

  @override
  State<HandbookChapterRail> createState() => _HandbookChapterRailState();
}

class _HandbookChapterRailState extends State<HandbookChapterRail> {
  /// Non-text chrome inside a tile plus centering slack: at 1.0x this
  /// yields the pre-pass 72 (no minutes) / 86 (minutes) heights.
  static const double _kFixedChrome = 55.0;

  /// Unscaled allocation for the 12px title line (72 - 55 at 1.0x).
  static const double _kTitleAllocation = 17.0;

  /// Unscaled allocation for the 9.5px minutes line plus its 2px gap
  /// (86 - 72 at 1.0x).
  static const double _kMinutesAllocation = 14.0;

  /// Glide used when the active tile is scrolled into view. Reduce-motion
  /// swaps this for an instant jump (see [_revealActiveTile]).
  static const Duration _kScrollDuration = Duration(milliseconds: 280);

  /// One key per tile: the target for [Scrollable.ensureVisible]. Kept
  /// stable across rebuilds (grown/shrunk in place) so tile element
  /// identity survives.
  final List<GlobalKey> _tileKeys = <GlobalKey>[];

  @override
  void initState() {
    super.initState();
    _syncTileKeys();
    // First layout may already open on a resumed/deep-linked chapter
    // whose tile is off-screen: bring it into view without animation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealActiveTile(animate: false);
    });
  }

  @override
  void didUpdateWidget(covariant HandbookChapterRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTileKeys();
    if (oldWidget.activeIndex != widget.activeIndex) {
      // The visible card moved into a different chapter: follow it so
      // the active tile never stays stranded off-screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _revealActiveTile(animate: true);
      });
    }
  }

  /// Grows/shrinks [_tileKeys] to match the chapter count, preserving
  /// existing keys so unchanged tiles keep their element identity.
  void _syncTileKeys() {
    final count = widget.chapters.length;
    if (_tileKeys.length == count) return;
    if (_tileKeys.length < count) {
      _tileKeys.addAll(
        List.generate(count - _tileKeys.length, (_) => GlobalKey()),
      );
    } else {
      _tileKeys.removeRange(count, _tileKeys.length);
    }
  }

  /// Scrolls the rail so the active tile sits centered (clamped to the
  /// scroll extent, so the first/last tiles rest against their edge).
  /// Respects reduce-motion: [MediaQuery.disableAnimations] makes the
  /// move an instant jump rather than an animated glide.
  void _revealActiveTile({required bool animate}) {
    if (!mounted) return;
    final index = widget.activeIndex;
    if (index < 0 || index >= _tileKeys.length) return;
    final tileContext = _tileKeys[index].currentContext;
    if (tileContext == null) return;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    Scrollable.ensureVisible(
      tileContext,
      alignment: 0.5,
      duration: (animate && !reduceMotion) ? _kScrollDuration : Duration.zero,
      curve: Curves.easeOut,
    );
  }

  /// True when the chapter at [index] opens a new named part (its
  /// partIndex differs from the previous chapter's). False for manuals
  /// without part grouping, so the rail renders exactly as before.
  bool _startsNewPart(int index) {
    final part = widget.chapters[index].partIndex;
    if (part == null) return false;
    return part != widget.chapters[index - 1].partIndex;
  }

  @override
  Widget build(BuildContext context) {
    final minutes = widget.chapterMinutes;
    final textScaler = MediaQuery.textScalerOf(context);
    final height = _kFixedChrome +
        textScaler.scale(_kTitleAllocation) +
        (minutes == null ? 0 : textScaler.scale(_kMinutesAllocation));
    return SizedBox(
      height: height,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < widget.chapters.length; index++) ...[
              // Part separator (structure pass): where a new named part
              // begins, a slim accent rule replaces the plain gap so the
              // reader sees the part boundary in the rail. Manuals without
              // part grouping never hit this branch (plain gaps as before).
              if (index > 0)
                if (_startsNewPart(index))
                  _PartRailSeparator(
                    chapter: widget.chapters[index],
                    accent: widget.activeAccent,
                  )
                else
                  const SizedBox(width: 10),
              _ChapterRailTile(
                key: _tileKeys[index],
                chapter: widget.chapters[index],
                index: index,
                chapterCount: widget.chapters.length,
                isActive: index == widget.activeIndex,
                isCompleted: widget.completedChapterIds
                    .contains(widget.chapters[index].id),
                activeAccent: widget.activeAccent,
                minutes: minutes != null && index < minutes.length
                    ? minutes[index]
                    : null,
                onTap: () => widget.onChapterTap(index),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One rail tile: icon (+ persisted all-cards-read check), title, and
/// an optional quiet 'about N min' reading-time line.
///
/// Screen-reader contract (rec #12): one merged button per tile, e.g.
/// 'Section 3 of 12: Milk, about 4 minutes, read'. The visible texts
/// are excluded so nothing reads twice; the label always carries the
/// FULL title even when the visible line ellipsizes.
class _ChapterRailTile extends StatelessWidget {
  final HandbookChapter chapter;
  final int index;
  final int chapterCount;
  final bool isActive;
  final bool isCompleted;
  final Color activeAccent;
  final int? minutes;
  final VoidCallback onTap;

  const _ChapterRailTile({
    super.key,
    required this.chapter,
    required this.index,
    required this.chapterCount,
    required this.isActive,
    required this.isCompleted,
    required this.activeAccent,
    required this.minutes,
    required this.onTap,
  });

  String get _semanticsLabel {
    final buffer = StringBuffer(
      'Section ${index + 1} of $chapterCount: ${chapter.title}',
    );
    final mins = minutes;
    if (mins != null) {
      buffer.write(mins == 1 ? ', about 1 minute' : ', about $mins minutes');
    }
    if (isCompleted) buffer.write(', read');
    return buffer.toString();
  }

  /// Tile decoration, split out of [build] to honor the 80-line
  /// engineering bar (metrics ratchet).
  BoxDecoration _tileDecoration() {
    return BoxDecoration(
      color: isActive
          ? activeAccent.withValues(alpha: 0.15)
          : const Color(0x0A16243B),
      borderRadius: BorderRadius.circular(BarrioRadii.chip),
      border: Border.all(
        color: isActive
            ? activeAccent.withValues(alpha: 0.50)
            : BarrioColors.hairline,
      ),
      boxShadow: isActive
          ? [
              BoxShadow(
                color: activeAccent.withValues(alpha: 0.20),
                blurRadius: 10,
                spreadRadius: 0,
              ),
            ]
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isActive,
      label: _semanticsLabel,
      child: GestureDetector(
        onTap: onTap,
        child: ExcludeSemantics(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: _tileDecoration(),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      // Fallback chain (visual wayfinding, recs 2+5):
                      // curated code-point icon (original handbook screen)
                      // -> curated chapter icon -> manual identity icon ->
                      // circle_outlined only when nothing resolves.
                      _chapterIcons[chapter.iconCodePoint] ??
                          barrioChapterIconFor(chapter.id),
                      size: 16,
                      color: isActive ? activeAccent : BarrioColors.textMuted,
                    ),
                    if (isCompleted) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.check_circle,
                          size: 12, color: BarrioColors.success),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 12,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    color: isActive
                        ? BarrioColors.textPrimary
                        : BarrioColors.textMuted,
                  ),
                ),
                if (minutes != null) ...[
                  const SizedBox(height: 2),
                  // Quiet reading-time estimate; small muted text so the
                  // dense rail stays calm.
                  Text(
                    'about $minutes min',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 9.5,
                      color: BarrioColors.textMuted.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Slim part-boundary marker in the chapter rail (structure pass).
/// Rendered before the first tile of each named part (except the very
/// first): a small 'PART k' cap and a thin accent rule so the reader
/// sees where a new part begins as they scroll the rail. The full part
/// name rides the screen-reader label; the hero carries it visibly.
class _PartRailSeparator extends StatelessWidget {
  final HandbookChapter chapter;
  final Color accent;

  const _PartRailSeparator({required this.chapter, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Part ${chapter.partIndex} of ${chapter.partCount}: '
          '${chapter.partTitle}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 4),
              Text(
                'PART ${chapter.partIndex}',
                maxLines: 1,
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: accent.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Container(
                  width: 2,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.40),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}
