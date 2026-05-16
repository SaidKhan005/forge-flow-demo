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

import '../services/demand_forecast_context_service.dart';
import '../services/restaurant_timing_config_read_service.dart';
import '../services/schedule_plan_read_service.dart';
import 'shift_service.dart';
import '../services/wage_standard_context_service.dart';
import '../services/weekly_plan_snapshot_service.dart';
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

    // Load the target cycle so the provenance row can surface effective
    // + calibration windows AND so the benchmark-authority + pool-
    // consistency checks have a cycle to audit.
    //
    // Per-Daypart V1 / Slice 6 — Gap 38 (structural ordering bug) fix.
    // Previously the cycle was only fetched when a locked snapshot
    // existed (`if (snapshot != null)`). That made every TargetCycle ->
    // Profile authority check and the new pool-consistency invariant
    // degrade to "unavailable" for the entire window between cycle
    // creation and the first weekly-plan lock — exactly when an
    // operator most needs the audit to confirm the freshly-recommended
    // cycle is internally consistent. The cycle's existence is
    // independent of whether a weekly plan has been locked yet, so the
    // fetch must be too. When a snapshot exists we still link by its
    // locked `targetCycleId` (the cycle the plan was generated under,
    // which may differ from the now-active cycle after a rollover);
    // otherwise we fall back to the active cycle.
    TargetCycle? targetCycle;
    if (snapshot != null) {
      targetCycle = await _safeLoad(() => SqliteTargetCycleRepository.instance
          .getCycleById(snapshot.targetCycleId));
    } else {
      targetCycle = await _safeLoad(() => SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId));
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
    out.addAll(_poolConsistencyChecks(targetCycle: targetCycle));
    out.addAll(_wageAtLockTimeChecks(snapshot: snapshot));
    // Per-Daypart V1 / Slice 6 (full scope) — the five per-period
    // categories the plan (lines 348-360) requires alongside the three
    // already shipped (pool-consistency, wage-at-lock-time, Gap-38
    // ordering fix). Each degrades honestly when per-period data is
    // absent (informational "no per-period rows — whole-day only";
    // never a false PASS, never a fabricated `0`, never a hard FAIL).
    out.addAll(_perPeriodBenchmarkAuthorityChecks(
      profile: profile,
      targetCycle: targetCycle,
    ));
    out.addAll(_perPeriodShiftRuntimeChecks(
      profile: profile,
      targetCycle: targetCycle,
    ));
    out.addAll(_perPeriodVarianceRuntimeChecks(
      profile: profile,
      targetCycle: targetCycle,
    ));
    out.addAll(_perPeriodLockedPlanReconciliationChecks(
      snapshot: snapshot,
      targetCycle: targetCycle,
    ));
    out.addAll(_perPeriodSumAndActualPresenceChecks(snapshot: snapshot));
    return out;
  }

  // ── Group: pool consistency (Design Rule 4) ──────────────────────────────
  //
  // Per-Daypart V1 / Slice 6. The whole-day pool scalars on the active
  // TargetCycle are a *derived cache* — recomputed inside the cycle
  // write path (`_writeReplacementCycle`) as the cover-weighted rollup
  // of the per-period `target_cycle_dayparts` rows:
  //
  //   pooled_cplh = Σ(cover × cplh) / Σ(cover)   (same shape for SPLH/PPA)
  //   pooled_opz_floor   = min over all period floors  (union floor)
  //   pooled_opz_ceiling = max over all period ceilings (union ceiling)
  //
  // No code path outside the write path may mutate the parent pool
  // fields directly. A future override UI that edited only the pool
  // (plan Gap 14) would silently break the per-period doctrine. This
  // check recomputes the rollup from the persisted child rows and
  // compares it against the persisted parent scalars; drift means the
  // pool diverged from its periods.
  //
  // Gap 42 path: a cycle written under the insufficient-recommendation
  // fallback persists *no* per-period child rows. The pool scalars are
  // then MeridianConfig whole-day defaults, not a rollup. There is
  // nothing to reconcile, so every check degrades to `unavailable`
  // (honest "no per-period rows" — never false drift). Per Design
  // Rule 2 the empty list is a legitimate state, not a sentinel.

  static List<DataAlignmentAuditCheck> _poolConsistencyChecks({
    required TargetCycle? targetCycle,
  }) {
    final out = <DataAlignmentAuditCheck>[];

    const labels = <String>[
      'Pool CPLH = cover-weighted Σ(period CPLH)',
      'Pool SPLH = cover-weighted Σ(period SPLH)',
      'Pool PPA = cover-weighted Σ(period PPA)',
      'Pool OPZ floor = min(period OPZ floors)',
      'Pool OPZ ceiling = max(period OPZ ceilings)',
    ];

    // Cycle missing entirely, or Gap 42 fallback (no child rows): the
    // rollup is undefined. Emit one unavailable row per invariant so
    // the group count is honest (it must NOT look "all aligned" by
    // omitting the checks).
    if (targetCycle == null || targetCycle.dayparts.isEmpty) {
      for (final label in labels) {
        out.add(DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.poolConsistency,
          label: label,
          expectedValue: null,
          comparedValue: null,
          tolerance: _rateTolerance,
        ));
      }
      return out;
    }

    final pool = TargetCycleDaypartPool.fromDayparts(targetCycle.dayparts);

    out.addAll([
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.poolConsistency,
        label: labels[0],
        expectedValue: pool.targetCPLH,
        comparedValue: targetCycle.targetCPLH,
        tolerance: _rateTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.poolConsistency,
        label: labels[1],
        expectedValue: pool.targetSPLH,
        comparedValue: targetCycle.targetSPLH,
        tolerance: _splhTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.poolConsistency,
        label: labels[2],
        expectedValue: pool.targetPPA,
        comparedValue: targetCycle.targetPPA,
        tolerance: _dollarTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.poolConsistency,
        label: labels[3],
        expectedValue: pool.opzFloorCPLH,
        comparedValue: targetCycle.opzFloorCPLH,
        tolerance: _rateTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.poolConsistency,
        label: labels[4],
        expectedValue: pool.opzCeilingCPLH,
        comparedValue: targetCycle.opzCeilingCPLH,
        tolerance: _rateTolerance,
      ),
    ]);

    return out;
  }

  // ── Group: wage-at-lock-time provenance (Design Rule 8) ──────────────────
  //
  // Per-Daypart V1 / Slice 6. The locked weekly plan's theoretical
  // labor dollars were computed from the wages *as they were at lock
  // time*, stamped into `weekly_plan_snapshots.wage_at_lock_time_json`.
  // After the week locks the operator may change the wage mix; the
  // current `ActiveTargetProfile` wages then no longer reproduce the
  // locked dollars. Any audit check that reconciles a locked dollar
  // value MUST use the lock-time stamp, not the live profile wage
  // (Design Rule 8) — otherwise a legitimate post-lock wage edit shows
  // up as false plan drift.
  //
  // These checks recompute the snapshot's locked FOH/BOH labor dollars
  // and blended wage from the lock-time stamp × the locked required
  // hours and confirm they reproduce the persisted locked dollars.
  // Missing snapshot, or a legacy snapshot with no stamp (written
  // before Slice 1), degrades to `unavailable` (honest absence — never
  // false drift, never a sentinel `0`).

  static List<DataAlignmentAuditCheck> _wageAtLockTimeChecks({
    required WeeklyPlanSnapshot? snapshot,
  }) {
    final out = <DataAlignmentAuditCheck>[];

    const fohLabel = 'Locked FOH \$ = lock-time FOH wage x locked FOH hrs';
    const bohLabel = 'Locked BOH \$ = lock-time BOH wage x locked BOH hrs';
    const blendedLabel =
        'Lock-time blended wage = locked \$ / locked hrs';
    const stampLabel = 'Snapshot carries wage-at-lock-time stamp';

    final wages = snapshot?.wageAtLockTime;
    if (snapshot == null || wages == null) {
      // Presence row: legacy snapshot (pre-Slice-1) or none at all.
      // Unavailable, not drifted — the absence is honest, and a missing
      // stamp on an older snapshot is not architectural drift.
      out.add(DataAlignmentAuditCheck.presence(
        groupId: DataAlignmentAuditGroup.wageAtLockTime,
        label: stampLabel,
        actualLabel: null,
      ));
      for (final label in [fohLabel, bohLabel, blendedLabel]) {
        out.add(DataAlignmentAuditCheck.numeric(
          groupId: DataAlignmentAuditGroup.wageAtLockTime,
          label: label,
          expectedValue: null,
          comparedValue: null,
          tolerance: _bigDollarTolerance,
        ));
      }
      return out;
    }

    out.add(DataAlignmentAuditCheck.presence(
      groupId: DataAlignmentAuditGroup.wageAtLockTime,
      label: stampLabel,
      actualLabel: 'weekly_plan_snapshots.wage_at_lock_time_json',
    ));

    // Locked dollars are reconciled against the LOCK-TIME stamp, never
    // the live ActiveTargetProfile wages (Design Rule 8).
    final expectedFohDollars = snapshot.requiredFohHours * wages.fohWage;
    final expectedBohDollars = snapshot.requiredBohHours * wages.bohWage;

    out.addAll([
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.wageAtLockTime,
        label: fohLabel,
        expectedValue: expectedFohDollars,
        comparedValue: snapshot.theoreticalFohLaborDollars,
        tolerance: _bigDollarTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: DataAlignmentAuditGroup.wageAtLockTime,
        label: bohLabel,
        expectedValue: expectedBohDollars,
        comparedValue: snapshot.theoreticalBohLaborDollars,
        tolerance: _bigDollarTolerance,
      ),
    ]);

    // Blended wage cross-check: the stamped blended wage should equal
    // the locked total labor dollars divided by the locked total
    // required hours. Degenerate zero-hours plans degrade to
    // unavailable rather than dividing by zero (Design Rule 2 — zero
    // hours is "no plan", not a sentinel-driven false drift).
    final totalHours = snapshot.totalRequiredHours;
    final double? observedBlended = totalHours > 0
        ? snapshot.theoreticalTotalLaborDollars / totalHours
        : null;
    out.add(DataAlignmentAuditCheck.numeric(
      groupId: DataAlignmentAuditGroup.wageAtLockTime,
      label: blendedLabel,
      expectedValue: totalHours > 0 ? wages.blendedWage : null,
      comparedValue: observedBlended,
      tolerance: _dollarTolerance,
    ));

    return out;
  }

  // ── Per-period Slice 6 (full scope) tolerances ───────────────────────────
  //
  // Per-period required hours are model-derived (covers / rate) and the
  // snapshot day-row hours are rounded integers; the largest-remainder
  // allocator can leave a ±1h gap per period. A 1.0h tolerance catches
  // genuine reconciliation drift without flagging honest rounding.
  static const double _hoursTolerance = 1.0;

  // ── Group: per-period benchmark authority (Slice 6, full scope) ─────────
  //
  // Plan Slice 6 category 1. `ActiveTargetProfile` is the runtime
  // projection of the locked `TargetCycle`; the per-period rows must
  // project 1:1 the same way the whole-day scalars already do
  // (`_benchmarkAuthorityChecks`). Two invariants:
  //
  //   (a) For every period the cycle carries, the profile's
  //       `daypartFor(p)` rate targets equal the cycle's
  //       `daypartFor(p)` rate targets (CPLH / SPLH / PPA / OPZ band).
  //   (b) Design Rule 4: the profile's whole-day scalars equal the
  //       cover-weighted Σ of the per-period rows
  //       (`TargetCycleDaypartPool.fromDayparts`) — the per-period rows
  //       are the authority, the pool is their honest rollup.
  //
  // Gap 42 honest degradation: a cycle written under the
  // insufficient-recommendation fallback carries NO per-period child
  // rows. There is nothing to project, so the group emits a single
  // informational presence row ("no per-period cycle rows — whole-day
  // only", unavailable) plus unavailable rollup rows — never a false
  // PASS, never a fabricated `0`, never a hard FAIL.

  static List<DataAlignmentAuditCheck> _perPeriodBenchmarkAuthorityChecks({
    required ActiveTargetProfile? profile,
    required TargetCycle? targetCycle,
  }) {
    const group = DataAlignmentAuditGroup.perPeriodBenchmarkAuthority;
    final out = <DataAlignmentAuditCheck>[];

    if (targetCycle == null || targetCycle.dayparts.isEmpty) {
      out.add(DataAlignmentAuditCheck.presence(
        groupId: group,
        label: 'Per-period cycle rows present',
        actualLabel: null, // honest "no per-period rows — whole-day only"
      ));
      for (final m in const ['CPLH', 'SPLH', 'PPA']) {
        out.add(DataAlignmentAuditCheck.numeric(
          groupId: group,
          label: 'Profile whole-day $m = cover-weighted Σ(period $m)',
          expectedValue: null,
          comparedValue: null,
          tolerance: _rateTolerance,
        ));
      }
      return out;
    }

    out.add(DataAlignmentAuditCheck.presence(
      groupId: group,
      label: 'Per-period cycle rows present',
      actualLabel: 'TargetCycle.dayparts (${targetCycle.dayparts.length})',
    ));

    // (a) Per-period cycle → profile equality.
    for (final cd in targetCycle.dayparts) {
      final pd = profile?.daypartFor(cd.servicePeriodId);
      final p = cd.servicePeriodId;
      out.addAll([
        DataAlignmentAuditCheck.numeric(
          groupId: group,
          label: 'Period $p: cycle CPLH -> profile CPLH',
          expectedValue: cd.targetCPLH,
          comparedValue: pd?.daypartTargetCPLH,
          tolerance: _rateTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: group,
          label: 'Period $p: cycle SPLH -> profile SPLH',
          expectedValue: cd.targetSPLH,
          comparedValue: pd?.daypartTargetSPLH,
          tolerance: _splhTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: group,
          label: 'Period $p: cycle PPA -> profile PPA',
          expectedValue: cd.targetPPA,
          comparedValue: pd?.daypartTargetPPA,
          tolerance: _dollarTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: group,
          label: 'Period $p: cycle OPZ floor -> profile OPZ floor',
          expectedValue: cd.opzFloorCPLH,
          comparedValue: pd?.daypartOpzFloorCPLH,
          tolerance: _rateTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: group,
          label: 'Period $p: cycle OPZ ceiling -> profile OPZ ceiling',
          expectedValue: cd.opzCeilingCPLH,
          comparedValue: pd?.daypartOpzCeilingCPLH,
          tolerance: _rateTolerance,
        ),
      ]);
    }

    // (b) Design Rule 4 — profile whole-day scalars == cover-weighted
    // rollup of the cycle's per-period rows.
    final pool = TargetCycleDaypartPool.fromDayparts(targetCycle.dayparts);
    out.addAll([
      DataAlignmentAuditCheck.numeric(
        groupId: group,
        label: 'Profile whole-day CPLH = cover-weighted Σ(period CPLH)',
        expectedValue: pool.targetCPLH,
        comparedValue: profile?.targetCPLH,
        tolerance: _rateTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: group,
        label: 'Profile whole-day SPLH = cover-weighted Σ(period SPLH)',
        expectedValue: pool.targetSPLH,
        comparedValue: profile?.targetSPLH,
        tolerance: _splhTolerance,
      ),
      DataAlignmentAuditCheck.numeric(
        groupId: group,
        label: 'Profile whole-day PPA = cover-weighted Σ(period PPA)',
        expectedValue: pool.targetPPA,
        comparedValue: profile?.targetPPA,
        tolerance: _dollarTolerance,
      ),
    ]);

    return out;
  }

  // ── Group: per-period Shift runtime (Slice 6, full scope) ───────────────
  //
  // Plan Slice 6 category 2. Slice 4 wires the Shift period card to
  // resolve its per-period target as
  //   `profile.daypartFor(p)`  ?? whole-day pool   (Gap-42 fallback)
  // exactly the same shape the Variance read seam uses. The runtime
  // per-period read model is owned by a parallel surface
  // (`shift_service_period_read_service.dart`) and is not an input
  // here, so this group audits the *resolution rule itself*: the value
  // the Shift card resolves for each period must reconcile to the
  // locked `TargetCycle` per-period standard (the end-to-end
  // benchmark-authority → profile-projection → Shift-card invariant).
  //
  //   - profile per-period row PRESENT → compare the resolved
  //     per-period target against the cycle per-period standard
  //     (mismatch = drift; this is the "flag mismatch" path).
  //   - profile per-period row ABSENT → honest Gap-42 fallback: the
  //     Shift card reads the whole-day pool. Emit an informational
  //     presence row recording the fallback (NOT a fail) and verify
  //     the whole-day pool the card falls back to is itself consistent
  //     with the cycle whole-day scalar (the fallback must still be
  //     honest, never silently wrong).

  static List<DataAlignmentAuditCheck> _perPeriodShiftRuntimeChecks({
    required ActiveTargetProfile? profile,
    required TargetCycle? targetCycle,
  }) {
    const group = DataAlignmentAuditGroup.perPeriodShiftRuntime;
    final out = <DataAlignmentAuditCheck>[];

    if (targetCycle == null || targetCycle.dayparts.isEmpty) {
      out.add(DataAlignmentAuditCheck.presence(
        groupId: group,
        label: 'Shift per-period resolution available',
        actualLabel: null, // honest "no per-period rows — whole-day only"
      ));
      return out;
    }

    for (final cd in targetCycle.dayparts) {
      final p = cd.servicePeriodId;
      final pd = profile?.daypartFor(p);
      if (pd == null) {
        // Honest Gap-42 fallback path — informational, never a fail.
        out.add(DataAlignmentAuditCheck.presence(
          groupId: group,
          label: 'Period $p: Shift card reads per-period profile row',
          actualLabel: profile == null
              ? null
              : 'Gap-42 whole-day pool fallback',
        ));
        // The whole-day pool the Shift card falls back to must itself
        // be consistent with the cycle whole-day scalar.
        out.add(DataAlignmentAuditCheck.numeric(
          groupId: group,
          label:
              'Period $p: Gap-42 fallback CPLH = cycle whole-day CPLH',
          expectedValue: targetCycle.targetCPLH,
          comparedValue: profile?.targetCPLH,
          tolerance: _rateTolerance,
        ));
        continue;
      }
      // Profile per-period present — the Shift card resolves the
      // per-period value; it must reconcile to the cycle per-period
      // standard (mismatch = real drift).
      out.add(DataAlignmentAuditCheck.presence(
        groupId: group,
        label: 'Period $p: Shift card reads per-period profile row',
        actualLabel: 'ActiveTargetProfile.daypartFor($p)',
      ));
      out.addAll([
        DataAlignmentAuditCheck.numeric(
          groupId: group,
          label: 'Period $p: Shift resolved CPLH = cycle period CPLH',
          expectedValue: cd.targetCPLH,
          comparedValue: pd.daypartTargetCPLH,
          tolerance: _rateTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: group,
          label: 'Period $p: Shift resolved SPLH = cycle period SPLH',
          expectedValue: cd.targetSPLH,
          comparedValue: pd.daypartTargetSPLH,
          tolerance: _splhTolerance,
        ),
        DataAlignmentAuditCheck.numeric(
          groupId: group,
          label: 'Period $p: Shift resolved PPA = cycle period PPA',
          expectedValue: cd.targetPPA,
          comparedValue: pd.daypartTargetPPA,
          tolerance: _dollarTolerance,
        ),
      ]);
    }

    return out;
  }

  // ── Group: per-period Variance runtime (Slice 6, full scope) ────────────
  //
  // Plan Slice 6 category 3. Slice 5 swapped the Variance Full Week
  // non-closed read seam to
  //   `profile.daypartTheoreticalLaborPctFor(p)` ?? `theoreticalLaborPct`
  // (`variance_week_projection_read_service.dart:245-254`). This group
  // audits that the per-period theoretical % the Variance seam consumes
  // reconciles to the per-period theoretical % recomputed from the
  // locked `TargetCycle` per-period rates + whole-day wages (wages stay
  // whole-day, Design Rule 5). Closed rows are NOT audited here — they
  // keep their locked `shift.theoreticalLaborPct` (Rule 4 exception),
  // which is closed-truth and immutable.
  //
  //   - profile per-period row PRESENT → expected = canonical % from
  //     the cycle per-period rates; compared = the value the Variance
  //     seam reads (`daypartTheoreticalLaborPctFor`).
  //   - profile per-period row ABSENT → honest Gap-42 fallback: the
  //     Variance seam reads the whole-day `theoreticalLaborPct`. Emit
  //     an informational presence row + verify the whole-day fallback
  //     equals the cycle whole-day recomputed %.

  static List<DataAlignmentAuditCheck> _perPeriodVarianceRuntimeChecks({
    required ActiveTargetProfile? profile,
    required TargetCycle? targetCycle,
  }) {
    const group = DataAlignmentAuditGroup.perPeriodVarianceRuntime;
    final out = <DataAlignmentAuditCheck>[];

    if (targetCycle == null || targetCycle.dayparts.isEmpty) {
      out.add(DataAlignmentAuditCheck.presence(
        groupId: group,
        label: 'Variance per-period theoretical % available',
        actualLabel: null, // honest "no per-period rows — whole-day only"
      ));
      return out;
    }

    for (final cd in targetCycle.dayparts) {
      final p = cd.servicePeriodId;
      // Canonical per-period theoretical % from the cycle per-period
      // rates + whole-day wages — the same formula
      // `ActiveTargetProfile.daypartTheoreticalLaborPctFor` /
      // `ActiveTargetProfile.build` use (Design Rule 5: wages stay
      // whole-day; only the per-period rates differ from the pool).
      final double? wholeDayWageFoh = profile?.fohWage;
      final double? wholeDayWageBoh = profile?.bohWage;
      double? expectedPct;
      if (wholeDayWageFoh != null && wholeDayWageBoh != null) {
        final fohPct = (cd.targetCPLH > 0 && cd.targetPPA > 0)
            ? wholeDayWageFoh / (cd.targetCPLH * cd.targetPPA) * 100
            : 0.0;
        final bohPct = cd.targetSPLH > 0
            ? wholeDayWageBoh / cd.targetSPLH * 100
            : 0.0;
        expectedPct = fohPct + bohPct;
      }
      final pd = profile?.daypartFor(p);
      if (pd == null) {
        out.add(DataAlignmentAuditCheck.presence(
          groupId: group,
          label: 'Period $p: Variance reads per-period theoretical %',
          actualLabel: profile == null
              ? null
              : 'Gap-42 whole-day theoretical % fallback',
        ));
        // The whole-day theoretical % the Variance seam falls back to
        // must itself reconcile to the cycle whole-day recomputed %.
        out.add(DataAlignmentAuditCheck.numeric(
          groupId: group,
          label:
              'Period $p: Gap-42 fallback % = profile whole-day %',
          expectedValue: profile?.theoreticalLaborPct,
          comparedValue: profile == null
              ? null
              : (profile.daypartTheoreticalLaborPctFor(p) ??
                  profile.theoreticalLaborPct),
          tolerance: _pctTolerance,
        ));
        continue;
      }
      out.add(DataAlignmentAuditCheck.presence(
        groupId: group,
        label: 'Period $p: Variance reads per-period theoretical %',
        actualLabel:
            'ActiveTargetProfile.daypartTheoreticalLaborPctFor($p)',
      ));
      out.add(DataAlignmentAuditCheck.numeric(
        groupId: group,
        label: 'Period $p: Variance theoretical % = cycle period %',
        expectedValue: expectedPct,
        comparedValue: profile?.daypartTheoreticalLaborPctFor(p),
        tolerance: _pctTolerance,
      ));
    }

    return out;
  }

  // ── Group: per-period locked-plan reconciliation (Slice 6) ──────────────
  //
  // Plan Slice 6 category 4. Each `WeeklyPlanSnapshot.dayDayparts` row
  // is reconciled against the LOCK-TIME `TargetCycle` per-period
  // standard. Closed-truth doctrine / Time Guardrails: the locked
  // snapshot row is immutable and is NOT re-graded under the now-active
  // cycle — the `targetCycle` passed here, when a snapshot exists, is
  // fetched by `snapshot.targetCycleId` in `loadSnapshot` (the cycle
  // the plan was generated under, which may differ from the active
  // cycle after a rollover), so reconciling against it preserves
  // closed-truth immutability.
  //
  // Reconciliation (the lock-time labor-model identities):
  //   forecast sales      = forecast covers × period PPA
  //   required FOH hours  = forecast covers / period CPLH
  //   required BOH hours  = forecast sales  / period SPLH
  //
  // Honest degradation: no snapshot, no per-period locked rows, no
  // cycle, or no per-period cycle rows → one informational presence
  // row + unavailable aggregates (never a false PASS / fabricated `0`).

  static List<DataAlignmentAuditCheck>
      _perPeriodLockedPlanReconciliationChecks({
    required WeeklyPlanSnapshot? snapshot,
    required TargetCycle? targetCycle,
  }) {
    const group = DataAlignmentAuditGroup.perPeriodLockedPlanReconciliation;
    final out = <DataAlignmentAuditCheck>[];

    final hasRows = snapshot != null && snapshot.dayDayparts.isNotEmpty;
    final hasCycle = targetCycle != null && targetCycle.dayparts.isNotEmpty;
    if (!hasRows || !hasCycle) {
      out.add(DataAlignmentAuditCheck.presence(
        groupId: group,
        label: 'Per-period locked plan rows present',
        actualLabel: null, // honest "no per-period rows — whole-day only"
      ));
      for (final m in const [
        'sales = covers x period PPA',
        'FOH hrs = covers / period CPLH',
        'BOH hrs = sales / period SPLH',
      ]) {
        out.add(DataAlignmentAuditCheck.aggregate(
          groupId: group,
          label: 'Locked per-period $m',
          alignedCount: 0,
          total: 0,
        ));
      }
      return out;
    }

    out.add(DataAlignmentAuditCheck.presence(
      groupId: group,
      label: 'Per-period locked plan rows present',
      actualLabel:
          'WeeklyPlanSnapshot.dayDayparts (${snapshot.dayDayparts.length}) '
          'vs lock-time cycle ${snapshot.targetCycleId}',
    ));

    var salesAligned = 0;
    var fohAligned = 0;
    var bohAligned = 0;
    var comparable = 0;
    for (final d in snapshot.dayDayparts) {
      final cd = targetCycle.daypartFor(d.servicePeriodId);
      if (cd == null) continue; // no lock-time cycle period — not gradable
      comparable++;
      final expectedSales = d.forecastCovers * cd.targetPPA;
      if ((d.forecastSales - expectedSales).abs() <= _bigDollarTolerance) {
        salesAligned++;
      }
      if (cd.targetCPLH > 0) {
        final expectedFoh = d.forecastCovers / cd.targetCPLH;
        if ((d.requiredFohHours - expectedFoh).abs() <= _hoursTolerance) {
          fohAligned++;
        }
      }
      if (cd.targetSPLH > 0) {
        final expectedBoh = d.forecastSales / cd.targetSPLH;
        if ((d.requiredBohHours - expectedBoh).abs() <= _hoursTolerance) {
          bohAligned++;
        }
      }
    }
    out.addAll([
      DataAlignmentAuditCheck.aggregate(
        groupId: group,
        label: 'Locked per-period sales = covers x period PPA',
        alignedCount: salesAligned,
        total: comparable,
      ),
      DataAlignmentAuditCheck.aggregate(
        groupId: group,
        label: 'Locked per-period FOH hrs = covers / period CPLH',
        alignedCount: fohAligned,
        total: comparable,
      ),
      DataAlignmentAuditCheck.aggregate(
        groupId: group,
        label: 'Locked per-period BOH hrs = sales / period SPLH',
        alignedCount: bohAligned,
        total: comparable,
      ),
    ]);

    return out;
  }

  // ── Group: per-period sum-to-day + actual presence (Slice 6) ────────────
  //
  // Plan Slice 6 category 5 (two sub-invariants):
  //
  //   (a) Sum-to-day reconciliation — pool-consistency at the PLAN
  //       layer. For each whole-day locked row, Σ(per-period locked
  //       rows for that business date) must equal the day's whole-day
  //       figure (covers / sales / FOH hrs / BOH hrs). This is the
  //       plan-side analogue of the cycle pool-consistency check.
  //
  //   (b) Per-period ACTUAL presence — reported honestly. There is no
  //       per-period actual feed wired into this diagnostic read path
  //       (per-period actuals are resolved by
  //       `shift_service_period_read_service.dart`, a parallel surface
  //       not consumed here). Per Design Rule 2 / Metric Honesty the
  //       absence is reported as "not present" / `—` (unavailable) —
  //       NEVER counted as a `0` PASS and never fabricated.
  //
  // Honest degradation: no snapshot or no per-period locked rows → one
  // informational presence row + unavailable aggregates.

  static List<DataAlignmentAuditCheck> _perPeriodSumAndActualPresenceChecks({
    required WeeklyPlanSnapshot? snapshot,
  }) {
    const group = DataAlignmentAuditGroup.perPeriodSumAndActuals;
    final out = <DataAlignmentAuditCheck>[];

    final hasRows = snapshot != null && snapshot.dayDayparts.isNotEmpty;
    if (!hasRows) {
      out.add(DataAlignmentAuditCheck.presence(
        groupId: group,
        label: 'Per-period locked plan rows present',
        actualLabel: null, // honest "no per-period rows — whole-day only"
      ));
      for (final m in const [
        'covers',
        'sales',
        'FOH hrs',
        'BOH hrs',
      ]) {
        out.add(DataAlignmentAuditCheck.aggregate(
          groupId: group,
          label: 'Σ(per-period $m) = whole-day locked $m',
          alignedCount: 0,
          total: 0,
        ));
      }
      // (b) Per-period actuals are honestly "not present" here — never
      // a fabricated `0` PASS (Design Rule 2 / Metric Honesty).
      for (final m in const ['covers', 'sales', 'FOH/BOH hours']) {
        out.add(DataAlignmentAuditCheck.presence(
          groupId: group,
          label: 'Per-period actual $m present',
          actualLabel: null,
        ));
      }
      return out;
    }

    // (a) Sum-to-day reconciliation.
    var coversDays = 0;
    var salesDays = 0;
    var fohDays = 0;
    var bohDays = 0;
    var daysWithPeriods = 0;
    for (final day in snapshot.dayRows) {
      final periodRows = snapshot.dayDayparts
          .where((d) => d.businessDate == day.businessDate)
          .toList();
      if (periodRows.isEmpty) continue;
      daysWithPeriods++;
      final sumCovers =
          periodRows.fold<int>(0, (s, d) => s + d.forecastCovers);
      final sumSales =
          periodRows.fold<double>(0, (s, d) => s + d.forecastSales);
      final sumFoh =
          periodRows.fold<double>(0, (s, d) => s + d.requiredFohHours);
      final sumBoh =
          periodRows.fold<double>(0, (s, d) => s + d.requiredBohHours);
      if (sumCovers == day.forecastCovers) coversDays++;
      if ((sumSales - day.forecastSales).abs() <= _bigDollarTolerance) {
        salesDays++;
      }
      if ((sumFoh - day.requiredFohHours).abs() <= _hoursTolerance) {
        fohDays++;
      }
      if ((sumBoh - day.requiredBohHours).abs() <= _hoursTolerance) {
        bohDays++;
      }
    }
    out.addAll([
      DataAlignmentAuditCheck.aggregate(
        groupId: group,
        label: 'Σ(per-period covers) = whole-day locked covers',
        alignedCount: coversDays,
        total: daysWithPeriods,
      ),
      DataAlignmentAuditCheck.aggregate(
        groupId: group,
        label: 'Σ(per-period sales) = whole-day locked sales',
        alignedCount: salesDays,
        total: daysWithPeriods,
      ),
      DataAlignmentAuditCheck.aggregate(
        groupId: group,
        label: 'Σ(per-period FOH hrs) = whole-day locked FOH hrs',
        alignedCount: fohDays,
        total: daysWithPeriods,
      ),
      DataAlignmentAuditCheck.aggregate(
        groupId: group,
        label: 'Σ(per-period BOH hrs) = whole-day locked BOH hrs',
        alignedCount: bohDays,
        total: daysWithPeriods,
      ),
    ]);

    // (b) Per-period ACTUAL presence — honest "not present" / `—`.
    // Per-period actuals are resolved by a parallel runtime surface
    // (`shift_service_period_read_service.dart`), not consumed by this
    // diagnostic read path. Reporting them as unavailable is the
    // honest state (Design Rule 2 / Metric Honesty) — they are NEVER
    // counted as a `0` PASS and never fabricated.
    for (final m in const ['covers', 'sales', 'FOH/BOH hours']) {
      out.add(DataAlignmentAuditCheck.presence(
        groupId: group,
        label: 'Per-period actual $m present',
        actualLabel: null,
      ));
    }

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

    // Variance Full Week daypart alignment for non-closed rows. Closed
    // rows preserve their locked target package — we only audit
    // non-closed cells.
    //
    // Per-Daypart V1 / Slice 6 (full scope) — AUTHORITY-PRECEDENCE FIX.
    // Slice 3 made the persisted `weekly_plan_snapshot_day_dayparts`
    // (via `WeeklyPlanSnapshot.dayDayparts`) the LOCKED per-period
    // authority and demoted `DaypartPlanAllocator` to a fallback that
    // only runs when no persisted per-period rows exist (live/preview
    // Schedule, legacy snapshots, Gap-42 insufficient-recommendation).
    // The previous audit reconciled non-closed cells against the LIVE
    // allocator output — i.e. it validated against the retired
    // authority, not the locked truth, so a snapshot whose persisted
    // per-period rows diverged from a re-run allocator would read as
    // "aligned". Precedence is now explicit:
    //
    //   snapshot.dayDayparts non-empty → reconcile against the LOCKED
    //     per-period rows (the authority).
    //   snapshot.dayDayparts empty     → fall back to
    //     `DaypartPlanAllocator.allocate(...)` (the same call the
    //     non-locked Schedule / legacy / Gap-42 paths use).
    if (snapshot != null &&
        snapshot.dayDayparts.isNotEmpty &&
        fullWeekShifts != null) {
      // LOCKED authority path — reconcile against the persisted
      // per-(business_date, service_period) rows. Map day label →
      // business date from the whole-day rows so shifts that carry no
      // explicit `businessDate` still resolve their locked sub-row.
      final dayLabelToDate = <String, String>{
        for (final r in snapshot.dayRows) r.day: r.businessDate,
      };
      var coversAligned = 0;
      var salesAligned = 0;
      var fohAligned = 0;
      var bohAligned = 0;
      var totalCells = 0;
      for (final s in fullWeekShifts) {
        if (s.isClosed) continue; // closed rows keep locked targets
        final businessDate = s.businessDate ?? dayLabelToDate[s.dayLabel];
        if (businessDate == null) continue;
        final locked = snapshot.dayDaypartFor(
          businessDate: businessDate,
          servicePeriodId: s.daypart,
        );
        if (locked == null) continue;
        totalCells++;
        if (s.forecastCovers == locked.forecastCovers) coversAligned++;
        final shiftSales = s.planForecastSales;
        if (shiftSales != null &&
            (shiftSales - locked.forecastSales).abs() <=
                _bigDollarTolerance) {
          salesAligned++;
        }
        if ((s.fohHours - locked.requiredFohHours).abs() <=
            _hoursTolerance) {
          fohAligned++;
        }
        if ((s.bohHours - locked.requiredBohHours).abs() <=
            _hoursTolerance) {
          bohAligned++;
        }
      }
      out.addAll([
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label:
              'Full Week non-closed forecast covers = locked dayDayparts',
          alignedCount: coversAligned,
          total: totalCells,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label:
              'Full Week non-closed forecast sales = locked dayDayparts',
          alignedCount: salesAligned,
          total: totalCells,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'Full Week non-closed FOH hrs = locked dayDayparts',
          alignedCount: fohAligned,
          total: totalCells,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'Full Week non-closed BOH hrs = locked dayDayparts',
          alignedCount: bohAligned,
          total: totalCells,
        ),
      ]);
    } else if (snapshot != null &&
        fullWeekShifts != null &&
        servicePeriodDefinitions != null) {
      // FALLBACK path — no persisted per-period rows (legacy snapshot
      // / Gap-42). Reconcile against the shared `DaypartPlanAllocator`
      // output (the same call the non-locked Schedule path uses). This
      // runs ONLY when `snapshot.dayDayparts` is empty, never when the
      // locked authority is present.
      final allocByDay = <String, Map<String, DaypartAllocation>>{};
      for (final dayRow in snapshot.dayRows) {
        // The allocator's own Slice 3 deprecation note explicitly
        // sanctions the audit (Slice 6) fallback consumer; this call
        // runs only when no locked per-period rows exist.
        // ignore: deprecated_member_use_from_same_package
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
              'Full Week non-closed forecast covers = DaypartPlanAllocator '
              '(fallback — no locked dayDayparts)',
          alignedCount: coversAligned,
          total: totalCells,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label:
              'Full Week non-closed forecast sales = DaypartPlanAllocator '
              '(fallback — no locked dayDayparts)',
          alignedCount: salesAligned,
          total: totalCells,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'Full Week non-closed FOH hrs = DaypartPlanAllocator '
              '(fallback — no locked dayDayparts)',
          alignedCount: fohAligned,
          total: totalCells,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'Full Week non-closed BOH hrs = DaypartPlanAllocator '
              '(fallback — no locked dayDayparts)',
          alignedCount: bohAligned,
          total: totalCells,
        ),
      ]);
    } else {
      // Snapshot / shifts / definitions missing → unavailable. Neutral
      // labels (neither authority nor fallback path ran).
      out.addAll([
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label:
              'Full Week non-closed forecast covers = locked dayDayparts',
          alignedCount: 0,
          total: 0,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label:
              'Full Week non-closed forecast sales = locked dayDayparts',
          alignedCount: 0,
          total: 0,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'Full Week non-closed FOH hrs = locked dayDayparts',
          alignedCount: 0,
          total: 0,
        ),
        DataAlignmentAuditCheck.aggregate(
          groupId: DataAlignmentAuditGroup.planRuntime,
          label: 'Full Week non-closed BOH hrs = locked dayDayparts',
          alignedCount: 0,
          total: 0,
        ),
      ]);
    }

    return out;
  }
}
