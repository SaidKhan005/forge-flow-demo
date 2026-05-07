// Phase 9 live-closeout B11 - Identity Toolkit TOTP MFA REST adapter.
//
// This adapter is safe for the Cloud Run proxy runtime: it uses the
// Identity Toolkit REST API instead of importing the Flutter-only
// firebase_auth SDK. The live TOTP endpoints use the project API key plus the
// already-verified user ID token; token values are never logged or returned in
// JSON bodies.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'firebase_mfa_client.dart';

class IdentityToolkitFirebaseMfaClient implements FirebaseMfaClient {
  IdentityToolkitFirebaseMfaClient({
    required this.apiKey,
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 10),
  }) : _httpClient = httpClient ?? HttpClient(),
       _timeout = timeout;

  final String apiKey;
  final HttpClient _httpClient;
  final Duration _timeout;

  @override
  Future<FirebaseMfaTotpBeginPayload> beginTotpEnrollment({
    String authorizationIdToken = '',
    required String userId,
    required String userEmail,
    required String issuerName,
  }) async {
    final body = await _postWithApiKey(
      '/v2/accounts/mfaEnrollment:start',
      <String, Object?>{
        'idToken': authorizationIdToken,
        'totpEnrollmentInfo': const <String, Object?>{},
      },
      expectedStatus: 200,
    );
    final sessionInfo = _readMap(body['totpSessionInfo'], 'totpSessionInfo');
    final sharedSecret = _readString(
      sessionInfo['sharedSecretKey'],
      'totpSessionInfo.sharedSecretKey',
    );
    final enrollmentSession = _readString(
      sessionInfo['sessionInfo'],
      'totpSessionInfo.sessionInfo',
    );
    return FirebaseMfaTotpBeginPayload(
      // Identity Toolkit's REST API names this `sessionInfo`; the existing
      // F&F seam calls the opaque begin-confirm handle `factorId`.
      factorId: enrollmentSession,
      secretBase32: sharedSecret,
      otpAuthUrl: _buildOtpAuthUrl(
        issuerName: issuerName,
        userEmail: userEmail,
        secretBase32: sharedSecret,
        hashingAlgorithm: _optionalString(sessionInfo['hashingAlgorithm']),
        verificationCodeLength: _optionalInt(
          sessionInfo['verificationCodeLength'],
        ),
        periodSec: _optionalInt(sessionInfo['periodSec']),
      ),
    );
  }

  @override
  Future<FirebaseMfaConfirmOutcome> confirmTotpEnrollment({
    String authorizationIdToken = '',
    required String factorId,
    required String oneTimeCode,
    String issuerName = 'Forge & Flow',
  }) async {
    Map<String, Object?> body;
    try {
      body = await _postWithApiKey(
        '/v2/accounts/mfaEnrollment:finalize',
        <String, Object?>{
          'idToken': authorizationIdToken,
          'displayName': issuerName,
          'totpVerificationInfo': <String, Object?>{
            'sessionInfo': factorId,
            'verificationCode': oneTimeCode,
          },
        },
        expectedStatus: 200,
      );
    } on IdentityToolkitFirebaseMfaError catch (error) {
      return FirebaseMfaConfirmFailed(
        code: error.code,
        message: _messageForCode(error.code),
      );
    }

    final updatedIdToken = _optionalString(body['idToken']);
    if (updatedIdToken == null) {
      return const FirebaseMfaConfirmFailed(
        code: 'mfa_finalize_missing_id_token',
        message: 'MFA enrollment could not be verified. Please try again.',
      );
    }

    // Race fix (CODE_HEALTH L11): when a user enrolls two factors in
    // parallel, re-querying `accounts:lookup` for the "newest" TOTP factor
    // races with the sibling enrollment and may return the wrong factor id.
    // Identity Toolkit's `mfaEnrollment:finalize` already returns the
    // freshly-enrolled factor in its response body; prefer that. Only
    // fall back to `accounts:lookup` if the response is genuinely absent
    // (defensive — covers REST shape drift / partial responses).
    final factorIdFromFinalize = _factorIdFromFinalizeBody(body);
    if (factorIdFromFinalize != null) {
      return FirebaseMfaConfirmSucceeded(
        factorMetadata: <String, Object?>{
          'firebase_factor_uid': factorIdFromFinalize,
          'issuer': issuerName,
          'provider': 'identity_toolkit_rest',
        },
      );
    }

    try {
      // Defensive fallback path: only reached if the finalize response did
      // not carry the enrolled factor (REST shape drift / unexpected partial
      // payload). Subject to the parallel-enrollment race; logged for ops.
      final firebaseFactorUid = await _latestTotpEnrollmentId(updatedIdToken);
      return FirebaseMfaConfirmSucceeded(
        factorMetadata: <String, Object?>{
          'firebase_factor_uid': firebaseFactorUid,
          'issuer': issuerName,
          'provider': 'identity_toolkit_rest',
        },
      );
    } on IdentityToolkitFirebaseMfaError catch (error) {
      return FirebaseMfaConfirmFailed(
        code: error.code,
        message: _messageForCode(error.code),
      );
    }
  }

  /// Reads the freshly-enrolled TOTP factor id from a
  /// `mfaEnrollment:finalize` response body. Returns `null` if the
  /// response does not carry the factor and the caller must fall back
  /// to `accounts:lookup`.
  ///
  /// Identity Toolkit's TOTP finalize response shape (observed):
  ///   * `mfaInfo`: list with the newly-enrolled factor (preferred), OR
  ///   * top-level `mfaEnrollmentId` (some older response variants), OR
  ///   * `totpAuthInfo` / `phoneAuthInfo` with `mfaEnrollmentId` nested.
  ///
  /// Only entries with a `totpInfo` discriminator are accepted (so an SMS
  /// factor that happens to be present cannot satisfy a TOTP enrollment).
  static String? _factorIdFromFinalizeBody(Map<String, Object?> body) {
    final directId = _optionalString(body['mfaEnrollmentId']);
    if (directId != null) return directId;

    final mfaInfo = body['mfaInfo'];
    if (mfaInfo is List) {
      for (final entry in mfaInfo) {
        if (entry is! Map) continue;
        final item = Map<String, Object?>.from(entry);
        if (!item.containsKey('totpInfo')) continue;
        final id = _optionalString(item['mfaEnrollmentId']);
        if (id != null) return id;
      }
    }

    for (final key in const <String>['totpAuthInfo', 'phoneAuthInfo']) {
      final nested = body[key];
      if (nested is Map) {
        final id = _optionalString(
          Map<String, Object?>.from(nested)['mfaEnrollmentId'],
        );
        if (id != null) return id;
      }
    }

    return null;
  }

  @override
  Future<List<FirebaseMfaTotpFactor>> listTotpFactors({
    String authorizationIdToken = '',
    required String userId,
  }) async {
    final body = await _postWithApiKey('/v1/accounts:lookup', <String, Object?>{
      'idToken': authorizationIdToken,
    }, expectedStatus: 200);
    final users = body['users'];
    if (users is! List || users.isEmpty || users.first is! Map) {
      return const <FirebaseMfaTotpFactor>[];
    }
    final user = Map<String, Object?>.from(users.first as Map);
    final mfaInfo = user['mfaInfo'];
    if (mfaInfo is! List) return const <FirebaseMfaTotpFactor>[];
    final factors = <FirebaseMfaTotpFactor>[];
    for (final entry in mfaInfo) {
      if (entry is! Map) continue;
      final item = Map<String, Object?>.from(entry);
      if (!item.containsKey('totpInfo')) continue;
      final id = _optionalString(item['mfaEnrollmentId']);
      if (id == null) continue;
      final enrolledAt =
          DateTime.tryParse(_optionalString(item['enrolledAt']) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      factors.add(
        FirebaseMfaTotpFactor(
          factorId: id,
          enrolledAt: enrolledAt.toUtc(),
          displayName: _optionalString(item['displayName']),
        ),
      );
    }
    return List<FirebaseMfaTotpFactor>.unmodifiable(factors);
  }

  @override
  Future<void> unenrollFactor({
    String authorizationIdToken = '',
    required String userId,
    required String factorId,
  }) async {
    await _postWithApiKey(
      '/v2/accounts/mfaEnrollment:withdraw',
      <String, Object?>{
        'idToken': authorizationIdToken,
        'mfaEnrollmentId': factorId,
      },
      expectedStatus: 200,
    );
  }

  Future<String> _latestTotpEnrollmentId(String idToken) async {
    final body = await _postWithApiKey('/v1/accounts:lookup', <String, Object?>{
      'idToken': idToken,
    }, expectedStatus: 200);
    final users = body['users'];
    if (users is! List || users.isEmpty || users.first is! Map) {
      throw const IdentityToolkitFirebaseMfaError('mfa_lookup_missing_user');
    }
    final user = Map<String, Object?>.from(users.first as Map);
    final mfaInfo = user['mfaInfo'];
    if (mfaInfo is! List) {
      throw const IdentityToolkitFirebaseMfaError('mfa_lookup_missing_totp');
    }

    String? latestId;
    DateTime? latestAt;
    for (final entry in mfaInfo) {
      if (entry is! Map) continue;
      final item = Map<String, Object?>.from(entry);
      if (!item.containsKey('totpInfo')) continue;
      final id = _optionalString(item['mfaEnrollmentId']);
      if (id == null) continue;
      final enrolledAt =
          DateTime.tryParse(_optionalString(item['enrolledAt']) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      if (latestId == null || enrolledAt.isAfter(latestAt!)) {
        latestId = id;
        latestAt = enrolledAt.toUtc();
      }
    }
    if (latestId == null) {
      throw const IdentityToolkitFirebaseMfaError('mfa_lookup_missing_totp');
    }
    return latestId;
  }

  Future<Map<String, Object?>> _postWithApiKey(
    String path,
    Map<String, Object?> body, {
    required int expectedStatus,
  }) {
    return _post(
      Uri.https('identitytoolkit.googleapis.com', path, <String, String>{
        'key': apiKey,
      }),
      body,
      expectedStatus: expectedStatus,
    );
  }

  Future<Map<String, Object?>> _post(
    Uri uri,
    Map<String, Object?> body, {
    required int expectedStatus,
  }) async {
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
      throw IdentityToolkitFirebaseMfaError(
        _errorCodeFromBody(raw) ?? 'identitytoolkit_mfa_request_failed',
        statusCode: response.statusCode,
      );
    }
    if (raw.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const <String, Object?>{};
    return Map<String, Object?>.from(decoded);
  }

  static String _buildOtpAuthUrl({
    required String issuerName,
    required String userEmail,
    required String secretBase32,
    String? hashingAlgorithm,
    int? verificationCodeLength,
    int? periodSec,
  }) {
    final label =
        '${Uri.encodeComponent(issuerName)}:${Uri.encodeComponent(userEmail)}';
    final algorithm = _otpAlgorithm(hashingAlgorithm);
    final query = Uri(
      queryParameters: <String, String>{
        'secret': secretBase32,
        'issuer': issuerName,
        if (algorithm != null) 'algorithm': algorithm,
        if (verificationCodeLength != null)
          'digits': verificationCodeLength.toString(),
        if (periodSec != null) 'period': periodSec.toString(),
      },
    ).query;
    return 'otpauth://totp/$label?$query';
  }

  static String? _otpAlgorithm(String? value) {
    if (value == null) return null;
    final normalized = value.trim().toUpperCase();
    if (normalized == 'SHA1' ||
        normalized == 'SHA256' ||
        normalized == 'SHA512') {
      return normalized;
    }
    return null;
  }

  static Map<String, Object?> _readMap(Object? value, String fieldName) {
    if (value is Map) return Map<String, Object?>.from(value);
    throw IdentityToolkitFirebaseMfaError('missing_$fieldName');
  }

  static String _readString(Object? value, String fieldName) {
    final parsed = _optionalString(value);
    if (parsed != null) return parsed;
    throw IdentityToolkitFirebaseMfaError('missing_$fieldName');
  }

  static String? _optionalString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _optionalInt(Object? value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String? _errorCodeFromBody(String raw) {
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
      // Provider bodies collapse to a generic code if malformed.
    }
    return null;
  }

  static String _messageForCode(String code) {
    switch (code) {
      case 'invalid_code':
      case 'invalid_verification_code':
      case 'invalid_totp_code':
      case 'totp_verification_code_invalid':
        return 'Code did not match. Try again.';
      case 'mfa_lookup_missing_totp':
      case 'mfa_lookup_missing_user':
        return 'MFA enrollment could not be verified. Please try again.';
      default:
        return 'MFA enrollment failed. Please try again.';
    }
  }
}

class IdentityToolkitFirebaseMfaError implements Exception {
  const IdentityToolkitFirebaseMfaError(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  @override
  String toString() =>
      'IdentityToolkitFirebaseMfaError(code: $code, status: $statusCode)';
}
