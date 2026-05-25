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
  final rawQuery = body['query'];
  final rawEmbedding = body['query_embedding'];

  if (rawQuery != null) {
    // ── Path A: text query → server-side embed → search → rerank ──────
    // Query-string validity is an HTTP-shape concern, so it is checked
    // HERE (before the pipeline) and writes the 400 envelope directly,
    // exactly as the A2b baseline did. Everything downstream of a valid
    // query string — gateway-presence, cap-check, embed + metering, param
    // parsing, retrieve, rerank + metering — is delegated to the shared
    // [_runAdvisorRetrievalPipeline] so the A4.2b answer route can reuse
    // the identical embed→search→rerank flow via the retrieve tool. This
    // handler maps the pipeline OUTCOME back to the exact same envelopes
    // the baseline wrote; the pipeline itself never touches [response].
    if (rawQuery is! String || rawQuery.trim().isEmpty) {
      _writeJson(response, 400, const <String, Object?>{
        'error': 'invalid_query',
        'message':
            'query must be a non-empty string when provided',
      });
      return;
    }

    final outcome = await _runAdvisorRetrievalPipeline(
      query: rawQuery.trim(),
      body: body,
      retrievalService: retrievalService,
      embeddingGateway: embeddingGateway,
      // HP #7: key stays in the call stack; never logged or returned.
      voyageApiKey: voyageApiKey,
      rerankGateway: rerankGateway,
      voyageRerankApiKey: voyageRerankApiKey,
      operator: operator,
      usageGuard: usageGuard,
      accountingStore: accountingStore,
      clock: clock,
    );

    // ── Map the pipeline outcome → the exact A2b/A3 baseline envelope ──
    switch (outcome) {
      case _AdvisorRetrievalSuccess(:final chunks):
        _writeJson(response, 200, _advisorRetrieveChunksBody(chunks));
        return;
      case _AdvisorRetrievalGatewayNotConfigured():
        _writeJson(response, 503, const <String, Object?>{
          'error': 'query_embedding_gateway_not_configured',
          'message':
              'server-side query embedding is not available; '
              'provide query_embedding instead',
        });
        return;
      case _AdvisorRetrievalCapRefused(:final refusal):
        // Same refusal envelope the metered LLM route returns, so an
        // over-budget operator gets a consistent 402/429/413/503.
        _writeJson(response, refusal.statusCode, refusal.toJson());
        return;
      case _AdvisorRetrievalEmbedUnavailable():
        _writeJson(response, 503, const <String, Object?>{
          'error': 'query_embedding_unavailable',
          'message': 'could not embed query; please retry',
        });
        return;
      case _AdvisorRetrievalDimensionMismatch():
        _writeJson(response, 503, const <String, Object?>{
          'error': 'query_embedding_dimension_mismatch',
          'message':
              'embedding provider returned wrong dimension; please retry',
        });
        return;
      case _AdvisorRetrievalRerankUnavailable():
        _writeJson(response, 503, const <String, Object?>{
          'error': 'rerank_unavailable',
          'message': 'could not rerank results; please retry',
        });
        return;
      case _AdvisorRetrievalParamError(body: final errorBody):
        _writeJson(response, 400, errorBody);
        return;
    }
  } else if (rawEmbedding != null) {
    // ── Path B: pre-computed embedding (A2 back-compat) ───────────────
    // Unchanged from the A2 baseline: validate the supplied vector, parse
    // the optional params, retrieve, and emit. This path performs NO
    // provider call (no embed, no rerank) and therefore meters NO Voyage
    // cost, so it deliberately does NOT run through the shared pipeline.
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

    // Shared param parsing (graph_scope / restaurant_id / max_results).
    final params = _parseAdvisorRetrieveParams(body);
    if (params is _AdvisorRetrieveParamFailure) {
      _writeJson(response, 400, params.body);
      return;
    }
    final parsed = params as _AdvisorRetrieveParams;

    // No query text on this path → never reranks; fetch exactly
    // maxResults (unchanged A2b behavior).
    final chunks = await retrievalService.retrieve(
      queryEmbedding: coerced,
      graphScope: parsed.graphScope,
      restaurantId: parsed.restaurantId,
      maxResults: parsed.maxResults,
    );

    _writeJson(response, 200, _advisorRetrieveChunksBody(chunks));
    return;
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
}

/// Builds the canonical 200 response body for a retrieval result. One
/// place so the text-query path, the pre-computed-embedding path, and any
/// future caller emit byte-identical chunk JSON.
Map<String, Object?> _advisorRetrieveChunksBody(List<RetrievedChunk> chunks) =>
    <String, Object?>{
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
    };

// ─── Shared retrieval pipeline (embed → search → rerank + metering) ────────────
//
// Factored out of [_handleAdvisorRetrieve] in Slice A4.2a so the A4.2b
// agentic answer route can let the advisor CALL the same pipeline through
// the `retrieve_methodology` tool (see [buildAdvisorRetrieveMethodologyTool]
// in `advisor_answer_tools_part.dart`) WITHOUT re-deriving the embed +
// Voyage-metering logic. The extraction is BEHAVIOR-PRESERVING for the
// retrieve route: the cap-check, both Voyage usage classes
// (`voyage_query_embedding` + `voyage_rerank`), the candidate-pool sizing,
// the rerank reordering, and the operation ORDER are identical to the A2b/A3
// baseline. The route maps the returned [outcome] back to the exact same
// HTTP envelopes; the pipeline NEVER touches an [HttpResponse]. HP #7: the
// Voyage embed + rerank keys are threaded through the call stack only and
// are never logged, returned, or stored.

/// Outcome of [_runAdvisorRetrievalPipeline]. A sealed result the caller
/// maps to its own surface (HTTP envelope for the route; a `sources`
/// envelope for the agentic tool). The pipeline writes NO response itself,
/// so the HTTP-shape decisions all stay with the caller.
sealed class _AdvisorRetrievalOutcome {
  const _AdvisorRetrievalOutcome();
}

/// The pipeline produced an ordered chunk list (possibly empty). For the
/// text-query path this is post-rerank when reranking was active.
class _AdvisorRetrievalSuccess extends _AdvisorRetrievalOutcome {
  const _AdvisorRetrievalSuccess(this.chunks);
  final List<RetrievedChunk> chunks;
}

/// The embedding gateway or its key was absent. The route surfaces a 503
/// `query_embedding_gateway_not_configured`; the tool degrades gracefully.
class _AdvisorRetrievalGatewayNotConfigured extends _AdvisorRetrievalOutcome {
  const _AdvisorRetrievalGatewayNotConfigured();
}

/// The usage guard refused the call BEFORE the provider call (over budget).
/// Carries the original [UsageRefusal] so the route writes the identical
/// refusal envelope (status + code + details).
class _AdvisorRetrievalCapRefused extends _AdvisorRetrievalOutcome {
  const _AdvisorRetrievalCapRefused(this.refusal);
  final UsageRefusal refusal;
}

/// The embedding provider threw (timeout, network, non-2xx, malformed).
class _AdvisorRetrievalEmbedUnavailable extends _AdvisorRetrievalOutcome {
  const _AdvisorRetrievalEmbedUnavailable();
}

/// The embedding provider returned a vector of the wrong dimension.
class _AdvisorRetrievalDimensionMismatch extends _AdvisorRetrievalOutcome {
  const _AdvisorRetrievalDimensionMismatch();
}

/// The rerank provider threw (timeout, network, non-2xx, malformed, or a
/// partial/unknown-id result).
class _AdvisorRetrievalRerankUnavailable extends _AdvisorRetrievalOutcome {
  const _AdvisorRetrievalRerankUnavailable();
}

/// A request parameter (graph_scope / restaurant_id / max_results) failed
/// validation. Carries the exact 400 [body] the baseline wrote so the
/// route reproduces it verbatim. NOTE this fires AFTER a successful embed +
/// its metering, exactly as the baseline did (the param parse sits between
/// the embed and the retrieve), so the ordering of side effects is
/// preserved.
class _AdvisorRetrievalParamError extends _AdvisorRetrievalOutcome {
  const _AdvisorRetrievalParamError(this.body);
  final Map<String, Object?> body;
}

/// Runs the advisor retrieval pipeline for a TEXT query: cap-check →
/// server-side Voyage embed (+ metering) → param parse → corpus vector
/// search → optional Voyage rerank (+ metering). Returns a sealed
/// [_AdvisorRetrievalOutcome]; never writes to any [HttpResponse].
///
/// [query] MUST already be the trimmed, non-empty query string (the caller
/// validates the query-string shape and emits its own 400 for a bad one).
/// [body] is read ONLY for the optional `graph_scope` / `restaurant_id` /
/// `max_results` params, parsed at the SAME point in the flow as the
/// baseline (after the embed + its metering) so the order of observable
/// side effects is identical.
///
/// HP #7: [voyageApiKey] / [voyageRerankApiKey] are used in exactly one
/// downstream call each and are never logged, returned, or stored.
///
/// HP #9 metering: when [accountingStore] + [operator] are supplied, the
/// embed spend is recorded under [kVoyageQueryEmbeddingUsageClass] and, when
/// reranking runs, the rerank spend under [kVoyageRerankUsageClass] — the
/// SAME accounting path the Anthropic answer uses (HP #8: no parallel
/// stack). When [usageGuard] is also supplied, the per-minute / monthly caps
/// are checked BEFORE the embed so an over-budget operator is refused
/// consistently with LLM calls. All three are OPTIONAL — when null
/// (tests / scaffolds / the tool's unmetered mode) the pipeline runs
/// unmetered exactly as the A2/A2b baseline did.
Future<_AdvisorRetrievalOutcome> _runAdvisorRetrievalPipeline({
  required String query,
  required Map<String, Object?> body,
  required CorpusRetrievalService retrievalService,
  AdvisorQueryEmbeddingGateway? embeddingGateway,
  String? voyageApiKey,
  AdvisorRerankGateway? rerankGateway,
  String? voyageRerankApiKey,
  OperatorContext? operator,
  ProxyUsageGuard? usageGuard,
  ProxyAccountingStore? accountingStore,
  DateTime Function()? clock,
}) async {
  if (embeddingGateway == null || voyageApiKey == null) {
    return const _AdvisorRetrievalGatewayNotConfigured();
  }

  // ── HP #9 cap-check BEFORE the provider call ────────────────────────
  // Estimate input tokens (Voyage bills input tokens only). ceil(chars/4)
  // is the standard heuristic the proxy uses elsewhere for pre-call
  // estimation; the ACTUAL provider-returned token count drives the
  // recorded cost below. The estimate only gates the cap-check so an
  // over-budget operator is refused consistently with LLM calls. The
  // guard is OPTIONAL — when unwired (tests/scaffold) no cap-check runs,
  // exactly as the LLM smoke route behaves with `usageGuard == null`.
  final estimatedInputTokens = (query.length + 3) ~/ 4;
  UsageDecisionAllowed? voyageUsageDecision;
  if (usageGuard != null && operator != null) {
    try {
      voyageUsageDecision = await usageGuard.requireAllowed(
        operator: operator,
        estimate: UsageEstimate(requestTokens: estimatedInputTokens),
      );
    } on UsageRefusal catch (refusal) {
      return _AdvisorRetrievalCapRefused(refusal);
    }
  }

  final AdvisorQueryEmbeddingResult embeddingResult;
  try {
    embeddingResult = await embeddingGateway.embedQuery(
      // HP #7: key stays in the call stack, never logged or returned.
      apiKey: voyageApiKey,
      model: AdvisorProviderConstants.voyageEmbeddingModelId,
      dimensions: AdvisorProviderConstants.voyageEmbeddingDimensions,
      queryText: query,
    );
  } on AdvisorQueryEmbeddingException catch (e) {
    // Surface the exception message in the proxy log — it is safe
    // (no key, truncated provider error). The caller maps the outcome
    // to a typed 503; the full message is not client-visible.
    log(
      LogSeverity.warning,
      'advisor_retrieve.embedding_failed',
      fields: <String, Object?>{'message': e.message},
    );
    return const _AdvisorRetrievalEmbedUnavailable();
  }

  final embedding = embeddingResult.embedding;

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
    return const _AdvisorRetrievalDimensionMismatch();
  }

  // ── HP #9 record the Voyage spend AFTER a successful call ───────────
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
        // request's graph_scope (which is parsed below and may yet 400):
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

  // ── Optional parameters with defaults ──────────────────────────────
  // Parsed HERE — after the embed + its metering — so an invalid param
  // 400 fires at the SAME point (and with the same already-recorded
  // Voyage spend) it did in the A2b/A3 baseline.
  final params = _parseAdvisorRetrieveParams(body);
  if (params is _AdvisorRetrieveParamFailure) {
    return _AdvisorRetrievalParamError(params.body);
  }
  final parsed = params as _AdvisorRetrieveParams;
  final graphScope = parsed.graphScope;
  final restaurantId = parsed.restaurantId;
  final maxResults = parsed.maxResults;

  // ── Decide whether the rerank step is active ────────────────────────
  // Slice A3 — rerank runs ONLY when a rerank gateway is wired AND its key
  // is present (we always have query text on this path). When either is
  // unmet the pipeline behaves exactly as the A2b vector-only baseline.
  final rerankActive = rerankGateway != null && voyageRerankApiKey != null;

  // ── Delegate to service ─────────────────────────────────────────────
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

  // ── Optional rerank reordering (gateway wired, candidates present) ──
  // Reorder the candidate pool by Voyage rerank-2.5 relevance, then keep
  // the top maxResults. No candidates → nothing to rerank, fall through to
  // the vector-only order (which is already empty/short). HP #9: the rerank
  // spend is metered below from the ACTUAL returned token count.
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
        queryText: query,
        candidates: candidates,
        // top_k is an optimization; we still re-clamp to maxResults below.
        topK: maxResults,
      );
    } on AdvisorRerankException catch (e) {
      // Surface the (safe, truncated) message in the proxy log; the caller
      // maps the outcome to a typed 503. The full provider error is not
      // client-visible and the key is never in the message.
      log(
        LogSeverity.warning,
        'advisor_retrieve.rerank_failed',
        fields: <String, Object?>{'message': e.message},
      );
      return const _AdvisorRetrievalRerankUnavailable();
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
    final orderedChunks =
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
    // at the head of the pipeline gates the whole request; the rerank cost
    // is recorded to usage_logs for per-class attribution.
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

    return _AdvisorRetrievalSuccess(orderedChunks);
  }

  return _AdvisorRetrievalSuccess(chunks);
}

// ─── Shared optional-parameter parsing ─────────────────────────────────────────

/// Parsed `graph_scope` / `restaurant_id` / `max_results` for a retrieve
/// request, with the same defaults the A2/A2b baseline applied
/// (`graph_scope` = `'methodology'`, `restaurant_id` = null, `max_results`
/// = 8).
class _AdvisorRetrieveParams {
  const _AdvisorRetrieveParams({
    required this.graphScope,
    required this.restaurantId,
    required this.maxResults,
  });
  final String graphScope;
  final String? restaurantId;
  final int maxResults;
}

/// A parameter failed validation. Carries the exact 400 [body] the baseline
/// wrote so every caller reproduces it verbatim.
class _AdvisorRetrieveParamFailure {
  const _AdvisorRetrieveParamFailure(this.body);
  final Map<String, Object?> body;
}

/// Parses the three optional retrieve params. Returns either an
/// [_AdvisorRetrieveParams] (valid) or an [_AdvisorRetrieveParamFailure]
/// (carrying the verbatim 400 body). Pure — no I/O, no response writes — so
/// both the text-query pipeline and the pre-computed-embedding path share
/// one validation, byte-identical to the A2b/A3 baseline.
Object _parseAdvisorRetrieveParams(Map<String, Object?> body) {
  final graphScopeRaw = body['graph_scope'];
  final String graphScope;
  if (graphScopeRaw == null) {
    graphScope = 'methodology';
  } else if (graphScopeRaw is String && graphScopeRaw.trim().isNotEmpty) {
    graphScope = graphScopeRaw.trim();
  } else {
    return const _AdvisorRetrieveParamFailure(<String, Object?>{
      'error': 'invalid_graph_scope',
      'message': 'graph_scope must be a non-empty string when provided',
    });
  }

  final restaurantIdRaw = body['restaurant_id'];
  final String? restaurantId;
  if (!body.containsKey('restaurant_id') || restaurantIdRaw == null) {
    restaurantId = null;
  } else if (restaurantIdRaw is String && restaurantIdRaw.trim().isNotEmpty) {
    restaurantId = restaurantIdRaw.trim();
  } else {
    return const _AdvisorRetrieveParamFailure(<String, Object?>{
      'error': 'invalid_restaurant_id',
      'message':
          'restaurant_id must be a non-empty UUID string or null when provided',
    });
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
    return const _AdvisorRetrieveParamFailure(<String, Object?>{
      'error': 'invalid_max_results',
      'message': 'max_results must be a positive integer when provided',
    });
  }

  return _AdvisorRetrieveParams(
    graphScope: graphScope,
    restaurantId: restaurantId,
    maxResults: maxResults,
  );
}
