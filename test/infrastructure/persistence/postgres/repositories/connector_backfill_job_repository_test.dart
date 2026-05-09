import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
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

  // ───────────────────────────────────────────────────────────────────
  // Phase 3B contract extensions (PR #450 ground-out)
  //
  // The three groups below pin contracts the in-memory simulator at
  // `tool/pressure/p3b_backfill_flood.dart` proved against
  // `InMemoryBackfillStore` and the runner at
  // `test/load/pressure/p3b_backfill_flood_runner_test.dart` asserted
  // at the harness boundary. These tests gate on `PHASE_6_PG_URL` (or
  // `--dart-define=PHASE_6_PG_URL=...`); when unset they emit a single
  // `setup_skipped` test result so a CI run without staging access is
  // unambiguous and not silently no-op'd.
  //
  // CONTRACT GAP findings live as `// CONTRACT GAP:` comments on the
  // assertions they cover. Per the prompt, no production-code edits in
  // this PR — gaps surface in the PR body for triage.
  // ───────────────────────────────────────────────────────────────────

  const definedUrl = String.fromEnvironment('PHASE_6_PG_URL');
  final phase6PgUrl = definedUrl.isNotEmpty
      ? definedUrl
      : (Platform.environment['PHASE_6_PG_URL'] ?? '');
  final hasDb = phase6PgUrl.isNotEmpty;

  // Always print a banner so the CI log makes the runtime / skip
  // distinction obvious without parsing test output. Mirrors the
  // pattern used by `p2b_sink_pressure_harness_test.dart`.
  // ignore: avoid_print
  print(
    '[connector_backfill_job_repository_test] phase6_pg_url_set=$hasDb '
    '(set PHASE_6_PG_URL or --dart-define=PHASE_6_PG_URL to drive '
    'real-DB contracts)',
  );

  group(
    'ConnectorBackfillJobRepository — Phase 3B contract: FOR UPDATE '
    'SKIP LOCKED claim semantics under contention (real DB)',
    () {
      if (!hasDb) {
        test(
          'setup_skipped — PHASE_6_PG_URL unset; staging connection '
          'required to exercise SKIP LOCKED contention',
          () {
            // ignore: avoid_print
            print(
              '[skip-locked-contract] setup_skipped: PHASE_6_PG_URL '
              'unset. The contract that two simultaneous claims return '
              'DIFFERENT rows can only be proven against a real '
              'Postgres because Dart is single-isolate; the in-memory '
              '_Pool serializes by construction.',
            );
            expect(true, isTrue);
          },
        );
        return;
      }

      late PackagePostgresPool pool;
      late TenantTransactionWrapper wrapper;
      late ConnectorBackfillJobRepository repo;

      // Phase-6 sentinel UUIDs. Distinct from the constants at the top
      // of this file so the SKIP LOCKED group cannot collide with the
      // mock-pool groups even if a future refactor shares state.
      const String op = '00000000-0000-6000-9000-000000003b01';
      const String loc = '00000000-0000-6000-9000-000000003b02';
      const String connectionId = '00000000-0000-6000-9000-000000003b03';
      const String actor = '00000000-0000-6000-9000-000000003b04';

      Future<void> seedConnection() async {
        await wrapper.runAsSystem<void>(
          (exec) async {
            await exec.execute(
              'insert into public.locations '
              '(operator_id, location_id, name) '
              'values (@op::uuid, @loc::uuid, @name) '
              'on conflict (operator_id, location_id) do nothing',
              parameters: <String, Object?>{
                'op': op,
                'loc': loc,
                'name': 'phase-6-skip-locked-test',
              },
            );
            await exec.execute(
              'insert into public.connector_connection ('
              'connection_id, operator_id, location_id, vendor_id, '
              'category, status'
              ') values ('
              '@cid::uuid, @op::uuid, @loc::uuid, @vendor, @cat, '
              "'connected') "
              'on conflict (connection_id) do nothing',
              parameters: <String, Object?>{
                'cid': connectionId,
                'op': op,
                'loc': loc,
                'vendor': 'square',
                'cat': 'pos',
              },
            );
          },
          reason: 'phase_6_skip_locked_test_seed',
        );
      }

      Future<void> cleanupRows() async {
        await wrapper.runAsSystem<void>(
          (exec) async {
            await exec.execute(
              'delete from public.connector_backfill_jobs '
              'where operator_id = @op::uuid',
              parameters: <String, Object?>{'op': op},
            );
          },
          reason: 'phase_6_skip_locked_test_cleanup',
        );
      }

      setUpAll(() async {
        pool = PackagePostgresPool.fromUrl(phase6PgUrl);
        wrapper = TenantTransactionWrapper(pool);
        repo = ConnectorBackfillJobRepository(wrapper);
        await seedConnection();
        await cleanupRows();
      });

      tearDown(() async {
        await cleanupRows();
      });

      test(
        'two concurrent claimNext calls return DIFFERENT rows when at '
        'least 2 unclaimed rows exist',
        () async {
          // Enqueue two distinct backfill jobs (different windows so
          // the active-uniqueness index does not collapse them).
          final jobA = await repo.enqueueFirstBackfill(
            operatorId: op,
            locationId: loc,
            connectionId: connectionId,
            vendorId: 'square',
            category: IntegrationCategory.pos,
            windowStart: DateTime.utc(2026, 3, 1, 12),
            windowEnd: DateTime.utc(2026, 4, 30, 12),
            actorUserId: actor,
          );
          final jobB = await repo.enqueueFirstBackfill(
            operatorId: op,
            locationId: loc,
            connectionId: connectionId,
            vendorId: 'square',
            category: IntegrationCategory.pos,
            windowStart: DateTime.utc(2026, 5, 1, 12),
            windowEnd: DateTime.utc(2026, 6, 30, 12),
            actorUserId: actor,
          );
          expect(jobA.jobId, isNot(equals(jobB.jobId)));

          // Race two claims. Each `claimNext` opens its own
          // transaction via the wrapper; SKIP LOCKED guarantees they
          // walk over each other's locked row.
          final results = await Future.wait<FirstConnectionBackfillJob?>([
            repo.claimNext(
              operatorId: op,
              locationId: loc,
              workerId: 'pod-A',
              actorUserId: actor,
            ),
            repo.claimNext(
              operatorId: op,
              locationId: loc,
              workerId: 'pod-B',
              actorUserId: actor,
            ),
          ]);

          final claimedA = results[0];
          final claimedB = results[1];
          expect(claimedA, isNotNull);
          expect(claimedB, isNotNull);
          expect(
            claimedA!.jobId,
            isNot(equals(claimedB!.jobId)),
            reason: 'FOR UPDATE SKIP LOCKED must hand the two pods '
                'distinct rows when ≥2 unclaimed rows exist',
          );
          expect(claimedA.workerId, equals('pod-A'));
          expect(claimedB.workerId, equals('pod-B'));
          expect(
            <String>{claimedA.jobId, claimedB.jobId},
            equals(<String>{jobA.jobId, jobB.jobId}),
          );
        },
      );

      test(
        'claimNext against an empty queue returns null without '
        'blocking',
        () async {
          // No jobs enqueued (cleanupRows ran in tearDown of prior
          // test). claimNext should fall through immediately.
          final stopwatch = Stopwatch()..start();
          final claimed = await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-empty',
            actorUserId: actor,
          );
          stopwatch.stop();

          expect(claimed, isNull);
          // 5s is the per-statement timeout in
          // `kPostgresPerStatementTimeout`; we want significantly
          // less. SKIP LOCKED + no rows must NOT block.
          expect(
            stopwatch.elapsed,
            lessThan(const Duration(seconds: 2)),
            reason:
                'an empty-queue claim must not block on row locks; '
                'took ${stopwatch.elapsed}',
          );
        },
      );

      test(
        'a row claimed but not yet committed in tx A is INVISIBLE to '
        'a parallel claimNext from tx B; after tx A commits, tx B '
        'sees the next row',
        () async {
          // Enqueue exactly one job. Open a long-lived transaction
          // that holds the row lock, then issue a parallel claim from
          // a separate transaction and assert it returns null.
          final jobA = await repo.enqueueFirstBackfill(
            operatorId: op,
            locationId: loc,
            connectionId: connectionId,
            vendorId: 'square',
            category: IntegrationCategory.pos,
            windowStart: DateTime.utc(2026, 3, 1, 12),
            windowEnd: DateTime.utc(2026, 4, 30, 12),
            actorUserId: actor,
          );

          // Tx A: claim the row inside a long-lived transaction held
          // open via a Completer gate. We mirror the production CTE
          // shape so the row IS row-locked (via SKIP LOCKED). We
          // capture only the `job_id` rather than reconstructing a
          // `FirstConnectionBackfillJob` — the contract under test is
          // about lock visibility, not the model.
          final txAGate = Completer<void>();
          final txAClaimed = Completer<String?>();
          final txAFuture = wrapper.runInTenantContext<void>(
            TenantContext(
              operatorId: op,
              locationId: loc,
              userId: actor,
            ),
            (exec) async {
              final rows = await exec.query(
                'with claimed as ('
                '  select job_id from public.connector_backfill_jobs '
                '  where operator_id = @operator_id::uuid '
                '  and location_id = @location_id::uuid '
                "  and mode = 'first_backfill' "
                "  and status = 'pending' "
                '  for update skip locked '
                '  limit 1'
                '), updated as ('
                '  update public.connector_backfill_jobs jobs '
                "  set status = 'running', "
                '      claimed_at = now(), '
                "      worker_id = 'pod-A-holding', "
                '      attempt_count = attempt_count + 1, '
                '      updated_at = now() '
                '  from claimed '
                '  where jobs.job_id = claimed.job_id '
                '  returning jobs.job_id::text as job_id'
                ') select * from updated',
                parameters: <String, Object?>{
                  'operator_id': op,
                  'location_id': loc,
                },
              );
              txAClaimed.complete(
                rows.isEmpty ? null : rows.single['job_id'] as String?,
              );
              // Hold the transaction open until the gate releases.
              await txAGate.future;
            },
          );

          final claimedInsideA = await txAClaimed.future;
          expect(
            claimedInsideA,
            equals(jobA.jobId),
            reason: 'tx A must claim the only enqueued row',
          );

          // Tx B (separate transaction) tries to claim while tx A
          // holds the row lock. SKIP LOCKED must yield zero rows.
          final claimedInB = await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-B',
            actorUserId: actor,
          );
          expect(
            claimedInB,
            isNull,
            reason: 'while tx A holds the row lock, SKIP LOCKED in '
                'tx B must skip the row — never block, never grab '
                'the same row',
          );

          // Release tx A so it commits. Tx B now sees the row in
          // `running` state but with the lock released; the row is
          // not eligible for a new claim until either it terminates
          // or its claim goes stale. So a fresh claim from tx C
          // returns null until we release-for-resume.
          txAGate.complete();
          await txAFuture;

          final claimedAgain = await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-C',
            actorUserId: actor,
          );
          expect(
            claimedAgain,
            isNull,
            reason: 'after tx A commits with status=running and a '
                'fresh claimed_at, the row is not stale and pod-C '
                'must NOT claim it (no held-lock leak — but also no '
                'spurious re-claim before claim_stale_after elapses)',
          );

          // Now release the row for resume so the next claim picks
          // it up. This proves the "no held lock leaks" branch: the
          // row IS available again for the next claim, the lock did
          // not stay engaged across tx boundaries.
          await repo.releaseForResume(
            operatorId: op,
            locationId: loc,
            jobId: jobA.jobId,
            cursorToken: 'cursor-resume',
            lastModifiedSeen: DateTime.utc(2026, 4, 30, 12),
            actorUserId: actor,
          );
          final reclaimed = await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-D',
            actorUserId: actor,
          );
          expect(reclaimed, isNotNull);
          expect(
            reclaimed!.jobId,
            equals(jobA.jobId),
            reason: 'after the row returns to pending, the next '
                'claimNext must see it (no leftover row lock)',
          );
          expect(reclaimed.workerId, equals('pod-D'));
        },
      );
    },
  );

  group(
    'ConnectorBackfillJobRepository — Phase 3B contract: demo-flip '
    'race resolution does not wedge the in-flight job (real DB)',
    () {
      // CONTRACT GAP: `connector_backfill_job_repository.dart` has NO
      // demo-flip-aware code path. The demo-flip evaluation lives in
      // `WorkerCanonicalSink.evaluateDemoFlip` (called by the worker
      // dispatch *after* `markSucceeded` returns). The repository
      // observes neither `demo_mode_state` nor any flip event; the
      // job's status transitions are independent of the flip outcome.
      //
      // What we CAN pin here is the weaker invariant that the repo
      // exercises in Phase 3B's "complete-then-flip" path: a job that
      // started in `running` reaches a terminal state regardless of
      // any concurrent mutation to `demo_mode_state` for the same
      // (operator, location, category) triple. The strong invariant
      // ("audit row for the flip event is emitted exactly once") must
      // be tested at the worker layer (covered by
      // `test/load/pressure/p3b_backfill_flood_runner_test.dart`),
      // not here.

      if (!hasDb) {
        test(
          'setup_skipped — PHASE_6_PG_URL unset; staging connection '
          'required to exercise demo-flip race resolution',
          () {
            // ignore: avoid_print
            print(
              '[demo-flip-race-contract] setup_skipped: PHASE_6_PG_URL '
              'unset. The repo does not branch on demo_mode_state, '
              'so the contract this group can pin is "lifecycle is '
              'demo-state independent" — still requires a real DB.',
            );
            expect(true, isTrue);
          },
        );
        return;
      }

      late PackagePostgresPool pool;
      late TenantTransactionWrapper wrapper;
      late ConnectorBackfillJobRepository repo;

      const String op = '00000000-0000-6000-9000-00000000fa01';
      const String loc = '00000000-0000-6000-9000-00000000fa02';
      const String connectionId =
          '00000000-0000-6000-9000-00000000fa03';
      const String actor = '00000000-0000-6000-9000-00000000fa04';

      Future<void> seedConnection() async {
        await wrapper.runAsSystem<void>(
          (exec) async {
            await exec.execute(
              'insert into public.locations '
              '(operator_id, location_id, name) '
              'values (@op::uuid, @loc::uuid, @name) '
              'on conflict (operator_id, location_id) do nothing',
              parameters: <String, Object?>{
                'op': op,
                'loc': loc,
                'name': 'phase-6-demo-flip-test',
              },
            );
            await exec.execute(
              'insert into public.connector_connection ('
              'connection_id, operator_id, location_id, vendor_id, '
              'category, status'
              ') values ('
              '@cid::uuid, @op::uuid, @loc::uuid, @vendor, @cat, '
              "'connected') "
              'on conflict (connection_id) do nothing',
              parameters: <String, Object?>{
                'cid': connectionId,
                'op': op,
                'loc': loc,
                'vendor': 'square',
                'cat': 'pos',
              },
            );
            await exec.execute(
              'insert into public.demo_mode_state '
              '(operator_id, location_id, category, is_demo) '
              'values (@op::uuid, @loc::uuid, @cat, true) '
              'on conflict (operator_id, location_id, category) '
              'do nothing',
              parameters: <String, Object?>{
                'op': op,
                'loc': loc,
                'cat': 'pos',
              },
            );
          },
          reason: 'phase_6_demo_flip_test_seed',
        );
      }

      Future<void> cleanupRows() async {
        await wrapper.runAsSystem<void>(
          (exec) async {
            await exec.execute(
              'delete from public.connector_backfill_jobs '
              'where operator_id = @op::uuid',
              parameters: <String, Object?>{'op': op},
            );
            await exec.execute(
              'update public.demo_mode_state set '
              'is_demo = true, '
              'flipped_to_live_at = null, '
              'flipped_by_connection_id = null '
              'where operator_id = @op::uuid',
              parameters: <String, Object?>{'op': op},
            );
          },
          reason: 'phase_6_demo_flip_test_cleanup',
        );
      }

      setUpAll(() async {
        pool = PackagePostgresPool.fromUrl(phase6PgUrl);
        wrapper = TenantTransactionWrapper(pool);
        repo = ConnectorBackfillJobRepository(wrapper);
        await seedConnection();
        await cleanupRows();
      });

      tearDown(() async {
        await cleanupRows();
      });

      test(
        'job that reaches running survives a concurrent demo→live '
        'flip and completes normally (complete-then-flip arm)',
        () async {
          final job = await repo.enqueueFirstBackfill(
            operatorId: op,
            locationId: loc,
            connectionId: connectionId,
            vendorId: 'square',
            category: IntegrationCategory.pos,
            windowStart: DateTime.utc(2026, 3, 1, 12),
            windowEnd: DateTime.utc(2026, 4, 30, 12),
            actorUserId: actor,
          );
          final claimed = await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-flip-A',
            actorUserId: actor,
          );
          expect(claimed, isNotNull);
          expect(
            claimed!.status,
            equals(FirstConnectionBackfillJobStatus.running),
          );

          // Mid-job: flip the demo_mode_state row to live. The
          // production flip is keyed on the connection that drove the
          // first backfill commit; we simulate the flip happening
          // concurrently with the in-flight job by issuing the update
          // before the terminal markSucceeded.
          await wrapper.runInTenantContext<void>(
            TenantContext(
              operatorId: op,
              locationId: loc,
              userId: actor,
            ),
            (exec) async {
              await exec.execute(
                'update public.demo_mode_state set '
                'is_demo = false, '
                'flipped_to_live_at = now(), '
                'flipped_by_connection_id = @cid::uuid, '
                'updated_at = now() '
                'where operator_id = @op::uuid '
                'and location_id = @loc::uuid '
                "and category = 'pos' "
                'and is_demo = true',
                parameters: <String, Object?>{
                  'op': op,
                  'loc': loc,
                  'cid': connectionId,
                },
              );
            },
          );

          // Job must reach the terminal `succeeded` state irrespective
          // of the flip — the repo does not branch on demo_mode_state.
          final terminal = await repo.markSucceeded(
            operatorId: op,
            locationId: loc,
            jobId: job.jobId,
            cursorToken: 'cursor-flip-end',
            lastModifiedSeen: DateTime.utc(2026, 4, 30, 12),
            actorUserId: actor,
          );
          expect(
            terminal,
            isNotNull,
            reason: 'mid-flight flip MUST NOT wedge the markSucceeded '
                'transition',
          );
          expect(
            terminal!.status,
            equals(FirstConnectionBackfillJobStatus.succeeded),
          );

          // Verify the demo row is in the post-flip state and the job
          // row is in `succeeded`. The repo does not assert the
          // ordering between these, but we observe it externally.
          await wrapper.runAsSystem<void>(
            (exec) async {
              final demoRows = await exec.query(
                'select is_demo from public.demo_mode_state '
                'where operator_id = @op::uuid '
                'and location_id = @loc::uuid '
                "and category = 'pos'",
                parameters: <String, Object?>{'op': op, 'loc': loc},
              );
              expect(demoRows, hasLength(1));
              expect(demoRows.single['is_demo'], isFalse);
              final jobRows = await exec.query(
                'select status from public.connector_backfill_jobs '
                'where job_id = @jid::uuid',
                parameters: <String, Object?>{'jid': job.jobId},
              );
              expect(jobRows.single['status'], equals('succeeded'));
            },
            reason: 'phase_6_demo_flip_inspect_post_state',
          );
        },
      );

      test(
        'job started while demo_mode_state is still demo, then '
        'released-for-resume after the flip, can be re-claimed and '
        'completed normally (flip-then-resume arm)',
        () async {
          final job = await repo.enqueueFirstBackfill(
            operatorId: op,
            locationId: loc,
            connectionId: connectionId,
            vendorId: 'square',
            category: IntegrationCategory.pos,
            windowStart: DateTime.utc(2026, 3, 1, 12),
            windowEnd: DateTime.utc(2026, 4, 30, 12),
            actorUserId: actor,
          );
          // Confirm the demo row is still demo at start.
          await wrapper.runAsSystem<void>(
            (exec) async {
              final rows = await exec.query(
                'select is_demo from public.demo_mode_state '
                'where operator_id = @op::uuid '
                "and category = 'pos'",
                parameters: <String, Object?>{'op': op},
              );
              expect(rows.single['is_demo'], isTrue);
            },
            reason: 'phase_6_demo_flip_pre_state',
          );

          await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-flip-B',
            actorUserId: actor,
          );

          // Flip mid-flight.
          await wrapper.runInTenantContext<void>(
            TenantContext(
              operatorId: op,
              locationId: loc,
              userId: actor,
            ),
            (exec) async {
              await exec.execute(
                'update public.demo_mode_state set '
                'is_demo = false, '
                'flipped_to_live_at = now(), '
                'flipped_by_connection_id = @cid::uuid, '
                'updated_at = now() '
                'where operator_id = @op::uuid '
                'and location_id = @loc::uuid '
                "and category = 'pos' "
                'and is_demo = true',
                parameters: <String, Object?>{
                  'op': op,
                  'loc': loc,
                  'cid': connectionId,
                },
              );
            },
          );

          // Worker hits a quota tick mid-job and releases for resume.
          final released = await repo.releaseForResume(
            operatorId: op,
            locationId: loc,
            jobId: job.jobId,
            cursorToken: 'cursor-flip-pause',
            lastModifiedSeen: DateTime.utc(2026, 4, 1, 12),
            actorUserId: actor,
          );
          expect(released, isNotNull);
          expect(
            released!.status,
            equals(FirstConnectionBackfillJobStatus.pending),
          );

          // A fresh worker re-claims and seals the job — flip-then-
          // resume must NOT wedge.
          final reclaimed = await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-flip-C',
            actorUserId: actor,
          );
          expect(reclaimed, isNotNull);
          expect(reclaimed!.jobId, equals(job.jobId));
          expect(
            reclaimed.cursorToken,
            equals('cursor-flip-pause'),
            reason: 'cursor must survive the flip → release → '
                're-claim cycle',
          );

          final sealed = await repo.markSucceeded(
            operatorId: op,
            locationId: loc,
            jobId: job.jobId,
            cursorToken: 'cursor-flip-end',
            lastModifiedSeen: DateTime.utc(2026, 4, 30, 12),
            actorUserId: actor,
          );
          expect(sealed, isNotNull);
          expect(
            sealed!.status,
            equals(FirstConnectionBackfillJobStatus.succeeded),
          );
        },
      );

      // CONTRACT GAP: "audit row for the flip event is emitted exactly
      // once" — the repository does NOT write to `audit_logs`. Audit
      // emission for backfill terminal events lives in the worker
      // dispatch (`tool/integration_sync_worker/backfill_dispatch.dart`
      // — the terminal-hook documented at line 191 of that file is
      // optional and the production wiring sits at the dispatch layer,
      // not here). This contract belongs in a worker-layer test, not
      // in this repository test. The Phase 3B harness pins it via the
      // `audit_row_missing` finding category in
      // `test/load/pressure/p3b_backfill_flood_runner_test.dart`.
    },
  );

  group(
    'ConnectorBackfillJobRepository — Phase 3B contract: pod-restart '
    'resume picks up an orphaned claim after the stale window (real '
    'DB)',
    () {
      if (!hasDb) {
        test(
          'setup_skipped — PHASE_6_PG_URL unset; staging connection '
          'required to exercise stale-claim recovery',
          () {
            // ignore: avoid_print
            print(
              '[pod-restart-resume-contract] setup_skipped: '
              'PHASE_6_PG_URL unset. The stale-claim predicate '
              '(`claimed_at < now() - claim_stale_after`) is the '
              'production lever for pod-restart resume; only a real '
              'Postgres can prove it under realistic clock semantics.',
            );
            expect(true, isTrue);
          },
        );
        return;
      }

      late PackagePostgresPool pool;
      late TenantTransactionWrapper wrapper;
      late ConnectorBackfillJobRepository repo;

      const String op = '00000000-0000-6000-9000-000000000d01';
      const String loc = '00000000-0000-6000-9000-000000000d02';
      const String connectionId =
          '00000000-0000-6000-9000-000000000d03';
      const String actor = '00000000-0000-6000-9000-000000000d04';

      Future<void> seedConnection() async {
        await wrapper.runAsSystem<void>(
          (exec) async {
            await exec.execute(
              'insert into public.locations '
              '(operator_id, location_id, name) '
              'values (@op::uuid, @loc::uuid, @name) '
              'on conflict (operator_id, location_id) do nothing',
              parameters: <String, Object?>{
                'op': op,
                'loc': loc,
                'name': 'phase-6-pod-restart-test',
              },
            );
            await exec.execute(
              'insert into public.connector_connection ('
              'connection_id, operator_id, location_id, vendor_id, '
              'category, status'
              ') values ('
              '@cid::uuid, @op::uuid, @loc::uuid, @vendor, @cat, '
              "'connected') "
              'on conflict (connection_id) do nothing',
              parameters: <String, Object?>{
                'cid': connectionId,
                'op': op,
                'loc': loc,
                'vendor': 'square',
                'cat': 'pos',
              },
            );
          },
          reason: 'phase_6_pod_restart_test_seed',
        );
      }

      Future<void> cleanupRows() async {
        await wrapper.runAsSystem<void>(
          (exec) async {
            await exec.execute(
              'delete from public.connector_backfill_jobs '
              'where operator_id = @op::uuid',
              parameters: <String, Object?>{'op': op},
            );
          },
          reason: 'phase_6_pod_restart_test_cleanup',
        );
      }

      setUpAll(() async {
        pool = PackagePostgresPool.fromUrl(phase6PgUrl);
        wrapper = TenantTransactionWrapper(pool);
        repo = ConnectorBackfillJobRepository(wrapper);
        await seedConnection();
        await cleanupRows();
      });

      tearDown(() async {
        await cleanupRows();
      });

      test(
        'pod B claimNext re-claims a row pod A claimed and abandoned '
        '(simulates pod death via tx-rollback on the original claim)',
        () async {
          final job = await repo.enqueueFirstBackfill(
            operatorId: op,
            locationId: loc,
            connectionId: connectionId,
            vendorId: 'square',
            category: IntegrationCategory.pos,
            windowStart: DateTime.utc(2026, 3, 1, 12),
            windowEnd: DateTime.utc(2026, 4, 30, 12),
            actorUserId: actor,
          );

          // Pod A claims (the wrapper commits on success — equivalent
          // to the production "successfully claimed but pod died
          // before completing the work" failure mode).
          final claimedA = await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-A-restart',
            actorUserId: actor,
          );
          expect(claimedA, isNotNull);
          expect(
            claimedA!.status,
            equals(FirstConnectionBackfillJobStatus.running),
          );
          final attemptCountAfterA = claimedA.attemptCount;

          // Backdate `claimed_at` so the staleness predicate fires
          // immediately — the production deployment uses 15min, the
          // simulator uses 200ms; here we backdate by 1 hour so even
          // a 5-second `claimStaleAfter` test value qualifies.
          await wrapper.runAsSystem<void>(
            (exec) async {
              await exec.execute(
                'update public.connector_backfill_jobs set '
                "claimed_at = now() - interval '1 hour' "
                'where job_id = @jid::uuid',
                parameters: <String, Object?>{'jid': job.jobId},
              );
            },
            reason: 'phase_6_pod_restart_backdate_claimed_at',
          );

          // Pod B claims with a short stale window. SKIP LOCKED +
          // stale-recovery predicate must hand the row over.
          final claimedB = await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-B-restart',
            actorUserId: actor,
            claimStaleAfter: const Duration(seconds: 5),
          );
          expect(
            claimedB,
            isNotNull,
            reason: 'pod B must re-claim the orphaned row once '
                'claimed_at is older than claimStaleAfter',
          );
          expect(claimedB!.jobId, equals(job.jobId));
          expect(claimedB.workerId, equals('pod-B-restart'));
          expect(
            claimedB.attemptCount,
            equals(attemptCountAfterA + 1),
            reason: 'attempt_count increments on each re-claim — the '
                'production observability anchor for "this row '
                'restarted N times"',
          );
        },
      );

      test(
        'pod B will NOT re-claim a row whose claimed_at is still '
        'fresh — guards against thundering-herd on healthy claims',
        () async {
          final job = await repo.enqueueFirstBackfill(
            operatorId: op,
            locationId: loc,
            connectionId: connectionId,
            vendorId: 'square',
            category: IntegrationCategory.pos,
            windowStart: DateTime.utc(2026, 5, 1, 12),
            windowEnd: DateTime.utc(2026, 6, 30, 12),
            actorUserId: actor,
          );
          await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-A-fresh',
            actorUserId: actor,
          );

          // No backdate. Pod B with a 1-hour stale window must NOT
          // see the row as stale.
          final claimedB = await repo.claimNext(
            operatorId: op,
            locationId: loc,
            workerId: 'pod-B-fresh',
            actorUserId: actor,
            claimStaleAfter: const Duration(hours: 1),
          );
          expect(
            claimedB,
            isNull,
            reason:
                'a fresh claim must NOT be stolen by another worker; '
                'this is the "no thundering herd on healthy claims" '
                'guarantee that keeps attempt_count bounded.',
          );

          // Sanity: the row is still claimed by pod-A-fresh.
          await wrapper.runAsSystem<void>(
            (exec) async {
              final rows = await exec.query(
                'select worker_id, status, attempt_count '
                'from public.connector_backfill_jobs '
                'where job_id = @jid::uuid',
                parameters: <String, Object?>{'jid': job.jobId},
              );
              expect(rows.single['worker_id'], equals('pod-A-fresh'));
              expect(rows.single['status'], equals('running'));
              expect(rows.single['attempt_count'], equals(1));
            },
            reason: 'phase_6_pod_restart_fresh_claim_inspect',
          );
        },
      );

      // CONTRACT GAP: "audit row for the re-claim event is emitted
      // with the prior pod's identifier captured" — the repository
      // does NOT emit audit rows for re-claims. The schema preserves
      // the prior `worker_id` on the UPDATE (the new claim overwrites
      // it), so even at the row level the prior pod's id is lost the
      // moment pod B's claim lands. Capturing the prior pod id at
      // re-claim time would require either:
      //   (a) appending `worker_id` to a history JSONB column on the
      //       row before the UPDATE, or
      //   (b) inserting a row into `audit_logs` from the worker
      //       dispatch's terminal hook with `prior_worker_id` in the
      //       payload.
      // (b) is the intended production design (worker-layer concern,
      // not repo-layer). Today neither path is wired up; the harness
      // at `tool/pressure/p3b_backfill_flood.dart` simulates the
      // intended behavior but no production code emits the audit row.
      // This is the strongest contract gap surfaced by Phase 6 work
      // on this repo and merits a follow-up slice on the worker.
    },
  );
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
