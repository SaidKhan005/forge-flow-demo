// Phase 8 spine-bridge Lane .A — ForgeFlowPollingTierRepository tests.
//
// Covers acceptance items E, F, G, I from the lane prompt:
//
//   E. tier assignment RLS round-trip — every read / write goes through
//      `withTenant`; SET LOCAL chain carries the right (operator,
//      location); SQL filters on operator_id::uuid + location_id::uuid.
//
//   F. assignTier transitions: prior currently-effective row closes
//      with effective_until = now(); new row inserted; readCurrent
//      returns the new row. All within a single transaction so the
//      partial-unique index never sees two NULL effective_until rows.
//
//   G. Assignment history chronological descending — `effective_at desc`
//      ORDER BY pinned in the SELECT.
//
//   I. Margin summary aggregates correctly — sums monthly_price_cents
//      and vendor_api_cost_estimate_cents_monthly across the
//      currently-effective rows visible to the tenant context. Optional
//      tier_key filter pinned.
//
// (Item H — service_role read-only / forge_admin write — is verified at
//  the migration level in `data_accuracy_migration_test.dart`. The
//  repository surface is uniform regardless of the calling Postgres
//  role; the role check happens server-side.)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/data_accuracy/forge_flow_polling_tier_repository.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _locB = '55555555-5555-5555-5555-555555555555';
const String _adminA = '33333333-3333-3333-3333-333333333333';

Map<String, Object?> _tierRow({
  String assignmentId = '99999999-9999-9999-9999-999999999999',
  String operatorId = _opA,
  String locationId = _locA,
  String tierKey = 'standard',
  Map<String, Object?>? cadence,
  int? priceCents = 4900,
  int? costCents = 1500,
  DateTime? effectiveAt,
  DateTime? effectiveUntil,
  String? adminUserId = _adminA,
}) {
  return <String, Object?>{
    'assignment_id': assignmentId,
    'operator_id': operatorId,
    'location_id': locationId,
    'tier_key': tierKey,
    'polling_cadence_per_vendor_seconds':
        cadence ?? const <String, Object?>{'oracle_micros_simphony': 300},
    'monthly_price_cents': priceCents,
    'vendor_api_cost_estimate_cents_monthly': costCents,
    'effective_at': effectiveAt ?? DateTime.utc(2026, 5, 5, 10),
    'effective_until': effectiveUntil,
    'assigned_by_admin_user_id': adminUserId,
    'created_at': DateTime.utc(2026, 5, 5, 10),
  };
}

void main() {
  group('ForgeFlowPollingTierRepository — RLS round-trip (item E)', () {
    test(
      'readCurrentAssignment for op A vs op B opens distinct '
      'transactions; SET LOCAL chain matches each tenant; SELECT '
      'filters on operator_id + location_id + effective_until is null',
      () async {
        final pool = _TierPool(
          currentRows: <PostgresRow>[
            _tierRow(operatorId: _opA, locationId: _locA),
          ],
          currentRowsAlt: <PostgresRow>[
            _tierRow(operatorId: _opB, locationId: _locB),
          ],
        );
        final repo = ForgeFlowPollingTierRepository(
          TenantTransactionWrapper(pool),
        );
        final rowA = await repo.readCurrentAssignment(
          operatorId: _opA,
          locationId: _locA,
        );
        final rowB = await repo.readCurrentAssignment(
          operatorId: _opB,
          locationId: _locB,
        );
        expect(rowA?.operatorId, equals(_opA));
        expect(rowB?.operatorId, equals(_opB));

        expect(pool.transactions, hasLength(2));
        final txA = pool.transactions[0];
        final txB = pool.transactions[1];
        expect(
          txA.parameters.firstWhere((p) => p['value'] == _opA)['value'],
          equals(_opA),
        );
        expect(
          txB.parameters.firstWhere((p) => p['value'] == _opB)['value'],
          equals(_opB),
        );

        final selectSql = txA.executedSql.firstWhere(
          (s) => s.contains('from forge_flow_polling_tier_assignment'),
        );
        expect(
          selectSql,
          contains('where operator_id = @operator_id::uuid'),
        );
        expect(
          selectSql,
          contains('and location_id = @location_id::uuid'),
        );
        expect(
          selectSql,
          contains('and effective_until is null'),
          reason: 'currently-effective filter — only the active row',
        );
      },
    );
  });

  group('ForgeFlowPollingTierRepository — assignTier transition (item F)',
      () {
    test(
      'assignTier closes the prior current row with '
      'effective_until = now(), then INSERTs the new row, all within '
      'a single transaction',
      () async {
        final pool = _TierPool(
          insertedRow: _tierRow(tierKey: 'premium', priceCents: 9900),
        );
        final repo = ForgeFlowPollingTierRepository(
          TenantTransactionWrapper(pool),
        );
        final inserted = await repo.assignTier(
          operatorId: _opA,
          locationId: _locA,
          tierKey: PollingTierKey.premium,
          pollingCadencePerVendorSeconds: const <String, int>{
            'oracle_micros_simphony': 60,
            'quickbooks_time': 60,
          },
          monthlyPriceCents: 9900,
          vendorApiCostEstimateCentsMonthly: 2500,
          adminUserId: _adminA,
          reasonNote: 'Operator upgraded after onboarding call',
        );
        expect(inserted.tierKey, equals(PollingTierKey.premium));
        expect(inserted.monthlyPriceCents, equals(9900));

        // Single transaction.
        expect(pool.transactions, hasLength(1));
        final tx = pool.transactions.single;

        // Step 1: UPDATE that closes the prior current row.
        final closeSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update forge_flow_polling_tier_assignment') &&
              s.contains('set effective_until = now()'),
        );
        expect(closeSql, contains('and effective_until is null'));
        expect(closeSql, contains('where operator_id = @operator_id::uuid'));

        // Step 2: INSERT new row.
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into forge_flow_polling_tier_assignment'),
        );
        expect(insertSql, contains('returning'));
        // Cadence bound as JSONB.
        final insertParams = tx.parameters.firstWhere(
          (p) => p['tier_key'] == 'premium',
        );
        final cadenceJson = insertParams['cadence'] as String;
        final decoded = jsonDecode(cadenceJson) as Map<String, Object?>;
        expect(decoded['oracle_micros_simphony'], equals(60));
        expect(decoded['quickbooks_time'], equals(60));

        // Order of operations: close before insert (history preserved).
        final closeIndex = tx.executedSql.indexWhere(
          (s) => s.contains('set effective_until = now()'),
        );
        final insertIndex = tx.executedSql.indexWhere(
          (s) => s.contains('insert into forge_flow_polling_tier_assignment'),
        );
        expect(
          closeIndex,
          lessThan(insertIndex),
          reason: 'close prior row BEFORE inserting new one',
        );

        // Commit ran at the end (single tx).
        expect(tx.commitCount, equals(1));
      },
    );

    test(
      'assignTier null monthly_price_cents (bundled / comped path) and '
      'null cost basis (not-yet-measured) bind through to the INSERT',
      () async {
        final pool = _TierPool(
          insertedRow: _tierRow(priceCents: null, costCents: null),
        );
        final repo = ForgeFlowPollingTierRepository(
          TenantTransactionWrapper(pool),
        );
        final inserted = await repo.assignTier(
          operatorId: _opA,
          locationId: _locA,
          tierKey: PollingTierKey.standard,
          pollingCadencePerVendorSeconds: const <String, int>{},
          adminUserId: _adminA,
        );
        expect(inserted.monthlyPriceCents, isNull);
        expect(inserted.vendorApiCostEstimateCentsMonthly, isNull);
        expect(inserted.netMarginCents, isNull);

        final tx = pool.transactions.single;
        final insertParams = tx.parameters.firstWhere(
          (p) => p['tier_key'] == 'standard',
        );
        expect(insertParams['monthly_price_cents'], isNull);
        expect(insertParams['vendor_api_cost_estimate_cents_monthly'], isNull);
      },
    );
  });

  group('ForgeFlowPollingTierRepository — assignment history (item G)',
      () {
    test(
      'listAssignmentHistory orders by effective_at desc; current row '
      '(effective_until is null) appears first',
      () async {
        final current = _tierRow(
          effectiveAt: DateTime.utc(2026, 5, 5, 10),
          tierKey: 'premium',
        );
        final older = _tierRow(
          assignmentId: '11111111-aaaa-aaaa-aaaa-111111111111',
          effectiveAt: DateTime.utc(2026, 4, 1, 10),
          effectiveUntil: DateTime.utc(2026, 5, 5, 10),
          tierKey: 'standard',
        );
        final pool = _TierPool(
          historyRows: <PostgresRow>[current, older],
        );
        final repo = ForgeFlowPollingTierRepository(
          TenantTransactionWrapper(pool),
        );
        final history = await repo.listAssignmentHistory(
          operatorId: _opA,
          locationId: _locA,
        );
        expect(history, hasLength(2));
        expect(history.first.tierKey, equals(PollingTierKey.premium));
        expect(history.first.isCurrent, isTrue);
        expect(history.last.tierKey, equals(PollingTierKey.standard));
        expect(history.last.isCurrent, isFalse);

        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('from forge_flow_polling_tier_assignment') &&
              s.contains('order by effective_at desc'),
        );
        expect(
          selectSql,
          isNot(contains('and effective_until is null')),
          reason: 'history SELECT must NOT filter to current — it lists '
              'every assignment row, current first',
        );
      },
    );
  });

  group('ForgeFlowPollingTierRepository — margin summary (item I)', () {
    test(
      'summarizeMargin aggregates currently-effective rows; '
      'totalMonthlyMarginCents = price - cost; marginFraction returns '
      'the right ratio',
      () async {
        final pool = _TierPool(
          marginRow: <String, Object?>{
            'assignment_count': 3,
            'total_price_cents': 24700, // 9900 + 9900 + 4900
            'total_cost_cents': 5500, // 2500 + 2500 + 500
          },
        );
        final repo = ForgeFlowPollingTierRepository(
          TenantTransactionWrapper(pool),
        );
        final summary = await repo.summarizeMargin(
          operatorId: _opA,
          locationId: _locA,
        );
        expect(summary.assignmentCount, equals(3));
        expect(summary.totalMonthlyPriceCents, equals(24700));
        expect(summary.totalMonthlyVendorCostCents, equals(5500));
        expect(summary.totalMonthlyMarginCents, equals(19200));
        expect(summary.marginFraction, closeTo(19200 / 24700, 1e-9));

        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from forge_flow_polling_tier_assignment'),
        );
        expect(
          selectSql,
          contains('and effective_until is null'),
          reason: 'margin only counts currently-effective rows',
        );
        expect(selectSql, contains('coalesce(sum(monthly_price_cents)'));
        expect(
          selectSql,
          contains('coalesce(sum(vendor_api_cost_estimate_cents_monthly)'),
        );
        expect(selectSql, contains('count(*)'));
      },
    );

    test(
      'summarizeMargin with tier_key filter narrows the SELECT to a '
      'single tier (used by the per-tier breakdown card)',
      () async {
        final pool = _TierPool(
          marginRow: <String, Object?>{
            'assignment_count': 1,
            'total_price_cents': 9900,
            'total_cost_cents': 2500,
          },
        );
        final repo = ForgeFlowPollingTierRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.summarizeMargin(
          operatorId: _opA,
          locationId: _locA,
          tierKey: PollingTierKey.premium,
        );
        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from forge_flow_polling_tier_assignment'),
        );
        expect(selectSql, contains('and tier_key = @tier_key'));
        final selectParams = tx.parameters.firstWhere(
          (p) => p['tier_key'] == 'premium',
        );
        expect(selectParams['tier_key'], equals('premium'));
      },
    );

    test(
      'summarizeMargin with zero rows returns a sensible zero summary '
      '(marginFraction null because no revenue)',
      () async {
        final pool = _TierPool(
          marginRow: <String, Object?>{
            'assignment_count': 0,
            'total_price_cents': 0,
            'total_cost_cents': 0,
          },
        );
        final repo = ForgeFlowPollingTierRepository(
          TenantTransactionWrapper(pool),
        );
        final summary = await repo.summarizeMargin(
          operatorId: _opA,
          locationId: _locA,
        );
        expect(summary.assignmentCount, equals(0));
        expect(summary.totalMonthlyPriceCents, equals(0));
        expect(summary.totalMonthlyVendorCostCents, equals(0));
        expect(summary.totalMonthlyMarginCents, equals(0));
        expect(summary.marginFraction, isNull);
      },
    );
  });
}

class _TierPool implements PostgresPool {
  _TierPool({
    this.currentRows = const <PostgresRow>[],
    this.currentRowsAlt = const <PostgresRow>[],
    this.historyRows = const <PostgresRow>[],
    this.insertedRow,
    this.marginRow,
  });

  final List<PostgresRow> currentRows;
  final List<PostgresRow> currentRowsAlt;
  final List<PostgresRow> historyRows;
  final PostgresRow? insertedRow;
  final PostgresRow? marginRow;

  final List<_TierTransaction> transactions = <_TierTransaction>[];
  int _txIndex = 0;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final isAltTx = _txIndex == 1;
    _txIndex += 1;
    final tx = _TierTransaction(
      currentRows: isAltTx && currentRowsAlt.isNotEmpty
          ? currentRowsAlt
          : currentRows,
      historyRows: historyRows,
      insertedRow: insertedRow,
      marginRow: marginRow,
    );
    transactions.add(tx);
    return tx;
  }
}

class _TierTransaction extends PostgresTransaction {
  _TierTransaction({
    required this.currentRows,
    required this.historyRows,
    required this.insertedRow,
    required this.marginRow,
  });

  final List<PostgresRow> currentRows;
  final List<PostgresRow> historyRows;
  final PostgresRow? insertedRow;
  final PostgresRow? marginRow;

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
    if (sql.contains('insert into forge_flow_polling_tier_assignment') &&
        sql.contains('returning')) {
      if (insertedRow == null) return const <PostgresRow>[];
      return <PostgresRow>[insertedRow!];
    }
    if (sql.contains('from forge_flow_polling_tier_assignment')) {
      if (sql.contains('coalesce(sum(monthly_price_cents)')) {
        if (marginRow == null) return const <PostgresRow>[];
        return <PostgresRow>[marginRow!];
      }
      if (sql.contains('order by effective_at desc')) {
        return historyRows;
      }
      if (sql.contains('and effective_until is null')) {
        return currentRows;
      }
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
