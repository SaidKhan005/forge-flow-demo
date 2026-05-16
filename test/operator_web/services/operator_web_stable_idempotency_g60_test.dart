// G60 — operator-web account / business-timing writes carry a
// CALLER-STABLE idempotency key.
//
// Audit finding G60 (cross_surface_parity_audit_2026_05_16.md):
// `OperatorWebProxyClient._applyHeaders` minted a FRESH idempotency
// key on every call and `patchJson`/`deleteJson` exposed no override,
// so a retried account/business-timing write got a NEW key each time
// and defeated the proxy `proxy_requests` UNIQUE replay guard
// (duplicate timing profiles, double-applied identity PATCH).
//
// These tests pin the fix invariants:
//   1. A retried logical write reuses the SAME Idempotency-Key.
//   2. Distinct actions / payloads get DISTINCT keys.
//   3. GET / read still works (auto-mint fallback unchanged).
//   4. The proxy client honors a caller-supplied stable key on
//      patchJson / deleteJson (regardless of header-name casing) and
//      sends exactly one canonical Idempotency-Key.
//
// Exemplar parity: this is the same "one stable key per logical
// action, reused on retry" posture `web_team_roles_gateway.dart`
// already implements via screen-minted keys.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/services/web_account_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_business_timing_gateway.dart';

void main() {
  group('G60 stable idempotency key — OperatorWebProxyClient', () {
    test(
      'patchJson honors a caller-supplied Idempotency-Key instead of '
      'minting a fresh one',
      () async {
        final captured = <http.Request>[];
        final mock = MockClient((request) async {
          captured.add(request);
          return http.Response(
            jsonEncode(<String, Object?>{'ok': true}),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        });
        var mintCount = 0;
        final client = OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          idempotencyKeyFactory: () => 'minted-${mintCount++}',
        );

        await client.patchJson(
          '/v1/operator/account',
          idToken: 'tok',
          body: const <String, Object?>{'businessName': 'Brio'},
          extraHeaders: const <String, String>{
            'Idempotency-Key': 'caller-stable-key',
          },
        );

        expect(captured.single.headers['idempotency-key'], 'caller-stable-key');
        // The auto-mint factory must NOT have been consulted.
        expect(mintCount, 0);
      },
    );

    test(
      'caller key wins even when supplied under a lower-case header '
      'name and exactly one canonical key is sent',
      () async {
        final captured = <http.Request>[];
        final mock = MockClient((request) async {
          captured.add(request);
          return http.Response('{}', 200);
        });
        final client = OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          idempotencyKeyFactory: () => 'minted',
        );

        await client.deleteJson(
          '/v1/operator/thing/1',
          idToken: 'tok',
          extraHeaders: const <String, String>{
            'idempotency-key': 'lower-case-caller-key',
          },
        );

        final request = captured.single;
        expect(request.headers['idempotency-key'], 'lower-case-caller-key');
        // No stray duplicate header survived the case-insensitive
        // merge (http.Request.headers is case-insensitive, so a single
        // lookup proves there is exactly one logical key, and it is
        // the caller's, not the minted fallback).
        expect(request.headers['idempotency-key'], isNot('minted'));
      },
    );

    test(
      'GET still auto-mints (read path unchanged — no caller key)',
      () async {
        final captured = <http.Request>[];
        final mock = MockClient((request) async {
          captured.add(request);
          return http.Response(
            jsonEncode(<String, Object?>{'operatorId': 'op-1'}),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        });
        final client = OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          idempotencyKeyFactory: () => 'minted-read-key',
        );

        await client.getJson('/v1/operator/account', idToken: 'tok');

        expect(
          captured.single.headers['idempotency-key'],
          'minted-read-key',
        );
      },
    );

    test('stableIdempotencyKey is deterministic + action/payload-scoped', () {
      final a1 = OperatorWebProxyClient.stableIdempotencyKey(
        'account-patch',
        <Object?>[
          <String, Object?>{'businessName': 'Brio'},
        ],
      );
      final a2 = OperatorWebProxyClient.stableIdempotencyKey(
        'account-patch',
        <Object?>[
          <String, Object?>{'businessName': 'Brio'},
        ],
      );
      final different = OperatorWebProxyClient.stableIdempotencyKey(
        'account-patch',
        <Object?>[
          <String, Object?>{'businessName': 'Other'},
        ],
      );
      final differentAction = OperatorWebProxyClient.stableIdempotencyKey(
        'self-profile-patch',
        <Object?>[
          <String, Object?>{'businessName': 'Brio'},
        ],
      );
      expect(a1, a2, reason: 'same action + payload => same key (retry safe)');
      expect(a1, isNot(different), reason: 'different payload => different key');
      expect(
        a1,
        isNot(differentAction),
        reason: 'different action => different key',
      );
      expect(a1, startsWith('op-web-account-patch-'));
    });
  });

  group('G60 stable idempotency key — HttpWebAccountGateway', () {
    test('retried patchAccount reuses the SAME stable key', () async {
      final captured = <http.Request>[];
      final mock = MockClient((request) async {
        captured.add(request);
        return http.Response(
          jsonEncode(<String, Object?>{
            'operatorId': 'op-1',
            'businessName': 'Brio Restaurants',
            'logoUrl': null,
            'currencyCode': 'USD',
            'localeTag': 'en-US',
            'weekStartDay': 'monday',
            'rolloverHour': 4,
            'updatedAt': '2026-05-16T12:00:00.000Z',
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json',
          },
        );
      });
      var mint = 0;
      final gateway = HttpWebAccountGateway(
        client: OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          idempotencyKeyFactory: () => 'fresh-mint-${mint++}',
        ),
        idTokenProvider: () async => 'tok',
      );

      const patch = AccountIdentityPatch(businessName: 'Brio Restaurants');
      await gateway.patchAccount(patch);
      // Simulate the user / transport retrying the exact same edit.
      await gateway.patchAccount(patch);

      expect(captured, hasLength(2));
      final first = captured[0].headers['idempotency-key'];
      final second = captured[1].headers['idempotency-key'];
      expect(first, isNotNull);
      expect(first, startsWith('op-web-account-patch-'));
      expect(
        first,
        second,
        reason: 'retried identical write must reuse the same key',
      );
      // Never the non-stable minted fallback.
      expect(first, isNot(startsWith('fresh-mint-')));
    });

    test('distinct patchAccount payloads get DISTINCT keys', () async {
      final captured = <http.Request>[];
      final mock = MockClient((request) async {
        captured.add(request);
        return http.Response(
          jsonEncode(<String, Object?>{
            'operatorId': 'op-1',
            'businessName': 'Brio Restaurants',
            'logoUrl': null,
            'currencyCode': 'USD',
            'localeTag': 'en-US',
            'weekStartDay': 'monday',
            'rolloverHour': 4,
            'updatedAt': '2026-05-16T12:00:00.000Z',
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json',
          },
        );
      });
      final gateway = HttpWebAccountGateway(
        client: OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          idempotencyKeyFactory: () => 'fresh-mint',
        ),
        idTokenProvider: () async => 'tok',
      );

      await gateway.patchAccount(
        const AccountIdentityPatch(businessName: 'Brio Restaurants'),
      );
      await gateway.patchAccount(
        const AccountIdentityPatch(currencyCode: 'CAD'),
      );

      expect(
        captured[0].headers['idempotency-key'],
        isNot(captured[1].headers['idempotency-key']),
        reason: 'a different edit is a different logical action',
      );
    });
  });

  group('G60 stable idempotency key — HttpWebBusinessTimingGateway', () {
    HttpWebBusinessTimingGateway buildGateway(List<http.Request> captured) {
      final mock = MockClient((request) async {
        captured.add(request);
        return http.Response(
          jsonEncode(<String, Object?>{
            'profileId': 'profile-1',
            'versionId': 'profile-1',
            'scopeKind': 'location',
            'scopeId': 'location-1',
            'effectiveAtBusinessDate': '2026-05-10',
            'ianaTimezone': 'America/Toronto',
            'weekStartDay': 'monday',
            'businessDayStartLocal': '04:00',
            'servicePeriods': const <Map<String, Object?>>[],
            'createdAt': '2026-05-16T12:00:00.000Z',
            'updatedAt': '2026-05-16T12:00:00.000Z',
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json',
          },
        );
      });
      var mint = 0;
      return HttpWebBusinessTimingGateway(
        client: OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          idempotencyKeyFactory: () => 'fresh-mint-${mint++}',
        ),
        idTokenProvider: () async => 'tok',
      );
    }

    test(
      'retried createProfile reuses the SAME stable key (no duplicate '
      'timing profile)',
      () async {
        final captured = <http.Request>[];
        final gateway = buildGateway(captured);

        const request = BusinessTimingProfileCreate(
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
        );
        await gateway.createProfile(request);
        await gateway.createProfile(request);

        expect(captured, hasLength(2));
        final first = captured[0].headers['idempotency-key'];
        expect(first, startsWith('op-web-timing-profile-create-'));
        expect(
          first,
          captured[1].headers['idempotency-key'],
          reason:
              'a retried create must collapse against proxy_requests '
              'UNIQUE, not insert a second profile',
        );
        expect(first, isNot(startsWith('fresh-mint-')));
      },
    );

    test(
      'updateServicePeriod key is scoped to profile + period key + '
      'payload (distinct period => distinct key)',
      () async {
        final captured = <http.Request>[];
        final gateway = buildGateway(captured);

        await gateway.updateServicePeriod(
          profileId: 'profile-1',
          key: 'lunch',
          patch: const ServicePeriodPatch(label: 'Midday'),
        );
        await gateway.updateServicePeriod(
          profileId: 'profile-1',
          key: 'dinner',
          patch: const ServicePeriodPatch(label: 'Midday'),
        );

        expect(
          captured[0].headers['idempotency-key'],
          startsWith('op-web-timing-service-period-update-'),
        );
        expect(
          captured[0].headers['idempotency-key'],
          isNot(captured[1].headers['idempotency-key']),
        );
      },
    );
  });
}
