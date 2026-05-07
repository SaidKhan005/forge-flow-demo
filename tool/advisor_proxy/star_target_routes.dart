// Phase 8 star/target truth - selected-star proxy routes.
//
// Routes:
//   GET  /v1/operators/:operator_id/locations/:location_id/selected_star_shift_decisions
//   GET  /v1/operators/:operator_id/locations/:location_id/target_cycles
//   GET  /v1/operators/:operator_id/locations/:location_id/active_target_profiles
//   GET  /v1/operators/:operator_id/locations/:location_id/target_profile_versions
//   POST /v1/operators/:operator_id/locations/:location_id/selected_star_shift_decisions/select
//   POST /v1/operators/:operator_id/locations/:location_id/selected_star_shift_decisions/clear
//   POST /v1/operators/:operator_id/locations/:location_id/target_cycles/project_manager_override
//
// The route layer owns HTTP validation, request hashing, and idempotency
// replay. The repository owns the selected-star decision row and audit row.

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/selected_star_shift_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart';
import 'package:forge_and_flow/services/server_target_cycle_projection_service.dart';

import 'operator_routes.dart'
    show
        OperatorWriteIdempotencyCache,
        OperatorWriteRejected,
        hashOperatorRequestBody;

const String selectedStarShiftDecisionsResource =
    'selected_star_shift_decisions';
const String targetCyclesResource = 'target_cycles';
const String activeTargetProfilesResource = 'active_target_profiles';
const String targetProfileVersionsResource = 'target_profile_versions';

const String selectedStarShiftDecisionsPathPrefix = '/v1/operators/';

const String selectedStarWritePermissionKey = 'forgeflow.baseline.override';

class SelectedStarTargetRouter {
  SelectedStarTargetRouter({
    required SelectedStarTargetGateway gateway,
    OperatorWriteIdempotencyCache? idempotencyCache,
  }) : _gateway = gateway,
       _idempotencyCache = idempotencyCache ?? OperatorWriteIdempotencyCache();

  static SelectedStarTargetRouter? _global;

  static SelectedStarTargetRouter? get global => _global;

  static void installGlobal(SelectedStarTargetRouter router) {
    _global = router;
  }

  static void resetGlobalForTesting() {
    _global = null;
  }

  static SelectedStarTargetRouteMatch? match(String path, String method) {
    if (!path.startsWith(selectedStarShiftDecisionsPathPrefix)) return null;
    final tail = path.substring(selectedStarShiftDecisionsPathPrefix.length);
    final parts = tail.split('/');
    if (parts.length < 4 || parts[1] != 'locations') return null;
    final operatorId = Uri.decodeComponent(parts[0]);
    final locationId = Uri.decodeComponent(parts[2]);
    final resource = parts.sublist(3).join('/');
    if (method == 'GET') {
      final routeResource = switch (resource) {
        selectedStarShiftDecisionsResource =>
          SelectedStarTargetRouteResource.selectedStarShiftDecisions,
        targetCyclesResource => SelectedStarTargetRouteResource.targetCycles,
        activeTargetProfilesResource =>
          SelectedStarTargetRouteResource.activeTargetProfiles,
        targetProfileVersionsResource =>
          SelectedStarTargetRouteResource.targetProfileVersions,
        _ => null,
      };
      if (routeResource != null) {
        return SelectedStarTargetRouteMatch(
          operatorId: operatorId,
          locationId: locationId,
          action: SelectedStarTargetRouteAction.read,
          resource: routeResource,
        );
      }
    }
    if (method == 'POST' &&
        resource == '$selectedStarShiftDecisionsResource/select') {
      return SelectedStarTargetRouteMatch(
        operatorId: operatorId,
        locationId: locationId,
        action: SelectedStarTargetRouteAction.select,
        resource: SelectedStarTargetRouteResource.selectedStarShiftDecisions,
      );
    }
    if (method == 'POST' &&
        resource == '$selectedStarShiftDecisionsResource/clear') {
      return SelectedStarTargetRouteMatch(
        operatorId: operatorId,
        locationId: locationId,
        action: SelectedStarTargetRouteAction.clear,
        resource: SelectedStarTargetRouteResource.selectedStarShiftDecisions,
      );
    }
    if (method == 'POST' &&
        resource == '$targetCyclesResource/project_manager_override') {
      return SelectedStarTargetRouteMatch(
        operatorId: operatorId,
        locationId: locationId,
        action: SelectedStarTargetRouteAction.projectManagerOverride,
        resource: SelectedStarTargetRouteResource.targetCycles,
      );
    }
    return null;
  }

  final SelectedStarTargetGateway _gateway;
  final OperatorWriteIdempotencyCache _idempotencyCache;

  Future<SelectedStarTargetRouteResult> handle({
    required SelectedStarTargetRouteMatch match,
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
        case SelectedStarTargetRouteAction.read:
          return _handleRead(
            match: match,
            queryParameters: queryParameters,
            actorUserId: actorUserId,
          );
        case SelectedStarTargetRouteAction.select:
        case SelectedStarTargetRouteAction.clear:
        case SelectedStarTargetRouteAction.projectManagerOverride:
          return _handleWrite(
            match: match,
            method: method,
            path: path,
            actorUserId: actorUserId,
            actorKind: actorKind,
            idempotencyKey: idempotencyKey,
            body: body,
          );
      }
    } on SelectedStarRouteRejected catch (rejected) {
      return SelectedStarTargetRouteResult(
        statusCode: rejected.statusCode,
        body: <String, Object?>{
          'error': rejected.code,
          'message': rejected.message,
        },
      );
    }
  }

  Future<SelectedStarTargetRouteResult> _handleWrite({
    required SelectedStarTargetRouteMatch match,
    required String method,
    required String path,
    required String actorUserId,
    required String actorKind,
    required String? idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    final key = idempotencyKey?.trim();
    if (key == null || key.isEmpty) {
      return const SelectedStarTargetRouteResult(
        statusCode: 400,
        body: <String, Object?>{
          'error': 'idempotency_key_missing',
          'message': 'Idempotency-Key header is required',
        },
      );
    }
    if (key.length > 200) {
      return const SelectedStarTargetRouteResult(
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
          if (match.action ==
              SelectedStarTargetRouteAction.projectManagerOverride) {
            final command = _projectionCommandFromBody(
              match: match,
              actorUserId: actorUserId,
              actorKind: actorKind,
              idempotencyKey: key,
              requestHash: requestHash,
              body: body,
            );
            final projection = await _gateway
                .projectManagerOverrideFromCurrentServerSelections(
                  command: command,
                );
            return (
              statusCode: 200,
              body: <String, Object?>{
                'target_cycle': projection.cycle.toJson(),
                'active_target_profile': projection.activeProfile.toJson(),
                'selected_star_summary': <String, Object?>{
                  'selected_shift_count':
                      projection.selectedStarSummary.selectedShiftCount,
                  'selected_record_keys':
                      projection.selectedStarSummary.recordKeys,
                  'selection_decision_ids':
                      projection.selectedStarSummary.decisionIds,
                },
              },
            );
          }
          final decision = _decisionWriteFromBody(
            match: match,
            actorUserId: actorUserId,
            actorKind: actorKind,
            idempotencyKey: key,
            requestHash: requestHash,
            body: body,
          );
          final row = await _gateway.recordDecision(
            decision: decision,
            actorKind: _repositoryActorKind(actorKind),
          );
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
            body: <String, Object?>{'decision': row.toJson()},
          );
        },
      );
      return SelectedStarTargetRouteResult(
        statusCode: result.statusCode,
        body: result.body,
      );
    } on SelectedStarRouteRejected catch (rejected) {
      return SelectedStarTargetRouteResult(
        statusCode: rejected.statusCode,
        body: <String, Object?>{
          'error': rejected.code,
          'message': rejected.message,
        },
      );
    } on OperatorWriteRejected catch (rejected) {
      return SelectedStarTargetRouteResult(
        statusCode: rejected.statusCode,
        body: <String, Object?>{
          'error': rejected.code,
          'message': rejected.message,
          ...rejected.extras,
        },
      );
    } on TargetCycleManagerOverrideAlreadyUsed catch (error) {
      return SelectedStarTargetRouteResult(
        statusCode: 409,
        body: <String, Object?>{
          'error': 'manager_override_already_used',
          'message':
              'Manager override has already been used for this target cycle',
          'active_cycle_id': error.activeCycleId,
          'restaurant_id': error.restaurantId,
        },
      );
    } on ArgumentError catch (error) {
      return SelectedStarTargetRouteResult(
        statusCode: 400,
        body: <String, Object?>{
          'error': 'invalid_selected_star_request',
          'message': error.message?.toString() ?? error.toString(),
        },
      );
    }
  }

  Future<SelectedStarTargetRouteResult> _handleRead({
    required SelectedStarTargetRouteMatch match,
    required Map<String, String> queryParameters,
    required String actorUserId,
  }) async {
    final limit = _limitFromQuery(queryParameters);
    final currentOnly = _boolQuery(queryParameters['current']);
    if (currentOnly) {
      if (match.resource !=
          SelectedStarTargetRouteResource.selectedStarShiftDecisions) {
        return const SelectedStarTargetRouteResult(
          statusCode: 400,
          body: <String, Object?>{
            'error': 'current_query_not_supported',
            'message': 'current=true is only supported for selected stars',
          },
        );
      }
      final restaurantId = _requiredQueryString(
        queryParameters,
        'restaurant_id',
      );
      final rows = await _gateway.listCurrentSelections(
        operatorId: match.operatorId,
        locationId: match.locationId,
        restaurantId: restaurantId,
        userId: actorUserId,
        limit: limit,
      );
      return _readResponse(
        match: match,
        rowsKey: selectedStarShiftDecisionsResource,
        rows: rows,
        limit: limit,
        rowUpdatedAt: (row) => row.updatedAt,
        rowToJson: (row) => row.toJson(),
      );
    }

    final rawCursor =
        _trimmed(queryParameters['modified_since']) ??
        _trimmed(queryParameters['updated_since']) ??
        _trimmed(queryParameters['cursor']);
    final updatedAfter = rawCursor == null
        ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
        : DateTime.tryParse(rawCursor)?.toUtc();
    if (updatedAfter == null) {
      return const SelectedStarTargetRouteResult(
        statusCode: 400,
        body: <String, Object?>{
          'error': 'invalid_modified_since',
          'message': 'modified_since must be an ISO-8601 timestamp',
        },
      );
    }
    switch (match.resource) {
      case SelectedStarTargetRouteResource.selectedStarShiftDecisions:
        final rows = await _gateway.listUpdatedSince(
          operatorId: match.operatorId,
          locationId: match.locationId,
          updatedAfter: updatedAfter,
          userId: actorUserId,
          limit: limit,
        );
        return _readResponse<SelectedStarShiftDecisionRow>(
          match: match,
          rowsKey: selectedStarShiftDecisionsResource,
          rows: rows,
          limit: limit,
          rowUpdatedAt: (row) => row.updatedAt,
          rowToJson: (row) => row.toJson(),
        );
      case SelectedStarTargetRouteResource.targetCycles:
        final rows = await _gateway.listTargetCyclesUpdatedSince(
          operatorId: match.operatorId,
          locationId: match.locationId,
          updatedAfter: updatedAfter,
          userId: actorUserId,
          limit: limit,
        );
        return _readResponse<TargetCyclePostgresRow>(
          match: match,
          rowsKey: targetCyclesResource,
          rows: rows,
          limit: limit,
          rowUpdatedAt: (row) => row.updatedAt,
          rowToJson: (row) => row.toJson(),
        );
      case SelectedStarTargetRouteResource.activeTargetProfiles:
        final rows = await _gateway.listActiveTargetProfilesUpdatedSince(
          operatorId: match.operatorId,
          locationId: match.locationId,
          updatedAfter: updatedAfter,
          userId: actorUserId,
          limit: limit,
        );
        return _readResponse<ActiveTargetProfilePostgresRow>(
          match: match,
          rowsKey: activeTargetProfilesResource,
          rows: rows,
          limit: limit,
          rowUpdatedAt: (row) => row.updatedAt,
          rowToJson: (row) => row.toJson(),
        );
      case SelectedStarTargetRouteResource.targetProfileVersions:
        final rows = await _gateway.listTargetProfileVersionsUpdatedSince(
          operatorId: match.operatorId,
          locationId: match.locationId,
          updatedAfter: updatedAfter,
          userId: actorUserId,
          limit: limit,
        );
        return _readResponse<TargetProfileVersionPostgresRow>(
          match: match,
          rowsKey: targetProfileVersionsResource,
          rows: rows,
          limit: limit,
          rowUpdatedAt: (row) => row.updatedAt,
          rowToJson: (row) => row.toJson(),
        );
    }
  }

  SelectedStarTargetRouteResult _readResponse<T>({
    required SelectedStarTargetRouteMatch match,
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
      return SelectedStarTargetRouteResult(
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
    return SelectedStarTargetRouteResult(
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

enum SelectedStarTargetRouteAction {
  read,
  select,
  clear,
  projectManagerOverride,
}

enum SelectedStarTargetRouteResource {
  selectedStarShiftDecisions,
  targetCycles,
  activeTargetProfiles,
  targetProfileVersions,
}

class SelectedStarTargetRouteMatch {
  const SelectedStarTargetRouteMatch({
    required this.operatorId,
    required this.locationId,
    required this.action,
    required this.resource,
  });

  final String operatorId;
  final String locationId;
  final SelectedStarTargetRouteAction action;
  final SelectedStarTargetRouteResource resource;
}

class SelectedStarTargetRouteResult {
  const SelectedStarTargetRouteResult({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

abstract class SelectedStarTargetGateway {
  Future<SelectedStarShiftDecisionRow> recordDecision({
    required SelectedStarShiftDecisionWrite decision,
    required String actorKind,
  });

  Future<ServerTargetCycleProjectionResult>
  projectManagerOverrideFromCurrentServerSelections({
    required ServerTargetCycleProjectionCommand command,
  });

  Future<List<SelectedStarShiftDecisionRow>> listUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit,
  });

  Future<List<SelectedStarShiftDecisionRow>> listCurrentSelections({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? userId,
    int limit,
  });

  Future<List<TargetCyclePostgresRow>> listTargetCyclesUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit,
  });

  Future<List<ActiveTargetProfilePostgresRow>>
  listActiveTargetProfilesUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit,
  });

  Future<List<TargetProfileVersionPostgresRow>>
  listTargetProfileVersionsUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit,
  });
}

class RepositorySelectedStarTargetGateway implements SelectedStarTargetGateway {
  RepositorySelectedStarTargetGateway({
    required this.repository,
    this.targetCycleRepository,
    this.activeTargetProfileRepository,
  });

  final SelectedStarShiftRepository repository;
  final TargetCycleRepository? targetCycleRepository;
  final ActiveTargetProfileRepository? activeTargetProfileRepository;

  @override
  Future<SelectedStarShiftDecisionRow> recordDecision({
    required SelectedStarShiftDecisionWrite decision,
    required String actorKind,
  }) {
    return repository.recordDecision(decision: decision, actorKind: actorKind);
  }

  @override
  Future<ServerTargetCycleProjectionResult>
  projectManagerOverrideFromCurrentServerSelections({
    required ServerTargetCycleProjectionCommand command,
  }) {
    final targetCycles = targetCycleRepository;
    final activeProfiles = activeTargetProfileRepository;
    if (targetCycles == null || activeProfiles == null) {
      throw StateError(
        'Target-cycle projection repositories are not configured',
      );
    }
    return ServerTargetCycleProjectionService.postgres(
      selectedStars: repository,
      targetCycles: targetCycles,
      activeProfiles: activeProfiles,
    ).projectManagerOverrideFromCurrentServerSelections(command: command);
  }

  @override
  Future<List<SelectedStarShiftDecisionRow>> listUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) {
    return repository.listUpdatedSince(
      operatorId: operatorId,
      locationId: locationId,
      updatedAfter: updatedAfter,
      userId: userId,
      limit: limit,
    );
  }

  @override
  Future<List<SelectedStarShiftDecisionRow>> listCurrentSelections({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? userId,
    int limit = 250,
  }) {
    return repository.listCurrentSelections(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      userId: userId,
      limit: limit,
    );
  }

  @override
  Future<List<TargetCyclePostgresRow>> listTargetCyclesUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) {
    final repo = targetCycleRepository;
    if (repo == null) {
      throw StateError('TargetCycleRepository is not configured');
    }
    return repo.listUpdatedSince(
      operatorId: operatorId,
      locationId: locationId,
      updatedAfter: updatedAfter,
      userId: userId,
      limit: limit,
    );
  }

  @override
  Future<List<ActiveTargetProfilePostgresRow>>
  listActiveTargetProfilesUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) {
    final repo = activeTargetProfileRepository;
    if (repo == null) {
      throw StateError('ActiveTargetProfileRepository is not configured');
    }
    return repo.listUpdatedSince(
      operatorId: operatorId,
      locationId: locationId,
      updatedAfter: updatedAfter,
      userId: userId,
      limit: limit,
    );
  }

  @override
  Future<List<TargetProfileVersionPostgresRow>>
  listTargetProfileVersionsUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) {
    final repo = activeTargetProfileRepository;
    if (repo == null) {
      throw StateError('ActiveTargetProfileRepository is not configured');
    }
    return repo.listVersionsUpdatedSince(
      operatorId: operatorId,
      locationId: locationId,
      updatedAfter: updatedAfter,
      userId: userId,
      limit: limit,
    );
  }
}

class SelectedStarRouteRejected implements Exception {
  const SelectedStarRouteRejected({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  final String code;
  final String message;
  final int statusCode;
}

SelectedStarShiftDecisionWrite _decisionWriteFromBody({
  required SelectedStarTargetRouteMatch match,
  required String actorUserId,
  required String actorKind,
  required String idempotencyKey,
  required String requestHash,
  required Map<String, Object?> body,
}) {
  if (body.containsKey('decision_type')) {
    throw const SelectedStarRouteRejected(
      code: 'decision_type_not_client_settable',
      message: 'decision_type is derived from the route action',
      statusCode: 400,
    );
  }
  final source = _optionalString(body, 'decision_source') ?? 'manager';
  if (source != 'manager' && source != 'admin') {
    throw const SelectedStarRouteRejected(
      code: 'invalid_decision_source',
      message: 'decision_source must be manager or admin',
      statusCode: 400,
    );
  }
  if (source == 'admin' && _repositoryActorKind(actorKind) != 'forge_admin') {
    throw const SelectedStarRouteRejected(
      code: 'admin_decision_source_forbidden',
      message: 'admin selected-star decisions require a forge admin actor',
      statusCode: 403,
    );
  }
  final isClear = match.action == SelectedStarTargetRouteAction.clear;
  final decisionType = source == 'admin'
      ? isClear
            ? 'admin_cleared'
            : 'admin_selected'
      : isClear
      ? 'manager_cleared'
      : 'manager_selected';

  return SelectedStarShiftDecisionWrite(
    operatorId: match.operatorId,
    locationId: match.locationId,
    restaurantId: _requiredString(body, 'restaurant_id'),
    recordKey: _requiredString(body, 'record_key'),
    weekId: _requiredString(body, 'week_id'),
    dayLabel: _requiredString(body, 'day_label'),
    daypart: _requiredString(body, 'daypart'),
    businessDate: _requiredDateString(body, 'business_date'),
    servicePeriodKey: _optionalString(body, 'service_period_key'),
    targetCycleId: _optionalString(body, 'target_cycle_id'),
    decisionType: decisionType,
    decisionSource: source,
    actorUserId: actorUserId,
    decidedAt: _optionalDateTime(body, 'decided_at'),
    sourceSystem: _optionalString(body, 'source_system'),
    sourceShiftId: _optionalString(body, 'source_shift_id'),
    sourceShiftRecordId: _optionalString(body, 'source_shift_record_id'),
    covers: _optionalInt(body, 'covers'),
    cplh: _optionalDouble(body, 'cplh'),
    splh: _optionalDouble(body, 'splh'),
    ppa: _optionalDouble(body, 'ppa'),
    primaryLeverId: _optionalString(body, 'primary_lever_id'),
    actualLaborPct: _optionalDouble(body, 'actual_labor_pct'),
    hasActualLaborPctTruth:
        _optionalBool(body, 'has_actual_labor_pct_truth') ?? false,
    recommendationReferenceId: _optionalString(
      body,
      'recommendation_reference_id',
    ),
    candidateSnapshot:
        _optionalObject(body, 'candidate_snapshot') ??
        const <String, Object?>{},
    reason: _optionalString(body, 'reason'),
    idempotencyKey: idempotencyKey,
    requestHash: requestHash,
    metadata: _optionalObject(body, 'metadata') ?? const <String, Object?>{},
  );
}

ServerTargetCycleProjectionCommand _projectionCommandFromBody({
  required SelectedStarTargetRouteMatch match,
  required String actorUserId,
  required String actorKind,
  required String idempotencyKey,
  required String requestHash,
  required Map<String, Object?> body,
}) {
  final standards =
      _optionalObject(body, 'standards') ?? const <String, Object?>{};
  return ServerTargetCycleProjectionCommand(
    operatorId: match.operatorId,
    locationId: match.locationId,
    restaurantId: _requiredString(body, 'restaurant_id'),
    cycleId: _optionalString(body, 'cycle_id'),
    effectiveStart: _requiredDateString(body, 'effective_start'),
    effectiveEnd: _requiredDateString(body, 'effective_end'),
    calibrationWindowStart: _requiredDateString(
      body,
      'calibration_window_start',
    ),
    calibrationWindowEnd: _requiredDateString(body, 'calibration_window_end'),
    standards: ServerTargetStandards(
      targetCplh: _requiredDouble(standards, body, 'target_cplh'),
      targetSplh: _requiredDouble(standards, body, 'target_splh'),
      targetPpa: _requiredDouble(standards, body, 'target_ppa'),
      fohWage: _requiredDouble(standards, body, 'foh_wage'),
      bohWage: _requiredDouble(standards, body, 'boh_wage'),
      opzFloorCplh: _requiredDouble(standards, body, 'opz_floor_cplh'),
      opzCeilingCplh: _requiredDouble(standards, body, 'opz_ceiling_cplh'),
    ),
    actorUserId: actorUserId,
    managerOverrideAt: _optionalDateTime(body, 'manager_override_at'),
    managerOverrideByUserId: _optionalString(
      body,
      'manager_override_by_user_id',
    ),
    adminReplacedAt: _optionalDateTime(body, 'admin_replaced_at'),
    adminReplacedByUserId: _optionalString(body, 'admin_replaced_by_user_id'),
    supersedesCycleId: _optionalString(body, 'supersedes_cycle_id'),
    reason: _optionalString(body, 'reason') ?? 'manager selected star override',
    idempotencyKey: idempotencyKey,
    requestHash: requestHash,
    actorKind: _repositoryActorKind(actorKind),
  );
}

int _limitFromQuery(Map<String, String> queryParameters) {
  final raw =
      _trimmed(queryParameters['page_size']) ??
      _trimmed(queryParameters['limit']);
  if (raw == null) return 200;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0 || parsed > 500) {
    throw const SelectedStarRouteRejected(
      code: 'invalid_page_size',
      message: 'page_size must be a positive integer no greater than 500',
      statusCode: 400,
    );
  }
  return parsed;
}

String _requiredQueryString(Map<String, String> values, String key) {
  final value = _trimmed(values[key]);
  if (value == null) {
    throw SelectedStarRouteRejected(
      code: 'missing_$key',
      message: '$key is required',
      statusCode: 400,
    );
  }
  return value;
}

String _requiredString(Map<String, Object?> body, String key) {
  final value = _optionalString(body, key);
  if (value == null) {
    throw SelectedStarRouteRejected(
      code: 'missing_$key',
      message: '$key is required',
      statusCode: 400,
    );
  }
  return value;
}

String _requiredDateString(Map<String, Object?> body, String key) {
  final value = _requiredString(body, key);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
      DateTime.tryParse('${value}T00:00:00Z') == null) {
    throw SelectedStarRouteRejected(
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

DateTime? _optionalDateTime(Map<String, Object?> body, String key) {
  final value = _optionalString(body, key);
  if (value == null) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw SelectedStarRouteRejected(
      code: 'invalid_$key',
      message: '$key must be an ISO-8601 timestamp',
      statusCode: 400,
    );
  }
  return parsed.toUtc();
}

int? _optionalInt(Map<String, Object?> body, String key) {
  final value = body[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value.roundToDouble() == value.toDouble()) {
    return value.toInt();
  }
  throw SelectedStarRouteRejected(
    code: 'invalid_$key',
    message: '$key must be an integer',
    statusCode: 400,
  );
}

double? _optionalDouble(Map<String, Object?> body, String key) {
  final value = body[key];
  if (value == null) return null;
  if (value is num) return value.toDouble();
  throw SelectedStarRouteRejected(
    code: 'invalid_$key',
    message: '$key must be a number',
    statusCode: 400,
  );
}

double _requiredDouble(
  Map<String, Object?> primary,
  Map<String, Object?> fallback,
  String key,
) {
  final value = _optionalDouble(primary, key) ?? _optionalDouble(fallback, key);
  if (value == null) {
    throw SelectedStarRouteRejected(
      code: 'missing_$key',
      message: '$key is required',
      statusCode: 400,
    );
  }
  return value;
}

bool? _optionalBool(Map<String, Object?> body, String key) {
  final value = body[key];
  if (value == null) return null;
  if (value is bool) return value;
  throw SelectedStarRouteRejected(
    code: 'invalid_$key',
    message: '$key must be a boolean',
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
  throw SelectedStarRouteRejected(
    code: 'invalid_$key',
    message: '$key must be an object',
    statusCode: 400,
  );
}

bool _boolQuery(String? raw) {
  final value = raw?.trim().toLowerCase();
  return value == '1' || value == 'true' || value == 'yes';
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
