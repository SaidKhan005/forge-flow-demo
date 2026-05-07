// Operator Web live data-accuracy gateway.
//
// Keeps the Operator Web Data Accuracy surface on the same server-owned
// settings row that mobile mirrors through operational sync. This client is
// web-safe: it goes through OperatorWebProxyClient and never imports dart:io.

import '../../domain/models/data_accuracy_settings.dart';
import 'operator_web_proxy_client.dart';

abstract class OperatorWebDataAccuracyGateway {
  Future<DataAccuracySettings?> loadSettings({
    required String operatorId,
    required String locationId,
  });

  Future<DataAccuracySettings> saveSettings(DataAccuracySettings settings);
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
  Future<DataAccuracySettings> saveSettings(DataAccuracySettings settings) async {
    final token = await _requireToken();
    final response = await _client.patchJson(
      dataAccuracySettingsPath(
        operatorId: settings.operatorId,
        locationId: settings.locationId,
      ),
      idToken: token,
      body: _settingsToJson(settings),
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
    'covers_source_lunch': settings.coversSourceLunch.wire,
    'covers_source_dinner': settings.coversSourceDinner.wire,
    'covers_source_late_night': settings.coversSourceLateNight.wire,
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
