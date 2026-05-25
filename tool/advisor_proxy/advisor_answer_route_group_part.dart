// Advisor Knowledge Activation — Slice A4.2b: POST /v1/advisor/answer.
//
// The ACTIVATING slice. Every A4.x dependency landed inert on master; this
// route wires them into one live, recommendation-only, encrypted, metered
// agentic answer endpoint:
//
//   * Engine (A4.1)            — `AdvisorAgenticAnswerEngine` drives a bounded
//                                tool-use loop against Anthropic and returns a
//                                recommendation-only answer + real citations.
//   * Tool-use gateway (A4.1)  — `AnthropicToolUseCompleteFn`, built in
//                                main.dart from ONE shared `http.Client` + the
//                                server-side Anthropic key. Injected (optional)
//                                so tests pass a scripted fn and the monolith
//                                never imports `package:http`.
//   * retrieve_methodology     — A4.2a tool wrapping the SHARED embed→search→
//                                rerank pipeline; DEGRADES (omitted) when the
//                                retrieval service / Voyage embed gateway is
//                                absent so the engine still runs op-tools only.
//   * operational tools (A4.6) — get_active_targets / get_week_plan /
//                                get_shift_variance, bound to the verified
//                                caller scope (HP #4).
//   * encryptor (A4-ENC)       — `AdvisorConversationEnvelope` encrypts each
//                                turn IN-PROCESS; the DB never sees plaintext.
//   * conversation log (9.0Σ.h)— `AdvisorConversationLogRepository.recordTurn`
//                                persists the encrypted user + assistant turns.
//   * metering (HP #9)         — `kAdvisorAnswerUsageClass` rolls up the
//                                Anthropic answer spend through the SAME
//                                `commitUsageLog` / `recordAllowed` path the
//                                LLM smoke route uses (HP #8: no parallel stack).
//
// This is a Dart `part of advisor_proxy.dart`: it shares the library's imports
// + private scope (the helpers `_writeJson` / `_readJsonBody` /
// `_maybeWriteDependencyTimeout` / `_logProxyUnhandled` /
// `_resolveOperatorContextOrWrite`, the metering types, the engine, and the
// two tool factories). ALL handler logic lives HERE; the monolith grows by one
// `part` directive + one dispatch block + a few optional `routeRequest`
// params. No `kAdvisorProxyMaxLines` raise.
//
// ── ENCRYPTION-FIRST, fail-closed (HP #7) ──
// Before ANY provider work the handler checks the encryption seam: if the CMK
// resolver is absent (ADVISOR_CONVERSATION_CMK not provisioned) OR the
// conversation-log repo is absent, the route returns 503
// `advisor_answer_encryption_unavailable` and NEVER calls Anthropic. There is
// no path that produces an advisor answer without also persisting an encrypted
// provenance row. The Anthropic / Voyage / CMK keys are NEVER logged and NEVER
// placed in the response body.
//
// ── HP #4 (per-operator isolation) ──
// Every conversation-log write and every operational-tool read is scoped to
// the verified caller's `OperatorContext` (operator_id / location_id / userId
// from the JWT). Scope is NEVER taken from the request body — `operator_id` /
// `location_id` in the body are ignored.
//
// ── HP #6 (recommend, never command) ──
// The engine's system prompt pins the recommendation-only voice; this route
// does NOT override it and exposes NO write/mutation tool. The advisor only
// reads + advises.

part of 'advisor_proxy.dart';

/// Route path constant for the agentic answer endpoint. Exported so tests
/// reference the canonical string without hardcoding it.
const String advisorAnswerPath = '/v1/advisor/answer';

/// Surface label written to `advisor_conversation_log.surface` for every
/// turn this route persists. Distinct from the `advisor_qa` smoke surface so
/// audit/replay can tell the agentic answer endpoint apart.
const String kAdvisorAnswerSurface = 'advisor_answer';

/// Hard cap on prior conversation turns accepted from the client. Bounds the
/// prompt size (and so the cap-check estimate + provider cost) so a client
/// cannot replay an unbounded history. Over the cap → 400
/// `invalid_prior_turns`.
const int kAdvisorAnswerMaxPriorTurns = 20;

/// Hard cap on the characters of a single prior-turn `content` string. Paired
/// with [kAdvisorAnswerMaxPriorTurns] so the worst-case prior-turn payload is
/// bounded. Over the cap → 400 `invalid_prior_turns`.
const int kAdvisorAnswerMaxPriorTurnChars = 8000;

/// Hard cap on the characters of the `question` string. A question over this
/// length is rejected with 400 `invalid_question` rather than embedded /
/// dispatched, bounding the per-request cost.
const int kAdvisorAnswerMaxQuestionChars = 8000;

/// Handler for POST [advisorAnswerPath].
///
/// Called from [routeRequest] AFTER the standard operator-scope JWT has been
/// resolved (the dispatch site resolves [operator] and reads [body], exactly
/// like the retrieve route). Runs the full agentic answer flow:
///
///   1. Parse + validate the body (question, optional conversation_id /
///      prior_turns / restaurant_id / subscription_tier / query_class).
///   2. FAIL-CLOSED on the encryption seam BEFORE any provider work.
///   3. HP #9 cap-check via [usageGuard] (when wired).
///   4. Tier → model routing.
///   5. Assemble the tool catalog (retrieve_methodology when retrieval is
///      wired; always the three operational tools) and run the engine.
///   6. Encrypt + persist the user turn and the assistant turn.
///   7. Meter the Anthropic spend under [kAdvisorAnswerUsageClass].
///   8. Return the answer + citations + conversation_id.
///
/// All injected dependencies are OPTIONAL so existing `routeRequest` callers
/// (and the many tests that drive other routes) stay byte-compatible; when a
/// required one is absent this route fails closed (503) rather than crashing.
///
/// HP #7: [conversationCmkResolver] resolves the CMK only inside one encrypt
/// call; the Anthropic key lives only inside [completeFn]; neither key (nor
/// the Voyage keys) is ever logged or returned.
Future<void> _handleAdvisorAnswer({
  required HttpRequest request,
  required HttpResponse response,
  required Map<String, Object?> body,
  required OperatorContext operator,
  // ── Provider seam (A4.1) ──
  // The tool-use Anthropic gateway, pre-built in main.dart from ONE shared
  // http.Client + the server-side Anthropic key, so the monolith never imports
  // package:http and one client is reused across requests. Null in
  // tests/scaffolds that pass a scripted fn or none → 503 not_configured.
  AnthropicToolUseCompleteFn? completeFn,
  // ── Encryption-first seam (A4-ENC) ──
  // The abstract resolver (the concrete proxy resolver is built only when
  // ADVISOR_CONVERSATION_CMK is provisioned). Null → fail closed.
  AdvisorConversationCmkResolver? conversationCmkResolver,
  // The encrypted-history sink (9.0Σ.h). Null → fail closed.
  AdvisorConversationLogRepository? conversationLogRepository,
  // ── retrieve_methodology dependencies (A4.2a) ──
  // When the retrieval service + embed gateway + Voyage key are present the
  // methodology tool is added; otherwise it is OMITTED and the engine runs the
  // operational tools only (graceful degrade, NOT an error).
  CorpusRetrievalService? retrievalService,
  AdvisorQueryEmbeddingGateway? embeddingGateway,
  String? voyageApiKey,
  AdvisorRerankGateway? rerankGateway,
  String? voyageRerankApiKey,
  // ── operational tool repositories (A4.6) ──
  // The three read repos, tenant-pool-backed in production. Null → the
  // operational tools are omitted (the engine can still answer from
  // methodology + its own reasoning).
  TargetCycleRepository? targetCycleRepository,
  WeeklyPlanSnapshotRepository? weeklyPlanSnapshotRepository,
  ShiftRecordsReadRepository? shiftRecordsReadRepository,
  // ── metering (HP #9) ──
  ProxyUsageGuard? usageGuard,
  ProxyAccountingStore? accountingStore,
  DateTime Function()? clock,
}) async {
  final answerClock = clock ?? DateTime.now;

  // ── (a) Parse + validate the body ──────────────────────────────────────
  final rawQuestion = body['question'];
  if (rawQuestion is! String || rawQuestion.trim().isEmpty) {
    _writeJson(response, 400, const <String, Object?>{
      'error': 'invalid_question',
      'message': 'question must be a non-empty string',
    });
    return;
  }
  final question = rawQuestion.trim();
  if (question.length > kAdvisorAnswerMaxQuestionChars) {
    _writeJson(response, 400, <String, Object?>{
      'error': 'invalid_question',
      'message': 'question must be at most '
          '$kAdvisorAnswerMaxQuestionChars characters',
    });
    return;
  }

  // conversation_id: a client may continue an existing conversation; we mint
  // a fresh v4 uuid when absent (matches the uuid column the log writes).
  final String conversationId;
  final rawConversationId = body['conversation_id'];
  if (rawConversationId == null) {
    conversationId = generateUuidV4();
  } else if (rawConversationId is String &&
      isValidUuidV4(rawConversationId.trim())) {
    conversationId = rawConversationId.trim();
  } else {
    _writeJson(response, 400, const <String, Object?>{
      'error': 'invalid_conversation_id',
      'message': 'conversation_id must be a v4 UUID string when provided',
    });
    return;
  }

  // prior_turns: optional list of {role ∈ {user, assistant}, content}. Capped
  // in count + per-turn length so the prompt (and the cost) is bounded.
  final priorTurnsResult = _parseAdvisorPriorTurns(body['prior_turns']);
  if (priorTurnsResult is _AdvisorPriorTurnsFailure) {
    _writeJson(response, 400, priorTurnsResult.body);
    return;
  }
  final priorTurns = (priorTurnsResult as _AdvisorPriorTurnsParsed).turns;

  // subscription_tier / query_class are cost levers (tier → model). Defaults
  // mirror the smoke route: 'basic' tier (safe Haiku fallback) +
  // 'methodology_lookup' query class.
  final subscriptionTier = _nonBlankOr(
    body['subscription_tier'] is String
        ? body['subscription_tier'] as String
        : null,
    'basic',
  );
  final queryClass = _nonBlankOr(
    body['query_class'] is String ? body['query_class'] as String : null,
    'methodology_lookup',
  );

  // ── (b) FAIL-CLOSED on the encryption seam, BEFORE any provider work ────
  // HP #7 / encryption-first: there is no path that produces an answer
  // without also persisting an encrypted provenance row. If we cannot
  // encrypt+persist, we do not call the provider.
  if (conversationCmkResolver == null || conversationLogRepository == null) {
    _writeJson(response, 503, const <String, Object?>{
      'error': 'advisor_answer_encryption_unavailable',
      'message':
          'advisor answer is unavailable: conversation encryption is not '
          'configured',
    });
    return;
  }

  // The provider seam must be wired too (separate code so an operator can tell
  // a missing Anthropic key from a missing CMK).
  if (completeFn == null) {
    _writeJson(response, 503, const <String, Object?>{
      'error': 'advisor_answer_not_configured',
      'message': 'advisor answer is unavailable: the language model provider '
          'is not configured',
    });
    return;
  }

  // ── (c) HP #9 cap-check BEFORE the provider call ────────────────────────
  // Estimate input tokens from the question + prior-turn chars (ceil(chars/4),
  // the standard proxy heuristic). The estimate only gates the cap-check; the
  // ACTUAL provider-returned token totals drive the recorded cost below. The
  // guard is OPTIONAL — when unwired (tests/scaffold) no cap-check runs, just
  // like the smoke route with `usageGuard == null`.
  final estimatedChars = question.length +
      priorTurns.fold<int>(0, (sum, t) => sum + t.content.length);
  final estimatedInputTokens = (estimatedChars + 3) ~/ 4;
  UsageDecisionAllowed? usageDecision;
  if (usageGuard != null) {
    try {
      usageDecision = await usageGuard.requireAllowed(
        operator: operator,
        estimate: UsageEstimate(requestTokens: estimatedInputTokens),
      );
    } on UsageRefusal catch (refusal) {
      _writeJson(response, refusal.statusCode, refusal.toJson());
      return;
    }
  }

  // ── (d) Tier → model ────────────────────────────────────────────────────
  // Plans & Limits V1: the operator's plan sets the model ceiling (Haiku vs
  // Sonnet); the query class may downgrade a Sonnet-capable plan but never
  // upgrade past the plan. Same routers the smoke route uses.
  const tierRouter = SubscriptionLlmTierRouter();
  const modelRouting = ProxyLlmModelRouting();
  final llmTier = tierRouter.tierFor(
    subscriptionTier: subscriptionTier,
    queryClass: queryClass,
  );
  final modelId = modelRouting.modelIdFor(llmTier);

  // ── (e) Assemble the tool catalog ───────────────────────────────────────
  final toolDefinitions = <AnthropicToolDefinition>[];
  final toolHandlers = <String, ToolHandler>{};

  // retrieve_methodology: added ONLY when retrieval is wired (service + embed
  // gateway + Voyage key). DEGRADE: when absent the tool is omitted and the
  // engine runs operational tools only — never an error.
  if (retrievalService != null &&
      embeddingGateway != null &&
      voyageApiKey != null) {
    final methodologyTool = buildAdvisorRetrieveMethodologyTool(
      retrievalService: retrievalService,
      embeddingGateway: embeddingGateway,
      // HP #7: keys stay in the call stack, never echoed to the model.
      voyageApiKey: voyageApiKey,
      rerankGateway: rerankGateway,
      voyageRerankApiKey: voyageRerankApiKey,
      // HP #9: the retrieval pipeline meters its own Voyage spend by class
      // (voyage_query_embedding / voyage_rerank) through the SAME accounting
      // path. The cap-check above already gated the whole request, so the
      // tool meters cost but does not re-gate.
      operator: operator,
      usageGuard: usageGuard,
      accountingStore: accountingStore,
      clock: clock,
    );
    toolDefinitions.add(methodologyTool.definition);
    toolHandlers[methodologyTool.definition.name] = methodologyTool.handler;
  }

  // Operational tools: added when all three repos are wired. HP #4: bound to
  // the verified caller scope only.
  if (targetCycleRepository != null &&
      weeklyPlanSnapshotRepository != null &&
      shiftRecordsReadRepository != null) {
    final opTools = buildAdvisorOperationalTools(
      operator: operator,
      targetCycleRepository: targetCycleRepository,
      weeklyPlanSnapshotRepository: weeklyPlanSnapshotRepository,
      shiftRecordsReadRepository: shiftRecordsReadRepository,
    );
    toolDefinitions.addAll(opTools.definitions);
    toolHandlers.addAll(opTools.handlers);
  }

  // ── (f) Build the engine + run it ───────────────────────────────────────
  // HP #6: the engine's default system prompt pins recommendation-only voice;
  // we do NOT override it.
  final engine = AdvisorAgenticAnswerEngine(
    completeFn: completeFn,
    modelId: modelId,
    toolDefinitions: toolDefinitions,
    toolHandlers: toolHandlers,
  );

  AdvisorAgenticAnswerResult result;
  try {
    result = await engine.answer(
      question,
      priorTurns: <AdvisorPriorTurn>[
        for (final t in priorTurns) (role: t.role, content: t.content),
      ],
    );
  } catch (error, stackTrace) {
    // Outer guard around the provider/engine call. A dependency timeout gets
    // the standard envelope; anything else degrades to a generic 503 with NO
    // raw error / key text (HP #7).
    if (_maybeWriteDependencyTimeout(response, error)) return;
    _logProxyUnhandled(
      surface: kAdvisorAnswerSurface,
      method: request.method,
      path: advisorAnswerPath,
      error: error,
      stackTrace: stackTrace,
    );
    _writeJson(response, 503, const <String, Object?>{
      'error': 'advisor_answer_unavailable',
      'message': 'advisor answer is unavailable; please retry',
    });
    return;
  }

  // ── (g) Encrypt + persist the user turn and the assistant turn ──────────
  // HP #7: encryption happens IN-PROCESS; only ciphertext + IV + key ref +
  // hash reach the repository. The user turn is turnIndex = priorTurns.length
  // (0-indexed conversation position); the assistant turn is the next index.
  final envelope = AdvisorConversationEnvelope(resolver: conversationCmkResolver);
  final userTurnIndex = priorTurns.length;
  final assistantTurnIndex = priorTurns.length + 1;

  // Cost (cents) from the ACTUAL provider-returned token totals via the model
  // rate. Unknown model → 0 (registry fail-open). cost_usd on the row = cents
  // / 100 so the log column matches the metered usage_logs spend.
  final answerRate = LlmCostRateRegistry.rateFor(result.modelUsed);
  final costCents = answerRate == null
      ? 0
      : answerRate.costCentsFor(
          inputTokens: result.totalInputTokens,
          outputTokens: result.totalOutputTokens,
        );

  try {
    final userEncrypted = envelope.encryptTurn(
      role: 'user',
      content: question,
    );
    await conversationLogRepository.recordTurn(
      // HP #4: scope is the verified caller's, NEVER the body.
      operatorId: operator.operatorId,
      locationId: operator.locationId,
      userId: operator.userId.isEmpty ? null : operator.userId,
      conversationId: conversationId,
      turnIndex: userTurnIndex,
      role: 'user',
      contentEncrypted: userEncrypted.contentEncrypted,
      contentIv: userEncrypted.contentIv,
      contentKeyRef: userEncrypted.contentKeyRef,
      contentHash: userEncrypted.contentHash,
      surface: kAdvisorAnswerSurface,
      queryClass: queryClass,
      usageClass: kAdvisorAnswerUsageClass,
    );

    final assistantEncrypted = envelope.encryptTurn(
      role: 'assistant',
      content: result.answer,
    );
    await conversationLogRepository.recordTurn(
      operatorId: operator.operatorId,
      locationId: operator.locationId,
      userId: operator.userId.isEmpty ? null : operator.userId,
      conversationId: conversationId,
      turnIndex: assistantTurnIndex,
      role: 'assistant',
      contentEncrypted: assistantEncrypted.contentEncrypted,
      contentIv: assistantEncrypted.contentIv,
      contentKeyRef: assistantEncrypted.contentKeyRef,
      contentHash: assistantEncrypted.contentHash,
      surface: kAdvisorAnswerSurface,
      queryClass: queryClass,
      usageClass: kAdvisorAnswerUsageClass,
      provider: 'anthropic',
      modelId: result.modelUsed,
      promptTokenCount: result.totalInputTokens,
      completionTokenCount: result.totalOutputTokens,
      // cost_usd column is dollars; cents / 100 keeps it aligned with the
      // metered usage_logs spend recorded below.
      costUsd: costCents / 100,
    );
  } on AdvisorConversationKeyLengthError {
    // The CMK was present but the wrong length (misprovisioned). Fail closed
    // — never surface the key length detail to the client. The provider call
    // already ran, but no answer is returned without a persisted, encrypted
    // record (encryption-first). HP #7: the typed error omits the bytes.
    _writeJson(response, 503, const <String, Object?>{
      'error': 'advisor_answer_encryption_unavailable',
      'message':
          'advisor answer is unavailable: conversation encryption is not '
          'configured',
    });
    return;
  } catch (error, stackTrace) {
    // A persistence failure (RLS denial, DB timeout, …) must NOT leak raw
    // text. A dependency timeout gets the standard envelope; otherwise a
    // generic 503. Encryption-first: no answer without a persisted record.
    if (_maybeWriteDependencyTimeout(response, error)) return;
    _logProxyUnhandled(
      surface: kAdvisorAnswerSurface,
      method: request.method,
      path: advisorAnswerPath,
      error: error,
      stackTrace: stackTrace,
    );
    _writeJson(response, 503, const <String, Object?>{
      'error': 'advisor_answer_unavailable',
      'message': 'advisor answer is unavailable; please retry',
    });
    return;
  }

  // ── (h) Meter the Anthropic answer spend (HP #9) ────────────────────────
  // Distinct cost class (advisor_answer) recorded through the SAME accounting
  // path the smoke route + Voyage classes use (HP #8: no parallel stack).
  // token_count = input + output; cost from the model rate. Only when the
  // accounting store is wired (production); tests/scaffolds skip it. Then
  // advance the per-minute / monthly counters so the next cap-check sees this
  // spend.
  if (accountingStore != null) {
    await accountingStore.commitUsageLog(
      operator: operator,
      usageClass: kAdvisorAnswerUsageClass,
      telemetry: ProxyUsageTelemetry(
        queryClass: queryClass,
        cacheHit: false,
        llmTier: llmTier.id,
        modelUsed: result.modelUsed,
      ),
      estimate: ProxyUsageChargeEstimate(
        tokenCount: result.totalInputTokens + result.totalOutputTokens,
        costCents: costCents,
      ),
      now: answerClock().toUtc(),
    );
  }
  if (usageGuard != null && usageDecision != null) {
    await usageGuard.recordAllowed(
      operator: operator,
      decision: usageDecision,
      costCentsToAdd: costCents,
    );
  }

  // ── (i) Success envelope ────────────────────────────────────────────────
  // HP #7: no key field anywhere. Citations are the engine's real,
  // tool-sourced citations only.
  _writeJson(response, 200, <String, Object?>{
    'answer': result.answer,
    'citations': <Map<String, Object?>>[
      for (final citation in result.citations) citation.toJson(),
    ],
    'conversation_id': conversationId,
    'turn_index': assistantTurnIndex,
    'tool_calls': result.toolCallsInvoked,
    'model_used': result.modelUsed,
    'usage_class': kAdvisorAnswerUsageClass,
    'query_class': queryClass,
    'hit_iteration_cap': result.hitIterationCap,
    'operator_id': operator.operatorId,
    'location_id': operator.locationId,
  });
}

// ─── prior_turns parsing ───────────────────────────────────────────────────────

/// One validated prior conversation turn parsed from the request body.
class _AdvisorAnswerPriorTurn {
  const _AdvisorAnswerPriorTurn({required this.role, required this.content});
  final String role;
  final String content;
}

/// Successful parse of the optional `prior_turns` list.
class _AdvisorPriorTurnsParsed {
  const _AdvisorPriorTurnsParsed(this.turns);
  final List<_AdvisorAnswerPriorTurn> turns;
}

/// A `prior_turns` validation failure carrying the exact 400 body to write.
class _AdvisorPriorTurnsFailure {
  const _AdvisorPriorTurnsFailure(this.body);
  final Map<String, Object?> body;
}

/// Parses + validates the optional `prior_turns` list. Returns either an
/// [_AdvisorPriorTurnsParsed] (valid, possibly empty) or an
/// [_AdvisorPriorTurnsFailure] (the verbatim 400 body). Pure — no I/O.
///
/// Rules:
///   * absent / null → empty list (a fresh conversation).
///   * must be a JSON array; over [kAdvisorAnswerMaxPriorTurns] entries → 400.
///   * each entry must be an object with `role ∈ {user, assistant}` and a
///     non-empty `content` string at most [kAdvisorAnswerMaxPriorTurnChars].
Object _parseAdvisorPriorTurns(Object? raw) {
  if (raw == null) {
    return const _AdvisorPriorTurnsParsed(<_AdvisorAnswerPriorTurn>[]);
  }
  if (raw is! List) {
    return const _AdvisorPriorTurnsFailure(<String, Object?>{
      'error': 'invalid_prior_turns',
      'message': 'prior_turns must be a JSON array when provided',
    });
  }
  if (raw.length > kAdvisorAnswerMaxPriorTurns) {
    return _AdvisorPriorTurnsFailure(<String, Object?>{
      'error': 'invalid_prior_turns',
      'message':
          'prior_turns must contain at most $kAdvisorAnswerMaxPriorTurns '
          'turns (got ${raw.length})',
    });
  }
  final turns = <_AdvisorAnswerPriorTurn>[];
  for (final entry in raw) {
    if (entry is! Map) {
      return const _AdvisorPriorTurnsFailure(<String, Object?>{
        'error': 'invalid_prior_turns',
        'message': 'each prior turn must be an object with role + content',
      });
    }
    final role = entry['role'];
    if (role is! String || (role != 'user' && role != 'assistant')) {
      return const _AdvisorPriorTurnsFailure(<String, Object?>{
        'error': 'invalid_prior_turns',
        'message': "each prior turn role must be 'user' or 'assistant'",
      });
    }
    final content = entry['content'];
    if (content is! String || content.isEmpty) {
      return const _AdvisorPriorTurnsFailure(<String, Object?>{
        'error': 'invalid_prior_turns',
        'message': 'each prior turn content must be a non-empty string',
      });
    }
    if (content.length > kAdvisorAnswerMaxPriorTurnChars) {
      return _AdvisorPriorTurnsFailure(<String, Object?>{
        'error': 'invalid_prior_turns',
        'message': 'each prior turn content must be at most '
            '$kAdvisorAnswerMaxPriorTurnChars characters',
      });
    }
    turns.add(_AdvisorAnswerPriorTurn(role: role, content: content));
  }
  return _AdvisorPriorTurnsParsed(turns);
}
