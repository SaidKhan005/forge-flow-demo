// Phase 11W.7 / Wave A2 - Operator-scoped account write gateway.
//
// Thin HTTP client over the operator-scoped account write route. The
// AccountScreen (business-identity editor) calls this gateway to
// PATCH the operator's business name, logo URL, currency, locale,
// week-start day, and rollover hour.
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

import 'package:flutter/foundation.dart';

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
  }) : _client = client,
       _idTokenProvider = idTokenProvider;

  final OperatorWebProxyClient _client;
  final Future<String?> Function() _idTokenProvider;

  /// Operator-scoped route. The unit-test contract pins this string.
  static const String operatorAccountPath = '/v1/operator/account';

  /// Existing self-service auth-session routes. These stay user-scoped and
  /// avoid `/v1/admin/*` or any B9.2-only schema additions.
  static const String activeSessionsPath = '/v1/auth/sessions';
  static const String revokeSessionPath = '/v1/auth/session/revoke';

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
    final response = await _client.patchJson(
      operatorAccountPath,
      idToken: token,
      body: patch.toJson(),
    );
    return AccountIdentity.fromJson(response.body);
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
    var revokedCount = 0;
    for (final sessionId in ids) {
      final response = await _client.postJson(
        revokeSessionPath,
        idToken: token,
        body: <String, Object?>{
          'session_id': sessionId,
          'reason': 'my_account.sign_out_other_sessions',
        },
      );
      final revoked =
          _readBool(response.body['revoked']) ??
          _readBool(response.body['ok']) ??
          true;
      if (revoked) revokedCount += 1;
    }
    return AccountSessionSignOutOthersResult(revokedCount: revokedCount);
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

  static bool? _readBool(Object? value) => value is bool ? value : null;
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
  final String? weekStartDay;
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
    if (weekStartDay != null) json['weekStartDay'] = weekStartDay;
    if (rolloverHour != null) json['rolloverHour'] = rolloverHour;
    return json;
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

class _AdminRouteForbidden implements Exception {
  const _AdminRouteForbidden();
  @override
  String toString() => 'WebAccountGateway must never resolve an /admin/ path.';
}
