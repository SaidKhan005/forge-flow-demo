// Advisor Knowledge Activation — Slice A4.2a.
//
// FAKES-ONLY unit tests for the `retrieve_methodology` answer tool
// (`advisor_answer_tools_part.dart`): the factory
// `buildAdvisorRetrieveMethodologyTool` and its handler, which wraps the
// shared embed -> search -> rerank pipeline.
//
// No live Voyage / Postgres — a fake embedding gateway, a fake rerank
// gateway, and a fake `CorpusRetrievalRepository` (driving a REAL
// `CorpusRetrievalService`) stand in for every dependency.
//
// Pins:
//   (a) a successful retrieval returns a `sources` array that maps each
//       RetrievedChunk -> {source_id, doc_id, title, snippet, similarity}
//       correctly (the keys the agentic engine cites from);
//   (b) the long chunk body is truncated to the snippet cap with an
//       ellipsis;
//   (c) the Voyage embed + rerank keys are NEVER echoed anywhere in the
//       result (HP #7);
//   (d) an ABSENT embedding gateway -> graceful {found:false, sources:[]}
//       envelope (NOT a thrown error);
//   (e) an absent Voyage key -> same graceful envelope;
//   (f) zero chunks -> graceful {found:false} envelope;
//   (g) an embedding-gateway FAILURE -> graceful {found:false} envelope
//       (degrades, never throws);
//   (h) the tool catalog shape (name + required `query`, optional
//       `max_results` / `restaurant_id`).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/retrieved_chunk.dart';
import 'package:forge_and_flow/domain/repositories/corpus_retrieval_repository.dart';
import 'package:forge_and_flow/domain/services/rerank_provider.dart';
import 'package:forge_and_flow/services/corpus_retrieval_service.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────────

/// Fake corpus retrieval repository. Records the requested `maxResults`
/// (so a test can assert the larger rerank pool is fetched) and the
/// embedding it received, and returns a canned chunk list.
class _FakeCorpusRepo implements CorpusRetrievalRepository {
  _FakeCorpusRepo({this.stubbedChunks = const <RetrievedChunk>[]});

  final List<RetrievedChunk> stubbedChunks;
  final List<int> receivedMaxResults = <int>[];
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
    receivedMaxResults.add(maxResults);
    receivedEmbeddings.add(List<double>.from(queryEmbedding));
    return stubbedChunks;
  }
}

/// Fake embedding gateway. Returns a canned 1024-dim vector + a token
/// count. HP #7: apiKey accepted but NOT stored, so no test can assert on
/// the key value.
class _FakeEmbeddingGateway implements AdvisorQueryEmbeddingGateway {
  final List<String> receivedQueries = <String>[];

  @override
  Future<AdvisorQueryEmbeddingResult> embedQuery({
    required String apiKey,
    required String model,
    required int dimensions,
    required String queryText,
  }) async {
    receivedQueries.add(queryText);
    return AdvisorQueryEmbeddingResult(
      embedding: List<double>.filled(1024, 0.42),
      // Token count is not asserted by these tests (metering is not wired
      // into the tool's tests); a fixed value keeps the fake simple.
      totalTokens: 7,
    );
  }
}

/// Embedding gateway that always throws — proves the tool degrades
/// gracefully instead of surfacing the exception (or the key).
class _ThrowingEmbeddingGateway implements AdvisorQueryEmbeddingGateway {
  _ThrowingEmbeddingGateway(this.message);
  final String message;

  @override
  Future<AdvisorQueryEmbeddingResult> embedQuery({
    required String apiKey,
    required String model,
    required int dimensions,
    required String queryText,
  }) async {
    throw AdvisorQueryEmbeddingException(message);
  }
}

/// Fake rerank gateway. Reorders candidates by a caller-supplied
/// `scoreById` map (higher = better). HP #7: apiKey accepted but NOT
/// stored.
class _FakeRerankGateway implements AdvisorRerankGateway {
  _FakeRerankGateway({required this.scoreById});

  final Map<String, double> scoreById;
  final List<String> receivedQueries = <String>[];

  @override
  Future<AdvisorRerankResult> rerank({
    required String apiKey,
    required String model,
    required String queryText,
    required List<RerankCandidate> candidates,
    int? topK,
  }) async {
    receivedQueries.add(queryText);
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
    // Token count is not asserted by these tests (metering is not wired
    // into the tool's tests); a fixed value keeps the fake simple.
    return AdvisorRerankResult(ranking: ranking, totalTokens: 0);
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────────────

RetrievedChunk _chunk(
  String id,
  double sim, {
  List<String> headingPath = const <String>['Methodology', 'CPLH'],
  String? text,
}) =>
    RetrievedChunk(
      chunkId: id,
      docId: 'doc-$id',
      headingPath: headingPath,
      text: text ?? 'methodology text for $id',
      similarity: sim,
    );

/// Builds the tool with the supplied (fake) deps. A real
/// [CorpusRetrievalService] is driven by the fake repo.
AdvisorRetrieveMethodologyTool _build({
  required _FakeCorpusRepo repo,
  AdvisorQueryEmbeddingGateway? embeddingGateway = const _AbsentSentinel(),
  String? voyageApiKey = 'sk-embed-secret',
  AdvisorRerankGateway? rerankGateway,
  String? voyageRerankApiKey,
}) {
  // `const _AbsentSentinel()` is the "use a default fake" marker; callers
  // pass `null` explicitly to exercise the absent-gateway degrade.
  final gateway = embeddingGateway is _AbsentSentinel
      ? _FakeEmbeddingGateway()
      : embeddingGateway;
  return buildAdvisorRetrieveMethodologyTool(
    retrievalService: CorpusRetrievalService(repository: repo),
    embeddingGateway: gateway,
    voyageApiKey: voyageApiKey,
    rerankGateway: rerankGateway,
    voyageRerankApiKey: voyageRerankApiKey,
  );
}

/// Sentinel so `_build` can tell "use the default fake gateway" apart from
/// an explicit `null` (absent gateway). Implements the gateway interface
/// only so it can sit in the parameter's type; it is never called.
class _AbsentSentinel implements AdvisorQueryEmbeddingGateway {
  const _AbsentSentinel();
  @override
  Future<AdvisorQueryEmbeddingResult> embedQuery({
    required String apiKey,
    required String model,
    required int dimensions,
    required String queryText,
  }) =>
      throw UnimplementedError();
}

void main() {
  group('buildAdvisorRetrieveMethodologyTool — catalog', () {
    test('(h) exposes the retrieve_methodology tool with the right schema',
        () {
      final tool = _build(repo: _FakeCorpusRepo());

      expect(tool.definition.name, equals('retrieve_methodology'));
      expect(tool.definition.name, equals(advisorToolRetrieveMethodology));

      // HP #6: a read tool name, no write/mutation verb.
      for (final verb in const <String>[
        'set',
        'update',
        'create',
        'delete',
        'write',
        'apply',
        'change',
      ]) {
        expect(tool.definition.name.contains(verb), isFalse,
            reason: 'name contains $verb');
      }

      final schema = tool.definition.inputSchema;
      expect(schema['type'], equals('object'));
      final props = schema['properties'] as Map<String, Object?>;
      expect(props.keys.toSet(),
          equals(<String>{'query', 'max_results', 'restaurant_id'}));
      expect(schema['required'], equals(<String>['query']));
      expect(schema['additionalProperties'], isFalse);
    });
  });

  group('retrieve_methodology handler — success', () {
    test('(a) maps each chunk to a source_id/doc_id/title/snippet/similarity',
        () async {
      final repo = _FakeCorpusRepo(
        stubbedChunks: <RetrievedChunk>[
          _chunk('c1', 0.91,
              headingPath: <String>['Labor', 'CPLH'], text: 'how CPLH works'),
          _chunk('c2', 0.82,
              headingPath: <String>['Sales', 'PPA'], text: 'how PPA works'),
        ],
      );
      final tool = _build(repo: repo);

      final result = await tool.handler(<String, Object?>{
        'query': 'how is CPLH calculated?',
      });

      expect(result['found'], isTrue);
      expect(result['result_count'], equals(2));

      final sources = result['sources'] as List<Object?>;
      expect(sources, hasLength(2));

      final s1 = sources[0] as Map<String, Object?>;
      expect(s1['source_id'], equals('c1'));
      expect(s1['doc_id'], equals('doc-c1'));
      // heading_path joined with ' > ' becomes the citation title.
      expect(s1['title'], equals('Labor > CPLH'));
      expect(s1['snippet'], equals('how CPLH works'));
      expect(s1['similarity'], equals(0.91));

      final s2 = sources[1] as Map<String, Object?>;
      expect(s2['source_id'], equals('c2'));
      expect(s2['title'], equals('Sales > PPA'));

      // The query text reached the embedding gateway (it was embedded).
      expect(repo.receivedEmbeddings, hasLength(1));
      expect(repo.receivedEmbeddings.first, hasLength(1024));
    });

    test('(b) a long chunk body is truncated to the snippet cap + ellipsis',
        () async {
      final longText = 'x' * 1000;
      final repo = _FakeCorpusRepo(
        stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9, text: longText)],
      );
      final tool = _build(repo: repo);

      final result = await tool.handler(<String, Object?>{'query': 'q'});
      final sources = result['sources'] as List<Object?>;
      final snippet = (sources.single as Map<String, Object?>)['snippet'] as String;

      // Capped to kAdvisorRetrieveMethodologySnippetMaxChars chars + '...'.
      expect(snippet.length,
          equals(kAdvisorRetrieveMethodologySnippetMaxChars + 3));
      expect(snippet.endsWith('...'), isTrue);
      expect(
        snippet.substring(0, kAdvisorRetrieveMethodologySnippetMaxChars),
        equals('x' * kAdvisorRetrieveMethodologySnippetMaxChars),
      );
    });

    test('(a) reranking reorders the sources by rerank score', () async {
      // Vector order c1(0.9) > c2(0.8) > c3(0.7); reranker flips it.
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
      final tool = _build(
        repo: repo,
        rerankGateway: rerank,
        voyageRerankApiKey: 'sk-rerank-secret',
      );

      final result = await tool.handler(<String, Object?>{
        'query': 'how is CPLH calculated?',
        'max_results': 3,
      });

      final ids = <String>[
        for (final s in (result['sources'] as List<Object?>))
          (s as Map<String, Object?>)['source_id'] as String,
      ];
      expect(ids, equals(<String>['c3', 'c2', 'c1']));
      // Rerank saw the query text.
      expect(rerank.receivedQueries, equals(<String>['how is CPLH calculated?']));
      // A larger candidate pool was fetched: clamp(max(3*4,20)) = 20.
      expect(repo.receivedMaxResults.first, equals(20));
    });
  });

  group('retrieve_methodology handler — HP #7 key never echoed', () {
    test('(c) neither the embed key nor the rerank key appears in the result',
        () async {
      const embedKey = 'voyage-EMBED-SECRET-KEY-12345';
      const rerankKey = 'voyage-RERANK-SECRET-KEY-67890';
      final repo = _FakeCorpusRepo(
        stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
      );
      final rerank =
          _FakeRerankGateway(scoreById: <String, double>{'c1': 1.0});
      final tool = _build(
        repo: repo,
        voyageApiKey: embedKey,
        rerankGateway: rerank,
        voyageRerankApiKey: rerankKey,
      );

      final result = await tool.handler(<String, Object?>{'query': 'q'});

      // Serialize the WHOLE result and assert neither key is anywhere in it.
      final encoded = jsonEncode(result);
      expect(encoded, isNot(contains(embedKey)));
      expect(encoded, isNot(contains(rerankKey)));
    });
  });

  group('retrieve_methodology handler — graceful degrade (no fabrication)',
      () {
    Future<void> expectUnavailable(Map<String, Object?> result) async {
      expect(result['found'], isFalse);
      expect(result['sources'], isEmpty);
      expect(result['message'], equals(kAdvisorMethodologyUnavailableMessage));
      expect(result['message'], equals('methodology search unavailable'));
    }

    test('(d) absent embedding gateway -> {found:false}, no throw', () async {
      final repo = _FakeCorpusRepo(
        stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
      );
      final tool = _build(repo: repo, embeddingGateway: null);

      final result = await tool.handler(<String, Object?>{'query': 'q'});
      await expectUnavailable(result);
      // Pipeline short-circuited before retrieval ran.
      expect(repo.receivedEmbeddings, isEmpty);
    });

    test('(e) absent Voyage key -> {found:false}, no throw', () async {
      final repo = _FakeCorpusRepo(
        stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
      );
      final tool = _build(repo: repo, voyageApiKey: null);

      final result = await tool.handler(<String, Object?>{'query': 'q'});
      await expectUnavailable(result);
    });

    test('(f) zero chunks -> {found:false}', () async {
      final repo = _FakeCorpusRepo(); // no chunks
      final tool = _build(repo: repo);

      final result = await tool.handler(<String, Object?>{'query': 'q'});
      await expectUnavailable(result);
    });

    test('(g) embedding-gateway failure -> {found:false}, no throw', () async {
      const rawError = 'Voyage connection_reset internal detail';
      final repo = _FakeCorpusRepo(
        stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
      );
      final tool = buildAdvisorRetrieveMethodologyTool(
        retrievalService: CorpusRetrievalService(repository: repo),
        embeddingGateway: _ThrowingEmbeddingGateway(rawError),
        voyageApiKey: 'sk-embed-secret',
      );

      final result = await tool.handler(<String, Object?>{'query': 'q'});
      await expectUnavailable(result);
      // The raw provider error must not leak into the tool result.
      expect(jsonEncode(result), isNot(contains(rawError)));
    });

    test('blank / missing query -> {found:false} without embedding', () async {
      final repo = _FakeCorpusRepo(
        stubbedChunks: <RetrievedChunk>[_chunk('c1', 0.9)],
      );
      final tool = _build(repo: repo);

      final blank = await tool.handler(<String, Object?>{'query': '   '});
      await expectUnavailable(blank);

      final missing = await tool.handler(const <String, Object?>{});
      await expectUnavailable(missing);

      // Never embedded a blank/absent query.
      expect(repo.receivedEmbeddings, isEmpty);
    });
  });
}
