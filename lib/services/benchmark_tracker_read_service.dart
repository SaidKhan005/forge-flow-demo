import '../domain/models/service_period_definition.dart';
import '../domain/models/target_cycle.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'business_date_authority_service.dart';
import 'baseline_authority_service.dart';
import 'restaurant_timing_config_read_service.dart';
import 'target_cycle_service.dart';
import '../models/baseline_candidate_shift.dart';
import 'baseline_manager_service.dart';

/// Canonical Benchmark read path for the visible Benchmark screen.
///
/// Runtime source of truth:
/// - 60-day historical evidence: closed shifts from persisted history
/// - active benchmark geometry: active TargetCycle
/// - manager override state: persisted selected-key cohort
/// - honest copy/state/badge/button: the single verdict-driven source
///   (`BaselineData.resolveGraphHonesty()`), identical to the bridge
///   `rangeGraphModel`
///
/// A bridge-only mode remains for widget tests that intentionally drive
/// BaselineData directly without standing up SQLite.
class BenchmarkTrackerReadService {
  BenchmarkTrackerReadService._();
  static final BenchmarkTrackerReadService instance =
      BenchmarkTrackerReadService._();

  static bool _useBridgeOnly = false;

  static void enableBridgeOnly() => _useBridgeOnly = true;
  static void disableBridgeOnly() => _useBridgeOnly = false;

  bool get isBridgeOnly => _useBridgeOnly;

  BenchmarkTrackerView bridgeView() {
    // Bridge-only widget tests have no persisted timing config; use the
    // canonical fixture-era definitions so labels/order match the
    // legacy bridge ranges. Period set still comes from the resolver,
    // never a hardcoded list inside this service (Design Rule:
    // period set + boundaries come from operator timing config).
    return BenchmarkTrackerView(
      hasManagerOverride: BaselineData.hasManagerOverride,
      selectedShiftCount: BaselineData.selectedRecordCount,
      historicalTotalCoversTracked: BaselineData.historicalTotalCoversTracked,
      daypartRanges: BaselineData.daypartRanges,
      rangeGraphModel: BaselineData.rangeGraphModel,
      servicePeriodDefinitions: ServicePeriodDefinitionResolver.demoDefinitions,
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
    final candidates = await BaselineManagerService.instance.getCandidateShifts();
    if (candidates.isEmpty) {
      throw StateError(
        'BenchmarkTrackerReadService: no candidate shifts available',
      );
    }

    // Period set + labels + ordering come from the operator's persisted
    // timing config, never a hardcoded `['lunch','dinner','late_night']`
    // list (Gap 15 / Design Rule: period set comes from operator timing
    // config). Falls back to the canonical fixture-era definitions when
    // no timing config is persisted yet.
    final timingConfig = await RestaurantTimingConfigReadService.instance
        .getActiveTimingConfig();
    final defs = (timingConfig?.servicePeriodDefinitions.isNotEmpty ?? false)
        ? timingConfig!.servicePeriodDefinitions
        : ServicePeriodDefinitionResolver.demoDefinitions;

    return _buildCanonical(candidates, cycle, defs);
  }

  BenchmarkTrackerView _buildCanonical(
    List<BaselineCandidateShift> candidates,
    TargetCycle cycle,
    List<ServicePeriodDefinition> defs,
  ) {
    final selected = candidates.where((c) => c.isSelected).toList();
    final historicalTotalCovers =
        candidates.fold<int>(0, (sum, c) => sum + c.covers);
    final daypartRanges = _buildDaypartRanges(candidates, defs);
    final graph = _buildGraph(
      candidates: candidates,
      selected: selected,
      cycle: cycle,
    );

    return BenchmarkTrackerView(
      hasManagerOverride: selected.isNotEmpty,
      selectedShiftCount: selected.length,
      historicalTotalCoversTracked: historicalTotalCovers,
      daypartRanges: daypartRanges,
      rangeGraphModel: graph,
      servicePeriodDefinitions: defs,
    );
  }

  List<DaypartRange> _buildDaypartRanges(
    List<BaselineCandidateShift> all,
    List<ServicePeriodDefinition> defs,
  ) {
    return ServicePeriodDefinitionResolver.ordered(defs)
        .map((d) => _rangeFor(d.id, all, defs))
        .toList();
  }

  DaypartRange _rangeFor(
    String id,
    List<BaselineCandidateShift> records,
    List<ServicePeriodDefinition> defs,
  ) {
    final all = records.where((r) => r.daypart == id).toList();
    final selected = all.where((r) => r.isSelected).toList();
    if (all.isEmpty) {
      return DaypartRange(
        id: id,
        label: ServicePeriodDefinitionResolver.labelForId(defs, id),
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
      label: ServicePeriodDefinitionResolver.labelForId(defs, id),
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

  // `summary` is no longer threaded here: honesty/copy/state come from
  // the single verdict-driven source (`BaselineData.resolveGraphHonesty()`),
  // not the persisted `rangeQualityLabel`. Geometry uses `cycle` /
  // `candidates` / `selected` only.
  BaselineRangeGraphModel _buildGraph({
    required List<BaselineCandidateShift> candidates,
    required List<BaselineCandidateShift> selected,
    required TargetCycle cycle,
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

    // Honesty / copy / state / button policy come from the SINGLE
    // verdict-driven source SC built (`BaselineData._resolveGraphHonesty`,
    // exposed additively via `BaselineData.resolveGraphHonesty()`).
    // There is no parallel honesty resolver in this service anymore: the
    // canonical screen path and the bridge `rangeGraphModel` now read the
    // exact same override-vs-recommendation mapping + approved §9 copy.
    // GEOMETRY (hist min/max, active range, target, positions, scale)
    // stays computed here from `cycle`/`candidates`/`selected`; only the
    // honesty fields delegate. Override geometry still uses the selected
    // min/max/avg; recommended geometry uses the cycle floor/ceiling/
    // target (unchanged).
    final honesty = BaselineData.resolveGraphHonesty();

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
      buttonEmphasis: honesty.buttonEmphasis,
      perPeriodRollupLine: honesty.perPeriodRollupLine,
    );
  }

  double _selectedMin(List<BaselineCandidateShift> selected) =>
      selected.map((r) => r.cplh).reduce((a, b) => a < b ? a : b);

  double _selectedMax(List<BaselineCandidateShift> selected) =>
      selected.map((r) => r.cplh).reduce((a, b) => a > b ? a : b);

  double _selectedAvg(List<BaselineCandidateShift> selected) =>
      selected.fold<double>(0, (s, r) => s + r.cplh) / selected.length;
}

class BenchmarkTrackerView {
  final bool hasManagerOverride;
  final int selectedShiftCount;
  final int historicalTotalCoversTracked;
  final List<DaypartRange> daypartRanges;
  final BaselineRangeGraphModel rangeGraphModel;

  /// Operator-configured service-period definitions (ordered). The
  /// Daypart Breakdown table reads labels + ordering from here instead
  /// of a hardcoded period list (Gap 15 / Design Rule: period set
  /// comes from operator timing config).
  final List<ServicePeriodDefinition> servicePeriodDefinitions;

  const BenchmarkTrackerView({
    required this.hasManagerOverride,
    required this.selectedShiftCount,
    required this.historicalTotalCoversTracked,
    required this.daypartRanges,
    required this.rangeGraphModel,
    this.servicePeriodDefinitions = const [],
  });
}
