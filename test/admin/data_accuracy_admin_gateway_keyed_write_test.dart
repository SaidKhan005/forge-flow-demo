import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';

void main() {
  group('DataAccuracy admin gateway keyed write shape', () {
    test('PATCH normal write sends keyed covers map only', () async {
      late Map<String, Object?> captured;
      final gateway = HttpDataAccuracyAdminGateway(
        baseUri: Uri.parse('https://proxy.test'),
        bearerTokenProvider: () async => 'token',
        httpClient: MockClient((http.Request request) async {
          captured = _decode(request);
          return _rowResponse();
        }),
      );

      await gateway.overrideDataAccuracy(
        operatorId: 'op-1',
        locationId: 'loc-1',
        coversSourcePerServicePeriod: const <String, CoversSource>{
          'breakfast': CoversSource.manual,
          'happy_hour': CoversSource.forecast,
        },
        actorUserId: 'admin-1',
        actorIsForgeAdmin: true,
        reasonNote: 'Set custom periods',
      );

      expect(captured['covers_source_per_service_period'], <String, Object?>{
        'breakfast': 'manual',
        'happy_hour': 'forecast',
      });
      expect(captured.containsKey('covers_source_lunch'), isFalse);
      expect(captured.containsKey('covers_source_dinner'), isFalse);
      expect(captured.containsKey('covers_source_late_night'), isFalse);
    });

    test('PUT scoped write sends keyed covers map only', () async {
      late Map<String, Object?> captured;
      final gateway = HttpDataAccuracyAdminGateway(
        baseUri: Uri.parse('https://proxy.test'),
        bearerTokenProvider: () async => 'token',
        httpClient: MockClient((http.Request request) async {
          captured = _decode(request);
          return _scopeResponse();
        }),
      );

      await gateway.overrideDataAccuracyScope(
        operatorId: 'op-1',
        scopeType: AdminDataAccuracyMutationScopeType.orgUnit,
        orgUnitId: 'ou-1',
        coversSourcePerServicePeriod: const <String, CoversSource>{
          'brunch': CoversSource.manual,
          'supper_rush': CoversSource.forecast,
        },
        actorUserId: 'admin-1',
        actorIsForgeAdmin: true,
        reasonNote: 'Set regional custom periods',
      );

      expect(captured['covers_source_per_service_period'], <String, Object?>{
        'brunch': 'manual',
        'supper_rush': 'forecast',
      });
      expect(captured.containsKey('covers_source_lunch'), isFalse);
      expect(captured.containsKey('covers_source_dinner'), isFalse);
      expect(captured.containsKey('covers_source_late_night'), isFalse);
    });
  });
}

Map<String, Object?> _decode(http.Request request) {
  final decoded = jsonDecode(request.body) as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
}

http.Response _rowResponse() {
  return http.Response(
    jsonEncode(<String, Object?>{'row': _row()}),
    200,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

http.Response _scopeResponse() {
  return http.Response(
    jsonEncode(<String, Object?>{
      'scope_type': 'org_unit',
      'operator_id': 'op-1',
      'org_unit_id': 'ou-1',
      'affected_location_count': 1,
      'rows': <Map<String, Object?>>[_row()],
    }),
    200,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

Map<String, Object?> _row() {
  return <String, Object?>{
    'operator_ref': <String, Object?>{
      'operator_id': 'op-1',
      'business_name': 'Demo Group',
      'location_id': 'loc-1',
      'location_name': 'Downtown',
    },
    'settings': <String, Object?>{
      'setting_id': 'setting-1',
      'operator_id': 'op-1',
      'location_id': 'loc-1',
      'covers_source_per_service_period': <String, Object?>{
        'breakfast': 'manual',
      },
      'covers_manual_entries': <String, Object?>{},
      'wage_source': 'vendor',
      'walk_in_handling_mode': 'reservations_only',
      'walk_in_manual_entries': <String, Object?>{},
      'created_at': '2026-05-20T00:00:00.000Z',
      'updated_at': '2026-05-20T00:00:00.000Z',
    },
    'service_period_settings': <Object?>[],
    'service_period_definitions': <Object?>[],
  };
}
