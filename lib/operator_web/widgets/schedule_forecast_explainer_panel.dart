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
import 'operator_web_info_button.dart';
import 'operator_web_section_heading.dart';

class ScheduleForecastExplainerPanel extends StatelessWidget {
  const ScheduleForecastExplainerPanel({
    super.key,
    required this.context,
    this.onOpenWageAuthority,
  });

  final ScheduleForecastContext? context;
  final VoidCallback? onOpenWageAuthority;

  @override
  Widget build(BuildContext buildContext) {
    final ctx = context;
    if (ctx == null || !ctx.hasBaseline) {
      return _ThinHistoryBanner(historyDays: ctx?.historyDays ?? 0);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const OperatorWebSectionHeading(title: 'Why these numbers?'),
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
              Text(
                "Forge & Flow built this week's plan from your closed-shift "
                "history. Here's every number that shaped it.",
                style: AppTextStyles.body12(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
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
                    'Required hours costed at your set wages here. '
                    'The dollar bar your actuals are measured against.',
                captionWidget: _TheoreticalLaborVisibleCaption(
                  onOpenWageAuthority: onOpenWageAuthority,
                ),
                infoBody: const _TheoreticalLaborInfoBody(),
                showInfoAbove: true,
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
    this.captionWidget,
    this.infoBody,
    this.showInfoAbove = false,
    this.isLast = false,
  });

  final String keyName;
  final String label;
  final String value;
  final String caption;
  final Widget? captionWidget;
  final Widget? infoBody;
  final bool showInfoAbove;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key(keyName),
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.mono14(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    OperatorWebInfoButton(
                      key: Key('${keyName}_help'),
                      title: label,
                      tooltip: label,
                      showAbove: showInfoAbove,
                      body:
                          infoBody ??
                          Text(
                            caption,
                            style: AppTextStyles.body13(
                              color: AppColors.textSecondary,
                            ),
                          ),
                    ),
                  ],
                ),
                if (captionWidget != null) ...<Widget>[
                  const SizedBox(height: 2),
                  captionWidget!,
                ],
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

class _TheoreticalLaborVisibleCaption extends StatelessWidget {
  const _TheoreticalLaborVisibleCaption({required this.onOpenWageAuthority});

  final VoidCallback? onOpenWageAuthority;

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyles.body12(color: AppColors.textMuted);
    final linkStyle = style.copyWith(
      color: AppColors.sunsetDark,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.sunsetDark,
    );
    final opener = onOpenWageAuthority;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text('Required hours costed at your ', style: style),
        if (opener == null)
          Text('set wages here.', style: style)
        else
          Semantics(
            link: true,
            button: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(3),
              onTap: opener,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Text('set wages here.', style: linkStyle),
              ),
            ),
          ),
      ],
    );
  }
}

class _TheoreticalLaborInfoBody extends StatelessWidget {
  const _TheoreticalLaborInfoBody();

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyles.body12(color: AppColors.textMuted);
    return Text(
      'The model cost of the plan: required FOH hours times FOH wage, '
      'plus required BOH hours times BOH wage. It is the dollar floor '
      'your actual labor spend compares against.',
      style: style,
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
        const OperatorWebSectionHeading(title: 'Explain unavailable'),
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
