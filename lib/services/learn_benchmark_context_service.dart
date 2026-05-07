// Phase 7.55l.8a — Learn Benchmark Context Service
//
// Resolves LearnBenchmarkContext from persisted app authority so
// LearnTeachingAnalyzer no longer reads BaselineData directly.
//
// Source label and targets: from persisted ActiveTargetProfile (canonical).
// Selected count + range quality: from persisted BenchmarkSelectionSummary
// tied to the active TargetCycle (canonical, as of 7.55l.8c).
//
// 7.55l.8a1: tightened fallback semantics. Bridge fallback is only used
// for explicit bridge-only mode and genuine no-profile bootstrap.
// Unexpected repository failures propagate instead of silently reverting
// to bridge truth.
//
// 7.55l.8b: canonical profile-present path no longer reads BaselineData
// for selected-shift count or range-quality analytics. Those now come
// from BaselineSelectionAnalyticsService.
//
// 7.55l.8b1: analytics resolution is now source-aware. Profile source type
// is passed to the analytics service so override-driven profiles compute
// from persisted selected-key state, while default recommended/system
// profiles use bridge analytics (not an empty override table).
//
// 7.55l.8c: canonical path now reads selection analytics from a persisted
// BenchmarkSelectionSummary tied to the active TargetCycle. The summary
// is persisted at cycle-build time by TargetCycleService.
//
// 7.55l.8c1: tightened missing-summary recovery. If a cycle exists but
// its summary is unexpectedly missing (pre-8c compatibility or partial
// migration), the service now does a one-time backfill: computes
// compatibility analytics, materializes a BenchmarkSelectionSummary,
// persists it, then uses the persisted values. This ensures subsequent
// reads use the canonical persisted path instead of silently falling
// back to transient compatibility analytics indefinitely.
//
// 7.55l.8d: profile-without-cycle recovery. If an active profile exists
// but no active cycle is found, the service now treats this as a
// recoverable app-state inconsistency instead of silently falling back
// to bridge-era compatibility analytics. It resolves the current
// benchmark anchor date (mock replay → latest closed), calls
// TargetCycleService.getOrCreateActiveCycle to recover the cycle, then
// re-reads the profile and continues on the canonical cycle/summary path.
// If no anchor date is available, throws an explicit StateError.
//
// 7.55l.8d1: after cycle recovery, the post-recovery active profile is
// required. If the re-read returns null, the service throws an explicit
// StateError instead of silently proceeding with stale pre-recovery
// profile values.
// BaselineData bridge is no longer used in the canonical path.

import '../domain/models/active_target_profile.dart';
import '../domain/models/benchmark_selection_summary.dart';
import '../domain/models/target_cycle.dart';
import '../domain/repositories/benchmark_selection_summary_repository.dart';
import '../domain/repositories/restaurant_scope_repository.dart';
import '../domain/repositories/shift_record_repository.dart';
import '../domain/repositories/target_cycle_repository.dart';
import '../domain/repositories/target_profile_repository.dart';
import '../domain/services/utc_metadata_timestamp.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_benchmark_selection_summary_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import '../models/learn_benchmark_context.dart';
import 'package:forge_and_flow/services/baseline_selection_analytics_service.dart';
import 'baseline_authority_service.dart';
import 'target_cycle_service.dart';

class LearnBenchmarkContextService {
  LearnBenchmarkContextService._();
  static final LearnBenchmarkContextService instance =
      LearnBenchmarkContextService._();

  final RestaurantScopeRepository _scopeRepo =
      SqliteRestaurantScopeRepository.instance;
  final TargetProfileRepository _profileRepo =
      SqliteTargetProfileRepository.instance;
  final TargetCycleRepository _cycleRepo =
      SqliteTargetCycleRepository.instance;
  final BenchmarkSelectionSummaryRepository _summaryRepo =
      SqliteBenchmarkSelectionSummaryRepository.instance;
  final ShiftRecordRepository _shiftRepo =
      SqliteShiftRecordRepository.instance;

  // ── Bridge-only override ─────────────────────────────────────────────────
  // When set, resolve() returns the bridge fallback without attempting
  // repository access. Used in widget tests where SQLite is not
  // initialized, and cleared between tests.

  static bool _useBridgeOnly = false;

  static void enableBridgeOnly() => _useBridgeOnly = true;
  static void disableBridgeOnly() => _useBridgeOnly = false;

  // ── Test injection seam ──────────────────────────────────────────────────
  // Overrides the canonical repository resolution path for unit tests.
  // - Return non-null to simulate a successful canonical read
  // - Return null to simulate the no-profile bootstrap path
  // - Throw to simulate a repository failure
  // Clear between tests.

  static Future<LearnBenchmarkContext?> Function()? testCanonicalOverride;

  // 7.55l.8c1: Per-repository test overrides for recovery-path testing.
  // When set and testCanonicalOverride is null, resolve() uses these
  // delegates instead of singleton repository instances. This enables
  // testing the missing-summary recovery logic without SQLite.
  // Clear between tests.

  static Future<String> Function()? testGetRestaurantId;
  static Future<ActiveTargetProfile?> Function(String restaurantId)?
      testGetProfile;
  static Future<TargetCycle?> Function(String restaurantId)? testGetCycle;
  static Future<BenchmarkSelectionSummary?> Function(String cycleId)?
      testGetSummary;
  static Future<void> Function(BenchmarkSelectionSummary summary)?
      testPersistSummary;

  // 7.55l.8d: Per-repository test overrides for cycle recovery testing.
  // testGetAnchorDate: controls the mock-replay / latest-closed anchor
  // testRecoverCycle: controls what getOrCreateActiveCycle returns
  // Clear between tests.

  static Future<String?> Function(String restaurantId)? testGetAnchorDate;
  static Future<TargetCycle> Function(String restaurantId, String anchorDate)?
      testRecoverCycle;

  Future<LearnBenchmarkContext> resolve() async {
    if (_useBridgeOnly) {
      return _bridgeFallback();
    }

    // Test injection seam — bypasses real repositories
    final override = testCanonicalOverride;
    if (override != null) {
      final result = await override();
      return result ?? _bridgeFallback();
    }

    // Canonical path — repository errors propagate, not silently caught.
    // 7.55l.8c1: per-repo test overrides checked first for recovery testing.
    final restaurantId = testGetRestaurantId != null
        ? await testGetRestaurantId!()
        : await _scopeRepo.getActiveRestaurantId();
    var profile = testGetProfile != null
        ? await testGetProfile!(restaurantId)
        : await _profileRepo.getActiveTargetProfile(restaurantId);

    if (profile != null) {
      var cycle = testGetCycle != null
          ? await testGetCycle!(profile.restaurantId)
          : await _cycleRepo.getActiveCycle(profile.restaurantId);

      // 7.55l.8d: if profile exists but cycle is missing, recover the
      // cycle from the app's current benchmark anchor instead of silently
      // falling back to bridge-era compatibility analytics.
      if (cycle == null) {
        final anchorDate = testGetAnchorDate != null
            ? await testGetAnchorDate!(profile.restaurantId)
            : await _resolveAnchorDate(profile.restaurantId);

        if (anchorDate == null) {
          throw StateError(
              'Learn: active profile exists but no active cycle and no '
              'anchor date available for cycle recovery. '
              'restaurantId=${profile.restaurantId}');
        }

        cycle = testRecoverCycle != null
            ? await testRecoverCycle!(profile.restaurantId, anchorDate)
            : await TargetCycleService.instance
                .getOrCreateActiveCycle(profile.restaurantId, anchorDate);

        // 7.55l.8d1: re-read profile since getOrCreateActiveCycle projects
        // and persists a fresh ActiveTargetProfile. The post-recovery
        // profile is required — do not silently proceed with stale
        // pre-recovery values if the re-read fails.
        final recoveredProfile = testGetProfile != null
            ? await testGetProfile!(restaurantId)
            : await _profileRepo.getActiveTargetProfile(restaurantId);
        if (recoveredProfile == null) {
          throw StateError(
              'Learn: cycle recovery succeeded but post-recovery active '
              'profile is missing. '
              'restaurantId=$restaurantId, '
              'recoveredCycleId=${cycle.cycleId}');
        }
        profile = recoveredProfile;
      }

      // 7.55l.8c: load persisted benchmark-selection summary from the
      // active cycle. If summary exists, selection analytics come from it
      // (no BaselineData reads).
      // 7.55l.8c1: if missing, do a one-time backfill rather than
      // silently falling back to transient compatibility analytics.
      var summary = testGetSummary != null
          ? await testGetSummary!(cycle.cycleId)
          : await _summaryRepo.getByTargetCycleId(cycle.cycleId);
      if (summary == null) {
        // 7.55l.8c1: one-time compatibility recovery backfill.
        // Missing summary for an active cycle is a data gap (pre-8c
        // cycle or partial migration). Compute compatibility analytics,
        // materialize and persist a BenchmarkSelectionSummary so
        // subsequent reads use the canonical persisted path instead of
        // silently falling back to transient compatibility analytics.
        final analytics =
            await BaselineSelectionAnalyticsService.instance.resolve(
                sourceType: profile.sourceType);
        summary = BenchmarkSelectionSummary(
          summaryId: '${cycle.cycleId}_summary',
          restaurantId: cycle.restaurantId,
          targetCycleId: cycle.cycleId,
          sourceType: profile.sourceType,
          selectedShiftCount: analytics.selectedShiftCount,
          rangeQualityLabel: analytics.rangeQualityLabel,
          rangeQualityMessage: analytics.rangeQualityMessage,
          createdAt: nowIsoUtc(),
        );
        if (testPersistSummary != null) {
          await testPersistSummary!(summary);
        } else {
          await _summaryRepo.upsert(summary);
        }
      }

      return LearnBenchmarkContext(
        benchmarkSourceLabel:
            sourceLabelFromProfileType(profile.sourceType),
        selectedShiftCount: summary.selectedShiftCount,
        targetCPLH: profile.targetCPLH,
        targetSPLH: profile.targetSPLH,
        targetPPA: profile.targetPPA,
        rangeQualityLabel: summary.rangeQualityLabel,
        rangeQualityMessage: summary.rangeQualityMessage,
      );
    }

    // No profile yet — genuine bootstrap (first launch before cycle
    // creation). This is the only non-bridge-only path that falls back.
    return _bridgeFallback();
  }

  // ── Anchor date resolution (7.55l.8d) ────────────────────────────────────
  // Same precedence as BaselineManagerService / DemandForecastContextService:
  // 1. Mock replay business date
  // 2. Latest closed business date

  Future<String?> _resolveAnchorDate(String restaurantId) async {
    final mockDate = await SqliteDatabase.instance
        .getMockReplayBusinessDate(restaurantId);
    if (mockDate != null) return mockDate;
    return _shiftRepo.getLatestClosedBusinessDate(restaurantId);
  }

  // ── Bridge fallback ──────────────────────────────────────────────────────

  LearnBenchmarkContext _bridgeFallback() {
    return LearnBenchmarkContext(
      benchmarkSourceLabel: BaselineData.hasManagerOverride
          ? 'MANAGER STAR SHIFTS'
          : 'SYSTEM BENCHMARK SET',
      selectedShiftCount: BaselineData.selectedRecordCount,
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      rangeQualityLabel: BaselineData.baselineRangeValidation.statusLabel,
      rangeQualityMessage: BaselineData.baselineRangeValidation.message,
    );
  }

  // ── Source label mapping ──────────────────────────────────────────────────
  // Handles both legacy pre-cycle and cycle-era source types from
  // ActiveTargetProfile.sourceType / TargetCycleActiveTargetProfileProjector.

  static String sourceLabelFromProfileType(String sourceType) {
    switch (sourceType) {
      case 'system_baseline':
      case 'cycle_recommended':
        return 'SYSTEM BENCHMARK SET';
      case 'manager_override':
      case 'cycle_manager_override':
        return 'MANAGER STAR SHIFTS';
      case 'admin_replacement':
      case 'cycle_admin_replacement':
        return 'ADMIN REPLACEMENT';
      default:
        return 'SYSTEM BENCHMARK SET';
    }
  }
}