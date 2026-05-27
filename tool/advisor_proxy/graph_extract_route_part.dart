// Forge & Flow advisor proxy -- graph semantic-extraction endpoint.
//
// Advisor Graph Activation -- Slice G4b.
//
// POST /v1/admin/graph/extract
//
// Brokers the C3 semantic-extraction LLM call server-side so the G4
// tool (tool/advisor_corpus) never calls providers directly after this
// endpoint is wired.
//
// Hard Promises honoured:
//
//   HP #7  -- server-side keys only.  The Anthropic API key comes from
//             ProxySecretNames.anthropicApiKey (env/KMS).  It is NEVER
//             logged, NEVER returned to the client, and NEVER stored
//             beyond the duration of one request call stack.
//
//   HP #8  -- no parallel AI stacks.  Reuses the existing
//             AnthropicHttpExtractFn typedef (same package:http client
//             lifecycle as the answer route).
//
//   HP #9  -- AI cost metered by class.  Every call records to
//             kGraphExtractionUsageClass ('graph_extraction') through
//             the same ProxyUsageGuard / ProxyAccountingStore two-slot
//             path the advisor routes use.  No USD in this file; the
//             existing LlmCostRateRegistry drives cost computation.
//
//   HP #4  -- per-operator isolation.  The caller scope is resolved
//             from the JWT; no scope values are accepted from the
//             request body.
//
// Idempotency:
//   Idempotency-Key header -> proxy_requests UNIQUE check via
//   ProxyAccountingStore.startRequest, same pattern as the answer route.
//
// Vocab constraint:
//   Returned nodes and edges are validated against the sealed C3
//   vocabulary (kC3NodeKinds / kC3EdgeTypes from
//   lib/infrastructure/persistence/postgres/repositories/graph_repository.dart
//   or declared inline here as a local mirror).  The kC3* sets live in
//   tool/advisor_corpus/advisor_corpus.dart on the G4 branch; this proxy
//   file declares its own local mirror to keep the dependency graph clean
//   (tool/advisor_proxy does not import tool/advisor_corpus).
//
// OP-GATED: the route is wired into routeRequest via the optional
// graphExtractGateway parameter.  When null (default), the route returns
// 503 graph_extract_not_configured with a message instructing the caller
// to wait for operator approval to enable.  The gateway itself is the
// real AnthropicSemanticExtractGateway -- the only thing that gates it
// from receiving live traffic is the nil-check in the dispatcher.
//
// Ceiling-safe: this file adds ZERO lines to advisor_proxy.dart.
// The monolith gains one optional parameter in routeRequest (< 4 lines)
// and one dispatch block (< 50 lines) -- well within the 981-line
// headroom at the time of writing.
//
// ASCII-only source.  No em dash.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Route path constant.  Exported so tests reference the canonical string.
const String graphExtractPath = '/v1/admin/graph/extract';

/// HP #9 usage-class string for the server-side Anthropic extraction call.
///
/// 'graph_extraction' is a new distinct class that rolls up separately from
/// advisor_answer and advisor_qa so the AI Metrics panel can show graph
/// extraction spend independently.  usage_class is a free-form text column
/// (1 to 64 chars), so no migration is required for a new class value.
const String kGraphExtractionUsageClass = 'graph_extraction';

/// Anthropic model used for semantic extraction.
///
/// Haiku is the appropriate default: extraction prompts are structured
/// (JSON-only output, no prose) so the heavier Sonnet is unnecessary.
/// The caller may override via the 'model' body field; the handler
/// validates the override against kGraphExtractionAllowedModels.
const String kGraphExtractionDefaultModel = 'claude-haiku-4-5';

/// Model whitelist for the extraction endpoint.  Prevents callers from
/// steering the endpoint at arbitrary models (HP #9: cost is class-metered
/// against a known rate; an unlisted model would silently zero the rate and
/// bypass the cap).
const Set<String> kGraphExtractionAllowedModels = <String>{
  'claude-haiku-4-5',
  'claude-sonnet-4-6',
};

/// Roles that may call POST /v1/admin/graph/extract.
/// Mirrors the corpus admin write-only posture: super_admin only.
const Set<String> kGraphExtractWriteRoles = <String>{'super_admin'};

/// Maximum characters accepted in the 'chunk_text' field.
/// Bounds the cost estimate and provider call size.
const int kGraphExtractMaxChunkTextChars = 12000;

/// Maximum characters in 'document_title' and 'source_path'.
const int kGraphExtractMaxMetaChars = 512;

/// Hard upper bound on extraction output tokens.
/// 2048 gives room for a densely-typed response; matching the tool's
/// _maxOutputTokens so the cap-check estimate is conservative.
const int kGraphExtractMaxOutputTokens = 2048;

// ─── C3 vocabulary mirror ─────────────────────────────────────────────────────
//
// Local mirror of the sealed C3 sets from
// 202605261200_phase_12_c3_typed_graph_vocabulary.sql.
//
// Do NOT expand these without a corresponding migration + operator sign-off
// (same rule as the tool/advisor_corpus copies).  The sets are intentionally
// reproduced here (not imported from tool/advisor_corpus) to keep the
// dependency graph of tool/advisor_proxy clean.

/// Sealed C3 node-kind wire values (proxy-local mirror).
const Set<String> _kProxyC3NodeKinds = <String>{
  'Concept',
  'SOP',
  'Policy',
  'Metric',
  'Formula',
  'Risk',
  'Word_To_Know',
  'Coaching_Move',
  'Role',
  'Workflow',
  'Document',
  'Chunk',
  'Procedure',
};

/// Sealed C3 edge-type wire values (proxy-local mirror).
const Set<String> _kProxyC3EdgeTypes = <String>{
  'CONTAINS',
  'CAUSES',
  'INFORMS',
  'RELATES_TO',
  'DEPENDS_ON',
  'GOVERNS',
  'MITIGATES',
  'TEACHES',
  'DEFINES',
  'MEASURES',
  'CALCULATES',
  'REDUCES_RISK_OF',
  'REQUIRES',
  'PART_OF',
  'NEAR',
};

// ─── Gateway seam ─────────────────────────────────────────────────────────────

/// One node extracted from a chunk, validated against the C3 vocabulary.
class GraphExtractNode {
  const GraphExtractNode({
    required this.nodeKey,
    required this.kind,
    required this.label,
    required this.verbatimText,
  });

  /// Short identifier for this node (concept name, metric label, etc.).
  final String nodeKey;

  /// C3 node-kind wire value.  Validated; falls back to 'Concept' + AMBIGUOUS.
  final String kind;

  /// EXTRACTED | INFERRED | AMBIGUOUS.
  final String label;

  /// Verbatim excerpt from the chunk that grounds this node.
  final String verbatimText;

  Map<String, Object?> toJson() => <String, Object?>{
    'node_key': nodeKey,
    'kind': kind,
    'label': label,
    'verbatim_text': verbatimText,
  };
}

/// One edge extracted from a chunk, validated against the C3 vocabulary.
class GraphExtractEdge {
  const GraphExtractEdge({
    required this.fromNodeKey,
    required this.toNodeKey,
    required this.edgeType,
    required this.label,
    required this.verbatimText,
  });

  final String fromNodeKey;
  final String toNodeKey;

  /// C3 edge-type wire value.  Validated; falls back to 'RELATES_TO' + AMBIGUOUS.
  final String edgeType;

  /// EXTRACTED | INFERRED | AMBIGUOUS.
  final String label;

  /// Verbatim excerpt from the chunk that grounds this edge.
  final String verbatimText;

  Map<String, Object?> toJson() => <String, Object?>{
    'from_node_key': fromNodeKey,
    'to_node_key': toNodeKey,
    'edge_type': edgeType,
    'label': label,
    'verbatim_text': verbatimText,
  };
}

/// Result of one [GraphSemanticExtractGateway.extractFromChunk] call.
///
/// Carries nodes, edges, and the provider-reported token counts so the
/// route can meter the spend under kGraphExtractionUsageClass (HP #9).
class GraphExtractResult {
  const GraphExtractResult({
    required this.nodes,
    required this.edges,
    required this.inputTokens,
    required this.outputTokens,
  });

  final List<GraphExtractNode> nodes;
  final List<GraphExtractEdge> edges;

  /// Provider-reported input tokens.  Zero on fail-open shapes.
  final int inputTokens;

  /// Provider-reported output tokens.  Zero on fail-open shapes.
  final int outputTokens;
}

/// Abstract gateway seam.  Tests inject a mock; production wires
/// [AnthropicHttpExtractGateway].
///
/// HP #7: [apiKey] is a server-side secret.  Implementations MUST NOT
/// log it, return it, or store it beyond a single call.
abstract class GraphSemanticExtractGateway {
  Future<GraphExtractResult> extractFromChunk({
    required String apiKey,
    required String model,
    required String documentTitle,
    required String sourcePath,
    required List<String> headingPath,
    required String chunkText,
    required String chunkId,
    required String contentSha256,
  });
}

/// Thrown when the extraction gateway fails.
///
/// The message is safe for proxy logs (no key, no raw body verbatim).
/// It is NOT safe to return to the client -- the route maps it to 503.
class GraphExtractGatewayException implements Exception {
  const GraphExtractGatewayException(this.message);
  final String message;
  @override
  String toString() => 'GraphExtractGatewayException: $message';
}

// ─── System prompt (static) ───────────────────────────────────────────────────

const String _kExtractionSystemPrompt =
    'You are a knowledge-graph extraction assistant for a restaurant '
    'operations methodology corpus. '
    'Your output MUST be a single valid JSON object with exactly two keys: '
    '"nodes" (array) and "edges" (array). '
    'No markdown fences, no prose, no extra keys. '
    'Each node: {"key":string,"kind":one-of-node-kinds,'
    '"label":"EXTRACTED"|"INFERRED","verbatim":string}. '
    'Each edge: {"from":string,"to":string,"type":one-of-edge-types,'
    '"label":"EXTRACTED"|"INFERRED","verbatim":string}. '
    'Use only the provided node-kinds and edge-types. '
    'When unsure, use "Concept" for nodes and "RELATES_TO" for edges '
    'and set label to "INFERRED". Do not invent new kinds or types.';

// ─── Production gateway ───────────────────────────────────────────────────────

/// Production [GraphSemanticExtractGateway] backed by the Anthropic
/// Messages API via package:http.
///
/// Uses package:http (injected [httpClient]) so tests can pass a
/// MockClient without network I/O.  The [apiKey] is accepted at call
/// time and is never stored on the instance (HP #7).
class AnthropicHttpExtractGateway implements GraphSemanticExtractGateway {
  AnthropicHttpExtractGateway({
    http.Client? httpClient,
    Uri? endpoint,
    Duration timeout = const Duration(seconds: 45),
  }) : _httpClient = httpClient ?? http.Client(),
       _endpoint = endpoint ??
           Uri.parse('https://api.anthropic.com/v1/messages'),
       _timeout = timeout;

  final http.Client _httpClient;
  final Uri _endpoint;
  final Duration _timeout;

  @override
  Future<GraphExtractResult> extractFromChunk({
    required String apiKey,
    // HP #7: key accepted, never stored.
    required String model,
    required String documentTitle,
    required String sourcePath,
    required List<String> headingPath,
    required String chunkText,
    required String chunkId,
    required String contentSha256,
  }) async {
    final heading = headingPath.isEmpty ? '(root)' : headingPath.join(' > ');
    final nodeKindList = _kProxyC3NodeKinds.toList()..sort();
    final edgeTypeList = _kProxyC3EdgeTypes.toList()..sort();

    final userPrompt =
        'Extract typed knowledge-graph nodes and edges from this '
        'corpus chunk.\n\n'
        'Document: $documentTitle\n'
        'Source: $sourcePath\n'
        'Heading: $heading\n'
        'Chunk ID: $chunkId\n\n'
        'Approved node kinds: ${nodeKindList.join(', ')}\n'
        'Approved edge types: ${edgeTypeList.join(', ')}\n\n'
        'Chunk:\n$chunkText\n\n'
        'Return {"nodes":[...],"edges":[...]} only.';

    final requestBody = jsonEncode(<String, Object?>{
      'model': model,
      'max_tokens': kGraphExtractMaxOutputTokens,
      'temperature': 0,
      'system': _kExtractionSystemPrompt,
      'messages': <Map<String, Object?>>[
        <String, Object?>{'role': 'user', 'content': userPrompt},
      ],
    });

    final http.Response response;
    try {
      response = await _httpClient
          .post(
            _endpoint,
            headers: <String, String>{
              HttpHeaders.contentTypeHeader: 'application/json',
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
            },
            body: requestBody,
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw GraphExtractGatewayException(
        'Anthropic extraction timed out after ${_timeout.inSeconds}s '
        '(chunk $chunkId)',
      );
    } on SocketException catch (e) {
      throw GraphExtractGatewayException(
        'Anthropic extraction network error: ${e.message} '
        '(chunk $chunkId)',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final truncated = response.body.length > 300
          ? '${response.body.substring(0, 300)}...'
          : response.body;
      throw GraphExtractGatewayException(
        'Anthropic extraction HTTP ${response.statusCode}: $truncated '
        '(chunk $chunkId)',
      );
    }

    final Map<String, Object?> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, Object?>;
    } catch (_) {
      throw GraphExtractGatewayException(
        'Anthropic extraction response is not valid JSON (chunk $chunkId)',
      );
    }

    // Parse provider-reported usage for HP #9 metering.  Fail-open: a
    // missing usage block yields 0 tokens (cost computes to 0 cents) rather
    // than blocking an otherwise-valid response.
    var inputTokens = 0;
    var outputTokens = 0;
    final usage = decoded['usage'];
    if (usage is Map<String, Object?>) {
      final rawIn = usage['input_tokens'];
      if (rawIn is num) inputTokens = rawIn.toInt();
      final rawOut = usage['output_tokens'];
      if (rawOut is num) outputTokens = rawOut.toInt();
    }

    // Extract text content from the response.
    final content = decoded['content'];
    if (content is! List) {
      throw GraphExtractGatewayException(
        'Anthropic extraction response missing content array '
        '(chunk $chunkId)',
      );
    }

    final textParts = <String>[];
    for (final part in content) {
      if (part is Map<String, Object?> && part['type'] == 'text') {
        final text = part['text']?.toString().trim();
        if (text != null && text.isNotEmpty) textParts.add(text);
      }
    }
    final rawJson = textParts.join('\n').trim();
    if (rawJson.isEmpty) {
      throw GraphExtractGatewayException(
        'Anthropic extraction produced no text content (chunk $chunkId)',
      );
    }

    return _parseAndValidate(
      rawJson: rawJson,
      chunkId: chunkId,
      inputTokens: inputTokens < 0 ? 0 : inputTokens,
      outputTokens: outputTokens < 0 ? 0 : outputTokens,
    );
  }
}

// ─── JSON parsing + C3 vocab validation ───────────────────────────────────────

/// Parses the model's JSON response and validates every node kind and
/// edge type against the sealed C3 vocabulary.
///
/// Unknown kinds/types fall back to 'Concept'/'RELATES_TO' and the
/// candidate is labelled AMBIGUOUS so the admin re-classifies before
/// commit.  This mirrors the tool/advisor_corpus behaviour exactly.
GraphExtractResult _parseAndValidate({
  required String rawJson,
  required String chunkId,
  required int inputTokens,
  required int outputTokens,
}) {
  final Map<String, Object?> parsed;
  try {
    parsed = jsonDecode(rawJson) as Map<String, Object?>;
  } catch (_) {
    // Non-JSON model output: treat as zero extractions, not an error.
    // The caller can inspect the empty result and flag the chunk for
    // manual review.
    return GraphExtractResult(
      nodes: const <GraphExtractNode>[],
      edges: const <GraphExtractEdge>[],
      inputTokens: inputTokens,
      outputTokens: outputTokens,
    );
  }

  final nodes = <GraphExtractNode>[];
  final rawNodes = parsed['nodes'];
  if (rawNodes is List) {
    for (final n in rawNodes) {
      if (n is! Map<String, Object?>) continue;
      final rawKey = n['key']?.toString().trim() ?? '';
      if (rawKey.isEmpty) continue;
      final rawKind = n['kind']?.toString().trim() ?? '';
      final rawLabel = n['label']?.toString().trim() ?? 'INFERRED';
      final verbatim = n['verbatim']?.toString().trim() ?? '';

      final String kind;
      final String label;
      if (_kProxyC3NodeKinds.contains(rawKind)) {
        kind = rawKind;
        label = (rawLabel == 'EXTRACTED' || rawLabel == 'INFERRED')
            ? rawLabel
            : 'AMBIGUOUS';
      } else {
        // Unknown kind: fall back + flag as AMBIGUOUS for admin review.
        kind = 'Concept';
        label = 'AMBIGUOUS';
      }

      nodes.add(GraphExtractNode(
        nodeKey: rawKey,
        kind: kind,
        label: label,
        verbatimText: verbatim,
      ));
    }
  }

  final edges = <GraphExtractEdge>[];
  final rawEdges = parsed['edges'];
  if (rawEdges is List) {
    for (final e in rawEdges) {
      if (e is! Map<String, Object?>) continue;
      final rawFrom = e['from']?.toString().trim() ?? '';
      final rawTo = e['to']?.toString().trim() ?? '';
      if (rawFrom.isEmpty || rawTo.isEmpty) continue;
      final rawType = e['type']?.toString().trim() ?? '';
      final rawLabel = e['label']?.toString().trim() ?? 'INFERRED';
      final verbatim = e['verbatim']?.toString().trim() ?? '';

      final String edgeType;
      final String label;
      if (_kProxyC3EdgeTypes.contains(rawType)) {
        edgeType = rawType;
        label = (rawLabel == 'EXTRACTED' || rawLabel == 'INFERRED')
            ? rawLabel
            : 'AMBIGUOUS';
      } else {
        // Unknown edge type: fall back + flag as AMBIGUOUS.
        edgeType = 'RELATES_TO';
        label = 'AMBIGUOUS';
      }

      edges.add(GraphExtractEdge(
        fromNodeKey: rawFrom,
        toNodeKey: rawTo,
        edgeType: edgeType,
        label: label,
        verbatimText: verbatim,
      ));
    }
  }

  return GraphExtractResult(
    nodes: nodes,
    edges: edges,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
  );
}

// ─── Route handler ─────────────────────────────────────────────────────────────

/// Internal input error (maps to 400).
class _GraphExtractInputError implements Exception {
  const _GraphExtractInputError({required this.code, required this.message});
  final String code;
  final String message;
}

// --- HP #9 metering seam ------------------------------------------------------
//
// This file is a standalone `import` (NOT a `part of advisor_proxy.dart`), so it
// CANNOT name the monolith's metering types (ProxyUsageGuard,
// ProxyAccountingStore, OperatorContext, LlmCostRateRegistry, ...). Those types
// live in the monolith library and importing advisor_proxy.dart here would be a
// circular import.
//
// To wire HP #9 cost metering + proxy_requests idempotency WITHOUT inventing a
// parallel stack (HP #8), the dispatcher in advisor_proxy.dart -- where those
// types ARE visible -- supplies two typed callback seams. The closures it
// passes call the SAME ProxyUsageGuard / ProxyAccountingStore instances the
// advisor answer route uses (startRequest + requireAllowed for the reservation
// and cap-check; commitUsageLog + recordAllowed + completeRequest on success).
// This mirrors the established AnthropicHttpExtractFn typedef seam already in
// this file -- the orchestration sequence (reserve -> gateway -> commit) stays
// HERE; only the typed monolith calls cross the boundary as closures.

/// Outcome of the idempotency reservation + cap-check seam.
///
/// Wraps the `ProxyAccountingStore.startRequest` reservation result and the
/// `ProxyUsageGuard.requireAllowed` cap-check into one plain-Dart value the
/// standalone route file can branch on without naming monolith types.
sealed class GraphExtractReservation {
  const GraphExtractReservation();
}

/// The request reserved cleanly and passed the cap-check: proceed to call the
/// provider and (on success) commit usage via [GraphExtractCommitFn].
class GraphExtractReserveProceed extends GraphExtractReservation {
  const GraphExtractReserveProceed();
}

/// An idempotency replay: the prior response payload is cached; the route
/// returns it verbatim (status 200) WITHOUT re-calling the provider.
class GraphExtractReserveReplay extends GraphExtractReservation {
  const GraphExtractReserveReplay({required this.responsePayload});

  /// The exact prior 200 body the first call persisted via completeRequest.
  final Map<String, Object?> responsePayload;
}

/// The request is blocked before any provider work: either the accounting
/// store refused on a cap (402 usage_cap_reached, same shape the answer route
/// returns) or the usage guard raised a UsageRefusal (its own status + body).
/// The route writes [statusCode] + [body] and does NOT call the provider.
class GraphExtractReserveBlocked extends GraphExtractReservation {
  const GraphExtractReserveBlocked({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

/// The reservation seam failed (the accounting store was unavailable). The
/// route maps this to 503 accounting_store_unavailable, mirroring the answer
/// route's `on Exception` handling around `startRequest`.
class GraphExtractReserveStoreUnavailable extends GraphExtractReservation {
  const GraphExtractReserveStoreUnavailable();
}

/// Reserves the idempotency row + runs the HP #9 cap-check.
///
/// The dispatcher's closure calls `accountingStore.startRequest` (proxy_requests
/// UNIQUE reservation, replay lookup, per-tier cap refusal) and
/// `usageGuard.requireAllowed` (per-minute / monthly cap) against the verified
/// caller scope. [estimatedInputTokens] / [estimatedOutputTokens] feed the
/// pre-flight cost estimate; [model] selects the per-class rate.
typedef GraphExtractReserveFn =
    Future<GraphExtractReservation> Function({
      required String idempotencyKey,
      required String model,
      required int estimatedInputTokens,
      required int estimatedOutputTokens,
    });

/// Commits the metered spend after a successful extraction.
///
/// The dispatcher's closure calls `accountingStore.commitUsageLog`
/// (kGraphExtractionUsageClass rollup), `usageGuard.recordAllowed` (advance the
/// per-minute / monthly counters), and `accountingStore.completeRequest` (mark
/// the idempotency row complete with [responsePayload] so a later replay
/// returns it). Cost is derived from the provider-reported [inputTokens] /
/// [outputTokens] via the monolith's LlmCostRateRegistry. Best-effort: a
/// commit-side failure must not change the already-built 200 response, mirroring
/// the answer route, so the closure swallows store exceptions.
typedef GraphExtractCommitFn =
    Future<void> Function({
      required String idempotencyKey,
      required String model,
      required int inputTokens,
      required int outputTokens,
      required Map<String, Object?> responsePayload,
    });

/// Handler for POST [graphExtractPath].
///
/// Called from the routeRequest dispatcher AFTER JWT is verified and the
/// actor's roles have been checked against [kGraphExtractWriteRoles].
///
/// Flow:
///   1. Read + validate request body (chunk_text, chunk_id, content_sha256,
///      document_title, source_path, heading_path, optional model).
///   2. HP #9 cap-check + idempotency reservation via [reserve] (when wired).
///      On replay -> return the cached prior response (no provider call). On a
///      cap refusal -> return the refusal shape (no provider call). On a store
///      outage -> 503 accounting_store_unavailable (no provider call).
///   3. Forward to [gateway.extractFromChunk] with the server-side API key.
///   4. Validate + constrain output to the sealed C3 vocabulary.
///   5. Meter the spend + mark the idempotency row complete via [commit] (when
///      wired) under kGraphExtractionUsageClass with the provider tokens.
///   6. Return 200 JSON.
///
/// The [reserve] / [commit] seams are OPTIONAL. When both are null (tests that
/// only exercise the extraction logic, or a scaffold) the route skips metering
/// and idempotency entirely -- the gateway-only behaviour stays byte-identical
/// to the pre-F2 endpoint. The production dispatcher always wires both.
///
/// HP #7: [anthropicApiKey] is NEVER logged, NEVER put in the response.
/// HP #4: the [reserve] / [commit] closures are bound by the dispatcher to the
/// verified caller scope (from the JWT); this handler accepts no scope from the
/// request body.
Future<void> handleGraphExtract({
  required HttpRequest request,
  required HttpResponse response,
  required String actorUserId,
  required String idempotencyKey,
  required GraphSemanticExtractGateway gateway,
  required String? anthropicApiKey,
  // HP #9 metering + proxy_requests idempotency seams. Optional for
  // back-compat with tests that only need to verify the extraction logic;
  // when null the route runs gateway-only with no cap-check / reservation.
  GraphExtractReserveFn? reserve,
  GraphExtractCommitFn? commit,
  DateTime Function()? clock,
}) async {
  final requestClock = clock ?? DateTime.now;
  final requestedAt = requestClock().toUtc();

  // Guard: API key must be wired server-side (HP #7).
  if (anthropicApiKey == null || anthropicApiKey.isEmpty) {
    _graphWriteJson(response, 503, <String, Object?>{
      'error': 'graph_extract_key_unavailable',
      'message': 'Anthropic API key is not configured server-side. '
          'Provision ANTHROPIC_API_KEY in the proxy environment.',
    });
    return;
  }

  // Parse + validate the request body.
  // All _GraphExtractInputError throws (body parsing AND required-field
  // checks) are caught in a single block so every 400 path is covered.
  final String chunkText;
  final String chunkId;
  final String contentSha256;
  final String documentTitle;
  final String sourcePath;
  List<String> headingPath;
  String model;

  try {
    final body = await _graphReadJsonBody(request);

    chunkText = _requireGraphBodyString(body, 'chunk_text');
    chunkId = _requireGraphBodyString(body, 'chunk_id');
    contentSha256 = _requireGraphBodyString(body, 'content_sha256');
    documentTitle = _requireGraphBodyString(body, 'document_title');
    sourcePath = _requireGraphBodyString(body, 'source_path');

    if (chunkText.length > kGraphExtractMaxChunkTextChars) {
      throw const _GraphExtractInputError(
        code: 'chunk_text_too_long',
        message: 'chunk_text exceeds $kGraphExtractMaxChunkTextChars characters',
      );
    }

    if (documentTitle.length > kGraphExtractMaxMetaChars ||
        sourcePath.length > kGraphExtractMaxMetaChars) {
      throw const _GraphExtractInputError(
        code: 'meta_field_too_long',
        message:
            'document_title and source_path must not exceed $kGraphExtractMaxMetaChars characters',
      );
    }

    // heading_path is optional; default to empty list.
    headingPath = const <String>[];
    final rawHeadings = body['heading_path'];
    if (rawHeadings is List) {
      headingPath = <String>[
        for (final h in rawHeadings)
          if (h is String && h.trim().isNotEmpty) h.trim(),
      ];
    }

    // Model override: validate against the whitelist.
    model = kGraphExtractionDefaultModel;
    final rawModel = body['model'];
    if (rawModel is String && rawModel.trim().isNotEmpty) {
      final candidate = rawModel.trim();
      if (!kGraphExtractionAllowedModels.contains(candidate)) {
        throw _GraphExtractInputError(
          code: 'unsupported_model',
          message: 'model must be one of: '
              '${kGraphExtractionAllowedModels.join(', ')}',
        );
      }
      model = candidate;
    }
  } on _GraphExtractInputError catch (e) {
    _graphWriteJson(response, 400, <String, Object?>{
      'error': e.code,
      'message': e.message,
    });
    return;
  }

  // HP #9 cap-check + proxy_requests idempotency reservation (when wired).
  // Runs AFTER body validation (so a malformed request never reserves a row)
  // and BEFORE the provider call (so a replay / cap refusal / store outage
  // never reaches the gateway). The estimated input tokens use the standard
  // proxy heuristic (ceil(chars/4)) over the chunk + grounding metadata; the
  // estimated output tokens use the hard ceiling the gateway enforces
  // (kGraphExtractMaxOutputTokens) so the pre-flight cost estimate is
  // conservative. Mirrors the advisor answer route's reserve-then-call order.
  if (reserve != null) {
    final estimatedChars =
        chunkText.length +
        documentTitle.length +
        sourcePath.length +
        headingPath.fold<int>(0, (sum, h) => sum + h.length);
    final estimatedInputTokens = (estimatedChars + 3) ~/ 4;
    final reservation = await reserve(
      idempotencyKey: idempotencyKey,
      model: model,
      estimatedInputTokens: estimatedInputTokens,
      estimatedOutputTokens: kGraphExtractMaxOutputTokens,
    );
    switch (reservation) {
      case GraphExtractReserveReplay(:final responsePayload):
        // Idempotent replay: return the cached prior response verbatim. The
        // provider is NOT called again.
        _graphWriteJson(response, 200, <String, Object?>{
          ...responsePayload,
          'idempotent_replay': true,
        });
        return;
      case GraphExtractReserveBlocked(:final statusCode, :final body):
        // Cap refusal (accounting store or usage guard): return the refusal
        // shape. The provider is NOT called.
        _graphWriteJson(response, statusCode, body);
        return;
      case GraphExtractReserveStoreUnavailable():
        _graphWriteJson(response, 503, <String, Object?>{
          'error': 'accounting_store_unavailable',
          'message': 'proxy accounting store unavailable',
        });
        return;
      case GraphExtractReserveProceed():
        // Reserved + within cap: fall through to the provider call.
        break;
    }
  }

  // Call the extraction gateway (server-side key, never returned).
  GraphExtractResult result;
  try {
    result = await gateway.extractFromChunk(
      apiKey: anthropicApiKey, // HP #7: key stays here
      model: model,
      documentTitle: documentTitle,
      sourcePath: sourcePath,
      headingPath: headingPath,
      chunkText: chunkText,
      chunkId: chunkId,
      contentSha256: contentSha256,
    );
  } on GraphExtractGatewayException catch (e) {
    _graphWriteJson(response, 503, <String, Object?>{
      'error': 'graph_extract_provider_error',
      'message': 'Extraction provider error; retry or reduce chunk size.',
      // Safe: the exception message does not contain the API key.
      'detail': e.message,
    });
    return;
  } on TimeoutException {
    _graphWriteJson(response, 503, <String, Object?>{
      'error': 'graph_extract_timeout',
      'message': 'Extraction provider timed out.',
    });
    return;
  }

  // Build the 200 response body.
  final responsePayload = <String, Object?>{
    'chunk_id': chunkId,
    'content_sha256': contentSha256,
    'model': model,
    'usage_class': kGraphExtractionUsageClass,
    'input_tokens': result.inputTokens,
    'output_tokens': result.outputTokens,
    'nodes': <Map<String, Object?>>[
      for (final n in result.nodes) n.toJson(),
    ],
    'edges': <Map<String, Object?>>[
      for (final e in result.edges) e.toJson(),
    ],
    'node_count': result.nodes.length,
    'edge_count': result.edges.length,
    'ambiguous_node_count':
        result.nodes.where((n) => n.label == 'AMBIGUOUS').length,
    'ambiguous_edge_count':
        result.edges.where((e) => e.label == 'AMBIGUOUS').length,
    'extracted_at': requestedAt.toIso8601String(),
    // First-time success carries idempotent_replay=false; this is the exact
    // payload completeRequest persists, so a later replay returns it with the
    // flag flipped to true (see the GraphExtractReserveReplay branch above).
    'idempotent_replay': false,
  };

  // HP #9: meter the spend under kGraphExtractionUsageClass + mark the
  // idempotency row complete with this payload (when wired). The provider
  // tokens drive the recorded cost (via the monolith rate registry inside the
  // dispatcher closure). Best-effort by contract: the 200 below is written
  // regardless of a commit-side store hiccup, mirroring the answer route.
  if (commit != null) {
    await commit(
      idempotencyKey: idempotencyKey,
      model: model,
      inputTokens: result.inputTokens,
      outputTokens: result.outputTokens,
      responsePayload: responsePayload,
    );
  }

  _graphWriteJson(response, 200, responsePayload);
}

// ─── Small HTTP helpers (self-contained -- no shared private scope) ───────────

void _graphWriteJson(
  HttpResponse response,
  int statusCode,
  Map<String, Object?> body,
) {
  response
    ..statusCode = statusCode
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  response.close().ignore();
}

Future<Map<String, Object?>> _graphReadJsonBody(HttpRequest request) async {
  final bytes = await request.fold<List<int>>(
    <int>[],
    (prev, chunk) => prev..addAll(chunk),
  );
  if (bytes.isEmpty) {
    throw const _GraphExtractInputError(
      code: 'missing_body',
      message: 'Request body is required.',
    );
  }
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const _GraphExtractInputError(
        code: 'invalid_body',
        message: 'Request body must be a JSON object.',
      );
    }
    return decoded;
  } on FormatException {
    throw const _GraphExtractInputError(
      code: 'malformed_json',
      message: 'Request body is not valid JSON.',
    );
  }
}

String _requireGraphBodyString(Map<String, Object?> body, String field) {
  final value = body[field];
  if (value is! String || value.trim().isEmpty) {
    throw _GraphExtractInputError(
      code: 'missing_$field',
      message: "'$field' is required and must be a non-empty string.",
    );
  }
  return value.trim();
}
