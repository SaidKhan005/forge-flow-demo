// Phase 8 / Wave W2.D — operator-scoped read of `connector_backfill_jobs`.
//
// Operator-web Vendor Connections needs per-connection backfill progress
// after `8.first-connect-backfill-wire-in` shipped the table + worker +
// post-commit projector. This file owns the read-only proxy routes that
// expose that truth to the operator-web shell.
//
// Routes:
//
//   GET /v1/operator/connector-backfill-jobs
//        Returns the latest backfill job per connection for the caller's
//        (operator_id, location_id) scope. The proxy resolves both ids
//        from the verified bearer token; the URL has no scope params.
//
//   GET /v1/operator/connector-backfill-jobs?connection_id=<uuid>
//        Returns the latest backfill job for a single connection. Same
//        response shape; the `jobs` list contains 0 or 1 entries.
//
// Auth + scope:
//   * Bearer token resolves to OperatorContext (operatorId + locationId).
//   * Per-tenant RLS enforced via `SET LOCAL` inside the gateway.
//   * Reads are open to any role with operator-web access; the shared
//     `VendorConnectionsScreen` already gates configure-write access via
//     `integrations.configure`. Read-only progress is admitted for
//     `operator_owner` and `location_manager` so a manager session lands
//     on the read-only forbidden surface for the screen as a whole, not
//     a 403 from this route.
//
// Idempotency:
//   * Read-only — no Idempotency-Key header required.
//
// CLAUDE.md compliance:
//   * Operator-scoped: every route resolves operatorId + locationId from
//     the JWT, never from the URL or body.
//   * Postgres time guardrail: timestamps round-trip in ISO-8601 UTC.

import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';

const String operatorConnectorBackfillJobsPath =
    '/v1/operator/connector-backfill-jobs';

/// Roles permitted to read backfill progress on the operator-web shell.
/// Mirrors the admit set on the Vendor Connections screen so a
/// `location_manager` session sees the same read surface (the screen
/// itself renders the friendly forbidden body for the configure path).
const Set<String> kOperatorConnectorBackfillJobsReadRoles = <String>{
  'operator_owner',
  'location_manager',
};

/// Narrow gateway seam the route reads against. Production binds this
/// to a [ConnectorBackfillJobRepository]-backed implementation; tests
/// inject a recording stub.
abstract class ConnectorBackfillJobsReadGateway {
  /// Lists the latest backfill job per connection for
  /// (operatorId, locationId). When [connectionId] is non-null, the
  /// result is at most one row for that connection.
  Future<List<FirstConnectionBackfillJob>> listLatestPerConnection({
    required String operatorId,
    required String locationId,
    String? connectionId,
    String? actorUserId,
  });
}

/// Result envelope returned by [ConnectorBackfillJobsRouter.handle].
class ConnectorBackfillJobsRouteResult {
  const ConnectorBackfillJobsRouteResult({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

/// Self-contained router for the read surface. Mounted by
/// `routeRequest` next to the other operator GET routes.
class ConnectorBackfillJobsRouter {
  ConnectorBackfillJobsRouter({
    required ConnectorBackfillJobsReadGateway gateway,
  }) : _gateway = gateway;

  final ConnectorBackfillJobsReadGateway _gateway;

  /// True iff [path] / [method] match the read route. Method-and-path
  /// only; the dispatcher resolves auth + scope before invoking
  /// [handle].
  static bool matches(String path, String method) {
    return method == 'GET' && path == operatorConnectorBackfillJobsPath;
  }

  /// Handles one read request after the dispatcher has resolved auth.
  Future<ConnectorBackfillJobsRouteResult> handle({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required Map<String, String> queryParameters,
  }) async {
    final raw = queryParameters['connection_id'];
    String? connectionId;
    if (raw != null) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return const ConnectorBackfillJobsRouteResult(
          statusCode: 400,
          body: <String, Object?>{
            'error': 'invalid_connection_id',
            'message':
                'connection_id query parameter must be a non-blank uuid string',
          },
        );
      }
      connectionId = trimmed;
    }

    final jobs = await _gateway.listLatestPerConnection(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      actorUserId: actorUserId,
    );
    return ConnectorBackfillJobsRouteResult(
      statusCode: 200,
      body: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'jobs': <Map<String, Object?>>[
          for (final job in jobs) connectorBackfillJobToJson(job),
        ],
      },
    );
  }
}

/// Stable JSON projection for one backfill job. Mirrors the
/// `_firstBackfillStatusJson` projection on the mobile sync gateway so
/// both surfaces read off the same shape.
Map<String, Object?> connectorBackfillJobToJson(
  FirstConnectionBackfillJob job,
) {
  return <String, Object?>{
    'job_id': job.jobId,
    'operator_id': job.operatorId,
    'location_id': job.locationId,
    'connection_id': job.connectionId,
    'vendor_id': job.vendorId,
    'category': job.category.backfillWire,
    'status': job.status.wire,
    'window_start': job.windowStart.toUtc().toIso8601String(),
    'window_end': job.windowEnd.toUtc().toIso8601String(),
    'cursor_token': job.cursorToken,
    'last_modified_seen': job.lastModifiedSeen?.toUtc().toIso8601String(),
    'attempt_count': job.attemptCount,
    'worker_id': job.workerId,
    'claimed_at': job.claimedAt?.toUtc().toIso8601String(),
    'completed_at': job.completedAt?.toUtc().toIso8601String(),
    'last_error': job.lastError,
    'created_at': job.createdAt.toUtc().toIso8601String(),
    'updated_at': job.updatedAt.toUtc().toIso8601String(),
  };
}
