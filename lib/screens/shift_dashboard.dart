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
import '../services/integration/shift_vendor_source_resolver.dart';
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
                  ..._servicePeriodSlivers(
                    context,
                    _selectedServicePeriodId!,
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 48)),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Builds the three pinned-header section groups from a
  /// [_ShiftSectionViewData]. This is the SINGLE structural grammar both
  /// lenses emit — whole-day and daypart differ only in the header
  /// labels and the projected data, never the widget tree. iOS
  /// UITableView-style: each [SliverMainAxisGroup] bundles a header +
  /// its content so the next group's header pushes the previous group
  /// off (no stacking).
  List<Widget> _sectionGroups({
    required _ShiftSectionViewData data,
    required String outputsLabel,
    required String inputsLabel,
    required String fohLabel,
  }) {
    return [
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: StickySectionDelegate(outputsLabel),
          ),
          SliverToBoxAdapter(child: _OutputsSection(data: data)),
        ],
      ),
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: StickySectionDelegate(inputsLabel),
          ),
          SliverToBoxAdapter(child: _InputsSection(data: data)),
        ],
      ),
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: StickySectionDelegate(fohLabel),
          ),
          SliverToBoxAdapter(child: _FohProductivitySection(data: data)),
        ],
      ),
    ];
  }

  /// Whole-day slivers — byte-untouched metric render (Promise 3 /
  /// Layer 9). Whole-day Shift is authoritative; daypart is additive.
  /// The shared section widgets consume the whole-day projection, which
  /// reproduces the pre-refactor inline render exactly.
  ///
  /// The leading primary-driver chip is additive chrome only — it
  /// displays the already-computed `rm.primaryLeverCard` (the read
  /// model resolves it through `LeverCards.lookup` in `buildWholeDay`;
  /// no new metric math here). It is positioned to mirror the daypart
  /// lens, where `_DaypartPeriodHeader`'s `_DaypartDriverChip` sits
  /// directly above the section groups, so the two lenses read as a
  /// true 1:1. The chip uses the SAME `_DaypartDriverChip` widget and
  /// its existing null → "No pattern yet" degraded state (7.58 F-1 /
  /// F-6); whole-day always determines a lever so it shows a real
  /// driver, never a phantom.
  List<Widget> _wholeDaySlivers(ShiftDashboardReadModel rm) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _DaypartDriverChip(card: rm.primaryLeverCard),
          ),
        ),
      ),
      ..._sectionGroups(
        data: _ShiftSectionViewData.fromWholeDay(rm),
        outputsLabel: 'SHIFT OUTPUTS',
        inputsLabel: 'SHIFT INPUTS',
        fohLabel: 'FOH PRODUCTIVITY',
      ),
    ];
  }

  /// Daypart slivers — a TRUE 1:1 of [_wholeDaySlivers]: the SAME three
  /// pinned-header section groups, the SAME section widgets, scoped to
  /// the selected period via [_ShiftSectionViewData.fromPeriod]. The
  /// period's identity + closed/active/future status renders as a
  /// compact header element above the sections (not a bordered card
  /// wrapping everything). The time-into-service header
  /// ("Lunch · 1h 12m in") sits above that and only renders when the
  /// period is active.
  List<Widget> _servicePeriodSlivers(
    BuildContext context,
    String selectedPeriodId,
  ) {
    final periodNotifier = context.watch<ShiftServicePeriodNotifier?>();
    final definitions = periodNotifier?.definitions ??
        ServicePeriodDefinitionResolver.demoDefinitions;
    ServicePeriodDefinition? selectedDefinition;
    for (final d in ServicePeriodDefinitionResolver.ordered(definitions)) {
      if (d.id == selectedPeriodId) {
        selectedDefinition = d;
        break;
      }
    }

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _TimeIntoServiceHeader(
          selectedPeriodId: selectedPeriodId,
          ticker: _ticker,
        ),
      ),
      SliverToBoxAdapter(
        child: _DaypartPeriodHeader(
          selectedPeriodId: selectedPeriodId,
          ticker: _ticker,
        ),
      ),
    ];

    if (selectedDefinition != null) {
      final bucket = periodNotifier?.buckets?[selectedDefinition.id] ??
          ServicePeriodAccumulator(servicePeriodId: selectedDefinition.id);
      final targetContext =
          periodNotifier?.daypartTargetFor(selectedDefinition.id) ??
              DaypartTargetContext.none;

      // Per-location vendor provenance + period lifecycle (Defects 2 & 3).
      // Same fixture-derived resolver the whole-day path and the
      // DemoModeBanner use — no parallel signal, no kDemoMode fork.
      final restaurant =
          context.watch<RestaurantScopeNotifier?>()?.restaurant;
      final restaurantId = restaurant?.restaurantId;
      final vendorSource = restaurantId == null
          ? ShiftVendorSource.none
          : ShiftVendorSourceResolver.forLocation(restaurantId);
      final cutoff = periodNotifier?.businessDayStartLocalTime ??
          _defaultBusinessDayStartLocalTime;
      final localNow = _restaurantLocalNow(restaurant);
      final periodNotStartedYet = localNow != null &&
          resolveServicePeriodPhase(
                localNow: localNow,
                businessDayStartLocalTime: cutoff,
                definitions: definitions,
                periodId: selectedDefinition.id,
              ) ==
              ServicePeriodPhase.future;

      slivers.addAll(
        _sectionGroups(
          data: _ShiftSectionViewData.fromPeriod(
            bucket,
            targetContext,
            vendorSource: vendorSource,
            periodNotStartedYet: periodNotStartedYet,
          ),
          outputsLabel: 'OUTPUTS',
          inputsLabel: 'INPUTS',
          fohLabel: 'FOH PRODUCTIVITY',
        ),
      );
    }

    return slivers;
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

// ─── Section view-data adapter (true 1:1 daypart ↔ whole-day) ───────────────
//
// The three Shift section widgets (`_OutputsSection`, `_InputsSection`,
// `_FohProductivitySection`) are data-source-agnostic: they consume a
// [_ShiftSectionViewData] value type that BOTH the whole-day
// [ShiftDashboardReadModel] and a per-period
// (`ServicePeriodAccumulator` + `DaypartTargetContext`) bucket project
// into. This is what makes the daypart lens a byte-for-byte structural
// mirror of the whole-day lens — the SAME widgets, not a lookalike.
//
// Whole-day projection reproduces the pre-refactor render exactly (all
// fields non-null where the whole-day card always drew a number), so
// Promise 3 / Layer 9 holds: whole-day is byte-untouched. The per-period
// projection carries honest nulls so the shared widgets fall back to the
// same "—" / "Connect a … vendor" empty states the whole-day card uses
// (Design Rule 2 + Metric Honesty Doctrine).

/// Labor % tile inputs. `actualPct` is null when labor is not connected
/// (no in-period minutes, or no sales divisor) — the shared card then
/// renders "—" instead of a phantom `0.0%`. `theoreticalPct` is null
/// when the cycle wrote no per-period theoretical row (Gap 42); the
/// sub-line + delta pill hide rather than draw `Theoretical 0.0%`.
class _LaborVarianceData {
  final double? actualPct;
  final double? theoreticalPct;
  final double? variancePts;
  const _LaborVarianceData({
    this.actualPct,
    this.theoreticalPct,
    this.variancePts,
  });
}

/// FOH/BOH hours column inputs. [value] is the already-formatted current
/// figure (an int string for whole-day scheduled hours, a 1-dp hours
/// string or "—" for a period). [needed]/[excess] are null for a period
/// (no scheduled-vs-needed target is tracked per period yet) — the
/// shared column then renders the value alone, never a fabricated
/// `Target 0 hrs` (Design Rule 2). Whole-day always supplies both.
class _HoursColumnData {
  final String value;
  final int? needed;
  final int? excess;
  const _HoursColumnData({required this.value, this.needed, this.excess});
}

/// OPZ band inputs for the FOH PRODUCTIVITY section. Null on the parent
/// [_ShiftSectionViewData] means "no locked productivity zone" — the
/// shared section renders the honest no-zone line instead of a band
/// drawn off a `0` anchor. Whole-day always has a band (profile floor/
/// ceiling), so it never hits the null branch.
class _OpzBandData {
  final double currentCPLH;
  final double opzFloorCPLH;
  final double opzCeilingCPLH;
  final double targetCPLH;
  final String opzStatus;
  final String opzLabel;
  final String opzSubLabel;
  final String? splhState;
  const _OpzBandData({
    required this.currentCPLH,
    required this.opzFloorCPLH,
    required this.opzCeilingCPLH,
    required this.targetCPLH,
    required this.opzStatus,
    required this.opzLabel,
    required this.opzSubLabel,
    this.splhState,
  });
}

/// The single render contract for the three Shift sections. Whole-day
/// and per-period both project into this; the section widgets never
/// branch on which source produced it.
class _ShiftSectionViewData {
  // OUTPUTS
  final double currentSales;
  final double forecastSales;
  final _LaborVarianceData labor;
  final MetricProvenance covers;
  final MetricProvenance blendedWage;
  // INPUTS
  final MetricProvenance ppa;
  final MetricProvenance cplh;
  final MetricProvenance splh;
  final _HoursColumnData fohHours;
  final _HoursColumnData bohHours;
  // FOH PRODUCTIVITY
  final _OpzBandData? opz;

  // Per-location vendor + period lifecycle context (Defects 2 & 3).
  // Whole-day leaves these at the defaults so its render is byte-
  // identical; the per-period path supplies the real per-(operator,
  // location, category) signal so an unavailable pill explains itself
  // honestly: genuinely-not-connected vs the period simply not having
  // started yet today.
  final bool posConnected;
  final bool laborConnected;
  final bool periodNotStartedYet;

  // Fix #839 D2/D3: true only for fixture-governed (demo) locations.
  // The pre-service ("hasn't started yet") branch in
  // [unavailableTooltip] fires ONLY when this is true, so an unknown
  // (production) location keeps the verbatim "Connect a … vendor" copy
  // byte-unchanged even though production `laborConnected` is now `true`
  // under the value-based fallback (authority doc §4.2 / §6.4 — no
  // production messaging regression).
  final bool fixtureGoverned;

  const _ShiftSectionViewData({
    required this.currentSales,
    required this.forecastSales,
    required this.labor,
    required this.covers,
    required this.blendedWage,
    required this.ppa,
    required this.cplh,
    required this.splh,
    required this.fohHours,
    required this.bohHours,
    required this.opz,
    this.posConnected = true,
    this.laborConnected = true,
    this.periodNotStartedYet = false,
    this.fixtureGoverned = false,
  });

  /// Honest unavailable-state copy for a metric pill. Three states:
  ///   (i)  vendor genuinely not connected for this location → the
  ///        verbatim prior "Connect a POS/labor vendor to see ..."
  ///        copy (no regression for not-connected);
  ///   (ii) vendor connected but the service period has not started yet
  ///        today → an honest pre-service line (never mislabels a
  ///        not-connected vendor as "hasn't started");
  ///   (iii) otherwise (period over / genuine zero) → the existing
  ///        connect copy is the honest-zero fallback, unchanged.
  String unavailableTooltip({
    required bool isLabor,
    required String metricPhrase,
  }) {
    final connected = isLabor ? laborConnected : posConnected;
    // Fix #839 D3: the pre-service line is a demo-only affordance —
    // gate it on `fixtureGoverned` so an unknown (production) location
    // (where `laborConnected` is now `true` under the value-based
    // fallback) never flips to "hasn't started yet"; production keeps
    // the verbatim "Connect a … vendor" copy byte-unchanged (authority
    // doc §4.2 / §6.4). Demo governed locations behave exactly as
    // before.
    if (fixtureGoverned && connected && periodNotStartedYet) {
      return "This service period hasn't started yet today — "
          'numbers appear here once service begins.';
    }
    return 'Connect a ${isLabor ? 'labor' : 'POS'} vendor to see '
        '$metricPhrase.';
  }

  /// Whole-day projection — reproduces the pre-refactor whole-day render
  /// exactly. Every field that the whole-day card always drew is
  /// non-null, so the shared widgets render byte-identically to the old
  /// inline whole-day path.
  factory _ShiftSectionViewData.fromWholeDay(ShiftDashboardReadModel rm) {
    return _ShiftSectionViewData(
      currentSales: rm.currentSales,
      forecastSales: rm.forecastSales,
      labor: _LaborVarianceData(
        actualPct: rm.actualLaborPct,
        theoreticalPct: rm.targetLaborPct,
        variancePts: rm.laborVariancePts,
      ),
      covers: rm.coversProvenance,
      blendedWage: rm.blendedWageProvenance,
      ppa: rm.ppaProvenance,
      cplh: rm.cplhProvenance,
      splh: rm.splhProvenance,
      fohHours: _HoursColumnData(
        value: '${rm.scheduledFohHours}',
        needed: rm.planFohHours,
        excess: rm.scheduledFohHours - rm.planFohHours,
      ),
      bohHours: _HoursColumnData(
        value: '${rm.scheduledBohHours}',
        needed: rm.planBohHours,
        excess: rm.scheduledBohHours - rm.planBohHours,
      ),
      opz: _OpzBandData(
        currentCPLH: rm.actualCPLH,
        opzFloorCPLH: rm.opzFloorCPLH,
        opzCeilingCPLH: rm.opzCeilingCPLH,
        targetCPLH: rm.targetCPLH,
        opzStatus: rm.opzStatus,
        opzLabel: rm.opzLabel,
        opzSubLabel: rm.opzSubLabel,
        splhState: rm.splhState,
      ),
    );
  }

  /// Per-period projection. Honest nulls everywhere a number cannot be
  /// derived so the shared widgets degrade to "—" / the connect copy /
  /// the no-zone line — never a phantom `0` (Design Rule 2 + Metric
  /// Honesty Doctrine). Gap-42 fallback (empty per-period rows → no
  /// locked target) is honored here: a null [DaypartTargetContext]
  /// field flows straight through to a hidden sub-line / no band.
  factory _ShiftSectionViewData.fromPeriod(
    ServicePeriodAccumulator bucket,
    DaypartTargetContext tc, {
    ShiftVendorSource vendorSource = ShiftVendorSource.none,
    bool periodNotStartedYet = false,
  }) {
    // Defect 2 — per-period labor must honest-degrade per location:
    // a location whose Labor category is NOT connected (e.g. Harbour,
    // North Loop) must not render labor actuals even though the bucket
    // carries minutes. ANDed ALONGSIDE the existing value gate; POS /
    // covers / sales behavior is untouched.
    //
    // Fix #839 D2 (authority doc §4.2 / §6.4): the per-location
    // connection suppression applies ONLY to fixture-governed (demo)
    // locations. An unknown (production) location is NOT
    // fixture-governed, so `laborConnected` stays `true` here and the
    // per-period render keeps the EXACT prior value-based behavior the
    // investigation §4.2 calls "correct" — no production
    // rendering-semantics regression. Demo governed locations resolve
    // to their real per-(operator, location, category) connection.
    final laborConnected =
        !vendorSource.fixtureGoverned || vendorSource.laborConnected;
    // Per-period SALES forecast footer — true 1:1 with whole-day, which
    // uses the plan-side `rm.forecastSales`. Prefer the locked
    // per-daypart `forecast_sales` from the in-force WeeklyPlanSnapshot
    // (`tc.forecastSales`): that is the honest per-daypart benchmark and
    // — like whole-day — is present pre-service (it does not depend on
    // in-period actuals). Fall back to the prior derived
    // `covers × locked per-period PPA target` only when the snapshot
    // carries no per-period row, so no existing demo state regresses.
    // All sources absent → 0 → SalesForecastCard's honest "No forecast
    // available", never a 0-anchored progress bar (Design Rule 2).
    final ppaTarget = tc.targetPPA;
    final forecastSales = tc.forecastSales ??
        (ppaTarget != null ? bucket.covers * ppaTarget : 0.0);

    // Labor % is honest only when BOTH labor punches and sales exist.
    final actualLaborDollars = bucket.fohWageDollars + bucket.bohWageDollars;
    final double? actualPct =
        (laborConnected && bucket.totalMinutes > 0 && bucket.sales > 0)
            ? actualLaborDollars / bucket.sales * 100
            : null;
    final double? theoreticalPct = tc.theoreticalLaborPct;
    final double? variancePts = (actualPct != null && theoreticalPct != null)
        ? actualPct - theoreticalPct
        : null;

    // Live per-period metrics reuse the demo whole-day provenance string
    // so the small source label under the value reads identically to the
    // whole-day pill (same synthesized canonical facts behind both).
    MetricProvenance liveOr(bool ok, num value) => ok
        ? MetricProvenance.live(value: value, provenance: 'vendor_unknown')
        : const MetricProvenance.unavailable();

    final hasLabor = laborConnected && bucket.totalMinutes > 0;
    final hasCovers = bucket.covers > 0;

    _OpzBandData? opz;
    if (tc.hasOpzBand) {
      final floor = tc.opzFloorCPLH!;
      final ceiling = tc.opzCeilingCPLH!;
      final target = tc.targetCPLH!;
      if (!hasLabor) {
        // Locked band exists but NO in-period labor punches yet. Do NOT
        // score the period off a phantom `0.0` CPLH — that previously
        // rendered an alarming "BELOW OPZ" verdict + a 0.0 needle for a
        // period that simply has no actuals in yet (Metric Honesty
        // Doctrine / Design Rule 2: missing actuals → honest pending
        // state, never a verdict computed off a sentinel zero). The band
        // is still shown (floor/ceiling/target) so the operator sees the
        // locked standard; `'pending'` makes ZoneStatusCard suppress the
        // needle, dash the CURRENT CPLH value, and neutralize the label.
        // Honest reason for the suppressed score (Defect 2): a Labor
        // vendor that is genuinely not connected for this location must
        // not read as merely "waiting on punches" — that would imply
        // data is coming when it is not. The band (locked standard) is
        // still shown either way; only the reason copy differs.
        opz = _OpzBandData(
          currentCPLH: 0.0, // sentinel — not rendered in the pending state
          opzFloorCPLH: floor,
          opzCeilingCPLH: ceiling,
          targetCPLH: target,
          opzStatus: 'pending',
          opzLabel:
              laborConnected ? 'AWAITING ACTUALS' : 'LABOR NOT CONNECTED',
          opzSubLabel: laborConnected
              ? 'Locked productivity zone is set. Waiting on labor punches '
                  'for this period before scoring.'
              : 'Locked productivity zone is set. Connect a labor vendor '
                  "to score this period's productivity.",
        );
      } else {
        final currentCplh = bucket.cplh;
        final status = currentCplh < floor
            ? 'below'
            : currentCplh > ceiling
                ? 'above'
                : 'in';
        final label = status == 'below'
            ? 'BELOW OPZ'
            : status == 'above'
                ? 'ABOVE OPZ'
                : 'IN OPZ';
        final sub = status == 'below'
            ? 'Productivity is below the OPZ floor. Too many labor hours '
                'for the volume.'
            : status == 'above'
                ? 'Productivity is above the OPZ ceiling. Service quality '
                    'may suffer.'
                : 'Team is producing. Watch covers.';
        opz = _OpzBandData(
          currentCPLH: currentCplh,
          opzFloorCPLH: floor,
          opzCeilingCPLH: ceiling,
          targetCPLH: target,
          opzStatus: status,
          opzLabel: label,
          opzSubLabel: sub,
        );
      }
    }

    String hrs(int minutes) => minutes > 0
        ? (minutes / 60).toStringAsFixed(minutes % 60 == 0 ? 0 : 1)
        : '—';

    // FOH/BOH HRS "Target N hrs" footer — true 1:1 with the whole-day
    // `_CompactHoursColumn`, fed by the locked per-daypart
    // `required_*_hours` from the in-force WeeklyPlanSnapshot
    // (`tc.requiredFohHours`/`requiredBohHours`). The shared widget
    // renders the target sub-line + delta pill only when BOTH `needed`
    // and `excess` are non-null; we populate them solely when (a) a
    // locked per-daypart required-hours value exists AND (b) the period
    // has in-period labor minutes. With no actuals in yet there is no
    // honest current figure to diff, so — exactly like the OPZ
    // "AWAITING ACTUALS" rule — we suppress the verdict rather than
    // score it off a phantom `0` (Design Rule 2 / Metric Honesty). No
    // locked value → value alone, never a fabricated `Target 0 hrs`
    // (the existing honest-degrade is preserved). The `excess`
    // subtraction is the same trivial display delta `fromWholeDay`
    // computes inline (`scheduled − plan`), not a metric formula.
    _HoursColumnData hoursColumn(int minutes, double? requiredHours) {
      if (requiredHours == null || minutes <= 0) {
        return _HoursColumnData(value: hrs(minutes));
      }
      final needed = requiredHours.round();
      final actualHrs = (minutes / 60).round();
      return _HoursColumnData(
        value: hrs(minutes),
        needed: needed,
        excess: actualHrs - needed,
      );
    }

    return _ShiftSectionViewData(
      currentSales: bucket.sales,
      forecastSales: forecastSales,
      labor: _LaborVarianceData(
        actualPct: actualPct,
        theoreticalPct: theoreticalPct,
        variancePts: variancePts,
      ),
      covers: liveOr(hasCovers, bucket.covers),
      blendedWage: liveOr(hasLabor, bucket.blendedWage),
      ppa: liveOr(hasCovers, bucket.ppa),
      cplh: liveOr(hasLabor, bucket.cplh),
      splh: liveOr(hasLabor, bucket.splh),
      fohHours: hoursColumn(bucket.fohMinutes, tc.requiredFohHours),
      bohHours: hoursColumn(bucket.bohMinutes, tc.requiredBohHours),
      opz: opz,
      posConnected: vendorSource.posConnected,
      laborConnected: laborConnected,
      periodNotStartedYet: periodNotStartedYet,
      fixtureGoverned: vendorSource.fixtureGoverned,
    );
  }
}

/// Test-only probe over the private per-period projection (Defects 2 &
/// 3). Mirrors exactly the fields the section widgets render so the
/// acceptance tests can pin per-location honest-degrade + the 3-state
/// unavailable copy without standing up the full provider widget tree.
/// Same `@visibleForTesting` testing-seam pattern as
/// [ShiftDashboard.clockOverride].
@visibleForTesting
class ShiftPeriodProvenanceProbe {
  const ShiftPeriodProvenanceProbe({
    required this.coversState,
    required this.ppaState,
    required this.blendedWageState,
    required this.cplhState,
    required this.splhState,
    required this.laborActualPctPresent,
    required this.opzLabel,
    required this.posUnavailableCopy,
    required this.laborUnavailableCopy,
  });

  final MetricState coversState;
  final MetricState ppaState;
  final MetricState blendedWageState;
  final MetricState cplhState;
  final MetricState splhState;
  final bool laborActualPctPresent;
  final String? opzLabel;
  final String posUnavailableCopy;
  final String laborUnavailableCopy;
}

@visibleForTesting
ShiftPeriodProvenanceProbe debugShiftPeriodProvenance({
  required ServicePeriodAccumulator bucket,
  required DaypartTargetContext tc,
  ShiftVendorSource vendorSource = ShiftVendorSource.none,
  bool periodNotStartedYet = false,
}) {
  final d = _ShiftSectionViewData.fromPeriod(
    bucket,
    tc,
    vendorSource: vendorSource,
    periodNotStartedYet: periodNotStartedYet,
  );
  return ShiftPeriodProvenanceProbe(
    coversState: d.covers.state,
    ppaState: d.ppa.state,
    blendedWageState: d.blendedWage.state,
    cplhState: d.cplh.state,
    splhState: d.splh.state,
    laborActualPctPresent: d.labor.actualPct != null,
    opzLabel: d.opz?.opzLabel,
    posUnavailableCopy:
        d.unavailableTooltip(isLabor: false, metricPhrase: 'covers'),
    laborUnavailableCopy:
        d.unavailableTooltip(isLabor: true, metricPhrase: 'blended wage'),
  );
}

class _OutputsSection extends StatelessWidget {
  final _ShiftSectionViewData data;
  const _OutputsSection({required this.data});

  @override
  Widget build(BuildContext context) {
    // feat(11W.metric-pill): converted from InputMetricCard /
    // MetricCardNotYetAvailable conditional to MetricPill, which
    // enforces state + provenance at the widget boundary.
    final coversProv = data.covers;
    final wageProv = data.blendedWage;

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
                    currentSales: data.currentSales,
                    forecastSales: data.forecastSales,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _LaborCard(labor: data.labor)),
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
                      unavailableTooltip: data.unavailableTooltip(
                        isLabor: false,
                        metricPhrase: 'covers',
                      ),
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
                      unavailableTooltip: data.unavailableTooltip(
                        isLabor: true,
                        metricPhrase: 'blended wage',
                      ),
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
  final _ShiftSectionViewData data;
  const _InputsSection({required this.data});

  @override
  Widget build(BuildContext context) {
    // feat(11W.metric-pill): converted from InputMetricCard /
    // MetricCardNotYetAvailable conditional to MetricPill for PPA,
    // CPLH, and SPLH. Provenance state flows from the section
    // view-data (whole-day read model OR a per-period bucket);
    // no state is hardcoded as live.
    final ppaProv = data.ppa;
    final cplhProv = data.cplh;
    final splhProv = data.splh;

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
                  unavailableTooltip: data.unavailableTooltip(
                    isLabor: false,
                    metricPhrase: 'per-person average',
                  ),
                ),
                label: 'PPA',
                value: ppaProv.value,
                formatter: (v) => '\$${v.toStringAsFixed(2)}',
              ),
              MetricPill(
                state: cplhProv.state,
                provenance: _toPillProvenance(
                  cplhProv,
                  unavailableTooltip: data.unavailableTooltip(
                    isLabor: true,
                    metricPhrase: 'covers per labor hour',
                  ),
                ),
                label: 'CPLH',
                value: cplhProv.value,
                formatter: (v) => v.toStringAsFixed(2),
              ),
              MetricPill(
                state: splhProv.state,
                provenance: _toPillProvenance(
                  splhProv,
                  unavailableTooltip: data.unavailableTooltip(
                    isLabor: true,
                    metricPhrase: 'sales per labor hour',
                  ),
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
                    value: data.fohHours.value,
                    needed: data.fohHours.needed,
                    excess: data.fohHours.excess,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CompactHoursColumn(
                    label: 'BOH HRS',
                    value: data.bohHours.value,
                    needed: data.bohHours.needed,
                    excess: data.bohHours.excess,
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

// ─── FOH Productivity section (OPZ band) ────────────────────────────────────

/// Shared FOH PRODUCTIVITY section. Whole-day always supplies a locked
/// band ([_OpzBandData]) so it renders the [ZoneStatusCard] exactly as
/// the pre-refactor inline whole-day path did (byte-untouched — Promise
/// 3 / Layer 9). A period with no locked OPZ band (no closed-shift
/// stamp, no open-shift profile row — Gap 42 fallback) renders the
/// honest no-zone line instead of a gauge drawn off a `0` anchor
/// (Design Rule 2). The horizontal:16 padding lives here so both lenses
/// share the identical inset.
class _FohProductivitySection extends StatelessWidget {
  final _ShiftSectionViewData data;
  const _FohProductivitySection({required this.data});

  @override
  Widget build(BuildContext context) {
    final opz = data.opz;
    if (opz == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
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
            'No locked productivity zone for this period yet.',
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ZoneStatusCard(
        currentCPLH: opz.currentCPLH,
        opzFloorCPLH: opz.opzFloorCPLH,
        opzCeilingCPLH: opz.opzCeilingCPLH,
        targetCPLH: opz.targetCPLH,
        opzStatus: opz.opzStatus,
        opzLabel: opz.opzLabel,
        opzSubLabel: opz.opzSubLabel,
        splhState: opz.splhState,
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
    // The active (current real-time) period is signalled by an orange
    // (sunset) border only — no "ACTIVE NOW" text. Selected styling keeps
    // its own border; an unselected-but-active chip gets the bold orange
    // border as the sole live affordance, others stay subtle.
    final borderColor = selected
        ? AppColors.sunsetDark
        : activeNow
            ? AppColors.sunset
            : AppColors.borderSubtle.withValues(alpha: 0.7);
    final borderWidth = activeNow && !selected ? 2.0 : 1.0;
    final textColor = selected
        ? AppColors.textPrimary
        : AppColors.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      // Preserve the active state for screen readers now that the visible
      // "ACTIVE NOW" text is gone (border-only affordance).
      value: activeNow ? 'active now' : null,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          key: activeNow ? const Key('shift_period_pill_active') : null,
          constraints: const BoxConstraints(minWidth: 88, minHeight: 38),
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
          decoration: BoxDecoration(
            color: bgColor,
            border: Border.all(color: borderColor, width: borderWidth),
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

// ─── Daypart period header (Per-Daypart V1 — true 1:1 layout) ───────────────

/// Compact period-identity + status element rendered ABOVE the three
/// shared section groups in the daypart lens — NOT a bordered card
/// wrapping the sections (operator instruction: the daypart layout is
/// the SAME grammar as Whole Day, not a lookalike). It carries only the
/// things the whole-day lens has no equivalent for: which period is
/// selected, its clock window, its tri-state status line, the missing-
/// timezone banner, and the Phase 10.5.3 per-period primary-driver chip.
/// The metric sections themselves are the SAME `_OutputsSection` /
/// `_InputsSection` / `_FohProductivitySection` whole-day uses.
///
/// **Time-source contract (mirrors `current_state_boundary_monitor.dart`):**
/// the active/closed/future phase is computed from `tz.TZDateTime.now`
/// for the restaurant's IANA `businessTimezone`, bucketed by
/// **business-date weekday** via [BusinessDateResolver] — never raw
/// `DateTime.now().weekday`. Tests inject a restaurant-local [DateTime]
/// via [ShiftDashboard.clockOverride]. No usable IANA timezone → the
/// status line degrades honestly ("Opens at …" / the missing-tz copy),
/// never a false "closed".
///
/// A4.2 (R2): rebuilds via the dashboard-wide [_ShiftDashboardTicker]
/// (30s) so the status line follows the live clock across a
/// service-period boundary without a local `Timer.periodic`.
class _DaypartPeriodHeader extends StatelessWidget {
  final String selectedPeriodId;
  final ValueListenable<DateTime> ticker;

  const _DaypartPeriodHeader({
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

        final definitions = periodNotifier?.definitions ??
            ServicePeriodDefinitionResolver.demoDefinitions;
        final cutoff = periodNotifier?.businessDayStartLocalTime ??
            _defaultBusinessDayStartLocalTime;
        final localNow = _restaurantLocalNow(restaurant);
        final ordered = ServicePeriodDefinitionResolver.ordered(definitions);
        ServicePeriodDefinition? selectedDefinition;
        for (final definition in ordered) {
          if (definition.id == selectedPeriodId) {
            selectedDefinition = definition;
            break;
          }
        }
        final missingTimezone = periodNotifier?.missingTimezone ?? false;
        final primaryLeverCard = selectedDefinition == null
            ? null
            : periodNotifier?.primaryLeverCardFor(selectedDefinition.id);

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
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
                // Item 1 de-dup (operator walkthrough 2026-05-16): the
                // `_ShiftPeriodSelector` pills above already announce the
                // selected period by `definition.label` (the selected
                // pill is the canonical period switcher). The old
                // identity Row here (shortLabel pill + duplicated full
                // label) repeated that, so the period was announced
                // twice. We keep ONLY what the selector does NOT convey:
                // the clock window, the tri-state status line, and the
                // primary-driver chip. Status line + time range share
                // one row to stay visually clean and aligned with the
                // true-1:1 grammar.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Tri-state status line — preserved verbatim from the
                    // retired bespoke card (Period closed / Active now /
                    // Opens at … / missing-tz). Never a false "closed".
                    Expanded(
                      child: _DaypartStatusLine(
                        missingTimezone: missingTimezone,
                        phase: localNow == null
                            ? null
                            : resolveServicePeriodPhase(
                                localNow: localNow,
                                businessDayStartLocalTime: cutoff,
                                definitions: definitions,
                                periodId: selectedDefinition.id,
                              ),
                        startLocalTime: selectedDefinition.startLocalTime,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${selectedDefinition.startLocalTime} – '
                      '${selectedDefinition.endLocalTime}',
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Phase 10.5.3 — per-period primary driver chip. Resolves
                // through `LeverCards.lookup`; null surfaces as the
                // "No pattern yet" degraded state per 7.58 F-1 / F-6
                // (no silent fall-through to a real lever).
                _DaypartDriverChip(card: primaryLeverCard),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Per-Daypart V1 (Slice 4 closed-state fix) — the tri-state status
/// line rendered inside (never instead of) the full daypart card.
///
/// Copy is intentionally minimal and reads as training (UX Writing
/// Standard):
///   * missing timezone → "Timezone not configured — metrics
///     unavailable." (kept verbatim from the prior implementation);
///   * [ServicePeriodPhase.past] → "Period closed" (the bug: a
///     past/closed period previously fell through to the future copy);
///   * [ServicePeriodPhase.active] → "Active now";
///   * [ServicePeriodPhase.future] (or null clock) → "Opens at
///     {startLocalTime}" — only a genuinely not-yet-open period is
///     framed as opening.
class _DaypartStatusLine extends StatelessWidget {
  final bool missingTimezone;
  final ServicePeriodPhase? phase;
  final String startLocalTime;

  const _DaypartStatusLine({
    required this.missingTimezone,
    required this.phase,
    required this.startLocalTime,
  });

  @override
  Widget build(BuildContext context) {
    final String text;
    if (missingTimezone) {
      text = 'Timezone not configured — metrics unavailable.';
    } else {
      switch (phase) {
        case ServicePeriodPhase.past:
          text = 'Period closed';
          break;
        case ServicePeriodPhase.active:
          text = 'Active now';
          break;
        case ServicePeriodPhase.future:
        case null:
          // Null clock degrades to the honest "opens at" framing — it
          // must never claim a period is closed without proof.
          text = 'Opens at $startLocalTime';
          break;
      }
    }
    return Text(
      text,
      style: AppTextStyles.mono10(color: AppColors.textMuted),
    );
  }
}

// Per-Daypart V1 — true 1:1 refactor: the bespoke daypart card family
// (`_DaypartScaffoldSection`, `_DaypartScaffoldCard`,
// `_DaypartSectionHeader`, `_dpFmt`, `_DaypartOutputsSection`,
// `_DaypartLaborCard`, `_DaypartInputsSection`,
// `_DaypartFohProductivitySection`, `_DaypartTargetedCell`,
// `_MetricCell`) was retired. The daypart lens now emits the SAME
// `_OutputsSection` / `_InputsSection` / `_FohProductivitySection`
// sticky-section groups the whole-day lens does, fed by
// `_ShiftSectionViewData.fromPeriod`. The honest per-period degrade
// (Design Rule 2) is preserved inside those shared widgets +
// `MetricPill`'s unavailable branch. `_DaypartStatusLine` (above) and
// `_DaypartDriverChip` (below) are kept — they back the compact
// `_DaypartPeriodHeader` element that sits above the sections.

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

/// Shared LABOR % card (Outputs section, right of Sales). Whole-day
/// supplies a fully-populated [_LaborVarianceData] so the render is
/// byte-identical to the pre-refactor whole-day card (Promise 3 / Layer
/// 9). A period supplies honest nulls: a null `actualPct` renders "\u2014"
/// (labor not connected), a null `theoreticalPct` hides the
/// `Theoretical X.X%` sub-line, a null `variancePts` hides the \u00b1pts
/// delta pill \u2014 never a phantom `0.0%` / `0.0 pts` (Design Rule 2 +
/// Metric Honesty Doctrine). The LABOR Theoretical + delta-pill parity
/// (#789) flows for free through this shared widget for both lenses.
class _LaborCard extends StatelessWidget {
  final _LaborVarianceData labor;
  const _LaborCard({required this.labor});

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
      child: _LaborVarianceSection(labor: labor),
    );
  }
}

class _LaborVarianceSection extends StatelessWidget {
  final _LaborVarianceData labor;
  const _LaborVarianceSection({required this.labor});

  @override
  Widget build(BuildContext context) {
    final actualPct = labor.actualPct;
    final theoreticalPct = labor.theoreticalPct;
    final variancePts = labor.variancePts;

    final hasVariance = actualPct != null && theoreticalPct != null;
    final isOver = (variancePts ?? 0) > 0;
    final accentColor = isOver ? AppColors.negative : AppColors.positive;
    final ptSign = isOver ? '+' : '\u2212';
    // Value color matches the whole-day card (accent over/under) only
    // when a variance can be computed; neutral when it cannot, muted
    // when the actual itself is unknown.
    final valueColor = actualPct == null
        ? AppColors.textMuted
        : hasVariance
            ? accentColor
            : AppColors.textPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label
        Text(
          'LABOR %',
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
        const SizedBox(height: 6),
        // Current value (honest "\u2014" when labor unconnected).
        Text(
          actualPct == null ? '\u2014' : '${actualPct.toStringAsFixed(1)}%',
          style: AppTextStyles.mono28(color: valueColor),
        ),
        // Theoretical reference \u2014 shown only when known (never
        // `Theoretical 0.0%`). Same spacing + style as the whole-day
        // card (which always has it).
        if (theoreticalPct != null) ...[
          const SizedBox(height: 3),
          Text(
            'Theoretical ${theoreticalPct.toStringAsFixed(1)}%',
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
        ],
        // Delta pill \u2014 byte-consistent with the whole-day pill. Hidden
        // when the variance cannot be computed.
        if (variancePts != null) ...[
          const SizedBox(height: 8),
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
      ],
    );
  }
}

/// Shared FOH/BOH hours column. Whole-day always supplies
/// [needed]/[excess] (SchedulePlan day row) so the "Target N hrs"
/// sub-line + delta pill render exactly as before. A period supplies
/// neither (no scheduled-vs-needed target is tracked per period yet) \u2192
/// the column shows the value alone, never a fabricated `Target 0 hrs`
/// (Design Rule 2). [value] is pre-formatted by the projection.
class _CompactHoursColumn extends StatelessWidget {
  final String label;
  final String value;
  final int? needed;
  final int? excess;

  const _CompactHoursColumn({
    required this.label,
    required this.value,
    this.needed,
    this.excess,
  });

  @override
  Widget build(BuildContext context) {
    final hasTarget = needed != null && excess != null;
    final isOver = (excess ?? 0) > 0;
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
          Text(value, style: AppTextStyles.mono28()),
          if (hasTarget) ...[
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
