import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

/// Single chapter entry for the Learn rail — label + leading icon.
class LearnChapter {
  final String title;
  final IconData icon;
  const LearnChapter({required this.title, required this.icon});
}

/// Horizontal chapter rail for the Variance > Learn tab.
///
/// Forked from Barrio's `LearningSectionRail` with two adaptations:
///
/// 1. Uses Forge & Flow colors (`AppColors`) and text styles
///    (`AppTextStyles.mono12`) instead of `BarrioColors` / `GoogleFonts`,
///    so the rail reads as a sibling of the variance TabBar and the
///    other tabbed surfaces in this app.
/// 2. Takes plain `IconData` instead of an `int` codepoint lookup —
///    there's no need for tree-shake-friendly constants here; the
///    caller already references the icons statically.
///
/// Completion state is intentionally unsupported (no checkmark overlay)
/// because the Variance Learn tab has no mastery / progress tracking —
/// the user scoped that out.
class LearnChapterRail extends StatelessWidget {
  final List<LearnChapter> chapters;
  final int activeIndex;
  final ValueChanged<int> onTap;

  const LearnChapterRail({
    super.key,
    required this.chapters,
    required this.activeIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: chapters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final isActive = i == activeIndex;
          final chapter = chapters[i];

          return GestureDetector(
            onTap: () => onTap(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.sunset.withValues(alpha: 0.14)
                    : AppColors.backgroundMid.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: isActive
                      ? AppColors.sunset.withValues(alpha: 0.55)
                      : AppColors.borderSubtle.withValues(alpha: 0.7),
                  width: 1,
                ),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color:
                              AppColors.sunset.withValues(alpha: 0.22),
                          blurRadius: 10,
                          spreadRadius: 0,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    chapter.icon,
                    size: 16,
                    color: isActive
                        ? AppColors.sunset
                        : AppColors.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    chapter.title,
                    style: AppTextStyles.mono12(
                      color: isActive
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                      weight:
                          isActive ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
