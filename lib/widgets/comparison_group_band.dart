// Phase 7.55o.1 — shared comparison-surface primitive.
//
// Lifted out of `lib/screens/variance_report.dart` and
// `lib/screens/week_detail_screen.dart` so the duplicated section-band widget
// lives in one place. Structure only — no behavior, color, sizing, or label
// change from the private `_GroupBand` implementations it replaces.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ComparisonGroupBand extends StatelessWidget {
  final String label;

  const ComparisonGroupBand(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.backgroundDeep,
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
      child: Row(
        children: [
          Container(width: 2, height: 10, color: AppColors.sunsetDark),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppTextStyles.mono8(color: AppColors.sunsetDark),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 1,
              color: AppColors.sunsetDark.withValues(alpha: 0.2),
            ),
          ),
        ],
      ),
    );
  }
}
