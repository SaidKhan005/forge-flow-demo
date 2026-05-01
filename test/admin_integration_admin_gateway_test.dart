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

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/integration_admin_models.dart';
import 'package:forge_and_flow/admin/services/integration_admin_gateway.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_stub_provider.dart';

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

    test('includes default vendor connectors and FX-rate / email status',
        () async {
      final gateway = InMemoryIntegrationAdminGateway();
      final bundle = await gateway.list();
      expect(bundle.vendorConnectors, isNotEmpty);
      expect(bundle.fxRateSource.id, equals('fx_rate'));
      expect(bundle.emailProvider.id, equals('email'));
      expect(
        bundle.emailProvider.detailMessage,
        contains('Phase 9.8'),
      );
    });
  });

  group('InMemoryIntegrationAdminGateway — rotate', () {
    test('rotate appends a new row, masks plaintext, preserves invariant',
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
        ),
      );
      // The rotation response carries plaintext ONCE.
      expect(result.plaintextValue, equals('sk-ant-thisIsTheNewPlaintext1234'));
      expect(result.row.maskedValue, equals('sk-a***1234'));
      expect(result.row.kmsSecretName, startsWith('kms://stub/'));
      expect(result.row.updatedBy, equals('rotator-x'));

      // Subsequent list calls return only the masked value.
      final bundle = await gateway.list();
      final anthropic = bundle.providerKeys
          .firstWhere((r) => r.keyKind == ProviderKeyKind.anthropic);
      expect(anthropic.maskedValue, equals('sk-a***1234'));
      expect(anthropic.maskedValue, isNot(contains('thisIsTheNew')));
    });

    test('rejects an empty plaintext_value at the gateway boundary',
        () async {
      final gateway = InMemoryIntegrationAdminGateway();
      Object? thrown;
      try {
        await gateway.rotateKey(
          const RotateKeyCommand(
            keyKind: ProviderKeyKind.voyage,
            plaintextValue: '   ',
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

    test('forced KMS failure surfaces a kms_write_failed gateway error',
        () async {
      final kms = KmsStubProvider(failNextWrite: true);
      final gateway = InMemoryIntegrationAdminGateway(kmsProvider: kms);
      Object? thrown;
      try {
        await gateway.rotateKey(
          const RotateKeyCommand(
            keyKind: ProviderKeyKind.azureDb,
            plaintextValue: 'azure-superuser-Pa55word!',
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
        bundle.providerKeys.where((r) => r.keyKind == ProviderKeyKind.azureDb),
        isEmpty,
      );
    });
  });
}
