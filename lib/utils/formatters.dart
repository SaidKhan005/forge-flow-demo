// ─── Formatting utilities ─────────────────────────────────────────────────────
// Single source for all display formatting across VarianceReport,
// WeekDetailScreen, VarianceBanner, WeekHistoryTile, ScheduleBuilder,
// and BaselineTracker.
//
// No business logic here — pure string/color formatting only.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

abstract class Fmt {
  Fmt._();

  // ── Dollar / number ────────────────────────────────────────────────────────

  /// Thousands-separated integer string. Handles both int and double.
  /// e.g. 1234.7 → '1,235'  |  1234 → '1,234'
  static String dollars(num n) => n
      .toDouble()
      .toStringAsFixed(0)
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');

  // ── Variance strings ──────────────────────────────────────────────────────

  /// Integer delta with sign and en-dash minus: +5 or −3
  static String varStr(int delta) =>
      delta >= 0 ? '+$delta' : '−${delta.abs()}';

  /// Floating delta with sign, configurable decimals: +0.23 or −1.50
  static String varDelta(double delta, {int dec = 2}) {
    final sign = delta >= 0 ? '+' : '−';
    return '$sign${delta.abs().toStringAsFixed(dec)}';
  }

  /// Dollar variance with sign: +$1.23 or −$0.50
  static String varDollars(double delta) {
    final sign = delta >= 0 ? '+' : '−';
    return '$sign\$${delta.abs().toStringAsFixed(2)}';
  }

  /// Percentage-point variance with sign and plural: +1.2 pts or −0.8 pt
  static String varPts(double delta) {
    final sign = delta >= 0 ? '+' : '−';
    final abs = delta.abs().toStringAsFixed(1);
    return '$sign$abs pt${delta.abs() != 1.0 ? 's' : ''}';
  }

  // ── Variance color ─────────────────────────────────────────────────────────

  // Metrics where a LOWER actual vs target is unfavorable (positive direction = good).
  static const _higherIsBetter = {'Covers', 'PPA', 'CPLH', 'SPLH'};

  /// Returns negative (red) or positive (green) based on metric and delta sign.
  /// Metrics in _higherIsBetter: delta < 0 → negative.
  /// All other metrics (cost/hours/labor %): delta > 0 → negative.
  static Color varColor(String metric, double delta) {
    return _higherIsBetter.contains(metric)
        ? (delta < 0 ? AppColors.negative : AppColors.positive)
        : (delta > 0 ? AppColors.negative : AppColors.positive);
  }
}
