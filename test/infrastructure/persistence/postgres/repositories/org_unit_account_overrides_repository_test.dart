import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/location_account_overrides_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/org_unit_account_overrides_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _orgUnitId = '22222222-2222-2222-2222-222222222222';
const String _userId = '33333333-3333-3333-3333-333333333333';

void main() {
  group('OrgUnitAccountOverridesRepository', () {
    test(
      'loadEffective merges selected override over nearest parent',
      () async {
        final pool = _RecordingPool(
          onQuery: (sql, _) {
            if (sql.contains('from selected_scope s')) {
              return <PostgresRow>[
                <String, Object?>{
                  'org_unit_id': _orgUnitId,
                  'override_operator_id': _operatorId,
                  'override_org_unit_id': _orgUnitId,
                  'override_iana_timezone': 'Europe/London',
                  'override_locale_code': null,
                  'override_currency_code': null,
                  'override_contact_email': null,
                  'override_contact_phone': null,
                  'override_created_at': DateTime.utc(2026, 5, 20, 10),
                  'override_updated_at': DateTime.utc(2026, 5, 20, 11),
                  'override_created_by_user_id': _userId,
                  'override_updated_by_user_id': _userId,
                  'parent_iana_timezone': 'America/Toronto',
                  'parent_locale_code': 'fr-CA',
                  'parent_currency_code': 'CAD',
                  'parent_contact_email': 'region@example.com',
                  'parent_contact_phone': '+1 555 0100',
                  'operator_locale_code': 'en-CA',
                  'operator_currency_code': 'USD',
                  'operator_updated_at': DateTime.utc(2026, 5, 20, 9),
                },
              ];
            }
            return const <PostgresRow>[];
          },
        );
        final repo = OrgUnitAccountOverridesRepository(
          TenantTransactionWrapper(pool),
        );

        final resolved = await repo.loadEffective(
          operatorId: _operatorId,
          orgUnitId: _orgUnitId,
          actorUserId: _userId,
        );

        expect(resolved?.scopeFound, isTrue);
        expect(resolved?.effective.ianaTimezone, equals('Europe/London'));
        expect(resolved?.effective.localeCode, equals('fr-CA'));
        expect(resolved?.effective.currencyCode, equals('CAD'));
        expect(resolved?.effective.contactEmail, equals('region@example.com'));
        final sql = pool.transactions.single.executedSql.last;
        expect(sql, contains('ou.path @> s.path'));
        expect(sql, contains("unit_type <> 'corp'"));
      },
    );

    test('upsert validates org unit before writing scoped fields', () async {
      final pool = _RecordingPool(
        onQuery: (sql, parameters) {
          if (sql.contains('from public.org_units')) {
            return <PostgresRow>[
              <String, Object?>{'id': _orgUnitId},
            ];
          }
          if (sql.contains('from public.org_unit_account_overrides')) {
            return const <PostgresRow>[];
          }
          if (sql.contains('insert into public.org_unit_account_overrides')) {
            return <PostgresRow>[
              <String, Object?>{
                'operator_id': _operatorId,
                'org_unit_id': _orgUnitId,
                'iana_timezone': parameters['iana_timezone'],
                'locale_code': parameters['locale_code'],
                'currency_code': parameters['currency_code'],
                'contact_email': parameters['contact_email'],
                'contact_phone': parameters['contact_phone'],
                'created_at': DateTime.utc(2026, 5, 20, 12),
                'updated_at': DateTime.utc(2026, 5, 20, 12),
                'created_by_user_id': _userId,
                'updated_by_user_id': _userId,
              },
            ];
          }
          return const <PostgresRow>[];
        },
      );
      final repo = OrgUnitAccountOverridesRepository(
        TenantTransactionWrapper(pool),
      );

      final row = await repo.upsertOverrides(
        operatorId: _operatorId,
        orgUnitId: _orgUnitId,
        actorUserId: _userId,
        patch: const LocationAccountOverridesPatch(
          ianaTimezone: 'Europe/London',
          currencyCode: 'GBP',
          contactPhone: '+44 20 7000 0000',
        ),
      );

      expect(row.ianaTimezone, equals('Europe/London'));
      expect(row.currencyCode, equals('GBP'));
      expect(row.contactPhone, equals('+44 20 7000 0000'));
      final tx = pool.transactions.single;
      final guardSql = tx.executedSql.firstWhere(
        (sql) => sql.contains('from public.org_units'),
      );
      expect(guardSql, contains("unit_type <> 'corp'"));
      final insertSql = tx.executedSql.firstWhere(
        (sql) => sql.contains('insert into public.org_unit_account_overrides'),
      );
      expect(insertSql, isNot(contains('business_day_rollover_hour')));
    });
  });
}

class _RecordingPool implements PostgresPool {
  _RecordingPool({required this.onQuery});

  final List<PostgresRow> Function(String sql, PostgresParameters parameters)
  onQuery;
  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(this);
    transactions.add(tx);
    return tx;
  }
}

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction(this.pool);

  final _RecordingPool pool;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return pool.onQuery(sql, parameters);
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 1;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
