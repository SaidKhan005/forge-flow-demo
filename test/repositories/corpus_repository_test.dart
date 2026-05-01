// Phase 11A.3a — CorpusRepository tests.
//
// Drives `CorpusRepository` against a fake `PostgresPool` so the
// SQL shape + transactional commit semantics are pinned without a
// live database. Coverage:
//
//   * `listVersions` issues a single statement that joins
//     `corpus_versions` to a `count(*)` over `corpus_version_chunks`,
//     and orders current-first (`superseded_at IS NULL DESC`).
//   * `commitVersion` runs five SQL stages inside one withSystem
//     block: supersede prior version, insert new version, mark prior
//     active chunks superseded, upsert each new chunk row WITHOUT
//     overwriting `version_id` (the join table is the membership
//     authority), insert membership rows in `corpus_version_chunks`.
//   * `rollbackToVersion` resolves the target's membership rows first
//     (via `corpus_version_chunks`), supersedes the prior current
//     state, inserts the new ledger row whose `rollback_of`
//     references the target, duplicates the membership rows under
//     the new version, and un-supersedes those chunks.
//   * `rollbackToVersion` honours `idempotencyKey`: a replay with the
//     same key reads the cached `proxy_requests` response instead of
//     writing a second ledger entry.
//   * Every withSystem call elevates to `forge_admin` and stamps
//     `app.bypass_rls_audit = 'system:<reason>'`.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/corpus_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

void main() {
  group('CorpusRepository.listVersions', () {
    test(
        'issues a single SELECT joining corpus_version_chunks for chunk_count + current-first order',
        () async {
      final pool = _CorpusPool(rows: <PostgresRow>[
        <String, Object?>{
          'version_id': 'v-current',
          'created_by': 'actor',
          'created_at': DateTime.utc(2026, 5, 1),
          'summary': 'current',
          'rollback_of': null,
          'superseded_at': null,
          'chunk_count': 4,
        },
        <String, Object?>{
          'version_id': 'v-prior',
          'created_by': 'actor',
          'created_at': DateTime.utc(2026, 4, 1),
          'summary': 'prior',
          'rollback_of': null,
          'superseded_at': DateTime.utc(2026, 5, 1),
          'chunk_count': 3,
        },
      ]);
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      final versions =
          await repo.listVersions(adminReason: 'admin.test.list');
      expect(versions, hasLength(2));
      expect(versions.first.versionId, equals('v-current'));
      expect(versions.first.chunkCount, equals(4));
      expect(versions.last.versionId, equals('v-prior'));
      // The transaction recorded the audit marker + role elevation
      // before the SELECT.
      final tx = pool.transactions.single;
      expect(tx.executed.first.sql, contains('app.bypass_rls_audit'));
      expect(tx.executed[1].sql, contains('set local role forge_admin'));
      expect(tx.executed[2].sql, contains('from corpus_versions'));
      // chunk_count must come from the membership join, not from
      // overwriting `advisor_source_chunks.version_id`.
      expect(tx.executed[2].sql, contains('from corpus_version_chunks'));
      expect(tx.executed[2].sql, contains('chunk_count'));
      expect(tx.executed[2].sql, contains('superseded_at is null desc'));
    });
  });

  group('CorpusRepository.commitVersion', () {
    test(
        'supersedes prior, inserts version, supersedes chunks, upserts new chunks WITHOUT version_id rewrite, records membership',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        'insert into corpus_versions': <PostgresRow>[
          <String, Object?>{
            'version_id': 'new-version',
            'created_by': 'actor',
            'created_at': DateTime.utc(2026, 5, 1),
            'summary': 'new',
            'rollback_of': null,
            'superseded_at': null,
          },
        ],
      });
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      final newVersion = await repo.commitVersion(
        summary: 'new',
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        chunks: <NewCorpusChunk>[
          const NewCorpusChunk(
            chunkId: 'doc.md#000',
            docId: 'doc.md',
            sourcePath: 'doc.md',
            scope: 'global_shared_methodology',
            chunkKind: 'paragraph',
            chunkProfile: 'default',
            headingPath: <String>['Doc'],
            startLine: 1,
            endLine: 5,
            estimatedTokens: 12,
            riskLevel: 'standard',
            contentSha256:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            text: 'Hello',
            provenanceJson: '{}',
          ),
        ],
        adminReason: 'admin.test.commit',
      );
      expect(newVersion.versionId, equals('new-version'));

      final stages = pool.transactions.single.executed
          .map((s) => s.sql)
          .where((s) =>
              !s.contains('app.bypass_rls_audit') &&
              !s.startsWith('set local role'))
          .toList();
      // 0: SELECT prior version_id (captured BEFORE step 1 supersede so
      //    cache_telemetry_v2 can record the bump's superseded_version_id)
      // 1: supersede prior corpus_versions
      // 2: insert new corpus_versions
      // 3: supersede prior chunks
      // 4: upsert chunk row
      // 5: insert membership row
      expect(stages, hasLength(6));
      expect(
        stages[0],
        contains('select version_id::text as version_id from corpus_versions'),
        reason:
            'commitVersion captures the prior version_id BEFORE the '
            'supersede UPDATE so cache_telemetry_v2 can populate '
            'corpus_invalidation_events.superseded_version_id',
      );
      expect(stages[0], contains('where superseded_at is null'));
      expect(
        stages[1],
        contains('update corpus_versions set superseded_at = now()'),
      );
      expect(stages[2], contains('insert into corpus_versions'));
      expect(stages[3], contains('update advisor_source_chunks'));
      expect(stages[3], contains('superseded_at = now()'));
      expect(stages[4], contains('insert into advisor_source_chunks'));
      // The on-conflict clause MUST NOT rewrite `version_id` — the
      // chunk's first-introduced pointer stays stable so historical
      // snapshot reads remain accurate. Membership in the new
      // version flows through the join table instead.
      expect(stages[4], contains('on conflict (chunk_id)'));
      expect(stages[4], isNot(contains('version_id = excluded.version_id')));
      expect(
        stages[5],
        contains('insert into corpus_version_chunks'),
        reason:
            'membership row links the new version to the chunk via '
            'the join table',
      );
    });
  });

  group('CorpusRepository.rollbackToVersion', () {
    test(
        'inserts a new ledger row whose rollback_of references the target and duplicates membership',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        'select chunk_id from corpus_version_chunks': <PostgresRow>[
          <String, Object?>{'chunk_id': 'doc.md#000'},
          <String, Object?>{'chunk_id': 'doc.md#001'},
        ],
        'insert into corpus_versions': <PostgresRow>[
          <String, Object?>{
            'version_id': 'rollback-version',
            'created_by': 'actor',
            'created_at': DateTime.utc(2026, 5, 1),
            'summary': 'rolled back',
            'rollback_of': 'v-target',
            'superseded_at': null,
          },
        ],
      });
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      final result = await repo.rollbackToVersion(
        targetVersionId: 'v-target',
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        summary: 'rolled back',
        adminReason: 'admin.test.rollback',
      );
      expect(result.version.versionId, equals('rollback-version'));
      expect(result.version.rollbackOf, equals('v-target'));
      expect(result.replayed, isFalse);

      final stages = pool.transactions.single.executed
          .map((s) => s.sql)
          .where((s) =>
              !s.contains('app.bypass_rls_audit') &&
              !s.startsWith('set local role'))
          .toList();
      // The rollback path SELECTs the target's membership rows
      // before any mutation so a partial failure cannot reassign a
      // chunk's `version_id` and orphan the snapshot.
      expect(
        stages.first,
        contains('select chunk_id from corpus_version_chunks'),
        reason:
            'rollback first reads the target membership set; mutating '
            '`advisor_source_chunks.version_id` would destroy the '
            'historical snapshot',
      );
      expect(
        stages.where((s) => s.contains('insert into corpus_versions')),
        hasLength(1),
      );
      // Two members → two membership inserts under the new version.
      expect(
        stages
            .where((s) => s.contains('insert into corpus_version_chunks'))
            .length,
        equals(2),
      );
      // Each member's `superseded_at` is cleared so the active-
      // snapshot read lights up the rolled-back chunk set.
      expect(
        stages.where((s) =>
            s.contains('update advisor_source_chunks') &&
            s.contains('superseded_at = null')),
        hasLength(2),
      );
    });

    test(
        'idempotencyKey replay returns the cached ledger row from admin_idempotency_cache',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        'from admin_idempotency_cache': <PostgresRow>[
          <String, Object?>{
            'response_payload': '{"version_id":"cached-version",'
                '"created_by":"actor",'
                '"created_at":"2026-05-01T00:00:00.000Z",'
                '"summary":"cached",'
                '"rollback_of":"v-target",'
                '"superseded_at":null,'
                '"is_current":true,'
                '"chunk_count":3}',
          },
        ],
      });
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      final replayed = await repo.rollbackToVersion(
        targetVersionId: 'v-target',
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        summary: 'rolled back',
        adminReason: 'admin.test.rollback.replay',
        idempotencyKey: 'rollback-key-1',
      );
      expect(replayed.version.versionId, equals('cached-version'));
      expect(replayed.replayed, isTrue,
          reason:
              'replay flag tells the gateway to skip emitting a '
              'duplicate audit row on retry');
      // Only the cache lookup ran — no mutations should have fired.
      final tx = pool.transactions.single;
      final mutations = tx.executed
          .map((s) => s.sql)
          .where((s) =>
              s.contains('insert into corpus_versions') ||
              s.contains('insert into corpus_version_chunks') ||
              s.contains('update advisor_source_chunks'))
          .toList();
      expect(mutations, isEmpty,
          reason:
              'cache hit must short-circuit the rollback before any '
              'write fires');
    });

    test(
        'idempotencyKey acquires pg_advisory_xact_lock BEFORE the cache read',
        () async {
      // Cache hits — replay path. We assert that the advisory lock
      // fires before the cache lookup, otherwise two concurrent
      // retries could both miss the cache and both run mutations.
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        'from admin_idempotency_cache': <PostgresRow>[
          <String, Object?>{
            'response_payload': '{"version_id":"cached-version",'
                '"created_by":"actor",'
                '"created_at":"2026-05-01T00:00:00.000Z",'
                '"summary":"cached",'
                '"rollback_of":"v-target",'
                '"superseded_at":null,'
                '"is_current":true,'
                '"chunk_count":3}',
          },
        ],
      });
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      await repo.rollbackToVersion(
        targetVersionId: 'v-target',
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        summary: 'rolled back',
        adminReason: 'admin.test.rollback.lock',
        idempotencyKey: 'rollback-key-1',
      );
      final stages = pool.transactions.single.executed
          .map((s) => s.sql)
          .where((s) =>
              !s.contains('app.bypass_rls_audit') &&
              !s.startsWith('set local role'))
          .toList();
      final lockIndex =
          stages.indexWhere((s) => s.contains('pg_advisory_xact_lock'));
      final cacheReadIndex = stages.indexWhere(
        (s) => s.contains('from admin_idempotency_cache'),
      );
      expect(lockIndex, greaterThanOrEqualTo(0),
          reason: 'rollback must take an advisory lock when an '
              'idempotency key is supplied');
      expect(cacheReadIndex, greaterThan(lockIndex),
          reason: 'cache read must run AFTER the advisory lock so '
              'concurrent retries serialize on the same key');
      // Resolution-safety: pg_advisory_xact_lock has overloads
      // `(bigint)` and `(integer, integer)`, but no `(bigint, bigint)`.
      // hashtext returns integer, so the two-arg call must pass the
      // hashes without ::bigint casts. A regression to ::bigint would
      // ship a 503 from Postgres with `function ... does not exist`.
      final lockSql = stages[lockIndex];
      expect(lockSql, isNot(contains('::bigint')),
          reason: 'pg_advisory_xact_lock(integer, integer) is the '
              'matching overload; ::bigint casts route to a '
              'nonexistent function signature');
    });

    test(
        'idempotencyKey persists the response on cache miss into admin_idempotency_cache',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        'from admin_idempotency_cache': const <PostgresRow>[],
        'select chunk_id from corpus_version_chunks': const <PostgresRow>[],
        'insert into corpus_versions': <PostgresRow>[
          <String, Object?>{
            'version_id': 'rollback-version',
            'created_by': 'actor',
            'created_at': DateTime.utc(2026, 5, 1),
            'summary': 'rolled back',
            'rollback_of': 'v-target',
            'superseded_at': null,
          },
        ],
      });
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      await repo.rollbackToVersion(
        targetVersionId: 'v-target',
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        summary: 'rolled back',
        adminReason: 'admin.test.rollback.first',
        idempotencyKey: 'rollback-key-1',
      );
      final tx = pool.transactions.single;
      final stages = tx.executed
          .map((s) => s.sql)
          .where((s) =>
              !s.contains('app.bypass_rls_audit') &&
              !s.startsWith('set local role'))
          .toList();
      // The advisory lock fires first; only then can mutations run.
      expect(stages.first, contains('pg_advisory_xact_lock'),
          reason: 'lock must be taken at the start of the '
              'transaction, before any cache read or mutation');

      final cacheWrites = tx.executed
          .where(
            (s) => s.sql.contains('insert into admin_idempotency_cache'),
          )
          .toList();
      expect(
        cacheWrites,
        hasLength(1),
        reason:
            'first run with an idempotency key must persist the '
            'response so the next retry replays it',
      );
      expect(
        cacheWrites.single.parameters['key'],
        equals('rollback-key-1'),
      );
      expect(
        cacheWrites.single.parameters['route'],
        equals('admin.corpus.rollback'),
      );
      // The repo MUST NOT touch the operator-scoped proxy_requests
      // table (it requires a (operator, location) FK pair which the
      // cross-tenant admin paths do not carry).
      expect(
        tx.executed.where((s) => s.sql.contains('proxy_requests')),
        isEmpty,
        reason:
            'admin idempotency must not write through the operator-'
            'scoped public.proxy_requests table',
      );
    });
  });
}

class _CorpusPool implements PostgresPool {
  _CorpusPool({
    this.rows = const <PostgresRow>[],
    this.rowsByContains = const <String, List<PostgresRow>>{},
  });

  final List<PostgresRow> rows;
  final Map<String, List<PostgresRow>> rowsByContains;
  final List<_CorpusTransaction> transactions = <_CorpusTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx =
        _CorpusTransaction(rows: rows, rowsByContains: rowsByContains);
    transactions.add(tx);
    return tx;
  }
}

class _RecordedSql {
  _RecordedSql({required this.sql, required this.parameters});
  final String sql;
  final PostgresParameters parameters;
}

class _CorpusTransaction extends PostgresTransaction {
  _CorpusTransaction({
    required this.rows,
    required this.rowsByContains,
  });

  final List<PostgresRow> rows;
  final Map<String, List<PostgresRow>> rowsByContains;
  final List<_RecordedSql> executed = <_RecordedSql>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executed.add(_RecordedSql(sql: sql, parameters: parameters));
    for (final entry in rowsByContains.entries) {
      if (sql.contains(entry.key)) return entry.value;
    }
    return rows;
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executed.add(_RecordedSql(sql: sql, parameters: parameters));
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
