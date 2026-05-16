import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';

import '../theme/app_theme.dart';
import '../state/active_target_profile_notifier.dart';
import '../state/demand_forecast_context_notifier.dart';
import '../domain/constants/app_defaults.dart';
import '../dev/demo_fixture_data.dart';
import '../state/schedule_distribution_weights_notifier.dart';
import '../domain/models/active_target_profile.dart';
import '../utils/formatters.dart';
import '../widgets/app_screen_header.dart';
import '../widgets/schedule_day_row.dart';
import '../widgets/sticky_section_delegate.dart';
import 'schedule/schedule_forecast_notifier.dart';

// 7.55o.3: re-export moved symbols so callers that still import
// `schedule_builder.dart` (tests, etc.) see the same public surface.
export 'schedule/schedule_forecast_notifier.dart'
    show ScheduleForecastNotifier, ScheduleLockedPlanLoadState;
export 'schedule/schedule_view_models.dart'
    show ScheduleDayView, ScheduleDaySubrow;

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
/// These config-default values are replaced by [updateTargets] when
/// the real profile arrives.
///
/// Per-Daypart V1 (Slice 3) — Gap 41 / Design Rule 2: the rate / OPZ /
/// theoretical-% fields previously carried `0` as a "unused on locked
/// path" sentinel. Design Rule 2 forbids `0`-as-null sentinels (they
/// collide with degenerate cycles where the target genuinely IS zero).
/// `ActiveTargetProfile`'s whole-day scalar fields are non-nullable
/// `double` with a documented `0.0` divide-by-zero fallback for legacy
/// consumers (see `active_target_profile.dart` Design Rule 2 note), so
/// the honest fix here is to seed real config defaults from
/// [MeridianConfig] — the same source this profile already uses for
/// wages and the same defaults the production bootstrap path resolves —
/// rather than fabricate zeros. The brief pre-load window now shows
/// honest config defaults instead of fake zeros.
ActiveTargetProfile _bootstrapFallbackProfile() {
  return ActiveTargetProfile(
    targetProfileId: 'schedule-bootstrap-fallback',
    restaurantId: '',
    sourceType: 'system_baseline',
    targetCPLH: MeridianConfig.targetCPLH,
    targetSPLH: MeridianConfig.targetSPLH,
    targetPPA: BaselineData.derivedTargetPPA,
    fohWage: MeridianConfig.fohWage,
    bohWage: MeridianConfig.bohWage,
    opzFloorCPLH: MeridianConfig.opzFloorCPLH,
    opzCeilingCPLH: MeridianConfig.opzCeilingCPLH,
    theoreticalFohLaborPct: MeridianConfig.fohTheoreticalLaborPct,
    theoreticalBohLaborPct: MeridianConfig.bohTheoreticalLaborPct,
    theoreticalLaborPct: MeridianConfig.totalTheoreticalLaborPct,
    builtAt: '',
  );
}

/// Per-Daypart V1 (Slice 3) — test-only accessor for the bootstrap
/// fallback profile. Lets the Gap 41 / Design Rule 2 sentinel-removal
/// test assert (via the public [ActiveTargetProfile] surface) that the
/// previously-sentinelled fields now carry honest config defaults.
@visibleForTesting
ActiveTargetProfile scheduleBootstrapFallbackProfileForTest() =>
    _bootstrapFallbackProfile();

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
                      value: notifier.hasPlan
                          ? notifier.weeklyCovers.toString()
                          : '--',
                    ),
                    const SizedBox(width: 8),
                    AppHeaderStat(
                      label: 'SALES',
                      value: notifier.hasPlan
                          ? '\$${Fmt.dollars(notifier.forecastedSales)}'
                          : '--',
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
      ('FOH HRS', hasPlan ? notifier.requiredFohHours.toString() : '--'),
      ('BOH HRS', hasPlan ? notifier.requiredBohHours.toString() : '--'),
      ('LABOR %', labor()),
      (
        'LABOR \$',
        hasPlan
            ? '\$${Fmt.dollars(notifier.forecastedTotalLaborDollar)}'
            : '--',
      ),
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
      final message = _emptySchedulePlanMessage(notifier);
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.rule, width: 1),
        ),
        child: Text(
          message,
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
      final message = _emptySchedulePlanMessage(widget.notifier);
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.rule, width: 1),
        ),
        child: Text(
          message,
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

String _emptySchedulePlanMessage(ScheduleForecastNotifier notifier) {
  if (!notifier.isLockedAuthority) {
    return 'No schedule plan available';
  }

  return switch (notifier.lockedPlanLoadState) {
    ScheduleLockedPlanLoadState.loading =>
      'Loading locked server weekly plan',
    ScheduleLockedPlanLoadState.unavailable =>
      'No locked server weekly plan yet',
    _ => 'No schedule plan available',
  };
}

