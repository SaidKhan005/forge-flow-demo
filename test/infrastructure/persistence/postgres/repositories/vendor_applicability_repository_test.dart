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
        // The `visible` CTE now also filters on location: only
        // location-null or location-matching rows are admitted.
        expect(
          selectSql,
          contains('location_id is null or location_id = @location_id::uuid'),
        );
        expect(selectSql, contains('effective_until is null'));
        expect(selectSql, contains('row_number() over'));
        expect(
          selectSql,
          contains('partition by setting_kind, setting_key, vendor_slug'),
        );
        // 3-way precedence ranking: location-match (0) beats
        // operator-level (1) beats global (2), then effective_from desc.
        expect(
          selectSql,
          contains('when location_id = @location_id::uuid then 0'),
        );
        expect(
          selectSql,
          contains('when operator_id = @operator_id::uuid then 1'),
        );
        // Precedence-fix: the enabled filter is applied to the WINNER
        // (final `where rn = 1` step), never inside the `visible` CTE.
        // If it were in `visible`, a more-specific enabled=false row
        // would be dropped before ranking and a less-specific
        // enabled row would silently win, ignoring the block.
        expect(selectSql, contains('where rn = 1 and enabled = true'));
        final visibleCte = selectSql.substring(
          selectSql.indexOf('with visible as ('),
          selectSql.indexOf('), ranked as ('),
        );
        expect(visibleCte, isNot(contains('enabled = true')));
        // The location filter lives in `visible`, before ranking.
        expect(visibleCte, contains('location_id is null or location_id'));
        expect(tx.operations.last.parameters['operator_id'], operatorId);
        expect(tx.operations.last.parameters['location_id'], locationId);
        expect(tx.operations.last.parameters['setting_kind'], 'wage');
        expect(tx.operations.last.parameters['setting_key'], 'tip_credit');
      },
    );

    test(
      'enabledOnly: false applies no enabled filter and keeps rn = 1',
      () async {
        final pool = _RecordingPostgresPool();
        final repository = VendorApplicabilityRepository(
          TenantTransactionWrapper(pool),
        );

        await repository.listCurrentForOperator(
          operatorId: operatorId,
          locationId: locationId,
          actorUserId: adminUserId,
          settingKind: 'covers',
        );

        final selectSql = pool.transactions.single.operations.last.sql;
        expect(selectSql, contains('where rn = 1'));
        expect(selectSql, isNot(contains('enabled = true')));
      },
    );

    test('operator enabled=false hides a globally enabled vendor when '
        'enabledOnly is true (block precedence)', () async {
      final now = DateTime.utc(2026, 5, 13, 12);
      final pool = _SeededPostgresPool(<Map<String, Object?>>[
        // Global default: covers from toast is allowed everywhere.
        _vaRow(
          id: 'global-toast',
          operatorId: null,
          settingKind: 'covers',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: true,
          effectiveFrom: now,
        ),
        // Operator-specific block: this operator may NOT use toast
        // covers. With the old (broken) filter this row was dropped
        // before ranking, so the global row won and toast leaked.
        _vaRow(
          id: 'operator-toast-block',
          operatorId: operatorId,
          settingKind: 'covers',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: false,
          effectiveFrom: now.add(const Duration(hours: 1)),
        ),
      ]);
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      final rows = await repository.listCurrentForOperator(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: adminUserId,
        settingKind: 'covers',
        enabledOnly: true,
      );

      // The operator-level disabled row wins precedence and is then
      // filtered out by `enabled = true`, so toast is hidden.
      expect(rows.map((r) => r.vendorSlug), isNot(contains('toast')));
      expect(rows, isEmpty);
    });

    test('operator enabled=true overrides a globally disabled vendor when '
        'enabledOnly is true', () async {
      final now = DateTime.utc(2026, 5, 13, 12);
      final pool = _SeededPostgresPool(<Map<String, Object?>>[
        _vaRow(
          id: 'global-sevenrooms-off',
          operatorId: null,
          settingKind: 'covers',
          settingKey: 'default',
          vendorSlug: 'sevenrooms',
          enabled: false,
          effectiveFrom: now,
        ),
        _vaRow(
          id: 'operator-sevenrooms-on',
          operatorId: operatorId,
          settingKind: 'covers',
          settingKey: 'default',
          vendorSlug: 'sevenrooms',
          enabled: true,
          effectiveFrom: now.add(const Duration(hours: 1)),
        ),
      ]);
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      final rows = await repository.listCurrentForOperator(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: adminUserId,
        settingKind: 'covers',
        enabledOnly: true,
      );

      expect(rows.map((r) => r.vendorSlug), contains('sevenrooms'));
      expect(rows.single.operatorId, operatorId);
    });

    test('location-scoped row beats operator-level beats global for the '
        'same vendor', () async {
      final now = DateTime.utc(2026, 5, 13, 12);
      final pool = _SeededPostgresPool(<Map<String, Object?>>[
        // Global default.
        _vaRow(
          id: 'global-toast',
          operatorId: null,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: true,
          effectiveFrom: now,
        ),
        // Operator-level override (location null), later effective_from.
        _vaRow(
          id: 'operator-toast',
          operatorId: operatorId,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: true,
          effectiveFrom: now.add(const Duration(hours: 1)),
        ),
        // Location-specific row, EARLIER effective_from than the
        // operator-level row: precedence must still pick this row because
        // location beats operator regardless of effective_from.
        _vaRow(
          id: 'location-toast',
          operatorId: operatorId,
          locationId: locationId,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: true,
          effectiveFrom: now.subtract(const Duration(hours: 1)),
        ),
      ]);
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      final rows = await repository.listCurrentForOperator(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: adminUserId,
        settingKind: 'polling',
      );

      expect(rows, hasLength(1));
      expect(rows.single.id, 'location-toast');
      expect(rows.single.locationId, locationId);
    });

    test('operator-level beats global when no location-scoped row exists '
        'for the asked location', () async {
      final now = DateTime.utc(2026, 5, 13, 12);
      final otherLocationId = '99999999-9999-4999-8999-999999999999';
      final pool = _SeededPostgresPool(<Map<String, Object?>>[
        _vaRow(
          id: 'global-toast',
          operatorId: null,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: true,
          effectiveFrom: now,
        ),
        _vaRow(
          id: 'operator-toast',
          operatorId: operatorId,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: true,
          effectiveFrom: now.add(const Duration(hours: 1)),
        ),
        // A location-scoped row for a DIFFERENT location must be ignored
        // when reading for `locationId`.
        _vaRow(
          id: 'other-location-toast',
          operatorId: operatorId,
          locationId: otherLocationId,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: false,
          effectiveFrom: now.add(const Duration(hours: 2)),
        ),
      ]);
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      final rows = await repository.listCurrentForOperator(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: adminUserId,
        settingKind: 'polling',
      );

      expect(rows, hasLength(1));
      expect(rows.single.id, 'operator-toast');
      expect(rows.single.locationId, isNull);
    });

    test('latest effective_from wins among rows at the same precedence '
        'level (tie-break)', () async {
      final now = DateTime.utc(2026, 5, 13, 12);
      final pool = _SeededPostgresPool(<Map<String, Object?>>[
        // Two location-specific rows for the same scope/vendor; the
        // later effective_from must win the tie-break. (Both current in
        // this fake; production uniqueness forbids two current rows, but
        // the ranking still proves the order-by.)
        _vaRow(
          id: 'location-toast-older',
          operatorId: operatorId,
          locationId: locationId,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: true,
          effectiveFrom: now,
        ),
        _vaRow(
          id: 'location-toast-newer',
          operatorId: operatorId,
          locationId: locationId,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: true,
          effectiveFrom: now.add(const Duration(hours: 5)),
        ),
      ]);
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      final rows = await repository.listCurrentForOperator(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: adminUserId,
        settingKind: 'polling',
      );

      expect(rows, hasLength(1));
      expect(rows.single.id, 'location-toast-newer');
    });

    test('location-scoped enabled=false hides a vendor that an '
        'operator-level (or global) row enables', () async {
      final now = DateTime.utc(2026, 5, 13, 12);
      final pool = _SeededPostgresPool(<Map<String, Object?>>[
        // Global enables toast polling.
        _vaRow(
          id: 'global-toast',
          operatorId: null,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: true,
          effectiveFrom: now,
        ),
        // Operator-level also enables it.
        _vaRow(
          id: 'operator-toast',
          operatorId: operatorId,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: true,
          effectiveFrom: now.add(const Duration(hours: 1)),
        ),
        // Location-specific BLOCK: this location may NOT use toast.
        // Precedence picks this row; the winner-side enabled filter then
        // drops it, so toast is hidden for this location.
        _vaRow(
          id: 'location-toast-block',
          operatorId: operatorId,
          locationId: locationId,
          settingKind: 'polling',
          settingKey: 'default',
          vendorSlug: 'toast',
          enabled: false,
          effectiveFrom: now.add(const Duration(hours: 2)),
        ),
      ]);
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      final rows = await repository.listCurrentForOperator(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: adminUserId,
        settingKind: 'polling',
        enabledOnly: true,
      );

      expect(rows.map((r) => r.vendorSlug), isNot(contains('toast')));
      expect(rows, isEmpty);
    });

    test('backward compat: with only global/operator rows and a locationId '
        'passed, results match pre-location behavior', () async {
      final now = DateTime.utc(2026, 5, 13, 12);
      final pool = _SeededPostgresPool(<Map<String, Object?>>[
        // Global disables, operator enables (location_id null on both) —
        // exactly the pre-location precedence case.
        _vaRow(
          id: 'global-sevenrooms-off',
          operatorId: null,
          settingKind: 'covers',
          settingKey: 'default',
          vendorSlug: 'sevenrooms',
          enabled: false,
          effectiveFrom: now,
        ),
        _vaRow(
          id: 'operator-sevenrooms-on',
          operatorId: operatorId,
          settingKind: 'covers',
          settingKey: 'default',
          vendorSlug: 'sevenrooms',
          enabled: true,
          effectiveFrom: now.add(const Duration(hours: 1)),
        ),
      ]);
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      final rows = await repository.listCurrentForOperator(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: adminUserId,
        settingKind: 'covers',
        enabledOnly: true,
      );

      // Identical to the existing no-location precedence test: the
      // operator-level enabled row wins over the globally-disabled one.
      expect(rows.map((r) => r.vendorSlug), contains('sevenrooms'));
      expect(rows.single.operatorId, operatorId);
      expect(rows.single.locationId, isNull);
    });

    test('upsert threads location_id into the temporal close and the '
        'insert', () async {
      final pool = _RecordingPostgresPool();
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      final row = await repository.upsert(
        operatorId: operatorId,
        locationId: locationId,
        settingKind: 'polling',
        settingKey: 'default',
        vendorSlug: 'toast',
        enabled: true,
        createdBy: adminUserId,
        adminReason: 'test.vendor_applicability.upsert_location',
      );

      expect(row.locationId, locationId);
      final tx = pool.transactions.single;
      final closeOperation = tx.operations.firstWhere(
        (operation) =>
            operation.sql.contains('update public.vendor_applicability'),
      );
      // Temporal close targets the same (operator, location) scope.
      expect(
        closeOperation.sql,
        contains('location_id is not distinct from @location_id::uuid'),
      );
      expect(closeOperation.parameters['location_id'], locationId);
      final insertOperation = tx.operations.firstWhere(
        (operation) =>
            operation.sql.contains('insert into public.vendor_applicability'),
      );
      expect(insertOperation.sql, contains('location_id'));
      expect(insertOperation.parameters['location_id'], locationId);
    });

    test('end threads location_id into the temporal close', () async {
      final pool = _RecordingPostgresPool();
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      final row = await repository.end(
        operatorId: operatorId,
        locationId: locationId,
        settingKind: 'polling',
        settingKey: 'default',
        vendorSlug: 'toast',
        adminReason: 'test.vendor_applicability.end_location',
      );

      expect(row, isNotNull);
      expect(row!.locationId, locationId);
      final closeOperation = pool.transactions.single.operations.firstWhere(
        (operation) =>
            operation.sql.contains('update public.vendor_applicability'),
      );
      expect(
        closeOperation.sql,
        contains('location_id is not distinct from @location_id::uuid'),
      );
      expect(closeOperation.parameters['location_id'], locationId);
    });

    test('listAdmin filters by location_id when provided', () async {
      final pool = _RecordingPostgresPool();
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      await repository.listAdmin(
        operatorId: operatorId,
        locationId: locationId,
        adminReason: 'test.vendor_applicability.list_admin_location',
      );

      final selectSql = pool.transactions.single.operations.last.sql;
      expect(
        selectSql,
        contains('location_id is not distinct from @location_id::uuid'),
      );
      expect(
        pool.transactions.single.operations.last.parameters['location_id'],
        locationId,
      );
    });

    test('listAdmin omits the location filter when no location is given', () {
      final pool = _RecordingPostgresPool();
      final repository = VendorApplicabilityRepository(
        TenantTransactionWrapper(pool),
      );

      return repository
          .listAdmin(
            operatorId: operatorId,
            adminReason: 'test.vendor_applicability.list_admin_no_location',
          )
          .then((_) {
            final selectSql = pool.transactions.single.operations.last.sql;
            expect(
              selectSql,
              isNot(
                contains('location_id is not distinct from @location_id::uuid'),
              ),
            );
          });
    });

    test('VendorApplicabilityRow round-trips location_id through fromRow '
        'and toJson', () {
      final now = DateTime.utc(2026, 5, 13, 17);
      final row = VendorApplicabilityRow.fromRow(<String, Object?>{
        'id': '44444444-4444-4444-8444-444444444444',
        'operator_id': operatorId,
        'location_id': locationId,
        'setting_kind': 'polling',
        'setting_key': 'default',
        'vendor_slug': 'toast',
        'enabled': true,
        'metadata': '{}',
        'effective_from': now,
        'effective_until': null,
        'created_at': now,
        'created_by': adminUserId,
      });

      expect(row.locationId, locationId);
      expect(row.toJson()['location_id'], locationId);

      // A null location_id (operator-level / global row) round-trips too.
      final nullLocationRow = VendorApplicabilityRow.fromRow(<String, Object?>{
        'id': '44444444-4444-4444-8444-444444444444',
        'operator_id': operatorId,
        'location_id': null,
        'setting_kind': 'polling',
        'setting_key': 'default',
        'vendor_slug': 'toast',
        'enabled': true,
        'metadata': '{}',
        'effective_from': now,
        'effective_until': null,
        'created_at': now,
        'created_by': adminUserId,
      });
      expect(nullLocationRow.locationId, isNull);
      expect(nullLocationRow.toJson().containsKey('location_id'), isTrue);
      expect(nullLocationRow.toJson()['location_id'], isNull);
    });

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
      'location_id': parameters['location_id'],
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

/// Builds a seeded `vendor_applicability` row map for [_SeededPostgresPool].
/// `operatorId == null` models a global default row; `locationId == null`
/// models an operator-level (or global) row.
Map<String, Object?> _vaRow({
  required String id,
  required String? operatorId,
  required String settingKind,
  required String settingKey,
  required String vendorSlug,
  required bool enabled,
  required DateTime effectiveFrom,
  String? locationId,
  DateTime? effectiveUntil,
}) {
  return <String, Object?>{
    'id': id,
    'operator_id': operatorId,
    'location_id': locationId,
    'setting_kind': settingKind,
    'setting_key': settingKey,
    'vendor_slug': vendorSlug,
    'enabled': enabled,
    'metadata': '{}',
    'effective_from': effectiveFrom,
    'effective_until': effectiveUntil,
    'created_at': effectiveFrom,
    'created_by': '11111111-1111-4111-8111-111111111111',
  };
}

/// Pool that backs [listCurrentForOperator] with an in-memory table so
/// the precedence + winner-side enabled filter can be proven
/// behaviorally (the [_RecordingPostgresPool] only records SQL and
/// cannot return query-shaped rows). The transaction evaluates the
/// exact ranking the repository SQL expresses: filter to visible rows,
/// rank operator-specific-then-latest, keep `rn = 1`, then drop
/// non-enabled winners only when the SQL carries the winner-side
/// `enabled = true` predicate.
class _SeededPostgresPool implements PostgresPool {
  _SeededPostgresPool(this.rows);

  final List<Map<String, Object?>> rows;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _SeededPostgresTransaction(rows);
  }
}

class _SeededPostgresTransaction implements PostgresTransaction {
  _SeededPostgresTransaction(this.rows);

  final List<Map<String, Object?>> rows;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    // SET LOCAL / set_config probes and any non-select return no rows.
    if (!sql.contains('from ranked')) return const <PostgresRow>[];

    final operatorId = parameters['operator_id'] as String?;
    final locationId = parameters['location_id'] as String?;
    final settingKind = parameters['setting_kind'] as String?;
    final settingKey = parameters['setting_key'] as String?;

    // `visible` CTE predicate: admit global (operator_id null),
    // operator-level (operator_id match, location_id null), and
    // location-specific (operator_id match, location_id match) rows;
    // exclude rows scoped to a different location.
    final visible = rows.where((row) {
      final rowOperator = row['operator_id'] as String?;
      if (!(rowOperator == null || rowOperator == operatorId)) return false;
      final rowLocation = row['location_id'] as String?;
      if (!(rowLocation == null || rowLocation == locationId)) return false;
      if (settingKind != null && row['setting_kind'] != settingKind) {
        return false;
      }
      if (row['effective_until'] != null) return false;
      if (settingKey != null && row['setting_key'] != settingKey) return false;
      return true;
    }).toList();

    // Partition by (setting_kind, setting_key, vendor_slug); rank by the
    // 3-way precedence case (location-match 0, operator-level 1, global
    // 2), then latest effective_from; keep rn = 1.
    final byKey = <String, List<Map<String, Object?>>>{};
    for (final row in visible) {
      final key =
          '${row['setting_kind']}|${row['setting_key']}|${row['vendor_slug']}';
      (byKey[key] ??= <Map<String, Object?>>[]).add(row);
    }
    int precedence(Map<String, Object?> row) {
      if ((row['location_id'] as String?) == locationId) return 0;
      if ((row['operator_id'] as String?) == operatorId) return 1;
      return 2;
    }

    final winners = <Map<String, Object?>>[];
    for (final group in byKey.values) {
      group.sort((a, b) {
        final aSpecific = precedence(a);
        final bSpecific = precedence(b);
        if (aSpecific != bSpecific) return aSpecific.compareTo(bSpecific);
        final aFrom = a['effective_from'] as DateTime;
        final bFrom = b['effective_from'] as DateTime;
        return bFrom.compareTo(aFrom); // effective_from desc
      });
      winners.add(group.first);
    }

    // Winner-side `enabled = true` filter (only when SQL carries it).
    final enabledOnly = sql.contains('and enabled = true');
    final result =
        winners.where((row) => !enabledOnly || row['enabled'] == true).toList()
          ..sort((a, b) {
            final keyCmp = (a['setting_key'] as String).compareTo(
              b['setting_key'] as String,
            );
            if (keyCmp != 0) return keyCmp;
            return (a['vendor_slug'] as String).compareTo(
              b['vendor_slug'] as String,
            );
          });
    return result.map((row) => Map<String, Object?>.from(row)).toList();
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}
