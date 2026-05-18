// Phase 8 weekly-plan server truth - proxy routes.
//
// Routes:
//   GET  /v1/operators/:operator_id/locations/:location_id/weekly_plan_snapshots
//   GET  /v1/operators/:operator_id/locations/:location_id/forecast_contexts
//   POST /v1/operators/:operator_id/locations/:location_id/weekly_plan_snapshots/lock
//
// The route layer owns HTTP validation, request hashing, and idempotency
// replay. Lane 0 owns repository/table binding; this file deliberately
// depends only on the abstract gateway seam.

import 'operator_routes.dart'
    show
        OperatorWriteIdempotencyCache,
        OperatorWriteRejected,
        hashOperatorRequestBody;

const String weeklyPlanSnapshotsResource = 'weekly_plan_snapshots';
const String forecastContextsResource = 'forecast_contexts';
const String weeklyPlanPathPrefix = '/v1/operators/';
const String weeklyPlanLockPermissionKey = 'forgeflow.weekly_plan.lock';

class WeeklyPlanRouter {
  WeeklyPlanRouter({
    required WeeklyPlanGateway gateway,
    OperatorWriteIdempotencyCache? idempotencyCache,
  }) : _gateway = gateway,
       _idempotencyCache = idempotencyCache ?? OperatorWriteIdempotencyCache();

  static WeeklyPlanRouter? _global;

  static WeeklyPlanRouter? get global => _global;

  static void installGlobal(WeeklyPlanRouter router) {
    _global = router;
  }

  static void resetGlobalForTesting() {
    _global = null;
  }

  static WeeklyPlanRouteMatch? match(String path, String method) {
    if (!path.startsWith(weeklyPlanPathPrefix)) return null;
    final tail = path.substring(weeklyPlanPathPrefix.length);
    final parts = tail.split('/');
    if (parts.length < 4 || parts[1] != 'locations') return null;
    final operatorId = Uri.decodeComponent(parts[0]);
    final locationId = Uri.decodeComponent(parts[2]);
    final resource = parts.sublist(3).join('/');
    if (method == 'GET') {
      final routeResource = switch (resource) {
        weeklyPlanSnapshotsResource => WeeklyPlanRouteResource.snapshots,
        forecastContextsResource => WeeklyPlanRouteResource.forecastContexts,
        _ => null,
      };
      if (routeResource != null) {
        return WeeklyPlanRouteMatch(
          operatorId: operatorId,
          locationId: locationId,
          action: WeeklyPlanRouteAction.read,
          resource: routeResource,
        );
      }
    }
    if (method == 'POST' && resource == '$weeklyPlanSnapshotsResource/lock') {
      return WeeklyPlanRouteMatch(
        operatorId: operatorId,
        locationId: locationId,
        action: WeeklyPlanRouteAction.lock,
        resource: WeeklyPlanRouteResource.snapshots,
      );
    }
    return null;
  }

  final WeeklyPlanGateway _gateway;
  final OperatorWriteIdempotencyCache _idempotencyCache;

  Future<WeeklyPlanRouteResult> handle({
    required WeeklyPlanRouteMatch match,
    required String method,
    required String path,
    required Map<String, String> queryParameters,
    required String actorUserId,
    required String actorKind,
    String? idempotencyKey,
    Map<String, Object?> body = const <String, Object?>{},
  }) async {
    try {
      switch (match.action) {
        case WeeklyPlanRouteAction.read:
          return await _handleRead(
            match: match,
            queryParameters: queryParameters,
            actorUserId: actorUserId,
          );
        case WeeklyPlanRouteAction.lock:
          return await _handleLock(
            match: match,
            method: method,
            path: path,
            actorUserId: actorUserId,
            actorKind: actorKind,
            idempotencyKey: idempotencyKey,
            body: body,
          );
      }
    } on WeeklyPlanRouteRejected catch (rejected) {
      return WeeklyPlanRouteResult(
        statusCode: rejected.statusCode,
        body: <String, Object?>{
          'error': rejected.code,
          'message': rejected.message,
        },
      );
    }
  }

  Future<WeeklyPlanRouteResult> _handleRead({
    required WeeklyPlanRouteMatch match,
    required Map<String, String> queryParameters,
    required String actorUserId,
  }) async {
    final limit = _limitFromQuery(queryParameters);
    final rawCursor =
        _trimmed(queryParameters['modified_since']) ??
        _trimmed(queryParameters['updated_since']) ??
        _trimmed(queryParameters['cursor']);
    final updatedAfter = rawCursor == null
        ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
        : DateTime.tryParse(rawCursor)?.toUtc();
    if (updatedAfter == null) {
      return const WeeklyPlanRouteResult(
        statusCode: 400,
        body: <String, Object?>{
          'error': 'invalid_modified_since',
          'message': 'modified_since must be an ISO-8601 timestamp',
        },
      );
    }

    switch (match.resource) {
      case WeeklyPlanRouteResource.snapshots:
        final rows = await _gateway.listWeeklyPlanSnapshotsUpdatedSince(
          operatorId: match.operatorId,
          locationId: match.locationId,
          updatedAfter: updatedAfter,
          userId: actorUserId,
          limit: limit,
        );
        return _readResponse<WeeklyPlanSnapshotRow>(
          match: match,
          rowsKey: weeklyPlanSnapshotsResource,
          rows: rows,
          limit: limit,
          rowUpdatedAt: (row) => row.updatedAt,
          rowToJson: (row) => row.toJson(),
        );
      case WeeklyPlanRouteResource.forecastContexts:
        final rows = await _gateway.listForecastContextsUpdatedSince(
          operatorId: match.operatorId,
          locationId: match.locationId,
          updatedAfter: updatedAfter,
          userId: actorUserId,
          limit: limit,
        );
        return _readResponse<ForecastContextRow>(
          match: match,
          rowsKey: forecastContextsResource,
          rows: rows,
          limit: limit,
          rowUpdatedAt: (row) => row.updatedAt,
          rowToJson: (row) => row.toJson(),
        );
    }
  }

  Future<WeeklyPlanRouteResult> _handleLock({
    required WeeklyPlanRouteMatch match,
    required String method,
    required String path,
    required String actorUserId,
    required String actorKind,
    required String? idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    final key = idempotencyKey?.trim();
    if (key == null || key.isEmpty) {
      return const WeeklyPlanRouteResult(
        statusCode: 400,
        body: <String, Object?>{
          'error': 'idempotency_key_missing',
          'message': 'Idempotency-Key header is required',
        },
      );
    }
    if (key.length > 200) {
      return const WeeklyPlanRouteResult(
        statusCode: 400,
        body: <String, Object?>{
          'error': 'idempotency_key_too_long',
          'message': 'Idempotency-Key header must be 200 characters or fewer',
        },
      );
    }
    final requestHash = hashOperatorRequestBody(<String, Object?>{
      'method': method,
      'path': path,
      'body': body,
    });
    try {
      final result = await _idempotencyCache.runOrReplay(
        operatorId: match.operatorId,
        route: '$method $path',
        idempotencyKey: key,
        requestBodyHash: requestHash,
        compute: () async {
          final request = _lockRequestFromBody(
            match: match,
            actorUserId: actorUserId,
            actorKind: actorKind,
            idempotencyKey: key,
            requestHash: requestHash,
            body: body,
          );
          final row = await _gateway.lockSnapshot(request: request);
          if (row.requestHash != requestHash) {
            return (
              statusCode: 409,
              body: const <String, Object?>{
                'error': 'idempotency_key_conflict',
                'message':
                    'Idempotency-Key was reused with a different request hash',
              },
            );
          }
          return (
            statusCode: 200,
            body: <String, Object?>{'snapshot': row.toJson()},
          );
        },
      );
      return WeeklyPlanRouteResult(
        statusCode: result.statusCode,
        body: result.body,
      );
    } on WeeklyPlanRouteRejected catch (rejected) {
      return WeeklyPlanRouteResult(
        statusCode: rejected.statusCode,
        body: <String, Object?>{
          'error': rejected.code,
          'message': rejected.message,
        },
      );
    } on OperatorWriteRejected catch (rejected) {
      return WeeklyPlanRouteResult(
        statusCode: rejected.statusCode,
        body: <String, Object?>{
          'error': rejected.code,
          'message': rejected.message,
          ...rejected.extras,
        },
      );
    } on ArgumentError catch (error) {
      return WeeklyPlanRouteResult(
        statusCode: 400,
        body: <String, Object?>{
          'error': 'invalid_weekly_plan_request',
          'message': error.message?.toString() ?? error.toString(),
        },
      );
    }
  }

  WeeklyPlanRouteResult _readResponse<T>({
    required WeeklyPlanRouteMatch match,
    required String rowsKey,
    required List<T> rows,
    required int limit,
    required DateTime Function(T row) rowUpdatedAt,
    required Map<String, Object?> Function(T row) rowToJson,
  }) {
    if (rows.isEmpty) {
      // Honest-unavailable shape so sync clients short-circuit on empty
      // server-side projections instead of treating zero rows as a synced
      // empty page. Sync clients recognize available:false / status:unavailable.
      return WeeklyPlanRouteResult(
        statusCode: 200,
        body: <String, Object?>{
          'operator_id': match.operatorId,
          'location_id': match.locationId,
          'available': false,
          'status': 'unavailable',
          'unavailable_reason': 'no_projected_rows',
          'reason': 'no_projected_rows',
          rowsKey: const <Map<String, Object?>>[],
          'next_cursor': null,
          'has_more': false,
        },
      );
    }
    String? nextCursor;
    for (final row in rows) {
      final value = rowUpdatedAt(row).toUtc().toIso8601String();
      if (nextCursor == null || value.compareTo(nextCursor) > 0) {
        nextCursor = value;
      }
    }
    return WeeklyPlanRouteResult(
      statusCode: 200,
      body: <String, Object?>{
        'operator_id': match.operatorId,
        'location_id': match.locationId,
        rowsKey: <Map<String, Object?>>[for (final row in rows) rowToJson(row)],
        'next_cursor': nextCursor,
        'has_more': rows.length == limit,
      },
    );
  }
}

enum WeeklyPlanRouteAction { read, lock }

enum WeeklyPlanRouteResource { snapshots, forecastContexts }

class WeeklyPlanRouteMatch {
  const WeeklyPlanRouteMatch({
    required this.operatorId,
    required this.locationId,
    required this.action,
    required this.resource,
  });

  final String operatorId;
  final String locationId;
  final WeeklyPlanRouteAction action;
  final WeeklyPlanRouteResource resource;
}

class WeeklyPlanRouteResult {
  const WeeklyPlanRouteResult({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, Object?> body;
}

abstract class WeeklyPlanGateway {
  Future<WeeklyPlanSnapshotRow> lockSnapshot({
    required WeeklyPlanLockRequest request,
  });

  Future<List<WeeklyPlanSnapshotRow>> listWeeklyPlanSnapshotsUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit,
  });

  Future<List<ForecastContextRow>> listForecastContextsUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit,
  });
}

class WeeklyPlanLockRequest {
  const WeeklyPlanLockRequest({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.weekStartDate,
    required this.weekEndDate,
    required this.targetCycleId,
    required this.forecastContextId,
    required this.embeddedForecastContext,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalFohLaborDollars,
    required this.theoreticalBohLaborDollars,
    required this.coversSource,
    required this.salesSource,
    required this.dayRows,
    this.dayDayparts = const <WeeklyPlanDayDaypartPayload>[],
    this.wageAtLockTimeJson,
    required this.reason,
    required this.actorUserId,
    required this.actorKind,
    required this.idempotencyKey,
    required this.requestHash,
    required this.metadata,
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String weekStartDate;
  final String weekEndDate;
  final String targetCycleId;
  final String? forecastContextId;
  final ForecastContextPayload? embeddedForecastContext;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  final double theoreticalFohLaborDollars;
  final double theoreticalBohLaborDollars;
  final String coversSource;
  final String salesSource;
  final List<WeeklyPlanDayPayload> dayRows;
  final List<WeeklyPlanDayDaypartPayload> dayDayparts;
  final Map<String, Object?>? wageAtLockTimeJson;
  final String reason;
  final String actorUserId;
  final String actorKind;
  final String idempotencyKey;
  final String requestHash;
  final Map<String, Object?> metadata;
}

class WeeklyPlanDayPayload {
  const WeeklyPlanDayPayload({
    required this.day,
    required this.businessDate,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
  });

  final String day;
  final String businessDate;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;

  Map<String, Object?> toJson() => <String, Object?>{
    'day': day,
    'business_date': businessDate,
    'forecast_covers': forecastCovers,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
  };
}

class WeeklyPlanDayDaypartPayload {
  const WeeklyPlanDayDaypartPayload({
    required this.businessDate,
    required this.servicePeriodId,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalFohDollars,
    required this.theoreticalBohDollars,
  });

  final String businessDate;
  final String servicePeriodId;
  final int forecastCovers;
  final double forecastSales;
  final double requiredFohHours;
  final double requiredBohHours;
  final double theoreticalFohDollars;
  final double theoreticalBohDollars;

  Map<String, Object?> toJson() => <String, Object?>{
    'business_date': businessDate,
    'service_period_id': servicePeriodId,
    'forecast_covers': forecastCovers,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
    'theoretical_foh_dollars': theoreticalFohDollars,
    'theoretical_boh_dollars': theoreticalBohDollars,
  };
}

class ForecastContextPayload {
  const ForecastContextPayload({
    required this.restaurantId,
    required this.anchorBusinessDate,
    required this.baselineTotalCovers,
    required this.baselineWeeklyAvgCovers,
    required this.baselineWeeksRepresented,
    required this.recentThreeWeekTotalCovers,
    required this.recentThreeWeekWeeklyAvgCovers,
    required this.recentTrendDeltaCovers,
    required this.resolvedWeeklyForecastCovers,
    required this.coversSource,
    required this.builtAt,
  });

  final String restaurantId;
  final String? anchorBusinessDate;
  final int baselineTotalCovers;
  final int baselineWeeklyAvgCovers;
  final double baselineWeeksRepresented;
  final int? recentThreeWeekTotalCovers;
  final int? recentThreeWeekWeeklyAvgCovers;
  final int? recentTrendDeltaCovers;
  final int resolvedWeeklyForecastCovers;
  final String coversSource;
  final DateTime builtAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'restaurant_id': restaurantId,
    'anchor_business_date': anchorBusinessDate,
    'baseline_total_covers': baselineTotalCovers,
    'baseline_weekly_avg_covers': baselineWeeklyAvgCovers,
    'baseline_weeks_represented': baselineWeeksRepresented,
    'recent_three_week_total_covers': recentThreeWeekTotalCovers,
    'recent_three_week_weekly_avg_covers': recentThreeWeekWeeklyAvgCovers,
    'recent_trend_delta_covers': recentTrendDeltaCovers,
    'resolved_weekly_forecast_covers': resolvedWeeklyForecastCovers,
    'covers_source': coversSource,
    'built_at': builtAt.toUtc().toIso8601String(),
  };
}

class WeeklyPlanSnapshotRow {
  const WeeklyPlanSnapshotRow({
    required this.snapshotId,
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.weekStartDate,
    required this.weekEndDate,
    required this.targetCycleId,
    required this.forecastContextId,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalFohLaborDollars,
    required this.theoreticalBohLaborDollars,
    required this.coversSource,
    required this.salesSource,
    required this.dayRows,
    this.dayDayparts = const <WeeklyPlanDayDaypartPayload>[],
    this.wageAtLockTimeJson,
    required this.lockedAt,
    required this.lockedByUserId,
    required this.lockReason,
    required this.isActive,
    required this.supersedesSnapshotId,
    required this.idempotencyKey,
    required this.requestHash,
    required this.metadata,
    required this.createdAt,
    required this.updatedAt,
    required this.supersededAt,
  });

  final String snapshotId;
  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String weekStartDate;
  final String weekEndDate;
  final String targetCycleId;
  final String? forecastContextId;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  final double theoreticalFohLaborDollars;
  final double theoreticalBohLaborDollars;
  final String coversSource;
  final String salesSource;
  final List<WeeklyPlanDayPayload> dayRows;
  final List<WeeklyPlanDayDaypartPayload> dayDayparts;
  final Map<String, Object?>? wageAtLockTimeJson;
  final DateTime lockedAt;
  final String lockedByUserId;
  final String lockReason;
  final bool isActive;
  final String? supersedesSnapshotId;
  final String idempotencyKey;
  final String requestHash;
  final Map<String, Object?> metadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? supersededAt;

  String get weekKey => '${weekStartDate}_$weekEndDate';

  Map<String, Object?> toJson() => <String, Object?>{
    'snapshot_id': snapshotId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'week_key': weekKey,
    'week_start_date': weekStartDate,
    'week_end_date': weekEndDate,
    'target_cycle_id': targetCycleId,
    'forecast_context_id': forecastContextId,
    'forecast_covers': forecastCovers,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
    'theoretical_foh_labor_dollars': theoreticalFohLaborDollars,
    'theoretical_boh_labor_dollars': theoreticalBohLaborDollars,
    'covers_source': coversSource,
    'sales_source': salesSource,
    'day_rows': <Map<String, Object?>>[for (final row in dayRows) row.toJson()],
    'day_dayparts': <Map<String, Object?>>[
      for (final row in dayDayparts) row.toJson(),
    ],
    if (wageAtLockTimeJson != null)
      'wage_at_lock_time_json': wageAtLockTimeJson,
    'locked_at': lockedAt.toUtc().toIso8601String(),
    'locked_by_user_id': lockedByUserId,
    'lock_reason': lockReason,
    'is_active': isActive,
    'supersedes_snapshot_id': supersedesSnapshotId,
    'idempotency_key': idempotencyKey,
    'request_hash': requestHash,
    'metadata': metadata,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'superseded_at': supersededAt?.toUtc().toIso8601String(),
  };
}

class ForecastContextRow {
  const ForecastContextRow({
    required this.forecastContextId,
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.anchorBusinessDate,
    required this.weekStartDate,
    required this.weekEndDate,
    required this.baselineTotalCovers,
    required this.baselineWeeklyAvgCovers,
    required this.baselineWeeksRepresented,
    required this.recentThreeWeekTotalCovers,
    required this.recentThreeWeekWeeklyAvgCovers,
    required this.recentTrendDeltaCovers,
    required this.resolvedWeeklyForecastCovers,
    required this.targetPpa,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalLaborDollars,
    required this.coversSource,
    required this.builtAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String forecastContextId;
  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String? anchorBusinessDate;
  final String weekStartDate;
  final String weekEndDate;
  final int? baselineTotalCovers;
  final int? baselineWeeklyAvgCovers;
  final double baselineWeeksRepresented;
  final int? recentThreeWeekTotalCovers;
  final int? recentThreeWeekWeeklyAvgCovers;
  final int? recentTrendDeltaCovers;
  final int? resolvedWeeklyForecastCovers;
  final double targetPpa;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  final double theoreticalLaborDollars;
  final String coversSource;
  final DateTime builtAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'forecast_context_id': forecastContextId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'anchor_business_date': anchorBusinessDate,
    'week_start_date': weekStartDate,
    'week_end_date': weekEndDate,
    'baseline_total_covers': baselineTotalCovers,
    'baseline_weekly_avg_covers': baselineWeeklyAvgCovers,
    'baseline_weeks_represented': baselineWeeksRepresented,
    'recent_three_week_total_covers': recentThreeWeekTotalCovers,
    'recent_three_week_weekly_avg_covers': recentThreeWeekWeeklyAvgCovers,
    'recent_trend_delta_covers': recentTrendDeltaCovers,
    'resolved_weekly_forecast_covers': resolvedWeeklyForecastCovers,
    'target_ppa': targetPpa,
    'forecast_sales': forecastSales,
    'required_foh_hours': requiredFohHours,
    'required_boh_hours': requiredBohHours,
    'theoretical_labor_dollars': theoreticalLaborDollars,
    'covers_source': coversSource,
    'built_at': builtAt.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

class WeeklyPlanRouteRejected implements Exception {
  const WeeklyPlanRouteRejected({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  final String code;
  final String message;
  final int statusCode;
}

WeeklyPlanLockRequest _lockRequestFromBody({
  required WeeklyPlanRouteMatch match,
  required String actorUserId,
  required String actorKind,
  required String idempotencyKey,
  required String requestHash,
  required Map<String, Object?> body,
}) {
  const forbidden = <String>{
    'actor_user_id',
    'actor_kind',
    'locked_by_user_id',
    'locked_by_actor_kind',
    'lock_source',
    'decision_source',
  };
  for (final key in forbidden) {
    if (body.containsKey(key)) {
      throw WeeklyPlanRouteRejected(
        code: '${key}_not_client_settable',
        message: '$key is derived by the proxy',
        statusCode: 400,
      );
    }
  }

  final weekStartDate = _requiredDateString(body, 'week_start_date');
  final weekEndDate = _requiredDateString(body, 'week_end_date');
  if (!_dateFromYyyyMmDd(
    weekEndDate,
  ).isAfter(_dateFromYyyyMmDd(weekStartDate))) {
    throw const WeeklyPlanRouteRejected(
      code: 'invalid_week_date_range',
      message: 'week_end_date must be after week_start_date',
      statusCode: 400,
    );
  }

  final restaurantId = _requiredString(body, 'restaurant_id');
  final forecastContextId = _optionalString(body, 'forecast_context_id');
  final embeddedForecastContext = _forecastContextPayload(
    body['forecast_context'],
    restaurantId: restaurantId,
  );
  if (forecastContextId == null && embeddedForecastContext == null) {
    throw const WeeklyPlanRouteRejected(
      code: 'missing_forecast_context',
      message: 'forecast_context_id or forecast_context values are required',
      statusCode: 400,
    );
  }

  return WeeklyPlanLockRequest(
    operatorId: match.operatorId,
    locationId: match.locationId,
    restaurantId: restaurantId,
    weekStartDate: weekStartDate,
    weekEndDate: weekEndDate,
    targetCycleId: _requiredString(body, 'target_cycle_id'),
    forecastContextId: forecastContextId,
    embeddedForecastContext: embeddedForecastContext,
    forecastCovers: _requiredInt(body, 'forecast_covers'),
    forecastSales: _requiredDouble(body, 'forecast_sales'),
    requiredFohHours: _requiredInt(body, 'required_foh_hours'),
    requiredBohHours: _requiredInt(body, 'required_boh_hours'),
    theoreticalFohLaborDollars: _requiredDouble(
      body,
      'theoretical_foh_labor_dollars',
    ),
    theoreticalBohLaborDollars: _requiredDouble(
      body,
      'theoretical_boh_labor_dollars',
    ),
    coversSource: _requiredString(body, 'covers_source'),
    salesSource: _requiredString(body, 'sales_source'),
    dayRows: _requiredDayRows(body['day_rows']),
    reason: _requiredString(body, 'reason'),
    actorUserId: actorUserId,
    actorKind: _repositoryActorKind(actorKind),
    idempotencyKey: idempotencyKey,
    requestHash: requestHash,
    metadata: _optionalObject(body, 'metadata') ?? const <String, Object?>{},
  );
}

int _limitFromQuery(Map<String, String> queryParameters) {
  final raw =
      _trimmed(queryParameters['page_size']) ??
      _trimmed(queryParameters['limit']);
  if (raw == null) return 200;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0 || parsed > 500) {
    throw const WeeklyPlanRouteRejected(
      code: 'invalid_page_size',
      message: 'page_size must be a positive integer no greater than 500',
      statusCode: 400,
    );
  }
  return parsed;
}

String _requiredString(Map<String, Object?> body, String key) {
  final value = _optionalString(body, key);
  if (value == null) {
    throw WeeklyPlanRouteRejected(
      code: 'missing_$key',
      message: '$key is required',
      statusCode: 400,
    );
  }
  return value;
}

String _requiredDateString(Map<String, Object?> body, String key) {
  final value = _requiredString(body, key);
  if (!_isYyyyMmDdDate(value)) {
    throw WeeklyPlanRouteRejected(
      code: 'invalid_$key',
      message: '$key must be a YYYY-MM-DD date',
      statusCode: 400,
    );
  }
  return value;
}

String? _optionalString(Map<String, Object?> body, String key) {
  final value = body[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

DateTime _requiredDateTime(Map<String, Object?> body, String key) {
  final value = _requiredString(body, key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw WeeklyPlanRouteRejected(
      code: 'invalid_$key',
      message: '$key must be an ISO-8601 timestamp',
      statusCode: 400,
    );
  }
  return parsed.toUtc();
}

int _requiredInt(Map<String, Object?> body, String key) {
  final value = _optionalInt(body, key);
  if (value == null) {
    throw WeeklyPlanRouteRejected(
      code: 'missing_$key',
      message: '$key is required',
      statusCode: 400,
    );
  }
  return value;
}

int? _optionalInt(Map<String, Object?> body, String key) {
  final value = body[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value.roundToDouble() == value.toDouble()) {
    return value.toInt();
  }
  throw WeeklyPlanRouteRejected(
    code: 'invalid_$key',
    message: '$key must be an integer',
    statusCode: 400,
  );
}

double _requiredDouble(Map<String, Object?> body, String key) {
  final value = _optionalDouble(body, key);
  if (value == null) {
    throw WeeklyPlanRouteRejected(
      code: 'missing_$key',
      message: '$key is required',
      statusCode: 400,
    );
  }
  return value;
}

double? _optionalDouble(Map<String, Object?> body, String key) {
  final value = body[key];
  if (value == null) return null;
  if (value is num) return value.toDouble();
  throw WeeklyPlanRouteRejected(
    code: 'invalid_$key',
    message: '$key must be a number',
    statusCode: 400,
  );
}

Map<String, Object?>? _optionalObject(Map<String, Object?> body, String key) {
  final value = body[key];
  if (value == null) return null;
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  throw WeeklyPlanRouteRejected(
    code: 'invalid_$key',
    message: '$key must be an object',
    statusCode: 400,
  );
}

List<WeeklyPlanDayPayload> _requiredDayRows(Object? raw) {
  if (raw is! List || raw.isEmpty) {
    throw const WeeklyPlanRouteRejected(
      code: 'invalid_day_rows',
      message: 'day_rows must be a non-empty list',
      statusCode: 400,
    );
  }
  final rows = <WeeklyPlanDayPayload>[];
  for (final item in raw) {
    if (item is! Map) {
      throw const WeeklyPlanRouteRejected(
        code: 'invalid_day_rows',
        message: 'each day row must be an object',
        statusCode: 400,
      );
    }
    final row = <String, Object?>{
      for (final entry in item.entries) entry.key.toString(): entry.value,
    };
    rows.add(
      WeeklyPlanDayPayload(
        day: _requiredString(row, 'day'),
        businessDate: _requiredDateString(row, 'business_date'),
        forecastCovers: _requiredInt(row, 'forecast_covers'),
        forecastSales: _requiredDouble(row, 'forecast_sales'),
        requiredFohHours: _requiredInt(row, 'required_foh_hours'),
        requiredBohHours: _requiredInt(row, 'required_boh_hours'),
      ),
    );
  }
  return List<WeeklyPlanDayPayload>.unmodifiable(rows);
}

ForecastContextPayload? _forecastContextPayload(
  Object? raw, {
  required String restaurantId,
}) {
  if (raw == null) return null;
  if (raw is! Map) {
    throw const WeeklyPlanRouteRejected(
      code: 'invalid_forecast_context',
      message: 'forecast_context must be an object',
      statusCode: 400,
    );
  }
  final body = <String, Object?>{
    for (final entry in raw.entries) entry.key.toString(): entry.value,
  };
  final contextRestaurantId =
      _optionalString(body, 'restaurant_id') ?? restaurantId;
  if (contextRestaurantId != restaurantId) {
    throw const WeeklyPlanRouteRejected(
      code: 'forecast_context_restaurant_mismatch',
      message: 'forecast_context restaurant_id must match restaurant_id',
      statusCode: 400,
    );
  }
  final anchorBusinessDate = _optionalString(body, 'anchor_business_date');
  if (anchorBusinessDate != null && !_isYyyyMmDdDate(anchorBusinessDate)) {
    throw const WeeklyPlanRouteRejected(
      code: 'invalid_anchor_business_date',
      message: 'anchor_business_date must be a YYYY-MM-DD date',
      statusCode: 400,
    );
  }
  return ForecastContextPayload(
    restaurantId: contextRestaurantId,
    anchorBusinessDate: anchorBusinessDate,
    baselineTotalCovers: _requiredInt(body, 'baseline_total_covers'),
    baselineWeeklyAvgCovers: _requiredInt(body, 'baseline_weekly_avg_covers'),
    baselineWeeksRepresented: _requiredDouble(
      body,
      'baseline_weeks_represented',
    ),
    recentThreeWeekTotalCovers: _optionalInt(
      body,
      'recent_three_week_total_covers',
    ),
    recentThreeWeekWeeklyAvgCovers: _optionalInt(
      body,
      'recent_three_week_weekly_avg_covers',
    ),
    recentTrendDeltaCovers: _optionalInt(body, 'recent_trend_delta_covers'),
    resolvedWeeklyForecastCovers: _requiredInt(
      body,
      'resolved_weekly_forecast_covers',
    ),
    coversSource: _requiredString(body, 'covers_source'),
    builtAt: _requiredDateTime(body, 'built_at'),
  );
}

bool _isYyyyMmDdDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final date = _dateFromYyyyMmDdOrNull(value);
  return date != null &&
      date.year == int.parse(value.substring(0, 4)) &&
      date.month == int.parse(value.substring(5, 7)) &&
      date.day == int.parse(value.substring(8, 10));
}

DateTime _dateFromYyyyMmDd(String value) {
  final date = _dateFromYyyyMmDdOrNull(value);
  if (date == null) throw ArgumentError('invalid date $value');
  return date;
}

DateTime? _dateFromYyyyMmDdOrNull(String value) {
  final year = int.tryParse(value.substring(0, 4));
  final month = int.tryParse(value.substring(5, 7));
  final day = int.tryParse(value.substring(8, 10));
  if (year == null || month == null || day == null) return null;
  try {
    return DateTime.utc(year, month, day);
  } catch (_) {
    return null;
  }
}

String? _trimmed(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _repositoryActorKind(String actorKind) {
  switch (actorKind) {
    case 'service':
    case 'system':
      return 'system';
    case 'forge_admin':
      return 'forge_admin';
    default:
      return 'operator_user';
  }
}
