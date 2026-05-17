// Phase 5.1 — Baseline Manager Screen (contract fix)
// Phase 7.55o.5 — shell / route / state only. Calendar, day detail,
// preview, action bars, and shared helpers now live in
// `screens/baseline_manager/`. Selection semantics, target-cycle
// write path, candidate truth, and preview formulas are unchanged.
//
// R1 — Choose Star Shifts: the period set, labels, order, and count
// now derive from the operator's persisted timing config
// (`ServicePeriodDefinitionResolver.ordered(...)`), never a hardcoded
// daypart list. A lens bar re-scopes the calendar AND the summary
// together (Whole day = cover-weighted rollup READ from existing
// plumbing). The calendar is the hero element with two cell states.
// A once-per-cycle pre-commit gate disables the commit action up
// front with plain-English copy when the override is already used
// or out of window. The selection write path
// (`BaselineManagerService.saveSelection`) is unchanged — no
// parallel target stack, no new persistence shape.

import 'package:flutter/material.dart';

import 'package:forge_and_flow/services/baseline_manager_service.dart';
import '../services/demand_forecast_context_service.dart';
import '../services/star_target_selection_write_service.dart';
import '../services/target_cycle_service.dart';
import '../services/business_date_authority_service.dart';
import '../services/restaurant_timing_config_read_service.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../domain/services/target_cycle_policy.dart';
import '../models/baseline_candidate_shift.dart';
import '../theme/app_theme.dart';
import 'baseline_manager/baseline_manager_actions.dart';
import 'baseline_manager/baseline_manager_calendar.dart';
import 'baseline_manager/baseline_manager_day_detail.dart';
import 'baseline_manager/baseline_manager_helpers.dart';
import 'baseline_manager/baseline_manager_lens.dart';
import 'baseline_manager/baseline_manager_preview.dart';

// 7.55o.5: preserve the existing `import '.../baseline_manager_screen.dart'`
// surface so callers can still reach ManagerOverridePlanPreview through
// this file.
export 'baseline_manager/baseline_manager_preview.dart'
    show ManagerOverridePlanPreview;

class BaselineManagerScreen extends StatefulWidget {
  /// Production constructor — loads candidates from DB on init.
  const BaselineManagerScreen({super.key})
    : initialCandidates = null,
      initialDemandCovers = null,
      initialDefs = null;

  /// Test-only constructor: skips async DB load and uses the supplied list.
  /// [initialDemandCovers] bypasses the async demand context load for tests.
  /// [initialDefs] bypasses the async timing-config load so widget tests
  /// can prove the lens / calendar derive from a given operator config
  /// (e.g. a 4-period config) without a DB.
  @visibleForTesting
  const BaselineManagerScreen.withCandidates(
    List<BaselineCandidateShift> candidates, {
    super.key,
    this.initialDemandCovers,
    this.initialDefs,
  }) : initialCandidates = candidates;

  final List<BaselineCandidateShift>? initialCandidates;
  final int? initialDemandCovers;
  final List<ServicePeriodDefinition>? initialDefs;

  @override
  State<BaselineManagerScreen> createState() => _BaselineManagerScreenState();
}

class _BaselineManagerScreenState extends State<BaselineManagerScreen> {
  // ── State ──────────────────────────────────────────────────────────────────

  bool _loading = true;
  List<BaselineCandidateShift> _candidates = [];
  late Set<String> _draftKeys;
  int? _demandWeeklyAvgCovers; // from canonical demand context
  String? _selectedDate; // null = calendar grid, non-null = day detail
  Map<String, List<BaselineCandidateShift>> _shiftsByDate = {};
  List<String> _windowDates = [];

  // R1: resolved, operator-configured service-period definitions
  // (ordered). Period set/labels/order/count flow exclusively from
  // here. Falls back to the fixture-era demo definitions only when
  // no timing config is persisted yet.
  List<ServicePeriodDefinition> _defs =
      ServicePeriodDefinitionResolver.ordered(
    ServicePeriodDefinitionResolver.demoDefinitions,
  );

  // Active lens. Default = Whole day (cover-weighted rollup).
  String _lensId = kWholeDayLensId;

  // R1: once-per-cycle pre-commit gate. When the active cycle has
  // already consumed its manager override (or the cycle is out of
  // window), the commit action is disabled UP FRONT with a clear
  // explanation, before the operator builds a selection. The
  // post-commit ManagerOverrideDeniedException SnackBar stays as a
  // backstop.
  bool _commitGateChecked = false;
  bool _canCommit = true;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    if (widget.initialDefs != null) {
      _defs =
          ServicePeriodDefinitionResolver.ordered(widget.initialDefs!);
    }
    if (widget.initialCandidates != null) {
      _candidates = widget.initialCandidates!;
      _draftKeys = _candidates
          .where((c) => c.isSelected)
          .map((c) => c.recordKey)
          .toSet();
      _loading = false;
      _buildCalendarData();
      if (widget.initialDemandCovers != null) {
        _demandWeeklyAvgCovers = widget.initialDemandCovers;
      } else {
        _loadDemandContext();
      }
      if (widget.initialDefs == null) {
        _loadTimingDefs();
      }
      _loadCommitGate();
    } else {
      _loadCandidates();
    }
  }

  Future<void> _loadCandidates() async {
    final candidates = await BaselineManagerService.instance
        .getCandidateShifts();
    await _loadTimingDefs();
    if (!mounted) return;
    setState(() {
      _candidates = candidates;
      _draftKeys = candidates
          .where((c) => c.isSelected)
          .map((c) => c.recordKey)
          .toSet();
      _loading = false;
      _buildCalendarData();
    });
    await _loadDemandContext();
    await _loadCommitGate();
  }

  /// Loads the operator's persisted timing config and resolves the
  /// service-period definitions. Falls back to the fixture-era demo
  /// definitions ONLY when no timing config is persisted yet — the
  /// same pattern as `benchmark_tracker_read_service.dart:86-90`.
  Future<void> _loadTimingDefs() async {
    final timingConfig = await RestaurantTimingConfigReadService.instance
        .getActiveTimingConfig();
    final resolved =
        (timingConfig?.servicePeriodDefinitions.isNotEmpty ?? false)
            ? timingConfig!.servicePeriodDefinitions
            : ServicePeriodDefinitionResolver.demoDefinitions;
    if (!mounted) return;
    setState(() {
      _defs = ServicePeriodDefinitionResolver.ordered(resolved);
    });
  }

  Future<void> _loadDemandContext() async {
    final ctx = await DemandForecastContextService.instance.getCurrentContext();
    if (!mounted) return;
    setState(() {
      _demandWeeklyAvgCovers = ctx.historicalWeeklyAvgCovers;
    });
  }

  /// R1 pre-commit gate. Reads the active cycle for the planning
  /// anchor date and calls `TargetCyclePolicy.canManagerOverride`.
  /// A false result means the operator may not commit a new override
  /// (already used this 60-day cycle, or out of window) — the commit
  /// action renders disabled with short explanatory copy.
  Future<void> _loadCommitGate() async {
    try {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final businessDate = await BusinessDateAuthorityService.instance
          .resolvePlanningAnchorDate(restaurantId);
      if (businessDate == null) {
        if (!mounted) return;
        setState(() {
          _commitGateChecked = true;
          _canCommit = true;
        });
        return;
      }
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, businessDate);
      final canOverride =
          TargetCyclePolicy.canManagerOverride(cycle, businessDate);
      if (!mounted) return;
      setState(() {
        _commitGateChecked = true;
        _canCommit = canOverride;
      });
    } catch (_) {
      // Gate is an up-front affordance, not the enforcement point.
      // The write path still enforces the rule and the post-commit
      // SnackBar is the backstop, so a gate-probe failure must not
      // block an otherwise-valid commit.
      if (!mounted) return;
      setState(() {
        _commitGateChecked = true;
        _canCommit = true;
      });
    }
  }

  // ── Calendar data ──────────────────────────────────────────────────────────

  void _buildCalendarData() {
    _shiftsByDate = {};
    _windowDates = [];
    _selectedDate = null;

    for (final c in _candidates) {
      if (c.businessDate == null) continue;
      _shiftsByDate.putIfAbsent(c.businessDate!, () => []).add(c);
    }

    if (_shiftsByDate.isEmpty) return;

    // Anchor to the latest candidate businessDate
    final anchorDate = _shiftsByDate.keys.reduce(
      (a, b) => a.compareTo(b) > 0 ? a : b,
    );

    final anchor = parseIsoDate(anchorDate);
    // Use DateTime constructor (not Duration) to avoid DST day-shift bugs.
    final start = DateTime(anchor.year, anchor.month, anchor.day - 59);

    _windowDates = List.generate(60, (i) {
      return formatIsoDate(DateTime(start.year, start.month, start.day + i));
    });

    // Sort candidates within each date by the operator-configured
    // service-period definition order — never a hardcoded daypart list.
    final defs = _defs;
    for (final list in _shiftsByDate.values) {
      list.sort(
        (a, b) => ServicePeriodDefinitionResolver.sortIndex(
          defs,
          a.daypart,
        ).compareTo(ServicePeriodDefinitionResolver.sortIndex(defs, b.daypart)),
      );
    }
  }

  // ── Lens scoping ───────────────────────────────────────────────────────────

  bool get _isWholeDay => _lensId == kWholeDayLensId;

  /// Draft-selected candidates scoped to the active lens. Whole day =
  /// the rollup of all configured periods; a period lens = only that
  /// period's shifts. Used to re-scope the summary/preview together
  /// with the calendar.
  List<BaselineCandidateShift> get _lensScopedSelected {
    final selected =
        _candidates.where((c) => _draftKeys.contains(c.recordKey));
    if (_isWholeDay) return selected.toList();
    return selected.where((c) => c.daypart == _lensId).toList();
  }

  String get _lensScopeLabel {
    if (_isWholeDay) return 'Whole day targets';
    final label =
        ServicePeriodDefinitionResolver.labelForId(_defs, _lensId);
    return '$label targets';
  }

  List<String> get _periodIds => _defs.map((d) => d.id).toList();

  // ── Draft helpers ──────────────────────────────────────────────────────────

  void _toggle(String recordKey) {
    setState(() {
      if (_draftKeys.contains(recordKey)) {
        _draftKeys.remove(recordKey);
      } else {
        _draftKeys.add(recordKey);
      }
    });
  }

  void _clearAll() {
    setState(() => _draftKeys.clear());
  }

  // ── Navigation actions ─────────────────────────────────────────────────────

  void _cancel() => Navigator.of(context).pop();

  Future<void> _done() async {
    // 7.55q.9: non-empty selections now route through
    // `TargetCycleService.applyManagerOverrideCycle` inside
    // `BaselineManagerService.saveSelection`, which enforces the
    // once-per-60-day manager override rule. If the cycle has already
    // consumed its override, a `ManagerOverrideDeniedException` is
    // thrown — surface it honestly and keep the draft intact so the
    // user sees why nothing landed. The R1 pre-commit gate disables
    // the action up front; this remains the enforcement backstop.
    try {
      await BaselineManagerService.instance.saveSelection(_draftKeys);
    } on ManagerOverrideDeniedException catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Manager override already used for this 60-day cycle. '
            'Use Settings, Reset Target Cycle (Admin) to test again.',
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
          backgroundColor: AppColors.backgroundMid,
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    } on StarTargetSelectionWriteException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _serverWriteErrorMessage(error),
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
          backgroundColor: AppColors.backgroundMid,
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  String _serverWriteErrorMessage(StarTargetSelectionWriteException error) {
    switch (error.code) {
      case 'permission_denied':
      case 'admin_decision_source_forbidden':
        return 'You do not have permission to change shared star shifts.';
      case 'selected_star_target_unavailable':
      case 'star_target_proxy_route_not_found':
      case 'sync_proxy_request_failed':
        return 'Star target server truth is unavailable. Sync again before changing star shifts.';
      case 'auth_session_required':
      case 'missing_auth_token':
        return 'Sign in again before changing shared star shifts.';
      case 'candidate_business_date_missing':
      case 'candidate_not_in_server_window':
        return error.message;
      default:
        return error.message.isEmpty
            ? 'Star shift selection could not be saved to server truth.'
            : error.message;
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final lensSelected = _lensScopedSelected;
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDeep,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios,
            size: 18,
            color: AppColors.textMuted,
          ),
          onPressed: _cancel,
        ),
        title: Text('Choose Star Shifts', style: AppTextStyles.mono11()),
        centerTitle: false,
        actions: [
          // Reset: restores defaults by clearing the draft selection.
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: GestureDetector(
                onTap: _draftKeys.isEmpty ? null : _clearAll,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _draftKeys.isEmpty
                          ? AppColors.borderSubtle
                          : AppColors.sunset,
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Reset',
                    style: AppTextStyles.mono8(
                      color: _draftKeys.isEmpty
                          ? AppColors.textMuted
                          : AppColors.sunset,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.sunset),
            )
          : Column(
              children: [
                // Lens bar: Whole day + one chip per configured period.
                BaselineManagerLensBar(
                  defs: _defs,
                  selectedLensId: _lensId,
                  onLensSelected: (id) => setState(() => _lensId = id),
                ),
                // Summary card scoped to the active lens. The scope tag
                // names the active lens; the metrics are the same
                // existing preview math scoped to that lens (Whole day
                // = cover-weighted rollup READ from existing plumbing).
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _lensScopeLabel,
                      style: AppTextStyles.mono8(color: AppColors.textMuted),
                    ),
                  ),
                ),
                PreviewPanel(
                  selected: lensSelected,
                  historicalWeeklyAvgCovers: _demandWeeklyAvgCovers,
                ),
                if (!_canCommit && _commitGateChecked)
                  const _CommitDisabledNotice(),
                if (_draftKeys.isNotEmpty) ClearAllBar(onClearAll: _clearAll),
                Expanded(
                  child: _selectedDate != null
                      ? DayDetail(
                          date: _selectedDate!,
                          candidates: _shiftsByDate[_selectedDate!] ?? [],
                          draftKeys: _draftKeys,
                          onToggle: _toggle,
                          onBack: () => setState(() => _selectedDate = null),
                          defs: _defs,
                        )
                      : CalendarGrid(
                          windowDates: _windowDates,
                          shiftsByDate: _shiftsByDate,
                          draftKeys: _draftKeys,
                          onDateTap: (date) =>
                              setState(() => _selectedDate = date),
                          activeLensId: _lensId,
                          periodIds: _periodIds,
                        ),
                ),
                // Persistent caption near the commit action.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'One override per 60 day cycle',
                      style: AppTextStyles.mono7(color: AppColors.textMuted),
                    ),
                  ),
                ),
                BottomBar(
                  onCancel: _cancel,
                  onDone: _done,
                  doneEnabled: _canCommit || !_commitGateChecked,
                ),
              ],
            ),
    );
  }
}

/// R1: shown above the calendar when the once-per-cycle override is
/// already used (or the cycle is out of window). Plain-English copy,
/// no jargon, surfaced BEFORE the operator builds a selection.
class _CommitDisabledNotice extends StatelessWidget {
  const _CommitDisabledNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 14, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'This 60 day cycle already used its one override. '
              'You can review shifts, but the change cannot be saved '
              'until the next cycle.',
              style: AppTextStyles.mono8(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
