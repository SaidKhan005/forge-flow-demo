// Forge & Flow advisor proxy — A3 rerank route tests.
//
// Advisor Knowledge Activation — Slice A3.
//
// Tests for the server-side Voyage rerank step on the text-query path of
// POST /v1/advisor/retrieve, plus the HP #9 rerank cost metering and the
// VoyageHttpRerankGateway HTTP parsing.
//
// Proves:
//   (a) text-query path reranks → chunks returned reordered by rerank
//       score (NOT the vector-similarity order); a LARGER candidate pool
//       is fetched from the retrieval service than the final max_results.
//   (b) rerank cost recorded under 'voyage_rerank' from the ACTUAL
//       provider-returned token count, attributed to operator/location;
//       a single request records BOTH a voyage_query_embedding row and a
//       voyage_rerank row.
//   (c) rerank gateway null → vector-only order unchanged + NO rerank
//       cost (full A2b back-compat).
//   (d) rerank gateway failure → 503 `rerank_unavailable` without leaking
//       the key or the raw provider error body.
//   (e) the VoyageHttpRerankGateway maps result.index → candidate id and
//       parses usage.total_tokens correctly (and fails open to 0 tokens).
//
// No live Voyage / Postgres — all fakes / MockClient.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/retrieved_chunk.dart';
import 'package:forge_and_flow/domain/repositories/corpus_retrieval_repository.dart';
import 'package:forge_and_flow/domain/services/advisor_provider_constants.dart';
import 'package:forge_and_flow/domain/services/rerank_provider.dart';
import 'package:forge_and_flow/services/corpus_retrieval_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../advisor_proxy_test_helpers.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────────

/// Fake corpus retrieval repository that records the requested
/// `maxResults` (so a test can assert the LARGER pool was fetched when
/// reranking) and returns a canned chunk list.
class _FakeCorpusRepo implements CorpusRetrievalRepository {
  _FakeCorpusRepo({this.stubbedChunks = const <RetrievedChunk>[]});

  final List<RetrievedChunk> stubbedChunks;
  final List<int> receivedMaxResults = <int>[];

  @override
  Future<List<RetrievedChunk>> searchChunks({
    required List<double> queryEmbedding,
    required String graphScope,
    String? restaurantId,
    required String providerId,
    required String modelId,
    required int dimension,
    required int maxResults,
  }) async {
    receivedMaxResults.add(maxResults);
    return stubbedChunks;
  }
}

/// Fake embedding gateway (re-used from the A2b shape): returns a canned
/// 1024-dim vector plus a configurable token count. HP #7: apiKey accepted
/// but NOT stored.
class _FakeEmbeddingGateway implements AdvisorQueryEmbeddingGateway {
  _FakeEmbeddingGateway({this.totalTokens = 7});

  final int totalTokens;

  @override
  Future<AdvisorQueryEmbeddingResult> embedQuery({
    required String apiKey,
    required String model,
    required int dimensions,
    required String queryText,
  }) async {
    return AdvisorQueryEmbeddingResult(
      embedding: List<double>.filled(1024, 0.42),
      totalTokens: totalTokens,
    );
  }
}

/// One captured [AdvisorRerankGateway.rerank] call.
class _RerankCall {
  const _RerankCall({
    required this.model,
    required this.queryText,
    required this.candidateIds,
    required this.topK,
    // HP #7: apiKey intentionally NOT captured.
  });

  final String model;
  final String queryText;
  final List<String> candidateIds;
  final int? topK;
}

/// Fake rerank gateway. Reorders the candidates by a caller-supplied
/// `scoreById` map (higher = better) and returns a configurable token
/// count. HP #7: apiKey accepted but NOT stored.
class _FakeRerankGateway implements AdvisorRerankGateway {
  _FakeRerankGateway({required this.scoreById, this.totalTokens = 0});

  /// Relevance score per candidate id. Candidates not in the map score 0.
  final Map<String, double> scoreById;
  final int totalTokens;

  final List<_RerankCall> calls = <_RerankCall>[];

  @override
  Future<AdvisorRerankResult> rerank({
    required String apiKey,
    required String model,
    required String queryText,
    required List<RerankCandidate> candidates,
    int? topK,
  }) async {
    calls.add(_RerankCall(
      model: model,
      queryText: queryText,
      candidateIds: <String>[for (final c in candidates) c.id],
      topK: topK,
    ));
    final sorted = [...candidates]
      ..sort((a, b) =>
          (scoreById[b.id] ?? 0.0).compareTo(scoreById[a.id] ?? 0.0));
    final ranking = <RerankResult>[
      for (var i = 0; i < sorted.length; i++)
        RerankResult(
          id: sorted[i].id,
          score: scoreById[sorted[i].id] ?? 0.0,
          rank: i,
        ),
    ];
    return AdvisorRerankResult(ranking: ranking, totalTokens: totalTokens);
  }
}

/// Rerank gateway that always throws.
class _ThrowingRerankGateway implements AdvisorRerankGateway {
  _ThrowingRerankGateway(this.message);
  final String message;

  @override
  Future<AdvisorRerankResult> rerank({
    required String apiKey,
    required String model,
    required String queryText,
    required List<RerankCandidate> candidates,
    int? topK,
  }) async {
    throw AdvisorRerankException(message);
  }
}

/// One captured [ProxyAccountingStore.commitUsageLog] call.
class _CommitCall {
  const _CommitCall({
    required this.operatorId,
    required this.locationId,
    required this.usageClass,
    required this.tokenCount,
    required this.costCents,
    required this.modelUsed,
  });

  final String operatorId;
  final String locationId;
  final String usageClass;
  final int tokenCount;
  final int costCents;
  final String modelUsed;
}

/// Accounting-store fake that records EVERY `commitUsageLog` call (the
/// shared `InMemoryAccountingStore` keeps only the last).
class _RecordingAccountingStore implements ProxyAccountingStore {
  final List<_CommitCall> commits = <_CommitCall>[];

  @override
  Future<void> commitUsageLog({
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) async {
    commits.add(_CommitCall(
      operatorId: operator.operatorId,
      locationId: operator.locationId,
      usageClass: usageClass,
      tokenCount: estimate.tokenCount,
      costCents: estimate.costCents,
      modelUsed: telemetry.modelUsed,
    ));
  }

  @override
  Future<ProxyAccountingStartResult> startRequest({
    required String idempotencyKey,
    required String requestType,
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) async {
    return const ProxyAccountingReserved(
      capStatus: ProxyCapStatus(
        usageClass: 'unused',
        monthlyCapCents: 0,
        monthlyUsedCents: 0,
        perInvocationCapCents: 0,
        estimatedCostCents: 0,
      ),
    );
  }

  @override
  Future<void> completeRequest({
    required OperatorContext operator,
    required String idempotencyKey,
    required Map<String, Object?> responsePayload,
    required DateTime now,
    ProxyRequestStats? stats,
  }) async {}
}

// ── Test helpers ──────────────────────────────────────────────────────────────

List<double> _zero1024() => List<double>.filled(1024, 0.0);

RetrievedChunk _chunk(String id, double sim) => RetrievedChunk(
      chunkId: id,
      docId: 'doc-$id',
      headingPath: <String>['Section'],
      text: 'text for $id',
      similarity: sim,
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  Future<T> withRealHttp<T>(Future<T> Function() body) async {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      return await body();
    } finally {
      HttpOverrides.global = saved;
    }
  }

  group('POST /v1/advisor/retrieve (A3 — rerank reordering)', () {
    late HttpServer server;
    late HttpClient client;
    late Uri baseUri;
    late SettableVerifier verifier;

    const meterOperatorId = 'op_meter_777';
    const meterLocationId = 'loc_meter_999';

    Future<void> spinUp({
      required CorpusRetrievalService retrievalService,
      AdvisorQueryEmbeddingGateway? embeddingGateway,
      String? voyageApiKey,
      AdvisorRerankGateway? rerankGateway,
      String? voyageRerankApiKey,
      ProxyUsageGuard? usageGuard,
      ProxyAccountingStore? accountingStore,
    }) async {
      verifier = SettableVerifier();
      verifier.claims = const ProxyJwtClaims(
        userId: 'user_meter',
        operatorId: meterOperatorId,
        locationId: meterLocationId,
        roles: <String>['advisor.read'],
      );
      final guard = ProxyRequestGuard(verifier: verifier);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            corpusRetrievalService: retrievalService,
            corpusQueryEmbeddingGateway: embeddingGateway,
            voyageApiKeyForRetrieval: voyageApiKey,
            corpusRerankGateway: rerankGateway,
            voyageRerankApiKeyForRetrieval: voyageRerankApiKey,
            usageGuard: usageGuard,
            accountingStore: accountingStore,
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {/* ignore */}
        }
      });
      client = HttpClient();
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
    }

    Future<void> shutDown() async {
      client.close(force: true);
      await server.close(force: true);
    }

    ProxyUsageGuard openGuard() => ProxyUsageGuard(
          store: FixedSnapshotProxyUsageStore(
            snapshot: UsageSnapshot(
              requestsThisMinute: 0,
              costCentsThisMonth: 0,
              minuteBucketStart: DateTime.utc(2026, 5, 24, 12, 0),
              monthBucketStart: DateTime.utc(2026, 5, 1),
            ),
          ),
          tierResolver: const FixedLaunchTierResolver(),
        );

    // ── (a) reranks → chunks reordered by rerank score; larger pool ─────────
    test('text query reranks and returns chunks reordered by rerank score',
        () async {
      await withRealHttp(() async {
        // Vector order: c1 (0.9), c2 (0.8), c3 (0.7). The reranker FLIPS it:
        // c3 best, then c2, then c1. The response must follow rerank order.
        final repo = _FakeCorpusRepo(
          stubbedChunks: <RetrievedChunk>[
            _chunk('c1', 0.9),
            _chunk('c2', 0.8),
            _chunk('c3', 0.7),
          ],
        );
        final rerank = _FakeRerankGateway(
          scoreById: <String, double>{'c1': 0.1, 'c2': 0.5, 'c3': 0.99},
        );
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: _FakeEmbeddingGateway(),
          voyageApiKey: 'sk-embed',
          rerankGateway: rerank,
          voyageRerankApiKey: 'sk-rerank',
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{
              'query': 'How do I improve CPLH?',
              'max_results': 3,
            },
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          final chunks = decoded['chunks'] as List<Object?>;
          final ids = <String>[
            for (final c in chunks) (c as Map<String, Object?>)['chunk_id'] as String,
          ];
          // Reordered by rerank score, NOT vector similarity.
          expect(ids, equals(<String>['c3', 'c2', 'c1']));

          // Rerank gateway saw the query text + the candidate ids.
          expect(rerank.calls, hasLength(1));
          expect(rerank.calls.first.queryText, equals('How do I improve CPLH?'));
          expect(
            rerank.calls.first.model,
            equals(AdvisorProviderConstants.voyageRerankModelId),
          );

          // A LARGER candidate pool was fetched than max_results (3): the
          // pool clamps to max(3*4, 20) = 20.
          expect(repo.receivedMaxResults, hasLength(1));
          expect(repo.receivedMaxResults.first, equals(20));
        } finally {
          await shutDown();
        }
      });
    });

    // ── (a') reranked pool is trimmed to max_results ────────────────────────
    test('reranked result is trimmed to max_results', () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo(
          stubbedChunks: <RetrievedChunk>[
            _chunk('c1', 0.9),
            _chunk('c2', 0.8),
            _chunk('c3', 0.7),
            _chunk('c4', 0.6),
          ],
        );
        final rerank = _FakeRerankGateway(
          scoreById: <String, double>{
            'c1': 0.2,
            'c2': 0.9,
            'c3': 0.5,
            'c4': 0.1,
          },
        );
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: _FakeEmbeddingGateway(),
          voyageApiKey: 'sk-embed',
          rerankGateway: rerank,
          voyageRerankApiKey: 'sk-rerank',
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': 'q', 'max_results': 2},
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          final chunks = decoded['chunks'] as List<Object?>;
          final ids = <String>[
            for (final c in chunks) (c as Map<String, Object?>)['chunk_id'] as String,
          ];
          // Top 2 by rerank score: c2 (0.9), c3 (0.5).
          expect(ids, equals(<String>['c2', 'c3']));
        } finally {
          await shutDown();
        }
      });
    });

    // ── (b) rerank cost recorded under 'voyage_rerank' from actual tokens ───
    test('rerank cost recorded under voyage_rerank from actual tokens, '
        'attributed to operator/location (plus embedding row)', () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo(
          stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
        );
        // 2,000,000 tokens at 5 cents/MTok → exactly 10 cents.
        final rerank = _FakeRerankGateway(
          scoreById: <String, double>{'c1': 1.0},
          totalTokens: 2000000,
        );
        final accounting = _RecordingAccountingStore();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: _FakeEmbeddingGateway(totalTokens: 1000000),
          voyageApiKey: 'sk-embed',
          rerankGateway: rerank,
          voyageRerankApiKey: 'sk-rerank',
          usageGuard: openGuard(),
          accountingStore: accounting,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': 'How do I improve CPLH?'},
          );
          expect(response.statusCode, equals(200));

          // TWO usage rows: one embedding, one rerank.
          expect(accounting.commits, hasLength(2));
          final embedCommit = accounting.commits.firstWhere(
              (c) => c.usageClass == kVoyageQueryEmbeddingUsageClass);
          final rerankCommit = accounting.commits
              .firstWhere((c) => c.usageClass == kVoyageRerankUsageClass);

          // Rerank row: distinct class, actual tokens, derived cost,
          // attributed to the caller, carrying the public rerank model id.
          expect(rerankCommit.usageClass, equals('voyage_rerank'));
          expect(rerankCommit.tokenCount, equals(2000000));
          expect(rerankCommit.costCents, equals(10));
          expect(rerankCommit.operatorId, equals(meterOperatorId));
          expect(rerankCommit.locationId, equals(meterLocationId));
          expect(
            rerankCommit.modelUsed,
            equals(AdvisorProviderConstants.voyageRerankModelId),
          );

          // Cross-check the cost against the registry rate directly.
          final rate = LlmCostRateRegistry.rateFor(
            AdvisorProviderConstants.voyageRerankModelId,
          )!;
          expect(
            rerankCommit.costCents,
            equals(rate.costCentsFor(inputTokens: 2000000, outputTokens: 0)),
          );

          // The embedding row is still its own distinct class.
          expect(embedCommit.tokenCount, equals(1000000));
          expect(embedCommit.costCents, equals(12));
        } finally {
          await shutDown();
        }
      });
    });

    // ── (b') rerank cost scales with the returned token count ───────────────
    test('rerank cost is derived from the returned token count (not fixed)',
        () async {
      await withRealHttp(() async {
        Future<_CommitCall> rerankCommitForTokens(int tokens) async {
          final repo = _FakeCorpusRepo(
            stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
          );
          final rerank = _FakeRerankGateway(
            scoreById: <String, double>{'c1': 1.0},
            totalTokens: tokens,
          );
          final accounting = _RecordingAccountingStore();
          await spinUp(
            retrievalService: CorpusRetrievalService(repository: repo),
            embeddingGateway: _FakeEmbeddingGateway(totalTokens: 0),
            voyageApiKey: 'sk-embed',
            rerankGateway: rerank,
            voyageRerankApiKey: 'sk-rerank',
            accountingStore: accounting,
          );
          try {
            final response = await httpPost(
              client,
              baseUri.resolve(advisorRetrievePath),
              authorization: 'Bearer token',
              body: <String, Object?>{'query': 'q'},
            );
            expect(response.statusCode, equals(200));
            return accounting.commits
                .firstWhere((c) => c.usageClass == kVoyageRerankUsageClass);
          } finally {
            await shutDown();
          }
        }

        final low = await rerankCommitForTokens(1000000); // 5 cents
        final high = await rerankCommitForTokens(4000000); // 20 cents
        expect(low.costCents, equals(5));
        expect(high.costCents, equals(20));
        expect(high.costCents, isNot(equals(low.costCents)));
      });
    });

    // ── (c) rerank gateway null → vector-only order unchanged, no cost ──────
    test('rerank gateway null → vector-only order unchanged + no rerank cost',
        () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo(
          stubbedChunks: <RetrievedChunk>[
            _chunk('c1', 0.9),
            _chunk('c2', 0.8),
          ],
        );
        final accounting = _RecordingAccountingStore();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: _FakeEmbeddingGateway(totalTokens: 100),
          voyageApiKey: 'sk-embed',
          // No rerank gateway / key.
          usageGuard: openGuard(),
          accountingStore: accounting,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': 'q', 'max_results': 5},
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          final chunks = decoded['chunks'] as List<Object?>;
          final ids = <String>[
            for (final c in chunks) (c as Map<String, Object?>)['chunk_id'] as String,
          ];
          // Vector-similarity order preserved (no reranking).
          expect(ids, equals(<String>['c1', 'c2']));

          // Exactly max_results requested from the repo (no larger pool).
          expect(repo.receivedMaxResults.first, equals(5));

          // Exactly ONE usage row (embedding) and NO rerank row.
          expect(
            accounting.commits.where(
                (c) => c.usageClass == kVoyageRerankUsageClass),
            isEmpty,
          );
          expect(
            accounting.commits
                .where((c) => c.usageClass == kVoyageQueryEmbeddingUsageClass),
            hasLength(1),
          );
        } finally {
          await shutDown();
        }
      });
    });

    // ── (c') no candidates → no rerank call, no rerank cost ─────────────────
    test('empty candidate pool → no rerank call and no rerank cost', () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo(); // no chunks
        final rerank = _FakeRerankGateway(scoreById: const <String, double>{});
        final accounting = _RecordingAccountingStore();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: _FakeEmbeddingGateway(totalTokens: 50),
          voyageApiKey: 'sk-embed',
          rerankGateway: rerank,
          voyageRerankApiKey: 'sk-rerank',
          accountingStore: accounting,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': 'q'},
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect((decoded['chunks'] as List<Object?>), isEmpty);
          // No candidates → rerank gateway never called, no rerank row.
          expect(rerank.calls, isEmpty);
          expect(
            accounting.commits.where(
                (c) => c.usageClass == kVoyageRerankUsageClass),
            isEmpty,
          );
        } finally {
          await shutDown();
        }
      });
    });

    // ── (c'') pre-computed embedding path cannot rerank ─────────────────────
    test('pre-computed embedding path never reranks (no query text)',
        () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo(
          stubbedChunks: <RetrievedChunk>[
            _chunk('c1', 0.9),
            _chunk('c2', 0.8),
          ],
        );
        final rerank = _FakeRerankGateway(
          scoreById: <String, double>{'c1': 0.1, 'c2': 0.99},
        );
        final accounting = _RecordingAccountingStore();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: _FakeEmbeddingGateway(),
          voyageApiKey: 'sk-embed',
          rerankGateway: rerank,
          voyageRerankApiKey: 'sk-rerank',
          accountingStore: accounting,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query_embedding': _zero1024()},
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          final ids = <String>[
            for (final c in (decoded['chunks'] as List<Object?>))
              (c as Map<String, Object?>)['chunk_id'] as String,
          ];
          // Vector order preserved — rerank never ran.
          expect(ids, equals(<String>['c1', 'c2']));
          expect(rerank.calls, isEmpty);
          expect(accounting.commits, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });

    // ── (d) rerank failure → 503 without leaking key or raw body ────────────
    test('rerank gateway failure → 503 rerank_unavailable, no key/body leak',
        () async {
      await withRealHttp(() async {
        const secretKey = 'voyage-RERANK-SECRET-KEY-999';
        const rawErrorText = 'Voyage rerank connection_reset internal detail';
        final repo = _FakeCorpusRepo(
          stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
        );
        final accounting = _RecordingAccountingStore();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: _FakeEmbeddingGateway(totalTokens: 10),
          voyageApiKey: 'sk-embed',
          rerankGateway: _ThrowingRerankGateway(rawErrorText),
          voyageRerankApiKey: secretKey,
          usageGuard: openGuard(),
          accountingStore: accounting,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': 'q'},
          );
          expect(response.statusCode, equals(503));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('rerank_unavailable'));
          // Neither the key nor the raw provider error leaks.
          expect(response.body, isNot(contains(secretKey)));
          expect(response.body, isNot(contains(rawErrorText)));
          // No rerank cost recorded on failure.
          expect(
            accounting.commits.where(
                (c) => c.usageClass == kVoyageRerankUsageClass),
            isEmpty,
          );
        } finally {
          await shutDown();
        }
      });
    });

    // ── (d') metered rerank path never leaks the key in telemetry ───────────
    test('metered rerank path never leaks the key', () async {
      await withRealHttp(() async {
        const secretKey = 'voyage-RERANK-METERED-KEY-abc';
        final repo = _FakeCorpusRepo(
          stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
        );
        final rerank = _FakeRerankGateway(
          scoreById: <String, double>{'c1': 1.0},
          totalTokens: 1000,
        );
        final accounting = _RecordingAccountingStore();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: _FakeEmbeddingGateway(totalTokens: 10),
          voyageApiKey: 'sk-embed',
          rerankGateway: rerank,
          voyageRerankApiKey: secretKey,
          usageGuard: openGuard(),
          accountingStore: accounting,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': 'q'},
          );
          expect(response.body, isNot(contains(secretKey)));
          for (final c in accounting.commits) {
            expect(c.modelUsed, isNot(contains(secretKey)));
          }
        } finally {
          await shutDown();
        }
      });
    });
  });

  // ── (e) VoyageHttpRerankGateway HTTP parsing unit tests ────────────────────

  group('VoyageHttpRerankGateway', () {
    test('maps result.index → candidate id and parses usage.total_tokens',
        () async {
      // Candidates in input order: a, b, c. The Voyage response scores
      // them out of order — index 2 (c) best, index 0 (a) worst — and the
      // gateway must sort descending by relevance_score and map index→id.
      final mock = MockClient((request) async {
        // Sanity: the request carries the documents we sent.
        final sent = jsonDecode(request.body) as Map<String, Object?>;
        expect(sent['model'], equals(AdvisorProviderConstants.voyageRerankModelId));
        expect((sent['documents'] as List<Object?>), hasLength(3));
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Map<String, Object?>>[
              <String, Object?>{'index': 0, 'relevance_score': 0.10},
              <String, Object?>{'index': 1, 'relevance_score': 0.55},
              <String, Object?>{'index': 2, 'relevance_score': 0.97},
            ],
            'usage': <String, Object?>{'total_tokens': 321},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = VoyageHttpRerankGateway(httpClient: mock);
      final result = await gateway.rerank(
        apiKey: 'sk-key',
        model: AdvisorProviderConstants.voyageRerankModelId,
        queryText: 'q',
        candidates: const <RerankCandidate>[
          RerankCandidate(id: 'a', text: 'alpha'),
          RerankCandidate(id: 'b', text: 'bravo'),
          RerankCandidate(id: 'c', text: 'charlie'),
        ],
      );
      // Descending by score: c (0.97), b (0.55), a (0.10).
      expect(<String>[for (final r in result.ranking) r.id],
          equals(<String>['c', 'b', 'a']));
      // Ranks assigned 0..n.
      expect(result.ranking.first.rank, equals(0));
      expect(result.totalTokens, equals(321));
    });

    test('missing usage block yields totalTokens 0 (fail-open)', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Map<String, Object?>>[
              <String, Object?>{'index': 0, 'relevance_score': 0.5},
            ],
            // no `usage` key
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = VoyageHttpRerankGateway(httpClient: mock);
      final result = await gateway.rerank(
        apiKey: 'sk-key',
        model: AdvisorProviderConstants.voyageRerankModelId,
        queryText: 'q',
        candidates: const <RerankCandidate>[
          RerankCandidate(id: 'only', text: 'doc'),
        ],
      );
      expect(result.ranking, hasLength(1));
      expect(result.ranking.first.id, equals('only'));
      expect(result.totalTokens, equals(0));
    });

    test('empty candidates → no HTTP call, empty ranking, zero tokens',
        () async {
      var called = false;
      final mock = MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      });
      final gateway = VoyageHttpRerankGateway(httpClient: mock);
      final result = await gateway.rerank(
        apiKey: 'sk-key',
        model: AdvisorProviderConstants.voyageRerankModelId,
        queryText: 'q',
        candidates: const <RerankCandidate>[],
      );
      expect(called, isFalse);
      expect(result.ranking, isEmpty);
      expect(result.totalTokens, equals(0));
    });

    test('non-2xx → AdvisorRerankException with truncated body, no key',
        () async {
      const secretKey = 'sk-SUPER-SECRET';
      final longBody = 'x' * 5000;
      final mock = MockClient((request) async {
        return http.Response(longBody, 500);
      });
      final gateway = VoyageHttpRerankGateway(httpClient: mock);
      Object? caught;
      try {
        await gateway.rerank(
          apiKey: secretKey,
          model: AdvisorProviderConstants.voyageRerankModelId,
          queryText: 'q',
          candidates: const <RerankCandidate>[
            RerankCandidate(id: 'a', text: 'alpha'),
          ],
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<AdvisorRerankException>());
      final message = (caught as AdvisorRerankException).message;
      // Body truncated to 300 chars + ellipsis — not the full 5000.
      expect(message.length, lessThan(longBody.length));
      expect(message, contains('...'));
      // The key is never in the exception message.
      expect(message, isNot(contains(secretKey)));
    });

    test('index out of range → typed AdvisorRerankException', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Map<String, Object?>>[
              // index 5 is out of range for a single-candidate request.
              <String, Object?>{'index': 5, 'relevance_score': 0.5},
            ],
          }),
          200,
        );
      });
      final gateway = VoyageHttpRerankGateway(httpClient: mock);
      expect(
        () => gateway.rerank(
          apiKey: 'sk-key',
          model: AdvisorProviderConstants.voyageRerankModelId,
          queryText: 'q',
          candidates: const <RerankCandidate>[
            RerankCandidate(id: 'a', text: 'alpha'),
          ],
        ),
        throwsA(isA<AdvisorRerankException>()),
      );
    });

    test('partial results (fewer than candidates) → typed exception',
        () async {
      // Two candidates sent but only one scored → provider 1:1 guard fires
      // and the gateway re-wraps the StateError as AdvisorRerankException.
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'results': <Map<String, Object?>>[
              <String, Object?>{'index': 0, 'relevance_score': 0.5},
            ],
          }),
          200,
        );
      });
      final gateway = VoyageHttpRerankGateway(httpClient: mock);
      expect(
        () => gateway.rerank(
          apiKey: 'sk-key',
          model: AdvisorProviderConstants.voyageRerankModelId,
          queryText: 'q',
          candidates: const <RerankCandidate>[
            RerankCandidate(id: 'a', text: 'alpha'),
            RerankCandidate(id: 'b', text: 'bravo'),
          ],
        ),
        throwsA(isA<AdvisorRerankException>()),
      );
    });
  });
}
