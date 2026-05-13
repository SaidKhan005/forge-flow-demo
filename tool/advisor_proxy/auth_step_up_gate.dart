// Lane B B11.2.b — RFC 9470 step-up challenge gate, executed at the
// top of `routeRequest` BEFORE any sensitive handler dispatches.
//
// The gate intercepts every request whose (method, path) is registered
// in `kStepUpSensitiveRoutes` (`auth_step_up_routes.dart`). On flagged
// routes it:
//
//   1. Resolves the caller's operator scope via the proxy's standard
//      `ProxyRequestGuard.requireOperatorContext` path. Auth failure
//      collapses to the same 401/403 the underlying handler would
//      have emitted (so the gate is observability-neutral on the
//      unauth path).
//
//   2. Reads the `Step-Up-Challenge-Id` value from the REQUEST HEADER
//      (NEVER from URL parameters — addendum A1 prohibition is
//      enforced here at the choke-point; any new token-bearing path
//      added later must come through this header, full stop).
//
//   3. Hands (operator_id, location_id, user_id, actor_kind,
//      auth_time, presented_challenge_id) to
//      `StepUpChallengeRouter.dispatch(...)`. The router decides
//      whether to admit, emit a fresh 401 + WWW-Authenticate
//      challenge, or reject a bad consume attempt.
//
// Returns true when the gate wrote a response and the caller should
// stop processing (challenge / reject path); false when the request
// should fall through to the normal handler chain.
//
// Lives in a dedicated file (not inline in `advisor_proxy.dart`) to
// honor the bleed-stop ceiling at
// `tool/advisor_proxy_size_lint.dart` — the monolith is at the cap;
// new wiring lands in decomposed sibling files per the seam map at
// `docs/_audits/code_health/a3_advisor_proxy_seam_map.md`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'advisor_proxy.dart'
    show OperatorContext, ProxyAuthError, ProxyRequestGuard;
import 'auth_step_up_routes.dart';

/// Default JSON encoder for the gate's responses. Mirrors the
/// `_writeJson` discipline in `advisor_proxy.dart` (Content-Type +
/// `Cache-Control: no-store`).
void _writeStepUpJson(
  HttpResponse response,
  int statusCode,
  Map<String, Object?> body, {
  Map<String, String> extraHeaders = const <String, String>{},
}) {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
  extraHeaders.forEach(response.headers.set);
  response.write(jsonEncode(body));
}

/// Runs the step-up gate for one request. Returns:
///   * `true`  — the gate wrote a response (401/403/410). Caller must
///               not dispatch the handler.
///   * `false` — fall through (challenge admitted, or the route is
///               not flagged sensitive for THIS caller — e.g. service
///               principal V1 skip).
///
/// Side effects:
///   * Writes JSON + headers on the auth-error / challenge / reject
///     branches. Closes nothing — the caller's outer handler closes
///     the response per the existing `routeRequest` discipline.
///   * Audits via the router's wired audit sink (production binds the
///     hash-chained `audit_logs` table; tests bind a recording fake).
Future<bool> runStepUpGate({
  required HttpRequest request,
  required String path,
  required ProxyRequestGuard authGuard,
  required StepUpChallengeRouter router,
  required DateTime Function() now,
}) async {
  final response = request.response;
  OperatorContext scope;
  try {
    scope = await authGuard.requireOperatorContext(
      authorizationHeader: request.headers.value(
        HttpHeaders.authorizationHeader,
      ),
    );
  } on ProxyAuthError catch (error) {
    _writeStepUpJson(response, error.statusCode, <String, Object?>{
      'error': error.message,
    });
    return true;
  }

  // The `Step-Up-Challenge-Id` value flows through the request HEADER
  // ONLY (addendum A1). The proxy NEVER inspects URL parameters for
  // this value — any caller smuggling the id through `?challenge=...`
  // would simply skip the consume path here and re-trigger a fresh
  // challenge (oracle-safe).
  final presentedChallengeId =
      request.headers.value(kStepUpChallengeIdHeader)?.trim();

  final result = await router.dispatch(
    method: request.method,
    path: path,
    operatorId: scope.operatorId,
    locationId: scope.locationId,
    userId: scope.userId,
    actorKind: scope.actorKind,
    authTime: scope.lastFreshAuthAt,
    presentedChallengeId:
        presentedChallengeId == null || presentedChallengeId.isEmpty
            ? null
            : presentedChallengeId,
    sourceDeviceFingerprint: null,
    now: now,
  );

  switch (result) {
    case StepUpDispatchAdmit():
      return false;
    case StepUpDispatchChallenge(
          :final statusCode,
          :final headers,
          :final body
        ):
      _writeStepUpJson(response, statusCode, body, extraHeaders: headers);
      return true;
    case StepUpDispatchReject(:final statusCode, :final body):
      _writeStepUpJson(response, statusCode, body);
      return true;
  }
}
