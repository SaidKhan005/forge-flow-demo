import 'package:flutter/material.dart';
import '../domain/constants/app_defaults.dart';
import '../dev/mock_integration_replay_seed.dart';
import '../models/data_alignment_audit_check.dart';
import '../models/data_alignment_audit_snapshot.dart';
import '../models/data_alignment_drift_check.dart';
import '../services/data_alignment_audit_read_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// Expandable dev-only audit panel for the Settings screen.
///
/// Phase 7.55r item 4 (scope expanded 2026-04-24):
///   - Tier 1 (boundary hygiene): this widget no longer imports SQLite
///     repositories directly; all diagnostic reads flow through
///     [DataAlignmentAuditReadService].
///   - Tier 2 (drift detection): a DRIFT CHECKS section at the top
///     renders green / red badges flagging cross-section value drift
///     against q-lane conformance Rules 2 and 3 plus wage-authority
///     consistency. Acts as a live regression detector for the q-lane
///     contracts during refactoring work.
///
/// Phase 7.56c.1 (this slice): grouped Plan + Benchmark coverage
/// sections render below the q-lane DRIFT CHECKS section and answer
///   1. Where did the live / actual value come from?
///   2. Where did the target / comparison value come from?
/// Each group header counts aligned / drifted / unavailable checks.
///
/// Not shown to real operators — developer Settings surface only.
class DataAlignmentAuditPanel extends StatefulWidget {
  const DataAlignmentAuditPanel({super.key});

  @override
  State<DataAlignmentAuditPanel> createState() =>
      _DataAlignmentAuditPanelState();
}

class _DataAlignmentAuditPanelState extends State<DataAlignmentAuditPanel> {
  bool _isExpanded = false;
  bool _isLoading = false;

  /// When true, only drifted / unavailable rows are shown and the
  /// purely-informational provenance readouts are collapsed — so a
  /// developer can jump straight to "what is wrong" without scrolling
  /// past the green noise.
  bool _issuesOnly = false;

  /// Complete diagnostic snapshot assembled by
  /// [DataAlignmentAuditReadService].
  DataAlignmentAuditSnapshot? _snapshot;

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      _snapshot =
          await DataAlignmentAuditReadService.instance.loadSnapshot();
    } catch (_) {
      _snapshot = null;
    }
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.backgroundMid,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header — tap to expand/collapse
          InkWell(
            onTap: () {
              setState(() => _isExpanded = !_isExpanded);
              if (_isExpanded && _snapshot == null && !_isLoading) {
                _load();
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Data Alignment Audit',
                      style: AppTextStyles.mono12(color: AppColors.textPrimary),
                    ),
                  ),
                  // Inline verdict chip in the header when loaded.
                  if (_snapshot != null) _headerVerdictChip(_snapshot!),
                  Icon(
                    _isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                ],
              ),
            ),
          ),

          if (_isExpanded) ...[
            if (_isLoading)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Loading...',
                    style: AppTextStyles.mono11(color: AppColors.textMuted)),
              )
            else if (_snapshot == null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Audit could not be loaded.',
                    style: AppTextStyles.mono11(color: AppColors.textMuted)),
              )
            else ...[
              // Plain-language verdict + legend + filter, so the first
              // thing the eye lands on is the answer, not a wall of rows.
              _verdictBanner(_snapshot!),
              _legendAndFilterRow(),

              // ── INTEGRITY ─────────────────────────────────────────
              _categoryHeader('INTEGRITY', Icons.rule_rounded),
              _buildDriftChecksSection(),
              const SizedBox(height: 8),
              _buildAuditChecksSections(),

              // The provenance / readout categories are reference
              // context, not pass/fail — hide them in issues-only mode.
              if (!_issuesOnly) ...[
                // ── PROVENANCE ──────────────────────────────────────
                _categoryHeader('PROVENANCE', Icons.history_rounded),
                _buildLockedWeekProvenanceSection(),

                // ── TARGETS ─────────────────────────────────────────
                _categoryHeader('TARGETS', Icons.track_changes_rounded),
                _buildProfileSection(),
                const SizedBox(height: 8),
                _buildWageAuthoritySection(),

                // ── FORECAST ────────────────────────────────────────
                _categoryHeader('FORECAST', Icons.query_stats_rounded),
                _buildDemandContextSection(),
                const SizedBox(height: 8),
                _buildScheduleSection(),
                const SizedBox(height: 8),
                _buildSchedulePlanSection(),

                // ── LIVE ────────────────────────────────────────────
                _categoryHeader('LIVE', Icons.bolt_rounded),
                _buildShiftSection(),
                const SizedBox(height: 8),
                _buildVarianceSection(),

                // ── REFERENCE ───────────────────────────────────────
                _categoryHeader('REFERENCE', Icons.bookmark_border_rounded),
                _buildDemoSeedSection(),
              ],
              const SizedBox(height: 16),
            ],
          ],
        ],
      ),
    );
  }

  // ─── Verdict, legend, filter ──────────────────────────────────────────────

  /// (aligned, drifted, unavailable) across BOTH the q-lane drift
  /// checks and the 7.56c.1 audit checks — one combined tally so the
  /// verdict speaks for the whole panel.
  ({int aligned, int drifted, int unavailable}) _tally(
      DataAlignmentAuditSnapshot s) {
    int aligned = 0, drifted = 0, unavailable = 0;
    for (final c in [...s.driftChecks]) {
      switch (c.status) {
        case DriftCheckStatus.aligned:
          aligned++;
          break;
        case DriftCheckStatus.drifted:
          drifted++;
          break;
        case DriftCheckStatus.unavailable:
          unavailable++;
          break;
      }
    }
    aligned += s.auditAlignedCount;
    drifted += s.auditDriftedCount;
    unavailable += s.auditUnavailableCount;
    return (aligned: aligned, drifted: drifted, unavailable: unavailable);
  }

  /// Compact verdict chip shown in the collapsed header.
  Widget _headerVerdictChip(DataAlignmentAuditSnapshot s) {
    final t = _tally(s);
    if (t.aligned == 0 && t.drifted == 0 && t.unavailable == 0) {
      return const SizedBox.shrink();
    }
    final color = t.drifted > 0
        ? AppColors.negative
        : (t.unavailable > 0 ? AppColors.textMuted : AppColors.positive);
    final text = t.drifted > 0
        ? '${t.drifted} drifted'
        : (t.unavailable > 0
            ? '${t.aligned} ok · ${t.unavailable} n/a'
            : 'all ${t.aligned} aligned');
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(text, style: AppTextStyles.mono10(color: color)),
    );
  }

  /// Full-width plain-language verdict at the top of the expanded body.
  /// One glance answers "is anything actually wrong?".
  Widget _verdictBanner(DataAlignmentAuditSnapshot s) {
    final t = _tally(s);
    final bool ok = t.drifted == 0;
    final Color color = ok ? AppColors.positive : AppColors.negative;
    final String headline = t.drifted > 0
        ? 'Needs attention: ${t.drifted} value${t.drifted == 1 ? '' : 's'} drifted'
        : 'All ${t.aligned} checked values aligned';
    final String sub = t.unavailable > 0
        ? '${t.unavailable} unavailable. Expected when that data is not present yet (not a failure).'
        : 'Benchmark and Plan targets flow through Shift and Variance with no mismatch.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(ok ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    headline,
                    style: AppTextStyles.mono12(color: color)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sub,
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Legend (what the icons mean) + the issues-only filter toggle.
  Widget _legendAndFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                _legendItem('✓', 'aligned', AppColors.positive),
                _legendItem('⚠', 'drifted', AppColors.negative),
                _legendItem('—', 'unavailable', AppColors.textMuted),
              ],
            ),
          ),
          InkWell(
            onTap: () => setState(() => _issuesOnly = !_issuesOnly),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _issuesOnly
                    ? AppColors.sunset.withValues(alpha: 0.18)
                    : Colors.transparent,
                border: Border.all(
                    color: AppColors.sunset.withValues(alpha: 0.5),
                    width: 1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _issuesOnly
                        ? Icons.filter_alt_rounded
                        : Icons.filter_alt_outlined,
                    size: 13,
                    color: AppColors.sunset,
                  ),
                  const SizedBox(width: 6),
                  Text('Issues only',
                      style: AppTextStyles.mono10(color: AppColors.sunset)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendItem(String glyph, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(glyph, style: AppTextStyles.mono10(color: color)),
        const SizedBox(width: 4),
        Text(label,
            style: AppTextStyles.mono10(color: AppColors.textMuted)),
      ],
    );
  }

  // ─── Sections ──────────────────────────────────────────────────────────────

  Widget _buildDriftChecksSection() {
    final all = _snapshot?.driftChecks ?? const <DataAlignmentDriftCheck>[];
    if (all.isEmpty) {
      return _emptySection('DRIFT CHECKS',
          'No checks available yet (missing authority data)',
          icon: Icons.rule_folder_outlined);
    }
    final drifted = _snapshot!.driftedCount;
    final aligned = _snapshot!.alignedCount;
    final accent = drifted > 0 ? AppColors.negative : AppColors.positive;
    final visible = _issuesOnly
        ? all.where((c) => c.status != DriftCheckStatus.aligned).toList()
        : all;
    // In issues-only mode a clean section collapses out entirely.
    if (_issuesOnly && visible.isEmpty) return const SizedBox.shrink();
    final subtitle = drifted > 0
        ? '$drifted drifted, $aligned aligned'
        : 'all $aligned aligned';
    return _tile(
      icon: Icons.rule_folder_outlined,
      title: 'DRIFT CHECKS',
      subtitle: subtitle,
      accentColor: accent,
      children: visible.map(_driftRow).toList(),
    );
  }

  Widget _driftRow(DataAlignmentDriftCheck c) {
    final Color color;
    final String icon;
    switch (c.status) {
      case DriftCheckStatus.aligned:
        color = AppColors.positive;
        icon = '✓';
        break;
      case DriftCheckStatus.drifted:
        color = AppColors.negative;
        icon = '⚠';
        break;
      case DriftCheckStatus.unavailable:
        color = AppColors.textMuted;
        icon = '—';
        break;
    }

    final expected = c.expectedValue != null
        ? c.expectedValue!.toStringAsFixed(2)
        : '—';
    final compared = c.comparedValue != null
        ? c.comparedValue!.toStringAsFixed(2)
        : '—';
    final valueStr = '$expected / $compared';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: Text(icon,
                style: AppTextStyles.mono12(color: color)),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              c.label,
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              c.ruleReference,
              textAlign: TextAlign.right,
              style: AppTextStyles.mono8(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              valueStr,
              textAlign: TextAlign.right,
              style: AppTextStyles.mono12(color: color),
            ),
          ),
        ],
      ),
    );
  }

  // ─── 7.56c.1 audit-check groups ─────────────────────────────────────────

  /// Renders the grouped audit-check sections (one section per group)
  /// with a header summary showing aligned / drifted / unavailable
  /// counts for each group. Empty when there are no audit checks at
  /// all (e.g. an early load failure).
  Widget _buildAuditChecksSections() {
    final groups = _snapshot?.auditGroups ?? const [];
    if (groups.isEmpty) {
      return _emptySection('AUDIT CHECKS', 'No audit checks available yet',
          icon: Icons.fact_check_outlined);
    }
    final overall = _overallAuditSummary();
    final drifted = _snapshot?.auditDriftedCount ?? 0;
    final accent = drifted > 0 ? AppColors.negative : AppColors.positive;
    // In issues-only mode keep only groups that still have something
    // to flag (a drifted or unavailable row).
    final visibleGroups = _issuesOnly
        ? groups
            .where((g) => g.driftedCount > 0 || g.unavailableCount > 0)
            .toList()
        : groups;
    // Summary is embedded in the title (with a colon separator) rather
    // than the subtitle chip so it lives inside a single Text widget.
    // UX no-em-dash law: label/value separators use a colon.
    return _tile(
      icon: Icons.fact_check_outlined,
      title: 'AUDIT CHECKS: $overall',
      accentColor: accent,
      children: visibleGroups.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  'No issues. Every audit check is aligned.',
                  style: AppTextStyles.mono11(color: AppColors.positive),
                ),
              ),
            ]
          : [
              for (int i = 0; i < visibleGroups.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _buildAuditGroupSection(visibleGroups[i]),
              ],
            ],
    );
  }

  String _overallAuditSummary() {
    final s = _snapshot!;
    final aligned = s.auditAlignedCount;
    final drifted = s.auditDriftedCount;
    final unavailable = s.auditUnavailableCount;
    final parts = <String>[
      if (aligned > 0) '$aligned aligned',
      if (drifted > 0) '$drifted drifted',
      if (unavailable > 0) '$unavailable unavailable',
    ];
    return parts.isEmpty ? '0 checks' : parts.join(', ');
  }

  Widget _buildAuditGroupSection(DataAlignmentAuditGroupSummary group) {
    final s = _snapshot;
    if (s == null) return const SizedBox.shrink();
    final allChecks = s.auditChecksFor(group.groupId);
    final checks = _issuesOnly
        ? allChecks
            .where((c) => c.status != DriftCheckStatus.aligned)
            .toList()
        : allChecks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Group sub-header inside the tile — uses the same mono10 label
        // convention as _row() labels so every audit-group header reads
        // as a labeled bucket rather than yet another title.
        Row(
          children: [
            Expanded(
              child: Text(
                group.groupId.title,
                style: AppTextStyles.mono10(
                    color: AppColors.textSecondary).copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                group.summaryLine,
                textAlign: TextAlign.right,
                style: AppTextStyles.mono8(color: AppColors.textMuted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final c in checks) _auditCheckRow(c),
      ],
    );
  }

  Widget _auditCheckRow(DataAlignmentAuditCheck c) {
    final Color color;
    final String icon;
    switch (c.status) {
      case DriftCheckStatus.aligned:
        color = AppColors.positive;
        icon = '✓';
        break;
      case DriftCheckStatus.drifted:
        color = AppColors.negative;
        icon = '⚠';
        break;
      case DriftCheckStatus.unavailable:
        color = AppColors.textMuted;
        icon = '—';
        break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: Text(icon,
                style: AppTextStyles.mono12(color: color)),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              c.label,
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              c.detail,
              textAlign: TextAlign.right,
              style: AppTextStyles.mono12(color: color),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Locked-week / target-cycle provenance (Tier 3) ───────────────────────

  Widget _buildLockedWeekProvenanceSection() {
    final provenance = _snapshot?.provenance;
    if (provenance == null || provenance.lockedWeek == null) {
      return _emptySection(
          'LOCKED WEEK PROVENANCE', 'No current-week snapshot resolved',
          icon: Icons.lock_outline_rounded);
    }
    final w = provenance.lockedWeek!;
    final cycle = provenance.targetCycle;
    final rows = <Widget>[
      _row('WEEK KEY', w.weekKey),
      _row('WEEK SPAN', '${w.weekStartDate} → ${w.weekEndDate}'),
      _row('SNAPSHOT ID', w.snapshotId),
      _row('GENERATED AT', w.generatedAt),
      _row('LOCKED AT', w.lockedAt),
      _row('TARGET CYCLE ID', w.targetCycleId),
    ];
    if (cycle == null) {
      rows.add(_row('CYCLE DETAILS', 'Not resolved'));
    } else {
      rows.addAll([
        _row('CYCLE SOURCE', cycle.sourceLabel),
        _row('EFFECTIVE WINDOW',
            '${cycle.effectiveStart} → ${cycle.effectiveEnd}'),
        _row('CALIBRATION WINDOW',
            '${cycle.calibrationWindowStart} → ${cycle.calibrationWindowEnd}'),
      ]);
    }
    return _tile(
      icon: Icons.lock_outline_rounded,
      title: 'LOCKED WEEK PROVENANCE',
      children: rows,
    );
  }

  Widget _buildProfileSection() {
    final p = _snapshot?.profile;
    if (p == null) {
      return _emptySection('ACTIVE TARGET PROFILE', 'Not loaded',
          icon: Icons.track_changes_rounded);
    }
    return _tile(
      icon: Icons.track_changes_rounded,
      title: 'ACTIVE TARGET PROFILE',
      children: [
        _row('CPLH', p.targetCPLH.toStringAsFixed(2)),
        _row('SPLH', p.targetSPLH.toStringAsFixed(2)),
        _row('PPA', '\$${p.targetPPA.toStringAsFixed(2)}'),
        _row('OPZ FLOOR', p.opzFloorCPLH.toStringAsFixed(2)),
        _row('OPZ CEILING', p.opzCeilingCPLH.toStringAsFixed(2)),
        _row('FOH WAGE', '\$${p.fohWage.toStringAsFixed(2)}'),
        _row('BOH WAGE', '\$${p.bohWage.toStringAsFixed(2)}'),
        _row('THEORETICAL LABOR %',
            '${p.theoreticalLaborPct.toStringAsFixed(1)}%'),
      ],
    );
  }

  Widget _buildDemandContextSection() {
    final dc = _snapshot?.demandContext;
    if (dc == null) {
      return _emptySection('DEMAND CONTEXT (ROLLING)', 'Not loaded',
          icon: Icons.trending_up_rounded);
    }
    return _tile(
      icon: Icons.trending_up_rounded,
      title: 'DEMAND CONTEXT',
      subtitle: 'Rolling',
      children: [
        _row('BASELINE TOTAL COVERS (60-DAY)',
            dc.baselineTotalCovers?.toString() ?? '—'),
        _row('BASELINE WEEKLY AVG (60-DAY)',
            dc.baselineWeeklyAvgCovers?.toString() ?? '—'),
        _row('RECENT TOTAL COVERS (3-WEEK)',
            dc.recentThreeWeekTotalCovers?.toString() ?? '—'),
        _row('RECENT WEEKLY AVG (3-WEEK)',
            dc.recentThreeWeekWeeklyAvgCovers?.toString() ?? '—'),
        _row('TREND DELTA',
            dc.recentTrendDeltaCovers?.toString() ?? '—'),
        _row('RESOLVED WEEKLY FORECAST',
            dc.resolvedWeeklyForecastCovers?.toString() ?? '—'),
        _row('DEMAND SOURCE', dc.coversSource.name),
        _row('ANCHOR DATE', dc.anchorBusinessDate ?? '—'),
      ],
    );
  }

  Widget _buildScheduleSection() {
    final p = _snapshot?.plan;
    if (p == null) {
      return _emptySection('SCHEDULE FORECAST', 'Not resolved',
          icon: Icons.event_note_rounded);
    }
    return _tile(
      icon: Icons.event_note_rounded,
      title: 'SCHEDULE FORECAST',
      subtitle: 'Locked Weekly',
      children: [
        _row('COVERS', p.forecastCovers.toString()),
        _row('SALES', '\$${Fmt.dollars(p.forecastSales)}'),
        _row('COVERS SOURCE', p.coversSourceLabel),
      ],
    );
  }

  Widget _buildSchedulePlanSection() {
    final p = _snapshot?.plan;
    final profile = _snapshot?.profile;
    if (p == null) {
      return _emptySection('SCHEDULE PLAN', 'Not resolved',
          icon: Icons.calendar_month_rounded);
    }
    return _tile(
      icon: Icons.calendar_month_rounded,
      title: 'SCHEDULE PLAN',
      subtitle: 'Locked Weekly',
      children: [
        _row('FORECAST COVERS', p.forecastCovers.toString()),
        _row('FORECAST SALES', '\$${Fmt.dollars(p.forecastSales)}'),
        _row('REQUIRED FOH HRS', p.requiredFohHours.toString()),
        _row('REQUIRED BOH HRS', p.requiredBohHours.toString()),
        _row('FOH LABOR \$',
            '\$${Fmt.dollars(p.theoreticalFohLaborDollars)}'),
        _row('BOH LABOR \$',
            '\$${Fmt.dollars(p.theoreticalBohLaborDollars)}'),
        _row(
            'BENCHMARK THEORETICAL LABOR %',
            profile != null
                ? '${profile.theoreticalLaborPct.toStringAsFixed(1)}%'
                : 'Not resolved'),
        _row(
            'BENCHMARK BLENDED WAGE',
            profile != null
                ? '\$${profile.targetBlendedWage.toStringAsFixed(2)}'
                : 'Not resolved'),
      ],
    );
  }

  Widget _buildShiftSection() {
    final s = _snapshot?.shiftReadModel;
    if (s == null) {
      return _emptySection('SHIFT DASHBOARD', 'No open shift',
          icon: Icons.dashboard_rounded);
    }
    return _tile(
      icon: Icons.dashboard_rounded,
      title: 'SHIFT DASHBOARD',
      children: [
        _row('ACTUAL COVERS', s.actualCovers.toString()),
        _row('FORECAST COVERS', s.forecastCovers.toString()),
        _row('ACTUAL CPLH', s.actualCPLH.toStringAsFixed(2)),
        _row('ACTUAL PPA', '\$${s.actualPPA.toStringAsFixed(2)}'),
        _row('ACTUAL SPLH', '\$${s.actualSPLH.toStringAsFixed(2)}'),
        _row('SCHED FOH HRS', s.scheduledFohHours.toString()),
        _row('SCHED BOH HRS', s.scheduledBohHours.toString()),
        _row('TARGET CPLH', s.targetCPLH.toStringAsFixed(2)),
        _row('TARGET PPA', '\$${s.targetPPA.toStringAsFixed(2)}'),
        _row('PLAN FOH HRS', s.planFohHours.toString()),
        _row('PLAN BOH HRS', s.planBohHours.toString()),
        _row('ACTUAL LABOR %', '${s.actualLaborPct.toStringAsFixed(1)}%'),
        _row('THEORETICAL LABOR %', '${s.targetLaborPct.toStringAsFixed(1)}%'),
        _row('PRIMARY LEVER', s.primaryLeverId),
      ],
    );
  }

  Widget _buildVarianceSection() {
    final w = _snapshot?.weekData;
    if (w == null) {
      return _emptySection('VARIANCE WTD', 'No WTD data',
          icon: Icons.balance_rounded);
    }
    return _tile(
      icon: Icons.balance_rounded,
      title: 'VARIANCE WTD',
      children: [
        _row('TOTAL COVERS', w.totalCovers.toString()),
        _row('TOTAL SALES', '\$${Fmt.dollars(w.totalSales)}'),
        _row('FOH HRS', w.totalFohHours.toString()),
        _row('BOH HRS', w.totalBohHours.toString()),
        _row('AVG CPLH', w.avgCPLH.toStringAsFixed(2)),
        _row('AVG PPA', '\$${w.avgPPA.toStringAsFixed(2)}'),
        _row('AVG SPLH', '\$${w.avgSPLH.toStringAsFixed(2)}'),
        _row('ACTUAL LABOR %', '${w.actualLaborPct.toStringAsFixed(1)}%'),
        _row('THEORETICAL LABOR %',
            '${w.theoreticalLaborPct.toStringAsFixed(1)}%'),
        _row('DOLLAR GAP', '\$${Fmt.dollars(w.dollarGap)}'),
        _row('TARGET CPLH', w.targetCPLH.toStringAsFixed(2)),
        _row('TARGET PPA', '\$${w.targetPPA.toStringAsFixed(2)}'),
        _row('PRIMARY LEVER', w.primaryLeverId),
      ],
    );
  }

  Widget _buildWageAuthoritySection() {
    final w = _snapshot?.wageContext;
    if (w == null) {
      return _emptySection('WAGE AUTHORITY', 'Not loaded',
          icon: Icons.payments_outlined);
    }
    return _tile(
      icon: Icons.payments_outlined,
      title: 'WAGE AUTHORITY',
      children: [
        _row('SOURCE', w.source.displayLabel),
        _row('FOH WAGE',
            w.fohWage != null ? '\$${w.fohWage!.toStringAsFixed(2)}' : '—'),
        _row('BOH WAGE',
            w.bohWage != null ? '\$${w.bohWage!.toStringAsFixed(2)}' : '—'),
        _row(
            'REF BLENDED',
            w.referenceBlendedWage != null
                ? '\$${w.referenceBlendedWage!.toStringAsFixed(2)}'
                : '—'),
      ],
    );
  }

  Widget _buildDemoSeedSection() {
    return _tile(
      icon: Icons.dataset_outlined,
      title: 'DEMO SEED REFERENCE',
      children: [
        _row('MERIDIAN COVERS', MeridianConfig.weeklyCovers.toString()),
        _row('MERIDIAN CPLH', MeridianConfig.targetCPLH.toStringAsFixed(1)),
        _row('MERIDIAN PPA',
            '\$${MeridianConfig.targetPPA.toStringAsFixed(2)}'),
        _row('MERIDIAN SPLH',
            '\$${MeridianConfig.targetSPLH.toStringAsFixed(2)}'),
        _row('CONFIG FOH WAGE',
            '\$${MeridianConfig.fohWage.toStringAsFixed(2)}'),
        _row('CONFIG BOH WAGE',
            '\$${MeridianConfig.bohWage.toStringAsFixed(2)}'),
        _row('MOCK REPLAY SHIFTS',
            MockIntegrationReplaySeed.output.currentWeekShifts.length.toString()),
      ],
    );
  }

  // ─── Layout helpers ────────────────────────────────────────────────────────

  /// Top-level category header — renders above a related cluster of tiles
  /// (e.g. INTEGRITY, PROVENANCE). Gives the panel a strong visual spine
  /// so the eye groups related tiles rather than treating everything as
  /// one long blob.
  Widget _categoryHeader(String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Row(
        children: [
          Icon(icon, size: 13, color: AppColors.sunset),
          const SizedBox(width: 8),
          Text(
            label,
            style: AppTextStyles.mono10(color: AppColors.sunset).copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 1,
              color: AppColors.sunset.withValues(alpha: 0.25),
            ),
          ),
        ],
      ),
    );
  }

  /// Bordered tile wrapping one data section. Header row has an icon, a
  /// title, and an optional right-aligned subtitle (used for summary
  /// counts or source labels like "Locked Weekly"). Title sits in
  /// mono12 weight 700 — a proper heading, not mono8 fine-print.
  Widget _tile({
    required IconData icon,
    required String title,
    String? subtitle,
    Color? accentColor,
    required List<Widget> children,
  }) {
    final accent = accentColor ?? AppColors.sunset;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.backgroundMid, AppColors.cardGlow],
            ),
            border: Border.all(color: AppColors.borderSubtle, width: 1),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: accent),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Tile header row
                      Padding(
                        padding:
                            const EdgeInsets.fromLTRB(12, 10, 12, 8),
                        child: Row(
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.12),
                                border: Border.all(
                                    color:
                                        accent.withValues(alpha: 0.4),
                                    width: 1),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Icon(icon,
                                  size: 14, color: accent),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                title,
                                style: AppTextStyles.mono12(
                                        color: AppColors.textPrimary)
                                    .copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color:
                                      accent.withValues(alpha: 0.12),
                                  borderRadius:
                                      BorderRadius.circular(10),
                                ),
                                child: Text(
                                  subtitle,
                                  style: AppTextStyles.mono8(
                                      color: accent),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Container(
                        height: 1,
                        color: AppColors.borderSubtle
                            .withValues(alpha: 0.6),
                      ),
                      // Tile body
                      Padding(
                        padding:
                            const EdgeInsets.fromLTRB(12, 8, 12, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: children,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptySection(String title, String message, {IconData? icon}) {
    return _tile(
      icon: icon ?? Icons.info_outline_rounded,
      title: title,
      accentColor: AppColors.textMuted,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(message,
              style: AppTextStyles.body13(color: AppColors.textMuted)),
        ),
      ],
    );
  }

  /// A single label/value pair. Labels sit in the left column in the
  /// muted mono10 caps style, values right-aligned in mono12 weight 700
  /// so the numbers pop — which was the whole point of the redesign.
  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTextStyles.mono10(color: AppColors.textMuted)
                  .copyWith(letterSpacing: 0.5),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: AppTextStyles.mono12(
                  color: AppColors.textPrimary, weight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  // Retained for binary/API compatibility even though the new layout
  // draws its own separators via category headers and tile borders.
  // ignore: unused_element
  Widget _sectionDivider() {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      color: AppColors.borderSubtle,
    );
  }
}
