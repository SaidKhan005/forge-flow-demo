// Phase 7.55l.8b — Baseline Selection Analytics Service
//
// Computes selection-analytics (selected shift count, range quality).
//
// After 7.55l.8c/8d, the steady-state Learn resolution path reads from
// a persisted BenchmarkSelectionSummary tied to the active TargetCycle.
// This service is no longer the primary resolution path for Learn.
//
// Current role:
// - override-driven analytics (manager_override / cycle_manager_override)
//   → compute from persisted selected-key state via
//     BaselineManagerService.getCandidateShifts()
// - compatibility recovery input for 8c1 one-time summary backfill
//   when a cycle exists but its BenchmarkSelectionSummary is missing
// - explicit bridge-only mode for widget tests without SQLite
//
// 7.55l.8b1: source-aware resolution. For default recommended/system
// profiles, the service returns bridge analytics from BaselineData
// (empty override table must not be misread as "0 selected star shifts").
// In the canonical Learn path, this branch only fires during the 8c1
// backfill for pre-summary cycles.
//
// Range quality rules match BaselineData.baselineRangeValidation exactly:
// - fewer than 2 selected -> OPZ RANGE TOO NARROW
// - CPLH width < 0.15 -> OPZ RANGE TOO NARROW
// - CPLH width > 1.25 -> OPZ RANGE TOO WIDE
// - otherwise -> GOOD OPZ RANGE

import 'dart:math' as math;

import '../models/baseline_selection_analytics.dart';
import 'baseline_manager_service.dart';
import 'legacy_fixture_data.dart';

class BaselineSelectionAnalyticsService {
  BaselineSelectionAnalyticsService._();
  static final BaselineSelectionAnalyticsService instance =
      BaselineSelectionAnalyticsService._();

  // ── Bridge-only override ─────────────────────────────────────────────────
  // When set, resolve() returns analytics from BaselineData without
  // repository access. Used in widget tests where SQLite is not initialized.

  static bool _useBridgeOnly = false;

  static void enableBridgeOnly() => _useBridgeOnly = true;
  static void disableBridgeOnly() => _useBridgeOnly = false;

  // ── Test injection seam ──────────────────────────────────────────────────
  // Overrides the canonical resolution path for unit tests.
  // Clear between tests.

  static Future<BaselineSelectionAnalytics> Function()? testAnalyticsOverride;

  Future<BaselineSelectionAnalytics> resolve({String? sourceType}) async {
    if (_useBridgeOnly) {
      return _bridgeFallback();
    }

    final override = testAnalyticsOverride;
    if (override != null) {
      return override();
    }

    // 7.55l.8b1: source-aware resolution.
    // Only override-driven profiles have meaningful persisted selection keys.
    // Default recommended/system benchmark truth does not have persisted
    // selection state — the empty override table must not be misread as
    // "0 selected star shifts".
    if (!_isOverrideDriven(sourceType)) {
      return _bridgeFallback();
    }

    // Canonical override path — compute from persisted baseline-selection state.
    final candidates =
        await BaselineManagerService.instance.getCandidateShifts();
    final selected = candidates.where((c) => c.isSelected).toList();
    return computeAnalytics(selected.length,
        selected.map((c) => c.cplh).toList());
  }

  /// Returns true when the source type represents manager-selected override truth.
  static bool _isOverrideDriven(String? sourceType) {
    return sourceType == 'manager_override' ||
        sourceType == 'cycle_manager_override';
  }

  // ── Analytics computation ───────────────────────────────────────────────

  static BaselineSelectionAnalytics computeAnalytics(
      int selectedCount, List<double> selectedCplhValues) {
    if (selectedCount < 2) {
      return BaselineSelectionAnalytics(
        selectedShiftCount: selectedCount,
        rangeQualityLabel: 'OPZ RANGE TOO NARROW',
        rangeQualityMessage:
            'Star shifts are bunched too tightly. Add a few more solid shifts before coaching to this range.',
      );
    }

    final rangeStart = selectedCplhValues.reduce(math.min);
    final rangeEnd = selectedCplhValues.reduce(math.max);
    final rangeWidth = rangeEnd - rangeStart;

    if (rangeWidth < 0.15) {
      return BaselineSelectionAnalytics(
        selectedShiftCount: selectedCount,
        rangeQualityLabel: 'OPZ RANGE TOO NARROW',
        rangeQualityMessage:
            'Star shifts are bunched too tightly. Add a few more solid shifts before coaching to this range.',
      );
    }

    if (rangeWidth > 1.25) {
      return BaselineSelectionAnalytics(
        selectedShiftCount: selectedCount,
        rangeQualityLabel: 'OPZ RANGE TOO WIDE',
        rangeQualityMessage:
            'Star shifts are spread too far apart. Tighten the set until the team is working to one standard.',
      );
    }

    return BaselineSelectionAnalytics(
      selectedShiftCount: selectedCount,
      rangeQualityLabel: 'GOOD OPZ RANGE',
      rangeQualityMessage:
          'Team looks busy without getting stretched. Service should hold here.',
    );
  }

  // ── Bridge fallback ──────────────────────────────────────────────────────

  BaselineSelectionAnalytics _bridgeFallback() {
    final v = BaselineData.baselineRangeValidation;
    return BaselineSelectionAnalytics(
      selectedShiftCount: BaselineData.selectedRecordCount,
      rangeQualityLabel: v.statusLabel,
      rangeQualityMessage: v.message,
    );
  }
}
