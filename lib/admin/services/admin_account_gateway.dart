// Wave 2 W-3 — admin "My Account" self-service profile gateway.
//
// The admin console parity surface for the operator-web W-3 self-
// service profile editor. Distinct from the W-1 admin members
// gateway (which edits *someone else's* row); this gateway edits the
// signed-in admin user's own display_name / email.
//
// Wire shape: the proxy route is the same as the operator-web side —
// `PATCH /v1/auth/self/profile`. The route resolves the target user
// from the verified bearer token, so the admin and the customer-web
// share the route. No separate `/v1/admin/auth/self/profile` route
// exists — that would force a parallel permission catalog entry,
// which CLAUDE.md HP #11 + R-2 explicitly disallow.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'admin_http_timeout.dart';

/// Bearer source the gateway attaches to every proxy call. Production
/// binds this to the admin Firebase ID-token stream; tests pin a
/// synthetic value.
typedef AdminAccountBearerTokenProvider = Future<String> Function();

/// Errors emitted by the gateway. Mirrors the existing admin gateway
/// error shape so the screen layer can show a calm friendly message.
class AdminAccountGatewayError implements Exception {
  const AdminAccountGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
    this.details = const <String, Object?>{},
  });

  final int statusCode;
  final String errorCode;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() =>
      'AdminAccountGatewayError($statusCode/$errorCode): $message';
}

/// Result of a successful PATCH.
@immutable
class AdminAccountProfilePatched {
  const AdminAccountProfilePatched({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.emailChanged,
    required this.displayNameChanged,
  });

  final String userId;
  final String email;
  final String displayName;
  final bool emailChanged;
  final bool displayNameChanged;
}

/// Self-service profile-edit surface for the F&F admin console.
abstract class AdminAccountGateway {
  /// Patches the signed-in admin's display name and/or email. At
  /// least one of [displayName] / [email] must be non-null; the proxy
  /// rejects the all-null shape with 400 `no_profile_fields`.
  ///
  /// [idempotencyKey] is required so a retry replays the same
  /// response without writing a second audit row.
  Future<AdminAccountProfilePatched> patchSelfProfile({
    String? displayName,
    String? email,
    required String idempotencyKey,
  });
}

/// Production HTTP implementation. Mirrors the
/// `HttpMembersAdminGateway` shape: the bearer source is injected so
/// the admin Firebase ID-token stream binds at startup and tests pin
/// a synthetic value.
class HttpAdminAccountGateway implements AdminAccountGateway {
  HttpAdminAccountGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri baseUri;
  final AdminAccountBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  /// Shared route — admin + operator-web both hit this path. The
  /// proxy resolves the actor from the verified bearer token, so the
  /// admin caller targets themselves automatically.
  static const String selfProfilePath = '/v1/auth/self/profile';

  @override
  Future<AdminAccountProfilePatched> patchSelfProfile({
    String? displayName,
    String? email,
    required String idempotencyKey,
  }) async {
    final trimmedDisplay = displayName?.trim();
    final trimmedEmail = email?.trim();
    if ((trimmedDisplay == null || trimmedDisplay.isEmpty) &&
        (trimmedEmail == null || trimmedEmail.isEmpty)) {
      throw const AdminAccountGatewayError(
        statusCode: 400,
        errorCode: 'no_profile_fields',
        message: 'at least one of email or display_name is required',
      );
    }
    final body = await _send(
      method: 'PATCH',
      path: selfProfilePath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        if (trimmedDisplay != null && trimmedDisplay.isNotEmpty)
          'display_name': trimmedDisplay,
        if (trimmedEmail != null && trimmedEmail.isNotEmpty)
          'email': trimmedEmail,
      },
    );
    final user = body['user'];
    if (user is! Map) {
      throw const AdminAccountGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin self-profile proxy returned an incomplete response',
      );
    }
    final userMap = Map<String, Object?>.from(user);
    final userId = _stringField(userMap, 'user_id');
    final emailValue = _stringField(userMap, 'email');
    final displayNameValue = _stringField(userMap, 'display_name');
    return AdminAccountProfilePatched(
      userId: userId,
      email: emailValue,
      displayName: displayNameValue,
      emailChanged: userMap['email_changed'] == true,
      displayNameChanged: userMap['display_name_changed'] == true,
    );
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    required String idempotencyKey,
    Map<String, Object?>? jsonBody,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json'
      ..headers['Idempotency-Key'] = idempotencyKey;
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw AdminAccountGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message: 'admin self-profile proxy timed out '
            'after ${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) parsed = decoded.cast<String, Object?>();
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    final message = (parsed['message'] as String?) ??
        'admin self-profile proxy returned an error';
    throw AdminAccountGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: message,
      details: parsed,
    );
  }

  static String _stringField(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is String && value.isNotEmpty) return value;
    throw AdminAccountGatewayError(
      statusCode: 502,
      errorCode: 'malformed_response',
      message: 'admin self-profile proxy response missing field $key',
    );
  }
}

/// In-memory demo gateway. Mirrors the seeded admin session row so
/// the walkthrough renders the editable surface without a backend.
class InMemoryAdminAccountGateway implements AdminAccountGateway {
  InMemoryAdminAccountGateway({
    required String initialDisplayName,
    required String initialEmail,
  })  : _displayName = initialDisplayName,
        _email = initialEmail;

  String _displayName;
  String _email;
  final List<AdminAccountPatchCall> calls = <AdminAccountPatchCall>[];

  /// Current snapshot of the in-memory state. Tests use this to
  /// assert the seeded row after a patch.
  String get currentDisplayName => _displayName;
  String get currentEmail => _email;

  @override
  Future<AdminAccountProfilePatched> patchSelfProfile({
    String? displayName,
    String? email,
    required String idempotencyKey,
  }) async {
    calls.add(AdminAccountPatchCall(
      displayName: displayName,
      email: email,
      idempotencyKey: idempotencyKey,
    ));
    final trimmedDisplay = displayName?.trim();
    final trimmedEmail = email?.trim();
    if ((trimmedDisplay == null || trimmedDisplay.isEmpty) &&
        (trimmedEmail == null || trimmedEmail.isEmpty)) {
      throw const AdminAccountGatewayError(
        statusCode: 400,
        errorCode: 'no_profile_fields',
        message: 'at least one of email or display_name is required',
      );
    }
    final displayNameChanged =
        trimmedDisplay != null && trimmedDisplay != _displayName;
    final emailChanged = trimmedEmail != null &&
        trimmedEmail.toLowerCase() != _email.toLowerCase();
    if (displayNameChanged) _displayName = trimmedDisplay;
    if (emailChanged) _email = trimmedEmail;
    return AdminAccountProfilePatched(
      userId: 'demo-admin',
      email: _email,
      displayName: _displayName,
      emailChanged: emailChanged,
      displayNameChanged: displayNameChanged,
    );
  }
}

@immutable
class AdminAccountPatchCall {
  const AdminAccountPatchCall({
    required this.displayName,
    required this.email,
    required this.idempotencyKey,
  });

  final String? displayName;
  final String? email;
  final String idempotencyKey;
}
