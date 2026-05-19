// Phase 11A.1 / post-hardening P2 — canonical-path unit tests for
// OperatorsRepository.
//
// Coverage focus (CLAUDE.md "RLS performance discipline" — repository
// pattern is the primary defense, BYPASSRLS is the backup):
//
//   * Every method runs through `withSystem` (the admin escape hatch
//     that elevates to `forge_admin` for cross-tenant reads/writes).
//     Tests verify the wrapper emits both `set local role forge_admin`
//     AND the `app.bypass_rls_audit = 'system:<reason>'` audit marker
//     so any incidental read of the GUC by an audit trigger picks up
//     the reason.
//
//   * `suspended_at` lifecycle (added under 11A.1 — admin can pause an
//     operator without dropping rows). Tests pin:
//       - suspendOperator: `coalesce(suspended_at, now())` is
//         IDEMPOTENT — re-suspending a suspended operator returns the
//         row with its existing suspended_at, not now().
//       - reactivateOperator: SET suspended_at = NULL.
//
//   * `onboardOperatorAtomically` — four statements in one
//     `withSystem` transaction so a partial failure rolls back. The
//     ordering is load-bearing because of the composite-FK chain
//     `operators.primary_location_id → locations(operator_id,
//     location_id)`: the operator must insert first (no
//     primary_location_id), then the root org_unit, then the location,
//     then the operator UPDATE writes the primary_location_id pointer.
//
//   * `insertOperator` / `updateOperator` / `findById` / `listOperators`
//     parameter shape and null-row handling.
//
//   * Cross-tenant listing posture — listOperators has NO operator_id
//     predicate (the admin walks every tenant); the test verifies the
//     SQL does not accidentally filter.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operators_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _ouRoot = '33333333-3333-3333-3333-333333333333';
const String _timingProfileId = '55555555-5555-5555-5555-555555555555';

DateTime _instant(int hour) => DateTime.utc(2026, 4, 30, hour);

PostgresRow _operatorRow({
  required String operatorId,
  String businessName = 'Test Op',
  String ownerEmail = 'owner@example.com',
  String subscriptionTier = 'pro',
  String preferredCurrency = 'USD',
  String? primaryLocationId,
  DateTime? suspendedAt,
}) {
  return <String, Object?>{
    'operator_id': operatorId,
    'business_name': businessName,
    'owner_email': ownerEmail,
    'subscription_tier': subscriptionTier,
    'preferred_currency': preferredCurrency,
    'primary_location_id': primaryLocationId,
    'suspended_at': suspendedAt,
    'created_at': _instant(10),
    'updated_at': _instant(11),
  };
}

void main() {
  group('OperatorsRepository.listOperators (cross-tenant admin sweep)', () {
    test('uses withSystem (forge_admin BYPASSRLS) and the SQL has NO '
        'operator_id predicate — every operator returned, ordered by '
        'business_name', () async {
      final pool = _OperatorsPool(
        listRows: <PostgresRow>[
          _operatorRow(operatorId: _opA, businessName: 'Acme'),
          _operatorRow(operatorId: _opB, businessName: 'Zenith'),
        ],
      );
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      final rows = await repo.listOperators(
        adminReason: 'admin.operators.list',
      );
      expect(rows, hasLength(2));
      expect(rows[0].operatorId, equals(_opA));
      expect(rows[1].operatorId, equals(_opB));

      // SET LOCAL bypass marker carries the canonical "system:<reason>"
      // shape — audit triggers can identify the admin path.
      final tx = pool.transactions.single;
      final auditCfg = tx.parameters.firstWhere(
        (p) =>
            p['value'] is String &&
            (p['value']! as String).startsWith('system:'),
      );
      expect(auditCfg['value'], equals('system:admin.operators.list'));

      // forge_admin elevation runs before the SELECT.
      expect(
        tx.executedSql.where((s) => s.contains('set local role forge_admin')),
        hasLength(1),
      );
      // No tenant SET LOCAL — withSystem skips operator_id /
      // location_id GUCs.
      expect(
        tx.executedSql.where((s) => s.contains("'app.operator_id'")),
        isEmpty,
        reason:
            'withSystem must not set tenant GUCs — that would shadow '
            'BYPASSRLS and break cross-tenant queries',
      );

      // Cross-tenant SELECT shape.
      final selectSql = tx.executedSql.firstWhere(
        (s) => s.contains('from operators'),
      );
      expect(selectSql, contains('order by business_name asc'));
      expect(
        selectSql,
        isNot(contains('where')),
        reason: 'cross-tenant sweep — no operator_id filter',
      );

      expect(tx.commitCount, equals(1));
    });

    test('rejects an empty adminReason at the wrapper boundary', () async {
      final pool = _OperatorsPool(listRows: const <PostgresRow>[]);
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      Object? thrown;
      try {
        await repo.listOperators(adminReason: '   ');
      } on ArgumentError catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ArgumentError>());
      expect(
        pool.transactions,
        isEmpty,
        reason:
            'wrapper validates the audit marker before opening a tx — '
            'a blank reason cannot mint an unattributable BYPASSRLS path',
      );
    });
  });

  group('OperatorsRepository.findById', () {
    test('returns the row when present, null when missing', () async {
      final pool = _OperatorsPool(
        findByIdRows: <PostgresRow>[
          _operatorRow(operatorId: _opA, primaryLocationId: _locA),
        ],
      );
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      final row = await repo.findById(
        operatorId: _opA,
        adminReason: 'admin.operators.get',
      );
      expect(row, isNotNull);
      expect(row!.operatorId, equals(_opA));
      expect(row.primaryLocationId, equals(_locA));
    });

    test('returns null when SELECT yields no rows (404 surface)', () async {
      final pool = _OperatorsPool(findByIdRows: const <PostgresRow>[]);
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      final row = await repo.findById(
        operatorId: _opA,
        adminReason: 'admin.operators.get',
      );
      expect(row, isNull);
    });
  });

  group('OperatorsRepository.insertOperator', () {
    test('binds business_name / owner_email / subscription_tier / '
        'preferred_currency and returns the inserted row', () async {
      final pool = _OperatorsPool(
        insertedOperatorRows: <PostgresRow>[
          _operatorRow(operatorId: _opA, businessName: 'New Op'),
        ],
      );
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      final row = await repo.insertOperator(
        businessName: 'New Op',
        ownerEmail: 'new@example.com',
        subscriptionTier: 'starter',
        preferredCurrency: 'CAD',
        adminReason: 'admin.operators.create',
      );
      expect(row.operatorId, equals(_opA));
      expect(row.businessName, equals('New Op'));

      final tx = pool.transactions.single;
      final insertParams = tx.parameters.firstWhere(
        (p) => p['business_name'] == 'New Op',
      );
      expect(insertParams['owner_email'], equals('new@example.com'));
      expect(insertParams['subscription_tier'], equals('starter'));
      expect(insertParams['preferred_currency'], equals('CAD'));
    });

    test(
      'throws StateError when INSERT … RETURNING produces no rows',
      () async {
        final pool = _OperatorsPool(
          insertedOperatorRows: const <PostgresRow>[],
        );
        final repo = OperatorsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.insertOperator(
            businessName: 'X',
            ownerEmail: 'x@example.com',
            subscriptionTier: 'pro',
            preferredCurrency: 'USD',
            adminReason: 'admin.operators.create',
          ),
          throwsStateError,
        );
      },
    );
  });

  group('OperatorsRepository.updateOperator (coalesce pattern)', () {
    test('all fields null: SQL still issues UPDATE with all coalesce '
        'expressions; the row is rewritten only with `updated_at = now()` '
        '(every other column resolves back to itself)', () async {
      final pool = _OperatorsPool(
        updatedOperatorRows: <PostgresRow>[_operatorRow(operatorId: _opA)],
      );
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      final row = await repo.updateOperator(
        operatorId: _opA,
        adminReason: 'admin.operators.update',
      );
      expect(row, isNotNull);
      expect(row!.operatorId, equals(_opA));

      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.firstWhere(
        (s) => s.contains('update operators'),
      );
      expect(updateSql, contains('coalesce(@business_name, business_name)'));
      expect(updateSql, contains('coalesce(@owner_email, owner_email)'));
      expect(
        updateSql,
        contains('coalesce(@subscription_tier, subscription_tier)'),
      );
      expect(
        updateSql,
        contains('coalesce(@preferred_currency, preferred_currency)'),
      );
      expect(
        updateSql,
        contains('coalesce(@primary_location_id::uuid, primary_location_id)'),
      );
      expect(updateSql, contains('updated_at = now()'));

      final params = tx.parameters.firstWhere(
        (p) => p.containsKey('business_name'),
      );
      expect(params['business_name'], isNull);
      expect(params['owner_email'], isNull);
      expect(params['subscription_tier'], isNull);
      expect(params['preferred_currency'], isNull);
      expect(params['primary_location_id'], isNull);
    });

    test('returns null when the operator row does not exist', () async {
      final pool = _OperatorsPool(updatedOperatorRows: const <PostgresRow>[]);
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      final row = await repo.updateOperator(
        operatorId: _opA,
        adminReason: 'admin.operators.update',
      );
      expect(row, isNull);
    });
  });

  group('OperatorsRepository.suspendOperator (11A.1 — idempotent)', () {
    test('UPDATE uses `coalesce(suspended_at, now())` so re-suspending a '
        'paused operator preserves the original suspended_at', () async {
      final originallyPausedAt = _instant(8);
      final pool = _OperatorsPool(
        updatedOperatorRows: <PostgresRow>[
          _operatorRow(operatorId: _opA, suspendedAt: originallyPausedAt),
        ],
      );
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      final row = await repo.suspendOperator(
        operatorId: _opA,
        adminReason: 'admin.operators.suspend',
      );
      expect(row!.suspendedAt, equals(originallyPausedAt));

      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.firstWhere(
        (s) => s.contains('update operators'),
      );
      // The idempotency guarantee lives in the SQL: COALESCE keeps
      // the prior suspended_at if it's already set; only a NULL ->
      // now() flip mutates the column.
      expect(
        updateSql,
        contains('suspended_at = coalesce(suspended_at, now())'),
      );
    });

    test('returns null when the operator does not exist', () async {
      final pool = _OperatorsPool(updatedOperatorRows: const <PostgresRow>[]);
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      final row = await repo.suspendOperator(
        operatorId: _opA,
        adminReason: 'admin.operators.suspend',
      );
      expect(row, isNull);
    });
  });

  group('OperatorsRepository.reactivateOperator (11A.1)', () {
    test('UPDATE explicitly sets suspended_at = null (not coalesce) so '
        'a reactivation clears the column unconditionally', () async {
      final pool = _OperatorsPool(
        updatedOperatorRows: <PostgresRow>[_operatorRow(operatorId: _opA)],
      );
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      final row = await repo.reactivateOperator(
        operatorId: _opA,
        adminReason: 'admin.operators.reactivate',
      );
      expect(row, isNotNull);
      expect(row!.suspendedAt, isNull);

      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.firstWhere(
        (s) => s.contains('update operators'),
      );
      expect(updateSql, contains('suspended_at = null'));
    });
  });

  group('OperatorsRepository.onboardOperatorAtomically', () {
    test(
      'one withSystem transaction inserts operator, root org_unit, location, '
      'starter Business Timing, and primary_location_id update in the '
      'load-bearing order',
      () async {
        final pool = _OperatorsPool(
          onboardOperatorInsertRows: <PostgresRow>[
            <String, Object?>{'operator_id': _opA},
          ],
          onboardRootOrgUnitRows: <PostgresRow>[
            <String, Object?>{'id': _ouRoot},
          ],
          onboardLocationRows: <PostgresRow>[
            <String, Object?>{
              'location_id': _locA,
              'operator_id': _opA,
              'name': 'Main',
              'address': '123 Main St',
              'timezone': 'America/Toronto',
              'business_day_rollover_hour': 5,
              'created_at': _instant(10),
              'updated_at': _instant(11),
            },
          ],
          onboardFinalOperatorRows: <PostgresRow>[
            _operatorRow(operatorId: _opA, primaryLocationId: _locA),
          ],
        );
        final repo = OperatorsRepository(TenantTransactionWrapper(pool));
        final result = await repo.onboardOperatorAtomically(
          businessName: 'Onboard Co',
          ownerEmail: 'owner@onboard.example',
          subscriptionTier: 'pro',
          preferredCurrency: 'USD',
          locationName: 'Main',
          locationAddress: '123 Main St',
          locationTimezone: 'America/Toronto',
          locationRolloverHour: 5,
          adminReason: 'admin.operators.onboard',
        );
        expect(result.operator.operatorId, equals(_opA));
        expect(result.operator.primaryLocationId, equals(_locA));
        expect(result.location.locationId, equals(_locA));
        expect(result.location.timezone, equals('America/Toronto'));

        // ONE transaction, with writes in load-bearing bootstrap order.
        expect(pool.transactions, hasLength(1));
        final tx = pool.transactions.single;
        final dataStatements = tx.executedSql
            .where(
              (s) =>
                  s.contains('insert into operators') ||
                  s.contains('insert into org_units') ||
                  s.contains('insert into locations') ||
                  s.contains('insert into public.business_timing_profiles') ||
                  s.contains(
                    'insert into public.business_timing_service_periods',
                  ) ||
                  s.contains(
                    'insert into public.business_timing_audit_events',
                  ) ||
                  s.contains('update operators set'),
            )
            .toList();
        expect(dataStatements, hasLength(8));
        expect(dataStatements[0], contains('insert into operators'));
        expect(dataStatements[1], contains('insert into org_units'));
        expect(dataStatements[2], contains('insert into locations'));
        expect(
          dataStatements[3],
          contains('insert into public.business_timing_profiles'),
        );
        expect(
          dataStatements[4],
          contains('insert into public.business_timing_service_periods'),
        );
        expect(
          dataStatements[5],
          contains('insert into public.business_timing_service_periods'),
        );
        expect(
          dataStatements[6],
          contains('insert into public.business_timing_audit_events'),
        );
        expect(dataStatements[7], contains('update operators set'));
        expect(dataStatements[1], contains('regexp_replace(@business_name'));
        expect(dataStatements[2], contains('parent_org_unit_id'));
        final rootParams = tx.parameters.firstWhere(
          (p) =>
              p.containsKey('operator_id') &&
              p.containsKey('business_name') &&
              !p.containsKey('subscription_tier'),
        );
        expect(rootParams['operator_id'], equals(_opA));
        expect(rootParams['business_name'], equals('Onboard Co'));
        final locationParams = tx.parameters.firstWhere(
          (p) => p.containsKey('parent_org_unit_id') && p.containsKey('name'),
        );
        expect(locationParams['operator_id'], equals(_opA));
        expect(locationParams['parent_org_unit_id'], equals(_ouRoot));
        final timingProfileSql = dataStatements[3];
        expect(timingProfileSql, contains("scope_type"));
        expect(timingProfileSql, contains('now() at time zone'));
        expect(timingProfileSql, isNot(contains('current_date')));
        expect(timingProfileSql, isNot(contains('iana_timezone')));
        final timingProfileParams =
            tx.parameters[tx.executedSql.indexOf(timingProfileSql)];
        expect(timingProfileParams['operator_id'], equals(_opA));
        expect(timingProfileParams['scope_id'], isNull);
        expect(
          timingProfileParams['business_timezone'],
          equals('America/Toronto'),
        );
        expect(
          timingProfileParams['business_day_start_local_time'],
          equals('05:00'),
        );
        expect(timingProfileParams['week_start_day'], equals(DateTime.monday));
        expect(
          timingProfileParams['close_authority'],
          equals('vendor_finalization'),
        );
        final periodParams = tx.parameters
            .where((p) => p.containsKey('service_period_key'))
            .toList();
        expect(periodParams, hasLength(2));
        expect(periodParams[0]['service_period_key'], equals('lunch'));
        expect(periodParams[0]['sort_order'], equals(1));
        expect(
          periodParams[0]['applicable_weekdays'],
          equals(<int>[1, 2, 3, 4, 5, 6, 7]),
        );
        expect(periodParams[1]['service_period_key'], equals('dinner'));
        expect(periodParams[1]['sort_order'], equals(2));
        final auditParams = tx.parameters.firstWhere(
          (p) =>
              p['metadata']?.toString().contains(
                'admin_operator_onboarding_bootstrap',
              ) ??
              false,
        );
        expect(auditParams['profile_id'], equals(_timingProfileId));
        expect(auditParams['reason'], equals('admin.operators.onboard'));
        // Final update binds primary_location_id with operator_id.
        final finalUpdateParams = tx.parameters.firstWhere(
          (p) =>
              p.containsKey('location_id') &&
              p.containsKey('operator_id') &&
              !p.containsKey('name'),
        );
        expect(finalUpdateParams['operator_id'], equals(_opA));
        expect(finalUpdateParams['location_id'], equals(_locA));

        expect(tx.commitCount, equals(1));
      },
    );

    test('when the operator INSERT returns no rows, throws StateError and '
        'the transaction rolls back (location row never written)', () async {
      final pool = _OperatorsPool(
        onboardOperatorInsertRows: const <PostgresRow>[],
      );
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.onboardOperatorAtomically(
          businessName: 'Failing Co',
          ownerEmail: 'fail@onboard.example',
          subscriptionTier: 'pro',
          preferredCurrency: 'USD',
          locationName: 'Main',
          locationAddress: '123 Main St',
          locationTimezone: 'America/Toronto',
          locationRolloverHour: 4,
          adminReason: 'admin.operators.onboard',
        ),
        throwsStateError,
      );
      // Wrapper rolled back; no location INSERT made it to the wire.
      final tx = pool.transactions.single;
      expect(
        tx.executedSql.where((s) => s.contains('insert into locations')),
        isEmpty,
      );
      expect(tx.rollbackCount, equals(1));
    });

    test(
      'when the root org-unit INSERT returns no rows, throws StateError '
      'and the transaction rolls back (location row never written)',
      () async {
        final pool = _OperatorsPool(
          onboardOperatorInsertRows: <PostgresRow>[
            <String, Object?>{'operator_id': _opA},
          ],
          onboardRootOrgUnitRows: const <PostgresRow>[],
        );
        final repo = OperatorsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.onboardOperatorAtomically(
            businessName: 'Failing Co',
            ownerEmail: 'fail@onboard.example',
            subscriptionTier: 'pro',
            preferredCurrency: 'USD',
            locationName: 'Main',
            locationAddress: '123 Main St',
            locationTimezone: 'America/Toronto',
            locationRolloverHour: 4,
            adminReason: 'admin.operators.onboard',
          ),
          throwsStateError,
        );
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where((s) => s.contains('insert into locations')),
          isEmpty,
        );
        expect(tx.rollbackCount, equals(1));
      },
    );

    test(
      'when the location INSERT returns no rows, throws StateError and '
      'the transaction rolls back (final UPDATE never reaches the wire)',
      () async {
        final pool = _OperatorsPool(
          onboardOperatorInsertRows: <PostgresRow>[
            <String, Object?>{'operator_id': _opA},
          ],
          onboardRootOrgUnitRows: <PostgresRow>[
            <String, Object?>{'id': _ouRoot},
          ],
          onboardLocationRows: const <PostgresRow>[],
        );
        final repo = OperatorsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.onboardOperatorAtomically(
            businessName: 'Failing Co',
            ownerEmail: 'fail@onboard.example',
            subscriptionTier: 'pro',
            preferredCurrency: 'USD',
            locationName: 'Main',
            locationAddress: '123 Main St',
            locationTimezone: 'America/Toronto',
            locationRolloverHour: 4,
            adminReason: 'admin.operators.onboard',
          ),
          throwsStateError,
        );
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where((s) => s.contains('update operators set')),
          isEmpty,
          reason:
              'rollback prevents primary_location_id pointer from being '
              'set on a half-onboarded row',
        );
        expect(tx.rollbackCount, equals(1));
      },
    );

    test(
      'when the starter Business Timing profile INSERT returns no rows, '
      'throws StateError and rolls back before primary_location_id update',
      () async {
        final pool = _OperatorsPool(
          onboardOperatorInsertRows: <PostgresRow>[
            <String, Object?>{'operator_id': _opA},
          ],
          onboardRootOrgUnitRows: <PostgresRow>[
            <String, Object?>{'id': _ouRoot},
          ],
          onboardLocationRows: <PostgresRow>[
            <String, Object?>{
              'location_id': _locA,
              'operator_id': _opA,
              'name': 'Main',
              'address': '123 Main St',
              'timezone': 'America/Toronto',
              'business_day_rollover_hour': 4,
              'created_at': _instant(10),
              'updated_at': _instant(11),
            },
          ],
          failOnboardTimingProfileInsert: true,
        );
        final repo = OperatorsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.onboardOperatorAtomically(
            businessName: 'Timing Fail Co',
            ownerEmail: 'timing@onboard.example',
            subscriptionTier: 'pro',
            preferredCurrency: 'USD',
            locationName: 'Main',
            locationAddress: '123 Main St',
            locationTimezone: 'America/Toronto',
            locationRolloverHour: 4,
            adminReason: 'admin.operators.onboard',
          ),
          throwsStateError,
        );
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where((s) => s.contains('update operators set')),
          isEmpty,
          reason:
              'rollback prevents the operator from completing without '
              'canonical Business Timing',
        );
        expect(tx.rollbackCount, equals(1));
      },
    );

    test(
      'when a starter service period INSERT returns no rows, throws '
      'StateError and rolls back before primary_location_id update',
      () async {
        final pool = _OperatorsPool(
          onboardOperatorInsertRows: <PostgresRow>[
            <String, Object?>{'operator_id': _opA},
          ],
          onboardRootOrgUnitRows: <PostgresRow>[
            <String, Object?>{'id': _ouRoot},
          ],
          onboardLocationRows: <PostgresRow>[
            <String, Object?>{
              'location_id': _locA,
              'operator_id': _opA,
              'name': 'Main',
              'address': '123 Main St',
              'timezone': 'America/Toronto',
              'business_day_rollover_hour': 4,
              'created_at': _instant(10),
              'updated_at': _instant(11),
            },
          ],
          failOnboardTimingServicePeriodInsert: true,
        );
        final repo = OperatorsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.onboardOperatorAtomically(
            businessName: 'Timing Period Fail Co',
            ownerEmail: 'timing-period@onboard.example',
            subscriptionTier: 'pro',
            preferredCurrency: 'USD',
            locationName: 'Main',
            locationAddress: '123 Main St',
            locationTimezone: 'America/Toronto',
            locationRolloverHour: 4,
            adminReason: 'admin.operators.onboard',
          ),
          throwsStateError,
        );
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where((s) => s.contains('update operators set')),
          isEmpty,
          reason:
              'rollback prevents the operator from completing with a '
              'partial Business Timing service-period set',
        );
        expect(tx.rollbackCount, equals(1));
      },
    );

    test('when the final operator UPDATE returns no rows, throws '
        'StateError (the operator row vanished mid-transaction — '
        'shouldn\'t happen, but the guard surfaces the violation)', () async {
      final pool = _OperatorsPool(
        onboardOperatorInsertRows: <PostgresRow>[
          <String, Object?>{'operator_id': _opA},
        ],
        onboardRootOrgUnitRows: <PostgresRow>[
          <String, Object?>{'id': _ouRoot},
        ],
        onboardLocationRows: <PostgresRow>[
          <String, Object?>{
            'location_id': _locA,
            'operator_id': _opA,
            'name': 'Main',
            'address': '123 Main St',
            'timezone': 'America/Toronto',
            'business_day_rollover_hour': 4,
            'created_at': _instant(10),
            'updated_at': _instant(11),
          },
        ],
        onboardFinalOperatorRows: const <PostgresRow>[],
      );
      final repo = OperatorsRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.onboardOperatorAtomically(
          businessName: 'Edge Co',
          ownerEmail: 'edge@onboard.example',
          subscriptionTier: 'pro',
          preferredCurrency: 'USD',
          locationName: 'Main',
          locationAddress: '123 Main St',
          locationTimezone: 'America/Toronto',
          locationRolloverHour: 4,
          adminReason: 'admin.operators.onboard',
        ),
        throwsStateError,
      );
    });
  });
}

/// Recording fake `PostgresPool` shaped for the OperatorsRepository
/// seam. Each named row-list controls a single SQL pattern's
/// returning shape; pass an empty list to simulate "no rows" for that
/// path. The transaction tracks commit/rollback counts for the
/// onboarding-rollback assertions.
class _OperatorsPool implements PostgresPool {
  _OperatorsPool({
    this.listRows = const <PostgresRow>[],
    this.findByIdRows = const <PostgresRow>[],
    this.insertedOperatorRows = const <PostgresRow>[],
    this.updatedOperatorRows = const <PostgresRow>[],
    this.onboardOperatorInsertRows = const <PostgresRow>[],
    this.onboardRootOrgUnitRows = const <PostgresRow>[],
    this.onboardLocationRows = const <PostgresRow>[],
    this.onboardFinalOperatorRows = const <PostgresRow>[],
    this.failOnboardTimingProfileInsert = false,
    this.failOnboardTimingServicePeriodInsert = false,
  });

  final List<PostgresRow> listRows;
  final List<PostgresRow> findByIdRows;
  final List<PostgresRow> insertedOperatorRows;
  final List<PostgresRow> updatedOperatorRows;
  final List<PostgresRow> onboardOperatorInsertRows;
  final List<PostgresRow> onboardRootOrgUnitRows;
  final List<PostgresRow> onboardLocationRows;
  final List<PostgresRow> onboardFinalOperatorRows;
  final bool failOnboardTimingProfileInsert;
  final bool failOnboardTimingServicePeriodInsert;

  final List<_OperatorsTransaction> transactions = <_OperatorsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _OperatorsTransaction(
      listRows: listRows,
      findByIdRows: findByIdRows,
      insertedOperatorRows: insertedOperatorRows,
      updatedOperatorRows: updatedOperatorRows,
      onboardOperatorInsertRows: onboardOperatorInsertRows,
      onboardRootOrgUnitRows: onboardRootOrgUnitRows,
      onboardLocationRows: onboardLocationRows,
      onboardFinalOperatorRows: onboardFinalOperatorRows,
      failOnboardTimingProfileInsert: failOnboardTimingProfileInsert,
      failOnboardTimingServicePeriodInsert:
          failOnboardTimingServicePeriodInsert,
    );
    transactions.add(tx);
    return tx;
  }
}

class _OperatorsTransaction extends PostgresTransaction {
  _OperatorsTransaction({
    required this.listRows,
    required this.findByIdRows,
    required this.insertedOperatorRows,
    required this.updatedOperatorRows,
    required this.onboardOperatorInsertRows,
    required this.onboardRootOrgUnitRows,
    required this.onboardLocationRows,
    required this.onboardFinalOperatorRows,
    required this.failOnboardTimingProfileInsert,
    required this.failOnboardTimingServicePeriodInsert,
  });

  final List<PostgresRow> listRows;
  final List<PostgresRow> findByIdRows;
  final List<PostgresRow> insertedOperatorRows;
  final List<PostgresRow> updatedOperatorRows;
  final List<PostgresRow> onboardOperatorInsertRows;
  final List<PostgresRow> onboardRootOrgUnitRows;
  final List<PostgresRow> onboardLocationRows;
  final List<PostgresRow> onboardFinalOperatorRows;
  final bool failOnboardTimingProfileInsert;
  final bool failOnboardTimingServicePeriodInsert;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  int commitCount = 0;
  int rollbackCount = 0;
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);

    final isOperatorInsert = sql.contains('insert into operators');
    final isOperatorUpdate = sql.contains('update operators set');
    final isRootOrgUnitInsert = sql.contains('insert into org_units');
    final isLocationInsert = sql.contains('insert into locations');
    final isTimingProfileInsert = sql.contains(
      'insert into public.business_timing_profiles',
    );
    final isTimingServicePeriodInsert = sql.contains(
      'insert into public.business_timing_service_periods',
    );
    final isTimingAuditInsert = sql.contains(
      'insert into public.business_timing_audit_events',
    );

    // Onboarding path: detected by the RETURNING shape — onboarding
    // INSERT returns ONLY `operator_id::text as operator_id`, while
    // `insertOperator` returns the full row (`operator_id, business_name,
    // ...`). Both INSERTs share the same column list, so the
    // RETURNING list is the discriminator.
    final isOnboardOperatorInsert =
        isOperatorInsert &&
        sql.contains('returning operator_id::text as operator_id') &&
        !sql.contains('as operator_id, business_name');
    final isOnboardOperatorUpdate =
        isOperatorUpdate &&
        sql.contains('primary_location_id = @location_id::uuid');

    if (isOnboardOperatorInsert) {
      return onboardOperatorInsertRows;
    }
    if (isRootOrgUnitInsert) {
      return onboardRootOrgUnitRows;
    }
    if (isLocationInsert) {
      return onboardLocationRows;
    }
    if (isTimingProfileInsert) {
      if (failOnboardTimingProfileInsert) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'profile_id': _timingProfileId,
          'effective_from_business_date': '2026-04-30',
        },
      ];
    }
    if (isTimingServicePeriodInsert) {
      if (failOnboardTimingServicePeriodInsert) {
        return const <PostgresRow>[];
      }
      return <PostgresRow>[
        <String, Object?>{
          'service_period_id': parameters['service_period_key'],
        },
      ];
    }
    if (isTimingAuditInsert) {
      return <PostgresRow>[
        <String, Object?>{
          'audit_event_id': '66666666-6666-6666-6666-666666666666',
        },
      ];
    }
    if (isOnboardOperatorUpdate) {
      return onboardFinalOperatorRows;
    }
    if (isOperatorInsert) {
      return insertedOperatorRows;
    }
    if (isOperatorUpdate) {
      return updatedOperatorRows;
    }
    if (sql.contains('from operators')) {
      // listOperators OR findById; differentiate by presence of WHERE.
      if (sql.contains('where operator_id = @operator_id::uuid')) {
        return findByIdRows;
      }
      return listRows;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
    rollbackCount += 1;
  }
}
