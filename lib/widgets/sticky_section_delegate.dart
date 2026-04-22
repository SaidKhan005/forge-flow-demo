import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Reusable [SliverPersistentHeaderDelegate] that renders a teal-accent
/// section label (same visual as the app's `_SectionLabel` widgets) and
/// pins to the top of the scroll area until the next sticky header
/// pushes it off.
///
/// Height is a compact 52 px — the original ~72 px included 32 px of
/// inter-section spacing that now lives on the content slivers instead.
///
/// When [overlapsContent] is true (i.e. the header is floating above
/// scrolling content), a subtle drop-shadow appears so the label
/// visually separates from what's behind it.
/// Plain scrolling section label — same visual as the delegate version
/// but renders as a normal widget inside a SliverToBoxAdapter. Does NOT
/// pin or float — it scrolls with the content.
class SectionLabel extends StatelessWidget {
  final String label;
  const SectionLabel(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: StickySectionDelegate.extent,
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 18,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [AppColors.sunset, AppColors.sunsetDark],
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              height: 2,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.sunset, AppColors.sunsetDark],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StickySectionDelegate extends SliverPersistentHeaderDelegate {
  final String label;

  static const double extent = 52.0;

  const StickySectionDelegate(this.label);

  @override
  double get maxExtent => extent;

  @override
  double get minExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      height: extent,
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        boxShadow: overlapsContent
            ? [
                BoxShadow(
                  color: AppColors.backgroundDeep.withValues(alpha: 0.8),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 18,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [AppColors.sunset, AppColors.sunsetDark],
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              height: 2,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.sunset, AppColors.sunsetDark],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant StickySectionDelegate oldDelegate) =>
      oldDelegate.label != label;
}

/// Sticky column header for variance tables (TARGET | ACTUAL | VAR).
///
/// Pins at the top of a `SliverMainAxisGroup` so it stays visible while
/// table rows scroll underneath, then gets pushed off when the next
/// section arrives. Same push-off behavior as [StickySectionDelegate].
class StickyColumnHeaderDelegate extends SliverPersistentHeaderDelegate {
  static const double extent = 36.0;

  const StickyColumnHeaderDelegate();

  @override
  double get maxExtent => extent;

  @override
  double get minExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // 16px horizontal margin matches the WTD / Week Detail table margin
    // so the column header aligns with the table edges, not the full
    // screen width.
    return Container(
      height: extent,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundSurface, AppColors.shimmer],
        ),
        border: Border(
          bottom: BorderSide(
            color: AppColors.sunset.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
        borderRadius: const BorderRadius.vertical(
            top: Radius.circular(3)),
        boxShadow: overlapsContent
            ? [
                BoxShadow(
                  color: AppColors.backgroundSurface.withValues(alpha: 0.9),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
      child: Row(
        children: [
          const Expanded(flex: 5, child: SizedBox()),
          Expanded(
            flex: 3,
            child: Text(
              'TARGET',
              style: AppTextStyles.mono8(color: AppColors.textMuted),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              'ACTUAL',
              style: AppTextStyles.mono8(color: AppColors.textSecondary),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              'VAR',
              style: AppTextStyles.mono8(color: AppColors.sunsetDark),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant StickyColumnHeaderDelegate oldDelegate) =>
      false;
}

/// Sticky daypart label for the Full Week Projection expanded day detail.
///
/// Renders "Fri Lunch - Closed" style bands that pin at the top while
/// scrolling through that daypart's detail rows. White/surface background
/// with an orange border for open shifts.
class StickyDaypartLabelDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  final bool isOpen;

  /// When true, the right side shows TARGET | ACTUAL | VAR column
  /// headers on the same line as the daypart label, aligned to the
  /// same flex ratios (5:3:3:3) as the table rows below.
  final bool showColumnHeaders;

  static const double extent = 40.0;

  const StickyDaypartLabelDelegate({
    required this.label,
    this.isOpen = false,
    this.showColumnHeaders = false,
  });

  @override
  double get maxExtent => extent;

  @override
  double get minExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // Same visual style as StickyColumnHeaderDelegate: gradient
    // background, 16px margin, rounded top corners, subtle bottom border.
    return Container(
      height: extent,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundSurface, AppColors.shimmer],
        ),
        border: const Border(
          left: BorderSide(color: AppColors.sunset, width: 3),
          right: BorderSide(color: AppColors.sunset, width: 2),
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
        boxShadow: overlapsContent
            ? [
                BoxShadow(
                  color: AppColors.backgroundSurface.withValues(alpha: 0.9),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          // Same flex: 5 as the table rows' label column
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: AppTextStyles.mono8(
                  color: isOpen
                      ? AppColors.sunsetDark
                      : AppColors.textSecondary),
            ),
          ),
          // Same flex: 3+3+3 as the table rows' value columns
          if (showColumnHeaders) ...[
            Expanded(
              flex: 3,
              child: Text('TARGET',
                  style: AppTextStyles.mono7(color: AppColors.textMuted),
                  textAlign: TextAlign.right),
            ),
            Expanded(
              flex: 3,
              child: Text('ACTUAL',
                  style: AppTextStyles.mono7(
                      color: AppColors.textSecondary),
                  textAlign: TextAlign.right),
            ),
            Expanded(
              flex: 3,
              child: Text('VAR',
                  style: AppTextStyles.mono7(
                      color: AppColors.sunsetDark),
                  textAlign: TextAlign.right),
            ),
          ],
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant StickyDaypartLabelDelegate oldDelegate) =>
      oldDelegate.label != label || oldDelegate.isOpen != isOpen;
}
