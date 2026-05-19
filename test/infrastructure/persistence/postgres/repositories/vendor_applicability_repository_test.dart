import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/vendor_applicability_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

void main() {
  const adminUserId = '11111111-1111-4111-8111-111111111111';
  const operatorId = '22222222-2222-4222-8222-222222222222';
  const locationId = '33333333-3333-4333-8333-333333333333';
  final effectiveFrom = DateTime.utc(2026, 5, 13, 15);
  final effectiveUntil = DateTime.utc(2026, 5, 14, 16);

  group('VendorApplicabilityRepository', () {
    test(
      'upsert closes current row then inserts and runs callback in one tx',
      () async {
        final pool = _RecordingPostgresPool();
        final repository = VendorApplicabilityRepository(
          TenantTransactionWrapper(pool),
        );

        final row = await repository.upsert(
          settingKind: 'wage',
          settingKey: 'tip_credit',
          vendorSlug: 'toast',
          enabled: true,
          metadata: const <String, Object?>{'authority_basis': 'job_code'},
          effectiveFrom: effectiveFrom,
          createdBy: adminUserId,
          adminReason: 'test.vendor_applicability.upsert',
          onCommit: (exec, row) async {
            await exec.query(
              'insert into auth_events_audit (event_type) '
              'values (@event_type) returning event_id',
              parameters: const <String, Object?>{
                'event_type': 'vendor_applicability.upsert',
              },
            );
          },
        );

        expect(row.settingKind, 'wage');
        expect(row.settingKey, 'tip_credit');
        expect(row.vendorSlug, 'toast');
        expect(row.metadata['authority_basis'], 'job_code');
        final tx = pool.transactions.single;
        expect(tx.committed, isTrue);
        expect(tx.rolledBack, isFalse);
        expect(
          tx.operations.map((operation) => operation.kind),
          containsAllInOrder(<String>['execute', 'query', 'query']),
        );
        final closeOperation = tx.operations.firstWhere(
          (operation) =>
              operation.sql.contains('update public.vendor_applicability'),
        );
        expect(closeOperation.parameters['effective_until'], effectiveFrom);
        final insertIndex = tx.operations.indexWhere(
          (operation) =>
              operation.sql.contains('insert into public.vendor_applicability'),
        );
        final auditIndex = tx.operations.indexWhere(
          (operation) =>
              operation.sql.contains('insert into auth_events_audit'),
        );
        expect(insertIndex, greaterThan(tx.operations.indexOf(closeOperation)));
        expect(auditIndex, greaterThan(insertIndex));
      },
    );

    test('end is insert-free and returns the closed row', () async {
      final pool = _RecordingPostgresPool();
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      final row = await repository.end(
        operatorId: operatorId,
        settingKind: 'covers',
        settingKey: 'covers',
        vendorSlug: 'sevenrooms',
        effectiveUntil: effectiveUntil,
        adminReason: 'test.vendor_applicability.end',
      );

      expect(row, isNotNull);
      expect(row!.operatorId, operatorId);
      expect(row.effectiveUntil, effectiveUntil);
      final sql = pool.transactions.single.operations.map((op) => op.sql);
      expect(
        sql,
        contains(
          predicate<String>((value) {
            return value.contains('update public.vendor_applicability') &&
                value.contains('returning');
          }),
        ),
      );
      expect(
        sql.join('\n'),
        isNot(contains('insert into public.vendor_applicability')),
      );
    });

    test(
      'operator reads include global defaults and operator overrides only',
      () async {
        final pool = _RecordingPostgresPool();
        final repository = VendorApplicabilityRepository(
          TenantTransactionWrapper(pool),
        );

        await repository.listCurrentForOperator(
          operatorId: operatorId,
          locationId: locationId,
          actorUserId: adminUserId,
          settingKind: 'wage',
          settingKey: 'tip_credit',
          enabledOnly: true,
        );

        final tx = pool.transactions.single;
        expect(
          tx.operations.map((operation) => operation.sql),
          containsAll(<String>[
            "select set_config('app.operator_id', @value, true)",
            "select set_config('app.location_id', @value, true)",
            "select set_config('app.user_id', @value, true)",
            "select set_config('app.bypass_rls_audit', 'tenant', true)",
          ]),
        );
        final selectSql = tx.operations.last.sql;
        expect(
          selectSql,
          contains('operator_id is null or operator_id = @operator_id::uuid'),
        );
        expect(selectSql, contains('effective_until is null'));
        expect(selectSql, contains('enabled = true'));
        expect(selectSql, contains('row_number() over'));
        expect(
          selectSql,
          contains('partition by setting_kind, setting_key, vendor_slug'),
        );
        expect(tx.operations.last.parameters['setting_kind'], 'wage');
        expect(tx.operations.last.parameters['setting_key'], 'tip_credit');
      },
    );

    test('schema validation fails before opening a transaction', () async {
      final pool = _RecordingPostgresPool();
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      expect(
        () => repository.upsert(
          settingKind: 'wage',
          settingKey: 'tip_credit',
          vendorSlug: 'toast',
          enabled: true,
          metadata: const <String, Object?>{'eav_escape_hatch': true},
          createdBy: adminUserId,
          adminReason: 'test.vendor_applicability.invalid',
        ),
        throwsA(isA<Exception>()),
      );
      expect(pool.transactions, isEmpty);
    });

    test(
      'covers metadata accepts custom service-period keys on write',
      () async {
        final pool = _RecordingPostgresPool();
        final repository = VendorApplicabilityRepository(
          TenantTransactionWrapper(pool),
        );

        final row = await repository.upsert(
          settingKind: 'covers',
          settingKey: 'covers_source',
          vendorSlug: 'sevenrooms',
          enabled: true,
          metadata: const <String, Object?>{
            'cover_filter': 'all_covers',
            'service_periods': <String>['brunch', 'happy_hour'],
          },
          createdBy: adminUserId,
          adminReason: 'test.vendor_applicability.custom_periods',
        );

        expect(row.settingKind, 'covers');
        expect(row.metadata['service_periods'], <String>[
          'brunch',
          'happy_hour',
        ]);
        expect(pool.transactions, hasLength(1));
      },
    );

    test('covers metadata rejects malformed service-period keys pre-tx', () {
      final pool = _RecordingPostgresPool();
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      expect(
        () => repository.upsert(
          settingKind: 'covers',
          settingKey: 'covers_source',
          vendorSlug: 'sevenrooms',
          enabled: true,
          metadata: const <String, Object?>{
            'service_periods': <String>['../brunch'],
          },
          createdBy: adminUserId,
          adminReason: 'test.vendor_applicability.invalid_periods',
        ),
        throwsA(isA<Exception>()),
      );
      expect(pool.transactions, isEmpty);
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

class _SqlOperation {
  const _SqlOperation(this.kind, this.sql, this.parameters);

  final String kind;
  final String sql;
  final PostgresParameters parameters;
}

class _RecordingPostgresTransaction implements PostgresTransaction {
  final List<_SqlOperation> operations = <_SqlOperation>[];
  var committed = false;
  var rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    operations.add(_SqlOperation('query', sql, parameters));
    if (sql.contains('insert into public.vendor_applicability') ||
        (sql.contains('update public.vendor_applicability') &&
            sql.contains('returning'))) {
      return <PostgresRow>[_row(parameters)];
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
    operations.add(_SqlOperation('execute', sql, parameters));
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

  PostgresRow _row(PostgresParameters parameters) {
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
