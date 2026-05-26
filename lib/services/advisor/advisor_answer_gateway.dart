// Advisor Knowledge Activation — Slice D1: operator-facing Advisor Answer
// client service.
//
// This is the CLIENT for the already-live agentic answer endpoint
// `POST /v1/advisor/answer` (server slice A4.2b, see
// `tool/advisor_proxy/advisor_answer_route_group_part.dart`). It turns the
// operator's question into one recommendation-only answer plus the real,
// tool-sourced citations the engine produced, and threads a conversation id so
// a follow-up turn continues the same conversation.
//
// Reach-agnostic on purpose. The chat-UI reach (web only vs web + mobile) is
// an open operator decision, so this lives in the shared `lib/services/advisor`
// home and stays web-safe (pure Dart over `package:http`; no `dart:io`, no
// sqflite). A future web OR mobile chat screen (slice D2) can consume it
// unchanged. This file is CLIENT/SERVICE ONLY: it adds no UI, no proxy/server
// change, and no schema.
//
// Provider seam pattern mirrors the sibling read gateway
// `lib/operator_web/services/operator_web_audit_chain_anchors_gateway_provider.dart`:
//   * an abstract [AdvisorAnswerGateway] the (future) screen consumes;
//   * a live `package:http` impl that threads the auth token through EVERY
//     call (so a refreshed token lands on the next request) and injects the
//     proxy base URL + token rather than hardcoding either;
//   * a demo impl that returns a canned recommendation with no network (HP #2
//     demo parity);
//   * a provider sentinel the auth source mixes in to choose live vs demo.
//
// ── Hard Promises honored here ──
//   * HP #6 (recommend, never command): the result is a RECOMMENDATION. This
//     client exposes NO execute / apply / "do it" affordance and never implies
//     the advisor acts on the operator's behalf. The demo answer is phrased in
//     the same recommendation-only voice.
//   * HP #7 (keys stay server-side): the bearer token is read from the injected
//     provider, attached as the `Authorization` header, and is NEVER logged,
//     printed, or placed in any error / result field. No provider key ever
//     touches this client.
//
// Fail-closed states surface as honest, calm, plain-English messages that read
// as training (no jargon, no em dash). The server fails closed BEFORE calling
// the model when encryption is unavailable; this client maps each server state
// to a typed [AdvisorAnswerStatus] so the screen can render a calm message
// instead of a raw error.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Locked path the client hits. Mirrors `advisorAnswerPath` in
/// `tool/advisor_proxy/advisor_answer_route_group_part.dart`. Exposed so the
/// gateway and its tests reference one canonical string instead of hardcoding
/// it in two places.
const String kAdvisorAnswerPath = '/v1/advisor/answer';

/// One citation surfaced by the advisor answer. Maps a REAL source the engine's
/// tools returned (never fabricated): the server only emits a citation for a
/// source a tool actually produced. Wire shape mirrors
/// `AdvisorAnswerCitation.toJson()` on the server
/// (`tool/advisor_proxy/advisor_agentic_answer_part.dart`):
/// `source_id` + `tool_name` are always present; `title` + `snippet` optional.
class AdvisorCitation {
  const AdvisorCitation({
    required this.sourceId,
    required this.toolName,
    this.title,
    this.snippet,
  });

  /// Stable identifier of the source (e.g. `target_cycle:<id>` from an
  /// operational tool, or a corpus `chunk_id` / `doc_id` from retrieval).
  /// Load-bearing: this ties the citation to a real artifact.
  final String sourceId;

  /// Name of the tool that surfaced this source.
  final String toolName;

  /// Optional human-readable source title (e.g. a heading path).
  final String? title;

  /// Optional short excerpt of the source text.
  final String? snippet;

  /// Parses one citation from its wire map. Returns null when the entry is
  /// malformed or carries no `source_id` (a citation without a stable id is
  /// not a real, citable artifact, so it is dropped rather than shown).
  static AdvisorCitation? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final sourceId = _readString(map['source_id']);
    if (sourceId == null) return null;
    return AdvisorCitation(
      sourceId: sourceId,
      toolName: _readString(map['tool_name']) ?? '',
      title: _readString(map['title']),
      snippet: _readString(map['snippet']),
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// A successful advisor answer: the recommendation text plus the real,
/// tool-sourced citations, the conversation id to continue with, and the
/// 0-indexed position of this (assistant) turn in the conversation.
///
/// HP #6: [answer] is a recommendation, not a command. Nothing on this result
/// represents an action taken on the operator's behalf.
class AdvisorAnswerResult {
  const AdvisorAnswerResult({
    required this.answer,
    required this.citations,
    required this.conversationId,
    required this.turnIndex,
  });

  /// The advisor's final recommendation-only answer text.
  final String answer;

  /// Real sources the engine's tools surfaced, in first-seen order. May be
  /// empty when the engine answered from methodology / its own reasoning with
  /// no citable operator fact.
  final List<AdvisorCitation> citations;

  /// The conversation id to pass back on the next turn to continue this
  /// conversation. Minted server-side on the first turn.
  final String conversationId;

  /// 0-indexed position of this assistant turn in the conversation.
  final int turnIndex;

  /// Parses the success (200) envelope. Throws [AdvisorAnswerException]
  /// ([AdvisorAnswerStatus.serverError]) when a load-bearing field is missing
  /// or the wrong type, so a malformed success never reaches the UI as a
  /// half-built result.
  static AdvisorAnswerResult fromJson(Map<String, Object?> body) {
    final answer = body['answer'];
    final conversationId = body['conversation_id'];
    final turnIndex = body['turn_index'];
    if (answer is! String ||
        conversationId is! String ||
        conversationId.trim().isEmpty ||
        turnIndex is! int) {
      throw const AdvisorAnswerException(AdvisorAnswerStatus.serverError);
    }
    final rawCitations = body['citations'];
    final citations = <AdvisorCitation>[];
    if (rawCitations is List) {
      for (final entry in rawCitations) {
        final citation = AdvisorCitation.fromJson(entry);
        if (citation != null) citations.add(citation);
      }
    }
    return AdvisorAnswerResult(
      answer: answer,
      citations: List<AdvisorCitation>.unmodifiable(citations),
      conversationId: conversationId.trim(),
      turnIndex: turnIndex,
    );
  }
}

/// The distinct ways an advisor answer can fail to come back. Each maps to a
/// calm, plain-English operator message (see [AdvisorAnswerException.message]).
enum AdvisorAnswerStatus {
  /// 503 `advisor_answer_encryption_unavailable`: conversation encryption is
  /// not provisioned (or is misprovisioned). The advisor is not switched on.
  notSwitchedOn,

  /// 503 `advisor_answer_not_configured`: the language-model provider seam is
  /// not wired. The advisor is set up but cannot answer yet.
  notConfigured,

  /// 402 (usage cap reached): the monthly AI usage cap is used up.
  usageCapReached,

  /// 500 (server error), or a malformed / unexpected success payload.
  serverError,

  /// The request never reached the proxy, or no usable response came back
  /// (transport failure / timeout). Distinct from a server-reported error.
  networkError,
}

/// Thrown by an [AdvisorAnswerGateway] when an answer cannot be returned.
/// Carries a typed [status] plus a calm, plain-English [message] suitable for
/// direct display to the operator.
///
/// HP #7: the message NEVER contains the bearer token, a provider key, or raw
/// server internals. Plain English, reads as training, NO em dash (the colon
/// and full stop do the separating; the standalone glyph is reserved as the
/// empty-value sentinel elsewhere, not used here).
class AdvisorAnswerException implements Exception {
  const AdvisorAnswerException(this.status);

  final AdvisorAnswerStatus status;

  /// A calm operator-facing message. Same wording the (future) D2 screen can
  /// surface verbatim.
  String get message {
    switch (status) {
      case AdvisorAnswerStatus.notSwitchedOn:
        return "The advisor isn't switched on yet.";
      case AdvisorAnswerStatus.notConfigured:
        return 'The advisor is being set up and cannot answer just yet. '
            'Please check back soon.';
      case AdvisorAnswerStatus.usageCapReached:
        return "You've reached this month's advisor usage. It refreshes at "
            'the start of next month.';
      case AdvisorAnswerStatus.serverError:
        return 'Something went wrong on our side. Please try asking again.';
      case AdvisorAnswerStatus.networkError:
        return "We couldn't reach the advisor. Please check your connection "
            'and try again.';
    }
  }

  @override
  String toString() => 'AdvisorAnswerException(${status.name})';
}

/// The client the (future) advisor chat screen consumes. Demo and live impls
/// keep the same shape so the screen has one code path.
///
/// HP #6: [ask] returns a RECOMMENDATION. There is deliberately no `execute`,
/// `apply`, or `act` method here: the advisor never acts on the operator's
/// behalf.
abstract class AdvisorAnswerGateway {
  /// Asks the advisor [question]. Pass [conversationId] (from a prior
  /// [AdvisorAnswerResult]) to continue an existing conversation; omit it to
  /// start a fresh one. Returns the recommendation + citations, or throws an
  /// [AdvisorAnswerException] with a typed [AdvisorAnswerStatus].
  Future<AdvisorAnswerResult> ask({
    required String question,
    String? conversationId,
  });
}

/// Provider sentinel the auth source mixes in when it can supply a gateway.
/// Mirrors `OperatorWebAuditChainAnchorsGatewayProvider`: the demo auth source
/// mixes this in with [AdvisorAnswerGatewayDemo]; the live source mixes it in
/// with [AdvisorAnswerGatewayLive]. The (future) D2 screen reaches the gateway
/// through this seam — D1 wires it into NO screen.
abstract class AdvisorAnswerGatewayProvider {
  AdvisorAnswerGateway get advisorAnswerGateway;
}

/// Live `package:http` implementation. POSTs to
/// `<proxyBaseUri>/v1/advisor/answer` with the operator's question and threads
/// the auth token through EVERY call so a refreshed token lands on the next
/// request.
///
/// The route requires the `advisor.read` role; an unauthenticated /
/// insufficiently-scoped caller is rejected server-side and surfaces here as
/// [AdvisorAnswerStatus.notSwitchedOn] / [AdvisorAnswerStatus.serverError]
/// per the status mapping below.
///
/// No idempotency key is attached: the answer route is recommendation-read
/// shaped and does NOT persist a `proxy_requests` idempotency row (unlike the
/// write gateways), so the closest sibling read gateway
/// (`OperatorWebAuditChainAnchorsGatewayLive`) attaches none either. HP #7: the
/// token is injected, attached as `Authorization`, and never logged or echoed.
class AdvisorAnswerGatewayLive implements AdvisorAnswerGateway {
  AdvisorAnswerGatewayLive({
    required this.proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 60),
  })  : _idTokenProvider = idTokenProvider,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  /// Injected proxy base URL (never hardcoded). The `/v1/advisor/answer` path
  /// resolves against this.
  final Uri proxyBaseUri;

  /// Injected token source. Returns the current auth token (e.g. a Firebase ID
  /// token) or null when there is none. Awaited on EVERY call so a refreshed
  /// token is always used.
  final Future<String?> Function() _idTokenProvider;

  final http.Client _httpClient;

  /// Generous default: the agentic loop may make several model round-trips, so
  /// this is longer than the read gateways' 15s.
  final Duration _timeout;

  @override
  Future<AdvisorAnswerResult> ask({
    required String question,
    String? conversationId,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      // No live token to attach. The advisor cannot be reached as this
      // operator; surface the same calm "not switched on" message rather than
      // leaking an auth-internals string. HP #7: nothing about the token is
      // exposed.
      throw const AdvisorAnswerException(AdvisorAnswerStatus.notSwitchedOn);
    }

    final url = proxyBaseUri.resolve(kAdvisorAnswerPath);
    final request = http.Request('POST', url);
    request.headers.addAll(<String, String>{
      'accept': 'application/json',
      'content-type': 'application/json',
      'authorization': 'Bearer ${token.trim()}',
    });
    final trimmedConversationId = conversationId?.trim();
    request.body = jsonEncode(<String, Object?>{
      'question': question,
      if (trimmedConversationId != null && trimmedConversationId.isNotEmpty)
        'conversation_id': trimmedConversationId,
    });

    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const AdvisorAnswerException(AdvisorAnswerStatus.networkError);
    } catch (_) {
      // Any pre-response transport failure (DNS, socket, refused) is a
      // network error, not a server-reported one. HP #7: the raw error is not
      // surfaced (it could carry the request URL with a token-bearing header
      // in some impls).
      throw const AdvisorAnswerException(AdvisorAnswerStatus.networkError);
    }

    final String raw;
    try {
      raw = await streamed.stream.bytesToString().timeout(_timeout);
    } on TimeoutException {
      throw const AdvisorAnswerException(AdvisorAnswerStatus.networkError);
    } catch (_) {
      throw const AdvisorAnswerException(AdvisorAnswerStatus.networkError);
    }

    Object? decoded;
    if (raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        decoded = const <String, Object?>{};
      }
    }
    final body = decoded is Map<Object?, Object?>
        ? Map<String, Object?>.from(decoded)
        : const <String, Object?>{};

    final statusCode = streamed.statusCode;
    if (statusCode == 200) {
      return AdvisorAnswerResult.fromJson(body);
    }
    throw AdvisorAnswerException(_statusFor(statusCode, body));
  }

  /// Maps a non-200 response to a typed [AdvisorAnswerStatus] using the HTTP
  /// status first, then the server `error` code to disambiguate the two
  /// distinct 503 states. The token / key are never read out of the body.
  static AdvisorAnswerStatus _statusFor(int statusCode, Map<String, Object?> body) {
    final errorCode = body['error'] is String
        ? (body['error']! as String).trim()
        : '';
    switch (statusCode) {
      case 402:
        return AdvisorAnswerStatus.usageCapReached;
      case 503:
        // Two distinct 503 codes; the not_configured code means the provider
        // seam is null, everything else (encryption unavailable / generic
        // unavailable) maps to "not switched on".
        if (errorCode == 'advisor_answer_not_configured') {
          return AdvisorAnswerStatus.notConfigured;
        }
        return AdvisorAnswerStatus.notSwitchedOn;
      case 500:
        return AdvisorAnswerStatus.serverError;
      default:
        // 400 invalid_* (shouldn't happen for a normal question), 401/403
        // auth, or any other unexpected status: treat as a server error so the
        // operator gets a calm retry message rather than a raw code.
        return AdvisorAnswerStatus.serverError;
    }
  }
}

/// Demo / fixture gateway. Returns a canned recommendation-only answer plus a
/// citation or two for the demo walkthrough, with NO network call (HP #2 demo
/// parity: same shape the live impl returns). Threads a stable demo
/// conversation id so a follow-up turn in the demo continues the same
/// conversation, and advances the turn index per call.
///
/// HP #6: the canned answer is phrased as a recommendation ("you could
/// consider ..."), never a command, and represents no action taken on the
/// operator's behalf.
class AdvisorAnswerGatewayDemo implements AdvisorAnswerGateway {
  AdvisorAnswerGatewayDemo({
    AdvisorAnswerResult? fixedResult,
    String conversationId = _demoConversationId,
  })  : _fixedResult = fixedResult,
        _conversationId = conversationId;

  /// A fixed v4-shaped conversation id so the demo walkthrough shows a stable,
  /// continuable conversation. Tests can override via the constructor.
  static const String _demoConversationId =
      '00000000-0000-4000-8000-000000000d01';

  final AdvisorAnswerResult? _fixedResult;
  final String _conversationId;

  /// Per-instance assistant turn counter so a multi-turn demo shows an
  /// advancing turn index (first answer at index 1, like the live route's
  /// `priorTurns.length + 1` for a fresh conversation).
  int _nextTurnIndex = 1;

  @override
  Future<AdvisorAnswerResult> ask({
    required String question,
    String? conversationId,
  }) async {
    final fixed = _fixedResult;
    if (fixed != null) return fixed;
    final turnIndex = _nextTurnIndex;
    _nextTurnIndex += 2; // user turn + assistant turn per exchange.
    return AdvisorAnswerResult(
      answer:
          'Based on your recent shifts, you could consider trimming about an '
          'hour from the early prep block on slower mornings and shifting it '
          'toward your mid-day rush. That tends to bring cost per labor hour '
          'back toward your target without touching guest-facing coverage. '
          "It's only a suggestion: you know your floor best, so weigh it "
          'against what you are seeing day to day.',
      citations: List<AdvisorCitation>.unmodifiable(<AdvisorCitation>[
        const AdvisorCitation(
          sourceId: 'target_cycle:demo-active',
          toolName: 'get_active_targets',
          title: 'Active target cycle',
          snippet: 'Target CPLH 8.0, SPLH 120.0, PPA 24.0.',
        ),
        const AdvisorCitation(
          sourceId: 'shift_variance:demo-week',
          toolName: 'get_shift_variance',
          title: 'Recent shift variance',
          snippet: 'Early prep ran above target labor on three mornings.',
        ),
      ]),
      conversationId:
          (conversationId != null && conversationId.trim().isNotEmpty)
              ? conversationId.trim()
              : _conversationId,
      turnIndex: turnIndex,
    );
  }
}
