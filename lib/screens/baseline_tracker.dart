import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../theme/app_theme.dart';
import '../data/meridian_data.dart';
import '../widgets/daypart_table.dart';

class BaselineTracker extends StatelessWidget {
  const BaselineTracker({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your Baseline', style: AppTextStyles.display20()),
                const SizedBox(height: 2),
                Text('Last 60 Days', style: AppTextStyles.mono10()),
              ],
            ),
          ),

          // Summary cards
          _SummaryCards(),

          const SizedBox(height: 8),

          // CPLH line chart
          _CplhLineChart(),

          const SizedBox(height: 8),

          // Daypart table
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Daypart Breakdown', style: AppTextStyles.body14()),
          ),
          DaypartTable(dayparts: BaselineData.dayparts),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              BaselineData.daypartNote,
              style: AppTextStyles.body12(),
            ),
          ),

          // Baseline targets card
          _BaselineTargetsCard(),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SummaryCards extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cards = [
      ('TOTAL COVERS', _fmt(BaselineData.totalCoversTracked)),
      ('WEEKLY AVG', '${BaselineData.weeklyAvgCovers}'),
      ('BEST CPLH', BaselineData.bestDaysAvgCPLH.toStringAsFixed(2)),
      ('WORST CPLH', BaselineData.worstDaysAvgCPLH.toStringAsFixed(2)),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: cards.asMap().entries.map((entry) {
          final i = entry.key;
          final card = entry.value;
          return Expanded(
            child: Container(
              margin: EdgeInsets.only(left: i == 0 ? 0 : 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.rule, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(card.$1, style: AppTextStyles.mono7()),
                  const SizedBox(height: 4),
                  Text(card.$2,
                      style: AppTextStyles.mono12(
                          color: AppColors.primaryText)),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  String _fmt(int n) => n
      .toString()
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
}

class _CplhLineChart extends StatefulWidget {
  const _CplhLineChart();

  @override
  State<_CplhLineChart> createState() => _CplhLineChartState();
}

class _CplhLineChartState extends State<_CplhLineChart> {
  late final LineChartData _chartData;

  @override
  void initState() {
    super.initState();
    final spots = BaselineData.days
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.cplh))
        .toList();
    _chartData = _buildChartData(spots);
  }

  LineChartData _buildChartData(List<FlSpot> spots) {
    return LineChartData(
      minY: 2.5,
      maxY: 7.0,
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
            reservedSize: 32,
            getTitlesWidget: (val, meta) => Text(
              val.toStringAsFixed(1),
              style: AppTextStyles.mono7(),
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 10,
            getTitlesWidget: (val, meta) => Text(
              'D${val.toInt() + 1}',
              style: AppTextStyles.mono7(),
            ),
          ),
        ),
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: AppColors.primaryText.withValues(alpha: 0.6),
          barWidth: 1.5,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: AppColors.positive.withValues(alpha: 0.08),
            cutOffY: MeridianConfig.opzCeilingCPLH,
            applyCutOffY: true,
          ),
        ),
      ],
      extraLinesData: ExtraLinesData(
        horizontalLines: [
          HorizontalLine(
            y: MeridianConfig.targetCPLH,
            color: AppColors.gold,
            strokeWidth: 1.5,
            dashArray: [6, 4],
            label: HorizontalLineLabel(
              show: true,
              alignment: Alignment.topRight,
              labelResolver: (_) => 'Target',
              style: AppTextStyles.mono7(color: AppColors.gold),
            ),
          ),
          HorizontalLine(
            y: MeridianConfig.opzCeilingCPLH,
            color: AppColors.gold.withValues(alpha: 0.6),
            strokeWidth: 1,
            dashArray: [4, 4],
            label: HorizontalLineLabel(
              show: true,
              alignment: Alignment.topRight,
              labelResolver: (_) => 'OPZ ceiling',
              style: AppTextStyles.mono7(color: AppColors.gold),
            ),
          ),
        ],
      ),
      lineTouchData: const LineTouchData(enabled: false),
    );
  }

  @override
  Widget build(BuildContext context) {
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
            child: Text('CPLH - LAST 60 DAYS', style: AppTextStyles.mono7()),
          ),
          SizedBox(
            height: 200,
            child: RepaintBoundary(
              child: LineChart(_chartData),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _LegendDot(color: AppColors.positive, label: 'In OPZ'),
              const SizedBox(width: 12),
              _LegendDot(color: AppColors.accent, label: 'Below target'),
              const SizedBox(width: 12),
              _LegendDot(color: AppColors.gold, label: 'Above ceiling'),
            ],
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: AppTextStyles.mono7(color: AppColors.secondaryText)),
      ],
    );
  }
}

class _BaselineTargetsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final targets = [
      ('CPLH', MeridianConfig.targetCPLH.toStringAsFixed(1)),
      ('SPLH', '\$${MeridianConfig.targetSPLH.toStringAsFixed(0)}'),
      ('PPA', '\$${MeridianConfig.targetPPA.toStringAsFixed(0)}'),
      (
        'THEORETICAL LABOR %',
        '${MeridianConfig.totalTheoreticalLaborPct.toStringAsFixed(1)}%'
      ),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('TARGETS DERIVED FROM BASELINE', style: AppTextStyles.mono7()),
          const SizedBox(height: 12),
          ...targets.map((t) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(t.$1, style: AppTextStyles.mono10()),
                    Text(
                      t.$2,
                      style:
                          AppTextStyles.mono14(color: AppColors.primaryText),
                    ),
                  ],
                ),
              )),
          Container(height: 1, color: AppColors.rule),
          const SizedBox(height: 10),
          Text(
            BaselineData.baselineTargetsNote,
            style: AppTextStyles.body11(),
          ),
        ],
      ),
    );
  }
}
