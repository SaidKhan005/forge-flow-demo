// Audit fix-first #7 (cross-surface parity finding G4) — admin
// console self-service Security gateway (MFA enroll/confirm/recover +
// password change).
//
// The F&F Ops admin console pins 4 MFA-fresh-gated actions
// (`admin_routes.dart` `_isAdminMfaFresh` ~:94-114; gates :816-819)
// yet, before this slice, gave an admin NO way to enroll/recover their
// own MFA or change their password — the My Account Security card was
// read-only. An admin who never enrolled MFA out-of-band was
// permanently locked out of those 4 actions.
//
// Step-1 verdict: A — admin MFA/password is meant to be self-served
// in-app against the EXISTING shared self-service proxy routes, NOT
// provisioned out-of-band. Evidence:
//   * `docs/contracts/team_roles_hierarchy_console_parity_contract.md`
//     :38 — the "Security (MFA + password + login history)" row maps
//     the F&F admin's OWN-user self-service to `/v1/auth/mfa/*` +
//     `/v1/auth/password/*` (the SAME routes operator-web + mobile
//     use). The `/v1/admin/auth/users/:id/*` paths are for an admin
//     acting on SOMEONE ELSE — not their own factors.
//   * Same contract :208 — Security row, F&F admin self-service is
//     "(own user)"; current-password reverification per write.
//   * Same contract :221 — "No new backend routes" — every read/write
//     hits a route already shipped by Phase 9 + 11A.1.
//   * The proxy resolves the acting user from the verified bearer
//     token (`_resolveOperatorContextOrWrite`), so an admin Firebase
//     ID token targets the admin automatically:
//       - password change handler: advisor_proxy.dart:10406-10473
//         (scope from `_resolveOperatorContextOrWrite` :10416-10421;
//         200 `{ok:true,hibp_unavailable}`; PasswordChangeRejected →
//         `{error,message,rejections}`; 503 fail-closed).
//       - MFA begin/confirm/list handler: advisor_proxy.dart
//         :10927-11123 (scope :10937-10942; bearer required
//         :10943-10952; begin 200 `{factor_id,secret_base32,
//         otp_auth_url}` :10995-10999; confirm 200 `{factor_id}`
//         :11065-11067; list 200 `{factors:[...],removal_requests:
//         [...]}` :11087-11121).
//       - recovery request handler: advisor_proxy.dart:10858-10925
//         (UNauthenticated by design — recovery is for an actor who
//         has lost access to every factor; body `{email,reason?}`;
//         202 `{ok:true,queued,request_id?}`).
//
// Wire shape mirrors the sibling admin gateways exactly
// (`HttpAdminSessionsGateway` / `HttpAdminAccountGateway`): the bearer
// source is injected so the admin Firebase ID-token stream binds at
// startup and tests pin a synthetic value; every state-changing POST
// carries a required CALLER-stable `Idempotency-Key` threaded through
// unchanged (no fresh-key-per-call G60 bug — the screen layer mints
// one key per user action). No new admin-only route, no parallel
// permission catalog entry (CLAUDE.md HP #11 + R-2). Proxy code is
// NOT touched by this slice.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'admin_http_timeout.dart';

/// Bearer source the gateway attaches to authenticated proxy calls.
/// Production binds this to the admin Firebase ID-token stream (the
/// same `_firebaseIdTokenProvider` the sibling admin gateways use);
/// tests pin a synthetic value.
typedef AdminSecurityBearerTokenProvider = Future<String> Function();

/// Narrow error the gateway throws so the screen layer can render a
/// calm friendly message. Mirrors `AdminSessionsGatewayError`. The
/// optional [rejections] carries the server's password-policy
/// rejection codes (parity with `WebSecurityError.rejections`).
class AdminSecurityGatewayError implements Exception {
  const AdminSecurityGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
    this.rejections = const <String>[],
  });

  final int statusCode;
  final String errorCode;
  final String message;
  final List<String> rejections;

  @override
  String toString() =>
      'AdminSecurityGatewayError($statusCode/$errorCode): $message';
}

/// One enrolled MFA factor row. Mirrors the operator-web
/// `WebSecurityMfaFactor` shape.
@immutable
class AdminSecurityMfaFactor {
  const AdminSecurityMfaFactor({
    required this.factorId,
    required this.factorType,
    required this.enrolledAt,
    required this.issuerLabel,
    this.lastUsedAt,
  });

  final String factorId;
  final String factorType;
  final DateTime enrolledAt;
  final DateTime? lastUsedAt;
  final String issuerLabel;
}

/// Snapshot of the admin's enrolled MFA factors.
@immutable
class AdminSecurityFactorsListed {
  const AdminSecurityFactorsListed({required this.factors});

  final List<AdminSecurityMfaFactor> factors;

  bool get hasEnrolledFactor => factors.isNotEmpty;
}

/// Artifact returned by [AdminSecurityGateway.beginTotpEnrollment].
/// The screen renders the otpauth URL + shared secret so the admin
/// can scan or paste either into their authenticator app.
@immutable
class AdminSecurityTotpEnrollment {
  const AdminSecurityTotpEnrollment({
    required this.factorId,
    required this.otpAuthUrl,
    required this.secretBase32,
  });

  final String factorId;
  final String otpAuthUrl;
  final String secretBase32;
}

/// Result of confirming a TOTP enrollment.
@immutable
class AdminSecurityTotpConfirmed {
  const AdminSecurityTotpConfirmed({required this.factorId});

  final String factorId;
}

/// Result of [AdminSecurityGateway.changePassword].
@immutable
class AdminSecurityPasswordChanged {
  const AdminSecurityPasswordChanged({this.hibpUnavailable = false});

  final bool hibpUnavailable;
}

/// Result of [AdminSecurityGateway.requestMfaRecovery]. The proxy
/// returns 202 + a queue receipt; the recovery email lands
/// out-of-band so the screen only needs the queued + requestId hint.
@immutable
class AdminSecurityRecoveryRequested {
  const AdminSecurityRecoveryRequested({
    required this.queued,
    this.requestId,
  });

  final bool queued;
  final String? requestId;
}

/// Self-service Security surface for the F&F admin console. Every
/// method targets the SIGNED-IN admin (the proxy resolves the actor
/// from the verified bearer token); [requestMfaRecovery] is the one
/// exception — it runs unauthenticated because it exists precisely
/// for the locked-out admin who cannot present a fresh factor.
abstract class AdminSecurityGateway {
  /// Lists the signed-in admin's enrolled MFA factors via
  /// `POST /v1/auth/mfa/factors/list`.
  Future<AdminSecurityFactorsListed> listFactors();

  /// Begins a TOTP enrollment via `POST /v1/auth/mfa/totp/begin`. The
  /// proxy requires [userEmail] so the issued otpauth URL carries an
  /// account label the admin's authenticator app recognises.
  Future<AdminSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  });

  /// Confirms a TOTP enrollment via `POST /v1/auth/mfa/totp/confirm`.
  Future<AdminSecurityTotpConfirmed> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  });

  /// Changes the admin's password via `POST /v1/auth/password/change`.
  /// The proxy reverifies [currentPassword] before applying.
  Future<AdminSecurityPasswordChanged> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  });

  /// Queues an MFA recovery request via
  /// `POST /v1/auth/mfa/recovery/request`. The proxy accepts this
  /// WITHOUT an authenticated bearer token (recovery is for an admin
  /// who has lost access to every enrolled factor) and emails a
  /// recovery link out-of-band.
  Future<AdminSecurityRecoveryRequested> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  });
}

/// Production HTTP implementation. Constructor shape + bearer source +
/// timeout mirror `HttpAdminSessionsGateway`.
class HttpAdminSecurityGateway implements AdminSecurityGateway {
  HttpAdminSecurityGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
    DateTime Function()? now,
  })  : _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _now = now ?? DateTime.now;

  final Uri baseUri;
  final AdminSecurityBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;
  final DateTime Function() _now;

  // Path constants intentionally duplicate the proxy's
  // `authMfaTotpBeginPath` etc. The proxy file lives under tool/ and
  // lib/ cannot import it without dragging the whole proxy into the
  // Flutter binary. The strings are part of the wire contract; the
  // proxy endpoint tests pin both sides.
  static const String mfaFactorsListPath = '/v1/auth/mfa/factors/list';
  static const String mfaTotpBeginPath = '/v1/auth/mfa/totp/begin';
  static const String mfaTotpConfirmPath = '/v1/auth/mfa/totp/confirm';
  static const String mfaRecoveryRequestPath = '/v1/auth/mfa/recovery/request';
  static const String passwordChangePath = '/v1/auth/password/change';

  @override
  Future<AdminSecurityFactorsListed> listFactors() async {
    final body = await _send(
      method: 'POST',
      path: mfaFactorsListPath,
      jsonBody: const <String, Object?>{},
    );
    final raw = body['factors'];
    if (raw is! List) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin MFA factors proxy returned an incomplete response',
      );
    }
    return AdminSecurityFactorsListed(
      factors: List<AdminSecurityMfaFactor>.unmodifiable(
        raw.map(_factorFromJson),
      ),
    );
  }

  @override
  Future<AdminSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  }) async {
    final trimmedEmail = userEmail.trim();
    if (trimmedEmail.isEmpty) {
      throw const AdminSecurityGatewayError(
        statusCode: 400,
        errorCode: 'missing_user_email',
        message: 'an account email is required to begin enrollment',
      );
    }
    final body = await _send(
      method: 'POST',
      path: mfaTotpBeginPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{'user_email': trimmedEmail},
    );
    final factorId = _readNonBlank(body['factor_id']);
    final otpAuthUrl = _readNonBlank(body['otp_auth_url']) ??
        _readNonBlank(body['otpauth_url']);
    final secret = _readNonBlank(body['secret_base32']) ??
        _readNonBlank(body['shared_secret']);
    if (factorId == null || otpAuthUrl == null || secret == null) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin TOTP begin proxy returned an incomplete response',
      );
    }
    return AdminSecurityTotpEnrollment(
      factorId: factorId,
      otpAuthUrl: otpAuthUrl,
      secretBase32: secret,
    );
  }

  @override
  Future<AdminSecurityTotpConfirmed> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  }) async {
    final body = await _send(
      method: 'POST',
      path: mfaTotpConfirmPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'factor_id': factorId,
        'one_time_code': oneTimeCode,
      },
    );
    final confirmedFactorId = _readNonBlank(body['factor_id']);
    if (confirmedFactorId == null) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin TOTP confirm proxy returned an incomplete response',
      );
    }
    return AdminSecurityTotpConfirmed(factorId: confirmedFactorId);
  }

  @override
  Future<AdminSecurityPasswordChanged> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  }) async {
    final body = await _send(
      method: 'POST',
      path: passwordChangePath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    );
    return AdminSecurityPasswordChanged(
      hibpUnavailable: body['hibp_unavailable'] == true,
    );
  }

  @override
  Future<AdminSecurityRecoveryRequested> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  }) async {
    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty) {
      throw const AdminSecurityGatewayError(
        statusCode: 400,
        errorCode: 'missing_email',
        message: 'an account email is required to request recovery',
      );
    }
    // Recovery runs UNauthenticated (the admin has lost access to
    // every factor); still thread an Idempotency-Key so a retried
    // submit does not multiply the recovery queue.
    final uri = baseUri.resolve(mfaRecoveryRequestPath);
    final request = http.Request('POST', uri)
      ..headers['accept'] = 'application/json'
      ..headers['content-type'] = 'application/json'
      ..headers['Idempotency-Key'] = idempotencyKey
      ..bodyBytes = utf8.encode(jsonEncode(<String, Object?>{
        'email': trimmedEmail,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      }));
    final parsed = await _dispatch(request, expectStatuses: const <int>[
      200,
      202,
    ]);
    final queued = parsed['queued'];
    return AdminSecurityRecoveryRequested(
      queued: queued is bool ? queued : true,
      requestId: _readNonBlank(parsed['request_id']),
    );
  }

  AdminSecurityMfaFactor _factorFromJson(Object? raw) {
    if (raw is! Map) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin MFA factor row was malformed',
      );
    }
    final json = Map<String, Object?>.from(raw);
    final factorId = _readNonBlank(json['factor_id']);
    final factorType = _readNonBlank(json['factor_type']);
    final enrolledAtRaw = _readNonBlank(json['enrolled_at']);
    if (factorId == null || factorType == null || enrolledAtRaw == null) {
      throw const AdminSecurityGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin MFA factor row was incomplete',
      );
    }
    final lastUsedAtRaw = _readNonBlank(json['last_used_at']);
    return AdminSecurityMfaFactor(
      factorId: factorId,
      factorType: factorType,
      enrolledAt: DateTime.parse(enrolledAtRaw).toUtc(),
      lastUsedAt:
          lastUsedAtRaw == null ? null : DateTime.parse(lastUsedAtRaw).toUtc(),
      issuerLabel: _readNonBlank(json['issuer_label']) ?? 'Forge & Flow',
    );
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    String? idempotencyKey,
    Map<String, Object?>? jsonBody,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    return _dispatch(request, expectStatuses: const <int>[200]);
  }

  Future<Map<String, Object?>> _dispatch(
    http.Request request, {
    required List<int> expectStatuses,
  }) async {
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw AdminSecurityGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin security proxy timed out after ${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) parsed = decoded.cast<String, Object?>();
      } on FormatException {
        // Non-JSON body (e.g. an LB error page) — leave parsed empty
        // so the status branch surfaces a calm error rather than
        // parsing garbage.
      }
    }
    if (expectStatuses.contains(response.statusCode)) {
      return parsed;
    }
    throw AdminSecurityGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: (parsed['message'] as String?) ??
          'admin security proxy returned an error',
      rejections: _rejections(parsed['rejections']),
    );
  }

  static List<String> _rejections(Object? raw) {
    if (raw is! List) return const <String>[];
    return List<String>.unmodifiable(raw.whereType<String>());
  }

  static String? _readNonBlank(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  // Exposed so a future caller can pin "now" without reflection; kept
  // private-by-convention via the leading underscore on the field.
  // ignore: unused_element
  DateTime _clock() => _now().toUtc();
}

/// In-memory demo gateway. Mirrors a seeded "no factor enrolled" admin
/// so the kDemoMode / share-preview walkthrough renders the enroll +
/// password-change + recovery surface without a backend. Parity with
/// `InMemoryAdminSessionsGateway` / `InMemoryAdminAccountGateway`.
class InMemoryAdminSecurityGateway implements AdminSecurityGateway {
  InMemoryAdminSecurityGateway({
    bool seedEnrolledFactor = false,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (seedEnrolledFactor) {
      _factors.add(
        AdminSecurityMfaFactor(
          factorId: 'demo-admin-factor-1',
          factorType: 'totp',
          enrolledAt: _now().toUtc().subtract(const Duration(days: 30)),
          issuerLabel: 'Forge & Flow',
        ),
      );
    }
  }

  final DateTime Function() _now;
  final List<AdminSecurityMfaFactor> _factors = <AdminSecurityMfaFactor>[];
  final List<String> idempotencyKeys = <String>[];
  String? _pendingFactorId;

  @override
  Future<AdminSecurityFactorsListed> listFactors() async =>
      AdminSecurityFactorsListed(
        factors: List<AdminSecurityMfaFactor>.unmodifiable(_factors),
      );

  @override
  Future<AdminSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    _pendingFactorId = 'demo-admin-pending-factor';
    return AdminSecurityTotpEnrollment(
      factorId: _pendingFactorId!,
      otpAuthUrl:
          'otpauth://totp/Forge%20%26%20Flow:$userEmail?secret=DEMOSECRET234567'
          '&issuer=Forge%20%26%20Flow',
      secretBase32: 'DEMOSECRET234567',
    );
  }

  @override
  Future<AdminSecurityTotpConfirmed> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    if (oneTimeCode.trim().length != 6) {
      throw const AdminSecurityGatewayError(
        statusCode: 422,
        errorCode: 'mfa_totp_invalid_code',
        message: 'That code did not match. Try the next one.',
      );
    }
    _factors.add(
      AdminSecurityMfaFactor(
        factorId: factorId,
        factorType: 'totp',
        enrolledAt: _now().toUtc(),
        issuerLabel: 'Forge & Flow',
      ),
    );
    _pendingFactorId = null;
    return AdminSecurityTotpConfirmed(factorId: factorId);
  }

  @override
  Future<AdminSecurityPasswordChanged> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    if (newPassword.trim().length < 12) {
      throw const AdminSecurityGatewayError(
        statusCode: 422,
        errorCode: 'password_policy',
        message: 'That password does not meet the policy.',
        rejections: <String>['too_short'],
      );
    }
    return const AdminSecurityPasswordChanged();
  }

  @override
  Future<AdminSecurityRecoveryRequested> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    return const AdminSecurityRecoveryRequested(
      queued: true,
      requestId: 'demo-recovery-request-1',
    );
  }
}
