// Forge & Flow — demo sample data (kDemoMode only).
//
// 7.57.1b carved this module out of the historical fixture surface so
// production code can stop importing a path that looks like runtime
// truth. Values, labels, list orders, and selected flags are preserved
// exactly — this is a structural move only.
//
// CODE_HEALTH L15 — `BaselineData` and its supporting read-model types
// (`DaypartBaseline`, `DaypartRange`, `DaypartForecast`, `OpzValidation`,
// `BaselineRangeValidation`, `BaselineRangeGraphModel`,
// `BaselineRecommendationSignals`) moved to
// `lib/services/baseline_authority_service.dart` (Layer 3). They are
// re-exported here so this file stays the single demo-mode entry point
// for fixture-shaped tests and demo-mode UI; canonical services no
// longer import `lib/dev/`.
//
// Holds (post-L15):
//   * ISO week-id helper `getWeekId`
//   * `ShiftSnapshot`, `WeekToDate`, `WeeklyVariance`, `ShiftMetrics`
//   * `ScheduleDay`, `ScheduleForecastDefaults`
//
// Re-exported from `lib/services/baseline_authority_service.dart`:
//   * `OpzValidation`, `BaselineRangeValidation`
//   * `DaypartBaseline`, `DaypartRange`, `DaypartForecast`
//   * `BaselineData`, `BaselineRecommendationSignals`,
//     `BaselineRangeGraphModel`
//
// Runtime defaults / lever metadata / pure value types live in
// `lib/domain/constants/app_defaults.dart` (extracted in 7.57.1a).

import 'package:flutter/foundation.dart';

import '../domain/constants/app_defaults.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../services/baseline_authority_service.dart';
import '../services/labor_model.dart';

export '../services/baseline_authority_service.dart'
    show
        BaselineData,
        BaselineRangeGraphModel,
        BaselineRangeValidation,
        BaselineRecommendationSignals,
        DaypartBaseline,
        DaypartForecast,
        DaypartRange,
        OpzValidation;

// ─── ISO week-id helper ───────────────────────────────────────────────────────
// Returns "YYYY-Www" for the Monday-anchored ISO week containing [date].

String getWeekId(DateTime date) {
  final monday = date.subtract(Duration(days: date.weekday - 1));
  final startOfYear = DateTime(monday.year, 1, 1);
  final firstMonday = startOfYear.weekday <= 4
      ? startOfYear.subtract(Duration(days: startOfYear.weekday - 1))
      : startOfYear.add(Duration(days: 8 - startOfYear.weekday));
  final weekNumber =
      ((monday.difference(firstMonday).inDays) / 7).floor() + 1;
  return '${monday.year}-W${weekNumber.toString().padLeft(2, '0')}';
}

// ─── Demo shift snapshot — Friday dinner, 7:42 PM (shift-level) ──────────────
// Friday dinner shift — forecast aligned with Schedule demand resolver.
// Schedule: weeklyCovers ≈ 1,119 → Friday = round(220 × 1119/1200) = 205
//           Friday dinner = round(205 × 0.40) = 82 covers
// Actuals: 52 covers (63% of forecast — covers light narrative).

class ShiftSnapshot {
  static const String daypart = 'Dinner';
  static const String day = 'Friday';
  static const String time = '7:42 PM';
  static const String serviceElapsed = '3h 14m into service';

  // Shift-level actuals
  static const int actualCovers = 52;          // running count — covers light
  static const int shiftForecastCovers = 82;   // Friday dinner from demand resolver
  static const int scheduledFohHours = 20;     // model+2 (overschedule narrative)
  static const int scheduledBohHours = 21;     // model+2 (overschedule narrative)

  // Computed shift metrics
  static const double actualPPA = 41.20;       // sales ÷ covers (kept)
  static const double actualCPLH = 2.6;        // 52 ÷ 20
  static const double actualSPLH = 102.0;      // (52 × 41.20) ÷ 21 ≈ 102.0
  static const double blendedWage = 18.74;

  // Model needed for 82 forecast covers
  static const int modelFohHours = 18;   // round(82 / 4.578)
  static const int modelBohHours = 19;   // round(82 × 41.79 / 180.07)

  // OPZ status — 'below' | 'in' | 'above'
  static const String opzStatus = 'below';
  static const String opzSubLabel = 'Covers are light. Watch the door.';

  // ── Runtime active lever (Prompt 7.11; 7.58.4 axis-set parity) ──────────
  // Uses the same lever-detection model as WTD/History to determine
  // which metric is the primary driver of this shift's variance.
  //
  // 7.58.4 / F-3: passes the full axis set (covers + ppa + cplh + splh +
  // wages + hours-flex) so this fixture row's lever mirrors what
  // `ShiftFactBuilder` and `ShiftDashboardReadModel.buildWholeDay` would
  // emit for the same inputs. Demo blended wages equal target — the wage
  // family stays quiet — but the call shape is now pinned to the
  // producer-side contract.
  static String get primaryLeverId => LaborModel.determineLever(
        actualCovers: actualCovers,
        forecastCovers: shiftForecastCovers,
        avgCPLH: actualCPLH,
        avgPPA: actualPPA,
        targetCPLH: BaselineData.derivedTargetCPLH,
        targetPPA: BaselineData.derivedTargetPPA,
        avgSPLH: actualSPLH,
        targetSPLH: BaselineData.derivedTargetSPLH,
        avgFohBlendedWage: MeridianConfig.fohWage,
        targetFohWage: MeridianConfig.fohWage,
        avgBohBlendedWage: MeridianConfig.bohWage,
        targetBohWage: MeridianConfig.bohWage,
        scheduledFohHours: scheduledFohHours,
        modelFohHours: modelFohHours,
        scheduledBohHours: scheduledBohHours,
        modelBohHours: modelBohHours,
      );

  // 7.61.3 / F-3: resolve through `LeverCards.lookup` per R-CONS-1 +
  // R-STOR-7 instead of the banned `firstWhere(orElse: coversDown)`
  // fall-through. `primaryLeverId` is sourced from
  // `LaborModel.determineLever`, which always returns a catalog id
  // (R-PROD-1), so the StateError branch is defense-in-depth — it
  // loudly surfaces a producer regression instead of silently
  // materializing a real `coversDown` card the engine never picked.
  // The resolver is split out as `resolveLeverCard` so the contract
  // test can pin the unknown-id failure boundary directly (the
  // deterministic seed never mints an unknown id, so calling the
  // getter alone cannot exercise the StateError branch).
  static LeverCardData get primaryLeverCard =>
      resolveLeverCard(primaryLeverId);

  /// Test-visible resolver. Returns the catalog card for [id], or
  /// throws `StateError` (naming the offending id) when [id] is the
  /// `on_model` sentinel, an unknown id, or empty. Mirrors the
  /// renderer-side R-CONS-3 contract on
  /// `lib/models/shift_dashboard_read_model.dart` while keeping the
  /// failure mode loud for dev fixtures rather than asserting via `!`.
  @visibleForTesting
  static LeverCardData resolveLeverCard(String id) =>
      LeverCards.lookup(id) ??
      (throw StateError(
        'demo fixture primaryLeverId not in catalog: $id',
      ));
}

// ─── Week-to-date totals (9 closed shifts Mon–Fri lunch) ─────────────────────

class WeekToDate {
  static const String currentWeekId = '2026-W13';
  static const String weekLabel = 'Week of Mar 24';

  // ── 9 closed shifts: Mon L → Fri L ────────────────────────────────────────
  // covers: 154+196+158+192+162+200+165+203+150 = 1,580
  // FOH:     36+ 48+ 36+ 47+ 36+ 47+ 36+ 47+ 29 = 362
  // BOH:     37+ 50+ 37+ 48+ 37+ 49+ 37+ 48+ 30 = 373
  // sales ≈ $67,180 · avgCPLH = 4.36 · avgSPLH = 180.1

  static const int totalCovers = 1580;
  static const int forecastCovers = MeridianConfig.weeklyCovers;
  static const int coversVariance = totalCovers - forecastCovers;

  static const int totalFohHours = 362;
  static const int totalBohHours = 373;

  // ── Schedule context ──────────────────────────────────────────────────────
  static const int shiftsCompleted = 9;
  static const int shiftsTotal = 14;
  static const String lastClosedDay  = 'Friday';  // last closed shift day (full name)
  static const int    closedDayNumber = 5;         // Mon=1, Tue=2, …, Fri=5, Sat=6, Sun=7

  // ── Jim Taylor model targets for actual WTD volume ────────────────────────
  // Covers: sum of shift forecasts for the 9 closed shifts
  //   5 lunches × 180 + 4 dinners × 220 = 900 + 880 = 1,780
  static const int wtdForecastCovers = 1780;

  // Model FOH hours = actual covers ÷ target CPLH = 1,580 ÷ 4.58 = 345.0 → 345
  static const int modelFohHoursWtd = 345;

  // Model BOH hours = actual sales ÷ target SPLH = $67,180 ÷ $180.07 = 373.1 → 373
  static const int modelBohHoursWtd = 373;

  // ── Rate metrics (WTD actuals from 9 closed shifts) ───────────────────────
  static const double avgPPA          = 42.52;  // $67,180 ÷ 1,580
  static const double avgCPLH         =  4.36;  // 1,580 ÷ 362
  static const double avgSPLH         = 180.1;  // $67,180 ÷ 373
  static const double avgBlendedWage  = 18.96;  // (362×16.50 + 373×21.35) ÷ 735
  // Demo blended wages — same as target (no wage lever fires for demo WTD)
  static const double blendedFohWage  = MeridianConfig.fohWage;
  static const double blendedBohWage  = MeridianConfig.bohWage;

  // Theoretical blended wage = weighted avg at model hours (345 FOH, 373 BOH)
  static const double theoreticalBlendedWage = 19.02; // (345×16.50 + 373×21.35) / 718

  // ── Labor % (WTD) ─────────────────────────────────────────────────────────
  static const int theoreticalFohHours = MeridianConfig.requiredFohHours; // full-week model
  static const int theoreticalBohHours = MeridianConfig.requiredBohHours; // full-week model
  // WTD variances use model hours for actual volume (Taylor Ch. 10)
  static const int fohHoursVariance = totalFohHours - modelFohHoursWtd; // 362 − 345 = +17
  static const int bohHoursVariance = totalBohHours - modelBohHoursWtd; // 373 − 373 = 0

  static const double theoreticalFohLaborPct = MeridianConfig.fohTheoreticalLaborPct;
  static const double actualFohLaborPct = 9.7;
  static const double fohLaborPctVariance = actualFohLaborPct - theoreticalFohLaborPct; // +1.0

  static const double theoreticalBohLaborPct = MeridianConfig.bohTheoreticalLaborPct;
  static const double actualBohLaborPct = 12.9;
  static const double bohLaborPctVariance = actualBohLaborPct - theoreticalBohLaborPct; // +1.0

  static const double theoreticalTotalLaborPct = MeridianConfig.totalTheoreticalLaborPct;
  static const double actualTotalLaborPct = 22.6;
  static const double totalLaborPctVariance =
      actualTotalLaborPct - theoreticalTotalLaborPct; // +2.0

  // ── Dollar impact ─────────────────────────────────────────────────────────
  static const double dollarGapWeekly    = 958.0;
  static const double dollarGapAnnualized = 49816.0;
  static const String annualizedContext  = 'At \$3M annual sales. One location. Recoverable.';

  static const String fohExcessCost = '\$215';
  static const String bohExcessCost = '\$214 + overtime';

  static const String plainLanguageRead =
      'Covers ran light. Schedule −13 FOH hours next week.';

  // ── Projected full-week totals (closed actuals + 5 projected at 20.6%) ───
  // Used by Projected Total Row in Full Week section.
  static const double projTargetLaborPct  = 20.6;
  static const double projActualLaborPct  = 21.4;
  static const double projVariancePts     =  0.8;
  static const double projDollarGapWeekly = 623.0;
  static const double projDollarGapAnnual = 32396.0;
}

// ─── Weekly variance — delegates to WeekToDate ────────────────────────────────

class WeeklyVariance {
  static const String weekLabel = WeekToDate.weekLabel;

  static const int theoreticalCovers = WeekToDate.forecastCovers;
  static const int actualCovers = WeekToDate.totalCovers;
  static const int coversVariance = WeekToDate.coversVariance;

  static const int theoreticalFohHours = WeekToDate.theoreticalFohHours;
  static const int actualFohHours = WeekToDate.totalFohHours;
  static const int fohHoursVariance = WeekToDate.fohHoursVariance;

  static const int theoreticalBohHours = WeekToDate.theoreticalBohHours;
  static const int actualBohHours = WeekToDate.totalBohHours;
  static const int bohHoursVariance = WeekToDate.bohHoursVariance;

  static const double theoreticalFohLaborPct = WeekToDate.theoreticalFohLaborPct;
  static const double actualFohLaborPct = WeekToDate.actualFohLaborPct;
  static const double fohLaborPctVariance = WeekToDate.fohLaborPctVariance;

  static const double theoreticalBohLaborPct = WeekToDate.theoreticalBohLaborPct;
  static const double actualBohLaborPct = WeekToDate.actualBohLaborPct;
  static const double bohLaborPctVariance = WeekToDate.bohLaborPctVariance;

  static const double theoreticalTotalLaborPct = WeekToDate.theoreticalTotalLaborPct;
  static const double actualTotalLaborPct = WeekToDate.actualTotalLaborPct;
  static const double totalLaborPctVariance = WeekToDate.totalLaborPctVariance;

  static const double dollarGapWeekly = WeekToDate.dollarGapWeekly;
  static const double dollarGapAnnualized = WeekToDate.dollarGapAnnualized;
  static const String annualizedContext = WeekToDate.annualizedContext;

  static const String fohExcessCost = WeekToDate.fohExcessCost;
  static const String bohExcessCost = WeekToDate.bohExcessCost;

  static const String plainLanguageRead = WeekToDate.plainLanguageRead;
}

class ShiftMetrics {
  // ── Hero mapping (Prompt 7.11) ──────────────────────────────────────────
  // Maps a lever id to the metric card name that should be highlighted.

  static String heroMetricNameForLever(String leverId) {
    if (leverId.startsWith('covers_')) return 'COVERS';
    if (leverId.startsWith('ppa_')) return 'PPA';
    if (leverId.startsWith('cplh_')) return 'CPLH';
    if (leverId.startsWith('splh_')) return 'SPLH';
    if (leverId.startsWith('foh_wage_') || leverId.startsWith('boh_wage_')) {
      return 'BLENDED WAGE';
    }
    return 'COVERS';
  }

  // ── Runtime Shift cards (Prompt 7.11) ────────────────────────────────────
  // Built from current ShiftSnapshot + BaselineData truth.
  // Exactly one card has isHero = true, matching the active lever family.

  static List<InputMetric> get cards {
    final leverId = ShiftSnapshot.primaryLeverId;
    final heroName = heroMetricNameForLever(leverId);

    // ── Covers ──────────────────────────────────────────────────────────
    final coversDelta = ShiftSnapshot.actualCovers - ShiftSnapshot.shiftForecastCovers;
    final coversUnfavorable = ShiftSnapshot.actualCovers < ShiftSnapshot.shiftForecastCovers;
    final coversStatus = coversUnfavorable
        ? 'Light'
        : (ShiftSnapshot.actualCovers > ShiftSnapshot.shiftForecastCovers ? 'Heavy' : 'On pace');

    // ── PPA ─────────────────────────────────────────────────────────────
    final ppaDelta = ShiftSnapshot.actualPPA - BaselineData.derivedTargetPPA;
    final ppaUnfavorable = ShiftSnapshot.actualPPA < BaselineData.derivedTargetPPA;
    final ppaStatus = ppaUnfavorable
        ? 'Watch'
        : (ShiftSnapshot.actualPPA > BaselineData.derivedTargetPPA ? 'Ahead' : 'On target');

    // ── CPLH ────────────────────────────────────────────────────────────
    final cplhDelta = ShiftSnapshot.actualCPLH - BaselineData.derivedTargetCPLH;
    final cplhUnfavorable = ShiftSnapshot.actualCPLH < BaselineData.derivedTargetCPLH;
    final opzLabel = BaselineData.opzStatusLabelForCplh(ShiftSnapshot.actualCPLH);
    String cplhStatus;
    switch (opzLabel) {
      case 'BELOW OPZ': cplhStatus = 'Below OPZ'; break;
      case 'IN OPZ':    cplhStatus = 'In OPZ';    break;
      case 'ABOVE OPZ': cplhStatus = 'Above OPZ'; break;
      default:          cplhStatus = 'In OPZ';
    }
    final cplhStatusFavorable =
        BaselineData.opzStatusForCplh(ShiftSnapshot.actualCPLH) == 'in';

    // ── SPLH ────────────────────────────────────────────────────────────
    final splhDelta = ShiftSnapshot.actualSPLH - BaselineData.derivedTargetSPLH;
    final splhUnfavorable = ShiftSnapshot.actualSPLH < BaselineData.derivedTargetSPLH;
    final splhStatus = splhUnfavorable
        ? 'Below target'
        : (ShiftSnapshot.actualSPLH > BaselineData.derivedTargetSPLH ? 'Above target' : 'On target');

    return [
      InputMetric(
        name: 'COVERS',
        currentFormatted: '${ShiftSnapshot.actualCovers}',
        targetFormatted: 'Forecast ${ShiftSnapshot.shiftForecastCovers}',
        deltaFormatted: '${coversDelta >= 0 ? '+' : ''}$coversDelta',
        deltaUnfavorable: coversUnfavorable,
        isHero: heroName == 'COVERS',
        statusLine: coversStatus,
      ),
      InputMetric(
        name: 'PPA',
        currentFormatted: '\$${ShiftSnapshot.actualPPA.toStringAsFixed(2)}',
        targetFormatted: 'Target \$${BaselineData.derivedTargetPPA.toStringAsFixed(2)}',
        deltaFormatted: ppaDelta >= 0
            ? '+\$${ppaDelta.toStringAsFixed(2)}'
            : '-\$${ppaDelta.abs().toStringAsFixed(2)}',
        deltaUnfavorable: ppaUnfavorable,
        isHero: heroName == 'PPA',
        statusLine: ppaStatus,
      ),
      InputMetric(
        name: 'CPLH',
        currentFormatted: ShiftSnapshot.actualCPLH.toStringAsFixed(1),
        targetFormatted: 'Target ${BaselineData.derivedTargetCPLH.toStringAsFixed(1)}',
        deltaFormatted: '${cplhDelta >= 0 ? '+' : ''}${cplhDelta.toStringAsFixed(1)}',
        deltaUnfavorable: cplhUnfavorable,
        statusFavorable: cplhStatusFavorable,
        isHero: heroName == 'CPLH',
        statusLine: cplhStatus,
      ),
      InputMetric(
        name: 'SPLH',
        currentFormatted: '\$${ShiftSnapshot.actualSPLH.toStringAsFixed(0)}',
        targetFormatted: 'Target \$${BaselineData.derivedTargetSPLH.toStringAsFixed(0)}',
        deltaFormatted: splhDelta >= 0
            ? '+\$${splhDelta.toStringAsFixed(0)}'
            : '-\$${splhDelta.abs().toStringAsFixed(0)}',
        deltaUnfavorable: splhUnfavorable,
        isHero: heroName == 'SPLH',
        statusLine: splhStatus,
      ),
      InputMetric(
        name: 'BLENDED WAGE',
        currentFormatted: '\$${ShiftSnapshot.blendedWage.toStringAsFixed(2)}',
        targetFormatted: 'Model \$${ShiftSnapshot.blendedWage.toStringAsFixed(2)}',
        deltaFormatted: '—',
        deltaUnfavorable: false,
        isHero: heroName == 'BLENDED WAGE',
        statusLine: 'On model',
        fullWidth: true,
      ),
    ];
  }
}

// ─── Schedule forecast ────────────────────────────────────────────────────────

class ScheduleDay {
  final String day;
  final int forecastCovers;

  const ScheduleDay({required this.day, required this.forecastCovers});

  int get requiredFohHours =>
      LaborModel.modelFohHours(forecastCovers, BaselineData.derivedTargetCPLH);

  int get requiredBohHours =>
      LaborModel.modelBohHours(
          forecastCovers, BaselineData.derivedTargetPPA, BaselineData.derivedTargetSPLH);

  /// Per-daypart cover breakdown for this day, proportional to BaselineData
  /// targetCovers for each daypart. Drives expandable rows in ScheduleBuilder.
  ///
  /// 7.55r item 2: inline resolver call (demo definitions for this
  /// fixture path, which is retired from the visible Schedule surface
  /// per compatibility_bridge_scope.md). No longer goes through the
  /// retired `WeekDayOrder.daypartsFor(...)` helper.
  List<DaypartForecast> get daypartBreakdown {
    final ids    = ServicePeriodDefinitionResolver.idsForDayLabel(
        ServicePeriodDefinitionResolver.demoDefinitions, day);
    final ranges = BaselineData.daypartRanges
        .where((r) => ids.contains(r.id))
        .toList();
    final total  = ranges.fold(0, (s, r) => s + r.targetCovers);
    if (total == 0) return [];
    return ranges
        .map((r) => DaypartForecast(
              daypart: r.id,
              label:   r.label,
              forecastCovers:
                  (forecastCovers * r.targetCovers / total).round(),
            ))
        .toList();
  }
}

class ScheduleForecastDefaults {
  static const List<ScheduleDay> defaultDays = [
    ScheduleDay(day: 'Mon', forecastCovers: 140),
    ScheduleDay(day: 'Tue', forecastCovers: 150),
    ScheduleDay(day: 'Wed', forecastCovers: 160),
    ScheduleDay(day: 'Thu', forecastCovers: 190),
    ScheduleDay(day: 'Fri', forecastCovers: 220),
    ScheduleDay(day: 'Sat', forecastCovers: 230),
    ScheduleDay(day: 'Sun', forecastCovers: 110),
  ];

  static const int defaultWeeklyCovers = 1200;

  static const String principleStatement =
      'You are not scheduling to last Friday\'s sales. You are scheduling to next '
      "Friday's guests. The covers tell you how many people are coming. CPLH tells "
      'you how many hours you need to serve them. That is the schedule.';
}
