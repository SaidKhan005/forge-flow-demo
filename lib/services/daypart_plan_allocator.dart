// Phase 7.56c.0 - Shared daypart plan-target allocator.
//
// Pure deterministic allocator that splits a day-level plan target
// package (covers, sales, FOH/BOH hours) across daypart subrows.
//
// Single shared seam used by:
//   - `ScheduleForecastNotifier.adjustedDayViews` (Schedule presentation)
//   - `ShiftService.getFullWeekShifts` (Variance Full Week non-closed
//     row construction)
//
// Both surfaces read from the same locked plan daypart targets, so a
// projected Sat dinner row cannot show 230 covers while the matching
// Schedule subrow shows 223. Schedule's existing distribution-weight
// + service-period-definition + largest-remainder behaviour is
// preserved exactly - this file only relocates the math behind one
// shared call.
library;

import '../domain/models/schedule_distribution_weights.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/proportional_allocation.dart' as shared;
import '../domain/services/service_period_definition_resolver.dart';

/// One daypart subrow allocated from a day-level plan target package.
///
/// Plan-owned values only - PPA, wages, blended wage, theoretical %,
/// and OPZ bounds remain Benchmark-owned and live on
/// [ActiveTargetProfile].
class DaypartAllocation {
  final String daypartId;
  final String label;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;

  const DaypartAllocation({
    required this.daypartId,
    required this.label,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
  });
}

/// Pure deterministic daypart plan-target allocator.
///
/// Per-Daypart V1 (Slice 3) — RETIRED from the production locked read
/// path. The Plan tab's daypart sub-rows now READ the locked
/// per-(day, service_period) values stamped at lock time
/// (`weekly_plan_snapshot_day_dayparts`, via
/// `WeeklyPlanSnapshot.dayDayparts` /
/// `WeeklyPlanSnapshot.dayDaypartFor`) instead of regenerating them on
/// every render (plan Gap 6 / Gap 12, Design Rule 4 — read through the
/// persisted canonical write path; never bypass it).
///
/// This allocator is intentionally NOT deleted because it still has
/// legitimate non-locked-read consumers:
///   - live / preview Schedule mode (no persisted snapshot exists — the
///     plan is resolved from inputs, so there is nothing persisted to
///     read), and the locked-snapshot empty-`dayDayparts` fallback
///     (legacy snapshots / Gap 42 insufficient-recommendation), both in
///     `ScheduleForecastNotifier`;
///   - `ShiftService.getFullWeekShifts` (Variance Full Week non-closed
///     row construction — its persisted-row swap is plan Slice 5);
///   - `data_alignment_audit_read_service.dart` (audit scorer — plan
///     Slice 6).
///
/// New code MUST NOT call this for any path that has a persisted locked
/// snapshot available — read `WeeklyPlanSnapshot.dayDayparts` instead.
@Deprecated(
  'Per-Daypart V1 Slice 3: read locked sub-rows from '
  'WeeklyPlanSnapshot.dayDayparts (weekly_plan_snapshot_day_dayparts) '
  'instead of regenerating per-period values at render time. This '
  'allocator survives only as the live/preview + legacy/Gap-42 '
  'fallback and for the not-yet-swapped Variance (Slice 5) / audit '
  '(Slice 6) consumers.',
)
class DaypartPlanAllocator {
  const DaypartPlanAllocator._();

  /// Allocates a day-level plan target package across daypart subrows.
  ///
  /// - [day] is the canonical day label ('Mon'..'Sun').
  /// - [dayCovers], [daySales], [dayFohHours], [dayBohHours] are the
  ///   day totals straight from the locked weekly plan day row.
  /// - [definitions] are the active restaurant's persisted
  ///   service-period definitions (or
  ///   [ServicePeriodDefinitionResolver.demoDefinitions] when no
  ///   timing config is persisted).
  /// - [distributionWeights] are optional data-driven weights from
  ///   closed `ShiftRecord` history. When available and at least one
  ///   per-day daypart weight is positive, the per-day weights drive
  ///   the cover split; otherwise the allocator falls back to the
  ///   built-in lunch / dinner / late-night cover proportions.
  ///
  /// Allocation rules (preserved from the prior Schedule notifier
  /// implementation):
  ///   - covers and FOH hours: largest-remainder over integer weights
  ///     so subrow sums equal the day totals exactly.
  ///   - sales: proportional split across subrow covers, with the
  ///     final slot absorbing the rounding remainder.
  ///   - BOH hours: largest-remainder weighted by subrow sales (BOH
  ///     follows sales, not covers).
  ///
  /// Returns subrows in canonical service-period order (sortOrder,
  /// then id), with unknown ids appended alphabetically. Returns an
  /// empty list when no service periods apply to [day] (e.g. an
  /// unrecognised day label).
  static List<DaypartAllocation> allocate({
    required String day,
    required int dayCovers,
    required double daySales,
    required int dayFohHours,
    required int dayBohHours,
    required List<ServicePeriodDefinition> definitions,
    ScheduleDistributionWeights? distributionWeights,
  }) {
    final daypartData = _resolveDaypartWeights(
      day: day,
      definitions: definitions,
      distributionWeights: distributionWeights,
    );
    if (daypartData.isEmpty) return const [];

    final ids = daypartData.map((e) => e.$1).toList();
    final intWeights = daypartData.map((e) => e.$2).toList();

    final subCovers = _allocateLargestRemainder(dayCovers, intWeights);
    final subSales = _allocateProportionalDoubles(daySales, subCovers);
    final subFoh = _allocateLargestRemainder(dayFohHours, subCovers);
    final subBoh =
        _allocateLargestRemainderByDouble(dayBohHours, subSales);

    return List.generate(ids.length, (i) {
      return DaypartAllocation(
        daypartId: ids[i],
        label: ServicePeriodDefinitionResolver.labelForId(
            definitions, ids[i]),
        forecastCovers: subCovers[i],
        forecastSales: subSales[i],
        requiredFohHours: subFoh[i],
        requiredBohHours: subBoh[i],
      );
    });
  }

  static List<(String, int)> _resolveDaypartWeights({
    required String day,
    required List<ServicePeriodDefinition> definitions,
    required ScheduleDistributionWeights? distributionWeights,
  }) {
    if (distributionWeights != null && distributionWeights.isAvailable) {
      final daypartMap = distributionWeights.daypartWeightsFor(day);
      if (daypartMap.isNotEmpty && daypartMap.values.any((v) => v > 0)) {
        final entries = daypartMap.entries.toList();
        entries.sort((a, b) => ServicePeriodDefinitionResolver.sortKey(
                definitions, a.key)
            .compareTo(ServicePeriodDefinitionResolver.sortKey(
                definitions, b.key)));
        return entries.map((e) => (e.key, e.value)).toList();
      }
    }
    final ids = ServicePeriodDefinitionResolver.idsForDayLabel(
        definitions, day);
    return ids.map((id) {
      final w = _daypartCoverWeight[id] ?? 1.0;
      return (id, (w * 100).round());
    }).toList();
  }
}

/// Default daypart cover weight proportions for fallback allocation.
/// Derived from fixture daypart shape - lunch ~45%, dinner ~40%,
/// late night ~15%. Not read from BaselineData at render time.
const _daypartCoverWeight = <String, double>{
  'lunch': 0.45,
  'dinner': 0.40,
  'late_night': 0.15,
};

// Per-Daypart V1 (bottom-up locked snapshot): the largest-remainder /
// proportional math now lives in the shared pure helper
// `lib/domain/services/proportional_allocation.dart` so the locked
// snapshot writer and this allocator split covers exactly once, the
// same way (single source of truth — the prior divergence was the root
// cause of Σ(per-period) ≠ day-row drift). These thin delegates
// preserve the exact prior behaviour for the allocator's existing
// live/preview + legacy/Gap-42 + Variance/audit consumers.

/// Largest-remainder allocation of [total] across integer [weights].
/// Guarantees `sum(result) == total`. Returns zeros when all weights
/// are zero.
List<int> _allocateLargestRemainder(int total, List<int> weights) =>
    shared.allocateLargestRemainderInt(total, weights);

/// Largest-remainder allocation of [total] across double [shares].
List<int> _allocateLargestRemainderByDouble(int total, List<double> shares) =>
    shared.allocateLargestRemainderByDouble(total, shares);

/// Proportional double split of [total] across integer [weights].
///
/// Returns doubles that sum exactly to [total] (subject to
/// floating-point precision) by assigning the rounding remainder to
/// the final slot.
List<double> _allocateProportionalDoubles(double total, List<int> weights) =>
    shared.allocateProportionalDoubles(total, weights);
