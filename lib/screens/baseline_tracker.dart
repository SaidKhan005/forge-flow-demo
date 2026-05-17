import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../state/active_target_profile_notifier.dart';
import 'package:forge_and_flow/services/benchmark_tracker_read_service.dart';
import '../services/baseline_authority_service.dart'
    show BaselineRangeGraphModel, BaselineGraphButtonEmphasis;
import '../domain/constants/app_defaults.dart';
import '../dev/demo_fixture_data.dart';
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

          // Daypart breakdown — per-period Target columns + OPZ Range,
          // plus a Whole Day rollup row. Per-period values read through
          // the active profile's `daypartFor` accessor; the slim strip
          // below carries the whole-day-only wage + theoretical % the
          // old "Targets Derived from Benchmark" card used to hold
          // (Decision 9 / Decision 10).
          if (view != null)
            SliverMainAxisGroup(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate:
                      StickySectionDelegate('DAYPART TARGET BREAKDOWNS'),
                ),
                // Per-Daypart Targets V1 (SC, Scenario 7): the rollup
                // line above the breakdown so the operator understands
                // each period is graded independently and one not-ready
                // period does not hold back the others. Copy is carried
                // on the model — never re-authored in the widget.
                SliverToBoxAdapter(
                  child: _PerPeriodRollupLine(
                    text: view.rangeGraphModel.perPeriodRollupLine,
                  ),
                ),
                SliverToBoxAdapter(
                  child: DaypartTable(
                    dayparts: view.daypartRanges,
                    profile:
                        context.watch<ActiveTargetProfileNotifier?>()?.profile,
                    servicePeriodDefinitions: view.servicePeriodDefinitions,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                // Same section-header grammar as DAYPART TARGET
                // BREAKDOWNS above
                // so the wage-mix + theoretical-floor strip reads as a
                // deliberate sibling, not an afterthought.
                const SliverPersistentHeader(
                  pinned: true,
                  delegate: StickySectionDelegate('OPERATING INPUTS'),
                ),
                const SliverToBoxAdapter(child: _OperatingStrip()),
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

/// Per-Daypart Targets V1 (SC, Scenario 7) — the per-period grading
/// rollup line shown above the DAYPART TARGET BREAKDOWNS. Reads its copy
/// verbatim from [BaselineRangeGraphModel.perPeriodRollupLine] (model-
/// owned, never re-authored here). Renders nothing when the line is
/// empty (legacy/no-signal paths) so it never adds dead chrome.
class _PerPeriodRollupLine extends StatelessWidget {
  final String text;
  const _PerPeriodRollupLine({required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Text(
        text,
        style: AppTextStyles.body13(color: AppColors.textMuted),
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
    //
    // Per-Daypart Targets V1 (SC): the `running_hot` verdict is a real,
    // drawable band but an unhealthy one — it gets the negative-red
    // badge (and a negative-red target tick) so the operator reads it as
    // a warning, not a build-up. Other degenerate states keep the warn
    // amber. Mirrors the existing warn/positive badge construction; no
    // new layout.
    final bool isRunningHot = graph.qualityTier == 'running_hot';
    final Color badgeColor = isRunningHot
        ? AppColors.negative
        : (graph.isDegenerate ? AppColors.warning : AppColors.positive);
    final Color targetTickColor =
        isRunningHot ? AppColors.negative : AppColors.sunset;
    final innerBoxColor = graph.isDegenerate
        ? AppColors.shimmer.withValues(alpha: 0.35)
        : AppColors.shimmer;
    final innerBoxBorder = isRunningHot
        ? AppColors.negative.withValues(alpha: 0.55)
        : (graph.isDegenerate
            ? AppColors.warning.withValues(alpha: 0.55)
            : AppColors.borderSubtle);

    return Container(
      margin: AppSpacing.screenH,
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

                    // Target tick — dominant; 4px, crosses through range
                    // box. Negative red when the operation is running
                    // hot (SC) so the unhealthy band reads as a warning.
                    Positioned(
                      left: targetPos - 2.0,
                      top: lineY - tickUp,
                      child: Container(
                        width: 4,
                        height: tickH,
                        color: targetTickColor,
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
          const AppDivider(),
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

          // Manager override CTA — taps into BaselineManagerScreen.
          //
          // Per-Daypart Targets V1 (SC) button policy: when the honest
          // state is `building_early` (no shifts to hand-pick yet — the
          // copy steers the operator to keep running the period) the CTA
          // is de-emphasized to a ghost outline so it does not compete
          // with that guidance. Every other state keeps the solid fill
          // (the copy actively steers to a manual pick, or the
          // recommended number stands).
          Builder(builder: (context) {
            final bool ghost = graph.buttonEmphasis ==
                BaselineGraphButtonEmphasis.deemphasized;
            final Color fg = ghost
                ? AppColors.sunset
                : AppColors.backgroundDeep;
            return GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const BaselineManagerScreen(),
                ),
              ),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: ghost ? Colors.transparent : AppColors.sunset,
                  border: Border.all(
                    color: ghost ? AppColors.sunset : AppColors.sunsetDark,
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.star_rounded,
                      size: 18,
                      color: fg,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        graph.overrideLabel,
                        style: AppTextStyles.mono12(
                            color: fg, weight: FontWeight.w700),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: fg,
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// Per-Daypart Targets V1 / Slice 2 — slim strip below the Daypart
/// Breakdown table (Decision 9 + Decision 10).
///
/// The old "Targets Derived from Benchmark" card is cut: its Target
/// Inputs + OPZ Range groups moved into the daypart table's per-period
/// columns. Its Wage + Theoretical Output groups can't fold into the
/// table because wages are restaurant-wide and theoretical % is
/// whole-day-only math (Decision 11), so they rehome here as a slim
/// two-half strip.
///
/// Labels are Option B (Jim Taylor vocabulary). No em dash anywhere
/// in the copy — "Theoretical Labor %: The Floor" uses a colon.
class _OperatingStrip extends StatelessWidget {
  const _OperatingStrip();

  @override
  Widget build(BuildContext context) {
    // Resolve all whole-day fields from the persisted
    // ActiveTargetProfile wherever available — the same runtime target
    // authority Shift / Variance / downstream surfaces read. Bridge
    // fallbacks are test-only; in production missing profile state
    // degrades honestly (the screen shows the unavailable message
    // above this strip via the CPLH range bar's honest badges).
    final profile = context.watch<ActiveTargetProfileNotifier?>()?.profile;
    final useBridgeFallbacks = BenchmarkTrackerReadService.instance.isBridgeOnly;

    if (profile == null && !useBridgeFallbacks) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.backgroundMid,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          'Benchmark target profile unavailable',
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
      );
    }

    // Wages — whole-day; Jim treats these as operational inputs, not
    // targets, and they have no per-period variant (Decision 11).
    final fohWage = profile?.fohWage ?? MeridianConfig.fohWage;
    final bohWage = profile?.bohWage ?? MeridianConfig.bohWage;

    // 7.55q.3: blended wage is a Benchmark-owned target metric read
    // from the shared `ActiveTargetProfile.targetBlendedWage` seam so
    // Benchmark and Variance WTD cannot drift. Fallback path is only
    // exercised in bridge-only tests.
    final blendedWage = profile?.targetBlendedWage ??
        ActiveTargetProfile.computeTargetBlendedWage(
          targetCPLH: BaselineData.derivedTargetCPLH,
          targetSPLH: BaselineData.derivedTargetSPLH,
          targetPPA: BaselineData.derivedTargetPPA,
          fohWage: fohWage,
          bohWage: bohWage,
        );

    // Theoretical labor % — whole-day-only math (whole-day wages ×
    // whole-day forecast). Per-period theoretical % shows up only where
    // it has period-specific inputs (Variance non-closed rows).
    final fohTheoreticalPct = profile?.theoreticalFohLaborPct ??
        BaselineData.derivedFohTheoreticalLaborPct;
    final bohTheoreticalPct = profile?.theoreticalBohLaborPct ??
        BaselineData.derivedBohTheoreticalLaborPct;
    final totalTheoreticalPct = profile?.theoreticalLaborPct ??
        BaselineData.derivedTheoreticalLaborPct;

    final wageRows = <(String, String)>[
      ('FOH Wage', '\$${fohWage.toStringAsFixed(2)}'),
      ('BOH Wage', '\$${bohWage.toStringAsFixed(2)}'),
      ('Blended Wage', '\$${blendedWage.toStringAsFixed(2)}'),
    ];
    final pctRows = <(String, String)>[
      ('FOH %', '${fohTheoreticalPct.toStringAsFixed(1)}%'),
      ('BOH %', '${bohTheoreticalPct.toStringAsFixed(1)}%'),
      ('Total %', '${totalTheoreticalPct.toStringAsFixed(1)}%'),
    ];

    // Same card grammar as the DaypartTable above (gradient surface,
    // hairline rule border, 3px radius) so this strip reads as its
    // deliberate sibling, with each half laid out as an aligned
    // label / value grid instead of the old ragged spaceBetween rows.
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.surface, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.rule, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _StripHalf(
                title: 'Operating Wage Mix',
                rows: wageRows,
              ),
            ),
            Container(width: 1, color: AppColors.rule),
            Expanded(
              child: _StripHalf(
                // No em dash — Option B uses a colon (Decision 10).
                title: 'Theoretical Labor %: The Floor',
                rows: pctRows,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One half of the Operating Inputs strip, laid out as an aligned
/// label / value grid that mirrors the DaypartTable's row grammar
/// (mono7 header cell, hairline rule dividers, value right-aligned to
/// a consistent column) so the two surfaces look like deliberate
/// siblings. Number formatting is owned by the caller and is already
/// consistent within each half (wages 2dp `$`, theoretical % 1dp `%`).
class _StripHalf extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;

  const _StripHalf({required this.title, required this.rows});

  // Both halves reserve a header band tall enough for a TWO-line
  // mono7 title so the hairline rule + every data row sit at the
  // same vertical position whether the title wraps or not. Operator
  // finding (live walkthrough): the long right title "Theoretical
  // Labor %: The Floor" wraps to two lines at phone width while the
  // short left title "Operating Wage Mix" stays one line, which
  // pushed the right half's rule + rows down and made the strip read
  // ragged. A fixed band makes the two halves deliberate, aligned
  // siblings regardless of title length. `_kHeaderFontSize` mirrors
  // `AppTextStyles.mono7`'s fontSize (11); the explicit line-height
  // multiplier makes the two-line band deterministic across font
  // metrics so the SizedBox height is exact.
  static const double _kHeaderFontSize = 11;
  static const double _kHeaderLineHeight = 1.3;
  static const double _kHeaderLines = 2;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Sub-group header — same weight/case as the DaypartTable
        // header cells. The title is left-aligned and vertically
        // centered inside a fixed two-line band so a one-line and a
        // two-line title occupy the same vertical space before the
        // rule. maxLines: 2 + ellipsis is the safety net: it keeps
        // the full text visible at phone/narrow width while
        // guaranteeing the band can never grow past two lines.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: SizedBox(
            height: _kHeaderFontSize * _kHeaderLineHeight * _kHeaderLines,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                style: AppTextStyles.mono7(color: AppColors.textSecondary)
                    .copyWith(height: _kHeaderLineHeight),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        const AppDivider(),
        ...rows.asMap().entries.map((entry) {
          final isLast = entry.key == rows.length - 1;
          final (label, value) = entry.value;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 14),
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(
                        label,
                        style: AppTextStyles.body11(
                          color: AppColors.primaryText,
                          style: FontStyle.normal,
                        ),
                        // Single-line so every data row is exactly one
                        // line tall in BOTH halves. The flex 5:4 column
                        // split starves the (longer) left labels at
                        // narrow width; left them to wrap, the left
                        // half's rows grew taller than the right's and
                        // the strip went ragged again below the now-
                        // aligned header band. Ellipsis is the 360px
                        // safety valve only — at the operator's phone
                        // width the full label is visible (verified in
                        // the widget test).
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 4,
                      child: Text(
                        value,
                        style:
                            AppTextStyles.mono10(color: AppColors.primaryText),
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isLast) const AppDivider(),
            ],
          );
        }),
      ],
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
