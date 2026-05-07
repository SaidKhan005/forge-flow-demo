import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../state/active_target_profile_notifier.dart';
import 'package:forge_and_flow/services/benchmark_tracker_read_service.dart';
import '../data/app_defaults.dart';
// ops-debt.demo-fallback-hardening: prod widgets must not import lib/dev/.
// `BaselineData` and `BaselineRangeGraphModel` are owned by
// `baseline_authority_service.dart` (Layer 3); the
// `lib/dev/demo_fixture_data.dart` re-export is demo-only.
import '../services/baseline_authority_service.dart';
import '../domain/models/active_target_profile.dart';
import '../widgets/app_screen_header.dart';
import '../widgets/daypart_table.dart';
import '../widgets/sticky_section_delegate.dart';
import 'baseline_manager_screen.dart';

class BaselineTracker extends StatefulWidget {
  const BaselineTracker({super.key});

  @override
  State<BaselineTracker> createState() => _BaselineTrackerState();
}

class _BaselineTrackerState extends State<BaselineTracker> {
  BenchmarkTrackerView? _view;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final service = BenchmarkTrackerReadService.instance;
    if (service.isBridgeOnly) {
      _view = service.bridgeView();
    } else {
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    BenchmarkTrackerView? view;
    try {
      view = await BenchmarkTrackerReadService.instance.load();
    } catch (_) {
      view = null;
    }
    if (!mounted) return;
    setState(() {
      _view = view;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return FadingHeaderShell(
      header: AppScreenHeader(
        title: '60 Day Benchmark',
        bottom: view == null
            ? null
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AppHeaderStat(
                    label: 'TOTAL COVERS LAST 60 DAYS:',
                    value: view.historicalTotalCoversTracked.toString(),
                  ),
                ),
              ),
      ),
      child: CustomScrollView(
        cacheExtent: 9999,
        slivers: [
          // Manager override banner — only shown when active
          if (_loading && view == null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            )
          else if (view == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Text(
                  'Benchmark evidence unavailable',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ),
            )
          else if (view.hasManagerOverride)
            SliverToBoxAdapter(
              child: _OverrideBanner(selectedCount: view.selectedShiftCount),
            ),

          // TOTAL COVERS LAST 60 DAYS now lives in the screen header
          // bottom slot — see AppHeaderStat above. Card removed from the
          // body to stop duplicating the same number.

          const SliverToBoxAdapter(child: SizedBox(height: 8)),

          // CPLH range bar — replaces 60-day line chart
          if (view != null)
            SliverMainAxisGroup(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: StickySectionDelegate('CPLH RANGE & TARGET'),
                ),
                SliverToBoxAdapter(
                  child: _CplhRangeBar(graph: view.rangeGraphModel),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
              ],
            ),

          // Daypart breakdown
          if (view != null)
            SliverMainAxisGroup(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: StickySectionDelegate('DAYPART BREAKDOWN'),
                ),
                SliverToBoxAdapter(
                  child: DaypartTable(dayparts: view.daypartRanges),
                ),
              ],
            ),

          // Baseline targets
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('TARGETS DERIVED FROM BENCHMARK'),
              ),
              SliverToBoxAdapter(child: _BaselineTargetsCard()),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ],
      ),
    );
  }
}

// _SectionLabel removed — replaced by shared StickySectionDelegate
// pinned headers in the CustomScrollView slivers above.

// ─── Override banner ───────────────────────────────────────────────────────────

class _OverrideBanner extends StatelessWidget {
  final int selectedCount;
  const _OverrideBanner({required this.selectedCount});

  @override
  Widget build(BuildContext context) {
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
                  '$selectedCount STAR SHIFTS SELECTED',
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

// _SummaryCards removed — TOTAL COVERS LAST 60 DAYS is now surfaced in
// the screen header bottom slot via AppHeaderStat instead of in a
// dedicated card. Same data, single source of truth in the UI.

class _CplhRangeBar extends StatelessWidget {
  final BaselineRangeGraphModel graph;

  const _CplhRangeBar({required this.graph});

  @override
  Widget build(BuildContext context) {
    // 7.55p.5h: badge colour and box opacity come from the honest
    // `isDegenerate` flag + normalized `qualityTier`. `isDegenerate` is
    // the single truth signal for whether the graph should teach
    // precision.
    final badgeColor =
        graph.isDegenerate ? AppColors.warning : AppColors.positive;
    final innerBoxColor = graph.isDegenerate
        ? AppColors.shimmer.withValues(alpha: 0.35)
        : AppColors.shimmer;
    final innerBoxBorder = graph.isDegenerate
        ? AppColors.warning.withValues(alpha: 0.55)
        : AppColors.borderSubtle;

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

                    // Highlighted range region — dimmed in degenerate states
                    // so it does not read as confident OPZ truth (7.55p.5h).
                    Positioned(
                      left: opzLeft,
                      top: opzBoxTop,
                      child: Container(
                        width: opzW,
                        height: opzBoxH,
                        decoration: BoxDecoration(
                          color: innerBoxColor,
                          border: Border.all(
                            color: innerBoxBorder,
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

          // Explanation block (7.55p.5h honest badge + optional fallback copy)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  border: Border.all(color: badgeColor, width: 1),
                ),
                child: Text(graph.statusBadgeLabel,
                    style: AppTextStyles.mono8(color: badgeColor)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      graph.recommendedExplanation,
                      style:
                          AppTextStyles.body13(color: AppColors.textSecondary),
                    ),
                    if (graph.degenerateFallbackMessage != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        graph.degenerateFallbackMessage!,
                        style:
                            AppTextStyles.body13(color: AppColors.textMuted),
                      ),
                    ],
                  ],
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
    // Phase 7.55p.5: Resolve all target-authority fields from the persisted
    // ActiveTargetProfile wherever available. This is the same runtime target
    // authority used by Shift, Variance, and downstream surfaces.
    //
    // Bridge fallbacks are test-only. In production, missing profile state
    // degrades honestly above instead of silently reusing BaselineData.
    // The graph/range-quality source stays separate because it represents
    // selection-context truth, not runtime target authority.
    final profile = context.watch<ActiveTargetProfileNotifier?>()?.profile;
    final useBridgeFallbacks = BenchmarkTrackerReadService.instance.isBridgeOnly;

    if (profile == null && !useBridgeFallbacks) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.backgroundMid,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
        ),
        child: Text(
          'Benchmark target profile unavailable',
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
      );
    }

    // Wages
    final fohWage = profile?.fohWage ?? MeridianConfig.fohWage;
    final bohWage = profile?.bohWage ?? MeridianConfig.bohWage;

    // 7.55q.3: blended wage is a Benchmark-owned target metric. Read it
    // from the shared `ActiveTargetProfile.targetBlendedWage` seam (the
    // same seam Variance WTD now consumes via
    // `WeekData.theoreticalBlendedWage`) so Benchmark and WTD cannot
    // drift on the same active target state. The fallback path is only
    // exercised in bridge-only tests.
    final blendedWage = profile?.targetBlendedWage ??
        ActiveTargetProfile.computeTargetBlendedWage(
          targetCPLH: BaselineData.derivedTargetCPLH,
          targetSPLH: BaselineData.derivedTargetSPLH,
          targetPPA: BaselineData.derivedTargetPPA,
          fohWage: fohWage,
          bohWage: bohWage,
        );

    // OPZ bounds — from persisted profile (locked on TargetCycle)
    final opzFloor = profile?.opzFloorCPLH ?? BaselineData.opzFloorCPLH;
    final opzCeiling = profile?.opzCeilingCPLH ?? BaselineData.opzCeilingCPLH;
    final targetCPLH = profile?.targetCPLH ?? BaselineData.derivedTargetCPLH;
    final headroom = opzCeiling - targetCPLH;

    // Target inputs — from persisted profile
    final targetSPLH = profile?.targetSPLH ?? BaselineData.derivedTargetSPLH;
    final targetPPA = profile?.targetPPA ?? BaselineData.derivedTargetPPA;

    // Theoretical output — FOH, BOH, and total from persisted profile
    final fohTheoreticalPct = profile?.theoreticalFohLaborPct
        ?? BaselineData.derivedFohTheoreticalLaborPct;
    final bohTheoreticalPct = profile?.theoreticalBohLaborPct
        ?? BaselineData.derivedBohTheoreticalLaborPct;
    final totalTheoreticalPct = profile?.theoreticalLaborPct
        ?? BaselineData.derivedTheoreticalLaborPct;

    // Grouped in preferred product order: wage → OPZ → inputs → output
    final groups = <(String, List<(String, String)>)>[
      ('WAGE', [
        ('FOH WAGE', '\$${fohWage.toStringAsFixed(2)}'),
        ('BOH WAGE', '\$${bohWage.toStringAsFixed(2)}'),
        ('BLENDED WAGE', '\$${blendedWage.toStringAsFixed(2)}'),
      ]),
      ('OPZ RANGE', [
        ('OPZ FLOOR', opzFloor.toStringAsFixed(2)),
        ('OPZ CEILING', opzCeiling.toStringAsFixed(2)),
        ('HEADROOM', headroom.toStringAsFixed(2)),
      ]),
      ('TARGET INPUTS', [
        ('CPLH', targetCPLH.toStringAsFixed(2)),
        ('SPLH', '\$${targetSPLH.toStringAsFixed(0)}'),
        ('PPA', '\$${targetPPA.toStringAsFixed(2)}'),
      ]),
      ('THEORETICAL OUTPUT', [
        ('FOH THEORETICAL %', '${fohTheoreticalPct.toStringAsFixed(1)}%'),
        ('BOH THEORETICAL %', '${bohTheoreticalPct.toStringAsFixed(1)}%'),
        ('TOTAL THEORETICAL %', '${totalTheoreticalPct.toStringAsFixed(1)}%'),
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

// 7.55q.3: the local `_targetBlendedWage(...)` helper that previously
// derived blended wage from `BaselineData.historicalWeeklyAvgCovers`
// and the target rate inputs is gone. Benchmark now reads
// `profile.targetBlendedWage` (or the cover-independent
// `ActiveTargetProfile.computeTargetBlendedWage(...)` static formula
// as a config-default fallback) — the same shared seam consumed by
// Variance WTD so the two surfaces cannot drift.
