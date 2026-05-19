// Phase 8.framework — RepositoryIntegrationRoutesGateway tests.
//
// Drives the production gateway with a deterministic in-memory
// PostgresPool / PostgresTransaction so we can assert:
//
//   * Permission gate: actor without `integrations.configure` → denied.
//   * Cross-tenant isolation: tenant A cannot see/modify tenant B
//     rows even with admin actor.
//   * Idempotent createConnection: 2 calls with same (operator,
//     vendor, location) → 1 row, second returns the existing
//     connection_id.
//   * Disconnect: soft-disables, writes audit row, listConnections
//     excludes disconnected rows.
//   * Decrypt failure: KMS error surfaces as typed
//     [IntegrationGatewayDecryptError], not raw exception.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/repository_integration_routes_gateway.dart';

const String _operatorA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const String _operatorB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const String _locationA = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
const String _locationB = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
const String _userA = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const String _userB = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
const String _envelopeKey = 'test-envelope-key-do-not-use-in-prod';

void main() {
  group('RepositoryIntegrationRoutesGateway permission gate', () {
    test('denies actor without integrations.configure', () async {
      final guard = InMemoryProxyAdminPermissionGuard(
        permissionEffects: const <String, PermissionEffect>{
          // Operator A's user has no allow effect → default deny.
        },
      );
      final pool = _FakePool();
      final gateway = _newGateway(pool: pool, guard: guard);

      expect(
        await gateway.hasIntegrationsConfigurePermission(
          operatorId: _operatorA,
          userId: _userA,
        ),
        isFalse,
      );
      // List route must throw PermissionDenied without ever
      // beginning a Postgres transaction.
      await expectLater(
        gateway.listForLocation(
          operatorId: _operatorA,
          locationId: _locationA,
          actorUserId: _userA,
        ),
        throwsA(isA<IntegrationGatewayPermissionDenied>()),
      );
      expect(pool.transactionsBegun, equals(0));
    });

    test('allows actor with integrations.configure', () async {
      final guard = InMemoryProxyAdminPermissionGuard(
        permissionEffects: <String, PermissionEffect>{
          '$_userA|integrations.configure': PermissionEffect.allow,
        },
      );
      final pool = _FakePool();
      final gateway = _newGateway(pool: pool, guard: guard);

      expect(
        await gateway.hasIntegrationsConfigurePermission(
          operatorId: _operatorA,
          userId: _userA,
        ),
        isTrue,
      );
      // List route runs through to the DB.
      final bundle = await gateway.listForLocation(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
      );
      expect(bundle['operator_id'], equals(_operatorA));
      expect(bundle['location_id'], equals(_locationA));
      expect(bundle['connections'], isA<List<Object?>>());
    });
  });

  group('RepositoryIntegrationRoutesGateway cross-tenant isolation', () {
    test('connect from tenant A cannot land on tenant B rows', () async {
      final guard = _allowGuardForUsers([_userA, _userB]);
      final pool = _FakePool();
      final gateway = _newGateway(pool: pool, guard: guard);

      // Tenant A connects square.
      await gateway.connectViaKeyPaste(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
        vendorId: 'square',
        apiKey: 'sq-secret-A',
      );
      // Tenant B connects square.
      await gateway.connectViaKeyPaste(
        operatorId: _operatorB,
        locationId: _locationB,
        actorUserId: _userB,
        vendorId: 'square',
        apiKey: 'sq-secret-B',
      );

      // Each transaction's tenant context is the operator that
      // initiated it: SET LOCAL app.operator_id is parameter-bound
      // exactly once per transaction.
      final tenantContexts = pool.tenantContextsObserved;
      expect(tenantContexts.length, greaterThanOrEqualTo(2));
      expect(
        tenantContexts.where((ctx) => ctx['operator_id'] == _operatorA),
        isNotEmpty,
      );
      expect(
        tenantContexts.where((ctx) => ctx['operator_id'] == _operatorB),
        isNotEmpty,
      );
      // Each connect inserts vendor_credentials + connector_connection
      // scoped to its own (operator_id, location_id). The fake's
      // table fan-out keys by operator_id; tenant A cannot have
      // written into tenant B's bucket.
      final aRows = pool.connections[_operatorA] ?? const <_FakeConnection>[];
      final bRows = pool.connections[_operatorB] ?? const <_FakeConnection>[];
      expect(aRows, hasLength(1));
      expect(bRows, hasLength(1));
      expect(aRows.single.locationId, equals(_locationA));
      expect(bRows.single.locationId, equals(_locationB));
    });

    test(
      'list from tenant A only sees tenant A connections, even with '
      'admin actor',
      () async {
        final guard = _allowGuardForUsers([_userA]);
        final pool = _FakePool()
          ..connections[_operatorA] = <_FakeConnection>[
            _FakeConnection(
              connectionId: 'a-conn-1',
              operatorId: _operatorA,
              locationId: _locationA,
              vendorId: 'square',
              category: 'pos',
              status: 'connected',
              credentialId: 'a-cred-1',
            ),
          ]
          ..connections[_operatorB] = <_FakeConnection>[
            _FakeConnection(
              connectionId: 'b-conn-1',
              operatorId: _operatorB,
              locationId: _locationB,
              vendorId: 'square',
              category: 'pos',
              status: 'connected',
              credentialId: 'b-cred-1',
            ),
          ];
        final gateway = _newGateway(pool: pool, guard: guard);

        final bundle = await gateway.listForLocation(
          operatorId: _operatorA,
          locationId: _locationA,
          actorUserId: _userA,
        );
        final connections = bundle['connections']! as List<Object?>;
        expect(connections, hasLength(1));
        expect(
          (connections.single as Map<Object?, Object?>)['connection_id'],
          equals('a-conn-1'),
        );
      },
    );
  });

  group('RepositoryIntegrationRoutesGateway idempotent connect', () {
    test('two connect calls with same key yield the same connection_id',
        () async {
      final guard = _allowGuardForUsers([_userA]);
      final pool = _FakePool();
      final gateway = _newGateway(pool: pool, guard: guard);

      final first = await gateway.connectViaKeyPaste(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
        vendorId: 'lightspeed_lsk',
        apiKey: 'first-key',
      );
      final second = await gateway.connectViaKeyPaste(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
        vendorId: 'lightspeed_lsk',
        apiKey: 'second-key',
      );

      expect(first['connection_id'], equals(second['connection_id']));
      expect(first['credential_id'], equals(second['credential_id']));
      // Exactly one row stored under (operatorA, locationA, vendor).
      expect(pool.connections[_operatorA], hasLength(1));
      // Ciphertext rotated on the second call (the fake records the
      // most recent plaintext for assertion).
      final cred = pool.credentials[_operatorA]!.single;
      expect(cred.lastAccessTokenPlaintext, equals('second-key'));
    });
  });

  group('RepositoryIntegrationRoutesGateway disconnect', () {
    test('soft-disables, writes audit row, hides from list', () async {
      final guard = _allowGuardForUsers([_userA]);
      final pool = _FakePool();
      final gateway = _newGateway(pool: pool, guard: guard);

      await gateway.connectViaKeyPaste(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
        vendorId: 'square',
        apiKey: 'sq-key',
      );

      // Pre-disconnect: list shows it.
      final preBundle = await gateway.listForLocation(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
      );
      expect(preBundle['connections'], hasLength(1));

      final auditCountBefore = pool.auditLogRows.length;
      final result = await gateway.disconnect(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
        vendorId: 'square',
        reason: 'operator_action',
      );
      expect(result['status'], equals('disconnected'));
      expect(result['already_disconnected'], isFalse);
      expect(result['disconnect_reason'], equals('operator_action'));

      // Audit row written for the disconnect state change.
      expect(pool.auditLogRows.length, greaterThan(auditCountBefore));
      final lastAudit = pool.auditLogRows.last;
      expect(lastAudit['action'], equals('integration.disconnect'));
      expect(lastAudit['operator_id'], equals(_operatorA));

      // Credential ciphertext cleared so a leak after disconnect
      // cannot reuse the vendor session.
      final cred = pool.credentials[_operatorA]!.single;
      expect(cred.accessTokenCiphertextNulled, isTrue);
      expect(cred.isActive, isFalse);

      // List no longer shows the disconnected row.
      final postBundle = await gateway.listForLocation(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
      );
      expect(postBundle['connections'], isEmpty);
    });

    test('disconnect on already-disconnected row is idempotent', () async {
      final guard = _allowGuardForUsers([_userA]);
      final pool = _FakePool()
        ..connections[_operatorA] = <_FakeConnection>[
          _FakeConnection(
            connectionId: 'conn-1',
            operatorId: _operatorA,
            locationId: _locationA,
            vendorId: 'square',
            category: 'pos',
            status: 'disconnected',
            credentialId: 'cred-1',
          ),
        ];
      final gateway = _newGateway(pool: pool, guard: guard);

      final auditCountBefore = pool.auditLogRows.length;
      final result = await gateway.disconnect(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
        vendorId: 'square',
        reason: 'operator_action',
      );
      expect(result['already_disconnected'], isTrue);
      // No audit row on the no-op path.
      expect(pool.auditLogRows.length, equals(auditCountBefore));
    });

    test('disconnect on missing connection throws NotFound', () async {
      final guard = _allowGuardForUsers([_userA]);
      final pool = _FakePool();
      final gateway = _newGateway(pool: pool, guard: guard);

      await expectLater(
        gateway.disconnect(
          operatorId: _operatorA,
          locationId: _locationA,
          actorUserId: _userA,
          vendorId: 'square',
          reason: 'operator_action',
        ),
        throwsA(isA<IntegrationGatewayNotFound>()),
      );
    });
  });

  group(
      'RepositoryIntegrationRoutesGateway rotateWebhookSigningSecret '
      '(CODE_OPS_DEBT G#2)', () {
    test(
        'persists ciphertext to webhook_signing_secret_ciphertext column, '
        'leaves access_token_ciphertext untouched, audits the rotation',
        () async {
      final guard = _allowGuardForUsers([_userA]);
      final pool = _FakePool();
      final gateway = _newGateway(pool: pool, guard: guard);

      // Connect first so a vendor_credentials row exists. Webhook
      // signing secret rotation never creates an orphan row.
      await gateway.connectViaKeyPaste(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
        vendorId: 'toast',
        apiKey: 'oauth-bearer-keep-me',
      );
      // Sanity: the bearer landed in the in-memory credential.
      final credBefore = pool.credentials[_operatorA]!.single;
      expect(credBefore.lastAccessTokenPlaintext, equals('oauth-bearer-keep-me'));
      expect(credBefore.lastWebhookSigningSecretPlaintext, isNull);

      final auditCountBefore = pool.auditLogRows.length;

      final result = await gateway.rotateWebhookSigningSecret(
        operatorId: _operatorA,
        locationId: _locationA,
        actorUserId: _userA,
        vendorId: 'toast',
        webhookSigningSecretPlaintext: 'whsec_toast_per_op_secret',
      );

      expect(result['vendor_id'], equals('toast'));
      expect(result['webhook_signing_secret_provisioned'], isTrue);

      final credAfter = pool.credentials[_operatorA]!.single;
      // Webhook signing secret landed.
      expect(
        credAfter.lastWebhookSigningSecretPlaintext,
        equals('whsec_toast_per_op_secret'),
      );
      // Critical: the OAuth bearer (used for outbound polling) is
      // NOT overwritten by the webhook secret rotation.
      expect(
        credAfter.lastAccessTokenPlaintext,
        equals('oauth-bearer-keep-me'),
        reason:
            'rotateWebhookSigningSecret must NOT touch '
            'access_token_ciphertext (HP #1: additive read-path fix)',
      );
      expect(credAfter.accessTokenCiphertextNulled, isFalse);
      expect(credAfter.isActive, isTrue);

      // Audit row carries the rotation action.
      expect(pool.auditLogRows.length, greaterThan(auditCountBefore));
      final audit = pool.auditLogRows.last;
      expect(audit['action'], equals('integration.webhook_secret_rotated'));
      expect(audit['operator_id'], equals(_operatorA));
      expect(audit['target_kind'], equals('vendor_credentials'));
    });

    test('empty plaintext rejected with Conflict', () async {
      final guard = _allowGuardForUsers([_userA]);
      final pool = _FakePool();
      final gateway = _newGateway(pool: pool, guard: guard);

      await expectLater(
        gateway.rotateWebhookSigningSecret(
          operatorId: _operatorA,
          locationId: _locationA,
          actorUserId: _userA,
          vendorId: 'toast',
          webhookSigningSecretPlaintext: '   ',
        ),
        throwsA(isA<IntegrationGatewayConflict>()),
      );
    });

    test('no active credential row → NotFound (operator must connect first)',
        () async {
      final guard = _allowGuardForUsers([_userA]);
      final pool = _FakePool();
      final gateway = _newGateway(pool: pool, guard: guard);

      await expectLater(
        gateway.rotateWebhookSigningSecret(
          operatorId: _operatorA,
          locationId: _locationA,
          actorUserId: _userA,
          vendorId: 'toast',
          webhookSigningSecretPlaintext: 'whsec_xyz',
        ),
        throwsA(isA<IntegrationGatewayNotFound>()),
      );
    });

    test('actor without integrations.configure denied', () async {
      // Empty allow list — actor is not entitled.
      final guard = _allowGuardForUsers(<String>[]);
      final pool = _FakePool();
      final gateway = _newGateway(pool: pool, guard: guard);

      await expectLater(
        gateway.rotateWebhookSigningSecret(
          operatorId: _operatorA,
          locationId: _locationA,
          actorUserId: _userA,
          vendorId: 'toast',
          webhookSigningSecretPlaintext: 'whsec_xyz',
        ),
        throwsA(isA<IntegrationGatewayPermissionDenied>()),
      );
    });
  });

  group('RepositoryIntegrationRoutesGateway test-connection decrypt', () {
    test('KMS / pgcrypto decrypt failure surfaces as typed error', () async {
      final guard = _allowGuardForUsers([_userA]);
      final pool = _FakePool(simulateDecryptError: true)
        ..connections[_operatorA] = <_FakeConnection>[
          _FakeConnection(
            connectionId: 'conn-1',
            operatorId: _operatorA,
            locationId: _locationA,
            vendorId: 'square',
            category: 'pos',
            status: 'connected',
            credentialId: 'cred-1',
          ),
        ]
        ..credentials[_operatorA] = <_FakeCredential>[
          _FakeCredential(
            credentialId: 'cred-1',
            operatorId: _operatorA,
            locationId: _locationA,
            vendorId: 'square',
            isActive: true,
          ),
        ];
      final gateway = _newGateway(
        pool: pool,
        guard: guard,
        testConnectionExecutor: _NeverTestConnectionExecutor(),
      );

      await expectLater(
        gateway.testConnection(
          operatorId: _operatorA,
          locationId: _locationA,
          actorUserId: _userA,
          vendorId: 'square',
        ),
        throwsA(isA<IntegrationGatewayDecryptError>()),
      );
    });

    test('test-connection without executor wired returns Unavailable',
        () async {
      final guard = _allowGuardForUsers([_userA]);
      final pool = _FakePool();
      final gateway = _newGateway(
        pool: pool,
        guard: guard,
        // Intentionally no testConnectionExecutor: this asserts the
        // 503 behavior bootstrap depends on.
      );

      await expectLater(
        gateway.testConnection(
          operatorId: _operatorA,
          locationId: _locationA,
          actorUserId: _userA,
          vendorId: 'square',
        ),
        throwsA(isA<IntegrationGatewayUnavailable>()),
      );
    });
  });
}

// ─── Helpers ─────────────────────────────────────────────────────────

RepositoryIntegrationRoutesGateway _newGateway({
  required _FakePool pool,
  required ProxyAdminPermissionGuard guard,
  VendorTestConnectionExecutor? testConnectionExecutor,
}) {
  final wrapper = TenantTransactionWrapper(pool);
  return RepositoryIntegrationRoutesGateway(
    tenantWrapper: wrapper,
    permissionGuard: guard,
    credentialEnvelopeKey: _envelopeKey,
    testConnectionExecutor: testConnectionExecutor,
    keyPasteCategoryResolver: (vendorId) => IntegrationCategory.pos,
    now: () => DateTime.utc(2026, 5, 6, 12, 0, 0),
  );
}

ProxyAdminPermissionGuard _allowGuardForUsers(List<String> userIds) {
  final effects = <String, PermissionEffect>{};
  for (final uid in userIds) {
    effects['$uid|integrations.configure'] = PermissionEffect.allow;
  }
  return InMemoryProxyAdminPermissionGuard(permissionEffects: effects);
}

// ─── Fake pool / transaction ─────────────────────────────────────────
//
// The fake services every SQL the gateway issues. It is **not** a
// generic Postgres simulator; each branch is keyed by a substring of
// the SQL the gateway emits in this slice. The asserted invariants
// are:
//
//   1. Tenant SET LOCAL flows through the parameterized
//      `select set_config(...)` path: the wrapper passes the value
//      via `parameters: {value: ...}`, never via string concat.
//      We capture the SET LOCAL parameters per transaction.
//   2. The fake never returns rows belonging to one operator when
//      the SET LOCAL bound a different operator: cross-tenant
//      isolation is structurally enforced by the in-memory
//      bucketing.

class _FakePool implements PostgresPool {
  _FakePool({this.simulateDecryptError = false});

  final bool simulateDecryptError;
  int transactionsBegun = 0;
  final List<Map<String, String?>> tenantContextsObserved =
      <Map<String, String?>>[];
  // operator_id → rows
  final Map<String, List<_FakeConnection>> connections =
      <String, List<_FakeConnection>>{};
  final Map<String, List<_FakeCredential>> credentials =
      <String, List<_FakeCredential>>{};
  final List<Map<String, Object?>> auditLogRows = <Map<String, Object?>>[];
  final List<Map<String, Object?>> syncLogRows = <Map<String, Object?>>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    transactionsBegun += 1;
    return _FakeTransaction(this);
  }
}

class _FakeTransaction implements PostgresTransaction {
  _FakeTransaction(this.pool);

  final _FakePool pool;
  String? operatorId;
  String? locationId;
  String? userId;
  bool finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains("set_config('app.operator_id'")) {
      operatorId = parameters['value'] as String?;
      return const <PostgresRow>[];
    }
    if (sql.contains("set_config('app.location_id'")) {
      locationId = parameters['value'] as String?;
      return const <PostgresRow>[];
    }
    if (sql.contains("set_config('app.user_id'")) {
      userId = parameters['value'] as String?;
      return const <PostgresRow>[];
    }
    if (sql.contains("set_config('app.bypass_rls_audit'")) {
      // Snapshot the tenant context once we have everything.
      pool.tenantContextsObserved.add(<String, String?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'user_id': userId,
      });
      return const <PostgresRow>[];
    }
    if (sql.contains('insert into public.vendor_credentials')) {
      return _upsertCredential(parameters);
    }
    if (sql.contains('select credential_id::text as credential_id') &&
        sql.contains('from public.vendor_credentials')) {
      return _selectCredentialIdForRotation(parameters);
    }
    if (sql.contains('insert into public.connector_connection')) {
      return _upsertConnection(parameters);
    }
    if (sql.contains('select cc.connection_id::text as connection_id') &&
        sql.contains('pgp_sym_decrypt')) {
      return _selectConnectionWithDecrypt(parameters);
    }
    if (sql.contains('select cc.connection_id::text as connection_id') &&
        sql.contains('cc.credential_id::text as credential_id') &&
        !sql.contains('pgp_sym_decrypt')) {
      return _selectConnectionForDisconnect(parameters);
    }
    if (sql.contains('select connection_id::text as connection_id') &&
        sql.contains('from public.connector_connection') &&
        sql.contains('limit 1')) {
      return _selectConnectionIdOnly(parameters);
    }
    if (sql.contains('from public.connector_connection') &&
        sql.contains("status <>")) {
      return _listConnections(parameters);
    }
    if (sql.contains('from public.demo_mode_state')) {
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.connector_sync_log')) {
      return _listSyncLogs(parameters);
    }
    if (sql.contains('insert into public.audit_logs')) {
      pool.auditLogRows.add(<String, Object?>{
        'operator_id': parameters['operator_id'],
        'location_id': parameters['location_id'],
        'action': parameters['action'],
        'target_id': parameters['target_id'],
        'target_kind': parameters['target_kind'],
        'actor_user_id': parameters['actor_user_id'],
        'payload': parameters['payload'],
      });
      return const <PostgresRow>[
        <String, Object?>{'id': 'audit-1'},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.startsWith('set local role')) return 0;
    if (sql.contains("set_config('app.operator_id'")) {
      operatorId = parameters['value'] as String?;
      return 0;
    }
    if (sql.contains("set_config('app.location_id'")) {
      locationId = parameters['value'] as String?;
      return 0;
    }
    if (sql.contains("set_config('app.user_id'")) {
      userId = parameters['value'] as String?;
      return 0;
    }
    if (sql.contains("set_config('app.bypass_rls_audit'")) {
      pool.tenantContextsObserved.add(<String, String?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'user_id': userId,
      });
      return 0;
    }
    if (sql.contains('update public.connector_connection')) {
      _disconnectConnection(parameters);
      return 1;
    }
    if (sql.contains('update public.vendor_credentials') &&
        sql.contains('access_token_ciphertext = null')) {
      _wipeCredential(parameters);
      return 1;
    }
    if (sql.contains('update public.vendor_credentials') &&
        sql.contains('webhook_signing_secret_ciphertext = ') &&
        sql.contains('pgp_sym_encrypt')) {
      _rotateWebhookSigningSecret(sql, parameters);
      return 1;
    }
    if (sql.contains('insert into public.connector_sync_log')) {
      pool.syncLogRows.add(<String, Object?>{
        'operator_id': parameters['operator_id'],
        'location_id': parameters['location_id'],
        'connection_id': parameters['connection_id'],
        'reason': parameters['reason'],
      });
      return 1;
    }
    return 0;
  }

  @override
  Future<void> commit() async {
    finalized = true;
  }

  @override
  Future<void> rollback() async {
    finalized = true;
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  List<PostgresRow> _upsertCredential(PostgresParameters parameters) {
    _assertTenantBoundsMatch(parameters);
    final op = parameters['operator_id']! as String;
    final loc = parameters['location_id'] as String?;
    final vendor = parameters['vendor_id']! as String;
    final module = parameters['module'] as String?;
    final list = pool.credentials.putIfAbsent(op, () => <_FakeCredential>[]);
    final existing = list.firstWhere(
      (c) =>
          c.operatorId == op &&
          c.locationId == loc &&
          c.vendorId == vendor &&
          c.module == module,
      orElse: () => _FakeCredential.empty(),
    );
    if (existing.credentialId.isEmpty) {
      final cred = _FakeCredential(
        credentialId: 'cred-${list.length + 1}',
        operatorId: op,
        locationId: loc,
        vendorId: vendor,
        module: module,
        lastAccessTokenPlaintext: parameters['access_token_plaintext'] as String?,
        isActive: true,
      );
      list.add(cred);
      return <PostgresRow>[
        <String, Object?>{'credential_id': cred.credentialId},
      ];
    }
    existing
      ..lastAccessTokenPlaintext =
          parameters['access_token_plaintext'] as String?
      ..isActive = true
      ..accessTokenCiphertextNulled = false;
    return <PostgresRow>[
      <String, Object?>{'credential_id': existing.credentialId},
    ];
  }

  List<PostgresRow> _upsertConnection(PostgresParameters parameters) {
    _assertTenantBoundsMatch(parameters);
    final op = parameters['operator_id']! as String;
    final loc = parameters['location_id']! as String;
    final vendor = parameters['vendor_id']! as String;
    final module = parameters['module'] as String?;
    final category = parameters['category']! as String;
    final credentialId = parameters['credential_id']! as String;
    final list = pool.connections.putIfAbsent(op, () => <_FakeConnection>[]);
    final existingIndex = list.indexWhere(
      (c) =>
          c.operatorId == op &&
          c.locationId == loc &&
          c.vendorId == vendor &&
          c.module == module,
    );
    if (existingIndex == -1) {
      final conn = _FakeConnection(
        connectionId: 'conn-${list.length + 1}',
        operatorId: op,
        locationId: loc,
        vendorId: vendor,
        module: module,
        category: category,
        status: 'connected',
        credentialId: credentialId,
      );
      list.add(conn);
      return <PostgresRow>[
        <String, Object?>{
          'connection_id': conn.connectionId,
          'status': conn.status,
        },
      ];
    }
    final existing = list[existingIndex];
    existing
      ..status = 'connected'
      ..credentialId = credentialId;
    return <PostgresRow>[
      <String, Object?>{
        'connection_id': existing.connectionId,
        'status': existing.status,
      },
    ];
  }

  List<PostgresRow> _selectConnectionWithDecrypt(
    PostgresParameters parameters,
  ) {
    _assertTenantBoundsMatch(parameters);
    if (pool.simulateDecryptError) {
      // pgcrypto wrong-key path: surface as a runtime exception
      // before the gateway sees the row, so the gateway re-wraps as
      // IntegrationGatewayDecryptError.
      throw _FakeDecryptError(
        'ERROR: Wrong key or corrupt data',
      );
    }
    final op = parameters['operator_id']! as String;
    final loc = parameters['location_id']! as String;
    final vendor = parameters['vendor_id']! as String;
    final list = pool.connections[op] ?? const <_FakeConnection>[];
    final conn = list.firstWhere(
      (c) =>
          c.operatorId == op &&
          c.locationId == loc &&
          c.vendorId == vendor,
      orElse: () => _FakeConnection.empty(),
    );
    if (conn.connectionId.isEmpty) return const <PostgresRow>[];
    return <PostgresRow>[
      <String, Object?>{
        'connection_id': conn.connectionId,
        'credential_id': conn.credentialId,
        'status': conn.status,
        'access_token_plaintext': 'decrypted-token',
      },
    ];
  }

  List<PostgresRow> _selectConnectionForDisconnect(
    PostgresParameters parameters,
  ) {
    _assertTenantBoundsMatch(parameters);
    final op = parameters['operator_id']! as String;
    final loc = parameters['location_id']! as String;
    final vendor = parameters['vendor_id']! as String;
    final list = pool.connections[op] ?? const <_FakeConnection>[];
    final conn = list.firstWhere(
      (c) =>
          c.operatorId == op &&
          c.locationId == loc &&
          c.vendorId == vendor,
      orElse: () => _FakeConnection.empty(),
    );
    if (conn.connectionId.isEmpty) return const <PostgresRow>[];
    return <PostgresRow>[
      <String, Object?>{
        'connection_id': conn.connectionId,
        'credential_id': conn.credentialId,
        'status': conn.status,
        'module': conn.module,
      },
    ];
  }

  List<PostgresRow> _selectConnectionIdOnly(PostgresParameters parameters) {
    _assertTenantBoundsMatch(parameters);
    final op = parameters['operator_id']! as String;
    final loc = parameters['location_id']! as String;
    final vendor = parameters['vendor_id']! as String;
    final list = pool.connections[op] ?? const <_FakeConnection>[];
    final conn = list.firstWhere(
      (c) =>
          c.operatorId == op &&
          c.locationId == loc &&
          c.vendorId == vendor,
      orElse: () => _FakeConnection.empty(),
    );
    if (conn.connectionId.isEmpty) return const <PostgresRow>[];
    return <PostgresRow>[
      <String, Object?>{'connection_id': conn.connectionId},
    ];
  }

  List<PostgresRow> _listConnections(PostgresParameters parameters) {
    _assertTenantBoundsMatch(parameters);
    final op = parameters['operator_id']! as String;
    final loc = parameters['location_id']! as String;
    final list = pool.connections[op] ?? const <_FakeConnection>[];
    return list
        .where((c) => c.locationId == loc && c.status != 'disconnected')
        .map((c) => <String, Object?>{
              'connection_id': c.connectionId,
              'vendor_id': c.vendorId,
              'category': c.category,
              'status': c.status,
              'module': c.module,
              'metadata': '{}',
              'last_sync_at': null,
              'last_error_at': null,
              'last_error_message': null,
              'webhook_url_provisioned': false,
              'disconnect_reason': null,
              'credential_id': c.credentialId,
              'created_at': null,
              'updated_at': null,
            })
        .toList(growable: false);
  }

  List<PostgresRow> _listSyncLogs(PostgresParameters parameters) {
    _assertTenantBoundsMatch(parameters);
    return const <PostgresRow>[];
  }

  void _disconnectConnection(PostgresParameters parameters) {
    final connectionId = parameters['connection_id']! as String;
    for (final list in pool.connections.values) {
      for (final conn in list) {
        if (conn.connectionId == connectionId) {
          conn.status = 'disconnected';
        }
      }
    }
  }

  void _wipeCredential(PostgresParameters parameters) {
    final credentialId = parameters['credential_id']! as String;
    for (final list in pool.credentials.values) {
      for (final cred in list) {
        if (cred.credentialId == credentialId) {
          cred
            ..accessTokenCiphertextNulled = true
            ..webhookSigningSecretCiphertextNulled = true
            ..isActive = false;
        }
      }
    }
  }

  /// Returns the active credential row for a (operator, location,
  /// vendor, module) tuple — the lookup `rotateWebhookSigningSecret`
  /// runs before issuing the UPDATE.
  List<PostgresRow> _selectCredentialIdForRotation(
    PostgresParameters parameters,
  ) {
    _assertTenantBoundsMatch(parameters);
    final op = parameters['operator_id']! as String;
    final loc = parameters['location_id'] as String?;
    final vendor = parameters['vendor_id']! as String;
    final module = parameters['module'] as String?;
    final list = pool.credentials[op] ?? const <_FakeCredential>[];
    final cred = list.firstWhere(
      (c) =>
          c.operatorId == op &&
          (c.locationId == null || c.locationId == loc) &&
          c.vendorId == vendor &&
          (c.module ?? '') == (module ?? '') &&
          c.isActive,
      orElse: () => _FakeCredential.empty(),
    );
    if (cred.credentialId.isEmpty) return const <PostgresRow>[];
    return <PostgresRow>[
      <String, Object?>{'credential_id': cred.credentialId},
    ];
  }

  void _rotateWebhookSigningSecret(
    String sql,
    PostgresParameters parameters,
  ) {
    final credentialId = parameters['credential_id']! as String;
    final plaintext = parameters['plaintext']! as String;
    // The UPDATE must touch ONLY the webhook signing secret column —
    // not the access_token_ciphertext (HP #1: read-path fix is
    // additive). Defense-in-depth assertion lives in the test, but
    // we record what landed for the test to inspect.
    for (final list in pool.credentials.values) {
      for (final cred in list) {
        if (cred.credentialId == credentialId) {
          cred
            ..lastWebhookSigningSecretPlaintext = plaintext
            ..webhookSigningSecretCiphertextNulled = false;
        }
      }
    }
  }

  /// Defense-in-depth check: every query the gateway emits passes
  /// `operator_id` and `location_id` as parameters; they MUST match
  /// the tenant context the wrapper bound via SET LOCAL. This is
  /// the structural assertion that backs cross-tenant isolation.
  void _assertTenantBoundsMatch(PostgresParameters parameters) {
    final paramOp = parameters['operator_id'];
    if (paramOp != null && operatorId != null && paramOp != operatorId) {
      throw StateError(
        'Tenant context mismatch: SET LOCAL bound operator $operatorId '
        'but query parameter is $paramOp. The repository pattern '
        '(primary defense) is the only writer of these parameters; a '
        'mismatch indicates a cross-tenant leak.',
      );
    }
    final paramLoc = parameters['location_id'];
    if (paramLoc != null && locationId != null && paramLoc != locationId) {
      throw StateError(
        'Tenant context mismatch: SET LOCAL bound location $locationId '
        'but query parameter is $paramLoc.',
      );
    }
  }
}

class _FakeConnection {
  _FakeConnection({
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.category,
    required this.status,
    required this.credentialId,
    this.module,
  });

  factory _FakeConnection.empty() => _FakeConnection(
        connectionId: '',
        operatorId: '',
        locationId: '',
        vendorId: '',
        category: '',
        status: '',
        credentialId: '',
      );

  final String connectionId;
  final String operatorId;
  final String locationId;
  final String vendorId;
  final String category;
  String status;
  String credentialId;
  final String? module;
}

class _FakeCredential {
  _FakeCredential({
    required this.credentialId,
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    this.module,
    this.lastAccessTokenPlaintext,
    this.isActive = true,
  })  : accessTokenCiphertextNulled = false,
        webhookSigningSecretCiphertextNulled = true;

  factory _FakeCredential.empty() => _FakeCredential(
        credentialId: '',
        operatorId: '',
        locationId: '',
        vendorId: '',
      );

  final String credentialId;
  final String operatorId;
  final String? locationId;
  final String vendorId;
  final String? module;
  String? lastAccessTokenPlaintext;
  String? lastWebhookSigningSecretPlaintext;
  bool isActive;
  bool accessTokenCiphertextNulled;
  bool webhookSigningSecretCiphertextNulled;
}

class _FakeDecryptError implements Exception {
  _FakeDecryptError(this.message);
  final String message;

  @override
  String toString() => 'pgcrypto: $message';
}

class _NeverTestConnectionExecutor implements VendorTestConnectionExecutor {
  @override
  Future<TestConnectionResult> run({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String credentialId,
    required String accessTokenPlaintext,
  }) async {
    throw StateError(
      'Test executor should not be reached when decrypt fails first.',
    );
  }
}
