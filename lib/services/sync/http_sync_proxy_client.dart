import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models/open_shift_snapshot.dart';
import '../../domain/models/business_scope.dart';
import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/models/wage_role_row.dart';
import '../../models/shift_record.dart';
import '../integration/demo_mode_state.dart';
import '../integration/integration_adapter_common.dart';
import '../star_target_selection_write_service.dart';
import '../scope/business_scope_repository.dart';
import 'star_target_sync_resources.dart';
import 'sync_proxy_client.dart';
import 'weekly_plan_sync_resources.dart';

class HttpSyncProxyClient
    implements
        SyncProxyClient,
        BusinessScopeClient,
        StarTargetSyncProxyClient,
        WeeklyPlanSyncProxyClient,
        StarTargetSelectionWriteClient {
  HttpSyncProxyClient({
    required this.proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    Future<void> Function()? refreshIdToken,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 20),
  }) : _idTokenProvider = idTokenProvider,
       _refreshIdToken = refreshIdToken,
       _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;

  /// Optional force-refresh hook for the Firebase ID token. When the
  /// proxy returns 401 (clock-skewed device, mid-sweep token rotation)
  /// the client invokes this once and retries the same request before
  /// surfacing the failure. Production wires this to
  /// `FirebaseAuthClient.refreshIdToken`. Demo/test bindings can leave
  /// it null — the client then throws on the first 401, matching the
  /// pre-fix behavior.
  final Future<void> Function()? _refreshIdToken;
  final http.Client _httpClient;
  final Duration _timeout;

  // Note: no leading slash. `_resolve` appends these segments to the
  // configured `proxyBaseUri` so any prefix path on the base URI (e.g.
  // `https://host/api/`) is preserved instead of being silently
  // replaced by `Uri.resolve('/v1/operators/...')`.
  static const List<String> _baseSegments = <String>['v1', 'operators'];
  static const List<String> _userBaseSegments = <String>['v1', 'users'];

  @override
  Future<List<BusinessScope>> fetchAccessibleBusinessScopes({
    required String userId,
  }) async {
    final body = await _getJson(<String>[
      userId,
      'business_scopes',
    ], baseSegments: _userBaseSegments);
    final rows = _readList(body, const <String>[
      'scopes',
      'business_scopes',
      'items',
      'data',
    ]);
    return rows
        .map((row) => BusinessScope.fromJson(_stringKeyMap(row)))
        .toList(growable: false);
  }

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    final body = await _getJson(
      _locationPath(operatorId, locationId, const <String>['shift_records']),
      queryParameters: _pageQuery(cursor: cursor, pageSize: pageSize),
    );
    final rows = _readList(body, const <String>[
      'records',
      'shift_records',
      'items',
      'data',
    ]);
    return ShiftRecordPage(
      records: rows
          .map((row) => ShiftRecord.fromMap(_stringKeyMap(row)))
          .toList(growable: false),
      nextCursor:
          _readString(body['next_cursor']) ?? _readString(body['nextCursor']),
    );
  }

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    final body = await _getJson(
      _locationPath(operatorId, locationId, const <String>[
        'open_shift_snapshots',
      ]),
      queryParameters: _pageQuery(cursor: cursor, pageSize: pageSize),
    );
    final rows = _readList(body, const <String>[
      'snapshots',
      'open_shift_snapshots',
      'items',
      'data',
    ]);
    return OpenShiftSnapshotPage(
      snapshots: rows
          .map((row) => OpenShiftSnapshot.fromMap(_stringKeyMap(row)))
          .toList(growable: false),
      nextCursor:
          _readString(body['next_cursor']) ?? _readString(body['nextCursor']),
    );
  }

  @override
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
  }) async {
    final body = await _getJson(
      _locationPath(operatorId, locationId, const <String>[
        'timing',
        'resolved',
      ]),
      queryParameters: <String, String>{'restaurant_id': restaurantId},
    );
    final raw =
        body['timing_config'] ?? body['resolved_timing_config'] ?? body['data'];
    if (raw == null) return null;
    final json = _stringKeyMap(raw);
    return _timingConfigFromJson(json, fallbackRestaurantId: restaurantId);
  }

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async {
    final body = await _getJson(
      _locationPath(operatorId, locationId, const <String>['demo_mode_states']),
    );
    final rows = _readList(body, const <String>[
      'demo_mode_states',
      'states',
      'records',
      'data',
    ]);
    return rows
        .map((row) => _demoModeRecordFromJson(_stringKeyMap(row)))
        .toList(growable: false);
  }

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) async {
    final body = await _getJson(
      _locationPath(operatorId, locationId, const <String>[
        'data_accuracy_settings',
      ]),
    );
    final raw =
        body['data_accuracy_settings'] ?? body['settings'] ?? body['data'];
    if (raw == null) return null;
    return _dataAccuracyFromJson(_stringKeyMap(raw));
  }

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
  fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) async {
    final body = await _getJson(
      _locationPath(operatorId, locationId, const <String>[
        'data_accuracy_service_period_settings',
      ]),
    );
    final rows = _readList(body, const <String>[
      'data_accuracy_service_period_settings',
      'service_period_settings',
      'settings',
      'items',
      'data',
    ]);
    return rows
        .map(
          (row) =>
              _dataAccuracyServicePeriodSettingFromJson(_stringKeyMap(row)),
        )
        .toList(growable: false);
  }

  @override
  Future<List<WageRoleRow>> fetchWageRoleRows({
    required String operatorId,
    required String locationId,
  }) async {
    final path = _locationPath(operatorId, locationId, const <String>[
      'wage_role_rows',
    ]);
    final rows = <WageRoleRow>[];
    String? cursor;
    while (true) {
      final body = await _getJson(
        path,
        queryParameters: _pageQuery(cursor: cursor, pageSize: 500),
      );
      final pageRows = _readList(body, const <String>[
        'wage_role_rows',
        'wage_roles',
        'rows',
        'items',
        'data',
      ]);
      rows.addAll(
        pageRows.map(
          (row) => _wageRoleRowFromJson(
            _stringKeyMap(row),
            fallbackRestaurantId: locationId,
          ),
        ),
      );
      final next =
          _readString(body['next_cursor']) ?? _readString(body['nextCursor']);
      if (next == null || next.isEmpty) break;
      cursor = next;
    }
    return rows;
  }

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async {
    final body = await _getJson(
      _locationPath(operatorId, locationId, const <String>[
        'polling_tier_assignment',
      ]),
    );
    final raw =
        body['polling_tier_assignment'] ?? body['assignment'] ?? body['data'];
    if (raw == null) return null;
    return _pollingTierFromJson(_stringKeyMap(raw));
  }

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) async {
    final Map<String, Object?> body;
    try {
      body = await _getJson(
        _locationPath(operatorId, locationId, const <String>[
          'first_backfill_status',
        ]),
      );
    } on SyncProxyClientException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
    final raw =
        body['first_backfill_status'] ??
        body['backfill_status'] ??
        body['status'] ??
        body['data'];
    if (raw == null) return null;
    if (raw is List) {
      if (raw.isEmpty) return null;
      return _firstBackfillStatusFromJson(_stringKeyMap(raw.first));
    }
    return _firstBackfillStatusFromJson(_stringKeyMap(raw));
  }

  @override
  Future<SelectedStarShiftDecisionPage> fetchSelectedStarShiftDecisions({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    final body = await _getStarTargetJsonOrUnavailable(
      _locationPath(operatorId, locationId, const <String>[
        'selected_star_shift_decisions',
      ]),
      queryParameters: _pageQuery(cursor: cursor, pageSize: pageSize),
    );
    final unavailableReason = starTargetUnavailableReason(body);
    if (unavailableReason != null) {
      return SelectedStarShiftDecisionPage.unavailable(unavailableReason);
    }
    final rows = _readList(body, const <String>[
      'decisions',
      'selected_star_shift_decisions',
      'baseline_selected_records',
      'records',
      'items',
      'data',
    ]);
    return SelectedStarShiftDecisionPage(
      decisions: rows
          .map(
            (row) =>
                SelectedStarShiftDecisionSyncRow.fromJson(_stringKeyMap(row)),
          )
          .toList(growable: false),
      nextCursor:
          _readString(body['next_cursor']) ?? _readString(body['nextCursor']),
    );
  }

  @override
  Future<void> submitSelectedStarDecision({
    required String operatorId,
    required String locationId,
    required StarTargetSelectionWriteAction action,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    try {
      await _postJson(
        _locationPath(operatorId, locationId, <String>[
          'selected_star_shift_decisions',
          action == StarTargetSelectionWriteAction.clear ? 'clear' : 'select',
        ]),
        body: body,
        idempotencyKey: idempotencyKey,
      );
    } on SyncProxyClientException catch (error) {
      throw StarTargetSelectionWriteException(
        code: error.code,
        message: error.message,
        statusCode: error.statusCode,
      );
    }
  }

  @override
  Future<void> submitSelectedStarTargetProjection({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    try {
      await _postJson(
        _locationPath(operatorId, locationId, const <String>[
          'target_cycles',
          'project_manager_override',
        ]),
        body: body,
        idempotencyKey: idempotencyKey,
      );
    } on SyncProxyClientException catch (error) {
      throw StarTargetSelectionWriteException(
        code: error.code,
        message: error.message,
        statusCode: error.statusCode,
      );
    }
  }

  @override
  Future<TargetCycleSyncPage> fetchTargetCycles({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    final body = await _getStarTargetJsonOrUnavailable(
      _locationPath(operatorId, locationId, const <String>['target_cycles']),
      queryParameters: _pageQuery(cursor: cursor, pageSize: pageSize),
    );
    final unavailableReason = starTargetUnavailableReason(body);
    if (unavailableReason != null) {
      return TargetCycleSyncPage.unavailable(unavailableReason);
    }
    final rows = _readList(body, const <String>[
      'target_cycles',
      'cycles',
      'records',
      'items',
      'data',
    ]);
    return TargetCycleSyncPage(
      cycles: rows
          .map((row) => TargetCycleSyncRow.fromJson(_stringKeyMap(row)))
          .toList(growable: false),
      nextCursor:
          _readString(body['next_cursor']) ?? _readString(body['nextCursor']),
    );
  }

  @override
  Future<ActiveTargetProfileSyncPage> fetchActiveTargetProfiles({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    final body = await _getStarTargetJsonOrUnavailable(
      _locationPath(operatorId, locationId, const <String>[
        'active_target_profiles',
      ]),
      queryParameters: _pageQuery(cursor: cursor, pageSize: pageSize),
    );
    final unavailableReason = starTargetUnavailableReason(body);
    if (unavailableReason != null) {
      return ActiveTargetProfileSyncPage.unavailable(unavailableReason);
    }
    final rows = _readList(body, const <String>[
      'active_target_profiles',
      'profiles',
      'records',
      'items',
      'data',
    ]);
    return ActiveTargetProfileSyncPage(
      profiles: rows
          .map((row) => ActiveTargetProfileSyncRow.fromJson(_stringKeyMap(row)))
          .toList(growable: false),
      nextCursor:
          _readString(body['next_cursor']) ?? _readString(body['nextCursor']),
    );
  }

  @override
  Future<TargetProfileVersionSyncPage> fetchTargetProfileVersions({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    final body = await _getStarTargetJsonOrUnavailable(
      _locationPath(operatorId, locationId, const <String>[
        'target_profile_versions',
      ]),
      queryParameters: _pageQuery(cursor: cursor, pageSize: pageSize),
    );
    final unavailableReason = starTargetUnavailableReason(body);
    if (unavailableReason != null) {
      return TargetProfileVersionSyncPage.unavailable(unavailableReason);
    }
    final rows = _readList(body, const <String>[
      'target_profile_versions',
      'versions',
      'records',
      'items',
      'data',
    ]);
    return TargetProfileVersionSyncPage(
      versions: rows
          .map(
            (row) => TargetProfileVersionSyncRow.fromJson(_stringKeyMap(row)),
          )
          .toList(growable: false),
      nextCursor:
          _readString(body['next_cursor']) ?? _readString(body['nextCursor']),
    );
  }

  @override
  Future<WeeklyPlanSnapshotSyncPage> fetchWeeklyPlanSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    final body = await _getWeeklyPlanJsonOrUnavailable(
      _locationPath(operatorId, locationId, const <String>[
        'weekly_plan_snapshots',
      ]),
      queryParameters: _pageQuery(cursor: cursor, pageSize: pageSize),
    );
    final unavailableReason = weeklyPlanUnavailableReason(body);
    if (unavailableReason != null) {
      return WeeklyPlanSnapshotSyncPage.unavailable(unavailableReason);
    }
    final rows = _readListOrSingleton(body, const <String>[
      'weekly_plan_snapshots',
      'snapshots',
      'weekly_plan_snapshot',
      'snapshot',
      'plans',
      'records',
      'items',
      'data',
    ]);
    return WeeklyPlanSnapshotSyncPage(
      snapshots: rows
          .map((row) => WeeklyPlanSnapshotSyncRow.fromJson(_stringKeyMap(row)))
          .toList(growable: false),
      nextCursor:
          _readString(body['next_cursor']) ?? _readString(body['nextCursor']),
    );
  }

  @override
  Future<ForecastContextSyncPage> fetchForecastContexts({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    final body = await _getWeeklyPlanJsonOrUnavailable(
      _locationPath(operatorId, locationId, const <String>[
        'forecast_contexts',
      ]),
      queryParameters: _pageQuery(cursor: cursor, pageSize: pageSize),
    );
    final unavailableReason = weeklyPlanUnavailableReason(body);
    if (unavailableReason != null) {
      return ForecastContextSyncPage.unavailable(unavailableReason);
    }
    final rows = _readListOrSingleton(body, const <String>[
      'forecast_contexts',
      'forecast_context',
      'current',
      'contexts',
      'context',
      'records',
      'items',
      'data',
    ]);
    return ForecastContextSyncPage(
      contexts: rows
          .map((row) => ForecastContextSyncRow.fromJson(_stringKeyMap(row)))
          .toList(growable: false),
      nextCursor:
          _readString(body['next_cursor']) ?? _readString(body['nextCursor']),
    );
  }

  Future<Map<String, Object?>> _getJson(
    List<String> tailSegments, {
    Map<String, String>? queryParameters,
    List<String> baseSegments = _baseSegments,
  }) async {
    final firstAttempt = await _attemptGet(
      tailSegments,
      queryParameters: queryParameters,
      baseSegments: baseSegments,
    );
    if (firstAttempt.statusCode != 401 || _refreshIdToken == null) {
      return _interpret(firstAttempt);
    }
    // BUG 4 (MEDIUM): force a single token refresh and retry once. A
    // clock-skewed device shipping a stale token surfaces as a 401 here;
    // the refresh hook re-pulls a fresh ID token. If the retry also
    // returns 401 we throw the original exception path — no infinite
    // retry loop.
    try {
      await _refreshIdToken();
    } catch (_) {
      return _interpret(firstAttempt);
    }
    final retry = await _attemptGet(
      tailSegments,
      queryParameters: queryParameters,
      baseSegments: baseSegments,
    );
    return _interpret(retry);
  }

  Future<Map<String, Object?>> _getStarTargetJsonOrUnavailable(
    List<String> tailSegments, {
    Map<String, String>? queryParameters,
  }) async {
    try {
      return await _getJson(tailSegments, queryParameters: queryParameters);
    } on SyncProxyClientException catch (error) {
      if (error.statusCode == 404) {
        return const <String, Object?>{
          'available': false,
          'unavailable_reason': 'star_target_proxy_route_not_found',
        };
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> _getWeeklyPlanJsonOrUnavailable(
    List<String> tailSegments, {
    Map<String, String>? queryParameters,
  }) async {
    try {
      return await _getJson(tailSegments, queryParameters: queryParameters);
    } on SyncProxyClientException catch (error) {
      if (error.statusCode == 404) {
        return const <String, Object?>{
          'available': false,
          'unavailable_reason': 'weekly_plan_proxy_route_not_found',
        };
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> _postJson(
    List<String> tailSegments, {
    required Map<String, Object?> body,
    required String idempotencyKey,
  }) async {
    final firstAttempt = await _attemptPost(
      tailSegments,
      body: body,
      idempotencyKey: idempotencyKey,
    );
    if (firstAttempt.statusCode != 401 || _refreshIdToken == null) {
      return _interpret(firstAttempt);
    }
    try {
      await _refreshIdToken();
    } catch (_) {
      return _interpret(firstAttempt);
    }
    final retry = await _attemptPost(
      tailSegments,
      body: body,
      idempotencyKey: idempotencyKey,
    );
    return _interpret(retry);
  }

  Future<_HttpAttemptResult> _attemptGet(
    List<String> tailSegments, {
    Map<String, String>? queryParameters,
    List<String> baseSegments = _baseSegments,
  }) async {
    final token = (await _idTokenProvider())?.trim();
    if (token == null || token.isEmpty) {
      throw const SyncProxyClientException(
        code: 'missing_auth_token',
        message: 'The sync proxy client has no live auth token.',
      );
    }
    final request = http.Request(
      'GET',
      _resolve(
        tailSegments,
        queryParameters: queryParameters,
        baseSegments: baseSegments,
      ),
    );
    request.headers.addAll(<String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer $token',
    });
    final streamed = await _httpClient.send(request).timeout(_timeout);
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    return _HttpAttemptResult(streamed.statusCode, raw);
  }

  Future<_HttpAttemptResult> _attemptPost(
    List<String> tailSegments, {
    required Map<String, Object?> body,
    required String idempotencyKey,
  }) async {
    final token = (await _idTokenProvider())?.trim();
    if (token == null || token.isEmpty) {
      throw const SyncProxyClientException(
        code: 'missing_auth_token',
        message: 'The sync proxy client has no live auth token.',
      );
    }
    final request = http.Request('POST', _resolve(tailSegments));
    request.headers.addAll(<String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer $token',
      'content-type': 'application/json',
      'idempotency-key': idempotencyKey,
    });
    request.body = jsonEncode(body);
    final streamed = await _httpClient.send(request).timeout(_timeout);
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    return _HttpAttemptResult(streamed.statusCode, raw);
  }

  Map<String, Object?> _interpret(_HttpAttemptResult attempt) {
    final body = _decodeObject(attempt.body);
    if (attempt.statusCode < 200 || attempt.statusCode >= 300) {
      throw SyncProxyClientException(
        code: _readString(body['error']) ?? 'sync_proxy_request_failed',
        message:
            _readString(body['message']) ?? 'The sync proxy request failed.',
        statusCode: attempt.statusCode,
      );
    }
    return body;
  }

  Uri _resolve(
    List<String> tailSegments, {
    Map<String, String>? queryParameters,
    List<String> baseSegments = _baseSegments,
  }) {
    // BUG 3 (MEDIUM): preserve any prefix path on `proxyBaseUri` (e.g.
    // `https://host/api/`). The previous implementation called
    // `proxyBaseUri.resolve('/v1/operators/...')`, which Uri treated as
    // an absolute path that wiped the prefix. Using path-segments here
    // guarantees prefix + `v1/operators/...` are concatenated cleanly.
    final basePathSegments = proxyBaseUri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final composed = <String>[
      ...basePathSegments,
      ...baseSegments,
      ...tailSegments,
    ];
    final resolved = proxyBaseUri.replace(pathSegments: composed);
    if (queryParameters == null || queryParameters.isEmpty) {
      return resolved;
    }
    return resolved.replace(
      queryParameters: <String, String>{
        ...resolved.queryParameters,
        ...queryParameters,
      },
    );
  }

  static List<String> _locationPath(
    String operatorId,
    String locationId,
    List<String> tail,
  ) => <String>[operatorId, 'locations', locationId, ...tail];

  static Map<String, String> _pageQuery({
    required String? cursor,
    required int pageSize,
  }) => <String, String>{
    'page_size': pageSize.toString(),
    if (cursor != null && cursor.isNotEmpty) 'modified_since': cursor,
  };

  static Map<String, Object?> _decodeObject(String raw) {
    if (raw.trim().isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    throw const SyncProxyClientException(
      code: 'malformed_sync_proxy_response',
      message: 'The sync proxy response was not a JSON object.',
    );
  }

  static List<Object?> _readList(Map<String, Object?> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      if (value is List) return value;
      throw SyncProxyClientException(
        code: 'malformed_sync_proxy_response',
        message: 'The sync proxy "$key" field was not a list.',
      );
    }
    return const <Object?>[];
  }

  static List<Object?> _readListOrSingleton(
    Map<String, Object?> json,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      if (value is List) return value;
      if (value is Map) return <Object?>[value];
      throw SyncProxyClientException(
        code: 'malformed_sync_proxy_response',
        message: 'The sync proxy "$key" field was not a list or object.',
      );
    }
    return const <Object?>[];
  }

  static Map<String, dynamic> _stringKeyMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map<String, Object?>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    throw const SyncProxyClientException(
      code: 'malformed_sync_proxy_response',
      message: 'The sync proxy row was not a JSON object.',
    );
  }

  static RestaurantTimingConfig _timingConfigFromJson(
    Map<String, dynamic> json, {
    required String fallbackRestaurantId,
  }) {
    final rawDefinitions =
        json['service_period_definitions'] ??
        json['service_period_definitions_json'] ??
        json['service_periods'] ??
        const <Object?>[];
    final definitionsSource = _readJsonList(
      rawDefinitions,
      'service_period_definitions',
    );
    final definitions = definitionsSource
        .map(
          (row) => ServicePeriodDefinition.fromMap(
            _normalizeServicePeriod(_stringKeyMap(row)),
          ),
        )
        .toList(growable: false);
    final shiftCloseAuthority =
        _readString(json['shift_close_authority']) ??
        _readString(json['close_authority']) ??
        ShiftCloseAuthority.vendorFinalization.value;
    final now = DateTime.now().toUtc().toIso8601String();
    return RestaurantTimingConfig(
      restaurantId: _readString(json['restaurant_id']) ?? fallbackRestaurantId,
      businessTimezone:
          _readString(json['business_timezone']) ??
          _readString(json['location_timezone']) ??
          '',
      businessDayStartLocalTime:
          _normalizeTime(_readString(json['business_day_start_local_time'])) ??
          '04:00',
      weekStartDay: _readInt(json['week_start_day']) ?? DateTime.monday,
      servicePeriodDefinitions: definitions,
      shiftCloseAuthority: ShiftCloseAuthority.fromValue(shiftCloseAuthority),
      localCloseFallback: _normalizeTime(
        _readString(json['local_close_fallback']) ??
            _readString(json['local_close_fallback_time']),
      ),
      createdAt: _readString(json['created_at']) ?? now,
      updatedAt: _readString(json['updated_at']) ?? now,
    );
  }

  static List<Object?> _readJsonList(Object? value, String key) {
    final Object? decoded;
    try {
      decoded = value is String ? jsonDecode(value) : value;
    } on FormatException {
      throw SyncProxyClientException(
        code: 'malformed_sync_proxy_response',
        message: 'The sync proxy "$key" field was not valid JSON.',
      );
    }
    if (decoded == null) return const <Object?>[];
    if (decoded is List) return decoded;
    throw SyncProxyClientException(
      code: 'malformed_sync_proxy_response',
      message: 'The sync proxy "$key" field was not a list.',
    );
  }

  static Map<String, dynamic> _normalizeServicePeriod(
    Map<String, dynamic> json,
  ) {
    return <String, dynamic>{
      'id':
          _readString(json['id']) ??
          _readString(json['service_period_key']) ??
          _readString(json['service_period_id']) ??
          '',
      'label': _readString(json['label']) ?? '',
      'short_label': _readString(json['short_label']) ?? '',
      'sort_order': _readInt(json['sort_order']) ?? 0,
      'start_local_time':
          _normalizeTime(_readString(json['start_local_time'])) ?? '00:00',
      'end_local_time':
          _normalizeTime(_readString(json['end_local_time'])) ?? '00:00',
      'rolls_past_midnight': _readBool(json['rolls_past_midnight']) ?? false,
      'applicable_days': _readIntList(
        json['applicable_days'] ?? json['applicable_weekdays'],
      ),
    };
  }

  static DemoModeRecord _demoModeRecordFromJson(Map<String, dynamic> json) {
    return DemoModeRecord(
      operatorId: _requiredString(json, 'operator_id'),
      locationId: _requiredString(json, 'location_id'),
      category: _integrationCategoryFromWire(_requiredString(json, 'category')),
      isDemo: _readBool(json['is_demo']) ?? true,
      flippedToLiveAt: _readDateTime(json['flipped_to_live_at']),
      flippedByConnectionId: _readString(json['flipped_by_connection_id']),
    );
  }

  static DataAccuracySettingsSnapshot _dataAccuracyFromJson(
    Map<String, dynamic> json,
  ) {
    return DataAccuracySettingsSnapshot(
      operatorId: _requiredString(json, 'operator_id'),
      locationId: _requiredString(json, 'location_id'),
      coversSourceLunch: _readString(json['covers_source_lunch']) ?? 'vendor',
      coversSourceDinner: _readString(json['covers_source_dinner']) ?? 'vendor',
      coversSourceLateNight:
          _readString(json['covers_source_late_night']) ?? 'vendor',
      coversManualEntries: _readManualEntries(json['covers_manual_entries']),
      wageSource: _readString(json['wage_source']) ?? 'vendor',
      walkInHandlingMode:
          _readString(json['walk_in_handling_mode']) ?? 'reservations_only',
      walkInManualEntries: _readIntMap(json['walk_in_manual_entries']),
      updatedAt: _readDateTime(json['updated_at']) ?? DateTime.now().toUtc(),
    );
  }

  static DataAccuracyServicePeriodSetting
  _dataAccuracyServicePeriodSettingFromJson(Map<String, dynamic> json) {
    return DataAccuracyServicePeriodSetting(
      id: _requiredString(json, 'id'),
      operatorId: _requiredString(json, 'operator_id'),
      locationId: _requiredString(json, 'location_id'),
      servicePeriodKey: _requiredString(json, 'service_period_key'),
      coversSource: ServicePeriodCoversSourceWire.fromWire(
        _readString(json['covers_source']) ?? 'vendor',
      ),
      wageSource: ServicePeriodWageSourceWire.fromWire(
        _readString(json['wage_source']) ?? 'target_substitution',
      ),
      effectiveAtBusinessDate:
          _readString(json['effective_at_business_date']) ??
          _readString(json['effectiveAtBusinessDate']) ??
          '1970-01-01',
      createdAt:
          _readDateTime(json['created_at']) ??
          _readDateTime(json['createdAt']) ??
          DateTime.now().toUtc(),
      updatedAt:
          _readDateTime(json['updated_at']) ??
          _readDateTime(json['updatedAt']) ??
          DateTime.now().toUtc(),
      updatedBy:
          _readString(json['updated_by']) ?? _readString(json['updatedBy']),
    );
  }

  static WageRoleRow _wageRoleRowFromJson(
    Map<String, dynamic> json, {
    required String fallbackRestaurantId,
  }) {
    return WageRoleRow(
      restaurantId:
          _readString(json['restaurant_id']) ??
          _readString(json['restaurantId']) ??
          fallbackRestaurantId,
      roleName:
          _readString(json['role_name']) ??
          _readString(json['roleName']) ??
          _requiredString(json, 'name'),
      laborBucket:
          _readString(json['labor_bucket']) ??
          _readString(json['laborBucket']) ??
          _requiredString(json, 'bucket'),
      hourlyRate:
          _readDouble(json['hourly_rate']) ??
          _readDouble(json['hourlyRate']) ??
          _requiredDouble(json, 'rate'),
      weightedHours:
          _readDouble(json['weighted_hours']) ??
          _readDouble(json['weightedHours']) ??
          _requiredDouble(json, 'hours'),
    );
  }

  static ForgeFlowPollingTierAssignmentSnapshot _pollingTierFromJson(
    Map<String, dynamic> json,
  ) {
    return ForgeFlowPollingTierAssignmentSnapshot(
      operatorId: _requiredString(json, 'operator_id'),
      locationId: _requiredString(json, 'location_id'),
      tierKey: _readString(json['tier_key']) ?? 'standard',
      pollingCadencePerVendorSeconds: _readIntMap(
        json['polling_cadence_per_vendor_seconds'],
      ),
      monthlyPriceCents: _readInt(json['monthly_price_cents']),
      effectiveAt:
          _readDateTime(json['effective_at']) ?? DateTime.now().toUtc(),
    );
  }

  static FirstBackfillStatusSnapshot _firstBackfillStatusFromJson(
    Map<String, dynamic> json,
  ) {
    final createdAt = _readDateTime(json['created_at']);
    final startedAt =
        _readDateTime(json['started_at']) ??
        _readDateTime(json['claimed_at']) ??
        createdAt;
    final updatedAt =
        _readDateTime(json['updated_at']) ??
        _readDateTime(json['completed_at']) ??
        startedAt;
    if (startedAt == null || updatedAt == null) {
      throw const SyncProxyClientException(
        code: 'malformed_sync_proxy_response',
        message:
            'The sync proxy first_backfill_status row was missing timestamps.',
      );
    }
    return FirstBackfillStatusSnapshot(
      jobId: _requiredString(json, 'job_id'),
      operatorId: _readString(json['operator_id']) ?? '',
      locationId: _readString(json['location_id']) ?? '',
      connectionId: _readString(json['connection_id']),
      vendorId: _readString(json['vendor_id']),
      category: _readString(json['category']),
      status: _requiredString(json, 'status').toLowerCase(),
      windowStart: _readDateTime(json['window_start']),
      windowEnd: _readDateTime(json['window_end']),
      startedAt: startedAt,
      completedAt: _readDateTime(json['completed_at']),
      updatedAt: updatedAt,
      lastError:
          _readString(json['last_error']) ?? _readString(json['error_summary']),
    );
  }

  static Map<String, Map<String, int>> _readManualEntries(Object? value) {
    if (value == null) return const <String, Map<String, int>>{};
    final outer = _stringKeyMap(value);
    return outer.map((date, rawInner) {
      final inner = _stringKeyMap(rawInner);
      return MapEntry(date, _readIntMap(inner));
    });
  }

  static Map<String, int> _readIntMap(Object? value) {
    if (value == null) return const <String, int>{};
    final json = _stringKeyMap(value);
    return json.map((key, val) => MapEntry(key, _readInt(val) ?? 0));
  }

  static IntegrationCategory _integrationCategoryFromWire(String value) {
    for (final category in IntegrationCategory.values) {
      if (category.name == value) return category;
    }
    throw SyncProxyClientException(
      code: 'malformed_sync_proxy_response',
      message: 'Unknown integration category "$value".',
    );
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = _readString(json[key]);
    if (value == null) {
      throw SyncProxyClientException(
        code: 'malformed_sync_proxy_response',
        message: 'The sync proxy response was missing "$key".',
      );
    }
    return value;
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _readDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static double _requiredDouble(Map<String, dynamic> json, String key) {
    final value = _readDouble(json[key]);
    if (value == null) {
      throw SyncProxyClientException(
        code: 'malformed_sync_proxy_response',
        message: 'The sync proxy response was missing "$key".',
      );
    }
    return value;
  }

  static List<int> _readIntList(Object? value) {
    if (value is! List) return const <int>[];
    return value.map(_readInt).whereType<int>().toList(growable: false);
  }

  static String? _normalizeTime(String? value) {
    if (value == null) return null;
    return value.length >= 5 ? value.substring(0, 5) : value;
  }

  static bool? _readBool(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return null;
  }

  static DateTime? _readDateTime(Object? value) {
    final raw = _readString(value);
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }
}

class SyncProxyClientException implements Exception {
  const SyncProxyClientException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'SyncProxyClientException($code, status=$statusCode)';
}

/// Internal carrier of a single HTTP attempt's status code + body so
/// the 401-retry path in [HttpSyncProxyClient] can decide whether to
/// invoke the optional refresh hook before throwing.
class _HttpAttemptResult {
  const _HttpAttemptResult(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
