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

  // V1.F NEW coverage — input validation, state-transition guards,
  // tenant isolation, RLS-block diagnostic, and mark* SQL shapes.
  group('ConnectorBackfillJobRepository.enqueueFirstBackfill (NEW)', () {
    test(
      'forwards SET LOCAL operator_id, location_id, and user_id before '
      'executing the enqueue CTE',
      () async {
        final pool = _Pool(
          enqueueRows: <PostgresRow>[_jobRow(status: 'pending')],
        );
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.enqueueFirstBackfill(
          operatorId: _op,
          locationId: _loc,
          connectionId: _connection,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 7, 12),
          windowEnd: DateTime.utc(2026, 5, 6, 12),
          actorUserId: _actor,
        );

        final tx = pool.transactions.single;
        final firstWriteIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('connector_backfill_jobs'),
        );
        expect(
          firstWriteIndex,
          greaterThan(2),
          reason: 'tenant SET LOCAL trio must run BEFORE the table is touched',
        );
        expect(
          tx.executedSql.take(firstWriteIndex),
          containsAll(<Matcher>[
            contains("set_config('app.operator_id'"),
            contains("set_config('app.location_id'"),
            contains("set_config('app.user_id'"),
          ]),
        );
      },
    );

    test('rejects blank connectionId / vendorId before opening a tx', () async {
      final pool = _Pool();
      final repo = ConnectorBackfillJobRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.enqueueFirstBackfill(
          operatorId: _op,
          locationId: _loc,
          connectionId: '   ',
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 7, 12),
          windowEnd: DateTime.utc(2026, 5, 6, 12),
        ),
        throwsArgumentError,
      );
      expect(
        () => repo.enqueueFirstBackfill(
          operatorId: _op,
          locationId: _loc,
          connectionId: _connection,
          vendorId: '  ',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 7, 12),
          windowEnd: DateTime.utc(2026, 5, 6, 12),
        ),
        throwsArgumentError,
      );
      expect(
        pool.transactions,
        isEmpty,
        reason: 'guard rails must run before any transaction opens',
      );
    });

    test(
      'throws StateError when both the CTE and the SELECT-fallback '
      'return zero rows (RLS denied or active row vanished)',
      () async {
        final pool = _Pool(
          enqueueRows: const <PostgresRow>[],
          fallbackRows: const <PostgresRow>[],
        );
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
            windowStart: DateTime.utc(2026, 3, 7, 12),
            windowEnd: DateTime.utc(2026, 5, 6, 12),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'wires distinct tenant SET LOCAL chains for two different operators '
      'so cross-tenant isolation holds at the wrapper boundary',
      () async {
        const String opB = '99999999-9999-1999-1999-999999999999';
        const String locB = 'aaaaaaaa-aaaa-1aaa-1aaa-aaaaaaaaaaaa';
        final pool = _Pool(
          enqueueRows: <PostgresRow>[_jobRow(status: 'pending')],
        );
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.enqueueFirstBackfill(
          operatorId: _op,
          locationId: _loc,
          connectionId: _connection,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 7, 12),
          windowEnd: DateTime.utc(2026, 5, 6, 12),
        );
        await repo.enqueueFirstBackfill(
          operatorId: opB,
          locationId: locB,
          connectionId: _connection,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 7, 12),
          windowEnd: DateTime.utc(2026, 5, 6, 12),
        );

        expect(
          pool.transactions,
          hasLength(2),
          reason: 'each tenant gets its own transaction and SET LOCAL chain',
        );
        final txA = pool.transactions[0];
        final txB = pool.transactions[1];
        expect(
          txA.parameters.firstWhere(
            (p) => p.containsKey('value'),
          )['value'],
          equals(_op),
        );
        expect(
          txB.parameters.firstWhere(
            (p) => p.containsKey('value'),
          )['value'],
          equals(opB),
        );
      },
    );
  });

  group('ConnectorBackfillJobRepository.claimNext (NEW)', () {
    test(
      'rejects blank workerId and non-positive claimStaleAfter before SQL',
      () async {
        final pool = _Pool();
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );
        expect(
          () => repo.claimNext(
            operatorId: _op,
            locationId: _loc,
            workerId: '  ',
          ),
          throwsArgumentError,
        );
        expect(
          () => repo.claimNext(
            operatorId: _op,
            locationId: _loc,
            workerId: 'worker-1',
            claimStaleAfter: Duration.zero,
          ),
          throwsArgumentError,
        );
        expect(
          () => repo.claimNext(
            operatorId: _op,
            locationId: _loc,
            workerId: 'worker-1',
            claimStaleAfter: const Duration(seconds: -5),
          ),
          throwsArgumentError,
        );
        expect(pool.transactions, isEmpty);
      },
    );

    test(
      'claim SQL contains the stale-lease recovery predicate so a worker '
      'that crashed mid-claim can be re-claimed after the timeout',
      () async {
        final pool = _Pool(
          claimRows: <PostgresRow>[
            _jobRow(
              status: 'running',
              workerId: 'worker-2',
              claimedAt: DateTime.utc(2026, 5, 6, 12),
              attemptCount: 3,
            ),
          ],
        );
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.claimNext(
          operatorId: _op,
          locationId: _loc,
          workerId: 'worker-2',
          claimStaleAfter: const Duration(minutes: 1),
        );
        final claimSql = pool.transactions.single.executedSql.firstWhere(
          (sql) => sql.contains('for update skip locked'),
        );
        expect(claimSql, contains('claimed_at is null'));
        expect(
          claimSql,
          contains("claimed_at < now() - (@claim_stale_seconds * interval"),
        );
        expect(claimSql, contains("mode = 'first_backfill'"));
        expect(
          pool.transactions.single.parameters.last['claim_stale_seconds'],
          equals(60),
        );
      },
    );
  });

  group('ConnectorBackfillJobRepository.markRunning (NEW)', () {
    test(
      'markRunning UPDATE shape: increments attempt_count, sets worker_id, '
      'flips status to running, only matches pending/running rows',
      () async {
        final pool = _Pool(
          updateRows: <PostgresRow>[
            _jobRow(
              status: 'running',
              workerId: 'worker-resume',
              claimedAt: DateTime.utc(2026, 5, 6, 12),
              attemptCount: 4,
            ),
          ],
        );
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );
        final job = await repo.markRunning(
          operatorId: _op,
          locationId: _loc,
          jobId: '99999999-9999-9999-9999-999999999999',
          workerId: 'worker-resume',
          actorUserId: _actor,
        );
        expect(job, isNotNull);
        expect(job!.status, equals(FirstConnectionBackfillJobStatus.running));
        expect(job.workerId, equals('worker-resume'));

        final updateSql = pool.transactions.single.executedSql.firstWhere(
          (sql) => sql.startsWith('update public.connector_backfill_jobs'),
        );
        expect(updateSql, contains("status = 'running'"));
        expect(updateSql, contains('claimed_at = now()'));
        expect(updateSql, contains('completed_at = null'));
        expect(updateSql, contains('attempt_count = attempt_count + 1'));
        expect(updateSql, contains("status in ('pending', 'running')"));
      },
    );

    test('markRunning rejects blank jobId and blank workerId', () async {
      final pool = _Pool();
      final repo = ConnectorBackfillJobRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.markRunning(
          operatorId: _op,
          locationId: _loc,
          jobId: '   ',
          workerId: 'worker-1',
        ),
        throwsArgumentError,
      );
      expect(
        () => repo.markRunning(
          operatorId: _op,
          locationId: _loc,
          jobId: '99999999-9999-9999-9999-999999999999',
          workerId: ' ',
        ),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty);
    });
  });

  group('ConnectorBackfillJobRepository.markFailed (NEW)', () {
    test(
      'markFailed UPDATE shape: records last_error, stamps completed_at, '
      'only matches a row already running',
      () async {
        final pool = _Pool(
          updateRows: <PostgresRow>[
            _jobRow(
              status: 'failed',
              completedAt: DateTime.utc(2026, 5, 6, 13),
              lastError: 'vendor 500',
            ),
          ],
        );
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );
        final job = await repo.markFailed(
          operatorId: _op,
          locationId: _loc,
          jobId: '99999999-9999-9999-9999-999999999999',
          errorMessage: 'vendor 500',
          actorUserId: _actor,
        );
        expect(job, isNotNull);
        expect(job!.status, equals(FirstConnectionBackfillJobStatus.failed));
        expect(job.lastError, equals('vendor 500'));

        final sql = pool.transactions.single.executedSql.firstWhere(
          (statement) => statement.contains("status = 'failed'"),
        );
        expect(sql, contains('completed_at = now()'));
        expect(sql, contains('last_error = @error_message'));
        expect(sql, contains("and status = 'running'"));
      },
    );

    test('markFailed rejects blank jobId or blank errorMessage', () async {
      final pool = _Pool();
      final repo = ConnectorBackfillJobRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.markFailed(
          operatorId: _op,
          locationId: _loc,
          jobId: '  ',
          errorMessage: 'boom',
        ),
        throwsArgumentError,
      );
      expect(
        () => repo.markFailed(
          operatorId: _op,
          locationId: _loc,
          jobId: '99999999-9999-9999-9999-999999999999',
          errorMessage: '   ',
        ),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty);
    });
  });

  group('ConnectorBackfillJobRepository.markSucceeded (NEW)', () {
    test(
      'markSucceeded returns null when no row matches (lost lease, wrong '
      'jobId, or row already finalized) so caller can no-op',
      () async {
        final pool = _Pool(updateRows: const <PostgresRow>[]);
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );
        final job = await repo.markSucceeded(
          operatorId: _op,
          locationId: _loc,
          jobId: '99999999-9999-9999-9999-999999999999',
          cursorToken: 'cursor-x',
          lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
        );
        expect(
          job,
          isNull,
          reason: 'no row to seal => null, the worker treats this as '
              'a benign race outcome instead of crashing',
        );

        final tx = pool.transactions.single;
        final sql = tx.executedSql.firstWhere(
          (statement) => statement.contains("status = 'succeeded'"),
        );
        expect(sql, contains("and status = 'running'"));
      },
    );

    test('markSucceeded rejects blank jobId or blank cursorToken', () async {
      final pool = _Pool();
      final repo = ConnectorBackfillJobRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.markSucceeded(
          operatorId: _op,
          locationId: _loc,
          jobId: '   ',
          cursorToken: 'cursor-1',
          lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
        ),
        throwsArgumentError,
      );
      expect(
        () => repo.markSucceeded(
          operatorId: _op,
          locationId: _loc,
          jobId: '99999999-9999-9999-9999-999999999999',
          cursorToken: '',
          lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
        ),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty);
    });
  });

  group('ConnectorBackfillJobRepository.releaseForResume (NEW)', () {
    test(
      'releaseForResume rejects blank jobId, blank cursorToken, and a '
      'non-null but blank errorMessage',
      () async {
        final pool = _Pool();
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );
        expect(
          () => repo.releaseForResume(
            operatorId: _op,
            locationId: _loc,
            jobId: '   ',
            cursorToken: 'c',
            lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
          ),
          throwsArgumentError,
        );
        expect(
          () => repo.releaseForResume(
            operatorId: _op,
            locationId: _loc,
            jobId: '99999999-9999-9999-9999-999999999999',
            cursorToken: '   ',
            lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
          ),
          throwsArgumentError,
        );
        expect(
          () => repo.releaseForResume(
            operatorId: _op,
            locationId: _loc,
            jobId: '99999999-9999-9999-9999-999999999999',
            cursorToken: 'c',
            lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
            errorMessage: '   ',
          ),
          throwsArgumentError,
          reason: 'a blank string for errorMessage is meaningless and '
              'should not silently be accepted',
        );
        expect(pool.transactions, isEmpty);
      },
    );

    test(
      'releaseForResume passes a null errorMessage through so a '
      'non-error pause (e.g. quota tick) does not stamp a fake error',
      () async {
        final pool = _Pool(
          updateRows: <PostgresRow>[
            _jobRow(
              status: 'pending',
              cursorToken: 'cursor-pause',
              lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
            ),
          ],
        );
        final repo = ConnectorBackfillJobRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.releaseForResume(
          operatorId: _op,
          locationId: _loc,
          jobId: '99999999-9999-9999-9999-999999999999',
          cursorToken: 'cursor-pause',
          lastModifiedSeen: DateTime.utc(2026, 5, 6, 11),
        );
        final params = pool.transactions.single.parameters.firstWhere(
          (p) => p['cursor_token'] == 'cursor-pause',
        );
        expect(params['error_message'], isNull);
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
