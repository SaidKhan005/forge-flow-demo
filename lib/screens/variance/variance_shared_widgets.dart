// Phase 7.55o.2 — Variance shared widget primitives.
//
// Small helpers used by more than one Variance tab file. At present only
// the chip widget previously named `_LearnChip` in variance_report.dart,
// which History's benchmark-daypart evidence card and the Learn tab both
// render. Behaviour and styling are unchanged from the pre-split version.

import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class VarianceChip extends StatelessWidget {
  final String label;
  final Color color;
  const VarianceChip({
    super.key,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(label, style: AppTextStyles.mono8(color: color)),
    );
  }
}
