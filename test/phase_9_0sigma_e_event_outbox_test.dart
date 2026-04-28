// Phase 9.0Σ.e — event_outbox foundation tests.
//
// Local framework slice (no live database). Three groups:
//
//   1. Migration shape
//      ─ table + tenant-leading claim index + RLS through 9.0Σ.b
//        wrappers + pg_notify trigger + grants. Asserts the schema
//        contract Phase 10a will wire its bridge worker against.
//
//   2. RLS lint posture
//      ─ runs the policy-aware lint (`tool/rls_policy_lint.dart`)
//        against the new migration only and proves it passes — i.e.
//        the new policy bodies use `public.app_current_operator()`
//        through a wrapper, not bare `current_setting('app.…')`.
//        Required by item 4 of the 4-27 scalability decisions.
//
//   3. Repository SQL contract
//      ─ `EventOutboxRepository.enqueue` + `claimBatch` against a
//        recording fake `PostgresPool`, proving:
//          * SET LOCAL app.operator_id is in place when the
//            INSERT/SELECT runs (verified at the wrapper layer);
//          * INSERT carries the operator + topic + payload binds and
//            returns the assigned id;
//          * the claim query uses `FOR UPDATE SKIP LOCKED`, orders
//            by `id`, and stamps `picked_up_at = now()` in the same
//            statement (so a worker restart cannot lose claims);
//          * the projected `EventOutboxClaimedRow` parses both
//            jsonb-as-Map and jsonb-as-String payloads.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../tool/rls_policy_lint.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';
const String _otherOpId = '44444444-4444-4444-4444-444444444444';

void main() {
  final migrationSql = _readSqlNormalized(
    'db/migrations/'
    '202604280003_phase_9_0sigma_e_event_outbox.sql',
  );

  group('Phase 9.0Σ.e migration shape', () {
    test('declares event_outbox with bigserial PK + locked column shape',
        () {
      expect(
        migrationSql,
        contains('create table if not exists public.event_outbox'),
      );
      expect(migrationSql, contains('id bigserial primary key'));
      expect(
        migrationSql,
        contains('operator_id uuid not null references public.operators'),
      );
      expect(migrationSql, contains('topic text not null'));
      expect(migrationSql, contains("payload jsonb not null default '{}'::jsonb"));
      expect(migrationSql, contains('created_at timestamptz not null default now()'));
      expect(migrationSql, contains('picked_up_at timestamptz null'));
      // Phase 10a fills these; declared now so the bridge worker
      // does not need a follow-up migration.
      expect(migrationSql, contains('delivered_at timestamptz null'));
      expect(migrationSql, contains('attempt_count integer not null default 0'));
      expect(migrationSql, contains('last_error_at timestamptz null'));
      expect(migrationSql, contains('last_error text null'));
    });

    test('payload CHECK enforces both size cap and JSON-object shape '
        '(P2 fix: jsonb_typeof guard so direct service_role / forge_admin '
        'inserts cannot store array/string/number/null bodies the '
        'claim decoder would reject)', () {
      expect(
        migrationSql,
        contains('check (octet_length(payload::text) <= 262144)'),
      );
      expect(
        migrationSql,
        contains("check (jsonb_typeof(payload) = 'object')"),
      );
    });

    test('claim index is tenant-leading per CLAUDE.md RLS performance '
        'discipline', () {
      // The exact column order matters — operator_id LEADS so the
      // per-tenant RLS policy folds into the index probe. Anything
      // else (e.g. `(picked_up_at, operator_id, id)`) collapses
      // claim throughput on multi-operator deployments.
      expect(
        migrationSql,
        contains(
          'create index if not exists event_outbox_claim_idx\n'
          '  on public.event_outbox '
          '(operator_id, picked_up_at nulls first, id);',
        ),
      );
    });

    test('NOTIFY trigger fires on INSERT with a small JSON envelope', () {
      expect(
        migrationSql,
        contains('create or replace function public.event_outbox_notify()'),
      );
      // Channel literal must match what Phase 10a's bridge LISTENs
      // on. Renaming this is a breaking-contract change.
      expect(migrationSql, contains("pg_notify(\n    'event_outbox',"));
      // Envelope keys are operator_id + topic + id only (Phase 10a
      // reads the full row from the table on claim).
      expect(migrationSql, contains("'operator_id', new.operator_id"));
      expect(migrationSql, contains("'topic', new.topic"));
      expect(migrationSql, contains("'id', new.id"));
      expect(
        migrationSql,
        contains('after insert on public.event_outbox'),
      );
      expect(
        migrationSql,
        contains('execute function public.event_outbox_notify()'),
      );
    });

    test('RLS policies use the 9.0Σ.b wrapper, not bare current_setting',
        () {
      expect(migrationSql, contains('alter table public.event_outbox enable row level security'));
      expect(
        migrationSql,
        contains('create policy "event_outbox_per_tenant_select"'),
      );
      expect(
        migrationSql,
        contains('create policy "event_outbox_per_tenant_modify"'),
      );
      // Both policies pull tenant context through the wrapper (item
      // 4 of the 4-27 lock).
      expect(
        migrationSql,
        contains('operator_id = public.app_current_operator()'),
      );
      // And the rewriter's bare-GUC reads must be absent — the lint
      // group below also asserts this against the policy-aware
      // scanner, but a literal guard here surfaces a regression
      // before the lint runs.
      expect(
        migrationSql,
        isNot(contains("current_setting('app.operator_id'")),
      );
    });

    test('grants the runtime + admin roles SELECT/INSERT/UPDATE/DELETE '
        'on the table AND USAGE on the sequence', () {
      // service_role is the proxy's runtime connection; forge_admin
      // is the BYPASSRLS escape hatch via runAsSystem.
      for (final role in <String>['service_role', 'forge_admin']) {
        expect(
          migrationSql,
          contains(
            'grant select, insert, update, delete on public.event_outbox '
            'to $role',
          ),
          reason: '$role needs DML so producers + the bridge worker + '
              'the retention sweep can all do their work',
        );
        // bigserial requires sequence USAGE for nextval(); without
        // this the INSERT errors before RLS even evaluates.
        expect(
          migrationSql,
          contains(
            'grant usage, select on sequence public.event_outbox_id_seq '
            'to $role',
          ),
          reason: '$role needs sequence USAGE to allocate the bigserial id',
        );
      }
    });
  });

  group('Phase 9.0Σ.e RLS lint', () {
    test('migration passes the policy-aware lint', () {
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280003_phase_9_0sigma_e_event_outbox.sql': migrationSql,
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason: 'event_outbox policies must read GUCs through the '
            '9.0Σ.b wrappers; violations: ${result.violations}',
      );
    });
  });

  group('EventOutboxRepository (B26 — fake Postgres)', () {
    test('enqueue runs SET LOCAL + INSERT and returns the assigned id',
        () async {
      final pool = _EventOutboxPool(returningId: '42');
      final repo = EventOutboxRepository(TenantTransactionWrapper(pool));

      final id = await repo.enqueue(
        operatorId: _validOpId,
        locationId: _validLocId,
        topic: 'auth.session.login',
        payload: const <String, Object?>{
          'user_id': _validUserId,
          'event_id': 'evt-1',
        },
      );

      expect(id, equals('42'));
      final tx = pool.transactions.single;
      // SET LOCAL block ran first; the wrapper test in
      // operator_scoped_repository_test asserts the exact shape, here
      // we just confirm the operator GUC was injected before the
      // INSERT so RLS would admit the row.
      expect(tx.executedSql.first, contains("set_config('app.operator_id'"));
      expect(tx.parameters.first['value'], equals(_validOpId));
      // INSERT shape.
      final insertSql = tx.executedSql.last;
      expect(insertSql, contains('insert into event_outbox'));
      expect(insertSql, contains('returning id::text as id'));
      final params = tx.parameters.last;
      expect(params['operator_id'], equals(_validOpId));
      expect(params['topic'], equals('auth.session.login'));
      // Payload is bound as serialized JSON; the contract forbids
      // string concatenation.
      final decoded = jsonDecode(params['payload'] as String)
          as Map<String, Object?>;
      expect(decoded['user_id'], equals(_validUserId));
      expect(decoded['event_id'], equals('evt-1'));
      expect(tx.commitCount, equals(1));
    });

    test('enqueue throws when RETURNING produces no rows '
        '(RLS denial scenario)', () async {
      final pool = _EventOutboxPool(returningId: null);
      final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.enqueue(
          operatorId: _validOpId,
          locationId: _validLocId,
          topic: 'auth.session.login',
          payload: const <String, Object?>{},
        ),
        throwsStateError,
      );
    });

    test('enqueue rejects an invalid operator UUID before opening a '
        'transaction', () async {
      final pool = _EventOutboxPool(returningId: '1');
      final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
      Object? thrown;
      try {
        await repo.enqueue(
          operatorId: 'not-a-uuid',
          locationId: _validLocId,
          topic: 'x',
          payload: const <String, Object?>{},
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      // Acceptance: the wrapper never opened a transaction because
      // TenantContext rejected the bad UUID first.
      expect(pool.transactions, isEmpty);
    });

    test('claimBatch issues FOR UPDATE SKIP LOCKED + lease-reclaim '
        'predicate + outer ORDER BY for stable returned-row order', () async {
      final claimedAt = DateTime.utc(2026, 4, 28, 12);
      final pool = _EventOutboxPool(
        returningId: '1',
        claimedRows: <PostgresRow>[
          <String, Object?>{
            'id': '101',
            'operator_id': _validOpId,
            'topic': 'auth.session.login',
            'payload': <String, Object?>{'user_id': _validUserId},
            'created_at': claimedAt.subtract(const Duration(seconds: 10)),
            'picked_up_at': claimedAt,
            'attempt_count': 0,
          },
          <String, Object?>{
            'id': '102',
            'operator_id': _validOpId,
            'topic': 'rollup.invalidate.daypart',
            // Driver may hand back the payload as a JSON string
            // when jsonb decoding is disabled — the repository
            // normalizes both shapes.
            'payload': jsonEncode(<String, Object?>{
              'rollup_table': 'daypart_summary',
              'business_date': '2026-04-28',
            }),
            'created_at': claimedAt.subtract(const Duration(seconds: 5)),
            'picked_up_at': claimedAt,
            'attempt_count': 0,
          },
        ],
      );
      final repo = EventOutboxRepository(TenantTransactionWrapper(pool));

      final claimed = await repo.claimBatch(
        operatorId: _validOpId,
        locationId: _validLocId,
        batchSize: 5,
      );

      expect(claimed, hasLength(2));
      final tx = pool.transactions.single;
      final claimSql = tx.executedSql.last;
      expect(claimSql, contains('for update skip locked'));
      expect(claimSql, contains('limit @batch_size'));
      // CTE pattern: inner CTE locks rows under SKIP LOCKED, then
      // a second CTE stamps picked_up_at and RETURNINGs the row,
      // then the outer SELECT re-orders by `updated.id` so the
      // returned-row contract holds (UPDATE … RETURNING does not
      // preserve row order on its own).
      expect(claimSql, contains('with claimed as'));
      expect(claimSql, contains('updated as'));
      expect(claimSql, contains('update event_outbox e'));
      expect(claimSql, contains('set picked_up_at = now()'));
      expect(claimSql, contains('from updated'));
      // P2 fix: outer ORDER BY MUST qualify with the CTE name
      // (`updated.id`) — the SELECT list aliases `id::text AS id`,
      // so a bare `ORDER BY id` would resolve to the text alias and
      // lex-sort '10' before '2' once ids cross digit lengths.
      expect(claimSql, contains('order by updated.id'));
      // Sanity: the inner CTE still uses `order by id` (its row
      // source is `event_outbox` directly, no alias collision).
      // Inner uses `order by id`; outer uses `order by updated.id`.
      expect(
        RegExp(r'order by id\b').allMatches(claimSql).length,
        equals(1),
        reason: 'only the inner CTE should use bare `order by id`; '
            'the outer SELECT must use `order by updated.id` to '
            'avoid sorting the text alias',
      );
      expect(
        RegExp(r'order by updated\.id\b').allMatches(claimSql).length,
        equals(1),
        reason: 'outer SELECT must explicitly qualify the BIGINT id '
            'from the CTE',
      );
      // P1 fix (round 2): delivered_at IS NULL keeps already-
      // delivered rows out of the claim set. Without this, every
      // delivered row whose picked_up_at crosses the reclaim window
      // would re-publish — combined with Phase 10a's 7-day
      // delivered-row retention, every delivered row would re-fan-
      // out every <reclaim_window> for a week.
      expect(claimSql, contains('delivered_at is null'));
      // P1 fix (round 1): lease-reclaim predicate so a worker crash
      // between claim-commit and Pub/Sub-ack does not strand the
      // row.
      expect(claimSql, contains('picked_up_at is null'));
      expect(
        claimSql,
        contains(
          "or picked_up_at < now() - (@reclaim_seconds * interval '1 second')",
        ),
      );
      // Tenant predicate is bound via parameter; never concatenated.
      expect(claimSql, contains('operator_id = @operator_id::uuid'));
      expect(tx.parameters.last['operator_id'], equals(_validOpId));
      expect(tx.parameters.last['batch_size'], equals(5));
      // Default reclaim window is 5 minutes (300 s) — Q22 RED lag
      // threshold doubles as the safe lease default.
      expect(tx.parameters.last['reclaim_seconds'], equals(300));

      // Both rows project cleanly (Map and String payload shapes).
      expect(claimed[0].id, equals('101'));
      expect(claimed[0].topic, equals('auth.session.login'));
      expect(claimed[0].payload['user_id'], equals(_validUserId));
      expect(claimed[1].id, equals('102'));
      expect(claimed[1].topic, equals('rollup.invalidate.daypart'));
      expect(claimed[1].payload['rollup_table'], equals('daypart_summary'));
      expect(claimed[1].payload['business_date'], equals('2026-04-28'));
    });

    test('claimBatch returns an empty list when no rows are available',
        () async {
      final pool = _EventOutboxPool(
        returningId: '1',
        claimedRows: const <PostgresRow>[],
      );
      final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
      final claimed = await repo.claimBatch(
        operatorId: _validOpId,
        locationId: _validLocId,
        batchSize: 10,
      );
      expect(claimed, isEmpty);
      expect(pool.transactions.single.commitCount, equals(1));
    });

    test('claimBatch rejects a non-positive batchSize before opening a '
        'transaction', () async {
      final pool = _EventOutboxPool(returningId: '1');
      final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
      Object? thrown;
      try {
        await repo.claimBatch(
          operatorId: _validOpId,
          locationId: _validLocId,
          batchSize: 0,
        );
      } on ArgumentError catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ArgumentError>());
      expect(pool.transactions, isEmpty);
    });

    test('claimBatch rejects a non-positive claimReclaimAfter before '
        'opening a transaction (a zero/negative lease would re-claim '
        'every row on every poll)', () async {
      final pool = _EventOutboxPool(returningId: '1');
      final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
      Object? thrown;
      try {
        await repo.claimBatch(
          operatorId: _validOpId,
          locationId: _validLocId,
          batchSize: 5,
          claimReclaimAfter: Duration.zero,
        );
      } on ArgumentError catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ArgumentError>());
      expect(pool.transactions, isEmpty);
    });

    test('claimBatch passes a custom claimReclaimAfter through to the '
        'reclaim_seconds bind so Phase 10a can tune the lease for its '
        'observed publish latency', () async {
      final pool = _EventOutboxPool(
        returningId: '1',
        claimedRows: const <PostgresRow>[],
      );
      final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
      await repo.claimBatch(
        operatorId: _validOpId,
        locationId: _validLocId,
        batchSize: 5,
        claimReclaimAfter: const Duration(seconds: 90),
      );
      expect(
        pool.transactions.single.parameters.last['reclaim_seconds'],
        equals(90),
      );
    });

    test('two consecutive enqueues bind their own operator_id — pooled '
        'connection reuse cannot leak tenant context', () async {
      final pool = _EventOutboxPool(returningId: '1');
      final repo = EventOutboxRepository(TenantTransactionWrapper(pool));

      await repo.enqueue(
        operatorId: _validOpId,
        locationId: _validLocId,
        topic: 'auth.session.login',
        payload: const <String, Object?>{},
      );
      await repo.enqueue(
        operatorId: _otherOpId,
        locationId: _validLocId,
        topic: 'auth.session.login',
        payload: const <String, Object?>{},
      );

      expect(pool.transactions, hasLength(2));
      expect(
        pool.transactions[0].parameters.first['value'],
        equals(_validOpId),
      );
      expect(
        pool.transactions[1].parameters.first['value'],
        equals(_otherOpId),
      );
    });
  });

  group('event_outbox contract doc', () {
    final contract = File('docs/contracts/event_outbox_contract.md');

    setUpAll(() {
      expect(
        contract.existsSync(),
        isTrue,
        reason: 'contract doc must accompany the migration + repository',
      );
    });

    test('names the Phase 10a bridge worker boundary explicitly', () {
      final body = contract.readAsStringSync();
      expect(body, contains('Phase 10a'));
      expect(body, contains('Pub/Sub'));
      expect(body, contains('wake-up signal'));
      expect(body, contains('FOR UPDATE SKIP LOCKED'));
    });

    test('locks the topic namespaces this slice ships', () {
      final body = contract.readAsStringSync();
      // Topic shape contract — producers MUST stay inside these
      // namespaces or coordinate with this doc + the bridge routing
      // table before merging.
      const lockedNamespaces = <String>[
        'auth.session.*',
        'auth.user.*',
        'usage.cap.*',
        'rollup.invalidate.*',
        'advisor.candidate.*',
        'workflow.event.*',
        'internal.health.*',
      ];
      for (final ns in lockedNamespaces) {
        expect(
          body,
          contains(ns),
          reason: 'contract must list locked topic namespace $ns',
        );
      }
    });

    test('locked schema block lists both payload CHECKs (P3 fix — '
        'block is the quick schema authority and must be self-'
        'consistent with the migration)', () {
      final body = contract.readAsStringSync();
      // The "Schema (locked here)" block is what implementers read
      // when they need a one-glance answer for the table shape.
      // Both CHECKs (size + jsonb_typeof) MUST appear there or the
      // contract drifts from the migration.
      expect(
        body,
        contains('check (octet_length(payload::text) <= 262144)'),
      );
      expect(
        body,
        contains("check (jsonb_typeof(payload) = 'object')"),
      );
    });

    test('claim-predicate snippet documents the delivered_at + lease '
        'filters (P1 fix round 2 + round 1 reflected in the consumer '
        'contract)', () {
      final body = contract.readAsStringSync();
      // The consumer-contract snippet MUST list all three filters
      // the repository applies, so a Phase 10a implementer reading
      // the contract gets the same predicate the SQL enforces.
      expect(body, contains('delivered_at IS NULL'));
      expect(body, contains('picked_up_at IS NULL'));
      expect(
        body,
        contains('picked_up_at < now() - <claimReclaimAfter>'),
      );
    });
  });

  group('Phase 10a plan alignment with event_outbox contract', () {
    final plan = File(
      'docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md',
    );

    setUpAll(() {
      expect(
        plan.existsSync(),
        isTrue,
        reason: 'Phase 10a plan doc must exist for the cross-doc '
            'alignment check',
      );
    });

    test('Phase 10a bridge spec points at event_outbox + treats NOTIFY '
        'as wake-up signal only (P2 fix — old plan described a direct '
        'NOTIFY → Pub/Sub bridge that bypassed the outbox)', () {
      final body = plan.readAsStringSync();
      expect(
        body,
        contains('event_outbox'),
        reason: 'plan must reference the durable outbox table',
      );
      expect(
        body,
        contains('event_outbox_contract.md'),
        reason: 'plan must defer to the contract doc for table shape, '
            'topic namespaces, payload rules, and lease semantics',
      );
      expect(
        body,
        contains('EventOutboxRepository.claimBatch'),
        reason: 'plan must direct the bridge worker through the '
            'repository claim path, not a raw NOTIFY consumer',
      );
      expect(
        body,
        contains('NOTIFY is a wake-up signal'),
        reason: 'plan must explicitly state NOTIFY is not the source '
            'of truth so the next implementer does not bypass the '
            'outbox',
      );
    });

    test('Phase 10a plan no longer instructs a direct shared_state '
        'NOTIFY bridge anywhere (round-3 fix — the locked-decision, '
        'runtime-contract, and dependencies sections all previously '
        'repeated the old direct flow even after the main bridge '
        'section was rewritten)', () {
      final body = plan.readAsStringSync();
      // Each pattern below is a phrase that USED to direct a Phase 10a
      // implementer to bypass event_outbox by routing fan-out
      // straight off Postgres LISTEN/NOTIFY against shared-state
      // tables. They MUST stay out of the plan or a careful reader
      // could still pick the wrong design.
      final forbidden = <RegExp>{
        // Old per-table channel naming.
        RegExp(r'shared_state\.\{operator_id\}\.\{table\}',
            caseSensitive: false),
        RegExp(r'NOTIFY\s+shared_state[:\s]', caseSensitive: false),
        // Old "thin LISTEN/NOTIFY → WebSocket bridge" claim that the
        // bridge is a direct fan-out, not an outbox consumer.
        RegExp(r'LISTEN/NOTIFY\s*(?:→|->|to)\s*WebSocket',
            caseSensitive: false),
        RegExp(r'thin\s+LISTEN/NOTIFY', caseSensitive: false),
        // Old per-table-mutation NOTIFY trigger description.
        RegExp(r'triggered on every shared.state.*mutation',
            caseSensitive: false),
        // Old subscribe-path description that registered LISTEN
        // handlers per-channel rather than reading event_outbox.
        RegExp(r'LISTEN\s+on\s+relevant\s+Postgres\s+channels',
            caseSensitive: false),
        // Old dependency line that named LISTEN/NOTIFY channels on
        // shared-state tables as the trigger surface.
        RegExp(r'LISTEN/NOTIFY\s+channels\s+defined\s+on\s+shared.state',
            caseSensitive: false),
      };
      for (final pattern in forbidden) {
        expect(
          pattern.hasMatch(body),
          isFalse,
          reason: 'Phase 10a plan still contains direct-NOTIFY '
              'language matching: ${pattern.pattern}',
        );
      }
    });
  });
}

/// Reads [path] and collapses CRLF → LF so multi-line `contains(...)`
/// assertions work on Windows checkouts (default `core.autocrlf=true`)
/// as well as on Linux/macOS CI runners. Throws (synchronously) if the
/// migration file is missing — the `flutter test` harness surfaces
/// that as a load failure, which is exactly the signal we want when a
/// run is launched from outside the repo root.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}

class _EventOutboxPool implements PostgresPool {
  _EventOutboxPool({
    required this.returningId,
    this.claimedRows = const <PostgresRow>[],
  });

  final String? returningId;
  final List<PostgresRow> claimedRows;

  final List<_EventOutboxTransaction> transactions =
      <_EventOutboxTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _EventOutboxTransaction(
      returningId: returningId,
      claimedRows: claimedRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _EventOutboxTransaction extends PostgresTransaction {
  _EventOutboxTransaction({
    required this.returningId,
    required this.claimedRows,
  });

  final String? returningId;
  final List<PostgresRow> claimedRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;
  int commitCount = 0;
  int rollbackCount = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into event_outbox') &&
        sql.contains('returning id')) {
      final id = returningId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'id': id},
      ];
    }
    if (sql.contains('update event_outbox e') &&
        sql.contains('returning')) {
      return claimedRows;
    }
    return <PostgresRow>[];
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
    if (_finalized) return;
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    rollbackCount += 1;
  }
}
