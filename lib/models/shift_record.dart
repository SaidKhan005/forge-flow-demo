// One shift (one daypart) — stored in SQLite.
// Raw inputs are set at close time; all labor % and dollar fields are derived.

import '../domain/constants/app_defaults.dart';
import '../services/labor_model.dart';

class ShiftRecord {
  final int? id;
  final String restaurantId;
  final String weekId; // "2026-W13"
  final String dayLabel; // "Mon", "Tue", …, "Sun"
  final String daypart; // "lunch" | "dinner" | "late_night"
  final String status; // "closed" | "projected"
  final int covers;
  final int forecastCovers;
  final double ppa;
  final double cplh;
  final double splh;
  final int fohHours;
  final int bohHours;
  final double
  theoreticalLaborPct; // locked at close — snapshot of target at time of shift
  final String
  primaryLever; // upper-snake form: "COVERS_DOWN", "CPLH_DOWN", …, plus
  // the "ON_MODEL" sentinel for non-closed rows
  // (phase_7_58 contract Output Cardinality).

  // ── Close-shift source facts (Phase 3 addition) ───────────────────────────
  // All nullable so existing seed/demo constructors compile without changes.

  /// FOH hours on the published schedule for this shift.
  final int? scheduledFohHours;

  /// BOH hours on the published schedule for this shift.
  final int? scheduledBohHours;

  /// Actual FOH labor dollars from the labor system.
  /// When absent, consumers should prefer persisted percent/blended facts.
  /// If no source-backed labor fact exists at all, the getters degrade
  /// honestly to 0 instead of synthesizing config-wage truth.
  final double? storedFohLaborDollar;

  /// Actual BOH labor dollars from the labor system.
  /// When absent, consumers should prefer persisted percent/blended facts.
  /// If no source-backed labor fact exists at all, the getters degrade
  /// honestly to 0 instead of synthesizing config-wage truth.
  final double? storedBohLaborDollar;

  /// Persisted actual FOH labor % from the source row.
  /// Used when dollar facts are absent so percent-based consumers do not
  /// silently synthesize config-wage truth.
  final double? storedFohLaborPct;

  /// Persisted actual BOH labor % from the source row.
  final double? storedBohLaborPct;

  /// Persisted actual total labor % from the source row.
  /// Used by Benchmark candidate evidence and similar consumers before
  /// any config-wage fallback is considered.
  final double? storedTotalLaborPct;

  /// Persisted blended wage from the source row.
  /// Used when dollar facts are absent so blended-wage consumers do not
  /// silently synthesize config-wage truth.
  final double? storedBlendedWage;

  // ── Locked target fields (Phase 7.5b) ──────────────────────────────────
  final String? targetProfileId;
  final String? targetProfileVersionId;
  final String? targetSourceType;
  final double? targetCPLH;
  final double? targetSPLH;
  final double? targetPPA;
  final double? targetFohWage;
  final double? targetBohWage;
  final double? opzFloorCPLH;
  final double? opzCeilingCPLH;
  final double? theoreticalFohLaborPct;
  final double? theoreticalBohLaborPct;

  // ── Per-Daypart V1 (Slice 1) — per-shift per-period target stamps ─────
  //
  // Promise 2: closed truth retains its stamp from close time. When the
  // cycle in force at close had a per-period row for this shift's
  // period, these columns mirror that row's values; otherwise they stay
  // null and consumers fall back to the whole-day `target*` fields
  // above (Gap 42 fallback semantics — Design Rule 2 forbids `0`
  // sentinels).
  final double? daypartTargetCPLH;
  final double? daypartTargetSPLH;
  final double? daypartTargetPPA;
  final double? daypartOpzFloorCPLH;
  final double? daypartOpzCeilingCPLH;

  /// Snapshot-sourced blended wage for open/projected rows.
  /// Populated from [OpenShiftSnapshot.blendedWage] via
  /// [CurrentWeekState.shiftRecordFromSnapshot]. Null for closed rows
  /// (which derive blended wage from actual labor dollars).
  final double? snapshotBlendedWage;

  /// Plan-sourced forecast sales for open/projected rows.
  ///
  /// This is an in-memory bridge for Full Week projection rows built from
  /// open snapshots. Closed rows and persisted historical rows leave it null
  /// and continue deriving sales from actual covers * row PPA.
  final double? planForecastSales;

  /// ISO 8601 date string for the business day of this shift (e.g. '2026-03-27').
  /// Nullable for backward compatibility with rows created before 7.55f.
  final String? businessDate;

  /// Business timing profile used to bucket this row. Nullable for legacy rows.
  final String? businessTimingProfileId;

  /// Stable timing version key. Lane 0 maps this to the profile id for now.
  final String? businessTimingProfileVersionId;

  /// Stable service-period key captured at bucket time. Mutable labels are
  /// display only.
  final String? servicePeriodKey;

  /// Identifier for the originating system (e.g. "toast", "demo_pos").
  final String? sourceSystem;

  /// Native shift/check id from the originating system.
  final String? sourceShiftId;

  const ShiftRecord({
    this.id,
    this.restaurantId = 'demo_restaurant_001',
    required this.weekId,
    required this.dayLabel,
    required this.daypart,
    required this.status,
    required this.covers,
    required this.forecastCovers,
    required this.ppa,
    required this.cplh,
    required this.splh,
    required this.fohHours,
    required this.bohHours,
    this.theoreticalLaborPct = MeridianConfig.totalTheoreticalLaborPct,
    required this.primaryLever,
    this.scheduledFohHours,
    this.scheduledBohHours,
    this.storedFohLaborDollar,
    this.storedBohLaborDollar,
    this.storedFohLaborPct,
    this.storedBohLaborPct,
    this.storedTotalLaborPct,
    this.storedBlendedWage,
    this.targetProfileId,
    this.targetProfileVersionId,
    this.targetSourceType,
    this.targetCPLH,
    this.targetSPLH,
    this.targetPPA,
    this.targetFohWage,
    this.targetBohWage,
    this.opzFloorCPLH,
    this.opzCeilingCPLH,
    this.theoreticalFohLaborPct,
    this.theoreticalBohLaborPct,
    this.daypartTargetCPLH,
    this.daypartTargetSPLH,
    this.daypartTargetPPA,
    this.daypartOpzFloorCPLH,
    this.daypartOpzCeilingCPLH,
    this.snapshotBlendedWage,
    this.planForecastSales,
    this.businessDate,
    this.businessTimingProfileId,
    this.businessTimingProfileVersionId,
    this.servicePeriodKey,
    this.sourceSystem,
    this.sourceShiftId,
  });

  // ── Dollar helpers — prefer stored source facts; fall back to config wages ─

  double get actualSales => covers * ppa;

  double? get _sourceBackedFohLaborDollar {
    if (storedFohLaborDollar != null) return storedFohLaborDollar;
    if (storedFohLaborPct != null && actualSales > 0) {
      return actualSales * storedFohLaborPct! / 100;
    }
    return null;
  }

  double? get _sourceBackedBohLaborDollar {
    if (storedBohLaborDollar != null) return storedBohLaborDollar;
    if (storedBohLaborPct != null && actualSales > 0) {
      return actualSales * storedBohLaborPct! / 100;
    }
    return null;
  }

  double? get _sourceBackedTotalLaborDollar {
    if (storedFohLaborDollar != null || storedBohLaborDollar != null) {
      return (storedFohLaborDollar ?? 0) + (storedBohLaborDollar ?? 0);
    }
    if (storedTotalLaborPct != null && actualSales > 0) {
      return actualSales * storedTotalLaborPct! / 100;
    }
    final totalHours = fohHours + bohHours;
    if (storedBlendedWage != null && totalHours > 0) {
      return storedBlendedWage! * totalHours;
    }
    final foh = _sourceBackedFohLaborDollar;
    final boh = _sourceBackedBohLaborDollar;
    if (foh != null || boh != null) {
      return (foh ?? 0) + (boh ?? 0);
    }
    return null;
  }

  /// Actual FOH labor dollars: prefer persisted source facts and otherwise
  /// degrade honestly to 0 rather than reconstructing config-wage truth.
  double get fohLaborDollar => _sourceBackedFohLaborDollar ?? 0;

  /// Actual BOH labor dollars: prefer persisted source facts and otherwise
  /// degrade honestly to 0 rather than reconstructing config-wage truth.
  double get bohLaborDollar => _sourceBackedBohLaborDollar ?? 0;

  double get totalLaborDollar => _sourceBackedTotalLaborDollar ?? 0;

  /// True when this row has source-backed total labor truth that can
  /// support an actual labor % reading.
  bool get hasSourceBackedTotalLaborPct =>
      storedTotalLaborPct != null ||
      (_sourceBackedTotalLaborDollar != null && actualSales > 0);

  // ── Labor % — derived from actual dollars and sales ───────────────────────
  double get fohLaborPct =>
      storedFohLaborPct ??
      (actualSales > 0 ? fohLaborDollar / actualSales * 100 : 0);
  double get bohLaborPct =>
      storedBohLaborPct ??
      (actualSales > 0 ? bohLaborDollar / actualSales * 100 : 0);
  double get totalLaborPct =>
      storedTotalLaborPct ??
      (actualSales > 0 ? totalLaborDollar / actualSales * 100 : 0);

  // ── Variance — actual labor % vs theoretical ─────────────────────────────
  double get variancePts => totalLaborPct - theoreticalLaborPct;

  // ── Blended wage — total labor dollars / total hours ─────────────────────
  double get blendedWage {
    if (storedBlendedWage != null) return storedBlendedWage!;
    final totalHours = fohHours + bohHours;
    return totalHours > 0 ? totalLaborDollar / totalHours : 0;
  }

  bool get isClosed => status == 'closed';
  bool get isProjected => status == 'projected';
  bool get isOpen => status == 'open';

  // ── Strict locked-target getters for historical closed-shift truth ────────
  double get lockedTargetPPA => _requireLocked(targetPPA, 'targetPPA');
  double get lockedTargetCPLH => _requireLocked(targetCPLH, 'targetCPLH');
  double get lockedTargetSPLH => _requireLocked(targetSPLH, 'targetSPLH');
  double get lockedTargetFohWage =>
      _requireLocked(targetFohWage, 'targetFohWage');
  double get lockedTargetBohWage =>
      _requireLocked(targetBohWage, 'targetBohWage');
  double get lockedTheoreticalFohLaborPct =>
      _requireLocked(theoreticalFohLaborPct, 'theoreticalFohLaborPct');
  double get lockedTheoreticalBohLaborPct =>
      _requireLocked(theoreticalBohLaborPct, 'theoreticalBohLaborPct');

  static double _requireLocked(double? value, String field) {
    if (value == null) {
      throw StateError(
        'ShiftRecord.$field is null — locked target field must be '
        'backfilled before reading historical truth.',
      );
    }
    return value;
  }

  // ── Actual-volume model hours (Jim Taylor Ch. 10) ─────────────────────────
  // For closed shifts: how many hours the model says you should have used
  // given the actual volume that walked in the door.

  /// FOH model hours based on actual covers and locked target CPLH.
  int get modelFohHours => LaborModel.modelFohHours(covers, lockedTargetCPLH);

  /// BOH model hours based on actual sales and locked target SPLH.
  /// Uses actual sales directly — never derives from target PPA.
  int get modelBohHours =>
      LaborModel.modelBohHoursFromSales(actualSales, lockedTargetSPLH);

  /// Returns a copy with locked target fields filled from the given defaults
  /// where the original fields are null. Preserves all existing non-null values.
  ShiftRecord withLockedTargetDefaults({
    required double defaultTargetCPLH,
    required double defaultTargetSPLH,
    required double defaultTargetPPA,
    required double defaultFohWage,
    required double defaultBohWage,
    required double defaultOpzFloorCPLH,
    required double defaultOpzCeilingCPLH,
    required double defaultTheoreticalFohLaborPct,
    required double defaultTheoreticalBohLaborPct,
    String defaultTargetProfileId = 'demo_static_locked_target',
    String defaultTargetProfileVersionId = 'demo_static_locked_target_v1',
    String defaultTargetSourceType = 'static_demo_locked_target',
  }) {
    return ShiftRecord(
      id: id,
      restaurantId: restaurantId,
      weekId: weekId,
      dayLabel: dayLabel,
      daypart: daypart,
      status: status,
      covers: covers,
      forecastCovers: forecastCovers,
      ppa: ppa,
      cplh: cplh,
      splh: splh,
      fohHours: fohHours,
      bohHours: bohHours,
      theoreticalLaborPct: theoreticalLaborPct,
      primaryLever: primaryLever,
      scheduledFohHours: scheduledFohHours,
      scheduledBohHours: scheduledBohHours,
      storedFohLaborDollar: storedFohLaborDollar,
      storedBohLaborDollar: storedBohLaborDollar,
      storedFohLaborPct: storedFohLaborPct,
      storedBohLaborPct: storedBohLaborPct,
      storedTotalLaborPct: storedTotalLaborPct,
      storedBlendedWage: storedBlendedWage,
      targetProfileId: targetProfileId ?? defaultTargetProfileId,
      targetProfileVersionId:
          targetProfileVersionId ?? defaultTargetProfileVersionId,
      targetSourceType: targetSourceType ?? defaultTargetSourceType,
      targetCPLH: targetCPLH ?? defaultTargetCPLH,
      targetSPLH: targetSPLH ?? defaultTargetSPLH,
      targetPPA: targetPPA ?? defaultTargetPPA,
      targetFohWage: targetFohWage ?? defaultFohWage,
      targetBohWage: targetBohWage ?? defaultBohWage,
      opzFloorCPLH: opzFloorCPLH ?? defaultOpzFloorCPLH,
      opzCeilingCPLH: opzCeilingCPLH ?? defaultOpzCeilingCPLH,
      theoreticalFohLaborPct:
          theoreticalFohLaborPct ?? defaultTheoreticalFohLaborPct,
      theoreticalBohLaborPct:
          theoreticalBohLaborPct ?? defaultTheoreticalBohLaborPct,
      // Per-Daypart V1 (Slice 1): per-period stamps are preserved if
      // already populated. We do NOT fall through to defaults here —
      // null is the honest signal that the cycle had no per-period row
      // for the shift's period (Gap 42 fallback). Substituting whole-day
      // defaults would violate Design Rule 2.
      daypartTargetCPLH: daypartTargetCPLH,
      daypartTargetSPLH: daypartTargetSPLH,
      daypartTargetPPA: daypartTargetPPA,
      daypartOpzFloorCPLH: daypartOpzFloorCPLH,
      daypartOpzCeilingCPLH: daypartOpzCeilingCPLH,
      snapshotBlendedWage: snapshotBlendedWage,
      planForecastSales: planForecastSales,
      businessDate: businessDate,
      businessTimingProfileId: businessTimingProfileId,
      businessTimingProfileVersionId: businessTimingProfileVersionId,
      servicePeriodKey: servicePeriodKey,
      sourceSystem: sourceSystem,
      sourceShiftId: sourceShiftId,
    );
  }

  /// Normalized lever id: lowercase underscore form of [primaryLever].
  /// "CPLH_DOWN" → "cplh_down", "ON_MODEL" → "on_model".
  String get normalizedLeverId => primaryLever.toLowerCase();

  String get daypartLabel {
    switch (daypart) {
      case 'lunch':
        return 'Lunch';
      case 'dinner':
        return 'Dinner';
      case 'late_night':
        return 'Late Night';
      default:
        return daypart;
    }
  }

  // ── SQLite serialization ──────────────────────────────────────────────────

  Map<String, dynamic> toMap() => {
    'id': id,
    'restaurant_id': restaurantId,
    'week_id': weekId,
    'day_label': dayLabel,
    'daypart': daypart,
    'status': status,
    'covers': covers,
    'forecast_covers': forecastCovers,
    'ppa': ppa,
    'cplh': cplh,
    'splh': splh,
    'blended_wage': storedBlendedWage ?? blendedWage,
    'foh_hours': fohHours,
    'boh_hours': bohHours,
    'foh_labor_pct': storedFohLaborPct ?? fohLaborPct,
    'boh_labor_pct': storedBohLaborPct ?? bohLaborPct,
    'total_labor_pct': storedTotalLaborPct ?? totalLaborPct,
    'theoretical_labor_pct': theoreticalLaborPct,
    'variance_pts': variancePts,
    'primary_lever': primaryLever,
    // Phase 3 source-fact columns
    'scheduled_foh_hours': scheduledFohHours,
    'scheduled_boh_hours': scheduledBohHours,
    'foh_labor_dollar': storedFohLaborDollar,
    'boh_labor_dollar': storedBohLaborDollar,
    'target_profile_id': targetProfileId,
    'target_profile_version_id': targetProfileVersionId,
    'target_source_type': targetSourceType,
    'target_cplh': targetCPLH,
    'target_splh': targetSPLH,
    'target_ppa': targetPPA,
    'target_foh_wage': targetFohWage,
    'target_boh_wage': targetBohWage,
    'opz_floor_cplh': opzFloorCPLH,
    'opz_ceiling_cplh': opzCeilingCPLH,
    'theoretical_foh_labor_pct': theoreticalFohLaborPct,
    'theoretical_boh_labor_pct': theoreticalBohLaborPct,
    // Per-Daypart V1 (Slice 1) — per-period locked target stamps.
    'daypart_target_cplh': daypartTargetCPLH,
    'daypart_target_splh': daypartTargetSPLH,
    'daypart_target_ppa': daypartTargetPPA,
    'daypart_opz_floor_cplh': daypartOpzFloorCPLH,
    'daypart_opz_ceiling_cplh': daypartOpzCeilingCPLH,
    'snapshot_blended_wage': snapshotBlendedWage,
    'business_date': businessDate,
    'business_timing_profile_id': businessTimingProfileId,
    'business_timing_profile_version_id': businessTimingProfileVersionId,
    'service_period_key': servicePeriodKey,
    'source_system': sourceSystem,
    'source_shift_id': sourceShiftId,
  };

  factory ShiftRecord.fromMap(Map<String, dynamic> m) => ShiftRecord(
    id: m['id'] as int?,
    restaurantId: (m['restaurant_id'] as String?) ?? 'demo_restaurant_001',
    weekId: m['week_id'] as String,
    dayLabel: m['day_label'] as String,
    daypart: m['daypart'] as String,
    status: m['status'] as String,
    covers: m['covers'] as int,
    forecastCovers: m['forecast_covers'] as int,
    ppa: (m['ppa'] as num).toDouble(),
    cplh: (m['cplh'] as num).toDouble(),
    splh: (m['splh'] as num).toDouble(),
    fohHours: m['foh_hours'] as int,
    bohHours: m['boh_hours'] as int,
    theoreticalLaborPct: (m['theoretical_labor_pct'] as num).toDouble(),
    primaryLever: m['primary_lever'] as String,
    scheduledFohHours: m['scheduled_foh_hours'] as int?,
    scheduledBohHours: m['scheduled_boh_hours'] as int?,
    storedBlendedWage: (m['blended_wage'] as num?)?.toDouble(),
    storedFohLaborPct: (m['foh_labor_pct'] as num?)?.toDouble(),
    storedBohLaborPct: (m['boh_labor_pct'] as num?)?.toDouble(),
    storedTotalLaborPct: (m['total_labor_pct'] as num?)?.toDouble(),
    storedFohLaborDollar: (m['foh_labor_dollar'] as num?)?.toDouble(),
    storedBohLaborDollar: (m['boh_labor_dollar'] as num?)?.toDouble(),
    targetProfileId: m['target_profile_id'] as String?,
    targetProfileVersionId: m['target_profile_version_id'] as String?,
    targetSourceType: m['target_source_type'] as String?,
    targetCPLH: (m['target_cplh'] as num?)?.toDouble(),
    targetSPLH: (m['target_splh'] as num?)?.toDouble(),
    targetPPA: (m['target_ppa'] as num?)?.toDouble(),
    targetFohWage: (m['target_foh_wage'] as num?)?.toDouble(),
    targetBohWage: (m['target_boh_wage'] as num?)?.toDouble(),
    opzFloorCPLH: (m['opz_floor_cplh'] as num?)?.toDouble(),
    opzCeilingCPLH: (m['opz_ceiling_cplh'] as num?)?.toDouble(),
    theoreticalFohLaborPct: (m['theoretical_foh_labor_pct'] as num?)
        ?.toDouble(),
    theoreticalBohLaborPct: (m['theoretical_boh_labor_pct'] as num?)
        ?.toDouble(),
    daypartTargetCPLH: (m['daypart_target_cplh'] as num?)?.toDouble(),
    daypartTargetSPLH: (m['daypart_target_splh'] as num?)?.toDouble(),
    daypartTargetPPA: (m['daypart_target_ppa'] as num?)?.toDouble(),
    daypartOpzFloorCPLH:
        (m['daypart_opz_floor_cplh'] as num?)?.toDouble(),
    daypartOpzCeilingCPLH:
        (m['daypart_opz_ceiling_cplh'] as num?)?.toDouble(),
    snapshotBlendedWage: (m['snapshot_blended_wage'] as num?)?.toDouble(),
    businessDate: m['business_date'] as String?,
    businessTimingProfileId: m['business_timing_profile_id'] as String?,
    businessTimingProfileVersionId:
        m['business_timing_profile_version_id'] as String?,
    servicePeriodKey: m['service_period_key'] as String?,
    sourceSystem: m['source_system'] as String?,
    sourceShiftId: m['source_shift_id'] as String?,
  );
}
