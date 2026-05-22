import 'package:flutter/foundation.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../domain/models/active_target_profile.dart';
import '../domain/services/next_service_period_open_resolver.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_reservation_book_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../models/app_data_status.dart';
import '../models/current_state_freshness.dart';
import '../models/shift_dashboard_read_model.dart';
import '../services/current_state_freshness_service.dart';
import '../services/integration/shift_vendor_source_resolver.dart';
import '../services/app_data_status_service.dart';
import '../services/restaurant_timing_config_read_service.dart';
import '../services/schedule_plan_read_service.dart';
import '../services/wage_standard_context_service.dart';
import '../domain/services/service_period_definition_resolver.dart';

/// Reads the active restaurant id; injected so tests can simulate a
/// scope flip mid-fetch.
typedef ActiveRestaurantIdReader = Future<String> Function();

class ShiftDashboardNotifier extends ChangeNotifier {
  ShiftDashboardReadModel? _readModel;
  AppDataStatus? _status;
  bool _isLoading = true;
  bool _lockedPlanUnavailable = false;
  bool _disposed = false;

  /// Per-surface freshness truth for the Shift current-state surface.
  ///
  /// Null when no current-state data exists (no open snapshots).
  /// Evaluated from the latest `OpenShiftSnapshot.updatedAt` on each load.
  /// The [refreshing] state preserves the prior source timestamp during
  /// in-flight revalidation.
  CurrentStateFreshness? _freshness;

  /// Closed-state Shift dashboard (Per-Daypart V1 — closed-state screen).
  ///
  /// True when there is NO `status='open'` shift but the operator HAS
  /// prior shift history, so the dashboard binds the last completed
  /// business day's already-persisted final values and renders the
  /// SAME Shift layout marked Closed. The read path is presentation
  /// only: it reuses `ShiftDashboardReadModel.buildWholeDay` verbatim
  /// over the persisted closed snapshots + the locked plan day row —
  /// no recompute, no new persistence, no formula change.
  ///
  /// False on the live path (an open shift exists) and false for a
  /// brand-new operator with no shift history (the simple empty state
  /// is preserved — nothing to show yet).
  bool _isClosedDay = false;

  /// The next moment a live shift opens, resolved from the operator's
  /// configured service periods relative to the close moment. Null when
  /// not on the closed-day path or when no usable timing config exists
  /// (the reopen line is then omitted rather than printed with a
  /// phantom time — Metric Honesty Doctrine).
  NextServicePeriodOpen? _nextOpen;

  /// Per-operator isolation seam (Launch Blocker #1).
  ///
  /// `_load` captures the active restaurant id at fetch-start and re-reads
  /// it before publishing. If the id changed mid-load (operator switched
  /// restaurants on a shared device), the result is abandoned: no state
  /// write, no `notifyListeners()`. CLAUDE.md: "Per-operator isolation is
  /// non-negotiable."
  final ActiveRestaurantIdReader _activeRestaurantIdReader;

  ShiftDashboardReadModel? get readModel => _readModel;
  AppDataStatus? get status => _status;
  bool get isLoading => _isLoading;
  CurrentStateFreshness? get freshness => _freshness;
  bool get lockedPlanUnavailable => _lockedPlanUnavailable;

  /// True when the dashboard is showing the last completed business
  /// day's final, settled values marked Closed (no open shift, but
  /// shift history exists). The widget swaps the green "Live" indicator
  /// for a neutral grey "Closed" and shows a slim reopen line.
  bool get isClosedDay => _isClosedDay;

  /// The resolved next service-period open (closed-day path only), or
  /// null when not applicable / not resolvable.
  NextServicePeriodOpen? get nextOpen => _nextOpen;

  ShiftDashboardNotifier({
    ActiveRestaurantIdReader? activeRestaurantIdReader,
  }) : _activeRestaurantIdReader = activeRestaurantIdReader ??
            SqliteRestaurantScopeRepository.instance.getActiveRestaurantId {
    _load();
  }

  /// Test-only constructor for synchronous setup.
  ShiftDashboardNotifier.fromReadModel(
    ShiftDashboardReadModel model, {
    CurrentStateFreshness? freshness,
    bool isClosedDay = false,
    NextServicePeriodOpen? nextOpen,
  })  : _readModel = model,
        _status = null,
        _freshness = freshness,
        _isClosedDay = isClosedDay,
        _nextOpen = nextOpen,
        _isLoading = false,
        _activeRestaurantIdReader =
            SqliteRestaurantScopeRepository.instance.getActiveRestaurantId;

  /// Test-only constructor for synchronous empty-state rendering.
  ShiftDashboardNotifier.emptyForTest(AppDataStatus status)
      : _readModel = null,
        _status = status,
        _freshness = null,
        _isLoading = false,
        _activeRestaurantIdReader =
            SqliteRestaurantScopeRepository.instance.getActiveRestaurantId;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    // Do NOT set _isLoading = true — during pull-to-refresh the
    // RefreshIndicator provides its own progress feedback and the
    // current data should stay visible. _isLoading is only for the
    // initial cold load in the constructor.
    _freshness = _freshness?.updatedAt != null
        ? CurrentStateFreshness.refreshing(
            priorUpdatedAt: _freshness!.updatedAt,
            evaluatedAt: DateTime.now().toUtc(),
          )
        : null;
    if (_disposed) return;
    notifyListeners();
    await _load();
  }

  Future<void> _load() async {
    // Always evaluate data status
    final loadedStatus = await AppDataStatusService.instance.evaluate();
    var lockedPlanUnavailable = false;

    // Per-operator isolation (Launch Blocker #1): capture the active
    // restaurant id at fetch-start. Every read below is scoped to it.
    final restaurantId = await _activeRestaurantIdReader();

    // Load active target profile via wage-aware bootstrap
    final ActiveTargetProfile profile = await WageStandardContextService
        .instance
        .loadOrBootstrapProfile(restaurantId);

    // Find the business date with an open shift
    final businessDate = await SqliteOpenShiftSnapshotRepository.instance
        .getCurrentBusinessDate(restaurantId);

    ShiftDashboardReadModel? loadedReadModel;
    CurrentStateFreshness? loadedFreshness;
    var isClosedDay = false;
    NextServicePeriodOpen? nextOpen;

    if (businessDate != null) {
      // ── Live path: an open shift exists for `businessDate`. ──────────
      final built = await _buildDayReadModel(
        restaurantId: restaurantId,
        businessDate: businessDate,
        profile: profile,
      );
      loadedReadModel = built.readModel;
      loadedFreshness = built.freshness;
      lockedPlanUnavailable = built.lockedPlanUnavailable;
    } else {
      // ── No open shift. Closed-state Shift dashboard (Per-Daypart V1
      // — closed-state screen): if the operator HAS prior COMPLETED
      // shift history, bind the last COMPLETED (settled) business day's
      // already-persisted final values and render the SAME Shift layout
      // marked Closed. The selection filters to `status='closed'` rows
      // ONLY: the demo seed (and real operation) persists future
      // `status='projected'` rows for the current/forthcoming week, so
      // an unfiltered max-date query would bind a forecast-only future
      // day with no completed actuals — a misleading all-zeros "Closed"
      // screen. Honesty: never build a Closed screen from
      // projected/forecast-only rows. Brand-new operator (no completed
      // history at all) keeps the simple empty state — nothing to show
      // yet. This is presentation only: it reuses `_buildDayReadModel`
      // (the same wiring the live path uses) verbatim — no recompute,
      // no new persistence, no formula change. ──────────────────────
      final mostRecentDate = await SqliteOpenShiftSnapshotRepository.instance
          .getMostRecentClosedBusinessDate(restaurantId);
      if (mostRecentDate != null) {
        final built = await _buildDayReadModel(
          restaurantId: restaurantId,
          businessDate: mostRecentDate,
          profile: profile,
        );
        loadedReadModel = built.readModel;
        // Closed-day freshness is intentionally NOT surfaced as a
        // live/updated/stale chip — the closed indicator + reopen line
        // carry the state instead. Keep it null so the header's
        // freshness slot is replaced by the "Closed" marker.
        loadedFreshness = null;
        lockedPlanUnavailable = built.lockedPlanUnavailable;
        // Only mark the screen Closed when a real read model was
        // produced (locked plan present for the day). If the locked
        // plan is missing, fall through to the honest
        // lockedPlanUnavailable empty state exactly as the live path
        // does — do NOT show a Closed screen with no data.
        if (loadedReadModel != null) {
          isClosedDay = true;
          nextOpen = await _resolveNextOpen();
        }
      } else {
        // Brand-new operator / no COMPLETED (closed) shift history at
        // all → simple empty state (nothing to show yet). A
        // projected-only future week alone does NOT produce a Closed
        // screen — there are no settled finals to honestly show.
        loadedReadModel = null;
        loadedFreshness = null;
        lockedPlanUnavailable = false;
      }
    }

    // Per-operator isolation re-check (Launch Blocker #1): if the active
    // restaurant changed mid-load, the result is for a stale tenant.
    // Abandon the publish — no state write, no `notifyListeners()`. The
    // next load (triggered by the scope-change handler) will reconcile.
    final currentRestaurantId = await _activeRestaurantIdReader();
    if (currentRestaurantId != restaurantId) {
      return;
    }

    if (_disposed) return;
    _status = loadedStatus;
    _lockedPlanUnavailable = lockedPlanUnavailable;
    _readModel = loadedReadModel;
    _freshness = loadedFreshness;
    _isClosedDay = isClosedDay;
    _nextOpen = nextOpen;
    _isLoading = false;
    notifyListeners();
  }

  /// Builds the whole-day read model for [businessDate] using the SAME
  /// wiring the live path uses (`ShiftDashboardReadModel.buildWholeDay`
  /// over the persisted snapshots + the locked plan day row + the same
  /// reservation-book / vendor-source provenance). Presentation only:
  /// no recompute, no write, no formula change. Both the live path and
  /// the closed-state path call this so the closed day renders exactly
  /// like a live day, just bound to the already-saved final values.
  ///
  /// Returns a null read model + `lockedPlanUnavailable: true` when the
  /// persisted locked plan has no matching day row (honest degrade —
  /// never fabricate plan values), exactly as the live path does.
  Future<_DayReadModelResult> _buildDayReadModel({
    required String restaurantId,
    required String businessDate,
    required ActiveTargetProfile profile,
  }) async {
    final snapshots = await SqliteOpenShiftSnapshotRepository.instance
        .getSnapshotsForDay(restaurantId, businessDate);

    if (snapshots.isEmpty) {
      return const _DayReadModelResult(
        readModel: null,
        freshness: null,
        lockedPlanUnavailable: false,
      );
    }

    // Evaluate per-surface freshness from the latest snapshot timestamp.
    // Same maxUpdatedAt pattern as AppDataStatusService.evaluate().
    final maxUpdatedAt = snapshots
        .map((s) => DateTime.tryParse(s.updatedAt))
        .whereType<DateTime>()
        .fold<DateTime?>(
            null, (a, b) => a == null || b.isAfter(a) ? b : a);
    final freshness = const CurrentStateFreshnessService().evaluate(
      updatedAt: maxUpdatedAt,
      now: DateTime.now().toUtc(),
    );

    // Read the persisted locked weekly plan only. If it is missing,
    // degrade honestly instead of silently falling back to the live plan.
    final plan = await SchedulePlanReadService.instance
        .getExistingCurrentLockedWeeklyPlan();

    // Day label: prefer the open snapshot (live path); otherwise the
    // first snapshot's label (closed path — every snapshot for a fully
    // closed day shares the same day label).
    final daySnap = snapshots
            .where((s) => s.status == 'open')
            .firstOrNull ??
        snapshots.first;
    final dayLabel = daySnap.dayLabel;

    final dayPlan = plan?.dayPlans
        .where((d) => d.day == dayLabel)
        .firstOrNull;

    // Sum reservation book unseated covers across all dayparts for the day
    final resSnapshots = await SqliteReservationBookSnapshotRepository
        .instance
        .getForDay(restaurantId, businessDate);
    final totalUnseated = resSnapshots.fold<int>(
        0, (s, r) => s + r.unseatedCovers);

    if (dayPlan == null) {
      // No persisted locked plan or no matching day row. Do not
      // fabricate plan values from a single daypart snapshot or from
      // the live plan path.
      return const _DayReadModelResult(
        readModel: null,
        freshness: null,
        lockedPlanUnavailable: true,
      );
    }

    // Per-location vendor provenance (Defect 1): feed the EXISTING
    // read-model honest-degrade gate the connected vendor ids for THIS
    // scope, resolved off the same per-(operator, location, category)
    // demo vendor fixture the DemoModeBanner uses. The gate bodies are
    // unchanged (HP #2: no kDemoMode fork).
    final vendorSource = ShiftVendorSourceResolver.forLocation(restaurantId);
    final readModel = ShiftDashboardReadModel.buildWholeDay(
      snapshots: snapshots,
      profile: profile,
      forecastCovers: dayPlan.forecastCovers,
      forecastSales: dayPlan.forecastSales,
      planFohHours: dayPlan.requiredFohHours,
      planBohHours: dayPlan.requiredBohHours,
      inTheBooksCovers: totalUnseated > 0 ? totalUnseated : null,
      posSourceVendorId: vendorSource.posSourceVendorId,
      laborSourceVendorId: vendorSource.laborSourceVendorId,
    );
    return _DayReadModelResult(
      readModel: readModel,
      freshness: freshness,
      lockedPlanUnavailable: false,
    );
  }

  /// Resolves the next live-shift open for the closed-state header line
  /// using the operator's persisted service-period definitions
  /// (timezone-correct restaurant-local "now"). Returns null when no
  /// usable timing config / timezone exists — the widget then omits the
  /// reopen line rather than printing a phantom time (Metric Honesty
  /// Doctrine). Pure presentation: no recompute, no write.
  Future<NextServicePeriodOpen?> _resolveNextOpen() async {
    try {
      final timing = await RestaurantTimingConfigReadService.instance
          .getActiveTimingConfig();
      final scope = await SqliteRestaurantScopeRepository.instance
          .getOrCreateActiveRestaurant();
      final iana = scope.businessTimezone.trim();
      if (iana.isEmpty) return null;

      final definitions =
          (timing?.servicePeriodDefinitions.isNotEmpty ?? false)
              ? timing!.servicePeriodDefinitions
              : ServicePeriodDefinitionResolver.demoDefinitions;

      // Restaurant-local "now". The Shift dashboard's clock test seam
      // (`ShiftDashboard.clockOverride`) is widget-layer; the notifier
      // resolves the local instant from the scope timezone the same way
      // ShiftServicePeriodNotifier does, so demo and production share
      // one path (no kDemoMode fork).
      final localNow = _restaurantLocalNow(iana);
      if (localNow == null) return null;

      return NextServicePeriodOpenResolver.resolve(
        localNow: localNow,
        definitions: definitions,
      );
    } catch (_) {
      // A read failure degrades to "no reopen line" rather than
      // throwing the whole notifier load.
      return null;
    }
  }

  /// Restaurant-local now from an IANA timezone, or null when the zone
  /// is unrecognized. Mirrors the Shift dashboard's
  /// `_restaurantLocalNow` (refuses to fall back to the device clock on
  /// an unknown zone).
  DateTime? _restaurantLocalNow(String iana) {
    try {
      tzdata.initializeTimeZones();
      final loc = tz.getLocation(iana);
      return tz.TZDateTime.now(loc);
    } catch (_) {
      return null;
    }
  }
}

/// Internal carrier for [ShiftDashboardNotifier._buildDayReadModel] —
/// keeps the live path and the closed-state path on one code path.
class _DayReadModelResult {
  final ShiftDashboardReadModel? readModel;
  final CurrentStateFreshness? freshness;
  final bool lockedPlanUnavailable;
  const _DayReadModelResult({
    required this.readModel,
    required this.freshness,
    required this.lockedPlanUnavailable,
  });
}