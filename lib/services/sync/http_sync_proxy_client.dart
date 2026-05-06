import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models/open_shift_snapshot.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../domain/models/service_period_definition.dart';
import '../../models/shift_record.dart';
import '../integration/demo_mode_state.dart';
import '../integration/integration_adapter_common.dart';
import 'sync_proxy_client.dart';

class HttpSyncProxyClient implements SyncProxyClient {
  HttpSyncProxyClient({
    required this.proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 20),
  }) : _idTokenProvider = idTokenProvider,
       _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String _basePath = '/v1/operators';

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    final body = await _getJson(
      _locationPath(operatorId, locationId, 'shift_records'),
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
      _locationPath(operatorId, locationId, 'open_shift_snapshots'),
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
      _locationPath(operatorId, locationId, 'timing/resolved'),
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
      _locationPath(operatorId, locationId, 'demo_mode_states'),
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
      _locationPath(operatorId, locationId, 'data_accuracy_settings'),
    );
    final raw =
        body['data_accuracy_settings'] ?? body['settings'] ?? body['data'];
    if (raw == null) return null;
    return _dataAccuracyFromJson(_stringKeyMap(raw));
  }

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async {
    final body = await _getJson(
      _locationPath(operatorId, locationId, 'polling_tier_assignment'),
    );
    final raw =
        body['polling_tier_assignment'] ?? body['assignment'] ?? body['data'];
    if (raw == null) return null;
    return _pollingTierFromJson(_stringKeyMap(raw));
  }

  Future<Map<String, Object?>> _getJson(
    String path, {
    Map<String, String>? queryParameters,
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
      _resolve(path, queryParameters: queryParameters),
    );
    request.headers.addAll(<String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer $token',
    });
    final streamed = await _httpClient.send(request).timeout(_timeout);
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    final body = _decodeObject(raw);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw SyncProxyClientException(
        code: _readString(body['error']) ?? 'sync_proxy_request_failed',
        message:
            _readString(body['message']) ?? 'The sync proxy request failed.',
        statusCode: streamed.statusCode,
      );
    }
    return body;
  }

  Uri _resolve(String path, {Map<String, String>? queryParameters}) {
    final resolved = proxyBaseUri.resolve(path);
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

  static String _locationPath(
    String operatorId,
    String locationId,
    String tail,
  ) =>
      '$_basePath/${Uri.encodeComponent(operatorId)}'
      '/locations/${Uri.encodeComponent(locationId)}/$tail';

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
      updatedAt: _readDateTime(json['updated_at']) ?? DateTime.now().toUtc(),
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
