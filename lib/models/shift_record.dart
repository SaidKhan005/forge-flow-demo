// One shift (one daypart) — stored in SQLite.
// Raw inputs are set at close time; all labor % and dollar fields are derived.

import '../data/legacy_fixture_data.dart';
import '../services/labor_model.dart';

class ShiftRecord {
  final int? id;
  final String restaurantId;
  final String weekId;              // "2026-W13"
  final String dayLabel;            // "Mon", "Tue", …, "Sun"
  final String daypart;             // "lunch" | "dinner" | "late_night"
  final String status;              // "closed" | "projected"
  final int covers;
  final int forecastCovers;
  final double ppa;
  final double cplh;
  final double splh;
  final int fohHours;
  final int bohHours;
  final double theoreticalLaborPct; // locked at close — snapshot of target at time of shift
  final String primaryLever;        // "COVERS_DOWN", "CPLH_DOWN", …, "ON_MODEL"

  // ── Close-shift source facts (Phase 3 addition) ───────────────────────────
  // All nullable so existing seed/demo constructors compile without changes.

  /// FOH hours on the published schedule for this shift.
  final int? scheduledFohHours;

  /// BOH hours on the published schedule for this shift.
  final int? scheduledBohHours;

  /// Actual FOH labor dollars from the labor system.
  /// When absent, `fohLaborDollar` falls back to `fohHours × MeridianConfig.fohWage`.
  final double? storedFohLaborDollar;

  /// Actual BOH labor dollars from the labor system.
  /// When absent, `bohLaborDollar` falls back to `bohHours × MeridianConfig.bohWage`.
  final double? storedBohLaborDollar;

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

  /// ISO 8601 date string for the business day of this shift (e.g. '2026-03-27').
  /// Nullable for backward compatibility with rows created before 7.55f.
  final String? businessDate;

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
    this.businessDate,
    this.sourceSystem,
    this.sourceShiftId,
  });

  // ── Dollar helpers — prefer stored source facts; fall back to config wages ─

  double get actualSales       => covers * ppa;

  /// Actual FOH labor dollars: stored value when present, else hours × config wage.
  double get fohLaborDollar    => storedFohLaborDollar ?? (fohHours * MeridianConfig.fohWage);

  /// Actual BOH labor dollars: stored value when present, else hours × config wage.
  double get bohLaborDollar    => storedBohLaborDollar ?? (bohHours * MeridianConfig.bohWage);

  double get totalLaborDollar  => fohLaborDollar + bohLaborDollar;

  // ── Labor % — derived from actual dollars and sales ───────────────────────
  double get fohLaborPct   => actualSales > 0
      ? fohLaborDollar  / actualSales * 100 : 0;
  double get bohLaborPct   => actualSales > 0
      ? bohLaborDollar  / actualSales * 100 : 0;
  double get totalLaborPct => actualSales > 0
      ? totalLaborDollar / actualSales * 100 : 0;

  // ── Variance — actual labor % vs theoretical ─────────────────────────────
  double get variancePts => totalLaborPct - theoreticalLaborPct;

  // ── Blended wage — total labor dollars / total hours ─────────────────────
  double get blendedWage {
    final totalHours = fohHours + bohHours;
    return totalHours > 0 ? totalLaborDollar / totalHours : 0;
  }

  bool get isClosed    => status == 'closed';
  bool get isProjected => status == 'projected';
  bool get isOpen      => status == 'open';

  // ── Strict locked-target getters for historical closed-shift truth ────────
  double get lockedTargetPPA => _requireLocked(targetPPA, 'targetPPA');
  double get lockedTargetCPLH => _requireLocked(targetCPLH, 'targetCPLH');
  double get lockedTargetSPLH => _requireLocked(targetSPLH, 'targetSPLH');
  double get lockedTargetFohWage => _requireLocked(targetFohWage, 'targetFohWage');
  double get lockedTargetBohWage => _requireLocked(targetBohWage, 'targetBohWage');
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
  int get modelFohHours =>
      LaborModel.modelFohHours(covers, lockedTargetCPLH);

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
      targetProfileId: targetProfileId ?? defaultTargetProfileId,
      targetProfileVersionId: targetProfileVersionId ?? defaultTargetProfileVersionId,
      targetSourceType: targetSourceType ?? defaultTargetSourceType,
      targetCPLH: targetCPLH ?? defaultTargetCPLH,
      targetSPLH: targetSPLH ?? defaultTargetSPLH,
      targetPPA: targetPPA ?? defaultTargetPPA,
      targetFohWage: targetFohWage ?? defaultFohWage,
      targetBohWage: targetBohWage ?? defaultBohWage,
      opzFloorCPLH: opzFloorCPLH ?? defaultOpzFloorCPLH,
      opzCeilingCPLH: opzCeilingCPLH ?? defaultOpzCeilingCPLH,
      theoreticalFohLaborPct: theoreticalFohLaborPct ?? defaultTheoreticalFohLaborPct,
      theoreticalBohLaborPct: theoreticalBohLaborPct ?? defaultTheoreticalBohLaborPct,
      businessDate: businessDate,
      sourceSystem: sourceSystem,
      sourceShiftId: sourceShiftId,
    );
  }

  /// Normalized lever id: lowercase underscore form of [primaryLever].
  /// "CPLH_DOWN" → "cplh_down", "ON_MODEL" → "on_model".
  String get normalizedLeverId => primaryLever.toLowerCase();

  String get daypartLabel {
    switch (daypart) {
      case 'lunch':      return 'Lunch';
      case 'dinner':     return 'Dinner';
      case 'late_night': return 'Late Night';
      default:           return daypart;
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
        'blended_wage': blendedWage,
        'foh_hours': fohHours,
        'boh_hours': bohHours,
        'foh_labor_pct': fohLaborPct,
        'boh_labor_pct': bohLaborPct,
        'total_labor_pct': totalLaborPct,
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
        'business_date': businessDate,
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
        theoreticalFohLaborPct: (m['theoretical_foh_labor_pct'] as num?)?.toDouble(),
        theoreticalBohLaborPct: (m['theoretical_boh_labor_pct'] as num?)?.toDouble(),
        businessDate: m['business_date'] as String?,
        sourceSystem: m['source_system'] as String?,
        sourceShiftId: m['source_shift_id'] as String?,
      );
}
