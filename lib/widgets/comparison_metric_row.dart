// Phase 7.55o.1 — shared comparison-surface primitive.
//
// Lifted out of `lib/screens/variance_report.dart` and
// `lib/screens/week_detail_screen.dart` so the duplicated metric-row widget
// lives in one place. Structure only — no formula, color, font, bold, or
// label change from the private `_TableRow` implementations it replaces.
//
// Vertical padding is parameterized because the live Variance WTD table
// (12) and the closed Week Detail summary table (14) historically differ
// by two logical pixels. The default matches Variance; Week Detail passes
// 14 explicitly.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ComparisonMetricRow extends StatelessWidget {
  final String label;
  final String target;
  final String actual;
  final String variance;
  final Color varColor;
  final bool isBold;
  final double verticalPadding;

  const ComparisonMetricRow({
    super.key,
    required this.label,
    required this.target,
    required this.actual,
    required this.variance,
    this.varColor = AppColors.textMuted,
    this.isBold = false,
    this.verticalPadding = 12,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: verticalPadding),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: isBold
                  ? AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w600,
                    )
                  : AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              target,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              actual,
              style: isBold
                  ? AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w600,
                    )
                  : AppTextStyles.mono12(color: AppColors.textPrimary),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              variance,
              style: AppTextStyles.mono14(
                color: varColor,
                weight: FontWeight.w700,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
