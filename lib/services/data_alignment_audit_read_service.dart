/// Dev-only diagnostic read service backing [DataAlignmentAuditPanel].
///
/// Phase 7.55r item 4 (scope expanded 2026-04-24):
///   - Tier 1 (boundary hygiene): audit-panel widget no longer imports
///     SQLite repositories directly; all reads flow through this service.
///   - Tier 2 (drift detection): this service computes cross-section
///     drift-check pairs comparing conceptually-one metrics that should be
///     equal across authority surfaces per q-lane Rules 2 and 3.
///
/// Phase 7.56c.1 (this slice): the audit also produces grouped
/// [DataAlignmentAuditCheck] coverage so the panel can answer
///   1. Where did the live / actual value come from?
///   2. Where did the target / comparison value come from?
/// across the full Plan + Benchmark surface listed in
/// `docs/phases/7_56/phase_7_56c_data_alignment_audit_plan_benchmark_coverage.md`.
/// The 9 existing q-lane numeric drift checks are kept untouched; the
/// new audit checks are additive grouped coverage.
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
import '../data/restaurant_timing_config_read_service.dart';
import '../data/schedule_plan_read_service.dart';
import '../data/shift_service.dart';
import '../data/wage_standard_context_service.dart';
import '../data/weekly_plan_snapshot_service.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/benchmark_selection_summary.dart';
import '../domain/models/schedule_distribution_weights.dart';
import '../domain/models/schedule_plan.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/models/target_cycle.dart';
import '../domain/models/wage_standard_context.dart';
import '../domain/models/weekly_plan_snapshot.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../domain/services/weekly_plan_snapshot_schedule_plan_projector.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_benchmark_selection_summary_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../models/data_alignment_audit_check.dart';
import '../models/data_alignment_audit_provenance.dart';
import '../models/data_alignment_audit_snapshot.dart';
import '../models/data_alignment_drift_check.dart';
import '../models/shift_dashboard_read_model.dart';
import '../models/shift_record.dart';
import '../models/week_data.dart';
import 'daypart_plan_allocator.dart';

class DataAlignmentAuditReadService {
  static final DataAlignmentAuditReadService instance =
      DataAlignmentAuditReadService._();

  DataAlignmentAuditReadService._();

  /// Tolerances per metric family.
  static const double _rateTolerance = 0.005; // CPLH
  static const double _splhTolerance = 0.01; // SPLH (dollar-scale rate)
  static const double _pctTolerance = 0.01; // theoretical labor %
  static const double _dollarTolerance = 0.01; // wages, PPA, blended wage
  static const double _bigDollarTolerance = 0.50; // sales, labor dollars

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
    //
    // Phase 7.55r item 4 Tier 3: read the snapshot once here and project
    // both the plan and the provenance from the same instance so plan
    // values and provenance rows cannot disagree.
    final snapshot = await _safeLoad(() =>
        WeeklyPlanSnapshotService.instance.getExistingCurrentWeekSnapshot());

    final SchedulePlan? plan = snapshot == null
        ? null
        : WeeklyPlanSnapshotSchedulePlanProjector.project(snapshot);

    // Load the linked target cycle so the provenance row can surface
    // effective + calibration windows. Null when missing or deactivated.
    TargetCycle? targetCycle;
    if (snapshot != null) {
      targetCycle = await _safeLoad(() => SqliteTargetCycleRepository.instance
          .getCycleById(snapshot.targetCycleId));
    }

    final provenance = _buildProvenance(
      snapshot: snapshot,
      targetCycle: targetCycle,
    );

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

    // Phase 7.56c.1: load the active cycle's benchmark-selection summary.
    //
    // The summary may legitimately be missing on older bootstraps that
    // pre-date `7.56b`. We distinguish "table not available" (catch the
    // exception → unavailable) from "table available but row missing"
    // (return null → drifted) so the panel renders honestly.
    BenchmarkSelectionSummary? benchmarkSelectionSummary;
    var benchmarkSelectionSummaryTableAvailable = true;
    if (targetCycle != null) {
      try {
        benchmarkSelectionSummary =
            await SqliteBenchmarkSelectionSummaryRepository.instance
                .getByTargetCycleId(targetCycle.cycleId);
      } catch (_) {
        benchmarkSelectionSummaryTableAvailable = false;
      }
    } else {
      // No cycle → summary lookup is structurally unavailable.
      benchmarkSelectionSummaryTableAvailable = false;
    }

    // Phase 7.56c.1: full-week shifts + timing definitions + distribution
    // weights are needed to recompute the daypart-allocator output the
    // Variance Full Week non-closed rows must align to. We only load
    // these when a locked snapshot exists — otherwise the daypart audit
    // checks degrade to unavailable rather than risk auto-generating a
    // snapshot through `getFullWeekShifts` for the current week.
    List<ShiftRecord>? fullWeekShifts;
    List<ServicePeriodDefinition>? servicePeriodDefinitions;
    ScheduleDistributionWeights? distributionWeights;
    if (snapshot != null) {
      final timingConfig = await _safeLoad(() =>
          RestaurantTimingConfigReadService.instance.getActiveTimingConfig());
      servicePeriodDefinitions = timingConfig?.servicePeriodDefinitions ??
          ServicePeriodDefinitionResolver.demoDefinitions;

      distributionWeights = await _safeLoad(() =>
          SchedulePlanReadService.loadDistributionWeights(restaurantId));

      // Use the snapshot's open-shift week id when available so the
      // audit reads the same week ShiftService renders. If we cannot
      // resolve a current weekId, leave fullWeekShifts null so the
      // daypart audit checks render unavailable rather than guessing.
      final currentWeekId = await _safeLoad(
          () => ShiftService.instance.getCurrentWeekId());
      if (currentWeekId != null) {
        fullWeekShifts = await _safeLoad(
            () => ShiftService.instance.getFullWeekShifts(currentWeekId));
      }
    }

    final driftChecks = _computeDriftChecks(
      profile: profile,
      shiftReadModel: shiftReadModel,
      weekData: weekData,
      wageContext: wageContext,
    );

    final auditChecks = computeAuditChecks(
      profile: profile,
      targetCycle: targetCycle,
      snapshot: snapshot,
      plan: plan,
      shiftReadModel: shiftReadModel,
      weekData: weekData,
      benchmarkSelectionSummary: benchmarkSelectionSummary,
      benchmarkSelectionSummaryTableAvailable:
          benchmarkSelectionSummaryTableAvailable,
      fullWeekShifts: fullWeekShifts,
      servicePeriodDefinitions: servicePeriodDefinitions,
      distributionWeights: distributionWeights,
    );

    return DataAlignmentAuditSnapshot(
      profile: profile,
      demandContext: demandContext,
      plan: plan,
      shiftReadModel: shiftReadModel,
      weekData: weekData,
      wageContext: wageContext,
      driftChecks: driftChecks,
      provenance: provenance,
      auditChecks: auditChecks,
    );
  }

  /// Assembles the audit-only provenance readout from the raw
  /// [WeeklyPlanSnapshot] and [TargetCycle] rows.
  ///
  /// Exposed as a static mirror so unit tests can feed synthetic snapshot
  /// + cycle inputs without invoking the full load path.
  static DataAlignmentAuditProvenance buildProvenance({
    required WeeklyPlanSnapshot? snapshot,
    required TargetCycle? targetCycle,
  }) {
    return _buildProvenance(snapshot: snapshot, targetCycle: targetCycle);
  }

  static DataAlignmentAuditProvenance _buildProvenance({
    required WeeklyPlanSnapshot? snapshot,
    required TargetCycle? targetCycle,
  }) {
    if (snapshot == null) {
      return const DataAlignmentAuditProvenance(
        lockedWeek: null,
        targetCycle: null,
      );
    }

    final lockedWeek = DataAlignmentLockedWeekProvenance(
      snapshotId: snapshot.snapshotId,
      weekKey: snapshot.weekKey,
      weekStartDate: snapshot.weekStartDate,
      weekEndDate: snapshot.weekEndDate,
      targetCycleId: snapshot.targetCycleId,
      generatedAt: snapshot.generatedAt,
      lockedAt: snapshot.lockedAt,
    );

    final cycleShape = targetCycle == null
        ? null
        : DataAlignmentTargetCycleProvenance(
            cycleId: targetCycle.cycleId,
            sourceLabel: targetCycle.source.label,
            effectiveStart: targetCycle.effectiveStart,
            effectiveEnd: targetCycle.effectiveEnd,
            calibrationWindowStart: targetCycle.calibrationWindowStart,
            calibrationWindowEnd: targetCycle.calibrationWindowEnd,
          );

    return DataAlignmentAuditProvenance(
      lockedWeek: lockedWeek,
      targetCycle: cycleShape,
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

  // ─── Phase 7.56c.1 audit checks ──────────────────────────────────────────
  //
  // Pure aggregation of the new grouped audit coverage. No I/O — every
  // input arrives pre-resolved so unit tests can drive synthetic cases
  // without invoking the SQLite bootstrap.

  /// Pure computation of grouped audit checks.
  ///
  /// Each section gracefully degrades when its inputs are missing:
  /// missing data renders unavailable, never false drift. The phase doc
  /// explicitly forbids treating live actuals vs targets as drift, so
  /// the live-actuals group only does presence / source-label checks.
  static List<DataAlignmentAuditCheck> computeAuditChecks({
    required ActiveTargetProfile? profile,
    required TargetCycle? targetCycle,
    required WeeklyPlanSnapshot? snapshot,
    required SchedulePlan? plan,
    required ShiftDashboardReadModel? shiftReadModel,
    required WeekData? weekData,
    required BenchmarkSelectionSummary? benchmarkSelectionSummary,
    required bool benchmarkSelectionSummaryTableAvailable,
    required List<ShiftRecord>? fullWeekShifts,
    required List<ServicePeriodDefinition>? servicePeriodDefinitions,
    required ScheduleDistributionWeights? distributionWeights,
  }) {
    final out = <DataAlignmentAuditCheck>[];
    out.addAll(_liveActualsChecks(
      shiftReadModel: shiftReadModel,
      weekData: weekData,
    ));
    out.addAll(_benchmarkAuthorityChecks(
      profile: profile,
      targetCycle: targetCycle,
      benchmarkSelectionSummary: benchmarkSelectionSummary,
      summaryTableAvailable: benchmarkSelectionSummaryTableAvailable,
    ));
    out.addAll(_benchmarkRuntimeChecks(
      profile: profile,
      shiftReadModel: shiftReadModel,
      weekData: weekData,
    ));
    out.addAll(_planLockedProjectionChecks(
      profile: profile,
      snapshot: snapshot,
      plan: plan,
    ));
    out.addAll(_planRuntimeChecks(
      snapshot: snapshot,
      shiftReadModel: shiftReadModel,
      weekData: weekData,
      fullWeekShifts: fullWeekShifts,
      servicePeriodDefinitions: servicePeriodDefinitions,
      distributionWeights: distributionWeights,
    ));
    return out;
  }

  // ── Group: live / actual provenance ──────────────────────────────────────
  //
  // Per the 7.56c.1 phase doc, live actuals must NOT be compared
  // numerically against targets — operational variance is not
  // architectural drift. These are presence / source-label checks only:
  // aligned when the runtime read model is exposing the value, and
  // unavailable when the read model is missing (no open shift, no
  // locked plan, etc.).

  static List<DataAlignmentAuditCheck> _liveActualsChecks({
    required ShiftDashboardReadModel? shiftReadModel,
    required WeekData? weekData,
  }) {
    final out = <DataAlignmentAuditCheck>[];

    const shiftSource = 'ShiftRecord/OpenShiftSnapshot';
    out.add(DataAlignmentAuditCheck.presence(
      groupId: DataAlignmentAuditGroup.liveActuals,
      label: 'Shift actual covers',
      actualLabel: shiftReadModel == null ? null : shiftSource,
    ));
    out.add(DataAlignmentAuditCheck.presence(
      groupId: DataAlignmentAuditGroup.liveActuals,
      label: 'Shift actual sales',
      actualLabel: shiftReadModel == null ? null : shiftSource,
    ));
    out.add(DataAlignmentAuditCheck.presence(
      groupId: DataAlignmentAuditGroup.liveActuals,
      label: 'Shift actual FOH/BOH hours',
      actualLabel: shiftReadModel == null ? null : shiftSource,
    ));
    out.add(DataAlignmentAuditCheck.presence(
      groupId: DataAlignmentAuditGroup.liveActuals,
      label: 'Shift actual blended wage',
      actualLabel: shiftReadModel == null ? null : shiftSource,
    ));

    const wtdSource = 'closed ShiftRecord';
    out.add(DataAlignmentAuditCheck.presence(
      groupId: DataAlignmentAuditGroup.liveActuals,
      label: 'WTD actual covers',
      actualLabel: weekData == null ? null : wtdSource,
    ));
    out.add(DataAlignmentAuditCheck.presence(
      groupId: DataAlignmentAuditGroup.liveActuals,
      label: 'WTD actual sales',
      actualLabel: weekData == null ? null : wtdSource,
    ));
    out.add(DataAlignmentAuditCheck.presence(
      groupId: DataAlignmentAuditGroup.liveActuals,
      label: 'WTD actual FOH/BOH hours',
      actualLabel: weekData == null ? null : wtdSource,
    ));
    out.add(DataAlignmentAuditCheck.presence(
      groupId: DataAlignmentAuditGroup.liveActuals,
      label: 'WTD actual blended wage',
      actualLabel: weekData == null ? null : wtdSource,
    ));

    return out;
  }

  // ── Group: benchmark authority (TargetCycle ↔ ActiveTargetProfile) ──────
  //
  // ActiveTargetProfile is the runtime projection of the locked
  // TargetCycle (`ActiveTargetProfile is a projection of cycle truth,
  // not an independent competing authority`). Each projected field
  // should match its cycle source 1:1, the profile's theoretical
  // formula fields should match their inputs, and the active cycle
  // should carry its benchmark-selection summary when the table is
  // available.

  static List<DataAlignmentAuditCheck> _benchmarkAuthorityChecks({
    required ActiveTargetProfile? profile,
    required TargetCycle? targetCycle,
    required BenchmarkSelectionSummary? benchmarkSelectionSummary,
    required bool summaryTableAvailable,
  }) {
    final out = <DataAlignmentAuditCheck>[];

    out.addAll([
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkAuthority,
        label: 'TargetCycle CPLH -> Profile CPLH',
        expectedValue: targetCycle?.targetCPLH,
        comparedValue: profile?.targetCPLH,
        tolerance: _rateTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkAuthority,
        label: 'TargetCycle SPLH -> Profile SPLH',
        expectedValue: targetCycle?.targetSPLH,
        comparedValue: profile?.targetSPLH,
        tolerance: _splhTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkAuthority,
        label: 'TargetCycle PPA -> Profile PPA',
        expectedValue: targetCycle?.targetPPA,
        comparedValue: profile?.targetPPA,
        tolerance: _dollarTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkAuthority,
        label: 'TargetCycle FOH wage -> Profile FOH wage',
        expectedValue: targetCycle?.fohWage,
        comparedValue: profile?.fohWage,
        tolerance: _dollarTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkAuthority,
        label: 'TargetCycle BOH wage -> Profile BOH wage',
        expectedValue: targetCycle?.bohWage,
        comparedValue: profile?.bohWage,
        tolerance: _dollarTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkAuthority,
        label: 'TargetCycle OPZ floor -> Profile OPZ floor',
        expectedValue: targetCycle?.opzFloorCPLH,
        comparedValue: profile?.opzFloorCPLH,
        tolerance: _rateTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkAuthority,
        label: 'TargetCycle OPZ ceiling -> Profile OPZ ceiling',
        expectedValue: targetCycle?.opzCeilingCPLH,
        comparedValue: profile?.opzCeilingCPLH,
        tolerance: _rateTolerance,
      ),
    ]);

    // Profile's theoretical formulas — recompute against the same
    // inputs and compare to the persisted projection.
    if (profile != null) {
      final expectedFohPct = (profile.targetCPLH > 0 && profile.targetPPA > 0)
          ? profile.fohWage / (profile.targetCPLH * profile.targetPPA) * 100
          : null;
      final expectedBohPct = profile.targetSPLH > 0
          ? profile.bohWage / profile.targetSPLH * 100
          : null;
      final expectedTotalPct = (expectedFohPct != null && expectedBohPct != null)
          ? expectedFohPct + expectedBohPct
          : null;
      final expectedBlendedWage = ActiveTargetProfile.computeTargetBlendedWage(
        targetCPLH: profile.targetCPLH,
        targetSPLH: profile.targetSPLH,
        targetPPA: profile.targetPPA,
        fohWage: profile.fohWage,
        bohWage: profile.bohWage,
      );

      out.addAll([
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.benchmarkAuthority,
          label: 'Profile theoretical FOH % matches formula',
          expectedValue: expectedFohPct,
          comparedValue: profile.theoreticalFohLaborPct,
          tolerance: _pctTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.benchmarkAuthority,
          label: 'Profile theoretical BOH % matches formula',
          expectedValue: expectedBohPct,
          comparedValue: profile.theoreticalBohLaborPct,
          tolerance: _pctTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.benchmarkAuthority,
          label: 'Profile theoretical total % = FOH % + BOH %',
          expectedValue: expectedTotalPct,
          comparedValue: profile.theoreticalLaborPct,
          tolerance: _pctTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.benchmarkAuthority,
          label: 'Profile target blended wage matches shared formula',
          expectedValue: expectedBlendedWage,
          comparedValue: profile.targetBlendedWage,
          tolerance: _dollarTolerance,
        ),
      ]);
    } else {
      // No profile → mark formula invariants unavailable so the count
      // is honest (the group does not look "all aligned" by omission).
      out.addAll([
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.benchmarkAuthority,
          label: 'Profile theoretical FOH % matches formula',
          expectedValue: null,
          comparedValue: null,
          tolerance: _pctTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.benchmarkAuthority,
          label: 'Profile theoretical BOH % matches formula',
          expectedValue: null,
          comparedValue: null,
          tolerance: _pctTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.benchmarkAuthority,
          label: 'Profile theoretical total % = FOH % + BOH %',
          expectedValue: null,
          comparedValue: null,
          tolerance: _pctTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.benchmarkAuthority,
          label: 'Profile target blended wage matches shared formula',
          expectedValue: null,
          comparedValue: null,
          tolerance: _dollarTolerance,
        ),
      ]);
    }

    // Active cycle's benchmark-selection summary presence.
    //
    // - Table missing entirely (older bootstrap): unavailable.
    // - Table present, no row: drifted (`7.56b` says the active cycle
    //   should carry its summary).
    // - Row present: aligned, with the persisted source-type label
    //   surfaced for quick eyeballing.
    final DriftCheckStatus summaryStatus;
    final String summaryDetail;
    if (!summaryTableAvailable) {
      summaryStatus = DriftCheckStatus.unavailable;
      summaryDetail = '—';
    } else if (benchmarkSelectionSummary == null) {
      summaryStatus = DriftCheckStatus.drifted;
      summaryDetail = 'missing';
    } else {
      summaryStatus = DriftCheckStatus.aligned;
      summaryDetail = benchmarkSelectionSummary.sourceType;
    }
    out.add(DataAlignmentAuditCheck(
      groupId: DataAlignmentAuditGroup.benchmarkAuthority,
      label: 'Active cycle has benchmark-selection summary',
      status: summaryStatus,
      detail: summaryDetail,
    ));

    return out;
  }

  // ── Group: benchmark -> runtime (Shift + WTD) ────────────────────────────
  //
  // Each runtime surface should read benchmark-owned target metrics 1:1
  // from the active profile. These checks parallel the q-lane Rule 2 /
  // Rule 3 numeric drift checks but extend the coverage to every field
  // listed in the 7.56c.1 phase doc (CPLH/SPLH/PPA/wages/OPZ for Shift;
  // CPLH/SPLH/PPA/theoretical %/blended wage for WTD).

  static List<DataAlignmentAuditCheck> _benchmarkRuntimeChecks({
    required ActiveTargetProfile? profile,
    required ShiftDashboardReadModel? shiftReadModel,
    required WeekData? weekData,
  }) {
    final out = <DataAlignmentAuditCheck>[];

    // Shift-side
    out.addAll([
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'Shift target CPLH = Profile CPLH',
        expectedValue: profile?.targetCPLH,
        comparedValue: shiftReadModel?.targetCPLH,
        tolerance: _rateTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'Shift target SPLH = Profile SPLH',
        expectedValue: profile?.targetSPLH,
        comparedValue: shiftReadModel?.targetSPLH,
        tolerance: _splhTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'Shift target PPA = Profile PPA',
        expectedValue: profile?.targetPPA,
        comparedValue: shiftReadModel?.targetPPA,
        tolerance: _dollarTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'Shift FOH wage = Profile FOH wage',
        expectedValue: profile?.fohWage,
        comparedValue: shiftReadModel?.fohWage,
        tolerance: _dollarTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'Shift BOH wage = Profile BOH wage',
        expectedValue: profile?.bohWage,
        comparedValue: shiftReadModel?.bohWage,
        tolerance: _dollarTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'Shift OPZ floor = Profile OPZ floor',
        expectedValue: profile?.opzFloorCPLH,
        comparedValue: shiftReadModel?.opzFloorCPLH,
        tolerance: _rateTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'Shift OPZ ceiling = Profile OPZ ceiling',
        expectedValue: profile?.opzCeilingCPLH,
        comparedValue: shiftReadModel?.opzCeilingCPLH,
        tolerance: _rateTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'Shift theoretical labor % = Profile theoretical %',
        expectedValue: profile?.theoreticalLaborPct,
        comparedValue: shiftReadModel?.targetLaborPct,
        tolerance: _pctTolerance,
      ),
    ]);

    // WTD-side
    out.addAll([
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'WTD target CPLH = Profile CPLH',
        expectedValue: profile?.targetCPLH,
        comparedValue: weekData?.targetCPLH,
        tolerance: _rateTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'WTD target SPLH = Profile SPLH',
        expectedValue: profile?.targetSPLH,
        comparedValue: weekData?.targetSPLH,
        tolerance: _splhTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'WTD target PPA = Profile PPA',
        expectedValue: profile?.targetPPA,
        comparedValue: weekData?.targetPPA,
        tolerance: _dollarTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'WTD theoretical FOH % = Profile FOH %',
        expectedValue: profile?.theoreticalFohLaborPct,
        comparedValue: weekData?.theoreticalFohLaborPct,
        tolerance: _pctTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'WTD theoretical BOH % = Profile BOH %',
        expectedValue: profile?.theoreticalBohLaborPct,
        comparedValue: weekData?.theoreticalBohLaborPct,
        tolerance: _pctTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'WTD theoretical total % = Profile theoretical %',
        expectedValue: profile?.theoreticalLaborPct,
        comparedValue: weekData?.theoreticalLaborPct,
        tolerance: _pctTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.benchmarkRuntime,
        label: 'WTD theoretical blended wage = Profile blended wage',
        expectedValue: profile?.targetBlendedWage,
        comparedValue: weekData?.theoreticalBlendedWage,
        tolerance: _dollarTolerance,
      ),
    ]);

    return out;
  }

  // ── Group: locked plan ↔ projection ──────────────────────────────────────
  //
  // The projector is a deterministic mapping from the locked snapshot
  // to a SchedulePlan; any divergence is a regression. Day-row equality
  // is summarised as one check per metric ("X/N day rows aligned").
  // Reconciliation checks make sure day-row sums add back to the
  // weekly totals. Plan-formula invariants check the locked snapshot
  // values against the active profile's PPA / wages.

  static List<DataAlignmentAuditCheck> _planLockedProjectionChecks({
    required ActiveTargetProfile? profile,
    required WeeklyPlanSnapshot? snapshot,
    required SchedulePlan? plan,
  }) {
    final out = <DataAlignmentAuditCheck>[];

    // Snapshot ↔ projected SchedulePlan weekly totals.
    out.addAll([
      DataAlignmentAuditCheck.intCount(
        groupId: DataAlignmentAuditGroup.planLockedProjection,
        label: 'Snapshot weekly forecast covers = projected plan',
        expectedValue: snapshot?.forecastCovers,
        comparedValue: plan?.forecastCovers,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.planLockedProjection,
        label: 'Snapshot weekly forecast sales = projected plan',
        expectedValue: snapshot?.forecastSales,
        comparedValue: plan?.forecastSales,
        tolerance: _bigDollarTolerance,
      ),
      DataAlignmentAuditCheck.intCount(
        groupId: DataAlignmentAuditGroup.planLockedProjection,
        label: 'Snapshot required FOH hours = projected plan',
        expectedValue: snapshot?.requiredFohHours,
        comparedValue: plan?.requiredFohHours,
      ),
      DataAlignmentAuditCheck.intCount(
        groupId: DataAlignmentAuditGroup.planLockedProjection,
        label: 'Snapshot required BOH hours = projected plan',
        expectedValue: snapshot?.requiredBohHours,
        comparedValue: plan?.requiredBohHours,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.planLockedProjection,
        label: 'Snapshot FOH labor \$ = projected plan',
        expectedValue: snapshot?.theoreticalFohLaborDollars,
        comparedValue: plan?.theoreticalFohLaborDollars,
        tolerance: _bigDollarTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.planLockedProjection,
        label: 'Snapshot BOH labor \$ = projected plan',
        expectedValue: snapshot?.theoreticalBohLaborDollars,
        comparedValue: plan?.theoreticalBohLaborDollars,
        tolerance: _bigDollarTolerance,
      ),
    ]);

    // Day-row equality: snapshot.dayRows[i] vs plan.dayPlans[i].
    if (snapshot != null && plan != null) {
      final n = snapshot.dayRows.length;
      // Length parity is its own check — the other day-row aggregates
      // are bounded by min(snapshot.dayRows.length, plan.dayPlans.length).
      out.add(DataAlignmentAuditCheck.intCount(
        groupId: DataAlignmentAuditGroup.planLockedProjection,
        label: 'Snapshot day-row count = projected plan day-plan count',
        expectedValue: snapshot.dayRows.length,
        comparedValue: plan.dayPlans.length,
      ));

      final compareLen = n < plan.dayPlans.length ? n : plan.dayPlans.length;
      var coversAligned = 0;
      var salesAligned = 0;
      var fohAligned = 0;
      var bohAligned = 0;
      for (var i = 0; i < compareLen; i++) {
        final row = snapshot.dayRows[i];
        final dp = plan.dayPlans[i];
        if (row.forecastCovers == dp.forecastCovers) coversAligned++;
        if ((row.forecastSales - dp.forecastSales).abs() <=
            _bigDollarTolerance) {
          salesAligned++;
        }
        if (row.requiredFohHours == dp.requiredFohHours) fohAligned++;
        if (row.requiredBohHours == dp.requiredBohHours) bohAligned++;
      }
      out.addAll([
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Day-row forecast covers match projection',
          alignedCount: coversAligned,
          total: compareLen,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Day-row forecast sales match projection',
          alignedCount: salesAligned,
          total: compareLen,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Day-row FOH hours match projection',
          alignedCount: fohAligned,
          total: compareLen,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Day-row BOH hours match projection',
          alignedCount: bohAligned,
          total: compareLen,
        ),
      ]);
    } else {
      // Day-row checks degrade to unavailable so the group counts are
      // honest when the snapshot is missing.
      out.addAll([
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Day-row forecast covers match projection',
          alignedCount: 0,
          total: 0,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Day-row forecast sales match projection',
          alignedCount: 0,
          total: 0,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Day-row FOH hours match projection',
          alignedCount: 0,
          total: 0,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Day-row BOH hours match projection',
          alignedCount: 0,
          total: 0,
        ),
      ]);
    }

    // Day-row reconciliation: sum(day rows) == weekly total.
    if (snapshot != null && snapshot.dayRows.isNotEmpty) {
      final sumCovers = snapshot.dayRows
          .fold<int>(0, (s, d) => s + d.forecastCovers);
      final sumSales = snapshot.dayRows
          .fold<double>(0, (s, d) => s + d.forecastSales);
      final sumFoh = snapshot.dayRows
          .fold<int>(0, (s, d) => s + d.requiredFohHours);
      final sumBoh = snapshot.dayRows
          .fold<int>(0, (s, d) => s + d.requiredBohHours);
      out.addAll([
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Sum(day-row covers) = snapshot weekly covers',
          expectedValue: snapshot.forecastCovers,
          comparedValue: sumCovers,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Sum(day-row sales) = snapshot weekly sales',
          expectedValue: snapshot.forecastSales,
          comparedValue: sumSales,
          tolerance: _bigDollarTolerance,
        ),
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Sum(day-row FOH hrs) = snapshot weekly FOH hrs',
          expectedValue: snapshot.requiredFohHours,
          comparedValue: sumFoh,
        ),
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Sum(day-row BOH hrs) = snapshot weekly BOH hrs',
          expectedValue: snapshot.requiredBohHours,
          comparedValue: sumBoh,
        ),
      ]);
    } else {
      out.addAll([
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Sum(day-row covers) = snapshot weekly covers',
          expectedValue: null,
          comparedValue: null,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Sum(day-row sales) = snapshot weekly sales',
          expectedValue: null,
          comparedValue: null,
          tolerance: _bigDollarTolerance,
        ),
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Sum(day-row FOH hrs) = snapshot weekly FOH hrs',
          expectedValue: null,
          comparedValue: null,
        ),
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Sum(day-row BOH hrs) = snapshot weekly BOH hrs',
          expectedValue: null,
          comparedValue: null,
        ),
      ]);
    }

    // Plan formula invariants: snapshot values against the active profile.
    if (snapshot != null && profile != null) {
      final expectedSales = snapshot.forecastCovers * profile.targetPPA;
      final expectedFohDollars =
          snapshot.requiredFohHours * profile.fohWage;
      final expectedBohDollars =
          snapshot.requiredBohHours * profile.bohWage;
      out.addAll([
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Snapshot forecast sales = covers x Profile PPA',
          expectedValue: expectedSales,
          comparedValue: snapshot.forecastSales,
          tolerance: _bigDollarTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Snapshot FOH labor \$ = FOH hrs x Profile FOH wage',
          expectedValue: expectedFohDollars,
          comparedValue: snapshot.theoreticalFohLaborDollars,
          tolerance: _bigDollarTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Snapshot BOH labor \$ = BOH hrs x Profile BOH wage',
          expectedValue: expectedBohDollars,
          comparedValue: snapshot.theoreticalBohLaborDollars,
          tolerance: _bigDollarTolerance,
        ),
      ]);
    } else {
      out.addAll([
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Snapshot forecast sales = covers x Profile PPA',
          expectedValue: null,
          comparedValue: null,
          tolerance: _bigDollarTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Snapshot FOH labor \$ = FOH hrs x Profile FOH wage',
          expectedValue: null,
          comparedValue: null,
          tolerance: _bigDollarTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planLockedProjection,
          label: 'Snapshot BOH labor \$ = BOH hrs x Profile BOH wage',
          expectedValue: null,
          comparedValue: null,
          tolerance: _bigDollarTolerance,
        ),
      ]);
    }

    return out;
  }

  // ── Group: plan -> runtime ───────────────────────────────────────────────
  //
  // Locked plan reaches Shift, WTD, and Variance Full Week through
  // separate read paths. Each path is checked here against the locked
  // snapshot directly.

  static List<DataAlignmentAuditCheck> _planRuntimeChecks({
    required WeeklyPlanSnapshot? snapshot,
    required ShiftDashboardReadModel? shiftReadModel,
    required WeekData? weekData,
    required List<ShiftRecord>? fullWeekShifts,
    required List<ServicePeriodDefinition>? servicePeriodDefinitions,
    required ScheduleDistributionWeights? distributionWeights,
  }) {
    final out = <DataAlignmentAuditCheck>[];

    // Shift current-day plan row alignment.
    WeeklyPlanSnapshotDay? matchingShiftDay;
    if (snapshot != null && shiftReadModel != null) {
      for (final r in snapshot.dayRows) {
        if (r.businessDate == shiftReadModel.businessDate) {
          matchingShiftDay = r;
          break;
        }
      }
    }
    out.addAll([
      DataAlignmentAuditCheck.intCount(
        groupId: DataAlignmentAuditGroup.planRuntime,
        label: 'Shift forecast covers = locked plan day row',
        expectedValue: matchingShiftDay?.forecastCovers,
        comparedValue: shiftReadModel?.forecastCovers,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.planRuntime,
        label: 'Shift forecast sales = locked plan day row',
        expectedValue: matchingShiftDay?.forecastSales,
        comparedValue: shiftReadModel?.forecastSales,
        tolerance: _bigDollarTolerance,
      ),
      DataAlignmentAuditCheck.intCount(
        groupId: DataAlignmentAuditGroup.planRuntime,
        label: 'Shift plan FOH hrs = locked plan day row',
        expectedValue: matchingShiftDay?.requiredFohHours,
        comparedValue: shiftReadModel?.planFohHours,
      ),
      DataAlignmentAuditCheck.intCount(
        groupId: DataAlignmentAuditGroup.planRuntime,
        label: 'Shift plan BOH hrs = locked plan day row',
        expectedValue: matchingShiftDay?.requiredBohHours,
        comparedValue: shiftReadModel?.planBohHours,
      ),
    ]);

    // WTD locked-plan alignment.
    if (snapshot != null && weekData != null) {
      const dayOrder = {
        'Mon': 1,
        'Tue': 2,
        'Wed': 3,
        'Thu': 4,
        'Fri': 5,
        'Sat': 6,
        'Sun': 7,
      };
      final closedDay = weekData.closedDayNumber;
      final wtdRows = snapshot.dayRows
          .where((d) => (dayOrder[d.day] ?? 0) <= closedDay)
          .toList();
      final expectedWtdCovers =
          wtdRows.fold<int>(0, (s, d) => s + d.forecastCovers);
      final expectedWtdFoh =
          wtdRows.fold<int>(0, (s, d) => s + d.requiredFohHours);
      final expectedWtdBoh =
          wtdRows.fold<int>(0, (s, d) => s + d.requiredBohHours);
      final expectedRemainingSales = (weekData.wtdForecastSales != null)
          ? snapshot.forecastSales - weekData.wtdForecastSales!
          : null;

      out.addAll([
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD forecast covers = sum(locked day rows through close)',
          expectedValue: expectedWtdCovers,
          comparedValue: weekData.wtdForecastCovers,
        ),
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD target FOH hrs = sum(locked day rows through close)',
          expectedValue: expectedWtdFoh,
          comparedValue: weekData.targetFohHoursWtd,
        ),
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD target BOH hrs = sum(locked day rows through close)',
          expectedValue: expectedWtdBoh,
          comparedValue: weekData.targetBohHoursWtd,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD remaining sales = locked snapshot - WTD forecast sales',
          expectedValue: expectedRemainingSales,
          comparedValue: weekData.remainingForecastSales,
          tolerance: _bigDollarTolerance,
        ),
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD total-week forecast covers = snapshot weekly covers',
          expectedValue: snapshot.forecastCovers,
          comparedValue: weekData.totalWeekForecastCovers,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD total-week forecast sales = snapshot weekly sales',
          expectedValue: snapshot.forecastSales,
          comparedValue: weekData.totalWeekForecastSales,
          tolerance: _bigDollarTolerance,
        ),
      ]);
    } else {
      out.addAll([
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD forecast covers = sum(locked day rows through close)',
          expectedValue: null,
          comparedValue: null,
        ),
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD target FOH hrs = sum(locked day rows through close)',
          expectedValue: null,
          comparedValue: null,
        ),
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD target BOH hrs = sum(locked day rows through close)',
          expectedValue: null,
          comparedValue: null,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD remaining sales = locked snapshot - WTD forecast sales',
          expectedValue: null,
          comparedValue: null,
          tolerance: _bigDollarTolerance,
        ),
        DataAlignmentAuditCheck.intCount(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD total-week forecast covers = snapshot weekly covers',
          expectedValue: null,
          comparedValue: null,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'WTD total-week forecast sales = snapshot weekly sales',
          expectedValue: null,
          comparedValue: null,
          tolerance: _bigDollarTolerance,
        ),
      ]);
    }

    // Variance Full Week daypart-allocation alignment for non-closed
    // rows. Closed rows preserve their locked target package — we only
    // audit non-closed cells against the shared `DaypartPlanAllocator`
    // output (the same call Schedule uses).
    if (snapshot != null &&
        fullWeekShifts != null &&
        servicePeriodDefinitions != null) {
      final allocByDay = <String, Map<String, DaypartAllocation>>{};
      for (final dayRow in snapshot.dayRows) {
        final allocs = DaypartPlanAllocator.allocate(
          day: dayRow.day,
          dayCovers: dayRow.forecastCovers,
          daySales: dayRow.forecastSales,
          dayFohHours: dayRow.requiredFohHours,
          dayBohHours: dayRow.requiredBohHours,
          definitions: servicePeriodDefinitions,
          distributionWeights: distributionWeights,
        );
        allocByDay[dayRow.day] = {for (final a in allocs) a.daypartId: a};
      }
      var coversAligned = 0;
      var salesAligned = 0;
      var fohAligned = 0;
      var bohAligned = 0;
      var totalCells = 0;
      for (final s in fullWeekShifts) {
        if (s.isClosed) continue; // closed rows keep locked targets
        final alloc = allocByDay[s.dayLabel]?[s.daypart];
        if (alloc == null) continue;
        totalCells++;
        if (s.forecastCovers == alloc.forecastCovers) coversAligned++;
        final shiftSales = s.planForecastSales;
        if (shiftSales != null &&
            (shiftSales - alloc.forecastSales).abs() <=
                _bigDollarTolerance) {
          salesAligned++;
        }
        if (s.fohHours == alloc.requiredFohHours) fohAligned++;
        if (s.bohHours == alloc.requiredBohHours) bohAligned++;
      }
      out.addAll([
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label:
              'Full Week non-closed forecast covers = DaypartPlanAllocator',
          alignedCount: coversAligned,
          total: totalCells,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label:
              'Full Week non-closed forecast sales = DaypartPlanAllocator',
          alignedCount: salesAligned,
          total: totalCells,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'Full Week non-closed FOH hrs = DaypartPlanAllocator',
          alignedCount: fohAligned,
          total: totalCells,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'Full Week non-closed BOH hrs = DaypartPlanAllocator',
          alignedCount: bohAligned,
          total: totalCells,
        ),
      ]);
    } else {
      // Snapshot / shifts / definitions missing → unavailable.
      out.addAll([
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label:
              'Full Week non-closed forecast covers = DaypartPlanAllocator',
          alignedCount: 0,
          total: 0,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label:
              'Full Week non-closed forecast sales = DaypartPlanAllocator',
          alignedCount: 0,
          total: 0,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'Full Week non-closed FOH hrs = DaypartPlanAllocator',
          alignedCount: 0,
          total: 0,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'Full Week non-closed BOH hrs = DaypartPlanAllocator',
          alignedCount: 0,
          total: 0,
        ),
      ]);
    }

    return out;
  }
}
