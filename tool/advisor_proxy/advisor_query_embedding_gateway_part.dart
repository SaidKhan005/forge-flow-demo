// Forge & Flow advisor proxy — server-side query embedding gateway.
//
// Advisor Knowledge Activation — Slice A2b.
//
// Runtime Voyage HTTP gateway that converts a plain-text question into a
// 1024-dim vector suitable for passing to [CorpusRetrievalService].
//
// Design decisions:
//   * Standalone file, NOT a `part of` — it imports `dart:io` /
//     `dart:convert` / `package:http` independently.  The part-file
//     pattern would pull those imports into the monolith; a standalone
//     class keeps the build graph clean and honors the ceiling-safe
//     decomposition principle.
//   * Uses `package:http` (already a direct dependency in main.dart,
//     `anthropic_http_complete_fn.dart`, etc.).  The `dart:io`
//     `HttpClient` used in `advisor_corpus.dart` is intentionally NOT
//     reused — the proxy already adopts `package:http` for outbound
//     calls; mixing two HTTP stacks in the proxy creates test friction.
//   * Injects `http.Client` so tests can pass a `MockClient` or a
//     `_FakeHttpClient` stub — no live Voyage call in tests.
//   * `input_type: 'query'` is mandatory for query-time embeddings per
//     the Voyage API contract (documents use `'document'`).  Using the
//     wrong input type silently degrades retrieval quality.
//   * The API key is accepted at call time, not stored on the instance,
//     so the caller (the route handler) holds it for the duration of
//     exactly one request and it is never captured in a closure.
//   * HP #7: the key MUST stay server-side.  This file does NOT log the
//     key, does NOT return it to the client, and does NOT store it as
//     an instance field.
//
// Ceiling-safe: this file adds zero lines to
// `tool/advisor_proxy/advisor_proxy.dart`.  The monolith's only
// change is the `corpusQueryEmbeddingGateway` optional parameter added
// to `routeRequest` (< 4 lines) — well within the 19 900-line ceiling.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Endpoint locked by the Phase 11b advisor contract.
const String _kVoyageEmbeddingsUrl =
    'https://api.voyageai.com/v1/embeddings';

/// Voyage `input_type` for QUERY embeddings.
///
/// Corpus documents were embedded with `'document'`.  Query-time
/// embeddings MUST use `'query'` to get asymmetric nearest-neighbour
/// alignment.  Mixing the two silently degrades cosine similarity
/// rankings.
const String _kVoyageQueryInputType = 'query';

/// Default request timeout for a single Voyage embedding call.
///
/// 30 s mirrors the Anthropic adapter's default; the upstream caller
/// may wrap this in a [DependencyTimeoutException] catcher.
const Duration _kDefaultVoyageRequestTimeout = Duration(seconds: 30);

/// Abstract seam so [AdvisorQueryEmbeddingGateway] is testable without
/// depending on [VoyageHttpQueryEmbeddingGateway].
abstract class AdvisorQueryEmbeddingGateway {
  /// Embed [queryText] via the configured provider.
  ///
  /// Returns a list of exactly [dimensions] doubles.
  ///
  /// Throws [AdvisorQueryEmbeddingException] on provider error
  /// (non-2xx status, malformed response, timeout, network error).
  ///
  /// HP #7: [apiKey] is a server-side secret.  Implementations MUST
  /// NOT log it, return it to the client, or store it beyond the
  /// duration of a single call.
  Future<List<double>> embedQuery({
    required String apiKey,
    required String model,
    required int dimensions,
    required String queryText,
  });
}

/// Thrown when a Voyage embedding call fails.
///
/// The message is safe to surface in proxy logs (it does not contain the
/// API key or the raw response body verbatim; long bodies are truncated).
/// It is NOT safe to return to the client — the route handler maps this
/// to a typed 503 envelope.
class AdvisorQueryEmbeddingException implements Exception {
  const AdvisorQueryEmbeddingException(this.message);
  final String message;
  @override
  String toString() => 'AdvisorQueryEmbeddingException: $message';
}

/// Production [AdvisorQueryEmbeddingGateway] backed by the Voyage
/// `/v1/embeddings` HTTP endpoint.
///
/// Uses `package:http` so tests can inject a `MockClient` without
/// starting a real socket.  The injected [httpClient] is shared across
/// calls; callers are responsible for closing it when the process shuts
/// down.
class VoyageHttpQueryEmbeddingGateway implements AdvisorQueryEmbeddingGateway {
  VoyageHttpQueryEmbeddingGateway({
    http.Client? httpClient,
    Uri? endpoint,
    Duration timeout = _kDefaultVoyageRequestTimeout,
  })  : _httpClient = httpClient ?? http.Client(),
        _endpoint = endpoint ?? Uri.parse(_kVoyageEmbeddingsUrl),
        _timeout = timeout;

  final http.Client _httpClient;
  final Uri _endpoint;
  final Duration _timeout;

  @override
  Future<List<double>> embedQuery({
    required String apiKey,
    required String model,
    required int dimensions,
    required String queryText,
  }) async {
    // HP #7: apiKey never logged, never captured beyond this call stack.
    final requestBody = jsonEncode(<String, Object?>{
      'input': <String>[queryText],
      'model': model,
      'input_type': _kVoyageQueryInputType,
      'output_dimension': dimensions,
      // Voyage-4-large supports float32; keep default (float32 / base64)
      // but do not override — the response parsing below handles
      // both float-list and base64 forms via the list path only,
      // which is what the API returns when output_dtype is omitted.
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
      throw AdvisorQueryEmbeddingException(
        'Voyage query-embedding request timed out after ${_timeout.inSeconds}s',
      );
    } on SocketException catch (e) {
      throw AdvisorQueryEmbeddingException(
        'Voyage query-embedding network error: ${e.message}',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Truncate the body so secrets-by-accident in error messages cannot
      // leak through proxy structured logs (the key itself is never in
      // the body, but defensive truncation costs nothing).
      final truncated = response.body.length > 300
          ? '${response.body.substring(0, 300)}...'
          : response.body;
      throw AdvisorQueryEmbeddingException(
        'Voyage embedding request failed with HTTP ${response.statusCode}: '
        '$truncated',
      );
    }

    final Map<String, Object?> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, Object?>;
    } catch (_) {
      throw const AdvisorQueryEmbeddingException(
        'Voyage embedding response was not valid JSON',
      );
    }

    final data = decoded['data'];
    if (data is! List || data.isEmpty) {
      throw const AdvisorQueryEmbeddingException(
        'Voyage embedding response did not include a data array',
      );
    }

    final first = data.first;
    if (first is! Map<String, Object?>) {
      throw const AdvisorQueryEmbeddingException(
        'Voyage embedding response data[0] is not an object',
      );
    }

    final embedding = first['embedding'];
    if (embedding is! List) {
      throw const AdvisorQueryEmbeddingException(
        'Voyage embedding response data[0].embedding is missing or not a list',
      );
    }

    try {
      return embedding
          .map<double>((e) => (e as num).toDouble())
          .toList(growable: false);
    } catch (_) {
      throw const AdvisorQueryEmbeddingException(
        'Voyage embedding response contained non-numeric values',
      );
    }
  }
}
