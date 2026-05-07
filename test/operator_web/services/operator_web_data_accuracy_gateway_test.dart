import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_data_accuracy_gateway.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';

void main() {
  group('OperatorWebHttpDataAccuracyGateway', () {
    late List<http.Request> capturedRequests;

    Map<String, Object?> settingsPayload({
      String coversSourceLunch = 'manual',
      String wageSource = 'manual_mix',
    }) {
      return <String, Object?>{
        'data': <String, Object?>{
          'setting_id': 'setting-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'covers_source_lunch': coversSourceLunch,
          'covers_source_dinner': 'vendor',
          'covers_source_late_night': 'forecast',
          'covers_manual_entries': <String, Object?>{
            '2026-05-06': <String, Object?>{'lunch': 42},
          },
          'wage_source': wageSource,
          'walk_in_handling_mode': 'walk_ins_added_to_reservations',
          'walk_in_manual_entries': <String, Object?>{'2026-05-06': 8},
          'created_at': '2026-05-06T12:00:00Z',
          'updated_at': '2026-05-06T12:01:00Z',
          'updated_by': 'user-1',
        },
      };
    }

    Map<String, Object?> servicePeriodRow({
      String servicePeriodKey = 'breakfast',
      String coversSource = 'reservation_plus_walkin',
      String wageSource = 'target_substitution',
      String effectiveAtBusinessDate = '2026-05-07',
    }) {
      return <String, Object?>{
        'id': 'period-setting-1',
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'service_period_key': servicePeriodKey,
        'covers_source': coversSource,
        'wage_source': wageSource,
        'effective_at_business_date': effectiveAtBusinessDate,
        'created_at': '2026-05-07T12:00:00Z',
        'updated_at': '2026-05-07T12:01:00Z',
        'updated_by': 'user-1',
      };
    }

    OperatorWebHttpDataAccuracyGateway buildGateway({
      String? token = 'demo-id-token',
      List<Map<String, Object?>>? responses,
    }) {
      capturedRequests = <http.Request>[];
      var index = 0;
      final mock = MockClient((request) async {
        capturedRequests.add(request);
        final body =
            (responses ?? <Map<String, Object?>>[settingsPayload()])[index];
        index++;
        return http.Response(
          jsonEncode(body),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = OperatorWebProxyClient(
        baseUri: Uri.parse('https://proxy.test/'),
        httpClient: mock,
        idempotencyKeyFactory: () => 'idem-${capturedRequests.length}',
      );
      return OperatorWebHttpDataAccuracyGateway(
        client: client,
        idTokenProvider: () async => token,
      );
    }

    test('loads data accuracy settings from operator-scoped path', () async {
      final gateway = buildGateway();
      final settings = await gateway.loadSettings(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );

      expect(settings, isNotNull);
      expect(settings!.coversSourceLunch, CoversSource.manual);
      expect(settings.wageSource, WageSource.manualMix);
      expect(settings.walkInCountFor('2026-05-06'), 8);
      final request = capturedRequests.single;
      expect(request.method, 'GET');
      expect(
        request.url.path,
        '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
      );
      expect(request.url.path.contains('/admin/'), isFalse);
      expect(request.headers['authorization'], 'Bearer demo-id-token');
    });

    test('loads service-period settings from operator-scoped path', () async {
      final gateway = buildGateway(
        responses: <Map<String, Object?>>[
          <String, Object?>{
            'data_accuracy_service_period_settings': <Map<String, Object?>>[
              servicePeriodRow(),
            ],
          },
        ],
      );

      final settings = await gateway.loadServicePeriodSettings(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );

      expect(settings, hasLength(1));
      final setting = settings.single;
      expect(setting.servicePeriodKey, 'breakfast');
      expect(
        setting.coversSource,
        ServicePeriodCoversSource.reservationPlusWalkin,
      );
      expect(setting.wageSource, ServicePeriodWageSource.targetSubstitution);
      expect(setting.effectiveAtBusinessDate, '2026-05-07');
      final request = capturedRequests.single;
      expect(request.method, 'GET');
      expect(
        request.url.path,
        '/v1/operators/op-1/locations/loc-1/'
        'data_accuracy_service_period_settings',
      );
      expect(request.url.path.contains('/admin/'), isFalse);
      expect(request.headers['authorization'], 'Bearer demo-id-token');
    });

    test('saves full settings payload through PATCH', () async {
      final gateway = buildGateway(
        responses: <Map<String, Object?>>[settingsPayload()],
      );
      final result = await gateway.saveSettings(
        DataAccuracySettings(
          settingId: 'setting-1',
          operatorId: 'op-1',
          locationId: 'loc-1',
          coversSourceLunch: CoversSource.manual,
          coversSourceDinner: CoversSource.vendor,
          coversSourceLateNight: CoversSource.forecast,
          coversManualEntries: const <String, Map<String, int>>{
            '2026-05-06': <String, int>{'lunch': 42},
          },
          wageSource: WageSource.manualMix,
          walkInHandlingMode:
              DataAccuracyWalkInHandlingMode.walkInsAddedToReservations,
          walkInManualEntries: const <String, int>{'2026-05-06': 8},
          createdAt: DateTime.utc(2026, 5, 6, 12),
          updatedAt: DateTime.utc(2026, 5, 6, 12, 1),
          updatedBy: 'user-1',
        ),
      );

      expect(result.coversSourceLateNight, CoversSource.forecast);
      final request = capturedRequests.single;
      expect(request.method, 'PATCH');
      expect(
        request.url.path,
        '/v1/operators/op-1/locations/loc-1/data_accuracy_settings',
      );
      final json = jsonDecode(request.body) as Map<String, Object?>;
      expect(json['covers_source_lunch'], 'manual');
      expect(json['wage_source'], 'manual_mix');
      expect(json['walk_in_handling_mode'], 'walk_ins_added_to_reservations');
      expect(request.headers['idempotency-key'], isNotNull);
    });

    test('saves service-period settings through PATCH', () async {
      final gateway = buildGateway(
        responses: <Map<String, Object?>>[
          <String, Object?>{'data': servicePeriodRow()},
        ],
      );

      final result = await gateway.saveServicePeriodSetting(
        operatorId: 'op-1',
        locationId: 'loc-1',
        servicePeriodKey: 'breakfast',
        coversSource: ServicePeriodCoversSource.reservationPlusWalkin,
        wageSource: ServicePeriodWageSource.targetSubstitution,
        effectiveAtBusinessDateIso: '2026-05-07',
      );

      expect(result.servicePeriodKey, 'breakfast');
      expect(
        result.coversSource,
        ServicePeriodCoversSource.reservationPlusWalkin,
      );
      expect(result.wageSource, ServicePeriodWageSource.targetSubstitution);
      final request = capturedRequests.single;
      expect(request.method, 'PATCH');
      expect(
        request.url.path,
        '/v1/operators/op-1/locations/loc-1/'
        'data_accuracy_service_period_settings',
      );
      final json = jsonDecode(request.body) as Map<String, Object?>;
      expect(json['service_period_key'], 'breakfast');
      expect(json['covers_source'], 'reservation_plus_walkin');
      expect(json['wage_source'], 'target_substitution');
      expect(json['effective_at_business_date'], '2026-05-07');
      expect(request.headers['idempotency-key'], isNotNull);
    });

    test('requires an id token', () async {
      final gateway = buildGateway(token: null);
      expect(
        () => gateway.loadSettings(operatorId: 'op-1', locationId: 'loc-1'),
        throwsA(isA<OperatorWebProxyException>()),
      );
      expect(capturedRequests, isEmpty);
    });
  });
}
