// Phase 11W.live - Flutter Web proxy client.
//
// The existing mobile/admin proxy gateway implementations import `dart:io`.
// This client intentionally stays web-safe so `lib/main_operator_web.dart`
// can build as a Flutter Web target.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../auth/mfa_freshness_redirect_listener.dart';
import '../../services/auth/account_info_gateway.dart';

class OperatorWebProxyClient {
  OperatorWebProxyClient({
    required this.baseUri,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
    String Function()? idempotencyKeyFactory,
    MfaFreshnessRedirectListener? mfaFreshnessRedirectListener,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout,
       _idempotencyKeyFactory = idempotencyKeyFactory ?? _defaultIdempotencyKey,
       _mfaFreshnessRedirectListener =
           mfaFreshnessRedirectListener ??
           const NoopMfaFreshnessRedirectListener();

  final Uri baseUri;
  final http.Client _httpClient;
  final Duration _timeout;
  final String Function() _idempotencyKeyFactory;
  MfaFreshnessRedirectListener _mfaFreshnessRedirectListener;

  /// Late-bind the listener for cases where the auth source is built
  /// after the proxy client (e.g. the `FirebaseOperatorWebAuthSource`
  /// constructor wires both at once but the listener wraps the auth
  /// source itself, so the listener cannot be ready at proxy-client
  /// construction).
  // ignore: avoid_setters_without_getters
  set mfaFreshnessRedirectListener(MfaFreshnessRedirectListener listener) {
    _mfaFreshnessRedirectListener = listener;
  }

  static const String authSessionLoginPath = '/v1/auth/session/login';
  static const String authAccountInfoPath = '/v1/auth/account';
  static const String authPermissionsSnapshotPath =
      '/v1/auth/permissions/snapshot';
  static const String authPasswordChangePath = '/v1/auth/password/change';
  static const String authMfaTotpBeginPath = '/v1/auth/mfa/totp/begin';
  static const String authMfaTotpConfirmPath = '/v1/auth/mfa/totp/confirm';
  // A7 — POST-body redemption path. Token never appears as a URL query
  // parameter on this side of the seam.
  static const String authMagicLinkRedeemPath = '/v1/auth/magic-link/redeem';

  Future<OperatorWebSessionLedgerRecord> recordSessionLogin({
    required String idToken,
    required String tokenHash,
    String? email,
  }) async {
    final response = await postJson(
      authSessionLoginPath,
      idToken: idToken,
      body: <String, Object?>{
        'token_hash': tokenHash,
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      },
    );
    final sessionId = _readString(response.body['session_id']);
    final userId = _readString(response.body['user_id']);
    final operatorId = _readString(response.body['operator_id']);
    final locationId = _readString(response.body['location_id']);
    if (sessionId == null ||
        userId == null ||
        operatorId == null ||
        locationId == null) {
      throw const OperatorWebProxyException(
        code: 'malformed_session_response',
        message: 'The proxy returned an incomplete session record.',
      );
    }
    return OperatorWebSessionLedgerRecord(
      sessionId: sessionId,
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  Future<AccountInfo> loadAccountInfo({required String idToken}) async {
    final response = await getJson(authAccountInfoPath, idToken: idToken);
    try {
      return AccountInfo.fromJson(response.body);
    } on AccountInfoUnavailable catch (error) {
      throw OperatorWebProxyException(code: error.code, message: error.message);
    }
  }

  Future<OperatorWebPermissionSnapshot> loadPermissionSnapshot({
    required String idToken,
  }) async {
    final response = await getJson(
      authPermissionsSnapshotPath,
      idToken: idToken,
    );
    return OperatorWebPermissionSnapshot.fromJson(response.body);
  }

  Future<OperatorWebPasswordChangeResult> changePassword({
    required String idToken,
    required String currentPassword,
    required String newPassword,
  }) async {
    final response = await postJson(
      authPasswordChangePath,
      idToken: idToken,
      body: <String, Object?>{
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    );
    return OperatorWebPasswordChangeResult(
      hibpUnavailable: response.body['hibp_unavailable'] == true,
    );
  }

  Future<OperatorWebTotpEnrollment> beginTotpEnrollment({
    required String idToken,
    required String email,
    String issuerName = 'Forge & Flow',
  }) async {
    final response = await postJson(
      authMfaTotpBeginPath,
      idToken: idToken,
      body: <String, Object?>{'user_email': email, 'issuer_name': issuerName},
    );
    final factorId = _readString(response.body['factor_id']);
    final secret = _readString(response.body['secret_base32']);
    final otpAuthUrl = _readString(response.body['otp_auth_url']);
    if (factorId == null || secret == null || otpAuthUrl == null) {
      throw const OperatorWebProxyException(
        code: 'malformed_mfa_begin_response',
        message: 'The proxy returned an incomplete MFA setup response.',
      );
    }
    return OperatorWebTotpEnrollment(
      factorId: factorId,
      secretBase32: secret,
      otpAuthUrl: otpAuthUrl,
    );
  }

  Future<void> confirmTotpEnrollment({
    required String idToken,
    required String factorId,
    required String oneTimeCode,
    String issuerName = 'Forge & Flow',
  }) async {
    await postJson(
      authMfaTotpConfirmPath,
      idToken: idToken,
      body: <String, Object?>{
        'factor_id': factorId,
        'one_time_code': oneTimeCode,
        'issuer_name': issuerName,
      },
    );
  }

  /// POST to [path] with a JSON [body] but WITHOUT an Authorization
  /// header. Used for unauthenticated routes where the request body
  /// itself carries the credential (e.g. magic-link token redemption).
  ///
  /// A7: the caller is responsible for supplying an idempotency_key in
  /// the body; this method does NOT attach the proxy-client-generated
  /// Idempotency-Key header so the key stays under the caller's control
  /// and is sent inside the POST body (not as a URL-leaking header).
  Future<OperatorWebJsonResponse> postJsonUnauthenticated(
    String path, {
    Map<String, Object?> body = const <String, Object?>{},
  }) async {
    final request = http.Request('POST', _resolve(path));
    request.headers.addAll(<String, String>{
      'accept': 'application/json',
      'content-type': 'application/json',
    });
    request.body = jsonEncode(body);
    final response = await _send(request);
    return response;
  }

  Future<OperatorWebJsonResponse> getJson(
    String path, {
    required String idToken,
    Map<String, String>? queryParameters,
  }) async {
    final request = http.Request(
      'GET',
      _resolve(path, queryParameters: queryParameters),
    );
    _applyHeaders(request, idToken: idToken);
    final response = await _send(request);
    _throwIfUnsuccessful(response, path);
    return response;
  }

  Future<OperatorWebJsonResponse> postJson(
    String path, {
    required String idToken,
    Map<String, Object?> body = const <String, Object?>{},
    Map<String, String>? queryParameters,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final request = http.Request(
      'POST',
      _resolve(path, queryParameters: queryParameters),
    );
    _applyHeaders(request, idToken: idToken, extraHeaders: extraHeaders);
    request.body = jsonEncode(body);
    final response = await _send(request);
    _throwIfUnsuccessful(response, path);
    return response;
  }

  Future<OperatorWebJsonResponse> patchJson(
    String path, {
    required String idToken,
    Map<String, Object?> body = const <String, Object?>{},
    Map<String, String>? queryParameters,
  }) async {
    final request = http.Request(
      'PATCH',
      _resolve(path, queryParameters: queryParameters),
    );
    _applyHeaders(request, idToken: idToken);
    request.body = jsonEncode(body);
    final response = await _send(request);
    _throwIfUnsuccessful(response, path);
    return response;
  }

  Future<OperatorWebJsonResponse> deleteJson(
    String path, {
    required String idToken,
    Map<String, Object?> body = const <String, Object?>{},
    Map<String, String>? queryParameters,
  }) async {
    final request = http.Request(
      'DELETE',
      _resolve(path, queryParameters: queryParameters),
    );
    _applyHeaders(request, idToken: idToken);
    request.body = jsonEncode(body);
    final response = await _send(request);
    _throwIfUnsuccessful(response, path);
    return response;
  }

  Uri _resolve(String path, {Map<String, String>? queryParameters}) {
    final uri = baseUri.resolve(path);
    if (queryParameters == null || queryParameters.isEmpty) return uri;
    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        ...queryParameters,
      },
    );
  }

  void _applyHeaders(
    http.Request request, {
    required String idToken,
    Map<String, String> extraHeaders = const <String, String>{},
  }) {
    request.headers.addAll(<String, String>{
      'accept': 'application/json',
      'content-type': 'application/json',
      'authorization': 'Bearer ${idToken.trim()}',
      'Idempotency-Key': _idempotencyKeyFactory(),
      // B11.2.b — caller-supplied headers (e.g. `Step-Up-Challenge-Id`
      // on a step-up replay). Applied AFTER the defaults so callers
      // cannot accidentally drop Authorization / Content-Type by
      // omitting them, but CAN add additional headers like the step-
      // up challenge id. The challenge id flows through the HEADER
      // here, NEVER through the URL (addendum A1) — `_resolve` builds
      // the URI from `path` + `queryParameters` only.
      ...extraHeaders,
    });
  }

  Future<OperatorWebJsonResponse> _send(http.Request request) async {
    final streamed = await _httpClient.send(request).timeout(_timeout);
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
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
    // B11.2.b — snapshot response headers so the failure path can
    // surface the RFC 9470 `WWW-Authenticate` header to the gateway's
    // step-up challenge parser.
    final headers = Map<String, String>.unmodifiable(streamed.headers);
    return OperatorWebJsonResponse(
      statusCode: streamed.statusCode,
      body: body,
      headers: headers,
    );
  }

  void _throwIfUnsuccessful(OperatorWebJsonResponse response, String path) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    // CODE_OPS_DEBT carry-over #1 — detect the proxy's
    // `mfa_freshness_required` 403 payload, hand the redirect hint to
    // the listener (which signs out + drives navigation), and surface
    // the same hint on the thrown exception so screen-level catch
    // blocks can render a "we signed you out, please sign in again"
    // message instead of the generic proxy error.
    final freshnessRedirect = MfaFreshnessRedirectPayload.tryParse(
      statusCode: response.statusCode,
      body: response.body,
    );
    if (freshnessRedirect != null) {
      _mfaFreshnessRedirectListener.onMfaFreshnessRedirect(freshnessRedirect);
    }
    throw OperatorWebProxyException(
      code: _readString(response.body['error']) ?? 'proxy_request_failed',
      message:
          _readString(response.body['message']) ??
          'The operator web proxy could not complete $path.',
      statusCode: response.statusCode,
      redirectUri: freshnessRedirect?.redirectUri,
      responseHeaders: response.headers,
      responseBody: response.body,
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Generates a cryptographically random idempotency key. Exposed so
  /// callers can embed the key in a POST body (A7: not as a header, to
  /// avoid accidental URL leakage via the Referer header).
  String generateIdempotencyKey() => _idempotencyKeyFactory();

  static String _defaultIdempotencyKey() {
    final random = math.Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

class OperatorWebJsonResponse {
  const OperatorWebJsonResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final Map<String, Object?> body;

  /// B11.2.b — response headers (lower-case keys per dart:io / http
  /// package conventions). The gateway's step-up challenge parser
  /// reads `www-authenticate` here to recognize an RFC 9470 challenge.
  final Map<String, String> headers;
}

class OperatorWebProxyException implements Exception {
  const OperatorWebProxyException({
    required this.code,
    required this.message,
    this.statusCode,
    this.redirectUri,
    this.responseHeaders,
    this.responseBody,
  });

  final String code;
  final String message;
  final int? statusCode;

  /// Populated when the proxy returned the `mfa_freshness_required`
  /// 403 payload (CODE_OPS_DEBT carry-over #1). Screens that catch
  /// this exception can branch on `redirectUri != null` to render a
  /// "you've been signed out — please sign in again" affordance
  /// instead of the generic gateway error. The actual sign-out is
  /// performed by the auth source's
  /// [MfaFreshnessRedirectListener] before this exception bubbles.
  final String? redirectUri;

  /// B11.2.b — snapshot of response headers (lower-case keys). The
  /// gateway's step-up challenge handler reads `www-authenticate`
  /// here to parse an RFC 9470 challenge from a 401. Null when the
  /// exception was synthesised without an underlying HTTP response
  /// (e.g. typed local validation failures).
  final Map<String, String>? responseHeaders;

  /// B11.2.b — snapshot of response body JSON. The step-up handler
  /// reads `challenge_id` / `message` / `challenge_expires_in_seconds`
  /// here. Null when the exception was synthesised without an
  /// underlying HTTP response.
  final Map<String, Object?>? responseBody;

  /// Convenience: true iff this exception was the
  /// `mfa_freshness_required` 403. Avoids stringly-typed branching
  /// in screen code.
  bool get isMfaFreshnessRedirect =>
      statusCode == 403 &&
      code == MfaFreshnessRedirectPayload.errorCode &&
      redirectUri != null;

  @override
  String toString() => 'OperatorWebProxyException(code: $code)';
}

class OperatorWebSessionLedgerRecord {
  const OperatorWebSessionLedgerRecord({
    required this.sessionId,
    required this.userId,
    required this.operatorId,
    required this.locationId,
  });

  final String sessionId;
  final String userId;
  final String operatorId;
  final String locationId;
}

class OperatorWebPermissionSnapshot {
  const OperatorWebPermissionSnapshot({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.rolesVersion,
    required this.evaluatedAt,
    required this.permissions,
    this.requiresMfaKeys = const <String>{},
  });

  final String userId;
  final String operatorId;
  final String locationId;
  final int rolesVersion;
  final DateTime evaluatedAt;
  final Map<String, String> permissions;
  final Set<String> requiresMfaKeys;

  Set<String> get allowedPermissions => permissions.entries
      .where((entry) => entry.value == 'allow')
      .map((entry) => entry.key)
      .toSet();

  bool allows(String permissionKey) => permissions[permissionKey] == 'allow';

  static OperatorWebPermissionSnapshot fromJson(Map<String, Object?> json) {
    final userId = OperatorWebProxyClient._readString(json['user_id']);
    final operatorId = OperatorWebProxyClient._readString(json['operator_id']);
    final locationId = OperatorWebProxyClient._readString(json['location_id']);
    final rolesVersion = json['roles_version'];
    final evaluatedAtRaw = OperatorWebProxyClient._readString(
      json['evaluated_at'],
    );
    final permissionsRaw = json['permissions'];
    if (userId == null ||
        operatorId == null ||
        locationId == null ||
        rolesVersion is! int ||
        evaluatedAtRaw == null ||
        permissionsRaw is! Map) {
      throw const OperatorWebProxyException(
        code: 'malformed_permission_snapshot',
        message: 'The proxy returned an incomplete permission snapshot.',
      );
    }
    final permissions = <String, String>{};
    permissionsRaw.forEach((key, value) {
      if (key is String && value is String) {
        final effect = value.trim();
        if (effect == 'allow' || effect == 'deny') permissions[key] = effect;
      }
    });
    final requiresMfaRaw = json['requires_mfa'];
    return OperatorWebPermissionSnapshot(
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
      rolesVersion: rolesVersion,
      evaluatedAt: DateTime.parse(evaluatedAtRaw).toUtc(),
      permissions: Map<String, String>.unmodifiable(permissions),
      requiresMfaKeys: requiresMfaRaw is List
          ? requiresMfaRaw.whereType<String>().toSet()
          : const <String>{},
    );
  }
}

class OperatorWebPasswordChangeResult {
  const OperatorWebPasswordChangeResult({required this.hibpUnavailable});

  final bool hibpUnavailable;
}

class OperatorWebTotpEnrollment {
  const OperatorWebTotpEnrollment({
    required this.factorId,
    required this.secretBase32,
    required this.otpAuthUrl,
  });

  final String factorId;
  final String secretBase32;
  final String otpAuthUrl;
}
