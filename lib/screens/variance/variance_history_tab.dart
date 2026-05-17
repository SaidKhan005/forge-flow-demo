// Phase 7.55o.2 / Variance V2 Lane R-HIST — Variance "History" tab.
//
// Owns the History tab, its data loader, the CPLH-vs-OPZ band card,
// the "Most common leak" card, and the previous-weeks list. Section
// order and labels mirror the approved mockup
// `docs/f&f Coaching/variance_tab_v2_mockup.html` `#hist`:
//   band -> Most common leak -> Previous weeks
//
// Variance V2 round-2 corrective: the benchmark-daypart list that used
// to sit under "Most common leak" is removed (operator decision: match
// the HTML exactly — no benchmark-daypart list there). The leak card is
// now a single styled card with a serif headline (the resolved leak
// driver) and a richer teaching body whose repeat-count span is
// emphasised via the V2-4 `[[bad:…]]` markup applied AT RENDER (never
// stored in the lever catalog).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/constants/app_defaults.dart';
import '../../state/active_target_profile_notifier.dart';
import '../../services/baseline_authority_service.dart' show BaselineData;
import '../../services/shift_data_source.dart';
import '../../models/history_pattern_record.dart';
import '../../models/shift_record.dart';
import '../../models/week_record.dart';
import '../../services/history_teaching_analyzer.dart';
import '../../services/variance_driver_pattern_read_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/sticky_section_delegate.dart';
import '../../widgets/variance/cplh_opz_band_card.dart';
import '../../widgets/variance/inline_emphasis_text.dart';
import '../../widgets/week_history_tile.dart';
import '../week_detail_screen.dart';

/// Variance V2 Lane R-HIST — the History "Most common leak" card.
///
/// 1:1 with the approved mockup
/// `docs/f&f Coaching/variance_tab_v2_mockup.html` `#hist` "Most common
/// leak" section: a single styled card holding a serif headline (the
/// resolved leak driver) and a richer teaching body with one inline
/// `.em-bad` emphasis span. The mockup's literal copy ("CPLH below OPZ
/// on busy weeks", "8 of the last 24 dayparts") is presentation
/// reference only — the headline is the real resolved
/// `LeverCardData.metric` and the count is the real
/// `mostCommonLeakCount` over the closed-shift population the History
/// tab already loads. The earlier benchmark-daypart list under this
/// section is removed by operator decision (match the HTML exactly; no
/// benchmark-daypart list there).
///
/// V2-4 inline emphasis: the `[[bad:…]]` markup is applied at RENDER
/// here, never stored in the lever catalog. The body is routed through
/// [InlineEmphasisText] so the "N of M dayparts" span renders in the
/// loss (red, bold) sentiment exactly like the mockup's `.em-bad`. When
/// the closed-shift denominator is unavailable the body degrades to the
/// honest no-count sentence (Metric Honesty Doctrine): no fabricated
/// "N of M".
class _MostCommonLeakCard extends StatelessWidget {
  final LeverCardData leakCard;
  final int repeatCount;
  final int totalHistoricalDayparts;

  const _MostCommonLeakCard({
    required this.leakCard,
    required this.repeatCount,
    required this.totalHistoricalDayparts,
  });

  /// The teaching body, with the real repeat count wrapped in the V2-4
  /// `[[bad:…]]` token AT RENDER TIME. The numbers are the real
  /// `mostCommonLeakCount` over the real closed-shift population the
  /// History tab loaded — only the styling mirrors the mockup, never
  /// the mockup's literal "8 of 24". When there is no honest
  /// denominator the count clause is dropped rather than invented.
  String _bodyMarkup() {
    if (totalHistoricalDayparts > 0) {
      return 'It has been your top driver in '
          '[[bad:$repeatCount of the last $totalHistoricalDayparts dayparts]]. '
          'Once is a bad night. A pattern in the same place is a habit, '
          'and a habit is what Learn is for.';
    }
    // Honest degraded body: no closed-shift denominator to count
    // against, so the repeat clause is omitted entirely (Metric
    // Honesty Doctrine — no fabricated "N of M").
    return 'It has been your top driver. Once is a bad night. '
        'A pattern in the same place is a habit, and a habit is what '
        'Learn is for.';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
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
          // Mockup `#hist`: serif headline `h3`. The headline is the
          // real resolved leak driver copy (`LeverCardData.metric`),
          // not the mockup's literal string.
          Text(
            leakCard.metric,
            style: AppTextStyles.display16(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          // Mockup `#hist`: `.tp` teaching paragraph with one `.em-bad`
          // span. Routed through InlineEmphasisText so the `[[bad:…]]`
          // markup applied above renders in the loss sentiment.
          InlineEmphasisText(
            _bodyMarkup(),
            baseStyle: AppTextStyles.body14(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────── History tab ───────────────────────────────

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

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab>
    with AutomaticKeepAliveClientMixin {
  late Future<_HistoryData> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final source = context.read<ShiftDataSource>();
    _future =
        Future.wait([
          source.getWeekHistory(),
          source.getHistoryPatternRecords(),
          source.getHistoricalClosedShifts(),
        ]).then(
          (results) => _HistoryData(
            weeks: results[0] as List<WeekRecord>,
            patternRecords: results[1] as List<HistoryPatternRecord>,
            historicalClosedShifts: results[2] as List<ShiftRecord>,
          ),
        );
  }

  String? _historyRangeLabel(List<WeekRecord> weeks) {
    if (weeks.isEmpty) return null;
    final sorted = [...weeks]..sort((a, b) => b.weekId.compareTo(a.weekId));
    final newest = sorted.first;
    final oldest = sorted.last;
    final oldestStart = _weekStartFromWeekId(oldest.weekId);
    final newestEnd =
        _parseIsoDate(newest.closedAt) ??
        _weekStartFromWeekId(newest.weekId)?.add(const Duration(days: 6));
    if (oldestStart == null || newestEnd == null) return null;
    return '${_formatMonthDayFromDate(oldestStart)} - '
        '${_formatMonthDayFromDate(newestEnd)}';
  }

  DateTime? _weekStartFromWeekId(String weekId) {
    final parts = weekId.split('-W');
    if (parts.length != 2) return null;
    final year = int.tryParse(parts[0]);
    final week = int.tryParse(parts[1]);
    if (year == null || week == null) return null;
    final jan4 = DateTime.utc(year, 1, 4);
    final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
    return week1Monday.add(Duration(days: (week - 1) * 7));
  }

  DateTime? _parseIsoDate(String? isoDate) {
    if (isoDate == null) return null;
    final parts = isoDate.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime.utc(year, month, day);
  }

  String _formatMonthDayFromDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}';
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
            child: Text(
              'Error loading history.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          );
        }
        final data =
            snapshot.data ??
            const _HistoryData(
              weeks: [],
              patternRecords: [],
              historicalClosedShifts: [],
            );
        final weeks = data.weeks;
        final patternRecords = data.patternRecords;

        // Teaching summary only shown when pattern records exist.
        HistoryTeachingSummary? teachingSummary;
        LeverCardData? leakCard;
        if (patternRecords.isNotEmpty) {
          teachingSummary = HistoryTeachingAnalyzer.summarize(patternRecords);
          // 7.58.2 — single source of truth for the leak driver. Same
          // service Variance > Learn consults; pins parity per
          // `docs/contracts/phase_7_58_primary_driver_contract.md`
          // Single Source of Truth so the History leak card and the
          // Learn three-card teaching shape resolve the same lever id +
          // LeverCardData.metric copy for the same scope.
          // 7.58.UX.5 (F-1): the service returns a null card for
          // unknown ids / empty sets, so an unknown leak id still
          // suppresses the leak card rather than fabricating a
          // coversDown leak.
          const driverService = VarianceDriverPatternReadService();
          leakCard = driverService.resolveLeakDriver(patternRecords).card;
        }

        final historyRangeLabel = _historyRangeLabel(weeks);

        // ── CPLH vs OPZ 60-day band (Variance V2 Lane HIST) ───────────────
        // Mockup `#hist` first card. OPERATOR DECISION (History OPZ band
        // re-model): the outer rail REUSES the proven model + data source
        // of the baseline_tracker "CPLH RANGE & TARGET" band. Its outer
        // axis = `BaselineData.historicalContextRecords` min/max CPLH —
        // the lowest / highest CPLH over the last 60 days. We pass those
        // through the proven accessors `BaselineData.cplhSixtyDayLow` /
        // `cplhSixtyDayHigh` (the SAME list `rangeGraphModel` reads for
        // its `histMin`/`histMax`); the band does NOT recompute them.
        // Because that rail is the widest real observed bound, the OPZ
        // range always sits naturally inside it — no clamp/cap kludge.
        //
        // OPZ floor/ceiling come from the active target profile. The
        // per-week `WeekRecord.avgCPLH` series + most-recent week now
        // drive ONLY the History-specific teaching numbers (weeks below
        // floor) and the red "now" marker. NO new math, no engine change
        // (`lib/services/labor_model.dart` FROZEN). The active-target
        // notifier is read nullably so surfaces / tests that do not
        // provide it degrade honestly rather than crash (same pattern as
        // `variance_this_week_tab.dart`).
        final activeProfile =
            context.watch<ActiveTargetProfileNotifier?>()?.profile;
        final cplhSeries = weeks
            .map((w) => w.avgCPLH)
            .where((v) => v.isFinite && v > 0)
            .toList(growable: false);
        // The most recent week is the newest by weekId; mirrors the
        // `_historyRangeLabel` newest-first sort, no re-derivation.
        double? nowCplh;
        if (weeks.isNotEmpty) {
          final sorted = [...weeks]
            ..sort((a, b) => b.weekId.compareTo(a.weekId));
          final v = sorted.first.avgCPLH;
          if (v.isFinite && v > 0) nowCplh = v;
        }
        final opzBandData = CplhOpzBandData.fromInputs(
          weeklyCplhSeries: cplhSeries,
          // Reuse the proven baseline_tracker outer-axis source — no
          // duplicated min/max computation.
          sixtyDayLowCplh: BaselineData.cplhSixtyDayLow,
          sixtyDayHighCplh: BaselineData.cplhSixtyDayHigh,
          opzFloor: activeProfile?.opzFloorCPLH,
          opzCeiling: activeProfile?.opzCeilingCPLH,
          nowCplh: nowCplh,
        );

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Previous Weeks', style: AppTextStyles.display28()),
                    if (historyRangeLabel != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        historyRangeLabel,
                        style: AppTextStyles.body13(color: AppColors.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // ── History sections ─────────────────────────────────
            // Section order mirrors the approved mockup `#hist`:
            // band -> Most common leak -> Previous weeks.
            //
            // CPLH vs OPZ 60-day band — mockup `#hist` first card.
            // Rendered as the first card after the header so the History
            // tab mirrors the approved mockup ordering. The band itself
            // degrades honestly inside the card when OPZ bounds or the
            // CPLH series are unavailable (Metric Honesty Doctrine), so
            // the section is shown whenever there is any week history.
            if (weeks.isNotEmpty)
              SliverMainAxisGroup(
                slivers: [
                  const SliverPersistentHeader(
                    pinned: true,
                    delegate:
                        StickySectionDelegate('CPLH VS YOUR OPZ · 60-DAY'),
                  ),
                  SliverToBoxAdapter(
                    child: CplhOpzBandCard(data: opzBandData),
                  ),
                ],
              ),

            // Most common leak — mockup `#hist` "Most common leak" card.
            // Single styled card: serif headline (resolved leak driver)
            // + a richer teaching body with the inline `[[bad:…]]`
            // emphasis applied at render. Only shown when pattern
            // records exist; the benchmark-daypart list that used to
            // sit here is removed (operator decision: match the HTML).
            if (teachingSummary != null && leakCard != null)
              SliverMainAxisGroup(
                slivers: [
                  const SliverPersistentHeader(
                    pinned: true,
                    delegate: StickySectionDelegate('MOST COMMON LEAK'),
                  ),
                  SliverToBoxAdapter(
                    child: _MostCommonLeakCard(
                      leakCard: leakCard,
                      repeatCount: teachingSummary.mostCommonLeakCount,
                      totalHistoricalDayparts:
                          data.historicalClosedShifts.length,
                    ),
                  ),
                ],
              ),

            if (weeks.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Text(
                    'No history yet.',
                    style: AppTextStyles.body13(color: AppColors.textMuted),
                  ),
                ),
              )
            else
              SliverMainAxisGroup(
                slivers: [
                  const SliverPersistentHeader(
                    pinned: true,
                    delegate: StickySectionDelegate('PREVIOUS WEEKS'),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => WeekHistoryTile(
                        week: weeks[i],
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => WeekDetailScreen(week: weeks[i]),
                          ),
                        ),
                      ),
                      childCount: weeks.length,
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}
