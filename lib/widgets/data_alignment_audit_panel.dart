import 'package:flutter/material.dart';
import '../data/demand_forecast_context_service.dart';
import '../data/legacy_fixture_data.dart';
import '../data/mock_integration_replay_seed.dart';
import '../data/schedule_plan_read_service.dart';
import '../data/shift_service.dart';
import '../data/wage_standard_context_service.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/demand_forecast_context.dart';
import '../domain/models/schedule_plan.dart';
import '../domain/models/wage_standard_context.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../models/shift_dashboard_read_model.dart';
import '../models/week_data.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// Expandable audit panel for the Settings screen.
///
/// Loads all resolved values from every data layer on first expand
/// and displays them side by side for architectural alignment verification.
class DataAlignmentAuditPanel extends StatefulWidget {
  const DataAlignmentAuditPanel({super.key});

  @override
  State<DataAlignmentAuditPanel> createState() =>
      _DataAlignmentAuditPanelState();
}

class _DataAlignmentAuditPanelState extends State<DataAlignmentAuditPanel> {
  bool _isExpanded = false;
  bool _isLoading = false;

  // Loaded data
  ActiveTargetProfile? _profile;
  DemandForecastContext? _demandContext;
  SchedulePlan? _plan;
  ShiftDashboardReadModel? _shiftReadModel;
  WeekData? _weekData;
  WageStandardContext? _wageContext;

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      _profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);

      // Load canonical demand context from repository
      _demandContext =
          await DemandForecastContextService.instance.getCurrentContext();

      // Read the EXISTING locked weekly plan only. The audit panel is meant
      // to reflect the same authority path as the production Schedule / Shift
      // surfaces after 7.55q.2, not a looser "live resolved" fallback.
      //
      // If the current-week snapshot is absent, leave `_plan` null and let the
      // panel render "Not resolved" honestly instead of auto-generating or
      // live-resolving a competing current-week plan.
      _plan = await SchedulePlanReadService.instance
          .getExistingCurrentLockedWeeklyPlan();

      _shiftReadModel = await ShiftService.instance.getShiftDashboard();

      // Keep the audit panel read-only: only attempt the WTD alignment read
      // when a locked current-week plan already exists. `getLiveWeekToDate()`
      // legitimately bootstraps a current snapshot when missing, which is
      // fine for production Variance but too loose for an "alignment audit"
      // surface that is supposed to mirror strict authority paths.
      _weekData = _plan != null
          ? await ShiftService.instance.getLiveWeekToDate()
          : null;
      _wageContext =
          await WageStandardContextService.instance.resolve(restaurantId);
    } catch (_) {
      // Gracefully handle missing data
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
              if (_isExpanded && _profile == null && !_isLoading) {
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

  // ─── Sections ──────────────────────────────────────────────────────────────

  Widget _buildProfileSection() {
    final p = _profile;
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
    final dc = _demandContext;
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
    final p = _plan;
    if (p == null) return _emptySection('SCHEDULE FORECAST', 'Not resolved');
    const sourceLabel = 'LOCKED WEEKLY';
    return _section('SCHEDULE FORECAST ($sourceLabel)', [
      _row('COVERS', p.forecastCovers.toString()),
      _row('SALES', '\$${Fmt.dollars(p.forecastSales)}'),
      _row('COVERS SOURCE', p.coversSourceLabel),
    ]);
  }

  Widget _buildSchedulePlanSection() {
    final p = _plan;
    final profile = _profile;
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
    final s = _shiftReadModel;
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
    final w = _weekData;
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
    final w = _wageContext;
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
