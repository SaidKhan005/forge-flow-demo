// Phase 9 live-closeout - server-side Firebase Admin auth seam.
//
// Flutter never imports this. The advisor proxy uses it to create/update
// Firebase Identity Platform accounts with the Cloud Run service account.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
    Duration timeout = const Duration(seconds: 5),
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
    final request = await _httpClient.getUrl(uri).timeout(_timeout);
    request.headers.set('Metadata-Flavor', 'Google');
    final response = await request.close().timeout(_timeout);
    final raw = await utf8
        .decodeStream(response.cast<List<int>>())
        .timeout(_timeout);
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
    final request = await _httpClient.postUrl(uri).timeout(_timeout);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close().timeout(_timeout);
    final raw = await utf8
        .decodeStream(response.cast<List<int>>())
        .timeout(_timeout);
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
    final request = await _httpClient.postUrl(uri).timeout(_timeout);
    request.headers.contentType = ContentType.json;
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close().timeout(_timeout);
    final raw = await utf8
        .decodeStream(response.cast<List<int>>())
        .timeout(_timeout);
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
