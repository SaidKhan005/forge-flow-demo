// Graph G5a -- AGE rebuild route seam.
//
// This standalone file (NOT a Dart `part`) carries the abstract gateway
// seam, result type, typed validation error, and route handler for
// POST /v1/admin/age/rebuild. The monolith (`advisor_proxy.dart`)
// imports the symbols below and threads an OPTIONAL
// `AgeRebuildGateway? ageRebuildGateway` parameter through
// `routeRequest`. When that parameter is null the monolith keeps
// returning the historical 501 `not_implemented` response so existing
// tests stay byte-compatible; when a gateway is injected, the monolith
// delegates to [handleAgeRebuild] which runs the real projection.
//
// Pattern source: the `GraphCandidatesProxyGateway` seam in
// `advisor_proxy.dart` + `proxy_bootstrap.dart`. The route shape mirrors
// `_routeGraphCandidates`: one method per route, returning JSON-ready
// maps so the route handler can wrap them in a 200 response without
// translating shapes a second time.
//
// Hard rules carried from the slice prompt and CLAUDE.md:
//
//   1. HP#4 per-operator isolation (non-negotiable). The rebuild reads
//      and projects strictly for the operator named in the VERIFIED
//      JWT. [handleAgeRebuild] receives `operatorId` / `locationId`
//      from the resolved claims, NEVER from the request body. The
//      production gateway stamps `operator_id` on every projected AGE
//      vertex/edge and scopes its convergence delete by `operator_id`
//      so traversal cannot cross a tenant boundary.
//
//   2. Idempotency / convergence. The route requires an Idempotency-Key
//      (the monolith rejects a missing key with 400 before this handler
//      runs). Re-running the rebuild MUST converge, not duplicate: the
//      production gateway deletes the operator's existing AGE subgraph
//      and re-projects the approved canonical rows (delete-and-reproject
//      MERGE), so a second run with identical canonical data yields the
//      same queryable subgraph.
//
//   3. No AI cost (HP#9). AGE projection is a pure Postgres-to-AGE
//      projection -- it makes no provider/LLM/embedding call, so there
//      is no meterable AI cost and no usage-class metering is required.
//
//   4. No secrets (HP#7). The projection needs no provider key. Any DB
//      credential comes from existing proxy config, never the body, and
//      nothing here logs or returns a credential.
//
//   5. Answer-generation (G5b) is out of scope. This file projects the
//      approved subgraph so it is QUERYABLE; the advisor READING the
//      graph is the separate G5b slice. Nothing here touches the answer
//      engine.

/// Result of a successful AGE rebuild. Carries the per-class projection
/// counts the route returns in its 200 JSON body.
class AgeRebuildResult {
  const AgeRebuildResult({
    required this.nodesProjected,
    required this.edgesProjected,
    required this.nodesDeleted,
    required this.ageAvailable,
    this.graphName = 'forgeflow',
  });

  /// Approved canonical nodes MERGEd into the AGE graph this run.
  final int nodesProjected;

  /// Approved canonical edges MERGEd into the AGE graph this run.
  final int edgesProjected;

  /// Pre-existing AGE vertices removed by the convergence DETACH DELETE
  /// before re-projection. A no-change re-run reports `nodesDeleted`
  /// equal to the prior `nodesProjected`, which is the idempotency
  /// signal: the graph converged rather than accumulated duplicates.
  final int nodesDeleted;

  /// False when the Postgres instance does not have the Apache AGE
  /// extension available. In that case the projection is a no-op and
  /// the route surfaces `age_available: false` so the operator knows
  /// vector-only retrieval remains the launch fallback (mirrors the
  /// AGE_BLOCKER posture of `tool/graph_projection`).
  final bool ageAvailable;

  /// The AGE label-graph name the rows were projected into. The live
  /// graph the health probe and the G5b advisor read both query is
  /// `forgeflow` (see `health_registry_part.dart`).
  final String graphName;

  /// JSON body returned inside the route's 200 response.
  Map<String, Object?> toJson() => <String, Object?>{
        'graph_name': graphName,
        'nodes_projected': nodesProjected,
        'edges_projected': edgesProjected,
        'nodes_deleted': nodesDeleted,
        'age_available': ageAvailable,
        // The projection is a DB-only operation; no provider call runs,
        // so there is nothing to meter. Surfaced explicitly so the
        // operator-facing screen can state "no AI cost" without guessing.
        'ai_cost_metered': false,
      };
}

/// Validation error raised by [AgeRebuildGateway] implementations when a
/// request is rejected for business reasons (e.g. the verified JWT
/// carries no operator scope, or the AGE projection dependency is not
/// configured). The route handler maps it back to a structured 4xx /
/// 5xx response carrying the `code` and `message`.
class AgeRebuildGatewayValidationError implements Exception {
  const AgeRebuildGatewayValidationError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'AgeRebuildGatewayValidationError($statusCode/$code): $message';
}

/// Gateway the proxy delegates to for POST /v1/admin/age/rebuild.
///
/// Mirrors the `GraphCandidatesProxyGateway` shape: a single async
/// method that takes the resolved actor / operator scope plus the
/// Idempotency-Key and returns an [AgeRebuildResult]. The production
/// implementation (`RepositoryAgeRebuildGateway` in
/// `proxy_bootstrap.dart`) reads the approved canonical graph for the
/// operator and re-projects it into the `forgeflow` AGE label graph.
abstract class AgeRebuildGateway {
  /// Rebuilds (delete-and-reproject) the AGE projection for [operatorId].
  ///
  /// [operatorId] / [locationId] / [actorUserId] come from the VERIFIED
  /// JWT, never the request body (HP#4). [idempotencyKey] is guaranteed
  /// non-empty (the route rejects a missing key with 400 before this is
  /// called). Re-running with the same inputs converges.
  Future<AgeRebuildResult> rebuild({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required String adminReason,
  });
}

/// Outcome of [handleAgeRebuild]: the HTTP status code plus the JSON
/// body the monolith writes to the response. Keeping the shape as a
/// value object lets the monolith own the actual `_writeJson` call (and
/// its response-encoding conventions) while this file owns the routing
/// and gateway-delegation logic.
class AgeRebuildRouteResult {
  const AgeRebuildRouteResult({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, Object?> body;
}

/// Default admin reason stamped on the rebuild's audit attribution when
/// the caller does not supply one. Matches the `admin.*` convention used
/// across the proxy's system-operation paths.
const String kAgeRebuildDefaultAdminReason = 'admin.age.rebuild';

/// Handles a POST /v1/admin/age/rebuild request once the monolith has
/// already (1) verified the JWT, (2) enforced the super_admin role gate
/// (`kFfCorpusAdminWriteRoles`), and (3) confirmed a non-empty
/// Idempotency-Key. This handler enforces HP#4 (operator scope must come
/// from the verified claims, not the body) and delegates the projection
/// to [gateway].
///
/// [operatorId] / [locationId] are the VERIFIED-claims scope. A caller
/// whose token carries no operator scope (e.g. an F&F super_admin token
/// minted without a selected operator) is rejected with a typed 400
/// `operator_scope_required` rather than silently projecting nothing or
/// reading scope from the body.
///
/// The handler maps [AgeRebuildGatewayValidationError] to its carried
/// status code; any other gateway throw propagates to the monolith's
/// surrounding try/catch which renders a 503.
Future<AgeRebuildRouteResult> handleAgeRebuild({
  required AgeRebuildGateway gateway,
  required String actorUserId,
  required String? operatorId,
  required String? locationId,
  required String idempotencyKey,
}) async {
  // HP#4: scope is taken ONLY from the verified JWT. If the token is not
  // operator-scoped we refuse rather than read scope from the body.
  final scopedOperatorId = operatorId?.trim();
  final scopedLocationId = locationId?.trim();
  if (scopedOperatorId == null || scopedOperatorId.isEmpty) {
    return const AgeRebuildRouteResult(
      statusCode: 400,
      body: <String, Object?>{
        'error': 'operator_scope_required',
        'message':
            'AGE rebuild requires an operator-scoped token. The verified '
            'claims carry no operator_id, and per-operator isolation '
            'forbids taking scope from the request body. Select an '
            'operator before rebuilding.',
      },
    );
  }
  if (scopedLocationId == null || scopedLocationId.isEmpty) {
    return const AgeRebuildRouteResult(
      statusCode: 400,
      body: <String, Object?>{
        'error': 'location_scope_required',
        'message':
            'AGE rebuild requires a location-scoped token. The verified '
            'claims carry no location_id.',
      },
    );
  }

  try {
    final result = await gateway.rebuild(
      actorUserId: actorUserId,
      operatorId: scopedOperatorId,
      locationId: scopedLocationId,
      idempotencyKey: idempotencyKey,
      adminReason: kAgeRebuildDefaultAdminReason,
    );
    return AgeRebuildRouteResult(statusCode: 200, body: result.toJson());
  } on AgeRebuildGatewayValidationError catch (error) {
    return AgeRebuildRouteResult(
      statusCode: error.statusCode,
      body: <String, Object?>{
        'error': error.code,
        'message': error.message,
      },
    );
  }
}
