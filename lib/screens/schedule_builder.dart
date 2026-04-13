import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../theme/app_theme.dart';
import '../data/active_target_profile_notifier.dart';
import '../data/demand_forecast_context_notifier.dart';
import '../data/legacy_fixture_data.dart';
import '../data/schedule_distribution_weights_notifier.dart';
import '../data/schedule_plan_read_service.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/schedule_distribution_weights.dart';
import '../domain/models/schedule_forecast_demand.dart';
import '../domain/models/schedule_plan.dart';
import '../utils/formatters.dart';
import '../widgets/schedule_day_row.dart';

// ─── State ────────────────────────────────────────────────────────────────────

class ScheduleForecastNotifier extends ChangeNotifier {
  // Target values — injected from persisted authority
  double _targetCPLH;
  double _targetPPA;
  double _targetSPLH;
  double _fohWage;
  double _bohWage;

  /// Canonical demand covers from [DemandForecastContext].
  int? _historicalWeeklyAvgCovers;

  /// Optional data-driven distribution weights from closed ShiftRecords.
  /// When available, used for both day-level allocation (via the shared plan)
  /// and daypart subrow splits (via adjustedDayViews).
  ScheduleDistributionWeights? _distributionWeights;

  /// The shared weekly plan resolved through [SchedulePlanReadService].
  /// Null when demand is unavailable.
  SchedulePlan? _plan;

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
        _historicalWeeklyAvgCovers = historicalWeeklyAvgCovers,
        _distributionWeights = distributionWeights {
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

  /// Builds from an ActiveTargetProfile, resolving demand through the
  /// shared [SchedulePlanReadService] authority.
  factory ScheduleForecastNotifier.fromProfile(
    ActiveTargetProfile profile, {
    int? historicalWeeklyAvgCovers,
    ScheduleDistributionWeights? distributionWeights,
  }) {
    return ScheduleForecastNotifier(
      targetCPLH: profile.targetCPLH,
      targetPPA: profile.targetPPA,
      targetSPLH: profile.targetSPLH,
      fohWage: profile.fohWage,
      bohWage: profile.bohWage,
      historicalWeeklyAvgCovers: historicalWeeklyAvgCovers,
      distributionWeights: distributionWeights,
    );
  }

  /// The current weekly [SchedulePlan]. Null when demand is unavailable.
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

  /// Updates distribution weights and rebuilds the plan.
  ///
  /// Preserves current covers, provenance, and targets. Does not reset
  /// manager-entered covers — only the day/daypart allocation changes.
  void updateDistributionWeights(ScheduleDistributionWeights? distributionWeights) {
    if (identical(_distributionWeights, distributionWeights)) return;
    _distributionWeights = distributionWeights;
    _rebuildPlan();
    notifyListeners();
  }

  /// Updates target values from the current active profile and rebuilds the plan.
  void updateTargets(ActiveTargetProfile profile) {
    _targetCPLH = profile.targetCPLH;
    _targetPPA = profile.targetPPA;
    _targetSPLH = profile.targetSPLH;
    _fohWage = profile.fohWage;
    _bohWage = profile.bohWage;
    _rebuildPlan();
    notifyListeners();
  }

  /// Updates demand covers from the canonical demand context and rebuilds the plan.
  ///
  /// Unlike [_rebuildPlan], this can create a plan from null when demand
  /// becomes available after initial construction.
  void updateDemandCovers(int? historicalWeeklyAvgCovers) {
    _historicalWeeklyAvgCovers = historicalWeeklyAvgCovers;
    final newPlan = SchedulePlanReadService.resolveFromInputs(
      targetCPLH: _targetCPLH,
      targetPPA: _targetPPA,
      targetSPLH: _targetSPLH,
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
    if (_plan == null) return; // no plan to rebuild when demand is unavailable
    _plan = SchedulePlanReadService.resolveFromInputs(
      targetCPLH: _targetCPLH,
      targetPPA: _targetPPA,
      targetSPLH: _targetSPLH,
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
  double get theoreticalLaborPct => _plan?.theoreticalLaborPct ?? 0;

  /// Day views from the shared [SchedulePlan] day rows.
  /// Daypart sub-rows are a presentation concern — built from plan day covers.
  ///
  /// When [_distributionWeights] has day-specific daypart weights for a given
  /// day, those weights drive the subrow split. Otherwise falls back to
  /// [WeekDayOrder.daypartsFor] + [_daypartCoverWeight].
  List<ScheduleDayView> get adjustedDayViews {
    if (_plan == null) return [];
    return _plan!.dayPlans.map((dp) {
      // Resolve daypart IDs and integer cover weights for this day.
      final daypartData = _resolveDaypartWeights(dp.day);
      final ids = daypartData.map((e) => e.$1).toList();
      final intWeights = daypartData.map((e) => e.$2).toList();

      // Allocate covers across dayparts using largest-remainder.
      final subCovers = _allocateLargestRemainder(dp.forecastCovers, intWeights);

      // Derive per-subrow sales from covers × PPA.
      final subSales = subCovers.map((c) => c * _targetPPA).toList();

      // Allocate FOH hours proportional to subrow covers.
      final subFoh = _allocateLargestRemainder(dp.requiredFohHours, subCovers);

      // Allocate BOH hours proportional to subrow sales.
      final subBoh = _allocateLargestRemainderByDouble(
          dp.requiredBohHours, subSales);

      final subrows = List.generate(ids.length, (i) {
        return ScheduleDaySubrow(
          label: _daypartLabel(ids[i]),
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
  /// [WeekDayOrder.daypartsFor] + [_daypartCoverWeight].
  ///
  /// Returns entries in canonical daypart order: lunch, dinner, late_night,
  /// then any unknown IDs sorted alphabetically.
  List<(String, int)> _resolveDaypartWeights(String day) {
    if (_distributionWeights != null && _distributionWeights!.isAvailable) {
      final daypartMap = _distributionWeights!.daypartWeightsFor(day);
      if (daypartMap.isNotEmpty && daypartMap.values.any((v) => v > 0)) {
        final entries = daypartMap.entries.toList();
        entries.sort((a, b) => _daypartSortKey(a.key)
            .compareTo(_daypartSortKey(b.key)));
        return entries.map((e) => (e.key, e.value)).toList();
      }
    }
    // Fallback: fixture-based daypart IDs with proportional weights
    // converted to integer basis (multiply by 100 to preserve precision).
    final ids = WeekDayOrder.daypartsFor(day);
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

String _daypartLabel(String id) {
  switch (id) {
    case 'lunch':      return 'Lunch';
    case 'dinner':     return 'Dinner';
    case 'late_night': return 'Late Night';
    default:           return id;
  }
}

/// Known daypart sort indices — ensures canonical lunch → dinner → late_night
/// ordering. Unknown IDs sort after known ones, alphabetically.
const _knownDaypartOrder = <String, int>{
  'lunch': 0,
  'dinner': 1,
  'late_night': 2,
};

/// Sort key for daypart ordering: known IDs get low indices, unknown IDs
/// get a high base plus their alphabetical position.
String _daypartSortKey(String id) {
  final idx = _knownDaypartOrder[id];
  if (idx != null) return '0_$idx';
  return '1_$id';
}

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

/// Pre-computed Schedule day row — model hours from injected target values.
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

/// Pre-computed daypart sub-row.
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
        final demandCtx =
            ctx.read<DemandForecastContextNotifier>().context;
        final histCovers = demandCtx.historicalWeeklyAvgCovers;
        final weights =
            ctx.read<ScheduleDistributionWeightsNotifier>().weights;
        if (profile != null) {
          return ScheduleForecastNotifier.fromProfile(
            profile,
            historicalWeeklyAvgCovers: histCovers,
            distributionWeights: weights,
          );
        }
        // Fallback during initial load — route through shared plan authority
        return ScheduleForecastNotifier(
          targetCPLH: BaselineData.derivedTargetCPLH,
          targetPPA: BaselineData.derivedTargetPPA,
          targetSPLH: BaselineData.derivedTargetSPLH,
          fohWage: MeridianConfig.fohWage,
          bohWage: MeridianConfig.bohWage,
          historicalWeeklyAvgCovers: histCovers,
          distributionWeights: weights,
        );
      },
      update: (ctx, targetNotifier, weightsNotifier, demandNotifier, previous) {
        if (previous != null) {
          final profile = targetNotifier.profile;
          if (profile != null) {
            previous.updateTargets(profile);
          }
          previous.updateDistributionWeights(weightsNotifier.weights);
          previous.updateDemandCovers(demandNotifier.historicalWeeklyAvgCovers);
        }
        return previous!;
      },
      child: const _ScheduleBuilderContent(),
    );
  }
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
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(
              'Weekly Operating Plan',
              style: AppTextStyles.display20(),
            ),
          ),

          // ── WEEKLY PLAN SUMMARY ─────────────────────────────────────────
          const _PlanSectionLabel('WEEKLY PLAN SUMMARY'),

          // Forecast cards (read-only, system-resolved)
          const _ForecastCardsRow(),

          const SizedBox(height: 8),

          // Derived summary cards
          Consumer<ScheduleForecastNotifier>(
            builder: (context, notifier, _) =>
                _DerivedSummaryCards(notifier: notifier),
          ),

          // ── COVER FORECAST BY DAY ──────────────────────────────────────
          const _PlanSectionLabel('COVER FORECAST BY DAY'),

          // Bar chart
          Consumer<ScheduleForecastNotifier>(
            builder: (context, notifier, _) =>
                _CoverBarChart(notifier: notifier),
          ),

          // ── DAY-BY-DAY PLAN ────────────────────────────────────────────
          const _PlanSectionLabel('DAY-BY-DAY PLAN'),

          // Day-by-day table
          Consumer<ScheduleForecastNotifier>(
            builder: (context, notifier, _) =>
                _DayTable(notifier: notifier),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _ForecastCardsRow extends StatelessWidget {
  const _ForecastCardsRow();

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<ScheduleForecastNotifier>();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Forecasted Covers
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.rule, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'FORECASTED COVERS - NEXT WEEK',
                      style: AppTextStyles.mono7(),
                    ),
                    const SizedBox(height: 8),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        notifier.weeklyCovers.toString(),
                        style: AppTextStyles.mono22(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Forecasted Sales
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.rule, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'FORECASTED SALES - NEXT WEEK',
                      style: AppTextStyles.mono7(),
                    ),
                    const SizedBox(height: 8),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '\$${Fmt.dollars(notifier.forecastedSales)}',
                        style: AppTextStyles.mono22(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DerivedSummaryCards extends StatelessWidget {
  final ScheduleForecastNotifier notifier;

  const _DerivedSummaryCards({required this.notifier});

  @override
  Widget build(BuildContext context) {
    final cards = [
      ('REQ FOH HRS', notifier.requiredFohHours.toString()),
      ('REQ BOH HRS', notifier.requiredBohHours.toString()),
      ('LABOR %', '${notifier.theoreticalLaborPct.toStringAsFixed(1)}%'),
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
                margin: EdgeInsets.only(left: i == 0 ? 0 : 4),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.rule, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 28,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(card.$1, style: AppTextStyles.mono7()),
                      ),
                    ),
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

// ─── Plan section label ──────────────────────────────────────────────────────

class _PlanSectionLabel extends StatelessWidget {
  final String text;
  const _PlanSectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          text,
          style: AppTextStyles.mono10(color: AppColors.textSecondary),
        ),
      );
}

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
