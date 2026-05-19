// Phase 11W.7 / Wave A2 - Operator-scoped account write gateway.
//
// Thin HTTP client over the operator-scoped account write route. The
// AccountScreen (business-identity editor) calls this gateway to
// PATCH the operator's business name, logo URL, currency, locale,
// and week-start day. Legacy rollover values remain readable for
// compatibility, but Business Timing owns business-day start edits.
//
// Route contract (operator-scoped, NOT /v1/admin/*):
//   PATCH /v1/operator/account
//
// Headers:
//   Authorization: Bearer <id token>
//   Idempotency-Key: <generated per request>
//
// The route is consumer-side only; the matching server-side handler
// lands in the A2-backend lane. Gateway tests pin the request shape
// so the backend knows exactly what to implement.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:meta/meta.dart';

import '../../auth/mfa_freshness_redirect_listener.dart';
import '../auth/step_up_challenge_handler.dart';
import 'operator_web_proxy_client.dart';

/// Operator-scoped business-identity surface. The frontend gateway
/// never produces an `/admin/` path; cross-tenant overrides live
/// behind the F&F Ops Console (separate worktree).
abstract class WebAccountGateway {
  /// 11W.7 ops-debt - GETs the operator's business identity. Returns
  /// the resolved row from `public.operators`.
  Future<AccountIdentity> getAccount();

  /// Patches the operator's business identity. Every field on
  /// [patch] is optional; the backend treats absent keys as
  /// "leave alone." Returns the resolved row after the write.
  Future<AccountIdentity> patchAccount(AccountIdentityPatch patch);

  /// Wave 2 W-6 - patches the primary location's IANA timezone.
  /// The write delegates server-side to
  /// `LocationsRepository.updateLocation(timezone: ...)`.
  ///
  /// Operator-scoped per HP #11: timezone is a location-scoped field;
  /// the route resolves the primary location from the caller's JWT.
  /// Returns the updated effective timezone after the write so the
  /// caller can refresh the UI without re-querying.
  ///
  /// Ops-debt: the matching backend handler lands in the W-6 backend
  /// follow-up lane (mirrors the 11W.7 ops-debt pattern for
  /// `/v1/operator/account`). Until then, callers will see a 404 from
  /// the proxy. The gateway shape is pinned here so the lane has an
  /// exact wire contract to implement against.
  Future<AccountLocationTimezone> patchLocationTimezone(
    AccountLocationTimezonePatch patch,
  );

  /// Wave 2 W-3 — self-service profile editor. Distinct from
  /// [patchAccount] (which writes operator business-identity columns)
  /// and from the W-1 admin-side `members_admin_gateway.updateMember`
  /// (which edits *someone else's* user row). This call patches the
  /// signed-in operator user's own `display_name` and/or `email`.
  ///
  /// The proxy route `/v1/auth/self/profile` resolves the target user
  /// from the verified bearer token; a client never supplies a target
  /// user id.
  Future<SelfProfilePatchResult> patchSelfProfile(
    SelfProfilePatchPayload patch,
  );

  /// Wave 2 U-FU-hp11-account — load the resolved effective / override
  /// / businessDefault triple for [locationId]. The AccountScreen
  /// uses this to render the HP #11 inheritance line at non-Business
  /// scope.
  Future<LocationAccountOverridesEnvelope> getLocationAccountOverrides({
    required String locationId,
  });

  /// Wave 2 U-FU-hp11-account — patch the override row for
  /// [locationId]. Every field on [patch] is optional; the backend
  /// treats absent keys as "leave alone" and explicit null as
  /// "clear the override (revert to business default)".
  Future<LocationAccountOverridesEnvelope> patchLocationAccountOverrides({
    required String locationId,
    required LocationAccountOverridesPatchPayload patch,
  });
}

/// User-scoped account session surface for My Account. Reuses the
/// existing Phase 9 active-session proxy routes; there is deliberately
/// no My Account-only proxy route here.
abstract class WebAccountSessionGateway {
  /// Lists the signed-in operator user's own sessions.
  Future<AccountActiveSessionsListed> listActiveSessions();

  /// Revokes every supplied session id using the existing single-session
  /// revoke route. Callers exclude the current session before invoking this.
  Future<AccountSessionSignOutOthersResult> signOutOtherSessions({
    required Iterable<String> sessionIds,
  });
}

/// Default implementation. Wraps [OperatorWebProxyClient.patchJson]
/// so token, idempotency-key, and error-mapping logic is shared with
/// the rest of the operator-web HTTP surface.
class HttpWebAccountGateway
    implements WebAccountGateway, WebAccountSessionGateway {
  HttpWebAccountGateway({
    required OperatorWebProxyClient client,
    required Future<String?> Function() idTokenProvider,
    DateTime Function()? now,
    StepUpChallengeReauthHook? stepUpReauthHook,
  }) : _client = client,
       _idTokenProvider = idTokenProvider,
       _now = now ?? DateTime.now,
       _stepUpReauthHook =
           stepUpReauthHook ?? const NoopStepUpChallengeReauthHook();

  final OperatorWebProxyClient _client;
  final Future<String?> Function() _idTokenProvider;
  final DateTime Function() _now;

  /// B11.2.b — server-side step-up reauth driver. When the proxy
  /// returns a step-up 401 challenge on revoke / MFA-remove / etc.,
  /// the gateway calls `hook.resolveFreshAuth(offer)`, gets a fresh
  /// ID token, and replays the original request with
  /// `Step-Up-Challenge-Id` as a request HEADER (addendum A1: never
  /// a URL param). When the hook is the [NoopStepUpChallengeReauthHook]
  /// (default), the gateway surfaces the 401 unchanged so the screen
  /// layer can fall back to its existing failure UX.
  final StepUpChallengeReauthHook _stepUpReauthHook;

  /// Operator-scoped route. The unit-test contract pins this string.
  static const String operatorAccountPath = '/v1/operator/account';

  /// Wave 2 W-6 - operator-scoped route for the primary location's
  /// IANA timezone. The handler lands in the W-6 backend follow-up
  /// (mirrors the 11W.7 ops-debt model where the frontend gateway
  /// shipped first with the wire contract pinned).
  static const String operatorLocationTimezonePath =
      '/v1/operator/location-timezone';

  /// Existing self-service auth-session routes. These stay user-scoped and
  /// avoid `/v1/admin/*` or any B9.2-only schema additions.
  static const String activeSessionsPath = '/v1/auth/sessions';
  static const String revokeSessionPath = '/v1/auth/session/revoke';

  /// Wave 2 W-3 — self-service profile editor route. The proxy
  /// resolves the target user from the verified bearer token.
  static const String selfProfilePath = '/v1/auth/self/profile';

  /// Wave 2 U-FU-hp11-account — per-location override path prefix.
  /// The location id is appended as a single path segment by
  /// [operatorLocationAccountOverridesPath].
  static const String operatorLocationAccountOverridesPathPrefix =
      '/v1/operator/location-account-overrides/';

  /// Wave 2 U-FU-hp11-account — builds the per-location override
  /// path for [locationId].
  static String operatorLocationAccountOverridesPath(String locationId) =>
      '$operatorLocationAccountOverridesPathPrefix$locationId';
  static const Duration _freshMfaWindow = Duration(hours: 1);
  static const String _freshMfaRedirectUri =
      '/auth/login?reason=fresh_mfa_required';

  /// B11.2.b deep-audit P1 fix — clock-skew tolerance for the
  /// `_requireFreshMfaToken` `auth_time > now` rejection branch.
  /// Without this window, legitimate client/server clock drift (any
  /// browser whose local clock is even a few seconds ahead of the
  /// proxy) trips the "auth_time is in the future" guard and forces a
  /// spurious re-auth. ±60s is the same skew tolerance Identity
  /// Platform applies to its own server-side ID token validation and
  /// is the standard JWT skew window (RFC 7519 §4.1.4 leeway).
  ///
  /// Tokens with auth_time MORE than 60s in the future are still
  /// rejected — that's a clock the operator must fix, or a malicious
  /// token with a forged future stamp.
  @visibleForTesting
  static const Duration freshMfaClockSkewWindow = Duration(seconds: 60);

  @override
  Future<AccountIdentity> getAccount() async {
    if (operatorAccountPath.contains('/admin/')) {
      throw const _AdminRouteForbidden();
    }
    final token = await _requireToken(
      'Sign in again to load your business account.',
    );
    final response = await _client.getJson(operatorAccountPath, idToken: token);
    return AccountIdentity.fromJson(response.body);
  }

  @override
  Future<AccountIdentity> patchAccount(AccountIdentityPatch patch) async {
    if (operatorAccountPath.contains('/admin/')) {
      // Belt and suspenders: the operator-web console must never
      // resolve an /admin/ path. The path constant above already
      // guarantees this, but the assertion makes route drift loud.
      throw const _AdminRouteForbidden();
    }
    final token = await _requireToken(
      'Sign in again to update your business account.',
    );
    final body = patch.toJson();
    final response = await _client.patchJson(
      operatorAccountPath,
      idToken: token,
      body: body,
      // G60 — caller-STABLE idempotency key. The payload uniquely
      // identifies this logical identity write, so a retry of the
      // same edit reuses the same key (collapses against the proxy
      // `proxy_requests` UNIQUE guard) while a different edit gets a
      // distinct key.
      extraHeaders: _stableKeyHeader('account-patch', <Object?>[body]),
    );
    return AccountIdentity.fromJson(response.body);
  }

  @override
  Future<AccountLocationTimezone> patchLocationTimezone(
    AccountLocationTimezonePatch patch,
  ) async {
    if (operatorLocationTimezonePath.contains('/admin/')) {
      throw const _AdminRouteForbidden();
    }
    final token = await _requireToken(
      'Sign in again to update your location timezone.',
    );
    final body = patch.toJson();
    final response = await _client.patchJson(
      operatorLocationTimezonePath,
      idToken: token,
      body: body,
      // G60 — caller-stable key per logical timezone write.
      extraHeaders: _stableKeyHeader('location-timezone-patch', <Object?>[
        body,
      ]),
    );
    return AccountLocationTimezone.fromJson(response.body);
  }

  @override
  Future<SelfProfilePatchResult> patchSelfProfile(
    SelfProfilePatchPayload patch,
  ) async {
    if (selfProfilePath.contains('/admin/')) {
      throw const _AdminRouteForbidden();
    }
    final token = await _requireToken('Sign in again to update your profile.');
    // Mirror the freshness gate the security section already uses for
    // sensitive writes. The operator's last sign-in must be inside the
    // `_freshMfaWindow` before we'll let them change email.
    if ((patch.email ?? '').isNotEmpty) {
      _requireFreshMfaToken(token);
    }
    final body = patch.toJson();
    final response = await _client.patchJson(
      selfProfilePath,
      idToken: token,
      body: body,
      // G60 — caller-stable key per logical self-profile write.
      extraHeaders: _stableKeyHeader('self-profile-patch', <Object?>[body]),
    );
    return SelfProfilePatchResult.fromJson(response.body);
  }

  @override
  Future<LocationAccountOverridesEnvelope> getLocationAccountOverrides({
    required String locationId,
  }) async {
    final path = operatorLocationAccountOverridesPath(locationId);
    if (path.contains('/admin/')) {
      throw const _AdminRouteForbidden();
    }
    final token = await _requireToken(
      'Sign in again to load this location\'s account overrides.',
    );
    final response = await _client.getJson(path, idToken: token);
    return LocationAccountOverridesEnvelope.fromJson(response.body);
  }

  @override
  Future<LocationAccountOverridesEnvelope> patchLocationAccountOverrides({
    required String locationId,
    required LocationAccountOverridesPatchPayload patch,
  }) async {
    final path = operatorLocationAccountOverridesPath(locationId);
    if (path.contains('/admin/')) {
      throw const _AdminRouteForbidden();
    }
    final token = await _requireToken(
      'Sign in again to update this location\'s account overrides.',
    );
    final body = patch.toJson();
    final response = await _client.patchJson(
      path,
      idToken: token,
      body: body,
      // G60 — caller-stable key scoped to the location + payload, so
      // retrying the same override edit collapses but a different
      // location / different edit does not.
      extraHeaders: _stableKeyHeader(
        'location-account-overrides-patch',
        <Object?>[locationId, body],
      ),
    );
    return LocationAccountOverridesEnvelope.fromJson(response.body);
  }

  @override
  Future<AccountActiveSessionsListed> listActiveSessions() async {
    if (activeSessionsPath.contains('/admin/')) {
      throw const _AdminRouteForbidden();
    }
    final token = await _requireToken(
      'Sign in again to load your active sessions.',
    );
    final response = await _client.getJson(activeSessionsPath, idToken: token);
    final raw = response.body['sessions'];
    if (raw is! List) {
      throw const OperatorWebProxyException(
        code: 'malformed_active_sessions',
        message: 'The proxy returned an incomplete active sessions list.',
      );
    }
    return AccountActiveSessionsListed(
      sessions: List<AccountActiveSessionEntry>.unmodifiable(
        raw.map(AccountActiveSessionEntry.fromJson),
      ),
    );
  }

  @override
  Future<AccountSessionSignOutOthersResult> signOutOtherSessions({
    required Iterable<String> sessionIds,
  }) async {
    if (revokeSessionPath.contains('/admin/')) {
      throw const _AdminRouteForbidden();
    }
    final ids = <String>{
      for (final sessionId in sessionIds)
        if (sessionId.trim().isNotEmpty) sessionId.trim(),
    }.toList(growable: false);
    if (ids.isEmpty) {
      return const AccountSessionSignOutOthersResult(revokedCount: 0);
    }
    final token = await _requireToken(
      'Sign in again before signing out other sessions.',
    );
    _requireFreshMfaToken(token);
    var revokedCount = 0;
    for (final sessionId in ids) {
      final revoked = await _revokeOnceWithStepUp(
        sessionId: sessionId,
        token: token,
      );
      if (revoked) revokedCount += 1;
    }
    return AccountSessionSignOutOthersResult(revokedCount: revokedCount);
  }

  /// Issues one revoke + drives the B11.2.b step-up flow when the
  /// proxy returns a 401 challenge. Returns true when the revoke
  /// succeeded (either on the first try OR on the post-step-up
  /// replay). Re-throws non-step-up errors verbatim.
  Future<bool> _revokeOnceWithStepUp({
    required String sessionId,
    required String token,
    String? stepUpChallengeId,
  }) async {
    try {
      final response = await _client.postJson(
        revokeSessionPath,
        idToken: token,
        body: <String, Object?>{
          'session_id': sessionId,
          'reason': 'my_account.sign_out_other_sessions',
        },
        extraHeaders: <String, String>{
          // G60 — caller-stable key per revoked session id. Retrying
          // the revoke of the SAME session reuses the same key; a
          // step-up replay of that same revoke deliberately keeps the
          // same key too (it is the same logical revoke, just
          // re-authenticated) so the proxy collapses the duplicate.
          ..._stableKeyHeader('session-revoke', <Object?>[sessionId]),
          if (stepUpChallengeId != null)
            // Addendum A1: the challenge id is a REQUEST HEADER
            // value. Never appended to revokeSessionPath as a
            // URL parameter.
            kStepUpChallengeIdHeader: stepUpChallengeId,
        },
      );
      return _readBool(response.body['revoked']) ??
          _readBool(response.body['ok']) ??
          true;
    } on OperatorWebProxyException catch (failure) {
      final offer = StepUpChallengeOffer.tryParse(
        statusCode: failure.statusCode ?? 0,
        headers: failure.responseHeaders ?? const <String, String>{},
        body: failure.responseBody ?? const <String, Object?>{},
      );
      if (offer == null) rethrow;
      // Already replaying once — don't loop. The proxy returned
      // another challenge on the replay (TTL expired, etc.) so
      // surface to the caller.
      if (stepUpChallengeId != null) rethrow;
      final freshToken = await _stepUpReauthHook.resolveFreshAuth(offer);
      if (freshToken == null || freshToken.isEmpty) {
        // User cancelled the fresh-auth flow — surface the original
        // 401 so the screen layer renders its existing failure UX.
        rethrow;
      }
      return _revokeOnceWithStepUp(
        sessionId: sessionId,
        token: freshToken,
        stepUpChallengeId: offer.challengeId,
      );
    }
  }

  /// G60 — builds the `Idempotency-Key` header carrying a
  /// caller-STABLE key derived from [action] + [parts]. The same
  /// logical write (same payload) on retry produces the SAME key,
  /// collapsing against the proxy `proxy_requests` UNIQUE guard;
  /// distinct actions / payloads produce distinct keys. Mirrors the
  /// exemplar idempotency posture of `web_team_roles_gateway.dart`.
  static Map<String, String> _stableKeyHeader(
    String action,
    List<Object?> parts,
  ) {
    return <String, String>{
      'Idempotency-Key': OperatorWebProxyClient.stableIdempotencyKey(
        action,
        parts,
      ),
    };
  }

  Future<String> _requireToken(String message) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw OperatorWebProxyException(
        code: 'unauthenticated',
        message: message,
      );
    }
    return token.trim();
  }

  void _requireFreshMfaToken(String idToken) {
    final authTime = _readAuthTime(idToken);
    final now = _now().toUtc();
    if (authTime == null) {
      throw const AccountSessionFreshMfaRequiredException();
    }
    // B11.2.b deep-audit P1 fix — apply ±60s skew tolerance to the
    // "auth_time in the future" guard. Without this a client whose
    // browser clock is even a few seconds ahead of the proxy trips
    // the freshness gate spuriously. Tokens MORE than 60s ahead are
    // still rejected — that's an unusable clock OR a forged stamp.
    if (authTime.isAfter(now.add(freshMfaClockSkewWindow))) {
      throw const AccountSessionFreshMfaRequiredException();
    }
    // Past direction is unchanged — the freshness window itself
    // already absorbs small drift, and a stale auth_time MUST trigger
    // re-auth regardless of clock skew. The window is computed
    // against `now` (not `now + skew`) so an early-by-skew client
    // cannot stretch the effective freshness budget.
    if (authTime.isBefore(now) && now.difference(authTime) > _freshMfaWindow) {
      throw const AccountSessionFreshMfaRequiredException();
    }
  }

  static DateTime? _readAuthTime(String idToken) {
    final parts = idToken.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, Object?>) return null;
      final raw = decoded['auth_time'];
      final seconds = _readAuthTimeSeconds(raw);
      if (seconds == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    } on Object {
      return null;
    }
  }

  static int? _readAuthTimeSeconds(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static bool? _readBool(Object? value) => value is bool ? value : null;
}

class AccountSessionFreshMfaRequiredException
    extends OperatorWebProxyException {
  const AccountSessionFreshMfaRequiredException()
    : super(
        code: MfaFreshnessRedirectPayload.errorCode,
        message: 'Fresh authentication is required.',
        statusCode: 403,
        redirectUri: HttpWebAccountGateway._freshMfaRedirectUri,
      );
}

/// Patch payload for [WebAccountGateway.patchAccount]. Every field
/// is optional. Use [AccountIdentityPatch.clearLogo] to send
/// `logoUrl: null` rather than omitting the key (the JSON-encoded
/// form is `"logoUrl": null` versus no `logoUrl` key at all).
@immutable
class AccountIdentityPatch {
  const AccountIdentityPatch({
    this.businessName,
    this.logoUrl,
    this.clearLogo = false,
    this.currencyCode,
    this.localeTag,
    this.weekStartDay,
    this.rolloverHour,
  });

  final String? businessName;
  final String? logoUrl;

  /// When true, the request sends `"logoUrl": null`, instructing the
  /// server to clear the logo. When false (default), the key is
  /// omitted entirely if [logoUrl] is null.
  final bool clearLogo;

  final String? currencyCode;
  final String? localeTag;

  /// Legacy compatibility field. Kept readable for older callers, but
  /// [toJson] deliberately omits it because Business Timing owns
  /// week-start writes.
  final String? weekStartDay;

  /// Legacy compatibility field. Kept so older call sites can still
  /// construct patches safely, but [toJson] deliberately omits it
  /// because Business Timing now owns business-day start writes.
  final int? rolloverHour;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (businessName != null) json['businessName'] = businessName;
    if (logoUrl != null) {
      json['logoUrl'] = logoUrl;
    } else if (clearLogo) {
      json['logoUrl'] = null;
    }
    if (currencyCode != null) json['currencyCode'] = currencyCode;
    if (localeTag != null) json['localeTag'] = localeTag;
    return json;
  }
}

/// Wave 2 W-6 - patch payload for the primary location's IANA
/// timezone. The wire shape is one required field so the backend
/// handler has the simplest possible contract to implement against.
@immutable
class AccountLocationTimezonePatch {
  const AccountLocationTimezonePatch({required this.ianaTimezone});

  /// IANA tz database name (e.g. `America/Toronto`, `Europe/London`).
  /// The backend handler validates the value before passing it to
  /// `LocationsRepository.updateLocation(timezone: ...)`. Empty / blank
  /// strings are rejected; the value MUST be a non-empty trimmed
  /// string per the validator contract.
  final String ianaTimezone;

  Map<String, Object?> toJson() => <String, Object?>{
    'ianaTimezone': ianaTimezone,
  };
}

/// Wave 2 W-6 - resolved location timezone returned by the proxy
/// after a successful PATCH. Carries the operator + location ids so
/// the UI can confirm the write landed on the expected scope, plus
/// the effective IANA timezone string.
@immutable
class AccountLocationTimezone {
  const AccountLocationTimezone({
    required this.operatorId,
    required this.locationId,
    required this.ianaTimezone,
    required this.updatedAt,
  });

  final String operatorId;
  final String locationId;
  final String ianaTimezone;
  final DateTime updatedAt;

  static AccountLocationTimezone fromJson(Map<String, Object?> json) {
    final operatorId = AccountIdentity._readString(json['operatorId']);
    final locationId = AccountIdentity._readString(json['locationId']);
    final ianaTimezone = AccountIdentity._readString(json['ianaTimezone']);
    final updatedAtRaw = AccountIdentity._readString(json['updatedAt']);
    if (operatorId == null ||
        locationId == null ||
        ianaTimezone == null ||
        updatedAtRaw == null) {
      throw const OperatorWebProxyException(
        code: 'malformed_location_timezone',
        message: 'The proxy returned an incomplete location timezone record.',
      );
    }
    return AccountLocationTimezone(
      operatorId: operatorId,
      locationId: locationId,
      ianaTimezone: ianaTimezone,
      updatedAt: DateTime.parse(updatedAtRaw).toUtc(),
    );
  }
}

/// Resolved account identity returned by the proxy after a PATCH.
@immutable
class AccountIdentity {
  const AccountIdentity({
    required this.operatorId,
    required this.businessName,
    required this.logoUrl,
    required this.currencyCode,
    required this.localeTag,
    required this.weekStartDay,
    required this.rolloverHour,
    required this.updatedAt,
  });

  final String operatorId;
  final String businessName;
  final String? logoUrl;
  final String currencyCode;
  final String localeTag;
  final String weekStartDay;
  final int rolloverHour;
  final DateTime updatedAt;

  static AccountIdentity fromJson(Map<String, Object?> json) {
    final operatorId = _readString(json['operatorId']);
    final businessName = _readString(json['businessName']);
    final currencyCode = _readString(json['currencyCode']);
    final localeTag = _readString(json['localeTag']);
    final weekStartDay = _readString(json['weekStartDay']);
    final rolloverHourRaw = json['rolloverHour'];
    final updatedAtRaw = _readString(json['updatedAt']);
    if (operatorId == null ||
        businessName == null ||
        currencyCode == null ||
        localeTag == null ||
        weekStartDay == null ||
        rolloverHourRaw is! int ||
        updatedAtRaw == null) {
      throw const OperatorWebProxyException(
        code: 'malformed_account_identity',
        message: 'The proxy returned an incomplete account record.',
      );
    }
    return AccountIdentity(
      operatorId: operatorId,
      businessName: businessName,
      logoUrl: _readString(json['logoUrl']),
      currencyCode: currencyCode,
      localeTag: localeTag,
      weekStartDay: weekStartDay,
      rolloverHour: rolloverHourRaw,
      updatedAt: DateTime.parse(updatedAtRaw).toUtc(),
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

@immutable
class AccountActiveSessionsListed {
  const AccountActiveSessionsListed({required this.sessions});

  final List<AccountActiveSessionEntry> sessions;
}

/// A user-scoped active-session row for the My Account card. Raw IP
/// addresses are intentionally omitted; the UI only receives city/country
/// geo hints.
@immutable
class AccountActiveSessionEntry {
  const AccountActiveSessionEntry({
    required this.sessionId,
    required this.lastActiveAt,
    required this.createdAt,
    this.deviceLabel,
    this.userAgent,
    this.deviceFingerprint,
    this.geoCity,
    this.geoCountry,
  });

  final String sessionId;
  final DateTime lastActiveAt;
  final DateTime createdAt;
  final String? deviceLabel;
  final String? userAgent;
  final String? deviceFingerprint;
  final String? geoCity;
  final String? geoCountry;

  static AccountActiveSessionEntry fromJson(Object? raw) {
    if (raw is! Map) {
      throw const OperatorWebProxyException(
        code: 'malformed_active_session',
        message: 'The proxy returned a malformed active session row.',
      );
    }
    final json = Map<String, Object?>.from(raw);
    final sessionId = AccountIdentity._readString(json['session_id']);
    final lastActiveAtRaw =
        AccountIdentity._readString(json['last_seen_at']) ??
        AccountIdentity._readString(json['last_active_at']);
    final createdAtRaw = AccountIdentity._readString(json['created_at']);
    if (sessionId == null || lastActiveAtRaw == null || createdAtRaw == null) {
      throw const OperatorWebProxyException(
        code: 'malformed_active_session',
        message: 'The proxy returned an incomplete active session row.',
      );
    }
    return AccountActiveSessionEntry(
      sessionId: sessionId,
      lastActiveAt: _parseUtc(lastActiveAtRaw),
      createdAt: _parseUtc(createdAtRaw),
      deviceLabel: AccountIdentity._readString(json['device_label']),
      userAgent: AccountIdentity._readString(json['user_agent']),
      deviceFingerprint: AccountIdentity._readString(
        json['device_fingerprint'],
      ),
      geoCity: AccountIdentity._readString(json['geo_city']),
      geoCountry: AccountIdentity._readString(json['geo_country']),
    );
  }

  static DateTime _parseUtc(String value) => DateTime.parse(value).toUtc();
}

@immutable
class AccountSessionSignOutOthersResult {
  const AccountSessionSignOutOthersResult({required this.revokedCount});

  final int revokedCount;
}

/// Wave 2 W-3 — payload for [WebAccountGateway.patchSelfProfile].
/// Both fields are optional; the proxy rejects the all-null shape
/// with 400 `no_profile_fields`.
@immutable
class SelfProfilePatchPayload {
  const SelfProfilePatchPayload({this.displayName, this.email});

  final String? displayName;
  final String? email;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (displayName != null) json['display_name'] = displayName;
    if (email != null) json['email'] = email;
    return json;
  }
}

/// Resolved profile after a successful PATCH.
@immutable
class SelfProfilePatchResult {
  const SelfProfilePatchResult({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.emailChanged,
    required this.displayNameChanged,
  });

  final String userId;
  final String email;
  final String displayName;

  /// True when the email actually changed (the patch could have been
  /// a no-op). The UI uses this to force a sign-out so the next
  /// sign-in picks up the new address.
  final bool emailChanged;

  /// True when the display name actually changed. Mostly a UX signal
  /// for rendering "Saved" confirmations.
  final bool displayNameChanged;

  static SelfProfilePatchResult fromJson(Map<String, Object?> json) {
    final rawUser = json['user'];
    if (rawUser is! Map) {
      throw const OperatorWebProxyException(
        code: 'malformed_self_profile_patch',
        message: 'The proxy returned an incomplete profile patch response.',
      );
    }
    final user = Map<String, Object?>.from(rawUser);
    final userId = AccountIdentity._readString(user['user_id']);
    final email = AccountIdentity._readString(user['email']);
    final displayName = AccountIdentity._readString(user['display_name']);
    if (userId == null || email == null || displayName == null) {
      throw const OperatorWebProxyException(
        code: 'malformed_self_profile_patch',
        message: 'The proxy returned an incomplete profile patch response.',
      );
    }
    return SelfProfilePatchResult(
      userId: userId,
      email: email,
      displayName: displayName,
      emailChanged: user['email_changed'] == true,
      displayNameChanged: user['display_name_changed'] == true,
    );
  }
}

class _AdminRouteForbidden implements Exception {
  const _AdminRouteForbidden();
  @override
  String toString() => 'WebAccountGateway must never resolve an /admin/ path.';
}

/// Wave 2 U-FU-hp11-account — patch payload for
/// [WebAccountGateway.patchLocationAccountOverrides]. Every field is
/// optional. Use the matching `clear*` flag to send `"<field>": null`
/// (which the backend treats as "reset the override, inherit the
/// business default"). Legacy business-day rollover fields are kept
/// readable but are no longer serialized by this payload.
@immutable
class LocationAccountOverridesPatchPayload {
  const LocationAccountOverridesPatchPayload({
    this.ianaTimezone,
    this.localeCode,
    this.currencyCode,
    this.businessDayRolloverHour,
    this.contactEmail,
    this.contactPhone,
    this.clearIanaTimezone = false,
    this.clearLocaleCode = false,
    this.clearCurrencyCode = false,
    this.clearBusinessDayRolloverHour = false,
    this.clearContactEmail = false,
    this.clearContactPhone = false,
  });

  final String? ianaTimezone;
  final String? localeCode;
  final String? currencyCode;

  /// Legacy compatibility field. Kept readable on response field sets,
  /// but [toJson] deliberately omits it because Business Timing now
  /// owns business-day start writes.
  final int? businessDayRolloverHour;
  final String? contactEmail;
  final String? contactPhone;

  final bool clearIanaTimezone;
  final bool clearLocaleCode;
  final bool clearCurrencyCode;

  /// Legacy compatibility flag. No longer serialized.
  final bool clearBusinessDayRolloverHour;
  final bool clearContactEmail;
  final bool clearContactPhone;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (ianaTimezone != null) {
      json['ianaTimezone'] = ianaTimezone;
    } else if (clearIanaTimezone) {
      json['ianaTimezone'] = null;
    }
    if (localeCode != null) {
      json['localeCode'] = localeCode;
    } else if (clearLocaleCode) {
      json['localeCode'] = null;
    }
    if (currencyCode != null) {
      json['currencyCode'] = currencyCode;
    } else if (clearCurrencyCode) {
      json['currencyCode'] = null;
    }
    if (contactEmail != null) {
      json['contactEmail'] = contactEmail;
    } else if (clearContactEmail) {
      json['contactEmail'] = null;
    }
    if (contactPhone != null) {
      json['contactPhone'] = contactPhone;
    } else if (clearContactPhone) {
      json['contactPhone'] = null;
    }
    return json;
  }
}

/// Wave 2 U-FU-hp11-account — wire response from the per-location
/// override route. Carries the effective / override / businessDefault
/// triple the AccountScreen renders as the HP #11 inheritance line.
@immutable
class LocationAccountOverridesEnvelope {
  const LocationAccountOverridesEnvelope({
    required this.operatorId,
    required this.locationId,
    required this.effective,
    required this.override,
    required this.businessDefault,
    required this.updatedAt,
  });

  final String operatorId;
  final String locationId;
  final LocationAccountOverridesFieldSet effective;
  final LocationAccountOverridesFieldSet override;
  final LocationAccountOverridesFieldSet businessDefault;
  final DateTime updatedAt;

  static LocationAccountOverridesEnvelope fromJson(Map<String, Object?> json) {
    final operatorId = AccountIdentity._readString(json['operatorId']);
    final locationId = AccountIdentity._readString(json['locationId']);
    final updatedAtRaw = AccountIdentity._readString(json['updatedAt']);
    final effectiveRaw = json['effective'];
    final overrideRaw = json['override'];
    final businessDefaultRaw = json['businessDefault'];
    if (operatorId == null ||
        locationId == null ||
        updatedAtRaw == null ||
        effectiveRaw is! Map ||
        overrideRaw is! Map ||
        businessDefaultRaw is! Map) {
      throw const OperatorWebProxyException(
        code: 'malformed_location_account_overrides',
        message:
            'The proxy returned an incomplete location account overrides record.',
      );
    }
    return LocationAccountOverridesEnvelope(
      operatorId: operatorId,
      locationId: locationId,
      effective: LocationAccountOverridesFieldSet._fromJson(
        Map<String, Object?>.from(effectiveRaw),
      ),
      override: LocationAccountOverridesFieldSet._fromJson(
        Map<String, Object?>.from(overrideRaw),
      ),
      businessDefault: LocationAccountOverridesFieldSet._fromJson(
        Map<String, Object?>.from(businessDefaultRaw),
      ),
      updatedAt: DateTime.parse(updatedAtRaw).toUtc(),
    );
  }
}

/// Wire sub-record carried inside the envelope. Every field is
/// nullable; null means "no value at this level" (and for `override`,
/// null means "no override is set, so the field inherits from the
/// business default").
@immutable
class LocationAccountOverridesFieldSet {
  const LocationAccountOverridesFieldSet({
    this.ianaTimezone,
    this.localeCode,
    this.currencyCode,
    this.businessDayRolloverHour,
    this.contactEmail,
    this.contactPhone,
  });

  final String? ianaTimezone;
  final String? localeCode;
  final String? currencyCode;
  final int? businessDayRolloverHour;
  final String? contactEmail;
  final String? contactPhone;

  static LocationAccountOverridesFieldSet _fromJson(Map<String, Object?> json) {
    final raw = json['businessDayRolloverHour'];
    final int? rollover;
    if (raw == null) {
      rollover = null;
    } else if (raw is int) {
      rollover = raw;
    } else if (raw is num) {
      rollover = raw.toInt();
    } else if (raw is String) {
      rollover = int.tryParse(raw);
    } else {
      rollover = null;
    }
    return LocationAccountOverridesFieldSet(
      ianaTimezone: AccountIdentity._readString(json['ianaTimezone']),
      localeCode: AccountIdentity._readString(json['localeCode']),
      currencyCode: AccountIdentity._readString(json['currencyCode']),
      businessDayRolloverHour: rollover,
      contactEmail: AccountIdentity._readString(json['contactEmail']),
      contactPhone: AccountIdentity._readString(json['contactPhone']),
    );
  }
}
