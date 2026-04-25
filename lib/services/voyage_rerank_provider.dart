// Forge & Flow — VoyageRerankProvider adapter.
//
// 7.57.3a foundation slice. Concrete `RerankProvider` for Voyage's
// `rerank-2.5` model. The HTTP/SDK gateway is injected as a callback so
// tests can substitute fakes; this slice does not wire real-API
// gateways into production.

import '../domain/services/advisor_provider_constants.dart';
import '../domain/services/rerank_provider.dart';

/// Gateway signature: send `query` + `candidates` to Voyage and receive
/// raw `(id, score)` pairs back. Pair ordering is not contractual — the
/// adapter sorts by score descending before returning [RerankResult]s.
typedef VoyageRerankFn = Future<List<({String id, double score})>> Function({
  required String query,
  required List<RerankCandidate> candidates,
  required String model,
});

class VoyageRerankProvider implements RerankProvider {
  final VoyageRerankFn _rerankFn;

  VoyageRerankProvider({required VoyageRerankFn rerankFn}) : _rerankFn = rerankFn;

  @override
  String get providerId => AdvisorProviderConstants.voyageProviderId;

  @override
  String get modelId => AdvisorProviderConstants.voyageRerankModelId;

  @override
  Future<List<RerankResult>> rerank(
    String query,
    List<RerankCandidate> candidates,
  ) async {
    if (candidates.isEmpty) return const <RerankResult>[];

    final raw = await _rerankFn(
      query: query,
      candidates: candidates,
      model: modelId,
    );

    if (raw.length != candidates.length) {
      throw StateError(
          'VoyageRerankProvider: gateway returned ${raw.length} scores for '
          '${candidates.length} candidates (must match 1:1).');
    }

    final candidateIds = candidates.map((c) => c.id).toSet();
    for (final pair in raw) {
      if (!candidateIds.contains(pair.id)) {
        throw StateError(
            'VoyageRerankProvider: gateway returned unknown id ${pair.id}.');
      }
    }

    final sorted = [...raw]..sort((a, b) => b.score.compareTo(a.score));
    return [
      for (var i = 0; i < sorted.length; i++)
        RerankResult(id: sorted[i].id, score: sorted[i].score, rank: i),
    ];
  }
}
