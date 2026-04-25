// Forge & Flow — VoyageEmbeddingProvider adapter.
//
// 7.57.3a foundation slice. Concrete `EmbeddingProvider` for Voyage's
// `voyage-4-large` retrieval model. The HTTP/SDK gateway is injected as
// a callback so tests can substitute fakes; this slice does not wire
// real-API gateways into production.

import '../domain/services/advisor_provider_constants.dart';
import '../domain/services/embedding_provider.dart';

/// Gateway signature: send `texts` to Voyage and receive vectors back
/// in the same order. Implementations are added in a later 7.57.3
/// sub-slice (HTTP/SDK gateway wiring is out of scope here).
typedef VoyageEmbedFn = Future<List<List<double>>> Function(
  List<String> texts, {
  required String model,
});

class VoyageEmbeddingProvider implements EmbeddingProvider {
  final VoyageEmbedFn _embedFn;

  VoyageEmbeddingProvider({required VoyageEmbedFn embedFn}) : _embedFn = embedFn;

  @override
  String get providerId => AdvisorProviderConstants.voyageProviderId;

  @override
  String get modelId => AdvisorProviderConstants.voyageEmbeddingModelId;

  @override
  int get dimensions => AdvisorProviderConstants.voyageEmbeddingDimensions;

  @override
  Future<List<double>> embed(String text) async {
    final batch = await _embedFn([text], model: modelId);
    if (batch.isEmpty) {
      throw StateError(
          'VoyageEmbeddingProvider: gateway returned empty batch for single embed');
    }
    final vector = batch.first;
    _assertDimensions(vector);
    return vector;
  }

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    final result = await _embedFn(texts, model: modelId);
    if (result.length != texts.length) {
      throw StateError(
          'VoyageEmbeddingProvider: gateway returned ${result.length} vectors '
          'for ${texts.length} inputs (must match 1:1).');
    }
    for (final v in result) {
      _assertDimensions(v);
    }
    return result;
  }

  void _assertDimensions(List<double> vector) {
    if (vector.length != dimensions) {
      throw StateError(
          'VoyageEmbeddingProvider: gateway returned ${vector.length}-dim '
          'vector; contract requires $dimensions dims for $modelId.');
    }
  }
}
