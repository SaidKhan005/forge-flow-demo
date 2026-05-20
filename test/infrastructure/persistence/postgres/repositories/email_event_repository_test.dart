import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/email_event_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/email/sendgrid_event_payload.dart';

void main() {
  group('EmailEventRepository.insertProviderEvent — terminal outbox flip', () {
    // ── 1. Terminal `bounced` flips status from 'sent' to 'bounced' ──
    test(
      'terminal `bounced` event flips matching sent outbox row to bounced',
      () async {
        final pool = _Pool(
          insertRows: <PostgresRow>[
            <String, Object?>{'event_id': 'event-1'},
          ],
          existingOutboxStatus: 'sent',
        );
        final repo = EmailEventRepository(TenantTransactionWrapper(pool));

        final result = await repo.insertProviderEvent(
          _event(
            eventKind: 'bounced',
            providerEventId: 'sg-event-1',
            providerMessageId: 'sg-message-1',
          ),
        );

        expect(result, isA<EmailEventInsertInserted>());
        final inserted = result as EmailEventInsertInserted;
        expect(inserted.flipOutcome, EmailOutboxTerminalFlipResult.flipped);

        final tx = pool.transactions.single;
        final updateIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('update public.email_outbox'),
        );
        expect(
          updateIndex,
          isNonNegative,
          reason: 'terminal `bounced` must issue an UPDATE on email_outbox',
        );
        expect(
          tx.executedSql[updateIndex],
          contains('status not in (@terminal_bounced'),
          reason: 'guard must exclude existing terminal statuses',
        );
        expect(tx.parameters[updateIndex]['status'], 'bounced');
        expect(
          tx.parameters[updateIndex]['provider_message_id'],
          'sg-message-1',
        );
        expect(tx.commitCount, 1);
        expect(tx.rollbackCount, 0);
      },
    );

    // ── 2. Terminal `complaint` flips status from 'sent' to 'complaint' ──
    test(
      'terminal `complaint` event flips matching sent outbox row to complaint',
      () async {
        final pool = _Pool(
          insertRows: <PostgresRow>[
            <String, Object?>{'event_id': 'event-c'},
          ],
          existingOutboxStatus: 'sent',
        );
        final repo = EmailEventRepository(TenantTransactionWrapper(pool));

        final result = await repo.insertProviderEvent(
          _event(
            eventKind: 'complaint',
            providerEventId: 'sg-event-c',
            providerMessageId: 'sg-message-c',
          ),
        );

        expect(result, isA<EmailEventInsertInserted>());
        final inserted = result as EmailEventInsertInserted;
        expect(inserted.flipOutcome, EmailOutboxTerminalFlipResult.flipped);

        final tx = pool.transactions.single;
        final updateIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('update public.email_outbox'),
        );
        expect(updateIndex, isNonNegative);
        expect(tx.parameters[updateIndex]['status'], 'complaint');
        expect(
          tx.parameters[updateIndex]['provider_message_id'],
          'sg-message-c',
        );
      },
    );

    // ── 3. Non-terminal kinds (`delivered`/`opened`/`clicked`) do NOT
    // flip and skip the SELECT/UPDATE entirely. ─────────────────────
    for (final nonTerminalKind in const <String>[
      'delivered',
      'opened',
      'clicked',
    ]) {
      test(
        'non-terminal `$nonTerminalKind` event leaves outbox status untouched',
        () async {
          final pool = _Pool(
            insertRows: <PostgresRow>[
              <String, Object?>{'event_id': 'event-nt-$nonTerminalKind'},
            ],
            // Existing outbox row would be 'sent' but the helper must
            // not even look it up for non-terminal events.
            existingOutboxStatus: 'sent',
          );
          final repo = EmailEventRepository(TenantTransactionWrapper(pool));

          final result = await repo.insertProviderEvent(
            _event(
              eventKind: nonTerminalKind,
              providerEventId: 'sg-event-nt-$nonTerminalKind',
              providerMessageId: 'sg-message-nt-$nonTerminalKind',
            ),
          );

          expect(result, isA<EmailEventInsertInserted>());
          final inserted = result as EmailEventInsertInserted;
          expect(
            inserted.flipOutcome,
            isNull,
            reason: 'non-terminal kinds carry no flip outcome',
          );

          final tx = pool.transactions.single;
          expect(
            tx.executedSql.where(
              (sql) => sql.contains('update public.email_outbox'),
            ),
            isEmpty,
            reason: 'non-terminal kinds must not issue an UPDATE',
          );
          expect(
            tx.executedSql.where(
              (sql) => sql.contains('from public.email_outbox'),
            ),
            isEmpty,
            reason:
                'non-terminal kinds must not even SELECT the email_outbox row',
          );
        },
      );
    }

    // ── 4. Duplicate event (already-inserted email_event) does NOT
    // re-flip the email_outbox row. ─────────────────────────────────
    test(
      'duplicate terminal event does NOT re-flip the outbox row',
      () async {
        final pool = _Pool(
          // Empty `insertRows` simulates the partial UNIQUE INDEX
          // collision: ON CONFLICT DO NOTHING returns zero rows.
          insertRows: const <PostgresRow>[],
          existingOutboxStatus: 'bounced',
        );
        final repo = EmailEventRepository(TenantTransactionWrapper(pool));

        final result = await repo.insertProviderEvent(
          _event(
            eventKind: 'bounced',
            providerEventId: 'sg-event-dup',
            providerMessageId: 'sg-message-dup',
          ),
        );

        expect(result, isA<EmailEventInsertDuplicate>());
        final tx = pool.transactions.single;
        // Duplicate replays MUST skip both the SELECT and the UPDATE
        // on email_outbox (the first delivery already performed the
        // flip — running it again risks flapping).
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('public.email_outbox'),
          ),
          isEmpty,
          reason:
              'duplicate event must skip the email_outbox SELECT + UPDATE',
        );
        expect(tx.commitCount, 1);
      },
    );

    // ── 5. Already-terminal `email_outbox.status` ('failed' from
    // dispatcher) is NOT overwritten. ───────────────────────────────
    test(
      'already-`failed` outbox status survives a later `bounce` event',
      () async {
        final pool = _Pool(
          insertRows: <PostgresRow>[
            <String, Object?>{'event_id': 'event-f'},
          ],
          existingOutboxStatus: 'failed',
        );
        final repo = EmailEventRepository(TenantTransactionWrapper(pool));

        final result = await repo.insertProviderEvent(
          _event(
            eventKind: 'bounced',
            providerEventId: 'sg-event-f',
            providerMessageId: 'sg-message-f',
          ),
        );

        expect(result, isA<EmailEventInsertInserted>());
        final inserted = result as EmailEventInsertInserted;
        expect(
          inserted.flipOutcome,
          EmailOutboxTerminalFlipResult.alreadyTerminal,
        );

        final tx = pool.transactions.single;
        // The helper read the row to disambiguate already-terminal vs
        // outbox-not-found, but MUST NOT issue an UPDATE.
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('update public.email_outbox'),
          ),
          isEmpty,
          reason: '`failed` rows must not be overwritten with `bounced`',
        );
      },
    );

    // ── 6. Already-`bounced` row is NOT overwritten with 'complaint'
    // (first terminal wins). ────────────────────────────────────────
    test(
      'already-`bounced` outbox status survives a later `complaint` event',
      () async {
        final pool = _Pool(
          insertRows: <PostgresRow>[
            <String, Object?>{'event_id': 'event-bc'},
          ],
          existingOutboxStatus: 'bounced',
        );
        final repo = EmailEventRepository(TenantTransactionWrapper(pool));

        final result = await repo.insertProviderEvent(
          _event(
            eventKind: 'complaint',
            providerEventId: 'sg-event-bc',
            providerMessageId: 'sg-message-bc',
          ),
        );

        expect(result, isA<EmailEventInsertInserted>());
        final inserted = result as EmailEventInsertInserted;
        expect(
          inserted.flipOutcome,
          EmailOutboxTerminalFlipResult.alreadyTerminal,
          reason: 'first terminal wins; the second terminal must no-op',
        );

        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('update public.email_outbox'),
          ),
          isEmpty,
          reason: 'already-`bounced` row must not be flipped to `complaint`',
        );
      },
    );

    // ── 7. Null `provider_message_id` (unsolicited event) does NOT
    // attempt a flip. ───────────────────────────────────────────────
    test(
      'event with null provider_message_id does NOT attempt a flip',
      () async {
        final pool = _Pool(
          insertRows: <PostgresRow>[
            <String, Object?>{'event_id': 'event-null'},
          ],
          existingOutboxStatus: 'sent',
        );
        final repo = EmailEventRepository(TenantTransactionWrapper(pool));

        final result = await repo.insertProviderEvent(
          _eventWithoutMessageId(
            eventKind: 'bounced',
            providerEventId: 'sg-event-null',
          ),
        );

        expect(result, isA<EmailEventInsertInserted>());
        final inserted = result as EmailEventInsertInserted;
        expect(
          inserted.flipOutcome,
          isNull,
          reason:
              'null provider_message_id must produce a null flipOutcome — no FK to resolve',
        );

        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('public.email_outbox'),
          ),
          isEmpty,
          reason:
              'helper must not touch email_outbox when provider_message_id is null',
        );
      },
    );

    // ── 8. Idempotent on replay: re-inserting same SendGrid event ID
    // doesn't double-flip. ──────────────────────────────────────────
    test(
      'replayed SendGrid event ID is idempotent — second call does not double-flip',
      () async {
        // First call: fresh insert + flip.
        final freshPool = _Pool(
          insertRows: <PostgresRow>[
            <String, Object?>{'event_id': 'event-replay-1'},
          ],
          existingOutboxStatus: 'sent',
        );
        final freshRepo = EmailEventRepository(
          TenantTransactionWrapper(freshPool),
        );
        final firstResult = await freshRepo.insertProviderEvent(
          _event(
            eventKind: 'bounced',
            providerEventId: 'sg-event-replay',
            providerMessageId: 'sg-message-replay',
          ),
        );
        expect(firstResult, isA<EmailEventInsertInserted>());
        expect(
          (firstResult as EmailEventInsertInserted).flipOutcome,
          EmailOutboxTerminalFlipResult.flipped,
        );

        // Second call (replay): ON CONFLICT DO NOTHING returns no rows;
        // the helper MUST return duplicate AND skip the flip.
        final replayPool = _Pool(
          insertRows: const <PostgresRow>[],
          // Outbox is already terminal from the first call; even if
          // the duplicate path mistakenly attempted a flip, the guard
          // would block it — but the contract is to skip the flip
          // entirely.
          existingOutboxStatus: 'bounced',
        );
        final replayRepo = EmailEventRepository(
          TenantTransactionWrapper(replayPool),
        );
        final secondResult = await replayRepo.insertProviderEvent(
          _event(
            eventKind: 'bounced',
            providerEventId: 'sg-event-replay',
            providerMessageId: 'sg-message-replay',
          ),
        );

        expect(secondResult, isA<EmailEventInsertDuplicate>());
        final replayTx = replayPool.transactions.single;
        expect(
          replayTx.executedSql.where(
            (sql) => sql.contains('public.email_outbox'),
          ),
          isEmpty,
          reason:
              'replay must NOT issue any email_outbox SELECT or UPDATE',
        );
      },
    );

    // ── 9. Terminal event with no matching outbox row records
    // `outboxNotFound` outcome and issues no UPDATE. ────────────────
    test(
      'terminal event with no matching outbox row records outboxNotFound',
      () async {
        final pool = _Pool(
          insertRows: <PostgresRow>[
            <String, Object?>{'event_id': 'event-orphan'},
          ],
          // Null means: no row exists in email_outbox for this
          // provider_message_id (the lookup SELECT returns empty).
          existingOutboxStatus: null,
        );
        final repo = EmailEventRepository(TenantTransactionWrapper(pool));

        final result = await repo.insertProviderEvent(
          _event(
            eventKind: 'bounced',
            providerEventId: 'sg-event-orphan',
            providerMessageId: 'sg-message-orphan',
          ),
        );

        expect(result, isA<EmailEventInsertInserted>());
        final inserted = result as EmailEventInsertInserted;
        expect(
          inserted.flipOutcome,
          EmailOutboxTerminalFlipResult.outboxNotFound,
        );

        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('update public.email_outbox'),
          ),
          isEmpty,
          reason:
              'orphan event (no matching outbox row) must not issue an UPDATE',
        );
      },
    );
  });

  group(
    'EmailEventRepository.flipOutboxStatusForTerminalEvent — standalone',
    () {
      test('standalone flip surfaces `flipped` outcome', () async {
        final pool = _Pool(
          insertRows: const <PostgresRow>[],
          existingOutboxStatus: 'sent',
        );
        final repo = EmailEventRepository(TenantTransactionWrapper(pool));

        final outcome = await repo.flipOutboxStatusForTerminalEvent(
          _event(
            eventKind: 'bounced',
            providerEventId: 'sg-event-standalone',
            providerMessageId: 'sg-message-standalone',
          ),
        );

        expect(outcome, EmailOutboxTerminalFlipResult.flipped);
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('update public.email_outbox'),
          ),
          isNotEmpty,
        );
      });

      test('standalone flip returns null for non-terminal kinds', () async {
        final pool = _Pool(
          insertRows: const <PostgresRow>[],
          existingOutboxStatus: 'sent',
        );
        final repo = EmailEventRepository(TenantTransactionWrapper(pool));

        final outcome = await repo.flipOutboxStatusForTerminalEvent(
          _event(
            eventKind: 'delivered',
            providerEventId: 'sg-event-standalone-d',
            providerMessageId: 'sg-message-standalone-d',
          ),
        );

        expect(outcome, isNull);
      });
    },
  );
}

SendGridEvent _event({
  required String eventKind,
  required String providerEventId,
  required String providerMessageId,
}) {
  return SendGridEvent.fromJson(<String, Object?>{
    'email': 'ops@example.com',
    'timestamp': 1718000000,
    'event': eventKind,
    'sg_event_id': providerEventId,
    'sg_message_id': providerMessageId,
  });
}

SendGridEvent _eventWithoutMessageId({
  required String eventKind,
  required String providerEventId,
}) {
  return SendGridEvent.fromJson(<String, Object?>{
    'email': 'ops@example.com',
    'timestamp': 1718000000,
    'event': eventKind,
    'sg_event_id': providerEventId,
    // sg_message_id intentionally omitted (the parser allows null).
  });
}

/// In-memory `PostgresPool` that records every executed SQL statement
/// + parameters per transaction, and answers queries based on the
/// values seeded in the constructor.
///
/// The fake disambiguates statements by substring match (the
/// repository's queries are written as single-line strings with
/// stable substrings: `insert into public.email_event`,
/// `from public.email_outbox`, `update public.email_outbox`).
class _Pool implements PostgresPool {
  _Pool({
    required this.insertRows,
    this.existingOutboxStatus,
  });

  /// Rows the INSERT into `email_event` returns (empty = duplicate;
  /// one row = fresh insert).
  final List<PostgresRow> insertRows;

  /// Current `email_outbox.status` for the row the flip helper looks
  /// up. `null` means no row exists in `email_outbox` for the given
  /// `provider_message_id` (the SELECT returns empty).
  final String? existingOutboxStatus;

  final List<_Tx> transactions = <_Tx>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _Tx(
      insertRows: insertRows,
      existingOutboxStatus: existingOutboxStatus,
    );
    transactions.add(tx);
    return tx;
  }
}

class _Tx extends PostgresTransaction {
  _Tx({
    required this.insertRows,
    required this.existingOutboxStatus,
  });

  final List<PostgresRow> insertRows;
  final String? existingOutboxStatus;

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
    if (sql.contains('insert into public.email_event')) {
      return insertRows;
    }
    if (sql.contains('from public.email_outbox')) {
      // SELECT lookup — answer with the configured existing status
      // (or empty when null, meaning "no row exists").
      if (existingOutboxStatus == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'status': existingOutboxStatus},
      ];
    }
    if (sql.contains('update public.email_outbox')) {
      // UPDATE … RETURNING. For test purposes the returned row count
      // does not change behaviour (the helper has already decided the
      // outcome via the prior SELECT); return empty to keep the fake
      // minimal.
      return const <PostgresRow>[];
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
