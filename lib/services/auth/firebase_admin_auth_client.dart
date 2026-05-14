// Phase 9 live-closeout - server-side Firebase Admin auth seam.
//
// Flutter never imports this. The advisor proxy uses it to create/update
// Firebase Identity Platform accounts with the Cloud Run service account.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../observability/dependency_timeout_exception.dart';
import '../observability/log.dart';

/// HARD-G observability — User-Agent enrichment for outbound Firebase
/// requests. When inside an active [withProxyLogContext] zone, tags
/// the outgoing User-Agent with the correlation_id and request_id so
/// Cloud Logging can correlate Firebase-side traces back to a request.
String _buildFirebaseUserAgent() {
  const base = 'forge-and-flow-advisor-proxy/1.0';
  final context = currentProxyLogContext();
  if (context == null) return base;
  return '$base '
      '(correlation_id=${context.correlationId}; '
      'request_id=${context.requestId})';
}

/// HARD-G observability — translate a raw [TimeoutException] into the
/// typed [DependencyTimeoutException] used by the route layer to
/// emit the contract-pinned envelope. Emits one
/// `request.dependency_timeout` log line at the wire boundary so the
/// timing signal reaches Cloud Logging even when the caller
/// translates the throw into a fail-open / cached response.
DependencyTimeoutException _emitFirebaseTimeout({
  required String operation,
  required Duration timeout,
}) {
  final exception = DependencyTimeoutException(
    surface: 'firebase',
    operation: operation,
    elapsedMs: timeout.inMilliseconds,
  );
  log(
    LogSeverity.error,
    'request.dependency_timeout',
    fields: <String, Object?>{
      'surface': exception.surface,
      'operation': exception.operation,
      'elapsed_ms': exception.elapsedMs,
    },
  );
  return exception;
}

class FirebaseAdminAuthError implements Exception {
  const FirebaseAdminAuthError(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  @override
  String toString() =>
      'FirebaseAdminAuthError(code: $code, status: $statusCode)';
}

class FirebasePasswordResetCodeInfo {
  const FirebasePasswordResetCodeInfo({required this.email, this.uid});

  final String email;
  final String? uid;
}

abstract class FirebaseAdminAuthClient {
  Future<void> createUser({
    required String uid,
    required String email,
    required Map<String, Object?> customClaims,
  });

  Future<void> setCustomClaims({
    required String uid,
    required Map<String, Object?> customClaims,
  });

  Future<void> setDisabled({required String uid, required bool disabled});

  /// Wave 2 W-2 — Cancel pending invite end-to-end.
  ///
  /// Deletes the Firebase Identity Platform account for [uid] so the
  /// magic-link / temporary credential the invite created can no longer
  /// be exchanged for a session. Used by `revokeInvite` to revoke the
  /// shadow account that `createInvite` provisioned with
  /// [createUser].
  ///
  /// Implementations MUST treat `user_not_found` as a no-op so the
  /// operation stays idempotent on the wire — a retried DELETE on an
  /// invite whose Firebase account was already deleted MUST NOT
  /// surface as an error to the caller.
  Future<void> deleteUser({required String uid});

  /// Phase 11W/11A — Members edit-user write path (W-1).
  ///
  /// Updates the Firebase Identity Platform account for an existing
  /// user. Both `email` and `displayName` are optional so a caller can
  /// patch one without forcing the other to round-trip through this
  /// seam (Identity Toolkit `accounts:update` treats missing fields as
  /// no-op). Email changes are sensitive — the operator-web /admin
  /// Edit member dialog requires the operator to confirm before
  /// invoking this path, and the calling proxy route layer writes an
  /// `auth.user_profile_updated` audit row regardless of the source.
  Future<void> updateUser({
    required String uid,
    String? email,
    String? displayName,
  });

  Future<void> sendPasswordResetEmail({
    required String email,
    String? continueUrl,
  });

  Future<FirebasePasswordResetCodeInfo> verifyPasswordResetCode({
    required String oobCode,
  });

  Future<void> confirmPasswordReset({
    required String oobCode,
    required String newPassword,
  });

  Future<bool> verifyPassword({
    required String email,
    required String password,
    required String expectedUid,
  });

  Future<void> updatePassword({required String uid, required String password});

  Future<void> revokeRefreshTokens({required String uid});

  Future<void> clearMfaEnrollments({required String uid});
}

class ScaffoldFailingFirebaseAdminAuthClient
    implements FirebaseAdminAuthClient {
  const ScaffoldFailingFirebaseAdminAuthClient();

  @override
  Future<void> createUser({
    required String uid,
    required String email,
    required Map<String, Object?> customClaims,
  }) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<void> setCustomClaims({
    required String uid,
    required Map<String, Object?> customClaims,
  }) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<void> setDisabled({required String uid, required bool disabled}) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<void> deleteUser({required String uid}) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<void> updateUser({
    required String uid,
    String? email,
    String? displayName,
  }) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    String? continueUrl,
  }) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<FirebasePasswordResetCodeInfo> verifyPasswordResetCode({
    required String oobCode,
  }) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<void> confirmPasswordReset({
    required String oobCode,
    required String newPassword,
  }) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<bool> verifyPassword({
    required String email,
    required String password,
    required String expectedUid,
  }) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<void> updatePassword({required String uid, required String password}) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<void> revokeRefreshTokens({required String uid}) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }

  @override
  Future<void> clearMfaEnrollments({required String uid}) {
    throw const FirebaseAdminAuthError('firebase_admin_not_configured');
  }
}

abstract class OAuthAccessTokenProvider {
  Future<String> accessToken();
}

class MetadataServerAccessTokenProvider implements OAuthAccessTokenProvider {
  MetadataServerAccessTokenProvider({
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 10),
  }) : _httpClient = httpClient ?? HttpClient(),
       _timeout = timeout;

  final HttpClient _httpClient;
  final Duration _timeout;

  String? _cachedToken;
  DateTime? _expiresAt;

  @override
  Future<String> accessToken() async {
    final now = DateTime.now().toUtc();
    final cachedToken = _cachedToken;
    final expiresAt = _expiresAt;
    if (cachedToken != null &&
        expiresAt != null &&
        now.isBefore(expiresAt.subtract(const Duration(minutes: 2)))) {
      return cachedToken;
    }

    final uri = Uri.parse(
      'http://metadata.google.internal/computeMetadata/v1/instance/'
      'service-accounts/default/token',
    );
    final HttpClientResponse response;
    final String raw;
    try {
      final request = await _httpClient.getUrl(uri).timeout(_timeout);
      request.headers.set('Metadata-Flavor', 'Google');
      response = await request.close().timeout(_timeout);
      raw = await utf8
          .decodeStream(response.cast<List<int>>())
          .timeout(_timeout);
    } on TimeoutException {
      throw _emitFirebaseTimeout(
        operation: 'metadata_token',
        timeout: _timeout,
      );
    }
    if (response.statusCode != 200) {
      throw FirebaseAdminAuthError(
        'metadata_token_unavailable',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FirebaseAdminAuthError('metadata_token_malformed');
    }
    final token = decoded['access_token'];
    final expiresIn = decoded['expires_in'];
    if (token is! String || token.isEmpty || expiresIn is! int) {
      throw const FirebaseAdminAuthError('metadata_token_malformed');
    }
    _cachedToken = token;
    _expiresAt = now.add(Duration(seconds: expiresIn));
    return token;
  }
}

class IdentityToolkitFirebaseAdminAuthClient
    implements FirebaseAdminAuthClient {
  IdentityToolkitFirebaseAdminAuthClient({
    required this.projectId,
    required this.apiKey,
    required OAuthAccessTokenProvider accessTokenProvider,
    HttpClient? httpClient,
    this.continueUrl,
    Duration timeout = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _accessTokenProvider = accessTokenProvider,
       _httpClient = httpClient ?? HttpClient(),
       _timeout = timeout,
       _now = now ?? DateTime.now;

  final String projectId;
  final String apiKey;
  final OAuthAccessTokenProvider _accessTokenProvider;
  final HttpClient _httpClient;
  final String? continueUrl;
  final Duration _timeout;
  final DateTime Function() _now;

  @override
  Future<void> createUser({
    required String uid,
    required String email,
    required Map<String, Object?> customClaims,
  }) async {
    await _post(
      '/v1/accounts:signUp',
      <String, Object?>{
        'localId': uid,
        'email': email,
        'password': _temporaryPassword(),
        'emailVerified': false,
        'disabled': false,
        'targetProjectId': projectId,
      },
      expectedStatus: 200,
      queryParameters: <String, String>{'key': apiKey},
    );
    await setCustomClaims(uid: uid, customClaims: customClaims);
  }

  @override
  Future<void> setCustomClaims({
    required String uid,
    required Map<String, Object?> customClaims,
  }) async {
    await _post(
      '/v1/projects/${Uri.encodeComponent(projectId)}/accounts:update',
      <String, Object?>{
        'localId': uid,
        'customAttributes': jsonEncode(customClaims),
      },
      expectedStatus: 200,
    );
  }

  @override
  Future<void> setDisabled({
    required String uid,
    required bool disabled,
  }) async {
    await _post(
      '/v1/projects/${Uri.encodeComponent(projectId)}/accounts:update',
      <String, Object?>{'localId': uid, 'disableUser': disabled},
      expectedStatus: 200,
    );
  }

  @override
  Future<void> deleteUser({required String uid}) async {
    // Wave 2 W-2 — Cancel pending invite. Identity Toolkit's
    // `accounts:delete` removes the Firebase account so the magic
    // link / temp credential `createUser` provisioned can no longer
    // be exchanged. Fail-soft on `user_not_found` so a retried DELETE
    // on an already-revoked invite (whose Firebase shadow account
    // was deleted on a prior attempt) stays idempotent on the wire.
    try {
      await _post(
        '/v1/projects/${Uri.encodeComponent(projectId)}/accounts:delete',
        <String, Object?>{'localId': uid},
        expectedStatus: 200,
      );
    } on FirebaseAdminAuthError catch (error) {
      if (error.code == 'user_not_found') return;
      rethrow;
    }
  }

  @override
  Future<void> updateUser({
    required String uid,
    String? email,
    String? displayName,
  }) async {
    final trimmedEmail = email?.trim();
    final trimmedDisplay = displayName?.trim();
    if ((trimmedEmail == null || trimmedEmail.isEmpty) &&
        (trimmedDisplay == null || trimmedDisplay.isEmpty)) {
      // No-op when neither field is supplied; the caller is responsible
      // for skipping the Firebase round-trip in that case but the
      // guard keeps the wire surface honest.
      return;
    }
    await _post(
      '/v1/projects/${Uri.encodeComponent(projectId)}/accounts:update',
      <String, Object?>{
        'localId': uid,
        if (trimmedEmail != null && trimmedEmail.isNotEmpty) ...<String, Object?>{
          'email': trimmedEmail,
          // Email changes are sensitive — force re-verification per
          // Firebase Identity Platform best practice so the user
          // re-confirms ownership of the new address.
          'emailVerified': false,
        },
        if (trimmedDisplay != null && trimmedDisplay.isNotEmpty)
          'displayName': trimmedDisplay,
      },
      expectedStatus: 200,
    );
  }

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    String? continueUrl,
  }) async {
    await _post(
      '/v1/projects/${Uri.encodeComponent(projectId)}/accounts:sendOobCode',
      <String, Object?>{
        'requestType': 'PASSWORD_RESET',
        'email': email,
        if ((continueUrl ?? this.continueUrl) != null)
          'continueUrl': continueUrl ?? this.continueUrl,
      },
      expectedStatus: 200,
    );
  }

  @override
  Future<bool> verifyPassword({
    required String email,
    required String password,
    required String expectedUid,
  }) async {
    try {
      final body = await _postWithApiKey(
        '/v1/accounts:signInWithPassword',
        <String, Object?>{
          'email': email,
          'password': password,
          'returnSecureToken': true,
        },
        expectedStatus: 200,
      );
      final localId = body['localId'];
      return localId is String && localId == expectedUid;
    } on FirebaseAdminAuthError catch (error) {
      if (_isInvalidPasswordError(error.code)) return false;
      rethrow;
    }
  }

  @override
  Future<void> updatePassword({
    required String uid,
    required String password,
  }) async {
    await _post(
      '/v1/projects/${Uri.encodeComponent(projectId)}/accounts:update',
      <String, Object?>{'localId': uid, 'password': password},
      expectedStatus: 200,
    );
  }

  @override
  Future<void> revokeRefreshTokens({required String uid}) async {
    await _post(
      '/v1/projects/${Uri.encodeComponent(projectId)}/accounts:update',
      <String, Object?>{
        'localId': uid,
        'validSince': (_now().toUtc().millisecondsSinceEpoch ~/ 1000)
            .toString(),
      },
      expectedStatus: 200,
    );
  }

  @override
  Future<FirebasePasswordResetCodeInfo> verifyPasswordResetCode({
    required String oobCode,
  }) async {
    final body = await _postWithApiKey(
      '/v1/accounts:resetPassword',
      <String, Object?>{'oobCode': oobCode},
      expectedStatus: 200,
    );
    final email = body['email'];
    final localId = body['localId'];
    if (email is! String || email.trim().isEmpty) {
      throw const FirebaseAdminAuthError('password_reset_code_malformed');
    }
    return FirebasePasswordResetCodeInfo(
      email: email,
      uid: localId is String && localId.trim().isNotEmpty ? localId : null,
    );
  }

  @override
  Future<void> confirmPasswordReset({
    required String oobCode,
    required String newPassword,
  }) async {
    await _postWithApiKey(
      '/v1/accounts:resetPassword',
      <String, Object?>{'oobCode': oobCode, 'newPassword': newPassword},
      expectedStatus: 200,
    );
  }

  @override
  Future<void> clearMfaEnrollments({required String uid}) async {
    await _post(
      '/v1/projects/${Uri.encodeComponent(projectId)}/accounts:update',
      <String, Object?>{
        'localId': uid,
        'mfa': const <String, Object?>{'enrollments': <Object?>[]},
      },
      expectedStatus: 200,
    );
  }

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body, {
    required int expectedStatus,
    Map<String, String>? queryParameters,
  }) async {
    final token = await _accessTokenProvider.accessToken();
    final uri = Uri.https(
      'identitytoolkit.googleapis.com',
      path,
      queryParameters,
    );
    final HttpClientResponse response;
    final String raw;
    try {
      final request = await _httpClient.postUrl(uri).timeout(_timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(
        HttpHeaders.userAgentHeader,
        _buildFirebaseUserAgent(),
      );
      final encoded = utf8.encode(jsonEncode(body));
      request.contentLength = encoded.length;
      request.add(encoded);
      response = await request.close().timeout(_timeout);
      raw = await utf8
          .decodeStream(response.cast<List<int>>())
          .timeout(_timeout);
    } on TimeoutException {
      throw _emitFirebaseTimeout(
        operation: _identityToolkitOperationName(path),
        timeout: _timeout,
      );
    }
    if (response.statusCode != expectedStatus) {
      throw FirebaseAdminAuthError(
        _errorCodeFromBody(raw) ?? 'identitytoolkit_request_failed',
        statusCode: response.statusCode,
      );
    }
    if (raw.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const <String, Object?>{};
    return Map<String, Object?>.from(decoded);
  }

  Future<Map<String, Object?>> _postWithApiKey(
    String path,
    Map<String, Object?> body, {
    required int expectedStatus,
  }) async {
    final uri = Uri.https(
      'identitytoolkit.googleapis.com',
      path,
      <String, String>{'key': apiKey},
    );
    final HttpClientResponse response;
    final String raw;
    try {
      final request = await _httpClient.postUrl(uri).timeout(_timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        _buildFirebaseUserAgent(),
      );
      final encoded = utf8.encode(jsonEncode(body));
      request.contentLength = encoded.length;
      request.add(encoded);
      response = await request.close().timeout(_timeout);
      raw = await utf8
          .decodeStream(response.cast<List<int>>())
          .timeout(_timeout);
    } on TimeoutException {
      throw _emitFirebaseTimeout(
        operation: _identityToolkitOperationName(path),
        timeout: _timeout,
      );
    }
    if (response.statusCode != expectedStatus) {
      throw FirebaseAdminAuthError(
        _errorCodeFromBody(raw) ?? 'identitytoolkit_request_failed',
        statusCode: response.statusCode,
      );
    }
    if (raw.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const <String, Object?>{};
    return Map<String, Object?>.from(decoded);
  }

  /// Maps an Identity Toolkit URL path onto a short operation label
  /// for [DependencyTimeoutException]. Returns the trailing path
  /// segment so the log line carries e.g. `accounts:resetPassword` or
  /// `accounts:update` without echoing the full URL.
  static String _identityToolkitOperationName(String path) {
    final lastSlash = path.lastIndexOf('/');
    if (lastSlash == -1 || lastSlash == path.length - 1) {
      return 'identity_toolkit';
    }
    final tail = path.substring(lastSlash + 1);
    return tail.isEmpty ? 'identity_toolkit' : tail;
  }

  String? _errorCodeFromBody(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          final message = error['message'];
          if (message is String && message.isNotEmpty) {
            return message.toLowerCase().replaceAll(
              RegExp(r'[^a-z0-9_]+'),
              '_',
            );
          }
        }
      }
    } catch (_) {
      // Keep HTTP responses narrow; malformed provider bodies collapse.
    }
    return null;
  }

  static bool _isInvalidPasswordError(String code) {
    return code == 'email_not_found' ||
        code == 'invalid_password' ||
        code == 'invalid_login_credentials' ||
        code == 'user_disabled';
  }

  static String _temporaryPassword() {
    final random = math.Random.secure();
    final bytes = Uint8List(24);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return '${base64UrlEncode(bytes).replaceAll('=', '')}Aa1!';
  }
}
