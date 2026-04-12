// Phase 7.55l.6b — WeeklyPlanSnapshot persistence + auto-lock spine.
//
// Narrow runtime seam for current-week snapshot access:
// - determines current business date (mock replay first, latest closed
//   fallback — same anchor precedence as the planning stack)
// - reads existing current-week snapshot if present
// - generates, persists, and returns a locked snapshot when missing
// - returns the existing locked snapshot unchanged on subsequent reads
//
// Generation bridge: maps TargetCycleService + SchedulePlanReadService
// into a persisted WeeklyPlanSnapshot. Current-week only — no arbitrary
// historical regeneration.

import '../domain/models/schedule_plan.dart';
import '../domain/models/weekly_plan_snapshot.dart';
import '../domain/repositories/weekly_plan_snapshot_repository.dart';
import '../domain/services/weekly_plan_snapshot_policy.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import 'schedule_plan_read_service.dart';
import 'target_cycle_service.dart';

class WeeklyPlanSnapshotService {
  WeeklyPlanSnapshotService._();
  static final WeeklyPlanSnapshotService instance =
      WeeklyPlanSnapshotService._();

  final WeeklyPlanSnapshotRepository _snapshotRepo =
      SqliteWeeklyPlanSnapshotRepository.instance;

  /// Returns the locked [WeeklyPlanSnapshot] for the current business week.
  ///
  /// - If a snapshot already exists for the current week, returns it unchanged.
  /// - If missing, generates one from the current active [TargetCycle] plus
  ///   the current resolved [SchedulePlan], persists it, and returns it.
  /// - Returns null when the current business date cannot be determined or
  ///   the weekly plan cannot be resolved.
  Future<WeeklyPlanSnapshot?> getCurrentWeekSnapshot() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();

    // Anchor precedence: mock replay date → latest closed business date.
    final businessDate = await _resolveCurrentBusinessDate(restaurantId);
    if (businessDate == null) return null;

    // Derive the current week span.
    final weekStart =
        WeeklyPlanSnapshotPolicy.weekStartForDate(businessDate);
    final weekEnd =
        WeeklyPlanSnapshotPolicy.weekEndForDate(businessDate);
    final weekKey =
        WeeklyPlanSnapshotPolicy.weekKeyFromSpan(weekStart, weekEnd);

    // Check for an existing snapshot for this week.
    final existing =
        await _snapshotRepo.getSnapshotForWeekKey(restaurantId, weekKey);
    if (existing != null) return existing;

    // No snapshot exists — generate and persist one.
    return _generateAndPersistSnapshot(
      restaurantId: restaurantId,
      businessDate: businessDate,
      weekStart: weekStart,
      weekEnd: weekEnd,
    );
  }

  // ── Business date resolution ────────────────────────────────────────────

  /// Same anchor precedence as the planning stack:
  /// 1. Mock replay business date (when available)
  /// 2. Latest closed business date (fallback)
  Future<String?> _resolveCurrentBusinessDate(String restaurantId) async {
    final mockDate = await SqliteDatabase.instance
        .getMockReplayBusinessDate(restaurantId);
    if (mockDate != null) return mockDate;

    return SqliteShiftRecordRepository.instance
        .getLatestClosedBusinessDate(restaurantId);
  }

  // ── Snapshot generation ─────────────────────────────────────────────────

  Future<WeeklyPlanSnapshot?> _generateAndPersistSnapshot({
    required String restaurantId,
    required String businessDate,
    required String weekStart,
    required String weekEnd,
  }) async {
    // Get the active target cycle for the current business date.
    final cycle = await TargetCycleService.instance
        .getOrCreateActiveCycle(restaurantId, businessDate);

    // Get the current resolved weekly plan.
    final plan =
        await SchedulePlanReadService.instance.getCurrentWeeklyPlan();
    if (plan == null) return null;

    // Map SchedulePlan day rows to WeeklyPlanSnapshotDay with business dates.
    final dayRows = _buildDayRows(plan, weekStart);

    final now = DateTime.now().toUtc().toIso8601String();
    final snapshot = WeeklyPlanSnapshot(
      snapshotId: '${restaurantId}_snapshot_${weekStart.replaceAll('-', '')}',
      restaurantId: restaurantId,
      weekStartDate: weekStart,
      weekEndDate: weekEnd,
      targetCycleId: cycle.cycleId,
      forecastCovers: plan.forecastCovers,
      forecastSales: plan.forecastSales,
      requiredFohHours: plan.requiredFohHours,
      requiredBohHours: plan.requiredBohHours,
      theoreticalFohLaborDollars: plan.theoreticalFohLaborDollars,
      theoreticalBohLaborDollars: plan.theoreticalBohLaborDollars,
      theoreticalLaborPct: plan.theoreticalLaborPct,
      targetBlendedWage: plan.targetBlendedWage,
      coversSource: plan.coversSource,
      salesSource: plan.salesSource,
      generatedAt: now,
      lockedAt: now,
      dayRows: dayRows,
    );

    await _snapshotRepo.upsertSnapshot(snapshot);
    return snapshot;
  }

  /// Maps [SchedulePlan.dayPlans] to [WeeklyPlanSnapshotDay] list with
  /// business dates derived from the week start.
  ///
  /// Day plans are ordered Mon–Sun by the resolver. Business dates are
  /// assigned sequentially starting from [weekStart] (Monday default).
  static List<WeeklyPlanSnapshotDay> _buildDayRows(
    SchedulePlan plan,
    String weekStart,
  ) {
    final startDate = _parseDate(weekStart);
    return List.generate(plan.dayPlans.length, (i) {
      final dayPlan = plan.dayPlans[i];
      final date = startDate.add(Duration(days: i));
      return WeeklyPlanSnapshotDay(
        day: dayPlan.day,
        businessDate: _formatDate(date),
        forecastCovers: dayPlan.forecastCovers,
        forecastSales: dayPlan.forecastSales,
        requiredFohHours: dayPlan.requiredFohHours,
        requiredBohHours: dayPlan.requiredBohHours,
      );
    });
  }

  // ── Date helpers ────────────────────────────────────────────────────────

  static DateTime _parseDate(String isoDate) {
    final parts = isoDate.split('-');
    return DateTime.utc(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  static String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}
