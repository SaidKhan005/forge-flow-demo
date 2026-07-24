import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'barrio_destination_scaffold.dart';
import '../content/company_handbook_content.dart';

/// Constant icon lookup for handbook chapter rail icons.
/// Maps each known iconCodePoint to its tree-shake-friendly Icons constant
/// so that release builds can eliminate unused glyphs from MaterialIcons.
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
/// Inactive chapters are dark glass tiles.
///
/// Accessibility pass (rec #12, 2026-07-24): the rail height grows with
/// the effective text scale instead of clipping its tiles. The formula
/// is anchored so the 1.0x heights are exactly the pre-pass constants
/// (72, or 86 with the minutes line): fixed chrome (padding, icon row,
/// gaps, centering slack) plus the scaled text-line allocations.
class HandbookChapterRail extends StatelessWidget {
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

  /// Non-text chrome inside a tile plus centering slack: at 1.0x this
  /// yields the pre-pass 72 (no minutes) / 86 (minutes) heights.
  static const double _kFixedChrome = 55.0;

  /// Unscaled allocation for the 12px title line (72 - 55 at 1.0x).
  static const double _kTitleAllocation = 17.0;

  /// Unscaled allocation for the 9.5px minutes line plus its 2px gap
  /// (86 - 72 at 1.0x).
  static const double _kMinutesAllocation = 14.0;

  @override
  Widget build(BuildContext context) {
    final minutes = chapterMinutes;
    final textScaler = MediaQuery.textScalerOf(context);
    final height = _kFixedChrome +
        textScaler.scale(_kTitleAllocation) +
        (minutes == null ? 0 : textScaler.scale(_kMinutesAllocation));
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: chapters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final chapter = chapters[index];
          return _ChapterRailTile(
            chapter: chapter,
            index: index,
            chapterCount: chapters.length,
            isActive: index == activeIndex,
            isCompleted: completedChapterIds.contains(chapter.id),
            activeAccent: activeAccent,
            minutes: minutes != null && index < minutes.length
                ? minutes[index]
                : null,
            onTap: () => onChapterTap(index),
          );
        },
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
            decoration: BoxDecoration(
              color: isActive
                  ? activeAccent.withValues(alpha: 0.15)
                  : const Color(0x0FFFFFFF),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isActive
                    ? activeAccent.withValues(alpha: 0.50)
                    : const Color(0x1AFFFFFF),
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
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _chapterIcons[chapter.iconCodePoint] ??
                          Icons.circle_outlined,
                      size: 16,
                      color: isActive ? activeAccent : BarrioColors.textMuted,
                    ),
                    if (isCompleted) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.check_circle,
                          size: 12, color: Color(0xFF2ECC71)),
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
