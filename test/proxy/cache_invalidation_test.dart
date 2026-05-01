// Phase 11A.B43 — corpus_invalidation_events telemetry. Asserts that
// `commitVersion` and `rollbackToVersion` write exactly one row into
// `corpus_invalidation_events` per corpus-version bump WHEN the
// `cache_telemetry_v2` flag is on, and zero rows when it's off. The row
// records the new version, the superseded version, and the count of
// chunks attached to the superseded version (a proxy for "dependent
// prompt-cache entries invalidated by this commit").

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/corpus_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('CorpusRepository.commitVersion — invalidation telemetry', () {
    test('emitInvalidationEvent default (false) writes ZERO event rows',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        // Prior version lookup — there is one current version to supersede.
        'select version_id::text as version_id from corpus_versions':
            <PostgresRow>[
          <String, Object?>{'version_id': 'v-prior'},
        ],
        'insert into corpus_versions': <PostgresRow>[
          <String, Object?>{
            'version_id': 'v-new',
            'created_by': 'actor',
            'created_at': DateTime.utc(2026, 5, 1),
            'summary': 'fresh corpus',
            'rollback_of': null,
            'superseded_at': null,
          },
        ],
      });
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      await repo.commitVersion(
        summary: 'fresh corpus',
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        chunks: <NewCorpusChunk>[
          _sampleChunk('doc.md#000'),
        ],
        adminReason: 'admin.test.commit.flag_off',
      );
      final inserts = pool.transactions.single.executed.where(
        (s) => s.sql.contains('insert into corpus_invalidation_events'),
      );
      expect(
        inserts,
        isEmpty,
        reason:
            'with cache_telemetry_v2 off (default), commitVersion must '
            'never write into corpus_invalidation_events',
      );
    });

    test(
        'emitInvalidationEvent: true writes ONE event row with prior version + dependent_count',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        'select version_id::text as version_id from corpus_versions':
            <PostgresRow>[
          <String, Object?>{'version_id': 'v-prior'},
        ],
        'insert into corpus_versions': <PostgresRow>[
          <String, Object?>{
            'version_id': 'v-new',
            'created_by': 'actor',
            'created_at': DateTime.utc(2026, 5, 1),
            'summary': 'fresh corpus',
            'rollback_of': null,
            'superseded_at': null,
          },
        ],
        // Dependent count over the superseded version's chunks.
        'count(*)::int as cnt from corpus_version_chunks': <PostgresRow>[
          <String, Object?>{'cnt': 7},
        ],
      });
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      await repo.commitVersion(
        summary: 'fresh corpus',
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        chunks: <NewCorpusChunk>[
          _sampleChunk('doc.md#000'),
        ],
        adminReason: 'admin.test.commit.flag_on',
        emitInvalidationEvent: true,
      );

      final inserts = pool.transactions.single.executed
          .where(
            (s) => s.sql.contains('insert into corpus_invalidation_events'),
          )
          .toList();
      expect(
        inserts,
        hasLength(1),
        reason:
            'flag-on commitVersion must write exactly one corpus_'
            'invalidation_events row',
      );
      final params = inserts.single.parameters;
      expect(params['new_version_id'], equals('v-new'));
      expect(params['prior_version_id'], equals('v-prior'));
      expect(
        params['dependent_count'],
        equals(7),
        reason:
            'dependent_count must equal the count of chunks attached '
            'to the superseded version (the cache entries that the '
            'corpus bump invalidates)',
      );
      expect(params['summary'], equals('fresh corpus'));
    });

    test(
        'first-ever commit (no prior version) writes event row with NULL superseded_version_id and 0 dependent_count',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        // Prior version lookup returns no row — first commit.
        'select version_id::text as version_id from corpus_versions':
            const <PostgresRow>[],
        'insert into corpus_versions': <PostgresRow>[
          <String, Object?>{
            'version_id': 'v-genesis',
            'created_by': 'actor',
            'created_at': DateTime.utc(2026, 5, 1),
            'summary': 'genesis',
            'rollback_of': null,
            'superseded_at': null,
          },
        ],
      });
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      await repo.commitVersion(
        summary: 'genesis',
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        chunks: <NewCorpusChunk>[
          _sampleChunk('doc.md#000'),
        ],
        adminReason: 'admin.test.commit.genesis',
        emitInvalidationEvent: true,
      );

      final inserts = pool.transactions.single.executed
          .where(
            (s) => s.sql.contains('insert into corpus_invalidation_events'),
          )
          .toList();
      expect(inserts, hasLength(1));
      final params = inserts.single.parameters;
      expect(params['new_version_id'], equals('v-genesis'));
      expect(
        params['prior_version_id'],
        isNull,
        reason: 'no prior version means superseded_version_id is NULL',
      );
      expect(
        params['dependent_count'],
        equals(0),
        reason: 'no prior version means zero invalidated entries',
      );

      // The dependent-count query should NOT have run (priorVersionId is
      // null, so the count is short-circuited to 0 without a round-trip).
      final countQueries = pool.transactions.single.executed.where(
        (s) => s.sql.contains('count(*)::int as cnt from corpus_version_chunks'),
      );
      expect(
        countQueries,
        isEmpty,
        reason:
            'first commit short-circuits dependent_count to 0 without '
            'a round-trip',
      );
    });

    test('event row insert lands AFTER the membership inserts (same tx)',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        'select version_id::text as version_id from corpus_versions':
            <PostgresRow>[
          <String, Object?>{'version_id': 'v-prior'},
        ],
        'insert into corpus_versions': <PostgresRow>[
          <String, Object?>{
            'version_id': 'v-new',
            'created_by': 'actor',
            'created_at': DateTime.utc(2026, 5, 1),
            'summary': 'fresh',
            'rollback_of': null,
            'superseded_at': null,
          },
        ],
        'count(*)::int as cnt from corpus_version_chunks': <PostgresRow>[
          <String, Object?>{'cnt': 1},
        ],
      });
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      await repo.commitVersion(
        summary: 'fresh',
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        chunks: <NewCorpusChunk>[
          _sampleChunk('doc.md#000'),
        ],
        adminReason: 'admin.test.commit.ordering',
        emitInvalidationEvent: true,
      );

      final stages = pool.transactions.single.executed
          .map((s) => s.sql)
          .where((s) =>
              !s.contains('app.bypass_rls_audit') &&
              !s.startsWith('set local role'))
          .toList();
      final membershipInsertIndex =
          stages.indexWhere((s) => s.contains('insert into corpus_version_chunks'));
      final eventInsertIndex = stages.indexWhere(
        (s) => s.contains('insert into corpus_invalidation_events'),
      );
      expect(membershipInsertIndex, greaterThanOrEqualTo(0));
      expect(eventInsertIndex, greaterThan(membershipInsertIndex),
          reason:
              'event row records the bump AFTER the new version + '
              'membership are stamped, all inside the same withSystem tx');
    });
  });

  group('CorpusRepository.rollbackToVersion — invalidation telemetry', () {
    test(
        'emitInvalidationEvent: true on a fresh rollback writes one event row',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        // No idempotency cache hit — fresh path.
        'from admin_idempotency_cache': const <PostgresRow>[],
        // Target membership returns one chunk.
        'select chunk_id from corpus_version_chunks': <PostgresRow>[
          <String, Object?>{'chunk_id': 'doc.md#000'},
        ],
        'select version_id::text as version_id from corpus_versions':
            <PostgresRow>[
          <String, Object?>{'version_id': 'v-prior'},
        ],
        'insert into corpus_versions': <PostgresRow>[
          <String, Object?>{
            'version_id': 'v-rollback',
            'created_by': 'actor',
            'created_at': DateTime.utc(2026, 5, 1),
            'summary': 'rolled back',
            'rollback_of': 'v-target',
            'superseded_at': null,
          },
        ],
        'count(*)::int as cnt from corpus_version_chunks': <PostgresRow>[
          <String, Object?>{'cnt': 4},
        ],
      });
      final repo = CorpusRepository(TenantTransactionWrapper(pool));
      final result = await repo.rollbackToVersion(
        targetVersionId: 'v-target',
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        summary: 'rolled back',
        adminReason: 'admin.test.rollback.flag_on',
        emitInvalidationEvent: true,
      );
      expect(result.replayed, isFalse);

      final inserts = pool.transactions.single.executed
          .where(
            (s) => s.sql.contains('insert into corpus_invalidation_events'),
          )
          .toList();
      expect(inserts, hasLength(1));
      final params = inserts.single.parameters;
      expect(params['new_version_id'], equals('v-rollback'));
      expect(params['prior_version_id'], equals('v-prior'));
      expect(params['dependent_count'], equals(4));
    });

    test(
        'emitInvalidationEvent: true on an idempotency replay does NOT write a duplicate event row',
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
        adminReason: 'admin.test.rollback.replay_flag_on',
        idempotencyKey: 'rollback-key-1',
        emitInvalidationEvent: true,
      );
      expect(replayed.replayed, isTrue);

      final inserts = pool.transactions.single.executed.where(
        (s) => s.sql.contains('insert into corpus_invalidation_events'),
      );
      expect(
        inserts,
        isEmpty,
        reason:
            'replay short-circuits before any mutation; the original '
            'request already emitted the event row',
      );
    });
  });

  group('Cache key invalidates on corpus_version bump', () {
    test('a new corpus_version produces a different cache key', () {
      const builder = AdvisorPromptCacheBuilder();
      final keyV1 = builder.cacheKeyForCorpusVersion('launch_v1');
      final keyV2 = builder.cacheKeyForCorpusVersion('launch_v2');
      expect(
        keyV1,
        isNot(equals(keyV2)),
        reason:
            'corpus_version bump must change the cache key string so '
            'every prior cached entry is logically invalidated',
      );
    });
  });

  group('RepositoryCorpusAdminProxyGateway — emitInvalidationEvent wiring',
      () {
    // The pool handles both the corpus tx AND the audit tx that fires
    // from the gateway's `_audit` helper. Each repository's `withSystem`
    // call opens its own transaction; assertions look across all of them.
    test('emitInvalidationEvent: true → rollback writes corpus_invalidation_events',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        // Idempotency cache miss — fresh path.
        'from admin_idempotency_cache': const <PostgresRow>[],
        'select chunk_id from corpus_version_chunks': <PostgresRow>[
          <String, Object?>{'chunk_id': 'doc.md#000'},
        ],
        'select version_id::text as version_id from corpus_versions':
            <PostgresRow>[
          <String, Object?>{'version_id': 'v-prior'},
        ],
        'insert into corpus_versions': <PostgresRow>[
          <String, Object?>{
            'version_id': 'v-rollback',
            'created_by': 'actor',
            'created_at': DateTime.utc(2026, 5, 1),
            'summary': 'rolled back',
            'rollback_of': 'v-target',
            'superseded_at': null,
          },
        ],
        'count(*)::int as cnt from corpus_version_chunks': <PostgresRow>[
          <String, Object?>{'cnt': 5},
        ],
        // The gateway's _audit helper expects this insert to return an
        // event_id text row. Without it, AuthEventsAuditRepository
        // throws StateError on read.
        'insert into auth_events_audit': <PostgresRow>[
          <String, Object?>{
            'event_id': '11111111-1111-4111-8111-111111111111',
          },
        ],
      });
      final wrapper = TenantTransactionWrapper(pool);
      final gateway = RepositoryCorpusAdminProxyGateway(
        corpusRepository: CorpusRepository(wrapper),
        auditRepository: AuthEventsAuditRepository(wrapper),
        emitInvalidationEvent: true,
      );
      await gateway.rollbackVersion(
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        targetVersionId: 'v-target',
        summary: 'rolled back',
        idempotencyKey: 'rollback-key-1',
        adminReason: 'admin.test.rollback.flag_on',
      );

      final allInserts = pool.transactions
          .expand((tx) => tx.executed)
          .where(
            (s) =>
                s.sql.contains('insert into corpus_invalidation_events'),
          )
          .toList();
      expect(
        allInserts,
        hasLength(1),
        reason:
            'flag-on gateway.rollbackVersion must write exactly one '
            'corpus_invalidation_events row',
      );
      expect(allInserts.single.parameters['new_version_id'],
          equals('v-rollback'));
      expect(allInserts.single.parameters['prior_version_id'],
          equals('v-prior'));
      expect(allInserts.single.parameters['dependent_count'], equals(5));
    });

    test('emitInvalidationEvent: false (default) → rollback writes no event row',
        () async {
      final pool = _CorpusPool(rowsByContains: <String, List<PostgresRow>>{
        'from admin_idempotency_cache': const <PostgresRow>[],
        'select chunk_id from corpus_version_chunks': <PostgresRow>[
          <String, Object?>{'chunk_id': 'doc.md#000'},
        ],
        'select version_id::text as version_id from corpus_versions':
            <PostgresRow>[
          <String, Object?>{'version_id': 'v-prior'},
        ],
        'insert into corpus_versions': <PostgresRow>[
          <String, Object?>{
            'version_id': 'v-rollback',
            'created_by': 'actor',
            'created_at': DateTime.utc(2026, 5, 1),
            'summary': 'rolled back',
            'rollback_of': 'v-target',
            'superseded_at': null,
          },
        ],
        'insert into auth_events_audit': <PostgresRow>[
          <String, Object?>{
            'event_id': '11111111-1111-4111-8111-111111111111',
          },
        ],
      });
      final wrapper = TenantTransactionWrapper(pool);
      final gateway = RepositoryCorpusAdminProxyGateway(
        corpusRepository: CorpusRepository(wrapper),
        auditRepository: AuthEventsAuditRepository(wrapper),
        // emitInvalidationEvent omitted — defaults to false.
      );
      await gateway.rollbackVersion(
        actorUserId: '00000000-0000-4000-8000-aaaaaaaaaaaa',
        targetVersionId: 'v-target',
        summary: 'rolled back',
        idempotencyKey: 'rollback-key-default',
        adminReason: 'admin.test.rollback.flag_off',
      );

      final allInserts = pool.transactions
          .expand((tx) => tx.executed)
          .where(
            (s) =>
                s.sql.contains('insert into corpus_invalidation_events'),
          );
      expect(
        allInserts,
        isEmpty,
        reason:
            'with the rollout flag off, the gateway must not produce '
            'any corpus_invalidation_events rows',
      );
    });
  });
}

NewCorpusChunk _sampleChunk(String chunkId) {
  return NewCorpusChunk(
    chunkId: chunkId,
    docId: 'doc.md',
    sourcePath: 'doc.md',
    scope: 'global_shared_methodology',
    chunkKind: 'paragraph',
    chunkProfile: 'default',
    headingPath: const <String>['Doc'],
    startLine: 1,
    endLine: 5,
    estimatedTokens: 12,
    riskLevel: 'standard',
    contentSha256:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    text: 'Hello',
    provenanceJson: '{}',
  );
}

class _CorpusPool implements PostgresPool {
  _CorpusPool({
    this.rowsByContains = const <String, List<PostgresRow>>{},
  });

  final Map<String, List<PostgresRow>> rowsByContains;
  final List<_CorpusTransaction> transactions = <_CorpusTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _CorpusTransaction(rowsByContains: rowsByContains);
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
  _CorpusTransaction({required this.rowsByContains});

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
    return const <PostgresRow>[];
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
