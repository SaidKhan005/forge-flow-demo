// Phase 11A.4 — Integration management admin gateway tests.
//
// Coverage groups:
//
//   * `InMemoryIntegrationAdminGateway` — list + rotate round trip,
//     masked-value invariant (plaintext NEVER reachable through
//     [list]), KMS forced-failure surfaces a 503 error, missing
//     plaintext rejected at the gateway boundary.
//
//   * `maskCredentialForDisplay` — small helper that the rest of the
//     codebase relies on for masked-display uniqueness.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/integration_admin_models.dart';
import 'package:forge_and_flow/admin/services/integration_admin_gateway.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_stub_provider.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:http/http.dart' as http;

void main() {
  group('maskCredentialForDisplay', () {
    test('masks long plaintext as <first4>***<last4>', () {
      expect(
        maskCredentialForDisplay('sk-ant-1234567890abcdQ9aB'),
        equals('sk-a***Q9aB'),
      );
    });

    test('rejects strings shorter than 9 characters', () {
      expect(maskCredentialForDisplay('short'), equals('***'));
    });
  });

  group('InMemoryIntegrationAdminGateway — list', () {
    test('returns provider keys in canonical order', () async {
      final gateway = InMemoryIntegrationAdminGateway(
        seed: <ProviderKeyRow>[
          ProviderKeyRow(
            credentialId: 'cred-voyage',
            keyKind: ProviderKeyKind.voyage,
            maskedValue: 'pa-v***RtZx',
            kmsSecretName: 'kms://stub/seed-voyage',
            createdBy: 'demo-actor',
            updatedBy: 'demo-actor',
            rotatedAt: DateTime.utc(2026, 4, 5, 9),
          ),
          ProviderKeyRow(
            credentialId: 'cred-anthropic',
            keyKind: ProviderKeyKind.anthropic,
            maskedValue: 'sk-a***Q9aB',
            kmsSecretName: 'kms://stub/seed-anthropic',
            createdBy: 'demo-actor',
            updatedBy: 'demo-actor',
            rotatedAt: DateTime.utc(2026, 4, 1, 14),
          ),
        ],
      );
      final bundle = await gateway.list();
      expect(
        bundle.providerKeys.map((r) => r.keyKind).toList(),
        equals(<ProviderKeyKind>[
          ProviderKeyKind.anthropic,
          ProviderKeyKind.voyage,
        ]),
      );
      // Plaintext invariant: list payload never carries a
      // `plaintext_value` field, only the masked display.
      for (final row in bundle.providerKeys) {
        expect(row.maskedValue.contains('***'), isTrue);
      }
    });

    test(
      'includes default vendor connectors and FX-rate / email status',
      () async {
        final gateway = InMemoryIntegrationAdminGateway();
        final bundle = await gateway.list();
        expect(bundle.vendorConnectors, hasLength(17));
        expect(
          bundle.vendorConnectors.map((status) => status.id),
          containsAll(<String>[
            'aloha_ncr_voyix',
            'clover',
            'lightspeed_lsk',
            'oracle_micros_simphony',
            'revel',
            'square',
            'toast',
            'libro',
            'opentable',
            'sevenrooms',
            'tock',
            'adp',
            'agendrix',
            'humanity',
            'push_operations',
            'quickbooks_time',
            'seven_shifts',
          ]),
        );
        expect(bundle.fxRateSource.id, equals('fx_rate'));
        expect(bundle.emailProvider.id, equals('email'));
        expect(bundle.emailProvider.detailMessage, contains('Phase 9.8'));
        expect(
          bundle.vendorConnectors.map((status) => status.statusLabel).toSet(),
          equals(<String>{'API pending'}),
        );
        expect(
          bundle.vendorConnectors
              .firstWhere((status) => status.id == 'toast')
              .detailMessage,
          startsWith('API reachability pending.'),
        );
        expect(
          bundle.vendorConnectors
              .firstWhere((status) => status.id == 'toast')
              .category,
          VendorCategory.pos,
        );
        expect(
          bundle.vendorConnectors
              .firstWhere((status) => status.id == 'quickbooks_time')
              .category,
          VendorCategory.labor,
        );
        expect(
          bundle.vendorConnectors
              .firstWhere((status) => status.id == 'tock')
              .category,
          VendorCategory.reservation,
        );
        expect(
          bundle.vendorConnectors
              .firstWhere((status) => status.id == 'toast')
              .unlockLabel,
          equals('Vendor setup waits for reachable API access'),
        );
      },
    );
  });

  group('InMemoryIntegrationAdminGateway — rotate', () {
    test(
      'rotate appends a new row, masks plaintext, preserves invariant',
      () async {
        final gateway = InMemoryIntegrationAdminGateway(
          actorUserId: 'rotator-x',
          seed: <ProviderKeyRow>[
            ProviderKeyRow(
              credentialId: 'cred-anthropic',
              keyKind: ProviderKeyKind.anthropic,
              maskedValue: 'sk-a***Q9aB',
              kmsSecretName: 'kms://stub/seed-anthropic',
              createdBy: 'demo-actor',
              updatedBy: 'demo-actor',
              rotatedAt: DateTime.utc(2026, 4, 1, 14),
            ),
          ],
        );
        final result = await gateway.rotateKey(
          const RotateKeyCommand(
            keyKind: ProviderKeyKind.anthropic,
            plaintextValue: 'sk-ant-thisIsTheNewPlaintext1234',
            idempotencyKey: 'k-rotate-anthropic',
          ),
        );
        // The rotation response carries plaintext ONCE.
        expect(
          result.plaintextValue,
          equals('sk-ant-thisIsTheNewPlaintext1234'),
        );
        expect(result.row.maskedValue, equals('sk-a***1234'));
        expect(result.row.kmsSecretName, startsWith('kms://stub/'));
        expect(result.row.updatedBy, equals('rotator-x'));

        // Subsequent list calls return only the masked value.
        final bundle = await gateway.list();
        final anthropic = bundle.providerKeys.firstWhere(
          (r) => r.keyKind == ProviderKeyKind.anthropic,
        );
        expect(anthropic.maskedValue, equals('sk-a***1234'));
        expect(anthropic.maskedValue, isNot(contains('thisIsTheNew')));
      },
    );

    test('rejects an empty plaintext_value at the gateway boundary', () async {
      final gateway = InMemoryIntegrationAdminGateway();
      Object? thrown;
      try {
        await gateway.rotateKey(
          const RotateKeyCommand(
            keyKind: ProviderKeyKind.voyage,
            plaintextValue: '   ',
            idempotencyKey: 'k-rotate-empty',
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<IntegrationAdminGatewayError>());
      final err = thrown! as IntegrationAdminGatewayError;
      expect(err.errorCode, equals('missing_plaintext_value'));
      expect(err.statusCode, equals(400));
    });

    test(
      'forced KMS failure surfaces a kms_write_failed gateway error',
      () async {
        final kms = KmsStubProvider(failNextWrite: true);
        final gateway = InMemoryIntegrationAdminGateway(kmsProvider: kms);
        Object? thrown;
        try {
          await gateway.rotateKey(
            const RotateKeyCommand(
              keyKind: ProviderKeyKind.azureDb,
              plaintextValue: 'azure-superuser-Pa55word!',
              idempotencyKey: 'k-rotate-kms-fail',
            ),
          );
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<IntegrationAdminGatewayError>());
        final err = thrown! as IntegrationAdminGatewayError;
        expect(err.errorCode, equals('kms_write_failed'));
        expect(err.statusCode, equals(503));

        // Prior list stays intact (Azure DB seed is empty by default;
        // the failed rotation must NOT have appended a row).
        final bundle = await gateway.list();
        expect(
          bundle.providerKeys.where(
            (r) => r.keyKind == ProviderKeyKind.azureDb,
          ),
          isEmpty,
        );
      },
    );
  });

  // HARD-H — admin idempotency parcel. The InMemory gateway caches
  // per-key like the proxy does against `admin_request_idempotency`.
  group('InMemoryIntegrationAdminGateway — idempotency replay', () {
    test('second rotateKey with same key returns cached row + plaintext '
        'without performing a second KMS write', () async {
      final kms = KmsStubProvider();
      final gateway = InMemoryIntegrationAdminGateway(kmsProvider: kms);
      final command = const RotateKeyCommand(
        keyKind: ProviderKeyKind.anthropic,
        plaintextValue: 'sk-ant-original-key-PlaintextHere',
        idempotencyKey: 'idem-rotate',
      );
      final first = await gateway.rotateKey(command);
      // Replay with a DIFFERENT plaintext under the same key — the
      // cached result wins (matches the proxy's
      // `idempotency_payload_mismatch` envelope by ignoring the
      // replay payload).
      final second = await gateway.rotateKey(
        const RotateKeyCommand(
          keyKind: ProviderKeyKind.anthropic,
          plaintextValue: 'sk-ant-different-key-2nd-attempt',
          idempotencyKey: 'idem-rotate',
        ),
      );
      expect(
        second.row.credentialId,
        equals(first.row.credentialId),
        reason: 'Replay must hit the cached row, not allocate a fresh one',
      );
      expect(second.row.maskedValue, equals(first.row.maskedValue));
      expect(second.plaintextValue, equals(first.plaintextValue));
    });
  });

  // HARD-H — Http variant attaches the Idempotency-Key header on
  // rotation POST so the proxy's `admin_request_idempotency` lookup
  // can dedup retries.
  group('HttpIntegrationAdminGateway — Idempotency-Key wiring', () {
    test(
      'list normalizes vendor lifecycle labels to API reachability',
      () async {
        final captured = <_CapturedAdminRequest>[];
        final client = _SingleResponseClient(
          captured: captured,
          response: _HttpFixture(
            statusCode: 200,
            body: <String, Object?>{
              'provider_keys': const <Object?>[],
              'vendor_connectors': const <Object?>[
                <String, Object?>{
                  'id': 'toast',
                  'display_name': 'Toast',
                  'status_label': 'Documented',
                  'category': 'pos',
                  'api_reachable': false,
                  'health_source': 'live_api_probe',
                  'unlock_state': 'api_pending',
                  'detail_message': 'POS adapter implemented.',
                },
                <String, Object?>{
                  'id': 'lightspeed_lsk',
                  'display_name': 'Lightspeed Restaurant K-Series',
                  'status_label': 'Ready to connect',
                  'category': 'pos',
                  'api_reachable': true,
                  'health_source_label': 'Vendor API probe succeeded',
                  'can_connect': true,
                  'detail_message': 'Production credentials available.',
                },
              ],
              'fx_rate_source': <String, Object?>{
                'id': 'fx_rate',
                'display_name': 'FX-rate source',
                'status_label': 'green',
                'detail_message': 'ECB feed live.',
              },
              'email_provider': <String, Object?>{
                'id': 'email',
                'display_name': 'Email provider',
                'status_label': 'placeholder',
                'detail_message': 'Email provider pending.',
              },
            },
          ),
        );
        final gateway = HttpIntegrationAdminGateway(
          baseUri: Uri.parse('https://proxy.example.com'),
          bearerTokenProvider: () async => 'fake.token',
          httpClient: client,
        );

        final bundle = await gateway.list();

        expect(captured.single.method, equals('GET'));
        expect(captured.single.uri.path, equals('/v1/admin/integrations'));
        expect(
          bundle.vendorConnectors.map((status) => status.statusLabel),
          equals(<String>['API pending', 'API reachable']),
        );
        expect(
          bundle.vendorConnectors.map((status) => status.apiReachable),
          equals(<bool?>[false, true]),
        );
        expect(
          bundle.vendorConnectors.map((status) => status.category),
          equals(<VendorCategory?>[VendorCategory.pos, VendorCategory.pos]),
        );
        expect(
          bundle.vendorConnectors.first.healthSourceLabel,
          equals('Live API reachability check'),
        );
        expect(
          bundle.vendorConnectors.last.healthSourceLabel,
          equals('Vendor API probe succeeded'),
        );
        expect(
          bundle.vendorConnectors.map((status) => status.unlockLabel),
          equals(<String?>[
            'Vendor setup waits for reachable API access',
            'Vendor setup unlocked',
          ]),
        );
        expect(
          bundle.vendorConnectors.first.detailMessage,
          startsWith('API reachability pending.'),
        );
        expect(
          bundle.vendorConnectors.last.detailMessage,
          startsWith('API reachable.'),
        );
      },
    );

    test(
      'rotateKey POSTs with Idempotency-Key header on rotate-anthropic',
      () async {
        final captured = <_CapturedAdminRequest>[];
        final client = _SingleResponseClient(
          captured: captured,
          response: _HttpFixture(
            statusCode: 200,
            body: <String, Object?>{
              'row': <String, Object?>{
                'credential_id': 'cred-1',
                'key_kind': 'anthropic',
                'masked_value': 'sk-a***1234',
                'kms_secret_name': 'kms://stub/cred-1',
                'created_by': 'actor-x',
                'updated_by': 'actor-x',
                'rotated_at': '2026-05-02T12:00:00.000Z',
              },
              'plaintext_value': 'sk-ant-1234',
            },
          ),
        );
        final gateway = HttpIntegrationAdminGateway(
          baseUri: Uri.parse('https://proxy.example.com'),
          bearerTokenProvider: () async => 'fake.token',
          httpClient: client,
        );
        await gateway.rotateKey(
          const RotateKeyCommand(
            keyKind: ProviderKeyKind.anthropic,
            plaintextValue: 'sk-ant-1234',
            idempotencyKey: 'idem-http-rotate',
          ),
        );
        final req = captured.single;
        expect(req.method, equals('POST'));
        expect(req.uri.path, equals('/v1/admin/integrations/rotate-anthropic'));
        expect(
          req.headers['idempotency-key'] ?? req.headers['Idempotency-Key'],
          equals('idem-http-rotate'),
        );
        // Plaintext belongs in the body; the idempotency key does NOT.
        expect(req.body['plaintext_value'], equals('sk-ant-1234'));
        expect(req.body.containsKey('idempotency_key'), isFalse);
      },
    );
  });
}

// ─── Test helpers ─────────────────────────────────────────────────

class _CapturedAdminRequest {
  _CapturedAdminRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
  });
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

class _HttpFixture {
  _HttpFixture({required this.statusCode, required this.body});
  final int statusCode;
  final Map<String, Object?> body;
}

class _SingleResponseClient extends http.BaseClient {
  _SingleResponseClient({required this.captured, required this.response});

  final List<_CapturedAdminRequest> captured;
  final _HttpFixture response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    Map<String, Object?> body = const <String, Object?>{};
    if (bodyBytes.isNotEmpty) {
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is Map) body = decoded.cast<String, Object?>();
    }
    captured.add(
      _CapturedAdminRequest(
        method: request.method,
        uri: request.url,
        headers: Map<String, String>.from(request.headers),
        body: body,
      ),
    );
    final encoded = utf8.encode(jsonEncode(response.body));
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[encoded]),
      response.statusCode,
      contentLength: encoded.length,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}
