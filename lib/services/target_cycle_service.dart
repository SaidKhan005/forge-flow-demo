// Phase 7.55l.2a+2b+2c+3a+3b — TargetCycle persistence, auto-refresh,
// override write path.
//
// Per-Daypart Targets V1 (Slice 1) extensions:
//   - `_writeReplacementCycle` and `_createRecommendedCycle` now build
//     per-period `TargetCycleDaypart` rows from `recommendation.perDaypartStats`
//     and compute the parent's whole-day pool as a cover-weighted rollup
//     of the per-period rows (Design Rule 4 — pool is derived from
//     period inside the write path; never the other way around).
//   - Per-period OPZ floor = min of period floors; ceiling = max of
//     period ceilings.
//   - Gap 42 fallback: when `recommendation.isInsufficient`, the parent
//     row is written with `MeridianConfig` whole-day defaults and the
//     `dayparts` list stays empty. Read-layer consumers fall back to
//     the parent pool when `cycle.daypartFor(periodId)` returns null.
//   - `_syncActiveTargetProfile` projects the cycle through to the
//     persisted `ActiveTargetProfile` AND attaches the per-period rows
//     so per-period consumers can read through the profile without a
//     second join (`ActiveTargetProfile.daypartFor(...)`).
//   - Manager-override path also bucket the selected candidates by
//     daypart and emit per-period rows; the pool then rolls up from
//     those rows the same way recommended cycles do.
//
// Narrow runtime seam: load/create/auto-refresh/override the active
// TargetCycle. Does not migrate consumers or change Benchmark/Manager
// Override UX.
//
// 7.55l.2b fixes:
// - recommended-cycle creation now rebuilds fresh from explicit
//   recommendation inputs + resolved wages instead of reading a stale
//   persisted ActiveTargetProfile
// - all existing active cycles are deactivated before writing a new one
//   to enforce one-active-per-restaurant
//
// 7.55l.2c fix:
// - recommended-cycle creation now re-primes BaselineData for the
//   requested business date's 60-day window before building, instead
//   of relying on whatever stale in-memory BaselineData was loaded
//
// 7.55l.3a additions:
// - applyManagerOverrideCycle: manager override write path (once per cycle)
// - applyAdminReplacementCycle: admin replacement write path (metadata only)
// - ManagerOverrideDeniedException for explicit denial signaling
//
// 7.55l.3b fixes:
// - replacement calibration window now matches the actual benchmark
//   window used to rebuild standards (businessDate-based), not the
//   prior cycle's stale calibration window
// - replacement cycleId now includes a UTC timestamp component so
//   repeated same-day replacements produce distinct historical rows
//   instead of overwriting via upsert
//
// 7.55l.4a additions:
// - after every cycle write, the service now projects the cycle to
//   ActiveTargetProfile and persists it through the target-profile
//   repository, keeping the persisted profile synchronized with the
//   current active cycle

import 'dart:math' as math;

import '../models/baseline_candidate_shift.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/benchmark_selection_summary.dart';
import '../domain/models/recommended_benchmark_selection.dart';
import '../domain/models/target_cycle.dart';
import '../domain/models/target_cycle_source.dart';
import '../domain/repositories/benchmark_selection_summary_repository.dart';
import '../domain/repositories/target_cycle_repository.dart';
import '../domain/repositories/target_profile_repository.dart';
import '../domain/services/target_cycle_active_target_profile_projector.dart';
import '../domain/services/target_cycle_policy.dart';
import '../domain/services/utc_metadata_timestamp.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_benchmark_selection_summary_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'app_notification_service.dart';
import 'baseline_authority_service.dart';
import 'baseline_manager_service.dart';
import 'baseline_selection_analytics_service.dart';
import '../domain/constants/app_defaults.dart';
import 'restaurant_timing_config_read_service.dart';
import 'wage_standard_context_service.dart';

/// Thrown when a manager override is denied by [TargetCyclePolicy] rules.
///
/// Denial reasons:
/// - once-per-cycle override already consumed
/// - business date outside the cycle's active window
class ManagerOverrideDeniedException implements Exception {
  final String reason;
  ManagerOverrideDeniedException(this.reason);
  @override
  String toString() => 'ManagerOverrideDeniedException: $reason';
}

class TargetCycleService {
  TargetCycleService._();
  static final TargetCycleService instance = TargetCycleService._();

  final TargetCycleRepository _cycleRepo =
      SqliteTargetCycleRepository.instance;

  final TargetProfileRepository _profileRepo =
      SqliteTargetProfileRepository.instance;

  final BenchmarkSelectionSummaryRepository _summaryRepo =
      SqliteBenchmarkSelectionSummaryRepository.instance;

  /// Loads the active cycle for [restaurantId] on [businessDate].
  ///
  /// - If no active cycle exists, creates a recommended one.
  /// - If the active cycle is past its effective end AND the business date
  ///   is the operator's configured week-start day, creates a new
  ///   recommended cycle (auto-refresh). All existing active cycles are
  ///   deactivated before the new one is written. Per-daypart-targets V1
  ///   (Slice 0) gates rollover to the operator-configured `week_start_day`
  ///   so cycle refresh cannot land mid-week; cycle length becomes 60–66
  ///   days per operator.
  /// - Otherwise returns the active cycle unchanged (including the
  ///   past-effective-end-but-not-yet-week-start deferral case), repairing
  ///   the companion [BenchmarkSelectionSummary] if it is missing (7.56b.1).
  Future<TargetCycle> getOrCreateActiveCycle(
      String restaurantId, String businessDate) async {
    final existing = await _cycleRepo.getActiveCycle(restaurantId);

    if (existing == null) {
      return _createRecommendedCycle(restaurantId, businessDate);
    }

    // Resolve the operator's configured business-week start day so the
    // cycle-rollover boundary aligns with the weekly-plan-lock boundary.
    // Falls back to DateTime.monday when the timing config has not been
    // persisted yet (bootstrap / older demo scopes).
    final timingConfig = await RestaurantTimingConfigReadService.instance
        .getTimingConfig(restaurantId);
    final weekStartDay = timingConfig?.weekStartDay ?? DateTime.monday;

    if (TargetCyclePolicy.needsAutoRefresh(existing, businessDate,
        weekStartDay: weekStartDay)) {
      final newCycle =
          await _createRecommendedCycle(restaurantId, businessDate);
      // Persist passive notification for cycle rollover (7.55p.4d).
      // Awaited so the notification row is durable before the rollover
      // path returns. Only on auto-refresh, not initial bootstrap.
      await AppNotificationService.instance.emitCycleRollover(
        restaurantId: restaurantId,
        cycleEffectiveStart: newCycle.effectiveStart,
        businessDate: businessDate,
      );
      return newCycle;
    }

    // 7.56b.1: the seed path (`_ensureDemoSeedCycle`) inserts an active
    // cycle row without a companion summary. Existing summaries are not
    // rewritten — the repair only writes when the row is missing.
    await _ensureSelectionSummaryExists(existing);
    return existing;
  }

  // ── Manager override write path (7.55l.3a) ────────────────────────────

  /// Applies a manager override to the active cycle for [restaurantId].
  ///
  /// Loads or creates the current active cycle, verifies the manager can
  /// override it (active window + once-per-cycle rule via
  /// [TargetCyclePolicy.canManagerOverride]), then builds a replacement
  /// cycle with fresh standards from current app truth.
  ///
  /// The replacement preserves the current cycle's effective window but
  /// recalibrates the calibration window to match the actual benchmark
  /// window used for the rebuild. Sets source to
  /// [TargetCycleSource.managerOverride] and marks the override as consumed.
  ///
  /// Throws [ManagerOverrideDeniedException] if the override is not allowed.
  Future<TargetCycle> applyManagerOverrideCycle(
      String restaurantId, String businessDate) async {
    final current = await getOrCreateActiveCycle(restaurantId, businessDate);

    if (!TargetCyclePolicy.canManagerOverride(current, businessDate)) {
      if (current.managerOverrideUsed) {
        throw ManagerOverrideDeniedException(
            'Manager override already used for this cycle');
      }
      throw ManagerOverrideDeniedException(
          'Business date is outside the active cycle window');
    }

    return _writeReplacementCycle(
      current: current,
      restaurantId: restaurantId,
      businessDate: businessDate,
      source: TargetCycleSource.managerOverride,
      managerOverrideUsed: true,
      managerOverrideAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  // ── Admin replacement write path (7.55l.3a) ───────────────────────────

  /// Applies an admin replacement to the active cycle for [restaurantId].
  ///
  /// Similar to manager override but bypasses the once-per-cycle rule.
  /// Admin can replace regardless of whether the manager override has been
  /// used. No auth enforcement in this slice — metadata path only.
  ///
  /// The replacement preserves the current cycle's effective window but
  /// recalibrates the calibration window to match the actual benchmark
  /// window used for the rebuild. Sets source to
  /// [TargetCycleSource.adminReplacement] and carries forward prior
  /// manager override metadata as historical context.
  Future<TargetCycle> applyAdminReplacementCycle(
      String restaurantId, String businessDate) async {
    final current = await getOrCreateActiveCycle(restaurantId, businessDate);

    return _writeReplacementCycle(
      current: current,
      restaurantId: restaurantId,
      businessDate: businessDate,
      source: TargetCycleSource.adminReplacement,
      managerOverrideUsed: current.managerOverrideUsed,
      managerOverrideAt: current.managerOverrideAt,
      adminReplacedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  // ── Shared replacement write path (7.55l.3a) ──────────────────────────

  /// Restores recommended-cycle authority after a manager override is cleared.
  ///
  /// Uses the canonical replacement-cycle path instead of mutating the active
  /// profile directly. Prior override usage is preserved so clearing the
  /// override does not silently grant a fresh once-per-cycle allowance.
  Future<TargetCycle> restoreRecommendedCycle(
      String restaurantId, String businessDate) async {
    final current = await getOrCreateActiveCycle(restaurantId, businessDate);

    if (current.source == TargetCycleSource.recommended) {
      return current;
    }

    return _writeReplacementCycle(
      current: current,
      restaurantId: restaurantId,
      businessDate: businessDate,
      source: TargetCycleSource.recommended,
      managerOverrideUsed: current.managerOverrideUsed,
      managerOverrideAt: current.managerOverrideAt,
      adminReplacedAt: current.adminReplacedAt,
    );
  }

  Future<TargetCycle> _writeReplacementCycle({
    required TargetCycle current,
    required String restaurantId,
    required String businessDate,
    required TargetCycleSource source,
    required bool managerOverrideUsed,
    String? managerOverrideAt,
    String? adminReplacedAt,
  }) async {
    // Re-prime benchmark context for the business date's 60-day window.
    await BaselineManagerService.instance
        .primeBaselineContextForDate(restaurantId, businessDate);

    // Resolve wages fresh from the wage-authority waterfall.
    final wageCtx =
        await WageStandardContextService.instance.resolve(restaurantId);

    // Manager-override replacement stays backed by the explicit
    // manager-selected candidate cohort. Admin replacements with no
    // manager-selected keys use the app-owned recommendation service
    // (7.55p.5g) so the replaced recommended baseline is not pulled
    // from bridge-selected state.
    final hasOverride = await BaselineManagerService.instance
        .hasPersistedManagerOverride(restaurantId);

    ActiveTargetProfileBuildResult build;
    RecommendedBenchmarkSelection? recommendation;
    List<TargetCycleDaypart> cycleDayparts;
    if (hasOverride) {
      final selected = await _selectedManagerOverrideCandidates(
        restaurantId,
        businessDate,
      );
      final overrideResult = _buildManagerOverrideProfileAndDayparts(
        restaurantId: restaurantId,
        wageFoh: wageCtx.fohWage ?? MeridianConfig.fohWage,
        wageBoh: wageCtx.bohWage ?? MeridianConfig.bohWage,
        selectedCandidates: selected,
        sourceType: source == TargetCycleSource.adminReplacement
            ? 'admin_replacement'
            : 'manager_override',
      );
      build = ActiveTargetProfileBuildResult(
        profile: overrideResult.profile,
        sourceLabel: source.label,
      );
      cycleDayparts = overrideResult.dayparts;
    } else {
      recommendation = await BaselineManagerService.instance
          .resolveRecommendedSelection(restaurantId, businessDate);
      final recResult = _buildRecommendedProfileAndDayparts(
        restaurantId: restaurantId,
        wageFoh: wageCtx.fohWage,
        wageBoh: wageCtx.bohWage,
        recommendation: recommendation,
      );
      build = ActiveTargetProfileBuildResult(
        profile: recResult.profile,
        sourceLabel: recResult.sourceLabel,
      );
      cycleDayparts = recResult.dayparts;
    }

    final profile = build.profile;

    // Deactivate all active cycles for the restaurant.
    await SqliteTargetCycleRepository.instance
        .deactivateAllForRestaurant(restaurantId);

    // Calibration window matches the actual benchmark window used to
    // rebuild standards — not the prior cycle's potentially stale window.
    final calibrationEnd = businessDate;
    final calibrationStart = _addDays(businessDate, -59);

    // CODE_HEALTH L15 fix: cycleId uses 128-bit cryptographically-random
    // hex instead of `millisecondsSinceEpoch` so two replacement writes
    // within the same millisecond cannot silently overwrite via upsert.
    // No `uuid` package on the dependency tree, so `Random.secure()`
    // builds a 128-bit hex (32 hex chars) directly — same collision
    // resistance as UUID v4.
    final nowUtc = DateTime.now().toUtc();
    final now = nowUtc.toIso8601String();
    final replacement = TargetCycle(
      cycleId:
          '${restaurantId}_${source.label}_${_random128BitHex()}',
      restaurantId: restaurantId,
      source: source,
      effectiveStart: current.effectiveStart,
      effectiveEnd: current.effectiveEnd,
      calibrationWindowStart: calibrationStart,
      calibrationWindowEnd: calibrationEnd,
      targetCPLH: profile.targetCPLH,
      targetSPLH: profile.targetSPLH,
      targetPPA: profile.targetPPA,
      fohWage: profile.fohWage,
      bohWage: profile.bohWage,
      opzFloorCPLH: profile.opzFloorCPLH,
      opzCeilingCPLH: profile.opzCeilingCPLH,
      managerOverrideUsed: managerOverrideUsed,
      managerOverrideAt: managerOverrideAt,
      adminReplacedAt: adminReplacedAt,
      createdAt: now,
      dayparts: cycleDayparts,
    );

    await _cycleRepo.upsertCycle(replacement);
    await _syncActiveTargetProfile(replacement);
    await _persistSelectionSummary(
      replacement,
      source.label,
      fromRecommendation: recommendation,
    );
    return replacement;
  }

  // ── Recommended-cycle write path (7.55p.5g) ───────────────────────────
  //
  // Routes between two source-truth paths:
  //
  // 1. Manager override present → read from the persisted selected
  //    candidate cohort directly. This is the explicit manager-selected
  //    authority path.
  //
  // 2. No manager override → consult
  //    `RecommendedBenchmarkSelectionService` for app-owned recommendation
  //    truth. The default recommended/system cycle no longer depends on
  //    hardcoded seed-selected BaselineData records for its active cohort.
  //
  // Both paths now build the profile from explicit values. The older
  // `buildActiveTargetProfileFromBaseline` helper remains as a bridge/
  // compatibility seam, but it is no longer the live authoring path here.

  Future<TargetCycle> _createRecommendedCycle(
      String restaurantId, String businessDate) async {
    // Re-prime benchmark context for the requested business date's 60-day
    // window. Still used for historicalContextRecords and manager-override
    // path compatibility.
    await BaselineManagerService.instance
        .primeBaselineContextForDate(restaurantId, businessDate);

    // Resolve wages fresh from the wage-authority waterfall.
    final wageCtx =
        await WageStandardContextService.instance.resolve(restaurantId);

    // Recommended-cycle creation must stay provenance-honest even if
    // persisted manager-selected keys happen to exist already. Override
    // selections only become authoritative through the explicit
    // applyManagerOverrideCycle/write-replacement path.
    final recommendation = await BaselineManagerService.instance
        .resolveRecommendedSelection(restaurantId, businessDate);
    final recResult = _buildRecommendedProfileAndDayparts(
      restaurantId: restaurantId,
      wageFoh: wageCtx.fohWage,
      wageBoh: wageCtx.bohWage,
      recommendation: recommendation,
    );

    final profile = recResult.profile;

    // Enforce one-active-per-restaurant: deactivate all existing active
    // cycles before writing the new one.
    await SqliteTargetCycleRepository.instance
        .deactivateAllForRestaurant(restaurantId);

    final effectiveStart = businessDate;
    final effectiveEnd = _addDays(businessDate, 59);
    final calibrationEnd = businessDate;
    final calibrationStart = _addDays(businessDate, -59);

    final cycle = TargetCycle(
      cycleId: '${restaurantId}_cycle_${businessDate.replaceAll('-', '')}',
      restaurantId: restaurantId,
      source: TargetCycleSource.recommended,
      effectiveStart: effectiveStart,
      effectiveEnd: effectiveEnd,
      calibrationWindowStart: calibrationStart,
      calibrationWindowEnd: calibrationEnd,
      targetCPLH: profile.targetCPLH,
      targetSPLH: profile.targetSPLH,
      targetPPA: profile.targetPPA,
      fohWage: profile.fohWage,
      bohWage: profile.bohWage,
      opzFloorCPLH: profile.opzFloorCPLH,
      opzCeilingCPLH: profile.opzCeilingCPLH,
      createdAt: nowIsoUtc(),
      dayparts: recResult.dayparts,
    );

    await _cycleRepo.upsertCycle(cycle);
    await _syncActiveTargetProfile(cycle);
    await _persistSelectionSummary(
      cycle,
      recResult.sourceLabel,
      fromRecommendation: recommendation,
    );
    return cycle;
  }

  /// Per-Daypart V1 (Slice 1) — recommended-path profile + per-period
  /// rows. Replaces the legacy `_buildRecommendedProfile` which read
  /// from `recommendation.pooledRecommendedTargetCPLH` etc. Now:
  ///
  /// 1. For each daypart with stats in `recommendation.perDaypartStats`,
  ///    emit a `TargetCycleDaypart` row.
  /// 2. Compute the parent's whole-day pool as a cover-weighted rollup
  ///    of those rows (Design Rule 4).
  /// 3. OPZ floor = min of period floors; ceiling = max of period
  ///    ceilings.
  /// 4. Gap 42 fallback (binding operator decision 2026-05-15): when
  ///    `recommendation.isInsufficient`, write the parent with
  ///    `MeridianConfig` whole-day defaults and leave the per-period
  ///    list empty. Read-layer consumers fall back to the parent pool
  ///    when `daypartFor` returns null.
  _RecommendedBuildResult _buildRecommendedProfileAndDayparts({
    required String restaurantId,
    required double? wageFoh,
    required double? wageBoh,
    required RecommendedBenchmarkSelection recommendation,
  }) {
    final resolvedFohWage = wageFoh ?? MeridianConfig.fohWage;
    final resolvedBohWage = wageBoh ?? MeridianConfig.bohWage;

    if (recommendation.isInsufficient) {
      // Gap 42 fallback: parent gets MeridianConfig whole-day defaults;
      // no per-period rows. Read-layer falls back to parent pool when
      // `cycle.daypartFor(periodId)` returns null.
      return _RecommendedBuildResult(
        profile: ActiveTargetProfile.build(
          restaurantId: restaurantId,
          sourceType: 'system_baseline_insufficient',
          targetCPLH: MeridianConfig.targetCPLH,
          targetSPLH: MeridianConfig.targetSPLH,
          targetPPA: MeridianConfig.targetPPA,
          fohWage: resolvedFohWage,
          bohWage: resolvedBohWage,
          opzFloorCPLH: MeridianConfig.opzFloorCPLH,
          opzCeilingCPLH: MeridianConfig.opzCeilingCPLH,
        ),
        dayparts: const <TargetCycleDaypart>[],
        sourceLabel: 'cycle_recommended_insufficient',
      );
    }

    // Build per-period rows from the recommendation's per-daypart stats.
    // The recommendation service has already done the heavy lifting
    // (eligibility gating, MAD-outlier filtering, CPLH-first top-N) per
    // daypart; this just lifts the stats into persistence shape.
    final dayparts = <TargetCycleDaypart>[];
    for (final entry in recommendation.perDaypartStats.entries) {
      final stats = entry.value;
      dayparts.add(TargetCycleDaypart(
        servicePeriodId: entry.key,
        targetCPLH: stats.recommendedTargetCPLH,
        targetSPLH: stats.recommendedTargetSPLH,
        targetPPA: stats.recommendedTargetPPA,
        opzFloorCPLH: stats.opzFloorCPLH,
        opzCeilingCPLH: stats.opzCeilingCPLH,
        coverCount: stats.selectedCount,
      ));
    }

    // Recompute pool from the per-period rows (Design Rule 4).
    final pool = TargetCycleDaypartPool.fromDayparts(dayparts);

    return _RecommendedBuildResult(
      profile: ActiveTargetProfile.build(
        restaurantId: restaurantId,
        sourceType: 'system_baseline',
        targetCPLH: pool.targetCPLH,
        targetSPLH: pool.targetSPLH,
        targetPPA: pool.targetPPA,
        fohWage: resolvedFohWage,
        bohWage: resolvedBohWage,
        opzFloorCPLH: pool.opzFloorCPLH,
        opzCeilingCPLH: pool.opzCeilingCPLH,
      ),
      dayparts: dayparts,
      sourceLabel: 'cycle_recommended',
    );
  }

  Future<List<BaselineCandidateShift>> _selectedManagerOverrideCandidates(
    String restaurantId,
    String businessDate,
  ) async {
    final startDate = _addDays(businessDate, -59);
    final candidates = await BaselineManagerService.instance
        .getCandidateShiftsForDateRange(
      startDate,
      businessDate,
      restaurantId: restaurantId,
    );
    return candidates.where((c) => c.isSelected).toList();
  }

  /// Per-Daypart V1 (Slice 1) — manager-override profile + per-period
  /// rows.
  ///
  /// The override input is `selectedCandidates` (one candidate per
  /// (week, day, period) the manager pinned). We bucket by `daypart` to
  /// produce one row per period: per-period CPLH/SPLH/PPA are means of
  /// the candidates in that bucket; OPZ floor/ceiling are the min/max
  /// CPLH within the bucket; cover_count is the sum of the bucket's
  /// candidate covers (used for cover-weighted pool rollup).
  ///
  /// The parent profile's whole-day pool is then computed from those
  /// per-period rows (Design Rule 4 — pool derives from period, never
  /// the other way around).
  ///
  /// When the manager has pinned zero candidates the function still
  /// throws — the caller should not be on the manager-override write
  /// path without at least one selected candidate.
  _OverrideBuildResult _buildManagerOverrideProfileAndDayparts({
    required String restaurantId,
    required double wageFoh,
    required double wageBoh,
    required List<BaselineCandidateShift> selectedCandidates,
    required String sourceType,
  }) {
    if (selectedCandidates.isEmpty) {
      throw StateError(
        'TargetCycleService: manager override profile requested without any '
        'selected candidate shifts in the active 60-day window.',
      );
    }

    // Bucket candidates by daypart so we can emit one per-period row
    // per pinned daypart.
    final byDaypart = <String, List<BaselineCandidateShift>>{};
    for (final c in selectedCandidates) {
      (byDaypart[c.daypart] ??= <BaselineCandidateShift>[]).add(c);
    }

    final dayparts = <TargetCycleDaypart>[];
    for (final entry in byDaypart.entries) {
      final periodId = entry.key;
      final cohort = entry.value;
      double sumCPLH = 0;
      double sumSPLH = 0;
      double sumPPA = 0;
      double opzFloor = cohort.first.cplh;
      double opzCeiling = cohort.first.cplh;
      int sumCovers = 0;
      for (final c in cohort) {
        sumCPLH += c.cplh;
        sumSPLH += c.splh;
        sumPPA += c.ppa;
        sumCovers += c.covers;
        if (c.cplh < opzFloor) opzFloor = c.cplh;
        if (c.cplh > opzCeiling) opzCeiling = c.cplh;
      }
      final n = cohort.length;
      dayparts.add(TargetCycleDaypart(
        servicePeriodId: periodId,
        targetCPLH: sumCPLH / n,
        targetSPLH: sumSPLH / n,
        targetPPA: sumPPA / n,
        opzFloorCPLH: opzFloor,
        opzCeilingCPLH: opzCeiling,
        coverCount: sumCovers,
      ));
    }

    // Pool computed from the per-period rows (Design Rule 4). When
    // every period has zero covers (degenerate cohort) the helper
    // falls back to unweighted mean.
    final pool = TargetCycleDaypartPool.fromDayparts(dayparts);

    return _OverrideBuildResult(
      profile: ActiveTargetProfile.build(
        restaurantId: restaurantId,
        sourceType: sourceType,
        targetCPLH: pool.targetCPLH,
        targetSPLH: pool.targetSPLH,
        targetPPA: pool.targetPPA,
        fohWage: wageFoh,
        bohWage: wageBoh,
        opzFloorCPLH: pool.opzFloorCPLH,
        opzCeilingCPLH: pool.opzCeilingCPLH,
      ),
      dayparts: dayparts,
    );
  }

  // ── Cycle -> ActiveTargetProfile projection (7.55l.4a) ────────────────
  //
  // Per-Daypart V1 (Slice 1): the projector now also carries the per-period
  // rows through to the persisted profile so per-period consumers can
  // read through `ActiveTargetProfile.daypartFor(...)` without a second
  // join. The persisted parent profile row in SQLite is still the legacy
  // flat shape — the per-period rows live alongside on the cycle's child
  // table and are reattached on read via the cycle DAO.

  Future<void> _syncActiveTargetProfile(TargetCycle cycle) async {
    final projected = TargetCycleActiveTargetProfileProjector.project(cycle);
    // Mirror the cycle's per-period rows onto the active profile shape
    // so consumers reading the profile (via the standard read seam) get
    // the same per-period data the write path emitted onto the cycle.
    final profileWithDayparts = projected.withDayparts(
      cycle.dayparts
          .map((d) => ActiveTargetProfileDaypart(
                servicePeriodId: d.servicePeriodId,
                daypartTargetCPLH: d.targetCPLH,
                daypartTargetSPLH: d.targetSPLH,
                daypartTargetPPA: d.targetPPA,
                daypartOpzFloorCPLH: d.opzFloorCPLH,
                daypartOpzCeilingCPLH: d.opzCeilingCPLH,
              ))
          .toList(),
    );
    await _profileRepo.upsertActiveTargetProfile(profileWithDayparts);
  }

  // ── Benchmark selection summary persistence (7.55l.8c + 7.55p.5g) ─────

  /// Captures the benchmark-selection summary alongside the cycle.
  ///
  /// When [fromRecommendation] is provided, the summary is derived from
  /// the app-owned recommendation output (7.55p.5g) rather than from
  /// potentially stale `BaselineData` seed-selected state. Manager-
  /// override and legacy paths continue to read from `BaselineData`.
  Future<void> _persistSelectionSummary(
    TargetCycle cycle,
    String sourceLabel, {
    RecommendedBenchmarkSelection? fromRecommendation,
  }) async {
    int selectedCount;
    List<double> cplhValues;
    if (fromRecommendation != null) {
      selectedCount = fromRecommendation.selectedRecordIds.length;
      // Use the union band's floor/ceiling to compute the spread-quality
      // label. This matches how the union band is actually surfaced by
      // legacy consumers today. Per-period OPZ bands replace these
      // pooled fields in V1 — this summary path still reads the union
      // for spread-quality continuity until Slice 6's audit overhaul
      // lands and the summary itself becomes per-period.
      // ignore: deprecated_member_use_from_same_package
      final unionFloor = fromRecommendation.unionOpzFloorCPLH;
      // ignore: deprecated_member_use_from_same_package
      final unionCeiling = fromRecommendation.unionOpzCeilingCPLH;
      cplhValues = fromRecommendation.selectedRecordIds.isEmpty
          ? <double>[]
          : <double>[unionFloor, unionCeiling];
    } else {
      final selected =
          BaselineData.records.where((r) => r.isSelected).toList();
      selectedCount = selected.length;
      cplhValues = selected.map((r) => r.cplh).toList();
    }

    final analytics = BaselineSelectionAnalyticsService.computeAnalytics(
      selectedCount,
      cplhValues,
    );
    final summary = BenchmarkSelectionSummary(
      summaryId: '${cycle.cycleId}_summary',
      restaurantId: cycle.restaurantId,
      targetCycleId: cycle.cycleId,
      sourceType: sourceLabel,
      selectedShiftCount: analytics.selectedShiftCount,
      rangeQualityLabel: analytics.rangeQualityLabel,
      rangeQualityMessage: analytics.rangeQualityMessage,
      createdAt: cycle.createdAt,
    );
    await _summaryRepo.upsert(summary);

    // 7.55p.5h + 7.55p.5h-review-fix: project recommendation-quality
    // truth AND the persisted cycle's geometry into BaselineData so the
    // Benchmark graph model can tell an honest story AND draw geometry
    // from the same source of truth as the copy. For manager-override
    // writes we clear the signals so the existing `baselineRangeValidation`
    // derivation remains authoritative for that path.
    if (fromRecommendation != null) {
      BaselineData.applyRecommendationSignals(
        BaselineRecommendationSignals(
          sourceType: sourceLabel,
          overallQuality: fromRecommendation.overallQuality,
          unionBandWidth: fromRecommendation.unionBandWidth,
          selectedShiftCount: selectedCount,
          rangeFloorCPLH: cycle.opzFloorCPLH,
          rangeCeilingCPLH: cycle.opzCeilingCPLH,
          targetCPLH: cycle.targetCPLH,
        ),
      );
    } else {
      BaselineData.clearRecommendationSignals();
    }
  }

  // ── Missing-summary repair (7.56b.1) ──────────────────────────────────
  //
  // When an active cycle row exists without a companion
  // `benchmark_selection_summaries` row — the shape produced by the
  // SQLite seed path's `_ensureDemoSeedCycle` helper — write exactly one
  // summary using the same provenance conventions as cycle writes.
  //
  // This is a narrow recovery path: it never rewrites an existing
  // summary, never duplicates, and never touches `BaselineData`
  // recommendation signals (those belong to
  // `hydrateBenchmarkHonestyFromActiveCycle`).

  Future<void> _ensureSelectionSummaryExists(TargetCycle cycle) async {
    final existing = await _summaryRepo.getByTargetCycleId(cycle.cycleId);
    if (existing != null) return;

    // 7.56b.1-review-fix: mirror `_writeReplacementCycle` evidence routing.
    //   - managerOverride cycles always use the persisted manager-selected
    //     cohort (read directly via `_selectedManagerOverrideCandidates`,
    //     never from the in-memory `BaselineData` bridge which can be
    //     stale on bootstrap / test setup).
    //   - adminReplacement cycles route on `hasPersistedManagerOverride`
    //     exactly as the write path does: override-selected cohort when
    //     present, recommendation pipeline otherwise.
    //   - recommended cycles always use the recommendation pipeline.
    String sourceLabel;
    int selectedCount;
    List<double> cplhValues;

    final useOverrideEvidence =
        cycle.source == TargetCycleSource.managerOverride ||
            (cycle.source == TargetCycleSource.adminReplacement &&
                await BaselineManagerService.instance
                    .hasPersistedManagerOverride(cycle.restaurantId));

    if (useOverrideEvidence) {
      sourceLabel = cycle.source == TargetCycleSource.managerOverride
          ? 'manager_override'
          : 'admin_replacement';
      final selected = await _selectedManagerOverrideCandidates(
        cycle.restaurantId,
        cycle.calibrationWindowEnd,
      );
      selectedCount = selected.length;
      cplhValues = selected.map((c) => c.cplh).toList();
    } else {
      // Recommended + admin-replacement-without-override both derive from
      // the recommendation pipeline. Re-run it against the cycle's
      // calibration-window end so the repaired selected_shift_count
      // reflects the evidence the cycle was built against.
      final recommendation = await BaselineManagerService.instance
          .resolveRecommendedSelection(
              cycle.restaurantId, cycle.calibrationWindowEnd);

      if (cycle.source == TargetCycleSource.adminReplacement) {
        sourceLabel = 'admin_replacement';
      } else {
        sourceLabel = recommendation.isInsufficient
            ? 'cycle_recommended_insufficient'
            : 'cycle_recommended';
      }

      selectedCount = recommendation.selectedRecordIds.length;
      // ignore: deprecated_member_use_from_same_package
      final unionFloor = recommendation.unionOpzFloorCPLH;
      // ignore: deprecated_member_use_from_same_package
      final unionCeiling = recommendation.unionOpzCeilingCPLH;
      cplhValues = recommendation.selectedRecordIds.isEmpty
          ? <double>[]
          : <double>[unionFloor, unionCeiling];
    }

    final analytics = BaselineSelectionAnalyticsService.computeAnalytics(
      selectedCount,
      cplhValues,
    );
    final summary = BenchmarkSelectionSummary(
      summaryId: '${cycle.cycleId}_summary',
      restaurantId: cycle.restaurantId,
      targetCycleId: cycle.cycleId,
      sourceType: sourceLabel,
      selectedShiftCount: analytics.selectedShiftCount,
      rangeQualityLabel: analytics.rangeQualityLabel,
      rangeQualityMessage: analytics.rangeQualityMessage,
      createdAt: cycle.createdAt,
    );
    await _summaryRepo.upsert(summary);
  }

  // ── Active-cycle summary coherence guarantee (7.56b.1) ────────────────
  //
  // Ensures the active cycle (if any) has its companion
  // `benchmark_selection_summaries` row WITHOUT running the
  // cycle-create/auto-refresh logic in [getOrCreateActiveCycle].
  //
  // The seed path (`_ensureDemoSeedCycle`) inserts an active cycle row
  // without a companion summary and relies on lazy repair via
  // [getOrCreateActiveCycle]. That repair is only reached when
  // `WeeklyPlanSnapshotService.getCurrentWeekSnapshot()` *generates* a
  // snapshot — but once a locked weekly_plan_snapshot is pre-seeded
  // (FU-mobile-cold-boot-shift-stale-state, #759), that call
  // short-circuits and the repair never runs, leaving the Benchmark /
  // Data-alignment surface without a summary. This narrow entry point
  // restores cycle⇄summary coherence on the short-circuit path.
  //
  // Idempotent + side-effect-free: delegates to the same
  // [_ensureSelectionSummaryExists] recovery path (never rewrites an
  // existing summary, never duplicates, never touches `BaselineData`
  // recommendation signals) and never writes a cycle.
  Future<void> ensureActiveCycleSelectionSummary(String restaurantId) async {
    final cycle = await _cycleRepo.getActiveCycle(restaurantId);
    if (cycle == null) return;
    await _ensureSelectionSummaryExists(cycle);
  }

  // ── Bootstrap honesty hydration (7.55p.5h-review-fix) ─────────────────
  //
  // Recommendation-honesty signals on `BaselineData` are in-memory. Cycle
  // writes set them inline through `_persistSelectionSummary`, but a fresh
  // app launch only sees the persisted cycle + summary, not the in-memory
  // signal. Call this once on bootstrap (and on explicit refresh) to
  // rehydrate honesty from the active cycle so the Benchmark graph
  // tells the same story across restarts.
  //
  // Routing mirrors the write-time logic:
  //   - No active cycle       → clear signals.
  //   - Manager-override cycle or persisted manager-selected keys
  //                            → clear signals (existing override branch wins).
  //   - Recommended cycle     → re-run the recommendation service against
  //                            the cycle's calibration window so the tier
  //                            matches what the cycle was built from, and
  //                            apply signals with the cycle's geometry.
  Future<void> hydrateBenchmarkHonestyFromActiveCycle(
      String restaurantId) async {
    final cycle = await _cycleRepo.getActiveCycle(restaurantId);
    if (cycle == null) {
      BaselineData.clearRecommendationSignals();
      return;
    }

    final hasOverride = await BaselineManagerService.instance
        .hasPersistedManagerOverride(restaurantId);
    if (hasOverride || cycle.source == TargetCycleSource.managerOverride) {
      BaselineData.clearRecommendationSignals();
      return;
    }

    // Recover the recommendation tier against the cycle's calibration
    // window so the hydrated tier matches the cycle's own build-time
    // evidence. For admin-replacement recommended cycles this still
    // uses the recommendation pipeline (7.55p.5g admin branch).
    final recommendation = await BaselineManagerService.instance
        .resolveRecommendedSelection(
            restaurantId, cycle.calibrationWindowEnd);

    final sourceLabel = recommendation.isInsufficient
        ? 'cycle_recommended_insufficient'
        : 'cycle_recommended';

    BaselineData.applyRecommendationSignals(
      BaselineRecommendationSignals(
        sourceType: sourceLabel,
        overallQuality: recommendation.overallQuality,
        unionBandWidth: recommendation.unionBandWidth,
        selectedShiftCount: recommendation.selectedRecordIds.length,
        rangeFloorCPLH: cycle.opzFloorCPLH,
        rangeCeilingCPLH: cycle.opzCeilingCPLH,
        targetCPLH: cycle.targetCPLH,
      ),
    );
  }

  // ── Date helpers (UTC to avoid DST issues) ────────────────────────────

  static String _addDays(String isoDate, int days) {
    final parts = isoDate.split('-');
    final dt = DateTime.utc(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    final result = dt.add(Duration(days: days));
    return '${result.year}-${result.month.toString().padLeft(2, '0')}'
        '-${result.day.toString().padLeft(2, '0')}';
  }

  // ── 128-bit cryptographic-random hex (CODE_HEALTH L15) ────────────────────
  // 16 random bytes → 32 hex chars. Equivalent collision resistance to
  // UUID v4. Used for cycleId so two replacement writes within the same
  // millisecond cannot collide. `dart:math.Random.secure()` is backed by
  // the platform CSPRNG (browser `crypto.getRandomValues`, OS urandom).
  static final math.Random _secureRandom = math.Random.secure();
  static String _random128BitHex() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Internal: pairs a freshly-built [ActiveTargetProfile] with the
/// summary source label used by the cycle write path. Different paths
/// (manager override, app-owned recommendation, insufficient fallback)
/// carry different source labels so the benchmark-selection summary
/// reflects the real provenance.
class ActiveTargetProfileBuildResult {
  final ActiveTargetProfile profile;
  final String sourceLabel;
  const ActiveTargetProfileBuildResult({
    required this.profile,
    required this.sourceLabel,
  });
}

/// Per-Daypart V1 (Slice 1) — internal carrier for recommended-path
/// writes. Pairs the freshly-built [ActiveTargetProfile] with the
/// matching per-period [TargetCycleDaypart] rows the cycle write path
/// will persist on the cycle's child table.
class _RecommendedBuildResult {
  final ActiveTargetProfile profile;
  final List<TargetCycleDaypart> dayparts;
  final String sourceLabel;
  const _RecommendedBuildResult({
    required this.profile,
    required this.dayparts,
    required this.sourceLabel,
  });
}

/// Per-Daypart V1 (Slice 1) — internal carrier for manager-override
/// (and admin-replacement-with-override) cycle writes.
class _OverrideBuildResult {
  final ActiveTargetProfile profile;
  final List<TargetCycleDaypart> dayparts;
  const _OverrideBuildResult({
    required this.profile,
    required this.dayparts,
  });
}
