// Phase 5.1 — Baseline Manager Screen (contract fix)
// Phase 7.55o.5 — shell / route / state only. Calendar, day detail,
// preview, action bars, and shared helpers now live in
// `screens/baseline_manager/`. Selection semantics, target-cycle
// write path, candidate truth, and preview formulas are unchanged.

import 'package:flutter/material.dart';

import '../data/baseline_manager_service.dart';
import '../data/demand_forecast_context_service.dart';
import '../data/target_cycle_service.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../models/baseline_candidate_shift.dart';
import '../theme/app_theme.dart';
import 'baseline_manager/baseline_manager_actions.dart';
import 'baseline_manager/baseline_manager_calendar.dart';
import 'baseline_manager/baseline_manager_day_detail.dart';
import 'baseline_manager/baseline_manager_helpers.dart';
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
        initialDemandCovers = null;

  /// Test-only constructor: skips async DB load and uses the supplied list.
  /// [initialDemandCovers] bypasses the async demand context load for tests.
  @visibleForTesting
  const BaselineManagerScreen.withCandidates(
    List<BaselineCandidateShift> candidates, {
    super.key,
    this.initialDemandCovers,
  }) : initialCandidates = candidates;

  final List<BaselineCandidateShift>? initialCandidates;
  final int? initialDemandCovers;

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
    final candidates =
        await BaselineManagerService.instance.getCandidateShifts();
    if (!mounted) return;
    setState(() {
      _candidates = candidates;
      _draftKeys =
          candidates.where((c) => c.isSelected).map((c) => c.recordKey).toSet();
      _loading = false;
      _buildCalendarData();
    });
    await _loadDemandContext();
  }

  Future<void> _loadDemandContext() async {
    final ctx =
        await DemandForecastContextService.instance.getCurrentContext();
    if (!mounted) return;
    setState(() {
      _demandWeeklyAvgCovers = ctx.historicalWeeklyAvgCovers;
    });
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
      return formatIsoDate(
          DateTime(start.year, start.month, start.day + i));
    });

    // Sort candidates within each date by service-period definition order
    const defs = ServicePeriodDefinitionResolver.demoDefinitions;
    for (final list in _shiftsByDate.values) {
      list.sort((a, b) =>
          ServicePeriodDefinitionResolver.sortIndex(defs, a.daypart)
              .compareTo(ServicePeriodDefinitionResolver.sortIndex(defs, b.daypart)));
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

  List<BaselineCandidateShift> get _draftSelected =>
      _candidates.where((c) => _draftKeys.contains(c.recordKey)).toList();

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
    }
    if (!mounted) return;
    Navigator.of(context).pop();
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
          icon: const Icon(Icons.arrow_back_ios,
              size: 18, color: AppColors.textMuted),
          onPressed: _cancel,
        ),
        title: Text('Choose Star Shifts', style: AppTextStyles.mono11()),
        centerTitle: false,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.sunset))
          : Column(
              children: [
                PreviewPanel(
                  selected: _draftSelected,
                  historicalWeeklyAvgCovers: _demandWeeklyAvgCovers,
                ),
                if (_draftKeys.isNotEmpty)
                  ClearAllBar(onClearAll: _clearAll),
                Expanded(
                  child: _selectedDate != null
                      ? DayDetail(
                          date: _selectedDate!,
                          candidates:
                              _shiftsByDate[_selectedDate!] ?? [],
                          draftKeys: _draftKeys,
                          onToggle: _toggle,
                          onBack: () =>
                              setState(() => _selectedDate = null),
                        )
                      : CalendarGrid(
                          windowDates: _windowDates,
                          shiftsByDate: _shiftsByDate,
                          draftKeys: _draftKeys,
                          onDateTap: (date) =>
                              setState(() => _selectedDate = date),
                        ),
                ),
                BottomBar(
                  onCancel: _cancel,
                  onDone: _done,
                ),
              ],
            ),
    );
  }
}
