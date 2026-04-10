// Phase 5.1 — Baseline Manager Screen (contract fix)
// Manager inspects historical closed shifts, toggles star selections,
// previews the full draft target, then commits or discards.
// Phase 7.55d.3 — Plan impact preview: shows downstream SchedulePlan
// impact (forecast covers/sales, required hours, labor %, blended wage)
// before the manager commits.
// Phase 7.55f.3 — Calendar navigation: 60-day calendar grid replaces
// the flat daypart list. Tap a date to see that day's closed shifts.

import 'package:flutter/material.dart';
import '../data/baseline_manager_service.dart';
import '../data/legacy_fixture_data.dart';
import '../domain/services/schedule_forecast_demand_resolver.dart';
import '../domain/services/schedule_plan_resolver.dart';
import '../models/baseline_candidate_shift.dart';
import '../theme/app_theme.dart';

// ─── Date helpers ─────────────────────────────────────────────────────────────

DateTime _parseIsoDate(String iso) {
  final p = iso.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

String _formatIsoDate(DateTime dt) {
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}'
      '-${dt.day.toString().padLeft(2, '0')}';
}

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _formatDisplayDate(String iso) {
  final dt = _parseIsoDate(iso);
  return '${_monthNames[dt.month - 1]} ${dt.day}';
}

String _formatDayDetailDate(String iso) {
  final dt = _parseIsoDate(iso);
  return '${_weekdayNames[dt.weekday - 1]}, ${_monthNames[dt.month - 1]} ${dt.day}';
}

// ─── Suggested star shift helper ──────────────────────────────────────────────
// A candidate is "suggested" when its lever signal is favorable.
// Uses the canonical LeverCards lookup — no new scoring model.

bool _isSuggestedStar(BaselineCandidateShift c) {
  final card = LeverCards.all.cast<LeverCardData?>().firstWhere(
        (l) => l!.id == c.primaryLeverId,
        orElse: () => null,
      );
  return card != null && card.isFavorable;
}

// ─── Lever label formatter ───────────────────────────────────────────────────
// Reuses canonical LeverCardData.metric for full natural-language lever meaning.
// This preserves direction (e.g. 'CPLH ABOVE TARGET' vs 'CPLH BELOW TARGET')
// instead of collapsing to a generic metric bucket ('CPLH').
// Falls back to title-casing the raw id if no match is found.

String _leverLabel(String leverId) {
  final card = LeverCards.all.cast<LeverCardData?>().firstWhere(
        (l) => l!.id == leverId,
        orElse: () => null,
      );
  if (card != null) return card.metric;
  // Fallback: title-case the snake_case id
  return leverId
      .split('_')
      .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

// ─── Plan impact preview model ───────────────────────────────────────────────
// Computed from the draft selected shifts using SchedulePlanResolver.
// All planning math flows through the resolver — no duplicate formulas.

class ManagerOverridePlanPreview {
  final int forecastCovers;
  final String coversSourceLabel;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  final double theoreticalLaborPct;
  final double targetBlendedWage;

  const ManagerOverridePlanPreview({
    required this.forecastCovers,
    required this.coversSourceLabel,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalLaborPct,
    required this.targetBlendedWage,
  });

  /// Build from the current draft selected shifts.
  /// Returns null when no shifts are selected.
  static ManagerOverridePlanPreview? fromDraftSelection(
    List<BaselineCandidateShift> selected,
  ) {
    if (selected.isEmpty) return null;

    final count = selected.length;
    final draftCPLH = selected.fold(0.0, (s, c) => s + c.cplh) / count;
    final draftSPLH = selected.fold(0.0, (s, c) => s + c.splh) / count;
    final draftPPA = selected.fold(0.0, (s, c) => s + c.ppa) / count;

    // Resolve demand — covers from 60-day history, sales derived from PPA.
    final demand = ScheduleForecastDemandResolver.resolve(
      targetPPA: draftPPA,
      historicalWeeklyAvgCovers: BaselineData.historicalWeeklyAvgCovers,
    );

    if (!demand.isAvailable || demand.forecastCovers == null) return null;

    // Build the plan through the canonical resolveFromValues entry point.
    // This avoids constructing a full ActiveTargetProfile.
    final plan = SchedulePlanResolver.resolveFromValues(
      forecastCovers: demand.forecastCovers!,
      targetPPA: draftPPA,
      targetCPLH: draftCPLH,
      targetSPLH: draftSPLH,
      fohWage: MeridianConfig.fohWage,
      bohWage: MeridianConfig.bohWage,
      coversSource: demand.coversSource,
      salesSource: demand.salesSource,
    );

    return ManagerOverridePlanPreview(
      forecastCovers: plan.forecastCovers,
      coversSourceLabel: plan.coversSourceLabel,
      forecastSales: plan.forecastSales,
      requiredFohHours: plan.requiredFohHours,
      requiredBohHours: plan.requiredBohHours,
      theoreticalLaborPct: plan.theoreticalLaborPct,
      targetBlendedWage: plan.targetBlendedWage,
    );
  }
}

class BaselineManagerScreen extends StatefulWidget {
  /// Production constructor — loads candidates from DB on init.
  const BaselineManagerScreen({super.key}) : initialCandidates = null;

  /// Test-only constructor: skips async DB load and uses the supplied list.
  @visibleForTesting
  const BaselineManagerScreen.withCandidates(
    List<BaselineCandidateShift> candidates, {
    super.key,
  }) : initialCandidates = candidates;

  final List<BaselineCandidateShift>? initialCandidates;

  @override
  State<BaselineManagerScreen> createState() => _BaselineManagerScreenState();
}

class _BaselineManagerScreenState extends State<BaselineManagerScreen> {
  // ── State ──────────────────────────────────────────────────────────────────

  bool _loading = true;
  List<BaselineCandidateShift> _candidates = [];
  late Set<String> _draftKeys;
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

    final anchor = _parseIsoDate(anchorDate);
    // Use DateTime constructor (not Duration) to avoid DST day-shift bugs.
    final start = DateTime(anchor.year, anchor.month, anchor.day - 59);

    _windowDates = List.generate(60, (i) {
      return _formatIsoDate(
          DateTime(start.year, start.month, start.day + i));
    });

    // Sort candidates within each date by daypart order
    const dpOrder = <String, int>{
      'lunch': 0,
      'dinner': 1,
      'late_night': 2,
    };
    for (final list in _shiftsByDate.values) {
      list.sort((a, b) =>
          (dpOrder[a.daypart] ?? 99).compareTo(dpOrder[b.daypart] ?? 99));
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
    await BaselineManagerService.instance.saveSelection(_draftKeys);
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
                _PreviewPanel(selected: _draftSelected),
                if (_draftKeys.isNotEmpty)
                  _ClearAllBar(onClearAll: _clearAll),
                Expanded(
                  child: _selectedDate != null
                      ? _DayDetail(
                          date: _selectedDate!,
                          candidates:
                              _shiftsByDate[_selectedDate!] ?? [],
                          draftKeys: _draftKeys,
                          onToggle: _toggle,
                          onBack: () =>
                              setState(() => _selectedDate = null),
                        )
                      : _CalendarGrid(
                          windowDates: _windowDates,
                          shiftsByDate: _shiftsByDate,
                          draftKeys: _draftKeys,
                          onDateTap: (date) =>
                              setState(() => _selectedDate = date),
                        ),
                ),
                _BottomBar(
                  onCancel: _cancel,
                  onDone: _done,
                ),
              ],
            ),
    );
  }
}

// ─── Preview panel ─────────────────────────────────────────────────────────────

class _PreviewPanel extends StatelessWidget {
  final List<BaselineCandidateShift> selected;

  const _PreviewPanel({required this.selected});

  @override
  Widget build(BuildContext context) {
    final count = selected.length;
    final hasData = count > 0;

    final cplh = hasData
        ? (selected.fold(0.0, (s, c) => s + c.cplh) / count)
            .toStringAsFixed(1)
        : '--';
    final splh = hasData
        ? (selected.fold(0.0, (s, c) => s + c.splh) / count)
            .toStringAsFixed(0)
        : '--';
    final ppa = hasData
        ? (selected.fold(0.0, (s, c) => s + c.ppa) / count)
            .toStringAsFixed(0)
        : '--';
    final floor = hasData
        ? selected
            .map((c) => c.cplh)
            .reduce((a, b) => a < b ? a : b)
            .toStringAsFixed(1)
        : '--';
    final ceil = hasData
        ? selected
            .map((c) => c.cplh)
            .reduce((a, b) => a > b ? a : b)
            .toStringAsFixed(1)
        : '--';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.backgroundDeep],
        ),
        border: Border.all(color: AppColors.borderStrong, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: SELECTED SHIFTS · TARGET CPLH
          Row(
            children: [
              Expanded(
                child: _PreviewCell(
                  label: 'SELECTED SHIFTS',
                  value: '$count',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(
                  label: 'TARGET CPLH',
                  value: cplh,
                  highlight: hasData,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 2: TARGET SPLH · TARGET PPA
          Row(
            children: [
              Expanded(
                child: _PreviewCell(label: 'TARGET SPLH', value: splh),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(label: 'TARGET PPA', value: ppa),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 3: OPZ FLOOR · OPZ CEILING
          Row(
            children: [
              Expanded(
                child: _PreviewCell(label: 'OPZ FLOOR', value: floor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(label: 'OPZ CEILING', value: ceil),
              ),
            ],
          ),
          // ── PLAN IMPACT ──────────────────────────────────────────────
          _PlanImpactSection(selected: selected),
        ],
      ),
    );
  }
}

/// Shows downstream SchedulePlan impact from the draft target profile.
/// When no shifts are selected all cells show "--".
class _PlanImpactSection extends StatelessWidget {
  final List<BaselineCandidateShift> selected;

  const _PlanImpactSection({required this.selected});

  @override
  Widget build(BuildContext context) {
    final preview = ManagerOverridePlanPreview.fromDraftSelection(selected);
    final hasData = preview != null;

    final fcCovers = hasData ? '${preview.forecastCovers}' : '--';
    final fcSales = hasData
        ? '\$${preview.forecastSales.toStringAsFixed(0)}'
        : '--';
    final fohHrs = hasData ? '${preview.requiredFohHours}' : '--';
    final bohHrs = hasData ? '${preview.requiredBohHours}' : '--';
    final laborPct = hasData
        ? '${preview.theoreticalLaborPct.toStringAsFixed(1)}%'
        : '--';
    final wage = hasData
        ? '\$${preview.targetBlendedWage.toStringAsFixed(2)}'
        : '--';
    final sourceLabel = hasData ? 'Covers source: ${preview.coversSourceLabel}' : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Container(height: 1, color: AppColors.borderSubtle),
        const SizedBox(height: 10),
        Text('PLAN IMPACT',
            style: AppTextStyles.mono7(color: AppColors.textMuted)),
        const SizedBox(height: 8),
        // Row 4: FORECAST COVERS · FORECAST SALES
        Row(
          children: [
            Expanded(
              child: _PreviewCell(label: 'FORECAST COVERS', value: fcCovers),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PreviewCell(label: 'FORECAST SALES', value: fcSales),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Row 5: FOH HRS · BOH HRS
        Row(
          children: [
            Expanded(
              child: _PreviewCell(label: 'FOH HRS', value: fohHrs),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PreviewCell(label: 'BOH HRS', value: bohHrs),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Row 6: LABOR % · BLENDED WAGE
        Row(
          children: [
            Expanded(
              child: _PreviewCell(label: 'LABOR %', value: laborPct),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PreviewCell(label: 'BLENDED WAGE', value: wage),
            ),
          ],
        ),
        if (sourceLabel.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(sourceLabel,
              style: AppTextStyles.mono7(color: AppColors.textMuted)),
        ],
      ],
    );
  }
}

class _PreviewCell extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _PreviewCell({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppTextStyles.mono7(color: AppColors.textMuted)),
        const SizedBox(height: 3),
        Text(
          value,
          style: AppTextStyles.mono14(
            color: highlight ? AppColors.sunsetDark : AppColors.textSecondary,
            weight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ─── Calendar grid (60-day window) ────────────────────────────────────────────

class _CalendarGrid extends StatelessWidget {
  final List<String> windowDates;
  final Map<String, List<BaselineCandidateShift>> shiftsByDate;
  final Set<String> draftKeys;
  final ValueChanged<String> onDateTap;

  const _CalendarGrid({
    required this.windowDates,
    required this.shiftsByDate,
    required this.draftKeys,
    required this.onDateTap,
  });

  @override
  Widget build(BuildContext context) {
    if (windowDates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No closed shifts found.\nClose some shifts to build your baseline.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),
        ),
      );
    }

    final startDt = _parseIsoDate(windowDates.first);
    final endDt = _parseIsoDate(windowDates.last);

    // Pad to full weeks (Monday-Sunday). Use DateTime constructor to
    // avoid DST day-shift bugs on Duration arithmetic.
    final mondayOffset = (startDt.weekday - 1) % 7;
    final gridStart = DateTime(
        startDt.year, startDt.month, startDt.day - mondayOffset);
    final sundayOffset = (7 - endDt.weekday) % 7;
    final gridEnd = DateTime(
        endDt.year, endDt.month, endDt.day + sundayOffset);
    // Build every date in the padded grid using constructor-based stepping
    // only — no Duration arithmetic — so DST boundaries never shift a cell.
    final gridDates = <DateTime>[];
    {
      var d = gridStart;
      while (!d.isAfter(gridEnd)) {
        gridDates.add(d);
        d = DateTime(d.year, d.month, d.day + 1);
      }
    }

    final windowSet = windowDates.toSet();

    // Build rows: month labels + week rows
    final rows = <Widget>[];
    int? prevMonth;

    for (int weekStart = 0; weekStart < gridDates.length; weekStart += 7) {
      // Find first in-window date in this week for month labelling
      for (int j = 0; j < 7 && weekStart + j < gridDates.length; j++) {
        final dt = gridDates[weekStart + j];
        if (!windowSet.contains(_formatIsoDate(dt))) continue;
        if (dt.month != prevMonth) {
          rows.add(Padding(
            padding: EdgeInsets.fromLTRB(0, prevMonth == null ? 0 : 8, 0, 4),
            child: Text(
              '${_monthNames[dt.month - 1].toUpperCase()} ${dt.year}',
              style: AppTextStyles.mono8(color: AppColors.textMuted),
            ),
          ));
          prevMonth = dt.month;
        }
        break;
      }

      // Build one week row (7 cells)
      final cells = <Widget>[];
      for (int j = 0; j < 7; j++) {
        final dayIndex = weekStart + j;
        if (dayIndex >= gridDates.length) {
          cells.add(const Expanded(child: SizedBox(height: 38)));
          continue;
        }

        final dt = gridDates[dayIndex];
        final dateStr = _formatIsoDate(dt);
        final inWindow = windowSet.contains(dateStr);

        if (!inWindow) {
          cells.add(const Expanded(child: SizedBox(height: 38)));
          continue;
        }

        final shifts = shiftsByDate[dateStr] ?? [];
        final hasShifts = shifts.isNotEmpty;
        final hasSelected =
            shifts.any((c) => draftKeys.contains(c.recordKey));
        final hasSuggested =
            shifts.any(_isSuggestedStar);

        // Visual priority: selected > suggested > available
        final Color cellBg;
        final Color cellBorder;
        final Color dotColor;
        if (hasSelected) {
          cellBg = AppColors.sunset.withValues(alpha: 0.15);
          cellBorder = AppColors.sunset.withValues(alpha: 0.5);
          dotColor = AppColors.sunset;
        } else if (hasSuggested) {
          cellBg = AppColors.jade.withValues(alpha: 0.12);
          cellBorder = AppColors.jade.withValues(alpha: 0.5);
          dotColor = AppColors.peacock;
        } else if (hasShifts) {
          cellBg = AppColors.backgroundMid;
          cellBorder = AppColors.borderSubtle;
          dotColor = AppColors.textMuted;
        } else {
          cellBg = Colors.transparent;
          cellBorder = Colors.transparent;
          dotColor = Colors.transparent;
        }

        cells.add(Expanded(
          child: GestureDetector(
            key: ValueKey<String>('cal_$dateStr'),
            onTap: () => onDateTap(dateStr),
            child: Container(
              height: 38,
              margin: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                color: cellBg,
                border: Border.all(color: cellBorder, width: 1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${dt.day}',
                    style: AppTextStyles.mono10(
                      color: hasShifts
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
                  ),
                  if (hasShifts)
                    Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.only(top: 2),
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ));
      }

      rows.add(Row(children: cells));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text('LAST 60 DAYS',
              style: AppTextStyles.mono11(color: AppColors.textMuted)),
          const SizedBox(height: 4),
          Text(
            '${_formatDisplayDate(windowDates.first)} – '
            '${_formatDisplayDate(windowDates.last)}',
            style: AppTextStyles.mono8(color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          // Legend
          Row(
            children: [
              _LegendDot(color: AppColors.textMuted, label: 'Closed shifts'),
              const SizedBox(width: 12),
              _LegendDot(color: AppColors.peacock, label: 'Suggested star'),
              const SizedBox(width: 12),
              _LegendDot(color: AppColors.sunset, label: 'Selected star'),
            ],
          ),
          const SizedBox(height: 8),
          // Weekday labels
          Row(
            children: ['M', 'T', 'W', 'T', 'F', 'S', 'S']
                .map((d) => Expanded(
                      child: Center(
                        child: Text(d,
                            style: AppTextStyles.mono8(
                                color: AppColors.textMuted)),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 4),
          // Calendar rows
          ...rows,
        ],
      ),
    );
  }
}

// ─── Day detail (single date) ─────────────────────────────────────────────────

class _DayDetail extends StatelessWidget {
  final String date;
  final List<BaselineCandidateShift> candidates;
  final Set<String> draftKeys;
  final ValueChanged<String> onToggle;
  final VoidCallback onBack;

  const _DayDetail({
    required this.date,
    required this.candidates,
    required this.draftKeys,
    required this.onToggle,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Back control
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: GestureDetector(
            onTap: onBack,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.arrow_back_ios,
                    size: 12, color: AppColors.textMuted),
                const SizedBox(width: 4),
                Text('BACK TO CALENDAR',
                    style: AppTextStyles.mono8(color: AppColors.textMuted)),
              ],
            ),
          ),
        ),
        // Date label
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            _formatDayDetailDate(date),
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
        ),
        // Candidate list or empty state
        Expanded(
          child: candidates.isEmpty
              ? Center(
                  child: Text(
                    'No closed shifts for this date.',
                    style: AppTextStyles.body13(color: AppColors.textMuted),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildDaypartSections(),
                  ),
                ),
        ),
      ],
    );
  }

  List<Widget> _buildDaypartSections() {
    final groups = <String, List<BaselineCandidateShift>>{};
    for (final c in candidates) {
      groups.putIfAbsent(c.daypart, () => []).add(c);
    }

    const order = ['lunch', 'dinner', 'late_night'];
    final items = <Widget>[];

    for (final dp in order) {
      final group = groups[dp];
      if (group == null || group.isEmpty) continue;
      items.add(_daypartHeader(group.first.daypartLabel));
      for (final c in group) {
        items.add(_CandidateTile(
          candidate: c,
          isSelected: draftKeys.contains(c.recordKey),
          onToggle: () => onToggle(c.recordKey),
        ));
      }
    }

    // Unknown dayparts after known ones
    for (final entry in groups.entries) {
      if (order.contains(entry.key)) continue;
      items.add(_daypartHeader(entry.key));
      for (final c in entry.value) {
        items.add(_CandidateTile(
          candidate: c,
          isSelected: draftKeys.contains(c.recordKey),
          onToggle: () => onToggle(c.recordKey),
        ));
      }
    }

    return items;
  }

  static Widget _daypartHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Text(label.toUpperCase(),
              style: AppTextStyles.mono11(color: AppColors.textMuted)),
          const SizedBox(width: 12),
          Expanded(
            child: Container(height: 1, color: AppColors.borderSubtle),
          ),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  final BaselineCandidateShift candidate;
  final bool isSelected;
  final VoidCallback onToggle;

  const _CandidateTile({
    required this.candidate,
    required this.isSelected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected
        ? AppColors.sunset.withValues(alpha: 0.7)
        : AppColors.borderSubtle;
    final bgColor = isSelected
        ? AppColors.sunset.withValues(alpha: 0.07)
        : Colors.transparent;

    return GestureDetector(
      onTap: onToggle,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          children: [
            // Selection indicator
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color:
                    isSelected ? AppColors.sunset : Colors.transparent,
                border: Border.all(
                  color: isSelected
                      ? AppColors.sunset
                      : AppColors.textMuted,
                  width: 1.5,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check,
                      size: 12, color: AppColors.backgroundDeep)
                  : null,
            ),
            const SizedBox(width: 12),

            // Label + metrics
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    candidate.businessDate != null
                        ? '${_formatDayDetailDate(candidate.businessDate!)} ${candidate.daypartLabel}'
                        : candidate.displayLabel,
                    style: AppTextStyles.mono10(
                        color: isSelected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary),
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _MetricChip(
                        label: 'CPLH',
                        value: candidate.cplh.toStringAsFixed(2),
                        highlight: isSelected,
                      ),
                      _MetricChip(
                        label: 'COVERS',
                        value: '${candidate.covers}',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'SPLH',
                        value: '\$${candidate.splh.toStringAsFixed(0)}',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'PPA',
                        value: '\$${candidate.ppa.toStringAsFixed(0)}',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'LABOR %',
                        value: '${candidate.actualLaborPct.toStringAsFixed(1)}%',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'LEVER',
                        value: _leverLabel(candidate.primaryLeverId),
                        highlight: false,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _MetricChip({
    required this.label,
    required this.value,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: AppTextStyles.mono7(color: AppColors.textMuted)),
        Text(
          value,
          style: AppTextStyles.mono10(
              color:
                  highlight ? AppColors.sunsetDark : AppColors.textSecondary),
        ),
      ],
    );
  }
}

// ─── Legend dot ───────────────────────────────────────────────────────────────

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: AppTextStyles.mono7(color: AppColors.textMuted)),
      ],
    );
  }
}

// ─── Clear All bar ────────────────────────────────────────────────────────────

class _ClearAllBar extends StatelessWidget {
  final VoidCallback onClearAll;

  const _ClearAllBar({required this.onClearAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          onTap: onClearAll,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.sunset, width: 1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'CLEAR ALL',
              style: AppTextStyles.mono8(color: AppColors.sunset),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Bottom action bar ─────────────────────────────────────────────────────────

class _BottomBar extends StatelessWidget {
  final VoidCallback onCancel;
  final Future<void> Function() onDone;

  const _BottomBar({
    required this.onCancel,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border(
          top: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        children: [
          // Cancel
          Expanded(
            child: GestureDetector(
              onTap: onCancel,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  border:
                      Border.all(color: AppColors.borderSubtle, width: 1),
                ),
                alignment: Alignment.center,
                child: Text('CANCEL',
                    style: AppTextStyles.mono8(color: AppColors.textMuted)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Done — always enabled; empty draft clears the override
          Expanded(
            flex: 2,
            child: GestureDetector(
              onTap: onDone,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: const BoxDecoration(
                  color: AppColors.sunset,
                ),
                alignment: Alignment.center,
                child: Text(
                  'DONE',
                  style: AppTextStyles.mono8(
                      color: AppColors.backgroundDeep),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
