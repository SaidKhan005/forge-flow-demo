import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../data/active_target_profile_notifier.dart';
import '../data/legacy_fixture_data.dart';
import '../services/labor_model.dart';
import '../widgets/daypart_table.dart';
import 'baseline_manager_screen.dart';

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
                Text('60 Day Benchmark', style: AppTextStyles.display20()),
              ],
            ),
          ),

          // Manager override banner — only shown when active
          if (BaselineData.hasManagerOverride) _OverrideBanner(),

          // Summary cards — unchanged, readable at a glance
          _SummaryCards(),

          const SizedBox(height: 8),

          // CPLH range bar — replaces 60-day line chart
          _CplhRangeBar(),

          const SizedBox(height: 8),

          // Daypart breakdown
          _SectionLabel('DAYPART BREAKDOWN'),
          DaypartTable(dayparts: BaselineData.daypartRanges),

          // Baseline targets
          _SectionLabel('TARGETS DERIVED FROM BENCHMARK'),
          _BaselineTargetsCard(),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─── Section label ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 32, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 20,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [AppColors.sunset, AppColors.sunsetDark],
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  text,
                  style: AppTextStyles.mono14(
                      color: AppColors.textPrimary, weight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 2,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.sunset, AppColors.sunsetDark],
                ),
              ),
            ),
          ],
        ),
      );
}

// ─── Override banner ───────────────────────────────────────────────────────────

class _OverrideBanner extends StatelessWidget {
  const _OverrideBanner();

  @override
  Widget build(BuildContext context) {
    final count = BaselineData.selectedRecordCount;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.sunset, width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.star_rounded, size: 16, color: AppColors.sunset),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'MANAGER OVERRIDE ACTIVE',
                  style: AppTextStyles.mono8(color: AppColors.sunsetDark),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count STAR SHIFTS SELECTED',
                  style: AppTextStyles.mono10(
                      color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCards extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cards = [
      ('TOTAL COVERS LAST 60 DAYS', BaselineData.historicalTotalCoversTracked.toString()),
    ];

    final card = cards.first;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.backgroundMid,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(card.$1, style: AppTextStyles.mono7()),
            const SizedBox(height: 6),
            Text(card.$2,
                style: AppTextStyles.mono16(color: AppColors.textPrimary)),
          ],
        ),
      ),
    );
  }

}

class _CplhRangeBar extends StatelessWidget {
  const _CplhRangeBar();

  @override
  Widget build(BuildContext context) {
    final graph      = BaselineData.rangeGraphModel;
    final validation = BaselineData.baselineRangeValidation;
    final badgeColor = validation.showWarning ? AppColors.warning : AppColors.positive;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.backgroundDeep],
        ),
        border: Border.all(color: AppColors.borderStrong, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(graph.title,
              style: AppTextStyles.mono11(color: AppColors.textSecondary)),
          const SizedBox(height: 18),

          // Endpoint labels — full-width row, float above the line endpoints
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(graph.startLabel,
                        style: AppTextStyles.mono7(color: AppColors.textMuted)),
                    const SizedBox(height: 3),
                    Text(graph.displayRangeStartCPLH.toStringAsFixed(2),
                        style: AppTextStyles.mono14(color: AppColors.textPrimary)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(graph.endLabel,
                        textAlign: TextAlign.right,
                        style: AppTextStyles.mono7(color: AppColors.textMuted)),
                    const SizedBox(height: 3),
                    Text(graph.displayRangeEndCPLH.toStringAsFixed(2),
                        style: AppTextStyles.mono14(color: AppColors.textPrimary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Graph — all positions read from rangeGraphModel, full card width
          LayoutBuilder(
            builder: (context, constraints) {
              final totalWidth = constraints.maxWidth;
              final targetPos = (graph.targetPosition * totalWidth).clamp(0.0, totalWidth);
              final opzLeft   = (graph.activeRangeStartPosition * totalWidth).clamp(0.0, totalWidth);
              final opzRight  = (graph.activeRangeEndPosition * totalWidth).clamp(0.0, totalWidth);
              final opzW      = math.max(2.0, opzRight - opzLeft);

              // Vertical layout — all constants, no recomputation
              const double opzLabelH   = 14.0;  // range label text
              const double opzLabelGap = 4.0;
              const double opzBoxPad   = 10.0;  // OPZ box extends this far above/below line
              const double lineY       = opzLabelH + opzLabelGap + opzBoxPad; // 28
              const double lnH         = 3.0;   // thicker line for presence
              const double opzBoxTop   = lineY - opzBoxPad; // 18
              const double opzBoxH     = lnH + opzBoxPad * 2; // 23
              const double tickUp      = opzBoxPad + 3; // tick extends 3px above OPZ box top
              const double tickH       = tickUp + lnH + opzBoxPad + 3; // full crossing height
              const double glowW       = 16.0;  // target glow halo width
              const double belowGap    = 9.0;
              const double targetLabelH = 46.0; // mono8 label + 3px gap + mono20 value
              const double stkH        = lineY + lnH + belowGap + targetLabelH; // 86

              return SizedBox(
                height: stkH,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Range label — centered above the highlighted box
                    Positioned(
                      left: (opzLeft + opzW / 2 - 27.0)
                          .clamp(0.0, math.max(0.0, totalWidth - 54.0)),
                      top: 0,
                      child: Text(
                        graph.rangeLabel,
                        style: AppTextStyles.mono7(color: AppColors.textSecondary),
                      ),
                    ),

                    // Highlighted range region — green-bordered box over the line
                    Positioned(
                      left: opzLeft,
                      top: opzBoxTop,
                      child: Container(
                        width: opzW,
                        height: opzBoxH,
                        decoration: BoxDecoration(
                          color: AppColors.shimmer,
                          border: Border.all(
                            color: AppColors.borderSubtle,
                            width: 1,
                          ),
                        ),
                      ),
                    ),

                    // Horizontal range line — neutral, full-width
                    Positioned(
                      left: 0,
                      right: 0,
                      top: lineY,
                      child: Container(
                        height: lnH,
                        color: AppColors.textSecondary.withValues(alpha: 0.45),
                      ),
                    ),

                    // Left endpoint tick
                    Positioned(
                      left: 0,
                      top: lineY - 7,
                      child: Container(
                        width: 2,
                        height: 18,
                        color: AppColors.textSecondary.withValues(alpha: 0.7),
                      ),
                    ),

                    // Right endpoint tick
                    Positioned(
                      right: 0,
                      top: lineY - 7,
                      child: Container(
                        width: 2,
                        height: 18,
                        color: AppColors.textSecondary.withValues(alpha: 0.7),
                      ),
                    ),

                    // Target glow halo — subtle teal wash behind the tick
                    Positioned(
                      left: (targetPos - glowW / 2)
                          .clamp(0.0, math.max(0.0, totalWidth - glowW)),
                      top: lineY - tickUp - 2,
                      child: Container(
                        width: glowW,
                        height: tickH + 4,
                        color: AppColors.sunset.withValues(alpha: 0.12),
                      ),
                    ),

                    // Target tick — dominant; 4px teal, crosses through range box
                    Positioned(
                      left: targetPos - 2.0,
                      top: lineY - tickUp,
                      child: Container(
                        width: 4,
                        height: tickH,
                        color: AppColors.sunset,
                      ),
                    ),

                    // CPLH TARGET label + value — below the line, anchored to tick
                    Positioned(
                      left: (targetPos - 36.0)
                          .clamp(0.0, math.max(0.0, totalWidth - 72.0)),
                      top: lineY + lnH + belowGap,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('CPLH TARGET',
                              style: AppTextStyles.mono8(color: AppColors.sunsetDark)),
                          const SizedBox(height: 3),
                          Text(graph.targetCPLH.toStringAsFixed(2),
                              style: AppTextStyles.mono20(
                                  color: AppColors.sunset,
                                  weight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          const SizedBox(height: 16),
          Container(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: 16),

          // Explanation block
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  border: Border.all(color: badgeColor, width: 1),
                ),
                child: Text(validation.statusLabel,
                    style: AppTextStyles.mono8(color: badgeColor)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  graph.recommendedExplanation,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Manager override CTA — taps into BaselineManagerScreen
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const BaselineManagerScreen(),
              ),
            ),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.sunset,
                border: Border.all(color: AppColors.sunsetDark, width: 1),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.star_rounded,
                    size: 18,
                    color: AppColors.backgroundDeep,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      graph.overrideLabel,
                      style: AppTextStyles.mono12(
                          color: AppColors.backgroundDeep,
                          weight: FontWeight.w700),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: AppColors.backgroundDeep,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BaselineTargetsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Resolve wage rates from the persisted profile. The profile now carries
    // wages synced from wage authority (via WageStandardContextService).
    // The MeridianConfig guard only fires if the profile hasn't loaded yet.
    final profile =
        context.watch<ActiveTargetProfileNotifier?>()?.profile;
    final fohWage = profile?.fohWage ?? MeridianConfig.fohWage;
    final bohWage = profile?.bohWage ?? MeridianConfig.bohWage;
    final blendedWage = _targetBlendedWage(fohWage, bohWage);

    // Grouped in preferred product order: wage → OPZ → inputs → output
    final groups = <(String, List<(String, String)>)>[
      ('WAGE', [
        ('FOH WAGE', '\$${fohWage.toStringAsFixed(2)}'),
        ('BOH WAGE', '\$${bohWage.toStringAsFixed(2)}'),
        ('BLENDED WAGE', '\$${blendedWage.toStringAsFixed(2)}'),
      ]),
      ('OPZ RANGE', [
        ('OPZ FLOOR', BaselineData.opzFloorCPLH.toStringAsFixed(2)),
        ('OPZ CEILING', BaselineData.opzCeilingCPLH.toStringAsFixed(2)),
        ('HEADROOM', BaselineData.opzHeadroomCPLH.toStringAsFixed(2)),
      ]),
      ('TARGET INPUTS', [
        ('CPLH', BaselineData.derivedTargetCPLH.toStringAsFixed(2)),
        ('SPLH', '\$${BaselineData.derivedTargetSPLH.toStringAsFixed(0)}'),
        ('PPA', '\$${BaselineData.derivedTargetPPA.toStringAsFixed(2)}'),
      ]),
      ('THEORETICAL OUTPUT', [
        (
          'THEORETICAL LABOR %',
          '${BaselineData.derivedTheoreticalLaborPct.toStringAsFixed(1)}%'
        ),
      ]),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var gi = 0; gi < groups.length; gi++) ...[
            if (gi > 0) const SizedBox(height: 12),
            // Group header
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(groups[gi].$1,
                  style: AppTextStyles.mono8(color: AppColors.textSecondary)),
            ),
            // Group rows
            ...groups[gi].$2.map((t) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(t.$1,
                          style: AppTextStyles.mono10(
                              color: AppColors.textMuted)),
                      Text(
                        t.$2,
                        style: AppTextStyles.mono14(
                            color: AppColors.textPrimary),
                      ),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

/// Derives the target blended wage from current baseline demand and target
/// standards. Not stored — always computed from the FOH/BOH model-hour mix.
double _targetBlendedWage(double fohWage, double bohWage) {
  final fohHours = LaborModel.modelFohHours(
    BaselineData.historicalWeeklyAvgCovers,
    BaselineData.derivedTargetCPLH,
  );
  final bohHours = LaborModel.modelBohHoursFromSales(
    BaselineData.historicalWeeklyAvgCovers * BaselineData.derivedTargetPPA,
    BaselineData.derivedTargetSPLH,
  );
  final total = fohHours + bohHours;
  return total > 0
      ? (fohHours * fohWage + bohHours * bohWage) / total
      : 0.0;
}
