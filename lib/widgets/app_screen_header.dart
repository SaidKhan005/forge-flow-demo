import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Unified top-of-screen header used across Shift / Variance / Plan /
/// Benchmark.
///
/// Locks every screen to the same top-bar height so the four tabs feel
/// cohesive when you swipe between them. The title sits in a fixed-height
/// title row in `display28`; the [bottom] slot sits in a second
/// fixed-height row underneath (used for Variance's TabBar, for Shift's
/// day + live time meta line, and left empty for Plan / Benchmark).
class AppScreenHeader extends StatelessWidget {
  static const double _titleRowHeight = 68;
  static const double _bottomRowHeight = 50;

  /// Total fixed header height. Exposed so callers (e.g. SliverAppBar
  /// hosts) can size around it.
  static const double height = _titleRowHeight + _bottomRowHeight;

  final String title;
  final Widget? bottom;

  const AppScreenHeader({
    super.key,
    required this.title,
    this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundDeep, AppColors.shimmer],
        ),
        border: Border(
          bottom: BorderSide(
            color: AppColors.borderSubtle.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row — fixed height, title aligned to the bottom so
          // every screen's display28 lands on the same baseline.
          SizedBox(
            height: _titleRowHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  title,
                  style: AppTextStyles.display28(),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          // Bottom row — fixed height. Holds tabs (Variance), the
          // day/time meta (Shift), or stays empty (Plan, Benchmark) so
          // the four tabs feel cohesive height-wise.
          SizedBox(
            height: _bottomRowHeight,
            child: bottom ?? const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// Compact stat pill used inside an [AppScreenHeader.bottom] slot to
/// surface a single headline metric (e.g. "COVERS · 1,234"). Designed
/// to fit two-up in the 50px-tall bottom row.
class AppHeaderStat extends StatelessWidget {
  final String label;
  final String value;
  const AppHeaderStat({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.45),
        border: Border.all(
            color: AppColors.borderSubtle.withValues(alpha: 0.7), width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(label,
              style: AppTextStyles.mono8(color: AppColors.textMuted)),
          const SizedBox(width: 8),
          Text(value,
              style: AppTextStyles.mono12(color: AppColors.textPrimary)),
        ],
      ),
    );
  }
}

/// Wraps an [AppScreenHeader] (or any header widget) above a scrollable
/// child and listens to the child's scroll updates so the header fades
/// slightly as the user scrolls down and restores as they scroll back
/// up. Keeps the header sticky (it never leaves its slot) so all four
/// screens share the same chrome behavior.
class FadingHeaderShell extends StatefulWidget {
  final Widget header;
  final Widget child;

  /// Lower bound on the header opacity. Defaults to 0.55 — header never
  /// fully disappears, just dims so the underlying content can breathe.
  final double minOpacity;

  /// Pixels of cumulative scroll-down required to reach [minOpacity].
  final double fadeDistance;

  const FadingHeaderShell({
    super.key,
    required this.header,
    required this.child,
    this.minOpacity = 0.55,
    this.fadeDistance = 90,
  });

  @override
  State<FadingHeaderShell> createState() => _FadingHeaderShellState();
}

class _FadingHeaderShellState extends State<FadingHeaderShell> {
  double _opacity = 1.0;

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      if (delta == 0) return false;
      final fadeStep = (1.0 - widget.minOpacity) / widget.fadeDistance;
      final next = (_opacity - delta * fadeStep)
          .clamp(widget.minOpacity, 1.0);
      if ((next - _opacity).abs() > 0.001) {
        setState(() => _opacity = next);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AnimatedOpacity(
          opacity: _opacity,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: widget.header,
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}


