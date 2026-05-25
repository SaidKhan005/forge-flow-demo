// Forge & Flow advisor proxy — server-side Voyage rerank gateway.
//
// Advisor Knowledge Activation — Slice A3.
//
// Runtime Voyage HTTP gateway that reorders a candidate pool of corpus
// chunks against the query text using the `rerank-2.5` cross-encoder,
// returning the candidate ids in relevance order plus the provider-
// reported token usage for HP #9 cost metering.
//
// Design decisions (mirror `advisor_query_embedding_gateway_part.dart`):
//   * Standalone file, NOT a `part of` — it imports `dart:io` /
//     `dart:convert` / `package:http` independently. The part-file
//     pattern would pull those imports into the monolith; a standalone
//     class keeps the build graph clean and honors the ceiling-safe
//     decomposition principle (zero monolith growth except the two
//     optional `routeRequest` params already added by A2b's sibling).
//   * Uses `package:http` (the proxy's adopted outbound stack), with an
//     injectable `http.Client` so tests pass a `MockClient` — no live
//     Voyage call in tests.
//   * The API key is accepted at call time, never stored on the instance,
//     so the route handler holds it for the duration of exactly one
//     request and it is never captured in a closure.
//   * HP #7: the key MUST stay server-side. This file does NOT log the
//     key, does NOT return it to the client, and does NOT store it as an
//     instance field. Error bodies are truncated before they reach a log.
//   * Reuse over re-derivation: the 1:1 validation, unknown-id guard, and
//     descending-by-score sort already live in `VoyageRerankProvider`
//     (`lib/services/voyage_rerank_provider.dart`). The gateway parses
//     the HTTP response into `(id, score)` pairs + `total_tokens`, then
//     funnels the pairs through a `VoyageRerankProvider` so that the
//     ordering contract is enforced in exactly one place. The existing
//     `VoyageRerankFn` typedef cannot carry token usage, so the gateway
//     surfaces `total_tokens` separately (HP #9 metering input) —
//     backward-compatible: the provider is untouched.
//
// Ceiling-safe: this file adds zero lines to
// `tool/advisor_proxy/advisor_proxy.dart`. The monolith's only change is
// the `corpusRerankGateway` / `voyageRerankApiKeyForRetrieval` optional
// parameters threaded through `routeRequest` (a few lines), mirroring the
// A2b embedding-gateway pattern.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/domain/services/rerank_provider.dart';
import 'package:forge_and_flow/services/voyage_rerank_provider.dart';
import 'package:http/http.dart' as http;

/// Endpoint locked by the Phase 11b advisor contract.
const String _kVoyageRerankUrl = 'https://api.voyageai.com/v1/rerank';

/// Default request timeout for a single Voyage rerank call. 30 s mirrors
/// the embedding gateway and the Anthropic adapter; the upstream caller
/// may wrap this in a [DependencyTimeoutException] catcher.
const Duration _kDefaultVoyageRerankTimeout = Duration(seconds: 30);

/// One id in relevance order produced by [AdvisorRerankGateway.rerank].
///
/// Mirrors a single [RerankResult] but is re-exported under a gateway-
/// local name so the route handler does not have to import the domain
/// type directly (the gateway already depends on it for the sort).
typedef AdvisorRerankRanking = List<RerankResult>;

/// Result of one [AdvisorRerankGateway.rerank] call.
///
/// Carries BOTH the relevance-ordered ranking AND the provider-reported
/// token count so the route can meter the Voyage rerank spend by class
/// (HP #9: AI cost metered by class). [totalTokens] is parsed from the
/// Voyage response `usage.total_tokens`; the rerank endpoint bills the
/// total processed tokens, so the whole count is billed as input tokens.
class AdvisorRerankResult {
  const AdvisorRerankResult({
    required this.ranking,
    required this.totalTokens,
  });

  /// Candidate ids in relevance order (rank 0 first), one [RerankResult]
  /// per input candidate. Sorted descending by Voyage `relevance_score`.
  final AdvisorRerankRanking ranking;

  /// Provider-reported total tokens consumed by the rerank call, parsed
  /// from the Voyage response `usage.total_tokens`. Used as the INPUT
  /// token count when computing cost via the Voyage rerank rate. Zero
  /// when the provider omits the field (cost then computes to 0 cents —
  /// fail-open so a malformed-but-2xx response never blocks retrieval).
  final int totalTokens;
}

/// Abstract seam so the route is testable without depending on
/// [VoyageHttpRerankGateway].
abstract class AdvisorRerankGateway {
  /// Rerank [candidates] against [queryText] via the configured provider.
  ///
  /// Returns an [AdvisorRerankResult] whose `ranking` lists every input
  /// candidate id in relevance order and whose `totalTokens` is the
  /// provider-reported token count for the call (HP #9 metering input).
  ///
  /// [topK] optionally limits how many results the provider returns; when
  /// null the provider scores and returns the full candidate set. The
  /// route caps the returned pool itself, so [topK] is an optimization,
  /// not a correctness requirement.
  ///
  /// Throws [AdvisorRerankException] on provider error (non-2xx status,
  /// malformed response, timeout, network error).
  ///
  /// HP #7: [apiKey] is a server-side secret. Implementations MUST NOT
  /// log it, return it to the client, or store it beyond the duration of
  /// a single call.
  Future<AdvisorRerankResult> rerank({
    required String apiKey,
    required String model,
    required String queryText,
    required List<RerankCandidate> candidates,
    int? topK,
  });
}

/// Thrown when a Voyage rerank call fails.
///
/// The message is safe to surface in proxy logs (it does not contain the
/// API key or the raw response body verbatim; long bodies are truncated).
/// It is NOT safe to return to the client — the route handler maps this
/// to a typed 503 envelope.
class AdvisorRerankException implements Exception {
  const AdvisorRerankException(this.message);
  final String message;
  @override
  String toString() => 'AdvisorRerankException: $message';
}

/// Production [AdvisorRerankGateway] backed by the Voyage `/v1/rerank`
/// HTTP endpoint.
///
/// Uses `package:http` so tests can inject a `MockClient` without
/// starting a real socket. The injected [httpClient] is shared across
/// calls; callers are responsible for closing it when the process shuts
/// down.
class VoyageHttpRerankGateway implements AdvisorRerankGateway {
  VoyageHttpRerankGateway({
    http.Client? httpClient,
    Uri? endpoint,
    Duration timeout = _kDefaultVoyageRerankTimeout,
  })  : _httpClient = httpClient ?? http.Client(),
        _endpoint = endpoint ?? Uri.parse(_kVoyageRerankUrl),
        _timeout = timeout;

  final http.Client _httpClient;
  final Uri _endpoint;
  final Duration _timeout;

  @override
  Future<AdvisorRerankResult> rerank({
    required String apiKey,
    required String model,
    required String queryText,
    required List<RerankCandidate> candidates,
    int? topK,
  }) async {
    if (candidates.isEmpty) {
      // No candidates → nothing to score, no provider call, no cost.
      return const AdvisorRerankResult(
        ranking: <RerankResult>[],
        totalTokens: 0,
      );
    }

    // The Voyage rerank API addresses candidates by their ordinal
    // position in the `documents` array (it returns `index`, not id), so
    // we keep `candidates` order fixed and map `index` → id below.
    final documents = <String>[
      for (final c in candidates) c.text,
    ];

    // HP #7: apiKey never logged, never captured beyond this call stack.
    final requestBody = jsonEncode(<String, Object?>{
      'model': model,
      'query': queryText,
      'documents': documents,
      // `return_documents: false` keeps the response small — we only need
      // index + relevance_score to reorder our own candidate list.
      'return_documents': false,
      if (topK != null) 'top_k': topK,
    });

    final http.Response response;
    try {
      response = await _httpClient
          .post(
            _endpoint,
            headers: <String, String>{
              HttpHeaders.contentTypeHeader: ContentType.json.value,
              HttpHeaders.authorizationHeader: 'Bearer $apiKey',
            },
            body: requestBody,
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw AdvisorRerankException(
        'Voyage rerank request timed out after ${_timeout.inSeconds}s',
      );
    } on SocketException catch (e) {
      throw AdvisorRerankException(
        'Voyage rerank network error: ${e.message}',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Truncate the body so secrets-by-accident in error messages cannot
      // leak through proxy structured logs (the key itself is never in
      // the body, but defensive truncation costs nothing).
      final truncated = response.body.length > 300
          ? '${response.body.substring(0, 300)}...'
          : response.body;
      throw AdvisorRerankException(
        'Voyage rerank request failed with HTTP ${response.statusCode}: '
        '$truncated',
      );
    }

    final Map<String, Object?> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, Object?>;
    } catch (_) {
      throw const AdvisorRerankException(
        'Voyage rerank response was not valid JSON',
      );
    }

    final results = decoded['results'];
    if (results is! List) {
      throw const AdvisorRerankException(
        'Voyage rerank response did not include a results array',
      );
    }

    // Map each result's `index` (ordinal into our `documents` array) back
    // to the corresponding candidate id, pairing it with the relevance
    // score. The ordering of `results` is NOT relied upon — the
    // VoyageRerankProvider below performs the authoritative descending
    // sort, exactly as it does for any other VoyageRerankFn caller.
    final pairs = <({String id, double score})>[];
    for (final entry in results) {
      if (entry is! Map<String, Object?>) {
        throw const AdvisorRerankException(
          'Voyage rerank response results[] contained a non-object entry',
        );
      }
      final rawIndex = entry['index'];
      final rawScore = entry['relevance_score'];
      if (rawIndex is! num) {
        throw const AdvisorRerankException(
          'Voyage rerank response result is missing a numeric index',
        );
      }
      if (rawScore is! num) {
        throw const AdvisorRerankException(
          'Voyage rerank response result is missing a numeric '
          'relevance_score',
        );
      }
      final index = rawIndex.toInt();
      if (index < 0 || index >= candidates.length) {
        throw AdvisorRerankException(
          'Voyage rerank response result index $index is out of range '
          '(0..${candidates.length - 1})',
        );
      }
      pairs.add((id: candidates[index].id, score: rawScore.toDouble()));
    }

    // Reuse the domain adapter for the 1:1 / unknown-id validation and the
    // descending-by-score sort so the ordering contract lives in exactly
    // one place. The provider's gateway callback is satisfied by the
    // already-parsed pairs; the model id is informational at this point.
    final provider = VoyageRerankProvider(
      rerankFn: ({
        required String query,
        required List<RerankCandidate> candidates,
        required String model,
      }) async =>
          pairs,
    );

    final AdvisorRerankRanking ranking;
    try {
      ranking = await provider.rerank(queryText, candidates);
    } on StateError catch (e) {
      // The provider throws StateError when the gateway's pair count does
      // not match the candidate count, or returns an unknown id. For the
      // rerank endpoint that means a partial / malformed results array
      // (e.g. fewer scored documents than we sent). Surface it as a typed
      // rerank failure so the route maps it to a 503 rather than a 500.
      throw AdvisorRerankException(
        'Voyage rerank response did not score every candidate: ${e.message}',
      );
    }

    // HP #9 metering input: parse the provider-reported token usage so the
    // route can charge the Voyage rerank cost class from REAL tokens (not
    // a heuristic). Voyage returns `{"usage": {"total_tokens": <int>}}`.
    // The rerank endpoint bills the total processed tokens, so
    // total_tokens IS the billable input count. Fail-open: a missing /
    // malformed `usage` block yields 0 (cost computes to 0 cents) rather
    // than blocking an otherwise-valid 2xx rerank.
    final usage = decoded['usage'];
    var totalTokens = 0;
    if (usage is Map<String, Object?>) {
      final rawTotal = usage['total_tokens'];
      if (rawTotal is num) {
        totalTokens = rawTotal.toInt();
      }
    }

    return AdvisorRerankResult(
      ranking: ranking,
      totalTokens: totalTokens < 0 ? 0 : totalTokens,
    );
  }
}
