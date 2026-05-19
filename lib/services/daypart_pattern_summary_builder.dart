// Phase 7.55k.3 — Builds aggregate DaypartPatternSummary records from
// closed ShiftRecords.
//
// Groups by recurring service-period bucket (restaurantId + dayLabel +
// daypart). Source facts are keyed by ServicePeriodKey-shaped identity;
// this builder aggregates across them.
//
// Does not replace HistoryPatternBuilder — current History / Learn
// consumers remain on HistoryPatternRecord for now.
//
// Phase 7.55k.3a: lever evidence now validates against LeverCards.all
// (aligned with HistoryPatternBuilder). Exemplar fallback IDs use stable
// source fields instead of input-order-dependent indices.

import '../domain/constants/app_defaults.dart';
import '../domain/canonical_day_order.dart';
import '../domain/models/restaurant_timing_config.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/shift_boundary_resolver.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../models/daypart_pattern_summary.dart';
import '../models/shift_record.dart';
import '../services/closed_timing_label_resolver.dart';
import '../services/labor_model.dart';

typedef DaypartPatternShiftCloseAuthorityResolver =
    ShiftCloseAuthority Function(ShiftRecord shift);

class DaypartPatternSummaryBuilder {
  DaypartPatternSummaryBuilder._();

  // ── Deterministic service-period sort order ─────────────────────────────
  // Narrow bridge — avoids building the full ServicePeriodDefinitionResolver
  // for this slice. Unknown IDs sort last, alphabetically among themselves.
  static const _servicePeriodOrder = <String, int>{
    'morning': 0,
    'lunch': 1,
    'dinner': 2,
    'late_night': 3,
  };

  // Tie-break orders match HistoryTeachingAnalyzer for consistency.
  static const _leakTieBreakOrder = [
    'cplh_down',
    'splh_down',
    'ppa_down',
    'covers_down',
    'foh_wage_up',
    'boh_wage_up',
  ];

  static const _benchmarkTieBreakOrder = [
    'ppa_up',
    'cplh_up',
    'splh_up',
    'covers_up',
    'foh_wage_down',
    'boh_wage_down',
  ];

  /// Valid lever IDs from LeverCards.all — aligned with HistoryPatternBuilder.
  /// Unknown or unmapped lever IDs are excluded from lever evidence but still
  /// contribute to closedShiftCount and metric averages.
  static final _validLeverIds = LeverCards.all.map((l) => l.id).toSet();

  /// Maximum number of exemplar source shift IDs per summary.
  static const maxExemplarCount = 5;

  /// Builds aggregate summaries from closed [ShiftRecord]s.
  ///
  /// - Only rows eligible for closed-truth surfaces are included.
  /// - Grouped by `restaurantId + dayLabel + daypart`.
  /// - [minSampleThreshold]: summaries with fewer closed shifts are
  ///   excluded from the output. Defaults to 1 (include all non-empty
  ///   buckets).
  /// - Output is sorted by canonical day order then service-period order.
  static List<DaypartPatternSummary> fromClosedShifts(
    List<ShiftRecord> shifts, {
    int minSampleThreshold = 1,
    ClosedTimingLabelResolver? timingLabelResolver,
    List<ServicePeriodDefinition>? servicePeriodDefinitions,
    String? currentOperationalBusinessDate,
    DaypartPatternShiftCloseAuthorityResolver? shiftCloseAuthorityForRow,
  }) {
    final configuredDefinitions = servicePeriodDefinitions?.isNotEmpty == true
        ? servicePeriodDefinitions
        : null;

    // ── 1. Group closed shifts by recurring bucket ────────────────────────
    final buckets = <String, List<ShiftRecord>>{};
    for (final shift in shifts) {
      if (!_isEligibleClosedTruth(
        shift,
        currentOperationalBusinessDate: currentOperationalBusinessDate,
        shiftCloseAuthorityForRow: shiftCloseAuthorityForRow,
      )) {
        continue;
      }
      final bucketKey = _bucketKeyFor(
        shift,
        timingLabelResolver: timingLabelResolver,
        servicePeriodDefinitions: configuredDefinitions,
      );
      final key = '${shift.restaurantId}|${shift.dayLabel}|$bucketKey';
      (buckets[key] ??= []).add(shift);
    }

    // ── 2. Build one summary per bucket ───────────────────────────────────
    final summaries = <DaypartPatternSummary>[];
    for (final entry in buckets.entries) {
      final group = entry.value;
      if (group.length < minSampleThreshold) continue;

      final first = group.first;
      summaries.add(
        _buildSummary(
          restaurantId: first.restaurantId,
          dayLabel: first.dayLabel,
          daypart: _bucketKeyFor(
            first,
            timingLabelResolver: timingLabelResolver,
            servicePeriodDefinitions: configuredDefinitions,
          ),
          servicePeriodLabel: _servicePeriodLabelFor(
            first,
            timingLabelResolver: timingLabelResolver,
            servicePeriodDefinitions: configuredDefinitions,
          ),
          servicePeriodSortOrder: _servicePeriodSortOrderFor(
            first,
            timingLabelResolver: timingLabelResolver,
            servicePeriodDefinitions: configuredDefinitions,
          ),
          shifts: group,
        ),
      );
    }

    // ── 3. Sort deterministically ─────────────────────────────────────────
    summaries.sort((a, b) {
      final dayA = CanonicalDayOrder.index[a.dayLabel] ?? 99;
      final dayB = CanonicalDayOrder.index[b.dayLabel] ?? 99;
      if (dayA != dayB) return dayA.compareTo(dayB);

      final dpA =
          a.servicePeriodSortOrder ?? _servicePeriodOrder[a.daypart] ?? 99;
      final dpB =
          b.servicePeriodSortOrder ?? _servicePeriodOrder[b.daypart] ?? 99;
      if (dpA != dpB) return dpA.compareTo(dpB);

      // Final tiebreak on daypart string for unknown IDs.
      return a.daypart.compareTo(b.daypart);
    });

    return summaries;
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  static DaypartPatternSummary _buildSummary({
    required String restaurantId,
    required String dayLabel,
    required String daypart,
    String? servicePeriodLabel,
    int? servicePeriodSortOrder,
    required List<ShiftRecord> shifts,
  }) {
    final count = shifts.length;

    // ── Metric sums ───────────────────────────────────────────────────────
    double sumCovers = 0;
    double sumSales = 0;
    double sumPPA = 0;
    double sumCPLH = 0;
    double sumSPLH = 0;
    double sumFohHours = 0;
    double sumBohHours = 0;
    double sumLaborPct = 0;
    double sumVariancePts = 0;
    int laborSampleCount = 0;

    for (final s in shifts) {
      sumCovers += s.covers;
      sumSales += s.actualSales;
      sumPPA += s.ppa;
      sumCPLH += s.cplh;
      sumSPLH += s.splh;
      sumFohHours += s.fohHours;
      sumBohHours += s.bohHours;
      if (s.hasSourceBackedTotalLaborPct) {
        sumLaborPct += s.totalLaborPct;
        laborSampleCount++;
      }
      sumVariancePts += s.variancePts;
    }

    // ── Lever classification ──────────────────────────────────────────────
    // ON_MODEL and unknown/unmapped lever IDs are excluded from lever
    // counting. Only valid known lever IDs (from LeverCards.all) participate
    // in benchmark/leak evidence. All closed shifts still count toward
    // closedShiftCount and metric averages.
    final benchmarkFreq = <String, int>{};
    final leakFreq = <String, int>{};
    int benchmarkCount = 0;
    int leakCount = 0;

    for (final s in shifts) {
      final leverId = s.normalizedLeverId;
      if (leverId == 'on_model') continue;
      if (!_validLeverIds.contains(leverId)) continue;

      if (LaborModel.isFavorableLever(leverId)) {
        benchmarkCount++;
        benchmarkFreq[leverId] = (benchmarkFreq[leverId] ?? 0) + 1;
      } else {
        leakCount++;
        leakFreq[leverId] = (leakFreq[leverId] ?? 0) + 1;
      }
    }

    // ── Exemplar IDs ──────────────────────────────────────────────────────
    // Sort candidate shifts deterministically so exemplar selection is stable
    // regardless of input ordering.
    final sorted = List<ShiftRecord>.from(shifts)
      ..sort((a, b) {
        final weekCmp = a.weekId.compareTo(b.weekId);
        if (weekCmp != 0) return weekCmp;
        final aDate = a.businessDate ?? '';
        final bDate = b.businessDate ?? '';
        final dateCmp = aDate.compareTo(bDate);
        if (dateCmp != 0) return dateCmp;
        return a.covers.compareTo(b.covers);
      });

    final exemplarIds = <String>[];
    for (
      var i = 0;
      i < sorted.length && exemplarIds.length < maxExemplarCount;
      i++
    ) {
      final s = sorted[i];
      final id =
          s.sourceShiftId ??
          '${s.weekId}:${s.dayLabel}:${s.daypart}:${s.businessDate ?? s.weekId}';
      exemplarIds.add(id);
    }

    return DaypartPatternSummary(
      restaurantId: restaurantId,
      dayLabel: dayLabel,
      daypart: daypart,
      servicePeriodLabel: servicePeriodLabel,
      servicePeriodSortOrder: servicePeriodSortOrder,
      closedShiftCount: count,
      benchmarkCount: benchmarkCount,
      leakCount: leakCount,
      dominantBenchmarkLeverId: _dominantLever(
        benchmarkFreq,
        _benchmarkTieBreakOrder,
      ),
      dominantLeakLeverId: _dominantLever(leakFreq, _leakTieBreakOrder),
      avgCovers: count > 0 ? sumCovers / count : 0,
      avgSales: count > 0 ? sumSales / count : 0,
      avgPPA: count > 0 ? sumPPA / count : 0,
      avgCPLH: count > 0 ? sumCPLH / count : 0,
      avgSPLH: count > 0 ? sumSPLH / count : 0,
      avgFohHours: count > 0 ? sumFohHours / count : 0,
      avgBohHours: count > 0 ? sumBohHours / count : 0,
      avgLaborPct: laborSampleCount > 0 ? sumLaborPct / laborSampleCount : 0,
      avgLaborSampleCount: laborSampleCount,
      avgVariancePts: count > 0 ? sumVariancePts / count : 0,
      exemplarSourceShiftIds: exemplarIds,
    );
  }

  static String _bucketKeyFor(
    ShiftRecord shift, {
    ClosedTimingLabelResolver? timingLabelResolver,
    List<ServicePeriodDefinition>? servicePeriodDefinitions,
  }) {
    if (timingLabelResolver?.hasSavedTimingIdentity(shift) ?? false) {
      return timingLabelResolver!.bucketKeyFor(shift);
    }
    if (_hasSavedTimingIdentity(shift)) {
      return shift.servicePeriodKey!.trim();
    }
    final servicePeriodKey = shift.servicePeriodKey?.trim();
    if (servicePeriodDefinitions != null &&
        servicePeriodKey != null &&
        servicePeriodKey.isNotEmpty) {
      return servicePeriodKey;
    }
    return shift.daypart;
  }

  static String? _servicePeriodLabelFor(
    ShiftRecord shift, {
    ClosedTimingLabelResolver? timingLabelResolver,
    List<ServicePeriodDefinition>? servicePeriodDefinitions,
  }) {
    final snapshot = timingLabelResolver?.snapshotFor(shift);
    final snapshotLabel = snapshot?.label.trim();
    if (snapshotLabel != null && snapshotLabel.isNotEmpty) {
      return snapshot!.label;
    }

    final servicePeriodKey = shift.servicePeriodKey?.trim();
    if (servicePeriodDefinitions != null &&
        servicePeriodKey != null &&
        servicePeriodKey.isNotEmpty) {
      return ServicePeriodDefinitionResolver.labelForId(
        servicePeriodDefinitions,
        servicePeriodKey,
      );
    }
    if (_hasSavedTimingIdentity(shift)) return null;
    return null;
  }

  static int? _servicePeriodSortOrderFor(
    ShiftRecord shift, {
    ClosedTimingLabelResolver? timingLabelResolver,
    List<ServicePeriodDefinition>? servicePeriodDefinitions,
  }) {
    final savedSortOrder = timingLabelResolver?.sortOrderFor(shift);
    if (savedSortOrder != null) return savedSortOrder;

    final servicePeriodKey = shift.servicePeriodKey?.trim();
    if (servicePeriodDefinitions != null &&
        servicePeriodKey != null &&
        servicePeriodKey.isNotEmpty) {
      return ServicePeriodDefinitionResolver.sortIndex(
        servicePeriodDefinitions,
        servicePeriodKey,
      );
    }
    if (_hasSavedTimingIdentity(shift)) return null;
    return null;
  }

  static bool _isEligibleClosedTruth(
    ShiftRecord shift, {
    required String? currentOperationalBusinessDate,
    required DaypartPatternShiftCloseAuthorityResolver?
    shiftCloseAuthorityForRow,
  }) {
    if (currentOperationalBusinessDate == null) return shift.isClosed;
    return ShiftBoundaryResolver.isEligibleForClosedTruth(
      rowStatus: shift.status,
      shiftCloseAuthority:
          shiftCloseAuthorityForRow?.call(shift) ??
          ShiftCloseAuthority.appLocalCutoffFallback,
      rowBusinessDate: shift.businessDate,
      currentOperationalBusinessDate: currentOperationalBusinessDate,
    );
  }

  static bool _hasSavedTimingIdentity(ShiftRecord shift) {
    final versionId = shift.businessTimingProfileVersionId?.trim();
    final periodKey = shift.servicePeriodKey?.trim();
    return versionId != null &&
        versionId.isNotEmpty &&
        periodKey != null &&
        periodKey.isNotEmpty;
  }

  /// Returns the most common lever ID in [freq], using [tieBreakOrder]
  /// for deterministic tie-breaking. Returns null when [freq] is empty.
  static String? _dominantLever(
    Map<String, int> freq,
    List<String> tieBreakOrder,
  ) {
    if (freq.isEmpty) return null;

    final maxCount = freq.values.reduce((a, b) => a > b ? a : b);
    final tied = freq.entries
        .where((e) => e.value == maxCount)
        .map((e) => e.key)
        .toList();

    tied.sort((a, b) {
      final ai = tieBreakOrder.indexOf(a);
      final bi = tieBreakOrder.indexOf(b);
      final ai2 = ai < 0 ? 999 : ai;
      final bi2 = bi < 0 ? 999 : bi;
      return ai2.compareTo(bi2);
    });

    return tied.first;
  }
}
