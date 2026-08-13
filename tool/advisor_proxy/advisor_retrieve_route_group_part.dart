// Forge & Flow advisor proxy — advisor retrieval route group.
//
// Advisor Knowledge Activation — Slice A2 (A2b extension).
//
// This part file exposes POST /v1/advisor/retrieve, which accepts either:
//   (a) a text `query` string (A2b): server-side Voyage embedding, then
//       [CorpusRetrievalService] vector search; OR
//   (b) a pre-computed `query_embedding` 1024-dim array (back-compat path
//       from Slice A2): passed directly to [CorpusRetrievalService].
//
// One of the two MUST be present; missing both returns 400.
//
// Ceiling-safe decomposition: ALL handler logic lives in this `part` file.
// The monolith (`advisor_proxy.dart`) gains one new optional parameter
// (`corpusQueryEmbeddingGateway`) in `routeRequest` — < 4 lines.
// No handler logic lives in the monolith. No `kAdvisorProxyMaxLines` raise.
//
// Route contract:
//   POST /v1/advisor/retrieve
//   Auth: standard operator JWT (requireOperatorContext).
//   Body (text-query path — A2b):
//     {
//       "query":       <non-empty string>,
//       "graph_scope"?:  "methodology"   (default: "methodology"),
//       "restaurant_id"?: <uuid-string|null>,
//       "max_results"?:  <int 1–100>     (default: 8)
//     }
//   Body (pre-computed embedding path — A2 back-compat):
//     {
//       "query_embedding": [<1024 floats>],
//       "graph_scope"?:  "methodology",
//       "restaurant_id"?: <uuid-string|null>,
//       "max_results"?:  <int 1–100>
//     }
//   200: { "chunks": [{ "chunk_id", "doc_id", "heading_path", "text",
//                        "similarity" }] }
//   400: standard error envelope (missing/invalid query or embedding)
//   401/403: standard auth envelope (missing/expired/wrong scope)
//   503: standard dependency-timeout envelope (gateway/service unavailable)
//
// HP #7: the Voyage API key is accepted by the route as a plain String,
// used in exactly one downstream call, and never returned to the client
// or captured in a log field.
//
// TODO(HP#9): increment the voyage usage counter for the embedding call.
//   The existing [ProxyUsageGuard] / [ProxyUsageCounterStore] is scoped
//   to LLM advisor requests (operator/location/tier). The query-embedding
//   call is a different cost class (Voyage tokens, not Anthropic tokens).
//   Wiring requires a separate counter lane or a new cost-class key in
//   `advisor_proxy_usage_counters`. This is left for a follow-up slice
//   (A2b.1 or the HP#9 dedicated pass) rather than implemented silently
//   with a no-op that would be invisible in the audit trail.

part of 'advisor_proxy.dart';

/// Route path constant for the corpus retrieval endpoint.
/// Exported so tests can reference the canonical string without
/// hardcoding it.
const String advisorRetrievePath = '/v1/advisor/retrieve';

/// Handler for POST [advisorRetrievePath].
///
/// Called from [routeRequest] after the standard operator-scope JWT has
/// been resolved. Supports two input paths:
///
///   1. **Text query (A2b):** body contains `"query": <string>`.  The
///      handler embeds it via [embeddingGateway] using the server-side
///      Voyage key ([voyageApiKey]).  [embeddingGateway] must be
///      non-null when this path is used.
///   2. **Pre-computed embedding (A2 back-compat):** body contains
///      `"query_embedding": [<1024 floats>]`.  Passed directly to
///      [retrievalService] — no API call.
///
/// HP #7: [voyageApiKey] is never logged or returned to the client.
Future<void> _handleAdvisorRetrieve({
  required HttpRequest request,
  required HttpResponse response,
  required Map<String, Object?> body,
  required CorpusRetrievalService retrievalService,
  AdvisorQueryEmbeddingGateway? embeddingGateway,
  String? voyageApiKey,
}) async {
  // ── Resolve the embedding (text query or pre-computed) ───────────────
  List<double> embedding;

  final rawQuery = body['query'];
  final rawEmbedding = body['query_embedding'];

  if (rawQuery != null) {
    // ── Path A: text query → server-side embedding (A2b) ──────────────
    if (rawQuery is! String || rawQuery.trim().isEmpty) {
      _writeJson(response, 400, const <String, Object?>{
        'error': 'invalid_query',
        'message':
            'query must be a non-empty string when provided',
      });
      return;
    }

    if (embeddingGateway == null || voyageApiKey == null) {
      _writeJson(response, 503, const <String, Object?>{
        'error': 'query_embedding_gateway_not_configured',
        'message':
            'server-side query embedding is not available; '
            'provide query_embedding instead',
      });
      return;
    }

    try {
      embedding = await embeddingGateway.embedQuery(
        // HP #7: key stays in the call stack, never logged or returned.
        apiKey: voyageApiKey,
        model: AdvisorProviderConstants.voyageEmbeddingModelId,
        dimensions: AdvisorProviderConstants.voyageEmbeddingDimensions,
        queryText: rawQuery.trim(),
      );
    } on AdvisorQueryEmbeddingException catch (e) {
      // Surface the exception message in the proxy log — it is safe
      // (no key, truncated provider error).  Return a typed 503 to
      // the caller; the full message is not client-visible.
      log(
        LogSeverity.warning,
        'advisor_retrieve.embedding_failed',
        fields: <String, Object?>{'message': e.message},
      );
      _writeJson(response, 503, const <String, Object?>{
        'error': 'query_embedding_unavailable',
        'message': 'could not embed query; please retry',
      });
      return;
    }

    // Dimension sanity check — Voyage should always return the
    // requested dimension, but guard defensively.
    if (embedding.length != AdvisorProviderConstants.voyageEmbeddingDimensions) {
      log(
        LogSeverity.warning,
        'advisor_retrieve.embedding_dimension_mismatch',
        fields: <String, Object?>{
          'expected': AdvisorProviderConstants.voyageEmbeddingDimensions,
          'received': embedding.length,
        },
      );
      _writeJson(response, 503, const <String, Object?>{
        'error': 'query_embedding_dimension_mismatch',
        'message':
            'embedding provider returned wrong dimension; please retry',
      });
      return;
    }
  } else if (rawEmbedding != null) {
    // ── Path B: pre-computed embedding (A2 back-compat) ───────────────
    if (rawEmbedding is! List) {
      _writeJson(response, 400, const <String, Object?>{
        'error': 'missing_query_embedding',
        'message': 'query_embedding is required and must be a JSON array',
      });
      return;
    }

    // Coerce each element to double. JSON numbers may arrive as int.
    final coerced = <double>[];
    for (final element in rawEmbedding) {
      if (element is num) {
        coerced.add(element.toDouble());
      } else {
        _writeJson(response, 400, const <String, Object?>{
          'error': 'invalid_query_embedding',
          'message': 'every element of query_embedding must be a number',
        });
        return;
      }
    }

    // Dimension check — CorpusRetrievalService also guards this, but
    // returning a structured 400 here before the service call gives the
    // caller a better error message than an unhandled ArgumentError.
    if (coerced.length != 1024) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'invalid_query_embedding_dimension',
        'message':
            'query_embedding must contain exactly 1024 floats '
            '(got ${coerced.length})',
        'expected_dimension': 1024,
        'received_dimension': coerced.length,
      });
      return;
    }

    embedding = coerced;
  } else {
    // ── Neither query nor query_embedding provided ─────────────────────
    _writeJson(response, 400, const <String, Object?>{
      'error': 'missing_query_or_embedding',
      'message':
          'provide either "query" (text, server-side embedding) or '
          '"query_embedding" (pre-computed 1024-dim array)',
    });
    return;
  }

  // ── Optional parameters with defaults ────────────────────────────────
  final graphScopeRaw = body['graph_scope'];
  final String graphScope;
  if (graphScopeRaw == null) {
    graphScope = 'methodology';
  } else if (graphScopeRaw is String && graphScopeRaw.trim().isNotEmpty) {
    graphScope = graphScopeRaw.trim();
  } else {
    _writeJson(response, 400, const <String, Object?>{
      'error': 'invalid_graph_scope',
      'message': 'graph_scope must be a non-empty string when provided',
    });
    return;
  }

  final restaurantIdRaw = body['restaurant_id'];
  final String? restaurantId;
  if (!body.containsKey('restaurant_id') || restaurantIdRaw == null) {
    restaurantId = null;
  } else if (restaurantIdRaw is String && restaurantIdRaw.trim().isNotEmpty) {
    restaurantId = restaurantIdRaw.trim();
  } else {
    _writeJson(response, 400, const <String, Object?>{
      'error': 'invalid_restaurant_id',
      'message':
          'restaurant_id must be a non-empty UUID string or null when provided',
    });
    return;
  }

  final maxResultsRaw = body['max_results'];
  final int maxResults;
  if (maxResultsRaw == null) {
    maxResults = 8;
  } else if (maxResultsRaw is int && maxResultsRaw >= 1) {
    maxResults = maxResultsRaw;
  } else if (maxResultsRaw is num && maxResultsRaw >= 1) {
    maxResults = maxResultsRaw.toInt();
  } else {
    _writeJson(response, 400, const <String, Object?>{
      'error': 'invalid_max_results',
      'message': 'max_results must be a positive integer when provided',
    });
    return;
  }

  // ── Delegate to service ───────────────────────────────────────────────
  final chunks = await retrievalService.retrieve(
    queryEmbedding: embedding,
    graphScope: graphScope,
    restaurantId: restaurantId,
    maxResults: maxResults,
  );

  _writeJson(response, 200, <String, Object?>{
    'chunks': <Map<String, Object?>>[
      for (final chunk in chunks)
        <String, Object?>{
          'chunk_id': chunk.chunkId,
          'doc_id': chunk.docId,
          'heading_path': chunk.headingPath,
          'text': chunk.text,
          'similarity': chunk.similarity,
        },
    ],
  });
}
