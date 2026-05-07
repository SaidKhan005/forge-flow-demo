// Phase 9.UX.1 / post-hardening P2 — canonical-path unit tests for
// MfaFactorRemovalRequestsRepository.
//
// Coverage focus:
//
//   * State transitions — the production state machine for a removal
//     request is:
//
//                  insertPending
//          (none) ───────────────► pending
//                                    │
//             markCompleted ◄────────┤
//             markCancelled ◄────────┤
//             markFailed (retryable)─┘  (clears processing fields so a
//                                          subsequent claim re-runs)
//
//     Prompt vocabulary note: an earlier draft mentioned "approved /
//     rejected / expired" terminal states. The shipped state machine
//     uses `completed_at` (success), `cancelled_at` (user revoked the
//     request), and `last_error` + cleared processing fields (transient
//     failure — the row stays pending so the worker can retry). There
//     is no separate "expired" terminal — the `execute_after` field is
//     the delay window before the request becomes due, and the
//     `staleAfter` lease is the worker-side fence for stuck claims.
//     Both "expiry" semantics are pinned below.
//
//   * `insertPending` upsert posture — `ON CONFLICT (operator_id,
//     user_id, factor_id) WHERE completed_at IS NULL AND cancelled_at
//     IS NULL DO UPDATE SET updated_at = mfa_factor_removal_requests.
//     updated_at` — a duplicate enqueue for the same (operator, user,
//     factor) triple while one is still pending returns the EXISTING
//     row (the partial-unique-index-targeted upsert preserves the
//     original `requested_at` / `execute_after` / `step_up_proof_id`).
//     This is the idempotency contract for the proxy's enqueue
//     endpoint.
//
//   * Expiry contract:
//
//       - Delay-window expiry: `listDuePendingForUser` and
//         `claimDuePending` BOTH filter `execute_after <= @now`.
//         A request requested at 09:00 with execute_after at 09:00 + 24h
//         will not appear in either listing until 24h have passed.
//
//       - Lease-stale expiry: `claimDuePending` includes a
//         `processing_started_at` predicate so a stuck-worker claim
//         (default 15 min) is reclaimable by another worker. The
//         predicate is `processing_started_at IS NULL OR
//         processing_started_at < @now - staleAfter`.
//
//   * Worker claim semantics — `claimDuePending` runs through
//     `withSystem` (no tenant context — the worker drains every
//     operator's pending queue). The CTE pattern is:
//       1. Inner CTE selects due rows with `FOR UPDATE SKIP LOCKED`
//          (pgmq is not available; this is the locked queue pattern).
//       2. Outer UPDATE stamps `processing_started_at` +
//          `processing_owner`.
//     Tests pin both: `for update skip locked`, the audit marker
//     `system:system.mfa_factor_removal_worker_claim`, and the
//     stale-lease predicate shape.
//
//   * `markCompleted` / `markCancelled` / `markFailed` — terminal vs
//     transient writes. Tests pin:
//       - completed_at + cancelled_at + last_error advance ONLY when
//         pending (the WHERE clause guards `completed_at IS NULL AND
//         cancelled_at IS NULL`).
//       - markCompleted clears `last_error` (the error counter resets
//         on success).
//       - markFailed clears `processing_started_at` + `processing_owner`
//         (so the worker can re-claim on next sweep) but does NOT
//         advance completed_at / cancelled_at.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factor_removal_requests_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';
const String _userB = '44444444-4444-4444-4444-444444444444';
const String _factorA = '66666666-6666-6666-6666-666666666666';
const String _requestA = '77777777-7777-7777-7777-777777777777';
const String _requestB = '88888888-8888-8888-8888-888888888888';
const String _stepUpProofA = 'stepup-proof-001';
const String _workerOwner = 'worker-pod-abc-001';

PostgresRow _requestRow({
  String requestId = _requestA,
  String operatorId = _opA,
  String locationId = _locA,
  String userId = _userA,
  String factorId = _factorA,
  String requestedByUserId = _userA,
  String stepUpProofId = _stepUpProofA,
  DateTime? requestedAt,
  DateTime? executeAfter,
  DateTime? completedAt,
  DateTime? cancelledAt,
  DateTime? processingStartedAt,
  String? processingOwner,
  String? lastError,
  int attemptCount = 0,
  DateTime? deadLetteredAt,
}) {
  return <String, Object?>{
    'request_id': requestId,
    'operator_id': operatorId,
    'location_id': locationId,
    'user_id': userId,
    'factor_id': factorId,
    'requested_by_user_id': requestedByUserId,
    'step_up_proof_id': stepUpProofId,
    'requested_at': requestedAt ?? DateTime.utc(2026, 4, 28, 9),
    'execute_after': executeAfter ?? DateTime.utc(2026, 4, 29, 9),
    'completed_at': completedAt,
    'cancelled_at': cancelledAt,
    'processing_started_at': processingStartedAt,
    'processing_owner': processingOwner,
    'last_error': lastError,
    'attempt_count': attemptCount,
    'dead_lettered_at': deadLetteredAt,
  };
}

void main() {
  group(
      'MfaFactorRemovalRequestsRepository.insertPending — '
      'state transition: (none) → pending', () {
    test(
      'happy path: row inserted in pending state '
      '(completed_at / cancelled_at / processing_* all NULL); '
      'returned record carries isPending=true and isCompleted=false',
      () async {
        final requestedAt = DateTime.utc(2026, 4, 28, 9);
        final executeAfter = DateTime.utc(2026, 4, 29, 9); // +24h
        final pool = _RemovalRequestsPool(
          insertedRow: _requestRow(
            requestedAt: requestedAt,
            executeAfter: executeAfter,
          ),
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final row = await repo.insertPending(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          factorId: _factorA,
          requestedByUserId: _userA,
          stepUpProofId: _stepUpProofA,
          requestId: _requestA,
          requestedAt: requestedAt,
          executeAfter: executeAfter,
        );
        expect(row.isPending, isTrue);
        expect(row.isCompleted, isFalse);
        expect(row.requestedAt, equals(requestedAt));
        expect(row.executeAfter, equals(executeAfter));
        expect(row.completedAt, isNull);
        expect(row.cancelledAt, isNull);
        expect(row.processingStartedAt, isNull);
      },
    );

    test(
      'upsert idempotency: ON CONFLICT (operator_id, user_id, factor_id) '
      'WHERE completed_at IS NULL AND cancelled_at IS NULL DO UPDATE '
      'preserves the existing pending row (the proxy enqueue endpoint '
      'is idempotent on duplicate enqueues for the same triple)',
      () async {
        final pool = _RemovalRequestsPool(insertedRow: _requestRow());
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.insertPending(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          factorId: _factorA,
          requestedByUserId: _userA,
          stepUpProofId: _stepUpProofA,
          requestId: _requestA,
          requestedAt: DateTime.utc(2026, 4, 28, 9),
          executeAfter: DateTime.utc(2026, 4, 29, 9),
        );
        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into mfa_factor_removal_requests'),
        );
        // Partial unique conflict target — only pending rows count
        // (terminal-state rows do not block re-enqueue).
        expect(
          insertSql,
          contains('on conflict (operator_id, user_id, factor_id)'),
        );
        expect(
          insertSql,
          contains('where completed_at is null and cancelled_at is null'),
        );
        // DO UPDATE is a no-op (just rewrites updated_at to itself) so
        // the existing row is returned by RETURNING instead of a fresh
        // insert.
        expect(
          insertSql,
          contains(
            'do update set updated_at = mfa_factor_removal_requests.updated_at',
          ),
        );
        // RETURNING projects every column the record carries.
        expect(insertSql, contains('returning request_id::text'));
      },
    );

    test(
      'tenant SET LOCAL ordering precedes the upsert — operator + '
      'user double-scope',
      () async {
        final pool = _RemovalRequestsPool(insertedRow: _requestRow());
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.insertPending(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          factorId: _factorA,
          requestedByUserId: _userA,
          stepUpProofId: _stepUpProofA,
          requestId: _requestA,
          requestedAt: DateTime.utc(2026, 4, 28, 9),
          executeAfter: DateTime.utc(2026, 4, 29, 9),
        );
        final tx = pool.transactions.single;
        expect(tx.executedSql[0], contains("'app.operator_id'"));
        expect(tx.parameters[0]['value'], equals(_opA));
        expect(tx.executedSql[1], contains("'app.location_id'"));
        expect(tx.parameters[1]['value'], equals(_locA));
        expect(tx.executedSql[2], contains("'app.user_id'"));
        expect(tx.parameters[2]['value'], equals(_userA));
        // No BYPASSRLS — insertPending is tenant-scoped only.
        expect(
          tx.executedSql.where((s) => s.contains('set local role forge_admin')),
          isEmpty,
        );
      },
    );

    test('throws StateError when RETURNING is empty (RLS denial)', () async {
      final pool = _RemovalRequestsPool(insertedRow: null);
      final repo = MfaFactorRemovalRequestsRepository(
        TenantTransactionWrapper(pool),
      );
      await expectLater(
        repo.insertPending(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          factorId: _factorA,
          requestedByUserId: _userA,
          stepUpProofId: _stepUpProofA,
          requestId: _requestA,
          requestedAt: DateTime.utc(2026, 4, 28, 9),
          executeAfter: DateTime.utc(2026, 4, 29, 9),
        ),
        throwsStateError,
      );
    });
  });

  group(
      'MfaFactorRemovalRequestsRepository — expiry contract '
      '(delay window)', () {
    test(
      'listDuePendingForUser filters execute_after <= @now AND '
      'completed_at IS NULL AND cancelled_at IS NULL — a request '
      'before its execute_after is NOT due even though pending',
      () async {
        final pool = _RemovalRequestsPool(
          listDueRows: <PostgresRow>[
            _requestRow(
              executeAfter: DateTime.utc(2026, 4, 28, 9),
            ),
          ],
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final rows = await repo.listDuePendingForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          now: DateTime.utc(2026, 4, 29, 9),
        );
        expect(rows, hasLength(1));

        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('from mfa_factor_removal_requests') &&
              s.contains('execute_after'),
        );
        expect(selectSql, contains('completed_at is null'));
        expect(selectSql, contains('cancelled_at is null'));
        // M4: dead-lettered rows leave the active/due set so the worker
        // and the user-listing both stop seeing them.
        expect(selectSql, contains('dead_lettered_at is null'));
        expect(selectSql, contains('execute_after <= @now::timestamptz'));
        // Order — most-due first, with stable secondary tie-break on
        // requested_at.
        expect(selectSql, contains('order by execute_after, requested_at'));
        expect(selectSql, contains('limit @limit'));
      },
    );
  });

  group(
      'MfaFactorRemovalRequestsRepository.claimDuePending — worker '
      'CTE + expiry contract (lease-stale)', () {
    test(
      'CTE pattern: due-rows CTE uses FOR UPDATE SKIP LOCKED so '
      "concurrent workers never compete for the same row; outer "
      'UPDATE stamps processing_started_at + processing_owner',
      () async {
        final pool = _RemovalRequestsPool(
          claimedRows: <PostgresRow>[
            _requestRow(
              processingStartedAt: DateTime.utc(2026, 4, 29, 9),
              processingOwner: _workerOwner,
            ),
          ],
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final rows = await repo.claimDuePending(
          now: DateTime.utc(2026, 4, 29, 9),
          workerOwner: _workerOwner,
          limit: 50,
          staleAfter: const Duration(minutes: 15),
        );
        expect(rows, hasLength(1));
        expect(rows.single.processingOwner, equals(_workerOwner));

        final tx = pool.transactions.single;
        // Bypass marker carries the canonical reason for the worker
        // claim — auditors can attribute the BYPASSRLS path back to
        // the queue-drain job.
        final auditCfg = tx.parameters.firstWhere(
          (p) =>
              p['value'] is String &&
              (p['value']! as String).startsWith('system:'),
        );
        expect(
          auditCfg['value'],
          equals('system:system.mfa_factor_removal_worker_claim'),
        );
        // forge_admin elevation engaged.
        expect(
          tx.executedSql.where((s) => s.contains('set local role forge_admin')),
          hasLength(1),
        );
        // Tenant SET LOCAL must NOT engage in withSystem.
        expect(
          tx.executedSql.where((s) => s.contains("'app.operator_id'")),
          isEmpty,
        );

        final claimSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('from mfa_factor_removal_requests') &&
              s.contains('for update skip locked'),
        );
        // Pending rows only.
        expect(claimSql, contains('completed_at is null'));
        expect(claimSql, contains('cancelled_at is null'));
        // M4: DLQ sentinel — dead-lettered rows are excluded from the
        // worker claim CTE so a poison row stops being re-claimed once
        // L7 stamps `dead_lettered_at`.
        expect(claimSql, contains('dead_lettered_at is null'));
        // Delay-window expiry.
        expect(claimSql, contains('execute_after <= @now::timestamptz'));
        // Lease-stale expiry — claim is reclaimable when the lease has
        // exceeded `staleAfter` seconds.
        expect(
          claimSql,
          contains(
            "@now::timestamptz - (@stale_seconds * interval '1 second')",
          ),
          reason:
              'staleAfter is bound as a seconds int + interval multiplier '
              'so a refactor to a different unit surfaces here',
        );
        expect(
          claimSql,
          contains(
            'processing_started_at is null',
          ),
          reason: 'fresh rows (never claimed) AND stale-claim rows both '
              'become eligible — the OR chain is what makes the lease '
              'reclaimable',
        );
        // The outer UPDATE stamps processing_started_at + processing_owner.
        expect(claimSql, contains('set processing_started_at = @now'));
        expect(claimSql, contains('processing_owner = @worker_owner'));
      },
    );

    test(
      'staleAfter parameter: claim binds @stale_seconds as the '
      "Duration's `inSeconds` value (so a future change from seconds "
      'to milliseconds breaks here, not in production)',
      () async {
        final pool = _RemovalRequestsPool(claimedRows: const <PostgresRow>[]);
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.claimDuePending(
          now: DateTime.utc(2026, 4, 29, 9),
          workerOwner: _workerOwner,
          staleAfter: const Duration(minutes: 15),
        );
        final params = pool.transactions.single.parameters.firstWhere(
          (p) => p['stale_seconds'] != null,
        );
        expect(params['stale_seconds'], equals(15 * 60));
      },
    );

    test('rejects empty workerOwner with ArgumentError', () async {
      final pool = _RemovalRequestsPool();
      final repo = MfaFactorRemovalRequestsRepository(
        TenantTransactionWrapper(pool),
      );
      await expectLater(
        () => repo.claimDuePending(
          now: DateTime.utc(2026, 4, 29, 9),
          workerOwner: '',
        ),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty);
    });

    test('rejects whitespace-only workerOwner with ArgumentError', () async {
      final pool = _RemovalRequestsPool();
      final repo = MfaFactorRemovalRequestsRepository(
        TenantTransactionWrapper(pool),
      );
      await expectLater(
        () => repo.claimDuePending(
          now: DateTime.utc(2026, 4, 29, 9),
          workerOwner: '   ',
        ),
        throwsArgumentError,
      );
    });

    test('rejects non-positive limit with ArgumentError', () async {
      final pool = _RemovalRequestsPool();
      final repo = MfaFactorRemovalRequestsRepository(
        TenantTransactionWrapper(pool),
      );
      await expectLater(
        () => repo.claimDuePending(
          now: DateTime.utc(2026, 4, 29, 9),
          workerOwner: _workerOwner,
          limit: 0,
        ),
        throwsArgumentError,
      );
      await expectLater(
        () => repo.claimDuePending(
          now: DateTime.utc(2026, 4, 29, 9),
          workerOwner: _workerOwner,
          limit: -5,
        ),
        throwsArgumentError,
      );
    });

    test('trims workerOwner before binding (whitespace tolerated)', () async {
      final pool = _RemovalRequestsPool(claimedRows: const <PostgresRow>[]);
      final repo = MfaFactorRemovalRequestsRepository(
        TenantTransactionWrapper(pool),
      );
      await repo.claimDuePending(
        now: DateTime.utc(2026, 4, 29, 9),
        workerOwner: '  $_workerOwner  ',
      );
      final params = pool.transactions.single.parameters.firstWhere(
        (p) => p['worker_owner'] != null,
      );
      expect(params['worker_owner'], equals(_workerOwner));
    });
  });

  group(
      'MfaFactorRemovalRequestsRepository.markCompleted — '
      'state transition: pending → completed', () {
    test(
      'idempotent: WHERE completed_at IS NULL AND cancelled_at IS '
      'NULL guard short-circuits a second call; completed_at advances '
      'while last_error and processing_* are cleared (success resets '
      'transient state)',
      () async {
        final pool = _RemovalRequestsPool(updateAffectedRows: 1);
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final affected = await repo.markCompleted(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          requestId: _requestA,
          completedAt: DateTime.utc(2026, 4, 29, 10),
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update mfa_factor_removal_requests') &&
              s.contains('completed_at = @completed_at::timestamptz'),
        );
        // Success seal: completed_at advances; transient state clears.
        expect(updateSql, contains('last_error = null'));
        expect(updateSql, contains('processing_started_at = null'));
        expect(updateSql, contains('processing_owner = null'));
        // Idempotent guard.
        expect(updateSql, contains('and completed_at is null'));
        expect(updateSql, contains('and cancelled_at is null'));
        // Operator + user + request_id triple-scope.
        expect(updateSql, contains('request_id = @request_id::uuid'));
        expect(updateSql, contains('operator_id = @operator_id::uuid'));
        expect(updateSql, contains('user_id = @user_id::uuid'));
      },
    );

    test('returns 0 when row already terminal (idempotent re-call)',
        () async {
      final pool = _RemovalRequestsPool(updateAffectedRows: 0);
      final repo = MfaFactorRemovalRequestsRepository(
        TenantTransactionWrapper(pool),
      );
      final affected = await repo.markCompleted(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        requestId: _requestA,
        completedAt: DateTime.utc(2026, 4, 29, 10),
      );
      expect(affected, equals(0));
    });
  });

  group(
      'MfaFactorRemovalRequestsRepository.markCancelled — '
      'state transition: pending → cancelled', () {
    test(
      'cancelled_at advances; last_error + processing_* clear; '
      "WHERE clause prevents cancelling a row that's already "
      'completed or cancelled',
      () async {
        final pool = _RemovalRequestsPool(updateAffectedRows: 1);
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final affected = await repo.markCancelled(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          requestId: _requestA,
          cancelledAt: DateTime.utc(2026, 4, 28, 10),
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update mfa_factor_removal_requests') &&
              s.contains('cancelled_at = @cancelled_at::timestamptz'),
        );
        // Cancellation seal: cancelled_at advances; transient state clears.
        expect(updateSql, contains('last_error = null'));
        expect(updateSql, contains('processing_started_at = null'));
        expect(updateSql, contains('processing_owner = null'));
        // Terminal-state guard prevents transitioning out of completed.
        expect(updateSql, contains('and completed_at is null'));
        expect(updateSql, contains('and cancelled_at is null'));
      },
    );
  });

  group(
      'MfaFactorRemovalRequestsRepository.markFailed — '
      'state transition: pending → pending (transient retry)', () {
    test(
      'last_error captured; processing_started_at + processing_owner '
      'cleared so the worker can re-claim on next sweep; '
      'completed_at and cancelled_at NOT advanced',
      () async {
        final pool = _RemovalRequestsPool(updateAffectedRows: 1);
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final affected = await repo.markFailed(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          requestId: _requestA,
          error: 'firebase: TOO_MANY_ATTEMPTS_TRY_LATER',
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update mfa_factor_removal_requests') &&
              s.contains('last_error = @last_error'),
        );
        expect(updateSql, contains('processing_started_at = null'));
        expect(updateSql, contains('processing_owner = null'));
        // markFailed must NOT touch completed_at / cancelled_at —
        // failures are transient. Terminal seals belong to
        // markCompleted / markCancelled.
        expect(
          updateSql,
          isNot(contains('completed_at = ')),
          reason: 'markFailed must not stamp completed_at — that would '
              'wedge the row into a misleading terminal state',
        );
        expect(
          updateSql,
          isNot(contains('cancelled_at = ')),
        );
        // Idempotency guards (so a failure on an already-terminal row
        // is a no-op).
        expect(updateSql, contains('and completed_at is null'));
        expect(updateSql, contains('and cancelled_at is null'));

        final params = tx.parameters.firstWhere(
          (p) => p['last_error'] != null,
        );
        expect(
          params['last_error'],
          equals('firebase: TOO_MANY_ATTEMPTS_TRY_LATER'),
          reason: 'error string round-trips verbatim — operators read '
              'this value back through the audit trail',
        );
      },
    );

    test(
      'returns 0 when row is already terminal (no retry on a settled '
      'row — the WHERE clause refuses)',
      () async {
        final pool = _RemovalRequestsPool(updateAffectedRows: 0);
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final affected = await repo.markFailed(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          requestId: _requestA,
          error: 'transient',
        );
        expect(affected, equals(0));
      },
    );
  });

  group('MfaFactorRemovalRequestsRepository.listRecentForUser', () {
    test(
      'returns rows ordered by requested_at desc, limited; '
      'tenant + user double-scope predicate ensures another user\'s '
      'recent requests cannot leak',
      () async {
        final pool = _RemovalRequestsPool(
          recentRows: <PostgresRow>[
            _requestRow(requestId: _requestA),
            _requestRow(
              requestId: _requestB,
              requestedAt: DateTime.utc(2026, 4, 27, 9),
              executeAfter: DateTime.utc(2026, 4, 28, 9),
              completedAt: DateTime.utc(2026, 4, 28, 10),
            ),
          ],
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final rows = await repo.listRecentForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          limit: 5,
        );
        expect(rows, hasLength(2));
        expect(rows[0].isPending, isTrue);
        expect(rows[1].isCompleted, isTrue);

        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('from mfa_factor_removal_requests') &&
              s.contains('order by requested_at desc'),
        );
        expect(selectSql, contains('operator_id = @operator_id::uuid'));
        expect(selectSql, contains('location_id = @location_id::uuid'));
        expect(selectSql, contains('user_id = @user_id::uuid'));
        expect(selectSql, contains('limit @limit'));

        final selectParams = tx.parameters.firstWhere(
          (p) => p['user_id'] == _userA && p['limit'] == 5,
        );
        expect(selectParams['operator_id'], equals(_opA));
        expect(selectParams['location_id'], equals(_locA));
      },
    );

    test('limit defaults to 20 when omitted', () async {
      final pool = _RemovalRequestsPool(recentRows: const <PostgresRow>[]);
      final repo = MfaFactorRemovalRequestsRepository(
        TenantTransactionWrapper(pool),
      );
      await repo.listRecentForUser(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
      );
      final params = pool.transactions.single.parameters.firstWhere(
        (p) => p['limit'] != null,
      );
      expect(params['limit'], equals(20));
    });

    test(
      'isolating by user — the user_id parameter scopes the SELECT so '
      "another user's pending request cannot project under this user's "
      'listing (defense in depth on top of RLS)',
      () async {
        final pool = _RemovalRequestsPool(recentRows: const <PostgresRow>[]);
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.listRecentForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userB,
        );
        final params = pool.transactions.single.parameters.firstWhere(
          (p) => p['user_id'] == _userB,
        );
        expect(params['user_id'], equals(_userB));
      },
    );
  });

  group(
      'MfaFactorRemovalRequestRecord — M4 projection round-trip '
      'for attempt_count + dead_lettered_at', () {
    test(
      'a fresh row defaults to attempt_count = 0, deadLetteredAt = null, '
      'and isPending=true / isDeadLettered=false',
      () async {
        final pool = _RemovalRequestsPool(insertedRow: _requestRow());
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final row = await repo.insertPending(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          factorId: _factorA,
          requestedByUserId: _userA,
          stepUpProofId: _stepUpProofA,
          requestId: _requestA,
          requestedAt: DateTime.utc(2026, 4, 28, 9),
          executeAfter: DateTime.utc(2026, 4, 29, 9),
        );
        expect(row.attemptCount, equals(0));
        expect(row.deadLetteredAt, isNull);
        expect(row.isPending, isTrue);
        expect(row.isDeadLettered, isFalse);
      },
    );

    test(
      'a row with attempt_count > 0 and dead_lettered_at non-null '
      'projects through the row-mapper as isDeadLettered=true and '
      'isPending=false (DLQ rows leave the active set)',
      () async {
        final deadAt = DateTime.utc(2026, 4, 30, 12);
        final pool = _RemovalRequestsPool(
          recentRows: <PostgresRow>[
            _requestRow(
              attemptCount: 11,
              deadLetteredAt: deadAt,
              lastError: 'firebase: PERMISSION_DENIED',
            ),
          ],
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final rows = await repo.listRecentForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(rows, hasLength(1));
        final row = rows.single;
        expect(row.attemptCount, equals(11));
        expect(row.deadLetteredAt, equals(deadAt));
        expect(row.isDeadLettered, isTrue);
        expect(row.isPending, isFalse);
        expect(row.lastError, equals('firebase: PERMISSION_DENIED'));
      },
    );

    test(
      'SELECT column lists project attempt_count + dead_lettered_at — '
      "this is the contract that lets the worker observe the row's "
      'retry state without a separate fetch',
      () async {
        final pool = _RemovalRequestsPool(
          recentRows: <PostgresRow>[_requestRow()],
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.listRecentForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        final selectSql = pool.transactions.single.executedSql.firstWhere(
          (s) =>
              s.contains('from mfa_factor_removal_requests') &&
              s.contains('order by requested_at desc'),
        );
        expect(selectSql, contains('attempt_count'));
        expect(selectSql, contains('dead_lettered_at'));
      },
    );
  });

  group(
      'MfaFactorRemovalRequestsRepository.incrementAttemptCount — '
      'M4 retry counter (per-row)', () {
    test(
      'happy path: UPDATE … SET attempt_count = attempt_count + 1 '
      'RETURNING attempt_count returns the new count; pending-only + '
      'dead_lettered_at IS NULL guards keep terminal/DLQ rows out of '
      'the bump path',
      () async {
        final pool = _RemovalRequestsPool(
          incrementReturnRows: <PostgresRow>[
            <String, Object?>{'attempt_count': 4},
          ],
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final newCount = await repo.incrementAttemptCount(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          requestId: _requestA,
        );
        expect(newCount, equals(4));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update mfa_factor_removal_requests') &&
              s.contains('set attempt_count = attempt_count + 1'),
        );
        // Pending-only + DLQ guards.
        expect(updateSql, contains('and completed_at is null'));
        expect(updateSql, contains('and cancelled_at is null'));
        expect(updateSql, contains('and dead_lettered_at is null'));
        // RETURNING the post-increment value so the caller doesn't
        // need a follow-up read.
        expect(updateSql, contains('returning attempt_count'));
        // Operator + user + request_id triple-scope.
        expect(updateSql, contains('request_id = @request_id::uuid'));
        expect(updateSql, contains('operator_id = @operator_id::uuid'));
        expect(updateSql, contains('user_id = @user_id::uuid'));
        // Tenant SET LOCAL precedes the bump.
        expect(tx.executedSql[0], contains("'app.operator_id'"));
      },
    );

    test(
      'throws StateError when no row is updated (row missing, terminal, '
      'or already dead-lettered) — caller must notice that the row '
      'left the active set',
      () async {
        final pool = _RemovalRequestsPool(
          incrementReturnRows: const <PostgresRow>[],
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        await expectLater(
          repo.incrementAttemptCount(
            operatorId: _opA,
            locationId: _locA,
            userId: _userA,
            requestId: _requestA,
          ),
          throwsStateError,
        );
      },
    );

    test(
      'is composable with markFailed in the same transaction sketch — '
      'the L7 worker calls increment + markFailed back-to-back inside '
      'one tenant transaction; this test pins the contract that '
      'incrementAttemptCount does NOT itself touch last_error or '
      'processing fields (so markFailed is the canonical place for '
      'those writes and there is no double-update conflict)',
      () async {
        final pool = _RemovalRequestsPool(
          incrementReturnRows: <PostgresRow>[
            <String, Object?>{'attempt_count': 1},
          ],
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.incrementAttemptCount(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          requestId: _requestA,
        );
        final updateSql = pool.transactions.single.executedSql.firstWhere(
          (s) =>
              s.contains('update mfa_factor_removal_requests') &&
              s.contains('set attempt_count'),
        );
        // Increment is a focused write — does not stamp last_error /
        // processing_*.
        expect(
          updateSql,
          isNot(contains('last_error')),
          reason: 'increment is the counter-only write; markFailed '
              'owns last_error so the two methods compose without '
              'overwriting one another',
        );
        expect(updateSql, isNot(contains('processing_started_at')));
        expect(updateSql, isNot(contains('processing_owner')));
        expect(
          updateSql,
          isNot(contains('completed_at = ')),
          reason: 'increment does not advance terminal seals',
        );
      },
    );
  });

  group(
      'MfaFactorRemovalRequestsRepository.markDeadLettered — '
      'M4 DLQ sentinel write', () {
    test(
      'stamps dead_lettered_at = now(), captures the reason in '
      'last_error, and clears processing_started_at + processing_owner '
      'so a confused worker cannot keep re-claiming the row',
      () async {
        final pool = _RemovalRequestsPool(updateAffectedRows: 1);
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final affected = await repo.markDeadLettered(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          requestId: _requestA,
          reason: 'retry budget exhausted (10 attempts)',
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update mfa_factor_removal_requests') &&
              s.contains('dead_lettered_at = now()'),
        );
        // DLQ stamp + worker-claim cleanup.
        expect(updateSql, contains('last_error = @last_error'));
        expect(updateSql, contains('processing_started_at = null'));
        expect(updateSql, contains('processing_owner = null'));
        // Terminal-state + idempotency guards (do not re-stamp DLQ on
        // an already-DLQ row).
        expect(updateSql, contains('and completed_at is null'));
        expect(updateSql, contains('and cancelled_at is null'));
        expect(updateSql, contains('and dead_lettered_at is null'));
        // markDeadLettered must NOT advance completed_at — DLQ is its
        // own terminal state, distinct from successful completion.
        expect(
          updateSql,
          isNot(contains('completed_at = ')),
          reason: 'DLQ is not the same as completion; the row needs '
              'operator review, not a success seal',
        );

        final params = tx.parameters.firstWhere(
          (p) => p['last_error'] != null,
        );
        expect(
          params['last_error'],
          equals('retry budget exhausted (10 attempts)'),
        );
      },
    );

    test(
      'returns 0 when the row is already terminal or already '
      'dead-lettered (idempotent re-call)',
      () async {
        final pool = _RemovalRequestsPool(updateAffectedRows: 0);
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        final affected = await repo.markDeadLettered(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          requestId: _requestA,
          reason: 'noop on settled row',
        );
        expect(affected, equals(0));
      },
    );
  });

  group(
      'MfaFactorRemovalRequestsRepository — M4 dead-lettered rows leave '
      'the active partial-index reads', () {
    test(
      'listDuePendingForUser filters dead_lettered_at IS NULL — a row '
      'that L7 has DLQd does NOT come back as due even if execute_after '
      'has passed',
      () async {
        final pool = _RemovalRequestsPool(
          listDueRows: const <PostgresRow>[],
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.listDuePendingForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          now: DateTime.utc(2026, 4, 30, 9),
        );
        final selectSql = pool.transactions.single.executedSql.firstWhere(
          (s) =>
              s.contains('from mfa_factor_removal_requests') &&
              s.contains('execute_after <= @now'),
        );
        expect(selectSql, contains('dead_lettered_at is null'));
      },
    );

    test(
      'claimDuePending CTE filters dead_lettered_at IS NULL — the '
      'worker stops re-claiming poison rows once they are DLQd',
      () async {
        final pool = _RemovalRequestsPool(
          claimedRows: const <PostgresRow>[],
        );
        final repo = MfaFactorRemovalRequestsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.claimDuePending(
          now: DateTime.utc(2026, 4, 30, 9),
          workerOwner: _workerOwner,
        );
        final claimSql = pool.transactions.single.executedSql.firstWhere(
          (s) =>
              s.contains('from mfa_factor_removal_requests') &&
              s.contains('for update skip locked'),
        );
        expect(claimSql, contains('dead_lettered_at is null'));
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the
/// MfaFactorRemovalRequestsRepository seam.
///
/// `insertedRow` controls insertPending RETURNING (pass null for empty
/// rows / RLS denial).
/// `recentRows` / `listDueRows` / `claimedRows` control the SELECT
/// returns.
/// `updateAffectedRows` controls every mark* UPDATE affected count.
/// `incrementReturnRows` controls the `incrementAttemptCount`
/// `UPDATE … RETURNING attempt_count` projection (M4).
class _RemovalRequestsPool implements PostgresPool {
  _RemovalRequestsPool({
    this.insertedRow,
    this.recentRows = const <PostgresRow>[],
    this.listDueRows = const <PostgresRow>[],
    this.claimedRows = const <PostgresRow>[],
    this.updateAffectedRows = 0,
    this.incrementReturnRows = const <PostgresRow>[],
  });

  final PostgresRow? insertedRow;
  final List<PostgresRow> recentRows;
  final List<PostgresRow> listDueRows;
  final List<PostgresRow> claimedRows;
  final int updateAffectedRows;
  final List<PostgresRow> incrementReturnRows;
  final List<_RemovalRequestsTransaction> transactions =
      <_RemovalRequestsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RemovalRequestsTransaction(
      insertedRow: insertedRow,
      recentRows: recentRows,
      listDueRows: listDueRows,
      claimedRows: claimedRows,
      updateAffectedRows: updateAffectedRows,
      incrementReturnRows: incrementReturnRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _RemovalRequestsTransaction extends PostgresTransaction {
  _RemovalRequestsTransaction({
    required this.insertedRow,
    required this.recentRows,
    required this.listDueRows,
    required this.claimedRows,
    required this.updateAffectedRows,
    required this.incrementReturnRows,
  });

  final PostgresRow? insertedRow;
  final List<PostgresRow> recentRows;
  final List<PostgresRow> listDueRows;
  final List<PostgresRow> claimedRows;
  final int updateAffectedRows;
  final List<PostgresRow> incrementReturnRows;

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
    if (sql.contains('insert into mfa_factor_removal_requests')) {
      if (insertedRow == null) return const <PostgresRow>[];
      return <PostgresRow>[insertedRow!];
    }
    // M4 — incrementAttemptCount routes UPDATE … RETURNING through
    // query(). The RETURNING clause is the discriminator; tenant
    // SET LOCAL statements share the `update` keyword but never
    // touch this table.
    if (sql.contains('update mfa_factor_removal_requests') &&
        sql.contains('returning attempt_count')) {
      return incrementReturnRows;
    }
    if (sql.contains('from mfa_factor_removal_requests')) {
      // claimDuePending CTE — outermost SELECT comes back from the
      // `claimed` CTE.
      if (sql.contains('for update skip locked')) {
        return claimedRows;
      }
      // listDuePendingForUser — filters execute_after <= @now.
      if (sql.contains('execute_after <= @now')) {
        return listDueRows;
      }
      // Default — listRecentForUser.
      return recentRows;
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
    if (sql.contains('update mfa_factor_removal_requests')) {
      return updateAffectedRows;
    }
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
