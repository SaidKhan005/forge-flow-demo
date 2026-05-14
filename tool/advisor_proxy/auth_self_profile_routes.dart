// Wave 2 W-3 — self-service profile editor route.
//
// Authority: `docs/_indices/WAVE_2_LEDGER.md` Lane W row W-3 (debug.md
// :45-52, P-1 / P-2 / P-3, MO-6c/d). Permission catalog row:
// `docs/contracts/auth_permission_key_catalog.md` § `team.*` table —
// the new `team.users.self_update` key gates this route.
//
// Route shape
// -----------
//   PATCH /v1/auth/self/profile
//
// Headers:
//   Authorization: Bearer <id token>
//   Idempotency-Key: <client-generated>
//
// Body:
//   { "display_name": "<optional>", "email": "<optional>" }
//
// At least one of `display_name` / `email` MUST be present. The proxy
// rejects the all-null shape with 400 `no_profile_fields`.
//
// Why a sibling file (not the monolith)
// -------------------------------------
// `tool/advisor_proxy/advisor_proxy.dart` is at the
// `kAdvisorProxyMaxLines` bleed-stop ceiling (CLAUDE.md "R-2 ceiling-
// raise rule"). Raising the ceiling requires explicit operator
// approval. This file keeps the route entirely outside the monolith.
// The monolith dispatcher hooks one if-block that:
//   1) matches PATCH on this path
//   2) resolves the operator scope (verified bearer token)
//   3) checks the `team.users.self_update` permission gate
//   4) reads the Idempotency-Key header
//   5) hands the parsed body to [SelfProfileRouter.handle] below
//
// Distinct from the W-1 admin-edit route in two ways:
//   * actor == target — the route guard NEVER reads a target user id
//     from the URL or body. The gateway resolves it from the
//     verified bearer token (we do that at the dispatch site;
//     `SelfProfileRouter` receives [actorUserId] directly).
//   * permission gate is `team.users.self_update`, NOT
//     `team.users.invite` (which gates admin-editing-someone-else).
//
// Idempotency
// -----------
// Every successful response is cached by `(operator_id, route, key)`
// in the gateway-shared `authIdempotencyCache`. A retry with the same
// key replays the same response so a flaky network call does not
// generate two audit rows.

import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';

import 'team_users_edit_member_validation.dart' show looksLikeEmailForEditMember;

/// Path the operator-web / admin / mobile clients hit to patch their
/// own display name / email. Exported so the route registry + tests
/// reference one canonical string.
const String authSelfProfilePath = '/v1/auth/self/profile';

/// Permission key the route guard checks. Mirrors
/// `PermissionKeys.teamUsersSelfUpdate`; kept as a local constant so
/// the route handler does not import the Flutter-side catalog.
const String authSelfProfilePermissionKey = 'team.users.self_update';

/// Pre-flight rejection envelope. Mirrors the W-1 admin-edit
/// `EditMemberRouteRejection` so the dispatcher writes both shapes
/// the same way.
class SelfProfileRouteRejection {
  const SelfProfileRouteRejection({
    required this.statusCode,
    required this.error,
    required this.message,
  });

  final int statusCode;
  final String error;
  final String message;
}

/// Validated triple returned by [validateSelfProfileRouteBody]. Either
/// [rejection] is non-null (caller writes it verbatim) or the trimmed
/// `displayName` / `email` pair is ready for the gateway call.
class SelfProfileRouteInputs {
  const SelfProfileRouteInputs._({
    this.displayName,
    this.email,
    this.rejection,
  });

  /// Final trimmed display-name value, or null if the operator did not
  /// patch this field.
  final String? displayName;

  /// Final trimmed email value, or null if the operator did not patch
  /// this field.
  final String? email;

  /// Pre-flight rejection envelope ready to be surfaced verbatim. Null
  /// when the inputs pass validation.
  final SelfProfileRouteRejection? rejection;
}

/// Validates the PATCH `/v1/auth/self/profile` body. Returns a
/// [SelfProfileRouteInputs] carrying either the validated pair or a
/// [SelfProfileRouteRejection] the caller surfaces verbatim.
///
/// The route guard MUST be invoked before this function — actor
/// identity is resolved from the verified bearer token, never from
/// the body. We deliberately do not accept a `user_id` field in the
/// body so a client cannot patch another user's profile by guessing
/// the route shape.
SelfProfileRouteInputs validateSelfProfileRouteBody({
  required String? Function(Object? raw) nonBlankString,
  required Object? rawDisplayName,
  required Object? rawEmail,
}) {
  final displayName = nonBlankString(rawDisplayName);
  final email = nonBlankString(rawEmail);
  if (displayName == null && email == null) {
    return const SelfProfileRouteInputs._(
      rejection: SelfProfileRouteRejection(
        statusCode: 400,
        error: 'no_profile_fields',
        message: 'at least one of display_name or email is required',
      ),
    );
  }
  if (email != null && !looksLikeEmailForEditMember(email)) {
    return const SelfProfileRouteInputs._(
      rejection: SelfProfileRouteRejection(
        statusCode: 400,
        error: 'invalid_email',
        message: 'email must be a syntactically valid address',
      ),
    );
  }
  return SelfProfileRouteInputs._(
    displayName: displayName,
    email: email,
  );
}

/// Result of a successful PATCH. The route serializer turns this into
/// the JSON response body the client reads.
class SelfProfileRouteResult {
  const SelfProfileRouteResult({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

/// Tiny dispatcher seam — calls the injected [AuthOperationsGateway]
/// and turns the result / exceptions into a status-code + body pair.
/// The monolith dispatcher writes this back to the HTTP response.
class SelfProfileRouter {
  const SelfProfileRouter({required this.authOperationsGateway});

  final AuthOperationsGateway authOperationsGateway;

  /// True when [path] / [method] match this route. The dispatcher uses
  /// this in the monolithic `routeRequest` to short-circuit the
  /// catch-all 404 without wiring a per-route if-block.
  static bool matches(String path, String method) {
    return method == 'PATCH' && path == authSelfProfilePath;
  }

  Future<SelfProfileRouteResult> handle({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String? displayName,
    required String? email,
  }) async {
    try {
      final patched = await authOperationsGateway.patchSelfProfile(
        SelfProfilePatchCommand(
          actorUserId: actorUserId,
          operatorId: operatorId,
          locationId: locationId,
          displayName: displayName,
          email: email,
        ),
      );
      return SelfProfileRouteResult(
        statusCode: 200,
        body: <String, Object?>{
          'ok': true,
          'user': <String, Object?>{
            'user_id': patched.userId,
            'email': patched.email,
            'display_name': patched.displayName,
            'email_changed': patched.emailChanged,
            'display_name_changed': patched.displayNameChanged,
          },
        },
      );
    } on AuthOperationRejected catch (rejected) {
      return SelfProfileRouteResult(
        statusCode: rejected.statusCode,
        body: <String, Object?>{
          'error': rejected.code,
          'message': rejected.message,
          ...rejected.details,
        },
      );
    }
  }

  /// Helper consumed by the monolith dispatcher. Validates the body,
  /// either returns a rejection-shaped result or hands off to [handle].
  /// Lives here (not the monolith) so the bleed-stop ceiling stays
  /// honest. The dispatcher passes its `_nonBlankString` callback so
  /// the sibling does not need its own copy of that helper.
  Future<SelfProfileRouteResult> handleRequest({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
    required String? Function(Object? raw) nonBlankString,
  }) async {
    final inputs = validateSelfProfileRouteBody(
      nonBlankString: nonBlankString,
      rawDisplayName: body['display_name'],
      rawEmail: body['email'],
    );
    final rejection = inputs.rejection;
    if (rejection != null) {
      return SelfProfileRouteResult(
        statusCode: rejection.statusCode,
        body: <String, Object?>{
          'error': rejection.error,
          'message': rejection.message,
        },
      );
    }
    return handle(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      displayName: inputs.displayName,
      email: inputs.email,
    );
  }
}
