// Phase 8.transport.sevenrooms-reservation — production SevenRooms HTTP
// transport.
//
// Concrete implementations of the three abstract API clients declared in
// `sevenrooms_reservation_adapter.dart`:
//
//   * [SevenRoomsAuthClient]          → [SevenRoomsAuthProductionApiClient]
//   * [SevenRoomsReservationsClient]  → [SevenRoomsReservationsProductionApiClient]
//   * [SevenRoomsWebhookClient]       → [SevenRoomsWebhookProductionApiClient]
//
// Hits the documented SevenRooms partner API surface:
//   * Marketing overview: https://sevenrooms.com/platform/integrations-apis/
//   * Partner API portal (account-rep gated): https://api-docs.sevenrooms.com/
//   * Auth-endpoint confirmation (Airship guide):
//     https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms
// Retrieved 2026-05-04 (mirrors `kSevenRoomsApiVersion = v2_2_2026_05`).
//
// Hard-Promise alignment (CLAUDE.md):
//   * HP #1 (pure transport swap): the transport never touches business
//     logic; it returns vendor-shaped JSON the existing adapter projects.
//   * HP #4 (per-operator isolation): plaintext credentials never leave
//     the transport boundary; the deps record carries a credential-store
//     resolver the production wiring backs with the operator-scoped
//     vendor_credentials table. The adapter only ever sees opaque
//     credential ids.
//   * HP #7 (F&F holds all provider keys server-side): no BYO-key path;
//     the partner credential pack (client_id + client_secret + venue_id)
//     and the issued bearer token are all server-side ciphertext.
//
// V1 lean-cut alignment (`memory/project_v1_lean_cut_2_2026_05_03.md`):
// no KMS rollout, no key-rotation UI hooks, no advisory locks, no
// SIGTERM drain handler, no DLQ tile mount, no raw-payload sibling
// tables, no 5-second test-connection SLA. The transport's job is the
// HTTP round trip and nothing more.
//
// Time Guardrails (CLAUDE.md):
//   * Vendor timestamps in JSON responses are passed through unmodified
//     (raw ISO-8601 strings with the vendor's offset preserved). The
//     adapter (not the transport) parses them via `DateTime.parse` and
//     hands the canonical sink the UTC instant + restaurant-local
//     business_date pairing per the time-boundary contract.
//   * No `TIMESTAMP WITHOUT TIME ZONE` reaches operator-scoped storage.
//
// No new pub deps — `package:http` is already a top-level dependency.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'sevenrooms_reservation_adapter.dart';

// ─── Documented endpoint paths ─────────────────────────────────────────
//
// Mirrors `docs/integrations/sevenrooms/api_consumed.md` row-for-row.
// Path templates use partner API version `2_2`. Constants are public so
// the test can grep them.

/// `POST /2_2/auth` — token exchange (client_id + client_secret +
/// venue_id → bearer access token).
const String kSevenRoomsAuthPath = '/2_2/auth';

/// `GET /2_2/reservations` — incremental polling.
const String kSevenRoomsReservationsPath = '/2_2/reservations';

/// `GET /2_2/reservations/export` — 60-day backfill source.
const String kSevenRoomsReservationsExportPath = '/2_2/reservations/export';

// ─── Defaults ──────────────────────────────────────────────────────────

/// Default per-page size (matches the adapter's `_kBackfillPageSize`).
const int _kDefaultPageSize = 100;

/// Default request timeout. SevenRooms reservation pages observed at
/// p99 ~3-5s in partner integration guides; 30s leaves margin for
/// slow venues without colliding with the route-layer timeout.
const Duration _kDefaultTimeout = Duration(seconds: 30);

/// Maximum number of retries on a 429 response. The transport retries
/// with exponential backoff bounded by `Retry-After`.
const int _kMax429Retries = 4;

/// Base delay for the 429 backoff. Doubled per retry up to a 30s cap.
const Duration _kBaseBackoff = Duration(milliseconds: 500);

/// Cap for the 429 backoff so a misbehaving vendor never wedges the
/// poll worker for minutes.
const Duration _kMaxBackoff = Duration(seconds: 30);

// ─── Credential store seam ─────────────────────────────────────────────

/// Resolves an opaque credential id (from `vendor_credentials.credential_id`)
/// to the plaintext bearer token the transport actually puts on the wire.
///
/// Production wires this to the operator-scoped credential store; the
/// transport never reads ciphertext directly and never holds plaintext
/// across requests.
abstract class SevenRoomsCredentialStore {
  /// Return the live bearer access token for [credentialId]. May refresh
  /// the bearer if it is near expiry; the production impl owns that
  /// detail. Throws [SevenRoomsAuthException] when the credential is
  /// missing, revoked, or expired.
  Future<String> resolveBearerToken({required String credentialId});

  /// Persist a freshly-issued bearer token + lifetime so subsequent
  /// resolve calls hit the cache instead of the auth endpoint. Returns
  /// the credential id the rest of the system addresses the token by.
  ///
  /// [clientSecret] and [venueId] are persisted alongside the bearer so
  /// the cross-tenant OAuth refresh worker (see
  /// `makeSevenRoomsOauthRefreshClosure` in
  /// `lib/integrations/_common/production_oauth_refresh_closures.dart`)
  /// can re-mint a fresh bearer via `POST /2_2/auth` without prompting
  /// the operator to reconnect. SevenRooms uses a `client_credentials`
  /// grant rather than a `refresh_token` grant, so re-exchange
  /// requires the full `(client_id, client_secret, venue_id)` triple
  /// rather than a refresh token. Phase 5 P1 closeout.
  Future<String> persistIssuedBearerToken({
    required String clientId,
    required String clientSecret,
    required String venueId,
    required String accessToken,
    required Duration? lifetime,
  });
}

// ─── Typed errors ──────────────────────────────────────────────────────

/// Common parent for every SevenRooms transport failure. The adapter +
/// worker dispatch on the runtime type to distinguish recoverable
/// (rate-limit) vs terminal (auth) failures.
sealed class SevenRoomsHttpException implements Exception {
  const SevenRoomsHttpException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'SevenRoomsHttpException(${statusCode ?? '-'}): $message';
}

/// Auth failure (401 / 403). The adapter flips connection status to
/// `error` after the OAuth-refresh cron's three-strike rule.
class SevenRoomsAuthException extends SevenRoomsHttpException {
  const SevenRoomsAuthException(super.message, {super.statusCode});

  @override
  String toString() =>
      'SevenRoomsAuthException(${statusCode ?? '-'}): $message';
}

/// Rate-limit failure (429) the transport could not retry within the
/// retry budget. The worker reschedules the tick at the next cron slot.
class SevenRoomsRateLimitException extends SevenRoomsHttpException {
  const SevenRoomsRateLimitException(
    super.message, {
    super.statusCode,
    this.retryAfter,
  });

  /// Suggested wait derived from the `Retry-After` response header.
  final Duration? retryAfter;

  @override
  String toString() =>
      'SevenRoomsRateLimitException(${statusCode ?? '-'}): $message '
      '(retryAfter=${retryAfter?.inSeconds ?? '-'}s)';
}

/// Vendor 5xx / network failure. The worker retries on the next tick.
class SevenRoomsServerException extends SevenRoomsHttpException {
  const SevenRoomsServerException(super.message, {super.statusCode});

  @override
  String toString() =>
      'SevenRoomsServerException(${statusCode ?? '-'}): $message';
}

/// Schema or non-JSON parse failure. The adapter logs a `parse_drop`
/// row via the gateway's sync log seam; never fed to the canonical
/// fact write path.
class SevenRoomsSchemaException extends SevenRoomsHttpException {
  const SevenRoomsSchemaException(super.message, {super.statusCode});

  @override
  String toString() =>
      'SevenRoomsSchemaException(${statusCode ?? '-'}): $message';
}

// ─── Shared transport core ─────────────────────────────────────────────

/// Shared request execution + retry / typed-error mapping. Used by the
/// auth client (POSTs) and the reservations client (GETs). The
/// reservations client also surfaces a per-call `Idempotency-Key`
/// helper so any future POST surface (e.g., a vendor "ack receipt"
/// endpoint should it emerge) inherits the convention without
/// re-implementing the retry path.
///
/// Public so the deps record can expose it for test-side overrides
/// (`SevenRoomsTransportDeps.core`); production wiring should not
/// reach in here directly.
class SevenRoomsHttpCore {
  SevenRoomsHttpCore({
    required this.baseUri,
    required this.httpClient,
    required this.timeout,
    required this.now,
    required this.random,
    required this.userAgent,
  });

  final Uri baseUri;
  final http.Client httpClient;
  final Duration timeout;
  final DateTime Function() now;
  final Random random;
  final String userAgent;

  Uri resolve(String path, [Map<String, String>? queryParameters]) {
    final basePathSegments = baseUri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final tail = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final composed = <String>[...basePathSegments, ...tail];
    final resolved = baseUri.replace(pathSegments: composed);
    if (queryParameters == null || queryParameters.isEmpty) {
      return resolved;
    }
    return resolved.replace(
      queryParameters: <String, String>{
        ...resolved.queryParameters,
        ...queryParameters,
      },
    );
  }

  Map<String, String> baseHeaders({required String? bearerToken}) {
    return <String, String>{
      'accept': 'application/json',
      'user-agent': userAgent,
      if (bearerToken != null && bearerToken.isNotEmpty)
        'authorization': 'Bearer $bearerToken',
    };
  }

  /// Executes [send] and applies the 429-with-backoff loop + typed
  /// error mapping. The closure receives an attempt number (zero-based)
  /// and must return the latest [http.Response].
  Future<http.Response> executeWithRetry(
    Future<http.Response> Function(int attempt) send, {
    required String operation,
  }) async {
    SevenRoomsRateLimitException? lastRateLimit;
    for (var attempt = 0; attempt <= _kMax429Retries; attempt++) {
      try {
        final response = await send(attempt).timeout(timeout);
        if (response.statusCode == 429) {
          final retryAfter = _parseRetryAfter(
            response.headers['retry-after'],
          );
          lastRateLimit = SevenRoomsRateLimitException(
            'SevenRooms rate-limited the $operation request.',
            statusCode: 429,
            retryAfter: retryAfter,
          );
          if (attempt == _kMax429Retries) break;
          await Future<void>.delayed(_backoffFor(attempt, retryAfter));
          continue;
        }
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw SevenRoomsAuthException(
            'SevenRooms refused the $operation request: '
            '${_summary(response)}',
            statusCode: response.statusCode,
          );
        }
        if (response.statusCode >= 500) {
          throw SevenRoomsServerException(
            'SevenRooms returned a server error on $operation: '
            '${_summary(response)}',
            statusCode: response.statusCode,
          );
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw SevenRoomsSchemaException(
            'SevenRooms returned ${response.statusCode} on $operation: '
            '${_summary(response)}',
            statusCode: response.statusCode,
          );
        }
        return response;
      } on TimeoutException catch (e) {
        throw SevenRoomsServerException(
          'SevenRooms $operation request timed out after '
          '${timeout.inSeconds}s: $e',
        );
      } on SocketException catch (e) {
        throw SevenRoomsServerException(
          'SevenRooms $operation network error: ${e.message}',
        );
      } on http.ClientException catch (e) {
        throw SevenRoomsServerException(
          'SevenRooms $operation client error: ${e.message}',
        );
      }
    }
    throw lastRateLimit ??
        SevenRoomsServerException(
          'SevenRooms $operation exhausted retry budget without a response.',
        );
  }

  Duration _backoffFor(int attempt, Duration? retryAfter) {
    if (retryAfter != null) {
      return retryAfter > _kMaxBackoff ? _kMaxBackoff : retryAfter;
    }
    final exponent = pow(2, attempt).toInt();
    final scaled = _kBaseBackoff * exponent;
    final capped = scaled > _kMaxBackoff ? _kMaxBackoff : scaled;
    // Jitter ±20% so concurrent ticks do not align retry storms.
    final jitterMs = (capped.inMilliseconds * 0.2).round();
    final offsetMs =
        jitterMs == 0 ? 0 : random.nextInt(jitterMs * 2 + 1) - jitterMs;
    final totalMs = capped.inMilliseconds + offsetMs;
    return Duration(milliseconds: totalMs < 0 ? 0 : totalMs);
  }

  Duration? _parseRetryAfter(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final trimmed = header.trim();
    final asInt = int.tryParse(trimmed);
    if (asInt != null) {
      return Duration(seconds: asInt < 0 ? 0 : asInt);
    }
    final asDate = HttpDate.parse(trimmed);
    final delta = asDate.difference(now()).inMilliseconds;
    return Duration(milliseconds: delta < 0 ? 0 : delta);
  }

  String _summary(http.Response response) {
    final body = response.body.trim();
    if (body.isEmpty) return '<empty body>';
    return body.length > 240 ? '${body.substring(0, 240)}...' : body;
  }

  /// Idempotency key generator for every POST surface. Format follows
  /// `docs/contracts/proxy_request_idempotency_contract.md` (UUID-style
  /// 16-byte hex). Production wiring may inject a stable generator if
  /// the worker needs to rebuild the same key after a Cloud Run Job
  /// restart.
  String generateIdempotencyKey() {
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = StringBuffer();
    for (final b in bytes) {
      hex.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return 'sr-${hex.toString()}';
  }
}

// ─── Auth client ───────────────────────────────────────────────────────

/// Production [SevenRoomsAuthClient] that exchanges the partner
/// credential pack (client_id + client_secret + venue_id) for a bearer
/// access token via `POST /2_2/auth`.
class SevenRoomsAuthProductionApiClient implements SevenRoomsAuthClient {
  SevenRoomsAuthProductionApiClient({
    required this.deps,
  });

  final SevenRoomsAuthProductionApiClientDeps deps;

  @override
  Future<SevenRoomsAuthResult> authenticate({
    required String clientId,
    required String clientSecret,
    required String venueId,
  }) async {
    final core = deps.core;
    final uri = core.resolve(kSevenRoomsAuthPath);
    final idempotencyKey = core.generateIdempotencyKey();
    final body = <String, Object?>{
      'client_id': clientId,
      'client_secret': clientSecret,
      'venue_id': venueId,
      'grant_type': 'client_credentials',
    };
    final response = await core.executeWithRetry(
      (_) async => core.httpClient.post(
        uri,
        headers: <String, String>{
          ...core.baseHeaders(bearerToken: null),
          'content-type': 'application/json',
          'idempotency-key': idempotencyKey,
        },
        body: jsonEncode(body),
      ),
      operation: 'auth',
    );
    final decoded = _decodeJsonObject(response.body, operation: 'auth');
    final accessToken = _readNonEmptyString(decoded, <String>[
      'access_token',
      'accessToken',
    ]);
    if (accessToken == null) {
      throw const SevenRoomsSchemaException(
        'SevenRooms /2_2/auth response missing access_token.',
      );
    }
    final returnedVenueId = _readNonEmptyString(decoded, <String>[
          'venue_id',
          'venueId',
        ]) ??
        venueId;
    final lifetime = _readLifetime(decoded);
    final credentialId = await deps.credentialStore.persistIssuedBearerToken(
      clientId: clientId,
      clientSecret: clientSecret,
      venueId: returnedVenueId,
      accessToken: accessToken,
      lifetime: lifetime,
    );
    return SevenRoomsAuthResult(
      venueId: returnedVenueId,
      accessTokenCredentialId: credentialId,
    );
  }

  @override
  Future<void> revoke({required String accessTokenCredentialId}) async {
    // SevenRooms does not document a public revoke endpoint per
    // `docs/integrations/sevenrooms/oauth_shape.md`. The transport
    // best-effort no-ops so disconnect is not blocked by a missing
    // upstream surface; the operator removing the F&F integration in
    // the SevenRooms admin portal invalidates credentials upstream.
    return;
  }

  Duration? _readLifetime(Map<String, Object?> decoded) {
    final raw = decoded['expires_in'] ?? decoded['expiresIn'];
    if (raw is num) return Duration(seconds: raw.toInt());
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null) return Duration(seconds: parsed);
    }
    return null;
  }
}

/// Deps record for [SevenRoomsAuthProductionApiClient]. Construct the
/// shared [SevenRoomsHttpCore] via [SevenRoomsTransportDeps.shared] so
/// the auth and reservations clients share one [http.Client] and one
/// retry policy.
class SevenRoomsAuthProductionApiClientDeps {
  const SevenRoomsAuthProductionApiClientDeps({
    required this.core,
    required this.credentialStore,
  });

  final SevenRoomsHttpCore core;
  final SevenRoomsCredentialStore credentialStore;
}

// ─── Reservations client ───────────────────────────────────────────────

/// Production [SevenRoomsReservationsClient] that hits
/// `GET /2_2/reservations` (poll) and `GET /2_2/reservations/export`
/// (backfill).
class SevenRoomsReservationsProductionApiClient
    implements SevenRoomsReservationsClient {
  SevenRoomsReservationsProductionApiClient({
    required this.deps,
  });

  final SevenRoomsReservationsProductionApiClientDeps deps;

  @override
  Future<SevenRoomsReservationsPage> fetchReservationsPage({
    required String accessTokenCredentialId,
    required String venueId,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required int pageSize,
    required bool useExport,
    String? cursorToken,
  }) async {
    final path = useExport
        ? kSevenRoomsReservationsExportPath
        : kSevenRoomsReservationsPath;
    final query = <String, String>{
      'venue_id': venueId,
      'updated_since': windowStartUtc.toUtc().toIso8601String(),
      'updated_until': windowEndUtc.toUtc().toIso8601String(),
      'page_size': _clampPageSize(pageSize).toString(),
      if (cursorToken != null && cursorToken.isNotEmpty)
        'page_token': cursorToken,
    };
    final response = await _get(path, query: query, operation: 'reservations');
    final decoded = _decodeJsonObject(
      response.body,
      operation: 'reservations',
    );
    final list = _readReservationList(decoded);
    final nextToken = _readNonEmptyString(decoded, <String>[
      'next_page_token',
      'nextPageToken',
    ]);
    return SevenRoomsReservationsPage(
      reservations: list,
      nextPageToken: nextToken,
    );
  }

  @override
  Future<Map<String, Object?>> fetchSampleReservation({
    required String accessTokenCredentialId,
    required String venueId,
  }) async {
    final response = await _get(
      kSevenRoomsReservationsPath,
      query: <String, String>{
        'venue_id': venueId,
        'page_size': '1',
      },
      operation: 'reservations.sample',
    );
    final decoded = _decodeJsonObject(
      response.body,
      operation: 'reservations.sample',
    );
    final list = _readReservationList(decoded);
    if (list.isEmpty) {
      return const <String, Object?>{};
    }
    return list.first;
  }

  Future<http.Response> _get(
    String path, {
    required Map<String, String> query,
    required String operation,
  }) async {
    final core = deps.core;
    final uri = core.resolve(path, query);
    return core.executeWithRetry(
      (_) async {
        final bearer = await deps.credentialStore.resolveBearerToken(
          credentialId: deps.credentialIdForRequest,
        );
        return core.httpClient.get(
          uri,
          headers: core.baseHeaders(bearerToken: bearer),
        );
      },
      operation: operation,
    );
  }

  int _clampPageSize(int requested) {
    if (requested <= 0) return _kDefaultPageSize;
    if (requested > _kDefaultPageSize) return _kDefaultPageSize;
    return requested;
  }
}

/// Deps record for [SevenRoomsReservationsProductionApiClient]. The
/// production wiring threads the live operator's
/// `accessTokenCredentialId` into [credentialIdForRequest] before each
/// call so the credential store resolves the right tenant's bearer.
class SevenRoomsReservationsProductionApiClientDeps {
  const SevenRoomsReservationsProductionApiClientDeps({
    required this.core,
    required this.credentialStore,
    required this.credentialIdForRequest,
  });

  final SevenRoomsHttpCore core;
  final SevenRoomsCredentialStore credentialStore;

  /// Opaque credential id (matches `vendor_credentials.credential_id`)
  /// the transport hands to [credentialStore.resolveBearerToken] for
  /// each outbound call. Production sets this per-request via the
  /// adapter-supplied `accessTokenCredentialId`; tests pass a fixed id.
  final String credentialIdForRequest;
}

// ─── Webhook client ────────────────────────────────────────────────────

/// Production [SevenRoomsWebhookClient]. SevenRooms uses `manualPaste`
/// per the capability profile; `subscribe()` MUST never be invoked by
/// the adapter. The production impl throws `StateError` on call so a
/// regression in the adapter surfaces immediately at the transport
/// boundary.
class SevenRoomsWebhookProductionApiClient implements SevenRoomsWebhookClient {
  const SevenRoomsWebhookProductionApiClient();

  @override
  Future<void> subscribe({
    required String accessTokenCredentialId,
    required String webhookUrl,
    required String venueId,
  }) async {
    throw StateError(
      'SevenRoomsWebhookProductionApiClient.subscribe MUST NOT be called '
      '— SevenRooms uses manualPaste; the operator pastes the F&F webhook '
      'URL into the SevenRooms admin portal. The adapter framework is '
      'expected to skip subscribe for VendorWebhookSupport.manualPaste.',
    );
  }
}

// ─── Composed deps ─────────────────────────────────────────────────────

/// Top-level deps record the production wiring assembles once per
/// adapter instance. Sharing one [SevenRoomsHttpCore] across the auth
/// and reservations surfaces means one [http.Client], one User-Agent,
/// one timeout, and one retry policy.
class SevenRoomsTransportDeps {
  SevenRoomsTransportDeps._({
    required this.core,
    required this.credentialStore,
  });

  /// Build the shared transport surface. [baseUri] defaults to the
  /// documented production endpoint and is overridable via
  /// [environmentBaseUri] (typically wired from
  /// `SEVENROOMS_API_BASE_URL`).
  factory SevenRoomsTransportDeps.shared({
    required SevenRoomsCredentialStore credentialStore,
    Uri? environmentBaseUri,
    http.Client? httpClient,
    Duration timeout = _kDefaultTimeout,
    DateTime Function()? now,
    Random? random,
    String? userAgent,
  }) {
    final base = environmentBaseUri ?? Uri.parse(kSevenRoomsProdBaseUrl);
    final core = SevenRoomsHttpCore(
      baseUri: base,
      httpClient: httpClient ?? http.Client(),
      timeout: timeout,
      now: now ?? DateTime.now,
      random: random ?? Random.secure(),
      userAgent: userAgent ??
          'forge-and-flow/$kSevenRoomsApiVersion (+sevenrooms-reservation)',
    );
    return SevenRoomsTransportDeps._(
      core: core,
      credentialStore: credentialStore,
    );
  }

  final SevenRoomsHttpCore core;
  final SevenRoomsCredentialStore credentialStore;

  /// Build an auth client from the shared deps.
  SevenRoomsAuthProductionApiClient buildAuthClient() {
    return SevenRoomsAuthProductionApiClient(
      deps: SevenRoomsAuthProductionApiClientDeps(
        core: core,
        credentialStore: credentialStore,
      ),
    );
  }

  /// Build a reservations client bound to a per-operator credential id.
  /// The adapter calls `lookupBinding` to resolve
  /// `accessTokenCredentialId` and threads it through to here for each
  /// fresh adapter instance.
  SevenRoomsReservationsProductionApiClient buildReservationsClient({
    required String credentialIdForRequest,
  }) {
    return SevenRoomsReservationsProductionApiClient(
      deps: SevenRoomsReservationsProductionApiClientDeps(
        core: core,
        credentialStore: credentialStore,
        credentialIdForRequest: credentialIdForRequest,
      ),
    );
  }
}

// ─── JSON helpers ──────────────────────────────────────────────────────

Map<String, Object?> _decodeJsonObject(
  String body, {
  required String operation,
}) {
  if (body.trim().isEmpty) {
    throw SevenRoomsSchemaException(
      'SevenRooms $operation response body was empty.',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw SevenRoomsSchemaException(
      'SevenRooms $operation response was not JSON: ${e.message}',
    );
  }
  if (decoded is! Map) {
    throw SevenRoomsSchemaException(
      'SevenRooms $operation response was not a JSON object.',
    );
  }
  return decoded.map(
    (key, value) => MapEntry<String, Object?>(key.toString(), value),
  );
}

List<Map<String, Object?>> _readReservationList(Map<String, Object?> decoded) {
  final raw = decoded['reservations'] ?? decoded['data'] ?? decoded['results'];
  if (raw is! List) {
    throw const SevenRoomsSchemaException(
      'SevenRooms reservations response missing reservations array.',
    );
  }
  final list = <Map<String, Object?>>[];
  for (final item in raw) {
    if (item is Map) {
      list.add(
        item.map(
          (key, value) => MapEntry<String, Object?>(key.toString(), value),
        ),
      );
    }
  }
  return list;
}

String? _readNonEmptyString(Map<String, Object?> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}
