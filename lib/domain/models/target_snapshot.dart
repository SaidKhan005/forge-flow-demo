// Targets locked at the moment a shift is closed.
//
// Once recorded this snapshot is immutable — values must NOT be re-derived
// from current BaselineData, which changes over time.  The close-shift ingest
// path (Phase 3) creates and persists one TargetSnapshot per closed shift so
// that historical variance analysis always uses the targets that were in force
// at close time.
//
// No UI imports. No database code. No widget code.

class TargetSnapshot {
  // ── Scope ────────────────────────────────────────────────────────────────

  /// Restaurant scope this snapshot was locked for.
  final String restaurantId;

  // ── Profile identity ────────────────────────────────────────────────────

  /// The active target profile id at close time.
  final String? targetProfileId;

  /// The immutable version id locked for this snapshot.
  final String? targetProfileVersionId;

  /// Source provenance locked from the active target profile at close time,
  /// e.g. legacy labels such as 'system_baseline' / 'manager_override' or
  /// cycle-era labels such as 'cycle_recommended' / 'cycle_manager_override'.
  final String? sourceType;

  // ── Rate targets ──────────────────────────────────────────────────────────

  /// Target covers-per-labor-hour for FOH scheduling (Jim Taylor Ch. 5).
  final double targetCPLH;

  /// Target sales-per-labor-hour for BOH scheduling (Jim Taylor Ch. 5).
  final double targetSPLH;

  /// Target price-per-cover / average check target.
  final double targetPPA;

  // ── Wage targets ──────────────────────────────────────────────────────────

  /// FOH blended wage target in force at close time.
  final double fohWage;

  /// BOH blended wage target in force at close time.
  final double bohWage;

  // ── OPZ bounds (Jim Taylor Ch. 11) ───────────────────────────────────────

  /// Lower Optimal Productivity Zone CPLH boundary.
  final double opzFloorCPLH;

  /// Upper Optimal Productivity Zone CPLH boundary.
  final double opzCeilingCPLH;

  // ── Theoretical labor % (Jim Taylor Ch. 9) ───────────────────────────────
  // Pre-computed and stored so this snapshot is self-contained.
  // Formula: fohPct = fohWage / (targetCPLH × targetPPA) × 100
  //          bohPct = bohWage / targetSPLH × 100

  /// Theoretical FOH labor % at target rates.
  final double theoreticalFohLaborPct;

  /// Theoretical BOH labor % at target rates.
  final double theoreticalBohLaborPct;

  /// Total theoretical labor % = theoreticalFohLaborPct + theoreticalBohLaborPct.
  final double theoreticalLaborPct;

  // ── Per-Daypart V1 (Slice 1) — per-period locked target stamps ─────────
  //
  // Populated by `TargetSnapshotBuilder` when the active cycle has a
  // per-period row matching the shift's service period at close time.
  // Nullable — when the cycle has no per-period row (Gap 42 fallback)
  // these stay null and downstream consumers fall back to the whole-day
  // scalar fields above.
  final double? daypartTargetCPLH;
  final double? daypartTargetSPLH;
  final double? daypartTargetPPA;
  final double? daypartOpzFloorCPLH;
  final double? daypartOpzCeilingCPLH;

  const TargetSnapshot({
    this.restaurantId = 'demo_restaurant_001',
    this.targetProfileId,
    this.targetProfileVersionId,
    this.sourceType,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCPLH,
    required this.opzCeilingCPLH,
    required this.theoreticalFohLaborPct,
    required this.theoreticalBohLaborPct,
    required this.theoreticalLaborPct,
    this.daypartTargetCPLH,
    this.daypartTargetSPLH,
    this.daypartTargetPPA,
    this.daypartOpzFloorCPLH,
    this.daypartOpzCeilingCPLH,
  });
}
