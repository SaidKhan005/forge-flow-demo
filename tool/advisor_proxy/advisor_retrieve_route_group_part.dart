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
// HP #9 (AI cost metered by class) — Slice A2b.1: the server-side Voyage
// embedding call on the TEXT-QUERY path is now metered as its own cost
// class. It reuses the SAME infrastructure the metered Anthropic LLM
// route uses (HP #8: no parallel stack) — the [ProxyUsageGuard] cap-check
// (`requireAllowed` → `recordAllowed`) plus the [ProxyAccountingStore]
// `usage_logs` rollup (`commitUsageLog`) — but under a DISTINCT
// `usage_class` ([kVoyageQueryEmbeddingUsageClass] = 'voyage_query_embedding').
// Cost is computed from the ACTUAL Voyage-returned token count via the
// Voyage rate in [LlmCostRateRegistry]. `usage_class` is a free-form text
// column, so no migration is required. Both the guard and the accounting
// store are OPTIONAL (null in tests / scaffolds): when unwired the route
// behaves exactly as before (no metering, no cap-check), so existing A2/A2b
// callers stay byte-compatible. The pre-computed-embedding (A2 back-compat)
// path performs NO provider call and therefore records NO Voyage cost.

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
///
/// HP #9 metering (text-query path only): when both [operator] and
/// [accountingStore] are supplied, the server-side Voyage embedding spend
/// is recorded under [kVoyageQueryEmbeddingUsageClass] via the SAME
/// accounting path the Anthropic LLM route uses. When [usageGuard] is also
/// supplied, the operator's per-minute / monthly caps are checked BEFORE
/// the Voyage call so an over-budget operator is refused consistently with
/// LLM calls. All three are OPTIONAL — when null (tests / scaffolds) the
/// route runs unmetered exactly as the A2/A2b baseline did.
Future<void> _handleAdvisorRetrieve({
  required HttpRequest request,
  required HttpResponse response,
  required Map<String, Object?> body,
  required CorpusRetrievalService retrievalService,
  AdvisorQueryEmbeddingGateway? embeddingGateway,
  String? voyageApiKey,
  // Slice A3 — OPTIONAL server-side rerank gateway + its key. When both are
  // wired (production) the TEXT-QUERY path fetches a larger candidate pool,
  // reranks it against the query text via Voyage `rerank-2.5`, and returns
  // the top max_results reordered by rerank score. When [rerankGateway] is
  // null (tests/scaffold) OR no candidates come back, behavior is UNCHANGED
  // (A2b vector-only order) — full back-compat. HP #7: [voyageRerankApiKey]
  // is never logged or returned to the client. The PRE-COMPUTED-embedding
  // path has no query text, so it CANNOT rerank and stays vector-only.
  AdvisorRerankGateway? rerankGateway,
  String? voyageRerankApiKey,
  // HP #9 metering handles — threaded from the dispatch site in
  // [routeRequest] after the operator JWT has been resolved. Optional so
  // existing tests that drive the route without the accounting stack keep
  // working unchanged.
  OperatorContext? operator,
  ProxyUsageGuard? usageGuard,
  ProxyAccountingStore? accountingStore,
  DateTime Function()? clock,
}) async {
  // ── Resolve the embedding (text query or pre-computed) ───────────────
  List<double> embedding;

  final rawQuery = body['query'];
  final rawEmbedding = body['query_embedding'];

  // Slice A3 — the trimmed query text, captured on the text-query path so
  // the rerank step (after max_results is parsed) can score candidates
  // against it. Stays null on the pre-computed-embedding path, which by
  // construction has no query text and therefore cannot rerank.
  String? rerankQueryText;

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

    final trimmedQuery = rawQuery.trim();
    // Slice A3 — remember the query text for the rerank step further down.
    rerankQueryText = trimmedQuery;

    // ── HP #9 cap-check BEFORE the provider call ──────────────────────
    // Estimate input tokens (Voyage bills input tokens only). ceil(chars/4)
    // is the standard heuristic the proxy uses elsewhere for pre-call
    // estimation; the ACTUAL provider-returned token count drives the
    // recorded cost below. The estimate only gates the cap-check so an
    // over-budget operator is refused consistently with LLM calls. The
    // guard is OPTIONAL — when unwired (tests/scaffold) no cap-check runs,
    // exactly as the LLM smoke route behaves with `usageGuard == null`.
    final estimatedInputTokens = (trimmedQuery.length + 3) ~/ 4;
    UsageDecisionAllowed? voyageUsageDecision;
    if (usageGuard != null && operator != null) {
      try {
        voyageUsageDecision = await usageGuard.requireAllowed(
          operator: operator,
          estimate: UsageEstimate(requestTokens: estimatedInputTokens),
        );
      } on UsageRefusal catch (refusal) {
        // Same refusal envelope the metered LLM route returns, so an
        // over-budget operator gets a consistent 402/429/413/503.
        _writeJson(response, refusal.statusCode, refusal.toJson());
        return;
      }
    }

    final AdvisorQueryEmbeddingResult embeddingResult;
    try {
      embeddingResult = await embeddingGateway.embedQuery(
        // HP #7: key stays in the call stack, never logged or returned.
        apiKey: voyageApiKey,
        model: AdvisorProviderConstants.voyageEmbeddingModelId,
        dimensions: AdvisorProviderConstants.voyageEmbeddingDimensions,
        queryText: trimmedQuery,
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

    embedding = embeddingResult.embedding;

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

    // ── HP #9 record the Voyage spend AFTER a successful call ─────────
    // Cost is computed from the ACTUAL provider-returned token count via
    // the Voyage rate, NOT a hardcoded constant. Recorded under the
    // distinct `voyage_query_embedding` usage class, attributed to the
    // caller's operator_id/location_id, through the SAME accounting path
    // the Anthropic answer uses (HP #8: no parallel stack). Both writes
    // mirror the LLM route: `commitUsageLog` rolls up `usage_logs`, and
    // `recordAllowed` advances `advisor_proxy_usage_counters` so the next
    // request's cap-check sees this spend. Metering only runs when the
    // accounting store is wired (production); tests/scaffolds skip it.
    if (accountingStore != null && operator != null) {
      final voyageRate = LlmCostRateRegistry.rateFor(
        AdvisorProviderConstants.voyageEmbeddingModelId,
      );
      // Embeddings bill input tokens only → outputTokens: 0. Unknown model
      // (rate == null) charges 0, preserving the registry's fail-open
      // contract; the Voyage model is registered so this resolves to the
      // 12 cents/MTok rate in practice.
      final voyageCostCents = voyageRate == null
          ? 0
          : voyageRate.costCentsFor(
              inputTokens: embeddingResult.totalTokens,
              outputTokens: 0,
            );
      final voyageClock = clock ?? DateTime.now;
      await accountingStore.commitUsageLog(
        operator: operator,
        usageClass: kVoyageQueryEmbeddingUsageClass,
        telemetry: ProxyUsageTelemetry(
          // Fixed query-class label for the embedding cost class. NOT the
          // request's graph_scope (which is parsed later and may yet 400):
          // the Voyage tokens are already spent the moment embedQuery
          // succeeds, so the spend is recorded here regardless.
          queryClass: 'query_embedding',
          cacheHit: false,
          // llmTier/modelUsed carry the Voyage provider+model for this
          // cost class — these are telemetry dims on the usage_logs row,
          // not an Anthropic tier. HP #7: no key, only the public model id.
          llmTier: AdvisorProviderConstants.voyageProviderId,
          modelUsed: AdvisorProviderConstants.voyageEmbeddingModelId,
        ),
        estimate: ProxyUsageChargeEstimate(
          tokenCount: embeddingResult.totalTokens,
          costCents: voyageCostCents,
        ),
        now: voyageClock().toUtc(),
      );
      // Advance the per-minute / monthly counters with the actual cost so
      // the next cap-check reflects this spend. Only when the guard ran a
      // cap-check above (so we hold a decision to record against).
      if (usageGuard != null && voyageUsageDecision != null) {
        await usageGuard.recordAllowed(
          operator: operator,
          decision: voyageUsageDecision,
          costCentsToAdd: voyageCostCents,
        );
      }
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

  // ── Decide whether the rerank step is active ──────────────────────────
  // Slice A3 — rerank runs ONLY when (a) a rerank gateway is wired,
  // (b) its key is present, and (c) we are on the text-query path (so we
  // have the query text to score against). The pre-computed-embedding path
  // leaves [rerankQueryText] null and therefore stays vector-only — it has
  // no query text, so there is nothing to feed the cross-encoder. When any
  // condition is unmet the route behaves exactly as the A2b baseline.
  final rerankActive = rerankGateway != null &&
      voyageRerankApiKey != null &&
      rerankQueryText != null;

  // ── Delegate to service ───────────────────────────────────────────────
  // When reranking, pull a LARGER candidate pool so the cross-encoder has
  // more than the final K to choose from; the pool is bounded to keep the
  // rerank token cost (and latency) predictable. Pool size mirrors the
  // plan: clamp(max(maxResults*4, 20), .., 100). When NOT reranking, fetch
  // exactly maxResults (unchanged A2b behavior).
  final int retrieveCount;
  if (rerankActive) {
    final pool = maxResults * 4;
    retrieveCount = pool < 20
        ? 20
        : pool > 100
            ? 100
            : pool;
  } else {
    retrieveCount = maxResults;
  }

  final chunks = await retrievalService.retrieve(
    queryEmbedding: embedding,
    graphScope: graphScope,
    restaurantId: restaurantId,
    maxResults: retrieveCount,
  );

  // ── Optional rerank reordering (text-query path, gateway wired) ───────
  // Reorder the candidate pool by Voyage rerank-2.5 relevance, then keep
  // the top maxResults. No candidates → nothing to rerank, fall through to
  // the vector-only order (which is already empty/short). HP #9: the rerank
  // spend is metered below from the ACTUAL returned token count.
  var orderedChunks = chunks;
  if (rerankActive && chunks.isNotEmpty) {
    final candidates = <RerankCandidate>[
      for (final chunk in chunks)
        RerankCandidate(id: chunk.chunkId, text: chunk.text),
    ];

    final AdvisorRerankResult rerankResult;
    try {
      rerankResult = await rerankGateway.rerank(
        // HP #7: key stays in the call stack, never logged or returned.
        apiKey: voyageRerankApiKey,
        model: AdvisorProviderConstants.voyageRerankModelId,
        queryText: rerankQueryText,
        candidates: candidates,
        // top_k is an optimization; we still re-clamp to maxResults below.
        topK: maxResults,
      );
    } on AdvisorRerankException catch (e) {
      // Surface the (safe, truncated) message in the proxy log; return a
      // typed 503 to the caller. The full provider error is not
      // client-visible and the key is never in the message.
      log(
        LogSeverity.warning,
        'advisor_retrieve.rerank_failed',
        fields: <String, Object?>{'message': e.message},
      );
      _writeJson(response, 503, const <String, Object?>{
        'error': 'rerank_unavailable',
        'message': 'could not rerank results; please retry',
      });
      return;
    }

    // Map chunk_id → chunk so we can emit the chunks in rerank order. The
    // provider already validated 1:1 + known-ids, so every ranked id is a
    // candidate we sent; the lookup cannot miss.
    final byId = <String, RetrievedChunk>{
      for (final chunk in chunks) chunk.chunkId: chunk,
    };
    final reordered = <RetrievedChunk>[
      for (final r in rerankResult.ranking)
        if (byId[r.id] != null) byId[r.id]!,
    ];
    // Keep the top maxResults after reordering.
    orderedChunks =
        reordered.length > maxResults ? reordered.sublist(0, maxResults) : reordered;

    // ── HP #9 record the Voyage rerank spend AFTER a successful call ──
    // A DISTINCT cost class from the embedding spend recorded above
    // (kVoyageRerankUsageClass = 'voyage_rerank'). Cost is computed from
    // the ACTUAL provider-returned token count via the Voyage rerank rate,
    // attributed to the caller's operator_id/location_id, through the SAME
    // accounting path the embedding + Anthropic answer use (HP #8: no
    // parallel stack). A single text-query request therefore records TWO
    // usage_logs rows — one embedding, one rerank — which is correct
    // (two distinct provider calls). Metering only runs when the
    // accounting store + operator are wired (production); tests/scaffolds
    // skip it. NOTE: no second cap-check/recordAllowed here — the cap-check
    // at the head of the text-query path gates the whole request; the
    // rerank cost is recorded to usage_logs for per-class attribution.
    if (accountingStore != null && operator != null) {
      final rerankRate = LlmCostRateRegistry.rateFor(
        AdvisorProviderConstants.voyageRerankModelId,
      );
      // Rerank bills total processed tokens as input → outputTokens: 0.
      // Unknown model (rate == null) charges 0, preserving the registry's
      // fail-open contract; rerank-2.5 is registered so this resolves to
      // the 5 cents/MTok rate in practice.
      final rerankCostCents = rerankRate == null
          ? 0
          : rerankRate.costCentsFor(
              inputTokens: rerankResult.totalTokens,
              outputTokens: 0,
            );
      final rerankClock = clock ?? DateTime.now;
      await accountingStore.commitUsageLog(
        operator: operator,
        usageClass: kVoyageRerankUsageClass,
        telemetry: ProxyUsageTelemetry(
          // Fixed rerank-class label for the rerank cost class.
          queryClass: 'rerank',
          cacheHit: false,
          // llmTier/modelUsed carry the Voyage provider+model for this cost
          // class. HP #7: no key, only the public provider/model id.
          llmTier: AdvisorProviderConstants.voyageProviderId,
          modelUsed: AdvisorProviderConstants.voyageRerankModelId,
        ),
        estimate: ProxyUsageChargeEstimate(
          tokenCount: rerankResult.totalTokens,
          costCents: rerankCostCents,
        ),
        now: rerankClock().toUtc(),
      );
    }
  }

  _writeJson(response, 200, <String, Object?>{
    'chunks': <Map<String, Object?>>[
      for (final chunk in orderedChunks)
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
