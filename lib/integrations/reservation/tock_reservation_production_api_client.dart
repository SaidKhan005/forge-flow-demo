// Phase 8.transport.tock-reservation — production Tock HTTP transport.
//
// Concrete implementation of [TockApiClient] (declared in
// `tock_reservation_adapter.dart`) backed by `package:http`. The
// adapter wires this in production; tests inject a fake
// [TockApiClient] directly and never instantiate this class.
//
// Authority:
//   * `lib/integrations/reservation/tock_reservation_adapter.dart` —
//     the [TockApiClient] interface this class implements.
//   * `docs/integrations/tock/api_consumed.md` — endpoint table and
//     auth shape (bearer header, base URL).
//   * `docs/contracts/vendor_adapter_slice_contract.md` — pure-
//     transport contract: this class never opens a database
//     connection and never bypasses the adapter's framework calls.
//
// Hard Promises honored:
//   * HP #1 (pure transport swap): only translates HTTP <-> Dart
//     maps; the adapter still drives the canonical sink.
//   * HP #4 (per-operator isolation): every request is scoped to
//     a per-(operator, location) credential handle; the production
//     transport NEVER caches or shares bearer tokens across handles.
//   * HP #7 (server-side credentials): plaintext API keys live only
//     inside the injected [TockCredentialResolver] — the transport
//     reads them just-in-time per request and never logs them.
//
// V1 lean cut 2 boundaries respected:
//   * No KMS code path, no key-rotation surface here.
//   * No DLQ tile, no SIGTERM drain handler.
//   * No raw-payload sibling tables (raw payloads round-trip
//     through the adapter's JSON path only).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'tock_reservation_adapter.dart';

/// Default Tock partner API base URL. Source:
/// `docs/integrations/tock/api_consumed.md` (retrieved 2026-05-04).
/// Override per-environment via constructor / environment shim.
const String kTockProductionBaseUrl = 'https://api.exploretock.com';

/// Header Tock uses for the bearer-style API key. Documented under the
/// Premium-tier developer portal; engineering treats it as a standard
/// `Authorization: Bearer <apiKey>` header. The `*.live.sandbox` slice
/// diffs the observed shape against this assumption.
const String kTockAuthorizationHeader = 'authorization';

/// Header Tock uses for idempotent POST de-duplication. Tock does not
/// publish a header name on the public reservation reference; we send
/// the standard `Idempotency-Key` shape so the live slice can confirm
/// (or rename) the header per observed behaviour. The transport always
/// sets the header on POSTs; if Tock ignores it, no harm done.
const String kTockIdempotencyHeader = 'idempotency-key';

/// Endpoint paths consumed (mirror of `docs/integrations/tock/api_consumed.md`).
const String kTockBusinessLookupPathPrefix = '/businesses/';
const String kTockReservationsSearchPath = '/reservations/search';
const String kTockReservationByIdPathPrefix = '/reservations/';

/// Maximum number of 429 retries on a single request. The transport
/// applies exponential backoff with jitter between retries; on the
/// final retry, a 429 surfaces as a [TockTransportException] so the
/// adapter's worker tick can park the batch.
const int kTockDefault429MaxRetries = 4;

/// Resolver that the production transport asks for the plaintext API
/// key at request time. Production wires this to the framework's
/// `vendor_credentials_repository` (Phase 8.0); tests pass an in-memory
/// implementation that returns a known string per [TockCredentialHandle].
abstract class TockCredentialResolver {
  /// Resolve a plaintext API key for the given handle. The resolver
  /// MUST NOT cache the value beyond the request scope; the transport
  /// re-asks per call so credential rotation is observed instantly.
  Future<String> resolveApiKey({
    required TockCredentialHandle handle,
  });

  /// Resolve a plaintext API key on the connect path, where no handle
  /// exists yet — the framework hands us the operator-pasted key
  /// directly via `ConnectCommand.keyPaste.apiKey` and the adapter
  /// passes it through to the transport. The resolver short-circuits
  /// to the pre-resolved key so the transport's request layer stays
  /// uniform.
  Future<String> resolvePastedApiKey({
    required String operatorId,
    required String locationId,
    required String pastedApiKey,
  });
}

/// Trivial resolver that yields the `pastedApiKey` straight back. Used
/// by the connect path (the operator-pasted key has not yet been
/// persisted into the credential vault). The unit tests bind this so
/// they do not need a vault stub for the connect call.
class TockPassThroughCredentialResolver implements TockCredentialResolver {
  const TockPassThroughCredentialResolver({required this.apiKeyByHandle});

  /// Map from `connectionId` to plaintext API key. The production
  /// resolver replaces this with a vault-backed lookup; tests stuff
  /// the map directly.
  final Map<String, String> apiKeyByHandle;

  @override
  Future<String> resolveApiKey({required TockCredentialHandle handle}) async {
    final value = apiKeyByHandle[handle.connectionId];
    if (value == null || value.isEmpty) {
      throw const TockTransportException(
        statusCode: 0,
        kind: TockTransportErrorKind.credentialMissing,
        message:
            'tock credential resolver returned no api key for the handle',
      );
    }
    return value;
  }

  @override
  Future<String> resolvePastedApiKey({
    required String operatorId,
    required String locationId,
    required String pastedApiKey,
  }) async {
    if (pastedApiKey.isEmpty) {
      throw const TockTransportException(
        statusCode: 0,
        kind: TockTransportErrorKind.credentialMissing,
        message: 'tock connect: operator pasted an empty api key',
      );
    }
    return pastedApiKey;
  }
}

/// Typed transport-level error. Unifies network / 4xx / 5xx into one
/// shape the adapter (and its retry loop) can switch on.
enum TockTransportErrorKind {
  /// Auth failure (401). The credential vault rotated under us, or the
  /// operator revoked the key in the Tock dashboard. The adapter's
  /// connect / disconnect chrome lights up.
  unauthorized,

  /// 403 — forbidden. The Premium-tier intake lapsed or the business
  /// id mismatches the key.
  forbidden,

  /// 404 — vendor entity not found (e.g. `fetchReservationById`).
  notFound,

  /// 429 — rate-limited. The transport already exhausted its retry
  /// budget; the adapter can park the worker tick.
  rateLimited,

  /// 5xx — vendor-side fault.
  serverError,

  /// Local credential resolver returned nothing (vault wipe race).
  credentialMissing,

  /// Network / parse error. The adapter logs and retries on the next
  /// worker tick.
  transport,

  /// Tock returned a 2xx but the body did not parse to the expected
  /// shape. Surfaces as a soft drop on the adapter side.
  malformedResponse,
}

/// Transport-level exception. Carries the raw status code so callers
/// can branch on `429` / `401` without parsing strings.
class TockTransportException implements Exception {
  const TockTransportException({
    required this.statusCode,
    required this.kind,
    required this.message,
  });

  final int statusCode;
  final TockTransportErrorKind kind;
  final String message;

  @override
  String toString() =>
      'TockTransportException(status=$statusCode, kind=$kind): $message';
}

/// Production HTTP transport for the Tock reservation API. The class
/// is intentionally small — every method maps to one Tock endpoint and
/// is independently testable with a fake [http.Client].
class TockReservationProductionApiClient implements TockApiClient {
  TockReservationProductionApiClient({
    required this.credentialResolver,
    Uri? baseUri,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 20),
    Duration backoffBase = const Duration(milliseconds: 200),
    int rateLimitMaxRetries = kTockDefault429MaxRetries,
    String Function()? idempotencyKeyFactory,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleeper,
  })  : _baseUri = baseUri ?? Uri.parse(kTockProductionBaseUrl),
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _backoffBase = backoffBase,
        _rateLimitMaxRetries = rateLimitMaxRetries,
        _idempotencyKeyFactory = idempotencyKeyFactory ?? _defaultKeyFactory,
        _clock = clock ?? DateTime.now,
        _sleep = sleeper ?? Future<void>.delayed;

  final TockCredentialResolver credentialResolver;
  final Uri _baseUri;
  final http.Client _httpClient;
  final Duration _timeout;
  final Duration _backoffBase;
  final int _rateLimitMaxRetries;
  final String Function() _idempotencyKeyFactory;
  // Injectable clock retained for upcoming request-timing audit +
  // replay determinism (Phase 8 vendor parity).
  // ignore: unused_field
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  // ─── verifyApiKey ────────────────────────────────────────────────
  //
  // Tock's `GET /businesses/{businessId}` confirms a key is valid for
  // the business id the operator pasted. A 200 -> success; 401/403 ->
  // typed auth error. The production resolver is only consulted for
  // post-connect calls — `verifyApiKey` is invoked with the operator-
  // pasted key in-flight and resolves it through the connect path.

  @override
  Future<TockCredentialHandle> verifyApiKey({
    required String operatorId,
    required String locationId,
    required String businessId,
    required String apiKey,
  }) async {
    final apiKeyResolved = await credentialResolver.resolvePastedApiKey(
      operatorId: operatorId,
      locationId: locationId,
      pastedApiKey: apiKey,
    );
    final response = await _send(
      method: 'GET',
      path: '$kTockBusinessLookupPathPrefix$businessId',
      apiKey: apiKeyResolved,
    );
    final body = _decodeJson(response.body);
    final resolvedBusinessId = _readString(body['id']) ??
        _readString(body['businessId']) ??
        businessId;
    // The framework mints the connector_connection.connection_id on
    // the connect path; the transport's verify call returns a handle
    // whose connectionId echoes the businessId so the in-flight call
    // chain has a stable token. The adapter's connect() path overrides
    // the handle's connectionId with the framework-issued value before
    // any subsequent transport call.
    return TockCredentialHandle(
      connectionId: resolvedBusinessId,
      businessId: resolvedBusinessId,
    );
  }

  // ─── fetchSampleReservation ─────────────────────────────────────
  //
  // The "Test connection" modal expects ONE real-looking reservation.
  // Tock's `POST /reservations/search` with a small page size returns
  // the most recently updated reservation; we surface the first row.

  @override
  Future<Map<String, Object?>> fetchSampleReservation({
    required TockCredentialHandle credentials,
  }) async {
    final apiKey = await credentialResolver.resolveApiKey(handle: credentials);
    final searchBody = <String, Object?>{
      'businessId': credentials.businessId,
      'pageSize': 1,
    };
    final response = await _send(
      method: 'POST',
      path: kTockReservationsSearchPath,
      apiKey: apiKey,
      jsonBody: searchBody,
      idempotencyKey: _idempotencyKeyFactory(),
    );
    final body = _decodeJson(response.body);
    final reservations = _readList(body, const <String>[
      'reservations',
      'results',
      'items',
      'data',
    ]);
    if (reservations.isEmpty) {
      // No reservations in the operator's recent window — return an
      // empty map so the test-connection modal can render the
      // "field-mapping preview is empty" note. Auth was still
      // validated by virtue of the 200 response.
      return const <String, Object?>{};
    }
    return _stringKeyMap(reservations.first);
  }

  // ─── fetchReservationsPage ──────────────────────────────────────
  //
  // Cursor-paginated window scan. Tock's documented shape is
  // `POST /reservations/search` with `windowStart` / `windowEnd` (both
  // ISO-8601 with restaurant-local offset preserved) and an optional
  // `pageToken`. The next page's token is returned as `nextPageToken`.

  @override
  Future<TockReservationsPage> fetchReservationsPage({
    required TockCredentialHandle credentials,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? resumeFromCursor,
  }) async {
    final apiKey = await credentialResolver.resolveApiKey(handle: credentials);
    final searchBody = <String, Object?>{
      'businessId': credentials.businessId,
      // TIMESTAMPTZ preservation: Dart's `DateTime` is offset-erasing
      // (it normalizes to local-or-UTC on parse), so we serialize the
      // wire shape as ISO-8601 with explicit UTC marker (`Z`). The
      // moment is preserved end-to-end; the restaurant-local offset
      // is reconstructed downstream from the location's timezone
      // catalog, not from this string. The Postgres sink stores
      // TIMESTAMPTZ and Postgres re-derives offset on read.
      'windowStart': windowStart.toUtc().toIso8601String(),
      'windowEnd': windowEnd.toUtc().toIso8601String(),
      if (resumeFromCursor != null && resumeFromCursor.isNotEmpty)
        'pageToken': resumeFromCursor,
    };
    final response = await _send(
      method: 'POST',
      path: kTockReservationsSearchPath,
      apiKey: apiKey,
      jsonBody: searchBody,
      idempotencyKey: _idempotencyKeyFactory(),
    );
    final body = _decodeJson(response.body);
    final rawList = _readList(body, const <String>[
      'reservations',
      'results',
      'items',
      'data',
    ]);
    final reservations = rawList
        .map(_stringKeyMap)
        .toList(growable: false);
    final nextCursor = _readString(body['nextPageToken']) ??
        _readString(body['next_cursor']) ??
        _readString(body['nextCursor']);
    final lastModified = _resolveLastModifiedSeen(reservations) ?? windowStart;
    return TockReservationsPage(
      reservations: reservations,
      nextCursor: (nextCursor == null || nextCursor.isEmpty) ? null : nextCursor,
      lastModifiedSeen: lastModified,
    );
  }

  // ─── fetchReservationById ───────────────────────────────────────

  @override
  Future<Map<String, Object?>?> fetchReservationById({
    required TockCredentialHandle credentials,
    required String reservationId,
  }) async {
    final apiKey = await credentialResolver.resolveApiKey(handle: credentials);
    try {
      final response = await _send(
        method: 'GET',
        path: '$kTockReservationByIdPathPrefix$reservationId',
        apiKey: apiKey,
      );
      return _stringKeyMap(_decodeJson(response.body));
    } on TockTransportException catch (error) {
      if (error.kind == TockTransportErrorKind.notFound) return null;
      rethrow;
    }
  }

  /// Release the underlying [http.Client]. The framework calls this on
  /// connector teardown; tests can ignore it.
  Future<void> close() async {
    _httpClient.close();
  }

  // ─── HTTP plumbing ───────────────────────────────────────────────

  Future<_TockHttpResponse> _send({
    required String method,
    required String path,
    required String apiKey,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final uri = _resolvePath(path);
    var attempt = 0;
    while (true) {
      attempt += 1;
      http.Response response;
      try {
        final request = http.Request(method, uri);
        request.headers[kTockAuthorizationHeader] = 'Bearer $apiKey';
        request.headers['accept'] = 'application/json';
        if (jsonBody != null) {
          request.headers['content-type'] = 'application/json';
          request.body = jsonEncode(jsonBody);
        }
        if (method == 'POST' && idempotencyKey != null) {
          request.headers[kTockIdempotencyHeader] = idempotencyKey;
        }
        final streamed = await _httpClient.send(request).timeout(_timeout);
        final raw = await streamed.stream.bytesToString().timeout(_timeout);
        response = http.Response(raw, streamed.statusCode,
            headers: streamed.headers);
      } on TimeoutException catch (error) {
        throw TockTransportException(
          statusCode: 0,
          kind: TockTransportErrorKind.transport,
          message: 'tock request timed out: $error',
        );
      } on http.ClientException catch (error) {
        throw TockTransportException(
          statusCode: 0,
          kind: TockTransportErrorKind.transport,
          message: 'tock http client error: ${error.message}',
        );
      }
      if (response.statusCode == 429) {
        if (attempt > _rateLimitMaxRetries) {
          throw TockTransportException(
            statusCode: 429,
            kind: TockTransportErrorKind.rateLimited,
            message:
                'tock rate-limited after $_rateLimitMaxRetries retries (429)',
          );
        }
        await _sleep(_computeBackoff(attempt, response));
        continue;
      }
      if (response.statusCode >= 500 && response.statusCode < 600) {
        if (attempt > _rateLimitMaxRetries) {
          throw TockTransportException(
            statusCode: response.statusCode,
            kind: TockTransportErrorKind.serverError,
            message:
                'tock server error ${response.statusCode} after $_rateLimitMaxRetries retries',
          );
        }
        await _sleep(_computeBackoff(attempt, response));
        continue;
      }
      if (response.statusCode == 401) {
        throw const TockTransportException(
          statusCode: 401,
          kind: TockTransportErrorKind.unauthorized,
          message: 'tock api key rejected (401)',
        );
      }
      if (response.statusCode == 403) {
        throw const TockTransportException(
          statusCode: 403,
          kind: TockTransportErrorKind.forbidden,
          message: 'tock api forbidden (403); premium-tier gate?',
        );
      }
      if (response.statusCode == 404) {
        throw const TockTransportException(
          statusCode: 404,
          kind: TockTransportErrorKind.notFound,
          message: 'tock resource not found (404)',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw TockTransportException(
          statusCode: response.statusCode,
          kind: TockTransportErrorKind.transport,
          message:
              'tock unexpected status ${response.statusCode}: ${_truncateBody(response.body)}',
        );
      }
      return _TockHttpResponse(
        statusCode: response.statusCode,
        body: response.body,
        headers: response.headers,
      );
    }
  }

  /// Compute backoff for a retry attempt. Honors `Retry-After` (in
  /// seconds) when Tock supplies it; otherwise applies exponential
  /// backoff with a small deterministic jitter (no `dart:math`
  /// dependency on Random — the test injects a sleeper anyway).
  Duration _computeBackoff(int attempt, http.Response response) {
    final header = response.headers['retry-after'];
    if (header != null) {
      final seconds = int.tryParse(header.trim());
      if (seconds != null && seconds > 0) {
        return Duration(seconds: seconds);
      }
    }
    final factor = 1 << (attempt - 1); // 1, 2, 4, 8, ...
    return _backoffBase * factor;
  }

  Uri _resolvePath(String path) {
    final base = _baseUri;
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final tail = path.startsWith('/') ? path : '/$path';
    return base.replace(path: '$basePath$tail');
  }

  Map<String, Object?> _decodeJson(String raw) {
    if (raw.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) return decoded.cast<String, Object?>();
    throw const TockTransportException(
      statusCode: 200,
      kind: TockTransportErrorKind.malformedResponse,
      message: 'tock response did not decode to a JSON object',
    );
  }

  String _truncateBody(String raw) {
    if (raw.length <= 256) return raw;
    return '${raw.substring(0, 256)}...';
  }
}

/// Internal value carrier; not exported beyond this file.
class _TockHttpResponse {
  const _TockHttpResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  final int statusCode;
  final String body;
  // Response headers captured for upcoming rate-limit + idempotency
  // diagnostics (Phase 8 vendor parity).
  // ignore: unused_field
  final Map<String, String> headers;
}

// ─── helpers ──────────────────────────────────────────────────────

List<Object?> _readList(Map<String, Object?> body, List<String> keys) {
  for (final key in keys) {
    final value = body[key];
    if (value is List) return value;
  }
  return const <Object?>[];
}

Map<String, Object?> _stringKeyMap(Object? raw) {
  if (raw is Map<String, Object?>) return raw;
  if (raw is Map) return raw.cast<String, Object?>();
  return const <String, Object?>{};
}

String? _readString(Object? raw) {
  if (raw is String) return raw;
  return null;
}

DateTime? _resolveLastModifiedSeen(List<Map<String, Object?>> reservations) {
  DateTime? winner;
  for (final r in reservations) {
    final raw = r['lastUpdatedTimestamp'];
    if (raw is! String || raw.isEmpty) continue;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) continue;
    if (winner == null || parsed.isAfter(winner)) winner = parsed;
  }
  return winner;
}

int _idempotencyCounter = 0;
String _defaultKeyFactory() {
  // Stable in-process counter + wall-clock to make duplicate requests
  // (e.g. the same worker tick re-issued) carry distinct keys without a
  // crypto dependency. Tock's idempotency contract requires uniqueness
  // per request, not unguessability.
  _idempotencyCounter += 1;
  return 'tock-${DateTime.now().microsecondsSinceEpoch}-$_idempotencyCounter';
}
