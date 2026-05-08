// CODE_OPS_DEBT carry-over #1 — Frontend listener for the
// `mfa_freshness_required` 403 redirect contract.
//
// The proxy's admin permission guard (see
// `tool/advisor_proxy/advisor_proxy.dart`
// `_requireAdminPermissionOrWrite`) returns a 403 with the following
// payload shape when an admin caller's `auth_time` claim falls
// outside the freshness window (`MFA_FRESHNESS_WINDOW_SECONDS`,
// default 1 hour — `lib/auth/fresh_mfa_resolver.dart`):
//
//   {
//     "error":         "mfa_freshness_required",
//     "message":       "fresh authentication is required",
//     "refresh_after": "<ISO-8601 timestamp>",
//     "redirect_uri":  "/auth/login?reason=fresh_mfa_required"
//                       "&permission_key=<encoded permission key>"
//   }
//
// PR #384 wired the proxy emission and the resolver. This file closes
// the matching frontend gap: the admin shell + operator-web 401/403
// handlers can detect the payload, extract the `redirect_uri` hint,
// and drive a full re-auth (sign-out → login → MFA → return) per the
// operator-locked decision in
// `runbooks/admin_provider_credentials_kms_rollout_runbook.md`
// section "MFA Freshness Window (CODE_OPS_DEBT Theme A item 1)".
//
// This module owns only the parser + the dispatcher seam. The actual
// sign-out is performed by the existing Firebase Auth sign-out path
// (admin: `AdminAuthSource.signOut`; operator-web:
// `OperatorWebAuthSource.signOut`); the navigation to the redirect
// target is the listener's responsibility. We deliberately do not
// invent a new sign-out flow here.

import 'package:meta/meta.dart';

/// Wire-shape of the proxy 403 emission. Parsed from the decoded
/// JSON body when [statusCode] is 403 and `body['error']` is
/// `'mfa_freshness_required'`. The `redirect_uri` is the only field
/// the frontend actually consumes; the others are surfaced for
/// diagnostics + tests.
@immutable
class MfaFreshnessRedirectPayload {
  const MfaFreshnessRedirectPayload({
    required this.redirectUri,
    this.message,
    this.refreshAfter,
  });

  /// Wire field name on the 403 body.
  static const String errorCode = 'mfa_freshness_required';

  /// Path the frontend should navigate to after sign-out. The proxy
  /// emits `/auth/login?reason=fresh_mfa_required&permission_key=...`;
  /// the frontend MUST treat this as opaque (no query-string parsing
  /// here) so a future proxy change to the URL shape does not require
  /// a coordinated client release.
  final String redirectUri;

  /// Human-readable message from the proxy (`'fresh authentication
  /// is required'`). Surfaced in the post-sign-out info banner.
  final String? message;

  /// ISO-8601 timestamp the proxy stamped — the moment the freshness
  /// window will refresh after a re-auth. Diagnostic only; not used
  /// in the navigation.
  final DateTime? refreshAfter;

  /// Tries to parse a decoded JSON body. Returns null if [statusCode]
  /// is not 403, the `error` field is not the freshness sentinel, or
  /// the `redirect_uri` is missing / empty / non-string. Defensive
  /// against partial / corrupted payloads — the caller can fall back
  /// to its existing 403 handling.
  static MfaFreshnessRedirectPayload? tryParse({
    required int statusCode,
    required Map<String, Object?> body,
  }) {
    if (statusCode != 403) return null;
    final error = body['error'];
    if (error is! String || error != errorCode) return null;
    final redirectUri = body['redirect_uri'];
    if (redirectUri is! String) return null;
    final trimmed = redirectUri.trim();
    if (trimmed.isEmpty) return null;
    final message = body['message'];
    final refreshAfterRaw = body['refresh_after'];
    DateTime? refreshAfter;
    if (refreshAfterRaw is String && refreshAfterRaw.trim().isNotEmpty) {
      refreshAfter = DateTime.tryParse(refreshAfterRaw.trim());
    }
    return MfaFreshnessRedirectPayload(
      redirectUri: trimmed,
      message: message is String ? message : null,
      refreshAfter: refreshAfter,
    );
  }
}

/// Listener seam wired by the admin shell and the operator-web shell.
/// Each shell registers its own implementation that:
///   1. signs out via the existing Firebase Auth sign-out path
///   2. emits a "needs sign-in" state with the `redirectUri` hint so
///      the screen layer can navigate after re-auth
///
/// Gateway code calls [onMfaFreshnessRedirect] when it parses the
/// payload off a 403 response. The listener is sync-fire-and-forget
/// from the gateway's POV — the gateway still throws its own typed
/// exception so existing call sites continue to surface error UI.
abstract class MfaFreshnessRedirectListener {
  /// Invoked when a gateway detects the proxy's
  /// `mfa_freshness_required` 403. Implementations must NOT throw —
  /// the gateway is mid-flight and any throw would mask the original
  /// 403.
  void onMfaFreshnessRedirect(MfaFreshnessRedirectPayload payload);
}

/// No-op listener used as a default so gateways can call into the
/// seam without a null check. Tests can replace it with a recording
/// fake.
class NoopMfaFreshnessRedirectListener implements MfaFreshnessRedirectListener {
  const NoopMfaFreshnessRedirectListener();

  @override
  void onMfaFreshnessRedirect(MfaFreshnessRedirectPayload payload) {}
}

/// Recording fake — useful in tests to assert the gateway dispatched
/// exactly one redirect with the expected URI.
class RecordingMfaFreshnessRedirectListener
    implements MfaFreshnessRedirectListener {
  final List<MfaFreshnessRedirectPayload> events =
      <MfaFreshnessRedirectPayload>[];

  @override
  void onMfaFreshnessRedirect(MfaFreshnessRedirectPayload payload) {
    events.add(payload);
  }
}
