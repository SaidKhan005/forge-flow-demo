// Phase 10.5.2 — ShiftServicePeriodNotifier.
//
// Bridges `ShiftServicePeriodReadService` to the Shift surface and the
// daypart Variance lens. Loads the active business date's canonical
// facts, runs them through the read service, and exposes per-service-
// period accumulators plus the location context callers need to
// resolve the active period + time-into-service.
//
// Demo-mode synthesis: until the Phase 8 vendor connectors land,
// canonical POS lines and labor punches are synthesized from the
// existing `OpenShiftSnapshot` records (one POS line at the period
// midpoint, one FOH + one BOH punch sized to the snapshot's
// scheduled hours and weighted by `blendedWage`). When Phase 8 ships,
// the synthesizer is replaced by a fact loader; the read service and
// notifier API stay the same.
//
// Refresh lifecycle: the notifier rebuilds its accumulator map on
// `refresh()` (pulled by the Shift dashboard's `RefreshIndicator` and
// by widgets that explicitly invalidate). Correction replay
// (`applyPosLineCorrection` / `applyLaborPunchCorrection`) is exposed
// for the future Phase 8 path; the demo source rebuilds in full.
library;

import 'package:flutter/foundation.dart';

import '../domain/constants/app_defaults.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/open_shift_snapshot.dart';
import '../domain/models/restaurant_timing_config.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/models/weekly_plan_snapshot.dart';
import '../models/shift_record.dart';
import '../domain/services/business_date_resolver.dart';
import '../domain/services/daypart_bucketer.dart';
import '../domain/services/locked_daypart_int_hours.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import '../services/restaurant_timing_config_read_service.dart';
import '../services/shift_service_period_read_service.dart';
import '../services/wage_standard_context_service.dart';

/// Default business-day cutoff used when no persisted timing config is
/// available. Matches the seeded
/// `business_day_start_local_time` and the 10.5.0 widget fallback.
const String _defaultBusinessDayStartLocalTime = '04:00';

/// Per-Daypart V1 (Slice 4) — the per-period locked target stamps the
/// Shift daypart card renders alongside the live per-period actuals.
///
/// Two honest sources, in priority order:
///   1. **Closed shift** — the per-shift `daypart_*` stamp columns on
///      the day's closed [ShiftRecord] for this period. Promise 2:
///      closed truth retains the stamp from its close time, so a closed
///      period is graded against the cycle that was active when it
///      closed, never re-graded under a later cycle.
///   2. **Open shift** — `ActiveTargetProfile.daypartFor(periodId)`.
///      The period has not closed yet, so the current cycle's per-period
///      row is the honest target.
///
/// When neither source has a per-period row (Gap 42 insufficient-
/// recommendation fallback, or no cycle yet) every field stays null.
/// Design Rule 2: the card renders the honest empty state ("—"), never
/// a `0` sentinel.
class DaypartTargetContext {
  /// `'closed_stamp'` when read from a closed shift's per-shift stamp,
  /// `'open_profile'` when read from the active profile's per-period
  /// row, or `'none'` when no per-period target exists for this period.
  final String source;
  final double? targetCPLH;
  final double? targetSPLH;
  final double? targetPPA;
  final double? opzFloorCPLH;
  final double? opzCeilingCPLH;

  /// Per-Daypart V1 (daypart LABOR % 1:1 parity fix) — the period's
  /// theoretical labor % the daypart LABOR card renders as its
  /// `Theoretical X.X%` sub-line + delta pill, mirroring the whole-day
  /// `_LaborVarianceSection`. Sourced from
  /// `ActiveTargetProfile.daypartTheoreticalLaborPctFor(periodId)`, the
  /// same live-profile origin the whole-day card uses for
  /// `profile.theoreticalLaborPct` (the whole-day labor card's
  /// theoretical reference is NOT closed-stamped — it always reads the
  /// live profile — so the per-period mirror reads it the same way; the
  /// Promise-2 closed-stamp freeze applies to the locked *rate* target
  /// sub-lines, not this derived reference). `null` when the cycle wrote
  /// no per-period row (Gap 42 fallback) → the card hides the sub-line
  /// and pill rather than drawing a `0.0%` phantom (Design Rule 2 /
  /// Metric Honesty Doctrine).
  final double? theoreticalLaborPct;

  /// Per-Daypart V1 (Shift daypart target/benchmark 1:1 parity) — the
  /// plan-side locked per-period reference values, read straight from
  /// the in-force [WeeklyPlanSnapshot]'s `WeeklyPlanSnapshotDayDaypart`
  /// child row for `(businessDate, servicePeriodId)`. These mirror the
  /// whole-day lens's plan-side footers:
  ///   * [forecastCovers] → the `COVERS` tile's "Forecast N" footer
  ///     (whole-day uses `rm.forecastCovers`, a plan-side number; the
  ///     per-period analogue is the locked per-daypart `forecast_covers`,
  ///     not actuals).
  ///   * [forecastSales] → the `SALES` tile's "Forecast $X" footer
  ///     (whole-day uses `rm.forecastSales`, a plan-side number; the
  ///     per-period analogue is the locked per-daypart `forecast_sales`,
  ///     not actuals × a rate).
  ///   * [requiredFohHours] / [requiredBohHours] → the FOH/BOH HRS
  ///     tiles' "Target N hrs" footer (whole-day uses
  ///     `rm.planFohHours`/`planBohHours`).
  ///
  /// `null` when the in-force snapshot has no per-period row for this
  /// period (legacy snapshot or Gap 42 fallback) → the shared widgets
  /// degrade to the same honest empty state whole-day uses when its own
  /// plan number is absent (Design Rule 2 / Metric Honesty Doctrine).
  /// These are read-only locked values surfaced for display — no metric
  /// math is performed here.
  final int? forecastCovers;
  final double? forecastSales;
  final double? requiredFohHours;
  final double? requiredBohHours;

  const DaypartTargetContext({
    required this.source,
    this.targetCPLH,
    this.targetSPLH,
    this.targetPPA,
    this.opzFloorCPLH,
    this.opzCeilingCPLH,
    this.theoreticalLaborPct,
    this.forecastCovers,
    this.forecastSales,
    this.requiredFohHours,
    this.requiredBohHours,
  });

  /// Honest empty context — no per-period target available for the
  /// period. Every field null so the card shows "—" (Design Rule 2).
  static const DaypartTargetContext none = DaypartTargetContext(source: 'none');

  /// True only when the full OPZ band + target CPLH are present, so the
  /// FOH Productivity zone gauge can render. A partial stamp (some
  /// fields null) keeps the gauge hidden rather than drawing a band off
  /// a `0` sentinel.
  bool get hasOpzBand =>
      targetCPLH != null && opzFloorCPLH != null && opzCeilingCPLH != null;
}

class ShiftServicePeriodNotifier extends ChangeNotifier {
  final ShiftServicePeriodReadService _readService;

  Map<String, ServicePeriodAccumulator>? _buckets;
  Map<String, String?> _primaryLeverIds = const {};

  /// Per-Daypart V1 (Slice 4) — per-period locked target context keyed
  /// by `ServicePeriodId`. Resolved in [_load] from the day's closed
  /// shift stamps (Promise 2) with an open-shift active-profile fallback.
  /// Absent entries mean "no per-period target" — the card renders the
  /// honest empty state, never `0`.
  Map<String, DaypartTargetContext> _daypartTargets = const {};
  List<ServicePeriodDefinition> _definitions =
      ServicePeriodDefinitionResolver.demoDefinitions;
  String? _businessDate;
  String? _businessDayStartLocalTime;
  String? _iana;
  bool _isLoading = true;
  bool _missingTimezone = false;
  bool _disposed = false;

  /// Per-service-period accumulators keyed by `ServicePeriodId`. Null
  /// while loading; an empty map (or one with empty accumulators) when
  /// no canonical facts are available for the current business date.
  Map<String, ServicePeriodAccumulator>? get buckets => _buckets;

  /// Ordered service-period definitions backing the current view.
  List<ServicePeriodDefinition> get definitions => _definitions;

  /// Current business date (`YYYY-MM-DD`) or null if no open shift
  /// exists.
  String? get businessDate => _businessDate;

  /// Resolved IANA timezone for the active restaurant. Null when the
  /// scope has no usable timezone — callers should refuse to fall back
  /// to the device clock.
  String? get iana => _iana;

  /// Resolved business-day cutoff (`HH:mm`).
  String get businessDayStartLocalTime =>
      _businessDayStartLocalTime ?? _defaultBusinessDayStartLocalTime;

  bool get isLoading => _isLoading;
  bool get missingTimezone => _missingTimezone;

  /// Phase 10.5.3 — per-period primary driver id (lowercase canonical
  /// form per `7.61` R-STOR-1) for [periodId], or `null` when:
  ///   * the bucket has no in-period evidence yet,
  ///   * required denominators are missing (no forecast covers,
  ///     no active target profile, etc.),
  ///   * OR the engine returned only the legacy `'covers_down'`
  ///     empty-candidate fallback (banned at the daypart scope per
  ///     `7.58` Finding F-2 until `7.58.0a` lands).
  ///
  /// Renderers MUST resolve the result through `LeverCards.lookup`
  /// (case-insensitive) and surface a null lookup as the
  /// `LeverCards.notYetOnModelLabel` degraded state — never fall
  /// through to a real lever card.
  String? primaryLeverIdFor(String periodId) => _primaryLeverIds[periodId];

  /// Phase 10.5.3 — resolved [LeverCardData] for [periodId], or null
  /// when no driver is available for this period (see
  /// [primaryLeverIdFor]).
  LeverCardData? primaryLeverCardFor(String periodId) =>
      LeverCards.lookup(_primaryLeverIds[periodId]);

  /// Per-Daypart V1 (Slice 4) — the locked per-period target context for
  /// [periodId]. Returns [DaypartTargetContext.none] (all fields null)
  /// when no closed-shift stamp and no open-shift profile row exist for
  /// the period, so the daypart card renders the honest "—" empty state
  /// instead of a `0` sentinel (Design Rule 2).
  DaypartTargetContext daypartTargetFor(String periodId) =>
      _daypartTargets[periodId] ?? DaypartTargetContext.none;

  /// Per-Daypart V1 (Slice 4 fix) — the past / active / future phase of
  /// [periodId] for a restaurant-local [localNow]. Resolved with the
  /// exact business-date-aware clock the active-period chip already uses
  /// ([resolveActiveServicePeriodId] → [BusinessDateResolver]), never
  /// raw `DateTime.now().weekday` and never a naive-vs-tz instant
  /// compare. The Shift daypart card uses this to render a correct
  /// tri-state status line ("Period closed" / "Active now" /
  /// "Opens at …") instead of the prior binary text that mislabeled an
  /// already-closed period as "until this period opens".
  ServicePeriodPhase servicePeriodPhase({
    required String periodId,
    required DateTime localNow,
  }) => resolveServicePeriodPhase(
    localNow: localNow,
    businessDayStartLocalTime: businessDayStartLocalTime,
    definitions: _definitions,
    periodId: periodId,
  );

  ShiftServicePeriodNotifier({
    ShiftServicePeriodReadService readService =
        const ShiftServicePeriodReadService(),
  }) : _readService = readService {
    _load();
  }

  /// Test-only constructor with pre-computed buckets. Mirrors the
  /// pattern in `ShiftDashboardNotifier.fromReadModel`.
  ShiftServicePeriodNotifier.fromBuckets({
    required Map<String, ServicePeriodAccumulator> buckets,
    List<ServicePeriodDefinition>? definitions,
    String? businessDate,
    String? iana,
    String businessDayStartLocalTime = _defaultBusinessDayStartLocalTime,
    Map<String, String?> primaryLeverIds = const {},
    Map<String, DaypartTargetContext> daypartTargets = const {},
  }) : _readService = const ShiftServicePeriodReadService(),
       _buckets = buckets,
       _primaryLeverIds = primaryLeverIds,
       _daypartTargets = daypartTargets,
       _definitions =
           definitions ?? ServicePeriodDefinitionResolver.demoDefinitions,
       _businessDate = businessDate,
       _iana = iana,
       _businessDayStartLocalTime = businessDayStartLocalTime,
       _isLoading = false,
       _missingTimezone = iana == null || iana.trim().isEmpty;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> refresh() async {
    await _load();
  }

  Future<void> _load() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();
    final scope = await SqliteRestaurantScopeRepository.instance
        .getOrCreateActiveRestaurant();
    final timing = await _safeReadTiming();

    _iana = scope.businessTimezone.trim().isEmpty
        ? null
        : scope.businessTimezone.trim();
    _businessDayStartLocalTime =
        timing?.businessDayStartLocalTime ?? _defaultBusinessDayStartLocalTime;
    _definitions = (timing?.servicePeriodDefinitions.isNotEmpty ?? false)
        ? timing!.servicePeriodDefinitions
        : ServicePeriodDefinitionResolver.demoDefinitions;

    if (_iana == null) {
      _missingTimezone = true;
      _buckets = {
        for (final d in _definitions)
          d.id: ServicePeriodAccumulator(servicePeriodId: d.id),
      };
      _primaryLeverIds = const {};
      _businessDate = null;
      _isLoading = false;
      if (_disposed) return;
      notifyListeners();
      return;
    }
    _missingTimezone = false;

    _businessDate = await SqliteOpenShiftSnapshotRepository.instance
        .getCurrentBusinessDate(restaurantId);

    if (_businessDate == null) {
      _buckets = {
        for (final d in _definitions)
          d.id: ServicePeriodAccumulator(servicePeriodId: d.id),
      };
      _primaryLeverIds = const {};
      _isLoading = false;
      if (_disposed) return;
      notifyListeners();
      return;
    }

    final snapshots = await SqliteOpenShiftSnapshotRepository.instance
        .getSnapshotsForDay(restaurantId, _businessDate!);
    final relevant = snapshots
        .where((s) => s.status == 'closed' || s.status == 'open')
        .toList();

    final synth = synthesizeCanonicalFactsFromSnapshots(
      snapshots: relevant,
      definitions: _definitions,
      businessDayStartLocalTime: _businessDayStartLocalTime!,
    );

    final location = BucketingLocationContext(
      iana: _iana!,
      businessDayStartLocalTime: _businessDayStartLocalTime!,
    );

    try {
      _buckets = _readService.build(
        posLines: synth.posLines,
        laborPunches: synth.laborPunches,
        location: location,
        definitions: _definitions,
      );
    } on MissingTimezoneError {
      _missingTimezone = true;
      _buckets = {
        for (final d in _definitions)
          d.id: ServicePeriodAccumulator(servicePeriodId: d.id),
      };
      _primaryLeverIds = const {};
      _isLoading = false;
      if (_disposed) return;
      notifyListeners();
      return;
    }

    // Phase 10.5.3 — mint per-period primary drivers off the accumulator.
    final profile = await _safeLoadActiveTargetProfile(restaurantId);
    final forecastCoversByPeriod = forecastCoversByPeriodFromSnapshots(
      snapshots: relevant,
      definitions: _definitions,
    );
    _primaryLeverIds = _readService.computePrimaryLevers(
      buckets: _buckets!,
      forecastCoversByPeriod: forecastCoversByPeriod,
      profile: profile,
    );

    // Per-Daypart V1 (Slice 4) — resolve the per-period locked target
    // context for every defined period. Closed-shift stamps win
    // (Promise 2); the open-shift active profile is the fallback for
    // periods that have not closed yet.
    _daypartTargets = await _resolveDaypartTargets(
      restaurantId: restaurantId,
      businessDate: _businessDate!,
      profile: profile,
    );

    _isLoading = false;
    if (_disposed) return;
    notifyListeners();
  }

  /// Builds the per-period target context map for the active business
  /// date.
  ///
  /// For each defined period:
  ///   * If a **closed** [ShiftRecord] exists for that period on this
  ///     business date, read its per-shift `daypart_*` stamp columns
  ///     (Promise 2 — closed truth keeps its own stamp). A closed shift
  ///     whose stamps are all null (cycle had no per-period row at
  ///     close) yields [DaypartTargetContext.none] — it is NOT silently
  ///     back-filled from the current profile, which would re-grade
  ///     closed truth.
  ///   * Otherwise (open / not-yet-closed period) fall back to the
  ///     active profile's `daypartFor(periodId)` row, or
  ///     [DaypartTargetContext.none] when the cycle wrote no per-period
  ///     row (Gap 42 fallback).
  Future<Map<String, DaypartTargetContext>> _resolveDaypartTargets({
    required String restaurantId,
    required String businessDate,
    required ActiveTargetProfile? profile,
  }) async {
    final closedByPeriod = <String, ShiftRecord>{};
    try {
      final closed = await SqliteShiftRecordRepository.instance
          .getClosedShiftsInDateRange(restaurantId, businessDate, businessDate);
      for (final r in closed) {
        closedByPeriod[r.daypart] = r;
      }
    } catch (_) {
      // Defensive: a read failure degrades to the open-shift fallback
      // path below rather than throwing the whole notifier load.
    }

    // Plan-side per-period reference: the in-force locked
    // WeeklyPlanSnapshot's per-(day, period) child row. This is the
    // per-daypart analogue of the whole-day lens's plan-side footers
    // (`rm.forecastSales`, `rm.planFohHours`/`planBohHours`). Read-only
    // locked values — no math here. A read failure or a legacy/Gap-42
    // snapshot with no child row degrades to null → the shared widgets
    // hide the footer exactly as whole-day does when its plan number is
    // absent (Design Rule 2 / Metric Honesty Doctrine).
    WeeklyPlanSnapshot? snapshot;
    try {
      snapshot = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForBusinessDate(restaurantId, businessDate);
    } catch (_) {
      snapshot = null;
    }

    final result = <String, DaypartTargetContext>{};
    for (final def in _definitions) {
      // The daypart LABOR card's `Theoretical X.X%` reference mirrors
      // the whole-day labor card, which reads `profile.theoreticalLaborPct`
      // off the *live* profile regardless of closed state (it is not a
      // closed-stamped value). The per-period mirror reads the live
      // profile's per-period theoretical the same way. `null` when the
      // cycle wrote no per-period row → honest empty (Design Rule 2);
      // the Promise-2 closed-stamp freeze still governs the locked rate
      // target sub-lines below, which keep reading the closed stamp.
      final theo = profile?.daypartTheoreticalLaborPctFor(def.id);

      // Plan-side locked per-period reference for this period (forecast
      // sales + required FOH/BOH hours). Independent of the rate-target
      // axis above — it is sourced from the locked WeeklyPlanSnapshot,
      // not the cycle/closed-stamp — so it is surfaced on every branch
      // below (including the `none` rate-target branch). `null` when the
      // snapshot has no child row → honest hidden footer.
      final dd = snapshot?.dayDaypartFor(
        businessDate: businessDate,
        servicePeriodId: def.id,
      );
      final planForecastCovers = dd?.forecastCovers;
      final planForecastSales = dd?.forecastSales;
      // Per-Daypart V1 (Slice 5): the persisted per-period FOH/BOH hours
      // are doubles, but the Shift card surfaces them to the operator as
      // whole hours (`requiredHours.round()` in shift_dashboard). Route
      // them through the SAME shared reconciliation the Variance Full
      // Week row uses (`reconcileLockedDaypartIntHours`) so the same
      // (day, period) shows IDENTICAL integer hours on both screens and
      // per-period whole hours sum exactly to the locked day-level
      // integer hours (Option B — not naive independent per-cell round;
      // parity pinned by test). Carried as doubles to keep the widget
      // contract byte-unchanged; the value is already a reconciled
      // integer so `.round()` is now an identity, not a re-rounding.
      final reconciledHrs = snapshot == null
          ? null
          : reconciledLockedDaypartFor(
              snapshot: snapshot,
              businessDate: businessDate,
              servicePeriodId: def.id,
              definitions: _definitions,
            );
      final planFohHours = reconciledHrs?.requiredFohHours.toDouble();
      final planBohHours = reconciledHrs?.requiredBohHours.toDouble();

      final closed = closedByPeriod[def.id];
      if (closed != null) {
        // Promise 2: closed period reads its own stamp only for the
        // locked *rate* targets. All-null stamps stay `none` — never
        // re-grade those with the live profile. The theoretical labor %
        // reference is the lone exception (it parallels the whole-day
        // card's live-profile theoretical, not a stamp).
        if (closed.daypartTargetCPLH == null &&
            closed.daypartTargetSPLH == null &&
            closed.daypartTargetPPA == null &&
            closed.daypartOpzFloorCPLH == null &&
            closed.daypartOpzCeilingCPLH == null) {
          result[def.id] = DaypartTargetContext(
            source: 'none',
            theoreticalLaborPct: theo,
            forecastCovers: planForecastCovers,
            forecastSales: planForecastSales,
            requiredFohHours: planFohHours,
            requiredBohHours: planBohHours,
          );
        } else {
          result[def.id] = DaypartTargetContext(
            source: 'closed_stamp',
            targetCPLH: closed.daypartTargetCPLH,
            targetSPLH: closed.daypartTargetSPLH,
            targetPPA: closed.daypartTargetPPA,
            opzFloorCPLH: closed.daypartOpzFloorCPLH,
            opzCeilingCPLH: closed.daypartOpzCeilingCPLH,
            theoreticalLaborPct: theo,
            forecastCovers: planForecastCovers,
            forecastSales: planForecastSales,
            requiredFohHours: planFohHours,
            requiredBohHours: planBohHours,
          );
        }
        continue;
      }

      // Open / not-yet-closed period — fall back to the current cycle's
      // per-period row.
      final row = profile?.daypartFor(def.id);
      if (row == null) {
        // No rate-target row, but the plan-side locked references may
        // still exist independently — surface them so the COVERS /
        // SALES / FOH·BOH HRS footers populate even on a Gap-42 rate
        // fallback. `forecastCovers` is the per-daypart analogue of the
        // whole-day `rm.forecastCovers` footer and, like `forecastSales`
        // / `required*Hours`, is plan-side (it does NOT depend on a
        // closed shift or an in-period actual), so a not-yet-started
        // daypart shows the same locked "Forecast N" the closed branches
        // already render — `null` only when the in-force snapshot has no
        // per-period row (Design Rule 2 honest empty, never `0`).
        result[def.id] = DaypartTargetContext(
          source: 'none',
          theoreticalLaborPct: theo,
          forecastCovers: planForecastCovers,
          forecastSales: planForecastSales,
          requiredFohHours: planFohHours,
          requiredBohHours: planBohHours,
        );
      } else {
        result[def.id] = DaypartTargetContext(
          source: 'open_profile',
          targetCPLH: row.daypartTargetCPLH,
          targetSPLH: row.daypartTargetSPLH,
          targetPPA: row.daypartTargetPPA,
          opzFloorCPLH: row.daypartOpzFloorCPLH,
          opzCeilingCPLH: row.daypartOpzCeilingCPLH,
          theoreticalLaborPct: theo,
          forecastCovers: planForecastCovers,
          forecastSales: planForecastSales,
          requiredFohHours: planFohHours,
          requiredBohHours: planBohHours,
        );
      }
    }
    return result;
  }

  Future<ActiveTargetProfile?> _safeLoadActiveTargetProfile(
    String restaurantId,
  ) async {
    try {
      return await WageStandardContextService.instance.loadOrBootstrapProfile(
        restaurantId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<RestaurantTimingConfig?> _safeReadTiming() async {
    try {
      return await RestaurantTimingConfigReadService.instance
          .getActiveTimingConfig();
    } catch (_) {
      return null;
    }
  }

  /// Applies a single POS-line correction and notifies listeners. The
  /// notifier owns dedup; callers pass the prior fact (by `sourceId`)
  /// and its replacement (or null for a delete). This is the Phase 8
  /// hook — the demo synthesizer rebuilds in full on refresh and does
  /// not call this.
  void applyPosLineCorrection({
    required CanonicalPosLine prior,
    required CanonicalPosLine? replacement,
  }) {
    if (_buckets == null || _iana == null) return;
    final location = BucketingLocationContext(
      iana: _iana!,
      businessDayStartLocalTime: businessDayStartLocalTime,
    );
    _buckets = _readService.applyPosLineCorrection(
      current: _buckets!,
      prior: prior,
      replacement: replacement,
      location: location,
      definitions: _definitions,
    );
    notifyListeners();
  }

  /// Applies a single labor-punch correction and notifies listeners.
  void applyLaborPunchCorrection({
    required CanonicalLaborPunch prior,
    required CanonicalLaborPunch? replacement,
  }) {
    if (_buckets == null || _iana == null) return;
    final location = BucketingLocationContext(
      iana: _iana!,
      businessDayStartLocalTime: businessDayStartLocalTime,
    );
    _buckets = _readService.applyLaborPunchCorrection(
      current: _buckets!,
      prior: prior,
      replacement: replacement,
      location: location,
      definitions: _definitions,
    );
    notifyListeners();
  }
}

/// Phase 10.5.3 — sums per-period forecast covers from the day's
/// open/closed snapshots. Pre-Phase-8, the snapshot's `daypart` field
/// matches the service-period definition id directly. Snapshots whose
/// `daypart` doesn't match a defined period are dropped (defensive,
/// not expected in normal operation).
@visibleForTesting
Map<String, int> forecastCoversByPeriodFromSnapshots({
  required List<OpenShiftSnapshot> snapshots,
  required List<ServicePeriodDefinition> definitions,
}) {
  final defIds = {for (final d in definitions) d.id};
  final byPeriod = <String, int>{for (final d in definitions) d.id: 0};
  for (final s in snapshots) {
    if (!defIds.contains(s.daypart)) continue;
    byPeriod[s.daypart] = (byPeriod[s.daypart] ?? 0) + s.forecastCovers;
  }
  return byPeriod;
}

/// Synthesized canonical facts. Pure-data return for
/// [synthesizeCanonicalFactsFromSnapshots] — kept on the notifier file
/// so the synthesizer can be unit-tested without exporting helpers.
@visibleForTesting
class SynthesizedDaypartFacts {
  final List<CanonicalPosLine> posLines;
  final List<CanonicalLaborPunch> laborPunches;
  const SynthesizedDaypartFacts(this.posLines, this.laborPunches);
}

/// Synthesizes canonical POS lines and labor punches from existing
/// daypart-pre-bucketed [OpenShiftSnapshot] records. One POS line is
/// emitted at the midpoint of each snapshot's matching service period
/// with covers / sales drawn from the snapshot; one FOH + one BOH
/// labor punch are emitted, each starting at the period start and
/// running for the snapshot's scheduled hours (capped at the period
/// length so the bucketer never sees a punch reaching outside its
/// owning period).
///
/// This is the Phase-8-pending stand-in. Once vendor connectors are
/// live, the same notifier reads real canonical facts from the SQLite
/// fact tables; the read service and accumulator stay the same.
@visibleForTesting
SynthesizedDaypartFacts synthesizeCanonicalFactsFromSnapshots({
  required List<OpenShiftSnapshot> snapshots,
  required List<ServicePeriodDefinition> definitions,
  required String businessDayStartLocalTime,
}) {
  final posLines = <CanonicalPosLine>[];
  final laborPunches = <CanonicalLaborPunch>[];
  final defsById = {for (final d in definitions) d.id: d};

  for (final s in snapshots) {
    final def = defsById[s.daypart];
    if (def == null) continue;
    final interval = _periodIntervalForBusinessDate(
      definition: def,
      businessDateIso: s.businessDate,
      businessDayStartLocalTime: businessDayStartLocalTime,
    );
    if (interval == null) continue;
    final periodMinutes = interval.end.difference(interval.start).inMinutes;
    if (periodMinutes <= 0) continue;

    final midpoint = interval.start.add(
      Duration(minutes: (periodMinutes / 2).floor()),
    );
    final sales = s.currentCovers * s.currentPPA;
    posLines.add(
      CanonicalPosLine(
        sourceId: 'snap_pos_${s.dayLabel}_${s.daypart}',
        eventLocalTimestamp: midpoint,
        covers: s.currentCovers,
        sales: sales,
      ),
    );

    final fohMinutes = (s.scheduledFohHours * 60).clamp(0, periodMinutes);
    if (fohMinutes > 0 && s.blendedWageAvailable) {
      laborPunches.add(
        CanonicalLaborPunch(
          sourceId: 'snap_foh_${s.dayLabel}_${s.daypart}',
          clockedInLocal: interval.start,
          clockedOutLocal: interval.start.add(Duration(minutes: fohMinutes)),
          role: 'foh',
          hourlyWage: s.blendedWage,
        ),
      );
    }
    final bohMinutes = (s.scheduledBohHours * 60).clamp(0, periodMinutes);
    if (bohMinutes > 0 && s.blendedWageAvailable) {
      laborPunches.add(
        CanonicalLaborPunch(
          sourceId: 'snap_boh_${s.dayLabel}_${s.daypart}',
          clockedInLocal: interval.start,
          clockedOutLocal: interval.start.add(Duration(minutes: bohMinutes)),
          role: 'boh',
          hourlyWage: s.blendedWage,
        ),
      );
    }
  }

  return SynthesizedDaypartFacts(posLines, laborPunches);
}

/// Computes the calendar `[start, end)` interval for [definition] on
/// the given business date. Mirrors `DaypartBucketer`'s internal helper
/// (kept private) so the synthesizer can place its facts inside the
/// matching period without cross-importing private bucketer state.
({DateTime start, DateTime end})? _periodIntervalForBusinessDate({
  required ServicePeriodDefinition definition,
  required String businessDateIso,
  required String businessDayStartLocalTime,
}) {
  final cutoffMin = _parseHm(businessDayStartLocalTime) ?? 0;
  final startMin = _parseHm(definition.startLocalTime);
  final endMin = _parseHm(definition.endLocalTime);
  if (startMin == null || endMin == null) return null;

  final businessDate = DateTime.parse(businessDateIso);
  final startCalendar = startMin >= cutoffMin
      ? businessDate
      : businessDate.add(const Duration(days: 1));
  final startInstant = startCalendar.add(Duration(minutes: startMin));
  final DateTime endInstant;
  if (definition.rollsPastMidnight) {
    final endCalendar = startCalendar.add(const Duration(days: 1));
    endInstant = endCalendar.add(Duration(minutes: endMin));
  } else {
    endInstant = startCalendar.add(Duration(minutes: endMin));
  }
  return (start: startInstant, end: endInstant);
}

int? _parseHm(String hm) {
  final parts = hm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// Resolves the active service-period id for a restaurant-local [now]
/// using **business-date weekday** (not wall-clock weekday) and the
/// inclusive-endpoint rule.
///
/// Time-of-day comparison uses full sub-minute precision (seconds,
/// milliseconds, microseconds) — the inclusive end applies only at
/// the exact boundary instant, not for the entire ending minute.
/// `15:00:00.000` is still Lunch; `15:00:00.001` and beyond are the
/// post-Lunch gap. This must match `DaypartBucketer._classifyInstant`
/// so the active chip / time-into-service header doesn't linger up to
/// 59 seconds past the boundary.
///
/// Returns null when no period is active or when the business-date /
/// weekday computation fails. Exposed as a top-level helper so the
/// Shift dashboard and the daypart Variance lens share a single
/// resolver.
String? resolveActiveServicePeriodId({
  required DateTime localNow,
  required String businessDayStartLocalTime,
  required List<ServicePeriodDefinition> definitions,
}) {
  final businessDateIso = BusinessDateResolver.resolve(
    localTimestamp: localNow,
    businessDayStartLocalTime: businessDayStartLocalTime,
  );
  final businessWeekday = DateTime.parse(businessDateIso).weekday;
  final localTimeOfDay = Duration(
    hours: localNow.hour,
    minutes: localNow.minute,
    seconds: localNow.second,
    milliseconds: localNow.millisecond,
    microseconds: localNow.microsecond,
  );
  for (final d in ServicePeriodDefinitionResolver.ordered(definitions)) {
    if (!d.applicableDays.contains(businessWeekday)) continue;
    final startMin = _parseHm(d.startLocalTime);
    final endMin = _parseHm(d.endLocalTime);
    if (startMin == null || endMin == null) continue;
    final start = Duration(minutes: startMin);
    final end = Duration(minutes: endMin);
    if (d.rollsPastMidnight) {
      if (localTimeOfDay >= start || localTimeOfDay <= end) return d.id;
    } else {
      if (localTimeOfDay >= start && localTimeOfDay <= end) return d.id;
    }
  }
  return null;
}

/// Resolves the active period's calendar `[start, end)` interval for
/// computing time-into-service. Returns null when no period is active
/// or when business-date math fails.
({DateTime start, DateTime end, ServicePeriodDefinition definition})?
resolveActiveServicePeriodInterval({
  required DateTime localNow,
  required String businessDayStartLocalTime,
  required List<ServicePeriodDefinition> definitions,
}) {
  final activeId = resolveActiveServicePeriodId(
    localNow: localNow,
    businessDayStartLocalTime: businessDayStartLocalTime,
    definitions: definitions,
  );
  if (activeId == null) return null;
  final def = definitions.firstWhere(
    (d) => d.id == activeId,
    orElse: () => throw StateError('Active period $activeId not in defs'),
  );
  final businessDateIso = BusinessDateResolver.resolve(
    localTimestamp: localNow,
    businessDayStartLocalTime: businessDayStartLocalTime,
  );
  final interval = _periodIntervalForBusinessDate(
    definition: def,
    businessDateIso: businessDateIso,
    businessDayStartLocalTime: businessDayStartLocalTime,
  );
  if (interval == null) return null;
  return (start: interval.start, end: interval.end, definition: def);
}

/// Per-Daypart V1 (Slice 4 fix) — the phase a service period is in
/// relative to a restaurant-local clock.
enum ServicePeriodPhase {
  /// The period already closed earlier on the active business date.
  past,

  /// The period is the currently-active period.
  active,

  /// The period has not opened yet on the active business date (or is
  /// not applicable on this business weekday — it will not open today).
  future,
}

/// Resolves whether [periodId] is in the past, active, or future for a
/// restaurant-local [localNow], using the **same** business-date-aware
/// machinery as [resolveActiveServicePeriodId]: the business-date
/// weekday (via [BusinessDateResolver]) for applicability and the
/// wall-clock time-of-day (full sub-minute precision) for the
/// start/end comparison. It never reads `DateTime.now().weekday` and
/// never compares a tz-aware instant against a naive interval
/// `DateTime`, so the answer matches the active chip exactly.
///
/// Non-active period rules (inclusive end, mirroring
/// [resolveActiveServicePeriodId] — active when `start <= t <= end`):
///   * applicable today AND past the period's end → [ServicePeriodPhase.past]
///     ("Period closed");
///   * otherwise → [ServicePeriodPhase.future] ("Opens at …"). This
///     covers "not opened yet today" and "not applicable on this
///     business weekday" — both are honestly *not closed*, so the card
///     never tells the operator a period that already ended is still
///     waiting to open.
///
/// A `rollsPastMidnight` period that is not active is always treated as
/// [ServicePeriodPhase.future]: its only non-active window is between
/// its end and its next start on the same business day, i.e. it has not
/// re-opened yet.
ServicePeriodPhase resolveServicePeriodPhase({
  required DateTime localNow,
  required String businessDayStartLocalTime,
  required List<ServicePeriodDefinition> definitions,
  required String periodId,
}) {
  final activeId = resolveActiveServicePeriodId(
    localNow: localNow,
    businessDayStartLocalTime: businessDayStartLocalTime,
    definitions: definitions,
  );
  if (activeId == periodId) return ServicePeriodPhase.active;

  ServicePeriodDefinition? def;
  for (final d in definitions) {
    if (d.id == periodId) {
      def = d;
      break;
    }
  }
  if (def == null) return ServicePeriodPhase.future;

  final businessDateIso = BusinessDateResolver.resolve(
    localTimestamp: localNow,
    businessDayStartLocalTime: businessDayStartLocalTime,
  );
  final businessWeekday = DateTime.parse(businessDateIso).weekday;
  if (!def.applicableDays.contains(businessWeekday)) {
    // Not applicable on this business weekday — it will not open today.
    // Honest framing is "Opens at …", never "Period closed".
    return ServicePeriodPhase.future;
  }

  final startMin = _parseHm(def.startLocalTime);
  final endMin = _parseHm(def.endLocalTime);
  if (startMin == null || endMin == null) return ServicePeriodPhase.future;

  if (def.rollsPastMidnight) {
    // Not active (excluded above); a rolling period's only non-active
    // window is between its end and its next start → has not re-opened.
    return ServicePeriodPhase.future;
  }

  final localTimeOfDay = Duration(
    hours: localNow.hour,
    minutes: localNow.minute,
    seconds: localNow.second,
    milliseconds: localNow.millisecond,
    microseconds: localNow.microsecond,
  );
  final end = Duration(minutes: endMin);
  // Inclusive end matches resolveActiveServicePeriodId, so "past"
  // begins strictly after the period's end instant.
  if (localTimeOfDay > end) return ServicePeriodPhase.past;
  return ServicePeriodPhase.future;
}
