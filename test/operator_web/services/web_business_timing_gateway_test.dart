// Phase 11W.7 / Wave A2 - WebBusinessTimingGateway tests.
//
// Pin the contract that the A2-backend lane implements:
//   POST   /v1/operator/business-timing-profiles
//   PATCH  /v1/operator/business-timing-profiles/:id
//   POST   /v1/operator/business-timing-profiles/:id/service-periods
//   PATCH  /v1/operator/business-timing-profiles/:id/service-periods/:key
//
// Per-route assertions:
//   - method + path
//   - Idempotency-Key + Bearer auth
//   - JSON body shape
//   - Lane 0 / A0: profileId == versionId in response
//   - Operator-scoped path (NOT /v1/admin/*)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/services/web_business_timing_gateway.dart';

void main() {
  group('HttpWebBusinessTimingGateway', () {
    late List<http.Request> capturedRequests;

    Map<String, Object?> profilePayload({
      String profileId = 'profile-1',
      List<Map<String, Object?>>? periods,
    }) =>
        <String, Object?>{
          'profileId': profileId,
          'versionId': profileId,
          'scopeKind': 'location',
          'scopeId': 'location-1',
          'effectiveAtBusinessDate': '2026-05-10',
          'ianaTimezone': 'America/Toronto',
          'weekStartDay': 'monday',
          'businessDayStartLocal': '04:00',
          'servicePeriods': periods ??
              <Map<String, Object?>>[
                <String, Object?>{
                  'key': 'lunch',
                  'label': 'Lunch',
                  'startLocal': '11:00',
                  'endLocal': '15:00',
                  'rollsPastMidnight': false,
                },
              ],
          'createdAt': '2026-05-06T18:00:00.000Z',
          'updatedAt': '2026-05-06T18:00:00.000Z',
        };

    HttpWebBusinessTimingGateway buildGateway({
      List<Map<String, Object?>>? responses,
      List<int>? statuses,
      String? token = 'demo-id-token',
    }) {
      capturedRequests = <http.Request>[];
      var index = 0;
      final mock = MockClient((request) async {
        capturedRequests.add(request);
        final status = (statuses ?? <int>[200])[index];
        final body = (responses ?? <Map<String, Object?>>[profilePayload()])[
            index];
        index++;
        return http.Response(
          jsonEncode(body),
          status,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = OperatorWebProxyClient(
        baseUri: Uri.parse('https://proxy.test/'),
        httpClient: mock,
        idempotencyKeyFactory: () => 'idem-${capturedRequests.length}',
      );
      return HttpWebBusinessTimingGateway(
        client: client,
        idTokenProvider: () async => token,
      );
    }

    test('all path constants are operator-scoped (not /admin/)', () {
      expect(
        HttpWebBusinessTimingGateway.operatorProfilesPath,
        '/v1/operator/business-timing-profiles',
      );
      expect(HttpWebBusinessTimingGateway.operatorProfilesPath
          .contains('/admin/'), isFalse);
      final id = HttpWebBusinessTimingGateway.operatorProfilePath('p');
      expect(id, '/v1/operator/business-timing-profiles/p');
      expect(id.contains('/admin/'), isFalse);
      final periods =
          HttpWebBusinessTimingGateway.operatorServicePeriodsPath('p');
      expect(periods, '/v1/operator/business-timing-profiles/p/service-periods');
      expect(periods.contains('/admin/'), isFalse);
      final period =
          HttpWebBusinessTimingGateway.operatorServicePeriodPath('p', 'k');
      expect(period,
          '/v1/operator/business-timing-profiles/p/service-periods/k');
      expect(period.contains('/admin/'), isFalse);
    });

    test('createProfile POSTs operator-scoped path with full body', () async {
      final gateway = buildGateway();
      final result = await gateway.createProfile(
        const BusinessTimingProfileCreate(
          scopeKind: 'location',
          scopeId: 'location-1',
          effectiveAtBusinessDate: '2026-05-10',
          ianaTimezone: 'America/Toronto',
          weekStartDay: 'monday',
          businessDayStartLocal: '04:00',
          servicePeriods: <ServicePeriodCreate>[
            ServicePeriodCreate(
              key: 'lunch',
              label: 'Lunch',
              startLocal: '11:00',
              endLocal: '15:00',
            ),
          ],
        ),
      );
      expect(capturedRequests, hasLength(1));
      final request = capturedRequests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/operator/business-timing-profiles');
      expect(request.url.path.contains('/admin/'), isFalse);
      expect(request.headers['idempotency-key'], isNotNull);
      expect(request.headers['authorization'], 'Bearer demo-id-token');
      final json = jsonDecode(request.body) as Map<String, Object?>;
      expect(json['scopeKind'], 'location');
      expect(json['scopeId'], 'location-1');
      expect(json['ianaTimezone'], 'America/Toronto');
      expect(json['businessDayStartLocal'], '04:00');
      expect((json['servicePeriods'] as List<Object?>).length, 1);
      // Lane 0: profileId == versionId in response.
      expect(result.profileId, equals(result.versionId));
    });

    test('updateProfile PATCHes operator-scoped path', () async {
      final gateway = buildGateway();
      await gateway.updateProfile(
        profileId: 'profile-1',
        patch: const BusinessTimingProfilePatch(
          ianaTimezone: 'America/Vancouver',
        ),
      );
      final request = capturedRequests.single;
      expect(request.method, 'PATCH');
      expect(
        request.url.path,
        '/v1/operator/business-timing-profiles/profile-1',
      );
      expect(request.url.path.contains('/admin/'), isFalse);
      final json = jsonDecode(request.body) as Map<String, Object?>;
      expect(json.keys.toList(), <String>['ianaTimezone']);
    });

    test('addServicePeriod POSTs nested operator-scoped path', () async {
      final gateway = buildGateway();
      await gateway.addServicePeriod(
        profileId: 'profile-1',
        period: const ServicePeriodCreate(
          key: 'brunch',
          label: 'Brunch',
          startLocal: '10:00',
          endLocal: '14:00',
        ),
      );
      final request = capturedRequests.single;
      expect(request.method, 'POST');
      expect(
        request.url.path,
        '/v1/operator/business-timing-profiles/profile-1/service-periods',
      );
      expect(request.url.path.contains('/admin/'), isFalse);
      final json = jsonDecode(request.body) as Map<String, Object?>;
      expect(json['key'], 'brunch');
      expect(json['label'], 'Brunch');
    });

    test('updateServicePeriod PATCHes deepest nested path', () async {
      final gateway = buildGateway();
      await gateway.updateServicePeriod(
        profileId: 'profile-1',
        key: 'lunch',
        patch: const ServicePeriodPatch(endLocal: '14:30'),
      );
      final request = capturedRequests.single;
      expect(request.method, 'PATCH');
      expect(
        request.url.path,
        '/v1/operator/business-timing-profiles/profile-1/service-periods/lunch',
      );
      expect(request.url.path.contains('/admin/'), isFalse);
      final json = jsonDecode(request.body) as Map<String, Object?>;
      expect(json.keys.toList(), <String>['endLocal']);
      expect(json['endLocal'], '14:30');
    });

    test('400 service_period_overlap error code surfaces verbatim', () async {
      final gateway = buildGateway(
        statuses: const <int>[400],
        responses: const <Map<String, Object?>>[
          <String, Object?>{
            'error': 'service_period_overlap',
            'message': 'Service periods overlap.',
          },
        ],
      );
      await expectLater(
        () => gateway.createProfile(
          const BusinessTimingProfileCreate(
            scopeKind: 'location',
            scopeId: 'location-1',
            effectiveAtBusinessDate: '2026-05-10',
            ianaTimezone: 'America/Toronto',
            weekStartDay: 'monday',
            businessDayStartLocal: '04:00',
            servicePeriods: <ServicePeriodCreate>[
              ServicePeriodCreate(
                key: 'lunch',
                label: 'Lunch',
                startLocal: '11:00',
                endLocal: '15:00',
              ),
              ServicePeriodCreate(
                key: 'mid',
                label: 'Mid',
                startLocal: '14:00',
                endLocal: '16:00',
              ),
            ],
          ),
        ),
        throwsA(
          isA<OperatorWebProxyException>().having(
            (e) => e.code,
            'code',
            'service_period_overlap',
          ),
        ),
      );
    });

    test('missing token raises unauthenticated before any request', () async {
      final gateway = buildGateway(token: '');
      await expectLater(
        () => gateway.updateProfile(
          profileId: 'p',
          patch: const BusinessTimingProfilePatch(),
        ),
        throwsA(
          isA<OperatorWebProxyException>().having(
            (e) => e.code,
            'code',
            'unauthenticated',
          ),
        ),
      );
      expect(capturedRequests, isEmpty);
    });

    // Slice 2.5 / Gap 28 — DTO carries the three new fields end-to-end.
    test('ServicePeriodCreate.toJson emits applicableDays, shortLabel, sortOrder',
        () {
      const create = ServicePeriodCreate(
        key: 'brunch',
        label: 'Weekend Brunch',
        startLocal: '10:00',
        endLocal: '14:00',
        applicableDays: <int>[6, 7],
        shortLabel: 'B',
        sortOrder: 2,
      );
      final json = create.toJson();
      expect(json['applicableDays'], <int>[6, 7]);
      expect(json['shortLabel'], 'B');
      expect(json['sortOrder'], 2);
    });

    test('ServicePeriodCreate.toJson defaults all 7 weekdays + 1 sort + empty short',
        () {
      const create = ServicePeriodCreate(
        key: 'lunch',
        label: 'Lunch',
        startLocal: '11:00',
        endLocal: '15:00',
      );
      final json = create.toJson();
      expect(json['applicableDays'], <int>[1, 2, 3, 4, 5, 6, 7]);
      expect(json['shortLabel'], '');
      expect(json['sortOrder'], 1);
    });

    test('ServicePeriodPatch.toJson emits only present fields', () {
      const patch = ServicePeriodPatch(
        applicableDays: <int>[6, 7],
        shortLabel: 'L',
      );
      final json = patch.toJson();
      expect(json.keys.toSet(), <String>{'applicableDays', 'shortLabel'});
      expect(json['applicableDays'], <int>[6, 7]);
      expect(json['shortLabel'], 'L');
    });

    test(
      'ServicePeriod.fromJson defaults the three new fields when server omits them',
      () {
        final period = ServicePeriod.fromJson(<String, Object?>{
          'key': 'lunch',
          'label': 'Lunch',
          'startLocal': '11:00',
          'endLocal': '15:00',
          'rollsPastMidnight': false,
          // Older payloads omit applicableDays / shortLabel / sortOrder
          // entirely. fromJson must NOT throw `malformed_service_period`.
        });
        expect(period.applicableDays, <int>[1, 2, 3, 4, 5, 6, 7]);
        expect(period.shortLabel, '');
        expect(period.sortOrder, 0);
      },
    );

    test('ServicePeriod.fromJson reads the three fields when present', () {
      final period = ServicePeriod.fromJson(<String, Object?>{
        'key': 'brunch',
        'label': 'Brunch',
        'startLocal': '10:00',
        'endLocal': '14:00',
        'rollsPastMidnight': false,
        'applicableDays': <int>[6, 7],
        'shortLabel': 'B',
        'sortOrder': 1,
      });
      expect(period.applicableDays, <int>[6, 7]);
      expect(period.shortLabel, 'B');
      expect(period.sortOrder, 1);
    });

    test(
      'createProfile emits applicableDays / shortLabel / sortOrder on the wire',
      () async {
        final gateway = buildGateway();
        await gateway.createProfile(
          const BusinessTimingProfileCreate(
            scopeKind: 'location',
            scopeId: 'location-1',
            effectiveAtBusinessDate: '2026-05-10',
            ianaTimezone: 'America/Toronto',
            weekStartDay: 'monday',
            businessDayStartLocal: '04:00',
            servicePeriods: <ServicePeriodCreate>[
              ServicePeriodCreate(
                key: 'brunch',
                label: 'Weekend Brunch',
                startLocal: '10:00',
                endLocal: '14:00',
                applicableDays: <int>[6, 7],
                shortLabel: 'B',
                sortOrder: 2,
              ),
            ],
          ),
        );
        final request = capturedRequests.single;
        final json = jsonDecode(request.body) as Map<String, Object?>;
        final periods = json['servicePeriods'] as List<Object?>;
        final first = periods.single as Map<String, Object?>;
        expect(first['applicableDays'], <int>[6, 7]);
        expect(first['shortLabel'], 'B');
        expect(first['sortOrder'], 2);
      },
    );
  });
}
