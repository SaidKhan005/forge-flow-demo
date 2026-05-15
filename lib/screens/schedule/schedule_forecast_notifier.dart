// Phase 7.55o.3 — Schedule planning notifier.
//
// Extracted from lib/screens/schedule_builder.dart. Owns the locked-
// plan load state, the `_ScheduleAuthorityMode` (locked vs live),
// and the proportional/largest-remainder allocation helpers used by
// the daypart subrow math. Behaviour, formulas, and fallback rules
// are unchanged from the pre-split implementation.

import 'package:flutter/foundation.dart';

import '../../services/restaurant_scope_service.dart';
import '../../services/restaurant_timing_config_read_service.dart';
import '../../services/schedule_plan_read_service.dart';
import '../../domain/models/active_target_profile.dart';
import '../../domain/models/schedule_distribution_weights.dart';
import '../../domain/models/schedule_forecast_demand.dart';
import '../../domain/models/schedule_plan.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/service_period_definition_resolver.dart';
import '../../services/daypart_plan_allocator.dart';
import '../../services/labor_model.dart';
import 'schedule_view_models.dart';

/// 7.55q.2: Schedule's plan authority mode.
///
/// Codifies the rule from 7.55q.1 that the in-force current week has
/// ONE locked plan authority. The Schedule production runtime must
/// read from the locked WeeklyPlanSnapshot projection (locked mode).
/// The live `resolveFromInputs` path is preserved for tests and for
/// preview-from-draft-targets flows (e.g. Manager Override preview),
/// but is NOT the production current-week authority.
enum _ScheduleAuthorityMode { live, locked }

/// 7.55q.2: load state of the locked weekly plan.
///
/// Surfaces honest degradation. When the locked snapshot truly cannot
/// be loaded, the notifier exposes [unavailable] rather than silently
/// falling back to the live `resolveFromInputs` path. UI surfaces can
/// branch on this to render an explicit message.
enum ScheduleLockedPlanLoadState { idle, loading, available, unavailable }

class ScheduleForecastNotifier extends ChangeNotifier {
  // Lifecycle guard. The async loaders (loadLockedPlan,
  // _loadServicePeriodDefinitions, etc.) `await` between widget mounts
  // and the listener notification, so when an operator navigates away
  // mid-load (Schedule -> Benchmark star-shift, for example) the
  // widget tree disposes this notifier before the await resolves.
  // Without the guard, the follow-up notifyListeners() throws
  // "A ScheduleForecastNotifier was used after being disposed" and
  // freezes / blanks the screen.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  // Wages + PPA — used by planned-package math + daypart subrow sales
  // presentation. Updatable in BOTH modes via [updateTargets].
  double _fohWage;
  double _bohWage;
  double _targetPPA;
  double _theoreticalLaborPct;
  bool _hasResolvedBenchmarkTarget;

  // Live-mode-only inputs. Required for `resolveFromInputs`; unused
  // in locked mode (the locked snapshot supplies the plan directly).
  double? _targetCPLH;
  double? _targetSPLH;
  int? _historicalWeeklyAvgCovers;

  /// Optional data-driven distribution weights from closed ShiftRecords.
  /// In live mode: drives both day-level allocation (via the resolver)
  /// and daypart subrow splits. In locked mode: drives only daypart
  /// subrow splits (presentation) — the locked plan's day allocation
  /// is fixed.
  ScheduleDistributionWeights? _distributionWeights;

  /// The shared weekly plan.
  ///
  /// In live mode: from [SchedulePlanReadService.resolveFromInputs].
  /// In locked mode: from
  /// [SchedulePlanReadService.getExistingCurrentLockedWeeklyPlan].
  /// Null when:
  /// - live mode: demand is unavailable.
  /// - locked mode: snapshot is unavailable, OR not yet loaded.
  SchedulePlan? _plan;

  /// 7.55q.2: authority mode is fixed at construction time.
  final _ScheduleAuthorityMode _mode;

  /// 7.55q.2: load state of the locked plan. Idle in live mode.
  ScheduleLockedPlanLoadState _lockedPlanLoadState =
      ScheduleLockedPlanLoadState.idle;

  /// 7.55r item 1: active service-period definitions used for daypart
  /// subrow ordering and label lookup. Defaults to `demoDefinitions`;
  /// [loadLockedPlan] replaces this with the persisted
  /// `RestaurantTimingConfig.servicePeriodDefinitions` when available.
  List<ServicePeriodDefinition> _servicePeriodDefinitions =
      ServicePeriodDefinitionResolver.demoDefinitions;

  /// Test/preview constructor — builds the plan via
  /// [SchedulePlanReadService.resolveFromInputs] (the live path).
  ///
  /// 7.55q.2: this is NOT the production current-week authority.
  /// Production code must use [ScheduleForecastNotifier.lockedAuthority]
  /// + [loadLockedPlan]. The live path remains valid for tests and for
  /// preview-from-draft-targets flows (e.g. Manager Override preview),
  /// but does not represent the in-force current-week plan.
  ScheduleForecastNotifier({
    required double targetCPLH,
    required double targetPPA,
    required double targetSPLH,
    required double fohWage,
    required double bohWage,
    int? historicalWeeklyAvgCovers,
    ScheduleDistributionWeights? distributionWeights,
  }) : _targetCPLH = targetCPLH,
       _targetPPA = targetPPA,
       _targetSPLH = targetSPLH,
       _fohWage = fohWage,
       _bohWage = bohWage,
       _theoreticalLaborPct = LaborModel.theoreticalLaborPct(
         targetCPLH,
         targetSPLH,
         targetPPA,
         fohWage,
         bohWage,
       ),
       _hasResolvedBenchmarkTarget = true,
       _historicalWeeklyAvgCovers = historicalWeeklyAvgCovers,
       _distributionWeights = distributionWeights,
       _mode = _ScheduleAuthorityMode.live {
    _plan = SchedulePlanReadService.resolveFromInputs(
      targetCPLH: targetCPLH,
      targetPPA: targetPPA,
      targetSPLH: targetSPLH,
      fohWage: fohWage,
      bohWage: bohWage,
      historicalWeeklyAvgCovers: historicalWeeklyAvgCovers,
      distributionWeights: distributionWeights,
    );
  }

  /// 7.55q.2 + 7.55q.2-review-fix: production constructor — the
  /// in-force current-week plan authority is the locked
  /// [WeeklyPlanSnapshot] projected via the **read-only**
  /// [SchedulePlanReadService.getExistingCurrentLockedWeeklyPlan]
  /// path.
  ///
  /// Wages and PPA from [profile] are used for planned-package math
  /// and daypart subrow sales presentation. The plan itself is NOT
  /// recomputed from those inputs — the locked snapshot is the
  /// singular in-force week truth (7.55q.1 conformance Rule 1).
  ///
  /// Call [loadLockedPlan] after construction to populate the plan
  /// asynchronously. When no snapshot is persisted for the current
  /// week, [_plan] stays null and [lockedPlanLoadState] becomes
  /// [ScheduleLockedPlanLoadState.unavailable]. The read path MUST
  /// NOT auto-generate a snapshot from the live plan — that hidden
  /// second authority is exactly what the review-fix removes.
  ScheduleForecastNotifier.lockedAuthority({
    required ActiveTargetProfile profile,
    ScheduleDistributionWeights? distributionWeights,
    bool benchmarkResolved = true,
  }) : _fohWage = profile.fohWage,
       _bohWage = profile.bohWage,
       _targetPPA = profile.targetPPA,
       _theoreticalLaborPct = profile.theoreticalLaborPct,
       _hasResolvedBenchmarkTarget = benchmarkResolved,
       _distributionWeights = distributionWeights,
       _mode = _ScheduleAuthorityMode.locked;

  /// 7.55q.2 + 7.55q.2-review-fix: loads the locked weekly snapshot
  /// projection (READ-ONLY) and updates [_plan]. Honest degradation:
  /// if no snapshot is persisted for the current week, [_plan] stays
  /// null and [lockedPlanLoadState] becomes
  /// [ScheduleLockedPlanLoadState.unavailable]. No live fallback, no
  /// hidden snapshot generation.
  ///
  /// Routes through
  /// [SchedulePlanReadService.getExistingCurrentLockedWeeklyPlan] —
  /// the read-only sibling of `getCurrentLockedWeeklyPlan`. The
  /// generate-on-miss path was the hidden second authority the
  /// review-fix removed: when the snapshot was missing it would
  /// silently re-run the live plan and persist a fresh snapshot from
  /// it, defeating Rule 1's "one in-force current-week plan authority"
  /// guarantee.
  ///
  /// In live mode this is a no-op.
  Future<void> loadLockedPlan() async {
    if (_mode != _ScheduleAuthorityMode.locked) return;
    _lockedPlanLoadState = ScheduleLockedPlanLoadState.loading;
    notifyListeners();
    // 7.55r item 1: load persisted service-period definitions alongside
    // the plan. Honest fallback — when no timing config is persisted,
    // stays on [demoDefinitions].
    await _loadServicePeriodDefinitions();
    await _loadDistributionWeightsIfUnavailable();
    try {
      final plan = await SchedulePlanReadService.instance
          .getExistingCurrentLockedWeeklyPlan();
      _plan = plan;
      _lockedPlanLoadState = plan != null
          ? ScheduleLockedPlanLoadState.available
          : ScheduleLockedPlanLoadState.unavailable;
    } catch (_) {
      _plan = null;
      _lockedPlanLoadState = ScheduleLockedPlanLoadState.unavailable;
    }
    notifyListeners();
  }

  /// 7.56c.0 follow-up: locked Schedule and Variance Full Week must
  /// use the same daypart split. Production normally receives weights
  /// from [ScheduleDistributionWeightsNotifier], but that notifier loads
  /// asynchronously at app start. If Schedule is built before those
  /// weights arrive, load the same canonical weights here so the first
  /// available locked-plan render does not show fallback daypart splits
  /// while Variance already shows weighted splits.
  Future<void> _loadDistributionWeightsIfUnavailable() async {
    if (_distributionWeights != null) return;
    try {
      final restaurantId =
          await RestaurantScopeService.instance.getActiveRestaurantId();
      _distributionWeights =
          await SchedulePlanReadService.loadDistributionWeights(restaurantId);
    } catch (_) {
      // Honest fallback - leave null so the allocator uses defaults.
    }
  }

  /// 7.55r item 1: loads the active restaurant's persisted
  /// service-period definitions. Falls back silently to `demoDefinitions`
  /// when no timing config is persisted or when the load fails.
  Future<void> _loadServicePeriodDefinitions() async {
    try {
      final config = await RestaurantTimingConfigReadService.instance
          .getActiveTimingConfig();
      final defs = config?.servicePeriodDefinitions;
      if (defs != null && defs.isNotEmpty) {
        _servicePeriodDefinitions = defs;
      }
    } catch (_) {
      // Honest fallback — leave demoDefinitions in place.
    }
  }

  /// 7.55q.2: true when this notifier is in locked-authority
  /// (production) mode.
  bool get isLockedAuthority => _mode == _ScheduleAuthorityMode.locked;

  /// 7.55q.2: load state of the locked plan. Idle in live mode.
  ScheduleLockedPlanLoadState get lockedPlanLoadState => _lockedPlanLoadState;

  /// True once the benchmark-owned target seam has been resolved.
  ///
  /// Locked mode starts false only during the brief bootstrap window before
  /// the real active profile loads, so the UI can degrade honestly instead of
  /// flashing a config-default benchmark percentage.
  bool get hasResolvedBenchmarkTarget => _hasResolvedBenchmarkTarget;

  /// 7.55q.2: test-only seam — inject a pre-built [SchedulePlan] into a
  /// locked-authority notifier without going through SQLite. Lets unit
  /// tests prove the locked-mode no-recompute conformance properties
  /// (updateTargets / updateDemandCovers / updateDistributionWeights)
  /// without standing up a real database.
  ///
  /// Throws when called on a live-mode notifier — that path constructs
  /// its plan eagerly from inputs and has no need for injection.
  @visibleForTesting
  void setLockedPlanForTest(
    SchedulePlan? plan, {
    ScheduleLockedPlanLoadState state = ScheduleLockedPlanLoadState.available,
  }) {
    if (_mode != _ScheduleAuthorityMode.locked) {
      throw StateError(
        'setLockedPlanForTest is only valid in locked-authority mode',
      );
    }
    _plan = plan;
    _lockedPlanLoadState = state;
    notifyListeners();
  }

  /// The current weekly [SchedulePlan]. Null when demand is unavailable
  /// (live mode) or when the locked snapshot is unavailable / not yet
  /// loaded (locked mode).
  SchedulePlan? get plan => _plan;

  /// Whether a valid plan exists.
  bool get hasPlan => _plan != null;

  int get weeklyCovers => _plan?.forecastCovers ?? 0;

  /// Current covers source provenance.
  ForecastDemandSource get coversSource =>
      _plan?.coversSource ?? ForecastDemandSource.unavailable;

  /// Current sales source provenance.
  ForecastDemandSource get salesSource =>
      _plan?.salesSource ?? ForecastDemandSource.unavailable;

  /// Human-readable label for the current forecast source.
  String get forecastSourceLabel => _plan?.coversSourceLabel ?? 'Unavailable';

  /// Updates distribution weights.
  ///
  /// In LIVE mode this rebuilds the plan (weights influence both day
  /// allocation and daypart subrow splits via the resolver).
  ///
  /// In LOCKED mode the plan stays locked. Distribution weights only
  /// affect the daypart subrow presentation in [adjustedDayViews] —
  /// the locked snapshot's day allocation is fixed.
  void updateDistributionWeights(
    ScheduleDistributionWeights? distributionWeights,
  ) {
    if (identical(_distributionWeights, distributionWeights)) return;
    _distributionWeights = distributionWeights;
    if (_mode == _ScheduleAuthorityMode.live) {
      _rebuildPlan();
    }
    notifyListeners();
  }

  /// Updates wages + PPA from the current active profile.
  ///
  /// In LIVE mode this also updates CPLH/SPLH and rebuilds the plan
  /// via [SchedulePlanReadService.resolveFromInputs].
  ///
  /// In LOCKED mode this only updates wages + PPA — the locked plan
  /// itself does NOT recompute (per 7.55q.1 conformance Rule 1, the
  /// locked snapshot is the singular in-force current-week authority).
  void updateTargets(ActiveTargetProfile profile) {
    _targetPPA = profile.targetPPA;
    _fohWage = profile.fohWage;
    _bohWage = profile.bohWage;
    _theoreticalLaborPct = profile.theoreticalLaborPct;
    _hasResolvedBenchmarkTarget = true;
    if (_mode == _ScheduleAuthorityMode.live) {
      _targetCPLH = profile.targetCPLH;
      _targetSPLH = profile.targetSPLH;
      _rebuildPlan();
    }
    notifyListeners();
  }

  /// Updates demand covers and rebuilds the plan in LIVE mode.
  ///
  /// In LOCKED mode this is a NO-OP — the locked snapshot is the
  /// in-force week authority and does NOT recompute when demand
  /// changes. (Demand changes flow into the next week's snapshot at
  /// week roll, not into the in-force locked plan.)
  void updateDemandCovers(int? historicalWeeklyAvgCovers) {
    if (_mode == _ScheduleAuthorityMode.locked) return;

    _historicalWeeklyAvgCovers = historicalWeeklyAvgCovers;
    final newPlan = SchedulePlanReadService.resolveFromInputs(
      targetCPLH: _targetCPLH!,
      targetPPA: _targetPPA,
      targetSPLH: _targetSPLH!,
      fohWage: _fohWage,
      bohWage: _bohWage,
      historicalWeeklyAvgCovers: historicalWeeklyAvgCovers,
      distributionWeights: _distributionWeights,
    );

    final newCovers = newPlan?.forecastCovers;
    final currentCovers = _plan?.forecastCovers;

    // Skip if resolved covers match and plan state is the same
    if (newCovers == currentCovers && (newPlan != null) == (_plan != null)) {
      return;
    }

    _plan = newPlan;
    notifyListeners();
  }

  void _rebuildPlan() {
    // 7.55q.2: defensive — locked mode never recomputes the plan.
    if (_mode != _ScheduleAuthorityMode.live) return;
    if (_plan == null) return; // no plan to rebuild when demand is unavailable
    _plan = SchedulePlanReadService.resolveFromInputs(
      targetCPLH: _targetCPLH!,
      targetPPA: _targetPPA,
      targetSPLH: _targetSPLH!,
      fohWage: _fohWage,
      bohWage: _bohWage,
      historicalWeeklyAvgCovers: _historicalWeeklyAvgCovers,
      distributionWeights: _distributionWeights,
    );
  }

  // ── Delegated weekly-level getters ─────────────────────────────────────────

  double get forecastedSales => _plan?.forecastSales ?? 0;
  int get requiredFohHours => _plan?.requiredFohHours ?? 0;
  int get requiredBohHours => _plan?.requiredBohHours ?? 0;
  double get forecastedFohLaborDollar => _plan?.theoreticalFohLaborDollars ?? 0;
  double get forecastedBohLaborDollar => _plan?.theoreticalBohLaborDollars ?? 0;
  double get forecastedTotalLaborDollar =>
      _plan?.theoreticalTotalLaborDollars ?? 0;

  /// 7.55q.6 + follow-up alignment fix: theoretical labor % is a
  /// Benchmark-owned target metric, so Schedule's weekly summary reads
  /// the current benchmark target seam rather than the locked plan
  /// projection.
  ///
  /// In locked mode this comes from the current [ActiveTargetProfile].
  /// In live/preview mode it is derived from the same explicit target
  /// inputs that built the preview plan. The card only renders the
  /// value when [hasPlan] is true, so a missing locked plan still
  /// degrades honestly.
  double get theoreticalLaborPct => _theoreticalLaborPct;

  /// Day views from the shared [SchedulePlan] day rows.
  /// Daypart sub-rows are a presentation concern — built from plan day covers.
  ///
  /// 7.56c.0: routes through the shared [DaypartPlanAllocator] so
  /// Schedule's subrow split is the same allocation Variance Full Week
  /// non-closed rows now consume. When [_distributionWeights] has
  /// day-specific daypart weights with at least one positive value for
  /// the day, those weights drive the subrow split. Otherwise the
  /// allocator falls back to its built-in daypart cover proportions.
  ///
  /// 7.55q.6: per-day and per-daypart planned labor packages are gone
  /// (planned labor package killed). Day rows and daypart subrows
  /// carry only Plan-owned values (covers / sales / FOH / BOH hours).
  /// There is no honest same-scope theoretical labor % at day or
  /// daypart granularity in the repo today.
  List<ScheduleDayView> get adjustedDayViews {
    if (_plan == null) return [];
    return _plan!.dayPlans.map((dp) {
      final allocations = DaypartPlanAllocator.allocate(
        day: dp.day,
        dayCovers: dp.forecastCovers,
        daySales: dp.forecastSales,
        dayFohHours: dp.requiredFohHours,
        dayBohHours: dp.requiredBohHours,
        definitions: _servicePeriodDefinitions,
        distributionWeights: _distributionWeights,
      );

      final subrows = allocations
          .map(
            (a) => ScheduleDaySubrow(
              label: a.label,
              forecastCovers: a.forecastCovers,
              forecastSales: a.forecastSales,
              requiredFohHours: a.requiredFohHours,
              requiredBohHours: a.requiredBohHours,
            ),
          )
          .toList();

      return ScheduleDayView(
        day: dp.day,
        forecastCovers: dp.forecastCovers,
        forecastSales: dp.forecastSales,
        requiredFohHours: dp.requiredFohHours,
        requiredBohHours: dp.requiredBohHours,
        subrows: subrows,
      );
    }).toList();
  }
}
