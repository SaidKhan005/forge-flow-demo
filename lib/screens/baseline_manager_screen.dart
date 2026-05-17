// Phase 5.1 — Baseline Manager Screen (contract fix)
// Phase 7.55o.5 — shell / route / state only. Calendar, day detail,
// preview, action bars, and shared helpers now live in
// `screens/baseline_manager/`. Selection semantics, target-cycle
// write path, candidate truth, and preview formulas are unchanged.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/services/baseline_manager_service.dart';
import '../services/demand_forecast_context_service.dart';
import '../services/star_target_selection_write_service.dart';
import '../services/target_cycle_service.dart' show ManagerOverrideDeniedException;
import '../state/active_target_profile_notifier.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../models/baseline_candidate_shift.dart';
import '../theme/app_theme.dart';
import 'baseline_manager/baseline_manager_actions.dart';
import 'baseline_manager/baseline_manager_calendar.dart';
import 'baseline_manager/baseline_manager_day_sheet.dart';
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
      initialDefs = null,
      initialCanOverride = null;

  /// Test-only constructor: skips async DB load and uses the supplied list.
  /// [initialDemandCovers] bypasses the async demand context load for tests.
  /// [initialDefs] injects the resolved operator service-period defs so
  /// tests can exercise 4+ period configs without DB plumbing.
  /// [initialCanOverride] injects the pre-commit once-per-cycle gate
  /// result so tests can exercise the disabled-commit state.
  @visibleForTesting
  const BaselineManagerScreen.withCandidates(
    List<BaselineCandidateShift> candidates, {
    super.key,
    this.initialDemandCovers,
    this.initialDefs,
    this.initialCanOverride,
  }) : initialCandidates = candidates;

  final List<BaselineCandidateShift>? initialCandidates;
  final int? initialDemandCovers;
  final List<ServicePeriodDefinition>? initialDefs;
  final bool? initialCanOverride;

  @override
  State<BaselineManagerScreen> createState() => _BaselineManagerScreenState();
}

class _BaselineManagerScreenState extends State<BaselineManagerScreen> {
  // ── State ──────────────────────────────────────────────────────────────────

  bool _loading = true;
  List<BaselineCandidateShift> _candidates = [];
  late Set<String> _draftKeys;
  int? _demandWeeklyAvgCovers; // from canonical demand context
  Map<String, List<BaselineCandidateShift>> _shiftsByDate = {};
  List<String> _windowDates = [];

  // R1: operator-configured service-period defs (period set, labels,
  // order) resolved once on init. Demo-defs fallback applied in the
  // service layer when no timing config is persisted yet.
  List<ServicePeriodDefinition> _defs =
      ServicePeriodDefinitionResolver.demoDefinitions;

  // R1: active lens. Default "Whole day" (cover-weighted rollup).
  String _selectedLensId = kWholeDayLensId;

  // R1: pre-commit once-per-60-day override gate. Null until resolved;
  // false means the override is used / out of window and commit is
  // disabled BEFORE the operator builds a selection.
  bool? _canOverride;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    if (widget.initialCandidates != null) {
      _candidates = widget.initialCandidates!;
      _draftKeys = _candidates
          .where((c) => c.isSelected)
          .map((c) => c.recordKey)
          .toSet();
      if (widget.initialDefs != null) {
        _defs = widget.initialDefs!;
      }
      _canOverride = widget.initialCanOverride;
      _loading = false;
      _buildCalendarData();
      if (widget.initialDemandCovers != null) {
        _demandWeeklyAvgCovers = widget.initialDemandCovers;
      } else {
        _loadDemandContext();
      }
    } else {
      _loadCandidates();
    }
  }

  Future<void> _loadCandidates() async {
    final defs = await BaselineManagerService.instance.resolveOperatorDefs();
    final candidates = await BaselineManagerService.instance
        .getCandidateShifts();
    final canOverride =
        await BaselineManagerService.instance.canManagerOverrideNow();
    if (!mounted) return;
    setState(() {
      _defs = defs;
      _candidates = candidates;
      _canOverride = canOverride;
      _draftKeys = candidates
          .where((c) => c.isSelected)
          .map((c) => c.recordKey)
          .toSet();
      _loading = false;
      _buildCalendarData();
    });
    await _loadDemandContext();
  }

  Future<void> _loadDemandContext() async {
    final ctx = await DemandForecastContextService.instance.getCurrentContext();
    if (!mounted) return;
    setState(() {
      _demandWeeklyAvgCovers = ctx.historicalWeeklyAvgCovers;
    });
  }

  // ── Calendar data ──────────────────────────────────────────────────────────

  void _buildCalendarData() {
    _shiftsByDate = {};
    _windowDates = [];

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
    // service-period definition order (resolved on init), never a
    // hardcoded daypart list.
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

  /// R2: tapping a calendar day opens an in-place bottom sheet (no
  /// route push). The sheet toggles selections through [_toggle] only;
  /// nothing is persisted or recomputed here. The wage authority passed
  /// in is the WHOLE-DAY profile wage pair (one pair, never per-period),
  /// read from the same `ActiveTargetProfileNotifier` the preview uses;
  /// when no profile is in scope the rollup labor % degrades to an
  /// honest unknown instead of a config-default guess.
  Future<void> _openDaySheet(String date) async {
    final profile = context.read<ActiveTargetProfileNotifier?>()?.profile;
    await showBaselineDayBottomSheet(
      context: context,
      date: date,
      dayShifts: _shiftsByDate[date] ?? const <BaselineCandidateShift>[],
      selectedLensId: _selectedLensId,
      defs: _defs,
      isSelected: (recordKey) => _draftKeys.contains(recordKey),
      onToggle: _toggle,
      fohWage: profile?.fohWage,
      bohWage: profile?.bohWage,
    );
  }

  List<BaselineCandidateShift> get _draftSelected =>
      _candidates.where((c) => _draftKeys.contains(c.recordKey)).toList();

  /// R1: the selected shifts the summary/preview region renders, scoped
  /// to match the active lens so the summary re-scopes together with the
  /// calendar. "Whole day" = every selected shift (the cover-weighted
  /// rollup the existing preview plumbing already produces); a period
  /// lens = only that period's selected shifts. No recomputation of
  /// whole-day truth here. This only filters the input list the
  /// existing preview already consumed.
  List<BaselineCandidateShift> get _lensScopedSelected {
    final selected = _draftSelected;
    if (_selectedLensId == kWholeDayLensId) return selected;
    return selected.where((c) => c.daypart == _selectedLensId).toList();
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
    // user sees why nothing landed.
    try {
      await BaselineManagerService.instance.saveSelection(_draftKeys);
    } on ManagerOverrideDeniedException catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Manager override already used for this 60-day cycle. '
            'Use Settings → Reset Target Cycle (Admin) to test again.',
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
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.sunset),
            )
          : Column(
              children: [
                // R1: the lens selector re-scopes the calendar AND the
                // summary/preview region together. The lens, gate
                // notice, scope tag, summary, and clear-all share one
                // compact scroll-tolerant band (capped flex) so the
                // calendar below stays the dominant hero element and the
                // body never overflows on short viewports.
                Flexible(
                  flex: 2,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        BaselineManagerLensBar(
                          defs: _defs,
                          selectedLensId: _selectedLensId,
                          onLensSelected: (id) =>
                              setState(() => _selectedLensId = id),
                        ),
                        if (_canOverride == false)
                          const _OverrideUsedNotice(),
                        BaselineManagerScopeTag(
                          defs: _defs,
                          selectedLensId: _selectedLensId,
                        ),
                        PreviewPanel(
                          selected: _lensScopedSelected,
                          historicalWeeklyAvgCovers: _demandWeeklyAvgCovers,
                        ),
                        if (_draftKeys.isNotEmpty)
                          ClearAllBar(onClearAll: _clearAll),
                      ],
                    ),
                  ),
                ),
                // Calendar is the dominant hero element of the screen:
                // it gets the larger flex share of the body. R2: tapping
                // a day opens an in-place bottom sheet rather than
                // swapping the body for a full-screen day detail.
                Expanded(
                  flex: 3,
                  child: CalendarGrid(
                    windowDates: _windowDates,
                    shiftsByDate: _shiftsByDate,
                    draftKeys: _draftKeys,
                    activeLensId: _selectedLensId,
                    defs: _defs,
                    onDateTap: _openDaySheet,
                  ),
                ),
                BottomBar(
                  onCancel: _cancel,
                  onDone: _done,
                  commitEnabled: _canOverride != false,
                ),
              ],
            ),
    );
  }
}

/// R1 pre-commit gate notice. Shown BEFORE the operator builds a
/// selection when the once-per-60-day override is already used or the
/// active cycle is out of window, so nobody builds a selection that
/// cannot land. Plain English, no dashes.
class _OverrideUsedNotice extends StatelessWidget {
  const _OverrideUsedNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('override_used_notice'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border.all(color: AppColors.borderStrong, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'You get one override per 60 day cycle, and this cycle already '
        'used it. You can look at past shifts, but you cannot change the '
        'targets until the next cycle. An admin can reset it for testing.',
        style: AppTextStyles.mono8(color: AppColors.textMuted),
      ),
    );
  }
}
