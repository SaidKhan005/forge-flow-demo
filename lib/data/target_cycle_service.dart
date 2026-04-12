// Phase 7.55l.2a+2b+2c+3a+3b — TargetCycle persistence, auto-refresh,
// override write path.
//
// Narrow runtime seam: load/create/auto-refresh/override the active
// TargetCycle. Does not migrate consumers or change Benchmark/Manager
// Override UX.
//
// 7.55l.2b fixes:
// - recommended-cycle creation now rebuilds fresh from current
//   BaselineData + resolved wages instead of reading potentially stale
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

import '../domain/models/benchmark_selection_summary.dart';
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
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
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
      return _createRecommendedCycle(restaurantId, businessDate);
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

    // Build fresh locked standards from current app truth.
    final profile = SqliteDatabase.buildActiveTargetProfileFromBaseline(
      restaurantId,
      fohWageOverride: wageCtx.fohWage,
      bohWageOverride: wageCtx.bohWage,
    );

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
    await _persistSelectionSummary(replacement, source.label);
    return replacement;
  }

  // ── Bridge: build recommended cycle from current app truth ────────────

  Future<TargetCycle> _createRecommendedCycle(
      String restaurantId, String businessDate) async {
    // Re-prime benchmark context for the requested business date's 60-day
    // window. This ensures buildActiveTargetProfileFromBaseline reads from
    // fresh BaselineData anchored to the correct date, not stale in-memory
    // state left over from a prior load or screen interaction.
    await BaselineManagerService.instance
        .primeBaselineContextForDate(restaurantId, businessDate);

    // Resolve wages fresh from the wage-authority waterfall.
    final wageCtx =
        await WageStandardContextService.instance.resolve(restaurantId);

    // Build from freshly primed BaselineData + resolved wages.
    // This is the transitional bridge — 7.55l.4 will project the profile
    // from the cycle instead.
    final profile = SqliteDatabase.buildActiveTargetProfileFromBaseline(
      restaurantId,
      fohWageOverride: wageCtx.fohWage,
      bohWageOverride: wageCtx.bohWage,
    );

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
    await _persistSelectionSummary(cycle, 'cycle_recommended');
    return cycle;
  }

  // ── Cycle -> ActiveTargetProfile projection (7.55l.4a) ────────────────

  Future<void> _syncActiveTargetProfile(TargetCycle cycle) async {
    final profile =
        TargetCycleActiveTargetProfileProjector.project(cycle);
    await _profileRepo.upsertActiveTargetProfile(profile);
  }

  // ── Benchmark selection summary persistence (7.55l.8c) ────────────────

  /// Captures the benchmark-selection summary from the currently effective
  /// BaselineData state (which must have been freshly primed before this
  /// call) and persists it alongside the cycle.
  Future<void> _persistSelectionSummary(
      TargetCycle cycle, String sourceLabel) async {
    final selected = BaselineData.records.where((r) => r.isSelected).toList();
    final analytics = BaselineSelectionAnalyticsService.computeAnalytics(
      selected.length,
      selected.map((r) => r.cplh).toList(),
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
