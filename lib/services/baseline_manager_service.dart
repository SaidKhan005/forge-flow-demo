// Phase 5 — Baseline Manager Service
// Loads historical closed shifts as selectable baseline candidates,
// persists the manager's selection, and keeps the remaining
// bridge-era Benchmark context in sync for compatibility surfaces.
//
// Phase 7.55f.2: Candidate loading now uses a true 60-calendar-day date
// window anchored to the latest closed business_date, replacing the old
// 8-week approximation.
//
// Phase 7.55f.4: Anchor prefers the mock replay current business date
// when available, falling back to the latest closed business_date.
//
// Phase 7.55m.1: Planning-anchor resolution now delegates to
// BusinessDateAuthorityService instead of duplicating the mock-replay →
// latest-closed precedence locally. Day-order maps now use the canonical
// source from BusinessDateAuthorityService.
//
// After changing active target authority through the canonical cycle path,
// notifies any registered active-target listener so the app-wide notifier
// path can refresh.

import '../domain/models/recommended_benchmark_selection.dart';
import '../domain/repositories/baseline_selection_repository.dart';
import '../domain/repositories/restaurant_scope_repository.dart';
import '../domain/repositories/shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_baseline_selection_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import '../models/baseline_candidate_shift.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../domain/services/target_cycle_policy.dart';
import 'business_date_authority_service.dart';
import 'baseline_authority_service.dart';
import '../domain/services/recommended_benchmark_selection_service.dart';
import 'restaurant_timing_config_read_service.dart';
import 'star_target_selection_write_service.dart';
import 'target_cycle_service.dart';

/// Callback type for active-target profile change events.
typedef ActiveTargetChangedCallback = Future<void> Function();

class BaselineManagerService {
  BaselineManagerService._();
  static final BaselineManagerService instance = BaselineManagerService._();

  final ShiftRecordRepository _shiftRepo = SqliteShiftRecordRepository.instance;
  final BaselineSelectionRepository _baselineRepo =
      SqliteBaselineSelectionRepository.instance;
  final RestaurantScopeRepository _scopeRepo =
      SqliteRestaurantScopeRepository.instance;

  /// Optional callback invoked after active target authority changes.
  /// Set by the app-wide ActiveTargetProfileNotifier to receive change events.
  ActiveTargetChangedCallback? onActiveTargetChanged;

  /// Production/mobile server-truth writer. When present, star selection
  /// changes must land through the proxy before the local SQLite mirror is
  /// updated. Demo/offline builds leave this null and keep the local cycle
  /// compatibility path below.
  BaselineServerSelectionWriter? serverSelectionWriter;

  Future<String> _activeRestaurantId() => _scopeRepo.getActiveRestaurantId();

  /// Resolves the operator-configured service-period definitions for the
  /// active restaurant. Period set, labels, and ordering come from the
  /// persisted timing config, never a hardcoded daypart list. Falls back
  /// to the canonical fixture-era definitions only when no timing config
  /// has been persisted yet (mirrors the canonical pattern in
  /// `BenchmarkTrackerReadService`).
  Future<List<ServicePeriodDefinition>> resolveOperatorDefs() async {
    final timingConfig = await RestaurantTimingConfigReadService.instance
        .getActiveTimingConfig();
    return (timingConfig?.servicePeriodDefinitions.isNotEmpty ?? false)
        ? timingConfig!.servicePeriodDefinitions
        : ServicePeriodDefinitionResolver.demoDefinitions;
  }

  /// Pre-commit once-per-60-day override gate. Reads the active
  /// [TargetCycle] for the active restaurant and returns whether the
  /// manager may still land an override on the current planning anchor
  /// date. Read-only: does not touch the selection write path. Returns
  /// `false` when the anchor date cannot be resolved (no candidates yet).
  Future<bool> canManagerOverrideNow() async {
    final restaurantId = await _activeRestaurantId();
    final businessDate = await BusinessDateAuthorityService.instance
        .resolvePlanningAnchorDate(restaurantId);
    if (businessDate == null) return false;
    final cycle = await TargetCycleService.instance
        .getOrCreateActiveCycle(restaurantId, businessDate);
    return TargetCyclePolicy.canManagerOverride(cycle, businessDate);
  }

  // ── Candidate loading ──────────────────────────────────────────────────────

  /// Loads candidates inside the true rolling 60-calendar-day window.
  ///
  /// Planning-anchor resolution delegates to [BusinessDateAuthorityService].
  Future<List<BaselineCandidateShift>> getCandidateShifts() async {
    final restaurantId = await _activeRestaurantId();
    final anchorDate = await BusinessDateAuthorityService.instance
        .resolvePlanningAnchorDate(restaurantId);
    if (anchorDate == null) return [];

    final endDate = anchorDate;
    final startDate = BusinessDateAuthorityService.subtractDays(anchorDate, 59);

    return getCandidateShiftsForDateRange(startDate, endDate);
  }

  /// Loads candidates for an explicit date range. Useful for testability
  /// and future calendar navigation (7.55f.3).
  ///
  /// 7.55p.5g-review-fix: accepts an optional [restaurantId] so callers
  /// with explicit scope (recommendation path, cross-restaurant admin
  /// work) route through the passed id instead of silently resolving
  /// the active restaurant. When [restaurantId] is omitted, the active
  /// scope is used — that preserves the long-standing convenience
  /// behavior for [getCandidateShifts] and other active-scope consumers.
  ///
  /// Selected-key lookup is scoped to the same id so
  /// `candidate.isSelected` reflects the requested restaurant's
  /// persisted manager selection, not the active restaurant's.
  Future<List<BaselineCandidateShift>> getCandidateShiftsForDateRange(
    String startDate,
    String endDate, {
    String? restaurantId,
  }) async {
    final scopedId = restaurantId ?? await _activeRestaurantId();
    final closedShifts = await _shiftRepo.getClosedShiftsInDateRange(
      scopedId,
      startDate,
      endDate,
    );
    final selectedKeys = await _baselineRepo.getSelectedRecordKeys(scopedId);

    final candidates = closedShifts.map((shift) {
      final recordKey = '${shift.weekId}|${shift.dayLabel}|${shift.daypart}';
      return BaselineCandidateShift(
        recordKey: recordKey,
        weekId: shift.weekId,
        weekLabel: shift.weekId,
        dayLabel: shift.dayLabel,
        daypart: shift.daypart,
        covers: shift.covers,
        cplh: shift.cplh,
        splh: shift.splh,
        ppa: shift.ppa,
        primaryLeverId: shift.normalizedLeverId,
        isSelected: selectedKeys.contains(recordKey),
        businessDate: shift.businessDate,
        actualLaborPct: shift.totalLaborPct,
        hasActualLaborPctTruth: shift.hasSourceBackedTotalLaborPct,
      );
    }).toList();

    final defs = await resolveOperatorDefs();
    _sortCandidates(candidates, defs);
    return candidates;
  }

  static void _sortCandidates(
    List<BaselineCandidateShift> candidates,
    List<ServicePeriodDefinition> defs,
  ) {
    // Canonical day ordering from BusinessDateAuthorityService.
    const dayOrder = BusinessDateAuthorityService.canonicalDayOrder;

    candidates.sort((a, b) {
      final dp = ServicePeriodDefinitionResolver.sortIndex(
        defs,
        a.daypart,
      ).compareTo(ServicePeriodDefinitionResolver.sortIndex(defs, b.daypart));
      if (dp != 0) return dp;
      final cplh = b.cplh.compareTo(a.cplh);
      if (cplh != 0) return cplh;
      final splh = b.splh.compareTo(a.splh);
      if (splh != 0) return splh;
      final ppa = b.ppa.compareTo(a.ppa);
      if (ppa != 0) return ppa;
      final week = b.weekId.compareTo(a.weekId);
      if (week != 0) return week;
      return (dayOrder[a.dayLabel] ?? 99).compareTo(dayOrder[b.dayLabel] ?? 99);
    });
  }

  // ── Recommended benchmark selection (7.55p.5g) ─────────────────────────────
  //
  // Resolves the app-owned recommendation for the default recommended/system
  // source path. Does NOT read manager-selected keys and does NOT write
  // fake selection keys — callers should keep manager override precedence
  // separate (see hasPersistedManagerOverride).

  /// Returns true when the restaurant has any persisted manager-selected
  /// benchmark record keys. Used by `TargetCycleService` to route between
  /// the manager-override path and the app-owned recommendation path
  /// without creating fake override rows.
  Future<bool> hasPersistedManagerOverride(String restaurantId) async {
    final keys = await _baselineRepo.getSelectedRecordKeys(restaurantId);
    return keys.isNotEmpty;
  }

  /// Runs the 7.55p.5g recommendation pipeline over the 60-day closed-shift
  /// window ending at [businessDate] for the explicit [restaurantId].
  ///
  /// Pure data path: loads eligible candidates scoped to [restaurantId],
  /// passes them to [RecommendedBenchmarkSelectionService], returns the
  /// result. No writes to the baseline-selection table, no
  /// manager-override key fabrication, no `BaselineData` mutation.
  ///
  /// 7.55p.5g-review-fix: the inner candidate loader now honors the
  /// passed [restaurantId] instead of silently falling back to the
  /// active-scope restaurant.
  Future<RecommendedBenchmarkSelection> resolveRecommendedSelection(
    String restaurantId,
    String businessDate, {
    RecommendedSelectionConfig config = const RecommendedSelectionConfig(),
  }) async {
    final endDate = businessDate;
    final startDate = BusinessDateAuthorityService.subtractDays(
      businessDate,
      59,
    );
    final candidates = await getCandidateShiftsForDateRange(
      startDate,
      endDate,
      restaurantId: restaurantId,
    );
    return RecommendedBenchmarkSelectionService.instance.select(
      candidates,
      config: config,
    );
  }

  // ── Date-anchored baseline context priming ─────────────────────────────────
  // Transitional bridge for TargetCycleService: ensures BaselineData reflects
  // the correct 60-day benchmark context for an explicit business date before
  // the canonical cycle/profile writer runs. Does not persist the active
  // target profile — the caller builds a TargetCycle from the primed state.

  /// Primes in-memory BaselineData for the 60-day window ending at
  /// [businessDate] for the explicit [restaurantId]. Loads closed shifts
  /// from DB, applies them as historical context, and re-applies manager
  /// override state from the persisted selection.
  ///
  /// 7.55p.5g-review-fix: the inner candidate loader now honors the
  /// passed [restaurantId] instead of silently falling back to the
  /// active-scope restaurant.
  Future<void> primeBaselineContextForDate(
    String restaurantId,
    String businessDate,
  ) async {
    final endDate = businessDate;
    final startDate = BusinessDateAuthorityService.subtractDays(
      businessDate,
      59,
    );

    final candidates = await getCandidateShiftsForDateRange(
      startDate,
      endDate,
      restaurantId: restaurantId,
    );

    if (candidates.isEmpty) {
      BaselineData.clearHistoricalContext();
      BaselineData.clearManagerOverride();
      return;
    }

    final context = candidates
        .map(
          (c) => DaypartBaseline(
            daypart: c.daypart,
            cplh: c.cplh,
            splh: c.splh,
            ppa: c.ppa,
            covers: c.covers,
            isSelected: c.isSelected,
          ),
        )
        .toList();

    BaselineData.applyHistoricalContext(context);

    final selected = candidates.where((c) => c.isSelected).toList();
    if (selected.isEmpty) {
      BaselineData.clearManagerOverride();
    } else {
      BaselineData.applyManagerOverride(context);
    }
  }

  // ── Apply persisted selection to BaselineData ──────────────────────────────
  // Compatibility bridge: BaselineData is still updated in-memory for
  // Benchmark/Learn helper paths that have not fully migrated yet.
  // This bridge must not rewrite the persisted ActiveTargetProfile —
  // the active cycle remains the canonical profile authority.

  Future<void> primeManagerOverride() async {
    final candidates = await getCandidateShifts();

    if (candidates.isEmpty) {
      // Compatibility bridge: clear in-memory BaselineData state
      BaselineData.clearHistoricalContext();
      BaselineData.clearManagerOverride();
      return;
    }

    // All candidates already come from the true 60-day date window.
    final context = candidates
        .map(
          (c) => DaypartBaseline(
            daypart: c.daypart,
            cplh: c.cplh,
            splh: c.splh,
            ppa: c.ppa,
            covers: c.covers,
            isSelected: c.isSelected,
          ),
        )
        .toList();

    // Compatibility bridge: update in-memory BaselineData with 60-day window
    BaselineData.applyHistoricalContext(context);

    final selected = candidates.where((c) => c.isSelected).toList();

    if (selected.isEmpty) {
      // Compatibility bridge: clear in-memory override
      BaselineData.clearManagerOverride();
      return;
    }

    // Compatibility bridge: apply in-memory override
    BaselineData.applyManagerOverride(context);
  }

  // ── Commit draft selection ─────────────────────────────────────────────────
  //
  // 7.55q.9+: selections route through the canonical cycle path so
  // `target_cycles` and `active_target_profiles` stay in lockstep and
  // the once-per-60-day `managerOverrideUsed` rule is actually enforced.
  // Clearing the selection now restores recommended-cycle authority
  // through the same replacement-cycle seam instead of mutating the
  // active profile directly.
  //
  // Throws [ManagerOverrideDeniedException] when the active cycle has
  // already consumed its manager override and the caller tries to
  // land a new non-empty selection. Callers (the Baseline Manager
  // form) should catch and surface this to the user.

  Future<void> saveSelection(Set<String> selectedKeys) async {
    final restaurantId = await _activeRestaurantId();
    final serverWriter = serverSelectionWriter;
    if (serverWriter != null) {
      final candidates = await getCandidateShifts();
      final selectedCandidates = candidates
          .where((c) => selectedKeys.contains(c.recordKey))
          .toList();
      final foundKeys = selectedCandidates.map((c) => c.recordKey).toSet();
      final missingKeys = selectedKeys.difference(foundKeys);
      if (missingKeys.isNotEmpty) {
        throw StarTargetSelectionWriteException(
          code: 'candidate_not_in_server_window',
          message:
              'Some selected star shifts are no longer in the synced '
              '60-day server history. Refresh and choose again.',
        );
      }
      await serverWriter.replaceSelection(
        restaurantId: restaurantId,
        selectedCandidates: selectedCandidates,
        previouslySelectedCandidates: candidates.where((c) => c.isSelected),
      );
      await _baselineRepo.replaceSelectedRecordKeys(restaurantId, selectedKeys);
      await primeManagerOverride();
      final callback = onActiveTargetChanged;
      if (callback != null) {
        await callback();
      }
      return;
    }
    await _baselineRepo.replaceSelectedRecordKeys(restaurantId, selectedKeys);
    if (selectedKeys.isEmpty) {
      BaselineData.clearManagerOverride();
      final businessDate = await BusinessDateAuthorityService.instance
          .resolvePlanningAnchorDate(restaurantId);
      if (businessDate == null) {
        throw StateError(
          'BaselineManagerService.saveSelection: cannot resolve planning '
          'anchor date for restaurant $restaurantId while clearing the '
          'manager override.',
        );
      }
      await TargetCycleService.instance.restoreRecommendedCycle(
        restaurantId,
        businessDate,
      );
      final callback = onActiveTargetChanged;
      if (callback != null) {
        await callback();
      }
      return;
    }

    // 7.55q.9: route through the canonical cycle path. This writes a
    // replacement `TargetCycle` with source `managerOverride`,
    // projects the profile via `_syncActiveTargetProfile`, and
    // enforces `canManagerOverride` (throws if already used). The
    // `primeBaselineContextForDate` and `_persistActiveTargetProfile`
    // side-effects previously run by `primeManagerOverride` now
    // happen inside `_writeReplacementCycle`.
    final businessDate = await BusinessDateAuthorityService.instance
        .resolvePlanningAnchorDate(restaurantId);
    if (businessDate == null) {
      throw StateError(
        'BaselineManagerService.saveSelection: cannot resolve planning '
        'anchor date for restaurant $restaurantId — cycle override '
        'cannot proceed without a business date anchor.',
      );
    }
    await TargetCycleService.instance.applyManagerOverrideCycle(
      restaurantId,
      businessDate,
    );

    // The cycle path writes the profile via the projector but does
    // not fire the active-target-changed callback. Fire it here so
    // `ActiveTargetProfileNotifier` refreshes downstream surfaces.
    final callback = onActiveTargetChanged;
    if (callback != null) {
      await callback();
    }
  }

  // ── Admin reset seam (7.55q.9) ─────────────────────────────────────────────
  //
  // Testing/admin affordance. Clears the persisted manager selection,
  // the in-memory BaselineData bridge, and deactivates the active
  // `TargetCycle`, then creates a fresh recommended cycle (which syncs
  // the profile via the projector). Lets manual validation loop
  // through the once-per-cycle override flow repeatedly without
  // waiting for a real 60-day rollover.
  //
  // Surfaced by the Settings "Reset Target Cycle (Admin)" tile. Not
  // a public manager-facing action.
  Future<void> resetForAdminTest() async {
    final restaurantId = await _activeRestaurantId();
    final businessDate = await BusinessDateAuthorityService.instance
        .resolvePlanningAnchorDate(restaurantId);
    if (businessDate == null) {
      throw StateError(
        'BaselineManagerService.resetForAdminTest: cannot resolve '
        'planning anchor date for restaurant $restaurantId.',
      );
    }

    // Clear persisted selection keys + in-memory bridge.
    await _baselineRepo.replaceSelectedRecordKeys(restaurantId, const {});
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();

    // Deactivate any active cycle so the next read builds a fresh
    // recommended one with `managerOverrideUsed: false`.
    await SqliteTargetCycleRepository.instance.deactivateAllForRestaurant(
      restaurantId,
    );

    // Build the fresh recommended cycle (also syncs the profile).
    await TargetCycleService.instance.getOrCreateActiveCycle(
      restaurantId,
      businessDate,
    );

    // Notify downstream surfaces that the active target changed.
    final callback = onActiveTargetChanged;
    if (callback != null) {
      await callback();
    }
  }

  // ── Persist active target profile and notify authority path ────────────────
}
