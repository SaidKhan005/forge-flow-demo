import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('RepositoryMobileOperationalSyncProxyGateway data accuracy writes', () {
    test('full settings save deep-merges covers_manual_entries by date and '
        'period instead of replacing the whole JSON object', () async {
      final pool = _RecordingPool();
      final gateway = RepositoryMobileOperationalSyncProxyGateway(
        tenantWrapper: TenantTransactionWrapper(pool),
      );

      await gateway.upsertDataAccuracySettings(
        scope: const OperatorContext(
          userId: '11111111-1111-4111-8111-111111111111',
          operatorId: '22222222-2222-4222-8222-222222222222',
          locationId: '33333333-3333-4333-8333-333333333333',
          roles: <String>['operator_owner'],
        ),
        operatorId: '22222222-2222-4222-8222-222222222222',
        locationId: '33333333-3333-4333-8333-333333333333',
        body: const <String, Object?>{
          'covers_manual_entries': <String, Object?>{
            '2026-05-04': <String, Object?>{'lunch': 60},
          },
          'wage_source': 'vendor',
          'walk_in_handling_mode': 'reservations_only',
        },
      );

      final sql = pool.transaction!.queryCalls
          .map((call) => call.sql)
          .firstWhere((sql) {
            return sql.contains('insert into public.data_accuracy_settings');
          });
      expect(sql, contains('jsonb_each(coalesce('));
      expect(sql, contains('full join jsonb_each(coalesce('));
      expect(
        sql,
        isNot(
          contains('covers_manual_entries = excluded.covers_manual_entries'),
        ),
      );
    });

    test(
      'manual covers clear removes one slot and preserves neighbors',
      () async {
        final pool = _RecordingPool(
          initialManualEntries: <String, Map<String, int>>{
            '2026-05-04': <String, int>{'lunch': 60, 'dinner': 187},
            '2026-05-05': <String, int>{'dinner': 201},
          },
        );
        final gateway = RepositoryMobileOperationalSyncProxyGateway(
          tenantWrapper: TenantTransactionWrapper(pool),
        );

        final result = await gateway.upsertDataAccuracyManualCovers(
          scope: const OperatorContext(
            userId: '11111111-1111-4111-8111-111111111111',
            operatorId: '22222222-2222-4222-8222-222222222222',
            locationId: '33333333-3333-4333-8333-333333333333',
            roles: <String>['operator_owner'],
          ),
          operatorId: '22222222-2222-4222-8222-222222222222',
          locationId: '33333333-3333-4333-8333-333333333333',
          body: const <String, Object?>{
            'business_date': '2026-05-04',
            'service_period_key': 'dinner',
            'clear': true,
          },
        );

        final data = result['data'] as Map<String, Object?>;
        expect(
          data['covers_manual_entries'],
          equals(<String, Object?>{
            '2026-05-04': <String, Object?>{'lunch': 60},
            '2026-05-05': <String, Object?>{'dinner': 201},
          }),
        );
        final sql = pool.transaction!.queryCalls
            .map((call) => call.sql)
            .firstWhere((sql) {
              return sql.contains('insert into public.data_accuracy_settings');
            });
        expect(sql, contains('- @service_period_key'));
        expect(sql, contains("where day.value <> '{}'::jsonb"));
      },
    );
  });
}

class _RecordingPool implements PostgresPool {
  _RecordingPool({
    Map<String, Map<String, int>> initialManualEntries =
        const <String, Map<String, int>>{},
  }) : _initialManualEntries = initialManualEntries;

  final Map<String, Map<String, int>> _initialManualEntries;
  _RecordingTransaction? transaction;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      initialManualEntries: _initialManualEntries,
    );
    transaction = tx;
    return tx;
  }
}

class _SqlCall {
  const _SqlCall(this.sql, this.parameters);

  final String sql;
  final PostgresParameters parameters;
}

class _RecordingTransaction implements PostgresTransaction {
  _RecordingTransaction({
    Map<String, Map<String, int>> initialManualEntries =
        const <String, Map<String, int>>{},
  }) : _manualEntries = <String, Map<String, int>>{
         for (final entry in initialManualEntries.entries)
           entry.key: Map<String, int>.from(entry.value),
       };

  final List<_SqlCall> queryCalls = <_SqlCall>[];
  final List<_SqlCall> executeCalls = <_SqlCall>[];
  final Map<String, Map<String, int>> _manualEntries;
  bool committed = false;
  bool rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_SqlCall(sql, parameters));
    if (sql.contains('insert into public.data_accuracy_settings')) {
      final businessDate = parameters['business_date'];
      final servicePeriodKey = parameters['service_period_key'];
      if (businessDate is String && servicePeriodKey is String) {
        if (parameters['clear_manual_cover'] == true) {
          final dayMap = _manualEntries[businessDate];
          if (dayMap != null) {
            dayMap.remove(servicePeriodKey);
            if (dayMap.isEmpty) _manualEntries.remove(businessDate);
          }
        } else if (parameters['covers'] is int) {
          final dayMap = _manualEntries.putIfAbsent(
            businessDate,
            () => <String, int>{},
          );
          dayMap[servicePeriodKey] = parameters['covers'] as int;
        }
      } else if (parameters['manual_entries'] is String) {
        final decoded =
            jsonDecode(parameters['manual_entries'] as String)
                as Map<String, Object?>;
        decoded.forEach((dateIso, rawDayMap) {
          if (rawDayMap is! Map) return;
          final dayMap = _manualEntries.putIfAbsent(
            dateIso,
            () => <String, int>{},
          );
          rawDayMap.forEach((key, value) {
            if (key is String && value is int) dayMap[key] = value;
          });
        });
      }
      return <PostgresRow>[
        <String, Object?>{
          'setting_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'operator_id': parameters['operator_id'],
          'location_id': parameters['location_id'],
          'covers_manual_entries': <String, Object?>{
            for (final entry in _manualEntries.entries)
              entry.key: <String, Object?>{
                for (final inner in entry.value.entries) inner.key: inner.value,
              },
          },
          'wage_source': parameters['wage_source'],
          'walk_in_handling_mode': parameters['walk_in_handling_mode'],
          'walk_in_manual_entries': <String, Object?>{},
          'created_at': DateTime.utc(2026, 5, 4, 12),
          'updated_at': DateTime.utc(2026, 5, 4, 12),
          'updated_by': parameters['updated_by'],
        },
      ];
    }
    if (sql.contains('from public.effective_data_accuracy_settings_v')) {
      return const <PostgresRow>[];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executeCalls.add(_SqlCall(sql, parameters));
    return 0;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {
    rolledBack = true;
  }
}
