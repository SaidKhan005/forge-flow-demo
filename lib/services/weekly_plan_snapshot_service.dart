// Phase 7.55l.6b — WeeklyPlanSnapshot persistence + auto-lock spine.
//
// Narrow runtime seam for current-week snapshot access:
// - determines current business date via BusinessDateAuthorityService
//   (shared planning-anchor precedence)
// - reads existing current-week snapshot if present
// - generates, persists, and returns a locked snapshot when missing
// - returns the existing locked snapshot unchanged on subsequent reads
//
// Generation bridge: maps TargetCycleService + SchedulePlanReadService
// into a persisted WeeklyPlanSnapshot. Current-week only — no arbitrary
// historical regeneration.
//
// Phase 7.55m.1: Planning-anchor resolution now delegates to
// BusinessDateAuthorityService instead of duplicating the mock-replay →
// latest-closed precedence locally.
//
// Phase 7.55n.4: Week-start wiring. Snapshot identity (weekStartDate,
// weekEndDate, weekKey) and day-row business dates now derive from the
// restaurant's configured weekStartDay via RestaurantTimingConfigReadService.
// Falls back to DateTime.monday when timing config is unavailable.
// Day rows are rotated to match the configured week start so labels
// and dates stay aligned.

import '../domain/models/schedule_plan.dart';
import '../domain/models/weekly_plan_snapshot.dart';
import '../domain/repositories/weekly_plan_snapshot_repository.dart';
import '../domain/services/weekly_plan_snapshot_policy.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import '../domain/services/utc_metadata_timestamp.dart';
import 'app_notification_service.dart';
import 'business_date_authority_service.dart';
import 'restaurant_timing_config_read_service.dart';
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
  /// - If missing, **generates** one from the current active [TargetCycle]
  ///   plus the current resolved live [SchedulePlan], persists it, and
  ///   returns it.
  /// - Returns null when the current business date cannot be determined or
  ///   the weekly plan cannot be resolved.
  ///
  /// IMPORTANT (7.55q.2-review-fix): this path AUTO-GENERATES when no
  /// snapshot is persisted. For read-only callers that must NOT silently
  /// re-introduce the live plan as a second current-week authority, use
  /// [getExistingCurrentWeekSnapshot] instead. The auto-generate
  /// behaviour is preserved here for the legitimate generation paths
  /// (week-roll bootstrap, Audit/Shift initial generation, etc.).
  Future<WeeklyPlanSnapshot?> getCurrentWeekSnapshot() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();

    // Planning-anchor resolution via shared authority service.
    final businessDate = await BusinessDateAuthorityService.instance
        .resolvePlanningAnchorDate(restaurantId);
    if (businessDate == null) return null;

    // Resolve week-start day from restaurant timing config.
    // Falls back to DateTime.monday when timing config is unavailable.
    final weekStartDay = await _resolveWeekStartDay(restaurantId);

    // Derive the current week span using configured week start.
    final weekStart = WeeklyPlanSnapshotPolicy.weekStartForDate(
        businessDate, weekStartDay: weekStartDay);
    final weekEnd = WeeklyPlanSnapshotPolicy.weekEndForDate(
        businessDate, weekStartDay: weekStartDay);
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
      weekStartDay: weekStartDay,
    );
  }

  /// 7.55q.2-review-fix: read-only access to the current-week snapshot.
  ///
  /// Returns the existing locked snapshot if one is persisted for the
  /// current business week, or null otherwise. **Never** generates,
  /// persists, or otherwise mutates state — the call is side-effect-free.
  ///
  /// Use this from read-only consumers (e.g. Schedule's locked-authority
  /// notifier path) that must NOT silently re-introduce the live plan
  /// as a second current-week authority.
  ///
  /// For paths that legitimately need to ensure a snapshot exists
  /// (week-roll bootstrap, Audit/Shift initial generation), call
  /// [getCurrentWeekSnapshot] instead — that path auto-generates from
  /// the live plan when missing.
  Future<WeeklyPlanSnapshot?> getExistingCurrentWeekSnapshot() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();

    final businessDate = await BusinessDateAuthorityService.instance
        .resolvePlanningAnchorDate(restaurantId);
    if (businessDate == null) return null;

    final weekStartDay = await _resolveWeekStartDay(restaurantId);
    final weekStart = WeeklyPlanSnapshotPolicy.weekStartForDate(
        businessDate, weekStartDay: weekStartDay);
    final weekEnd = WeeklyPlanSnapshotPolicy.weekEndForDate(
        businessDate, weekStartDay: weekStartDay);
    final weekKey =
        WeeklyPlanSnapshotPolicy.weekKeyFromSpan(weekStart, weekEnd);

    return _snapshotRepo.getSnapshotForWeekKey(restaurantId, weekKey);
  }

  /// Resolves the configured week-start day for [restaurantId].
  ///
  /// Returns [DateTime.monday] when timing config is unavailable — this
  /// makes Monday an explicit default fallback, not hidden truth.
  Future<int> _resolveWeekStartDay(String restaurantId) async {
    final config = await RestaurantTimingConfigReadService.instance
        .getTimingConfig(restaurantId);
    return config?.weekStartDay ?? DateTime.monday;
  }

  // ── Snapshot generation ─────────────────────────────────────────────────

  Future<WeeklyPlanSnapshot?> _generateAndPersistSnapshot({
    required String restaurantId,
    required String businessDate,
    required String weekStart,
    required String weekEnd,
    int weekStartDay = DateTime.monday,
  }) async {
    // Get the active target cycle for the current business date.
    final cycle = await TargetCycleService.instance
        .getOrCreateActiveCycle(restaurantId, businessDate);

    // Get the current resolved weekly plan.
    final plan =
        await SchedulePlanReadService.instance.getCurrentWeeklyPlan();
    if (plan == null) return null;

    // Map SchedulePlan day rows to WeeklyPlanSnapshotDay with business dates.
    // Day rows are rotated to match the configured week start so labels
    // and business dates stay aligned.
    final dayRows = _buildDayRows(plan, weekStart, weekStartDay: weekStartDay);

    final now = nowIsoUtc();
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
      coversSource: plan.coversSource,
      salesSource: plan.salesSource,
      generatedAt: now,
      lockedAt: now,
      dayRows: dayRows,
    );

    await _snapshotRepo.upsertSnapshot(snapshot);

    // Persist passive notification for new week snapshot (7.55p.4d).
    // Awaited so the notification row is durable before the generation
    // path returns. Dedupe via event_key ensures replays are silent.
    await AppNotificationService.instance.emitNewWeekSnapshot(
      restaurantId: restaurantId,
      weekStart: weekStart,
      weekEnd: weekEnd,
      businessDate: businessDate,
    );

    return snapshot;
  }

  /// Maps [SchedulePlan.dayPlans] to [WeeklyPlanSnapshotDay] list with
  /// business dates derived from the week start.
  ///
  /// Day plans from the resolver are always Mon–Sun ordered. When
  /// [weekStartDay] is not Monday, the list is rotated so the first
  /// entry matches the configured week-start day and business dates
  /// stay aligned with day labels.
  static List<WeeklyPlanSnapshotDay> _buildDayRows(
    SchedulePlan plan,
    String weekStart, {
    int weekStartDay = DateTime.monday,
  }) {
    final startDate = _parseDate(weekStart);

    // Rotate day plans to match configured week start.
    // dayPlans is Mon–Sun (indices 0–6 = weekdays 1–7).
    // Rotation offset: (weekStartDay - 1) % 7.
    final rotationOffset = (weekStartDay - 1) % 7;
    final dayPlans = plan.dayPlans;
    final rotated = rotationOffset == 0
        ? dayPlans
        : [
            ...dayPlans.sublist(rotationOffset),
            ...dayPlans.sublist(0, rotationOffset),
          ];

    return List.generate(rotated.length, (i) {
      final dayPlan = rotated[i];
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