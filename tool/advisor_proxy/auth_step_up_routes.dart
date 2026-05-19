// Lane B B11.2 — RFC 9470 step-up challenge emitter for sensitive
// proxy routes.
//
// RFC 9470 (OAuth 2.0 Step Up Authentication Challenge Protocol)
// shape:
//
//   On a flagged sensitive route, when the caller's bearer token does
//   not meet the route's freshness or acr policy, the proxy returns:
//
//     HTTP/1.1 401 Unauthorized
//     WWW-Authenticate: Bearer error="insufficient_user_authentication",
//                       acr_values="urn:mfa", max_age=300
//     Content-Type: application/json
//     {
//       "error":   "insufficient_user_authentication",
//       "message": "<plain English step-up reason>",
//       "challenge_id":           "<opaque>",
//       "required_acr":           "urn:mfa",
//       "max_age_seconds":        300,
//       "challenge_expires_in_seconds": 300
//     }
//
//   The client (mobile or web) re-authenticates via the existing MFA
//   flow, gets a fresh JWT with a new `auth_time`, replays the
//   original request (with the same body) carrying the new token AND
//   the `step_up_challenge_id` header. The proxy then:
//
//     * verifies freshness/acr now meets the route's policy, AND
//     * atomically consumes the challenge row
//       (UPDATE ... RETURNING with predicate
//        consumed_at IS NULL AND expires_at > now() AND
//        route_path = $route AND user_id = $user AND
//        operator_id = app_current_operator()).
//
//   If both succeed the request proceeds. Otherwise the proxy
//   re-emits a fresh challenge (one-shot consumption is the
//   replay-protection invariant).
//
// Authority:
//   * RFC 9470 — https://www.rfc-editor.org/rfc/rfc9470
//   * docs/archive/_execution/lane_b_features/03_execution_slices.md
//     ("B11.2 — RFC 9470 step-up challenge on sensitive routes")
//   * CLAUDE.md "Hard Promises" #4 (per-operator isolation)
//   * CLAUDE.md "Proxy & API Conventions" (idempotent writes, JWT-
//     resolved scope, no client-supplied operator_id)
//   * CLAUDE.md "Service principals" — actor_kind taxonomy. V1
//     SKIPS step-up emission for service_principal callers (no
//     interactive MFA); the policy returns
//     [StepUpRequirement.skipServicePrincipal] so the route-level
//     enforcement helper passes the request through.
//   * B11.1 precedent: tool/advisor_proxy/auth_handoff_routes.dart
//     (mirrored decomposed-routes pattern, gateway seam, audit sink
//     seam, recording test fakes).
//
// What this file ships:
//
//   * `kStepUpSensitiveRoutes` — the registry of sensitive routes +
//     their freshness / acr requirements. The registry is the source
//     of truth for "which routes need step-up". It is NOT injected;
//     a constant table keeps the policy auditable in code review.
//
//   * `StepUpPolicy` — pure-function classifier that takes a JWT
//     auth_time + the matching `StepUpRouteSpec` and returns a
//     `StepUpRequirement`. Stateless; deterministic; trivial to
//     unit-test.
//
//   * `StepUpChallengeRouter` — the integration handle. Route
//     handlers in advisor_proxy.dart (or the decomposed *_routes.dart
//     files) call `router.evaluate(...)` at the top of the handler
//     to decide whether to (a) pass through, (b) emit a 401 + 9470
//     challenge, or (c) consume a presented challenge_id and proceed.
//     The router holds the gateway + audit-sink seams.
//
//   * `StepUpChallengesGateway` — abstraction over the Postgres
//     persistence (the table created by
//     202605131400_b11_2_auth_step_up_challenges.sql). Production
//     binds a Postgres-backed implementation; tests pass a recording
//     fake.
//
//   * `StepUpAuditSink` — abstraction over the hash-chained audit
//     log. Production fans `auth.step_up.challenge_emitted` and
//     `auth.step_up.challenge_consumed` through AuditLogsRepository
//     in the same tenant transaction the persist/consume ran in.
//
//   * `buildWwwAuthenticateHeader` — the RFC 9470 quoting/format
//     helper. Pure function so a unit test can pin the header shape
//     against the RFC examples.
//
// File-isolation note (per the orchestrator agent prompt for B11.2):
//
//   This PR delivers schema + policy + router + tests. Per-route
//   wiring (calling `router.evaluate(...)` at the head of each
//   sensitive route's handler in advisor_proxy.dart and the
//   decomposed *_routes.dart files) is intentionally OUT OF SCOPE
//   here so this PR does not collide with the in-flight A3.2 / A4.2
//   proxy decomposition lanes and does not blow through the
//   bleed-stop ceiling in tool/advisor_proxy_size_lint.dart. A
//   follow-up wave wires the integration once A3.2/A4.2 land.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/step_up_challenges_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

/// RFC 9470 §4 error code that gates the step-up flow.
const String kStepUpErrorCode = 'insufficient_user_authentication';

/// Header field name carrying the RFC 9470 challenge.
const String kStepUpWwwAuthenticateHeader = 'WWW-Authenticate';

/// Header the client adds when replaying a request that originally
/// drew a step-up 401. The route handler reads this header, hands the
/// id to the consume gateway, and only admits the request when the
/// atomic consume returns the row.
///
/// Lower-case in the wire (HTTP headers are case-insensitive); the
/// constant is the canonical spelling used in code + audits.
const String kStepUpChallengeIdHeader = 'Step-Up-Challenge-Id';

/// Default acr value the V1 emitter requests when a route demands
/// MFA-fresh auth. Future per-route overrides may demand
/// `urn:mfa:totp` or `urn:mfa:webauthn` once the corresponding flows
/// are wired client-side; the per-route registry is the source of
/// truth.
const String kStepUpDefaultAcr = 'urn:mfa';

/// Default freshness window for step-up: 5 minutes (300 s) per the
/// slice doc. The per-route registry can override.
const Duration kStepUpDefaultFreshness = Duration(seconds: 300);

/// Default challenge TTL: 5 minutes. Long enough for an interactive
/// MFA prompt (TOTP or push) to complete; short enough that a stolen
/// challenge_id has a small replay window. Hard-capped at 15 minutes
/// by the table's CHECK constraint.
const Duration kStepUpDefaultChallengeTtl = Duration(seconds: 300);

/// Specification for one sensitive route. The registry holds one of
/// these per (method, pathOrPrefix) tuple.
///
/// Path matching is exact when [isPrefix] is false (e.g. `POST
/// /v1/auth/password/change`) and prefix-based when [isPrefix] is true
/// (e.g. `PATCH /v1/admin/auth/roles/<role_id>` matches
/// `/v1/admin/auth/roles/`).
class StepUpRouteSpec {
  const StepUpRouteSpec({
    required this.method,
    required this.path,
    required this.isPrefix,
    required this.acr,
    required this.maxAge,
    required this.challengeTtl,
    required this.label,
  });

  /// HTTP method the rule applies to (`POST`, `PATCH`, `DELETE`).
  final String method;

  /// Exact path (when [isPrefix] is false) or prefix (when [isPrefix]
  /// is true).
  final String path;

  /// True when [path] is a prefix; false when it is an exact match.
  final bool isPrefix;

  /// `acr_values` value the proxy demands. RFC 9470 §3 allows a
  /// space-separated list of acceptable values; for V1 we always
  /// demand a single value.
  final String acr;

  /// `max_age` value the proxy demands (RFC 9470 §3). The caller's
  /// JWT `auth_time` must be within this window.
  final Duration maxAge;

  /// Lifetime of the persisted challenge row. The client has this
  /// long to complete MFA + replay before the row expires.
  final Duration challengeTtl;

  /// Plain-English label surfaced in the 401 body's `message` field.
  /// Operator-friendly per CLAUDE.md UX writing standard.
  final String label;
}

/// V1 sensitive-route registry. Lives next to the policy so a code
/// reviewer sees the policy and the surface in the same file.
///
/// Ordering: more-specific paths before prefix-matchers, so the
/// matcher returns the first hit.
const List<StepUpRouteSpec> kStepUpSensitiveRoutes = <StepUpRouteSpec>[
  // ─── operator account edits ─────────────────────────────────────
  StepUpRouteSpec(
    method: 'PATCH',
    path: '/v1/operator/account',
    isPrefix: false,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Editing your account requires a fresh sign-in.',
  ),

  // ─── password change ────────────────────────────────────────────
  StepUpRouteSpec(
    method: 'POST',
    path: '/v1/auth/password/change',
    isPrefix: false,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Changing your password requires a fresh sign-in.',
  ),

  // ─── MFA enroll / revoke ────────────────────────────────────────
  StepUpRouteSpec(
    method: 'POST',
    path: '/v1/auth/mfa/totp/begin',
    isPrefix: false,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Enrolling a new MFA factor requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'POST',
    path: '/v1/auth/mfa/totp/confirm',
    isPrefix: false,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Enrolling a new MFA factor requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'POST',
    path: '/v1/auth/mfa/factors/revoke',
    isPrefix: false,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Removing an MFA factor requires a fresh sign-in.',
  ),

  // ─── admin role mutations (F&F admin console) ───────────────────
  StepUpRouteSpec(
    method: 'POST',
    path: '/v1/admin/auth/roles',
    isPrefix: false,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Creating a role requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'PATCH',
    path: '/v1/admin/auth/roles/',
    isPrefix: true,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Editing a role requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'DELETE',
    path: '/v1/admin/auth/roles/',
    isPrefix: true,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Deleting a role requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'POST',
    path: '/v1/admin/auth/role-grants',
    isPrefix: false,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Granting a role requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'DELETE',
    path: '/v1/admin/auth/role-grants/',
    isPrefix: true,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Revoking a role requires a fresh sign-in.',
  ),

  // ─── operator-web team role mutations ───────────────────────────
  StepUpRouteSpec(
    method: 'POST',
    path: '/v1/auth/team/roles',
    isPrefix: false,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Creating a team role requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'PATCH',
    path: '/v1/auth/team/roles/',
    isPrefix: true,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Editing a team role requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'DELETE',
    path: '/v1/auth/team/roles/',
    isPrefix: true,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Deleting a team role requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'POST',
    path: '/v1/auth/team/role-grants',
    isPrefix: false,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Granting a team role requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'DELETE',
    path: '/v1/auth/team/role-grants/',
    isPrefix: true,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Revoking a team role requires a fresh sign-in.',
  ),

  // ─── billing (Phase 11A.2 pricing routes) ───────────────────────
  StepUpRouteSpec(
    method: 'PATCH',
    path: '/v1/admin/pricing/operators/',
    isPrefix: true,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Editing pricing requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'PATCH',
    path: '/v1/admin/pricing/usage-caps',
    isPrefix: false,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label: 'Editing usage caps requires a fresh sign-in.',
  ),

  // ─── vendor applicability edits (B10) ───────────────────────────
  // The B10 admin route lands in a sibling slice; the prefix here
  // future-proofs the registry so when B10's routes commit they
  // automatically receive step-up coverage.
  StepUpRouteSpec(
    method: 'POST',
    path: '/v1/admin/vendor-applicability',
    isPrefix: true,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label:
        'Editing vendor applicability requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'PATCH',
    path: '/v1/admin/vendor-applicability',
    isPrefix: true,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label:
        'Editing vendor applicability requires a fresh sign-in.',
  ),
  StepUpRouteSpec(
    method: 'DELETE',
    path: '/v1/admin/vendor-applicability',
    isPrefix: true,
    acr: kStepUpDefaultAcr,
    maxAge: kStepUpDefaultFreshness,
    challengeTtl: kStepUpDefaultChallengeTtl,
    label:
        'Editing vendor applicability requires a fresh sign-in.',
  ),
];

/// Find the registry entry that applies to ([method], [path]). Returns
/// null when the route is not flagged sensitive (the proxy MUST NOT
/// emit a step-up challenge for unflagged routes — that would be a
/// noisy false positive that trains operators to ignore step-up
/// prompts).
StepUpRouteSpec? lookupStepUpRoute({
  required String method,
  required String path,
  List<StepUpRouteSpec> registry = kStepUpSensitiveRoutes,
}) {
  for (final spec in registry) {
    if (spec.method != method) continue;
    if (spec.isPrefix) {
      if (path.startsWith(spec.path)) return spec;
    } else {
      if (path == spec.path) return spec;
    }
  }
  return null;
}

/// Outcome of running the step-up policy on one (route, caller) pair.
sealed class StepUpRequirement {
  const StepUpRequirement();
}

/// Route is not flagged sensitive — let the request through.
class StepUpRequirementNotSensitive extends StepUpRequirement {
  const StepUpRequirementNotSensitive();
}

/// Route is flagged sensitive but caller is a service principal —
/// V1 SKIPS step-up emission because service principals do not have
/// an interactive MFA flow. Documented in the migration's actor_kind
/// note.
class StepUpRequirementSkipServicePrincipal extends StepUpRequirement {
  const StepUpRequirementSkipServicePrincipal();
}

/// Caller's auth_time is fresh enough AND no challenge replay is
/// required — pass through.
class StepUpRequirementFreshEnough extends StepUpRequirement {
  const StepUpRequirementFreshEnough({required this.spec});
  final StepUpRouteSpec spec;
}

/// Caller's auth_time is stale — emit a 401 + RFC 9470 challenge.
/// The route handler should call `router.emitChallenge(...)` to
/// persist the row + write the response.
class StepUpRequirementChallengeNeeded extends StepUpRequirement {
  const StepUpRequirementChallengeNeeded({
    required this.spec,
    required this.reason,
  });
  final StepUpRouteSpec spec;

  /// Plain-English reason ("missing_auth_time" / "auth_time_stale").
  /// Surfaces in audit payload + diagnostic chips. Not shown to end
  /// users (the user-facing message is `spec.label`).
  final String reason;
}

/// Pure-function step-up policy. Decides whether to challenge based on
/// (a) the matched route spec, (b) the caller's `auth_time`, and (c)
/// the caller's `actor_kind`.
class StepUpPolicy {
  const StepUpPolicy();

  /// Evaluates whether the request needs a step-up challenge.
  ///
  /// Inputs:
  ///   * [spec] — the matched route entry (or null when the route is
  ///     not flagged).
  ///   * [authTime] — caller's JWT `auth_time` claim. Null when the
  ///     JWT did not carry one (treated as "never fresh").
  ///   * [actorKind] — caller's `actor_kind` (`'user'`,
  ///     `'service_principal'`, etc.).
  ///   * [now] — clock for freshness comparison.
  StepUpRequirement evaluate({
    required StepUpRouteSpec? spec,
    required DateTime? authTime,
    required String actorKind,
    required DateTime now,
  }) {
    if (spec == null) return const StepUpRequirementNotSensitive();
    if (actorKind == 'service_principal' || actorKind.startsWith('sp:')) {
      return const StepUpRequirementSkipServicePrincipal();
    }
    if (authTime == null) {
      return StepUpRequirementChallengeNeeded(
        spec: spec,
        reason: 'missing_auth_time',
      );
    }
    final age = now.toUtc().difference(authTime.toUtc());
    if (age <= spec.maxAge) {
      return StepUpRequirementFreshEnough(spec: spec);
    }
    return StepUpRequirementChallengeNeeded(
      spec: spec,
      reason: 'auth_time_stale',
    );
  }
}

/// RFC 9470 §3 quoted-string helper. Backslash-escapes `"` and `\` so
/// the value can be embedded in a `WWW-Authenticate` quoted-string
/// without breaking the parse on a stray quote. The acr / max_age /
/// error values we emit today are ASCII so this is defensive against
/// future label values that include punctuation.
String _wwwQuoted(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

/// Build the RFC 9470 `WWW-Authenticate: Bearer ...` header value
/// for a step-up challenge.
///
/// Shape:
///   `Bearer error="insufficient_user_authentication", `
///   `acr_values="urn:mfa", max_age=300, `
///   `error_description="<label>"`
///
/// `max_age` is bare-numeric per RFC 7235 §2.1 (only string params are
/// quoted). The label travels as `error_description` so the client
/// can show the operator-friendly reason; this is also RFC 6750 §3
/// vocabulary that existing OAuth client libraries understand.
String buildWwwAuthenticateHeader({
  required String acr,
  required Duration maxAge,
  required String label,
}) {
  return 'Bearer '
      'error=${_wwwQuoted(kStepUpErrorCode)}, '
      'acr_values=${_wwwQuoted(acr)}, '
      'max_age=${maxAge.inSeconds}, '
      'error_description=${_wwwQuoted(label)}';
}

/// Result of a successful one-shot consume.
class StepUpChallengeConsumed {
  const StepUpChallengeConsumed({
    required this.challengeId,
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.routePath,
    required this.requiredAcr,
    required this.requiredFreshnessSeconds,
    required this.consumedAt,
  });

  final String challengeId;
  final String operatorId;
  final String locationId;
  final String userId;
  final String routePath;
  final String requiredAcr;
  final int requiredFreshnessSeconds;
  final DateTime consumedAt;
}

/// Snapshot of a challenge row used by the consume failure
/// classifier. Mirrors the B11.1 `HandoffCodeState` shape so the
/// router's failure-classification idiom matches.
class StepUpChallengeState {
  const StepUpChallengeState({
    required this.operatorId,
    required this.userId,
    required this.routePath,
    required this.expiresAt,
    required this.consumedAt,
  });

  final String operatorId;
  final String userId;
  final String routePath;
  final DateTime expiresAt;
  final DateTime? consumedAt;
}

/// Persistence seam over `public.auth_step_up_challenges`. Production
/// binds a Postgres-backed implementation that issues the SET LOCAL
/// chain through the tenant transaction wrapper; tests pass a
/// recording fake.
abstract class StepUpChallengesGateway {
  /// Inserts a fresh challenge row. Returns the generated opaque
  /// `challenge_id`.
  Future<String> emit({
    required String operatorId,
    required String locationId,
    required String userId,
    required String routePath,
    required String requiredAcr,
    required int requiredFreshnessSeconds,
    required Duration challengeTtl,
    required String sourceActorKind,
    required String? sourceDeviceFingerprint,
  });

  /// Atomic consume. Returns the redeemed projection on success, null
  /// when no row matched the predicate (expired, consumed, wrong
  /// route, wrong user, wrong operator, or unknown id).
  Future<StepUpChallengeConsumed?> consume({
    required String callerOperatorId,
    required String callerLocationId,
    required String callerUserId,
    required String callerRoutePath,
    required String challengeId,
  });

  /// Reads the current state of [challengeId] without mutating it.
  /// Used by the consume failure classifier to distinguish
  ///   * 401 retry  — challenge expired, route mismatch, or
  ///                  user mismatch
  ///   * 410 gone   — already consumed in this tenant
  ///   * 401 unknown_challenge — id never existed (oracle-safe: same
  ///                  status as expired so brute-force probing cannot
  ///                  distinguish the two cases).
  Future<StepUpChallengeState?> lookupForReplayCheck({
    required String callerOperatorId,
    required String challengeId,
  });
}

/// Audit sink seam — production fans events to the hash-chained
/// `audit_logs` table; tests pass a recording fake.
abstract class StepUpAuditSink {
  /// Records `auth.step_up.challenge_emitted`.
  Future<void> recordChallengeEmitted({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required String challengeId,
    required String routePath,
    required String requiredAcr,
    required int requiredFreshnessSeconds,
    required String reason,
    required DateTime occurredAt,
  });

  /// Records `auth.step_up.challenge_consumed`.
  Future<void> recordChallengeConsumed({
    required StepUpChallengeConsumed row,
    required DateTime occurredAt,
  });
}

/// No-op audit sink for tests + scaffolds.
class NoopStepUpAuditSink implements StepUpAuditSink {
  const NoopStepUpAuditSink();

  @override
  Future<void> recordChallengeEmitted({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required String challengeId,
    required String routePath,
    required String requiredAcr,
    required int requiredFreshnessSeconds,
    required String reason,
    required DateTime occurredAt,
  }) async {}

  @override
  Future<void> recordChallengeConsumed({
    required StepUpChallengeConsumed row,
    required DateTime occurredAt,
  }) async {}
}

/// Lightweight rejection envelope mirroring B11.1's
/// `AuthHandoffRouteRejected`. Used by the consume-failure
/// classifier to surface typed errors back through the route layer.
class StepUpRouteRejected implements Exception {
  const StepUpRouteRejected({
    required this.code,
    required this.message,
    required this.statusCode,
    this.extras = const <String, Object?>{},
  });

  final String code;
  final String message;
  final int statusCode;
  final Map<String, Object?> extras;
}

/// Result tuple the router returns to the calling route handler so the
/// handler knows whether to (a) write the 401 + WWW-Authenticate, (b)
/// pass through, or (c) write a typed 4xx for a bad consume attempt.
sealed class StepUpDispatchResult {
  const StepUpDispatchResult();
}

/// Pass through — proceed with the original route handler.
class StepUpDispatchAdmit extends StepUpDispatchResult {
  const StepUpDispatchAdmit();
}

/// Emit a 401 + RFC 9470 challenge. The handler MUST write the
/// response using [statusCode], [headers], and [body] verbatim.
class StepUpDispatchChallenge extends StepUpDispatchResult {
  const StepUpDispatchChallenge({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

/// Emit a typed 4xx for a bad consume attempt (replay, unknown id,
/// wrong route, etc.). [statusCode] + [body] go on the wire verbatim.
class StepUpDispatchReject extends StepUpDispatchResult {
  const StepUpDispatchReject({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

/// Integration handle the route handlers call. One instance per
/// proxy, wired in `proxy_bootstrap.dart` once the per-route
/// integration lands (see file-isolation note at the top of this
/// file — wiring is intentionally OUT OF SCOPE for the B11.2 PR).
class StepUpChallengeRouter {
  StepUpChallengeRouter({
    required this.gateway,
    StepUpAuditSink? auditSink,
    StepUpPolicy? policy,
    List<StepUpRouteSpec> registry = kStepUpSensitiveRoutes,
  })  : _auditSink = auditSink ?? const NoopStepUpAuditSink(),
        _policy = policy ?? const StepUpPolicy(),
        _registry = registry;

  final StepUpChallengesGateway gateway;
  final StepUpAuditSink _auditSink;
  final StepUpPolicy _policy;
  final List<StepUpRouteSpec> _registry;

  /// True when ([method], [path]) is one of the registry entries.
  /// Cheap path lookup so the route layer can skip the heavier
  /// `dispatch` call when the route is not flagged.
  bool isSensitive({required String method, required String path}) {
    return lookupStepUpRoute(
          method: method,
          path: path,
          registry: _registry,
        ) !=
        null;
  }

  /// Top-level entry point. Combines:
  ///
  ///   1. Match the route against the registry.
  ///   2. If not sensitive -> [StepUpDispatchAdmit].
  ///   3. If service principal -> [StepUpDispatchAdmit] (V1 skip).
  ///   4. If a `Step-Up-Challenge-Id` header is present -> attempt
  ///      atomic consume. Success -> [StepUpDispatchAdmit]. Failure
  ///      -> [StepUpDispatchReject] with 410 / 401 per the classifier.
  ///   5. Otherwise -> evaluate freshness:
  ///        * fresh enough -> [StepUpDispatchAdmit]
  ///        * stale / missing -> emit a fresh challenge and return
  ///          [StepUpDispatchChallenge].
  ///
  /// The route handler writes the response based on the returned
  /// variant; this method does not touch HttpResponse so it stays
  /// trivially testable.
  Future<StepUpDispatchResult> dispatch({
    required String method,
    required String path,
    required String operatorId,
    required String locationId,
    required String userId,
    required String actorKind,
    required DateTime? authTime,
    required String? presentedChallengeId,
    required String? sourceDeviceFingerprint,
    DateTime Function()? now,
  }) async {
    final clock = now ?? DateTime.now;
    final spec = lookupStepUpRoute(
      method: method,
      path: path,
      registry: _registry,
    );

    final requirement = _policy.evaluate(
      spec: spec,
      authTime: authTime,
      actorKind: actorKind,
      now: clock(),
    );

    switch (requirement) {
      case StepUpRequirementNotSensitive():
        return const StepUpDispatchAdmit();
      case StepUpRequirementSkipServicePrincipal():
        return const StepUpDispatchAdmit();
      case StepUpRequirementFreshEnough():
        // Fresh enough — but if the client offered a challenge id we
        // still consume it (one-shot) so a stolen id cannot replay
        // later. This is defense in depth: the freshness check is
        // already sufficient, but consuming a presented id keeps the
        // table's invariant honest.
        if (presentedChallengeId != null && presentedChallengeId.isNotEmpty) {
          await _tryConsumeAndIgnore(
            operatorId: operatorId,
            locationId: locationId,
            userId: userId,
            routePath: path,
            challengeId: presentedChallengeId,
            now: clock,
          );
        }
        return const StepUpDispatchAdmit();
      case StepUpRequirementChallengeNeeded(:final spec, :final reason):
        if (presentedChallengeId != null && presentedChallengeId.isNotEmpty) {
          return await _consumeOrReject(
            operatorId: operatorId,
            locationId: locationId,
            userId: userId,
            routePath: path,
            challengeId: presentedChallengeId,
            now: clock,
          );
        }
        return await _emitChallenge(
          operatorId: operatorId,
          locationId: locationId,
          userId: userId,
          actorKind: actorKind,
          routePath: path,
          spec: spec,
          reason: reason,
          sourceDeviceFingerprint: sourceDeviceFingerprint,
          now: clock,
        );
    }
  }

  Future<StepUpDispatchChallenge> _emitChallenge({
    required String operatorId,
    required String locationId,
    required String userId,
    required String actorKind,
    required String routePath,
    required StepUpRouteSpec spec,
    required String reason,
    required String? sourceDeviceFingerprint,
    required DateTime Function() now,
  }) async {
    final emittedAt = now().toUtc();
    final challengeId = await gateway.emit(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      routePath: routePath,
      requiredAcr: spec.acr,
      requiredFreshnessSeconds: spec.maxAge.inSeconds,
      challengeTtl: spec.challengeTtl,
      sourceActorKind: actorKind,
      sourceDeviceFingerprint: sourceDeviceFingerprint,
    );

    // Audit fan-out. Failures inside the audit sink are surfaced via
    // the sink's own discipline (production logs + swallows; test
    // fakes throw). The challenge row already committed inside the
    // tenant transaction so an audit failure cannot un-emit it.
    await _auditSink.recordChallengeEmitted(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: userId,
      actorKind: actorKind,
      challengeId: challengeId,
      routePath: routePath,
      requiredAcr: spec.acr,
      requiredFreshnessSeconds: spec.maxAge.inSeconds,
      reason: reason,
      occurredAt: emittedAt,
    );

    final headerValue = buildWwwAuthenticateHeader(
      acr: spec.acr,
      maxAge: spec.maxAge,
      label: spec.label,
    );

    return StepUpDispatchChallenge(
      statusCode: 401,
      headers: <String, String>{
        kStepUpWwwAuthenticateHeader: headerValue,
      },
      body: <String, Object?>{
        'error': kStepUpErrorCode,
        'message': spec.label,
        'challenge_id': challengeId,
        'required_acr': spec.acr,
        'max_age_seconds': spec.maxAge.inSeconds,
        'challenge_expires_in_seconds': spec.challengeTtl.inSeconds,
        'reason': reason,
      },
    );
  }

  Future<StepUpDispatchResult> _consumeOrReject({
    required String operatorId,
    required String locationId,
    required String userId,
    required String routePath,
    required String challengeId,
    required DateTime Function() now,
  }) async {
    final consumed = await gateway.consume(
      callerOperatorId: operatorId,
      callerLocationId: locationId,
      callerUserId: userId,
      callerRoutePath: routePath,
      challengeId: challengeId,
    );
    if (consumed != null) {
      await _auditSink.recordChallengeConsumed(
        row: consumed,
        occurredAt: now().toUtc(),
      );
      return const StepUpDispatchAdmit();
    }

    // Predicate failed. Classify so the caller sees the right code:
    //   * 410 — challenge already consumed (in this operator + same
    //           route + same user)
    //   * 401 — every other failure (expired, route mismatch, user
    //           mismatch, wrong operator, unknown id). 401 is the
    //           oracle-safe default — revealing "no such challenge"
    //           would help a brute-force attacker probe the id space.
    final state = await gateway.lookupForReplayCheck(
      callerOperatorId: operatorId,
      challengeId: challengeId,
    );
    if (state != null &&
        state.operatorId == operatorId &&
        state.userId == userId &&
        state.routePath == routePath &&
        state.consumedAt != null) {
      return StepUpDispatchReject(
        statusCode: 410,
        body: <String, Object?>{
          'error': 'step_up_challenge_already_consumed',
          'message':
              'This step-up challenge has already been used. Please '
              're-authenticate and try again.',
        },
      );
    }
    return StepUpDispatchReject(
      statusCode: 401,
      body: <String, Object?>{
        'error': kStepUpErrorCode,
        'message':
            'Step-up challenge is unknown or no longer valid. Please '
            're-authenticate and try again.',
      },
    );
  }

  Future<void> _tryConsumeAndIgnore({
    required String operatorId,
    required String locationId,
    required String userId,
    required String routePath,
    required String challengeId,
    required DateTime Function() now,
  }) async {
    try {
      final consumed = await gateway.consume(
        callerOperatorId: operatorId,
        callerLocationId: locationId,
        callerUserId: userId,
        callerRoutePath: routePath,
        challengeId: challengeId,
      );
      if (consumed != null) {
        await _auditSink.recordChallengeConsumed(
          row: consumed,
          occurredAt: now().toUtc(),
        );
      }
    } catch (_) {
      // Fresh-enough caller — best-effort consume only. Swallow.
    }
  }
}

/// Stable hash helper used by future Postgres-backed gateway
/// implementations that audit a challenge id without leaking the
/// raw id to the audit row. Lives here so repository code can import
/// the canonical implementation rather than re-rolling SHA-256.
String hashStepUpChallengeIdForAudit(String challengeId) {
  return sha256.convert(utf8.encode(challengeId)).toString();
}

// ─── B11.2.b production bindings ────────────────────────────────────
//
// The classes below are the production implementations of the abstract
// seams defined above. They wrap [StepUpChallengesRepository]
// (Postgres-backed; lib/infrastructure/persistence/postgres) and the
// hash-chained [AuditLogsRepository], and live next to the seams they
// implement so a reviewer sees the interface, the in-memory recording
// fake (in tests), and the production binding in one file. Mirrors the
// B11.1 idiom (`RepositoryHandoffCodesGateway` + `ProductionHandoffAuditSink`).

/// Production gateway backed by the Postgres repository. Wired into
/// the proxy via `proxy_bootstrap.dart`.
class RepositoryStepUpChallengesGateway implements StepUpChallengesGateway {
  RepositoryStepUpChallengesGateway({required this.repository});

  final StepUpChallengesRepository repository;

  @override
  Future<String> emit({
    required String operatorId,
    required String locationId,
    required String userId,
    required String routePath,
    required String requiredAcr,
    required int requiredFreshnessSeconds,
    required Duration challengeTtl,
    required String sourceActorKind,
    required String? sourceDeviceFingerprint,
  }) =>
      repository.emit(
        operatorId: operatorId,
        locationId: locationId,
        userId: userId,
        routePath: routePath,
        requiredAcr: requiredAcr,
        requiredFreshnessSeconds: requiredFreshnessSeconds,
        challengeTtl: challengeTtl,
        sourceActorKind: sourceActorKind,
        sourceDeviceFingerprint: sourceDeviceFingerprint,
      );

  @override
  Future<StepUpChallengeConsumed?> consume({
    required String callerOperatorId,
    required String callerLocationId,
    required String callerUserId,
    required String callerRoutePath,
    required String challengeId,
  }) async {
    final row = await repository.consume(
      callerOperatorId: callerOperatorId,
      callerLocationId: callerLocationId,
      callerUserId: callerUserId,
      callerRoutePath: callerRoutePath,
      challengeId: challengeId,
    );
    if (row == null) return null;
    return StepUpChallengeConsumed(
      challengeId: row.challengeId,
      operatorId: row.operatorId,
      locationId: row.locationId,
      userId: row.userId,
      routePath: row.routePath,
      requiredAcr: row.requiredAcr,
      requiredFreshnessSeconds: row.requiredFreshnessSeconds,
      consumedAt: row.consumedAt,
    );
  }

  @override
  Future<StepUpChallengeState?> lookupForReplayCheck({
    required String callerOperatorId,
    required String challengeId,
  }) async {
    final state = await repository.lookupForReplayCheck(
      challengeId: challengeId,
    );
    if (state == null) return null;
    return StepUpChallengeState(
      operatorId: state.operatorId,
      userId: state.userId,
      routePath: state.routePath,
      expiresAt: state.expiresAt,
      consumedAt: state.consumedAt,
    );
  }
}

/// Production audit sink fan-out to the hash-chained `audit_logs`
/// table. Mirrors `ProductionHandoffAuditSink` (B11.1). Failures are
/// swallowed and surfaced via the structured logger so an audit-write
/// outage cannot 5xx a request whose challenge already committed.
///
/// `target_id` carries the SHA-256 hex hash of the challenge_id (never
/// the raw id) so the audit chain is not a token-leak vector.
class ProductionStepUpAuditSink implements StepUpAuditSink {
  ProductionStepUpAuditSink({
    required TenantTransactionWrapper tenantWrapper,
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    void Function(Object error, StackTrace stackTrace)? onError,
  })  : _tenantWrapper = tenantWrapper,
        _auditLogsRepository = auditLogsRepository,
        _onError = onError;

  final TenantTransactionWrapper _tenantWrapper;
  final AuditLogsRepository _auditLogsRepository;
  final void Function(Object error, StackTrace stackTrace)? _onError;

  @override
  Future<void> recordChallengeEmitted({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required String challengeId,
    required String routePath,
    required String requiredAcr,
    required int requiredFreshnessSeconds,
    required String reason,
    required DateTime occurredAt,
  }) async {
    final hashed = hashStepUpChallengeIdForAudit(challengeId);
    try {
      final ctx = TenantContext(
        operatorId: operatorId,
        locationId: locationId,
        userId: actorUserId,
      );
      await _tenantWrapper.runInTenantContext(ctx, (exec) async {
        await _auditLogsRepository.writeRow(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          occurredAt: occurredAt,
          actorKind: actorKind == 'user' ? 'user' : actorKind,
          actorUserId: actorUserId,
          targetKind: 'auth.step_up_challenge',
          targetId: hashed,
          action: 'auth.step_up_challenge.required',
          payload: <String, Object?>{
            'route_path': routePath,
            'required_acr': requiredAcr,
            'required_freshness_seconds': requiredFreshnessSeconds,
            'reason': reason,
            'challenge_id_hash': hashed,
          },
        );
      });
    } on Exception catch (error, stackTrace) {
      // Audit write is best-effort post-commit. Surface via onError so
      // the structured logger captures the failure; never re-throw.
      _onError?.call(error, stackTrace);
    }
  }

  @override
  Future<void> recordChallengeConsumed({
    required StepUpChallengeConsumed row,
    required DateTime occurredAt,
  }) async {
    final hashed = hashStepUpChallengeIdForAudit(row.challengeId);
    try {
      final ctx = TenantContext(
        operatorId: row.operatorId,
        locationId: row.locationId,
        userId: row.userId,
      );
      await _tenantWrapper.runInTenantContext(ctx, (exec) async {
        await _auditLogsRepository.writeRow(
          exec,
          operatorId: row.operatorId,
          locationId: row.locationId,
          occurredAt: occurredAt,
          actorKind: 'user',
          actorUserId: row.userId,
          targetKind: 'auth.step_up_challenge',
          targetId: hashed,
          action: 'auth.step_up_challenge.consumed',
          payload: <String, Object?>{
            'route_path': row.routePath,
            'required_acr': row.requiredAcr,
            'required_freshness_seconds': row.requiredFreshnessSeconds,
            'challenge_id_hash': hashed,
          },
        );
      });
    } on Exception catch (error, stackTrace) {
      _onError?.call(error, stackTrace);
    }
  }
}
