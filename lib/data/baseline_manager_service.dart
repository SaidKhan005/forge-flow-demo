// Phase 5 — Baseline Manager Service
// Loads historical closed shifts as selectable baseline candidates,
// persists the manager's selection, and applies it to BaselineData.
//
// Phase 7.55f.2: Candidate loading now uses a true 60-calendar-day date
// window anchored to the latest closed business_date, replacing the old
// 8-week approximation.
//
// Phase 7.55f.4: Anchor prefers the mock replay current business date
// when available, falling back to the latest closed business_date.
//
// After persisting the active target profile, notifies any registered
// active-target listener so the app-wide notifier path can refresh.

import '../domain/repositories/baseline_selection_repository.dart';
import '../domain/repositories/restaurant_scope_repository.dart';
import '../domain/repositories/shift_record_repository.dart';
import '../domain/repositories/target_profile_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_baseline_selection_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import '../models/baseline_candidate_shift.dart';
import 'legacy_fixture_data.dart';

/// Callback type for active-target profile change events.
typedef ActiveTargetChangedCallback = Future<void> Function();

class BaselineManagerService {
  BaselineManagerService._();
  static final BaselineManagerService instance = BaselineManagerService._();

  final ShiftRecordRepository _shiftRepo =
      SqliteShiftRecordRepository.instance;
  final BaselineSelectionRepository _baselineRepo =
      SqliteBaselineSelectionRepository.instance;
  final RestaurantScopeRepository _scopeRepo =
      SqliteRestaurantScopeRepository.instance;
  final TargetProfileRepository _profileRepo =
      SqliteTargetProfileRepository.instance;

  /// Optional callback invoked after the active target profile is persisted.
  /// Set by the app-wide ActiveTargetProfileNotifier to receive change events.
  ActiveTargetChangedCallback? onActiveTargetChanged;

  Future<String> _activeRestaurantId() => _scopeRepo.getActiveRestaurantId();

  // ── Candidate loading ──────────────────────────────────────────────────────

  /// Loads candidates inside the true rolling 60-calendar-day window.
  ///
  /// Anchor preference:
  /// 1. Mock replay current business date (when available)
  /// 2. Latest closed business date (fallback)
  Future<List<BaselineCandidateShift>> getCandidateShifts() async {
    final restaurantId = await _activeRestaurantId();
    final mockDate = await SqliteDatabase.instance
        .getMockReplayBusinessDate(restaurantId);
    final anchorDate =
        mockDate ?? await _shiftRepo.getLatestClosedBusinessDate(restaurantId);
    if (anchorDate == null) return [];

    final endDate = anchorDate;
    final startDate = _subtractDays(anchorDate, 59);

    return getCandidateShiftsForDateRange(startDate, endDate);
  }

  /// Loads candidates for an explicit date range. Useful for testability and
  /// future calendar navigation (7.55f.3).
  Future<List<BaselineCandidateShift>> getCandidateShiftsForDateRange(
      String startDate, String endDate) async {
    final restaurantId = await _activeRestaurantId();
    final closedShifts = await _shiftRepo.getClosedShiftsInDateRange(
        restaurantId, startDate, endDate);
    final selectedKeys =
        await _baselineRepo.getSelectedRecordKeys(restaurantId);

    final candidates = closedShifts.map((shift) {
      final recordKey =
          '${shift.weekId}|${shift.dayLabel}|${shift.daypart}';
      return BaselineCandidateShift(
        recordKey:      recordKey,
        weekId:         shift.weekId,
        weekLabel:      shift.weekId,
        dayLabel:       shift.dayLabel,
        daypart:        shift.daypart,
        covers:         shift.covers,
        cplh:           shift.cplh,
        splh:           shift.splh,
        ppa:            shift.ppa,
        primaryLeverId: shift.normalizedLeverId,
        isSelected:     selectedKeys.contains(recordKey),
        businessDate:   shift.businessDate,
        actualLaborPct: shift.totalLaborPct,
      );
    }).toList();

    _sortCandidates(candidates);
    return candidates;
  }

  /// Subtracts [days] from an ISO date string, returning an ISO date string.
  static String _subtractDays(String isoDate, int days) {
    final parts = isoDate.split('-');
    final dt = DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    final result = dt.subtract(Duration(days: days));
    return '${result.year}-${result.month.toString().padLeft(2, '0')}'
        '-${result.day.toString().padLeft(2, '0')}';
  }

  static void _sortCandidates(List<BaselineCandidateShift> candidates) {
    const daypartOrder = <String, int>{
      'lunch': 0, 'dinner': 1, 'late_night': 2,
    };
    const dayOrder = <String, int>{
      'Mon': 0, 'Tue': 1, 'Wed': 2, 'Thu': 3, 'Fri': 4, 'Sat': 5, 'Sun': 6,
    };

    candidates.sort((a, b) {
      final dp = (daypartOrder[a.daypart] ?? 99)
          .compareTo(daypartOrder[b.daypart] ?? 99);
      if (dp != 0) return dp;
      final cplh = b.cplh.compareTo(a.cplh);
      if (cplh != 0) return cplh;
      final splh = b.splh.compareTo(a.splh);
      if (splh != 0) return splh;
      final ppa = b.ppa.compareTo(a.ppa);
      if (ppa != 0) return ppa;
      final week = b.weekId.compareTo(a.weekId);
      if (week != 0) return week;
      return (dayOrder[a.dayLabel] ?? 99)
          .compareTo(dayOrder[b.dayLabel] ?? 99);
    });
  }

  // ── Apply persisted selection to BaselineData ──────────────────────────────
  // Compatibility bridge: BaselineData is still updated in-memory for Baseline,
  // Schedule, and Learn surfaces that have not yet migrated to the persisted
  // active-target authority. This is temporary bridge behavior — the persisted
  // ActiveTargetProfile is the canonical authority.

  Future<void> primeManagerOverride() async {
    final candidates = await getCandidateShifts();

    if (candidates.isEmpty) {
      // Compatibility bridge: clear in-memory BaselineData state
      BaselineData.clearHistoricalContext();
      BaselineData.clearManagerOverride();
      await _persistActiveTargetProfile();
      return;
    }

    // All candidates already come from the true 60-day date window.
    final context = candidates
        .map((c) => DaypartBaseline(
              daypart:    c.daypart,
              cplh:       c.cplh,
              splh:       c.splh,
              ppa:        c.ppa,
              covers:     c.covers,
              isSelected: c.isSelected,
            ))
        .toList();

    // Compatibility bridge: update in-memory BaselineData with 60-day window
    BaselineData.applyHistoricalContext(context);

    final selected = candidates.where((c) => c.isSelected).toList();

    if (selected.isEmpty) {
      // Compatibility bridge: clear in-memory override
      BaselineData.clearManagerOverride();
      await _persistActiveTargetProfile();
      return;
    }

    // Compatibility bridge: apply in-memory override
    BaselineData.applyManagerOverride(context);
    await _persistActiveTargetProfile();
  }

  // ── Commit draft selection ─────────────────────────────────────────────────

  Future<void> saveSelection(Set<String> selectedKeys) async {
    final restaurantId = await _activeRestaurantId();
    await _baselineRepo.replaceSelectedRecordKeys(
        restaurantId, selectedKeys);
    if (selectedKeys.isEmpty) {
      // Compatibility bridge: clear in-memory override
      BaselineData.clearManagerOverride();
      await _persistActiveTargetProfile();
    } else {
      await primeManagerOverride();
    }
  }

  // ── Persist active target profile and notify authority path ────────────────

  Future<void> _persistActiveTargetProfile() async {
    final restaurantId = await _activeRestaurantId();
    final profile =
        SqliteDatabase.buildActiveTargetProfileFromBaseline(restaurantId);
    await _profileRepo.upsertActiveTargetProfile(profile);

    // Notify the persisted active-target authority path
    final callback = onActiveTargetChanged;
    if (callback != null) {
      await callback();
    }
  }
}
