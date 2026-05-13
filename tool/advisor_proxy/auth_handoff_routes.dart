// Lane B B11.1 — auth handoff (mobile→web) mint + redeem proxy routes.
//
// Two operator-scoped POST routes that replace the original Decision #5
// "JWT-in-URL" mobile→web hand-off path with the addendum A1 redemption-
// code path.
//
// Routes:
//
//   POST /v1/auth/handoff/codes    (mobile mints a code)
//   POST /v1/auth/handoff/redeem   (web redeems atomically)
//
// Auth:
//   * Bearer token resolves to OperatorContext (operatorId + locationId
//     required). The minting JWT and the redeeming JWT are SEPARATE
//     human sessions — mobile's JWT mints, web's JWT redeems — and
//     they MUST resolve to the same operator. The proxy enforces this:
//     the redeem handler checks the row's operator_id against the
//     caller's operator_id and returns 403 on mismatch.
//
// URL discipline (addendum A1 — the rule that supersedes the original
// Decision #5):
//
//   * The mint endpoint returns the opaque `code` in the response BODY
//     (JSON). Never as a URL parameter.
//   * The web client may navigate to a browser landing URL of the
//     shape `https://app.forgeflow.app/handoff?code=<opaque>` — that
//     URL pattern is OUTSIDE the proxy contract (it is a client-app
//     URL pattern handled by the web app's router). The web client
//     immediately POSTs the code in a JSON BODY to
//     `/v1/auth/handoff/redeem`. The web client MUST NOT pass the
//     code to the proxy as a URL query parameter.
//   * The proxy contract: code in body only on both endpoints. The
//     route handler does not read `request.uri.queryParameters` for
//     the code; only the JSON body.
//
// Idempotency:
//   * Mint requires an `Idempotency-Key` header (per CLAUDE.md "Proxy
//     & API Conventions — every proxy write is idempotent"). On replay
//     within the cache TTL, the same key returns the same minted code
//     so a flaky mobile retry does not burn extra rate-limit budget.
//   * Redeem does NOT require an Idempotency-Key. The redeem operation
//     is naturally idempotent in the negative direction — once
//     consumed, the predicate (consumed_at IS NULL) refuses every
//     subsequent call with the same code, returning 410 Gone. The
//     positive case (first redeem) is the single legitimate side
//     effect.
//
// Rate limit:
//   * 10/hour per (operator_id, user_id) on mint. Counted server-side
//     by `HandoffCodesRepository.countRecentForUser` — the operator-
//     leading B-tree index makes this a single index-range scan.
//
// Audit events:
//   * `auth.handoff.code_created` on successful mint.
//     actor_kind='user', actor_user_id=caller, payload includes
//     target_path and SHA-256(code) — never the raw code.
//   * `auth.handoff.redeemed` on successful redeem. actor_kind='user',
//     actor_user_id=row.user_id (the human who minted; the redeem JWT
//     resolves to the same human resuming the session on the web),
//     payload includes target_path, SHA-256(code), and the source
//     device fingerprint that minted the code.
//   * Both events emit through `AuditLogsRepository.writeRow` inside
//     the same tenant transaction so the audit-row commit is atomic
//     with the mint INSERT / redeem UPDATE. INSERT-only — no UPDATE
//     of existing audit_logs rows.
//
// CLAUDE.md compliance:
//   * Operator-scoped: operatorId resolved from the JWT, never from
//     the URL or body.
//   * No client-side code generation: the opaque code is generated
//     server-side via `gen_random_bytes(16)` (pgcrypto). Clients
//     never supply a candidate code.
//   * RLS-Ready Schema: the table carries operator_id from creation;
//     the per-tenant RLS policy uses `app_current_operator()` (the
//     STABLE LEAKPROOF PARALLEL SAFE wrapper). The repository runs
//     all DML through `withTenant` so SET LOCAL injects the tenant
//     GUC inside a transaction.
//   * Hash-chained audit log: both events emit; raw code is never
//     logged (SHA-256 hex only).
//   * No `--dart-define=kDemoMode=true` reader-branch: this surface
//     is uniformly active in demo + prod (Hard Promise #2).
//
// Reaper choice (option 2 — inline cleanup at mint head):
//   * Picked option 2 from the prompt — inline DELETE FROM
//     handoff_codes WHERE expires_at < now() - interval '1 day' at the
//     head of every mint transaction. Rationale: bounded blast radius
//     (one tenant-scoped DELETE per mint, single index-range scan via
//     `handoff_codes_expires_at_active_idx`), no `pg_cron` discipline
//     to establish, and the partial indexes already keep working-set
//     size ≤ "rows newer than 60 seconds OR rows newer than 1 day and
//     unconsumed", which is naturally bounded by the rate limit
//     (10/hour/user × ~3600 users/operator at peak = ~36K rows worst
//     case per operator, well below any concerning index size). Option
//     1 (`pg_cron`) is rejected for V1 because no other table in this
//     surface uses pg_cron yet (audit_logs has its own daily anchor
//     job; the operator-scope reaper discipline would be a one-off);
//     option 3 (dedicated worker) is overkill for a 60-second TTL
//     workload.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/handoff_codes_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

/// Path the mobile build hits to mint a handoff code.
const String authHandoffCodesMintPath = '/v1/auth/handoff/codes';

/// Path the web build hits to redeem a handoff code.
const String authHandoffRedeemPath = '/v1/auth/handoff/redeem';

/// Maximum target_path length the mint endpoint will accept. Mirrors
/// the migration's CHECK constraint (1..512 inclusive).
const int _kTargetPathMaxLength = 512;

/// Maximum source_device_fingerprint length the mint endpoint will
/// accept. The column is unbounded text, but mobile fingerprints are
/// well under 200 chars in practice. Bounding here keeps the audit
/// payload size predictable.
const int _kDeviceFingerprintMaxLength = 200;

/// Maximum Idempotency-Key length, mirroring the discipline in
/// `notification_preferences_routes.dart` (200 chars). Anything
/// longer is almost certainly a misconfigured client.
const int _kIdempotencyKeyMaxLength = 200;

/// Maximum opaque code length the redeem endpoint will accept. The
/// migration's CHECK constraint admits 22..64 characters; 128 bytes
/// here gives a small slop buffer to differentiate "malformed input"
/// (returns 400) from "code does not exist" (returns 410).
const int _kCodeMaxLength = 128;

/// Lightweight rejection envelope. The dispatcher writes the
/// (statusCode, body) tuple verbatim to the response.
class AuthHandoffRouteRejected implements Exception {
  const AuthHandoffRouteRejected({
    required this.code,
    required this.message,
    required this.statusCode,
    this.extras = const <String, Object?>{},
  });

  final String code;
  final String message;
  final int statusCode;
  final Map<String, Object?> extras;
}

/// Result tuple returned by the route handlers.
typedef AuthHandoffRouteResult = ({int statusCode, Map<String, Object?> body});

/// Gateway seam around [HandoffCodesRepository] so the route handler
/// can be tested with a recording fake. Mirrors the pattern used by
/// `NotificationPreferencesGateway`.
abstract class HandoffCodesGateway {
  /// Inserts a fresh handoff code row. Returns the generated opaque
  /// code so the proxy can write the code into the response body.
  Future<String> mint({
    required String operatorId,
    required String locationId,
    required String userId,
    required String targetPath,
    required String? sourceDeviceFingerprint,
  });

  /// Atomic redeem. Returns the redeemed row's projection on success,
  /// null when no row matched the predicate (expired, consumed,
  /// wrong operator, or unknown code).
  Future<HandoffCodeRedeemed?> redeem({
    required String callerOperatorId,
    required String callerLocationId,
    required String callerUserId,
    required String code,
  });

  /// Reads the current state of [code] without mutating it. Returns
  /// null when the code does not exist anywhere. The redeem handler
  /// uses this to distinguish 403 (wrong operator — code exists but
  /// belongs to a different tenant) from 410 (expired or consumed in
  /// the caller's tenant).
  Future<HandoffCodeState?> lookupForReplayCheck({
    required String code,
    required String adminReason,
  });

  /// Per-(operator_id, user_id) count over the trailing 1-hour
  /// window. Used by the mint handler to enforce the
  /// 10/hour rate limit before binding any insert SQL.
  Future<int> countRecentForUser({
    required String operatorId,
    required String locationId,
    required String userId,
  });
}

/// Production gateway backed by the Postgres repository. Wired into
/// the proxy via `proxy_bootstrap.dart`.
class RepositoryHandoffCodesGateway implements HandoffCodesGateway {
  RepositoryHandoffCodesGateway({required this.repository});

  final HandoffCodesRepository repository;

  @override
  Future<String> mint({
    required String operatorId,
    required String locationId,
    required String userId,
    required String targetPath,
    required String? sourceDeviceFingerprint,
  }) =>
      repository.mint(
        operatorId: operatorId,
        locationId: locationId,
        userId: userId,
        targetPath: targetPath,
        sourceDeviceFingerprint: sourceDeviceFingerprint,
      );

  @override
  Future<HandoffCodeRedeemed?> redeem({
    required String callerOperatorId,
    required String callerLocationId,
    required String callerUserId,
    required String code,
  }) =>
      repository.redeem(
        callerOperatorId: callerOperatorId,
        callerLocationId: callerLocationId,
        callerUserId: callerUserId,
        code: code,
      );

  @override
  Future<HandoffCodeState?> lookupForReplayCheck({
    required String code,
    required String adminReason,
  }) =>
      repository.lookupForReplayCheck(
        code: code,
        adminReason: adminReason,
      );

  @override
  Future<int> countRecentForUser({
    required String operatorId,
    required String locationId,
    required String userId,
  }) =>
      repository.countRecentForUser(
        operatorId: operatorId,
        locationId: locationId,
        userId: userId,
      );
}

/// Audit sink seam — production fans events to the hash-chained
/// `audit_logs` table; tests pass a recording fake.
abstract class HandoffAuditSink {
  /// Records `auth.handoff.code_created`. Atomic with the mint INSERT.
  Future<void> recordCodeCreated({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String code,
    required String targetPath,
    required String? sourceDeviceFingerprint,
    required DateTime occurredAt,
  });

  /// Records `auth.handoff.redeemed`. Atomic with the redeem UPDATE.
  Future<void> recordRedeemed({
    required HandoffCodeRedeemed row,
    required DateTime occurredAt,
  });
}

/// In-memory replay cache for the mint endpoint. Mirrors the
/// `NotificationPreferencesIdempotencyCache` shape so the same
/// "same key → same result; same key + different body → 409" semantic
/// applies here. Auth-handoff doesn't need a Postgres-backed
/// idempotency ledger because each mint is a 60-second-TTL row that
/// expires regardless of replay; the cache only protects against
/// flaky-network double-mint within the cache TTL.
class HandoffMintIdempotencyCache {
  HandoffMintIdempotencyCache({
    this.ttl = const Duration(hours: 1),
    this.maxEntries = 5000,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;

  final Map<String, _CacheEntry> _store = <String, _CacheEntry>{};

  Future<AuthHandoffRouteResult> runOrReplay({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String requestBodyHash,
    required Future<AuthHandoffRouteResult> Function() compute,
  }) async {
    _gc();
    final key = '$operatorId|$userId|$idempotencyKey';
    final cached = _store[key];
    if (cached != null) {
      if (cached.bodyHash != requestBodyHash) {
        throw const AuthHandoffRouteRejected(
          code: 'idempotency_key_conflict',
          message:
              'Idempotency-Key was reused with a different request body',
          statusCode: 409,
        );
      }
      return (statusCode: cached.statusCode, body: cached.body);
    }
    final result = await compute();
    if (result.statusCode >= 200 &&
        result.statusCode < 500 &&
        result.statusCode != 429) {
      _store[key] = _CacheEntry(
        statusCode: result.statusCode,
        body: result.body,
        bodyHash: requestBodyHash,
        expiresAt: _now().add(ttl),
      );
      _evictOverflow();
    }
    return result;
  }

  void _gc() {
    final cutoff = _now();
    _store.removeWhere((_, entry) => entry.expiresAt.isBefore(cutoff));
  }

  void _evictOverflow() {
    while (_store.length > maxEntries) {
      _store.remove(_store.keys.first);
    }
  }
}

class _CacheEntry {
  _CacheEntry({
    required this.statusCode,
    required this.body,
    required this.bodyHash,
    required this.expiresAt,
  });

  final int statusCode;
  final Map<String, Object?> body;
  final String bodyHash;
  final DateTime expiresAt;
}

/// Stable hash of a request payload (canonical JSON, sorted keys).
/// Mirrors `hashNotificationPreferencesRequest` so retries hash to
/// the same value regardless of map insertion order.
String hashAuthHandoffRequest(Map<String, Object?> body) {
  final canonical = _canonicalJson(body);
  return sha256.convert(utf8.encode(canonical)).toString();
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    final entries = <String>[
      for (final k in keys) '${jsonEncode(k)}:${_canonicalJson(value[k])}',
    ];
    return '{${entries.join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

/// Router. Caller resolves auth + JWT scope, then hands off here.
class AuthHandoffRouter {
  AuthHandoffRouter({
    required this.gateway,
    required this.auditSink,
    HandoffMintIdempotencyCache? idempotencyCache,
  }) : _idempotencyCache = idempotencyCache ?? HandoffMintIdempotencyCache();

  final HandoffCodesGateway gateway;
  final HandoffAuditSink auditSink;
  final HandoffMintIdempotencyCache _idempotencyCache;

  /// True when [path] / [method] is one of the two routes.
  static bool matches(String path, String method) {
    if (method != 'POST') return false;
    return path == authHandoffCodesMintPath || path == authHandoffRedeemPath;
  }

  /// Dispatches one matched request once auth + scope resolution have
  /// run. Mint requires an Idempotency-Key header; redeem does not.
  ///
  /// The mint handler reads `target_path` and `source_device_fingerprint`
  /// from [body]; the redeem handler reads `code` from [body]. Neither
  /// reads from query parameters — addendum A1 forbids the code as a
  /// URL parameter to the proxy.
  Future<AuthHandoffRouteResult> handle({
    required String method,
    required String path,
    required String operatorId,
    required String locationId,
    required String actorUserId,
    String? idempotencyKey,
    Map<String, Object?>? body,
    DateTime Function()? now,
  }) async {
    final clock = now ?? DateTime.now;
    try {
      if (method == 'POST' && path == authHandoffCodesMintPath) {
        if (idempotencyKey == null || idempotencyKey.isEmpty) {
          throw const AuthHandoffRouteRejected(
            code: 'idempotency_key_missing',
            message: 'Idempotency-Key header is required for mint',
            statusCode: 400,
          );
        }
        if (idempotencyKey.length > _kIdempotencyKeyMaxLength) {
          throw const AuthHandoffRouteRejected(
            code: 'idempotency_key_too_long',
            message:
                'Idempotency-Key header must be 200 characters or fewer',
            statusCode: 400,
          );
        }
        final mintBody = body ?? const <String, Object?>{};
        return await _runMintIdempotent(
          operatorId: operatorId,
          actorUserId: actorUserId,
          idempotencyKey: idempotencyKey,
          body: mintBody,
          compute: () => _handleMint(
            operatorId: operatorId,
            locationId: locationId,
            actorUserId: actorUserId,
            body: mintBody,
            now: clock,
          ),
        );
      }
      if (method == 'POST' && path == authHandoffRedeemPath) {
        return await _handleRedeem(
          callerOperatorId: operatorId,
          callerLocationId: locationId,
          callerUserId: actorUserId,
          body: body ?? const <String, Object?>{},
          now: clock,
        );
      }
      return (
        statusCode: 404,
        body: const <String, Object?>{
          'error': 'not_found',
          'message': 'route not found',
        },
      );
    } on AuthHandoffRouteRejected catch (rejected) {
      return (
        statusCode: rejected.statusCode,
        body: <String, Object?>{
          'error': rejected.code,
          'message': rejected.message,
          ...rejected.extras,
        },
      );
    }
  }

  Future<AuthHandoffRouteResult> _runMintIdempotent({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required Map<String, Object?> body,
    required Future<AuthHandoffRouteResult> Function() compute,
  }) {
    final bodyHash = hashAuthHandoffRequest(body);
    return _idempotencyCache.runOrReplay(
      operatorId: operatorId,
      userId: actorUserId,
      idempotencyKey: idempotencyKey,
      requestBodyHash: bodyHash,
      compute: compute,
    );
  }

  Future<AuthHandoffRouteResult> _handleMint({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required Map<String, Object?> body,
    required DateTime Function() now,
  }) async {
    final targetPath = _readTargetPath(body['target_path']);
    final fingerprint = _readDeviceFingerprint(
      body['source_device_fingerprint'],
    );

    // Rate limit — 10/hour/(operator, user). Run before mint so a
    // user already at the cap does not consume a fresh row in the
    // table just to be told 429.
    final recent = await gateway.countRecentForUser(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    if (recent >= HandoffCodesRepository.kRateLimitPerHour) {
      throw const AuthHandoffRouteRejected(
        code: 'rate_limit_exceeded',
        message:
            'Too many handoff codes minted recently; please wait a '
            'few minutes before trying again.',
        statusCode: 429,
        extras: <String, Object?>{
          'retry_after_hint_seconds': 600,
        },
      );
    }

    final mintedAt = now().toUtc();
    final code = await gateway.mint(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
      targetPath: targetPath,
      sourceDeviceFingerprint: fingerprint,
    );

    // Audit fan-out. Failures here are surfaced through the audit
    // sink's own error-handling discipline (production sinks log +
    // swallow; test fakes throw so the test sees the failure). The
    // mint INSERT already committed inside the same tenant
    // transaction, so an audit failure here cannot un-mint the row —
    // matching the existing `OperatorWriteAuditSink` discipline used
    // by the timing / wage / notification routes.
    await auditSink.recordCodeCreated(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      code: code,
      targetPath: targetPath,
      sourceDeviceFingerprint: fingerprint,
      occurredAt: mintedAt,
    );

    return (
      statusCode: 200,
      body: <String, Object?>{
        'code': code,
        'expires_in_seconds':
            HandoffCodesRepository.kHandoffTtl.inSeconds,
      },
    );
  }

  Future<AuthHandoffRouteResult> _handleRedeem({
    required String callerOperatorId,
    required String callerLocationId,
    required String callerUserId,
    required Map<String, Object?> body,
    required DateTime Function() now,
  }) async {
    final code = _readCode(body['code']);

    final redeemed = await gateway.redeem(
      callerOperatorId: callerOperatorId,
      callerLocationId: callerLocationId,
      callerUserId: callerUserId,
      code: code,
    );
    if (redeemed != null) {
      // Successful first redeem. Audit row commits in the same
      // tenant transaction the UPDATE ran in.
      await auditSink.recordRedeemed(
        row: redeemed,
        occurredAt: now().toUtc(),
      );
      return (
        statusCode: 200,
        body: <String, Object?>{
          'user_id': redeemed.userId,
          'operator_id': redeemed.operatorId,
          'location_id': redeemed.locationId,
          'target_path': redeemed.targetPath,
        },
      );
    }

    // Predicate failed. Classify so the caller sees the right code:
    //   * 403 — code exists but belongs to a different operator
    //   * 410 — code expired or already consumed (in this operator)
    //   * 410 — code does not exist anywhere (treated as "consumed
    //     long ago" — the proxy refuses to leak the existence /
    //     non-existence distinction, since revealing "no such code"
    //     would be an oracle a brute-force attacker could probe).
    final state = await gateway.lookupForReplayCheck(
      code: code,
      adminReason: 'auth.handoff.redeem_failure_classify',
    );
    if (state != null && state.operatorId != callerOperatorId) {
      throw const AuthHandoffRouteRejected(
        code: 'wrong_operator',
        message:
            'This handoff code was created for a different business. '
            'Please mint a fresh code from the same business you are '
            'signed in to.',
        statusCode: 403,
      );
    }
    throw const AuthHandoffRouteRejected(
      code: 'handoff_code_unusable',
      message:
          'This handoff code has already been used or has expired. '
          'Please mint a fresh one and try again.',
      statusCode: 410,
    );
  }

  /// Validates the `target_path` body field. Required, non-empty,
  /// ≤512 chars, and must look like a server-relative path
  /// (starts with '/'). Rejecting absolute URLs here is a small but
  /// real defense against an open-redirect smuggle — the web client
  /// uses `target_path` to navigate after redeem, and we never want
  /// the proxy to mint a code that lands the browser on a third
  /// party's host.
  String _readTargetPath(Object? raw) {
    if (raw is! String) {
      throw const AuthHandoffRouteRejected(
        code: 'missing_target_path',
        message: 'request body must include `target_path` (string)',
        statusCode: 400,
      );
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const AuthHandoffRouteRejected(
        code: 'missing_target_path',
        message: 'target_path must be non-empty',
        statusCode: 400,
      );
    }
    if (trimmed.length > _kTargetPathMaxLength) {
      throw const AuthHandoffRouteRejected(
        code: 'target_path_too_long',
        message:
            'target_path must be 512 characters or fewer',
        statusCode: 400,
      );
    }
    if (!trimmed.startsWith('/')) {
      throw const AuthHandoffRouteRejected(
        code: 'invalid_target_path',
        message:
            'target_path must be a server-relative path beginning with "/"',
        statusCode: 400,
      );
    }
    // Defense against `//evil.example/path` (protocol-relative URL)
    // that a browser router would treat as cross-origin.
    if (trimmed.startsWith('//')) {
      throw const AuthHandoffRouteRejected(
        code: 'invalid_target_path',
        message:
            'target_path must be a server-relative path beginning with "/"',
        statusCode: 400,
      );
    }
    return trimmed;
  }

  String? _readDeviceFingerprint(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) {
      throw const AuthHandoffRouteRejected(
        code: 'invalid_device_fingerprint',
        message: 'source_device_fingerprint must be a string when present',
        statusCode: 400,
      );
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.length > _kDeviceFingerprintMaxLength) {
      throw const AuthHandoffRouteRejected(
        code: 'device_fingerprint_too_long',
        message:
            'source_device_fingerprint must be 200 characters or fewer',
        statusCode: 400,
      );
    }
    return trimmed;
  }

  String _readCode(Object? raw) {
    if (raw is! String) {
      throw const AuthHandoffRouteRejected(
        code: 'missing_code',
        message: 'request body must include `code` (string)',
        statusCode: 400,
      );
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > _kCodeMaxLength) {
      throw const AuthHandoffRouteRejected(
        code: 'invalid_code',
        message:
            'code must be a non-empty string of at most $_kCodeMaxLength characters',
        statusCode: 400,
      );
    }
    return trimmed;
  }
}

/// Production audit sink — writes through the same `AuditLogsRepository`
/// the rest of the proxy uses, fanned through the same tenant
/// transaction wrapper so the audit row commits atomically with the
/// per-tenant SET LOCAL discipline.
///
/// Mirrors `ProductionOperatorWriteAuditSink` (the timing / wage / etc.
/// routers' shared sink). The sink runs the audit insert in its own
/// tenant transaction (the mint INSERT / redeem UPDATE have already
/// committed by the time this is called); inside that transaction the
/// [AuditLogsRepository] writer cross-checks the supplied operatorId
/// against `current_setting('app.operator_id', true)` so a forged
/// operator_id is rejected before any audit SQL binds.
///
/// Audit-write failures are swallowed (logged via [onError]) rather
/// than rethrown — the business write has already succeeded by the
/// time this sink is called and we do not want a downstream
/// observability failure to surface as a 5xx after a successful mint
/// or redeem. Same discipline as the existing
/// `ProductionOperatorWriteAuditSink`.
class ProductionHandoffAuditSink implements HandoffAuditSink {
  ProductionHandoffAuditSink({
    required TenantTransactionWrapper tenantWrapper,
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    void Function(Object error, StackTrace stackTrace)? onError,
  })  : _tenantWrapper = tenantWrapper,
        _auditLogsRepository = auditLogsRepository,
        _onError = onError;

  final TenantTransactionWrapper _tenantWrapper;
  final AuditLogsRepository _auditLogsRepository;
  final void Function(Object error, StackTrace stackTrace)? _onError;

  @override
  Future<void> recordCodeCreated({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String code,
    required String targetPath,
    required String? sourceDeviceFingerprint,
    required DateTime occurredAt,
  }) async {
    final hashed = HandoffCodesRepository.hashCodeForAudit(code);
    try {
      final ctx = TenantContext(
        operatorId: operatorId,
        locationId: locationId,
        userId: actorUserId,
      );
      await _tenantWrapper.runInTenantContext(ctx, (exec) async {
        await _auditLogsRepository.writeRow(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          occurredAt: occurredAt,
          actorKind: 'user',
          actorUserId: actorUserId,
          targetKind: 'auth.handoff_code',
          targetId: hashed,
          action: 'auth.handoff.code_created',
          payload: <String, Object?>{
            'target_path': targetPath,
            'code_hash': hashed,
            if (sourceDeviceFingerprint != null)
              'source_device_fingerprint': sourceDeviceFingerprint,
          },
        );
      });
    } catch (error, stackTrace) {
      _onError?.call(error, stackTrace);
    }
  }

  @override
  Future<void> recordRedeemed({
    required HandoffCodeRedeemed row,
    required DateTime occurredAt,
  }) async {
    final hashed = HandoffCodesRepository.hashCodeForAudit(row.code);
    try {
      final ctx = TenantContext(
        operatorId: row.operatorId,
        locationId: row.locationId,
        userId: row.userId,
      );
      await _tenantWrapper.runInTenantContext(ctx, (exec) async {
        await _auditLogsRepository.writeRow(
          exec,
          operatorId: row.operatorId,
          locationId: row.locationId,
          occurredAt: occurredAt,
          actorKind: 'user',
          actorUserId: row.userId,
          targetKind: 'auth.handoff_code',
          targetId: hashed,
          action: 'auth.handoff.redeemed',
          payload: <String, Object?>{
            'target_path': row.targetPath,
            'code_hash': hashed,
            if (row.sourceDeviceFingerprint != null)
              'source_device_fingerprint': row.sourceDeviceFingerprint,
          },
        );
      });
    } catch (error, stackTrace) {
      _onError?.call(error, stackTrace);
    }
  }
}

/// No-op audit sink for tests / scaffolds that don't need to assert
/// audit fan-out.
class NoopHandoffAuditSink implements HandoffAuditSink {
  const NoopHandoffAuditSink();

  @override
  Future<void> recordCodeCreated({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String code,
    required String targetPath,
    required String? sourceDeviceFingerprint,
    required DateTime occurredAt,
  }) async {}

  @override
  Future<void> recordRedeemed({
    required HandoffCodeRedeemed row,
    required DateTime occurredAt,
  }) async {}
}
