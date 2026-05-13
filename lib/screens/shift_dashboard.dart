import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../theme/app_theme.dart';
import '../domain/constants/app_defaults.dart';
import '../domain/models/restaurant_location.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../services/shift_service_period_read_service.dart';
import '../state/restaurant_scope_notifier.dart';
import '../state/shift_dashboard_notifier.dart';
import '../state/shift_service_period_notifier.dart';
import '../models/current_state_freshness.dart';
import '../models/shift_dashboard_read_model.dart';
import '../utils/formatters.dart';
import '../widgets/app_screen_header.dart';
import '../widgets/data_source_health_pill.dart';
import '../widgets/metric_pill.dart';
import '../widgets/sticky_section_delegate.dart';
import '../widgets/zone_status_card.dart';
import '../widgets/sales_forecast_card.dart';
import '../domain/models/metric_provenance.dart';

/// Default business-day cutoff used by the daypart scaffold until the
/// timing-config wiring (`RestaurantTimingConfigReadService`) is plumbed
/// through to this widget tree. Matches the seeded
/// `business_day_start_local_time` in
/// `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart`.
const String _defaultBusinessDayStartLocalTime = '04:00';

bool _tzInitialized = false;

void _ensureTzInitialized() {
  if (_tzInitialized) return;
  tzdata.initializeTimeZones();
  _tzInitialized = true;
}

class ShiftDashboard extends StatefulWidget {
  final VoidCallback? onVarianceTap;

  /// Test seam: when non-null, used instead of [DateTime.now] for the
  /// header clock display and the daypart scaffold's active-period
  /// resolver. Set in tests, clear in tearDown.
  @visibleForTesting
  static DateTime Function()? clockOverride;

  const ShiftDashboard({super.key, this.onVarianceTap});

  @override
  State<ShiftDashboard> createState() => _ShiftDashboardState();
}

class _ShiftDashboardState extends State<ShiftDashboard> {
  String? _selectedServicePeriodId;

  /// A4.2 (R2) per `docs/_audits/code_health/a4_performance_audit.md`:
  /// one shared 30-second ticker drives every wall-clock-dependent
  /// widget on the screen (`_LiveClock`, `_ShiftPeriodSelector`,
  /// `_DaypartScaffoldSection`, `_TimeIntoServiceHeader`). Before the
  /// coalesce each widget owned its own `Timer.periodic` — four timers,
  /// four independent tick offsets, four `setState` calls per cycle.
  /// Now: one timer fires; all four widgets rebuild on the same vsync
  /// via `ValueListenableBuilder<DateTime>`. The ticker is passed to
  /// each consumer through its constructor (avoids the
  /// `Provider<Listenable>` debug check from the `provider` package and
  /// keeps the wiring explicit).
  late final _ShiftDashboardTicker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = _ShiftDashboardTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _setSelectedServicePeriodId(String? next) {
    if (_selectedServicePeriodId == next) return;
    setState(() => _selectedServicePeriodId = next);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ShiftDashboardNotifier>(
      builder: (context, notifier, _) {
        if (notifier.isLoading) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.sunset),
          );
        }
        // Phase 10.5.2 — pull-to-refresh must refresh BOTH the
        // whole-day notifier and the per-period accumulator notifier
        // so the daypart cards don't go stale relative to whole-day.
        // Awaits both in parallel so the spinner only releases once
        // both surfaces have rebuilt.
        Future<void> refreshBoth() async {
          final periodNotifier = context.read<ShiftServicePeriodNotifier?>();
          await Future.wait([
            notifier.refresh(),
            if (periodNotifier != null) periodNotifier.refresh(),
          ]);
        }

        final rm = notifier.readModel;
        if (rm == null) {
          return RefreshIndicator(
            color: AppColors.sunset,
            onRefresh: refreshBoth,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverFillRemaining(
                  child: _ShiftEmptyState(
                    headline: notifier.lockedPlanUnavailable
                        ? 'LOCKED PLAN UNAVAILABLE'
                        : notifier.status?.label ?? 'NO LIVE SHIFT',
                    body: notifier.lockedPlanUnavailable
                        ? 'No locked weekly plan is available for the current week.'
                        : notifier.status?.description ??
                              'No open or projected shift is available.',
                    timestamp: notifier.status?.latestImportTimestamp,
                  ),
                ),
              ],
            ),
          );
        }
        return FadingHeaderShell(
          header: _ShiftHeader(
            readModel: rm,
            freshness: notifier.freshness,
            ticker: _ticker,
          ),
          child: RefreshIndicator(
            color: AppColors.sunset,
            onRefresh: refreshBoth,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _ShiftPeriodSelector(
                    selectedPeriodId: _selectedServicePeriodId,
                    onChanged: _setSelectedServicePeriodId,
                    ticker: _ticker,
                  ),
                ),
                // Phase 8.0 V1 lean cut 2 — DataSourceHealthPill
                // mounted at the dashboard root. Renders nothing when
                // every visible metric is `live`; renders a single
                // line when any metric is non-live. Per
                // metric_card_honesty_contract.md "Forbidden
                // Patterns": no card-level chrome, no "All live"
                // pill.
                SliverToBoxAdapter(
                  child: _ShiftDashboardHealthPill(readModel: rm),
                ),
                if (_selectedServicePeriodId == null)
                  ..._wholeDaySlivers(rm)
                else
                  ..._servicePeriodSlivers(_selectedServicePeriodId!),
                const SliverToBoxAdapter(child: SizedBox(height: 48)),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Existing whole-day slivers — kept identical to pre-10.5 behavior.
  /// Whole-day Shift is authoritative; daypart is additive.
  List<Widget> _wholeDaySlivers(ShiftDashboardReadModel rm) {
    return [
      // Each SliverMainAxisGroup bundles a header + its content
      // so the next group's header pushes the entire previous
      // group off — iOS UITableView-style, no stacking.
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: StickySectionDelegate('SHIFT OUTPUTS'),
          ),
          SliverToBoxAdapter(child: _OutputsSection(readModel: rm)),
        ],
      ),
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: StickySectionDelegate('SHIFT INPUTS'),
          ),
          SliverToBoxAdapter(child: _InputsSection(readModel: rm)),
        ],
      ),
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: StickySectionDelegate('FOH PRODUCTIVITY'),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ZoneStatusCard(
                currentCPLH: rm.actualCPLH,
                opzFloorCPLH: rm.opzFloorCPLH,
                opzCeilingCPLH: rm.opzCeilingCPLH,
                targetCPLH: rm.targetCPLH,
                opzStatus: rm.opzStatus,
                opzLabel: rm.opzLabel,
                opzSubLabel: rm.opzSubLabel,
                // 7.58 depth wave (slice 10.5.6): SPLH band feeds the
                // cross-axis matrix rendered inside the OPZ tile.
                splhState: rm.splhState,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  /// Daypart slivers — Phase 10.5.2 lights up the live per-period
  /// accumulator. The scaffold reads from [ShiftServicePeriodNotifier]
  /// (with a graceful fallback to `demoDefinitions` when the notifier
  /// is missing) and renders one card per service-period definition
  /// with covers / sales / CPLH / SPLH / PPA / blended-wage metrics
  /// when the bucket has data. The time-into-service header
  /// ("Lunch · 1h 12m in") sits above the SERVICE PERIODS sticky
  /// header and only renders when an active period is in progress.
  List<Widget> _servicePeriodSlivers(String selectedPeriodId) {
    return [
      SliverToBoxAdapter(
        child: _TimeIntoServiceHeader(
          selectedPeriodId: selectedPeriodId,
          ticker: _ticker,
        ),
      ),
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: const StickySectionDelegate('SERVICE PERIOD'),
          ),
          SliverToBoxAdapter(
            child: _DaypartScaffoldSection(
              selectedPeriodId: selectedPeriodId,
              ticker: _ticker,
            ),
          ),
        ],
      ),
    ];
  }
}

// ─── Header — unified app screen header with day · time meta row ─────────

class _ShiftHeader extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  final CurrentStateFreshness? freshness;
  final ValueListenable<DateTime> ticker;
  const _ShiftHeader({
    required this.readModel,
    required this.ticker,
    this.freshness,
  });

  @override
  Widget build(BuildContext context) {
    final restaurantName =
        context.watch<RestaurantScopeNotifier?>()?.restaurant?.displayName ??
        'Restaurant';
    return AppScreenHeader(
      title: restaurantName,
      trailing: _LiveClock(ticker: ticker),
      bottom: _ShiftHeaderMeta(
        day: readModel.day,
        businessDate: readModel.businessDate,
        daypart: readModel.daypart,
        freshness: freshness,
      ),
    );
  }
}

String _formatMonthDay(String isoDate) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final parts = isoDate.split('-');
  if (parts.length != 3) return isoDate;
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (month == null || day == null || month < 1 || month > 12) {
    return isoDate;
  }
  return '${months[month - 1]} $day';
}

/// Bottom-row meta for the Shift header: day · live business date · optional
/// daypart on the left, live clock + optional freshness chip on the right.
/// Lives in the same slot where Variance shows its TabBar so all four tabs
/// match in height.
class _ShiftHeaderMeta extends StatelessWidget {
  final String day;
  final String businessDate;
  final String daypart;
  final CurrentStateFreshness? freshness;
  const _ShiftHeaderMeta({
    required this.day,
    required this.businessDate,
    required this.daypart,
    this.freshness,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left group — dot + day · date
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: AppColors.sunset,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$day \u00b7 ${_formatMonthDay(businessDate)}',
                style: AppTextStyles.mono12(color: AppColors.sunsetDark),
              ),
            ],
          ),
          // Clock moved to the title row trailing slot. Only the
          // freshness chip remains here on the right.
          if (freshness != null) ...[
            const Spacer(),
            _FreshnessLabel(freshness: freshness!),
          ],
        ],
      ),
    );
  }
}

// ─── Shared 30s ticker (A4.2 R2) ────────────────────────────────────────────

/// Default cadence shared by the four wall-clock-driven widgets on the
/// shift dashboard. Each widget previously owned its own
/// `Timer.periodic(30s)` and called `setState(() {})` on every tick;
/// after A4.2 R2 they all share [_ShiftDashboardTicker] and rebuild
/// inside `ValueListenableBuilder<DateTime>` instead.
const Duration _kShiftDashboardTickInterval = Duration(seconds: 30);

/// One owner of the periodic timer + one [ValueListenable] feed for the
/// four shift-dashboard widgets that need a wall-clock pulse:
/// `_LiveClock`, `_ShiftPeriodSelector`, `_DaypartScaffoldSection`,
/// `_TimeIntoServiceHeader`.
///
/// Owned by [_ShiftDashboardState]; constructed in `initState`,
/// disposed in `dispose`, and passed to each consumer widget via
/// constructor so the `provider` package's `Provider<Listenable>` debug
/// check is avoided (the consumers opt into rebuilds via
/// `ValueListenableBuilder`, not `context.watch`). Reads honor
/// [ShiftDashboard.clockOverride] the same way the prior per-widget
/// timers did, so existing test seams continue to work without
/// modification.
class _ShiftDashboardTicker extends ValueNotifier<DateTime> {
  _ShiftDashboardTicker({
    Duration interval = _kShiftDashboardTickInterval,
  })  : _interval = interval,
        super(_currentTime()) {
    _timer = Timer.periodic(_interval, (_) {
      value = _currentTime();
    });
  }

  final Duration _interval;
  Timer? _timer;

  static DateTime _currentTime() =>
      (ShiftDashboard.clockOverride ?? DateTime.now)();

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

// ─── Live clock ─────────────────────────────────────────────────────────────

/// Ticking wall-clock display for the Shift header.
///
/// Shows the current time formatted as `h:mm AM/PM`. Rebuilds whenever
/// the shared [_ShiftDashboardTicker] (provided at the dashboard root)
/// fires — every 30 seconds in production. Uses
/// [ShiftDashboard.clockOverride] when set (test seam), otherwise
/// [DateTime.now]; both read paths are funneled through the shared
/// ticker.
///
/// This is display-only — it does not determine business date, shift status,
/// or daypart. Those remain snapshot-driven through the read model.
///
/// A4.2 (R2): previously owned its own `Timer.periodic(30s)`; now
/// listens to the dashboard-wide ticker (passed in via constructor)
/// via `ValueListenableBuilder`.
class _LiveClock extends StatelessWidget {
  final ValueListenable<DateTime> ticker;
  const _LiveClock({required this.ticker});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: ticker,
      builder: (context, now, _) {
        final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
        final minute = now.minute.toString().padLeft(2, '0');
        final amPm = now.hour >= 12 ? 'PM' : 'AM';
        return Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$hour:$minute',
              style: AppTextStyles.mono16(color: AppColors.textPrimary),
            ),
            const SizedBox(width: 4),
            Text(amPm, style: AppTextStyles.mono10(color: AppColors.textMuted)),
          ],
        );
      },
    );
  }
}

// ─── Freshness label (7.55n.8) ──────────────────────────────────────────────

/// Compact freshness indicator using the shared [CurrentStateFreshness] seam.
///
/// - [FreshnessState.live]: green dot + "Live"
/// - [FreshnessState.updated]: amber dot + "Updated X min ago"
/// - [FreshnessState.stale]: muted dot + "Updated X hr ago"
/// - [FreshnessState.refreshing]: preserves prior age if available
class _FreshnessLabel extends StatelessWidget {
  final CurrentStateFreshness freshness;
  const _FreshnessLabel({required this.freshness});

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color dotColor;

    switch (freshness.state) {
      case FreshnessState.live:
        label = 'Live';
        dotColor = AppColors.positive;
      case FreshnessState.updated:
        final age = freshness.age;
        label = age != null ? 'Updated ${Fmt.timeAgo(age)}' : 'Updated';
        dotColor = AppColors.sunset;
      case FreshnessState.stale:
        final age = freshness.age;
        label = age != null ? 'Updated ${Fmt.timeAgo(age)}' : 'Stale';
        dotColor = AppColors.textMuted;
      case FreshnessState.refreshing:
        final age = freshness.age;
        label = age != null ? 'Updated ${Fmt.timeAgo(age)}' : 'Refreshing';
        dotColor = AppColors.textMuted;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: AppTextStyles.mono10(color: AppColors.textMuted)),
      ],
    );
  }
}

// _SectionHeader removed — replaced by shared StickySectionDelegate
// pinned headers in the CustomScrollView slivers above.

// ignore: unused_element — Phase 10.5 lever teaching
class _SectionHeaderWithIcon extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SectionHeaderWithIcon({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppColors.sunset, AppColors.sunsetDark],
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Icon(icon, size: 16, color: AppColors.sunset),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppTextStyles.mono14(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 2,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.sunset, AppColors.sunsetDark],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Outputs section (Sales, Labor%, Covers, Blended Wage) ──────────────────

/// Converts a domain provenance ID string (e.g. "vendor_toast_pos",
/// "vendor_quickbooks_time_partial_sync", "none") into a short human-
/// readable label for [MetricPillProvenance.label].
///
/// TODO(11W.metric-pill): replace with a proper vendor-display-name
/// lookup table once Phase 8 connector metadata exposes display names.
String _provenanceLabelFor(String provenanceId) {
  if (provenanceId == provenanceNone || provenanceId.isEmpty) return 'Unknown';
  final stripped = provenanceId
      .replaceFirst('vendor_', '')
      .replaceAll('_with_fallback_labor_dollars', '')
      .replaceAll('_partial_sync', ' (partial)')
      .replaceAll('_', ' ');
  // Title-case the first letter only.
  return stripped.isEmpty
      ? 'Unknown'
      : stripped[0].toUpperCase() + stripped.substring(1);
}

/// Adapts a [MetricProvenance] domain object to the widget-layer
/// [MetricPillProvenance] descriptor used by [MetricPill].
MetricPillProvenance _toPillProvenance(
  MetricProvenance prov, {
  String? unavailableTooltip,
}) {
  return MetricPillProvenance(
    label: _provenanceLabelFor(prov.provenance),
    tooltip: prov.state == MetricState.unavailable ? unavailableTooltip : null,
  );
}

class _OutputsSection extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _OutputsSection({required this.readModel});

  @override
  Widget build(BuildContext context) {
    // feat(11W.metric-pill): converted from InputMetricCard /
    // MetricCardNotYetAvailable conditional to MetricPill, which
    // enforces state + provenance at the widget boundary.
    final coversProv = readModel.coversProvenance;
    final wageProv = readModel.blendedWageProvenance;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        children: [
          // ── Sales + Labor side by side ──
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SalesForecastCard(
                    currentSales: readModel.currentSales,
                    forecastSales: readModel.forecastSales,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _LaborCard(readModel: readModel)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // ── Covers + Blended Wage side by side ──
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: MetricPill(
                    state: coversProv.state,
                    provenance: _toPillProvenance(
                      coversProv,
                      unavailableTooltip:
                          'Connect a POS vendor to see covers.',
                    ),
                    label: 'COVERS',
                    value: coversProv.value,
                    formatter: (v) => '${v.toInt()}',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: MetricPill(
                    state: wageProv.state,
                    provenance: _toPillProvenance(
                      wageProv,
                      unavailableTooltip:
                          'Connect a labor vendor to see blended wage.',
                    ),
                    label: 'BLENDED WAGE',
                    value: wageProv.value,
                    formatter: (v) => '\$${v.toStringAsFixed(2)}',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Inputs section (PPA, CPLH, SPLH, FOH HRS, BOH HRS) ───────────────────

class _InputsSection extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _InputsSection({required this.readModel});

  @override
  Widget build(BuildContext context) {
    // feat(11W.metric-pill): converted from InputMetricCard /
    // MetricCardNotYetAvailable conditional to MetricPill for PPA,
    // CPLH, and SPLH. Provenance state flows from the read model;
    // no state is hardcoded as live.

    // Provenance objects from read model (carry state + provenance string).
    final ppaProv = readModel.ppaProvenance;
    final cplhProv = readModel.cplhProvenance;
    final splhProv = readModel.splhProvenance;

    // Hours data — plan targets from SchedulePlan day row
    final fohScheduled = readModel.scheduledFohHours;
    final bohScheduled = readModel.scheduledBohHours;
    final fohTarget = readModel.planFohHours;
    final bohTarget = readModel.planBohHours;
    final fohExcess = fohScheduled - fohTarget;
    final bohExcess = bohScheduled - bohTarget;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // PPA, CPLH, SPLH in grid — each rendered via MetricPill.
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.05,
            children: [
              MetricPill(
                state: ppaProv.state,
                provenance: _toPillProvenance(
                  ppaProv,
                  unavailableTooltip:
                      'Connect a POS vendor to see per-person average.',
                ),
                label: 'PPA',
                value: ppaProv.value,
                formatter: (v) => '\$${v.toStringAsFixed(2)}',
              ),
              MetricPill(
                state: cplhProv.state,
                provenance: _toPillProvenance(
                  cplhProv,
                  unavailableTooltip:
                      'Connect a labor vendor to see covers per labor hour.',
                ),
                label: 'CPLH',
                value: cplhProv.value,
                formatter: (v) => v.toStringAsFixed(2),
              ),
              MetricPill(
                state: splhProv.state,
                provenance: _toPillProvenance(
                  splhProv,
                  unavailableTooltip:
                      'Connect a labor vendor to see sales per labor hour.',
                ),
                label: 'SPLH',
                value: splhProv.value,
                formatter: (v) => '\$${v.toStringAsFixed(0)}',
              ),
            ],
          ),
          const SizedBox(height: 8),
          // FOH + BOH hours side by side
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _CompactHoursColumn(
                    label: 'FOH HRS',
                    scheduled: fohScheduled,
                    needed: fohTarget,
                    excess: fohExcess,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CompactHoursColumn(
                    label: 'BOH HRS',
                    scheduled: bohScheduled,
                    needed: bohTarget,
                    excess: bohExcess,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Teaching takeaway ───────────────────────────────────────────────────────

// ignore: unused_element — Phase 10.5 lever teaching
class _TeachingTakeaway extends StatelessWidget {
  final LeverCardData lever;
  const _TeachingTakeaway({required this.lever});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.7),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lever.metric,
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            lever.whatHappened,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ─── Scope toggle (Phase 10.5.0) ────────────────────────────────────────────

/// Unified selector for the Shift rollup and configured service periods.
///
/// Whole Day stays selected by default and remains the authoritative
/// rollup; selecting a period opens that period's live lens without
/// changing the whole-day path.
class _ShiftPeriodSelector extends StatelessWidget {
  final String? selectedPeriodId;
  final ValueChanged<String?> onChanged;
  final ValueListenable<DateTime> ticker;

  const _ShiftPeriodSelector({
    required this.selectedPeriodId,
    required this.onChanged,
    required this.ticker,
  });

  // A4.2 (R2): rebuilds are driven by the dashboard-wide ticker
  // (constructor-injected from `_ShiftDashboardState`), not a local
  // `Timer.periodic`. Keeps the "ACTIVE NOW" chip accurate across
  // service-period boundaries without owning its own timer.
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: ticker,
      builder: (context, _, __) {
        final restaurant = context.watch<RestaurantScopeNotifier?>()?.restaurant;
        final periodNotifier = context.watch<ShiftServicePeriodNotifier?>();
        final definitions = ServicePeriodDefinitionResolver.ordered(
          periodNotifier?.definitions ??
              ServicePeriodDefinitionResolver.demoDefinitions,
        );
        final cutoff =
            periodNotifier?.businessDayStartLocalTime ??
            _defaultBusinessDayStartLocalTime;
        final localNow = _restaurantLocalNow(restaurant);
        final activeId = localNow == null
            ? null
            : resolveActiveServicePeriodId(
                localNow: localNow,
                businessDayStartLocalTime: cutoff,
                definitions: definitions,
              );

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _PeriodPill(
                  label: 'Whole Day',
                  selected: selectedPeriodId == null,
                  onTap: () => onChanged(null),
                ),
                for (final definition in definitions) ...[
                  const SizedBox(width: 8),
                  _PeriodPill(
                    label: definition.label,
                    selected: selectedPeriodId == definition.id,
                    activeNow: activeId == definition.id,
                    onTap: () => onChanged(definition.id),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PeriodPill extends StatelessWidget {
  final String label;
  final bool selected;
  final bool activeNow;
  final VoidCallback onTap;

  const _PeriodPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.activeNow = false,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = selected ? AppColors.sunset : AppColors.backgroundMid;
    final borderColor = selected
        ? AppColors.sunsetDark
        : AppColors.borderSubtle.withValues(alpha: 0.7);
    final textColor = selected
        ? AppColors.textPrimary
        : AppColors.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 88, minHeight: 38),
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
          decoration: BoxDecoration(
            color: bgColor,
            border: Border.all(color: borderColor, width: 1),
            borderRadius: BorderRadius.circular(2),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppTextStyles.mono12(
                  color: textColor,
                  weight: FontWeight.w700,
                ),
              ),
              if (activeNow) ...[
                const SizedBox(height: 2),
                Text(
                  'ACTIVE NOW',
                  style: AppTextStyles.mono8(
                    color: AppColors.sunsetDark,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Daypart scaffold (Phase 10.5.0 → 10.5.2) ───────────────────────────────

/// Live daypart lens for the Shift surface.
///
/// Phase 10.5.0 opened the surface seam (cards + ACTIVE NOW chip).
/// Phase 10.5.2 lights up the per-service-period accumulator: the
/// scaffold now reads bucket totals from [ShiftServicePeriodNotifier]
/// (covers, sales, CPLH, SPLH, PPA, blended-wage) and renders them
/// on each card. Empty buckets show an explicit "no data yet" line so
/// the operator never sees zeros that could be confused with real
/// truth.
///
/// **Time-source contract (mirrors `current_state_boundary_monitor.dart`):**
/// the active-period chip is computed from `tz.TZDateTime.now(loc)` for
/// the active restaurant's IANA `businessTimezone`, then bucketed by
/// **business-date weekday** via [BusinessDateResolver] — never by raw
/// `DateTime.now().weekday`. Tests inject a restaurant-local
/// [DateTime] via [ShiftDashboard.clockOverride]. When the
/// restaurant has no usable IANA timezone, no `ACTIVE NOW` chip
/// surfaces — the scaffold refuses to fall back to the device clock,
/// matching the boundary monitor's contract refusal.
///
/// A4.2 (R2): rebuilds are driven by the dashboard-wide
/// [_ShiftDashboardTicker] (provided at the dashboard root) instead of
/// a local `Timer.periodic`. The shared ticker fires once every 30s
/// and fans out to every wall-clock-dependent widget so the chip stays
/// accurate when the operator parks on the daypart view across a
/// service-period boundary (e.g. Lunch → no-period → Dinner).
class _DaypartScaffoldSection extends StatelessWidget {
  final String selectedPeriodId;
  final ValueListenable<DateTime> ticker;

  const _DaypartScaffoldSection({
    required this.selectedPeriodId,
    required this.ticker,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: ticker,
      builder: (context, _, __) {
        final restaurant =
            context.watch<RestaurantScopeNotifier?>()?.restaurant;
        final periodNotifier = context.watch<ShiftServicePeriodNotifier?>();

        final definitions =
            periodNotifier?.definitions ??
            ServicePeriodDefinitionResolver.demoDefinitions;
        final cutoff =
            periodNotifier?.businessDayStartLocalTime ??
            _defaultBusinessDayStartLocalTime;
        final localNow = _restaurantLocalNow(restaurant);
        final activeId = localNow == null
            ? null
            : resolveActiveServicePeriodId(
                localNow: localNow,
                businessDayStartLocalTime: cutoff,
                definitions: definitions,
              );
        final ordered = ServicePeriodDefinitionResolver.ordered(definitions);
        ServicePeriodDefinition? selectedDefinition;
        for (final definition in ordered) {
          if (definition.id == selectedPeriodId) {
            selectedDefinition = definition;
            break;
          }
        }
        final buckets = periodNotifier?.buckets;
        final missingTimezone = periodNotifier?.missingTimezone ?? false;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (missingTimezone)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppColors.backgroundMid, AppColors.cardGlow],
                      ),
                      border: Border.all(
                        color: AppColors.borderSubtle.withValues(alpha: 0.7),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      'Restaurant timezone is not configured. Per-period '
                      'metrics are unavailable until Settings is completed.',
                      style:
                          AppTextStyles.body13(color: AppColors.textSecondary),
                    ),
                  ),
                ),
              if (selectedDefinition == null)
                Text(
                  'Selected service period is unavailable.',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                )
              else ...[
                _DaypartScaffoldCard(
                  definition: selectedDefinition,
                  isActive: selectedDefinition.id == activeId,
                  bucket: buckets?[selectedDefinition.id],
                  primaryLeverCard: periodNotifier?.primaryLeverCardFor(
                    selectedDefinition.id,
                  ),
                  missingTimezone: missingTimezone,
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DaypartScaffoldCard extends StatelessWidget {
  final ServicePeriodDefinition definition;
  final bool isActive;
  final ServicePeriodAccumulator? bucket;
  final LeverCardData? primaryLeverCard;
  final bool missingTimezone;

  const _DaypartScaffoldCard({
    required this.definition,
    required this.isActive,
    required this.bucket,
    this.primaryLeverCard,
    this.missingTimezone = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isActive ? AppColors.sunset : AppColors.borderSubtle;
    final hasData = bucket?.hasAnyData ?? false;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(
          color: accent.withValues(alpha: isActive ? 0.85 : 0.6),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.sunset.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  definition.shortLabel,
                  style: AppTextStyles.mono10(
                    color: AppColors.sunsetDark,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  definition.label,
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${definition.startLocalTime} – ${definition.endLocalTime}',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (hasData) ...[
            _DaypartMetricGrid(bucket: bucket!),
            const SizedBox(height: 10),
            // Phase 10.5.3 — per-period primary driver chip. Resolves
            // through `LeverCards.lookup`; null surfaces as the
            // "No pattern yet" degraded state per 7.58 F-1 / F-6
            // (no silent fall-through to a real lever).
            _DaypartDriverChip(card: primaryLeverCard),
          ] else
            Text(
              missingTimezone
                  ? 'Timezone not configured — metrics unavailable.'
                  : isActive
                  ? 'No data yet for this period.'
                  : 'Projected / unavailable until this period opens.',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
        ],
      ),
    );
  }
}

/// Phase 10.5.3 — per-period primary driver chip rendered alongside
/// the daypart metric grid. Mirrors the Variance daypart lens chip so
/// the two surfaces present the same driver shape.
///
/// Null [card] degrades to "No pattern yet" — never silently falls
/// through to a real lever (`LeverCards.coversDown` overclaim is
/// banned at the daypart scope per 7.58 F-1 / F-6 / F-2).
class _DaypartDriverChip extends StatelessWidget {
  final LeverCardData? card;
  const _DaypartDriverChip({required this.card});

  @override
  Widget build(BuildContext context) {
    final c = card;
    final hasDriver = c != null;
    // Color is favorability (green / red); the arrow is the raw
    // metric direction derived from the lever id suffix
    // (`_up` / `_over` → ↑; `_down` / `_under` → ↓). These are
    // independent: e.g. `foh_wage_down` is favorable (green) but
    // points down (the metric moved down).
    final accent = hasDriver
        ? (c.isFavorable ? AppColors.positive : AppColors.negative)
        : AppColors.textMuted;
    final arrow = hasDriver
        ? (LeverCards.metricDirectionGlyph(c.id) ?? '')
        : '';
    final label = hasDriver
        ? 'PRIMARY DRIVER · ${c.shortLabel} $arrow'
        : 'PRIMARY DRIVER · NO PATTERN YET';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        border: Border.all(color: accent.withValues(alpha: 0.55), width: 1),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono10(
          color: accent,
        ).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Compact 3-row metric grid for a single service-period bucket.
///
/// Layout (per-period, all values are actuals — no plan target on
/// purpose, since per-period plan targets are not yet shipped):
///   row 1: COVERS · SALES
///   row 2: PPA · CPLH · SPLH
///   row 3: HRS (FOH/BOH) · BLENDED WAGE
class _DaypartMetricGrid extends StatelessWidget {
  final ServicePeriodAccumulator bucket;
  const _DaypartMetricGrid({required this.bucket});

  @override
  Widget build(BuildContext context) {
    final fohHrs = (bucket.fohMinutes / 60).toStringAsFixed(
      bucket.fohMinutes % 60 == 0 ? 0 : 1,
    );
    final bohHrs = (bucket.bohMinutes / 60).toStringAsFixed(
      bucket.bohMinutes % 60 == 0 ? 0 : 1,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _MetricCell(label: 'COVERS', value: '${bucket.covers}'),
            ),
            Expanded(
              child: _MetricCell(
                label: 'SALES',
                value: '\$${bucket.sales.toStringAsFixed(0)}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _MetricCell(
                label: 'PPA',
                value: '\$${bucket.ppa.toStringAsFixed(2)}',
              ),
            ),
            Expanded(
              child: _MetricCell(
                label: 'CPLH',
                value: bucket.cplh.toStringAsFixed(2),
              ),
            ),
            Expanded(
              child: _MetricCell(
                label: 'SPLH',
                value: '\$${bucket.splh.toStringAsFixed(0)}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _MetricCell(
                label: 'HRS',
                value: '$fohHrs FOH / $bohHrs BOH',
              ),
            ),
            Expanded(
              child: _MetricCell(
                label: 'BLENDED WAGE',
                value: '\$${bucket.blendedWage.toStringAsFixed(2)}',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MetricCell extends StatelessWidget {
  final String label;
  final String value;
  const _MetricCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.mono10(color: AppColors.textMuted)),
        const SizedBox(height: 2),
        Text(
          value,
          style: AppTextStyles.mono14(
            color: AppColors.textPrimary,
            weight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Restaurant-local now resolver shared by the daypart scaffold and
/// the time-into-service header. Returns null when the scope's IANA
/// timezone is missing or unrecognized — callers must refuse to fall
/// back to the device clock.
DateTime? _restaurantLocalNow(RestaurantLocation? restaurant) {
  final override = ShiftDashboard.clockOverride;
  if (override != null) return override();
  if (restaurant == null) return null;
  final tzName = restaurant.businessTimezone.trim();
  if (tzName.isEmpty) return null;
  _ensureTzInitialized();
  try {
    final loc = tz.getLocation(tzName);
    return tz.TZDateTime.now(loc);
  } on tz.LocationNotFoundException {
    return null;
  }
}

// ─── Time-into-service header (Phase 10.5.2) ────────────────────────────────

/// Thin header strip rendered above the SERVICE PERIODS sticky group
/// when the daypart lens is open. Shows the active period label and
/// elapsed minutes (e.g., "Lunch · 1h 12m in"). Hidden when no period
/// is active (between Lunch and Dinner) or when the restaurant has no
/// usable IANA timezone.
///
/// A4.2 (R2): rebuilds via the dashboard-wide [_ShiftDashboardTicker]
/// (provided at the dashboard root) instead of a local
/// `Timer.periodic`. The shared 30s pulse keeps the elapsed display
/// current without owning its own timer or a snapshot refresh.
class _TimeIntoServiceHeader extends StatelessWidget {
  final String selectedPeriodId;
  final ValueListenable<DateTime> ticker;

  const _TimeIntoServiceHeader({
    required this.selectedPeriodId,
    required this.ticker,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: ticker,
      builder: (context, _, __) {
        final restaurant =
            context.watch<RestaurantScopeNotifier?>()?.restaurant;
        final periodNotifier = context.watch<ShiftServicePeriodNotifier?>();
        final definitions =
            periodNotifier?.definitions ??
            ServicePeriodDefinitionResolver.demoDefinitions;
        final cutoff =
            periodNotifier?.businessDayStartLocalTime ??
            _defaultBusinessDayStartLocalTime;
        final localNow = _restaurantLocalNow(restaurant);
        if (localNow == null) return const SizedBox.shrink();
        final interval = resolveActiveServicePeriodInterval(
          localNow: localNow,
          businessDayStartLocalTime: cutoff,
          definitions: definitions,
        );
        if (interval == null) return const SizedBox.shrink();
        if (interval.definition.id != selectedPeriodId) {
          return const SizedBox.shrink();
        }
        final elapsedMinutes = localNow.difference(interval.start).inMinutes;
        if (elapsedMinutes < 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: AppColors.sunset,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${interval.definition.label} · ${_formatElapsed(elapsedMinutes)} in',
                style: AppTextStyles.mono12(color: AppColors.sunsetDark),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _formatElapsed(int totalMinutes) {
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours == 0) return '${minutes}m';
    return '${hours}h ${minutes}m';
  }
}

// ─── Empty state ────────────────────────────────────────────────────────────

class _ShiftEmptyState extends StatelessWidget {
  final String headline;
  final String body;
  final String? timestamp;
  const _ShiftEmptyState({
    required this.headline,
    required this.body,
    this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              headline,
              style: AppTextStyles.mono14(color: AppColors.textMuted),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            if (timestamp != null) ...[
              const SizedBox(height: 8),
              Text(
                'Last import: $timestamp',
                style: AppTextStyles.mono8(color: AppColors.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LaborCard extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _LaborCard({required this.readModel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.7),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(3),
      ),
      child: _LaborVarianceSection(readModel: readModel),
    );
  }
}

class _LaborVarianceSection extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _LaborVarianceSection({required this.readModel});

  @override
  Widget build(BuildContext context) {
    final actual = readModel.actualLaborPct;
    final target = readModel.targetLaborPct;
    final variancePts = readModel.laborVariancePts;

    final isOver = variancePts > 0;
    final accentColor = isOver ? AppColors.negative : AppColors.positive;
    final ptSign = isOver ? '+' : '\u2212';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label
        Text(
          'LABOR %',
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
        const SizedBox(height: 6),
        // Current value
        Text(
          '${actual.toStringAsFixed(1)}%',
          style: AppTextStyles.mono28(color: accentColor),
        ),
        const SizedBox(height: 3),
        // Target reference
        Text(
          'Theoretical ${target.toStringAsFixed(1)}%',
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        // Delta pill
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isOver ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14,
                color: accentColor,
              ),
              const SizedBox(width: 2),
              Text(
                '$ptSign${variancePts.abs().toStringAsFixed(1)} pts',
                style: AppTextStyles.mono12(
                  color: accentColor,
                  weight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactHoursColumn extends StatelessWidget {
  final String label;
  final int scheduled;
  final int needed;
  final int excess;

  const _CompactHoursColumn({
    required this.label,
    required this.scheduled,
    required this.needed,
    required this.excess,
  });

  @override
  Widget build(BuildContext context) {
    final isOver = excess > 0;
    final deltaColor = isOver ? AppColors.negative : AppColors.positive;
    final deltaIcon = isOver ? Icons.arrow_upward : Icons.arrow_downward;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.7),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label
          Text(label, style: AppTextStyles.mono10(color: AppColors.textMuted)),
          const SizedBox(height: 6),
          // Current value
          Text('$scheduled', style: AppTextStyles.mono28()),
          const SizedBox(height: 3),
          // Target reference
          Text(
            'Target $needed hrs',
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          // Delta pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: deltaColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(deltaIcon, size: 14, color: deltaColor),
                const SizedBox(width: 2),
                Text(
                  '${isOver ? '+' : ''}$excess hrs',
                  style: AppTextStyles.mono12(
                    color: deltaColor,
                    weight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Phase 8.0 V1 lean cut 2 — DataSourceHealthPill mount ─────────────────
//
// Assembles the union of MetricProvenance states across the visible
// dashboard metrics and feeds DataSourceHealthPill. The pill renders
// nothing when every state is `live`; one short line otherwise.

class _ShiftDashboardHealthPill extends StatelessWidget {
  const _ShiftDashboardHealthPill({required this.readModel});

  final ShiftDashboardReadModel readModel;

  @override
  Widget build(BuildContext context) {
    final entries = <DataSourceHealthEntry>[];
    void addIfDegraded(
      String label,
      MetricProvenance prov, {
      String? overrideLine,
    }) {
      if (!prov.isDegraded) return;
      String summary;
      switch (prov.state) {
        case MetricState.unavailable:
          summary = overrideLine ?? '$label: not yet connected';
          break;
        case MetricState.fallback:
          summary = '$label: ${_pillCopyForFallback(prov.provenance)}';
          break;
        case MetricState.partial:
          summary = '$label: partial sync';
          break;
        case MetricState.stale:
          summary = '$label: stale — sync lapsed';
          break;
        case MetricState.empty:
          summary = '$label: no data yet';
          break;
        case MetricState.demo:
        case MetricState.live:
          return;
      }
      entries.add(
        DataSourceHealthEntry(
          metricLabel: label,
          state: prov.state,
          provenance: prov.provenance,
          summaryLine: summary,
        ),
      );
    }

    addIfDegraded('Sales', readModel.salesProvenance);
    addIfDegraded('Covers', readModel.coversProvenance);
    addIfDegraded('PPA', readModel.ppaProvenance);
    addIfDegraded(
      'CPLH',
      readModel.cplhProvenance,
      overrideLine: 'Labor: not yet connected',
    );
    addIfDegraded('SPLH', readModel.splhProvenance);
    addIfDegraded('Blended wage', readModel.blendedWageProvenance);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: DataSourceHealthPill(entries: entries),
      ),
    );
  }

  String _pillCopyForFallback(String provenance) {
    if (provenance.contains('forecast_covers')) {
      return 'covers via forecast';
    }
    if (provenance.contains('fallback_labor_dollars')) {
      return 'labor via wage × hours fallback';
    }
    return 'fallback source';
  }
}
