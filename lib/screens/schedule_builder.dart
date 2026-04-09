import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../theme/app_theme.dart';
import '../data/active_target_profile_notifier.dart';
import '../data/legacy_fixture_data.dart';
import '../domain/models/active_target_profile.dart';
import '../services/labor_model.dart';
import '../utils/formatters.dart';
import '../widgets/schedule_day_row.dart';

// ─── State ────────────────────────────────────────────────────────────────────

class ScheduleForecastNotifier extends ChangeNotifier {
  int _weeklyCovers = ScheduleForecastDefaults.defaultWeeklyCovers;

  // Explicit active-target values — injected from persisted authority
  double _targetCPLH;
  double _targetPPA;
  double _targetSPLH;
  double _fohWage;
  double _bohWage;
  double _theoreticalLaborPct;

  ScheduleForecastNotifier({
    required double targetCPLH,
    required double targetPPA,
    required double targetSPLH,
    required double fohWage,
    required double bohWage,
    required double theoreticalLaborPct,
  })  : _targetCPLH = targetCPLH,
        _targetPPA = targetPPA,
        _targetSPLH = targetSPLH,
        _fohWage = fohWage,
        _bohWage = bohWage,
        _theoreticalLaborPct = theoreticalLaborPct;

  /// Builds from an ActiveTargetProfile.
  factory ScheduleForecastNotifier.fromProfile(ActiveTargetProfile profile) {
    return ScheduleForecastNotifier(
      targetCPLH: profile.targetCPLH,
      targetPPA: profile.targetPPA,
      targetSPLH: profile.targetSPLH,
      fohWage: profile.fohWage,
      bohWage: profile.bohWage,
      theoreticalLaborPct: profile.theoreticalLaborPct,
    );
  }

  int get weeklyCovers => _weeklyCovers;

  void setCovers(int covers) {
    if (covers > 0) {
      _weeklyCovers = covers;
      notifyListeners();
    }
  }

  /// Updates target values from the current active profile.
  void updateTargets(ActiveTargetProfile profile) {
    _targetCPLH = profile.targetCPLH;
    _targetPPA = profile.targetPPA;
    _targetSPLH = profile.targetSPLH;
    _fohWage = profile.fohWage;
    _bohWage = profile.bohWage;
    _theoreticalLaborPct = profile.theoreticalLaborPct;
    notifyListeners();
  }

  int get requiredFohHours =>
      LaborModel.modelFohHours(_weeklyCovers, _targetCPLH);
  int get requiredBohHours =>
      LaborModel.modelBohHours(_weeklyCovers, _targetPPA, _targetSPLH);
  double get forecastedFohLaborDollar => requiredFohHours * _fohWage;
  double get forecastedBohLaborDollar => requiredBohHours * _bohWage;
  double get forecastedTotalLaborDollar =>
      forecastedFohLaborDollar + forecastedBohLaborDollar;
  double get theoreticalLaborPct => _theoreticalLaborPct;

  /// Adjusted days with model hours computed from injected target values.
  List<ScheduleDayView> get adjustedDayViews {
    final defaultTotal = ScheduleForecastDefaults.defaultDays
        .fold<int>(0, (s, d) => s + d.forecastCovers);
    final ratio = _weeklyCovers / defaultTotal;
    return ScheduleForecastDefaults.defaultDays.map((d) {
      final covers = (d.forecastCovers * ratio).round();
      final foh = LaborModel.modelFohHours(covers, _targetCPLH);
      final boh = LaborModel.modelBohHours(covers, _targetPPA, _targetSPLH);

      // Build daypart sub-rows — covers weighted by fixture daypart proportions
      final ids = WeekDayOrder.daypartsFor(d.day);
      final weights = ids.map((id) => _daypartCoverWeight[id] ?? 1.0).toList();
      final totalWeight = weights.fold(0.0, (s, w) => s + w);
      final subrows = totalWeight > 0
          ? List.generate(ids.length, (i) {
              final dpCovers = (covers * weights[i] / totalWeight).round();
              return ScheduleDaySubrow(
                label: _daypartLabel(ids[i]),
                forecastCovers: dpCovers,
                requiredFohHours:
                    LaborModel.modelFohHours(dpCovers, _targetCPLH),
                requiredBohHours:
                    LaborModel.modelBohHours(dpCovers, _targetPPA, _targetSPLH),
              );
            })
          : <ScheduleDaySubrow>[];

      return ScheduleDayView(
        day: d.day,
        forecastCovers: covers,
        requiredFohHours: foh,
        requiredBohHours: boh,
        subrows: subrows,
      );
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

/// Pre-computed Schedule day row — model hours from injected target values.
class ScheduleDayView {
  final String day;
  final int forecastCovers;
  final int requiredFohHours;
  final int requiredBohHours;
  final List<ScheduleDaySubrow> subrows;
  const ScheduleDayView({
    required this.day,
    required this.forecastCovers,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.subrows,
  });
}

/// Pre-computed daypart sub-row.
class ScheduleDaySubrow {
  final String label;
  final int forecastCovers;
  final int requiredFohHours;
  final int requiredBohHours;
  const ScheduleDaySubrow({
    required this.label,
    required this.forecastCovers,
    required this.requiredFohHours,
    required this.requiredBohHours,
  });
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class ScheduleBuilder extends StatelessWidget {
  const ScheduleBuilder({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProxyProvider<ActiveTargetProfileNotifier,
        ScheduleForecastNotifier>(
      create: (ctx) {
        final profile =
            ctx.read<ActiveTargetProfileNotifier>().profile;
        if (profile != null) {
          return ScheduleForecastNotifier.fromProfile(profile);
        }
        // Fallback during initial load — will be updated by proxy
        return ScheduleForecastNotifier(
          targetCPLH: BaselineData.derivedTargetCPLH,
          targetPPA: BaselineData.derivedTargetPPA,
          targetSPLH: BaselineData.derivedTargetSPLH,
          fohWage: MeridianConfig.fohWage,
          bohWage: MeridianConfig.bohWage,
          theoreticalLaborPct: BaselineData.derivedTheoreticalLaborPct,
        );
      },
      update: (ctx, targetNotifier, previous) {
        final profile = targetNotifier.profile;
        if (profile != null && previous != null) {
          previous.updateTargets(profile);
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
  final TextEditingController _controller =
      TextEditingController(text: '1200');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

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
              'Next Week',
              style: AppTextStyles.display20(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Schedule to Covers',
              style: AppTextStyles.mono10(),
            ),
          ),
          // Forecast input
          _ForecastInput(controller: _controller),

          const SizedBox(height: 8),

          // Derived summary cards
          Consumer<ScheduleForecastNotifier>(
            builder: (context, notifier, _) =>
                _DerivedSummaryCards(notifier: notifier),
          ),

          const SizedBox(height: 8),

          // Bar chart
          Consumer<ScheduleForecastNotifier>(
            builder: (context, notifier, _) =>
                _CoverBarChart(notifier: notifier),
          ),

          const SizedBox(height: 8),

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

class _ForecastInput extends StatelessWidget {
  final TextEditingController controller;

  const _ForecastInput({required this.controller});

  @override
  Widget build(BuildContext context) {
    final notifier = context.read<ScheduleForecastNotifier>();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FORECASTED COVERS - NEXT WEEK',
                  style: AppTextStyles.mono7(),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: AppTextStyles.mono22(),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: '1200',
                    hintStyle:
                        AppTextStyles.mono22(color: AppColors.secondaryText),
                  ),
                  onChanged: (val) {
                    final parsed = int.tryParse(val);
                    if (parsed != null && parsed > 0) {
                      notifier.setCovers(parsed);
                    }
                  },
                ),
              ],
            ),
          ),
          const Icon(Icons.edit, size: 16, color: AppColors.secondaryText),
        ],
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
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 12),
            child: Text('COVER FORECAST BY DAY', style: AppTextStyles.mono7()),
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
                      getTitlesWidget: (val, meta) => Text(
                        val.toInt().toString(),
                        style: AppTextStyles.mono7(),
                      ),
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
    final days        = widget.notifier.adjustedDayViews;
    final totalCovers = days.fold<int>(0, (s, d) => s + d.forecastCovers);
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
            requiredFohHours: totalFoh,
            requiredBohHours: totalBoh,
            isTotal: true,
          ),
        ],
      ),
    );
  }
}
