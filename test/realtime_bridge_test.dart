// Phase 10a.0 — RealtimeBridgeWorker integration test.
//
// Drives the worker against:
//   * a fake OutboxNotificationListener (controls when wake-ups fire)
//   * the real EventOutboxRepository wired to a recording fake pool
//     (proves the worker uses claimBatch and markDelivered as the
//     contract requires — no LISTEN-fan-out shortcut)
//   * the real InProcessRealtimePublisher (so subscribers can verify
//     they receive frames)
//
// Pinned behavior (matches `docs/contracts/event_outbox_contract.md`):
//   * On wake-up, the worker calls claimBatch — the fake pool sees the
//     `with claimed as` SQL with `for update skip locked`.
//   * Each successfully published row is followed by a markDelivered
//     UPDATE.
//   * Multiple wake-ups for the same operator are coalesced — no
//     parallel claims for the same operator (would race under SKIP
//     LOCKED).
//   * The 60s poll tick drains all known operators even without a
//     fresh notification.
//   * RealtimeEvent.eventId prefers payload['event_id'] when present;
//     falls back to outbox id otherwise.
//
// Phase 10a.2 — additional pinned behaviour for the dead-letter cap
// + transactional MOVE + counter increment, exercised in a separate
// test group below so the existing publish-loop tests stay
// untouched (per the slice's "do NOT modify existing publish-loop
// tests" constraint).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/outbox_notification_listener.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_dead_letter_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';

import '../tool/advisor_proxy/realtime_bridge.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const String _locB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

void main() {
  group('RealtimeBridgeWorker — claim → publish → markDelivered', () {
    test(
      'on notification, runs claimBatch + publishes each row + marks '
      'delivered (no LISTEN-fan-out shortcut)',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '101', operatorId: _opA, topic: 'rollup.invalidate.variance_week'),
          ],
          updateRowCount: 1,
        );
        final listener = _FakeListener();
        final publisher = InProcessRealtimePublisher();
        final worker = RealtimeBridgeWorker(
          listener: listener,
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (_) async => _locA,
        );
        final received = <RealtimeEvent>[];
        publisher.subscribe(_opA).listen(received.add);

        await worker.start();
        listener.fire(operatorId: _opA, topic: 'rollup.invalidate.variance_week', id: '101');
        // Drain microtasks so the bridge processes the notification.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(received, hasLength(1));
        expect(received.single.topic, 'rollup.invalidate.variance_week');
        expect(received.single.eventId, '101');
        expect(received.single.operatorId, _opA);

        // The fake pool recorded one transaction with both the claim
        // SQL and the markDelivered UPDATE — proves no LISTEN-only
        // fan-out shortcut bypassed the table.
        final claimTx = pool.transactions.firstWhere(
          (t) => t.executedSql.any((s) => s.contains('with claimed as')),
        );
        expect(
          claimTx.executedSql.any((s) => s.contains('for update skip locked')),
          isTrue,
        );
        final deliverTx = pool.transactions.firstWhere(
          (t) =>
              t.executedSql.any((s) => s.contains('set delivered_at = now()')),
        );
        expect(deliverTx.executedSql.any((s) => s.contains('id = @id::bigint')),
            isTrue);

        await worker.stop();
        await publisher.close();
      },
    );

    test(
      'eventId prefers payload event_id; falls back to outbox id when '
      'payload does not carry one',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(
              id: '201',
              operatorId: _opA,
              topic: 'rollup.invalidate.variance_week',
              payload: const <String, Object?>{'event_id': 'producer-uuid'},
            ),
            _row(
              id: '202',
              operatorId: _opA,
              topic: 'rollup.invalidate.variance_week',
            ),
          ],
          updateRowCount: 1,
        );
        final publisher = InProcessRealtimePublisher();
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
        );
        final received = <RealtimeEvent>[];
        publisher.subscribe(_opA).listen(received.add);

        await worker.start();
        // Bootstrap drain runs once at start — covers both rows.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(received.map((e) => e.eventId).toList(),
            <String>['producer-uuid', '202']);

        await worker.stop();
        await publisher.close();
      },
    );

    test(
      'concurrent notifications for the same operator coalesce into a '
      'single drain (would race under FOR UPDATE SKIP LOCKED otherwise)',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '301', operatorId: _opA, topic: 'rollup.invalidate.variance_week'),
          ],
          updateRowCount: 1,
        );
        final listener = _FakeListener();
        final publisher = InProcessRealtimePublisher();
        final worker = RealtimeBridgeWorker(
          listener: listener,
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (_) async => _locA,
        );
        await worker.start();
        // Fire three notifications synchronously before the first
        // drain finishes its first await.
        listener.fire(operatorId: _opA, topic: 'a.b.c', id: '301');
        listener.fire(operatorId: _opA, topic: 'a.b.c', id: '301');
        listener.fire(operatorId: _opA, topic: 'a.b.c', id: '301');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // Should have run claimBatch exactly once for the burst.
        final claimRuns = pool.transactions
            .where(
              (t) => t.executedSql.any((s) => s.contains('with claimed as')),
            )
            .length;
        expect(
          claimRuns,
          1,
          reason: 'three notifications coalesce into one claim cycle so '
              'concurrent claims do not race on FOR UPDATE SKIP LOCKED',
        );
        await worker.stop();
        await publisher.close();
      },
    );

    test(
      'poll tick drains all known operators even with no notification',
      () async {
        final logEvents = <RealtimeBridgeLogEvent>[];
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '401', operatorId: _opA, topic: 'rollup.invalidate.variance_week'),
          ],
          updateRowCount: 1,
        );
        final publisher = InProcessRealtimePublisher();
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (op) async => op == _opA ? _locA : _locB,
          bootstrapOperatorIds: const <String>{_opA, _opB},
          // Real timer with a short interval so the test does not
          // depend on fakeAsync microtask gymnastics for the
          // bootstrap drain to complete in addition to the poll tick.
          pollInterval: const Duration(milliseconds: 50),
          logger: logEvents.add,
        );
        await worker.start();
        // Bootstrap drain is unawaited inside start(); give real time
        // for both operators to drain sequentially.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        final claimsAfterBootstrap = pool.transactions
            .where(
              (t) => t.executedSql.any((s) => s.contains('with claimed as')),
            )
            .length;
        // Both operators should have a claim TX from the bootstrap.
        expect(
          claimsAfterBootstrap,
          greaterThanOrEqualTo(2),
          reason:
              'bootstrap drain should iterate both seeded operators; '
              'observed log events: '
              '${logEvents.map((e) => e.kind.name).toList()}',
        );
        // Wait one poll interval — should drain both operators again.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final claimsAfterPoll = pool.transactions
            .where(
              (t) => t.executedSql.any((s) => s.contains('with claimed as')),
            )
            .length;
        expect(claimsAfterPoll, greaterThan(claimsAfterBootstrap));
        await worker.stop();
        await publisher.close();
      },
    );

    test(
      'poll cycle pulls in operators discovered via the discoverer '
      '(not just bootstrap / NOTIFY-known operators)',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '601', operatorId: _opA, topic: 'rollup.invalidate.variance_week'),
          ],
          updateRowCount: 1,
        );
        // Discoverer reveals an operator that the bridge has never
        // seen via NOTIFY and that was not bootstrap-seeded. Without
        // the discoverer being honored, this operator's row would
        // strand because the poll only walks `_knownOperatorIds`.
        var discoveryCalls = 0;
        Future<Set<String>> discoverer() async {
          discoveryCalls += 1;
          return {_opA};
        }
        final publisher = InProcessRealtimePublisher();
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          operatorDiscoverer: discoverer,
          // Empty bootstrap on purpose: simulates production startup
          // before any NOTIFY has been received.
          pollInterval: const Duration(milliseconds: 50),
        );
        await worker.start();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        // Bootstrap cycle should have called discoverer + drained _opA.
        expect(discoveryCalls, greaterThanOrEqualTo(1));
        final claims = pool.transactions
            .where(
              (t) => t.executedSql.any((s) => s.contains('with claimed as')),
            )
            .length;
        expect(
          claims,
          greaterThanOrEqualTo(1),
          reason: 'discovered operator must be drained even though the '
              'bridge never received a NOTIFY for it and was started '
              'with no bootstrap seed',
        );
        await worker.stop();
        await publisher.close();
      },
    );

    test(
      'discoverer failure does NOT block draining of already-known operators',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '701', operatorId: _opA, topic: 'rollup.invalidate.variance_week'),
          ],
          updateRowCount: 1,
        );
        Future<Set<String>> failingDiscoverer() async {
          throw const _SimulatedDiscoveryFailure();
        }
        final logEvents = <RealtimeBridgeLogEvent>[];
        final publisher = InProcessRealtimePublisher();
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          operatorDiscoverer: failingDiscoverer,
          bootstrapOperatorIds: const <String>{_opA},
          pollInterval: const Duration(milliseconds: 50),
          logger: logEvents.add,
        );
        await worker.start();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        // _opA was bootstrapped, so the cycle still drains it.
        final claims = pool.transactions
            .where(
              (t) => t.executedSql.any((s) => s.contains('with claimed as')),
            )
            .length;
        expect(claims, greaterThanOrEqualTo(1));
        // Discovery failure logged.
        expect(
          logEvents.where(
            (e) => e.kind == RealtimeBridgeLogKind.discoveryFailed,
          ),
          isNotEmpty,
        );
        await worker.stop();
        await publisher.close();
      },
    );

    test(
      'publish failure leaves the row unmarked (lease retry); '
      'markDelivered is NOT called',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '501', operatorId: _opA, topic: 'rollup.invalidate.variance_week'),
          ],
          updateRowCount: 1,
        );
        final publisher = _FailingPublisher();
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
        );
        await worker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(publisher.attempts, 1);
        // No markDelivered UPDATE recorded — the row stays claimed
        // until the lease window expires and another claim picks it up.
        final delivered = pool.transactions.any(
          (t) => t.executedSql.any((s) => s.contains('set delivered_at = now()')),
        );
        expect(
          delivered,
          isFalse,
          reason: 'publish failure must not seal the outbox row — the '
              'lease-based retry is the safety net',
        );
        await worker.stop();
      },
    );
  });

  // ── Phase 10a.2 — DLQ cap + transactional MOVE + counter ─────────────
  //
  // These tests are intentionally a separate group so the existing
  // publish-loop tests above stay byte-untouched (per the slice's
  // "do NOT modify existing publish-loop tests" constraint).
  group('RealtimeBridgeWorker — Phase 10a.2 DLQ', () {
    test(
      'cap enforcement: row with attempt_count > cap MOVES to DLQ '
      'BEFORE the publish loop runs; publisher never sees the row',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(
              id: '801',
              operatorId: _opA,
              topic: 'rollup.invalidate.variance_week',
              attemptCount: 6,
            ),
          ],
          updateRowCount: 1,
          dlqMoveReturningId: '801',
        );
        final publisher = _RecordingPublisher();
        final logEvents = <RealtimeBridgeLogEvent>[];
        final wrapper = TenantTransactionWrapper(pool);
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository: EventOutboxRepository(wrapper),
          deadLetterRepository: EventOutboxDeadLetterRepository(wrapper),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
          dlqCap: 5,
          logger: logEvents.add,
        );
        await worker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // Publisher must NOT have received the over-cap row — MOVE
        // happens before the publish loop.
        expect(
          publisher.published,
          isEmpty,
          reason: 'rows past the cap must MOVE to DLQ instead of '
              'being published; otherwise subscribers get a payload '
              'the bridge already gave up on',
        );

        // The MOVE CTE ran exactly once.
        final moveTransactions = pool.transactions.where(
          (t) => t.executedSql.any(
            (s) =>
                s.contains('with dead as') &&
                s.contains('insert into event_outbox_dead_letter'),
          ),
        );
        expect(
          moveTransactions,
          hasLength(1),
          reason: 'one row past the cap → exactly one MOVE CTE',
        );

        // Counter increments by 1 on a successful MOVE.
        expect(worker.deadLetteredTotal, equals(1));

        // Structured log surfaced the deadLettered event with cap +
        // attempt_count metadata so log search can correlate cap
        // changes with DLQ-rate changes.
        final dlqEvent = logEvents.firstWhere(
          (e) => e.kind == RealtimeBridgeLogKind.deadLettered,
        );
        expect(dlqEvent.attemptCount, equals(6));
        expect(dlqEvent.cap, equals(5));
        expect(dlqEvent.outboxId, equals('801'));

        await worker.stop();
      },
    );

    test(
      'transactional move: the MOVE CTE is a single statement that '
      'BOTH deletes from event_outbox AND inserts into '
      'event_outbox_dead_letter — either both writes commit or '
      'neither does (test asserts the wire shape and rollback path)',
      () async {
        // Path A — both writes in one CTE, commit.
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(
              id: '901',
              operatorId: _opA,
              topic: 'rollup.invalidate.variance_week',
              attemptCount: 7,
            ),
          ],
          updateRowCount: 1,
          dlqMoveReturningId: '901',
        );
        final publisher = _RecordingPublisher();
        final wrapper = TenantTransactionWrapper(pool);
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository: EventOutboxRepository(wrapper),
          deadLetterRepository: EventOutboxDeadLetterRepository(wrapper),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
          dlqCap: 5,
        );
        await worker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        final moveTx = pool.transactions.firstWhere(
          (t) => t.executedSql.any((s) => s.contains('with dead as')),
        );
        // The single SQL string contains BOTH the DELETE and the
        // INSERT — Postgres CTE semantics make this one statement
        // execute atomically inside the wrapping transaction.
        final cteSql = moveTx.executedSql.firstWhere(
          (s) => s.contains('with dead as'),
        );
        expect(cteSql, contains('delete from event_outbox'));
        expect(cteSql, contains('insert into event_outbox_dead_letter'));
        expect(cteSql, contains('returning'));
        // The MOVE transaction committed (success path).
        expect(moveTx.commitCount, equals(1));
        expect(moveTx.rollbackCount, equals(0));

        await worker.stop();

        // Path B — DB failure inside the MOVE rolls the whole
        // transaction back; counter does NOT increment; the row
        // stays in the live queue (re-claimable on the next cycle).
        final failingPool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(
              id: '902',
              operatorId: _opA,
              topic: 'rollup.invalidate.variance_week',
              attemptCount: 7,
            ),
          ],
          updateRowCount: 1,
          dlqMoveThrows: const _SimulatedDlqMoveFailure(),
        );
        final failingPublisher = _RecordingPublisher();
        final failingLogs = <RealtimeBridgeLogEvent>[];
        final failingWrapper = TenantTransactionWrapper(failingPool);
        final failingWorker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository: EventOutboxRepository(failingWrapper),
          deadLetterRepository:
              EventOutboxDeadLetterRepository(failingWrapper),
          publisher: failingPublisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
          dlqCap: 5,
          logger: failingLogs.add,
        );
        await failingWorker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        final failedMoveTx = failingPool.transactions.firstWhere(
          (t) => t.executedSql.any((s) => s.contains('with dead as')),
        );
        expect(
          failedMoveTx.commitCount,
          equals(0),
          reason: 'MOVE failure must NOT commit — neither DELETE nor '
              'INSERT can land partially',
        );
        expect(failedMoveTx.rollbackCount, equals(1));
        expect(
          failingWorker.deadLetteredTotal,
          equals(0),
          reason: 'counter must not advance on rollback — it tracks '
              'successful MOVEs only',
        );
        expect(
          failingPublisher.published,
          isEmpty,
          reason: 'a row that should have moved must NOT be published, '
              'even when the MOVE itself failed; the next claim cycle '
              're-attempts the partition',
        );
        // Failure event surfaced in the log stream.
        expect(
          failingLogs.where(
            (e) => e.kind == RealtimeBridgeLogKind.deadLetterMoveFailed,
          ),
          isNotEmpty,
        );
        await failingWorker.stop();
      },
    );

    test(
      'counter increment: each successful MOVE bumps the bridge '
      'worker\'s deadLetteredTotal by exactly 1 (process-local '
      'counter; the proxy /health envelope reports table depth via '
      'a separate SQL count, not this counter)',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(
              id: '1001',
              operatorId: _opA,
              topic: 'rollup.invalidate.variance_week',
              attemptCount: 6,
            ),
            _row(
              id: '1002',
              operatorId: _opA,
              topic: 'rollup.invalidate.variance_week',
              attemptCount: 8,
            ),
            _row(
              id: '1003',
              operatorId: _opA,
              topic: 'rollup.invalidate.variance_week',
              attemptCount: 2, // BELOW cap — should NOT count toward DLQ
            ),
          ],
          updateRowCount: 1,
          dlqMoveReturningId: 'will-be-overridden',
          dlqMoveReturningIds: <String>['1001', '1002'],
        );
        final publisher = _RecordingPublisher();
        final wrapper = TenantTransactionWrapper(pool);
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository: EventOutboxRepository(wrapper),
          deadLetterRepository: EventOutboxDeadLetterRepository(wrapper),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
          dlqCap: 5,
        );
        await worker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          worker.deadLetteredTotal,
          equals(2),
          reason: 'two rows past the cap → counter at 2; the third row '
              'with attempt_count below the cap must NOT count toward '
              'the DLQ total',
        );
        // The below-cap row went through the publish path normally.
        expect(
          publisher.published.map((e) => e.eventId).toList(),
          equals(<String>['1003']),
        );
        await worker.stop();
      },
    );

    test(
      'env var override: a higher EVENT_OUTBOX_DLQ_CAP keeps a row at '
      'attempt_count = 6 in the live queue (matches the walkthrough '
      'env var override scenario)',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(
              id: '1101',
              operatorId: _opA,
              topic: 'rollup.invalidate.variance_week',
              attemptCount: 6,
            ),
          ],
          updateRowCount: 1,
        );
        final publisher = _RecordingPublisher();
        final wrapper = TenantTransactionWrapper(pool);
        // Resolved cap = 10 (operator raised the env var to ride out
        // a vendor-side outage). Row at attempt_count = 6 should NOT
        // move to DLQ; should publish normally.
        final cap = resolveEventOutboxDlqCap(<String, String>{
          eventOutboxDlqCapEnvVar: '10',
        });
        expect(cap, equals(10));
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository: EventOutboxRepository(wrapper),
          deadLetterRepository: EventOutboxDeadLetterRepository(wrapper),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
          dlqCap: cap,
        );
        await worker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // No MOVE happened — row stayed in the live queue and went
        // through publish + markDelivered.
        expect(worker.deadLetteredTotal, equals(0));
        final moveAttempts = pool.transactions
            .where(
              (t) =>
                  t.executedSql.any((s) => s.contains('with dead as')),
            )
            .length;
        expect(
          moveAttempts,
          equals(0),
          reason: 'env var override raised the cap; row stays in '
              'the live queue and goes through normal publish path',
        );
        expect(publisher.published, hasLength(1));
        expect(publisher.published.single.eventId, equals('1101'));

        await worker.stop();
      },
    );

    test(
      'resolveEventOutboxDlqCap: missing env, blank, non-numeric, or '
      'sub-1 values fall back to defaultEventOutboxDlqCap',
      () {
        expect(
          resolveEventOutboxDlqCap(const <String, String>{}),
          equals(defaultEventOutboxDlqCap),
        );
        expect(
          resolveEventOutboxDlqCap(const <String, String>{
            eventOutboxDlqCapEnvVar: '',
          }),
          equals(defaultEventOutboxDlqCap),
        );
        expect(
          resolveEventOutboxDlqCap(const <String, String>{
            eventOutboxDlqCapEnvVar: '   ',
          }),
          equals(defaultEventOutboxDlqCap),
        );
        expect(
          resolveEventOutboxDlqCap(const <String, String>{
            eventOutboxDlqCapEnvVar: 'abc',
          }),
          equals(defaultEventOutboxDlqCap),
        );
        expect(
          resolveEventOutboxDlqCap(const <String, String>{
            eventOutboxDlqCapEnvVar: '0',
          }),
          equals(defaultEventOutboxDlqCap),
          reason: 'cap < 1 would auto-DLQ every row on first failure; '
              'the resolver clamps back to the default',
        );
        expect(
          resolveEventOutboxDlqCap(const <String, String>{
            eventOutboxDlqCapEnvVar: '12',
          }),
          equals(12),
        );
      },
    );

    test(
      'Phase 10a.4 publish-metrics: success increments attempted '
      'only; failure increments BOTH attempted and failed in the '
      'same minute bucket',
      () async {
        final pinnedClock = DateTime.utc(2026, 5, 5, 12, 34, 17);
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '2001', operatorId: _opA, topic: 'rollup.invalidate.x'),
            _row(id: '2002', operatorId: _opA, topic: 'rollup.invalidate.x'),
            _row(id: '2003', operatorId: _opA, topic: 'rollup.invalidate.x'),
          ],
          updateRowCount: 1,
        );
        // First two publish OK, third throws.
        final publisher = _CountingFlakyPublisher(failOnIndices: const {2});
        final flushedBatches =
            <List<RealtimeBridgePublishMetricsBucket>>[];
        Future<void> writer(
          List<RealtimeBridgePublishMetricsBucket> buckets,
        ) async {
          flushedBatches.add(List.unmodifiable(buckets));
        }

        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
          publishMetricsWriter: writer,
          // Long enough that the periodic timer never fires during
          // the test; we drive the flush via worker.stop().
          publishMetricsFlushInterval: const Duration(seconds: 5),
          clock: () => pinnedClock,
        );
        await worker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // Process-lifetime totals before stop().
        expect(
          worker.publishAttemptedTotal,
          equals(3),
          reason: 'every publish attempt bumps attempted, even the '
              'one that throws',
        );
        expect(
          worker.publishFailedTotal,
          equals(1),
          reason: 'only the throwing publish bumps failed',
        );

        await worker.stop();

        // Final flush on stop emitted exactly one bucket (all three
        // attempts share the same minute via the pinned clock).
        expect(flushedBatches, hasLength(1));
        expect(flushedBatches.single, hasLength(1));
        final bucket = flushedBatches.single.single;
        expect(
          bucket.windowStart,
          equals(DateTime.utc(2026, 5, 5, 12, 34)),
          reason: 'bucket boundary is the start-of-minute UTC',
        );
        expect(bucket.attemptedDelta, equals(3));
        expect(bucket.failedDelta, equals(1));
      },
    );

    test(
      'Phase 10a.4 publish-metrics: events that span a minute '
      'boundary land in separate buckets',
      () async {
        final clockReturns = <DateTime>[
          DateTime.utc(2026, 5, 5, 12, 34, 50), // bucket 12:34
          DateTime.utc(2026, 5, 5, 12, 34, 59), // bucket 12:34
          DateTime.utc(2026, 5, 5, 12, 35, 1),  // bucket 12:35
        ];
        var clockIndex = 0;
        DateTime nextNow() {
          final t = clockReturns[clockIndex];
          clockIndex = (clockIndex + 1) % clockReturns.length;
          return t;
        }

        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '3001', operatorId: _opA, topic: 'rollup.invalidate.x'),
            _row(id: '3002', operatorId: _opA, topic: 'rollup.invalidate.x'),
            _row(id: '3003', operatorId: _opA, topic: 'rollup.invalidate.x'),
          ],
          updateRowCount: 1,
        );
        final publisher = _RecordingPublisher();
        final flushed = <RealtimeBridgePublishMetricsBucket>[];
        Future<void> writer(
          List<RealtimeBridgePublishMetricsBucket> buckets,
        ) async {
          flushed.addAll(buckets);
        }

        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
          publishMetricsWriter: writer,
          publishMetricsFlushInterval: const Duration(seconds: 5),
          clock: nextNow,
        );
        await worker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await worker.stop();

        // Two distinct buckets: minute 34 (2 attempts) and minute 35
        // (1 attempt). No failures in either.
        final byBucket = <DateTime, RealtimeBridgePublishMetricsBucket>{
          for (final b in flushed) b.windowStart: b,
        };
        expect(
          byBucket.keys,
          containsAll(<DateTime>[
            DateTime.utc(2026, 5, 5, 12, 34),
            DateTime.utc(2026, 5, 5, 12, 35),
          ]),
        );
        expect(
          byBucket[DateTime.utc(2026, 5, 5, 12, 34)]?.attemptedDelta,
          equals(2),
        );
        expect(
          byBucket[DateTime.utc(2026, 5, 5, 12, 34)]?.failedDelta,
          equals(0),
        );
        expect(
          byBucket[DateTime.utc(2026, 5, 5, 12, 35)]?.attemptedDelta,
          equals(1),
        );
      },
    );

    test(
      'Phase 10a.4 publish-metrics: writer failure merges deltas '
      'back into the live map; the next flush retries them',
      () async {
        final pinnedClock = DateTime.utc(2026, 5, 5, 12, 36, 0);
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '4001', operatorId: _opA, topic: 'rollup.invalidate.x'),
          ],
          updateRowCount: 1,
        );
        final publisher = _RecordingPublisher();
        var callIndex = 0;
        final logEvents = <RealtimeBridgeLogEvent>[];
        final accepted = <RealtimeBridgePublishMetricsBucket>[];
        Future<void> writer(
          List<RealtimeBridgePublishMetricsBucket> buckets,
        ) async {
          callIndex += 1;
          if (callIndex == 1) {
            throw StateError('simulated writer failure');
          }
          accepted.addAll(buckets);
        }

        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
          publishMetricsWriter: writer,
          publishMetricsFlushInterval: const Duration(milliseconds: 50),
          clock: () => pinnedClock,
          logger: logEvents.add,
        );
        await worker.start();
        // Let bootstrap publish, then wait for the first flush
        // (which throws) AND a second flush (which retries).
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await worker.stop();

        // The first writer call threw; the bridge logged the failure
        // and merged the snapshot back. A subsequent flush succeeded
        // and `accepted` carries the original delta.
        expect(callIndex, greaterThanOrEqualTo(2));
        expect(
          logEvents.where(
            (e) => e.kind == RealtimeBridgeLogKind.publishMetricsFlushFailed,
          ),
          isNotEmpty,
        );
        expect(
          accepted,
          isNotEmpty,
          reason: 'a successful retry must deliver the original deltas',
        );
        final retried = accepted.firstWhere(
          (b) => b.windowStart == DateTime.utc(2026, 5, 5, 12, 36),
        );
        expect(retried.attemptedDelta, equals(1));
        expect(retried.failedDelta, equals(0));
      },
    );

    test(
      'Phase 10a.4 publish-metrics: when no writer is wired, the '
      'flush timer never starts and the publish loop runs unchanged',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '5001', operatorId: _opA, topic: 'rollup.invalidate.x'),
          ],
          updateRowCount: 1,
        );
        final publisher = _RecordingPublisher();
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
          // publishMetricsWriter intentionally null — backward compat.
          publishMetricsFlushInterval: const Duration(milliseconds: 10),
        );
        await worker.start();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await worker.stop();

        // Counters still tick (cheap accounting) but no flush surface
        // observed, no log events emitted.
        expect(worker.publishAttemptedTotal, equals(1));
        expect(worker.publishFailedTotal, equals(0));
        expect(publisher.published, hasLength(1));
      },
    );

    test(
      'when no dead-letter repository is wired (existing demo / '
      'scaffold callers), the bridge runs the original publish loop '
      'without DLQ logic — preserves backward compatibility',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(
              id: '1201',
              operatorId: _opA,
              topic: 'rollup.invalidate.variance_week',
              attemptCount: 99,
            ),
          ],
          updateRowCount: 1,
        );
        final publisher = _RecordingPublisher();
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository:
              EventOutboxRepository(TenantTransactionWrapper(pool)),
          // deadLetterRepository intentionally null.
          publisher: publisher,
          locationResolver: (_) async => _locA,
          bootstrapOperatorIds: const <String>{_opA},
          dlqCap: 5,
        );
        await worker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // Even though attempt_count = 99, no MOVE happens because
        // the dead-letter repo is null. The row publishes normally.
        expect(worker.deadLetteredTotal, equals(0));
        expect(publisher.published, hasLength(1));
        expect(publisher.published.single.eventId, equals('1201'));

        await worker.stop();
      },
    );
  });

  // ── Code-Health L8 — attempt_count is actually incremented ───────────
  //
  // The pre-L8 behaviour was theatre: rows that failed to publish stayed
  // at attempt_count=0 forever, so the claim-time partition
  // `attempt_count > _dlqCap` never fired and a poison-pill row recycled
  // until 7-day retention swept it. These tests pin the new contract:
  //   * Every publish failure invokes the [BridgeOutboxFailureMarker].
  //   * The marker returns the new attempt_count (post-increment).
  //   * When the new count crosses the cap, the bridge calls
  //     `moveFromOutbox` inline with `attemptCountThreshold = cap - 1`
  //     and bumps the DLQ counter exactly once.
  group('Code-Health L8 — attempt_count increment + DLQ on cap', () {
    test(
      '5 successive publish failures bump attempt_count from 0→5; the '
      '5th failure transitions the row to DLQ; metric counter '
      'increments once',
      () async {
        // The bridge claims 5 times in a row; each claim returns the
        // same logical row (same id) with an incrementing attempt_count
        // 0..4. The publisher always throws. The marker mimics a
        // tenant-scoped UPDATE that bumps attempt_count and returns the
        // new value. The dead-letter pool fixture lets the MOVE return
        // a non-null id on the 5th failure.
        const rowId = '7777';
        final markerCalls = <_FailureMarkerCall>[];
        var attemptCount = 0;
        Future<int> failureMarker({
          required String operatorId,
          required String locationId,
          required String eventId,
          required String errorMessage,
        }) async {
          markerCalls.add(_FailureMarkerCall(
            operatorId: operatorId,
            locationId: locationId,
            eventId: eventId,
            errorMessage: errorMessage,
          ));
          attemptCount += 1;
          return attemptCount;
        }

        // Build five claim batches, each with one row whose
        // attempt_count reflects the prior failures. Note: the bridge
        // re-claims after a lease window in production; here we drive
        // five back-to-back drain cycles through `_runPollCycle`-
        // equivalent bootstrap notifications.
        const cap = 5;
        final logEvents = <RealtimeBridgeLogEvent>[];
        final publisher = _FailingPublisher();

        // The pool is built per-cycle so each "claim" returns a row
        // carrying the up-to-date attempt_count. We drive one drain
        // per cycle by re-creating the worker — simpler than making
        // the fake pool stateful across calls.
        for (var cycle = 1; cycle <= 5; cycle++) {
          final claimed = _row(
            id: rowId,
            operatorId: _opA,
            topic: 'rollup.invalidate.variance_week',
            attemptCount: cycle - 1, // 0,1,2,3,4 entering the failure
          );
          // On the cap-crossing cycle, the MOVE CTE returns the row
          // id (success). Earlier cycles must NOT call MOVE.
          final pool = _BridgePool(
            claimedRows: <PostgresRow>[claimed],
            updateRowCount: 1,
            dlqMoveReturningId: cycle == cap ? rowId : null,
          );
          final wrapper = TenantTransactionWrapper(pool);
          final worker = RealtimeBridgeWorker(
            listener: _FakeListener(),
            outboxRepository: EventOutboxRepository(wrapper),
            deadLetterRepository: EventOutboxDeadLetterRepository(wrapper),
            publisher: publisher,
            locationResolver: (_) async => _locA,
            outboxFailureMarker: failureMarker,
            bootstrapOperatorIds: const <String>{_opA},
            dlqCap: cap,
            logger: logEvents.add,
          );
          await worker.start();
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);

          // Marker is invoked once per failure.
          expect(
            markerCalls.length,
            equals(cycle),
            reason:
                'cycle $cycle: marker should have been invoked once '
                'per accumulated publish failure',
          );
          // attempt_count after the cycle's increment matches the
          // cycle index (1..5).
          expect(
            attemptCount,
            equals(cycle),
            reason: 'cycle $cycle: attempt_count should be $cycle '
                'after the marker bumps it',
          );

          // Cycles 1..4 must NOT have run a DLQ MOVE; cycle 5 must.
          final moveTransactions = pool.transactions.where(
            (t) => t.executedSql.any(
              (s) =>
                  s.contains('with dead as') &&
                  s.contains('insert into event_outbox_dead_letter'),
            ),
          );
          if (cycle < cap) {
            expect(
              moveTransactions,
              isEmpty,
              reason: 'cycle $cycle: row has not crossed the cap yet, '
                  'no MOVE should fire',
            );
            expect(
              worker.deadLetteredTotal,
              equals(0),
              reason: 'cycle $cycle: deadLetteredTotal must stay at 0 '
                  'until the cap is crossed',
            );
          } else {
            expect(
              moveTransactions,
              hasLength(1),
              reason: 'cap-crossing cycle: exactly one MOVE CTE runs',
            );
            expect(
              worker.deadLetteredTotal,
              equals(1),
              reason: 'cap-crossing cycle: counter increments once',
            );
            // The MOVE was issued with threshold = cap - 1 so the
            // server-side `attempt_count > threshold` predicate
            // matches the new count of `cap`.
            final moveTx = pool.transactions.firstWhere(
              (t) =>
                  t.executedSql.any((s) => s.contains('with dead as')),
            );
            final moveParams = moveTx.parameters[
                moveTx.executedSql.indexWhere(
                    (s) => s.contains('with dead as'))];
            expect(
              moveParams['threshold'],
              equals(cap - 1),
              reason:
                  'failure-time MOVE uses threshold = cap - 1 so the '
                  '`> threshold` predicate matches a row at exactly cap',
            );
          }

          await worker.stop();
        }

        // Final tally: 5 marker calls, 1 dead-letter event in the log,
        // attempt_count landed at exactly 5.
        expect(markerCalls.length, equals(5));
        expect(attemptCount, equals(5));
        final dlqEvents = logEvents.where(
          (e) => e.kind == RealtimeBridgeLogKind.deadLettered,
        );
        expect(
          dlqEvents,
          hasLength(1),
          reason: 'exactly one deadLettered log event across the run',
        );
        expect(dlqEvents.single.attemptCount, equals(5));
        expect(dlqEvents.single.cap, equals(5));
      },
    );

    test(
      'when no failure marker is wired (legacy callers), the bridge '
      'still logs publishFailed but does not increment attempt_count '
      'or call the dead-letter repository — preserves backward compat',
      () async {
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '8888', operatorId: _opA, topic: 'a.b'),
          ],
          updateRowCount: 1,
        );
        final publisher = _FailingPublisher();
        final logEvents = <RealtimeBridgeLogEvent>[];
        final wrapper = TenantTransactionWrapper(pool);
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository: EventOutboxRepository(wrapper),
          deadLetterRepository: EventOutboxDeadLetterRepository(wrapper),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          // outboxFailureMarker intentionally null — legacy path.
          bootstrapOperatorIds: const <String>{_opA},
          dlqCap: 5,
          logger: logEvents.add,
        );
        await worker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(publisher.attempts, 1);
        expect(
          logEvents.where(
            (e) => e.kind == RealtimeBridgeLogKind.publishFailed,
          ),
          isNotEmpty,
          reason: 'legacy path still logs publish failure',
        );
        expect(worker.deadLetteredTotal, equals(0));
        // No MOVE CTE was issued.
        final moveTransactions = pool.transactions.where(
          (t) => t.executedSql.any((s) => s.contains('with dead as')),
        );
        expect(moveTransactions, isEmpty);
        await worker.stop();
      },
    );

    test(
      'marker failure is logged but does not crash the publish loop; '
      'subsequent rows still drain',
      () async {
        // Two claimed rows: first publish fails AND the marker throws;
        // second publish succeeds and is markDelivered.
        final pool = _BridgePool(
          claimedRows: <PostgresRow>[
            _row(id: '9001', operatorId: _opA, topic: 'a.b'),
            _row(id: '9002', operatorId: _opA, topic: 'a.b'),
          ],
          updateRowCount: 1,
        );
        Future<int> throwingMarker({
          required String operatorId,
          required String locationId,
          required String eventId,
          required String errorMessage,
        }) async {
          throw StateError('simulated marker failure');
        }

        final publisher = _FlakyPublisherFailFirst();
        final logEvents = <RealtimeBridgeLogEvent>[];
        final wrapper = TenantTransactionWrapper(pool);
        final worker = RealtimeBridgeWorker(
          listener: _FakeListener(),
          outboxRepository: EventOutboxRepository(wrapper),
          deadLetterRepository: EventOutboxDeadLetterRepository(wrapper),
          publisher: publisher,
          locationResolver: (_) async => _locA,
          outboxFailureMarker: throwingMarker,
          bootstrapOperatorIds: const <String>{_opA},
          dlqCap: 5,
          logger: logEvents.add,
        );
        await worker.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // Both rows were attempted; the second succeeded.
        expect(publisher.attempts, equals(2));
        // markDelivered ran for the successful row.
        final delivered = pool.transactions.any(
          (t) => t.executedSql.any(
            (s) => s.contains('set delivered_at = now()'),
          ),
        );
        expect(
          delivered,
          isTrue,
          reason: 'second row should still be markDelivered',
        );
        // Counter stays at 0 (marker threw, no MOVE).
        expect(worker.deadLetteredTotal, equals(0));
        await worker.stop();
      },
    );
  });
}

class _SimulatedDlqMoveFailure implements Exception {
  const _SimulatedDlqMoveFailure();
}

class _RecordingPublisher implements RealtimeEventPublisher {
  final List<RealtimeEvent> published = <RealtimeEvent>[];

  @override
  Future<void> publish(RealtimeEvent event) async {
    published.add(event);
  }
}

PostgresRow _row({
  required String id,
  required String operatorId,
  required String topic,
  Map<String, Object?> payload = const <String, Object?>{},
  int attemptCount = 0,
}) {
  final now = DateTime.utc(2026, 5, 2, 12);
  return <String, Object?>{
    'id': id,
    'operator_id': operatorId,
    'topic': topic,
    'payload': payload,
    'created_at': now.subtract(const Duration(seconds: 1)),
    'picked_up_at': now,
    'attempt_count': attemptCount,
  };
}

class _FakeListener implements OutboxNotificationListener {
  final StreamController<OutboxNotification> _controller =
      StreamController<OutboxNotification>.broadcast();

  @override
  Stream<OutboxNotification> get notifications => _controller.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    if (!_controller.isClosed) await _controller.close();
  }

  void fire({
    required String operatorId,
    required String topic,
    required String id,
  }) {
    _controller.add(
      OutboxNotification(operatorId: operatorId, topic: topic, outboxId: id),
    );
  }
}

class _FailingPublisher implements RealtimeEventPublisher {
  int attempts = 0;

  @override
  Future<void> publish(RealtimeEvent event) async {
    attempts += 1;
    throw const _SimulatedPublishFailure();
  }
}

/// Code-Health L8 — captures one [BridgeOutboxFailureMarker] call so
/// tests can assert which row, operator, and location the marker
/// observed. Distinct from [_FailureMarkerLog] only in that it lives
/// alongside the L8 group's helpers.
class _FailureMarkerCall {
  const _FailureMarkerCall({
    required this.operatorId,
    required this.locationId,
    required this.eventId,
    required this.errorMessage,
  });

  final String operatorId;
  final String locationId;
  final String eventId;
  final String errorMessage;
}

/// Code-Health L8 — publisher that throws on the FIRST publish call
/// and succeeds on every subsequent call. Used to verify the bridge's
/// publish loop continues past a failed-marker scenario.
class _FlakyPublisherFailFirst implements RealtimeEventPublisher {
  int attempts = 0;

  @override
  Future<void> publish(RealtimeEvent event) async {
    attempts += 1;
    if (attempts == 1) {
      throw const _SimulatedPublishFailure();
    }
  }
}

/// Phase 10a.4 — publisher that throws on a configurable subset of
/// publish indices (1-based). The 10a.4 publish-metrics tests use
/// this to drive a mix of success and failure in one drain.
class _CountingFlakyPublisher implements RealtimeEventPublisher {
  _CountingFlakyPublisher({required this.failOnIndices});

  /// 1-based indices into the publish sequence that should throw.
  final Set<int> failOnIndices;
  int _calls = 0;

  @override
  Future<void> publish(RealtimeEvent event) async {
    _calls += 1;
    if (failOnIndices.contains(_calls)) {
      throw const _SimulatedPublishFailure();
    }
  }
}

class _SimulatedPublishFailure implements Exception {
  const _SimulatedPublishFailure();
}

class _SimulatedDiscoveryFailure implements Exception {
  const _SimulatedDiscoveryFailure();
}

class _BridgePool implements PostgresPool {
  _BridgePool({
    this.claimedRows = const <PostgresRow>[],
    this.updateRowCount = 0,
    this.dlqMoveReturningId,
    this.dlqMoveReturningIds,
    this.dlqMoveThrows,
  });

  final List<PostgresRow> claimedRows;
  final int updateRowCount;

  /// Phase 10a.2 — what the MOVE CTE's `RETURNING id` should hand
  /// back. Used when a single row is moved.
  final String? dlqMoveReturningId;

  /// Phase 10a.2 — when the test expects multiple sequential MOVE
  /// calls (different rows in the same drain), each entry is the
  /// next response in order. Falls back to [dlqMoveReturningId] when
  /// the list is exhausted.
  final List<String>? dlqMoveReturningIds;

  /// Phase 10a.2 — simulate a DB failure inside the MOVE CTE. The
  /// transaction should roll back; counter must not increment.
  final Exception? dlqMoveThrows;

  final List<_BridgeTransaction> transactions = <_BridgeTransaction>[];
  int _dlqMoveCallIndex = 0;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final returningId = _nextDlqReturningId();
    final tx = _BridgeTransaction(
      claimedRows: claimedRows,
      updateRowCount: updateRowCount,
      dlqMoveReturningId: returningId,
      dlqMoveThrows: dlqMoveThrows,
    );
    transactions.add(tx);
    return tx;
  }

  String? _nextDlqReturningId() {
    final ids = dlqMoveReturningIds;
    if (ids != null && _dlqMoveCallIndex < ids.length) {
      return ids[_dlqMoveCallIndex++];
    }
    return dlqMoveReturningId;
  }
}

class _BridgeTransaction extends PostgresTransaction {
  _BridgeTransaction({
    required this.claimedRows,
    required this.updateRowCount,
    this.dlqMoveReturningId,
    this.dlqMoveThrows,
  });

  final List<PostgresRow> claimedRows;
  final int updateRowCount;
  final String? dlqMoveReturningId;
  final Exception? dlqMoveThrows;
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
    if (sql.contains('with claimed as') && sql.contains('update event_outbox e')) {
      return claimedRows;
    }
    if (sql.contains('with dead as') &&
        sql.contains('insert into event_outbox_dead_letter')) {
      if (dlqMoveThrows != null) throw dlqMoveThrows!;
      if (dlqMoveReturningId == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'id': dlqMoveReturningId},
      ];
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
    if (sql.contains('update event_outbox') &&
        sql.contains('set delivered_at = now()')) {
      return updateRowCount;
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
