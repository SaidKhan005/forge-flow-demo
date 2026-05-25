// Unit coverage for the admin business-timing PROFILE write gateway.
//
// Asserts the gateway hits the admin cross-tenant routes (never the
// operator route), injects the server-required `admin_reason` + an
// `Idempotency-Key` header on writes, omits null patch fields, parses the
// returned record, and surfaces the proxy error code on a non-2xx.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/admin/services/admin_business_timing_profiles_gateway.dart';

void main() {
  Map<String, Object?> recordJson({
    String profileId = 'p1',
    String tz = 'America/Toronto',
    String dayStart = '04:00',
    List<Map<String, Object?>> periods = const <Map<String, Object?>>[],
  }) => <String, Object?>{
    'profileId': profileId,
    'versionId': profileId,
    'scopeKind': 'operator',
    'scopeId': 'op-1',
    'effectiveAtBusinessDate': '2026-05-24',
    'ianaTimezone': tz,
    'weekStartDay': 'monday',
    'businessDayStartLocal': dayStart,
    'servicePeriods': periods,
    'createdAt': '2026-05-24T00:00:00Z',
    'updatedAt': '2026-05-24T00:00:00Z',
  };

  HttpAdminBusinessTimingProfilesGateway gateway(
    http.Client client, {
    bool useStablePayloadIdempotencyKeys = true,
  }) => HttpAdminBusinessTimingProfilesGateway(
    baseUri: Uri.parse('https://admin-proxy.forgeflow.app'),
    bearerTokenProvider: () async => 'tok',
    httpClient: client,
    useStablePayloadIdempotencyKeys: useStablePayloadIdempotencyKeys,
  );

  test('createProfile POSTs to the admin profiles route with admin_reason + '
      'idempotency key, and parses the returned record', () async {
    late http.Request captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(
          recordJson(
            periods: <Map<String, Object?>>[
              <String, Object?>{
                'key': 'lunch',
                'label': 'Lunch',
                'startLocal': '11:00',
                'endLocal': '15:00',
                'rollsPastMidnight': false,
                'shortLabel': 'L',
                'sortOrder': 1,
                'applicableDays': <int>[1, 2, 3, 4, 5, 6, 7],
              },
            ],
          ),
        ),
        201,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    });

    final record = await gateway(client).createProfile(
      operatorId: 'op-1',
      profile: const AdminBusinessTimingProfileCreate(
        scopeKind: 'operator',
        scopeId: 'op-1',
        effectiveAtBusinessDate: '2026-05-24',
        ianaTimezone: 'America/Toronto',
        weekStartDay: 'monday',
        businessDayStartLocal: '04:00',
        servicePeriods: <AdminServicePeriodWrite>[
          AdminServicePeriodWrite(
            key: 'lunch',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '15:00',
          ),
        ],
      ),
      adminReason: 'support repair',
      idempotencyKey: 'idem-1',
    );

    expect(captured.method, 'POST');
    expect(
      captured.url.path,
      '/v1/admin/operators/op-1/business-timing-profiles',
    );
    // Never the operator-scoped route (no silent permission downgrade).
    expect(captured.url.path, isNot(contains('/v1/operator/')));
    expect(
      captured.headers['idempotency-key'],
      startsWith('admin-timing-profile-create-'),
    );
    expect(captured.headers['authorization'], 'Bearer tok');

    final sent = jsonDecode(captured.body) as Map<String, Object?>;
    expect(sent['admin_reason'], 'support repair');
    expect(sent['scopeKind'], 'operator');
    expect((sent['servicePeriods'] as List).length, 1);

    expect(record.profileId, 'p1');
    expect(record.ianaTimezone, 'America/Toronto');
    expect(record.servicePeriods.single.key, 'lunch');
  });

  test('updateProfile PATCHes the profile route, sends only non-null patch '
      'fields + admin_reason', () async {
    late http.Request captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(jsonEncode(recordJson(dayStart: '05:00')), 200);
    });

    await gateway(client).updateProfile(
      operatorId: 'op-1',
      profileId: 'p1',
      patch: const AdminBusinessTimingProfilePatch(
        scopeKind: 'org_unit',
        scopeId: 'ou-1',
        businessDayStartLocal: '05:00',
      ),
      adminReason: 'shift start fix',
      idempotencyKey: 'idem-2',
    );

    expect(captured.method, 'PATCH');
    expect(
      captured.url.path,
      '/v1/admin/operators/op-1/business-timing-profiles/p1',
    );
    final sent = jsonDecode(captured.body) as Map<String, Object?>;
    expect(sent['scopeKind'], 'org_unit');
    expect(sent['scopeId'], 'ou-1');
    expect(sent['businessDayStartLocal'], '05:00');
    expect(sent['admin_reason'], 'shift start fix');
    expect(
      captured.headers['idempotency-key'],
      startsWith('admin-timing-profile-update-'),
    );
    // Null patch fields are omitted (server's immutable-field guard
    // never sees an unchanged field).
    expect(sent.containsKey('ianaTimezone'), isFalse);
    expect(sent.containsKey('servicePeriods'), isFalse);
  });

  test(
    'updateProfile derives a stable payload idempotency key while preserving '
    'admin_reason in the body',
    () async {
      final captured = <http.Request>[];
      final client = MockClient((req) async {
        captured.add(req);
        return http.Response(jsonEncode(recordJson(dayStart: '05:00')), 200);
      });
      final adminGateway = gateway(client);
      const patch = AdminBusinessTimingProfilePatch(
        scopeKind: 'location',
        scopeId: 'loc-1',
        businessDayStartLocal: '05:00',
      );

      await adminGateway.updateProfile(
        operatorId: 'op-1',
        profileId: 'p1',
        patch: patch,
        adminReason: 'same support reason',
        idempotencyKey: 'caller-key-1',
      );
      await adminGateway.updateProfile(
        operatorId: 'op-1',
        profileId: 'p1',
        patch: patch,
        adminReason: 'same support reason',
        idempotencyKey: 'caller-key-2',
      );
      await adminGateway.updateProfile(
        operatorId: 'op-1',
        profileId: 'p1',
        patch: patch,
        adminReason: 'different support reason',
        idempotencyKey: 'caller-key-3',
      );

      expect(captured, hasLength(3));
      final firstKey = captured[0].headers['idempotency-key'];
      expect(firstKey, startsWith('admin-timing-profile-update-'));
      expect(
        firstKey,
        captured[1].headers['idempotency-key'],
        reason: 'same logical PATCH should replay under the same key',
      );
      expect(
        firstKey,
        isNot(captured[2].headers['idempotency-key']),
        reason: 'admin_reason is part of the audited payload',
      );
      expect(firstKey, isNot('caller-key-1'));

      final sent = jsonDecode(captured[0].body) as Map<String, Object?>;
      expect(sent['scopeKind'], 'location');
      expect(sent['scopeId'], 'loc-1');
      expect(sent['admin_reason'], 'same support reason');
    },
  );

  test(
    'legacy mode can still forward the caller-supplied idempotency key',
    () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode(recordJson(dayStart: '05:00')), 200);
      });

      await gateway(
        client,
        useStablePayloadIdempotencyKeys: false,
      ).updateProfile(
        operatorId: 'op-1',
        profileId: 'p1',
        patch: const AdminBusinessTimingProfilePatch(
          scopeKind: 'operator',
          scopeId: 'op-1',
          businessDayStartLocal: '05:00',
        ),
        adminReason: 'shift start fix',
        idempotencyKey: 'caller-owned-key',
      );

      expect(captured.headers['idempotency-key'], 'caller-owned-key');
    },
  );

  test('a non-2xx surfaces the proxy error code', () async {
    final client = MockClient(
      (req) async => http.Response(
        jsonEncode(<String, Object?>{
          'error': 'missing_admin_reason',
          'message': 'admin_reason is required',
        }),
        400,
      ),
    );

    await expectLater(
      () => gateway(client).createProfile(
        operatorId: 'op-1',
        profile: const AdminBusinessTimingProfileCreate(
          scopeKind: 'operator',
          scopeId: 'op-1',
          effectiveAtBusinessDate: '2026-05-24',
          ianaTimezone: 'UTC',
          weekStartDay: 'monday',
          businessDayStartLocal: '04:00',
          servicePeriods: <AdminServicePeriodWrite>[],
        ),
        adminReason: 'x',
        idempotencyKey: 'k',
      ),
      throwsA(
        isA<AdminBusinessTimingProfileGatewayError>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.errorCode, 'errorCode', 'missing_admin_reason'),
      ),
    );
  });

  test('malformed successful profile body surfaces parser error', () async {
    final client = MockClient(
      (req) async => http.Response(
        jsonEncode(<String, Object?>{...recordJson(), 'profileId': ''}),
        201,
      ),
    );

    await expectLater(
      () => gateway(client).createProfile(
        operatorId: 'op-1',
        profile: const AdminBusinessTimingProfileCreate(
          scopeKind: 'operator',
          scopeId: 'op-1',
          effectiveAtBusinessDate: '2026-05-24',
          ianaTimezone: 'UTC',
          weekStartDay: 'monday',
          businessDayStartLocal: '04:00',
          servicePeriods: <AdminServicePeriodWrite>[],
        ),
        adminReason: 'x',
        idempotencyKey: 'k',
      ),
      throwsA(
        isA<AdminBusinessTimingProfileGatewayError>().having(
          (e) => e.errorCode,
          'errorCode',
          'malformed_business_timing_profile',
        ),
      ),
    );
  });

  test(
    'malformed successful service-period body surfaces parser error',
    () async {
      final client = MockClient(
        (req) async => http.Response(
          jsonEncode(
            recordJson(
              periods: const <Map<String, Object?>>[
                <String, Object?>{
                  'key': 'lunch',
                  'label': 'Lunch',
                  'startLocal': '11:00',
                  // Missing endLocal.
                },
              ],
            ),
          ),
          201,
        ),
      );

      await expectLater(
        () => gateway(client).createProfile(
          operatorId: 'op-1',
          profile: const AdminBusinessTimingProfileCreate(
            scopeKind: 'operator',
            scopeId: 'op-1',
            effectiveAtBusinessDate: '2026-05-24',
            ianaTimezone: 'UTC',
            weekStartDay: 'monday',
            businessDayStartLocal: '04:00',
            servicePeriods: <AdminServicePeriodWrite>[],
          ),
          adminReason: 'x',
          idempotencyKey: 'k',
        ),
        throwsA(
          isA<AdminBusinessTimingProfileGatewayError>().having(
            (e) => e.errorCode,
            'errorCode',
            'malformed_business_timing_profile',
          ),
        ),
      );
    },
  );

  test('listProfiles GETs the route and parses the profile list', () async {
    late http.Request captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode(<String, Object?>{
          'profiles': <Map<String, Object?>>[recordJson()],
        }),
        200,
      );
    });

    final list = await gateway(client).listProfiles(operatorId: 'op-1');

    expect(captured.method, 'GET');
    expect(
      captured.url.path,
      '/v1/admin/operators/op-1/business-timing-profiles',
    );
    expect(list.single.profileId, 'p1');
  });
}
