import '../domain/models/benchmark_selection_summary.dart';
import '../domain/models/target_cycle.dart';
import '../domain/repositories/benchmark_selection_summary_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_benchmark_selection_summary_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../data/business_date_authority_service.dart';
import '../data/legacy_fixture_data.dart';
import '../data/target_cycle_service.dart';
import '../models/baseline_candidate_shift.dart';
import 'baseline_manager_service.dart';

/// Canonical Benchmark read path for the visible Benchmark screen.
///
/// Runtime source of truth:
/// - 60-day historical evidence: closed shifts from persisted history
/// - active benchmark geometry: active TargetCycle + persisted summary
/// - manager override state: persisted selected-key cohort
///
/// A bridge-only mode remains for widget tests that intentionally drive
/// BaselineData directly without standing up SQLite.
class BenchmarkTrackerReadService {
  BenchmarkTrackerReadService._();
  static final BenchmarkTrackerReadService instance =
      BenchmarkTrackerReadService._();

  final BenchmarkSelectionSummaryRepository _summaryRepo =
      SqliteBenchmarkSelectionSummaryRepository.instance;

  static bool _useBridgeOnly = false;

  static void enableBridgeOnly() => _useBridgeOnly = true;
  static void disableBridgeOnly() => _useBridgeOnly = false;

  bool get isBridgeOnly => _useBridgeOnly;

  BenchmarkTrackerView bridgeView() {
    return BenchmarkTrackerView(
      hasManagerOverride: BaselineData.hasManagerOverride,
      selectedShiftCount: BaselineData.selectedRecordCount,
      historicalTotalCoversTracked: BaselineData.historicalTotalCoversTracked,
      daypartRanges: BaselineData.daypartRanges,
      rangeGraphModel: BaselineData.rangeGraphModel,
    );
  }

  Future<BenchmarkTrackerView> load() async {
    if (_useBridgeOnly) return bridgeView();
    return _loadCanonical();
  }

  Future<BenchmarkTrackerView> _loadCanonical() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();
    final businessDate = await BusinessDateAuthorityService.instance
        .resolvePlanningAnchorDate(restaurantId);
    if (businessDate == null) {
      throw StateError(
        'BenchmarkTrackerReadService: planning anchor date unavailable',
      );
    }

    final cycle = await TargetCycleService.instance
        .getOrCreateActiveCycle(restaurantId, businessDate);
    final summary = await _summaryRepo.getByTargetCycleId(cycle.cycleId);
    final candidates = await BaselineManagerService.instance.getCandidateShifts();
    if (candidates.isEmpty) {
      throw StateError(
        'BenchmarkTrackerReadService: no candidate shifts available',
      );
    }

    return _buildCanonical(candidates, cycle, summary);
  }

  BenchmarkTrackerView _buildCanonical(
    List<BaselineCandidateShift> candidates,
    TargetCycle cycle,
    BenchmarkSelectionSummary? summary,
  ) {
    final selected = candidates.where((c) => c.isSelected).toList();
    final historicalTotalCovers =
        candidates.fold<int>(0, (sum, c) => sum + c.covers);
    final daypartRanges = _buildDaypartRanges(candidates);
    final graph = _buildGraph(
      candidates: candidates,
      selected: selected,
      cycle: cycle,
      summary: summary,
    );

    return BenchmarkTrackerView(
      hasManagerOverride: selected.isNotEmpty,
      selectedShiftCount: selected.length,
      historicalTotalCoversTracked: historicalTotalCovers,
      daypartRanges: daypartRanges,
      rangeGraphModel: graph,
    );
  }

  List<DaypartRange> _buildDaypartRanges(List<BaselineCandidateShift> all) {
    return ['lunch', 'dinner', 'late_night']
        .map((id) => _rangeFor(id, all))
        .toList();
  }

  DaypartRange _rangeFor(String id, List<BaselineCandidateShift> records) {
    final all = records.where((r) => r.daypart == id).toList();
    final selected = all.where((r) => r.isSelected).toList();
    if (all.isEmpty) {
      return DaypartRange(
        id: id,
        label: _labelFor(id),
        sampleSize: 0,
        selectedCount: 0,
        avgCovers: 0,
        avgCPLH: 0,
        avgSPLH: 0,
        avgPPA: 0,
        minCPLH: 0,
        maxCPLH: 0,
        targetCPLH: 0,
        targetSPLH: 0,
        targetPPA: 0,
        targetCovers: 0,
      );
    }

    final source = selected.isEmpty ? all : selected;
    final minCplh = all.map((r) => r.cplh).reduce((a, b) => a < b ? a : b);
    final maxCplh = all.map((r) => r.cplh).reduce((a, b) => a > b ? a : b);

    return DaypartRange(
      id: id,
      label: _labelFor(id),
      sampleSize: all.length,
      selectedCount: selected.length,
      avgCovers: all.fold<int>(0, (s, r) => s + r.covers) ~/ all.length,
      avgCPLH: all.fold<double>(0, (s, r) => s + r.cplh) / all.length,
      avgSPLH: all.fold<double>(0, (s, r) => s + r.splh) / all.length,
      avgPPA: all.fold<double>(0, (s, r) => s + r.ppa) / all.length,
      minCPLH: minCplh,
      maxCPLH: maxCplh,
      targetCPLH:
          source.fold<double>(0, (s, r) => s + r.cplh) / source.length,
      targetSPLH:
          source.fold<double>(0, (s, r) => s + r.splh) / source.length,
      targetPPA:
          source.fold<double>(0, (s, r) => s + r.ppa) / source.length,
      targetCovers: source.fold<int>(0, (s, r) => s + r.covers) ~/ source.length,
    );
  }

  String _labelFor(String id) {
    switch (id) {
      case 'lunch':
        return 'Lunch';
      case 'dinner':
        return 'Dinner';
      case 'late_night':
        return 'Late Night';
      default:
        return id;
    }
  }

  BaselineRangeGraphModel _buildGraph({
    required List<BaselineCandidateShift> candidates,
    required List<BaselineCandidateShift> selected,
    required TargetCycle cycle,
    required BenchmarkSelectionSummary? summary,
  }) {
    final histCplh = candidates.map((r) => r.cplh).toList();
    final histMin = histCplh.reduce((a, b) => a < b ? a : b);
    final histMax = histCplh.reduce((a, b) => a > b ? a : b);
    final hasManagerOverride = selected.isNotEmpty;

    final activeMin = hasManagerOverride ? _selectedMin(selected) : cycle.opzFloorCPLH;
    final activeMax =
        hasManagerOverride ? _selectedMax(selected) : cycle.opzCeilingCPLH;
    final target = hasManagerOverride ? _selectedAvg(selected) : cycle.targetCPLH;

    var scaleMin = histMin;
    var scaleMax = histMax;
    if (scaleMax <= scaleMin) {
      scaleMin = target - 1.0;
      scaleMax = target + 1.0;
    }
    final scaleRange = scaleMax - scaleMin;

    final honesty = _resolveHonesty(
      hasManagerOverride: hasManagerOverride,
      selected: selected,
      summary: summary,
    );

    return BaselineRangeGraphModel(
      historicalRangeStartCPLH: histMin,
      historicalRangeEndCPLH: histMax,
      displayRangeStartCPLH: histMin,
      displayRangeEndCPLH: histMax,
      activeRangeStartCPLH: activeMin,
      activeRangeEndCPLH: activeMax,
      targetCPLH: target,
      displayRangeStartPosition: 0.0,
      displayRangeEndPosition: 1.0,
      activeRangeStartPosition:
          ((activeMin - scaleMin) / scaleRange).clamp(0.0, 1.0),
      activeRangeEndPosition:
          ((activeMax - scaleMin) / scaleRange).clamp(0.0, 1.0),
      targetPosition: ((target - scaleMin) / scaleRange).clamp(0.0, 1.0),
      title: 'CPLH RANGE & TARGET',
      startLabel: 'LOWEST CPLH LAST 60 DAYS',
      endLabel: 'HIGHEST CPLH LAST 60 DAYS',
      rangeLabel: hasManagerOverride ? 'STAR SHIFT RANGE' : 'BENCHMARK RANGE',
      recommendedExplanation: honesty.explanation,
      overrideLabel: 'CHOOSE STAR SHIFTS',
      qualityTier: honesty.tier,
      isDegenerate: honesty.isDegenerate,
      degenerateFallbackMessage: honesty.fallbackMessage,
      statusBadgeLabel: honesty.badgeLabel,
    );
  }

  double _selectedMin(List<BaselineCandidateShift> selected) =>
      selected.map((r) => r.cplh).reduce((a, b) => a < b ? a : b);

  double _selectedMax(List<BaselineCandidateShift> selected) =>
      selected.map((r) => r.cplh).reduce((a, b) => a > b ? a : b);

  double _selectedAvg(List<BaselineCandidateShift> selected) =>
      selected.fold<double>(0, (s, r) => s + r.cplh) / selected.length;

  _GraphHonesty _resolveHonesty({
    required bool hasManagerOverride,
    required List<BaselineCandidateShift> selected,
    required BenchmarkSelectionSummary? summary,
  }) {
    if (hasManagerOverride) {
      final count = selected.length;
      if (count < 2) {
        return const _GraphHonesty(
          tier: 'too_narrow',
          isDegenerate: true,
          badgeLabel: 'OPZ RANGE TOO NARROW',
          explanation:
              'Star shifts too tightly clustered. Add more for a teachable range.',
        );
      }

      final width = _selectedMax(selected) - _selectedMin(selected);
      if (width < 0.15) {
        return const _GraphHonesty(
          tier: 'too_narrow',
          isDegenerate: true,
          badgeLabel: 'OPZ RANGE TOO NARROW',
          explanation:
              'Star shifts too tightly clustered. Add more for a teachable range.',
        );
      }
      if (width > 1.25) {
        return const _GraphHonesty(
          tier: 'too_wide',
          isDegenerate: true,
          badgeLabel: 'OPZ RANGE TOO WIDE',
          explanation:
              'Star shifts too widely spread. Tighten to one clean standard.',
        );
      }

      return const _GraphHonesty(
        tier: 'good',
        isDegenerate: false,
        badgeLabel: 'GOOD OPZ RANGE',
        explanation: 'Target sits in a usable range with room to flex.',
      );
    }

    if (summary == null) {
      return const _GraphHonesty(
        tier: 'unknown',
        isDegenerate: true,
        badgeLabel: 'RANGE UNCONFIRMED',
        explanation:
            'Benchmark evidence is not fully loaded yet. Treat the graph as context only.',
      );
    }

    if (summary.sourceType.contains('insufficient')) {
      return const _GraphHonesty(
        tier: 'insufficient',
        isDegenerate: true,
        badgeLabel: 'RANGE UNCONFIRMED',
        explanation:
            'Not enough recent 60-day evidence to recommend a benchmark range yet. Close more shifts before treating this as a target.',
        fallbackMessage:
            'The graph is showing the Config Default range as a placeholder, not a recommendation.',
      );
    }

    switch (summary.rangeQualityLabel) {
      case 'OPZ RANGE TOO WIDE':
        return const _GraphHonesty(
          tier: 'weak',
          isDegenerate: true,
          badgeLabel: 'RANGE TOO WIDE TO TEACH',
          explanation:
              'Dayparts (lunch, dinner, late night) have very different CPLH levels. The combined cross-daypart range is too wide to teach one standard.',
          fallbackMessage:
              'Per-daypart benchmarks are coming. Until then, treat this union band as context only.',
        );
      case 'OPZ RANGE TOO NARROW':
        return const _GraphHonesty(
          tier: 'weak',
          isDegenerate: true,
          badgeLabel: 'RANGE UNCERTAIN',
          explanation:
              'Recent cohorts did not meet the quality bar. Target may not be teachable yet.',
          fallbackMessage:
              'Give the 60-day window more closed shifts - the recommendation improves as evidence builds.',
        );
      default:
        return const _GraphHonesty(
          tier: 'good',
          isDegenerate: false,
          badgeLabel: 'GOOD OPZ RANGE',
          explanation: 'Target sits in a usable range with room to flex.',
        );
    }
  }
}

class BenchmarkTrackerView {
  final bool hasManagerOverride;
  final int selectedShiftCount;
  final int historicalTotalCoversTracked;
  final List<DaypartRange> daypartRanges;
  final BaselineRangeGraphModel rangeGraphModel;

  const BenchmarkTrackerView({
    required this.hasManagerOverride,
    required this.selectedShiftCount,
    required this.historicalTotalCoversTracked,
    required this.daypartRanges,
    required this.rangeGraphModel,
  });
}

class _GraphHonesty {
  final String tier;
  final bool isDegenerate;
  final String badgeLabel;
  final String explanation;
  final String? fallbackMessage;

  const _GraphHonesty({
    required this.tier,
    required this.isDegenerate,
    required this.badgeLabel,
    required this.explanation,
    this.fallbackMessage,
  });
}
