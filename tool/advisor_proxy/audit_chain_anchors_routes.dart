// Operator Web W4.B - Per-tenant audit-chain-anchor read route.
//
// Read-only proxy surface that returns the operator's most-recent
// `public.audit_chain_anchors` row plus the M3 breadcrumb columns
// (`last_anchor_blob_url`, `last_anchor_blob_at`). The Operator Web
// Audit Log screen consumes this so an operator can see whether the
// daily 02:00 UTC audit-chain anchor is healthy, delayed, failed, or
// unknown for their tenant. The F&F Ops Console (HealthAdminScreen)
// already exposes anchor health globally via the `/health` envelope;
// this route is the operator-scoped equivalent.
//
// Route shape:
//
//   GET /v1/operator/audit-chain-anchors/latest
//
// Auth:
//   * Bearer token resolves to OperatorContext (operatorId required).
//   * No additional role gate — every operator user that already has
//     console.web access (the screen is gated on
//     `team.audit_log.view`) may read their own anchor health, the
//     same way the Audit Log screen itself reads `auth_events_audit`.
//
// Per-tenant isolation:
//   * The gateway implementation runs the SELECT through the
//     tenant-pool transaction wrapper, which issues `SET LOCAL
//     app.operator_id` so the existing
//     `audit_chain_anchors_per_tenant_select` RLS policy clamps the
//     query to the caller's operator. The operator_id from the JWT is
//     the source of truth; no client-supplied operator_id is read.
//
// Response shape (200, body):
//
//   {
//     "operator_id": "<uuid>",
//     "anchor": null  // or
//     {
//       "chain_date": "2026-05-06",
//       "anchored_at": "2026-05-06T02:00:14Z",
//       "row_count": 1234,
//       "blob_uri": "https://...",
//       "last_anchor_blob_url": "https://...",  // may be null
//       "last_anchor_blob_at": "2026-05-06T02:00:12Z",  // may be null
//       "status": "healthy"  // healthy | delayed | failed | unknown
//     }
//   }
//
// Status derivation (server-side classification, mirrors the badge
// states the screen renders):
//   * `unknown`  - no anchor row exists yet for the operator.
//   * `failed`   - a row exists, but `blob_uri` is empty / null OR the
//                  M3 breadcrumb columns indicate a half-written sweep
//                  (`last_anchor_blob_at` is null AND the most recent
//                  row is older than 48 hours).
//   * `delayed`  - the most recent anchor is older than 26 hours
//                  (the daily 02:00 UTC cadence + a 2-hour grace).
//   * `healthy`  - within the daily-cadence window.
//
// CLAUDE.md compliance:
//   * No em-dashes (U+2014) in any literal returned to the client.
//   * Operator-scoped: operatorId resolved from the JWT, never from
//     the URL or body.
//   * Read-only: GET with no body, no idempotency key required.
//
// Test seam: the route delegates to [AuditChainAnchorsGateway] so the
// proxy test can pass a fake; production binds a Postgres
// implementation that issues the SET LOCAL chain through the tenant
// transaction wrapper (see `proxy_bootstrap.dart`).

import 'dart:async';

/// Path the operator-web build hits.
const String operatorAuditChainAnchorsLatestPath =
    '/v1/operator/audit-chain-anchors/latest';

/// Prefix the admin cross-tenant anchor route lives under. Format:
/// `/v1/admin/operators/<operatorId>/audit-chain-anchors/latest`.
const String adminAuditChainAnchorsPathPrefix = '/v1/admin/operators/';

/// Suffix on the admin path: everything after the operatorId segment.
const String _kAdminAnchorsSegment = 'audit-chain-anchors';
const String _kAdminAnchorsLatestSegment = 'latest';

/// Roles permitted to read another tenant's audit-chain-anchor health.
/// Mirrors `kAdminBusinessTimingRoles` so the admin cross-tenant read
/// gate is identical to the existing admin business-timing surface.
const Set<String> kAdminAuditChainAnchorRoles = <String>{
  'super_admin',
  'ff_support',
};

/// Parsed `operatorId` for the admin anchor route, or null when [path]
/// is not that route. The operatorId comes from the URL path segment
/// (the established admin cross-tenant convention), never the JWT.
String? adminAuditChainAnchorsOperatorIdOf(String path) {
  if (!path.startsWith(adminAuditChainAnchorsPathPrefix)) return null;
  final tail = path.substring(adminAuditChainAnchorsPathPrefix.length);
  final parts = tail.split('/');
  // <operatorId>/audit-chain-anchors/latest
  if (parts.length != 3) return null;
  if (parts[1] != _kAdminAnchorsSegment) return null;
  if (parts[2] != _kAdminAnchorsLatestSegment) return null;
  final operatorId = Uri.decodeComponent(parts[0]);
  if (operatorId.trim().isEmpty) return null;
  return operatorId;
}

/// True when [path] + [method] is the admin anchor route. GET only.
bool isAdminAuditChainAnchorsPath(String path) =>
    adminAuditChainAnchorsOperatorIdOf(path) != null;

/// Status the screen renders. Server-side classification keeps the
/// rule set in one place so the badge cannot drift from the route.
enum AuditChainAnchorStatus { healthy, delayed, failed, unknown }

String auditChainAnchorStatusWire(AuditChainAnchorStatus status) {
  switch (status) {
    case AuditChainAnchorStatus.healthy:
      return 'healthy';
    case AuditChainAnchorStatus.delayed:
      return 'delayed';
    case AuditChainAnchorStatus.failed:
      return 'failed';
    case AuditChainAnchorStatus.unknown:
      return 'unknown';
  }
}

/// One row from `public.audit_chain_anchors` projected for the screen.
class AuditChainAnchorRow {
  const AuditChainAnchorRow({
    required this.chainDate,
    required this.anchoredAt,
    required this.rowCount,
    required this.blobUri,
    this.lastAnchorBlobUrl,
    this.lastAnchorBlobAt,
  });

  /// Local calendar date the chain covers (UTC-derived).
  final DateTime chainDate;

  /// `anchored_at` timestamp (UTC).
  final DateTime anchoredAt;

  /// `row_count` at anchor time.
  final int rowCount;

  /// Immutable Azure Blob URI the anchor evidence lives at.
  final String blobUri;

  /// M3 breadcrumb: most-recent Blob URL the L9 sweep stamped before
  /// inserting this anchor row. Null on rows written before lane L9
  /// shipped.
  final String? lastAnchorBlobUrl;

  /// M3 breadcrumb: when the Blob URL was last persisted. Paired with
  /// [lastAnchorBlobUrl] for crash-recovery roll-forward.
  final DateTime? lastAnchorBlobAt;
}

/// Read seam the route depends on. Production wires a Postgres-backed
/// implementation that runs the query through the tenant transaction
/// wrapper so the per-tenant RLS policy clamps the result. Tests pass
/// a fake.
abstract class AuditChainAnchorsGateway {
  /// Returns the most-recent anchor for the caller's tenant, or null
  /// when none has been recorded yet. Implementations MUST scope the
  /// read to the operator (RLS plus `SET LOCAL app.operator_id` in
  /// the tenant transaction wrapper). Both [operatorId] and
  /// [locationId] are threaded so the wrapper can issue both
  /// `SET LOCAL` payloads required by the tenant-pool transaction.
  Future<AuditChainAnchorRow?> latestForOperator({
    required String operatorId,
    required String locationId,
    String? userId,
  });
}

/// Result of routing a single GET. The proxy serializes the body and
/// returns [statusCode] verbatim.
class AuditChainAnchorsRouteResult {
  const AuditChainAnchorsRouteResult({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

/// Match shape returned by [AuditChainAnchorsRouter.match]. Extra
/// shape carriers can be added later without changing the dispatch
/// site.
class AuditChainAnchorsRouteMatch {
  const AuditChainAnchorsRouteMatch();
}

/// Read-only operator-scoped router for `audit_chain_anchors`. Mirrors
/// the dispatcher pattern used by [BusinessScopeRouter] in
/// `business_scope_routes.dart`.
class AuditChainAnchorsRouter {
  AuditChainAnchorsRouter({
    required AuditChainAnchorsGateway gateway,
    DateTime Function()? now,
  })  : _gateway = gateway,
        _now = now ?? DateTime.now;

  final AuditChainAnchorsGateway _gateway;
  final DateTime Function() _now;

  /// True when the route + method matches. The dispatcher uses this
  /// to short-circuit the catch-all 404.
  static AuditChainAnchorsRouteMatch? match(String path, String method) {
    if (method != 'GET') return null;
    if (path != operatorAuditChainAnchorsLatestPath) return null;
    return const AuditChainAnchorsRouteMatch();
  }

  /// Handles one matched request. The caller resolves the operator
  /// context from the JWT and threads the operator/location/user ids
  /// in so the route stays free of any auth-guard plumbing.
  Future<AuditChainAnchorsRouteResult> handle({
    required String operatorId,
    required String locationId,
    String? userId,
  }) async {
    final row = await _gateway.latestForOperator(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    if (row == null) {
      return AuditChainAnchorsRouteResult(
        statusCode: 200,
        body: <String, Object?>{
          'operator_id': operatorId,
          'anchor': null,
        },
      );
    }
    final status = classifyAnchorStatus(row, now: _now());
    return AuditChainAnchorsRouteResult(
      statusCode: 200,
      body: <String, Object?>{
        'operator_id': operatorId,
        'anchor': <String, Object?>{
          'chain_date': _formatDate(row.chainDate.toUtc()),
          'anchored_at': row.anchoredAt.toUtc().toIso8601String(),
          'row_count': row.rowCount,
          'blob_uri': row.blobUri,
          'last_anchor_blob_url': row.lastAnchorBlobUrl,
          'last_anchor_blob_at':
              row.lastAnchorBlobAt?.toUtc().toIso8601String(),
          'status': auditChainAnchorStatusWire(status),
        },
      },
    );
  }
}

/// Admin/cross-tenant analogue of [AuditChainAnchorsGateway]. The admin
/// console reads ANOTHER tenant's most-recent anchor row, so the
/// implementation MUST run through the sanctioned system-scope bypass
/// (`runAsSystem` on the admin pool) rather than the per-tenant RLS
/// clamp the operator gateway uses — exactly like the admin
/// business-timing resolution gateway's `resolveForLocationAsSystem`.
/// The dispatcher gates this to super_admin / ff_support before any
/// implementation runs. Tests pass a fake.
abstract class AdminAuditChainAnchorsGateway {
  /// Returns the most-recent anchor for [operatorId] (taken from the
  /// URL, not a JWT), or null when none has been recorded yet.
  /// [reason] is the audit-attribution string stamped on the
  /// system-scope transaction (the `app.bypass_rls_audit` marker).
  Future<AuditChainAnchorRow?> latestForOperatorAsSystem({
    required String operatorId,
    required String reason,
  });
}

/// Read-only ADMIN cross-tenant router for `audit_chain_anchors`.
/// Mirrors [AdminBusinessTimingRouter.handleResolution] in
/// `admin_business_timing_routes.dart`: the operatorId comes from the
/// URL (the established admin cross-tenant convention); the dispatcher
/// has already verified the actor holds a super_admin / ff_support
/// role before [handle] runs; the read flows through the sanctioned
/// `runAsSystem` admin bypass. Returns the SAME
/// `{operator_id, anchor: null | {...}}` body shape and the SAME
/// shared [classifyAnchorStatus] classifier as the operator route, so
/// the admin badge cannot drift from the operator-web badge.
class AdminAuditChainAnchorsRouter {
  AdminAuditChainAnchorsRouter({
    required AdminAuditChainAnchorsGateway gateway,
    DateTime Function()? now,
  })  : _gateway = gateway,
        _now = now ?? DateTime.now;

  final AdminAuditChainAnchorsGateway _gateway;
  final DateTime Function() _now;

  /// Audit-attribution string stamped on every system-scope read.
  static const String auditReason = 'admin.audit_chain_anchors.latest_read';

  /// True when the route + method matches (GET on the admin path).
  static bool matches(String path, String method) {
    if (method != 'GET') return false;
    return isAdminAuditChainAnchorsPath(path);
  }

  /// Handles one matched request. [operatorId] is parsed from the URL
  /// by the dispatcher and threaded in; this router never reads a JWT.
  Future<AuditChainAnchorsRouteResult> handle({
    required String operatorId,
  }) async {
    final row = await _gateway.latestForOperatorAsSystem(
      operatorId: operatorId,
      reason: auditReason,
    );
    if (row == null) {
      return AuditChainAnchorsRouteResult(
        statusCode: 200,
        body: <String, Object?>{
          'operator_id': operatorId,
          'anchor': null,
        },
      );
    }
    final status = classifyAnchorStatus(row, now: _now());
    return AuditChainAnchorsRouteResult(
      statusCode: 200,
      body: <String, Object?>{
        'operator_id': operatorId,
        'anchor': <String, Object?>{
          'chain_date': _formatDate(row.chainDate.toUtc()),
          'anchored_at': row.anchoredAt.toUtc().toIso8601String(),
          'row_count': row.rowCount,
          'blob_uri': row.blobUri,
          'last_anchor_blob_url': row.lastAnchorBlobUrl,
          'last_anchor_blob_at':
              row.lastAnchorBlobAt?.toUtc().toIso8601String(),
          'status': auditChainAnchorStatusWire(status),
        },
      },
    );
  }
}

/// Window that still counts as healthy: the cron tick fires daily at
/// 02:00 UTC, so any anchor newer than 26 hours is on cadence.
const Duration _kHealthyWindow = Duration(hours: 26);

/// Beyond 48 hours without a fresh row we treat the chain as failed
/// (two consecutive missed daily ticks).
const Duration _kFailedWindow = Duration(hours: 48);

/// Server-side classifier shared between the route and unit tests so
/// the screen always renders the same status the proxy computed.
AuditChainAnchorStatus classifyAnchorStatus(
  AuditChainAnchorRow row, {
  required DateTime now,
}) {
  final blobUri = row.blobUri.trim();
  final age = now.toUtc().difference(row.anchoredAt.toUtc());
  // Failed: blob_uri is empty (sweep never wrote evidence) OR the M3
  // breadcrumb shows a half-written sweep (no blob_at) AND we are well
  // past the daily cadence — the verifier needs operator attention.
  if (blobUri.isEmpty) {
    return AuditChainAnchorStatus.failed;
  }
  if (age >= _kFailedWindow && row.lastAnchorBlobAt == null) {
    return AuditChainAnchorStatus.failed;
  }
  if (age >= _kHealthyWindow) {
    return AuditChainAnchorStatus.delayed;
  }
  return AuditChainAnchorStatus.healthy;
}

String _formatDate(DateTime utc) {
  final y = utc.year.toString().padLeft(4, '0');
  final m = utc.month.toString().padLeft(2, '0');
  final d = utc.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
