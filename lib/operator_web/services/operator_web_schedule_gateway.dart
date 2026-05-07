// Phase 8 W5.B - Operator Web Schedule gateway.
//
// Reads the locked weekly plan snapshot + the matching forecast context
// for the active operator/location. The proxy already exposes both
// resources via the per-tenant routes mounted by
// `tool/advisor_proxy/weekly_plan_routes.dart`:
//
//   GET /v1/operators/:operator_id/locations/:location_id/
//       weekly_plan_snapshots
//   GET /v1/operators/:operator_id/locations/:location_id/
//       forecast_contexts
//
// The Schedule screen needs the latest active snapshot and the matching
// forecast context for the current week-in-force; this gateway pulls
// both, picks the most recently locked snapshot, and pairs it with the
// forecast context whose week range matches.
//
// Web-safe: pure-Dart over `package:http`. No `dart:io`, no sqflite.
// Mirrors the live + demo + provider-sentinel pattern used by the
// Connector Backfill Jobs gateway (W2.D / PR #310) and the Vendor
// Lifecycle Recently Available gateway (W4.A / PR #310).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One day row inside a locked weekly plan snapshot.
class ScheduleSnapshotDay {
  const ScheduleSnapshotDay({
    required this.day,
    required this.businessDate,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
  });

  /// Three-letter day label as ordered by the snapshot
  /// (e.g. `Mon`, `Tue`).
  final String day;

  /// `YYYY-MM-DD` business date for the row in restaurant-local time.
  final String businessDate;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
}

/// Wire shape the screen renders. Carries enough explainer context to
/// satisfy Doc 1's `Plan / Schedule Screen` contract (60-day baseline,
/// 21-day trend, target PPA, forecast sales, required FOH/BOH hours,
/// theoretical labor dollars).
class ScheduleSnapshot {
  const ScheduleSnapshot({
    required this.snapshotId,
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.weekStartDate,
    required this.weekEndDate,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalFohLaborDollars,
    required this.theoreticalBohLaborDollars,
    required this.coversSource,
    required this.salesSource,
    required this.lockedAt,
    required this.dayRows,
    this.forecastContext,
  });

  final String snapshotId;
  final String operatorId;
  final String locationId;
  final String restaurantId;

  /// `YYYY-MM-DD` boundaries (inclusive) of the locked week.
  final String weekStartDate;
  final String weekEndDate;

  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  final double theoreticalFohLaborDollars;
  final double theoreticalBohLaborDollars;
  final String coversSource;
  final String salesSource;
  final DateTime lockedAt;
  final List<ScheduleSnapshotDay> dayRows;

  /// Forecast context that drove the snapshot. Null when no matching
  /// row is on the wire — the screen renders the thin-history fallback
  /// in that case.
  final ScheduleForecastContext? forecastContext;

  double get theoreticalLaborDollars =>
      theoreticalFohLaborDollars + theoreticalBohLaborDollars;
}

/// Forecast explainer context. Mirrors the proxy's `ForecastContextRow`
/// projection: 60-day baseline + 21-day trend + target PPA + theoretical
/// labor dollars. Field names mirror the wire shape so the screen and
/// gateway never disagree.
class ScheduleForecastContext {
  const ScheduleForecastContext({
    required this.forecastContextId,
    required this.weekStartDate,
    required this.weekEndDate,
    required this.coversSource,
    required this.builtAt,
    required this.targetPpa,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalLaborDollars,
    required this.baselineWeeksRepresented,
    this.anchorBusinessDate,
    this.baselineTotalCovers,
    this.baselineWeeklyAvgCovers,
    this.recentThreeWeekTotalCovers,
    this.recentThreeWeekWeeklyAvgCovers,
    this.recentTrendDeltaCovers,
    this.resolvedWeeklyForecastCovers,
  });

  final String forecastContextId;
  final String weekStartDate;
  final String weekEndDate;

  /// Wire source label, e.g. `app_derived_from_historical_average` or
  /// `unavailable`. The screen reads this to flip between the explained
  /// state and the thin-history caveat.
  final String coversSource;
  final DateTime builtAt;
  final double targetPpa;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  final double theoreticalLaborDollars;
  final double baselineWeeksRepresented;
  final String? anchorBusinessDate;
  final int? baselineTotalCovers;
  final int? baselineWeeklyAvgCovers;
  final int? recentThreeWeekTotalCovers;
  final int? recentThreeWeekWeeklyAvgCovers;
  final int? recentTrendDeltaCovers;
  final int? resolvedWeeklyForecastCovers;

  /// True when the proxy could not build a 60-day baseline. The
  /// explainer panel renders the "need 60 days" caveat in that case
  /// instead of zeroes.
  bool get hasBaseline =>
      coversSource != 'unavailable' &&
      baselineWeeklyAvgCovers != null &&
      baselineTotalCovers != null;

  /// Approximate count of business days behind the baseline. Each
  /// covered week is 7 days; thin-history fallback messaging surfaces
  /// the integer rounded down so the operator sees "29 days" rather
  /// than "29.4".
  int get historyDays => (baselineWeeksRepresented * 7).floor();
}

/// Narrow gateway interface the Schedule screen calls.
abstract class OperatorWebScheduleGateway {
  /// Loads the most recently locked active snapshot for the active
  /// (operator, location) and pairs it with the matching forecast
  /// context. Returns null when no snapshot has been locked yet — the
  /// screen renders the empty / setup state.
  Future<ScheduleSnapshot?> fetchCurrent({
    required String operatorId,
    required String locationId,
  });
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply an [OperatorWebScheduleGateway]. Live wiring (Firebase
/// source + proxy) implements this; demo / fixture sources may either
/// leave the mixin off (router falls back to the in-memory demo
/// gateway) or mix in their own demo impl.
abstract class OperatorWebScheduleGatewayProvider {
  OperatorWebScheduleGateway? get scheduleGateway;
}

/// Thrown when the proxy returns a non-2xx response, the body is
/// malformed, or the network call fails. Carries the proxy's error
/// code + message verbatim so the screen can surface honest copy.
class OperatorWebScheduleGatewayException implements Exception {
  const OperatorWebScheduleGatewayException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'OperatorWebScheduleGatewayException(code: $code, status: $statusCode)';
}

String operatorWebWeeklyPlanSnapshotsPath({
  required String operatorId,
  required String locationId,
}) =>
    '/v1/operators/${Uri.encodeComponent(operatorId)}/locations/'
    '${Uri.encodeComponent(locationId)}/weekly_plan_snapshots';

String operatorWebForecastContextsPath({
  required String operatorId,
  required String locationId,
}) =>
    '/v1/operators/${Uri.encodeComponent(operatorId)}/locations/'
    '${Uri.encodeComponent(locationId)}/forecast_contexts';

/// Live HTTP gateway. Reaches the proxy directly with a Bearer token
/// from [idTokenProvider] on every call.
class OperatorWebHttpScheduleGateway implements OperatorWebScheduleGateway {
  OperatorWebHttpScheduleGateway({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
  })  : _baseUri = proxyBaseUri,
        _idTokenProvider = idTokenProvider,
        _client = client ?? http.Client(),
        _timeout = timeout;

  final Uri _baseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _client;
  final Duration _timeout;

  @override
  Future<ScheduleSnapshot?> fetchCurrent({
    required String operatorId,
    required String locationId,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebScheduleGatewayException(
        code: 'unauthenticated',
        message: 'Sign in again to load your schedule.',
        statusCode: 401,
      );
    }
    final headers = <String, String>{
      'authorization': 'Bearer ${token.trim()}',
      'accept': 'application/json',
    };

    final snapshotsUrl = _baseUri.resolve(
      operatorWebWeeklyPlanSnapshotsPath(
        operatorId: operatorId,
        locationId: locationId,
      ),
    );
    final contextsUrl = _baseUri.resolve(
      operatorWebForecastContextsPath(
        operatorId: operatorId,
        locationId: locationId,
      ),
    );

    final snapshots = await _readList(
      url: snapshotsUrl,
      headers: headers,
      key: 'weekly_plan_snapshots',
    );
    if (snapshots.isEmpty) return null;
    final activeSnapshots = <Map<String, Object?>>[
      for (final entry in snapshots)
        if (entry['is_active'] != false) entry,
    ];
    if (activeSnapshots.isEmpty) return null;
    activeSnapshots.sort((a, b) {
      final lockedA = _readDate(a['locked_at']) ??
          _readDate(a['updated_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final lockedB = _readDate(b['locked_at']) ??
          _readDate(b['updated_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      return lockedB.compareTo(lockedA);
    });
    final latest = activeSnapshots.first;

    final contexts = await _readList(
      url: contextsUrl,
      headers: headers,
      key: 'forecast_contexts',
    );

    final weekStart = _readNonBlankString(latest['week_start_date']);
    final weekEnd = _readNonBlankString(latest['week_end_date']);
    Map<String, Object?>? matchingContext;
    if (weekStart != null && weekEnd != null) {
      for (final entry in contexts) {
        if (_readNonBlankString(entry['week_start_date']) == weekStart &&
            _readNonBlankString(entry['week_end_date']) == weekEnd) {
          matchingContext = entry;
          break;
        }
      }
    }

    return _scheduleSnapshotFromJson(
      latest,
      contextJson: matchingContext,
    );
  }

  Future<List<Map<String, Object?>>> _readList({
    required Uri url,
    required Map<String, String> headers,
    required String key,
  }) async {
    final http.Response response;
    try {
      response = await _client.get(url, headers: headers).timeout(_timeout);
    } on TimeoutException {
      throw const OperatorWebScheduleGatewayException(
        code: 'transport_timeout',
        message: 'Schedule request timed out before reaching the proxy.',
      );
    } catch (error) {
      throw OperatorWebScheduleGatewayException(
        code: 'transport_error',
        message: 'Schedule request failed before reaching the proxy ($error).',
      );
    }
    final body = _decode(response);
    final raw = body[key];
    if (raw is! List) {
      throw const OperatorWebScheduleGatewayException(
        code: 'malformed_response',
        message: "We couldn't read your schedule. Try again in a minute.",
      );
    }
    return <Map<String, Object?>>[
      for (final entry in raw)
        if (entry is Map) Map<String, Object?>.from(entry),
    ];
  }

  Map<String, Object?> _decode(http.Response response) {
    Map<String, Object?> body;
    try {
      final decoded = response.body.trim().isEmpty
          ? const <String, Object?>{}
          : jsonDecode(response.body);
      body = decoded is Map
          ? Map<String, Object?>.from(decoded)
          : <String, Object?>{};
    } catch (_) {
      throw OperatorWebScheduleGatewayException(
        code: 'malformed_response',
        message:
            "We couldn't read the response from Forge & Flow. Try again in a minute.",
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode >= 400) {
      throw OperatorWebScheduleGatewayException(
        code: (body['error'] as String?) ?? 'request_failed',
        message: (body['message'] as String?) ??
            "We couldn't load your schedule. Try again in a minute.",
        statusCode: response.statusCode,
      );
    }
    return body;
  }
}

/// In-memory demo gateway. Returns the seeded sample week (or null) so
/// the walkthrough renders without a live proxy.
class OperatorWebDemoScheduleGateway implements OperatorWebScheduleGateway {
  OperatorWebDemoScheduleGateway({ScheduleSnapshot? seed}) : _seed = seed;

  final ScheduleSnapshot? _seed;

  @override
  Future<ScheduleSnapshot?> fetchCurrent({
    required String operatorId,
    required String locationId,
  }) async {
    final seed = _seed;
    if (seed == null) return null;
    if (seed.operatorId.isNotEmpty && seed.operatorId != operatorId) {
      return null;
    }
    if (seed.locationId.isNotEmpty && seed.locationId != locationId) {
      return null;
    }
    return seed;
  }
}

/// Builds a sane demo snapshot keyed to the supplied operator + location.
/// Pulls a Mon–Sun week starting on the most recent past Monday so the
/// header copy shows a plausible date range. Used by the router fallback
/// and tests.
ScheduleSnapshot demoScheduleSnapshotFor({
  required String operatorId,
  required String locationId,
  required String restaurantId,
  DateTime? now,
}) {
  final clock = (now ?? DateTime.now()).toUtc();
  final today = DateTime.utc(clock.year, clock.month, clock.day);
  final daysFromMonday = (today.weekday - DateTime.monday) % 7;
  final weekStart = today.subtract(Duration(days: daysFromMonday));
  final weekEnd = weekStart.add(const Duration(days: 6));
  String fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  const labels = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  // Plausible day distribution: weekend covers heavier than weekdays.
  const dailyCovers = <int>[120, 130, 140, 160, 220, 260, 200];
  const dailyFoh = <int>[28, 30, 32, 36, 44, 50, 40];
  const dailyBoh = <int>[20, 22, 24, 26, 32, 36, 28];
  final dayRows = <ScheduleSnapshotDay>[
    for (var i = 0; i < 7; i++)
      ScheduleSnapshotDay(
        day: labels[i],
        businessDate: fmt(weekStart.add(Duration(days: i))),
        forecastCovers: dailyCovers[i],
        forecastSales: dailyCovers[i] * 38.0,
        requiredFohHours: dailyFoh[i],
        requiredBohHours: dailyBoh[i],
      ),
  ];
  final totalCovers = dailyCovers.fold<int>(0, (a, b) => a + b);
  final totalSales = totalCovers * 38.0;
  final totalFoh = dailyFoh.fold<int>(0, (a, b) => a + b);
  final totalBoh = dailyBoh.fold<int>(0, (a, b) => a + b);
  final fohDollars = totalFoh * 18.50;
  final bohDollars = totalBoh * 16.25;
  final lockedAt = clock;
  return ScheduleSnapshot(
    snapshotId: 'demo-snapshot-${fmt(weekStart).replaceAll('-', '')}',
    operatorId: operatorId,
    locationId: locationId,
    restaurantId: restaurantId,
    weekStartDate: fmt(weekStart),
    weekEndDate: fmt(weekEnd),
    forecastCovers: totalCovers,
    forecastSales: totalSales,
    requiredFohHours: totalFoh,
    requiredBohHours: totalBoh,
    theoreticalFohLaborDollars: fohDollars,
    theoreticalBohLaborDollars: bohDollars,
    coversSource: 'app_derived_from_historical_average',
    salesSource: 'app_derived_from_historical_average',
    lockedAt: lockedAt,
    dayRows: dayRows,
    forecastContext: ScheduleForecastContext(
      forecastContextId: 'demo-forecast-${fmt(weekStart).replaceAll('-', '')}',
      weekStartDate: fmt(weekStart),
      weekEndDate: fmt(weekEnd),
      coversSource: 'app_derived_from_historical_average',
      builtAt: lockedAt,
      targetPpa: 38.0,
      forecastSales: totalSales,
      requiredFohHours: totalFoh,
      requiredBohHours: totalBoh,
      theoreticalLaborDollars: fohDollars + bohDollars,
      baselineWeeksRepresented: 60 / 7,
      anchorBusinessDate: fmt(weekStart.subtract(const Duration(days: 1))),
      baselineTotalCovers: totalCovers * 8,
      baselineWeeklyAvgCovers: totalCovers,
      recentThreeWeekTotalCovers: totalCovers * 3,
      recentThreeWeekWeeklyAvgCovers: totalCovers,
      recentTrendDeltaCovers: 0,
      resolvedWeeklyForecastCovers: totalCovers,
    ),
  );
}

ScheduleSnapshot _scheduleSnapshotFromJson(
  Map<String, Object?> json, {
  Map<String, Object?>? contextJson,
}) {
  final snapshotId = _readNonBlankString(json['snapshot_id']) ?? '';
  final operatorId = _readNonBlankString(json['operator_id']) ?? '';
  final locationId = _readNonBlankString(json['location_id']) ?? '';
  final restaurantId = _readNonBlankString(json['restaurant_id']) ?? '';
  final weekStart = _readNonBlankString(json['week_start_date']) ?? '';
  final weekEnd = _readNonBlankString(json['week_end_date']) ?? '';
  if (snapshotId.isEmpty || weekStart.isEmpty || weekEnd.isEmpty) {
    throw const OperatorWebScheduleGatewayException(
      code: 'malformed_snapshot',
      message: "We couldn't read your locked weekly plan. Try again in a minute.",
    );
  }
  final lockedAt = _readDate(json['locked_at']) ??
      _readDate(json['updated_at']) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final rawDays = json['day_rows'];
  final dayRows = <ScheduleSnapshotDay>[];
  if (rawDays is List) {
    for (final entry in rawDays) {
      if (entry is Map) {
        final row = Map<String, Object?>.from(entry);
        final day = _readNonBlankString(row['day']);
        final businessDate = _readNonBlankString(row['business_date']);
        if (day == null || businessDate == null) continue;
        dayRows.add(
          ScheduleSnapshotDay(
            day: day,
            businessDate: businessDate,
            forecastCovers: _readInt(row['forecast_covers']) ?? 0,
            forecastSales: _readDouble(row['forecast_sales']) ?? 0,
            requiredFohHours: _readInt(row['required_foh_hours']) ?? 0,
            requiredBohHours: _readInt(row['required_boh_hours']) ?? 0,
          ),
        );
      }
    }
  }
  return ScheduleSnapshot(
    snapshotId: snapshotId,
    operatorId: operatorId,
    locationId: locationId,
    restaurantId: restaurantId,
    weekStartDate: weekStart,
    weekEndDate: weekEnd,
    forecastCovers: _readInt(json['forecast_covers']) ?? 0,
    forecastSales: _readDouble(json['forecast_sales']) ?? 0,
    requiredFohHours: _readInt(json['required_foh_hours']) ?? 0,
    requiredBohHours: _readInt(json['required_boh_hours']) ?? 0,
    theoreticalFohLaborDollars:
        _readDouble(json['theoretical_foh_labor_dollars']) ?? 0,
    theoreticalBohLaborDollars:
        _readDouble(json['theoretical_boh_labor_dollars']) ?? 0,
    coversSource: _readNonBlankString(json['covers_source']) ?? 'unavailable',
    salesSource: _readNonBlankString(json['sales_source']) ?? 'unavailable',
    lockedAt: lockedAt,
    dayRows: List<ScheduleSnapshotDay>.unmodifiable(dayRows),
    forecastContext:
        contextJson == null ? null : _forecastContextFromJson(contextJson),
  );
}

ScheduleForecastContext _forecastContextFromJson(Map<String, Object?> json) {
  final id = _readNonBlankString(json['forecast_context_id']) ?? '';
  return ScheduleForecastContext(
    forecastContextId: id,
    weekStartDate: _readNonBlankString(json['week_start_date']) ?? '',
    weekEndDate: _readNonBlankString(json['week_end_date']) ?? '',
    coversSource: _readNonBlankString(json['covers_source']) ?? 'unavailable',
    builtAt: _readDate(json['built_at']) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    targetPpa: _readDouble(json['target_ppa']) ?? 0,
    forecastSales: _readDouble(json['forecast_sales']) ?? 0,
    requiredFohHours: _readInt(json['required_foh_hours']) ?? 0,
    requiredBohHours: _readInt(json['required_boh_hours']) ?? 0,
    theoreticalLaborDollars: _readDouble(json['theoretical_labor_dollars']) ?? 0,
    baselineWeeksRepresented: _readDouble(json['baseline_weeks_represented']) ?? 0,
    anchorBusinessDate: _readNonBlankString(json['anchor_business_date']),
    baselineTotalCovers: _readInt(json['baseline_total_covers']),
    baselineWeeklyAvgCovers: _readInt(json['baseline_weekly_avg_covers']),
    recentThreeWeekTotalCovers: _readInt(json['recent_three_week_total_covers']),
    recentThreeWeekWeeklyAvgCovers:
        _readInt(json['recent_three_week_weekly_avg_covers']),
    recentTrendDeltaCovers: _readInt(json['recent_trend_delta_covers']),
    resolvedWeeklyForecastCovers:
        _readInt(json['resolved_weekly_forecast_covers']),
  );
}

String? _readNonBlankString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _readDate(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.tryParse(value)?.toUtc();
  }
  return null;
}

int? _readInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _readDouble(Object? value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
