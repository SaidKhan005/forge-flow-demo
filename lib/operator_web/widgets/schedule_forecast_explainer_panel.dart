// Phase 8 W5.B - Schedule forecast explainer panel.
//
// Renders the "Why these numbers?" body Doc 1's Plan / Schedule Screen
// contract requires: 60-day baseline, 21-day trend, target PPA, forecast
// sales, required FOH / BOH hours, theoretical labor dollars. Each field
// gets a one-line plain-English caption (UX writing standard:
// `memory/project_ux_writing_standard.md`).
//
// Honest fallback per the same contract: when the proxy returns
// `forecast_context.covers_source = unavailable` (or the matching context
// row is missing) the panel renders the "need 60 days" caveat instead of
// rendering zeroes.

import 'package:flutter/material.dart';

import '../services/operator_web_schedule_gateway.dart';
import '../../theme/app_theme.dart';
import 'operator_web_info_popover.dart';
import 'operator_web_section_heading.dart';

class ScheduleForecastExplainerPanel extends StatelessWidget {
  const ScheduleForecastExplainerPanel({super.key, required this.context});

  final ScheduleForecastContext? context;

  @override
  Widget build(BuildContext buildContext) {
    final ctx = context;
    if (ctx == null || !ctx.hasBaseline) {
      return _ThinHistoryBanner(historyDays: ctx?.historyDays ?? 0);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const OperatorWebSectionHeading(
          title: 'Why these numbers?',
          trailing: OperatorWebInfoPopover(
            keyPrefix: 'schedule_forecast_section_help',
            title: 'Why these numbers?',
            tooltip: 'Explain forecast math',
            bullets: <String>[
              "F&F builds the week's plan from closed-shift history.",
              'The visible rows show the inputs and outputs at a glance.',
              'Tap any row help icon to see the plain-English explanation.',
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          key: const Key('schedule_forecast_explainer_panel'),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          decoration: BoxDecoration(
            color: AppColors.cardGlow,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _ExplainerRow(
                keyName: 'schedule_explainer_baseline',
                label: '60-day baseline covers',
                value: _coversWeekly(ctx.baselineWeeklyAvgCovers),
                caption:
                    'Average weekly covers across the last 60 service periods. '
                    'Your steady-state demand.',
              ),
              _ExplainerRow(
                keyName: 'schedule_explainer_trend',
                label: '21-day trend',
                value: _trendValue(ctx),
                caption:
                    'How the last three weeks compare to the 60-day baseline. '
                    'Tells us if covers are climbing or dipping right now.',
              ),
              _ExplainerRow(
                keyName: 'schedule_explainer_ppa',
                label: 'Target PPA',
                value: _money(ctx.targetPpa),
                caption:
                    'Your average sale per cover. Multiplied with forecast covers '
                    'to size weekly sales.',
              ),
              _ExplainerRow(
                keyName: 'schedule_explainer_forecast_sales',
                label: 'Forecast sales',
                value: _money(ctx.forecastSales),
                caption:
                    'Forecast covers times target PPA. Drives required hours '
                    'through your labor model.',
              ),
              _ExplainerRow(
                keyName: 'schedule_explainer_required_foh',
                label: 'Required FOH hours',
                value: _hours(ctx.requiredFohHours),
                caption:
                    'Total front-of-house hours your labor model needs to hit '
                    'the forecast sales target.',
              ),
              _ExplainerRow(
                keyName: 'schedule_explainer_required_boh',
                label: 'Required BOH hours',
                value: _hours(ctx.requiredBohHours),
                caption:
                    'Total back-of-house hours your labor model needs to hit '
                    'the forecast sales target.',
              ),
              _ExplainerRow(
                keyName: 'schedule_explainer_theoretical_dollars',
                label: 'Theoretical labor dollars',
                value: _money(ctx.theoreticalLaborDollars),
                caption:
                    'Required hours costed at your wage authority averages. '
                    'The dollar bar your actuals are measured against.',
                isLast: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _coversWeekly(int? covers) {
    if (covers == null) return '—';
    return '$covers covers / week';
  }

  static String _hours(int hours) => '$hours hrs / week';

  static String _money(num value) {
    final whole = value.round();
    final formatted = whole.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (match) => '${match.group(1)},',
    );
    return '\$$formatted';
  }

  static String _trendValue(ScheduleForecastContext ctx) {
    final delta = ctx.recentTrendDeltaCovers;
    if (delta == null) {
      return 'Not enough recent shifts yet';
    }
    if (delta == 0) return 'Flat vs. baseline';
    final magnitude = delta.abs();
    final direction = delta > 0 ? 'up' : 'down';
    return '$magnitude covers / week $direction';
  }
}

class _ExplainerRow extends StatelessWidget {
  const _ExplainerRow({
    required this.keyName,
    required this.label,
    required this.value,
    required this.caption,
    this.isLast = false,
  });

  final String keyName;
  final String label;
  final String value;
  final String caption;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key(keyName),
      padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            flex: 4,
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    label,
                    style: AppTextStyles.mono14(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                OperatorWebInfoPopover(
                  keyPrefix: '${keyName}_help',
                  title: label,
                  tooltip: 'Explain $label',
                  alignment: OperatorWebInfoPopoverAlignment.start,
                  bullets: <String>[caption],
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                value,
                key: Key('${keyName}_value'),
                style: AppTextStyles.mono14(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThinHistoryBanner extends StatelessWidget {
  const _ThinHistoryBanner({required this.historyDays});

  final int historyDays;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const OperatorWebSectionHeading(
          title: 'Explain unavailable',
          trailing: OperatorWebInfoPopover(
            keyPrefix: 'schedule_thin_history_help',
            title: 'Explain unavailable',
            tooltip: 'Explain unavailable forecast math',
            bullets: <String>[
              'Forecast math stays hidden until enough history exists.',
              'Missing history shows as unavailable, never as zero.',
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          key: const Key('schedule_forecast_explainer_thin_history'),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          decoration: BoxDecoration(
            color: AppColors.cardGlow,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                historyDays > 0
                    ? 'Need 60 days of history before we can explain this '
                          "forecast. Currently have $historyDays days. Keep "
                          "closing shifts and we'll surface the math here as "
                          "soon as the baseline window fills."
                    : 'Need 60 days of history before we can explain this '
                          'forecast. Close a few shifts and check back. We '
                          'never show zeroes for missing data.',
                style: AppTextStyles.body12(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
