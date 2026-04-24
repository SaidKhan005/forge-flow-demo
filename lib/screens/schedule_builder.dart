import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../theme/app_theme.dart';
import '../data/active_target_profile_notifier.dart';
import '../data/demand_forecast_context_notifier.dart';
import '../data/legacy_fixture_data.dart';
import '../data/restaurant_timing_config_read_service.dart';
import '../data/schedule_distribution_weights_notifier.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../data/schedule_plan_read_service.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/schedule_distribution_weights.dart';
import '../domain/models/schedule_forecast_demand.dart';
import '../domain/models/schedule_plan.dart';
import '../domain/models/service_period_definition.dart';
import '../services/labor_model.dart';
import '../utils/formatters.dart';
import '../widgets/app_screen_header.dart';
import '../widgets/schedule_day_row.dart';
import '../widgets/sticky_section_delegate.dart';

// ─── State ────────────────────────────────────────────────────────────────────

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
  })  : _targetCPLH = targetCPLH,
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
  })  : _fohWage = profile.fohWage,
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
  ScheduleLockedPlanLoadState get lockedPlanLoadState =>
      _lockedPlanLoadState;

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
          'setLockedPlanForTest is only valid in locked-authority mode');
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
  String get forecastSourceLabel =>
      _plan?.coversSourceLabel ?? 'Unavailable';

  /// Updates distribution weights.
  ///
  /// In LIVE mode this rebuilds the plan (weights influence both day
  /// allocation and daypart subrow splits via the resolver).
  ///
  /// In LOCKED mode the plan stays locked. Distribution weights only
  /// affect the daypart subrow presentation in [adjustedDayViews] —
  /// the locked snapshot's day allocation is fixed.
  void updateDistributionWeights(ScheduleDistributionWeights? distributionWeights) {
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
  double get forecastedTotalLaborDollar => _plan?.theoreticalTotalLaborDollars ?? 0;

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
  /// When [_distributionWeights] has day-specific daypart weights for a given
  /// day, those weights drive the subrow split. Otherwise falls back to
  /// [ServicePeriodDefinitionResolver.idsForDayLabel] over
  /// [_servicePeriodDefinitions] + [_daypartCoverWeight].
  ///
  /// 7.55q.6: per-day and per-daypart planned labor packages are gone
  /// (planned labor package killed). Day rows and daypart subrows
  /// carry only Plan-owned values (covers / sales / FOH / BOH hours).
  /// There is no honest same-scope theoretical labor % at day or
  /// daypart granularity in the repo today.
  List<ScheduleDayView> get adjustedDayViews {
    if (_plan == null) return [];
    return _plan!.dayPlans.map((dp) {
      // Resolve daypart IDs and integer cover weights for this day.
      final daypartData = _resolveDaypartWeights(dp.day);
      final ids = daypartData.map((e) => e.$1).toList();
      final intWeights = daypartData.map((e) => e.$2).toList();

      // Allocate covers across dayparts using largest-remainder.
      final subCovers = _allocateLargestRemainder(dp.forecastCovers, intWeights);

      // Split the locked day-row sales total across dayparts instead of
      // rebuilding sales from the current benchmark PPA.
      final subSales =
          _allocateProportionalDoubles(dp.forecastSales, subCovers);

      // Allocate FOH hours proportional to subrow covers.
      final subFoh = _allocateLargestRemainder(dp.requiredFohHours, subCovers);

      // Allocate BOH hours proportional to subrow sales.
      final subBoh = _allocateLargestRemainderByDouble(
          dp.requiredBohHours, subSales);

      final subrows = List.generate(ids.length, (i) {
        return ScheduleDaySubrow(
          label: ServicePeriodDefinitionResolver.labelForId(
              _servicePeriodDefinitions, ids[i]),
          forecastCovers: subCovers[i],
          forecastSales: subSales[i],
          requiredFohHours: subFoh[i],
          requiredBohHours: subBoh[i],
        );
      });

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

  /// Resolves daypart IDs and integer weights for a given day.
  ///
  /// Prefers data-driven weights from [_distributionWeights] when available
  /// and containing at least one positive value for the day. Falls back to
  /// [ServicePeriodDefinitionResolver.idsForDayLabel] + [_daypartCoverWeight].
  ///
  /// Returns entries in canonical service-period order, then any unknown
  /// IDs sorted alphabetically.
  List<(String, int)> _resolveDaypartWeights(String day) {
    final defs = _servicePeriodDefinitions;
    if (_distributionWeights != null && _distributionWeights!.isAvailable) {
      final daypartMap = _distributionWeights!.daypartWeightsFor(day);
      if (daypartMap.isNotEmpty && daypartMap.values.any((v) => v > 0)) {
        final entries = daypartMap.entries.toList();
        entries.sort((a, b) => ServicePeriodDefinitionResolver.sortKey(
                defs, a.key)
            .compareTo(ServicePeriodDefinitionResolver.sortKey(defs, b.key)));
        return entries.map((e) => (e.key, e.value)).toList();
      }
    }
    // Fallback: definition-based daypart IDs with proportional weights
    // converted to integer basis (multiply by 100 to preserve precision).
    final ids = ServicePeriodDefinitionResolver.idsForDayLabel(defs, day);
    return ids.map((id) {
      final w = _daypartCoverWeight[id] ?? 1.0;
      return (id, (w * 100).round());
    }).toList();
  }
}

/// Default daypart cover weight proportions for Schedule subrow allocation.
/// Derived from fixture daypart shape — lunch ~45%, dinner ~40%, late night ~15%.
/// Not read from BaselineData at render time.
const _daypartCoverWeight = <String, double>{
  'lunch': 0.45,
  'dinner': 0.40,
  'late_night': 0.15,
};


/// Largest-remainder allocation of [total] across integer [weights].
/// Guarantees sum(result) == total. Returns zeros when all weights are zero.
List<int> _allocateLargestRemainder(int total, List<int> weights) {
  final weightSum = weights.fold<int>(0, (s, v) => s + v);
  if (weightSum == 0) return List.filled(weights.length, 0);
  final fractional = weights.map((w) => total * w / weightSum).toList();
  return _largestRemainderCore(total, fractional);
}

/// Largest-remainder allocation of [total] across double [shares].
List<int> _allocateLargestRemainderByDouble(int total, List<double> shares) {
  final shareSum = shares.fold<double>(0, (s, v) => s + v);
  if (shareSum == 0) return List.filled(shares.length, 0);
  final fractional = shares.map((s) => total * s / shareSum).toList();
  return _largestRemainderCore(total, fractional);
}

/// Proportional allocation of [total] across integer [weights].
///
/// Returns doubles that sum exactly to [total] (subject to floating-point
/// precision) by assigning the rounding remainder to the final slot.
List<double> _allocateProportionalDoubles(double total, List<int> weights) {
  final weightSum = weights.fold<int>(0, (s, v) => s + v);
  if (weightSum == 0 || total == 0) return List.filled(weights.length, 0.0);

  final values = List<double>.filled(weights.length, 0.0);
  double assigned = 0;
  for (var i = 0; i < weights.length; i++) {
    if (i == weights.length - 1) {
      values[i] = total - assigned;
    } else {
      final share = total * weights[i] / weightSum;
      values[i] = share;
      assigned += share;
    }
  }
  return values;
}

/// Core largest-remainder: floor each fractional value, then distribute
/// the remaining units to the slots with the largest fractional parts.
List<int> _largestRemainderCore(int total, List<double> fractional) {
  final floors = fractional.map((f) => f.floor()).toList();
  var remainder = total - floors.fold<int>(0, (s, v) => s + v);
  final remainders = List.generate(
      fractional.length, (i) => (i, fractional[i] - floors[i]));
  remainders.sort((a, b) => b.$2.compareTo(a.$2));
  for (final entry in remainders) {
    if (remainder <= 0) break;
    floors[entry.$1] += 1;
    remainder -= 1;
  }
  return floors;
}

/// Pre-computed Schedule day row — Plan-owned values only.
///
/// 7.55q.6: per-day planned labor package field removed. There is no
/// honest same-scope theoretical labor % at day granularity in the
/// repo today; the row carries Plan-owned values only.
class ScheduleDayView {
  final String day;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  final List<ScheduleDaySubrow> subrows;

  const ScheduleDayView({
    required this.day,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.subrows,
  });
}

/// Pre-computed daypart sub-row — Plan-owned values only.
///
/// 7.55q.6: per-daypart planned labor package field removed. Same
/// reasoning as [ScheduleDayView] — no honest same-scope theoretical
/// labor % at daypart granularity exists today.
class ScheduleDaySubrow {
  final String label;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;

  const ScheduleDaySubrow({
    required this.label,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
  });
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class ScheduleBuilder extends StatelessWidget {
  const ScheduleBuilder({super.key});

  /// Test-only: wraps the real [_ScheduleBuilderContent] with a direct
  /// notifier provider, bypassing the upstream 3-provider tree.
  @visibleForTesting
  static Widget testContent(ScheduleForecastNotifier notifier) {
    return ChangeNotifierProvider<ScheduleForecastNotifier>.value(
      value: notifier,
      child: const _ScheduleBuilderContent(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProxyProvider3<ActiveTargetProfileNotifier,
        ScheduleDistributionWeightsNotifier,
        DemandForecastContextNotifier,
        ScheduleForecastNotifier>(
      create: (ctx) {
        final profile =
            ctx.read<ActiveTargetProfileNotifier>().profile;
        final weights =
            ctx.read<ScheduleDistributionWeightsNotifier>().weights;
        // 7.55q.2: production current-week plan authority is the
        // locked WeeklyPlanSnapshot projection (conformance Rule 1).
        // Both branches construct a locked-authority notifier — the
        // only difference is whether the real profile or the
        // bootstrap fallback profile supplies wages/PPA during the
        // brief window before ActiveTargetProfileNotifier finishes
        // loading. The locked-plan load runs identically and is
        // independent of which profile was passed in.
        final notifier = ScheduleForecastNotifier.lockedAuthority(
          profile: profile ?? _bootstrapFallbackProfile(),
          distributionWeights: weights,
          benchmarkResolved: profile != null,
        );
        // Fire the locked-plan load. The notifier surfaces honest
        // degradation (state == unavailable) when the snapshot
        // cannot be loaded — it must NOT silently fall back to the
        // live `resolveFromInputs` path.
        unawaited(notifier.loadLockedPlan());
        return notifier;
      },
      update: (ctx, targetNotifier, weightsNotifier, demandNotifier, previous) {
        if (previous != null) {
          final profile = targetNotifier.profile;
          if (profile != null) {
            // 7.55q.2: in locked mode this only refreshes wages + PPA
            // used by planned-package math; the locked plan stays in
            // force.
            previous.updateTargets(profile);
          }
          previous.updateDistributionWeights(weightsNotifier.weights);
          // 7.55q.2: in locked mode this is a no-op — the locked
          // plan does NOT recompute from demand changes. Kept for
          // symmetry and as a defense against future live-mode
          // reintroduction.
          previous.updateDemandCovers(demandNotifier.historicalWeeklyAvgCovers);
        }
        return previous!;
      },
      child: const _ScheduleBuilderContent(),
    );
  }
}

/// 7.55q.2: bootstrap fallback profile used by [ScheduleBuilder]'s
/// proxy provider during the brief window before
/// [ActiveTargetProfileNotifier] finishes loading. The locked-plan
/// load is unaffected — it reads the snapshot directly from SQLite.
/// These config-default wages / PPA are replaced by [updateTargets]
/// when the real profile arrives.
ActiveTargetProfile _bootstrapFallbackProfile() {
  return ActiveTargetProfile(
    targetProfileId: 'schedule-bootstrap-fallback',
    restaurantId: '',
    sourceType: 'system_baseline',
    targetCPLH: 0, // unused on locked path
    targetSPLH: 0, // unused on locked path
    targetPPA: BaselineData.derivedTargetPPA,
    fohWage: MeridianConfig.fohWage,
    bohWage: MeridianConfig.bohWage,
    opzFloorCPLH: 0,
    opzCeilingCPLH: 0,
    theoreticalFohLaborPct: 0,
    theoreticalBohLaborPct: 0,
    theoreticalLaborPct: 0,
    builtAt: '',
  );
}

class _ScheduleBuilderContent extends StatefulWidget {
  const _ScheduleBuilderContent();

  @override
  State<_ScheduleBuilderContent> createState() =>
      _ScheduleBuilderContentState();
}

class _ScheduleBuilderContentState
    extends State<_ScheduleBuilderContent> {
  @override
  Widget build(BuildContext context) {
    return FadingHeaderShell(
      header: Consumer<ScheduleForecastNotifier>(
        builder: (context, notifier, _) => AppScreenHeader(
          title: 'Weekly Operating Plan',
          bottom: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            // Left-aligned label above left-aligned pill row — same
            // pattern as the Benchmark header so the two tabs feel
            // cohesive.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('NEXT WEEK PROJECTIONS',
                    style:
                        AppTextStyles.mono8(color: AppColors.textMuted)),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppHeaderStat(
                      label: 'COVERS',
                      value: notifier.weeklyCovers.toString(),
                    ),
                    const SizedBox(width: 8),
                    AppHeaderStat(
                      label: 'SALES',
                      value:
                          '\$${Fmt.dollars(notifier.forecastedSales)}',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      child: CustomScrollView(
        cacheExtent: 9999,
        slivers: [
          // ── LABOR PLAN ──────────────────────────────────────────────
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('LABOR PLAN'),
              ),

              // Derived summary cards (FOH/BOH hrs, labor %, labor $)
              SliverToBoxAdapter(
                child: Consumer<ScheduleForecastNotifier>(
                  builder: (context, notifier, _) =>
                      _DerivedSummaryCards(notifier: notifier),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),

          // ── COVER FORECAST ADJUSTED BY DAY ─────────────────────────
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('COVER FORECAST ADJUSTED BY DAY'),
              ),

              // Bar chart
              SliverToBoxAdapter(
                child: Consumer<ScheduleForecastNotifier>(
                  builder: (context, notifier, _) =>
                      _CoverBarChart(notifier: notifier),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),

          // ── DAY-BY-DAY PLAN ────────────────────────────────────────
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('DAY-BY-DAY PLAN'),
              ),

              // Day-by-day table
              SliverToBoxAdapter(
                child: Consumer<ScheduleForecastNotifier>(
                  builder: (context, notifier, _) =>
                      _DayTable(notifier: notifier),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ],
      ),
    );
  }
}

// _ForecastCardsRow removed — FORECAST COVERS and FORECAST SALES moved
// to the screen header bottom slot via AppHeaderStat. The Plan body
// keeps only the labor-driven derived cards and the day-by-day breakdown.

class _DerivedSummaryCards extends StatelessWidget {
  final ScheduleForecastNotifier notifier;

  const _DerivedSummaryCards({required this.notifier});

  @override
  Widget build(BuildContext context) {
    // 7.55q.6 + follow-up alignment fix: the planned labor package is
    // dead, and the weekly summary's LABOR % card now reads the
    // benchmark-owned theoretical target seam via
    // [ScheduleForecastNotifier.theoreticalLaborPct]. The UI label may
    // stay generic, but there is no separate "planned labor %" concept
    // in the app anymore.
    final weekPct = notifier.theoreticalLaborPct;
    final hasPlan = notifier.hasPlan;
    final hasBenchmarkTarget = notifier.hasResolvedBenchmarkTarget;
    // Card labels are shortened so they fit a 4-up grid without truncating.
    // When the locked plan or benchmark seam is unavailable, render an
    // honest placeholder instead of a fake numeric zero.
    String labor() => hasPlan && hasBenchmarkTarget
        ? '${weekPct.toStringAsFixed(1)}%'
        : '--';
    final cards = [
      ('FOH HRS', notifier.requiredFohHours.toString()),
      ('BOH HRS', notifier.requiredBohHours.toString()),
      ('LABOR %', labor()),
      ('LABOR \$', '\$${Fmt.dollars(notifier.forecastedTotalLaborDollar)}'),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: cards.asMap().entries.map((entry) {
            final i = entry.key;
            final card = entry.value;
            return Expanded(
              child: Container(
                margin: EdgeInsets.only(left: i == 0 ? 0 : 6),
                padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.backgroundMid,
                      AppColors.cardGlow,
                    ],
                  ),
                  border: Border.all(
                      color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(card.$1,
                        style: AppTextStyles.mono8(
                            color: AppColors.textMuted)),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(card.$2,
                          style: AppTextStyles.mono16(
                              color: AppColors.primaryText)),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

}

/// Tiny dashed swatch used in chart legends to echo an in-chart dashed
/// reference line.
class _DashedSwatch extends StatelessWidget {
  final Color color;
  const _DashedSwatch({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 2,
      child: CustomPaint(
        painter: _DashedLinePainter(color: color),
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  final Color color;
  const _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    const dashWidth = 3.0;
    const dashGap = 2.0;
    double x = 0;
    final y = size.height / 2;
    while (x < size.width) {
      canvas.drawLine(Offset(x, y),
          Offset((x + dashWidth).clamp(0.0, size.width), y), paint);
      x += dashWidth + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter old) => old.color != color;
}

class _CoverBarChart extends StatelessWidget {
  final ScheduleForecastNotifier notifier;

  const _CoverBarChart({required this.notifier});

  @override
  Widget build(BuildContext context) {
    final days = notifier.adjustedDayViews;
    if (days.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.rule, width: 1),
        ),
        child: Text(
          'No forecast data available',
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
      );
    }
    final maxCovers = days.map((d) => d.forecastCovers).reduce(
          (a, b) => a > b ? a : b,
        );

    final barGroups = days.asMap().entries.map((entry) {
      final i = entry.key;
      final day = entry.value;
      return BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: day.forecastCovers.toDouble(),
            color: AppColors.sunset.withValues(alpha: 0.7),
            width: 24,
            borderRadius: BorderRadius.zero,
          ),
        ],
      );
    }).toList();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Legend — dashed swatch + "DAILY AVG" above the chart so the
          // label never collides with a bar column.
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _DashedSwatch(color: AppColors.sunset),
                const SizedBox(width: 6),
                Text('WEEKLY AVG',
                    style: AppTextStyles.mono7(
                        color: AppColors.sunsetDark)),
              ],
            ),
          ),
          SizedBox(
            height: 160,
            child: BarChart(
              BarChartData(
                barGroups: barGroups,
                maxY: (maxCovers * 1.3).toDouble(),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: AppColors.rule,
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      getTitlesWidget: (val, meta) {
                        if (val >= meta.max) return const SizedBox.shrink();
                        return Text(
                          val.toInt().toString(),
                          style: AppTextStyles.mono7(),
                        );
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (val, meta) {
                        final dayNames = ['M', 'Tu', 'W', 'Th', 'F', 'Sa', 'Su'];
                        return Text(
                          dayNames[val.toInt()],
                          style: AppTextStyles.mono7(
                              color: AppColors.primaryText),
                        );
                      },
                    ),
                  ),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                ),
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: notifier.weeklyCovers / 7.0,
                      color: AppColors.sunset,
                      strokeWidth: 1,
                      dashArray: [4, 4],
                      // Label moved to the legend row above the chart.
                    ),
                  ],
                ),
                barTouchData: BarTouchData(enabled: false),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// _PlanSectionLabel removed — replaced by shared StickySectionDelegate
// pinned headers in the CustomScrollView slivers above.

class _DayTable extends StatefulWidget {
  final ScheduleForecastNotifier notifier;

  const _DayTable({required this.notifier});

  @override
  State<_DayTable> createState() => _DayTableState();
}

class _DayTableState extends State<_DayTable> {
  final Set<int> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final days = widget.notifier.adjustedDayViews;
    if (days.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.rule, width: 1),
        ),
        child: Text(
          'No schedule plan available',
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
      );
    }
    final totalCovers = days.fold<int>(0, (s, d) => s + d.forecastCovers);
    final totalSales  = days.fold<double>(0, (s, d) => s + d.forecastSales);
    final totalFoh    = days.fold<int>(0, (s, d) => s + d.requiredFohHours);
    final totalBoh    = days.fold<int>(0, (s, d) => s + d.requiredBohHours);

    // 7.55q.6: planned labor package killed. The day-by-day table now
    // renders Plan-owned columns only (covers / sales / FOH / BOH
    // hours). Day-level / daypart-level theoretical labor % would
    // require honest same-scope theoretical truth, which the repo
    // does not have today (Phase 10.5 daypart work).

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        children: [
          ScheduleDayRow.header(),
          Container(height: 1, color: AppColors.rule),
          ...days.asMap().entries.expand((entry) {
            final i          = entry.key;
            final day        = entry.value;
            final isExpanded = _expanded.contains(i);
            final hasSubrows = day.subrows.isNotEmpty;

            return [
              GestureDetector(
                onTap: hasSubrows
                    ? () => setState(() {
                          isExpanded
                              ? _expanded.remove(i)
                              : _expanded.add(i);
                        })
                    : null,
                child: ScheduleDayRow(
                  day: day.day,
                  forecastCovers: day.forecastCovers,
                  forecastSales: day.forecastSales,
                  requiredFohHours: day.requiredFohHours,
                  requiredBohHours: day.requiredBohHours,
                  trailing: hasSubrows
                      ? Icon(
                          isExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 14,
                          color: AppColors.textMuted,
                        )
                      : null,
                ),
              ),
              if (isExpanded)
                ...day.subrows.map((dp) => ScheduleDayRow(
                      day: dp.label,
                      forecastCovers: dp.forecastCovers,
                      forecastSales: dp.forecastSales,
                      requiredFohHours: dp.requiredFohHours,
                      requiredBohHours: dp.requiredBohHours,
                      isSubrow: true,
                    )),
              Container(height: 1, color: AppColors.rule),
            ];
          }),
          ScheduleDayRow(
            day: 'Total',
            forecastCovers: totalCovers,
            forecastSales: totalSales,
            requiredFohHours: totalFoh,
            requiredBohHours: totalBoh,
            isTotal: true,
          ),
        ],
      ),
    );
  }
}
