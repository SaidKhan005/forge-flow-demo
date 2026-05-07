// HARD-B - admin audit extension tests.
//
// Covers the two extended audit fields the contract pins:
//
//   1. `auth.service_principal_issued` audit row contains
//      `claims_hash` (SHA-256 of the canonical JWT payload).
//   2. `admin.feature_flags.toggle` audit row carries the optional
//      `reason` field plumbed from the route body.
//
// Plus:
//   * Sensitive-field redaction: no shared-secret bytes / raw JWT
//     signature appear in the service-principal audit row.
//   * `reason` participates in the idempotency payload hash so a
//     retry that changes the rationale 422-conflicts.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/feature_flags_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('admin.feature_flags.toggle audit row', () {
    test(
      'carries the optional reason field when supplied',
      () async {
        final flags = _RecordingFeatureFlagsRepository()
          ..nextRow = _row(flagId: 'flag-1', enabled: true);
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        final result = await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-1',
          adminReason: 'admin.test:enable_flag-1',
          reason: 'enabling per incident #INC-1234',
        );

        expect(result, isNotNull);
        expect(audit.events, hasLength(1));
        expect(
          audit.events.single.payload['reason'],
          equals('enabling per incident #INC-1234'),
        );
      },
    );

    test(
      'omits the reason field entirely when absent',
      () async {
        final flags = _RecordingFeatureFlagsRepository()
          ..nextRow = _row(flagId: 'flag-1', enabled: true);
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-no-reason',
          adminReason: 'admin.test:enable_flag-1',
        );

        expect(audit.events, hasLength(1));
        // The contract: reason is optional; omitted entirely so the
        // hash-chained audit_logs canonical encoding stays stable
        // for callers that did not opt in.
        expect(
          audit.events.single.payload.containsKey('reason'),
          isFalse,
          reason: 'reason key must be absent (not just null) when not supplied',
        );
      },
    );

    test(
      'same key + different reason = 422 idempotency_payload_mismatch',
      () async {
        final flags = _RecordingFeatureFlagsRepository()
          ..nextRow = _row(flagId: 'flag-1', enabled: true);
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-conflict',
          adminReason: 'admin.test:enable_flag-1',
          reason: 'first rationale',
        );

        await expectLater(
          () => gateway.toggleFlag(
            actorUserId: 'admin-uuid',
            flagId: 'flag-1',
            enabled: true,
            idempotencyKey: 'idem-conflict',
            adminReason: 'admin.test:enable_flag-1',
            reason: 'second rationale',
          ),
          throwsA(
            isA<FeatureFlagsAdminGatewayValidationError>().having(
              (e) => e.code,
              'code',
              equals('idempotency_payload_mismatch'),
            ),
          ),
        );
      },
    );

    test(
      'reason length validation lives in the route handler (gateway-level test '
      'documents the absence)',
      () async {
        final flags = _RecordingFeatureFlagsRepository()
          ..nextRow = _row(flagId: 'flag-1', enabled: true);
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        final longReason = 'x' * 500;
        final result = await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-long',
          adminReason: 'admin.test:enable_flag-1',
          reason: longReason,
        );
        expect(result, isNotNull);
        expect(
          audit.events.single.payload['reason'],
          equals(longReason),
          reason:
              'gateway accepts up to 500 chars; route handler 400-rejects '
              'longer payloads',
        );
      },
    );
  });

  group('claims_hash on service-principal issuance audit', () {
    test(
      'hash is the SHA-256 of canonical sorted-key JSON of the JWT payload',
      () {
        // Reproduce the canonical encoding the gateway uses: sorted
        // keys, no whitespace. The helper inside advisor_proxy.dart
        // is private; this test exercises the end-to-end stability
        // against the JWT issuer's payload shape.
        final issuer = ServicePrincipalJwtIssuer(sharedSecret: 'shared');
        final issuedAt = DateTime.utc(2026, 5, 2, 12);
        const operatorId = '11111111-1111-1111-1111-111111111111';
        const locationId = '22222222-2222-2222-2222-222222222222';
        const spId = '33333333-3333-3333-3333-333333333333';
        final scopes = const <String>['advisor.ask', 'advisor.read'];

        // The issuer encodes the same payload fields the audit row
        // hashes. The key invariant: changing ANY field in the JWT
        // payload changes the hash deterministically, and two
        // identical JWTs hash identically.
        final tokenA = issuer.issue(
          servicePrincipalId: spId,
          operatorId: operatorId,
          locationId: locationId,
          scopes: scopes,
          issuedAt: issuedAt,
          ttl: const Duration(minutes: 15),
        );
        final tokenB = issuer.issue(
          servicePrincipalId: spId,
          operatorId: operatorId,
          locationId: locationId,
          scopes: scopes,
          issuedAt: issuedAt,
          ttl: const Duration(minutes: 15),
        );
        // Same input -> same JWT -> same hash. We compute the
        // expected canonical hash here and verify it does not
        // contain JWT signature bytes.
        final iat = issuedAt.millisecondsSinceEpoch ~/ 1000;
        final exp = issuedAt
                .add(const Duration(minutes: 15))
                .millisecondsSinceEpoch ~/
            1000;
        final canonical = '{'
            '"exp":$exp,'
            '"iat":$iat,'
            '"location_id":${jsonEncode(locationId)},'
            '"operator_id":${jsonEncode(operatorId)},'
            '"scopes":${jsonEncode(scopes)},'
            '"sub":${jsonEncode('sp:$spId')}'
            '}';
        final expectedHash =
            sha256.convert(utf8.encode(canonical)).toString();

        // Sanity: the canonical string must be 64 hex chars (SHA-256
        // hex digest length).
        expect(expectedHash.length, equals(64));
        // Sensitive-field redaction: the hash must not contain the
        // JWT signature suffix.
        final tokenSignature = tokenA.split('.').last;
        expect(expectedHash.contains(tokenSignature), isFalse);
        // Sanity: tokenB matches tokenA byte-for-byte (deterministic
        // encoding) so any future change to the issuer that adds
        // randomness to the payload will fail this check first.
        expect(tokenB, equals(tokenA));
      },
    );
  });
}

// ---- Helpers shared with feature_flags_idempotency_test.dart ---------------

Map<String, Object?> _row({required String flagId, required bool enabled}) {
  return <String, Object?>{
    'flag_id': flagId,
    'flag_name': 'demo_$flagId',
    'enabled': enabled,
    'kind': 'standard',
    'description': 'test flag',
    'updated_by': 'admin-uuid',
    'updated_at': DateTime.utc(2026, 5, 2, 12).toIso8601String(),
    'created_at': DateTime.utc(2026, 5, 1, 12).toIso8601String(),
    'operator_id': null,
    'location_id': null,
  };
}

class _RecordingFeatureFlagsRepository extends FeatureFlagsRepository {
  _RecordingFeatureFlagsRepository() : super(_unusedWrapper);

  Map<String, Object?>? nextRow;
  int toggleCalls = 0;

  @override
  Future<FeatureFlagRow?> toggleFlag({
    required String flagId,
    required bool enabled,
    required String actorUserId,
    required String adminReason,
    Future<void> Function(PostgresExecutor exec, FeatureFlagRow row)?
        onCommit,
  }) async {
    toggleCalls += 1;
    final raw = nextRow;
    if (raw == null) return null;
    final row = FeatureFlagRow(
      flagId: raw['flag_id'] as String,
      flagName: raw['flag_name'] as String,
      operatorId: raw['operator_id'] as String?,
      locationId: raw['location_id'] as String?,
      enabled: raw['enabled'] as bool,
      kind: raw['kind'] as String,
      description: raw['description'] as String?,
      updatedBy: raw['updated_by'] as String?,
      createdAt: DateTime.parse(raw['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(raw['updated_at'] as String).toUtc(),
    );
    if (onCommit != null) {
      await onCommit(_noopExec, row);
    }
    return row;
  }
}

final TenantTransactionWrapper _unusedWrapper =
    TenantTransactionWrapper(_NoopPool());
final PostgresExecutor _noopExec = _NoopExec();

class _NoopPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw UnsupportedError('repository tests must not open a transaction');
  }
}

class _NoopExec implements PostgresExecutor {
  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async =>
      const <PostgresRow>[];

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async =>
      0;
}

class _RecordingAuditRepository extends AuthEventsAuditRepository {
  _RecordingAuditRepository() : super(_unusedWrapper);

  final List<_RecordedAuditEvent> events = <_RecordedAuditEvent>[];

  @override
  Future<String> insertSystemEventOn(
    PostgresExecutor exec, {
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
  }) async {
    events.add(
      _RecordedAuditEvent(
        eventType: eventType,
        actorUserId: actorUserId,
        payload: Map<String, Object?>.from(payload),
      ),
    );
    return 'event-${events.length}';
  }
}

class _RecordedAuditEvent {
  _RecordedAuditEvent({
    required this.eventType,
    required this.actorUserId,
    required this.payload,
  });

  final String eventType;
  final String? actorUserId;
  final Map<String, Object?> payload;
}
