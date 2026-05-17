// Phase 7.55l.6b — WeeklyPlanSnapshot persistence + auto-lock spine.
//
// Per-Daypart Targets V1 (Slice 1) extensions:
//   - The lock-time generation path now also computes one
//     [WeeklyPlanSnapshotDayDaypart] row per (business_date, service_period)
//     pair and stamps it on the new persisted child table.
//   - The snapshot row's new `wage_at_lock_time_json` column is populated
//     with `{"foh_wage", "boh_wage", "blended_wage"}` from the cycle in
//     force at lock time (Design Rule 8 — audit checks compare against
//     this column, not against `ActiveTargetProfile` current wages).
//   - Per-period required hours math:
//       requiredFohHours = period forecast covers / period target CPLH
//       requiredBohHours = period forecast sales  / period target SPLH
//     Per-period theoretical dollars math (Design Rule 5, wages
//     stay whole-day):
//       theoreticalFohDollars = required FOH hours × whole-day FOH wage
//       theoreticalBohDollars = required BOH hours × whole-day BOH wage
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

import 'package:flutter/foundation.dart';

import '../domain/models/active_target_profile.dart';
import '../domain/models/schedule_plan.dart';
import '../domain/models/target_cycle.dart';
import '../domain/models/weekly_plan_snapshot.dart';
import '../domain/repositories/weekly_plan_snapshot_repository.dart';
import '../domain/services/proportional_allocation.dart';
import '../domain/services/weekly_plan_snapshot_bottom_up_reconciler.dart';
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
    if (existing != null) {
      // 7.56b.1: when a locked weekly_plan_snapshot is pre-seeded
      // (FU-mobile-cold-boot-shift-stale-state, #759) this path
      // short-circuits BEFORE _generateAndPersistSnapshot's
      // getOrCreateActiveCycle call — the only trigger for the
      // seed-cycle's missing-summary repair. Guarantee cycle⇄summary
      // coherence here too so the Benchmark / Data-alignment surface
      // always sees the companion summary, independent of snapshot
      // presence. Narrow + idempotent — does NOT run
      // getOrCreateActiveCycle, so no cycle rollover side-effect.
      await TargetCycleService.instance
          .ensureActiveCycleSelectionSummary(restaurantId);
      return existing;
    }

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

    // Per-Daypart V1 (Slice 1) — compute per-(day, period) sub-rows
    // from the cycle's per-period rows + the operator-configured
    // service-period weights. When the cycle has no per-period rows
    // (Gap 42 fallback) the list stays empty and read consumers fall
    // back to the whole-day day_rows.
    final dayDayparts = _buildDayDaypartRowsForLock(
      restaurantId: restaurantId,
      cycle: cycle,
      dayRows: dayRows,
    );

    // Per-Daypart V1 (bottom-up locked snapshot): the locked snapshot
    // is now bottom-up by construction — day rows are the SUM of their
    // per-period rows, and week totals are the SUM of the day rows.
    // This makes `Σ(per-period) == day-row == week-total` true by
    // construction instead of three independently-sourced layers that
    // drift. Days with no per-period rows (Gap 42 empty cycle dayparts)
    // keep their original pooled `plan.dayPlans` whole-day values
    // (honest fallback — never zeroed). When the cycle has NO
    // per-period rows at all, the whole snapshot keeps the original
    // `plan.*` pooled totals.
    final reconciled = _reconcileBottomUp(
      plan: plan,
      dayRows: dayRows,
      dayDayparts: dayDayparts,
    );

    // Per-Daypart V1 (Slice 1) — wage stamp at lock time. Pull wages
    // from the cycle's parent (cycle-in-force wages, not current).
    // Blended wage uses the canonical cover-independent formula on the
    // ActiveTargetProfile model so this stamp can't drift from the
    // shared seam.
    final wageStamp = WeeklyPlanSnapshotWagesAtLockTime(
      fohWage: cycle.fohWage,
      bohWage: cycle.bohWage,
      blendedWage: ActiveTargetProfile.computeTargetBlendedWage(
        targetCPLH: cycle.targetCPLH,
        targetSPLH: cycle.targetSPLH,
        targetPPA: cycle.targetPPA,
        fohWage: cycle.fohWage,
        bohWage: cycle.bohWage,
      ),
    );

    final now = nowIsoUtc();
    final snapshot = WeeklyPlanSnapshot(
      snapshotId: '${restaurantId}_snapshot_${weekStart.replaceAll('-', '')}',
      restaurantId: restaurantId,
      weekStartDate: weekStart,
      weekEndDate: weekEnd,
      targetCycleId: cycle.cycleId,
      forecastCovers: reconciled.weekCovers,
      forecastSales: reconciled.weekSales,
      requiredFohHours: reconciled.weekFohHours,
      requiredBohHours: reconciled.weekBohHours,
      theoreticalFohLaborDollars: reconciled.weekFohDollars,
      theoreticalBohLaborDollars: reconciled.weekBohDollars,
      coversSource: plan.coversSource,
      salesSource: plan.salesSource,
      generatedAt: now,
      lockedAt: now,
      dayRows: reconciled.dayRows,
      dayDayparts: dayDayparts,
      wageAtLockTime: wageStamp,
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
  ///
  /// CODE_HEALTH L15 fix: the Mon-first contract on `plan.dayPlans` is
  /// now asserted explicitly at the rotation boundary. Drift in
  /// `SchedulePlanResolver._defaultDayWeights` would otherwise
  /// silently desync business dates from day labels.
  static const List<String> _expectedMonFirstLabels = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];

  @visibleForTesting
  static List<WeeklyPlanSnapshotDay> debugBuildDayRows(
    SchedulePlan plan,
    String weekStart, {
    int weekStartDay = DateTime.monday,
  }) =>
      _buildDayRows(plan, weekStart, weekStartDay: weekStartDay);

  static List<WeeklyPlanSnapshotDay> _buildDayRows(
    SchedulePlan plan,
    String weekStart, {
    int weekStartDay = DateTime.monday,
  }) {
    final startDate = _parseDate(weekStart);

    // Mon-first contract pin (CODE_HEALTH L15). The resolver upstream is
    // documented Mon-first; if upstream order ever drifts, day-row
    // business dates would silently desync from day labels — fail loud
    // here so the regression surfaces at the boundary instead of
    // shipping wrong dates to consumers. `throw` (not `assert`) so the
    // contract holds in release builds too, where `assert` is stripped.
    final dayLabels = plan.dayPlans.map((d) => d.day).toList();
    final monFirstOk = dayLabels.length == _expectedMonFirstLabels.length &&
        List.generate(
          dayLabels.length,
          (i) => dayLabels[i] == _expectedMonFirstLabels[i],
        ).every((ok) => ok);
    if (!monFirstOk) {
      throw StateError(
        'WeeklyPlanSnapshotService: SchedulePlan.dayPlans must be Mon-first '
        'to keep day-row rotation aligned with business dates; got '
        '$dayLabels',
      );
    }

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

  /// Per-Daypart V1 (Slice 1) — compute per-(day, period) sub-rows for
  /// the locked snapshot.
  ///
  /// Allocation strategy:
  ///   1. For each day-row in [dayRows], iterate the
  ///      operator-configured service periods applicable to that day.
  ///   2. Allocate the day's `forecastCovers` across the applicable
  ///      periods using the cycle's per-period `coverCount` as the
  ///      proportion source (the recommendation engine already weighted
  ///      the cover signal from real evidence in the 60-day calibration
  ///      window). When the cycle has no per-period rows, returns
  ///      empty — read consumers fall back to whole-day rows.
  ///   3. Per-period forecast sales = period forecast covers × period
  ///      target PPA (from the cycle's per-period row).
  ///   4. Per-period required FOH hours = period forecast covers /
  ///      period target CPLH.
  ///   5. Per-period required BOH hours = period forecast sales /
  ///      period target SPLH.
  ///   6. Per-period theoretical FOH dollars = required FOH hours ×
  ///      whole-day FOH wage (wages stay whole-day, Design Rule 5).
  ///   7. Per-period theoretical BOH dollars = required BOH hours ×
  ///      whole-day BOH wage.
  ///
  /// This helper is sync (no I/O); all the inputs are already in
  /// memory at lock time.
  ///
  /// Public for testing; private wiring stays through
  /// `_generateAndPersistSnapshot`.
  @visibleForTesting
  static List<WeeklyPlanSnapshotDayDaypart> debugBuildDayDaypartRows({
    required TargetCycle cycle,
    required List<WeeklyPlanSnapshotDay> dayRows,
    Map<int, List<String>>? applicablePeriodIdsByWeekday,
  }) =>
      _buildDayDaypartRows(
        cycle: cycle,
        dayRows: dayRows,
        applicablePeriodIdsByWeekday: applicablePeriodIdsByWeekday,
      );

  List<WeeklyPlanSnapshotDayDaypart> _buildDayDaypartRowsForLock({
    required String restaurantId,
    required TargetCycle cycle,
    required List<WeeklyPlanSnapshotDay> dayRows,
  }) =>
      _buildDayDaypartRows(cycle: cycle, dayRows: dayRows);

  static List<WeeklyPlanSnapshotDayDaypart> _buildDayDaypartRows({
    required TargetCycle cycle,
    required List<WeeklyPlanSnapshotDay> dayRows,
    Map<int, List<String>>? applicablePeriodIdsByWeekday,
  }) {
    if (cycle.dayparts.isEmpty) {
      // Gap 42 fallback: no per-period rows on the cycle → no
      // per-(day, period) sub-rows on the snapshot. Read consumers
      // fall back to whole-day day_rows honestly.
      return const <WeeklyPlanSnapshotDayDaypart>[];
    }

    // Per-period total cover weight from the cycle (recommendation
    // engine's 60-day evidence). Used to allocate each day's forecast
    // covers across applicable periods.
    final periodCoverWeights = <String, int>{
      for (final dp in cycle.dayparts) dp.servicePeriodId: dp.coverCount,
    };

    final out = <WeeklyPlanSnapshotDayDaypart>[];
    for (final dayRow in dayRows) {
      // Determine which periods are applicable on this weekday. When
      // the caller hasn't supplied a map, fall back to the cycle's
      // entire per-period set (all applicable). This is acceptable
      // because the cycle was built from the operator's actual
      // calibration window evidence; periods that never serve a given
      // weekday simply contribute zero covers to that day.
      final periodIds = applicablePeriodIdsByWeekday == null
          ? cycle.dayparts.map((d) => d.servicePeriodId).toList()
          : (applicablePeriodIdsByWeekday[
                  _isoWeekdayFromLabel(dayRow.day)] ??
              cycle.dayparts.map((d) => d.servicePeriodId).toList());

      // Keep only periods that actually exist on the cycle, in the
      // caller's iteration order, so the allocation weight vector lines
      // up 1:1 with the rows we emit.
      final applicableIds = [
        for (final id in periodIds)
          if (cycle.daypartFor(id) != null) id,
      ];

      // Per-Daypart V1 (bottom-up locked snapshot): allocate the day's
      // forecast covers across the applicable periods with a single
      // largest-remainder pass so `Σ(periodCovers) == dayRow
      // .forecastCovers` EXACTLY (no independent per-period `.round()`
      // drift — that divergence was the Σ(per-period) ≠ day-row root
      // cause). Per-period rate fidelity (sales/FOH/BOH) is unchanged.
      final weights = [
        for (final id in applicableIds) periodCoverWeights[id] ?? 0,
      ];
      final allocatedCovers =
          allocateLargestRemainderInt(dayRow.forecastCovers, weights);

      for (var idx = 0; idx < applicableIds.length; idx++) {
        final periodId = applicableIds[idx];
        final cycleDp = cycle.daypartFor(periodId);
        if (cycleDp == null) continue;
        final periodCovers = allocatedCovers[idx];
        final periodSales = periodCovers * cycleDp.targetPPA;
        final periodReqFohHours = cycleDp.targetCPLH > 0
            ? periodCovers / cycleDp.targetCPLH
            : 0.0;
        final periodReqBohHours = cycleDp.targetSPLH > 0
            ? periodSales / cycleDp.targetSPLH
            : 0.0;
        final periodFohDollars = periodReqFohHours * cycle.fohWage;
        final periodBohDollars = periodReqBohHours * cycle.bohWage;
        out.add(WeeklyPlanSnapshotDayDaypart(
          businessDate: dayRow.businessDate,
          servicePeriodId: periodId,
          forecastCovers: periodCovers,
          forecastSales: periodSales,
          requiredFohHours: periodReqFohHours,
          requiredBohHours: periodReqBohHours,
          theoreticalFohDollars: periodFohDollars,
          theoreticalBohDollars: periodBohDollars,
        ));
      }
    }
    return out;
  }

  /// Per-Daypart V1 (bottom-up locked snapshot) — recompute day rows
  /// and week totals as the SUM of the locked per-period rows so the
  /// snapshot is `Σ(per-period) == day-row == week-total` by
  /// construction (the plan doc's "1:1 by construction" intent;
  /// `per_daypart_targets_v1_plan.md` lines ~234, ~241).
  ///
  /// The math itself lives in the SHARED pure
  /// [WeeklyPlanSnapshotBottomUpReconciler.reconcile] so the runtime
  /// lock path AND the demo seed
  /// (`SqliteDatabaseSeed` snapshot builders) reconcile through ONE
  /// implementation — no third divergent writer. This wrapper only
  /// delegates; behaviour is byte-identical to PR #917's private
  /// reconciliation.
  static WeeklyPlanSnapshotBottomUpReconcileResult _reconcileBottomUp({
    required SchedulePlan plan,
    required List<WeeklyPlanSnapshotDay> dayRows,
    required List<WeeklyPlanSnapshotDayDaypart> dayDayparts,
  }) =>
      WeeklyPlanSnapshotBottomUpReconciler.reconcile(
        plan: plan,
        dayRows: dayRows,
        dayDayparts: dayDayparts,
      );

  /// Public test seam for the bottom-up reconciliation math. Private
  /// wiring stays through `_generateAndPersistSnapshot`.
  @visibleForTesting
  static List<WeeklyPlanSnapshotDay> debugReconcileBottomUpDayRows({
    required SchedulePlan plan,
    required List<WeeklyPlanSnapshotDay> dayRows,
    required List<WeeklyPlanSnapshotDayDaypart> dayDayparts,
  }) =>
      _reconcileBottomUp(
        plan: plan,
        dayRows: dayRows,
        dayDayparts: dayDayparts,
      ).dayRows;

  static int _isoWeekdayFromLabel(String dayLabel) {
    // 1=Mon..7=Sun. Mirrors ScheduleDistributionWeights.canonicalDayOrder.
    switch (dayLabel) {
      case 'Mon':
        return 1;
      case 'Tue':
        return 2;
      case 'Wed':
        return 3;
      case 'Thu':
        return 4;
      case 'Fri':
        return 5;
      case 'Sat':
        return 6;
      case 'Sun':
        return 7;
      default:
        return 0;
    }
  }

  /// Public adapter that maps timing-config service periods into
  /// `applicableDays`-keyed lookup. Provided here so the cover
  /// allocator above can read operator-configured restrictions when
  /// they're available; the legacy fallback (no map) treats every
  /// per-period row as applicable on every weekday.
  static Map<int, List<String>> applicablePeriodIdsByWeekday(
    List<dynamic> servicePeriodDefinitions,
  ) {
    final out = <int, List<String>>{};
    // We don't import `ServicePeriodDefinition` directly to keep the
    // dependency boundary minimal; rely on duck typing on `.id` and
    // `.applicableDays` which both `ServicePeriodDefinition` and any
    // future replacement carry.
    for (final def in servicePeriodDefinitions) {
      final id = def.id as String;
      final days = (def.applicableDays as List).cast<int>();
      for (final d in days) {
        (out[d] ??= <String>[]).add(id);
      }
    }
    return out;
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