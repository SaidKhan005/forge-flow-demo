import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/vendor_applicability_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  const adminUserId = '11111111-1111-4111-8111-111111111111';

  group('RepositoryVendorApplicabilityProxyGateway', () {
    test('upsert and end append vendor_applicability audit events', () async {
      final pool = _RecordingPostgresPool();
      final wrapper = TenantTransactionWrapper(pool);
      final gateway = RepositoryVendorApplicabilityProxyGateway(
        repository: VendorApplicabilityRepository(wrapper),
        auditRepository: AuthEventsAuditRepository(wrapper),
      );

      final upserted = await gateway.upsert(
        actorUserId: adminUserId,
        settingKind: 'wage',
        settingKey: 'tip_credit',
        vendorSlug: 'toast',
        enabled: true,
        metadata: const <String, Object?>{'authority_basis': 'job_code'},
        reasonNote: 'launch default',
        adminReason: 'test.vendor_applicability.upsert',
      );
      final ended = await gateway.end(
        actorUserId: adminUserId,
        settingKind: 'wage',
        settingKey: 'tip_credit',
        vendorSlug: 'toast',
        reasonNote: 'retired default',
        adminReason: 'test.vendor_applicability.end',
      );

      expect(upserted['vendor_slug'], 'toast');
      expect(ended, isNotNull);
      final auditCalls = pool.transactions
          .expand((tx) => tx.queryCalls)
          .where((call) => call.sql.contains('insert into auth_events_audit'))
          .toList(growable: false);
      expect(auditCalls, hasLength(2));
      expect(
        auditCalls[0].parameters['event_type'],
        'vendor_applicability.upsert',
      );
      expect(
        auditCalls[1].parameters['event_type'],
        'vendor_applicability.end',
      );
      for (final call in auditCalls) {
        expect(call.parameters['actor_kind'], 'forge_admin');
        expect(call.parameters['actor_user_id'], adminUserId);
        final payload =
            jsonDecode(call.parameters['payload']! as String)
                as Map<String, Object?>;
        expect(payload['setting_kind'], 'wage');
        expect(payload['setting_key'], 'tip_credit');
        expect(payload['vendor_slug'], 'toast');
      }
    });

    test('upsert threads operator + location into the INSERT scope', () async {
      const operatorId = '22222222-2222-4222-8222-222222222222';
      const locationId = '33333333-3333-4333-8333-333333333333';
      final pool = _RecordingPostgresPool();
      final wrapper = TenantTransactionWrapper(pool);
      final gateway = RepositoryVendorApplicabilityProxyGateway(
        repository: VendorApplicabilityRepository(wrapper),
        auditRepository: AuthEventsAuditRepository(wrapper),
      );

      await gateway.upsert(
        actorUserId: adminUserId,
        operatorId: operatorId,
        locationId: locationId,
        settingKind: 'wage',
        settingKey: 'tip_credit',
        vendorSlug: 'toast',
        enabled: true,
        metadata: const <String, Object?>{'authority_basis': 'job_code'},
        adminReason: 'test.vendor_applicability.upsert',
      );

      final insertCall = pool.transactions
          .expand((tx) => tx.queryCalls)
          .firstWhere(
            (call) =>
                call.sql.contains('insert into public.vendor_applicability'),
          );
      expect(insertCall.parameters['operator_id'], operatorId);
      expect(insertCall.parameters['location_id'], locationId);
    });
  });
}

class _RecordingPostgresPool implements PostgresPool {
  final List<_RecordingPostgresTransaction> transactions =
      <_RecordingPostgresTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingPostgresTransaction();
    transactions.add(tx);
    return tx;
  }
}

class _SqlCall {
  const _SqlCall(this.sql, this.parameters);

  final String sql;
  final PostgresParameters parameters;
}

class _RecordingPostgresTransaction implements PostgresTransaction {
  final List<_SqlCall> queryCalls = <_SqlCall>[];
  var committed = false;
  var rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_SqlCall(sql, parameters));
    if (sql.contains('insert into public.vendor_applicability') ||
        (sql.contains('update public.vendor_applicability') &&
            sql.contains('returning'))) {
      return <PostgresRow>[_vendorRow(parameters)];
    }
    if (sql.contains('insert into auth_events_audit')) {
      return const <PostgresRow>[
        <String, Object?>{'event_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    return 1;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {
    rolledBack = true;
  }

  PostgresRow _vendorRow(PostgresParameters parameters) {
    final now = DateTime.utc(2026, 5, 13, 17);
    return <String, Object?>{
      'id': '44444444-4444-4444-8444-444444444444',
      'operator_id': parameters['operator_id'],
      'setting_kind': parameters['setting_kind'],
      'setting_key': parameters['setting_key'],
      'vendor_slug': parameters['vendor_slug'],
      'enabled': parameters['enabled'] ?? true,
      'metadata': parameters['metadata'] ?? '{}',
      'effective_from': parameters['effective_from'] ?? now,
      'effective_until': parameters['effective_until'],
      'created_at': now,
      'created_by':
          parameters['created_by'] ?? '11111111-1111-4111-8111-111111111111',
    };
  }
}
