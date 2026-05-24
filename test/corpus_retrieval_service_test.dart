// Advisor Knowledge Activation — Slice A1.
// Unit tests for CorpusRetrievalService using a fake repository.
//
// Proves:
//   1. Locked filters (voyage / voyage-4-large / 1024) are forwarded
//      to the repository on every call.
//   2. Chunk ordering from the repository is preserved (most-similar
//      first).
//   3. maxResults is forwarded as-is; the SQL function handles capping.
//   4. An embedding with length != 1024 is rejected before the
//      repository is called.
//
// No network, no Postgres, no SharedPreferences.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/retrieved_chunk.dart';
import 'package:forge_and_flow/domain/repositories/corpus_retrieval_repository.dart';
import 'package:forge_and_flow/domain/services/advisor_provider_constants.dart';
import 'package:forge_and_flow/services/corpus_retrieval_service.dart';

// ── Fake repository ──────────────────────────────────────────────────────────

/// Capture of one [CorpusRetrievalRepository.searchChunks] call.
class _SearchCall {
  const _SearchCall({
    required this.queryEmbedding,
    required this.graphScope,
    required this.restaurantId,
    required this.providerId,
    required this.modelId,
    required this.dimension,
    required this.maxResults,
  });

  final List<double> queryEmbedding;
  final String graphScope;
  final String? restaurantId;
  final String providerId;
  final String modelId;
  final int dimension;
  final int maxResults;
}

/// Fake [CorpusRetrievalRepository] that records every call and returns
/// a canned list of [RetrievedChunk]s.
class _FakeCorpusRetrievalRepository implements CorpusRetrievalRepository {
  _FakeCorpusRetrievalRepository({required List<RetrievedChunk> stubbedResult})
      : _stubbedResult = stubbedResult;

  final List<RetrievedChunk> _stubbedResult;
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
        providerId: providerId,
        modelId: modelId,
        dimension: dimension,
        maxResults: maxResults,
      ),
    );
    return _stubbedResult;
  }
}

// ── Test helpers ─────────────────────────────────────────────────────────────

/// A valid 1024-dim zero embedding for use in tests that don't care
/// about embedding content.
List<double> _zero1024() => List<double>.filled(1024, 0.0);

/// Build a minimal [RetrievedChunk] for ordering tests.
RetrievedChunk _chunk(String id, double similarity) => RetrievedChunk(
      chunkId: id,
      docId: 'doc-$id',
      headingPath: const <String>[],
      text: 'text for $id',
      similarity: similarity,
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('CorpusRetrievalService', () {
    // ── Locked-filter forwarding ──────────────────────────────────────

    test('passes locked Voyage provider/model/dimension filters', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      await service.retrieve(queryEmbedding: _zero1024());

      expect(fakeRepo.calls, hasLength(1));
      final call = fakeRepo.calls.first;

      expect(
        call.providerId,
        AdvisorProviderConstants.voyageProviderId,
        reason: 'provider must be the locked voyage constant',
      );
      expect(
        call.modelId,
        AdvisorProviderConstants.voyageEmbeddingModelId,
        reason: 'model must be the locked voyage-4-large constant',
      );
      expect(
        call.dimension,
        AdvisorProviderConstants.voyageEmbeddingDimensions,
        reason: 'dimension must be the locked 1024 constant',
      );
    });

    test('default graphScope is methodology', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      await service.retrieve(queryEmbedding: _zero1024());

      expect(fakeRepo.calls.first.graphScope, 'methodology');
    });

    test('custom graphScope is forwarded', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      await service.retrieve(
        queryEmbedding: _zero1024(),
        graphScope: 'coaching',
      );

      expect(fakeRepo.calls.first.graphScope, 'coaching');
    });

    test('restaurantId is forwarded (null = global corpus)', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      await service.retrieve(
        queryEmbedding: _zero1024(),
        restaurantId: null,
      );

      expect(fakeRepo.calls.first.restaurantId, isNull);
    });

    test('restaurantId is forwarded when supplied', () async {
      const testId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      await service.retrieve(
        queryEmbedding: _zero1024(),
        restaurantId: testId,
      );

      expect(fakeRepo.calls.first.restaurantId, testId);
    });

    // ── maxResults forwarding ─────────────────────────────────────────

    test('default maxResults is 8', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      await service.retrieve(queryEmbedding: _zero1024());

      expect(fakeRepo.calls.first.maxResults, 8);
    });

    test('custom maxResults is forwarded', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      await service.retrieve(
        queryEmbedding: _zero1024(),
        maxResults: 20,
      );

      expect(fakeRepo.calls.first.maxResults, 20);
    });

    // ── Ordering preserved ────────────────────────────────────────────

    test('returns chunks in repository order (most-similar first)', () async {
      final ordered = <RetrievedChunk>[
        _chunk('c1', 0.95),
        _chunk('c2', 0.80),
        _chunk('c3', 0.70),
      ];
      final fakeRepo = _FakeCorpusRetrievalRepository(stubbedResult: ordered);
      final service = CorpusRetrievalService(repository: fakeRepo);

      final result = await service.retrieve(queryEmbedding: _zero1024());

      expect(result.length, 3);
      expect(result[0].chunkId, 'c1');
      expect(result[1].chunkId, 'c2');
      expect(result[2].chunkId, 'c3');
      // Verify descending similarity order.
      expect(result[0].similarity, greaterThan(result[1].similarity));
      expect(result[1].similarity, greaterThan(result[2].similarity));
    });

    test('empty repository result is returned as-is', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      final result = await service.retrieve(queryEmbedding: _zero1024());

      expect(result, isEmpty);
    });

    // ── Embedding dimension guard ─────────────────────────────────────

    test('throws ArgumentError for a too-short embedding', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      expect(
        () => service.retrieve(
          queryEmbedding: List<double>.filled(512, 0.0),
        ),
        throwsArgumentError,
      );
      // Repository must NOT be called when the guard fires.
      expect(fakeRepo.calls, isEmpty);
    });

    test('throws ArgumentError for an empty embedding', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      expect(
        () => service.retrieve(queryEmbedding: const <double>[]),
        throwsArgumentError,
      );
      expect(fakeRepo.calls, isEmpty);
    });

    test('throws ArgumentError for a too-long embedding', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      expect(
        () => service.retrieve(
          queryEmbedding: List<double>.filled(2048, 0.0),
        ),
        throwsArgumentError,
      );
      expect(fakeRepo.calls, isEmpty);
    });

    test('accepts exactly 1024-dim embedding without throwing', () async {
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      // Must complete without error.
      await expectLater(
        service.retrieve(queryEmbedding: _zero1024()),
        completes,
      );
      expect(fakeRepo.calls, hasLength(1));
    });

    // ── queryEmbedding forwarded unchanged ───────────────────────────

    test('forwards the exact queryEmbedding list to the repository', () async {
      final embedding = List<double>.generate(1024, (i) => i * 0.001);
      final fakeRepo = _FakeCorpusRetrievalRepository(
        stubbedResult: const <RetrievedChunk>[],
      );
      final service = CorpusRetrievalService(repository: fakeRepo);

      await service.retrieve(queryEmbedding: embedding);

      expect(fakeRepo.calls.first.queryEmbedding, same(embedding));
    });
  });
}
