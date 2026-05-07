// Phase 8 — ConnectorConnectionListRepository tests.
//
// Validates the read-only projection over `public.connector_connection`
// used by the operator-self-service Connections route. The pool fake
// records every executed SQL statement so the test can assert that
// the SET LOCAL trio runs BEFORE the SELECT, and that the SELECT
// scopes by (operator_id, location_id) without leaking other rows.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_connection_list_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

const String _op = '11111111-1111-1111-1111-111111111111';
const String _loc = '22222222-2222-2222-2222-222222222222';
const String _actor = '33333333-3333-3333-3333-333333333333';

void main() {
  group('ConnectorConnectionListRepository.listForLocation', () {
    test(
      'projects rows from connector_connection scoped to '
      '(operator_id, location_id) and returns them in stable category, '
      'vendor_id order',
      () async {
        final pool = _Pool(
          listRows: <PostgresRow>[
            _connectionRow(
              connectionId: 'aaaa-pos-toast',
              vendorId: 'toast',
              category: 'pos',
              status: 'connected',
              webhookProvisioned: true,
              metadata: <String, Object?>{'merchant_id': 'm-1'},
            ),
            _connectionRow(
              connectionId: 'bbbb-labor-7s',
              vendorId: '7shifts',
              category: 'labor',
              status: 'connected',
              module: 'time',
            ),
            _connectionRow(
              connectionId: 'cccc-pos-square',
              vendorId: 'square',
              category: 'pos',
              status: 'error',
              disconnectReason: 'oauth_timeout',
              lastErrorMessage: 'token revoked',
            ),
          ],
        );
        final repo = ConnectorConnectionListRepository(
          TenantTransactionWrapper(pool),
        );

        final bundle = await repo.listForLocation(
          operatorId: _op,
          locationId: _loc,
          actorUserId: _actor,
        );

        expect(bundle.operatorId, equals(_op));
        expect(bundle.locationId, equals(_loc));
        expect(bundle.rows, hasLength(3));

        final toast = bundle.rows.firstWhere((r) => r.vendorId == 'toast');
        expect(toast.category, IntegrationCategory.pos);
        expect(toast.status, equals('connected'));
        expect(toast.webhookUrlProvisioned, isTrue);
        expect(toast.metadata['merchant_id'], equals('m-1'));

        final sevenShifts = bundle.rows.firstWhere(
          (r) => r.vendorId == '7shifts',
        );
        expect(sevenShifts.category, IntegrationCategory.labor);
        expect(sevenShifts.module, equals('time'));

        final squareErr = bundle.rows.firstWhere(
          (r) => r.vendorId == 'square',
        );
        expect(squareErr.status, equals('error'));
        expect(squareErr.disconnectReason, equals('oauth_timeout'));
        expect(squareErr.lastErrorMessage, equals('token revoked'));

        // SQL shape — must run inside a tenant SET LOCAL transaction
        // and select scoped by both operator_id and location_id.
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.take(3),
          containsAll(<Matcher>[
            contains("set_config('app.operator_id'"),
            contains("set_config('app.location_id'"),
            contains("set_config('app.user_id'"),
          ]),
        );
        final selectSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('from public.connector_connection'),
        );
        expect(selectSql, contains('operator_id = @operator_id::uuid'));
        expect(selectSql, contains('location_id = @location_id::uuid'));
        expect(selectSql, contains('order by category asc'));

        // Bound params must carry the operator + location passed in.
        final selectParams = tx.parameters.firstWhere(
          (p) => p['operator_id'] == _op && p['location_id'] == _loc,
        );
        expect(selectParams['operator_id'], equals(_op));
        expect(selectParams['location_id'], equals(_loc));
      },
    );

    test(
      'returns an empty bundle when no connector_connection rows exist '
      'for the (operator, location) — the noConnectedRowForCategory '
      'helper signals demo-mode is still active for every category',
      () async {
        final pool = _Pool(listRows: const <PostgresRow>[]);
        final repo = ConnectorConnectionListRepository(
          TenantTransactionWrapper(pool),
        );

        final bundle = await repo.listForLocation(
          operatorId: _op,
          locationId: _loc,
          actorUserId: _actor,
        );

        expect(bundle.rows, isEmpty);
        expect(
          bundle.noConnectedRowForCategory(IntegrationCategory.pos),
          isTrue,
        );
        expect(
          bundle.noConnectedRowForCategory(IntegrationCategory.labor),
          isTrue,
        );
        expect(
          bundle.noConnectedRowForCategory(IntegrationCategory.reservation),
          isTrue,
        );
      },
    );

    test(
      'a single connected row in a category flips '
      'noConnectedRowForCategory false for that category only',
      () async {
        final pool = _Pool(
          listRows: <PostgresRow>[
            _connectionRow(
              connectionId: 'aaaa',
              vendorId: 'toast',
              category: 'pos',
              status: 'connected',
            ),
          ],
        );
        final repo = ConnectorConnectionListRepository(
          TenantTransactionWrapper(pool),
        );

        final bundle = await repo.listForLocation(
          operatorId: _op,
          locationId: _loc,
        );

        expect(
          bundle.noConnectedRowForCategory(IntegrationCategory.pos),
          isFalse,
        );
        expect(
          bundle.noConnectedRowForCategory(IntegrationCategory.labor),
          isTrue,
        );
        expect(
          bundle.noConnectedRowForCategory(IntegrationCategory.reservation),
          isTrue,
        );
      },
    );

    test('a disconnected/error row does NOT flip the demo flag off', () async {
      final pool = _Pool(
        listRows: <PostgresRow>[
          _connectionRow(
            connectionId: 'cnx-d',
            vendorId: 'square',
            category: 'pos',
            status: 'disconnected',
            disconnectReason: 'operator_action',
          ),
          _connectionRow(
            connectionId: 'cnx-e',
            vendorId: 'opentable',
            category: 'reservation',
            status: 'error',
            disconnectReason: 'vendor_revoked',
          ),
        ],
      );
      final repo = ConnectorConnectionListRepository(
        TenantTransactionWrapper(pool),
      );

      final bundle = await repo.listForLocation(
        operatorId: _op,
        locationId: _loc,
      );

      expect(
        bundle.noConnectedRowForCategory(IntegrationCategory.pos),
        isTrue,
      );
      expect(
        bundle.noConnectedRowForCategory(IntegrationCategory.reservation),
        isTrue,
      );
    });

    test('rejects blank operatorId / locationId before opening a tx', () async {
      final pool = _Pool();
      final repo = ConnectorConnectionListRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.listForLocation(operatorId: '   ', locationId: _loc),
        throwsArgumentError,
      );
      expect(
        () => repo.listForLocation(operatorId: _op, locationId: '   '),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty);
    });
  });
}

PostgresRow _connectionRow({
  required String connectionId,
  required String vendorId,
  required String category,
  required String status,
  String? module,
  Map<String, Object?>? metadata,
  bool webhookProvisioned = false,
  String? disconnectReason,
  String? lastErrorMessage,
}) {
  return <String, Object?>{
    'connection_id': connectionId,
    'vendor_id': vendorId,
    'category': category,
    'status': status,
    'module': module,
    'metadata': metadata ?? const <String, Object?>{},
    'last_sync_at': DateTime.utc(2026, 5, 7, 11, 30),
    'last_error_at': lastErrorMessage == null
        ? null
        : DateTime.utc(2026, 5, 7, 11),
    'last_error_message': lastErrorMessage,
    'disconnect_reason': disconnectReason,
    'webhook_url_provisioned': webhookProvisioned,
    'created_at': DateTime.utc(2026, 5, 7, 9),
    'updated_at': DateTime.utc(2026, 5, 7, 11, 30),
  };
}

class _Pool implements PostgresPool {
  _Pool({this.listRows = const <PostgresRow>[]});

  final List<PostgresRow> listRows;
  final List<_Tx> transactions = <_Tx>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _Tx(listRows: listRows);
    transactions.add(tx);
    return tx;
  }
}

class _Tx extends PostgresTransaction {
  _Tx({required this.listRows});

  final List<PostgresRow> listRows;
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
    if (sql.contains('from public.connector_connection')) {
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
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
