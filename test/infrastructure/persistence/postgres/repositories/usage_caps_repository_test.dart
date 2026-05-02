// Phase 11A.2 / 9.0Σ.g / post-hardening P2 — canonical-path unit
// tests for UsageCapsRepository.
//
// Coverage focus:
//
//   * Two-slot key — the locked logical key after 9.0Σ.g step c is
//     `(operator_id, billing_owner_org_unit_id, scoped_org_unit_id,
//     location_id, staff_id, workflow_id, usage_class)` enforced by
//     the named UNIQUE NULLS NOT DISTINCT constraint
//     `usage_caps_two_slot_uq`. The upsert path targets that
//     constraint by NAME (not column list) so renames at the migration
//     layer surface as a hard test failure here. Tests pin:
//       - `on conflict on constraint usage_caps_two_slot_uq` shape
//       - all seven logical-key columns appear in the INSERT bind
//       - DO UPDATE rewrites only `monthly_cap_usd`,
//         `per_invocation_cap_usd`, `updated_by`, and `updated_at` —
//         `created_by` is preserved on conflict so the audit trail
//         tracks the original creator
//
//   * NULLS NOT DISTINCT collision — when `staff_id` and `workflow_id`
//     are both null (the "all-staff / all-workflow" cap), the upsert
//     still collides on the constraint so a re-upsert becomes a true
//     UPDATE rather than minting a duplicate row. The test pins this
//     by binding the same null-pair twice (the second call must reach
//     the SQL identically; the constraint then handles the dedup at
//     the DB layer).
//
//   * Cross-tenant admin posture — every method runs through
//     `withSystem` (the admin pricing console walks the entire fleet,
//     not one tenant). Tests verify `set local role forge_admin` AND
//     the canonical `app.bypass_rls_audit = 'system:<reason>'` audit
//     marker.
//
//   * `listAllCaps` cross-tenant — SQL has NO `where operator_id =`
//     predicate; ordered by `(operator_id, location_id, usage_class)`
//     so the admin grouping is stable.
//
//   * `listForOperator` tenant-bounded admin path — same `withSystem`
//     posture but WITH `where operator_id = @operator_id::uuid`.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/usage_caps_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _orgUnit = '66666666-6666-6666-6666-666666666666';
const String _capId = '77777777-7777-7777-7777-777777777777';
const String _actor = '33333333-3333-3333-3333-333333333333';
const String _staffId = '88888888-8888-8888-8888-888888888888';
const String _workflowId = '99999999-9999-9999-9999-999999999999';

PostgresRow _capRow({
  String capId = _capId,
  String operatorId = _opA,
  String locationId = _locA,
  String usageClass = 'llm_haiku',
  num monthly = 100,
  num perInvocation = 1,
  String? staffId,
  String? workflowId,
  String billingOwner = _orgUnit,
  String scoped = _orgUnit,
  String? createdBy = _actor,
  String? updatedBy = _actor,
}) {
  return <String, Object?>{
    'cap_id': capId,
    'operator_id': operatorId,
    'location_id': locationId,
    'usage_class': usageClass,
    'monthly_cap_usd': monthly,
    'per_invocation_cap_usd': perInvocation,
    'staff_id': staffId,
    'workflow_id': workflowId,
    'billing_owner_org_unit_id': billingOwner,
    'scoped_org_unit_id': scoped,
    'created_by': createdBy,
    'updated_by': updatedBy,
    'created_at': DateTime.utc(2026, 4, 28),
    'updated_at': DateTime.utc(2026, 4, 28),
  };
}

void main() {
  group('UsageCapsRepository.listAllCaps (cross-tenant admin sweep)', () {
    test(
      'uses withSystem with the canonical bypass marker; SQL has NO '
      'operator_id predicate; ORDER BY (operator_id, location_id, '
      'usage_class) so the pricing-admin console grouping is stable',
      () async {
        final pool = _CapsPool(
          listAllRows: <PostgresRow>[
            _capRow(operatorId: _opA),
            _capRow(operatorId: _opB),
          ],
        );
        final repo = UsageCapsRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listAllCaps(
          adminReason: 'admin.pricing.list_all',
        );
        expect(rows, hasLength(2));
        expect(rows[0].operatorId, equals(_opA));
        expect(rows[1].operatorId, equals(_opB));

        final tx = pool.transactions.single;
        // Bypass audit marker carries the canonical "system:<reason>" shape.
        final auditCfg = tx.parameters.firstWhere(
          (p) => p['value'] is String &&
              (p['value']! as String).startsWith('system:'),
        );
        expect(auditCfg['value'], equals('system:admin.pricing.list_all'));
        // forge_admin elevation precedes the SELECT.
        expect(
          tx.executedSql.where((s) => s.contains('set local role forge_admin')),
          hasLength(1),
        );
        // Tenant GUCs MUST NOT be set in withSystem.
        expect(
          tx.executedSql.where((s) => s.contains("'app.operator_id'")),
          isEmpty,
        );
        // SQL shape — no WHERE, ordered for stable admin grouping.
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from usage_caps'),
        );
        expect(selectSql, isNot(contains('where ')));
        expect(
          selectSql,
          contains(
            'order by operator_id asc, location_id asc, usage_class asc',
          ),
        );
      },
    );
  });

  group('UsageCapsRepository.listForOperator (admin tenant-bounded)', () {
    test(
      'uses withSystem AND filters operator_id::uuid — admin still '
      'walks via BYPASSRLS but scopes the read to one operator',
      () async {
        final pool = _CapsPool(
          listForOperatorRows: <PostgresRow>[
            _capRow(operatorId: _opA),
          ],
        );
        final repo = UsageCapsRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listForOperator(
          operatorId: _opA,
          adminReason: 'admin.pricing.list_for_op',
        );
        expect(rows, hasLength(1));
        expect(rows.single.operatorId, equals(_opA));

        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from usage_caps'),
        );
        expect(selectSql, contains('where operator_id = @operator_id::uuid'));
        expect(selectSql, contains('order by location_id asc, usage_class asc'));
        // Bound parameter, not concatenated.
        final selectParams = tx.parameters.firstWhere(
          (p) => p['operator_id'] == _opA,
        );
        expect(selectParams['operator_id'], equals(_opA));
      },
    );
  });

  group('UsageCapsRepository.upsertCap — two-slot UNIQUE NULLS NOT DISTINCT',
      () {
    test(
      'INSERT ... ON CONFLICT ON CONSTRAINT usage_caps_two_slot_uq '
      'DO UPDATE — targets the constraint by NAME (not column list) '
      'so a migration rename surfaces as a hard test failure',
      () async {
        final pool = _CapsPool(upsertedRow: _capRow());
        final repo = UsageCapsRepository(TenantTransactionWrapper(pool));
        await repo.upsertCap(
          operatorId: _opA,
          billingOwnerOrgUnitId: _orgUnit,
          scopedOrgUnitId: _orgUnit,
          locationId: _locA,
          usageClass: 'llm_haiku',
          monthlyCapUsd: 100.0,
          perInvocationCapUsd: 1.0,
          actorUserId: _actor,
          adminReason: 'admin.pricing.set',
        );
        final tx = pool.transactions.single;
        final upsertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into usage_caps'),
        );
        expect(
          upsertSql,
          contains('on conflict on constraint usage_caps_two_slot_uq'),
          reason:
              'targeting by named constraint keeps the conflict shape '
              'load-bearing across migration changes',
        );
        // DO UPDATE rewrites cap economics + updated_by, NOT created_by.
        expect(upsertSql, contains('do update set'));
        expect(upsertSql, contains('monthly_cap_usd = excluded.monthly_cap_usd'));
        expect(upsertSql, contains(
          'per_invocation_cap_usd = excluded.per_invocation_cap_usd',
        ));
        expect(upsertSql, contains('updated_by = excluded.updated_by'));
        expect(upsertSql, contains('updated_at = now()'));
        expect(
          upsertSql,
          isNot(contains('created_by = excluded.created_by')),
          reason:
              'created_by must be preserved on conflict so the audit '
              'trail keeps the original creator while updated_by tracks '
              'the latest admin actor',
        );
      },
    );

    test(
      'INSERT bind covers all seven logical-key columns + economics + '
      'created_by + updated_by — every column the constraint cares '
      'about reaches the wire',
      () async {
        final pool = _CapsPool(upsertedRow: _capRow(
          staffId: _staffId,
          workflowId: _workflowId,
        ));
        final repo = UsageCapsRepository(TenantTransactionWrapper(pool));
        await repo.upsertCap(
          operatorId: _opA,
          billingOwnerOrgUnitId: _orgUnit,
          scopedOrgUnitId: _orgUnit,
          locationId: _locA,
          usageClass: 'llm_sonnet',
          monthlyCapUsd: 1000.0,
          perInvocationCapUsd: 5.0,
          staffId: _staffId,
          workflowId: _workflowId,
          actorUserId: _actor,
          adminReason: 'admin.pricing.set',
        );
        final tx = pool.transactions.single;
        final params = tx.parameters.firstWhere(
          (p) => p['usage_class'] == 'llm_sonnet',
        );
        // Two-slot key columns.
        expect(params['operator_id'], equals(_opA));
        expect(params['billing_owner'], equals(_orgUnit));
        expect(params['scoped'], equals(_orgUnit));
        expect(params['location_id'], equals(_locA));
        expect(params['staff_id'], equals(_staffId));
        expect(params['workflow_id'], equals(_workflowId));
        expect(params['usage_class'], equals('llm_sonnet'));
        // Economics.
        expect(params['monthly_cap_usd'], equals(1000.0));
        expect(params['per_invocation_cap_usd'], equals(5.0));
        // Actor — bound to BOTH created_by and updated_by on insert
        // (a fresh row records the same admin in both columns; on
        // conflict, only updated_by is rewritten, see preceding test).
        expect(params['actor'], equals(_actor));
      },
    );

    test(
      'NULLS NOT DISTINCT collision: null staff_id AND null '
      'workflow_id reach the SQL bind as null. The DB constraint '
      'treats null = null on these columns so a re-upsert collides '
      'and DO UPDATE runs (rather than minting a duplicate row)',
      () async {
        final pool = _CapsPool(upsertedRow: _capRow());
        final repo = UsageCapsRepository(TenantTransactionWrapper(pool));
        await repo.upsertCap(
          operatorId: _opA,
          billingOwnerOrgUnitId: _orgUnit,
          scopedOrgUnitId: _orgUnit,
          locationId: _locA,
          usageClass: 'llm_haiku',
          monthlyCapUsd: 100.0,
          perInvocationCapUsd: 1.0,
          // staff_id and workflow_id deliberately omitted
          actorUserId: _actor,
          adminReason: 'admin.pricing.set',
        );
        final tx = pool.transactions.single;
        final params = tx.parameters.firstWhere(
          (p) => p['usage_class'] == 'llm_haiku',
        );
        expect(
          params['staff_id'],
          isNull,
          reason:
              'NULLS NOT DISTINCT relies on the row literally carrying '
              'NULL — coercing to a sentinel like an empty UUID string '
              'would defeat the constraint dedup',
        );
        expect(params['workflow_id'], isNull);
      },
    );

    test(
      'throws StateError when the upsert RETURNING row is empty — '
      'this would only happen if the conflict target never matched '
      'AND the INSERT was somehow refused (RLS off the admin path), '
      'so loud failure beats a silent caller-side null deref',
      () async {
        final pool = _CapsPool(upsertedRow: null);
        final repo = UsageCapsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.upsertCap(
            operatorId: _opA,
            billingOwnerOrgUnitId: _orgUnit,
            scopedOrgUnitId: _orgUnit,
            locationId: _locA,
            usageClass: 'llm_haiku',
            monthlyCapUsd: 100.0,
            perInvocationCapUsd: 1.0,
            actorUserId: _actor,
            adminReason: 'admin.pricing.set',
          ),
          throwsStateError,
        );
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the UsageCapsRepository
/// seam.
///
/// `listAllRows` / `listForOperatorRows` control the SELECT returns;
/// `upsertedRow` controls the INSERT … ON CONFLICT … RETURNING return
/// (pass `null` for an empty-rows scenario).
class _CapsPool implements PostgresPool {
  _CapsPool({
    this.listAllRows = const <PostgresRow>[],
    this.listForOperatorRows = const <PostgresRow>[],
    this.upsertedRow,
  });

  final List<PostgresRow> listAllRows;
  final List<PostgresRow> listForOperatorRows;
  final PostgresRow? upsertedRow;
  final List<_CapsTransaction> transactions = <_CapsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _CapsTransaction(
      listAllRows: listAllRows,
      listForOperatorRows: listForOperatorRows,
      upsertedRow: upsertedRow,
    );
    transactions.add(tx);
    return tx;
  }
}

class _CapsTransaction extends PostgresTransaction {
  _CapsTransaction({
    required this.listAllRows,
    required this.listForOperatorRows,
    required this.upsertedRow,
  });

  final List<PostgresRow> listAllRows;
  final List<PostgresRow> listForOperatorRows;
  final PostgresRow? upsertedRow;

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
    if (sql.contains('insert into usage_caps') &&
        sql.contains('on conflict on constraint')) {
      if (upsertedRow == null) return const <PostgresRow>[];
      return <PostgresRow>[upsertedRow!];
    }
    if (sql.contains('from usage_caps')) {
      if (sql.contains('where operator_id = @operator_id::uuid')) {
        return listForOperatorRows;
      }
      return listAllRows;
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
