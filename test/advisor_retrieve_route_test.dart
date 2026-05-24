// Advisor Knowledge Activation — Slice A2.
// Route + unit tests for POST /v1/advisor/retrieve.
//
// Proves:
//   1. Valid 1024-dim embedding returns 200 with a 'chunks' list.
//   2. Wrong-length embedding (not 1024) returns 400 with a structured
//      error envelope before the service is called.
//   3. Missing query_embedding field returns 400.
//   4. Non-list query_embedding returns 400.
//   5. Service not configured returns 503.
//   6. Missing auth returns 401.
//   7. Optional parameters (graph_scope, restaurant_id, max_results)
//      are forwarded correctly to the service.
//
// No Postgres, no network; uses a fake CorpusRetrievalService backed by
// a fake CorpusRetrievalRepository (same pattern as Slice A1 tests).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/retrieved_chunk.dart';
import 'package:forge_and_flow/domain/repositories/corpus_retrieval_repository.dart';
import 'package:forge_and_flow/services/corpus_retrieval_service.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import 'advisor_proxy_test_helpers.dart';

// ── Fake repository ──────────────────────────────────────────────────────────

/// Capture of one searchChunks call.
class _SearchCall {
  const _SearchCall({
    required this.queryEmbedding,
    required this.graphScope,
    required this.restaurantId,
    required this.maxResults,
  });

  final List<double> queryEmbedding;
  final String graphScope;
  final String? restaurantId;
  final int maxResults;
}

/// Fake CorpusRetrievalRepository that records calls and returns a
/// canned chunk list.
class _FakeCorpusRetrievalRepository implements CorpusRetrievalRepository {
  _FakeCorpusRetrievalRepository({required this.stubbedChunks});

  final List<RetrievedChunk> stubbedChunks;
  final List<_SearchCall> calls = <_SearchCall>[];

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
    calls.add(
      _SearchCall(
        queryEmbedding: queryEmbedding,
        graphScope: graphScope,
        restaurantId: restaurantId,
        maxResults: maxResults,
      ),
    );
    return stubbedChunks;
  }
}

// ── Test helpers ─────────────────────────────────────────────────────────────

/// A valid zero 1024-dim embedding.
List<double> _zero1024() => List<double>.filled(1024, 0.0);

/// A minimal RetrievedChunk for response-shape tests.
RetrievedChunk _chunk(String id, double similarity) => RetrievedChunk(
  chunkId: id,
  docId: 'doc-$id',
  headingPath: <String>['Section 1'],
  text: 'text for $id',
  similarity: similarity,
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('POST /v1/advisor/retrieve (advisor_retrieve_route)', () {
    // Flutter test environment installs HttpOverrides that reject real
    // HTTP. Clear for each server-based test, restore after.
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    late HttpServer server;
    late HttpClient client;
    late SettableVerifier verifier;
    late Uri baseUri;
    late _FakeCorpusRetrievalRepository fakeRepo;
    late CorpusRetrievalService service;

    Future<void> spinUp({List<RetrievedChunk> chunks = const []}) async {
      fakeRepo = _FakeCorpusRetrievalRepository(stubbedChunks: chunks);
      service = CorpusRetrievalService(repository: fakeRepo);
      verifier = SettableVerifier();
      verifier.claims = defaultProxyClaims();
      final guard = ProxyRequestGuard(verifier: verifier);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            corpusRetrievalService: service,
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {
            /* ignore */
          }
        }
      });
      client = HttpClient();
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
    }

    Future<void> spinUpNoService() async {
      verifier = SettableVerifier();
      verifier.claims = defaultProxyClaims();
      final guard = ProxyRequestGuard(verifier: verifier);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          // corpusRetrievalService is null — 503 expected.
          await routeRequest(request, guard);
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {
            /* ignore */
          }
        }
      });
      client = HttpClient();
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
    }

    Future<void> shutDown() async {
      client.close(force: true);
      await server.close(force: true);
    }

    // ── 200 — valid 1024-dim embedding returns chunks ─────────────────

    test('valid 1024-dim embedding returns 200 with chunks', () async {
      await withRealHttp(() async {
        await spinUp(
          chunks: <RetrievedChunk>[
            _chunk('c1', 0.95),
            _chunk('c2', 0.80),
          ],
        );
        try {
          final body = <String, Object?>{
            'query_embedding': _zero1024(),
          };
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: body,
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded.containsKey('chunks'), isTrue);
          final chunks = decoded['chunks']! as List<Object?>;
          expect(chunks, hasLength(2));
          final first = chunks[0]! as Map<String, Object?>;
          expect(first['chunk_id'], equals('c1'));
          expect(first['doc_id'], equals('doc-c1'));
          expect(first['similarity'], closeTo(0.95, 0.001));
          expect(first['heading_path'], isA<List<Object?>>());
          expect(first['text'], isA<String>());
        } finally {
          await shutDown();
        }
      });
    });

    // ── 400 — wrong-length embedding (too short) ──────────────────────

    test('512-dim embedding returns 400 without calling the service', () async {
      await withRealHttp(() async {
        await spinUp();
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{
              'query_embedding': List<double>.filled(512, 0.0),
            },
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_query_embedding_dimension'));
          // Service must NOT have been called.
          expect(fakeRepo.calls, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });

    // ── 400 — too-long embedding ──────────────────────────────────────

    test('2048-dim embedding returns 400 without calling the service', () async {
      await withRealHttp(() async {
        await spinUp();
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{
              'query_embedding': List<double>.filled(2048, 0.0),
            },
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_query_embedding_dimension'));
          expect(fakeRepo.calls, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });

    // ── 400 — missing query_embedding ────────────────────────────────

    test('missing query_embedding returns 400', () async {
      await withRealHttp(() async {
        await spinUp();
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('missing_query_embedding'));
        } finally {
          await shutDown();
        }
      });
    });

    // ── 400 — non-list query_embedding ───────────────────────────────

    test('non-list query_embedding returns 400', () async {
      await withRealHttp(() async {
        await spinUp();
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: const <String, Object?>{'query_embedding': 'not-a-list'},
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('missing_query_embedding'));
        } finally {
          await shutDown();
        }
      });
    });

    // ── 503 — service not configured ─────────────────────────────────

    test('returns 503 when corpusRetrievalService is not configured', () async {
      await withRealHttp(() async {
        await spinUpNoService();
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{
              'query_embedding': _zero1024(),
            },
          );
          expect(response.statusCode, equals(503));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('corpus_retrieval_not_configured'));
        } finally {
          await shutDown();
        }
      });
    });

    // ── 401 — missing auth ────────────────────────────────────────────

    test('missing Authorization header returns 401', () async {
      await withRealHttp(() async {
        await spinUp();
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            // No authorization header.
            body: <String, Object?>{
              'query_embedding': _zero1024(),
            },
          );
          expect(response.statusCode, equals(401));
        } finally {
          await shutDown();
        }
      });
    });

    // ── Optional parameters forwarded correctly ───────────────────────

    test(
      'graph_scope, restaurant_id, max_results are forwarded to the service',
      () async {
        await withRealHttp(() async {
          await spinUp();
          try {
            const restaurantUuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
            final response = await httpPost(
              client,
              baseUri.resolve(advisorRetrievePath),
              authorization: 'Bearer token',
              body: <String, Object?>{
                'query_embedding': _zero1024(),
                'graph_scope': 'coaching',
                'restaurant_id': restaurantUuid,
                'max_results': 16,
              },
            );
            expect(response.statusCode, equals(200));
            expect(fakeRepo.calls, hasLength(1));
            final call = fakeRepo.calls.first;
            expect(call.graphScope, equals('coaching'));
            expect(call.restaurantId, equals(restaurantUuid));
            expect(call.maxResults, equals(16));
          } finally {
            await shutDown();
          }
        });
      },
    );

    // ── Default parameters applied when omitted ───────────────────────

    test('defaults: graphScope=methodology, restaurantId=null, maxResults=8',
        () async {
      await withRealHttp(() async {
        await spinUp();
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{
              'query_embedding': _zero1024(),
            },
          );
          expect(response.statusCode, equals(200));
          expect(fakeRepo.calls, hasLength(1));
          final call = fakeRepo.calls.first;
          expect(call.graphScope, equals('methodology'));
          expect(call.restaurantId, isNull);
          expect(call.maxResults, equals(8));
        } finally {
          await shutDown();
        }
      });
    });

    // ── Empty chunk list is valid ─────────────────────────────────────

    test('empty chunk list returns 200 with empty chunks array', () async {
      await withRealHttp(() async {
        await spinUp();
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{
              'query_embedding': _zero1024(),
            },
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['chunks'], equals(const <Object?>[]));
        } finally {
          await shutDown();
        }
      });
    });
  });
}
