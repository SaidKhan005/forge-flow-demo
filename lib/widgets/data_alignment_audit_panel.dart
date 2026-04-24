import 'package:flutter/material.dart';
import '../data/legacy_fixture_data.dart';
import '../data/mock_integration_replay_seed.dart';
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
///   - Tier 2 (drift detection): a new DRIFT CHECKS section at the top
///     renders green / red badges flagging cross-section value drift
///     against q-lane conformance Rules 2 and 3 plus wage-authority
///     consistency. Acts as a live regression detector for the q-lane
///     contracts during refactoring work.
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
                  // Inline drift summary in the header when loaded.
                  if (_snapshot != null) _headerDriftSummary(_snapshot!),
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
            else ...[
              _buildDriftChecksSection(),
              _sectionDivider(),
              _buildProfileSection(),
              _sectionDivider(),
              _buildDemandContextSection(),
              _sectionDivider(),
              _buildScheduleSection(),
              _sectionDivider(),
              _buildSchedulePlanSection(),
              _sectionDivider(),
              _buildShiftSection(),
              _sectionDivider(),
              _buildVarianceSection(),
              _sectionDivider(),
              _buildWageAuthoritySection(),
              _sectionDivider(),
              _buildDemoSeedSection(),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }

  // ─── Drift summary (header) ───────────────────────────────────────────────

  /// Compact drift badge shown in the panel header when loaded.
  Widget _headerDriftSummary(DataAlignmentAuditSnapshot s) {
    final drifted = s.driftedCount;
    final aligned = s.alignedCount;
    if (aligned == 0 && drifted == 0) {
      return const SizedBox.shrink();
    }
    final color = drifted > 0 ? AppColors.negative : AppColors.positive;
    final text = drifted > 0 ? '$drifted drifted' : 'all aligned';
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(text, style: AppTextStyles.mono10(color: color)),
    );
  }

  // ─── Sections ──────────────────────────────────────────────────────────────

  Widget _buildDriftChecksSection() {
    final checks = _snapshot?.driftChecks ?? const <DataAlignmentDriftCheck>[];
    if (checks.isEmpty) {
      return _emptySection(
          'DRIFT CHECKS', 'No checks available yet (missing authority data)');
    }
    final drifted = _snapshot!.driftedCount;
    final aligned = _snapshot!.alignedCount;
    final title = drifted > 0
        ? 'DRIFT CHECKS — $drifted drifted, $aligned aligned'
        : 'DRIFT CHECKS — all $aligned aligned';
    return _section(title, checks.map(_driftRow).toList());
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
          Text(
            c.ruleReference,
            style: AppTextStyles.mono8(color: AppColors.textMuted),
          ),
          const SizedBox(width: 8),
          Text(
            valueStr,
            style: AppTextStyles.mono12(color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileSection() {
    final p = _snapshot?.profile;
    if (p == null) return _emptySection('ACTIVE TARGET PROFILE', 'Not loaded');
    return _section('ACTIVE TARGET PROFILE', [
      _row('CPLH', p.targetCPLH.toStringAsFixed(2)),
      _row('SPLH', p.targetSPLH.toStringAsFixed(2)),
      _row('PPA', '\$${p.targetPPA.toStringAsFixed(2)}'),
      _row('OPZ FLOOR', p.opzFloorCPLH.toStringAsFixed(2)),
      _row('OPZ CEILING', p.opzCeilingCPLH.toStringAsFixed(2)),
      _row('FOH WAGE', '\$${p.fohWage.toStringAsFixed(2)}'),
      _row('BOH WAGE', '\$${p.bohWage.toStringAsFixed(2)}'),
      _row('THEORETICAL LABOR %',
          '${p.theoreticalLaborPct.toStringAsFixed(1)}%'),
    ]);
  }

  Widget _buildDemandContextSection() {
    final dc = _snapshot?.demandContext;
    if (dc == null) {
      return _emptySection('DEMAND CONTEXT (ROLLING)', 'Not loaded');
    }
    return _section('DEMAND CONTEXT (ROLLING)', [
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
      _row('DEMAND SOURCE',
          dc.coversSource.name),
      _row('ANCHOR DATE',
          dc.anchorBusinessDate ?? '—'),
    ]);
  }

  Widget _buildScheduleSection() {
    final p = _snapshot?.plan;
    if (p == null) return _emptySection('SCHEDULE FORECAST', 'Not resolved');
    const sourceLabel = 'LOCKED WEEKLY';
    return _section('SCHEDULE FORECAST ($sourceLabel)', [
      _row('COVERS', p.forecastCovers.toString()),
      _row('SALES', '\$${Fmt.dollars(p.forecastSales)}'),
      _row('COVERS SOURCE', p.coversSourceLabel),
    ]);
  }

  Widget _buildSchedulePlanSection() {
    final p = _snapshot?.plan;
    final profile = _snapshot?.profile;
    if (p == null) return _emptySection('SCHEDULE PLAN', 'Not resolved');
    const sourceLabel = 'LOCKED WEEKLY';
    return _section('SCHEDULE PLAN ($sourceLabel)', [
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
    ]);
  }

  Widget _buildShiftSection() {
    final s = _snapshot?.shiftReadModel;
    if (s == null) return _emptySection('SHIFT DASHBOARD', 'No open shift');
    return _section('SHIFT DASHBOARD', [
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
    ]);
  }

  Widget _buildVarianceSection() {
    final w = _snapshot?.weekData;
    if (w == null) return _emptySection('VARIANCE WTD', 'No WTD data');
    return _section('VARIANCE WTD', [
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
    ]);
  }

  Widget _buildWageAuthoritySection() {
    final w = _snapshot?.wageContext;
    if (w == null) return _emptySection('WAGE AUTHORITY', 'Not loaded');
    return _section('WAGE AUTHORITY', [
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
    ]);
  }

  Widget _buildDemoSeedSection() {
    return _section('DEMO SEED REFERENCE', [
      _row('MERIDIAN COVERS', MeridianConfig.weeklyCovers.toString()),
      _row('MERIDIAN CPLH', MeridianConfig.targetCPLH.toStringAsFixed(1)),
      _row('MERIDIAN PPA', '\$${MeridianConfig.targetPPA.toStringAsFixed(2)}'),
      _row('MERIDIAN SPLH',
          '\$${MeridianConfig.targetSPLH.toStringAsFixed(2)}'),
      _row('CONFIG FOH WAGE',
          '\$${MeridianConfig.fohWage.toStringAsFixed(2)}'),
      _row('CONFIG BOH WAGE',
          '\$${MeridianConfig.bohWage.toStringAsFixed(2)}'),
      _row('MOCK REPLAY SHIFTS',
          MockIntegrationReplaySeed.output.currentWeekShifts.length.toString()),
    ]);
  }

  // ─── Layout helpers ────────────────────────────────────────────────────────

  Widget _section(String title, List<Widget> rows) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTextStyles.mono8(color: AppColors.textMuted)),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }

  Widget _emptySection(String title, String message) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTextStyles.mono8(color: AppColors.textMuted)),
          const SizedBox(height: 6),
          Text(message,
              style: AppTextStyles.mono11(color: AppColors.textMuted)),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style:
                    AppTextStyles.mono11(color: AppColors.textSecondary)),
          ),
          Text(value,
              style: AppTextStyles.mono12(color: AppColors.textPrimary)),
        ],
      ),
    );
  }

  Widget _sectionDivider() {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      color: AppColors.borderSubtle,
    );
  }
}
