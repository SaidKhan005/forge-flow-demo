import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

const String _op = '11111111-1111-1111-1111-111111111111';
const String _loc = '22222222-2222-2222-2222-222222222222';
const String _actor = '33333333-3333-3333-3333-333333333333';
const String _connection = '44444444-4444-4444-4444-444444444444';

void main() {
  group('ConnectorBackfillJobRepository.enqueueFirstBackfill', () {
    test('idempotently returns the active job for the same '
        'connection/category/window', () async {
      final pool = _Pool(
        enqueueRows: <PostgresRow>[_jobRow(status: 'pending')],
      );
      final repo = ConnectorBackfillJobRepository(
        TenantTransactionWrapper(pool),
      );

      final job = await repo.enqueueFirstBackfill(
        operatorId: _op,
        locationId: _loc,
        connectionId: _connection,
        vendorId: 'square',
        category: IntegrationCategory.pos,
        windowStart: DateTime.utc(2026, 3, 7, 12),
        windowEnd: DateTime.utc(2026, 5, 6, 12),
        actorUserId: _actor,
      );

      expect(job.connectionId, equals(_connection));
      expect(job.status, equals(FirstConnectionBackfillJobStatus.pending));
      expect(job.category, equals(IntegrationCategory.pos));

      final tx = pool.transactions.single;
      expect(tx.executedSql[0], contains("'app.operator_id'"));
      expect(tx.parameters[0]['value'], equals(_op));
      expect(tx.executedSql[1], contains("'app.location_id'"));
      expect(tx.parameters[1]['value'], equals(_loc));
      expect(tx.executedSql[2], contains("'app.user_id'"));
      expect(tx.parameters[2]['value'], equals(_actor));

      final enqueueSql = tx.executedSql.firstWhere(
        (sql) => sql.contains('insert into public.connector_backfill_jobs'),
      );
      expect(enqueueSql, contains('with existing as'));
      expect(enqueueSql, contains("and status in ('pending', 'running')"));
      expect(enqueueSql, contains('on conflict do nothing'));
      expect(enqueueSql, contains('union all'));
      expect(enqueueSql, contains('select * from existing'));

      final params = tx.parameters.firstWhere(
        (p) => p['connection_id'] == _connection,
      );
      expect(params['category'], equals('pos'));
      expect(params['mode'], equals('first_backfill'));
      expect(params['vendor_id'], equals('square'));
      expect(params['window_start'], equals(DateTime.utc(2026, 3, 7, 12)));
      expect(params['window_end'], equals(DateTime.utc(2026, 5, 6, 12)));
    });

    test(
      'falls back to SELECT when a concurrent insert wins the race',
      () async {
        final pool = _Pool(
          enqueueRows: const <PostgresRow>[],
          fallbackRows: <PostgresRow>[_jobRow(status: 'running')],
        );
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );

        final job = await repo.enqueueFirstBackfill(
          operatorId: _op,
          locationId: _loc,
          connectionId: _connection,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 7, 12),
          windowEnd: DateTime.utc(2026, 5, 6, 12),
        );

        expect(job.status, equals(FirstConnectionBackfillJobStatus.running));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('from public.connector_backfill_jobs'),
          ),
          hasLength(2),
        );
      },
    );

    test('rejects windows wider than 60 days before issuing SQL', () async {
      final pool = _Pool();
      final repo = ConnectorBackfillJobRepository(
        TenantTransactionWrapper(pool),
      );

      expect(
        () => repo.enqueueFirstBackfill(
          operatorId: _op,
          locationId: _loc,
          connectionId: _connection,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 1),
          windowEnd: DateTime.utc(2026, 5, 1, 0, 0, 1),
        ),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty);
    });
  });

  group('ConnectorBackfillJobRepository.claimNext', () {
    test('claims one pending or stale running job with SKIP LOCKED and '
        'never claims completed jobs', () async {
      final claimedAt = DateTime.utc(2026, 5, 6, 12);
      final pool = _Pool(
        claimRows: <PostgresRow>[
          _jobRow(
            status: 'running',
            workerId: 'worker-1',
            claimedAt: claimedAt,
            attemptCount: 2,
          ),
        ],
      );
      final repo = ConnectorBackfillJobRepository(
        TenantTransactionWrapper(pool),
      );

      final job = await repo.claimNext(
        operatorId: _op,
        locationId: _loc,
        workerId: 'worker-1',
        claimStaleAfter: const Duration(minutes: 5),
      );

      expect(job, isNotNull);
      expect(job!.status, equals(FirstConnectionBackfillJobStatus.running));
      expect(job.workerId, equals('worker-1'));
      expect(job.attemptCount, equals(2));

      final tx = pool.transactions.single;
      final claimSql = tx.executedSql.firstWhere(
        (sql) => sql.contains('for update skip locked'),
      );
      expect(claimSql, contains("status = 'pending'"));
      expect(claimSql, contains("status = 'running'"));
      expect(claimSql, isNot(contains("status = 'succeeded'")));
      expect(claimSql, isNot(contains("status = 'failed'")));
      expect(claimSql, contains('attempt_count = attempt_count + 1'));
      expect(claimSql, contains('order by created_at asc'));
      expect(tx.parameters.last['claim_stale_seconds'], equals(300));
    });

    test('returns null when no claimable job exists', () async {
      final pool = _Pool(claimRows: const <PostgresRow>[]);
      final repo = ConnectorBackfillJobRepository(
        TenantTransactionWrapper(pool),
      );

      final job = await repo.claimNext(
        operatorId: _op,
        locationId: _loc,
        workerId: 'worker-1',
      );

      expect(job, isNull);
    });
  });

  group('ConnectorBackfillJobRepository status updates', () {
    test(
      'markSucceeded persists cursor and last-modified resume state',
      () async {
        final pool = _Pool(
          updateRows: <PostgresRow>[
            _jobRow(
              status: 'succeeded',
              cursorToken: 'cursor-9',
              lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
              completedAt: DateTime.utc(2026, 5, 6, 12),
            ),
          ],
        );
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );

        final job = await repo.markSucceeded(
          operatorId: _op,
          locationId: _loc,
          jobId: '99999999-9999-9999-9999-999999999999',
          cursorToken: 'cursor-9',
          lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
          actorUserId: _actor,
        );

        expect(job, isNotNull);
        expect(job!.status, equals(FirstConnectionBackfillJobStatus.succeeded));
        expect(job.cursorToken, equals('cursor-9'));
        expect(job.lastModifiedSeen, equals(DateTime.utc(2026, 5, 6, 11)));

        final sql = pool.transactions.single.executedSql.firstWhere(
          (statement) => statement.contains("status = 'succeeded'"),
        );
        expect(sql, contains('last_error = null'));
        expect(sql, contains("and status = 'running'"));
      },
    );

    test(
      'releaseForResume clears the lease and returns the job to pending',
      () async {
        final pool = _Pool(
          updateRows: <PostgresRow>[
            _jobRow(
              status: 'pending',
              cursorToken: 'cursor-resume',
              lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
              lastError: 'time budget reached',
            ),
          ],
        );
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );

        final job = await repo.releaseForResume(
          operatorId: _op,
          locationId: _loc,
          jobId: '99999999-9999-9999-9999-999999999999',
          cursorToken: 'cursor-resume',
          lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
          errorMessage: 'time budget reached',
        );

        expect(job, isNotNull);
        expect(job!.status, equals(FirstConnectionBackfillJobStatus.pending));
        expect(job.lastError, equals('time budget reached'));

        final sql = pool.transactions.single.executedSql.firstWhere(
          (statement) => statement.contains("status = 'pending'"),
        );
        expect(sql, contains('claimed_at = null'));
        expect(sql, contains('worker_id = null'));
        expect(sql, contains("and status = 'running'"));
      },
    );
  });
}

PostgresRow _jobRow({
  String status = 'pending',
  String vendorId = 'square',
  String category = 'pos',
  String? cursorToken,
  DateTime? lastModifiedSeen,
  int attemptCount = 0,
  String? workerId,
  DateTime? claimedAt,
  DateTime? completedAt,
  String? lastError,
}) {
  return <String, Object?>{
    'job_id': '99999999-9999-9999-9999-999999999999',
    'operator_id': _op,
    'location_id': _loc,
    'connection_id': _connection,
    'vendor_id': vendorId,
    'category': category,
    'window_start': DateTime.utc(2026, 3, 7, 12),
    'window_end': DateTime.utc(2026, 5, 6, 12),
    'status': status,
    'cursor_token': cursorToken,
    'last_modified_seen': lastModifiedSeen,
    'attempt_count': attemptCount,
    'worker_id': workerId,
    'claimed_at': claimedAt,
    'completed_at': completedAt,
    'last_error': lastError,
    'created_at': DateTime.utc(2026, 5, 6, 10),
    'updated_at': DateTime.utc(2026, 5, 6, 11),
  };
}

class _Pool implements PostgresPool {
  _Pool({
    this.enqueueRows = const <PostgresRow>[],
    this.fallbackRows = const <PostgresRow>[],
    this.claimRows = const <PostgresRow>[],
    this.updateRows = const <PostgresRow>[],
  });

  final List<PostgresRow> enqueueRows;
  final List<PostgresRow> fallbackRows;
  final List<PostgresRow> claimRows;
  final List<PostgresRow> updateRows;
  final List<_Tx> transactions = <_Tx>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _Tx(
      enqueueRows: enqueueRows,
      fallbackRows: fallbackRows,
      claimRows: claimRows,
      updateRows: updateRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _Tx extends PostgresTransaction {
  _Tx({
    required this.enqueueRows,
    required this.fallbackRows,
    required this.claimRows,
    required this.updateRows,
  });

  final List<PostgresRow> enqueueRows;
  final List<PostgresRow> fallbackRows;
  final List<PostgresRow> claimRows;
  final List<PostgresRow> updateRows;
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
    if (sql.contains('insert into public.connector_backfill_jobs')) {
      return enqueueRows;
    }
    if (sql.contains('for update skip locked')) {
      return claimRows;
    }
    if (sql.startsWith('update public.connector_backfill_jobs')) {
      return updateRows;
    }
    if (sql.contains('from public.connector_backfill_jobs')) {
      return fallbackRows;
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
