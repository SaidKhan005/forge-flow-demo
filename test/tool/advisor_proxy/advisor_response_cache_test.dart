// code-health.L14 — PostgresAdvisorResponseCache tests.
//
// Verifies hit / miss / TTL / operator-isolation semantics against a
// fake `PostgresPool` that mirrors the existing repository test
// pattern (see
// `test/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository_test.dart`).
//
// No live Postgres binding — the fake pool records every executed
// SQL + parameters and returns canned rows so the assertions cover
// both the SQL shape (tenant SET LOCAL trio runs first; lookup query
// filters by all six key columns; upsert uses ON CONFLICT … DO
// UPDATE) and the surface behavior (hit returns the cached answer;
// stale row is self-healed; cross-operator probe returns miss).

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../../tool/advisor_proxy/advisor_response_cache.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _loc = '33333333-3333-3333-3333-333333333333';

Uint8List _hashOf(String s) =>
    Uint8List.fromList(sha256.convert(utf8.encode(s)).bytes);

void main() {
  group('PostgresAdvisorResponseCache.lookup', () {
    test(
      'returns the cached answer when a non-expired row matches the '
      '6-tuple key, after issuing the tenant SET LOCAL trio',
      () async {
        final fixedNow = DateTime.utc(2026, 5, 7, 12);
        final futureExpiry = fixedNow.add(const Duration(hours: 23));
        final pool = _Pool(
          lookupRows: <PostgresRow>[
            <String, Object?>{
              'cache_id': 7,
              'response': <String, Object?>{'answer': 'cached answer'},
              'expires_at': futureExpiry,
            },
          ],
        );
        final cache = PostgresAdvisorResponseCache(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => fixedNow,
        );

        final answer = await cache.lookup(
          operatorId: _opA,
          locationId: _loc,
          queryClass: 'haiku',
          questionHash: 'q-hash-1',
          corpusVersion: 'v42',
        );

        expect(answer, equals('cached answer'));
        final tx = pool.transactions.single;

        // Tenant SET LOCAL trio runs BEFORE any cache table touch.
        final firstCacheTouchIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('public.advisor_response_cache'),
        );
        expect(firstCacheTouchIndex, greaterThan(1));
        expect(
          tx.executedSql.take(firstCacheTouchIndex),
          containsAll(<Matcher>[
            contains("set_config('app.operator_id'"),
            contains("set_config('app.location_id'"),
          ]),
        );

        // Lookup query filters by every key column the unique index uses.
        final lookupSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('select cache_id, response, expires_at'),
        );
        expect(lookupSql, contains('operator_id = @operator_id'));
        expect(lookupSql, contains('location_id = @location_id'));
        expect(lookupSql, contains('query_class = @query_class'));
        expect(lookupSql, contains('corpus_version = @corpus_version'));
        expect(lookupSql, contains('prompt_hash = @prompt_hash'));
        expect(lookupSql, contains('coalesce(embedding_id, 0) = 0'));

        final lookupParams = tx.parameters.firstWhere(
          (p) => p.containsKey('prompt_hash'),
        );
        expect(lookupParams['operator_id'], equals(_opA));
        expect(lookupParams['location_id'], equals(_loc));
        expect(lookupParams['query_class'], equals('haiku'));
        expect(lookupParams['corpus_version'], equals('v42'));
        expect(lookupParams['prompt_hash'], equals(_hashOf('q-hash-1')));

        // No proactive DELETE on a fresh hit.
        expect(
          tx.executedSql.any(
            (sql) => sql.startsWith('delete from public.advisor_response_cache'),
          ),
          isFalse,
        );
      },
    );

    test('returns miss when the lookup query yields no rows', () async {
      final pool = _Pool(lookupRows: const <PostgresRow>[]);
      final cache = PostgresAdvisorResponseCache(
        tenantWrapper: TenantTransactionWrapper(pool),
      );

      final answer = await cache.lookup(
        operatorId: _opA,
        locationId: _loc,
        queryClass: 'haiku',
        questionHash: 'q-hash-2',
        corpusVersion: 'v42',
      );

      expect(answer, isNull);
    });

    test(
      'returns miss AND proactively deletes the stale row when the '
      'matched entry is past expires_at (self-healing TTL)',
      () async {
        final fixedNow = DateTime.utc(2026, 5, 7, 12);
        final pastExpiry = fixedNow.subtract(const Duration(seconds: 1));
        final pool = _Pool(
          lookupRows: <PostgresRow>[
            <String, Object?>{
              'cache_id': 99,
              'response': <String, Object?>{'answer': 'stale answer'},
              'expires_at': pastExpiry,
            },
          ],
        );
        final cache = PostgresAdvisorResponseCache(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => fixedNow,
        );

        final answer = await cache.lookup(
          operatorId: _opA,
          locationId: _loc,
          queryClass: 'haiku',
          questionHash: 'q-hash-3',
          corpusVersion: 'v42',
        );

        expect(answer, isNull, reason: 'stale row must not serve a hit');

        final tx = pool.transactions.single;
        final deleteSql = tx.executedSql.firstWhere(
          (sql) => sql.startsWith('delete from public.advisor_response_cache'),
          orElse: () =>
              throw StateError('expected stale-row DELETE was not issued'),
        );
        expect(deleteSql, contains('cache_id = @id'));
        final deleteParams = tx.parameters.firstWhere(
          (p) => p['id'] == 99,
        );
        expect(deleteParams['id'], equals(99));
      },
    );

    test(
      'enforces operator isolation: a row stored for operator A cannot '
      'serve a hit for operator B with the same prompt key',
      () async {
        // Two separate fake pools to mirror "no shared visibility":
        // operator A's cache row never reaches operator B's transaction.
        // The Dart-side TenantContext + SET LOCAL story is the primary
        // defense; this test verifies the cache class does not leak
        // operator A's row into operator B's lookup parameters.
        final fixedNow = DateTime.utc(2026, 5, 7, 12);
        final futureExpiry = fixedNow.add(const Duration(hours: 23));

        final poolA = _Pool(
          lookupRows: <PostgresRow>[
            <String, Object?>{
              'cache_id': 1,
              'response': <String, Object?>{'answer': 'A-only answer'},
              'expires_at': futureExpiry,
            },
          ],
        );
        final cacheA = PostgresAdvisorResponseCache(
          tenantWrapper: TenantTransactionWrapper(poolA),
          now: () => fixedNow,
        );

        // Operator B's pool sees no rows — RLS would filter them out
        // in production; the fake mirrors that posture.
        final poolB = _Pool(lookupRows: const <PostgresRow>[]);
        final cacheB = PostgresAdvisorResponseCache(
          tenantWrapper: TenantTransactionWrapper(poolB),
          now: () => fixedNow,
        );

        final hitA = await cacheA.lookup(
          operatorId: _opA,
          locationId: _loc,
          queryClass: 'haiku',
          questionHash: 'shared-q',
          corpusVersion: 'v42',
        );
        final missB = await cacheB.lookup(
          operatorId: _opB,
          locationId: _loc,
          queryClass: 'haiku',
          questionHash: 'shared-q',
          corpusVersion: 'v42',
        );

        expect(hitA, equals('A-only answer'));
        expect(missB, isNull);

        // Each transaction bound its own operator_id — never cross-
        // contaminated.
        final aLookupParams = poolA.transactions.single.parameters
            .firstWhere((p) => p.containsKey('prompt_hash'));
        final bLookupParams = poolB.transactions.single.parameters
            .firstWhere((p) => p.containsKey('prompt_hash'));
        expect(aLookupParams['operator_id'], equals(_opA));
        expect(bLookupParams['operator_id'], equals(_opB));
      },
    );

    test('decodes the response when the driver hands back a JSON string',
        () async {
      // package:postgres can return JSONB as either a Map (when it
      // decoded) or a raw String (when it did not). The cache class
      // handles both shapes.
      final fixedNow = DateTime.utc(2026, 5, 7, 12);
      final pool = _Pool(
        lookupRows: <PostgresRow>[
          <String, Object?>{
            'cache_id': 5,
            'response': '{"answer":"string-shape"}',
            'expires_at': fixedNow.add(const Duration(hours: 1)),
          },
        ],
      );
      final cache = PostgresAdvisorResponseCache(
        tenantWrapper: TenantTransactionWrapper(pool),
        now: () => fixedNow,
      );

      final answer = await cache.lookup(
        operatorId: _opA,
        locationId: _loc,
        queryClass: 'haiku',
        questionHash: 'q',
        corpusVersion: 'v',
      );

      expect(answer, equals('string-shape'));
    });
  });

  group('PostgresAdvisorResponseCache.put', () {
    test(
      'issues an INSERT … ON CONFLICT DO UPDATE upsert with the '
      'computed expires_at and the JSON envelope',
      () async {
        final fixedNow = DateTime.utc(2026, 5, 7, 12);
        final pool = _Pool();
        final cache = PostgresAdvisorResponseCache(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => fixedNow,
        );

        await cache.put(
          operatorId: _opA,
          locationId: _loc,
          queryClass: 'sonnet',
          questionHash: 'q-hash-put',
          corpusVersion: 'v42',
          answer: 'fresh answer',
        );

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('insert into public.advisor_response_cache'),
        );
        expect(insertSql, contains('on conflict'));
        expect(insertSql, contains('do update set'));
        expect(insertSql, contains('@response::jsonb'));

        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('response'),
        );
        expect(insertParams['operator_id'], equals(_opA));
        expect(insertParams['location_id'], equals(_loc));
        expect(insertParams['query_class'], equals('sonnet'));
        expect(insertParams['corpus_version'], equals('v42'));
        expect(insertParams['prompt_hash'], equals(_hashOf('q-hash-put')));

        final responseJson = insertParams['response'] as String;
        final decoded = jsonDecode(responseJson) as Map<String, Object?>;
        expect(decoded['answer'], equals('fresh answer'));

        // Default 24h TTL when the caller does not override.
        expect(
          insertParams['expires_at'],
          equals(fixedNow.add(const Duration(hours: 24))),
        );
      },
    );

    test(
      'TTL: a put with a tiny ttl is treated as expired by a lookup '
      'whose now() advances past the boundary (self-healing path)',
      () async {
        // The repository fakes don't actually persist; this test
        // asserts the put() side computes expires_at correctly AND
        // the lookup() side correctly treats a stale row as miss.
        // Persistent end-to-end coverage would need a live Postgres
        // binding (out of scope for unit tests).
        final tWrite = DateTime.utc(2026, 5, 7, 12, 0, 0);
        final tRead = tWrite.add(const Duration(milliseconds: 5));
        final tinyTtl = const Duration(milliseconds: 1);

        // Phase 1 — record the put's bound expires_at.
        final writePool = _Pool();
        final writeCache = PostgresAdvisorResponseCache(
          tenantWrapper: TenantTransactionWrapper(writePool),
          now: () => tWrite,
        );
        await writeCache.put(
          operatorId: _opA,
          locationId: _loc,
          queryClass: 'haiku',
          questionHash: 'tiny-ttl-q',
          corpusVersion: 'v1',
          answer: 'will expire',
          ttl: tinyTtl,
        );
        final boundExpiry = writePool.transactions.single.parameters
            .firstWhere((p) => p.containsKey('response'))['expires_at']
            as DateTime;
        expect(boundExpiry, equals(tWrite.add(tinyTtl)));

        // Phase 2 — feed that stale row back into a lookup whose
        // clock has advanced past the boundary. The row must be
        // treated as miss AND proactively DELETEd.
        final readPool = _Pool(
          lookupRows: <PostgresRow>[
            <String, Object?>{
              'cache_id': 42,
              'response': <String, Object?>{'answer': 'will expire'},
              'expires_at': boundExpiry,
            },
          ],
        );
        final readCache = PostgresAdvisorResponseCache(
          tenantWrapper: TenantTransactionWrapper(readPool),
          now: () => tRead,
        );
        final hit = await readCache.lookup(
          operatorId: _opA,
          locationId: _loc,
          queryClass: 'haiku',
          questionHash: 'tiny-ttl-q',
          corpusVersion: 'v1',
        );
        expect(hit, isNull);
        expect(
          readPool.transactions.single.executedSql.any(
            (sql) => sql.startsWith('delete from public.advisor_response_cache'),
          ),
          isTrue,
        );
      },
    );

    test('rejects non-positive ttl arguments', () async {
      final pool = _Pool();
      final cache = PostgresAdvisorResponseCache(
        tenantWrapper: TenantTransactionWrapper(pool),
      );

      await expectLater(
        cache.put(
          operatorId: _opA,
          locationId: _loc,
          queryClass: 'haiku',
          questionHash: 'q',
          corpusVersion: 'v',
          answer: 'a',
          ttl: Duration.zero,
        ),
        throwsA(isA<AdvisorResponseCacheTtlError>()),
      );
    });
  });

  group('PostgresAdvisorResponseCache constructor', () {
    test('rejects a non-positive defaultTtl', () {
      final pool = _Pool();
      expect(
        () => PostgresAdvisorResponseCache(
          tenantWrapper: TenantTransactionWrapper(pool),
          defaultTtl: Duration.zero,
        ),
        throwsA(isA<AdvisorResponseCacheTtlError>()),
      );
    });
  });
}

class _Pool implements PostgresPool {
  _Pool({this.lookupRows = const <PostgresRow>[]});

  final List<PostgresRow> lookupRows;
  final List<_Tx> transactions = <_Tx>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _Tx(lookupRows: lookupRows);
    transactions.add(tx);
    return tx;
  }
}

class _Tx extends PostgresTransaction {
  _Tx({required this.lookupRows});

  final List<PostgresRow> lookupRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql.trim());
    this.parameters.add(parameters);
    if (sql.contains('select cache_id, response, expires_at')) {
      return lookupRows;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql.trim());
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
