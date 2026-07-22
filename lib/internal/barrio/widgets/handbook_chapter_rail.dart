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

  @override
  Widget build(BuildContext context) {
    final minutes = chapterMinutes;
    return SizedBox(
      height: minutes == null ? 72 : 86,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: chapters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final chapter = chapters[index];
          final isActive = index == activeIndex;
          final isCompleted = completedChapterIds.contains(chapter.id);

          return GestureDetector(
            onTap: () => onChapterTap(index),
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
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isActive
                          ? BarrioColors.textPrimary
                          : BarrioColors.textMuted,
                    ),
                  ),
                  if (minutes != null && index < minutes.length) ...[
                    const SizedBox(height: 2),
                    // Quiet reading-time estimate; small muted text so
                    // the dense rail stays calm.
                    Text(
                      'about ${minutes[index]} min',
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
          );
        },
      ),
    );
  }
}
