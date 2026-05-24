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

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_data_accuracy_gateway.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_vendor_connections_gateway.dart';
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

  // OW-G72 — extends the #855/G60 caller-stable pattern to the two
  // operator-web write gateways #855 left uncovered:
  // OperatorWebHttpDataAccuracyGateway (saveSettings,
  // saveServicePeriodSetting — the active per-daypart covers/wage
  // SOURCE write) and OperatorWebHttpVendorConnectionsGateway
  // (connectWithApiKey credential persist, disconnect). Same
  // invariants as the #855 groups above.
  group('OW-G72 stable idempotency key — OperatorWebHttpDataAccuracyGateway',
      () {
    OperatorWebHttpDataAccuracyGateway buildGateway(
      List<http.Request> captured, {
      List<Map<String, Object?>>? responses,
    }) {
      final mock = MockClient((request) async {
        captured.add(request);
        final pool =
            responses ??
                <Map<String, Object?>>[
                  <String, Object?>{
                    'data': <String, Object?>{
                      'setting_id': 'setting-1',
                      'operator_id': 'op-1',
                      'location_id': 'loc-1',
                      'covers_source_per_service_period': <String, Object?>{
                        'lunch': 'manual',
                        'dinner': 'vendor',
                        'late_night': 'forecast',
                      },
                      'covers_manual_entries': <String, Object?>{},
                      'wage_source': 'manual_mix',
                      'walk_in_handling_mode':
                          'walk_ins_added_to_reservations',
                      'walk_in_manual_entries': <String, Object?>{},
                      'created_at': '2026-05-06T12:00:00Z',
                      'updated_at': '2026-05-06T12:01:00Z',
                      'updated_by': 'user-1',
                    },
                  },
                ];
        // Reuse the last canned response once the pool is exhausted so
        // a retried write (2nd identical call) still gets a 200.
        final body = pool[
            captured.length - 1 < pool.length
                ? captured.length - 1
                : pool.length - 1];
        return http.Response(
          jsonEncode(body),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      return OperatorWebHttpDataAccuracyGateway(
        client: OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          idempotencyKeyFactory: () => 'fresh-mint-${captured.length}',
        ),
        idTokenProvider: () async => 'tok',
      );
    }

    DataAccuracySettings settings({String currency = 'USD'}) {
      return DataAccuracySettings(
        settingId: 'setting-1',
        operatorId: 'op-1',
        locationId: 'loc-1',
        coversSourcePerServicePeriod: const <String, CoversSource>{
          'lunch': CoversSource.manual,
          'dinner': CoversSource.vendor,
          'late_night': CoversSource.forecast,
        },
        coversManualEntries: const <String, Map<String, int>>{},
        wageSource: WageSource.manualMix,
        walkInHandlingMode:
            DataAccuracyWalkInHandlingMode.walkInsAddedToReservations,
        walkInManualEntries: <String, int>{'2026-05-06': currency == 'USD' ? 8 : 9},
        createdAt: DateTime.utc(2026, 5, 6, 12),
        updatedAt: DateTime.utc(2026, 5, 6, 12, 1),
        updatedBy: 'user-1',
      );
    }

    test('retried saveSettings reuses the SAME stable key', () async {
      final captured = <http.Request>[];
      final gateway = buildGateway(captured);

      final payload = settings();
      await gateway.saveSettings(payload);
      await gateway.saveSettings(payload);

      expect(captured, hasLength(2));
      final first = captured[0].headers['idempotency-key'];
      expect(first, startsWith('op-web-data-accuracy-settings-save-'));
      expect(
        first,
        captured[1].headers['idempotency-key'],
        reason: 'retried identical settings write must reuse the same key',
      );
      expect(first, isNot(startsWith('fresh-mint-')));
    });

    test('distinct saveSettings payloads get DISTINCT keys', () async {
      final captured = <http.Request>[];
      final gateway = buildGateway(captured);

      await gateway.saveSettings(settings(currency: 'USD'));
      await gateway.saveSettings(settings(currency: 'CAD'));

      expect(
        captured[0].headers['idempotency-key'],
        isNot(captured[1].headers['idempotency-key']),
        reason: 'a different settings edit is a different logical action',
      );
    });

    test(
      'retried saveServicePeriodSetting reuses the SAME stable key; a '
      'different period key differs',
      () async {
        final captured = <http.Request>[];
        final periodRow = <String, Object?>{
          'data': <String, Object?>{
            'id': 'period-setting-1',
            'operator_id': 'op-1',
            'location_id': 'loc-1',
            'service_period_key': 'breakfast',
            'covers_source': 'reservation_plus_walkin',
            'wage_source': 'target_substitution',
            'effective_at_business_date': '2026-05-07',
            'created_at': '2026-05-07T12:00:00Z',
            'updated_at': '2026-05-07T12:01:00Z',
            'updated_by': 'user-1',
          },
        };
        final gateway = buildGateway(
          captured,
          responses: <Map<String, Object?>>[periodRow, periodRow, periodRow],
        );

        Future<void> save(String periodKey) => gateway.saveServicePeriodSetting(
              operatorId: 'op-1',
              locationId: 'loc-1',
              servicePeriodKey: periodKey,
              coversSource: ServicePeriodCoversSource.reservationPlusWalkin,
              wageSource: ServicePeriodWageSource.targetSubstitution,
              effectiveAtBusinessDateIso: '2026-05-07',
            );

        await save('breakfast');
        await save('breakfast');
        await save('lunch');

        expect(captured, hasLength(3));
        final first = captured[0].headers['idempotency-key'];
        expect(
          first,
          startsWith('op-web-data-accuracy-service-period-save-'),
        );
        expect(
          first,
          captured[1].headers['idempotency-key'],
          reason: 'retried identical per-daypart SOURCE write reuses key',
        );
        expect(
          first,
          isNot(captured[2].headers['idempotency-key']),
          reason: 'a different service period is a distinct logical write',
        );
        expect(first, isNot(startsWith('fresh-mint-')));
      },
    );

    test('GET loadSettings still auto-mints (read path unchanged)', () async {
      final captured = <http.Request>[];
      final gateway = buildGateway(captured);

      await gateway.loadSettings(operatorId: 'op-1', locationId: 'loc-1');

      expect(captured.single.method, 'GET');
      expect(
        captured.single.headers['idempotency-key'],
        startsWith('fresh-mint-'),
        reason: 'reads keep the per-request auto-mint fallback',
      );
    });
  });

  group(
      'OW-G72 stable idempotency key — '
      'OperatorWebHttpVendorConnectionsGateway', () {
    OperatorWebHttpVendorConnectionsGateway buildGateway(
      List<http.Request> captured,
    ) {
      final mock = MockClient((request) async {
        captured.add(request);
        return http.Response(
          jsonEncode(<String, Object?>{
            'connection_id': 'conn-1',
            'connected_at': '2026-05-16T12:00:00Z',
            'first_backfill_started': true,
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      return OperatorWebHttpVendorConnectionsGateway(
        proxyClient: OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          idempotencyKeyFactory: () => 'fresh-mint-${captured.length}',
        ),
        idTokenProvider: () async => 'tok',
      );
    }

    test('retried connectWithApiKey reuses the SAME stable key', () async {
      final captured = <http.Request>[];
      final gateway = buildGateway(captured);

      Future<void> connect() => gateway.connectWithApiKey(
            operatorId: 'op-1',
            locationId: 'loc-1',
            vendorId: 'square',
            apiKey: 'sk-123',
          );
      await connect();
      await connect();

      expect(captured, hasLength(2));
      final first = captured[0].headers['idempotency-key'];
      expect(first, startsWith('op-web-vendor-connect-api-key-'));
      expect(
        first,
        captured[1].headers['idempotency-key'],
        reason:
            'a retried credential persist must collapse against '
            'proxy_requests UNIQUE, not create a second connection',
      );
      expect(first, isNot(startsWith('fresh-mint-')));
    });

    test(
      'connectWithApiKey key differs by vendor / location / credential',
      () async {
        final captured = <http.Request>[];
        final gateway = buildGateway(captured);

        await gateway.connectWithApiKey(
          operatorId: 'op-1',
          locationId: 'loc-1',
          vendorId: 'square',
          apiKey: 'sk-123',
        );
        await gateway.connectWithApiKey(
          operatorId: 'op-1',
          locationId: 'loc-1',
          vendorId: 'toast',
          apiKey: 'sk-123',
        );
        await gateway.connectWithApiKey(
          operatorId: 'op-1',
          locationId: 'loc-1',
          vendorId: 'square',
          apiKey: 'sk-ROTATED',
        );

        final keys = captured
            .map((r) => r.headers['idempotency-key'])
            .toSet();
        expect(
          keys,
          hasLength(3),
          reason:
              'different vendor / rotated credential are distinct logical '
              'writes',
        );
      },
    );

    test('retried disconnect reuses the SAME stable key', () async {
      final captured = <http.Request>[];
      final gateway = buildGateway(captured);

      Future<void> disconnect() => gateway.disconnect(
            operatorId: 'op-1',
            locationId: 'loc-1',
            vendorId: 'square',
            reason: 'operator_requested',
          );
      await disconnect();
      await disconnect();

      expect(captured, hasLength(2));
      final first = captured[0].headers['idempotency-key'];
      expect(first, startsWith('op-web-vendor-disconnect-'));
      expect(
        first,
        captured[1].headers['idempotency-key'],
        reason: 'retried disconnect must not double-apply',
      );
      expect(first, isNot(startsWith('fresh-mint-')));
    });

    test(
      'startConnect / testConnection keep the per-request auto-mint '
      'fallback (out of OW-G72 scope, unchanged)',
      () async {
        final captured = <http.Request>[];
        final mock = MockClient((request) async {
          captured.add(request);
          return http.Response(
            jsonEncode(<String, Object?>{
              'auth_valid': true,
              'elapsed_ms': 12,
              'sample_summary': 'ok',
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        });
        final gateway = OperatorWebHttpVendorConnectionsGateway(
          proxyClient: OperatorWebProxyClient(
            baseUri: Uri.parse('https://proxy.test/'),
            httpClient: mock,
            idempotencyKeyFactory: () => 'fresh-mint-${captured.length}',
          ),
          idTokenProvider: () async => 'tok',
        );

        await gateway.testConnection(
          operatorId: 'op-1',
          locationId: 'loc-1',
          vendorId: 'square',
        );

        expect(
          captured.single.headers['idempotency-key'],
          startsWith('fresh-mint-'),
          reason:
              'the test-connection probe is not a OW-G72 logical write',
        );
      },
    );
  });

  // opweb-mfa-enroll — TOTP enroll's begin + confirm are TWO proxy
  // writes in ONE user action, so a retried confirm must replay the
  // SAME key (CLAUDE.md Proxy & API Conventions: every proxy write is
  // idempotent; proxy stores keys in proxy_requests UNIQUE). Mirrors
  // the admin one-stable-key-per-enroll-chain parity at the proxy-
  // client HTTP boundary.
  group('opweb-mfa-enroll — OperatorWebProxyClient TOTP enroll', () {
    test(
      'begin + confirm with the SAME caller key send the SAME '
      'Idempotency-Key (one enroll attempt correlates)',
      () async {
        final captured = <http.Request>[];
        final mock = MockClient((request) async {
          captured.add(request);
          if (request.url.path.endsWith('/begin')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'factor_id': 'totp-1',
                'secret_base32': 'JBSWY3DPEHPK3PXP',
                'otp_auth_url': 'otpauth://totp/Forge:demo?secret=JBSWY3DPEHPK3PXP',
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return http.Response('{}', 200);
        });
        var mintCount = 0;
        final client = OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          idempotencyKeyFactory: () => 'minted-${mintCount++}',
        );

        const enrollKey = 'op-web-account-mfa-enroll-abc-123';
        await client.beginTotpEnrollment(
          idToken: 'tok',
          email: 'alex@brio.test',
          idempotencyKey: enrollKey,
        );
        // A retried confirm of the SAME attempt replays the SAME key.
        await client.confirmTotpEnrollment(
          idToken: 'tok',
          factorId: 'totp-1',
          oneTimeCode: '654321',
          idempotencyKey: enrollKey,
        );
        await client.confirmTotpEnrollment(
          idToken: 'tok',
          factorId: 'totp-1',
          oneTimeCode: '654321',
          idempotencyKey: enrollKey,
        );

        expect(captured, hasLength(3));
        final keys = captured
            .map((r) => r.headers['idempotency-key'])
            .toList(growable: false);
        expect(keys, everyElement(enrollKey));
        expect(keys.toSet(), hasLength(1));
        // The auto-mint factory must NOT have been consulted for any of
        // the three writes.
        expect(mintCount, 0);
      },
    );

    test(
      'begin + confirm WITHOUT a caller key keep the byte-identical '
      'auto-mint fallback (no-op when no caller key)',
      () async {
        final captured = <http.Request>[];
        final mock = MockClient((request) async {
          captured.add(request);
          if (request.url.path.endsWith('/begin')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'factor_id': 'totp-1',
                'secret_base32': 'JBSWY3DPEHPK3PXP',
                'otp_auth_url': 'otpauth://totp/Forge:demo?secret=JBSWY3DPEHPK3PXP',
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return http.Response('{}', 200);
        });
        var mintCount = 0;
        final client = OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          idempotencyKeyFactory: () => 'minted-${mintCount++}',
        );

        await client.beginTotpEnrollment(
          idToken: 'tok',
          email: 'alex@brio.test',
        );
        await client.confirmTotpEnrollment(
          idToken: 'tok',
          factorId: 'totp-1',
          oneTimeCode: '654321',
        );

        // The legacy path: each call auto-mints a fresh per-request key
        // (begin and confirm therefore DIFFER), exactly as before this
        // change. The factory was consulted once per call.
        expect(mintCount, 2);
        expect(captured[0].headers['idempotency-key'], 'minted-0');
        expect(captured[1].headers['idempotency-key'], 'minted-1');
      },
    );

    test(
      'mintActionChainIdempotencyKey is distinct per call and web-safe '
      'shaped',
      () {
        final a = OperatorWebProxyClient.mintActionChainIdempotencyKey(
          'account-mfa-enroll',
        );
        final b = OperatorWebProxyClient.mintActionChainIdempotencyKey(
          'account-mfa-enroll',
        );
        expect(a, startsWith('op-web-account-mfa-enroll-'));
        expect(
          a,
          isNot(equals(b)),
          reason:
              'two separate enroll attempts must never collide, so each '
              'mint yields a distinct key',
        );
      },
    );
  });
}
