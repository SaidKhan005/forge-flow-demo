// Forge & Flow advisor proxy — advisor retrieval route group.
//
// Advisor Knowledge Activation — Slice A2.
//
// This part file exposes POST /v1/advisor/retrieve, which accepts a
// pre-computed 1024-dim query embedding and returns the top-K corpus
// chunks by cosine similarity. It delegates to [CorpusRetrievalService]
// (Slice A1) and [PostgresCorpusRetrievalRepository] for the actual SQL
// call — no additional DB connections are opened here.
//
// Ceiling-safe decomposition: ALL handler logic lives in this `part` file.
// The monolith (`advisor_proxy.dart`) gains exactly two lines:
//   1. `part 'advisor_retrieve_route_group_part.dart';`  (beside line 325)
//   2. A minimal path-match + dispatch in `routeRequest` (before the
//      final 404 fallthrough).
// No handler logic lives in the monolith. No `kAdvisorProxyMaxLines` raise.
//
// Route contract:
//   POST /v1/advisor/retrieve
//   Auth: standard operator JWT (requireOperatorContext).
//   Body: {
//     "query_embedding": [<1024 floats>],
//     "graph_scope"?:  "methodology"   (default: "methodology"),
//     "restaurant_id"?: <uuid-string|null>,
//     "max_results"?:  <int 1–100>     (default: 8)
//   }
//   200: { "chunks": [{ "chunk_id", "doc_id", "heading_path", "text",
//                        "similarity" }] }
//   400: standard error envelope (missing/invalid embedding, wrong length)
//   401/403: standard auth envelope (missing/expired/wrong scope)
//   503: standard dependency-timeout envelope
//
// Read-only retrieval only. No writes, no rerank (A3), no answer
// generation (A4), no server-side text→embedding (A2b).

part of 'advisor_proxy.dart';

/// Route path constant for the corpus retrieval endpoint.
/// Exported so tests can reference the canonical string without
/// hardcoding it.
const String advisorRetrievePath = '/v1/advisor/retrieve';

/// Handler for POST [advisorRetrievePath].
///
/// Called from [routeRequest] after the standard operator-scope JWT has
/// been resolved. The repository is constructed from the shared
/// [tenantWrapper] injected via the [CorpusRetrievalService] parameter —
/// no new DB connection is opened.
///
/// Validation is intentionally minimal here: the embedding-length guard
/// is owned by [CorpusRetrievalService] (throws [ArgumentError] on
/// wrong dimension). This function validates the raw JSON shape only
/// (presence and list-of-number constraints).
Future<void> _handleAdvisorRetrieve({
  required HttpRequest request,
  required HttpResponse response,
  required Map<String, Object?> body,
  required CorpusRetrievalService retrievalService,
}) async {
  // ── Validate query_embedding ─────────────────────────────────────────
  final rawEmbedding = body['query_embedding'];
  if (rawEmbedding is! List) {
    _writeJson(response, 400, const <String, Object?>{
      'error': 'missing_query_embedding',
      'message': 'query_embedding is required and must be a JSON array',
    });
    return;
  }

  // Coerce each element to double. JSON numbers may arrive as int.
  final embedding = <double>[];
  for (final element in rawEmbedding) {
    if (element is num) {
      embedding.add(element.toDouble());
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
  if (embedding.length != 1024) {
    _writeJson(response, 400, <String, Object?>{
      'error': 'invalid_query_embedding_dimension',
      'message':
          'query_embedding must contain exactly 1024 floats '
          '(got ${embedding.length})',
      'expected_dimension': 1024,
      'received_dimension': embedding.length,
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
