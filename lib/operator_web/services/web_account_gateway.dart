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

/// Default implementation. Wraps [OperatorWebProxyClient.patchJson]
/// so token, idempotency-key, and error-mapping logic is shared with
/// the rest of the operator-web HTTP surface.
class HttpWebAccountGateway implements WebAccountGateway {
  HttpWebAccountGateway({
    required OperatorWebProxyClient client,
    required Future<String?> Function() idTokenProvider,
  })  : _client = client,
        _idTokenProvider = idTokenProvider;

  final OperatorWebProxyClient _client;
  final Future<String?> Function() _idTokenProvider;

  /// Operator-scoped route. The unit-test contract pins this string.
  static const String operatorAccountPath = '/v1/operator/account';

  @override
  Future<AccountIdentity> getAccount() async {
    if (operatorAccountPath.contains('/admin/')) {
      throw const _AdminRouteForbidden();
    }
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebProxyException(
        code: 'unauthenticated',
        message: 'Sign in again to load your business account.',
      );
    }
    final response = await _client.getJson(
      operatorAccountPath,
      idToken: token,
    );
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
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebProxyException(
        code: 'unauthenticated',
        message: 'Sign in again to update your business account.',
      );
    }
    final response = await _client.patchJson(
      operatorAccountPath,
      idToken: token,
      body: patch.toJson(),
    );
    return AccountIdentity.fromJson(response.body);
  }
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

class _AdminRouteForbidden implements Exception {
  const _AdminRouteForbidden();
  @override
  String toString() => 'WebAccountGateway must never resolve an /admin/ path.';
}
