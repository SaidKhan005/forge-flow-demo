// Forge & Flow — advisor response cache interface.
//
// Lock 7 secondary fallback. v1 ships `AlwaysMissAdvisorResponseCache`
// (always returns null); a real impl backed by `query_response_cache`
// or an in-memory LRU lands with E.2b alongside the Gemini secondary.
// The interface is real so E.2b is a swap-in, not a rewrite.

abstract class AdvisorResponseCache {
  Future<String?> lookup({
    required String operatorId,
    required String locationId,
    required String queryClass,
    required String questionHash,
    required String corpusVersion,
  });
}

class AlwaysMissAdvisorResponseCache implements AdvisorResponseCache {
  const AlwaysMissAdvisorResponseCache();

  @override
  Future<String?> lookup({
    required String operatorId,
    required String locationId,
    required String queryClass,
    required String questionHash,
    required String corpusVersion,
  }) async => null;
}
