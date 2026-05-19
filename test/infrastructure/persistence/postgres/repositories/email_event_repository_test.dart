import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/email_event_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/email/sendgrid_event_payload.dart';

void main() {
  group('EmailEventRepository.insertProviderEvent terminal outbox repair', () {
    test('bounced event flips matching sent outbox row to bounced', () async {
      final pool = _Pool(
        insertRows: <PostgresRow>[
          <String, Object?>{'event_id': 'event-1'},
        ],
        terminalUpdateRows: <PostgresRow>[
          <String, Object?>{'email_id': 'email-1'},
        ],
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
      final tx = pool.transactions.single;
      final updateIndex = tx.executedSql.indexWhere(
        (sql) => sql.contains('update public.email_outbox'),
      );
      expect(updateIndex, isNonNegative);
      expect(tx.executedSql[updateIndex], contains("status = 'sent'"));
      expect(tx.parameters[updateIndex]['status'], 'bounced');
      expect(tx.parameters[updateIndex]['provider_message_id'], 'sg-message-1');
      expect(tx.commitCount, 1);
      expect(tx.rollbackCount, 0);
    });

    test('duplicate complaint event still attempts outbox repair', () async {
      final pool = _Pool(insertRows: const <PostgresRow>[]);
      final repo = EmailEventRepository(TenantTransactionWrapper(pool));

      final result = await repo.insertProviderEvent(
        _event(
          eventKind: 'complaint',
          providerEventId: 'sg-event-2',
          providerMessageId: 'sg-message-2',
        ),
      );

      expect(result, isA<EmailEventInsertDuplicate>());
      final tx = pool.transactions.single;
      final updateIndex = tx.executedSql.indexWhere(
        (sql) => sql.contains('update public.email_outbox'),
      );
      expect(updateIndex, isNonNegative);
      expect(tx.parameters[updateIndex]['status'], 'complaint');
      expect(tx.parameters[updateIndex]['provider_message_id'], 'sg-message-2');
    });

    test('non-terminal event only records email_event row', () async {
      final pool = _Pool(
        insertRows: <PostgresRow>[
          <String, Object?>{'event_id': 'event-3'},
        ],
      );
      final repo = EmailEventRepository(TenantTransactionWrapper(pool));

      await repo.insertProviderEvent(
        _event(
          eventKind: 'delivered',
          providerEventId: 'sg-event-3',
          providerMessageId: 'sg-message-3',
        ),
      );

      final tx = pool.transactions.single;
      expect(
        tx.executedSql.where(
          (sql) => sql.contains('update public.email_outbox'),
        ),
        isEmpty,
      );
    });
  });
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

class _Pool implements PostgresPool {
  _Pool({
    required this.insertRows,
    this.terminalUpdateRows = const <PostgresRow>[],
  });

  final List<PostgresRow> insertRows;
  final List<PostgresRow> terminalUpdateRows;
  final List<_Tx> transactions = <_Tx>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _Tx(
      insertRows: insertRows,
      terminalUpdateRows: terminalUpdateRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _Tx extends PostgresTransaction {
  _Tx({required this.insertRows, required this.terminalUpdateRows});

  final List<PostgresRow> insertRows;
  final List<PostgresRow> terminalUpdateRows;
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
    if (sql.contains('update public.email_outbox')) {
      return terminalUpdateRows;
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
