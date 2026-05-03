// Phase 10.5.2 — ShiftServicePeriodReadService.
//
// Per-service-period read service that consumes 10.5.1's
// `DaypartBucketer` and aggregates canonical facts into per-period
// accumulators (covers, sales, FOH/BOH minutes, wage dollars, derived
// CPLH / SPLH / PPA / blended wage).
//
// Design notes:
//   * Pure-function service. No I/O, no state. The notifier
//     (`ShiftServicePeriodNotifier`) owns lifecycle and source-of-truth
//     loading; this service just folds canonical facts into buckets.
//   * Canonical-fact-driven. Inputs are POS lines + labor punches
//     carrying restaurant-local timestamps. The bucketing engine
//     (10.5.1) handles classification and punch-split.
//   * Jim Taylor labor-punch-split rule honored: `non_service`
//     segments returned by `DaypartBucketer.bucketLaborPunch` are
//     excluded from CPLH / SPLH denominators (we drop segments with
//     `servicePeriodId == null`).
//   * Correction replay supported via `applyPosLineCorrection` /
//     `applyLaborPunchCorrection`. The notifier dedupes facts by
//     `sourceId` (latest wins) before calling `build`; the helper
//     methods exist for incremental updates that don't want to walk
//     the full fact list again.
//
// Phase 10.5.3 — Per-period primary driver:
//   * `computePrimaryLeverId` mints the per-period driver via
//     `LaborModel.determineLever` (the 7.58 single source of truth).
//   * Returns `null` when inputs are insufficient OR when the engine
//     would fall through to the legacy `'covers_down'` empty-candidate
//     default (per 7.58 F-2 — `'covers_down'` overclaim is banned at
//     the daypart scope before `7.58.0a` lands the `'on_model'`
//     replacement). The notifier surfaces null as the
//     `LeverCards.notYetOnModelLabel` degraded state.
//   * Lowercase canonical id form per `7.61` R-STOR-1 / R-PROD-5; no
//     upper-snake leak.
library;

import '../domain/models/active_target_profile.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/daypart_bucketer.dart';
import 'labor_model.dart';

/// One canonical POS line for bucketing. `eventLocalTimestamp` must
/// already be in restaurant-local time (per the canonical-fact
/// contract).
class CanonicalPosLine {
  final String sourceId;
  final DateTime eventLocalTimestamp;

  /// Number of guests on this order (`Order.numberOfGuests` for Toast,
  /// equivalent for other vendors).
  final int covers;

  /// Order amount in dollars, less voids.
  final double sales;

  const CanonicalPosLine({
    required this.sourceId,
    required this.eventLocalTimestamp,
    required this.covers,
    required this.sales,
  });
}

/// One canonical labor punch for bucketing. Both timestamps must be
/// restaurant-local. `role` is `'foh'` or `'boh'`; `hourlyWage` is the
/// punch's effective hourly rate (per-minute wage = `hourlyWage / 60`).
class CanonicalLaborPunch {
  final String sourceId;
  final DateTime clockedInLocal;
  final DateTime clockedOutLocal;
  final String role;
  final double hourlyWage;

  const CanonicalLaborPunch({
    required this.sourceId,
    required this.clockedInLocal,
    required this.clockedOutLocal,
    required this.role,
    required this.hourlyWage,
  });
}

/// Per-service-period rolling accumulator. Mutable internally during a
/// build pass; the read service returns immutable snapshots.
class ServicePeriodAccumulator {
  final String servicePeriodId;
  final int covers;
  final double sales;
  final int checks;
  final int fohMinutes;
  final int bohMinutes;
  final double fohWageDollars;
  final double bohWageDollars;

  const ServicePeriodAccumulator({
    required this.servicePeriodId,
    this.covers = 0,
    this.sales = 0,
    this.checks = 0,
    this.fohMinutes = 0,
    this.bohMinutes = 0,
    this.fohWageDollars = 0,
    this.bohWageDollars = 0,
  });

  double get fohHours => fohMinutes / 60.0;
  double get bohHours => bohMinutes / 60.0;
  double get totalHours => fohHours + bohHours;
  int get totalMinutes => fohMinutes + bohMinutes;

  /// Covers per labor hour. Denominator excludes `non_service` minutes
  /// per the Jim Taylor labor-punch-split rule (those segments are
  /// never added to `fohMinutes` / `bohMinutes`).
  double get cplh => totalMinutes > 0 ? covers * 60.0 / totalMinutes : 0.0;

  /// Sales per labor hour. Same denominator as CPLH.
  double get splh => totalMinutes > 0 ? sales * 60.0 / totalMinutes : 0.0;

  /// Per-cover average sale.
  double get ppa => covers > 0 ? sales / covers : 0.0;

  /// Blended wage = total wage dollars ÷ total in-period hours.
  double get blendedWage => totalMinutes > 0
      ? (fohWageDollars + bohWageDollars) * 60.0 / totalMinutes
      : 0.0;

  /// FOH-side blended wage. 0 when no FOH minutes recorded.
  double get fohBlendedWage =>
      fohMinutes > 0 ? fohWageDollars * 60.0 / fohMinutes : 0.0;

  /// BOH-side blended wage. 0 when no BOH minutes recorded.
  double get bohBlendedWage =>
      bohMinutes > 0 ? bohWageDollars * 60.0 / bohMinutes : 0.0;

  /// Sales per BOH labor hour. The 7.58 contract defines SPLH as the
  /// BOH productivity axis (`splh_up` / `splh_down` are BOH-only
  /// levers); the engine input must match that convention. Distinct
  /// from [splh], which is sales over FOH+BOH minutes for the
  /// per-period metric grid.
  double get bohSplh =>
      bohMinutes > 0 ? sales * 60.0 / bohMinutes : 0.0;

  /// Whether this bucket has any covers, sales, or labor minutes
  /// recorded. Empty buckets render as "no data yet".
  bool get hasAnyData =>
      covers > 0 || sales > 0 || fohMinutes > 0 || bohMinutes > 0;

  ServicePeriodAccumulator copyWith({
    int? covers,
    double? sales,
    int? checks,
    int? fohMinutes,
    int? bohMinutes,
    double? fohWageDollars,
    double? bohWageDollars,
  }) {
    return ServicePeriodAccumulator(
      servicePeriodId: servicePeriodId,
      covers: covers ?? this.covers,
      sales: sales ?? this.sales,
      checks: checks ?? this.checks,
      fohMinutes: fohMinutes ?? this.fohMinutes,
      bohMinutes: bohMinutes ?? this.bohMinutes,
      fohWageDollars: fohWageDollars ?? this.fohWageDollars,
      bohWageDollars: bohWageDollars ?? this.bohWageDollars,
    );
  }
}

class ShiftServicePeriodReadService {
  const ShiftServicePeriodReadService();

  /// Folds [posLines] and [laborPunches] into per-service-period
  /// accumulators. The returned map is keyed by `ServicePeriodId` and
  /// contains an entry for every period in [definitions] (zero-data
  /// periods are populated with empty accumulators so the UI can render
  /// every defined service period).
  ///
  /// Callers must dedupe inputs by `sourceId` (latest wins) before
  /// calling — the notifier owns this lifecycle. `non_service` punch
  /// segments are dropped per the Jim Taylor labor-punch-split rule.
  ///
  /// Throws [MissingTimezoneError] when [location] has no IANA
  /// timezone (delegated from the bucketing engine).
  Map<String, ServicePeriodAccumulator> build({
    required List<CanonicalPosLine> posLines,
    required List<CanonicalLaborPunch> laborPunches,
    required BucketingLocationContext location,
    required List<ServicePeriodDefinition> definitions,
  }) {
    final buckets = <String, _MutableAccumulator>{
      for (final d in definitions) d.id: _MutableAccumulator(d.id),
    };

    for (final line in posLines) {
      final periodId = DaypartBucketer.bucketPosLine(
        BucketingPosLine(
          sourceId: line.sourceId,
          eventLocalTimestamp: line.eventLocalTimestamp,
        ),
        location,
        definitions,
      );
      if (periodId == null) continue;
      final bucket = buckets[periodId];
      if (bucket == null) continue;
      bucket.addPos(
        covers: line.covers,
        sales: line.sales,
        checkDelta: 1,
      );
    }

    for (final punch in laborPunches) {
      final segments = DaypartBucketer.bucketLaborPunch(
        BucketingLaborPunch(
          sourceId: punch.sourceId,
          clockedInLocal: punch.clockedInLocal,
          clockedOutLocal: punch.clockedOutLocal,
        ),
        location,
        definitions,
      );
      for (final seg in segments) {
        final id = seg.servicePeriodId;
        if (id == null) continue; // Jim Taylor: drop non_service slivers.
        final bucket = buckets[id];
        if (bucket == null) continue;
        bucket.addPunchMinutes(
          role: punch.role,
          minutes: seg.minutes,
          hourlyWage: punch.hourlyWage,
        );
      }
    }

    return {
      for (final entry in buckets.entries) entry.key: entry.value.snapshot(),
    };
  }

  /// Subtracts the contribution of [prior] and adds the contribution
  /// of [replacement] (or treats it as a delete when null). Used by
  /// the notifier when a single fact is updated and a full rebuild
  /// would be wasteful.
  ///
  /// The same `non_service` exclusion rule applies — replacement
  /// segments classified as `non_service` are not added back, and
  /// prior `non_service` segments were never added in the first place.
  Map<String, ServicePeriodAccumulator> applyPosLineCorrection({
    required Map<String, ServicePeriodAccumulator> current,
    required CanonicalPosLine prior,
    required CanonicalPosLine? replacement,
    required BucketingLocationContext location,
    required List<ServicePeriodDefinition> definitions,
  }) {
    final mutable = <String, _MutableAccumulator>{
      for (final entry in current.entries)
        entry.key: _MutableAccumulator.fromSnapshot(entry.value),
    };

    final priorPeriod = DaypartBucketer.bucketPosLine(
      BucketingPosLine(
        sourceId: prior.sourceId,
        eventLocalTimestamp: prior.eventLocalTimestamp,
      ),
      location,
      definitions,
    );
    if (priorPeriod != null) {
      // Subtract the prior fact: covers/sales negated, check decremented
      // by 1. The check delta is explicit so a zero-cover or zero-sales
      // legitimate POS line (e.g., a void) is still counted/uncounted as
      // exactly one check movement — never inferred from amount sign.
      mutable[priorPeriod]?.addPos(
        covers: -prior.covers,
        sales: -prior.sales,
        checkDelta: -1,
      );
    }

    if (replacement != null) {
      final newPeriod = DaypartBucketer.bucketPosLine(
        BucketingPosLine(
          sourceId: replacement.sourceId,
          eventLocalTimestamp: replacement.eventLocalTimestamp,
        ),
        location,
        definitions,
      );
      if (newPeriod != null) {
        mutable[newPeriod]?.addPos(
          covers: replacement.covers,
          sales: replacement.sales,
          checkDelta: 1,
        );
      }
    }

    return {
      for (final entry in mutable.entries) entry.key: entry.value.snapshot(),
    };
  }

  /// Same as [applyPosLineCorrection] for labor punches. Iterates the
  /// segment list returned by the bucketer, dropping non-service
  /// slivers on both the subtract and add side.
  Map<String, ServicePeriodAccumulator> applyLaborPunchCorrection({
    required Map<String, ServicePeriodAccumulator> current,
    required CanonicalLaborPunch prior,
    required CanonicalLaborPunch? replacement,
    required BucketingLocationContext location,
    required List<ServicePeriodDefinition> definitions,
  }) {
    final mutable = <String, _MutableAccumulator>{
      for (final entry in current.entries)
        entry.key: _MutableAccumulator.fromSnapshot(entry.value),
    };

    final priorSegments = DaypartBucketer.bucketLaborPunch(
      BucketingLaborPunch(
        sourceId: prior.sourceId,
        clockedInLocal: prior.clockedInLocal,
        clockedOutLocal: prior.clockedOutLocal,
      ),
      location,
      definitions,
    );
    for (final seg in priorSegments) {
      final id = seg.servicePeriodId;
      if (id == null) continue;
      mutable[id]?.addPunchMinutes(
        role: prior.role,
        minutes: -seg.minutes,
        hourlyWage: prior.hourlyWage,
      );
    }

    if (replacement != null) {
      final newSegments = DaypartBucketer.bucketLaborPunch(
        BucketingLaborPunch(
          sourceId: replacement.sourceId,
          clockedInLocal: replacement.clockedInLocal,
          clockedOutLocal: replacement.clockedOutLocal,
        ),
        location,
        definitions,
      );
      for (final seg in newSegments) {
        final id = seg.servicePeriodId;
        if (id == null) continue;
        mutable[id]?.addPunchMinutes(
          role: replacement.role,
          minutes: seg.minutes,
          hourlyWage: replacement.hourlyWage,
        );
      }
    }

    return {
      for (final entry in mutable.entries) entry.key: entry.value.snapshot(),
    };
  }

  /// Phase 10.5.3 — per-period primary driver.
  ///
  /// Mints the driver id for one service period via
  /// `LaborModel.determineLever` (the 7.58 single source of truth). The
  /// engine consumes the per-period actuals on [bucket], the per-period
  /// [forecastCovers] (summed from the day's open / closed snapshots
  /// matching this period), and the whole-day [profile] standards
  /// (CPLH, SPLH, PPA, FOH/BOH wage). Per-period plan targets are not
  /// yet shipped — `ActiveTargetProfile` carries restaurant-level
  /// standards only, and the same standards apply across periods today.
  ///
  /// Returns `null` when:
  ///   * [profile] is null or the bucket has no in-period evidence
  ///     (`!bucket.hasAnyData`),
  ///   * required denominators are absent ([forecastCovers] ≤ 0,
  ///     `targetCPLH` ≤ 0, or `targetPPA` ≤ 0),
  ///   * OR the engine would fall through to the legacy
  ///     `'covers_down'` empty-candidate default (no axis exceeds its
  ///     threshold). Per Block 2 / 7.58 F-2, the daypart scope refuses
  ///     to overclaim `'covers_down'` until `7.58.0a` ships the
  ///     `'on_model'` replacement.
  ///
  /// When non-null, the returned id is one of the 16 lowercase
  /// canonical lever ids per `7.61` R-STOR-1 — never `'on_model'`,
  /// never upper-snake.
  ///
  /// Hours-flex levers (`foh_hours_*` / `boh_hours_*`) are not
  /// considered: per-period scheduled hours are not tracked yet.
  String? computePrimaryLeverId({
    required ServicePeriodAccumulator bucket,
    required int forecastCovers,
    required ActiveTargetProfile? profile,
  }) {
    if (profile == null) return null;
    if (!bucket.hasAnyData) return null;
    if (forecastCovers <= 0) return null;
    if (profile.targetCPLH <= 0 || profile.targetPPA <= 0) return null;

    // Mirror `LaborModel.determineLever`'s threshold checks to detect
    // the empty-candidate state up-front. We do NOT mint an id from
    // these deltas — that responsibility stays with the engine per
    // 7.58 Single Source of Truth + 7.61 R-PROD-1. We only gate the
    // engine call so its legacy `'covers_down'` fallback (F-2) cannot
    // surface as a real driver at the daypart scope.
    final coversDelta = (bucket.covers - forecastCovers) / forecastCovers;
    final cplhDelta = (bucket.cplh - profile.targetCPLH) / profile.targetCPLH;
    final ppaDelta = (bucket.ppa - profile.targetPPA) / profile.targetPPA;

    var anyCandidate = coversDelta.abs() > 0.02 ||
        cplhDelta.abs() > 0.05 ||
        ppaDelta.abs() > 0.03;

    // SPLH is the BOH productivity axis per 7.58. Use BOH-only sales-
    // per-labor-hour and skip the axis when no BOH minutes were
    // recorded — otherwise a FOH-only period would mint splh_up /
    // splh_down off `bucket.splh` (sales / total minutes), which is
    // not the BOH productivity the engine documents. Mirrors the
    // whole-day path's `avgSPLH = totalSales / actBoh`.
    final hasSplhInputs = profile.targetSPLH > 0 && bucket.bohMinutes > 0;
    if (hasSplhInputs) {
      final splhDelta =
          (bucket.bohSplh - profile.targetSPLH) / profile.targetSPLH;
      anyCandidate = anyCandidate || splhDelta.abs() > 0.05;
    }

    final hasFohWageInputs = profile.fohWage > 0 && bucket.fohMinutes > 0;
    if (hasFohWageInputs) {
      final fohWageDelta =
          (bucket.fohBlendedWage - profile.fohWage) / profile.fohWage;
      anyCandidate = anyCandidate || fohWageDelta.abs() > 0.03;
    }

    final hasBohWageInputs = profile.bohWage > 0 && bucket.bohMinutes > 0;
    if (hasBohWageInputs) {
      final bohWageDelta =
          (bucket.bohBlendedWage - profile.bohWage) / profile.bohWage;
      anyCandidate = anyCandidate || bohWageDelta.abs() > 0.03;
    }

    if (!anyCandidate) return null;

    return LaborModel.determineLever(
      actualCovers: bucket.covers,
      forecastCovers: forecastCovers,
      avgCPLH: bucket.cplh,
      avgPPA: bucket.ppa,
      targetCPLH: profile.targetCPLH,
      targetPPA: profile.targetPPA,
      avgSPLH: hasSplhInputs ? bucket.bohSplh : null,
      targetSPLH: hasSplhInputs ? profile.targetSPLH : null,
      avgFohBlendedWage: hasFohWageInputs ? bucket.fohBlendedWage : null,
      targetFohWage: hasFohWageInputs ? profile.fohWage : null,
      avgBohBlendedWage: hasBohWageInputs ? bucket.bohBlendedWage : null,
      targetBohWage: hasBohWageInputs ? profile.bohWage : null,
    );
  }

  /// Convenience: mint per-period drivers for every period in [buckets]
  /// using a per-period [forecastCoversByPeriod] map. Periods missing a
  /// forecast covers entry default to 0 (degrades to null per
  /// [computePrimaryLeverId]).
  Map<String, String?> computePrimaryLevers({
    required Map<String, ServicePeriodAccumulator> buckets,
    required Map<String, int> forecastCoversByPeriod,
    required ActiveTargetProfile? profile,
  }) {
    return {
      for (final entry in buckets.entries)
        entry.key: computePrimaryLeverId(
          bucket: entry.value,
          forecastCovers: forecastCoversByPeriod[entry.key] ?? 0,
          profile: profile,
        ),
    };
  }
}

/// Internal mutable accumulator. Only the snapshot is exposed publicly.
class _MutableAccumulator {
  final String servicePeriodId;
  int _covers = 0;
  double _sales = 0;
  int _checks = 0;
  int _fohMinutes = 0;
  int _bohMinutes = 0;
  double _fohWageDollars = 0;
  double _bohWageDollars = 0;

  _MutableAccumulator(this.servicePeriodId);

  factory _MutableAccumulator.fromSnapshot(ServicePeriodAccumulator s) {
    return _MutableAccumulator(s.servicePeriodId)
      .._covers = s.covers
      .._sales = s.sales
      .._checks = s.checks
      .._fohMinutes = s.fohMinutes
      .._bohMinutes = s.bohMinutes
      .._fohWageDollars = s.fohWageDollars
      .._bohWageDollars = s.bohWageDollars;
  }

  void addPos({
    required int covers,
    required double sales,
    required int checkDelta,
  }) {
    _covers += covers;
    _sales += sales;
    // Caller passes an explicit check delta so the contract works for
    // legitimate zero-cover / zero-sales POS lines (voids, comp meals,
    // discounts) without inferring direction from amount sign.
    _checks += checkDelta;
  }

  void addPunchMinutes({
    required String role,
    required int minutes,
    required double hourlyWage,
  }) {
    if (minutes == 0) return;
    final wageDollars = minutes * hourlyWage / 60.0;
    final isFoh = role.toLowerCase() == 'foh';
    if (isFoh) {
      _fohMinutes += minutes;
      _fohWageDollars += wageDollars;
    } else {
      _bohMinutes += minutes;
      _bohWageDollars += wageDollars;
    }
  }

  ServicePeriodAccumulator snapshot() {
    return ServicePeriodAccumulator(
      servicePeriodId: servicePeriodId,
      covers: _covers,
      sales: _sales,
      checks: _checks,
      fohMinutes: _fohMinutes,
      bohMinutes: _bohMinutes,
      fohWageDollars: _fohWageDollars,
      bohWageDollars: _bohWageDollars,
    );
  }
}
