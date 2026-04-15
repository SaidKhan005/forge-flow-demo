// Phase 7.55l.2a+2b+2c+3a+3b — TargetCycle persistence, auto-refresh,
// override write path.
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
import '../infrastructure/persistence/sqlite/repositories/sqlite_benchmark_selection_summary_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'app_notification_service.dart';
import 'baseline_manager_service.dart';
import 'baseline_selection_analytics_service.dart';
import 'legacy_fixture_data.dart';
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
  /// - If the active cycle is past its effective end, creates a new
  ///   recommended cycle (auto-refresh). All existing active cycles are
  ///   deactivated before the new one is written.
  /// - Otherwise returns the active cycle unchanged.
  Future<TargetCycle> getOrCreateActiveCycle(
      String restaurantId, String businessDate) async {
    final existing = await _cycleRepo.getActiveCycle(restaurantId);

    if (existing == null) {
      return _createRecommendedCycle(restaurantId, businessDate);
    }

    if (TargetCyclePolicy.needsAutoRefresh(existing, businessDate)) {
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
    if (hasOverride) {
      final selected = await _selectedManagerOverrideCandidates(
        restaurantId,
        businessDate,
      );
      build = ActiveTargetProfileBuildResult(
        profile: _buildManagerOverrideProfile(
          restaurantId: restaurantId,
          wageFoh: wageCtx.fohWage ?? MeridianConfig.fohWage,
          wageBoh: wageCtx.bohWage ?? MeridianConfig.bohWage,
          selectedCandidates: selected,
          sourceType: source == TargetCycleSource.adminReplacement
              ? 'admin_replacement'
              : 'manager_override',
        ),
        sourceLabel: source.label,
      );
    } else {
      recommendation = await BaselineManagerService.instance
          .resolveRecommendedSelection(restaurantId, businessDate);
      build = _buildRecommendedProfile(
        restaurantId: restaurantId,
        wageFoh: wageCtx.fohWage,
        wageBoh: wageCtx.bohWage,
        recommendation: recommendation,
      );
    }

    final profile = build.profile;

    // Deactivate all active cycles for the restaurant.
    await SqliteTargetCycleRepository.instance
        .deactivateAllForRestaurant(restaurantId);

    // Calibration window matches the actual benchmark window used to
    // rebuild standards — not the prior cycle's potentially stale window.
    final calibrationEnd = businessDate;
    final calibrationStart = _addDays(businessDate, -59);

    // Timestamp-based cycleId ensures repeated same-day replacements
    // produce distinct historical rows instead of overwriting via upsert.
    final nowUtc = DateTime.now().toUtc();
    final now = nowUtc.toIso8601String();
    final replacement = TargetCycle(
      cycleId:
          '${restaurantId}_${source.label}_${nowUtc.millisecondsSinceEpoch}',
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
    final build = _buildRecommendedProfile(
      restaurantId: restaurantId,
      wageFoh: wageCtx.fohWage,
      wageBoh: wageCtx.bohWage,
      recommendation: recommendation,
    );

    final profile = build.profile;

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
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );

    await _cycleRepo.upsertCycle(cycle);
    await _syncActiveTargetProfile(cycle);
    await _persistSelectionSummary(
      cycle,
      build.sourceLabel,
      fromRecommendation: recommendation,
    );
    return cycle;
  }

  /// Builds a profile for the recommended path. When the recommendation
  /// is `'insufficient'`, falls back to `MeridianConfig` hard defaults
  /// rather than the seed-selected `BaselineData` cohort. That keeps
  /// the bridge honest: we either teach from app-owned recommendation
  /// output, or we admit we do not have a recommendation and fall back
  /// to the Config Default standards.
  ActiveTargetProfileBuildResult _buildRecommendedProfile({
    required String restaurantId,
    required double? wageFoh,
    required double? wageBoh,
    required RecommendedBenchmarkSelection recommendation,
  }) {
    final resolvedFohWage = wageFoh ?? MeridianConfig.fohWage;
    final resolvedBohWage = wageBoh ?? MeridianConfig.bohWage;
    if (recommendation.isInsufficient) {
      return ActiveTargetProfileBuildResult(
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
        sourceLabel: 'cycle_recommended_insufficient',
      );
    }

    return ActiveTargetProfileBuildResult(
      profile: ActiveTargetProfile.build(
        restaurantId: restaurantId,
        sourceType: 'system_baseline',
        targetCPLH: recommendation.pooledRecommendedTargetCPLH,
        targetSPLH: recommendation.pooledRecommendedTargetSPLH,
        targetPPA: recommendation.pooledRecommendedTargetPPA,
        fohWage: resolvedFohWage,
        bohWage: resolvedBohWage,
        opzFloorCPLH: recommendation.unionOpzFloorCPLH,
        opzCeilingCPLH: recommendation.unionOpzCeilingCPLH,
      ),
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

  ActiveTargetProfile _buildManagerOverrideProfile({
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

    double targetCPLH = 0;
    double targetSPLH = 0;
    double targetPPA = 0;
    double opzFloor = selectedCandidates.first.cplh;
    double opzCeiling = selectedCandidates.first.cplh;

    for (final candidate in selectedCandidates) {
      targetCPLH += candidate.cplh;
      targetSPLH += candidate.splh;
      targetPPA += candidate.ppa;
      if (candidate.cplh < opzFloor) opzFloor = candidate.cplh;
      if (candidate.cplh > opzCeiling) opzCeiling = candidate.cplh;
    }

    final count = selectedCandidates.length.toDouble();
    return ActiveTargetProfile.build(
      restaurantId: restaurantId,
      sourceType: sourceType,
      targetCPLH: targetCPLH / count,
      targetSPLH: targetSPLH / count,
      targetPPA: targetPPA / count,
      fohWage: wageFoh,
      bohWage: wageBoh,
      opzFloorCPLH: opzFloor,
      opzCeilingCPLH: opzCeiling,
    );
  }

  // ── Cycle -> ActiveTargetProfile projection (7.55l.4a) ────────────────

  Future<void> _syncActiveTargetProfile(TargetCycle cycle) async {
    final profile =
        TargetCycleActiveTargetProfileProjector.project(cycle);
    await _profileRepo.upsertActiveTargetProfile(profile);
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
      // legacy consumers today.
      cplhValues = fromRecommendation.selectedRecordIds.isEmpty
          ? <double>[]
          : <double>[
              fromRecommendation.unionOpzFloorCPLH,
              fromRecommendation.unionOpzCeilingCPLH,
            ];
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
