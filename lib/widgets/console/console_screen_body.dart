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
    return SingleChildScrollView(
      key: scrollKey,
      padding: padding,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxContentWidth),
          child: child,
        ),
      ),
    );
  }
}
