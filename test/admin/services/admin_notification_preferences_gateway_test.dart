// X-G71 (cross-surface parity register §0b) — admin self-service
// notification-preferences gateway tests.
//
// Pins:
//   * GET hits `/v1/operator/notification-preferences` with the
//     bearer token and parses the `preferences` array.
//   * PUT hits `/v1/operator/notification-preferences/:event/:channel`
//     with the bearer token, the Idempotency-Key header, the
//     `scope_kind` query param, and the `{enabled: bool}` body.
//   * A 4xx proxy error surfaces as
//     `AdminNotificationPreferencesGatewayError`.
//   * The in-memory demo gateway round-trips upserts AND records the
//     idempotency key on every call (so the screen test can prove key
//     stability across retries — the G60/G70 bug class).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:forge_and_flow/admin/services/admin_notification_preferences_gateway.dart';

void main() {
  group('HttpAdminNotificationPreferencesGateway', () {
    test('listPreferences GETs the shared operator route', () async {
      late http.Request captured;
      final client = http_testing.MockClient.streaming(
        (request, stream) async {
          captured = request as http.Request;
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(<String, Object?>{
              'preferences': <Map<String, Object?>>[
                <String, Object?>{
                  'event_key': 'notif.backfill.complete',
                  'channel': 'email',
                  'scope_kind': 'operator',
                  'scope_id': null,
                  'enabled': false,
                },
              ],
            }))),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        },
      );
      final gateway = HttpAdminNotificationPreferencesGateway(
        baseUri: Uri.parse('https://proxy.test'),
        bearerTokenProvider: () async => 'test-token',
        httpClient: client,
      );

      final rows = await gateway.listPreferences();

      expect(captured.method, 'GET');
      expect(captured.url.path, '/v1/operator/notification-preferences');
      expect(captured.headers['authorization'], 'Bearer test-token');
      expect(rows, hasLength(1));
      expect(rows.single.eventKey, 'notif.backfill.complete');
      expect(rows.single.channel, 'email');
      expect(rows.single.enabled, isFalse);
    });

    test('upsertPreference PUTs the expected wire payload', () async {
      late http.Request captured;
      final client = http_testing.MockClient.streaming(
        (request, stream) async {
          captured = request as http.Request;
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(<String, Object?>{
              'event_key': 'notif.backfill.complete',
              'channel': 'push',
              'scope_kind': 'operator',
              'scope_id': null,
              'enabled': true,
            }))),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        },
      );
      final gateway = HttpAdminNotificationPreferencesGateway(
        baseUri: Uri.parse('https://proxy.test'),
        bearerTokenProvider: () async => 'test-token',
        httpClient: client,
      );

      final row = await gateway.upsertPreference(
        eventKey: 'notif.backfill.complete',
        channel: 'push',
        scopeKind: 'operator',
        scopeId: null,
        enabled: true,
        idempotencyKey: 'idem-stable-1',
      );

      expect(captured.method, 'PUT');
      expect(
        captured.url.path,
        '/v1/operator/notification-preferences/'
        'notif.backfill.complete/push',
      );
      expect(captured.url.queryParameters['scope_kind'], 'operator');
      expect(captured.headers['authorization'], 'Bearer test-token');
      expect(captured.headers['Idempotency-Key'], 'idem-stable-1');
      final body = jsonDecode(captured.body) as Map<String, Object?>;
      expect(body, <String, Object?>{'enabled': true});
      expect(row.enabled, isTrue);
      expect(row.channel, 'push');
    });

    test('4xx proxy error surfaces as a typed gateway error', () async {
      final client = http_testing.MockClient.streaming(
        (request, stream) async {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(<String, Object?>{
              'error': 'idempotency_key_conflict',
              'message': 'Idempotency-Key was reused with a different body',
            }))),
            409,
            headers: <String, String>{'content-type': 'application/json'},
          );
        },
      );
      final gateway = HttpAdminNotificationPreferencesGateway(
        baseUri: Uri.parse('https://proxy.test'),
        bearerTokenProvider: () async => 'test-token',
        httpClient: client,
      );

      await expectLater(
        gateway.upsertPreference(
          eventKey: 'notif.backfill.complete',
          channel: 'push',
          scopeKind: 'operator',
          scopeId: null,
          enabled: true,
          idempotencyKey: 'idem-1',
        ),
        throwsA(
          isA<AdminNotificationPreferencesGatewayError>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.errorCode, 'errorCode',
                  'idempotency_key_conflict'),
        ),
      );
    });
  });

  group('InMemoryAdminNotificationPreferencesGateway', () {
    test('seeds, round-trips upserts, and records every call', () async {
      final gateway = InMemoryAdminNotificationPreferencesGateway(
        initial: const <AdminNotificationPreference>[
          AdminNotificationPreference(
            eventKey: 'notif.backfill.complete',
            channel: 'email',
            scopeKind: 'operator',
            scopeId: null,
            enabled: false,
          ),
        ],
      );

      final seeded = await gateway.listPreferences();
      expect(seeded.single.enabled, isFalse);

      await gateway.upsertPreference(
        eventKey: 'notif.backfill.complete',
        channel: 'email',
        scopeKind: 'operator',
        scopeId: null,
        enabled: true,
        idempotencyKey: 'idem-42',
      );

      final after = await gateway.listPreferences();
      expect(after.single.enabled, isTrue);
      expect(gateway.calls, hasLength(1));
      expect(gateway.calls.single.idempotencyKey, 'idem-42');
      expect(gateway.calls.single.eventKey, 'notif.backfill.complete');
    });
  });
}
