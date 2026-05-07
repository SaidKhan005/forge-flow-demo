// Phase 11A.4c — RepositoryIntegrationAdminProxyGateway revision-restart tests.
//
// Drives the real `RepositoryIntegrationAdminProxyGateway.rotateProviderKey`
// implementation with fake collaborators (KMS, repository, audit, Cloud Run
// admin). Asserts that:
//
//   * Runtime-read lanes (anthropic / voyage / gemini) trigger one
//     `forceNewRevision` call with the expected `kms_rotation:<kind>:<id>`
//     reason and emit a `cloud_run_revision_forced` audit row.
//   * `azure_db` (NOT a runtime-read lane) skips the Cloud Run path.
//   * A Cloud Run failure is best-effort: the rotation still returns 200
//     and a `cloud_run_refresh_failed` audit row records the error.
//   * KMS write failures stop the flow before Cloud Run is touched.
//
// The gateway interface itself is NOT faked here — that would bypass the
// branch under test. We construct the production class with hand-rolled
// fakes for each collaborator.
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/cloud_run/cloud_run_admin_client.dart';
import 'package:forge_and_flow/infrastructure/kms/gcp_secret_manager_kms_provider.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_provider.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/provider_credentials_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/proxy_bootstrap.dart'
    show RepositoryIntegrationAdminProxyGateway;

void main() {
  group('RepositoryIntegrationAdminProxyGateway revision restart', () {
    const actorUserId = '00000000-0000-0000-0000-000000000001';
    const adminReason = 'phase_11a_4c_test';
    const plaintextValue = 'sk-ant-test-plaintext-1234567890';

    ({
      RepositoryIntegrationAdminProxyGateway gateway,
      _FakeProviderCredentialsRepository credentials,
      _FakeKmsProvider kms,
      _RecordingAuditRepository audit,
      _FakeCloudRunAdminClient cloudRun,
    })
    buildGateway({String credentialId = 'cred-1', String? keyKind}) {
      final credentials = _FakeProviderCredentialsRepository();
      credentials.rotateResult = ProviderCredentialRow(
        credentialId: credentialId,
        keyKind: keyKind ?? 'anthropic',
        maskedValue: 'sk-a***1234',
        kmsSecretName: 'kms://stub/$credentialId',
        createdBy: actorUserId,
        updatedBy: actorUserId,
        isActive: true,
        rotatedAt: DateTime.utc(2026, 5, 1, 12),
        createdAt: DateTime.utc(2026, 5, 1, 12),
        updatedAt: DateTime.utc(2026, 5, 1, 12),
      );
      final kms = _FakeKmsProvider();
      final audit = _RecordingAuditRepository();
      final cloudRun = _FakeCloudRunAdminClient();
      final gateway = RepositoryIntegrationAdminProxyGateway(
        providerCredentialsRepository: credentials,
        kmsProvider: kms,
        auditRepository: audit,
        cloudRunAdminClient: cloudRun,
      );
      return (
        gateway: gateway,
        credentials: credentials,
        kms: kms,
        audit: audit,
        cloudRun: cloudRun,
      );
    }

    test('listBundle projects the implemented adapter catalog', () async {
      final harness = buildGateway();
      final bundle = await harness.gateway.listBundle(
        actorUserId: actorUserId,
        adminReason: adminReason,
      );

      final vendors = (bundle['vendor_connectors'] as List)
          .cast<Map<String, Object?>>();
      expect(vendors, hasLength(17));
      expect(
        vendors.map((vendor) => vendor['id']),
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
      expect(
        vendors.firstWhere((vendor) => vendor['id'] == 'toast')['status_label'],
        equals('Documented'),
      );
      expect(
        vendors.firstWhere(
          (vendor) => vendor['id'] == 'oracle_micros_simphony',
        )['detail_message'],
        contains('poll-only'),
      );
    });

    test('rotating anthropic forces a new Cloud Run revision once with the '
        'expected reason', () async {
      final harness = buildGateway(
        credentialId: 'cred-anth-1',
        keyKind: 'anthropic',
      );
      await harness.gateway.rotateProviderKey(
        actorUserId: actorUserId,
        keyKind: 'anthropic',
        plaintextValue: plaintextValue,
        adminReason: adminReason,
      );

      expect(harness.cloudRun.calls, hasLength(1));
      expect(
        harness.cloudRun.calls.single,
        'kms_rotation:anthropic:cred-anth-1',
      );
    });

    test('rotating voyage forces a new Cloud Run revision once', () async {
      final harness = buildGateway(
        credentialId: 'cred-voy-1',
        keyKind: 'voyage',
      );
      await harness.gateway.rotateProviderKey(
        actorUserId: actorUserId,
        keyKind: 'voyage',
        plaintextValue: plaintextValue,
        adminReason: adminReason,
      );

      expect(harness.cloudRun.calls, hasLength(1));
      expect(harness.cloudRun.calls.single, 'kms_rotation:voyage:cred-voy-1');
    });

    test('rotating gemini forces a new Cloud Run revision once', () async {
      final harness = buildGateway(
        credentialId: 'cred-gem-1',
        keyKind: 'gemini',
      );
      await harness.gateway.rotateProviderKey(
        actorUserId: actorUserId,
        keyKind: 'gemini',
        plaintextValue: plaintextValue,
        adminReason: adminReason,
      );

      expect(harness.cloudRun.calls, hasLength(1));
      expect(harness.cloudRun.calls.single, 'kms_rotation:gemini:cred-gem-1');
    });

    test('rotating azure_db does NOT force a Cloud Run revision (not a '
        'runtime-read lane)', () async {
      final harness = buildGateway(
        credentialId: 'cred-azdb-1',
        keyKind: 'azure_db',
      );
      await harness.gateway.rotateProviderKey(
        actorUserId: actorUserId,
        keyKind: 'azure_db',
        plaintextValue: plaintextValue,
        adminReason: adminReason,
      );

      expect(harness.cloudRun.calls, isEmpty);
      // Sanity: rotation_success audit still landed even though the
      // Cloud Run path was skipped.
      final eventTypes = harness.audit.events
          .map((e) => e.eventType)
          .toList(growable: false);
      expect(eventTypes, contains('admin.integrations.rotation_success'));
      // Neither cloud_run audit row should have been recorded.
      expect(
        eventTypes,
        isNot(contains('admin.integrations.cloud_run_revision_forced')),
      );
      expect(
        eventTypes,
        isNot(contains('admin.integrations.cloud_run_refresh_failed')),
      );
    });

    test('rotating a runtime-read lane while its kms_real_provider_*_enabled '
        'flag is OFF (router-routed-to-stub) does NOT force a Cloud Run '
        'revision and does NOT emit cloud_run_revision_forced', () async {
      // Day 0 rollout scenario: the proxy is wired with the real
      // GCP Cloud Run admin client (env vars set), but the
      // `kms_real_provider_anthropic_enabled` flag is still false.
      // The KmsLaneRouter dispatches to KmsStubProvider, which
      // returns a `kms://stub/<uuid>` pointer. Without the
      // pointer-prefix gate this would still PATCH Cloud Run and
      // audit `cloud_run_revision_forced`, even though no Secret
      // Manager version was created.
      final harness = buildGateway(
        credentialId: 'cred-anth-stub',
        keyKind: 'anthropic',
      );
      harness.kms.secretNamePrefix = 'kms://stub/';

      await harness.gateway.rotateProviderKey(
        actorUserId: actorUserId,
        keyKind: 'anthropic',
        plaintextValue: plaintextValue,
        adminReason: adminReason,
      );

      // The KMS write succeeded against the stub provider.
      expect(harness.kms.calls, hasLength(1));

      // But Cloud Run was NOT contacted, and no
      // cloud_run_revision_forced audit row was emitted.
      expect(harness.cloudRun.calls, isEmpty);
      final eventTypes = harness.audit.events
          .map((e) => e.eventType)
          .toList(growable: false);
      expect(
        eventTypes,
        contains('admin.integrations.rotation_success'),
        reason:
            'rotation itself succeeded; only the Cloud Run '
            'restart should be skipped',
      );
      expect(
        eventTypes,
        isNot(contains('admin.integrations.cloud_run_revision_forced')),
        reason:
            'restart should be gated on a real Secret Manager '
            'pointer, not on the lane kind alone',
      );
      expect(
        eventTypes,
        isNot(contains('admin.integrations.cloud_run_refresh_failed')),
      );

      // The persisted ledger pointer reflects the stub write.
      final ledgerCalls = harness.credentials.rotateCalls;
      expect(ledgerCalls, hasLength(1));
      expect(ledgerCalls.single.kmsSecretName, startsWith('kms://stub/'));
    });

    test('Cloud Run failure does NOT roll back the rotation; a '
        'cloud_run_refresh_failed audit row is recorded', () async {
      final harness = buildGateway(
        credentialId: 'cred-anth-2',
        keyKind: 'anthropic',
      );
      harness.cloudRun.throwsOnNextCall = CloudRunAdminError(
        message: 'simulated_patch_500',
        statusCode: 500,
      );

      final response = await harness.gateway.rotateProviderKey(
        actorUserId: actorUserId,
        keyKind: 'anthropic',
        plaintextValue: plaintextValue,
        adminReason: adminReason,
      );

      // The rotation as a whole still succeeded — the response carries
      // the freshly inserted row.
      expect(response['row'], isA<Map<String, Object?>>());
      final row = response['row'] as Map<String, Object?>;
      expect(row['credential_id'], 'cred-anth-2');
      expect(row['key_kind'], 'anthropic');
      expect(row['is_active'], true);
      expect(response['plaintext_value'], plaintextValue);

      // The Cloud Run client was called once (and threw), but the
      // gateway swallowed the error and audited it.
      expect(harness.cloudRun.calls, hasLength(1));

      final failureEvents = harness.audit.events
          .where(
            (e) => e.eventType == 'admin.integrations.cloud_run_refresh_failed',
          )
          .toList(growable: false);
      expect(failureEvents, hasLength(1));
      final failurePayload = failureEvents.single.payload;
      expect(failurePayload['key_kind'], 'anthropic');
      expect(failurePayload['credential_id'], 'cred-anth-2');
      final message = failurePayload['message'];
      expect(message, isA<String>());
      expect((message as String).contains('simulated_patch_500'), isTrue);

      // No success audit row for the revision restart.
      final successEvents = harness.audit.events.where(
        (e) => e.eventType == 'admin.integrations.cloud_run_revision_forced',
      );
      expect(successEvents, isEmpty);
    });

    test(
      'KMS write failure stops the flow before Cloud Run is contacted',
      () async {
        final harness = buildGateway(
          credentialId: 'cred-anth-3',
          keyKind: 'anthropic',
        );
        harness.kms.throwsOnNextCall = const KmsWriteFailure(
          'simulated_kms_outage',
        );

        await expectLater(
          () => harness.gateway.rotateProviderKey(
            actorUserId: actorUserId,
            keyKind: 'anthropic',
            plaintextValue: plaintextValue,
            adminReason: adminReason,
          ),
          throwsA(isA<Object>()),
        );

        // The Postgres rotate must NOT have been called and Cloud Run
        // must NOT have been contacted — KMS failed first.
        expect(harness.credentials.rotateCalls, isEmpty);
        expect(harness.cloudRun.calls, isEmpty);
        // A rotation_failed row should have landed; no
        // rotation_success / cloud_run_* rows.
        final eventTypes = harness.audit.events
            .map((e) => e.eventType)
            .toList(growable: false);
        expect(eventTypes, contains('admin.integrations.rotation_failed'));
        expect(
          eventTypes,
          isNot(contains('admin.integrations.rotation_success')),
        );
        expect(
          eventTypes,
          isNot(contains('admin.integrations.cloud_run_revision_forced')),
        );
        expect(
          eventTypes,
          isNot(contains('admin.integrations.cloud_run_refresh_failed')),
        );
      },
    );

    test('successful runtime-read rotation records a cloud_run_revision_forced '
        'audit row with the operation name returned by Cloud Run', () async {
      final harness = buildGateway(
        credentialId: 'cred-voy-2',
        keyKind: 'voyage',
      );
      harness.cloudRun.nextRevisionName =
          'projects/test-proj/locations/us-east1/operations/op-rot-42';

      await harness.gateway.rotateProviderKey(
        actorUserId: actorUserId,
        keyKind: 'voyage',
        plaintextValue: plaintextValue,
        adminReason: adminReason,
      );

      final successEvents = harness.audit.events
          .where(
            (e) =>
                e.eventType == 'admin.integrations.cloud_run_revision_forced',
          )
          .toList(growable: false);
      expect(successEvents, hasLength(1));
      final payload = successEvents.single.payload;
      expect(payload['key_kind'], 'voyage');
      expect(payload['credential_id'], 'cred-voy-2');
      expect(
        payload['operation_name'],
        'projects/test-proj/locations/us-east1/operations/op-rot-42',
      );
      // The rotation_success row preceded the cloud_run_revision_forced
      // row — verifies ordering matches the production flow (rotation
      // success first, then revision restart).
      final orderedTypes = harness.audit.events
          .map((e) => e.eventType)
          .toList(growable: false);
      final successIdx = orderedTypes.indexOf(
        'admin.integrations.rotation_success',
      );
      final revisionIdx = orderedTypes.indexOf(
        'admin.integrations.cloud_run_revision_forced',
      );
      expect(successIdx, isNonNegative);
      expect(revisionIdx, isNonNegative);
      expect(successIdx, lessThan(revisionIdx));
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes — hand-rolled per the strategy in the prompt. None of them open a
// real Postgres connection; the inert pool wrapper is shared by the two
// repository subclasses so the parent constructor's signature is satisfied
// without ever exercising the wrapper at runtime.
// ---------------------------------------------------------------------------

class _UnusedPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw UnimplementedError(
      'fake repository overrides bypass the wrapper entirely',
    );
  }
}

final TenantTransactionWrapper _unusedWrapper = TenantTransactionWrapper(
  _UnusedPool(),
);

class _FakeProviderCredentialsRepository extends ProviderCredentialsRepository {
  _FakeProviderCredentialsRepository() : super(_unusedWrapper);

  ProviderCredentialRow? rotateResult;
  Object? rotateThrows;
  final List<({String keyKind, String maskedValue, String kmsSecretName})>
  rotateCalls = [];

  List<ProviderCredentialRow> listResult = const <ProviderCredentialRow>[];

  @override
  Future<ProviderCredentialRow> rotate({
    required String keyKind,
    required String maskedValue,
    required String kmsSecretName,
    required String actorUserId,
    required String adminReason,
  }) async {
    rotateCalls.add((
      keyKind: keyKind,
      maskedValue: maskedValue,
      kmsSecretName: kmsSecretName,
    ));
    final raise = rotateThrows;
    if (raise != null) throw raise;
    final template = rotateResult;
    if (template == null) {
      throw StateError('rotateResult not configured for fake repository');
    }
    // Echo the kmsSecretName + maskedValue the gateway just handed us
    // into the returned row — this is what the real repository does
    // (it persists those fields and reads them back via RETURNING).
    // Without this echo, the gateway's pointer-prefix gate (which
    // reads `row.kmsSecretName`) would test a stale value rather
    // than the actual write.
    return ProviderCredentialRow(
      credentialId: template.credentialId,
      keyKind: template.keyKind,
      maskedValue: maskedValue,
      kmsSecretName: kmsSecretName,
      createdBy: template.createdBy,
      updatedBy: template.updatedBy,
      isActive: template.isActive,
      rotatedAt: template.rotatedAt,
      createdAt: template.createdAt,
      updatedAt: template.updatedAt,
    );
  }

  @override
  Future<List<ProviderCredentialRow>> listActive({
    required String adminReason,
  }) async {
    return listResult;
  }
}

class _FakeKmsProvider implements KmsProvider {
  Object? throwsOnNextCall;
  String maskedDisplay = 'sk-a***1234';

  /// Pointer prefix returned from `writeSecret`. Defaults to the
  /// real-GCP prefix so the bulk of the integration tests cover the
  /// flag-ON / real-write path. The flag-OFF / stub-routed test
  /// flips this back to `kms://stub/` to verify the Cloud Run
  /// restart gate respects the persisted pointer.
  String secretNamePrefix = GcpSecretManagerKmsProvider.pointerPrefix;

  final List<({String logicalKeyKind, String plaintext})> calls = [];

  @override
  Future<KmsWriteResult> writeSecret({
    required String logicalKeyKind,
    required String plaintext,
  }) async {
    calls.add((logicalKeyKind: logicalKeyKind, plaintext: plaintext));
    final raise = throwsOnNextCall;
    if (raise != null) {
      throwsOnNextCall = null;
      throw raise;
    }
    return KmsWriteResult(
      secretName:
          '${secretNamePrefix}projects/p/secrets/forge-flow-'
          '${logicalKeyKind.replaceAll('_', '-')}-api-key/versions/'
          '${calls.length}',
      maskedDisplay: maskedDisplay,
    );
  }
}

class _FakeCloudRunAdminClient implements CloudRunAdminClient {
  Object? throwsOnNextCall;
  // Long-running operation name reported by Cloud Run after a
  // successful PATCH. The name format is
  // `projects/<P>/locations/<R>/operations/<op-id>`; the actual
  // revision is assigned asynchronously and resolved later via
  // `gcloud run operations describe`.
  String nextRevisionName =
      'projects/test/locations/us-east1/operations/op-test-1';

  final List<String> calls = <String>[];

  @override
  Future<String> forceNewRevision({required String reason}) async {
    calls.add(reason);
    final raise = throwsOnNextCall;
    if (raise != null) {
      throwsOnNextCall = null;
      throw raise;
    }
    return nextRevisionName;
  }
}

class _RecordingAuditRepository extends AuthEventsAuditRepository {
  _RecordingAuditRepository() : super(_unusedWrapper);

  final List<_RecordedAuditEvent> events = <_RecordedAuditEvent>[];

  @override
  Future<String> insertEvent({
    required String operatorId,
    required String locationId,
    required String eventType,
    required String actorKind,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
  }) async {
    events.add(_RecordedAuditEvent(eventType: eventType, payload: payload));
    return 'event-${events.length}';
  }

  @override
  Future<String> insertSystemEvent({
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) async {
    events.add(_RecordedAuditEvent(eventType: eventType, payload: payload));
    return 'event-${events.length}';
  }
}

class _RecordedAuditEvent {
  const _RecordedAuditEvent({required this.eventType, required this.payload});

  final String eventType;
  final Map<String, Object?> payload;
}
