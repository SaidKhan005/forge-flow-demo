// Phase 7.55o.2 — Variance "Learn" tab.
//
// Extracted from lib/screens/variance_report.dart. Owns the Learn tab, its
// data loader, the hero, leak/wins/coach cards, and the Learn-specific
// metric row. Behaviour, labels, and fallback rules are unchanged from
// the pre-split implementation.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/learn_benchmark_context_service.dart';
import '../../domain/constants/app_defaults.dart';
import '../../domain/constants/cross_axis_pair_catalog.dart';
import '../../services/shift_data_source.dart';
import '../../models/history_pattern_record.dart';
import '../../models/learn_benchmark_context.dart';
import '../../models/learn_repeatable_win_summary.dart';
import '../../models/learn_teaching_summary.dart';
import '../../models/shift_record.dart';
import '../../models/week_record.dart';
import '../../services/daypart_evidence_visibility_policy.dart';
import '../../services/learn_repeatable_wins_read_service.dart';
import '../../services/learn_teaching_analyzer.dart';
import '../../services/variance_driver_pattern_read_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/learn/learn_carousel.dart';
import '../../widgets/learn/learn_chapter_rail.dart';
import '../../widgets/learn/learn_cross_axis_card.dart';
import '../../widgets/learn/learn_story_frame_card.dart';
import '../../widgets/learn/learn_teaching_card.dart';

class LearnTab extends StatefulWidget {
  const LearnTab({super.key});

  @override
  State<LearnTab> createState() => _LearnTabState();
}

class _LearnTabState extends State<LearnTab>
    with AutomaticKeepAliveClientMixin {
  late Future<_LearnData> _future;

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
          LearnBenchmarkContextService.instance.resolve(),
          source.getHistoricalClosedShifts(),
        ]).then((results) {
          final weeks = results[0] as List<WeekRecord>;
          final patternRecords = results[1] as List<HistoryPatternRecord>;
          final benchmarkContext = results[2] as LearnBenchmarkContext;
          final closedShifts = results[3] as List<ShiftRecord>;
          // 7.58.3 — coverage denominator for the leak repeat counter.
          // `closedShifts` is the same closed `shift_records` population
          // `HistoryPatternBuilder` consumes upstream, so repeats and
          // coverage read from the same source. See Sub-Slice Family
          // `.3` row in
          // `docs/contracts/phase_7_58_primary_driver_contract.md`.
          final summary = LearnTeachingAnalyzer.summarize(
            patternRecords: patternRecords,
            weekCount: weeks.length,
            benchmarkContext: benchmarkContext,
            coverageCount: closedShifts.length,
          );
          // 7.58.2 — single source of truth for the leak driver. Same
          // service Variance > History consults; pins parity per
          // `docs/contracts/phase_7_58_primary_driver_contract.md`
          // Single Source of Truth so the Learn three-card teaching
          // shape and the History leak evidence card resolve the same
          // lever id + LeverCardData.metric copy for the same scope.
          const driverService = VarianceDriverPatternReadService();
          final leakDriver = driverService.resolveLeakDriver(patternRecords);
          const winsService = LearnRepeatableWinsReadService();
          final allWins = winsService.build(closedShifts);
          // Apply visibility policy: only truly repeated wins pass (7.55k.7).
          final repeatableWins = allWins
              .where(
                (w) =>
                    DaypartEvidenceVisibilityPolicy.classifyRepeatableWin(
                      benchmarkCount: w.benchmarkCount,
                    ) ==
                    EvidenceTier.strong,
              )
              .toList();
          return _LearnData(
            summary: summary,
            repeatableWins: repeatableWins,
            leakDriver: leakDriver,
          );
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
            child: Text(
              'Error loading Learn data.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return Center(
            child: Text(
              'No data.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          );
        }
        return _LearnContent(
          summary: data.summary,
          repeatableWins: data.repeatableWins,
          leakDriver: data.leakDriver,
        );
      },
    );
  }
}

class _LearnData {
  final LearnTeachingSummary summary;
  final List<LearnRepeatableWinSummary> repeatableWins;
  final VarianceDriverPattern leakDriver;
  const _LearnData({
    required this.summary,
    required this.repeatableWins,
    required this.leakDriver,
  });
}

class _LearnContent extends StatefulWidget {
  final LearnTeachingSummary summary;
  final List<LearnRepeatableWinSummary> repeatableWins;
  final VarianceDriverPattern leakDriver;
  const _LearnContent({
    required this.summary,
    required this.repeatableWins,
    required this.leakDriver,
  });

  @override
  State<_LearnContent> createState() => _LearnContentState();
}

class _LearnContentState extends State<_LearnContent> {
  // V2-5: the rail is preserved exactly with three permanent entries in
  // the mockup order. 0 = Recurring Leak, 1 = Repeatable Wins,
  // 2 = Cross-Axis. None of the three is ever dropped; Cross-Axis is its
  // own 4-pair section rather than a conditional swap of chapter 0. See
  // docs/contracts/phase_7_58_primary_driver_contract.md V2-5 and the
  // binding mockup docs/f&f Coaching/variance_tab_v2_mockup.html #rail.
  int _activeChapter = 0;

  static const List<LearnChapter> _chapters = [
    LearnChapter(title: 'Recurring Leak', icon: Icons.warning_amber_rounded),
    LearnChapter(title: 'Repeatable Wins', icon: Icons.trending_up_rounded),
    LearnChapter(title: 'Cross-Axis', icon: Icons.swap_horiz_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final wins = widget.repeatableWins;

    // V2-5: resolve the locked-catalog source for each section. Pure
    // read, no state mutation, no engine call.
    //
    // The leak card comes from the shared
    // `VarianceDriverPatternReadService` (the same service Variance >
    // History consults), so the Learn story and the History leak card
    // resolve the identical `LeverCardData` for the same closed-shift
    // scope (7.58.2 Single Source of Truth). A null card (unknown id /
    // empty set / `on_model` sentinel) falls back to the honest
    // "no patterns yet" frame instead of fabricating a card.
    final leakCard =
        summary.hasHistoryPatterns ? widget.leakDriver.card : null;
    final LearnRepeatableWinSummary? topWin =
        wins.isNotEmpty ? wins.first : null;
    final benchmarkCard =
        topWin == null ? null : LeverCards.lookup(topWin.dominantLeverId);

    // V2-5: Carousel configuration for the active section. Leak and
    // Wins each render as a 3-frame story (dots adapt to 3); Cross-Axis
    // is the locked 4-pair walk (dots adapt to 4). The honest-fallback
    // single card stays 1 frame. `LearnCarousel` reads `cardCount`
    // directly so the worm-dot indicator adapts to the active section.
    final int cardCount;
    final IndexedWidgetBuilder cardBuilder;
    if (_activeChapter == 0) {
      // Recurring Leak.
      if (leakCard == null) {
        cardCount = 1;
        cardBuilder = (ctx, _) => LearnTeachingCard(
          badgeLabel: 'NO PATTERNS YET',
          badgeColor: AppColors.textMuted,
          title: 'Leaks will surface here',
          body: summary.primaryFixLine,
        );
      } else {
        final caption = _leakCoverageCaption(summary);
        cardCount = 3;
        cardBuilder = (ctx, i) {
          switch (i) {
            case 0:
              return LearnStoryFrameCard(
                stepLabel: 'FRAME 1 · WHAT HAPPENED',
                heading: leakCard.metric,
                caption: caption,
                visualHint: _leverVisualHint(leakCard, favorable: false),
                body: leakCard.whatHappened,
                accent: AppColors.negative,
              );
            case 1:
              return LearnStoryFrameCard(
                stepLabel: 'FRAME 2 · WHY IT MATTERS',
                heading: 'Luck does not repeat',
                visualHint: _consequenceHint(leakCard),
                body: leakCard.teachingNote,
                accent: AppColors.negative,
              );
            default:
              return LearnStoryFrameCard(
                stepLabel: 'FRAME 3 · WHAT TO DO',
                heading: 'Schedule from the math',
                body: leakCard.whatToDo,
                actionPlay: leakCard.whatToDo,
                accent: AppColors.sunset,
              );
          }
        };
      }
    } else if (_activeChapter == 1) {
      // Repeatable Wins.
      if (benchmarkCard == null || topWin == null) {
        cardCount = 1;
        cardBuilder = (ctx, _) => LearnTeachingCard(
          badgeLabel: 'NO REPEATABLE WINS YET',
          badgeColor: AppColors.textMuted,
          title: 'Wins will surface here',
          body: summary.studyLine,
        );
      } else {
        final caption = _winCoverageCaption(topWin);
        cardCount = 3;
        cardBuilder = (ctx, i) {
          switch (i) {
            case 0:
              return LearnStoryFrameCard(
                stepLabel: 'FRAME 1 · WHAT HELD',
                heading: benchmarkCard.metric,
                caption: caption,
                visualHint:
                    _leverVisualHint(benchmarkCard, favorable: true),
                body: benchmarkCard.whatHappened,
                accent: AppColors.positive,
              );
            case 1:
              return LearnStoryFrameCard(
                stepLabel: 'FRAME 2 · WHY IT MATTERS',
                heading: 'You cannot repeat what you do not understand',
                visualHint: _consequenceHint(benchmarkCard),
                body: benchmarkCard.teachingNote,
                accent: AppColors.positive,
              );
            default:
              return LearnStoryFrameCard(
                stepLabel: 'FRAME 3 · WHAT TO PROTECT',
                heading: 'Bank the setup',
                body: benchmarkCard.whatToDo,
                actionPlay: benchmarkCard.whatToDo,
                accent: AppColors.sunset,
              );
          }
        };
      }
    } else {
      // Cross-Axis: the locked 4-pair swipe, one card per
      // `CrossAxisPairs` entry, exactly as the mockup `#crossTrack`.
      const pairs = CrossAxisPairs.all;
      cardCount = pairs.length;
      cardBuilder = (ctx, i) {
        final pair = pairs[i];
        return LearnCrossAxisCard(
          pair: pair,
          axisBadge: _pairAxisBadge(pair.id),
        );
      };
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ Hero framing ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _LearnHero(summary: summary),
          ),
          const SizedBox(height: 16),

          // ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ Chapter rail ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬
          LearnChapterRail(
            chapters: _chapters,
            activeIndex: _activeChapter,
            onTap: (i) => setState(() => _activeChapter = i),
          ),
          const SizedBox(height: 8),

          // ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ Carousel ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬
          SizedBox(
            height: 420,
            child: LearnCarousel(
              key: ValueKey(_activeChapter),
              cardCount: cardCount,
              cardBuilder: cardBuilder,
            ),
          ),
          const SizedBox(height: 6),

          // V2-5: the mockup `#learn` ends with the `.hint` swipe
          // affordance, not a coaching footer. The retired
          // `_CoachNextWeekCard` (primaryFix / study / coachTo lines) is
          // NOT in the approved mockup; those summary fields are
          // untouched and still consumed by the honest leak/win fallback
          // frames (`summary.primaryFixLine` / `summary.studyLine`).
          Center(
            child: Text(
              '‹ swipe ›',
              style: AppTextStyles.mono12(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Learn-tab header: the serif `Learn` display heading plus the mockup
/// `.sub` line, matching the approved `#learn` header exactly. The
/// decorative benchmark/target chip row that previously lived here was
/// trimmed (not in the mockup); the benchmark-set facts still resolve
/// through the read services and surface in the story frames below.
class _LearnHero extends StatelessWidget {
  final LearnTeachingSummary summary;
  const _LearnHero({required this.summary});

  @override
  Widget build(BuildContext context) {
    // V2-5: the Learn hero is exactly the mockup `#learn` header: the
    // serif `Learn` display heading plus the `.sub` line. The decorative
    // 5-chip benchmark/target Wrap is NOT in the approved mockup and was
    // trimmed; the benchmark-set facts still live in the read services
    // and the story frames, so this hero is header-only.
    return Padding(
      // Match the This Week / Previous Weeks sub-header padding so
      // the three tab titles align vertically.
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Learn', style: AppTextStyles.display28()),
          const SizedBox(height: 4),
          Text(
            'One idea per frame. Swipe each section.',
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

// === V2-5 Learn-story helpers ============================================
// Derive the optional frame-1 caption and the `.fvis` visual-hint chips
// from the LOCKED catalog identity fields only. These never author new
// teaching prose into the catalog and never call the driver engine; they
// compose short, truthful identity strings from data the read services
// already resolved (lever short label / side / cause category, repeat
// counts, daypart labels). Honest-fallback rules return null so a frame
// never asserts a denominator or hint the data cannot back.

/// Frame-1 caption for the Recurring Leak story. Mirrors the mockup
/// `.lcap` ("Repeated 6 of last 12 Fri dinners"). Returns null when the
/// denominator is unknown (zero coverage / no recurring leak / no top
/// daypart) so the copy stays honest.
String? _leakCoverageCaption(LearnTeachingSummary summary) {
  if (summary.coverageCount <= 0) return null;
  if (summary.primaryLeakCount <= 0) return null;
  if (summary.topLeakDayparts.isEmpty) return null;
  final daypartLabel = _pluralizeDaypart(summary.topLeakDayparts.first);
  return 'Repeated ${summary.primaryLeakCount} of last '
      '${summary.coverageCount} $daypartLabel';
}

/// Frame-1 caption for the Repeatable Wins story. Mirrors the mockup
/// `.lcap` ("In the zone 9 of last 12 Tue lunches"). Returns null when
/// the win has no resolvable daypart label so the copy stays honest.
String? _winCoverageCaption(LearnRepeatableWinSummary win) {
  if (win.closedShiftCount <= 0) return null;
  if (win.label.isEmpty) return null;
  final daypartLabel = _pluralizeDaypart(win.label);
  return 'In the zone ${win.benchmarkCount} of last '
      '${win.closedShiftCount} $daypartLabel';
}

/// Pluralizes the trailing daypart noun on a `fullLabel` like
/// `Tue Lunch` -> `Tue Lunches`. The three canonical daypart labels
/// (`Lunch` / `Dinner` / `Late Night`) cover the plural rules: `Lunch`
/// takes `es`, the others take `s`.
String _pluralizeDaypart(String fullLabel) {
  if (fullLabel.isEmpty) return fullLabel;
  if (fullLabel.endsWith('Lunch')) return '${fullLabel}es';
  return '${fullLabel}s';
}

/// Frame-1 `.fvis` visual hint built from the locked lever identity.
/// Composed from `shortLabel` + sentiment glyph + side, never authored
/// prose, so it cannot drift the frozen catalog. Returns null when the
/// short label is unavailable.
String? _leverVisualHint(LeverCardData card, {required bool favorable}) {
  if (card.shortLabel.isEmpty) return null;
  final glyph = card.isFavorable ? '↑ held' : '↓ soft';
  return '${card.shortLabel} $glyph · ${card.sideLabel.toLowerCase()}';
}

/// Frame-2 `.fvis` consequence hint. Names the lever and its cause
/// category as the "why it matters" thread, composed from locked
/// identity fields only.
String _consequenceHint(LeverCardData card) {
  return '${card.shortLabel} · ${card.causeCategory.toLowerCase()} pattern';
}

/// CPLH/SPLH glyph badge for a Cross-Axis pair card (mockup `.lb`,
/// e.g. `CPLH ↓ · SPLH ↑`). Keyed off the locked pair id so the badge
/// stays in lockstep with the frozen `CrossAxisPairs` catalog.
String _pairAxisBadge(String pairId) {
  switch (pairId) {
    case 'cplh_below_splh_above':
      return 'CPLH ↓ · SPLH ↑';
    case 'cplh_on_splh_below':
      return 'CPLH = · SPLH ↓';
    case 'cplh_above_splh_below':
      return 'CPLH ↑ · SPLH ↓';
    case 'both_below':
      return 'CPLH ↓ · SPLH ↓';
    default:
      return 'CPLH · SPLH';
  }
}
