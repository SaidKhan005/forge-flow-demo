// Phase 7.13 — Variance Coaching Layout Cleanup
// Phase 7.55k.4 — Full Week Projection semantics: read service, honest
// row provenance, day-total reconciliation, projected-row copy fix.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../data/active_target_profile_notifier.dart';
import '../data/learn_benchmark_context_service.dart';
import '../data/legacy_fixture_data.dart';
import '../data/shift_data_source.dart';
import '../data/week_data_notifier.dart';
import '../models/history_benchmark_daypart_summary.dart';
import '../models/history_pattern_record.dart';
import '../models/learn_benchmark_context.dart';
import '../models/shift_record.dart';
import '../models/variance_week_projection_row.dart';
import '../models/week_data.dart';
import '../models/week_record.dart';
import '../widgets/dollar_impact_card.dart';
import '../models/learn_repeatable_win_summary.dart';
import '../models/learn_teaching_summary.dart';
import '../services/daypart_evidence_visibility_policy.dart';
import '../services/history_benchmark_daypart_read_service.dart';
import '../services/learn_repeatable_wins_read_service.dart';
import '../services/history_teaching_analyzer.dart';
import '../services/learn_teaching_analyzer.dart';
import '../services/variance_week_projection_read_service.dart';
import '../utils/formatters.dart';
import '../widgets/app_screen_header.dart';
import '../widgets/lever_card.dart';
import '../widgets/week_history_tile.dart';
import 'week_detail_screen.dart';

class VarianceReport extends StatelessWidget {
  const VarianceReport({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: FadingHeaderShell(
        header: AppScreenHeader(
          title: 'Variance',
          bottom: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                    color: AppColors.sunset.withValues(alpha: 0.2),
                    width: 1),
              ),
            ),
            child: TabBar(
              isScrollable: false,
              labelStyle:
                  AppTextStyles.mono12(color: AppColors.sunsetDark),
              unselectedLabelStyle:
                  AppTextStyles.mono12(color: AppColors.textMuted),
              indicatorColor: AppColors.sunset,
              indicatorWeight: 3,
              labelColor: AppColors.sunsetDark,
              unselectedLabelColor: AppColors.textMuted,
              dividerColor: Colors.transparent,
              tabs: const [
                Tab(text: 'This Week'),
                Tab(text: 'History'),
                Tab(text: 'Learn'),
              ],
            ),
          ),
        ),
        child: TabBarView(
          children: [
            _ThisWeekTab(),
            _HistoryTab(),
            _LearnTab(),
          ],
        ),
      ),
    );
  }
}

// ─── This Week tab ────────────────────────────────────────────────────────────

class _ThisWeekTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<WeekDataNotifier>(
      builder: (context, notifier, _) {
        if (notifier.isLoading) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.sunset),
          );
        }
        final weekData = notifier.weekData;
        if (weekData == null) {
          return Center(
            child: Text('No closed shifts yet.',
                style: AppTextStyles.body13(color: AppColors.textMuted)),
          );
        }
        return _ThisWeekContent(weekData: weekData);
      },
    );
  }
}

// ─── This Week content ────────────────────────────────────────────────────────

class _ThisWeekContent extends StatelessWidget {
  final WeekData weekData;
  const _ThisWeekContent({required this.weekData});

  @override
  Widget build(BuildContext context) {
    final lever = LeverCards.all.firstWhere(
      (l) => l.id == weekData.primaryLeverId,
      orElse: () => LeverCards.coversDown,
    );

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Sub-header ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
            child: Text('This Week', style: AppTextStyles.display20()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Text(
              '${weekData.weekLabel} · ${weekData.lastClosedDay} · Day ${weekData.closedDayNumber} of 7',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          ),

          // ── WTD Variance Table ────────────────────────────────────────
          _SectionLabel('WEEK-TO-DATE vs LOCKED PLAN'),
          _WtdTable(data: weekData),

          // ── Dollar Impact Card ────────────────────────────────────────
          _SectionLabel('DOLLAR IMPACT'),
          DollarImpactCard(
            weekImpact: weekData.dollarGap,
            monthImpact: weekData.monthDollarImpact,
            sixtyDayImpact: weekData.sixtyDayDollarImpact,
            annualizedImpact: weekData.annualizedDollarImpact,
            footerText: 'Through ${weekData.lastClosedDay}',
          ),

          // ── Primary Lever ─────────────────────────────────────────────
          _SectionLabel('PRIMARY DRIVER'),
          LeverCardWidget(data: lever),

          // ── Full Week: Collapsible Day Rows ───────────────────────────
          _SectionLabel('FULL WEEK PROJECTION'),
          _FullWeekLoader(
              theoreticalBlendedWage: weekData.theoreticalBlendedWage,
              weekId: weekData.weekId),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ─── Section label — teal accent ─────────────────────────────────────────────

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
                  style: AppTextStyles.mono14(color: AppColors.textPrimary, weight: FontWeight.w700),
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

// ─── WTD Variance Table ───────────────────────────────────────────────────────

class _WtdTable extends StatelessWidget {
  final WeekData data;
  const _WtdTable({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // ── Teal-accented column header band ─────────────────────────
          _WtdColumnHeader(),

          // ── CONDITIONS group band ────────────────────────────────────
          _GroupBand('CONDITIONS'),

          // ── Condition rows ──────────────────────────────────────────
          _TableRow(
            label: 'Covers',
            target: data.wtdForecastCovers.toString(),
            actual: data.totalCovers.toString(),
            variance: Fmt.varStr(data.totalCovers - data.wtdForecastCovers),
            varColor: Fmt.varColor('Covers',
                (data.totalCovers - data.wtdForecastCovers).toDouble()),
          ),
          _divider(),
          _TableRow(
            label: 'Blended Wage',
            target: '\$${data.theoreticalBlendedWage.toStringAsFixed(2)}',
            actual: '\$${data.avgBlendedWage.toStringAsFixed(2)}',
            variance: Fmt.varDollars(
                data.avgBlendedWage - data.theoreticalBlendedWage),
            varColor: Fmt.varColor('Blended Wage',
                data.avgBlendedWage - data.theoreticalBlendedWage),
          ),

          // ── EXECUTION group band ─────────────────────────────────────
          _GroupBand('EXECUTION'),

          // ── Execution rows ──────────────────────────────────────────
          _TableRow(
            label: 'PPA',
            target: '\$${data.targetPPA.toStringAsFixed(2)}',
            actual: '\$${data.avgPPA.toStringAsFixed(2)}',
            variance: Fmt.varDollars(data.avgPPA - data.targetPPA),
            varColor: Fmt.varColor('PPA', data.avgPPA - data.targetPPA),
          ),
          _divider(),
          _TableRow(
            label: 'FOH Hours',
            target: data.targetFohHoursWtd?.toString() ?? '—',
            actual: data.totalFohHours.toString(),
            variance: data.targetFohHoursWtd != null
                ? Fmt.varStr(data.totalFohHours - data.targetFohHoursWtd!)
                : '—',
            varColor: data.targetFohHoursWtd != null
                ? Fmt.varColor('FOH Hours',
                    (data.totalFohHours - data.targetFohHoursWtd!).toDouble())
                : AppColors.textMuted,
          ),
          _divider(),
          _TableRow(
            label: 'BOH Hours',
            target: data.targetBohHoursWtd?.toString() ?? '—',
            actual: data.totalBohHours.toString(),
            variance: data.targetBohHoursWtd != null
                ? Fmt.varStr(data.totalBohHours - data.targetBohHoursWtd!)
                : '—',
            varColor: data.targetBohHoursWtd != null
                ? Fmt.varColor('BOH Hours',
                    (data.totalBohHours - data.targetBohHoursWtd!).toDouble())
                : AppColors.textMuted,
          ),
          _divider(),
          _TableRow(
            label: 'CPLH',
            target: data.targetCPLH.toStringAsFixed(2),
            actual: data.avgCPLH.toStringAsFixed(2),
            variance: Fmt.varDelta(data.avgCPLH - data.targetCPLH),
            varColor: Fmt.varColor('CPLH', data.avgCPLH - data.targetCPLH),
          ),
          _divider(),
          _TableRow(
            label: 'SPLH',
            target: '\$${data.targetSPLH.toStringAsFixed(0)}',
            actual: '\$${data.avgSPLH.toStringAsFixed(0)}',
            variance: Fmt.varDollars(data.avgSPLH - data.targetSPLH),
            varColor: Fmt.varColor('SPLH', data.avgSPLH - data.targetSPLH),
          ),

          // ── OUTCOMES group band ──────────────────────────────────────
          _GroupBand('OUTCOMES'),

          // ── Outcome rows ────────────────────────────────────────────
          _TableRow(
            label: 'FOH Labor %',
            target: '${data.theoreticalFohLaborPct.toStringAsFixed(1)}%',
            actual: '${data.actualFohLaborPct.toStringAsFixed(1)}%',
            variance: Fmt.varPts(
                data.actualFohLaborPct - data.theoreticalFohLaborPct),
            varColor: Fmt.varColor('FOH Labor %',
                data.actualFohLaborPct - data.theoreticalFohLaborPct),
          ),
          _divider(),
          _TableRow(
            label: 'BOH Labor %',
            target: '${data.theoreticalBohLaborPct.toStringAsFixed(1)}%',
            actual: '${data.actualBohLaborPct.toStringAsFixed(1)}%',
            variance: Fmt.varPts(
                data.actualBohLaborPct - data.theoreticalBohLaborPct),
            varColor: Fmt.varColor('BOH Labor %',
                data.actualBohLaborPct - data.theoreticalBohLaborPct),
          ),
          _divider(),
          _TableRow(
            label: 'Total Labor %',
            target: '${data.theoreticalLaborPct.toStringAsFixed(1)}%',
            actual: '${data.actualLaborPct.toStringAsFixed(1)}%',
            variance: Fmt.varPts(data.variancePts),
            varColor: Fmt.varColor('Total Labor %', data.variancePts),
            isBold: true,
          ),
        ],
      ),
    );
  }

  static Widget _divider() =>
      Container(height: 1, color: AppColors.borderSubtle);
}

// ─── WTD column header band ───────────────────────────────────────────────────

class _WtdColumnHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundSurface, AppColors.shimmer],
        ),
        border: Border(
          bottom: BorderSide(
              color: AppColors.sunset.withValues(alpha: 0.15), width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Expanded(flex: 5, child: SizedBox()),
          Expanded(
            flex: 3,
            child: Text('TARGET',
                style: AppTextStyles.mono8(color: AppColors.textMuted),
                textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 3,
            child: Text('ACTUAL',
                style: AppTextStyles.mono8(color: AppColors.textSecondary),
                textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 3,
            child: Text('VAR',
                style: AppTextStyles.mono8(color: AppColors.sunsetDark),
                textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

// ─── Coaching group band ─────────────────────────────────────────────────────

class _GroupBand extends StatelessWidget {
  final String label;
  const _GroupBand(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.backgroundDeep,
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
      child: Row(
        children: [
          Container(width: 2, height: 10, color: AppColors.sunsetDark),
          const SizedBox(width: 6),
          Text(label,
              style: AppTextStyles.mono8(color: AppColors.sunsetDark)),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
                height: 1,
                color: AppColors.sunsetDark.withValues(alpha: 0.2)),
          ),
        ],
      ),
    );
  }
}

// ─── Table row ────────────────────────────────────────────────────────────────

class _TableRow extends StatelessWidget {
  final String label;
  final String target;
  final String actual;
  final String variance;
  final Color varColor;
  final bool isBold;

  const _TableRow({
    required this.label,
    required this.target,
    required this.actual,
    required this.variance,
    this.varColor = AppColors.textMuted,
    this.isBold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: isBold
                  ? AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w600)
                  : AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              target,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              actual,
              style: isBold
                  ? AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w600)
                  : AppTextStyles.mono12(color: AppColors.textPrimary),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              variance,
              style: AppTextStyles.mono14(
                  color: varColor, weight: FontWeight.w700),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Full Week loader — bridges data source to _FullWeekSection ──────────────

class _FullWeekLoader extends StatefulWidget {
  final double theoreticalBlendedWage;
  final String weekId;
  const _FullWeekLoader({
    required this.theoreticalBlendedWage,
    required this.weekId,
  });

  @override
  State<_FullWeekLoader> createState() => _FullWeekLoaderState();
}

class _FullWeekLoaderState extends State<_FullWeekLoader> {
  List<ShiftRecord>? _shifts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final source = context.read<ShiftDataSource>();
    final shifts = await source.getFullWeekShifts(widget.weekId);
    if (mounted) setState(() => _shifts = shifts);
  }

  @override
  Widget build(BuildContext context) {
    final shifts = _shifts;
    if (shifts == null) {
      return const SizedBox(height: 60);
    }
    return _FullWeekSection(
      theoreticalBlendedWage: widget.theoreticalBlendedWage,
      shifts: shifts,
    );
  }
}

// ─── Full Week — Collapsible Day Rows ─────────────────────────────────────────

class _FullWeekSection extends StatefulWidget {
  final double theoreticalBlendedWage;
  final List<ShiftRecord> shifts;
  const _FullWeekSection({
    required this.theoreticalBlendedWage,
    required this.shifts,
  });

  @override
  State<_FullWeekSection> createState() => _FullWeekSectionState();
}

class _FullWeekSectionState extends State<_FullWeekSection> {
  static const _readService = VarianceWeekProjectionReadService();
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    // 7.55q.4-review-fix: thread the CURRENT shared
    // [ActiveTargetProfile] into the read service so day-row
    // aggregates substitute current Benchmark theoretical % for
    // non-closed children (Rule 3). Closed children continue to
    // contribute their own locked `shift.theoreticalLaborPct`
    // (Rule 4 exception). Without this Provider read the
    // `currentTargetProfile` parameter the read service grew in
    // `7.55q.4` would never receive a value in production — only
    // the unit tests would exercise it. Honest fallback: when
    // the notifier isn't in scope (e.g. legacy widget tests),
    // the profile is null and the read service falls back to
    // per-shift values (backward-compatible).
    final currentTargetProfile =
        context.watch<ActiveTargetProfileNotifier?>()?.profile;
    final projection = _readService.build(
      widget.shifts,
      currentTargetProfile: currentTargetProfile,
    );
    final groups = projection.dayRows;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        children: [
          for (int i = 0; i < groups.length; i++) ...[
            _DayRow(
              row: groups[i],
              theoreticalBlendedWage: widget.theoreticalBlendedWage,
              isExpanded: _expanded.contains(groups[i].dayLabel),
              onTap: () => setState(() {
                final k = groups[i].dayLabel;
                _expanded.contains(k)
                    ? _expanded.remove(k)
                    : _expanded.add(k);
              }),
            ),
            if (i < groups.length - 1)
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(horizontal: 14),
                color: AppColors.borderSubtle,
              ),
          ],

          // ── Projected Total Row ──────────────────────────────────────
          Container(height: 2, color: AppColors.borderStrong),
          _ProjectedTotalRow(),
        ],
      ),
    );
  }
}

// ─── _DayGroup removed in 7.55k.4 — replaced by ProjectionDayRow read model ─

// ─── Daypart status chips (L✓ D→ LN→) ────────────────────────────────────────

class _DaypartChips extends StatelessWidget {
  final List<ProjectionDaypartRow> children;
  const _DaypartChips({required this.children});

  static String _abbr(String daypart) {
    switch (daypart) {
      case 'lunch':      return 'L';
      case 'dinner':     return 'D';
      case 'late_night': return 'LN';
      default:           return daypart[0].toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    // FittedBox prevents overflow inside the fixed-width day-label column
    // at any viewport width (test or production).
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Text(
              '${_abbr(children[i].daypart)}${children[i].status == RowStatus.closed ? '✓' : children[i].status == RowStatus.open ? '●' : '→'}',
              style: AppTextStyles.mono7(
                color: children[i].status == RowStatus.closed
                    ? AppColors.positive
                    : children[i].status == RowStatus.open
                        ? AppColors.sunsetDark
                        : AppColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Collapsed day row ────────────────────────────────────────────────────────

class _DayRow extends StatelessWidget {
  final ProjectionDayRow row;
  final double theoreticalBlendedWage;
  final bool isExpanded;
  final VoidCallback onTap;

  const _DayRow({
    required this.row,
    required this.theoreticalBlendedWage,
    required this.isExpanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final laborPct = row.laborPct;
    final varPts = row.variancePts;
    final isOver = varPts > 0;
    final varColor = isOver ? AppColors.negative : AppColors.positive;

    return Container(
      decoration: isExpanded
          ? BoxDecoration(
              border: Border.all(color: AppColors.sunset, width: 2),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Collapsed header row
          InkWell(
            onTap: onTap,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                // Day label + per-daypart status chips + mixed summary
                SizedBox(
                  width: 64,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row.dayLabel,
                          style: AppTextStyles.mono14(
                              color: row.allProjected
                                  ? AppColors.textMuted
                                  : (row.hasOpen || row.status == RowStatus.mixed)
                                      ? AppColors.sunsetDark
                                      : AppColors.textPrimary,
                              weight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      _DaypartChips(children: row.children),
                    ],
                  ),
                ),

                // Covers column removed from the collapsed header — the
                // bare total-covers number was un-labeled noise here.
                // Per-daypart covers are still shown in the expanded detail.
                const Spacer(),

                // Labor %
                Text(
                  '${laborPct.toStringAsFixed(1)}%',
                  style: AppTextStyles.mono12(color: varColor),
                ),
                const SizedBox(width: 8),

                // Variance pts
                SizedBox(
                  width: 60,
                  child: Text(
                    '${isOver ? '+' : '−'}${varPts.abs().toStringAsFixed(1)} pts',
                    style: AppTextStyles.mono10(color: varColor),
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 8),

                // Chevron
                AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.keyboard_arrow_down,
                      size: 20, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ),

        // Expanded daypart detail
        if (isExpanded)
          _DayExpanded(
            row: row,
            theoreticalBlendedWage: theoreticalBlendedWage,
          ),
      ],
      ),
    );
  }
}

// ─── Expanded day content ─────────────────────────────────────────────────────

class _DayExpanded extends StatelessWidget {
  final ProjectionDayRow row;
  final double theoreticalBlendedWage;
  const _DayExpanded(
      {required this.row, required this.theoreticalBlendedWage});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Column(
        children: [
          for (int i = 0; i < row.children.length; i++) ...[
            if (i > 0)
              Container(
                height: 6,
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: AppColors.borderSubtle, width: 1),
                    bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
                  ),
                  color: AppColors.shimmer,
                ),
              ),
            row.children[i].status == RowStatus.closed
                ? _ClosedShiftDetail(shift: row.children[i].shift)
                : _ProjectedShiftDetail(
                    shift: row.children[i].shift,
                    isOpen: row.children[i].status == RowStatus.open,
                  ),
          ],
        ],
      ),
    );
  }
}

// ─── Closed shift: full input/output table ────────────────────────────────────

class _ClosedShiftDetail extends StatelessWidget {
  final ShiftRecord shift;
  const _ClosedShiftDetail({required this.shift});

  @override
  Widget build(BuildContext context) {
    final s = shift;

    // All target comparisons use locked shift truth — not current globals
    final lockedPPA = s.lockedTargetPPA;
    final lockedCPLH = s.lockedTargetCPLH;
    final lockedSPLH = s.lockedTargetSPLH;
    final lockedFohWage = s.lockedTargetFohWage;
    final lockedBohWage = s.lockedTargetBohWage;
    final lockedFohPct = s.lockedTheoreticalFohLaborPct;
    final lockedBohPct = s.lockedTheoreticalBohLaborPct;

    final coversDelta = s.covers - s.forecastCovers;
    final ppaDelta = s.ppa - lockedPPA;
    final cplhDelta = s.cplh - lockedCPLH;
    final splhDelta = s.splh - lockedSPLH;

    // Actual-volume model hours from locked targets (Jim Taylor Ch. 10)
    final theoFoh = s.modelFohHours;
    final theoBoh = s.modelBohHours;

    // Blended-wage target from locked shift truth
    final totalModelHours = theoFoh + theoBoh;
    final lockedBlendedWage = totalModelHours > 0
        ? (theoFoh * lockedFohWage + theoBoh * lockedBohWage) / totalModelHours
        : 0.0;
    final wageDelta = s.blendedWage - lockedBlendedWage;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Daypart label
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.backgroundSurface,
              border: Border.all(
                  color: AppColors.borderSubtle, width: 1),
            ),
            child: Text(
              '${s.dayLabel.toUpperCase()} ${s.daypartLabel.toUpperCase()}  ·  '
              '${s.covers} covers  ·  CLOSED',
              style: AppTextStyles.mono10(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: 10),

          // Table header
          _ShiftRow.header(),
          Container(height: 1, color: AppColors.borderSubtle),

          // ── Input group ──────────────────────────────────────────────
          _ShiftRow(
            label: 'Covers',
            target: s.forecastCovers.toString(),
            actual: s.covers.toString(),
            variance: Fmt.varStr(coversDelta),
            varColor: Fmt.varColor('Covers', coversDelta.toDouble()),
          ),
          _micro(),
          _ShiftRow(
            label: 'PPA',
            target: '\$${lockedPPA.toStringAsFixed(2)}',
            actual: '\$${s.ppa.toStringAsFixed(2)}',
            variance: Fmt.varDollars(ppaDelta),
            varColor: Fmt.varColor('PPA', ppaDelta),
          ),
          _micro(),
          _ShiftRow(
            label: 'CPLH',
            target: lockedCPLH.toStringAsFixed(2),
            actual: s.cplh.toStringAsFixed(2),
            variance: Fmt.varDelta(cplhDelta),
            varColor: Fmt.varColor('CPLH', cplhDelta),
          ),
          _micro(),
          _ShiftRow(
            label: 'SPLH',
            target: '\$${lockedSPLH.toStringAsFixed(0)}',
            actual: '\$${s.splh.toStringAsFixed(0)}',
            variance: Fmt.varDollars(splhDelta),
            varColor: Fmt.varColor('SPLH', splhDelta),
          ),
          _micro(),
          _ShiftRow(
            label: 'Blended Wage',
            target: '\$${lockedBlendedWage.toStringAsFixed(2)}',
            actual: '\$${s.blendedWage.toStringAsFixed(2)}',
            variance: Fmt.varDollars(wageDelta),
            varColor: Fmt.varColor('Blended Wage', wageDelta),
          ),

          // ── Input/Output divider ─────────────────────────────────────
          Container(
              height: 1,
              color: AppColors.borderStrong,
              margin: const EdgeInsets.symmetric(vertical: 6)),

          // ── Output group ─────────────────────────────────────────────
          _ShiftRow(
            label: 'FOH Hours',
            target: theoFoh.toString(),
            actual: s.fohHours.toString(),
            variance: Fmt.varStr(s.fohHours - theoFoh),
            varColor: Fmt.varColor(
                'FOH Hours', (s.fohHours - theoFoh).toDouble()),
          ),
          _micro(),
          _ShiftRow(
            label: 'BOH Hours',
            target: theoBoh.toString(),
            actual: s.bohHours.toString(),
            variance: Fmt.varStr(s.bohHours - theoBoh),
            varColor: Fmt.varColor(
                'BOH Hours', (s.bohHours - theoBoh).toDouble()),
          ),
          _micro(),
          _ShiftRow(
            label: 'FOH Labor %',
            target: '${lockedFohPct.toStringAsFixed(1)}%',
            actual: '${s.fohLaborPct.toStringAsFixed(1)}%',
            variance: Fmt.varPts(s.fohLaborPct - lockedFohPct),
            varColor: Fmt.varColor('FOH Labor %',
                s.fohLaborPct - lockedFohPct),
          ),
          _micro(),
          _ShiftRow(
            label: 'BOH Labor %',
            target: '${lockedBohPct.toStringAsFixed(1)}%',
            actual: '${s.bohLaborPct.toStringAsFixed(1)}%',
            variance: Fmt.varPts(s.bohLaborPct - lockedBohPct),
            varColor: Fmt.varColor('BOH Labor %',
                s.bohLaborPct - lockedBohPct),
          ),
          _micro(),
          _ShiftRow(
            label: 'Total Labor %',
            target: '${s.theoreticalLaborPct.toStringAsFixed(1)}%',
            actual: '${s.totalLaborPct.toStringAsFixed(1)}%',
            variance: Fmt.varPts(s.variancePts),
            varColor: Fmt.varColor('Total Labor %', s.variancePts),
            isBold: true,
          ),

          // ── Primary lever badge ───────────────────────────────────────
          const SizedBox(height: 10),
          _LeverBadge(lever: s.primaryLever),
        ],
      ),
    );
  }

  Widget _micro() => Container(
      height: 1,
      color: AppColors.borderSubtle.withValues(alpha: 0.5));
}

// ─── Projected shift: trajectory only ────────────────────────────────────────

class _ProjectedShiftDetail extends StatelessWidget {
  final ShiftRecord shift;
  final bool isOpen;
  const _ProjectedShiftDetail({required this.shift, this.isOpen = false});

  @override
  Widget build(BuildContext context) {
    final statusLabel = isOpen ? 'OPEN' : 'PROJ';
    final headerLabel = isOpen ? 'PLAN CONTEXT' : 'PROJECTED';
    final statusColor = isOpen ? AppColors.sunsetDark : AppColors.textMuted;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.backgroundSurface,
              border:
                  Border.all(color: isOpen ? AppColors.sunsetDark : AppColors.borderSubtle, width: 1),
            ),
            child: Text(
              '${shift.dayLabel.toUpperCase()} ${shift.daypartLabel.toUpperCase()}  ·  '
              '${isOpen ? shift.covers : shift.forecastCovers} covers  ·  $statusLabel',
              style: AppTextStyles.mono10(color: statusColor),
            ),
          ),
          const SizedBox(height: 10),

          // Header
          Row(children: [
            Expanded(
              flex: 4,
              child: Text('METRIC',
                  style: AppTextStyles.mono8(color: AppColors.textMuted)),
            ),
            Expanded(
              flex: 6,
              child: Text(headerLabel,
                  style: AppTextStyles.mono8(color: statusColor),
                  textAlign: TextAlign.right),
            ),
          ]),
          Container(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: 7),

          // Covers row
          Row(children: [
            Expanded(
              flex: 4,
              child: Text('Covers',
                  style: AppTextStyles.body13(
                      color: AppColors.textSecondary)),
            ),
            Expanded(
              flex: 6,
              child: Text(
                '${shift.forecastCovers}  (plan)',
                style: AppTextStyles.mono12(
                    color: AppColors.sunsetDark),
                textAlign: TextAlign.right,
              ),
            ),
          ]),
          const SizedBox(height: 7),

          // FOH Hours row
          Row(children: [
            Expanded(
              flex: 4,
              child: Text('FOH Hours',
                  style: AppTextStyles.body13(
                      color: AppColors.textSecondary)),
            ),
            Expanded(
              flex: 6,
              child: Text(
                '${shift.fohHours}  (plan)',
                style: AppTextStyles.mono12(
                    color: AppColors.sunsetDark),
                textAlign: TextAlign.right,
              ),
            ),
          ]),
          const SizedBox(height: 7),

          // BOH Hours row
          Row(children: [
            Expanded(
              flex: 4,
              child: Text('BOH Hours',
                  style: AppTextStyles.body13(
                      color: AppColors.textSecondary)),
            ),
            Expanded(
              flex: 6,
              child: Text(
                '${shift.bohHours}  (plan)',
                style: AppTextStyles.mono12(
                    color: AppColors.sunsetDark),
                textAlign: TextAlign.right,
              ),
            ),
          ]),
          const SizedBox(height: 7),

          // Blended Wage row — 7.55q.4: Benchmark-owned, read from
          // current ActiveTargetProfile via the 7.55q.3 shared seam.
          // Honest fallback to per-shift fields when the profile
          // notifier isn't in scope (e.g. legacy widget tests).
          Builder(builder: (ctx) {
            final profile =
                ctx.watch<ActiveTargetProfileNotifier?>()?.profile;
            final wage = profile?.targetBlendedWage ??
                shift.snapshotBlendedWage ??
                shift.blendedWage;
            return Row(children: [
              Expanded(
                flex: 4,
                child: Text('Blended Wage',
                    style: AppTextStyles.body13(
                        color: AppColors.textSecondary)),
              ),
              Expanded(
                flex: 6,
                child: Text(
                  '\$${wage.toStringAsFixed(2)}  (plan)',
                  style: AppTextStyles.mono12(
                      color: AppColors.sunsetDark),
                  textAlign: TextAlign.right,
                ),
              ),
            ]);
          }),
          const SizedBox(height: 7),

          // Labor % row — 7.55q.4: Benchmark-owned theoretical %,
          // read from current ActiveTargetProfile (Rule 3). Honest
          // fallback to the shift's locked-at-write value when the
          // profile notifier isn't in scope.
          Builder(builder: (ctx) {
            final profile =
                ctx.watch<ActiveTargetProfileNotifier?>()?.profile;
            final theoPct = profile?.theoreticalLaborPct ??
                shift.theoreticalLaborPct;
            return Row(children: [
              Expanded(
                flex: 4,
                child: Text('Labor %',
                    style: AppTextStyles.body13(
                        color: AppColors.textSecondary)),
              ),
              Expanded(
                flex: 6,
                child: Text(
                  '${theoPct.toStringAsFixed(1)}%  (theoretical)',
                  style: AppTextStyles.mono12(
                      color: AppColors.sunsetDark),
                  textAlign: TextAlign.right,
                ),
              ),
            ]);
          }),

          const SizedBox(height: 12),

          // Week-end projection line
          Builder(builder: (ctx) {
            final wd = ctx.read<WeekDataNotifier>().weekData!;
            final projColor = wd.projVariancePts > 0
                ? AppColors.negative
                : AppColors.positive;
            return RichText(
              text: TextSpan(
                style: AppTextStyles.mono10(color: AppColors.textMuted),
                children: [
                  const TextSpan(text: 'Week ends at '),
                  TextSpan(
                    text: '${wd.projActualLaborPct.toStringAsFixed(1)}%',
                    style: AppTextStyles.mono10(color: projColor),
                  ),
                  const TextSpan(text: '  →  gap '),
                  TextSpan(
                    text:
                        '\$${wd.projDollarGapWeekly.abs().toStringAsFixed(0)}',
                    style: AppTextStyles.mono10(color: projColor),
                  ),
                ],
              ),
            );
          }),

          const SizedBox(height: 4),
          Text(
            isOpen
                ? 'Live shift in progress. Finalizes on close.'
                : 'Projected from weekly plan. Actuals populate when shift closes.',
            style: AppTextStyles.mono8(color: isOpen ? AppColors.sunsetDark : AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

// ─── Shift table row (used in expanded closed-shift detail) ───────────────────

class _ShiftRow extends StatelessWidget {
  final String label;
  final String target;
  final String actual;
  final String variance;
  final Color varColor;
  final bool isHeader;
  final bool isBold;

  const _ShiftRow({
    required this.label,
    required this.target,
    required this.actual,
    required this.variance,
    this.varColor = AppColors.textMuted,
    this.isHeader = false,
    this.isBold = false,
  });

  const _ShiftRow.header()
      : this(
          label: 'METRIC',
          target: 'TARGET',
          actual: 'ACTUAL',
          variance: 'VAR',
          isHeader: true,
        );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: isHeader
                  ? AppTextStyles.mono8(color: AppColors.textMuted)
                  : (isBold
                      ? AppTextStyles.mono12(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w700)
                      : AppTextStyles.body13(
                          color: AppColors.textSecondary)),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              target,
              style: isHeader
                  ? AppTextStyles.mono8(color: AppColors.textMuted)
                  : AppTextStyles.mono8(color: AppColors.textMuted),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              actual,
              style: isHeader
                  ? AppTextStyles.mono8(color: AppColors.textMuted)
                  : AppTextStyles.mono11(color: AppColors.textPrimary),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              variance,
              style: isHeader
                  ? AppTextStyles.mono8(color: AppColors.textMuted)
                  : AppTextStyles.mono12(
                      color: varColor, weight: FontWeight.w700),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Lever badge (inside expanded closed shift) ───────────────────────────────

class _LeverBadge extends StatelessWidget {
  final String lever;
  const _LeverBadge({required this.lever});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.6), width: 1),
      ),
      child: Text(
        'PRIMARY LEVER: ${lever.replaceAll('_', ' ')}',
        style: AppTextStyles.mono8(color: AppColors.warning),
      ),
    );
  }
}

// ─── Projected Total Row ──────────────────────────────────────────────────────

class _ProjectedTotalRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final wd = context.read<WeekDataNotifier>().weekData!;
    final isOver = wd.projVariancePts > 0;
    final ptColor = isOver ? AppColors.negative : AppColors.positive;
    final ptSign = isOver ? '+' : '−';

    return Container(
      color: AppColors.backgroundSurface,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              'PROJ TOTAL',
              style: AppTextStyles.mono14(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w700),
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'TARGET',
                  style:
                      AppTextStyles.mono8(color: AppColors.textMuted),
                ),
                const SizedBox(height: 4),
                Text(
                  '${wd.projTargetLaborPct.toStringAsFixed(1)}%',
                  style: AppTextStyles.mono12(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'PROJ',
                  style:
                      AppTextStyles.mono8(color: AppColors.textMuted),
                ),
                const SizedBox(height: 4),
                Text(
                  '${wd.projActualLaborPct.toStringAsFixed(1)}%',
                  style: AppTextStyles.mono12(color: ptColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: Text(
              '$ptSign${wd.projVariancePts.abs().toStringAsFixed(1)} pts',
              style: AppTextStyles.mono14(
                  color: ptColor, weight: FontWeight.w700),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Teaching Summary Card (History tab) ──────────────────────────────────────

class _HistorySectionLabel extends StatelessWidget {
  final String text;
  const _HistorySectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 32, bottom: 10),
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

class _TeachingSummaryCard extends StatelessWidget {
  final HistoryTeachingSummary summary;
  final LeverCardData leakCard;
  final int weekCount;
  final List<HistoryBenchmarkDaypartSummary> benchmarkDayparts;

  const _TeachingSummaryCard({
    required this.summary,
    required this.leakCard,
    required this.weekCount,
    required this.benchmarkDayparts,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // MOST COMMON LEAK
          _TeachRow(
            title: 'MOST COMMON LEAK',
            value: leakCard.shortLabel,
            subtitle:
                '${summary.mostCommonLeakCount} dayparts in the last $weekCount weeks',
            valueColor: AppColors.negative,
          ),
          Container(height: 1, color: AppColors.borderSubtle),

          // BENCHMARK DAYPARTS — evidence-backed with visibility policy (7.55k.7)
          ..._buildBenchmarkDaypartRows(benchmarkDayparts),
        ],
      ),
    );
  }
}

/// Builds the benchmark daypart rows with visibility policy (7.55k.7).
/// Strong evidence renders as benchmark truth; thin evidence renders as
/// early signal; empty renders as a dash.
List<Widget> _buildBenchmarkDaypartRows(
    List<HistoryBenchmarkDaypartSummary> benchmarkDayparts) {
  if (benchmarkDayparts.isEmpty) {
    return [
      const _TeachRow(
        title: 'BENCHMARK DAYPARTS',
        value: '\u2014',
        valueColor: AppColors.positive,
        isLast: true,
      ),
    ];
  }

  final strong = <HistoryBenchmarkDaypartSummary>[];
  final earlySignal = <HistoryBenchmarkDaypartSummary>[];
  for (final b in benchmarkDayparts) {
    final tier = DaypartEvidenceVisibilityPolicy.classifyBenchmark(
      benchmarkCount: b.benchmarkCount,
      closedShiftCount: b.closedShiftCount,
    );
    if (tier == EvidenceTier.strong) {
      strong.add(b);
    } else if (tier == EvidenceTier.earlySignal) {
      earlySignal.add(b);
    }
  }

  return [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (strong.isNotEmpty) ...[
            Text('BENCHMARK DAYPARTS',
                style: AppTextStyles.mono10(color: AppColors.textMuted)),
            const SizedBox(height: 8),
            for (final b in strong) ...[
              Text(
                '${b.label} \u00b7 ${b.benchmarkCount}/${b.closedShiftCount} wins \u00b7 '
                '${b.avgCPLH.toStringAsFixed(2)} CPLH \u00b7 '
                '\$${b.avgSPLH.toStringAsFixed(0)} SPLH',
                style: AppTextStyles.mono12(color: AppColors.positive),
              ),
              const SizedBox(height: 4),
            ],
          ],
          if (earlySignal.isNotEmpty) ...[
            if (strong.isNotEmpty) const SizedBox(height: 8),
            Text('EARLY SIGNALS',
                style: AppTextStyles.mono10(color: AppColors.textMuted)),
            const SizedBox(height: 8),
            for (final b in earlySignal) ...[
              Text(
                '${b.label} \u00b7 ${b.benchmarkCount}/${b.closedShiftCount} wins \u00b7 '
                '${b.avgCPLH.toStringAsFixed(2)} CPLH \u00b7 '
                '\$${b.avgSPLH.toStringAsFixed(0)} SPLH',
                style: AppTextStyles.mono12(color: AppColors.warning),
              ),
              const SizedBox(height: 4),
            ],
          ],
          if (strong.isEmpty && earlySignal.isEmpty) ...[
            Text('BENCHMARK DAYPARTS',
                style: AppTextStyles.mono10(color: AppColors.textMuted)),
            const SizedBox(height: 8),
            Text('\u2014',
                style: AppTextStyles.mono14(color: AppColors.positive)),
          ],
        ],
      ),
    ),
  ];
}

class _TeachRow extends StatelessWidget {
  final String title;
  final String value;
  final String? subtitle;
  final Color? valueColor;
  final bool isLast;

  const _TeachRow({
    required this.title,
    required this.value,
    this.subtitle,
    this.valueColor,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 13, 16, isLast ? 16 : 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              title,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: AppTextStyles.mono14(
                      color: valueColor ?? AppColors.textPrimary),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── History tab ──────────────────────────────────────────────────────────────

/// Holds data sets loaded for the History tab.
class _HistoryData {
  final List<WeekRecord> weeks;
  final List<HistoryPatternRecord> patternRecords;
  final List<ShiftRecord> historicalClosedShifts;
  const _HistoryData({
    required this.weeks,
    required this.patternRecords,
    required this.historicalClosedShifts,
  });
}

class _HistoryTab extends StatefulWidget {
  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab>
    with AutomaticKeepAliveClientMixin {
  late Future<_HistoryData> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final source = context.read<ShiftDataSource>();
    _future = Future.wait([
      source.getWeekHistory(),
      source.getHistoryPatternRecords(),
      source.getHistoricalClosedShifts(),
    ]).then((results) => _HistoryData(
          weeks: results[0] as List<WeekRecord>,
          patternRecords: results[1] as List<HistoryPatternRecord>,
          historicalClosedShifts: results[2] as List<ShiftRecord>,
        ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<_HistoryData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.sunset),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Error loading history.',
                style: AppTextStyles.body13(color: AppColors.textMuted)),
          );
        }
        final data = snapshot.data ??
            const _HistoryData(
                weeks: [], patternRecords: [], historicalClosedShifts: []);
        final weeks = data.weeks;
        final patternRecords = data.patternRecords;

        // Teaching summary — only shown when pattern records exist.
        HistoryTeachingSummary? teachingSummary;
        LeverCardData? leakCard;
        if (patternRecords.isNotEmpty) {
          teachingSummary =
              HistoryTeachingAnalyzer.summarize(patternRecords);
          leakCard = LeverCards.all.firstWhere(
            (l) => l.id == teachingSummary!.mostCommonLeakId,
            orElse: () => LeverCards.coversDown,
          );
        }

        // Benchmark daypart evidence (7.55k.5).
        const benchmarkService = HistoryBenchmarkDaypartReadService();
        final benchmarkDayparts =
            benchmarkService.build(data.historicalClosedShifts);

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Previous Weeks',
                        style: AppTextStyles.display28()),
                    const SizedBox(height: 4),
                    Text('Last ${weeks.length} weeks · Newest first',
                        style: AppTextStyles.body13(
                            color: AppColors.textMuted)),
                  ],
                ),
              ),
            ),

            // ── Teaching summary — only when pattern records are present ──
            if (teachingSummary != null && leakCard != null) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _HistorySectionLabel('WHAT HISTORY IS TEACHING'),
                ),
              ),
              SliverToBoxAdapter(
                child: _TeachingSummaryCard(
                  summary: teachingSummary,
                  leakCard: leakCard,
                  weekCount: weeks.length,
                  benchmarkDayparts: benchmarkDayparts,
                ),
              ),
            ],

            if (weeks.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Text('No history yet.',
                      style: AppTextStyles.body13(
                          color: AppColors.textMuted)),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => WeekHistoryTile(
                    week: weeks[i],
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              WeekDetailScreen(week: weeks[i])),
                    ),
                  ),
                  childCount: weeks.length,
                ),
              ),
          ],
        );
      },
    );
  }
}

// ─── Learn tab ───────────────────────────────────────────────────────────────

class _LearnTab extends StatefulWidget {
  @override
  State<_LearnTab> createState() => _LearnTabState();
}

class _LearnTabState extends State<_LearnTab>
    with AutomaticKeepAliveClientMixin {
  late Future<_LearnData> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final source = context.read<ShiftDataSource>();
    _future = Future.wait([
      source.getWeekHistory(),
      source.getHistoryPatternRecords(),
      LearnBenchmarkContextService.instance.resolve(),
      source.getHistoricalClosedShifts(),
    ]).then((results) {
      final weeks = results[0] as List<WeekRecord>;
      final patternRecords = results[1] as List<HistoryPatternRecord>;
      final benchmarkContext = results[2] as LearnBenchmarkContext;
      final closedShifts = results[3] as List<ShiftRecord>;
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: patternRecords,
        weekCount: weeks.length,
        benchmarkContext: benchmarkContext,
      );
      const winsService = LearnRepeatableWinsReadService();
      final allWins = winsService.build(closedShifts);
      // Apply visibility policy: only truly repeated wins pass (7.55k.7).
      final repeatableWins = allWins
          .where((w) =>
              DaypartEvidenceVisibilityPolicy.classifyRepeatableWin(
                  benchmarkCount: w.benchmarkCount) ==
              EvidenceTier.strong)
          .toList();
      return _LearnData(summary: summary, repeatableWins: repeatableWins);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<_LearnData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.sunset),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Error loading Learn data.',
                style: AppTextStyles.body13(color: AppColors.textMuted)),
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return Center(
            child: Text('No data.',
                style: AppTextStyles.body13(color: AppColors.textMuted)),
          );
        }
        return _LearnContent(
          summary: data.summary,
          repeatableWins: data.repeatableWins,
        );
      },
    );
  }
}

class _LearnData {
  final LearnTeachingSummary summary;
  final List<LearnRepeatableWinSummary> repeatableWins;
  const _LearnData({required this.summary, required this.repeatableWins});
}

class _LearnContent extends StatelessWidget {
  final LearnTeachingSummary summary;
  final List<LearnRepeatableWinSummary> repeatableWins;
  const _LearnContent({required this.summary, required this.repeatableWins});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────
          Text('Learn', style: AppTextStyles.display28()),
          const SizedBox(height: 4),
          Text(
            summary.weekCount > 0
                ? 'Last ${summary.weekCount} tracked weeks'
                : 'No tracked weeks yet',
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),

          // ── Benchmark Set ───────────────────────────────────────────
          _LearnSectionLabel(label: 'BENCHMARK SET'),
          _BenchmarkSetCard(summary: summary),

          // ── Recurring Leak ──────────────────────────────────────────
          _LearnSectionLabel(label: 'RECURRING LEAK'),
          _RecurringLeakCard(summary: summary),

          // ── Repeatable Wins ─────────────────────────────────────────
          _LearnSectionLabel(label: 'REPEATABLE WINS'),
          _RepeatableWinsCard(
            summary: summary,
            repeatableWins: repeatableWins,
          ),

          // ── Coach Next Week ─────────────────────────────────────────
          _LearnSectionLabel(label: 'COACH NEXT WEEK'),
          _CoachNextWeekCard(summary: summary),
        ],
      ),
    );
  }
}

// ── Learn section label ──────────────────────────────────────────────────────

class _LearnSectionLabel extends StatelessWidget {
  final String label;
  const _LearnSectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 10),
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
              Text(label,
                  style: AppTextStyles.mono14(color: AppColors.textPrimary, weight: FontWeight.w700)),
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
}

// ── Benchmark Set card ───────────────────────────────────────────────────────

class _BenchmarkSetCard extends StatelessWidget {
  final LearnTeachingSummary summary;
  const _BenchmarkSetCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LearnMetricRow(
                label: 'SOURCE', value: summary.benchmarkSourceLabel),
                const SizedBox(height: 10),
                _LearnMetricRow(
                    label: 'STAR SHIFTS',
                    value: summary.selectedShiftCount.toString()),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _LearnMetricRow(
                          label: 'TARGET CPLH',
                          value: summary.targetCPLH.toStringAsFixed(1)),
                    ),
                    Expanded(
                      child: _LearnMetricRow(
                          label: 'TARGET SPLH',
                          value: summary.targetSPLH.toStringAsFixed(0)),
                    ),
                    Expanded(
                      child: _LearnMetricRow(
                          label: 'TARGET PPA',
                          value: summary.targetPPA.toStringAsFixed(0)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(height: 1, color: AppColors.borderSubtle),
                const SizedBox(height: 14),
                _LearnChip(
                  label: summary.rangeQualityLabel,
                  color: summary.rangeQualityLabel == 'GOOD OPZ RANGE'
                      ? AppColors.positive
                      : AppColors.warning,
                ),
                const SizedBox(height: 4),
                Text('RANGE QUALITY',
                    style: AppTextStyles.mono7(color: AppColors.textMuted)),
                const SizedBox(height: 8),
                Text(summary.rangeQualityMessage,
                    style:
                        AppTextStyles.body13(color: AppColors.textSecondary)),
              ],
            ),
          ),
    );
  }
}

// ── Recurring Leak card ──────────────────────────────────────────────────────

class _RecurringLeakCard extends StatelessWidget {
  final LearnTeachingSummary summary;
  const _RecurringLeakCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    if (!summary.hasHistoryPatterns) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.backgroundMid, AppColors.cardGlow],
          ),
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(summary.primaryFixLine,
            style: AppTextStyles.body13(color: AppColors.textMuted)),
      );
    }

    // Resolve the lever card for teaching content
    final leakCard = LeverCards.all.firstWhere(
      (l) => l.id == summary.primaryLeakId,
      orElse: () => LeverCards.coversDown,
    );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top accent bar with leak identity
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(
                left: BorderSide(color: AppColors.borderSubtle, width: 4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _LearnChip(
                      label: leakCard.shortLabel,
                      color: AppColors.negative,
                    ),
                    const SizedBox(width: 8),
                    _LearnChip(
                      label: leakCard.causeCategory,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    _LearnChip(
                      label: leakCard.sideLabel,
                      color: AppColors.textMuted,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(leakCard.metric,
                    style: AppTextStyles.mono14(
                        color: AppColors.textPrimary)),
              ],
            ),
          ),

          // Frequency and daypart info
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: _LearnMetricRow(
                    label: 'LEAK REPEATS',
                    value: summary.primaryLeakCount.toString(),
                    valueColor: AppColors.negative,
                  ),
                ),
                Expanded(
                  child: _LearnMetricRow(
                    label: 'REPEATS IN',
                    value: summary.topLeakDayparts.isEmpty
                        ? '\u2014'
                        : summary.topLeakDayparts.join(' / '),
                  ),
                ),
              ],
            ),
          ),

          // Teaching content from lever card
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Container(height: 1, color: AppColors.borderSubtle),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text('WHAT HAPPENED',
                style: AppTextStyles.mono8(color: AppColors.sunsetDark)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(leakCard.whatHappened,
                style: AppTextStyles.body13(color: AppColors.textSecondary)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Container(height: 1, color: AppColors.borderSubtle),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text('WHAT TO DO',
                style: AppTextStyles.mono8(color: AppColors.sunsetDark)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(leakCard.whatToDo,
                style: AppTextStyles.body13(color: AppColors.textSecondary)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Container(height: 1, color: AppColors.borderSubtle),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text('WHAT TO STUDY',
                style: AppTextStyles.mono8(color: AppColors.sunsetDark)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(leakCard.teachingNote,
                style: AppTextStyles.body13(color: AppColors.textSecondary)),
          ),
        ],
      ),
    );
  }
}

// ── Repeatable Wins card ─────────────────────────────────────────────────────

class _RepeatableWinsCard extends StatelessWidget {
  final LearnTeachingSummary summary;
  final List<LearnRepeatableWinSummary> repeatableWins;
  const _RepeatableWinsCard({
    required this.summary,
    required this.repeatableWins,
  });

  @override
  Widget build(BuildContext context) {
    // No evidence at all — intentional empty state (7.55k.7a).
    // Does not fall back to legacy frequency-only benchmark-daypart labels.
    if (repeatableWins.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.backgroundMid, AppColors.cardGlow],
          ),
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('No repeatable wins yet',
                style: AppTextStyles.mono14(color: AppColors.textMuted)),
            const SizedBox(height: 14),
            Container(height: 1, color: AppColors.borderSubtle),
            const SizedBox(height: 14),
            Text(summary.studyLine,
                style: AppTextStyles.body13(color: AppColors.textSecondary)),
          ],
        ),
      );
    }

    // Use the dominant lever from the top-ranked win for teaching copy.
    final topWin = repeatableWins.first;
    final benchmarkCard = LeverCards.all.firstWhere(
      (l) => l.id == topWin.dominantLeverId,
      orElse: () => LeverCards.ppaUp,
    );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top accent bar with dominant lever identity
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(
                left: BorderSide(color: AppColors.borderSubtle, width: 4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _LearnChip(
                      label: benchmarkCard.shortLabel,
                      color: AppColors.positive,
                    ),
                    const SizedBox(width: 8),
                    _LearnChip(
                      label: benchmarkCard.causeCategory,
                      color: AppColors.sunsetDark,
                    ),
                    const SizedBox(width: 8),
                    _LearnChip(
                      label: benchmarkCard.sideLabel,
                      color: AppColors.sunsetDark,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(benchmarkCard.metric,
                    style: AppTextStyles.mono14(
                        color: AppColors.textPrimary)),
              ],
            ),
          ),

          // Evidence-backed win rows with per-row lever identity (7.55k.6a)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('WIN REPEATS',
                    style: AppTextStyles.mono10(color: AppColors.textMuted)),
                const SizedBox(height: 8),
                for (final w in repeatableWins) ...[
                  Row(
                    children: [
                      _LearnChip(
                        label: _leverShortLabel(w.dominantLeverId),
                        color: AppColors.positive,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${w.label} \u00b7 ${w.benchmarkCount}/${w.closedShiftCount} wins \u00b7 '
                          '${w.avgCPLH.toStringAsFixed(2)} CPLH \u00b7 '
                          '\$${w.avgSPLH.toStringAsFixed(0)} SPLH',
                          style: AppTextStyles.mono12(color: AppColors.positive),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
              ],
            ),
          ),

          // Context chips
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                _LearnChip(
                  label: summary.benchmarkSourceLabel,
                  color: AppColors.sunsetDark,
                ),
                const SizedBox(width: 8),
                _LearnChip(
                  label: summary.rangeQualityLabel,
                  color: summary.rangeQualityLabel == 'GOOD OPZ RANGE'
                      ? AppColors.positive
                      : AppColors.warning,
                ),
              ],
            ),
          ),

          // Teaching content scoped to top-ranked win (7.55k.6a)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Container(height: 1, color: AppColors.borderSubtle),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('COACHING \u2014 ${topWin.label}',
                style: AppTextStyles.mono8(color: AppColors.sunsetDark)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('WHAT HELD',
                style: AppTextStyles.mono8(color: AppColors.sunsetDark)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(benchmarkCard.whatHappened,
                style: AppTextStyles.body13(color: AppColors.textSecondary)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Container(height: 1, color: AppColors.borderSubtle),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text('WHAT TO PROTECT',
                style: AppTextStyles.mono8(color: AppColors.sunsetDark)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(benchmarkCard.whatToDo,
                style: AppTextStyles.body13(color: AppColors.textSecondary)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Container(height: 1, color: AppColors.borderSubtle),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text('WHAT TO STUDY',
                style: AppTextStyles.mono8(color: AppColors.sunsetDark)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(benchmarkCard.teachingNote,
                style: AppTextStyles.body13(color: AppColors.textSecondary)),
          ),
        ],
      ),
    );
  }
}

/// Resolves a lever ID to its compact short label for per-row identity chips.
String _leverShortLabel(String leverId) {
  final card = LeverCards.all.firstWhere(
    (l) => l.id == leverId,
    orElse: () => LeverCards.ppaUp,
  );
  return card.shortLabel;
}

// ── Coach Next Week card ─────────────────────────────────────────────────────

class _CoachNextWeekCard extends StatelessWidget {
  final LearnTeachingSummary summary;
  const _CoachNextWeekCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.shimmer, AppColors.cardGlow],
        ),
        border: Border.all(
            color: AppColors.borderStrong.withValues(alpha: 0.5), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CoachLine(
                  icon: Icons.priority_high_rounded,
                  color: AppColors.negative,
                  text: summary.primaryFixLine,
                ),
                const SizedBox(height: 14),
                _CoachLine(
                  icon: Icons.search_rounded,
                  color: AppColors.sunset,
                  text: summary.studyLine,
                ),
                const SizedBox(height: 14),
                _CoachLine(
                  icon: Icons.trending_up_rounded,
                  color: AppColors.positive,
                  text: summary.coachToLine,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CoachLine extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _CoachLine(
      {required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: AppTextStyles.mono12(color: AppColors.textPrimary)),
        ),
      ],
    );
  }
}

// ── Shared Learn components ──────────────────────────────────────────────────

class _LearnMetricRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _LearnMetricRow(
      {required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppTextStyles.mono7(color: AppColors.textMuted)),
        const SizedBox(height: 3),
        Text(value,
            style: AppTextStyles.mono12(
                color: valueColor ?? AppColors.textPrimary)),
      ],
    );
  }
}

class _LearnChip extends StatelessWidget {
  final String label;
  final Color color;
  const _LearnChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(label, style: AppTextStyles.mono8(color: color)),
    );
  }
}
