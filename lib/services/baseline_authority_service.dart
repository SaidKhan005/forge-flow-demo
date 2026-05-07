// ─── Baseline Authority Service (Layer 3) ─────────────────────────────────────
// Extracted from `lib/dev/demo_fixture_data.dart` per CODE_HEALTH L15:
//   "BaselineData (in lib/dev/) is mutated and read by canonical services"
//
// Owns the runtime BaselineData authority and the supporting read-model
// types that surfaces consume:
//   * `DaypartBaseline`   — one historical-shift record (daypart, cplh, splh, ppa, covers)
//   * `DaypartRange`      — per-daypart aggregation read-model
//   * `DaypartForecast`   — per-daypart cover forecast with computed model hours
//   * `OpzValidation`     — OPZ-band validation result
//   * `BaselineRangeValidation` — selection-range quality (Ch. 11)
//   * `BaselineRangeGraphModel` — CPLH range-graph read-model (Ch. 9–12)
//   * `BaselineRecommendationSignals` — projected `RecommendedBenchmarkSelection` signals
//   * `BaselineData`      — static authority surface (kept as static-class API to
//     preserve the existing call sites; mutation methods continue to fire the
//     `revision` ValueNotifier so existing reactive consumers are unchanged)
//
// CLAUDE.md "Service-Layer Split":
//   - `lib/services/` is runtime orchestration (Layer 3).
//   - `lib/dev/` is demo / dev-only seed data.
// Canonical services now import from this Layer 3 file. The fixture seam in
// `lib/dev/demo_fixture_data.dart` re-exports these types so demo-mode
// classes (`ShiftSnapshot`, `WeekToDate`, `ShiftMetrics`, etc.) still
// compose unchanged.
//
// Behaviour preserved bit-for-bit from the prior `lib/dev/demo_fixture_data.dart`
// implementation. Seed records stay in this file (they are the bootstrap
// truth callers depended on); demo-mode override seeding still lands through
// `applyHistoricalContext` / `applyManagerOverride` from
// `BaselineManagerService.primeBaselineContextForDate`.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/app_defaults.dart';
import 'labor_model.dart';

// ─── OPZ validation result ────────────────────────────────────────────────────

class OpzValidation {
  final double floorCPLH;
  final double ceilingCPLH;
  final double targetCPLH;
  final double headroomCPLH;
  final double usedPct;
  final String status;
  final String statusLabel;
  final String message;
  final bool showWarning;

  const OpzValidation({
    required this.floorCPLH,
    required this.ceilingCPLH,
    required this.targetCPLH,
    required this.headroomCPLH,
    required this.usedPct,
    required this.status,
    required this.statusLabel,
    required this.message,
    required this.showWarning,
  });
}

// ─── Baseline range validation (Ch. 11 — benchmark selection quality) ────────

class BaselineRangeValidation {
  final double rangeStartCPLH;
  final double rangeEndCPLH;
  final double rangeWidthCPLH;
  final int selectedCount;
  final String status;
  final String statusLabel;
  final String message;
  final bool showWarning;

  const BaselineRangeValidation({
    required this.rangeStartCPLH,
    required this.rangeEndCPLH,
    required this.rangeWidthCPLH,
    required this.selectedCount,
    required this.status,
    required this.statusLabel,
    required this.message,
    required this.showWarning,
  });
}

// ─── DaypartBaseline ─────────────────────────────────────────────────────────
// Each record is one historical shift tagged by daypart and manager-selection.
// Targets are derived from isSelected records; no manual constants needed.

class DaypartBaseline {
  final String daypart; // 'lunch' | 'dinner' | 'late_night'
  final double cplh;
  final double splh;
  final double ppa;
  final int covers;
  final bool isSelected; // manager-flagged high-performing shift

  const DaypartBaseline({
    required this.daypart,
    required this.cplh,
    required this.splh,
    required this.ppa,
    required this.covers,
    this.isSelected = false,
  });
}

// Full range analytics for one daypart — computed from DaypartBaseline records.
class DaypartRange {
  final String id; // 'lunch' | 'dinner' | 'late_night'
  final String label; // 'Lunch', 'Dinner', 'Late Night'
  final int sampleSize;
  final int selectedCount;
  final int avgCovers;
  final double avgCPLH;
  final double avgSPLH;
  final double avgPPA;
  final double minCPLH;
  final double maxCPLH;
  final double targetCPLH; // avg CPLH of selected records
  final double targetSPLH;
  final double targetPPA;
  final int targetCovers; // used by ScheduleDay.daypartBreakdown

  const DaypartRange({
    required this.id,
    required this.label,
    required this.sampleSize,
    required this.selectedCount,
    required this.avgCovers,
    required this.avgCPLH,
    required this.avgSPLH,
    required this.avgPPA,
    required this.minCPLH,
    required this.maxCPLH,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.targetCovers,
  });
}

// Per-daypart cover forecast with computed model hours — output of
// ScheduleDay.daypartBreakdown. Drives expandable rows in ScheduleBuilder.
class DaypartForecast {
  final String daypart;
  final String label;
  final int forecastCovers;

  const DaypartForecast({
    required this.daypart,
    required this.label,
    required this.forecastCovers,
  });

  int get requiredFohHours =>
      LaborModel.modelFohHours(forecastCovers, BaselineData.derivedTargetCPLH);

  int get requiredBohHours => LaborModel.modelBohHours(forecastCovers,
      BaselineData.derivedTargetPPA, BaselineData.derivedTargetSPLH);
}

class BaselineData {
  static const String daypartNote = '';

  static const String baselineTargetsNote =
      'These are your numbers. Not a benchmark. Not last year. Built from your best shifts.';

  // ── Runtime override storage ──────────────────────────────────────────────
  // Phase 5: manager can select star shifts from tracked history.
  // When set, all computed getters read from this list instead of _seedRecords.

  static List<DaypartBaseline>? _runtimeRecords;
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static List<DaypartBaseline> get records => _runtimeRecords ?? _seedRecords;

  static bool get hasManagerOverride => _runtimeRecords != null;

  static int get selectedRecordCount =>
      records.where((r) => r.isSelected).length;

  static void applyManagerOverride(List<DaypartBaseline> overrideRecords) {
    _runtimeRecords = List.unmodifiable(overrideRecords);
    revision.value++;
  }

  static void clearManagerOverride() {
    _runtimeRecords = null;
    revision.value++;
  }

  // ── Historical context storage (60-day full context) ─────────────────────
  // Separate from the active selected benchmark set so that context metrics
  // (total covers, weekly avg) remain stable regardless of override state.

  static List<DaypartBaseline>? _runtimeHistoricalContextRecords;

  static List<DaypartBaseline> get historicalContextRecords =>
      _runtimeHistoricalContextRecords ?? _seedRecords;

  static void applyHistoricalContext(List<DaypartBaseline> records) {
    _runtimeHistoricalContextRecords = List.unmodifiable(records);
    revision.value++;
  }

  static void clearHistoricalContext() {
    _runtimeHistoricalContextRecords = null;
    revision.value++;
  }

  // ── Recommendation honesty signals (7.55p.5h) ────────────────────────────
  //
  // Tiny compatibility seam so the Benchmark graph model can tell an honest
  // story when the app-owned recommendation service (7.55p.5g) concludes the
  // 60-day cohort is insufficient, weak, or has a union band too wide to
  // teach at cross-daypart scope. Populated by
  // `TargetCycleService._persistSelectionSummary` after a recommendation-
  // backed cycle write. Cleared for manager-override writes so the existing
  // `baselineRangeValidation`-driven copy remains unchanged there.
  //
  // The widget still reads through `rangeGraphModel`; this seam only lets
  // that model branch on recommendation-quality truth when present. Source
  // ownership: the recommendation service owns the tier; this bridge only
  // forwards what was already computed.

  static BaselineRecommendationSignals? _runtimeRecommendationSignals;

  /// Recommendation-path signals, or null when the graph should fall back to
  /// the existing `baselineRangeValidation` + selected-record derivation
  /// (manager override / tests / pre-cycle legacy).
  static BaselineRecommendationSignals? get recommendationSignals =>
      _runtimeRecommendationSignals;

  static void applyRecommendationSignals(BaselineRecommendationSignals s) {
    _runtimeRecommendationSignals = s;
    revision.value++;
  }

  static void clearRecommendationSignals() {
    _runtimeRecommendationSignals = null;
    revision.value++;
  }

  // ── 55 daypart records: 20 lunch · 25 dinner · 10 late_night ─────────────
  // isSelected = true on 14 records that represent high-performing shifts
  // (5 lunch + 6 dinner + 3 late_night).
  // derivedTargetCPLH = avg CPLH of selected ≈ 4.58  (MeridianConfig = 4.5)
  // worstDaysAvgCPLH  = avg CPLH of bottom quartile ≈ 3.52
  static const List<DaypartBaseline> _seedRecords = [
    // ── Lunch ──────────────────────────────────────────────────────────────
    DaypartBaseline(daypart: 'lunch', cplh: 4.4, splh: 178, ppa: 41, covers: 165, isSelected: true),
    DaypartBaseline(daypart: 'lunch', cplh: 4.5, splh: 180, ppa: 42, covers: 170, isSelected: true),
    DaypartBaseline(daypart: 'lunch', cplh: 4.6, splh: 181, ppa: 42, covers: 172, isSelected: true),
    DaypartBaseline(daypart: 'lunch', cplh: 4.7, splh: 182, ppa: 43, covers: 175, isSelected: true),
    DaypartBaseline(daypart: 'lunch', cplh: 4.8, splh: 183, ppa: 43, covers: 178, isSelected: true),
    DaypartBaseline(daypart: 'lunch', cplh: 4.3, splh: 177, ppa: 41, covers: 162),
    DaypartBaseline(daypart: 'lunch', cplh: 4.2, splh: 176, ppa: 41, covers: 160),
    DaypartBaseline(daypart: 'lunch', cplh: 4.1, splh: 175, ppa: 40, covers: 157),
    DaypartBaseline(daypart: 'lunch', cplh: 4.0, splh: 174, ppa: 40, covers: 155),
    DaypartBaseline(daypart: 'lunch', cplh: 3.9, splh: 173, ppa: 40, covers: 153),
    DaypartBaseline(daypart: 'lunch', cplh: 3.8, splh: 171, ppa: 39, covers: 150),
    DaypartBaseline(daypart: 'lunch', cplh: 3.7, splh: 170, ppa: 39, covers: 148),
    DaypartBaseline(daypart: 'lunch', cplh: 3.6, splh: 169, ppa: 38, covers: 145),
    DaypartBaseline(daypart: 'lunch', cplh: 3.5, splh: 167, ppa: 38, covers: 142),
    DaypartBaseline(daypart: 'lunch', cplh: 3.6, splh: 169, ppa: 38, covers: 144),
    DaypartBaseline(daypart: 'lunch', cplh: 3.7, splh: 170, ppa: 39, covers: 147),
    DaypartBaseline(daypart: 'lunch', cplh: 3.8, splh: 171, ppa: 39, covers: 149),
    DaypartBaseline(daypart: 'lunch', cplh: 4.0, splh: 174, ppa: 40, covers: 154),
    DaypartBaseline(daypart: 'lunch', cplh: 4.2, splh: 176, ppa: 41, covers: 159),
    DaypartBaseline(daypart: 'lunch', cplh: 3.9, splh: 172, ppa: 39, covers: 152),
    // ── Dinner ─────────────────────────────────────────────────────────────
    DaypartBaseline(daypart: 'dinner', cplh: 4.2, splh: 176, ppa: 43, covers: 225, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.3, splh: 177, ppa: 43, covers: 228, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.4, splh: 178, ppa: 44, covers: 232, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.5, splh: 180, ppa: 44, covers: 238, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.6, splh: 181, ppa: 45, covers: 242, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.7, splh: 182, ppa: 45, covers: 248, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.1, splh: 175, ppa: 43, covers: 220),
    DaypartBaseline(daypart: 'dinner', cplh: 4.0, splh: 174, ppa: 42, covers: 215),
    DaypartBaseline(daypart: 'dinner', cplh: 3.9, splh: 173, ppa: 42, covers: 210),
    DaypartBaseline(daypart: 'dinner', cplh: 3.8, splh: 172, ppa: 41, covers: 205),
    DaypartBaseline(daypart: 'dinner', cplh: 3.7, splh: 171, ppa: 41, covers: 200),
    DaypartBaseline(daypart: 'dinner', cplh: 3.6, splh: 170, ppa: 41, covers: 195),
    DaypartBaseline(daypart: 'dinner', cplh: 3.5, splh: 168, ppa: 40, covers: 190),
    DaypartBaseline(daypart: 'dinner', cplh: 3.4, splh: 167, ppa: 40, covers: 185),
    DaypartBaseline(daypart: 'dinner', cplh: 3.4, splh: 167, ppa: 40, covers: 183),
    DaypartBaseline(daypart: 'dinner', cplh: 3.5, splh: 168, ppa: 40, covers: 188),
    DaypartBaseline(daypart: 'dinner', cplh: 4.1, splh: 175, ppa: 43, covers: 218),
    DaypartBaseline(daypart: 'dinner', cplh: 3.9, splh: 173, ppa: 42, covers: 208),
    DaypartBaseline(daypart: 'dinner', cplh: 3.7, splh: 171, ppa: 41, covers: 200),
    DaypartBaseline(daypart: 'dinner', cplh: 4.0, splh: 174, ppa: 42, covers: 212),
    DaypartBaseline(daypart: 'dinner', cplh: 3.6, splh: 170, ppa: 41, covers: 193),
    DaypartBaseline(daypart: 'dinner', cplh: 3.8, splh: 172, ppa: 41, covers: 203),
    DaypartBaseline(daypart: 'dinner', cplh: 3.6, splh: 170, ppa: 41, covers: 193),
    DaypartBaseline(daypart: 'dinner', cplh: 3.5, splh: 168, ppa: 40, covers: 187),
    DaypartBaseline(daypart: 'dinner', cplh: 3.9, splh: 173, ppa: 42, covers: 207),
    // ── Late Night ──────────────────────────────────────────────────────────
    DaypartBaseline(daypart: 'late_night', cplh: 4.6, splh: 179, ppa: 36, covers: 85, isSelected: true),
    DaypartBaseline(daypart: 'late_night', cplh: 4.8, splh: 181, ppa: 37, covers: 90, isSelected: true),
    DaypartBaseline(daypart: 'late_night', cplh: 5.0, splh: 183, ppa: 37, covers: 92, isSelected: true),
    DaypartBaseline(daypart: 'late_night', cplh: 4.2, splh: 177, ppa: 35, covers: 80),
    DaypartBaseline(daypart: 'late_night', cplh: 4.0, splh: 175, ppa: 35, covers: 77),
    DaypartBaseline(daypart: 'late_night', cplh: 3.8, splh: 173, ppa: 34, covers: 74),
    DaypartBaseline(daypart: 'late_night', cplh: 3.6, splh: 171, ppa: 34, covers: 71),
    DaypartBaseline(daypart: 'late_night', cplh: 3.5, splh: 170, ppa: 34, covers: 69),
    DaypartBaseline(daypart: 'late_night', cplh: 3.4, splh: 169, ppa: 33, covers: 67),
    DaypartBaseline(daypart: 'late_night', cplh: 3.6, splh: 171, ppa: 34, covers: 71),
  ];

  // ── Computed aggregates ───────────────────────────────────────────────────

  static List<DaypartBaseline> get _selected =>
      records.where((r) => r.isSelected).toList();

  // OPZ source set — selected records when any exist, all records as
  // fallback when nothing is selected. The fallback ensures Shift always
  // has OPZ bounds even when the selection is empty. Note: this fallback
  // means OPZ bounds and baselineRangeValidation can use different source
  // sets — see phase_7_55m_5 audit doc "Source-Set Fallback Split."
  static List<DaypartBaseline> get _opzSourceRecords =>
      _selected.isNotEmpty ? _selected : records;

  /// Avg CPLH of manager-selected records (the high-performing shifts).
  static double get bestDaysAvgCPLH =>
      _selected.fold(0.0, (s, r) => s + r.cplh) / _selected.length;

  /// Avg CPLH of the bottom quartile of all records.
  static double get worstDaysAvgCPLH {
    final sorted = [...records]..sort((a, b) => a.cplh.compareTo(b.cplh));
    final bottom = sorted.take(records.length ~/ 4).toList();
    return bottom.fold(0.0, (s, r) => s + r.cplh) / bottom.length;
  }

  static int get totalCoversTracked =>
      records.fold(0, (s, r) => s + r.covers);

  static int get weeklyAvgCovers => MeridianConfig.weeklyCovers;

  // ── Historical context metrics (Ch. 9 — always 60-day, never overridden) ─

  static int get historicalTotalCoversTracked =>
      historicalContextRecords.fold(0, (s, r) => s + r.covers);

  static int get historicalWeeklyAvgCovers =>
      (historicalTotalCoversTracked / (60 / 7)).round();

  // ── Derived targets — from selected records, replace hardcoded config ─────

  static double get derivedTargetCPLH =>
      _selected.fold(0.0, (s, r) => s + r.cplh) / _selected.length;

  static double get derivedTargetSPLH =>
      _selected.fold(0.0, (s, r) => s + r.splh) / _selected.length;

  static double get derivedTargetPPA =>
      _selected.fold(0.0, (s, r) => s + r.ppa) / _selected.length;

  static double get derivedTheoreticalLaborPct => LaborModel.theoreticalLaborPct(
      derivedTargetCPLH, derivedTargetSPLH, derivedTargetPPA,
      MeridianConfig.fohWage, MeridianConfig.bohWage);

  // FOH theoretical labor % = fohWage / (targetCPLH × targetPPA) × 100
  static double get derivedFohTheoreticalLaborPct =>
      (derivedTargetCPLH == 0 || derivedTargetPPA == 0)
          ? 0
          : MeridianConfig.fohWage / (derivedTargetCPLH * derivedTargetPPA) * 100;

  // BOH theoretical labor % = bohWage / targetSPLH × 100
  static double get derivedBohTheoreticalLaborPct =>
      derivedTargetSPLH == 0
          ? 0
          : MeridianConfig.bohWage / derivedTargetSPLH * 100;

  // ── OPZ definition (Jim Taylor Ch. 11) ───────────────────────────────────
  // OPZ floor and ceiling = min/max CPLH of the selected benchmark or
  // star-shift records. This is the **OPZ definition** — the band within
  // which current CPLH is considered healthy.
  //
  // This is a different concept from:
  // - **range quality** (baselineRangeValidation) — whether the selection
  //   spread is too narrow, appropriate, or too wide for coaching
  // - **zone status** (opzStatusForCplh) — where live CPLH sits relative
  //   to these bounds
  //
  // See phase_7_55m_5 audit doc for the full three-concept separation.

  static double get opzFloorCPLH =>
      _opzSourceRecords.map((r) => r.cplh).reduce(math.min);
  static double get opzCeilingCPLH =>
      _opzSourceRecords.map((r) => r.cplh).reduce(math.max);

  /// Headroom = how far below the ceiling the target sits.
  static double get opzHeadroomCPLH => opzCeilingCPLH - derivedTargetCPLH;

  /// Where the target sits in the OPZ band, expressed as 0–100%.
  static double get opzUsedPct {
    final band = opzCeilingCPLH - opzFloorCPLH;
    if (band <= 0) return 0;
    return ((derivedTargetCPLH - opzFloorCPLH) / band * 100).clamp(0, 100);
  }

  /// Full OPZ validation result — status, label, message, and warning flag.
  static OpzValidation get opzValidation {
    final target = derivedTargetCPLH;
    final floor = opzFloorCPLH;
    final ceiling = opzCeilingCPLH;
    final headroom = opzHeadroomCPLH;
    final used = opzUsedPct;

    String status;
    String statusLabel;
    String message;
    bool showWarning;

    if (target > ceiling) {
      status = 'above_ceiling';
      statusLabel = 'ABOVE CEILING';
      message = 'Target is above the OPZ ceiling. Chapter 11 treats this as an unstable standard, not a teachable baseline.';
      showWarning = true;
    } else if (target >= ceiling - 0.30) {
      status = 'near_ceiling';
      statusLabel = 'NEAR CEILING';
      message = 'Target is too close to the OPZ ceiling. Chapter 11 calls for sustainable productivity with usable headroom, not ceiling chasing.';
      showWarning = true;
    } else if (target < floor) {
      status = 'below_floor';
      statusLabel = 'BELOW FLOOR';
      message = 'Target sits below the OPZ floor. Review whether the baseline is too soft to teach the operation.';
      showWarning = true;
    } else {
      status = 'in_zone';
      statusLabel = 'IN OPZ';
      message = 'Target sits inside the OPZ with usable headroom. This is a teachable standard.';
      showWarning = false;
    }

    return OpzValidation(
      floorCPLH: floor,
      ceilingCPLH: ceiling,
      targetCPLH: target,
      headroomCPLH: headroom,
      usedPct: used,
      status: status,
      statusLabel: statusLabel,
      message: message,
      showWarning: showWarning,
    );
  }

  /// OPZ zone status for a live CPLH reading: 'below' | 'in' | 'above'.
  /// This is about **current position** within the OPZ band — independent
  /// of whether the benchmark selection quality is narrow, good, or wide.
  static String opzStatusForCplh(double currentCplh) {
    if (currentCplh < opzFloorCPLH) return 'below';
    if (currentCplh > opzCeilingCPLH) return 'above';
    return 'in';
  }

  /// Human-readable OPZ zone label.
  static String opzStatusLabelForCplh(double currentCplh) {
    switch (opzStatusForCplh(currentCplh)) {
      case 'below': return 'BELOW OPZ';
      case 'above': return 'ABOVE OPZ';
      default:      return 'IN OPZ';
    }
  }

  /// One-line teaching sub-label for the current CPLH zone.
  static String opzSubLabelForCplh(double currentCplh) {
    switch (opzStatusForCplh(currentCplh)) {
      case 'below':
        return 'Productivity is below the OPZ floor. The shift is underproducing the standard.';
      case 'above':
        return 'Productivity is above the OPZ ceiling. Service risk rises here.';
      default:
        return 'Productivity is inside the OPZ. Protect guest attention and hold the pattern.';
    }
  }

  // ── Benchmark range-quality assessment (Ch. 11) ──────────────────────────
  // Evaluates whether the selected benchmark CPLH spread is usable for
  // coaching. This is about **selection quality**, not live CPLH position.
  // Thresholds must stay aligned with BaselineSelectionAnalyticsService.
  // See phase_7_55m_5 audit doc for the full three-concept separation.

  static BaselineRangeValidation get baselineRangeValidation {
    final selected = records.where((r) => r.isSelected).toList();
    if (selected.length < 2) {
      return const BaselineRangeValidation(
        rangeStartCPLH: 0,
        rangeEndCPLH: 0,
        rangeWidthCPLH: 0,
        selectedCount: 0,
        status: 'too_narrow',
        statusLabel: 'OPZ RANGE TOO NARROW',
        message:
            'Star shifts are bunched too tightly. Add a few more solid shifts before coaching to this range.',
        showWarning: true,
      );
    }

    final rangeStart = selected.map((r) => r.cplh).reduce(math.min);
    final rangeEnd = selected.map((r) => r.cplh).reduce(math.max);
    final rangeWidth = rangeEnd - rangeStart;

    String status;
    String statusLabel;
    String message;
    bool showWarning;

    if (rangeWidth < 0.15) {
      status = 'too_narrow';
      statusLabel = 'OPZ RANGE TOO NARROW';
      message =
          'Star shifts are bunched too tightly. Add a few more solid shifts before coaching to this range.';
      showWarning = true;
    } else if (rangeWidth > 1.25) {
      status = 'too_wide';
      statusLabel = 'OPZ RANGE TOO WIDE';
      message =
          'Star shifts are spread too far apart. Tighten the set until the team is working to one standard.';
      showWarning = true;
    } else {
      status = 'healthy';
      statusLabel = 'GOOD OPZ RANGE';
      message =
          'Team looks busy without getting stretched. Service should hold here.';
      showWarning = false;
    }

    return BaselineRangeValidation(
      rangeStartCPLH: rangeStart,
      rangeEndCPLH: rangeEnd,
      rangeWidthCPLH: rangeWidth,
      selectedCount: selected.length,
      status: status,
      statusLabel: statusLabel,
      message: message,
      showWarning: showWarning,
    );
  }

  // ── DaypartRange list — computed from records ─────────────────────────────

  static List<DaypartRange> get daypartRanges =>
      ['lunch', 'dinner', 'late_night'].map(_rangeFor).toList();

  static DaypartRange _rangeFor(String id) {
    final all      = records.where((r) => r.daypart == id).toList();
    final selected = all.where((r) => r.isSelected).toList();
    final n        = all.length;
    if (n == 0) return _emptyRange(id);
    final avgCovers = all.fold(0, (s, r) => s + r.covers) ~/ n;
    final avgCPLH   = all.fold(0.0, (s, r) => s + r.cplh) / n;
    final avgSPLH   = all.fold(0.0, (s, r) => s + r.splh) / n;
    final avgPPA    = all.fold(0.0, (s, r) => s + r.ppa) / n;
    final minCPLH   = all.map((r) => r.cplh).reduce((a, b) => a < b ? a : b);
    final maxCPLH   = all.map((r) => r.cplh).reduce((a, b) => a > b ? a : b);
    final sel       = selected.isEmpty ? all : selected;
    return DaypartRange(
      id: id,
      label: _labelFor(id),
      sampleSize: n,
      selectedCount: selected.length,
      avgCovers: avgCovers,
      avgCPLH: avgCPLH,
      avgSPLH: avgSPLH,
      avgPPA: avgPPA,
      minCPLH: minCPLH,
      maxCPLH: maxCPLH,
      targetCPLH: sel.fold(0.0, (s, r) => s + r.cplh) / sel.length,
      targetSPLH: sel.fold(0.0, (s, r) => s + r.splh) / sel.length,
      targetPPA:  sel.fold(0.0, (s, r) => s + r.ppa) / sel.length,
      targetCovers: sel.fold(0, (s, r) => s + r.covers) ~/ sel.length,
    );
  }

  static String _labelFor(String id) {
    switch (id) {
      case 'lunch':      return 'Lunch';
      case 'dinner':     return 'Dinner';
      case 'late_night': return 'Late Night';
      default:           return id;
    }
  }

  static DaypartRange _emptyRange(String id) => DaypartRange(
        id: id,
        label: _labelFor(id),
        sampleSize: 0,
        selectedCount: 0,
        avgCovers: 0,
        avgCPLH: 0,
        avgSPLH: 0,
        avgPPA: 0,
        minCPLH: 0,
        maxCPLH: 0,
        targetCPLH: MeridianConfig.targetCPLH,
        targetSPLH: MeridianConfig.targetSPLH,
        targetPPA: MeridianConfig.targetPPA,
        targetCovers: 0,
      );

  // ── Graph model (Jim Taylor Ch. 9–12) ─────────────────────────────────────
  // The graph shows two layered ranges:
  //   Outer line  = full 60-day historical CPLH range (Ch. 9 lived range)
  //   Inner box   = selected benchmark/star-shift CPLH range (Ch. 11–12)
  // Display endpoints are always the historical context so the 60-day truth
  // stays visible. Position normalization is against the historical scale.
  //
  // If the inner box fills most of the bar, it means the selected shifts
  // genuinely span most of the historical range — this is true data, not a
  // distortion. See phase_7_55m_5 audit doc.

  static BaselineRangeGraphModel get rangeGraphModel {
    // A. Historical context — always the outer display range
    final histCplh = historicalContextRecords.map((r) => r.cplh).toList();
    final histMin = histCplh.reduce(math.min);
    final histMax = histCplh.reduce(math.max);

    // B. Inner active range + target.
    //
    // 7.55p.5h-review-fix: when recommendation signals are present and
    // no manager override is active, the inner band + target come from
    // the persisted cycle/profile (the same source the honest copy is
    // talking about) instead of `BaselineData.records.where(isSelected)`.
    // Otherwise the graph could still draw a confident seed-selected
    // band while the copy said "Config Default placeholder".
    //
    // Manager override keeps the star-shift / seed-selected geometry
    // unchanged so its existing behavior is preserved bit-for-bit.
    final signals = _runtimeRecommendationSignals;
    final useSignalGeometry = signals != null && !hasManagerOverride;

    double activeMin;
    double activeMax;
    double target;
    if (useSignalGeometry) {
      activeMin = signals.rangeFloorCPLH;
      activeMax = signals.rangeCeilingCPLH;
      target = signals.targetCPLH;
    } else {
      final selected = records.where((r) => r.isSelected).toList();
      activeMin = selected.map((r) => r.cplh).reduce(math.min);
      activeMax = selected.map((r) => r.cplh).reduce(math.max);
      target = derivedTargetCPLH;
    }

    // C. Display range is always historical
    final displayMin = histMin;
    final displayMax = histMax;

    // D. Inner range label depends on override state
    final rangeLabel =
        hasManagerOverride ? 'STAR SHIFT RANGE' : 'BENCHMARK RANGE';

    // E. Position normalization — always against the historical scale
    var scaleMin = displayMin;
    var scaleMax = displayMax;
    if (scaleMax <= scaleMin) {
      scaleMin = math.max(0.0, target - 1.0);
      scaleMax = target + 1.0;
    }
    final scaleRange = scaleMax - scaleMin;

    final activeStartPos = scaleRange > 0
        ? ((activeMin - scaleMin) / scaleRange).clamp(0.0, 1.0)
        : 0.0;
    final activeEndPos = scaleRange > 0
        ? ((activeMax - scaleMin) / scaleRange).clamp(0.0, 1.0)
        : 1.0;
    final targetPos = scaleRange > 0
        ? ((target - scaleMin) / scaleRange).clamp(0.0, 1.0)
        : 0.5;

    // F. Honest fallback state for the recommendation path (7.55p.5h).
    //
    // Three-way branch:
    //   - Manager override → existing `baselineRangeValidation` drives the
    //     badge/copy; the graph shows selected star-shift truth unchanged.
    //   - Recommendation signals present → quality/width come from the
    //     recommendation service; the graph shows an honest fallback when
    //     the cohort is insufficient or weak/wide.
    //   - Neither (tests / legacy) → current `baselineRangeValidation`
    //     behavior preserved bit-for-bit.
    final honesty = _resolveGraphHonesty();

    return BaselineRangeGraphModel(
      historicalRangeStartCPLH: histMin,
      historicalRangeEndCPLH:   histMax,
      displayRangeStartCPLH:   displayMin,
      displayRangeEndCPLH:     displayMax,
      activeRangeStartCPLH:    activeMin,
      activeRangeEndCPLH:      activeMax,
      targetCPLH:              target,
      displayRangeStartPosition: 0.0,
      displayRangeEndPosition:   1.0,
      activeRangeStartPosition:  activeStartPos,
      activeRangeEndPosition:    activeEndPos,
      targetPosition:            targetPos,
      title:                   'CPLH RANGE & TARGET',
      startLabel:              'LOWEST CPLH LAST 60 DAYS',
      endLabel:                'HIGHEST CPLH LAST 60 DAYS',
      rangeLabel:              rangeLabel,
      recommendedExplanation:  honesty.explanation,
      overrideLabel:           'CHOOSE STAR SHIFTS',
      qualityTier:             honesty.tier,
      isDegenerate:            honesty.isDegenerate,
      degenerateFallbackMessage: honesty.fallbackMessage,
      statusBadgeLabel:        honesty.badgeLabel,
    );
  }

  /// Resolves the Benchmark graph's honest explainer state.
  ///
  /// Manager-override branch always defers to the existing
  /// `baselineRangeValidation` derivation so manager-selected behavior is
  /// bit-for-bit preserved.
  static _BaselineGraphHonesty _resolveGraphHonesty() {
    // 1. Manager override → existing derivation wins.
    if (hasManagerOverride) {
      final v = baselineRangeValidation;
      return _BaselineGraphHonesty(
        tier: v.status,
        isDegenerate: v.showWarning,
        badgeLabel: v.statusLabel,
        explanation: v.message,
        fallbackMessage: null,
      );
    }

    // 2. Recommendation signals drive honest recommendation-path copy.
    final signals = _runtimeRecommendationSignals;
    if (signals != null) {
      switch (signals.overallQuality) {
        case 'insufficient':
          return const _BaselineGraphHonesty(
            tier: 'insufficient',
            isDegenerate: true,
            badgeLabel: 'RANGE UNCONFIRMED',
            explanation:
                'Not enough recent shifts yet to set a reliable '
                'benchmark range.',
            fallbackMessage:
                'For now this is a placeholder range until more shift '
                'history builds.',
          );
        case 'weak':
          if (signals.unionBandWidth > _unionBandWideThresholdCPLH) {
            return const _BaselineGraphHonesty(
              tier: 'weak',
              isDegenerate: true,
              badgeLabel: 'RANGE TOO WIDE TO TEACH',
              explanation:
                  'Lunch, dinner, and late night are behaving '
                  'differently. This needs daypart-specific coaching.',
              fallbackMessage:
                  'Use this as a broad guide for now, not one standard '
                  'for every period.',
            );
          }
          return const _BaselineGraphHonesty(
            tier: 'weak',
            isDegenerate: true,
            badgeLabel: 'RANGE UNCERTAIN',
            explanation:
                'We do not have a clean operating range yet. Let more '
                'shifts close before coaching to this.',
            fallbackMessage:
                'As more shifts close, the benchmark will settle into a '
                'clearer working range.',
          );
        case 'adequate':
        case 'strong':
        default:
          return const _BaselineGraphHonesty(
            tier: 'good',
            isDegenerate: false,
            badgeLabel: 'GOOD OPZ RANGE',
            explanation:
                'Team looks busy without getting stretched. Service should hold here.',
            fallbackMessage: null,
          );
      }
    }

    // 3. No override + no signals → current behavior (tests / legacy).
    final v = baselineRangeValidation;
    return _BaselineGraphHonesty(
      tier: v.status,
      isDegenerate: v.showWarning,
      badgeLabel: v.statusLabel,
      explanation: v.message,
      fallbackMessage: null,
    );
  }

  /// Matches the 7.55p.5f / 7.55p.5g "union full-width adequate cap" so
  /// the graph cue stays consistent with the recommendation-service threshold
  /// (see `RecommendedSelectionConfig.unionAdequateCap` and the per-daypart
  /// TOO WIDE threshold from `baselineRangeValidation`).
  static const double _unionBandWideThresholdCPLH = 1.25;
}

/// Internal honest-explainer state for the Benchmark graph (7.55p.5h).
class _BaselineGraphHonesty {
  final String tier;
  final bool isDegenerate;
  final String badgeLabel;
  final String explanation;
  final String? fallbackMessage;
  const _BaselineGraphHonesty({
    required this.tier,
    required this.isDegenerate,
    required this.badgeLabel,
    required this.explanation,
    required this.fallbackMessage,
  });
}

/// Recommendation-quality signals projected from the persisted
/// `TargetCycle` + `RecommendedBenchmarkSelection` output into
/// `BaselineData` so the Benchmark graph can both (a) branch its copy
/// on real cohort-quality truth and (b) draw geometry from the same
/// source of truth as the copy (7.55p.5h + 7.55p.5h-review-fix).
///
/// Owned by `TargetCycleService` — populated inline during
/// `_persistSelectionSummary` on cycle write AND rehydrated during
/// `hydrateBenchmarkHonestyFromActiveCycle` at bootstrap so honesty
/// survives fresh launches. The graph only consumes.
class BaselineRecommendationSignals {
  /// Cycle source label, e.g. `cycle_recommended`,
  /// `cycle_recommended_insufficient`, `cycle_manager_override`.
  final String sourceType;

  /// `'strong' | 'adequate' | 'weak' | 'insufficient'`.
  final String overallQuality;

  /// Full-width cross-daypart union band (max − min) of the selected
  /// cohort's CPLH values.
  final double unionBandWidth;

  /// Total shifts in the selected cohort across all dayparts.
  final int selectedShiftCount;

  /// Floor of the inner range the graph should draw. Sourced from the
  /// persisted cycle's `opzFloorCPLH` — matches the recommendation for
  /// recommended writes and `MeridianConfig.opzFloorCPLH` for
  /// insufficient fallback writes. The graph uses this instead of
  /// `BaselineData.records.where(isSelected)` so the drawn range
  /// matches the claim the copy makes.
  final double rangeFloorCPLH;

  /// Ceiling of the inner range the graph should draw.
  final double rangeCeilingCPLH;

  /// Target tick position the graph should draw. Sourced from the
  /// persisted cycle's `targetCPLH` — matches recommendation or
  /// Config Default as appropriate.
  final double targetCPLH;

  const BaselineRecommendationSignals({
    required this.sourceType,
    required this.overallQuality,
    required this.unionBandWidth,
    required this.selectedShiftCount,
    required this.rangeFloorCPLH,
    required this.rangeCeilingCPLH,
    required this.targetCPLH,
  });
}

// ─── Baseline range graph model (Jim Taylor Ch. 9–12) ────────────────────────
// Immutable read-model for the CPLH range graph.
// historicalRange   = full 60-day min/max CPLH (Ch. 9 lived range).
// activeRange       = selected star-shift min/max CPLH (Ch. 11–12 benchmark).
// displayRange      = what the graph endpoints show: historical or star-shift.
// target            = recommended target inside the zone, built from benchmark shifts (Ch. 12).
// Positions are normalized 0.0–1.0 within [displayRangeStart, displayRangeEnd].

class BaselineRangeGraphModel {
  final double historicalRangeStartCPLH;
  final double historicalRangeEndCPLH;
  final double displayRangeStartCPLH;
  final double displayRangeEndCPLH;
  final double activeRangeStartCPLH;
  final double activeRangeEndCPLH;
  final double targetCPLH;
  final double displayRangeStartPosition;
  final double displayRangeEndPosition;
  final double activeRangeStartPosition;
  final double activeRangeEndPosition;
  final double targetPosition;
  final String title;
  final String startLabel;
  final String endLabel;
  final String rangeLabel;
  final String recommendedExplanation;
  final String overrideLabel;

  // ── 7.55p.5h honesty fields ─────────────────────────────────────────────
  // Drive the Benchmark graph's degenerate-state UI: dimmed inner box,
  // honest badge label, and an explicit fallback message that tells the
  // user the range is not teachable yet rather than pretending it is.
  //
  // Source of truth:
  //   - Manager override → `baselineRangeValidation`
  //   - Recommendation signals present → `RecommendedBenchmarkSelection`
  //   - Neither → existing `baselineRangeValidation`

  /// Normalized quality tier:
  /// `'strong' | 'adequate' | 'weak' | 'insufficient' | 'good' |
  /// 'too_narrow' | 'too_wide' | 'healthy'`.
  final String qualityTier;

  /// When true, the graph should NOT teach precision. UI should mute the
  /// inner highlight and lead with `degenerateFallbackMessage`.
  final bool isDegenerate;

  /// Optional secondary line rendered below the primary explainer when
  /// the graph is in a degenerate state. Null when no fallback copy is
  /// needed.
  final String? degenerateFallbackMessage;

  /// Label to show in the status badge. Replaces the legacy hard-coded
  /// mapping from `baselineRangeValidation.statusLabel` when recommendation
  /// signals are active.
  final String statusBadgeLabel;

  const BaselineRangeGraphModel({
    required this.historicalRangeStartCPLH,
    required this.historicalRangeEndCPLH,
    required this.displayRangeStartCPLH,
    required this.displayRangeEndCPLH,
    required this.activeRangeStartCPLH,
    required this.activeRangeEndCPLH,
    required this.targetCPLH,
    required this.displayRangeStartPosition,
    required this.displayRangeEndPosition,
    required this.activeRangeStartPosition,
    required this.activeRangeEndPosition,
    required this.targetPosition,
    required this.title,
    required this.startLabel,
    required this.endLabel,
    required this.rangeLabel,
    required this.recommendedExplanation,
    required this.overrideLabel,
    required this.qualityTier,
    required this.isDegenerate,
    required this.degenerateFallbackMessage,
    required this.statusBadgeLabel,
  });
}
