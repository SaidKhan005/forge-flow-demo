// Advisor Knowledge Activation — Slice A4.2a: the `retrieve_methodology`
// answer tool.
//
// The ONE agentic tool that lets the advisor (`AdvisorAgenticAnswerEngine`,
// Slice A4.1) pull Forge & Flow methodology passages from the corpus. It
// wraps the SHARED retrieval pipeline ([_runAdvisorRetrievalPipeline] in
// `advisor_retrieve_route_group_part.dart`) — the exact embed → vector
// search → rerank flow + Voyage metering the POST /v1/advisor/retrieve
// route uses — and maps the retrieved chunks into the `sources` envelope
// the engine auto-collects citations from. So a methodology citation the
// advisor makes traces back to a REAL corpus chunk (never fabricated).
//
// This is a Dart `part of advisor_proxy.dart`, so it shares the library's
// imports + private scope (including the shared pipeline helper). It is
// INERT in A4.2a: it defines the tool definition + a factory that binds a
// handler to the embed gateway / Voyage key / CorpusRetrievalService /
// rerank gateway / rerank key (+ optional metering handles). NOTHING here
// is wired into a live route, `routeRequest` dispatch, or bootstrap — the
// A4.2b answer route is what will construct an engine with this tool and
// deploy it. The monolith grows by ONLY the `part` directive; no
// `kAdvisorProxyMaxLines` raise.
//
// ── Hard Promise #6 (advisor recommends, never acts) ──
// This is a READ tool. It only searches the methodology corpus; it cannot
// edit, schedule, or mutate anything.
//
// ── Hard Promise #7 (F&F holds all provider keys server-side) ──
// The Voyage embed + rerank keys are closed over by the factory and used
// only inside the shared pipeline's downstream provider calls. They are
// NEVER placed in the tool result, the `sources`, a log field, or any
// envelope the engine hands back to the model.
//
// ── No-fabrication degrade ──
// When the embed gateway / Voyage key is absent, OR retrieval returns no
// chunks, OR any pipeline step fails, the handler returns a NON-fabricated
// `{found:false, sources:[], message:'methodology search unavailable'}`
// envelope rather than THROWING. The engine then degrades gracefully (its
// system prompt tells it to say "I do not have methodology on that yet."),
// instead of surfacing a tool error.

part of 'advisor_proxy.dart';

/// Tool name constant. Exported so the A4.2b answer route + tests can
/// reference the canonical string without hardcoding it.
const String advisorToolRetrieveMethodology = 'retrieve_methodology';

/// Max characters of a chunk's body surfaced in a `sources[].snippet`.
/// The full chunk text can be large; the citation only needs a short,
/// human-readable excerpt, so it is truncated. The full body still drives
/// the rerank inside the pipeline — this cap is presentation-only.
const int kAdvisorRetrieveMethodologySnippetMaxChars = 300;

/// Message used in the graceful, non-fabricated degrade envelope when
/// methodology retrieval is unavailable or empty. Exported so tests assert
/// against the canonical string.
const String kAdvisorMethodologyUnavailableMessage =
    'methodology search unavailable';

/// Bundle returned by [buildAdvisorRetrieveMethodologyTool]: the tool
/// definition (for the Anthropic `tools` catalog) paired with its handler.
/// The A4.2b answer route merges this into the engine alongside the A4.6
/// operational tools.
typedef AdvisorRetrieveMethodologyTool = ({
  AnthropicToolDefinition definition,
  ToolHandler handler,
});

/// The `retrieve_methodology` tool definition (Anthropic `tools` shape).
///
/// `query` is required; `max_results` and `restaurant_id` are optional.
/// `restaurant_id` scopes the corpus search to a restaurant's own indexed
/// material when the corpus is partitioned that way; methodology passages
/// are operator-agnostic, so it is usually omitted.
final AnthropicToolDefinition advisorRetrieveMethodologyToolDefinition =
    AnthropicToolDefinition(
  name: advisorToolRetrieveMethodology,
  description:
      'Search the Forge and Flow methodology library for passages that '
      'explain how to read and improve labor and sales metrics (for '
      'example CPLH, SPLH, PPA, the optimal zone, daypart targeting). Use '
      'this whenever you need the methodology or definitions behind a '
      'recommendation so you can ground your answer in real source '
      'material and cite it. Returns the most relevant passages. '
      'Read-only.',
  inputSchema: <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'query': <String, Object?>{
        'type': 'string',
        'description':
            'Required. What to look up, in plain language (for example '
            '"how is CPLH calculated" or "what is the optimal zone").',
      },
      'max_results': <String, Object?>{
        'type': 'integer',
        'description':
            'Optional. How many passages to return (1 to 100). '
            'Defaults to 8 when omitted.',
        'minimum': 1,
        'maximum': 100,
      },
      'restaurant_id': <String, Object?>{
        'type': 'string',
        'description':
            'Optional. Scopes the search to a restaurant\'s own indexed '
            'material when the library is partitioned that way. Methodology '
            'passages are usually shared, so omit this unless you know a '
            'restaurant-specific scope is needed.',
      },
    },
    'required': <String>['query'],
    'additionalProperties': false,
  },
);

/// Builds the `retrieve_methodology` tool bound to the injected retrieval
/// dependencies. The returned [handler] closes over the embed gateway, the
/// server-side Voyage embed key, the [CorpusRetrievalService], the rerank
/// gateway + its key, and the OPTIONAL HP #9 metering handles.
///
/// The deps are injected (not constructed here) so the A4.2b route can pass
/// the SAME instances the rest of the proxy uses and so tests can pass
/// fakes. Mirrors [buildAdvisorOperationalTools].
///
/// HP #7: [voyageApiKey] / [voyageRerankApiKey] are captured by the handler
/// and only ever reach the shared pipeline's downstream provider calls —
/// never the tool result.
///
/// HP #9: when [accountingStore] + [operator] are supplied the embed (and,
/// when reranking runs, the rerank) spend is metered via the shared
/// pipeline, exactly as the retrieve route meters it. When [usageGuard] is
/// also supplied the operator's caps are checked before the embed. All
/// three are OPTIONAL — when null the tool runs the pipeline unmetered.
AdvisorRetrieveMethodologyTool buildAdvisorRetrieveMethodologyTool({
  required CorpusRetrievalService retrievalService,
  AdvisorQueryEmbeddingGateway? embeddingGateway,
  String? voyageApiKey,
  AdvisorRerankGateway? rerankGateway,
  String? voyageRerankApiKey,
  OperatorContext? operator,
  ProxyUsageGuard? usageGuard,
  ProxyAccountingStore? accountingStore,
  DateTime Function()? clock,
}) {
  Future<Map<String, Object?>> handler(Map<String, Object?> input) async {
    // ── Read + validate the query from tool input ─────────────────────
    // A blank / non-string / missing query cannot be embedded, so degrade
    // gracefully rather than throw — the engine then answers "I do not
    // have methodology on that yet." (HP #6 voice).
    final rawQuery = input['query'];
    if (rawQuery is! String || rawQuery.trim().isEmpty) {
      return _advisorMethodologyUnavailableResult();
    }
    final query = rawQuery.trim();

    // The shared pipeline parses `graph_scope` / `restaurant_id` /
    // `max_results` from a body map. The tool exposes `max_results` +
    // `restaurant_id`; pass them through under the keys the pipeline reads.
    // `graph_scope` is left at the pipeline default ('methodology'), which
    // is exactly the corpus this tool searches.
    final pipelineBody = <String, Object?>{
      if (input.containsKey('max_results'))
        'max_results': input['max_results'],
      if (input.containsKey('restaurant_id'))
        'restaurant_id': input['restaurant_id'],
    };

    final _AdvisorRetrievalOutcome outcome;
    try {
      outcome = await _runAdvisorRetrievalPipeline(
        query: query,
        body: pipelineBody,
        retrievalService: retrievalService,
        embeddingGateway: embeddingGateway,
        // HP #7: keys stay in the call stack, never echoed to the model.
        voyageApiKey: voyageApiKey,
        rerankGateway: rerankGateway,
        voyageRerankApiKey: voyageRerankApiKey,
        operator: operator,
        usageGuard: usageGuard,
        accountingStore: accountingStore,
        clock: clock,
      );
    } catch (_) {
      // Defensive: any unexpected pipeline error degrades gracefully. The
      // pipeline already maps known provider failures to typed outcomes
      // (handled below); this only catches the unexpected, and never
      // surfaces an exception (or a key) to the model.
      return _advisorMethodologyUnavailableResult();
    }

    // ── Map the pipeline outcome → a citable `sources` envelope ───────
    // Only a SUCCESS with at least one chunk is citable. Every other
    // outcome (gateway absent, cap refusal, embed / dimension / rerank
    // failure, param error) degrades to the non-fabricated
    // unavailable envelope — the engine never sees a key or a raw error.
    switch (outcome) {
      case _AdvisorRetrievalSuccess(:final chunks):
        if (chunks.isEmpty) {
          return _advisorMethodologyUnavailableResult();
        }
        return <String, Object?>{
          'found': true,
          'result_count': chunks.length,
          'sources': <Map<String, Object?>>[
            for (final chunk in chunks)
              <String, Object?>{
                // Keys the engine's citation collector reads
                // (advisor_agentic_answer_part.dart). `source_id` is the
                // stable chunk id; `doc_id` ties it to the document;
                // `title` is the heading breadcrumb; `snippet` a short
                // excerpt. HP #7: NO key field anywhere here.
                'source_id': chunk.chunkId,
                'doc_id': chunk.docId,
                'title': chunk.headingPath.join(' > '),
                'snippet': _advisorMethodologySnippet(chunk.text),
                'similarity': chunk.similarity,
              },
          ],
        };
      case _AdvisorRetrievalGatewayNotConfigured():
      case _AdvisorRetrievalCapRefused():
      case _AdvisorRetrievalEmbedUnavailable():
      case _AdvisorRetrievalDimensionMismatch():
      case _AdvisorRetrievalRerankUnavailable():
      case _AdvisorRetrievalParamError():
        return _advisorMethodologyUnavailableResult();
    }
  }

  return (
    definition: advisorRetrieveMethodologyToolDefinition,
    handler: handler,
  );
}

/// The non-fabricated "no methodology available" tool result. NOT flagged
/// is_error (the engine still answers gracefully); carries an empty
/// `sources` list so no citation is produced.
Map<String, Object?> _advisorMethodologyUnavailableResult() =>
    <String, Object?>{
      'found': false,
      'sources': <Map<String, Object?>>[],
      'message': kAdvisorMethodologyUnavailableMessage,
    };

/// Truncates [text] to [kAdvisorRetrieveMethodologySnippetMaxChars] for a
/// citation snippet, appending an ellipsis when it was cut. Presentation
/// only — the full body still drives the rerank inside the pipeline.
String _advisorMethodologySnippet(String text) {
  if (text.length <= kAdvisorRetrieveMethodologySnippetMaxChars) {
    return text;
  }
  return '${text.substring(0, kAdvisorRetrieveMethodologySnippetMaxChars)}...';
}
