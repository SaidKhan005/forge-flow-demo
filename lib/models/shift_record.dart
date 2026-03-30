// One shift (one daypart) — stored in SQLite.
// Raw inputs are set at close time; all labor % and dollar fields are derived.

import '../data/meridian_data.dart';

class ShiftRecord {
  final int? id;
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

  /// Identifier for the originating system (e.g. "toast", "demo_pos").
  final String? sourceSystem;

  /// Native shift/check id from the originating system.
  final String? sourceShiftId;

  const ShiftRecord({
    this.id,
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
        'source_system': sourceSystem,
        'source_shift_id': sourceShiftId,
      };

  factory ShiftRecord.fromMap(Map<String, dynamic> m) => ShiftRecord(
        id: m['id'] as int?,
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
        sourceSystem: m['source_system'] as String?,
        sourceShiftId: m['source_shift_id'] as String?,
      );
}
