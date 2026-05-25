import 'package:flutter/material.dart';

/// Shared action cluster for console headers, section headings, and rows.
///
/// The console has many small action groups. Keeping the spacing and right-edge
/// alignment here prevents each screen from inventing a slightly different
/// button location.
class OperatorWebActionBar extends StatelessWidget {
  const OperatorWebActionBar({
    super.key,
    required this.children,
    this.spacing = 10,
    this.runSpacing = 8,
    this.alignment = WrapAlignment.end,
    this.crossAxisAlignment = WrapCrossAlignment.center,
  });

  final List<Widget> children;
  final double spacing;
  final double runSpacing;
  final WrapAlignment alignment;
  final WrapCrossAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      alignment: alignment,
      crossAxisAlignment: crossAxisAlignment,
      children: children,
    );
  }
}
