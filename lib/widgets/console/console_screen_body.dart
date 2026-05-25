import 'package:flutter/material.dart';

/// Centered, max-width scroll body shared by operator-web screens.
///
/// Every screen's main content sits in the same centered column (matching
/// the Data accuracy screen the operator standardized on): a scroll view
/// with the screen's edge [padding], whose child is centered and capped at
/// [maxContentWidth] so wide viewports get balanced margins instead of
/// edge-to-edge content. [scrollKey] is applied to the inner
/// `SingleChildScrollView` so existing screen-body keys keep resolving to a
/// `SingleChildScrollView` exactly as before.
class OperatorWebScreenBody extends StatelessWidget {
  const OperatorWebScreenBody({
    super.key,
    this.scrollKey,
    required this.padding,
    this.maxContentWidth = 1120,
    required this.child,
  });

  final Key? scrollKey;
  final EdgeInsetsGeometry padding;
  final double maxContentWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedPadding = padding.resolve(Directionality.of(context));
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth -
                  resolvedPadding.left -
                  resolvedPadding.right
            : maxContentWidth;
        final boundedWidth =
            availableWidth.isFinite && availableWidth < maxContentWidth
            ? availableWidth.clamp(0.0, maxContentWidth)
            : maxContentWidth;
        return SingleChildScrollView(
          key: scrollKey,
          padding: padding,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(width: boundedWidth, child: child),
          ),
        );
      },
    );
  }
}

/// Centered, max-width frame for screens that must NOT scroll vertically
/// at the page level: fixed-height tabbed screens whose body is a
/// `TabBar` + `Expanded(TabBarView)` (each tab scrolling internally) and
/// therefore cannot live inside [OperatorWebScreenBody]'s
/// `SingleChildScrollView` (which would strip the `Expanded` fill).
///
/// It renders the same balanced layout [OperatorWebScreenBody] gives
/// scroll screens (content [Center]ed and capped at [maxContentWidth],
/// with edge [padding]) but keeps its [child] at the bounded incoming
/// height so an `Expanded` inside it still works. The caller supplies the
/// background (e.g. a `ColoredBox` or `Material`) so this widget stays
/// background-agnostic.
class OperatorWebScreenFrame extends StatelessWidget {
  const OperatorWebScreenFrame({
    super.key,
    required this.padding,
    this.maxContentWidth = 1120,
    required this.child,
  });

  final EdgeInsetsGeometry padding;
  final double maxContentWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxContentWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
