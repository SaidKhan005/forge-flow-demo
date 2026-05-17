// Operator Web live data-accuracy gateway.
//
// Keeps the Operator Web Data Accuracy surface on the same server-owned
// settings row that mobile mirrors through operational sync. This client is
// web-safe: it goes through OperatorWebProxyClient and never imports dart:io.

import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/data_accuracy_service_period_setting.dart';
import 'operator_web_proxy_client.dart';

abstract class OperatorWebDataAccuracyGateway {
  Future<DataAccuracySettings?> loadSettings({
    required String operatorId,
    required String locationId,
  });

  Future<DataAccuracySettings> saveSettings(DataAccuracySettings settings);

  Future<List<DataAccuracyServicePeriodSetting>> loadServicePeriodSettings({
    required String operatorId,
    required String locationId,
  });

  Future<DataAccuracyServicePeriodSetting> saveServicePeriodSetting({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required ServicePeriodCoversSource coversSource,
    required ServicePeriodWageSource wageSource,
    required String effectiveAtBusinessDateIso,
  });
}

class OperatorWebHttpDataAccuracyGateway
    implements OperatorWebDataAccuracyGateway {
  OperatorWebHttpDataAccuracyGateway({
    required OperatorWebProxyClient client,
    required Future<String?> Function() idTokenProvider,
  }) : _client = client,
       _idTokenProvider = idTokenProvider;

  final OperatorWebProxyClient _client;
  final Future<String?> Function() _idTokenProvider;

  static String dataAccuracySettingsPath({
    required String operatorId,
    required String locationId,
  }) =>
      '/v1/operators/${Uri.encodeComponent(operatorId)}/locations/'
      '${Uri.encodeComponent(locationId)}/data_accuracy_settings';

  static String dataAccuracyServicePeriodSettingsPath({
    required String operatorId,
    required String locationId,
  }) =>
      '/v1/operators/${Uri.encodeComponent(operatorId)}/locations/'
      '${Uri.encodeComponent(locationId)}/'
      'data_accuracy_service_period_settings';

  @override
  Future<DataAccuracySettings?> loadSettings({
    required String operatorId,
    required String locationId,
  }) async {
    final token = await _requireToken();
    final response = await _client.getJson(
      dataAccuracySettingsPath(operatorId: operatorId, locationId: locationId),
      idToken: token,
    );
    final raw = response.body['data'];
    if (raw == null) return null;
    if (raw is! Map<Object?, Object?>) {
      throw const OperatorWebProxyException(
        code: 'malformed_data_accuracy_settings',
        message: 'The proxy returned malformed data accuracy settings.',
      );
    }
    return _settingsFromJson(Map<String, Object?>.from(raw));
  }

  @override
  Future<DataAccuracySettings> saveSettings(
    DataAccuracySettings settings,
  ) async {
    final token = await _requireToken();
    final body = _settingsToJson(settings);
    final response = await _client.patchJson(
      dataAccuracySettingsPath(
        operatorId: settings.operatorId,
        locationId: settings.locationId,
      ),
      idToken: token,
      body: body,
      // OW-G72 — caller-STABLE idempotency key, parity with the
      // #855/G60 fix in web_account_gateway.dart /
      // web_business_timing_gateway.dart. The operator+location scope
      // plus the full payload uniquely identifies this logical
      // data-accuracy settings write, so a retried "Save" reuses the
      // SAME key and the proxy `proxy_requests` UNIQUE guard collapses
      // the duplicate instead of double-applying the settings PATCH. A
      // different operator/location or a different edit gets a distinct
      // key.
      extraHeaders: _stableKeyHeader(
        'data-accuracy-settings-save',
        <Object?>[settings.operatorId, settings.locationId, body],
      ),
    );
    final raw = response.body['data'];
    if (raw is! Map<Object?, Object?>) {
      throw const OperatorWebProxyException(
        code: 'malformed_data_accuracy_settings',
        message: 'The proxy returned malformed data accuracy settings.',
      );
    }
    return _settingsFromJson(Map<String, Object?>.from(raw));
  }

  @override
  Future<List<DataAccuracyServicePeriodSetting>> loadServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) async {
    final token = await _requireToken();
    final response = await _client.getJson(
      dataAccuracyServicePeriodSettingsPath(
        operatorId: operatorId,
        locationId: locationId,
      ),
      idToken: token,
    );
    final raw =
        response.body['data_accuracy_service_period_settings'] ??
        response.body['service_period_settings'];
    if (raw is! List<Object?>) {
      throw const OperatorWebProxyException(
        code: 'malformed_data_accuracy_service_period_settings',
        message:
            'The proxy returned malformed data accuracy service-period '
            'settings.',
      );
    }
    final settings = <DataAccuracyServicePeriodSetting>[];
    for (final row in raw) {
      if (row is! Map<Object?, Object?>) {
        throw const OperatorWebProxyException(
          code: 'malformed_data_accuracy_service_period_settings',
          message:
              'The proxy returned malformed data accuracy service-period '
              'settings.',
        );
      }
      settings.add(
        _servicePeriodSettingFromJson(Map<String, Object?>.from(row)),
      );
    }
    return settings;
  }

  @override
  Future<DataAccuracyServicePeriodSetting> saveServicePeriodSetting({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required ServicePeriodCoversSource coversSource,
    required ServicePeriodWageSource wageSource,
    required String effectiveAtBusinessDateIso,
  }) async {
    final token = await _requireToken();
    final body = <String, Object?>{
      'service_period_key': servicePeriodKey,
      'covers_source': coversSource.wire,
      'wage_source': wageSource.wire,
      'effective_at_business_date': effectiveAtBusinessDateIso,
    };
    final response = await _client.patchJson(
      dataAccuracyServicePeriodSettingsPath(
        operatorId: operatorId,
        locationId: locationId,
      ),
      idToken: token,
      body: body,
      // OW-G72 — caller-STABLE idempotency key, parity with the
      // #855/G60 fix. This is the active per-daypart covers/wage SOURCE
      // write: the operator+location+service-period-key scope plus the
      // full payload uniquely identifies this logical write, so a
      // retried save reuses the SAME key (proxy `proxy_requests` UNIQUE
      // guard collapses the duplicate) while a different period / a
      // different edit gets a distinct key.
      extraHeaders: _stableKeyHeader(
        'data-accuracy-service-period-save',
        <Object?>[operatorId, locationId, servicePeriodKey, body],
      ),
    );
    final raw = response.body['data'];
    if (raw is! Map<Object?, Object?>) {
      throw const OperatorWebProxyException(
        code: 'malformed_data_accuracy_service_period_settings',
        message:
            'The proxy returned malformed data accuracy service-period '
            'settings.',
      );
    }
    return _servicePeriodSettingFromJson(Map<String, Object?>.from(raw));
  }

  /// OW-G72 — builds the `Idempotency-Key` header carrying a
  /// caller-STABLE key derived from [action] + [parts]. Same logical
  /// write (same operator/location/payload) on retry => same key
  /// (proxy `proxy_requests` UNIQUE guard collapses it); distinct
  /// actions / scopes / payloads => distinct keys. Exact parity with
  /// the #855/G60 `_stableKeyHeader` in `web_account_gateway.dart` and
  /// `web_business_timing_gateway.dart`.
  static Map<String, String> _stableKeyHeader(
    String action,
    List<Object?> parts,
  ) {
    return <String, String>{
      'Idempotency-Key': OperatorWebProxyClient.stableIdempotencyKey(
        action,
        parts,
      ),
    };
  }

  Future<String> _requireToken() async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebProxyException(
        statusCode: 401,
        code: 'unauthenticated',
        message: 'Sign in again to edit data accuracy.',
      );
    }
    return token.trim();
  }
}

Map<String, Object?> _settingsToJson(DataAccuracySettings settings) {
  return <String, Object?>{
    // Per-Daypart V1 Slice R5 (Gap 27/36): the canonical per-period
    // covers source is the keyed map. The three legacy wire keys are
    // still emitted (derived from the keyed map) so the proxy's
    // not-yet-migrated `data_accuracy_settings` upsert columns keep
    // working during the deprecation window; `fromRow` prefers the
    // keyed map when present.
    'covers_source_per_service_period': <String, Object?>{
      for (final e in settings.coversSourcePerServicePeriod.entries)
        e.key: e.value.wire,
    },
    'covers_source_lunch': settings.coversSourceFor('lunch').wire,
    'covers_source_dinner': settings.coversSourceFor('dinner').wire,
    'covers_source_late_night': settings.coversSourceFor('late_night').wire,
    'covers_manual_entries': <String, Object?>{
      for (final entry in settings.coversManualEntries.entries)
        entry.key: <String, Object?>{
          for (final inner in entry.value.entries) inner.key: inner.value,
        },
    },
    'wage_source': settings.wageSource.wire,
    'walk_in_handling_mode': settings.walkInHandlingMode.wire,
    'walk_in_manual_entries': <String, Object?>{
      for (final entry in settings.walkInManualEntries.entries)
        entry.key: entry.value,
    },
  };
}

DataAccuracySettings _settingsFromJson(Map<String, Object?> json) {
  return DataAccuracySettings.fromRow(<String, Object?>{
    ...json,
    'setting_id':
        _readString(json['setting_id']) ??
        'default:${_readString(json['operator_id'])}:'
            '${_readString(json['location_id'])}',
    'created_at': _dateTime(json['created_at']),
    'updated_at': _dateTime(json['updated_at']),
  });
}

String? _readString(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

DateTime _dateTime(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.parse(value).toUtc();
  }
  return DateTime.utc(1970);
}

DataAccuracyServicePeriodSetting _servicePeriodSettingFromJson(
  Map<String, Object?> json,
) {
  return DataAccuracyServicePeriodSetting.fromRow(<String, Object?>{
    ...json,
    'created_at': _dateTime(json['created_at']),
    'updated_at': _dateTime(json['updated_at']),
  });
}
