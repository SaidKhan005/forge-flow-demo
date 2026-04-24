/// Dev-only diagnostic read service backing [DataAlignmentAuditPanel].
///
/// Phase 7.55r item 4 (scope expanded 2026-04-24):
///   - Tier 1 (boundary hygiene): audit-panel widget no longer imports
///     SQLite repositories directly; all reads flow through this service.
///   - Tier 2 (drift detection): this service computes cross-section
///     drift-check pairs comparing conceptually-one metrics that should be
///     equal across authority surfaces per q-lane Rules 2 and 3.
///
/// Not intended for production runtime reads. Reads the persisted
/// [ActiveTargetProfile] directly (no wage-aware bootstrap) so the panel
/// reflects the actual persisted state, not a bootstrap projection.
///
/// The direct repository access lives here, not in the widget. That is
/// the architecturally-correct placement: services may touch repositories;
/// widgets must go through services.
library;

import '../data/demand_forecast_context_service.dart';
import '../data/schedule_plan_read_service.dart';
import '../data/shift_service.dart';
import '../data/wage_standard_context_service.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/wage_standard_context.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../models/data_alignment_audit_snapshot.dart';
import '../models/data_alignment_drift_check.dart';
import '../models/shift_dashboard_read_model.dart';
import '../models/week_data.dart';

class DataAlignmentAuditReadService {
  static final DataAlignmentAuditReadService instance =
      DataAlignmentAuditReadService._();

  DataAlignmentAuditReadService._();

  /// Tolerances per metric family.
  static const double _rateTolerance = 0.005; // CPLH / SPLH
  static const double _pctTolerance = 0.01; // theoretical labor %
  static const double _dollarTolerance = 0.01; // wages, PPA, blended wage

  /// Loads a complete audit snapshot across all authority sections.
  ///
  /// Errors in any individual section are caught and leave that section
  /// null — the audit panel renders "Not loaded" honestly rather than
  /// failing the whole panel.
  Future<DataAlignmentAuditSnapshot> loadSnapshot() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();

    ActiveTargetProfile? profile;
    try {
      // Read raw persisted profile (no bootstrap) for the diagnostic view.
      profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
    } catch (_) {
      profile = null;
    }

    final demandContext = await _safeLoad(() =>
        DemandForecastContextService.instance.getCurrentContext());

    // Read-only current-week locked snapshot — audit panel must mirror
    // the strict authority path used by production Schedule / Shift, not
    // a looser live-resolved fallback (see panel's prior inline comment).
    final plan = await _safeLoad(() => SchedulePlanReadService.instance
        .getExistingCurrentLockedWeeklyPlan());

    final shiftReadModel =
        await _safeLoad(() => ShiftService.instance.getShiftDashboard());

    // Only read WTD when a locked current-week plan already exists.
    // `getLiveWeekToDate()` may legitimately auto-generate a snapshot in
    // production; in the audit panel we want strict authority, so gate it.
    WeekData? weekData;
    if (plan != null) {
      weekData =
          await _safeLoad(() => ShiftService.instance.getLiveWeekToDate());
    }

    final wageContext = await _safeLoad(() =>
        WageStandardContextService.instance.resolve(restaurantId));

    final driftChecks = _computeDriftChecks(
      profile: profile,
      shiftReadModel: shiftReadModel,
      weekData: weekData,
      wageContext: wageContext,
    );

    return DataAlignmentAuditSnapshot(
      profile: profile,
      demandContext: demandContext,
      plan: plan,
      shiftReadModel: shiftReadModel,
      weekData: weekData,
      wageContext: wageContext,
      driftChecks: driftChecks,
    );
  }

  /// Runs [f] and returns the result, or null on any exception.
  ///
  /// The audit panel is a diagnostic surface — a failure in one section
  /// must not propagate and break the rest of the panel.
  Future<T?> _safeLoad<T>(Future<T?> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }

  /// Computes drift checks comparing conceptually-equal metrics across
  /// authority surfaces per q-lane Rules 2 and 3 plus wage-authority
  /// consistency.
  ///
  /// Exposed `@visibleForTesting` via a static mirror so unit tests can
  /// seed synthetic inputs without invoking the full load path.
  List<DataAlignmentDriftCheck> _computeDriftChecks({
    required ActiveTargetProfile? profile,
    required ShiftDashboardReadModel? shiftReadModel,
    required WeekData? weekData,
    required WageStandardContext? wageContext,
  }) {
    return computeDriftChecks(
      profile: profile,
      shiftReadModel: shiftReadModel,
      weekData: weekData,
      wageContext: wageContext,
    );
  }

  /// Pure computation of drift checks — no I/O, no side effects.
  /// Testable in isolation.
  static List<DataAlignmentDriftCheck> computeDriftChecks({
    required ActiveTargetProfile? profile,
    required ShiftDashboardReadModel? shiftReadModel,
    required WeekData? weekData,
    required WageStandardContext? wageContext,
  }) {
    final checks = <DataAlignmentDriftCheck>[];

    // ── Rule 2: Shift reads benchmark targets from ActiveTargetProfile ──
    if (profile != null && shiftReadModel != null) {
      checks.add(DataAlignmentDriftCheck(
        label: 'Shift Target CPLH',
        expectedSource: 'ActiveTargetProfile.targetCPLH',
        comparedSource: 'ShiftDashboardReadModel.targetCPLH',
        expectedValue: profile.targetCPLH,
        comparedValue: shiftReadModel.targetCPLH,
        tolerance: _rateTolerance,
        ruleReference: 'Rule 2',
      ));

      checks.add(DataAlignmentDriftCheck(
        label: 'Shift Target PPA',
        expectedSource: 'ActiveTargetProfile.targetPPA',
        comparedSource: 'ShiftDashboardReadModel.targetPPA',
        expectedValue: profile.targetPPA,
        comparedValue: shiftReadModel.targetPPA,
        tolerance: _dollarTolerance,
        ruleReference: 'Rule 2',
      ));

      checks.add(DataAlignmentDriftCheck(
        label: 'Shift Theoretical Labor %',
        expectedSource: 'ActiveTargetProfile.theoreticalLaborPct',
        comparedSource: 'ShiftDashboardReadModel.targetLaborPct',
        expectedValue: profile.theoreticalLaborPct,
        comparedValue: shiftReadModel.targetLaborPct,
        tolerance: _pctTolerance,
        ruleReference: 'Rule 2',
      ));
    }

    // ── Rule 3: non-closed Variance WTD reads benchmark targets 1:1 ─────
    if (profile != null && weekData != null) {
      checks.add(DataAlignmentDriftCheck(
        label: 'WTD Target CPLH',
        expectedSource: 'ActiveTargetProfile.targetCPLH',
        comparedSource: 'WeekData.targetCPLH',
        expectedValue: profile.targetCPLH,
        comparedValue: weekData.targetCPLH,
        tolerance: _rateTolerance,
        ruleReference: 'Rule 3',
      ));

      checks.add(DataAlignmentDriftCheck(
        label: 'WTD Target PPA',
        expectedSource: 'ActiveTargetProfile.targetPPA',
        comparedSource: 'WeekData.targetPPA',
        expectedValue: profile.targetPPA,
        comparedValue: weekData.targetPPA,
        tolerance: _dollarTolerance,
        ruleReference: 'Rule 3',
      ));

      checks.add(DataAlignmentDriftCheck(
        label: 'WTD Theoretical Labor %',
        expectedSource: 'ActiveTargetProfile.theoreticalLaborPct',
        comparedSource: 'WeekData.theoreticalLaborPct',
        expectedValue: profile.theoreticalLaborPct,
        comparedValue: weekData.theoreticalLaborPct,
        tolerance: _pctTolerance,
        ruleReference: 'Rule 3',
      ));

      checks.add(DataAlignmentDriftCheck(
        label: 'WTD Theoretical Blended Wage',
        expectedSource: 'ActiveTargetProfile.targetBlendedWage',
        comparedSource: 'WeekData.theoreticalBlendedWage',
        expectedValue: profile.targetBlendedWage,
        comparedValue: weekData.theoreticalBlendedWage,
        tolerance: _dollarTolerance,
        ruleReference: 'Rule 3',
      ));
    }

    // ── Wage authority consistency (one wage truth path) ────────────────
    //
    // The resolved wage context should equal the active profile's wages.
    // Only compare when the wage authority reports an available resolved
    // value — an `unavailable` wage context is not a drift, it's a known
    // absence (honest degradation).
    if (profile != null && wageContext != null && wageContext.isAvailable) {
      checks.add(DataAlignmentDriftCheck(
        label: 'FOH Wage authority',
        expectedSource: 'ActiveTargetProfile.fohWage',
        comparedSource: 'WageStandardContext.fohWage',
        expectedValue: profile.fohWage,
        comparedValue: wageContext.fohWage,
        tolerance: _dollarTolerance,
        ruleReference: 'Wage authority',
      ));

      checks.add(DataAlignmentDriftCheck(
        label: 'BOH Wage authority',
        expectedSource: 'ActiveTargetProfile.bohWage',
        comparedSource: 'WageStandardContext.bohWage',
        expectedValue: profile.bohWage,
        comparedValue: wageContext.bohWage,
        tolerance: _dollarTolerance,
        ruleReference: 'Wage authority',
      ));
    }

    return checks;
  }
}
