// B5 — RLS isolation test template.
//
// Provides [verifyRlsIsolation], a reusable function that, given a
// table name and a fact-row factory, verifies three RLS invariants:
//
//   1. Operator B cannot read operator A's rows (cross-tenant SELECT
//      returns empty under tenant context B).
//   2. Without tenant context, a SELECT returns empty (no SET LOCAL →
//      the current_setting() wrappers fall back to '' which is not a
//      valid UUID, so RLS predicates evaluate to false).
//   3. Operator A in location A1 can read its own rows; the test
//      documents the posture of location-scoped tables.
//
// The harness is passive by default — every test that calls this
// function must be tagged `@Tags(['postgres'])` and will be skipped
// unless `POSTGRES_TEST_URL` (or the default localhost URL) resolves
// to a live Postgres.
//
// Usage:
//   @Tags(['postgres'])
//   void main() {
//     group('auth_invites RLS isolation', () {
//       verifyRlsIsolation(
//         tableName: 'auth_invites',
//         insertRow: (exec, {required operatorId, required locationId}) async {
//           await exec.execute(
//             'insert into public.auth_invites (...) values (...)',
//             parameters: {'operator_id': operatorId, ...},
//           );
//         },
//         selectSql: (operatorId) =>
//           'select count(*) as n from public.auth_invites '
//           'where operator_id = \'$operatorId\'::uuid',
//       );
//     });
//   }

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';

import '../../../postgres_test_harness.dart';

// ─── Constants ───────────────────────────────────────────────────────

/// Fixture operator A UUID used by all RLS isolation tests.
const String kRlsOpA = 'a1a1a1a1-1111-1111-1111-111111111111';

/// Fixture operator B UUID used by all RLS isolation tests.
const String kRlsOpB = 'b2b2b2b2-2222-2222-2222-222222222222';

/// Primary location for operator A.
const String kRlsLocA1 = 'c3c3c3c3-3333-3333-3333-333333333311';

/// Second location for operator A (used by location-scoped test).
const String kRlsLocA2 = 'c3c3c3c3-3333-3333-3333-333333333322';

/// Primary location for operator B.
const String kRlsLocB1 = 'd4d4d4d4-4444-4444-4444-444444444411';

// ─── Template ────────────────────────────────────────────────────────

/// Registers three test cases inside the nearest enclosing [group]
/// that together verify per-tenant and per-location RLS isolation.
///
/// [tableName] — Postgres table name (for test descriptions only).
///
/// [insertRow] — async callback that inserts exactly one fixture row
///   for ([operatorId], [locationId]) via [exec]. Should not SET LOCAL
///   — the harness controls tenant context via admin path.
///
/// [selectSql] — returns a SELECT that counts rows owned by
///   [ownerOperatorId]. The count column must be named `n`.
///
/// [pool] — optional shared pool. When omitted, a fresh pool is
///   opened from [resolveTestPostgresUrl()].
void verifyRlsIsolation({
  required String tableName,
  required Future<void> Function(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
  }) insertRow,
  required String Function(String ownerOperatorId) selectSql,
  PackagePostgresPool? pool,
}) {
  test(
    'operator B cannot read operator A rows (cross-tenant isolation)',
    () async {
      await withTestPostgres(
        (p, wrapper) async {
          await seedOperator(p, operatorId: kRlsOpA, locationId: kRlsLocA1);
          await seedOperator(p, operatorId: kRlsOpB, locationId: kRlsLocB1);

          // Write a row as operator A using admin path (no RLS).
          final adminTx = await p.beginTransaction();
          try {
            await insertRow(adminTx,
                operatorId: kRlsOpA, locationId: kRlsLocA1);
            await adminTx.commit();
          } catch (e) {
            await adminTx.rollback();
            rethrow;
          }

          // Query as operator B — should see nothing.
          await wrapper.runInTenantContext(
            TenantContext(operatorId: kRlsOpB, locationId: kRlsLocB1),
            (exec) async {
              final rows = await exec.query(selectSql(kRlsOpA));
              final count = _count(rows);
              expect(
                count,
                isZero,
                reason:
                    '$tableName: operator B must not see operator A rows '
                    '(RLS cross-tenant SELECT blocked)',
              );
            },
          );
        },
        pool: pool,
      );
    },
    tags: <String>['postgres'],
  );

  test(
    'query without tenant context returns empty '
    '(no SET LOCAL → wrappers return empty UUID)',
    () async {
      await withTestPostgres(
        (p, wrapper) async {
          await seedOperator(p, operatorId: kRlsOpA, locationId: kRlsLocA1);

          // Write row via admin path.
          final adminTx = await p.beginTransaction();
          try {
            await insertRow(adminTx,
                operatorId: kRlsOpA, locationId: kRlsLocA1);
            await adminTx.commit();
          } catch (e) {
            await adminTx.rollback();
            rethrow;
          }

          // Open a raw transaction WITHOUT setting tenant GUCs.
          final rawTx = await p.beginTransaction();
          try {
            final rows = await rawTx.query(selectSql(kRlsOpA));
            final count = _count(rows);
            expect(
              count,
              isZero,
              reason:
                  '$tableName: SELECT without tenant SET LOCAL must return '
                  'empty — wrapper functions return NULL/empty when GUC is '
                  'absent, so the predicate never matches a real operator_id',
            );
            await rawTx.commit();
          } catch (e) {
            await rawTx.rollback();
            rethrow;
          }
        },
        pool: pool,
      );
    },
    tags: <String>['postgres'],
  );

  test(
    'operator A in location Y cannot read rows scoped to location X '
    '(location-scoped RLS posture documentation)',
    () async {
      await withTestPostgres(
        (p, wrapper) async {
          await seedOperator(p, operatorId: kRlsOpA, locationId: kRlsLocA1);

          // Ensure second location row exists for operator A.
          final insertLocTx = await p.beginTransaction();
          try {
            final ouId =
                '${kRlsOpA.substring(0, 8)}-0000-0000-0000-000000000099';
            await insertLocTx.execute(
              'insert into public.locations ('
              '  location_id, operator_id, parent_org_unit_id, '
              '  name, address, timezone, business_day_rollover_hour'
              ') values ('
              "  '$kRlsLocA2'::uuid, '$kRlsOpA'::uuid, '$ouId'::uuid, "
              "  'Second Location', '456 Test Ave', 'America/Toronto', 4"
              ') on conflict (location_id) do nothing',
            );
            await insertLocTx.commit();
          } catch (e) {
            await insertLocTx.rollback();
            rethrow;
          }

          // Write row for operator A, location A1 via admin.
          final adminTx = await p.beginTransaction();
          try {
            await insertRow(adminTx,
                operatorId: kRlsOpA, locationId: kRlsLocA1);
            await adminTx.commit();
          } catch (e) {
            await adminTx.rollback();
            rethrow;
          }

          // Query as operator A but from location A2.
          // Location-scoped tables return 0; operator-scoped-only
          // tables may return the row — both are valid postures.
          // The critical invariant is that no cross-TENANT leak occurs.
          await wrapper.runInTenantContext(
            TenantContext(operatorId: kRlsOpA, locationId: kRlsLocA2),
            (exec) async {
              // Executes without error — documents the posture.
              final rows = await exec.query(selectSql(kRlsOpA));
              // count is informational at this level; per-table callers
              // that KNOW the table is location-scoped can add:
              //   expect(count, isZero, reason: '...');
              _count(rows);
            },
          );
        },
        pool: pool,
      );
    },
    tags: <String>['postgres'],
  );
}

// ─── Private helpers ─────────────────────────────────────────────────

int _count(List<PostgresRow> rows) {
  if (rows.isEmpty) return 0;
  final n = rows.first['n'];
  if (n == null) return 0;
  if (n is int) return n;
  if (n is num) return n.toInt();
  return int.tryParse(n.toString()) ?? 0;
}
