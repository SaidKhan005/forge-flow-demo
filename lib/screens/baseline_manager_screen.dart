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
import 'baseline_manager/baseline_manager_band.dart';
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

  // R10: per-service-period band map keyed by service-period id (from
  // the resolved operator defs via ServicePeriodDefinitionResolver).
  // Every configured period defaults to StarBand.balanced on init
  // (preserving the R8 "opens populated" behaviour). This is EPHEMERAL
  // UI state: it only drives the in-memory draft derivation. Nothing
  // about it is persisted, there is no new column / table / field, and
  // it never reaches the write path. The selected record keys remain
  // the sole persisted source of truth (saveSelection, on DONE only).
  // null entry / hand-tweak drops the highlight for that period (the
  // selection itself stays).
  Map<String, StarBand?> _bandByPeriod = {};

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
      if (widget.initialDefs != null) {
        _defs = widget.initialDefs!;
      }
      _draftKeys = _initialDraftKeys();
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
      _draftKeys = _initialDraftKeys();
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

  /// R10: the default per-period band map. EVERY operator-configured
  /// service period (from the resolved defs, never a hardcoded daypart
  /// list) starts at [StarBand.balanced]. Ephemeral UI state only; not
  /// persisted, no new column / table / field.
  Map<String, StarBand?> _defaultBandByPeriod() {
    return {
      for (final d in ServicePeriodDefinitionResolver.ordered(_defs))
        d.id: StarBand.balanced,
    };
  }

  /// R8/R10: the screen OPENS POPULATED. On load every operator-
  /// configured service period defaults to [StarBand.balanced] in the
  /// per-period band map and the union of each period's strongest N is
  /// applied to the in-memory draft, so SELECTED count / targets / OPZ
  /// floor+ceiling / preview render populated on entry (matching the
  /// committed prototype, which calls `applyBand('bal')` on reset).
  ///
  /// This is a CLIENT-SIDE DRAFT DEFAULT ONLY. It mutates nothing but
  /// the in-memory `Set<String>` draft and the ephemeral per-period
  /// `_bandByPeriod` highlight map. Nothing is persisted:
  /// `BaselineManagerService.saveSelection` is still only called from
  /// [_done] when the operator taps the action. The operator can still
  /// switch band per daypart, hand-tweak, or Clear (which empties the
  /// draft).
  ///
  /// Falls back to the previously-selected candidate keys when no
  /// candidate has a service period the band can rank (defensive: keeps
  /// the screen honest rather than silently empty).
  Set<String> _initialDraftKeys() {
    _bandByPeriod = _defaultBandByPeriod();
    final derived = derivePerPeriodBandSelection(
      _candidates,
      _defs,
      _resolvedBandByPeriod(),
    );
    if (derived.isEmpty) {
      // Defensive: no candidate has a period the band can rank. Keep the
      // screen honest with the previously-selected keys rather than
      // silently empty, and drop the per-period highlights.
      _bandByPeriod = {
        for (final id in _bandByPeriod.keys) id: null,
      };
      return _candidates
          .where((c) => c.isSelected)
          .map((c) => c.recordKey)
          .toSet();
    }
    return derived;
  }

  /// R10: the band map narrowed to non-null entries, ready for the pure
  /// per-period derivation. A null entry (period hand-tweaked or never
  /// banded) defaults to Balanced for derivation purposes only; the
  /// highlight stays off because the stored value is null.
  Map<String, StarBand> _resolvedBandByPeriod() {
    return {
      for (final entry in _bandByPeriod.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
  }

  /// R10: the band the Lean / Balanced / Generous control highlights for
  /// the active lens. A specific daypart shows THAT daypart's own band.
  /// Whole day shows the common band only when every configured period
  /// shares it (so a uniform state still highlights), else null.
  StarBand? _activeLensBand() {
    if (_selectedLensId != kWholeDayLensId) {
      return _bandByPeriod[_selectedLensId];
    }
    final values = _bandByPeriod.values.toSet();
    if (values.length == 1) return values.first;
    return null;
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
      // A hand-tweak means the selection no longer exactly matches a
      // band. Drop the highlight for the affected period (the selection
      // itself stays). On the whole-day lens a tweak can touch any
      // period, so drop every highlight.
      _dropBandHighlight();
    });
  }

  /// R10: clears the per-period band highlight(s) without changing the
  /// draft selection. Scoped to the active lens: a daypart lens clears
  /// only that daypart's highlight; whole day clears them all.
  void _dropBandHighlight() {
    if (_selectedLensId != kWholeDayLensId &&
        _bandByPeriod.containsKey(_selectedLensId)) {
      _bandByPeriod[_selectedLensId] = null;
    } else {
      _bandByPeriod = {for (final id in _bandByPeriod.keys) id: null};
    }
  }

  void _clearAll() {
    setState(() {
      _draftKeys.clear();
      _bandByPeriod = {for (final id in _bandByPeriod.keys) id: null};
    });
  }

  /// R8: the app-bar RESET pill. Restores the default Balanced band
  /// selection (the same client-side default applied on open) and
  /// re-scopes back to the whole-day lens. Mutates only the in-memory
  /// draft / lens / band-highlight state. Nothing is persisted: commit
  /// still flows through the unchanged `saveSelection` on Done.
  void _resetToDefault() {
    setState(() {
      _selectedLensId = kWholeDayLensId;
      _draftKeys = _initialDraftKeys();
    });
  }

  /// R10: applying a band updates the PER-PERIOD band map then RE-DERIVES
  /// the draft from the union over every configured period of that
  /// period's strongest N (N per that period's own tier). Behaviour
  /// depends on the active lens:
  ///
  ///  - A specific daypart lens: set ONLY that daypart's band. Each
  ///    daypart remembers its own, so the operator can mix and match.
  ///  - The whole-day lens: a BULK OVERRIDE that sets EVERY configured
  ///    period's band to the chosen value (operator-confirmed: whole day
  ///    sets all, then they can open individual dayparts to mix).
  ///
  /// This ONLY mutates the in-memory draft + the ephemeral band map; the
  /// operator can still hand-tweak afterwards and commit still flows
  /// through the unchanged `BaselineManagerService.saveSelection` on
  /// DONE. No persistence, no parallel target stack, no new column.
  void _applyBand(StarBand band) {
    setState(() {
      if (_selectedLensId == kWholeDayLensId) {
        _bandByPeriod = {for (final id in _bandByPeriod.keys) id: band};
      } else {
        _bandByPeriod[_selectedLensId] = band;
      }
      _draftKeys = derivePerPeriodBandSelection(
        _candidates,
        _defs,
        _resolvedBandByPeriod(),
      );
    });
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
        actions: [
          // R8: RESET pill, top-right, matching the prototype. Tapping
          // it restores the default Balanced band selection in the
          // in-memory draft only (same client-side default applied on
          // open). It never persists anything; commit still flows
          // through the unchanged save path on Done.
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: _resetToDefault,
              child: Container(
                key: const ValueKey<String>('reset_pill'),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.backgroundMid,
                  border: Border.all(color: AppColors.sunset, width: 1.5),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'RESET',
                  style: AppTextStyles.mono8(color: AppColors.sunsetDark),
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
                // R9: ONE single continuous scroll region, matching the
                // committed prototype's `.scl` element. The fixed app bar
                // (title + RESET) stays above and the fixed bottom action
                // bar (CANCEL / DONE + the once-per-cycle caption) stays
                // below; EVERYTHING between them (lens, gate notice,
                // scope tag, summary card with the collapsible PLAN
                // IMPACT dropdown, STAR SHIFT SELECTION band, the LAST 60
                // DAYS header + legend + count caption + calendar grid)
                // lives in ONE scroll and scrolls as a single page. The
                // calendar is no longer its own scroller and is no longer
                // wrapped in Expanded/Flexible: it lays out at intrinsic
                // height inside this one scroll so the page owns all
                // scrolling and there are no nested scroll conflicts.
                Expanded(
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
                        // R8: prototype order is summary/preview card
                        // FIRST, then the STAR SHIFT SELECTION band, then
                        // the calendar. The band derivation and per-period
                        // preview behaviour from R3 are unchanged; only
                        // the placement and the section label move.
                        PreviewPanel(
                          selected: _lensScopedSelected,
                          historicalWeeklyAvgCovers: _demandWeeklyAvgCovers,
                          selectedLensId: _selectedLensId,
                        ),
                        // R10: the control reflects/sets the band for the
                        // ACTIVE lens. A daypart lens shows + sets only
                        // that daypart's band; whole day shows the common
                        // band (when uniform) and a pick is a bulk
                        // override across every configured period.
                        BaselineManagerBandSelector(
                          selectedBand: _activeLensBand(),
                          onBandSelected: _applyBand,
                        ),
                        if (_draftKeys.isNotEmpty)
                          ClearAllBar(onClearAll: _clearAll),
                        // R9: calendar renders at its full natural
                        // height inside the single page scroll (it is
                        // NOT its own scrollable and NOT in
                        // Expanded/Flexible). R2: tapping a day opens an
                        // in-place bottom sheet.
                        CalendarGrid(
                          windowDates: _windowDates,
                          shiftsByDate: _shiftsByDate,
                          draftKeys: _draftKeys,
                          activeLensId: _selectedLensId,
                          defs: _defs,
                          onDateTap: _openDaySheet,
                        ),
                      ],
                    ),
                  ),
                ),
                BottomBar(
                  onCancel: _cancel,
                  onDone: _done,
                  commitEnabled: _canOverride != false,
                  draftCount: _draftKeys.length,
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
