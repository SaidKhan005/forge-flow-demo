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

import '../data/app_defaults.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/open_shift_snapshot.dart';
import '../domain/models/restaurant_timing_config.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/business_date_resolver.dart';
import '../domain/services/daypart_bucketer.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../services/restaurant_timing_config_read_service.dart';
import '../services/shift_service_period_read_service.dart';
import '../services/wage_standard_context_service.dart';

/// Default business-day cutoff used when no persisted timing config is
/// available. Matches the seeded
/// `business_day_start_local_time` and the 10.5.0 widget fallback.
const String _defaultBusinessDayStartLocalTime = '04:00';

class ShiftServicePeriodNotifier extends ChangeNotifier {
  final ShiftServicePeriodReadService _readService;

  Map<String, ServicePeriodAccumulator>? _buckets;
  Map<String, String?> _primaryLeverIds = const {};
  List<ServicePeriodDefinition> _definitions =
      ServicePeriodDefinitionResolver.demoDefinitions;
  String? _businessDate;
  String? _businessDayStartLocalTime;
  String? _iana;
  bool _isLoading = true;
  bool _missingTimezone = false;

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
  })  : _readService = const ShiftServicePeriodReadService(),
        _buckets = buckets,
        _primaryLeverIds = primaryLeverIds,
        _definitions = definitions ??
            ServicePeriodDefinitionResolver.demoDefinitions,
        _businessDate = businessDate,
        _iana = iana,
        _businessDayStartLocalTime = businessDayStartLocalTime,
        _isLoading = false,
        _missingTimezone = iana == null || iana.trim().isEmpty;

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
      notifyListeners();
      return;
    }

    final snapshots = await SqliteOpenShiftSnapshotRepository.instance
        .getSnapshotsForDay(restaurantId, _businessDate!);
    final relevant =
        snapshots.where((s) => s.status == 'closed' || s.status == 'open').toList();

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

    _isLoading = false;
    notifyListeners();
  }

  Future<ActiveTargetProfile?> _safeLoadActiveTargetProfile(
      String restaurantId) async {
    try {
      return await WageStandardContextService.instance
          .loadOrBootstrapProfile(restaurantId);
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

    final midpoint = interval.start
        .add(Duration(minutes: (periodMinutes / 2).floor()));
    final sales = s.currentCovers * s.currentPPA;
    posLines.add(CanonicalPosLine(
      sourceId: 'snap_pos_${s.dayLabel}_${s.daypart}',
      eventLocalTimestamp: midpoint,
      covers: s.currentCovers,
      sales: sales,
    ));

    final fohMinutes = (s.scheduledFohHours * 60).clamp(0, periodMinutes);
    if (fohMinutes > 0) {
      laborPunches.add(CanonicalLaborPunch(
        sourceId: 'snap_foh_${s.dayLabel}_${s.daypart}',
        clockedInLocal: interval.start,
        clockedOutLocal: interval.start.add(Duration(minutes: fohMinutes)),
        role: 'foh',
        hourlyWage: s.blendedWage,
      ));
    }
    final bohMinutes = (s.scheduledBohHours * 60).clamp(0, periodMinutes);
    if (bohMinutes > 0) {
      laborPunches.add(CanonicalLaborPunch(
        sourceId: 'snap_boh_${s.dayLabel}_${s.daypart}',
        clockedInLocal: interval.start,
        clockedOutLocal: interval.start.add(Duration(minutes: bohMinutes)),
        role: 'boh',
        hourlyWage: s.blendedWage,
      ));
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
