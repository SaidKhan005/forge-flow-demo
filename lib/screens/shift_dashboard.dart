import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../theme/app_theme.dart';
import '../data/app_defaults.dart';
import '../domain/models/restaurant_location.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/business_date_resolver.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../state/restaurant_scope_notifier.dart';
import '../state/shift_dashboard_notifier.dart';
import '../models/current_state_freshness.dart';
import '../models/shift_dashboard_read_model.dart';
import '../utils/formatters.dart';
import '../widgets/app_screen_header.dart';
import '../widgets/sticky_section_delegate.dart';
import '../widgets/zone_status_card.dart';
import '../widgets/input_metric_card.dart';
import '../widgets/sales_forecast_card.dart';

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

/// Shift surface scope selector.
///
/// Phase 10.5: whole-day is the default and the source of truth; daypart
/// is an additive lens that opens alongside it. The bucketing engine and
/// per-period live metrics land in subsequent 10.5 slices; this scaffold
/// only opens the surface.
enum ShiftScope { wholeDay, daypart }

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
  ShiftScope _scope = ShiftScope.wholeDay;

  void _setScope(ShiftScope next) {
    if (_scope == next) return;
    setState(() => _scope = next);
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
        final rm = notifier.readModel;
        if (rm == null) {
          return RefreshIndicator(
            color: AppColors.sunset,
            onRefresh: () => notifier.refresh(),
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
          ),
          child: RefreshIndicator(
            color: AppColors.sunset,
            onRefresh: () => notifier.refresh(),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _ShiftScopeToggle(
                    scope: _scope,
                    onChanged: _setScope,
                  ),
                ),
                if (_scope == ShiftScope.wholeDay) ..._wholeDaySlivers(rm),
                if (_scope == ShiftScope.daypart) ..._daypartSlivers(),
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
          SliverToBoxAdapter(
            child: _OutputsSection(readModel: rm),
          ),
        ],
      ),
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: StickySectionDelegate('SHIFT INPUTS'),
          ),
          SliverToBoxAdapter(
            child: _InputsSection(readModel: rm),
          ),
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
              ),
            ),
          ),
        ],
      ),
    ];
  }

  /// Daypart scaffold — surface-only seam for slice 10.5.0. Renders the
  /// service-period strip from [ServicePeriodDefinitionResolver.demoDefinitions]
  /// so the operator can see the lens exists and which period is live; the
  /// live bucketing engine, per-period metrics, and primary-driver teaching
  /// land in subsequent 10.5 slices. The scaffold owns its own
  /// restaurant-local clock and ticker — see [_DaypartScaffoldSection].
  List<Widget> _daypartSlivers() {
    return [
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: StickySectionDelegate('SERVICE PERIODS'),
          ),
          const SliverToBoxAdapter(
            child: _DaypartScaffoldSection(
              definitions:
                  ServicePeriodDefinitionResolver.demoDefinitions,
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
  const _ShiftHeader({required this.readModel, this.freshness});

  @override
  Widget build(BuildContext context) {
    final restaurantName =
        context.watch<RestaurantScopeNotifier?>()?.restaurant?.displayName ??
            'Restaurant';
    return AppScreenHeader(
      title: restaurantName,
      trailing: const _LiveClock(),
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
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
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
                style:
                    AppTextStyles.mono12(color: AppColors.sunsetDark),
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

// ─── Live clock ─────────────────────────────────────────────────────────────

/// Ticking wall-clock display for the Shift header.
///
/// Shows the current time formatted as `h:mm AM/PM`. Ticks every 30 seconds.
/// Uses [ShiftDashboard.clockOverride] when set (test seam), otherwise
/// [DateTime.now].
///
/// This is display-only — it does not determine business date, shift status,
/// or daypart. Those remain snapshot-driven through the read model.
class _LiveClock extends StatefulWidget {
  const _LiveClock();

  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  late DateTime _now;
  Timer? _timer;

  DateTime _currentTime() =>
      (ShiftDashboard.clockOverride ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _now = _currentTime();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      setState(() => _now = _currentTime());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hour = _now.hour % 12 == 0 ? 12 : _now.hour % 12;
    final minute = _now.minute.toString().padLeft(2, '0');
    final amPm = _now.hour >= 12 ? 'PM' : 'AM';
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
        Text(
          amPm,
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
      ],
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
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
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
              Text(label, style: AppTextStyles.mono14(color: AppColors.textPrimary, weight: FontWeight.w700)),
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

class _OutputsSection extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _OutputsSection({required this.readModel});

  @override
  Widget build(BuildContext context) {
    // Extract output metric cards: COVERS and BLENDED WAGE
    final coversCard = readModel.metricCards.where((m) => m.name == 'COVERS').toList();
    final wageCard = readModel.metricCards.where((m) => m.name == 'BLENDED WAGE').toList();

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
                Expanded(
                  child: _LaborCard(readModel: readModel),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // ── Covers + Blended Wage side by side ──
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (coversCard.isNotEmpty)
                  Expanded(child: InputMetricCard(metric: coversCard.first)),
                const SizedBox(width: 8),
                if (wageCard.isNotEmpty)
                  Expanded(child: InputMetricCard(metric: wageCard.first)),
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
    // Input metric cards: PPA, CPLH, SPLH (exclude COVERS and BLENDED WAGE)
    final inputCards = readModel.metricCards
        .where((m) => m.name != 'COVERS' && m.name != 'BLENDED WAGE')
        .toList();

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
          // PPA, CPLH, SPLH in grid
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.05,
            children:
                inputCards.map((m) => InputMetricCard(metric: m)).toList(),
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
            color: AppColors.borderSubtle.withValues(alpha: 0.7), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lever.metric,
            style: AppTextStyles.mono14(
                color: AppColors.textPrimary, weight: FontWeight.w600),
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

/// Segmented control that switches the Shift surface between the
/// authoritative whole-day view and the additive daypart lens.
///
/// Whole-day stays selected by default and stays the source of truth;
/// the daypart selection opens a parallel lens without removing or
/// rewriting the whole-day path. See `phase_10_5_*.md` for the full
/// scope contract.
class _ShiftScopeToggle extends StatelessWidget {
  final ShiftScope scope;
  final ValueChanged<ShiftScope> onChanged;

  const _ShiftScopeToggle({required this.scope, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: _ScopePill(
              label: 'Whole Day',
              selected: scope == ShiftScope.wholeDay,
              onTap: () => onChanged(ShiftScope.wholeDay),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ScopePill(
              label: 'Daypart',
              selected: scope == ShiftScope.daypart,
              onTap: () => onChanged(ShiftScope.daypart),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScopePill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ScopePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = selected ? AppColors.sunset : AppColors.backgroundMid;
    final borderColor = selected
        ? AppColors.sunsetDark
        : AppColors.borderSubtle.withValues(alpha: 0.7);
    final textColor =
        selected ? AppColors.textPrimary : AppColors.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: bgColor,
            border: Border.all(color: borderColor, width: 1),
            borderRadius: BorderRadius.circular(2),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppTextStyles.mono12(
              color: textColor,
              weight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Daypart scaffold (Phase 10.5.0) ────────────────────────────────────────

/// Surface-only scaffold for the daypart lens.
///
/// Renders one card per restaurant-scoped service-period definition
/// (Lunch, Dinner, Late Night from the demo defaults) plus a banner
/// reminding the operator that whole-day stays authoritative.
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
/// Has its own `Timer.periodic` (default 30s) so the chip stays
/// accurate when the operator parks on the daypart view across a
/// service-period boundary (e.g. Lunch → no-period → Dinner).
///
/// This intentionally has no live metrics — the bucketing engine and
/// per-period numbers come from later 10.5 slices. The job of this
/// slice is to open the surface seam without replacing whole-day.
class _DaypartScaffoldSection extends StatefulWidget {
  final List<ServicePeriodDefinition> definitions;

  const _DaypartScaffoldSection({required this.definitions});

  @override
  State<_DaypartScaffoldSection> createState() =>
      _DaypartScaffoldSectionState();
}

class _DaypartScaffoldSectionState extends State<_DaypartScaffoldSection> {
  /// Refresh interval for the active-period chip. Matches the live
  /// header clock's 30-second cadence so both stay in sync.
  static const Duration _tickInterval = Duration(seconds: 30);

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(_tickInterval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Restaurant-local now. Returns null when the restaurant scope or
  /// its IANA timezone is unavailable — caller renders no `ACTIVE NOW`
  /// chip in that case (no fallback to the device clock).
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

  /// Resolves the active service-period id for [localNow] using the
  /// **business-date weekday** (not the wall-clock weekday). Pure;
  /// safe to call from the build path.
  static String? _resolveActivePeriodId({
    required DateTime localNow,
    required String businessDayStartLocalTime,
    required List<ServicePeriodDefinition> definitions,
  }) {
    final businessDateIso = BusinessDateResolver.resolve(
      localTimestamp: localNow,
      businessDayStartLocalTime: businessDayStartLocalTime,
    );
    final businessDate = DateTime.parse(businessDateIso);
    final businessWeekday = businessDate.weekday; // 1 = Mon ... 7 = Sun
    final minutes = localNow.hour * 60 + localNow.minute;
    for (final d in definitions) {
      if (!d.applicableDays.contains(businessWeekday)) continue;
      final start = _parseHm(d.startLocalTime);
      final end = _parseHm(d.endLocalTime);
      if (start == null || end == null) continue;
      if (d.rollsPastMidnight) {
        if (minutes >= start || minutes <= end) return d.id;
      } else {
        if (minutes >= start && minutes <= end) return d.id;
      }
    }
    return null;
  }

  static int? _parseHm(String hm) {
    final parts = hm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  @override
  Widget build(BuildContext context) {
    final restaurant =
        context.watch<RestaurantScopeNotifier?>()?.restaurant;
    final localNow = _restaurantLocalNow(restaurant);
    final activeId = localNow == null
        ? null
        : _resolveActivePeriodId(
            localNow: localNow,
            // Business-day cutoff defaults to 04:00 until the
            // RestaurantTimingConfig wiring lands in this widget tree
            // (deferred-foundation work the phase 10.5 plan calls out).
            businessDayStartLocalTime: _defaultBusinessDayStartLocalTime,
            definitions: widget.definitions,
          );
    final ordered =
        ServicePeriodDefinitionResolver.ordered(widget.definitions);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
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
              'Whole-day Shift remains the source of truth. Live daypart '
              'projections build out in upcoming 10.5 slices.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: 8),
          for (final def in ordered) ...[
            _DaypartScaffoldCard(
              definition: def,
              isActive: def.id == activeId,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _DaypartScaffoldCard extends StatelessWidget {
  final ServicePeriodDefinition definition;
  final bool isActive;

  const _DaypartScaffoldCard({
    required this.definition,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isActive ? AppColors.sunset : AppColors.borderSubtle;
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
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.sunset.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  definition.shortLabel,
                  style: AppTextStyles.mono10(color: AppColors.sunsetDark)
                      .copyWith(fontWeight: FontWeight.w700),
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
              if (isActive) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.sunset.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    'ACTIVE NOW',
                    style: AppTextStyles.mono8(color: AppColors.sunsetDark)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Daypart bucketing not yet wired.',
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
        ],
      ),
    );
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
            Text(headline,
                style: AppTextStyles.mono14(color: AppColors.textMuted)),
            const SizedBox(height: 8),
            Text(body,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
                textAlign: TextAlign.center),
            if (timestamp != null) ...[
              const SizedBox(height: 8),
              Text('Last import: $timestamp',
                  style: AppTextStyles.mono8(color: AppColors.textMuted)),
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
            color: AppColors.borderSubtle.withValues(alpha: 0.7), width: 1),
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
        Text('LABOR %',
            style: AppTextStyles.mono10(color: AppColors.textMuted)),
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
          padding: const EdgeInsets.symmetric(
              horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isOver ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14, color: accentColor),
              const SizedBox(width: 2),
              Text(
                '$ptSign${variancePts.abs().toStringAsFixed(1)} pts',
                style: AppTextStyles.mono12(
                    color: accentColor, weight: FontWeight.w700),
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
          Text(label,
              style: AppTextStyles.mono10(color: AppColors.textMuted)),
          const SizedBox(height: 6),
          // Current value
          Text('$scheduled',
              style: AppTextStyles.mono28()),
          const SizedBox(height: 3),
          // Target reference
          Text('Target $needed hrs',
              style: AppTextStyles.mono10(color: AppColors.textMuted)),
          const SizedBox(height: 8),
          // Delta pill
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 6, vertical: 2),
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
                      color: deltaColor, weight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
