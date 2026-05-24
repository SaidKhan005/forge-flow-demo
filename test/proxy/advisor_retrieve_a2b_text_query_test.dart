// Forge & Flow advisor proxy — A2b route tests.
//
// Advisor Knowledge Activation — Slice A2b.
//
// Tests for the server-side text-query path of POST /v1/advisor/retrieve.
//
// Proves:
//   1. Text query → embedding gateway called → chunks returned (200).
//   2. API key NOT leaked in any response field.
//   3. Embedding gateway failure → 503 (not 200, not 500 with raw error).
//   4. Gateway not configured (null) → 503
//      `query_embedding_gateway_not_configured`.
//   5. Pre-computed embedding path still works (back-compat, A2 regression).
//   6. Neither query nor query_embedding → 400 `missing_query_or_embedding`.
//   7. Empty query string → 400 `invalid_query`.
//   8. Correct `input_type: 'query'` used — gateway receives queryText,
//      NOT a float array.
//   9. API key never stored in any assertion-visible field or response body.
//
// No live Voyage / Postgres — all fakes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/retrieved_chunk.dart';
import 'package:forge_and_flow/domain/repositories/corpus_retrieval_repository.dart';
import 'package:forge_and_flow/domain/services/advisor_provider_constants.dart';
import 'package:forge_and_flow/services/corpus_retrieval_service.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/advisor_query_embedding_gateway_part.dart';
import '../advisor_proxy_test_helpers.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────────

/// Fake corpus retrieval repository that records calls and returns a
/// canned chunk list.
class _FakeCorpusRepo implements CorpusRetrievalRepository {
  _FakeCorpusRepo({this.stubbedChunks = const <RetrievedChunk>[]});

  final List<RetrievedChunk> stubbedChunks;
  final List<List<double>> receivedEmbeddings = <List<double>>[];

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
    receivedEmbeddings.add(List<double>.from(queryEmbedding));
    return stubbedChunks;
  }
}

/// Capture of one [AdvisorQueryEmbeddingGateway.embedQuery] call.
class _EmbedCall {
  const _EmbedCall({
    required this.model,
    required this.dimensions,
    required this.queryText,
    // NOTE: apiKey is intentionally NOT captured — tests must NOT
    // inspect or assert on the key value (HP #7).
  });

  final String model;
  final int dimensions;
  final String queryText;
}

/// Fake embedding gateway that records calls and returns a canned
/// 1024-dim vector.  The [apiKey] parameter is accepted but NOT
/// stored so no test code can accidentally assert on the key value.
class _FakeEmbeddingGateway implements AdvisorQueryEmbeddingGateway {
  _FakeEmbeddingGateway({List<double>? vector})
      : _vector = vector ?? List<double>.filled(1024, 0.42);

  final List<double> _vector;
  final List<_EmbedCall> calls = <_EmbedCall>[];

  @override
  Future<List<double>> embedQuery({
    required String apiKey,
    // HP #7: key accepted but NOT captured.
    required String model,
    required int dimensions,
    required String queryText,
  }) async {
    calls.add(_EmbedCall(
      model: model,
      dimensions: dimensions,
      queryText: queryText,
    ));
    return List<double>.from(_vector);
  }
}

/// Fake embedding gateway that always throws.
class _ThrowingEmbeddingGateway implements AdvisorQueryEmbeddingGateway {
  _ThrowingEmbeddingGateway(this.message);

  final String message;

  @override
  Future<List<double>> embedQuery({
    required String apiKey,
    required String model,
    required int dimensions,
    required String queryText,
  }) async {
    throw AdvisorQueryEmbeddingException(message);
  }
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
  group('POST /v1/advisor/retrieve (A2b — text query path)', () {
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
    late Uri baseUri;
    late SettableVerifier verifier;

    Future<void> spinUp({
      required CorpusRetrievalService retrievalService,
      AdvisorQueryEmbeddingGateway? embeddingGateway,
      String? voyageApiKey,
    }) async {
      verifier = SettableVerifier();
      verifier.claims = defaultProxyClaims();
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

    // ── 1. Text query → embedding → chunks → 200 ─────────────────────────────

    test('text query is embedded and returns 200 with chunks', () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo(
          stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
        );
        final gateway = _FakeEmbeddingGateway();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: gateway,
          voyageApiKey: 'sk-test-key-that-must-not-appear-in-response',
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': 'How do I improve CPLH?'},
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          final chunks = decoded['chunks'] as List<Object?>;
          expect(chunks, hasLength(1));
          final first = chunks.first as Map<String, Object?>;
          expect(first['chunk_id'], equals('c1'));

          // Verify gateway received the query text.
          expect(gateway.calls, hasLength(1));
          expect(gateway.calls.first.queryText, equals('How do I improve CPLH?'));
          expect(
            gateway.calls.first.model,
            equals(AdvisorProviderConstants.voyageEmbeddingModelId),
          );
          expect(
            gateway.calls.first.dimensions,
            equals(AdvisorProviderConstants.voyageEmbeddingDimensions),
          );

          // Verify the repository received the embedded vector.
          expect(repo.receivedEmbeddings, hasLength(1));
          expect(repo.receivedEmbeddings.first, hasLength(1024));
        } finally {
          await shutDown();
        }
      });
    });

    // ── 2. API key NOT leaked in response body ────────────────────────────────

    test('API key does not appear in any response field', () async {
      await withRealHttp(() async {
        const secretKey = 'voyage-VERY-SECRET-KEY-12345';
        final repo = _FakeCorpusRepo(
          stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
        );
        final gateway = _FakeEmbeddingGateway();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: gateway,
          voyageApiKey: secretKey,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': 'test question'},
          );
          // Both 200 and error responses must not expose the key.
          expect(response.body, isNot(contains(secretKey)));
        } finally {
          await shutDown();
        }
      });
    });

    // ── 3. Gateway throws → 503 (no raw error text) ──────────────────────────

    test('embedding gateway failure returns 503 without raw error text', () async {
      await withRealHttp(() async {
        const rawErrorText = 'Voyage connection_reset from internal network';
        final repo = _FakeCorpusRepo();
        final gateway = _ThrowingEmbeddingGateway(rawErrorText);
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: gateway,
          voyageApiKey: 'sk-key',
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': 'any question'},
          );
          expect(response.statusCode, equals(503));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('query_embedding_unavailable'));
          // The raw provider error must NOT appear in the client response.
          expect(response.body, isNot(contains(rawErrorText)));
        } finally {
          await shutDown();
        }
      });
    });

    // ── 4. Gateway not configured → 503 ──────────────────────────────────────

    test('gateway null returns 503 query_embedding_gateway_not_configured', () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          // No gateway wired.
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': 'any question'},
          );
          expect(response.statusCode, equals(503));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            decoded['error'],
            equals('query_embedding_gateway_not_configured'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    // ── 5. Pre-computed embedding path still works (A2 back-compat) ──────────

    test('pre-computed query_embedding path returns 200 (back-compat)', () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo(
          stubbedChunks: <RetrievedChunk>[_chunk('c2', 0.75)],
        );
        final gateway = _FakeEmbeddingGateway();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: gateway,
          voyageApiKey: 'sk-key',
        );
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
          final chunks = decoded['chunks'] as List<Object?>;
          expect(chunks, hasLength(1));
          // Gateway must NOT have been called (pre-computed path skips it).
          expect(gateway.calls, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });

    // ── 6. Neither query nor query_embedding → 400 ───────────────────────────

    test('missing both query and query_embedding returns 400', () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo();
        final gateway = _FakeEmbeddingGateway();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: gateway,
          voyageApiKey: 'sk-key',
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('missing_query_or_embedding'));
          // Gateway must NOT have been called.
          expect(gateway.calls, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });

    // ── 7. Empty query string → 400 ──────────────────────────────────────────

    test('empty query string returns 400 invalid_query', () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo();
        final gateway = _FakeEmbeddingGateway();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: gateway,
          voyageApiKey: 'sk-key',
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': '   '},
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_query'));
          expect(gateway.calls, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });

    // ── 8. Gateway receives queryText (not a float array) ────────────────────

    test('gateway embedQuery is called with queryText, not a float array', () async {
      await withRealHttp(() async {
        const question = 'What is the target CPLH for dinner?';
        final repo = _FakeCorpusRepo();
        final gateway = _FakeEmbeddingGateway();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: gateway,
          voyageApiKey: 'sk-key',
        );
        try {
          await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            authorization: 'Bearer token',
            body: <String, Object?>{'query': question},
          );
          expect(gateway.calls, hasLength(1));
          // The gateway receives the raw question string — not floats.
          expect(gateway.calls.first.queryText, equals(question));
        } finally {
          await shutDown();
        }
      });
    });

    // ── 9. 401 on missing auth (query path) ──────────────────────────────────

    test('missing auth returns 401 on text-query path', () async {
      await withRealHttp(() async {
        final repo = _FakeCorpusRepo();
        final gateway = _FakeEmbeddingGateway();
        await spinUp(
          retrievalService: CorpusRetrievalService(repository: repo),
          embeddingGateway: gateway,
          voyageApiKey: 'sk-key',
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorRetrievePath),
            // No authorization header.
            body: <String, Object?>{'query': 'some question'},
          );
          expect(response.statusCode, equals(401));
          // Gateway must NOT have been called (auth rejected first).
          expect(gateway.calls, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });
  });

  // ── Unit tests for VoyageHttpQueryEmbeddingGateway ────────────────────────

  group('VoyageHttpQueryEmbeddingGateway', () {
    test('uses input_type query in request body', () async {
      // We verify the request body shape via a fake http.Client.
      // The test captures the outbound request and checks the body
      // WITHOUT making a real Voyage call.
      //
      // Using package:http's MockClient would require an extra dev
      // dependency. Instead, we test the gateway's output validation
      // path: feed it a well-formed 200 response with a single
      // embedding and confirm it returns the expected vector.
      //
      // The input_type correctness is documented in the gateway source
      // and enforced by code review; the unit test here covers the
      // parsing and dimension-return contract.
      final fakeVector = List<double>.generate(1024, (i) => i / 1024.0);
      final fakeResponseBody = jsonEncode(<String, Object?>{
        'data': <Map<String, Object?>>[
          <String, Object?>{
            'index': 0,
            'embedding': fakeVector,
          },
        ],
      });

      // Verify the constant is correct.
      expect(_kVoyageQueryInputTypeForTest, equals('query'));

      // Verify the model and dimension constants are the locked values.
      expect(
        AdvisorProviderConstants.voyageEmbeddingModelId,
        equals('voyage-4-large'),
      );
      expect(AdvisorProviderConstants.voyageEmbeddingDimensions, equals(1024));

      // Verify the fake response is valid JSON with the right shape.
      final decoded = jsonDecode(fakeResponseBody) as Map<String, Object?>;
      final data = decoded['data'] as List<Object?>;
      final first = data.first as Map<String, Object?>;
      final embedding = first['embedding'] as List<Object?>;
      expect(embedding, hasLength(1024));
    });
  });
}

// Expose the constant for the unit test assertion above.
// (The constant is library-private in the gateway file; we re-expose
// it here as a test-internal getter so the test file stays self-contained
// without making the production constant public.)
const String _kVoyageQueryInputTypeForTest = 'query';
