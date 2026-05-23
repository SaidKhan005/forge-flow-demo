// G63 — unified operator-web proxy error-envelope classification.
//
// The operator-web proxy answers every failure with one stable
// envelope: a JSON body `{ "error": <code>, "message": <msg> }` plus an
// HTTP status. The canonical client
// (`operator_web_proxy_client.dart`) already parses that envelope into a
// typed `OperatorWebProxyException`. What was missing — and what the
// G63 cross-surface parity audit flagged — is a SHARED way to turn that
// `(status, code)` pair into a canonical category every operator-web
// surface agrees on, so the team-roles / team-users / security gateways
// stop each inventing their own ad-hoc error code and their own
// inconsistent 409-replay / 403-freshness handling.
//
// This module is that shared interpreter. It is PURE: no I/O, no
// `dart:io`, no Flutter widget imports. It depends only on the typed
// exception (for the convenience extension) and the freshness sentinel
// constant. Gateways that do not route through the canonical client
// (the three named gateways still own their own `package:http`
// transport and their own typed error) classify off the raw
// `(statusCode, code, isMfaFreshnessRedirect)` triple via
// [classifyOperatorWebError] and borrow the canonical copy via
// [operatorWebErrorMessageFor], rather than duplicating the mapping.
//
// Contract: `docs/contracts/proxy_error_envelope_contract.md`.
// CLAUDE.md "Proxy & API Conventions".

import '../../auth/mfa_freshness_redirect_listener.dart';
import '../auth/step_up_challenge_handler.dart' show kStepUpErrorCode;
import 'operator_web_proxy_client.dart';

/// Canonical category for an operator-web proxy failure. Every
/// operator-web surface classifies into exactly one of these so error
/// handling, copy, and the replay-vs-conflict decision are uniform.
enum OperatorWebErrorKind {
  /// The proxy returned the `mfa_freshness_required` 403 (or the
  /// RFC 9470 step-up `insufficient_user_authentication` sentinel): the
  /// operator must sign in again before this protected action runs. The
  /// canonical client surfaces this as
  /// [OperatorWebProxyException.isMfaFreshnessRedirect]; the security
  /// gateway recognises the same two codes.
  mfaFreshnessRedirect,

  /// A plain permission denial: HTTP 403 that is NOT a freshness
  /// redirect. The caller's role lacks the permission the route gates
  /// on. Distinct from [mfaFreshnessRedirect] because the remedy is
  /// different — there is nothing the operator can do except ask for
  /// the permission; signing in again will not help.
  permissionDenied,

  /// HTTP 409 with code `idempotency_key_conflict`: the same
  /// Idempotency-Key was reused with a DIFFERENT request body. The
  /// proxy's `proxy_requests` UNIQUE guard treats a SAME-body retry as a
  /// replay of the prior 2xx (never a 409), so a 409 with this code
  /// means the logical action this key identifies was already
  /// processed. Surfaces are expected to treat it as "already applied",
  /// not as a hard error.
  idempotencyReplayConflict,

  /// HTTP 409 with any other code: a genuine domain conflict (e.g. the
  /// org unit still has children, the role still has active grants, a
  /// uniqueness rule was violated). The remedy is operator action, not
  /// a retry.
  resourceConflict,

  /// HTTP 404: the addressed resource does not exist (or is no longer
  /// visible to this operator).
  notFound,

  /// HTTP 400 or 422: the request was malformed or failed server-side
  /// validation. The remedy is to correct the input and retry.
  validation,

  /// A retryable transport / availability failure: HTTP 408, 429, or
  /// any 5xx. The remedy is to try again shortly.
  transient,

  /// Anything not covered above (including a synthesised exception with
  /// no HTTP status, e.g. a malformed-response or no-id-token guard).
  unknown,
}

/// Classifies a proxy failure into its canonical [OperatorWebErrorKind]
/// from the raw envelope signal every operator-web surface has on hand:
/// the HTTP [statusCode], the envelope [code] (`body['error']`), and
/// whether the canonical client already recognised a freshness redirect
/// ([isMfaFreshnessRedirect]).
///
/// Gateways that route through `OperatorWebProxyClient` should prefer
/// the [OperatorWebErrorClassification.kind] extension getter, which
/// feeds `isMfaFreshnessRedirect` from the typed exception. Gateways
/// that own their own transport (and therefore only have a status + an
/// envelope code) call this directly; they pass
/// `isMfaFreshnessRedirect: false` and rely on the code-based freshness
/// recognition below.
///
/// Freshness-vs-permission split: a 403 is [mfaFreshnessRedirect] when
/// the canonical client flagged it, OR when the envelope code is the
/// freshness sentinel ([MfaFreshnessRedirectPayload.errorCode]) or the
/// RFC 9470 step-up sentinel ([kStepUpErrorCode]). Every other 403 is a
/// plain [permissionDenied]. The step-up sentinel is folded in because
/// the security surface already drives the same "sign in again" remedy
/// for it.
OperatorWebErrorKind classifyOperatorWebError({
  required int? statusCode,
  required String? code,
  bool isMfaFreshnessRedirect = false,
}) {
  if (_isFreshnessFailure(statusCode, code, isMfaFreshnessRedirect)) {
    return OperatorWebErrorKind.mfaFreshnessRedirect;
  }
  return _kindForStatus(statusCode, code?.trim());
}

/// True when a failure is the two-factor-freshness redirect: the
/// canonical client already flagged it, OR the envelope code is the
/// `mfa_freshness_required` sentinel or the RFC 9470 step-up sentinel on
/// a 403. Recognising it by code lets a surface that only has the
/// envelope code (no status) classify it consistently.
bool _isFreshnessFailure(int? statusCode, String? code, bool clientFlagged) {
  if (clientFlagged) return true;
  if (statusCode != 403) return false;
  final normalisedCode = code?.trim();
  return normalisedCode == MfaFreshnessRedirectPayload.errorCode ||
      normalisedCode == kStepUpErrorCode;
}

/// Maps the HTTP status (plus the envelope code for the 409 split) to
/// its canonical kind. Freshness is resolved by [_isFreshnessFailure]
/// before this is reached, so a 403 here is always a plain permission
/// denial.
OperatorWebErrorKind _kindForStatus(int? statusCode, String? normalisedCode) {
  switch (statusCode) {
    case 403:
      return OperatorWebErrorKind.permissionDenied;
    case 409:
      return normalisedCode == kIdempotencyKeyConflictCode
          ? OperatorWebErrorKind.idempotencyReplayConflict
          : OperatorWebErrorKind.resourceConflict;
    case 404:
      return OperatorWebErrorKind.notFound;
    case 400:
    case 422:
      return OperatorWebErrorKind.validation;
  }
  if (_isTransientStatus(statusCode)) return OperatorWebErrorKind.transient;
  return OperatorWebErrorKind.unknown;
}

/// True for retryable transport / availability statuses: 408, 429, or
/// any 5xx.
bool _isTransientStatus(int? statusCode) {
  if (statusCode == null) return false;
  if (statusCode == 408 || statusCode == 429) return true;
  return statusCode >= 500 && statusCode < 600;
}

/// The proxy envelope code for a replayed Idempotency-Key collision: a
/// key reused with a DIFFERENT body. Confirmed in
/// `tool/advisor_proxy/auth_handoff_routes.dart` +
/// `admin_integrations_routes.dart`. A SAME-body retry replays the
/// prior 2xx instead of returning this.
const String kIdempotencyKeyConflictCode = 'idempotency_key_conflict';

/// Canonical, operator-facing copy for each [OperatorWebErrorKind].
/// Plain English, reads as guidance, no engineering jargon, no em dash
/// (CLAUDE.md "UX no-em-dash law" + UX writing standard). Surfaces may
/// still render their own more specific copy for a known envelope code
/// (e.g. "Revoke this role from every member before deleting it" for a
/// `role_has_active_grants` 409); this is the SHARED fallback so the
/// generic case reads the same everywhere.
String operatorWebErrorMessageFor(OperatorWebErrorKind kind) {
  switch (kind) {
    case OperatorWebErrorKind.mfaFreshnessRedirect:
      return 'Please sign in again to continue. This protects your account.';
    case OperatorWebErrorKind.permissionDenied:
      return 'You do not have permission to do this. Ask an owner or admin '
          'if you need access.';
    case OperatorWebErrorKind.idempotencyReplayConflict:
      return 'This change was already applied. No action is needed.';
    case OperatorWebErrorKind.resourceConflict:
      return 'This conflicts with something already saved. Refresh the page '
          'to see the latest, then try again.';
    case OperatorWebErrorKind.notFound:
      return 'We could not find that item. It may have been removed. Refresh '
          'the page to see the latest.';
    case OperatorWebErrorKind.validation:
      return 'Some details need fixing before we can save. Check your '
          'entries and try again.';
    case OperatorWebErrorKind.transient:
      return 'Something went wrong on our end. Try again in a moment.';
    case OperatorWebErrorKind.unknown:
      return 'Action could not be completed. Try again in a moment, or '
          'refresh the page if the problem keeps happening.';
  }
}

/// Convenience classification over the canonical typed exception so
/// surfaces that DO route through `OperatorWebProxyClient` get the kind
/// without restating the status/code wiring. Feeds
/// [OperatorWebProxyException.isMfaFreshnessRedirect] into the shared
/// [classifyOperatorWebError].
extension OperatorWebErrorClassification on OperatorWebProxyException {
  /// The canonical [OperatorWebErrorKind] for this exception.
  OperatorWebErrorKind get kind => classifyOperatorWebError(
    statusCode: statusCode,
    code: code,
    isMfaFreshnessRedirect: isMfaFreshnessRedirect,
  );

  /// The shared operator-facing message for this exception's kind. A
  /// caller that wants the proxy's own `message` instead can read
  /// [message] directly; this getter is the canonical-copy path.
  String get operatorFacingMessage => operatorWebErrorMessageFor(kind);
}
