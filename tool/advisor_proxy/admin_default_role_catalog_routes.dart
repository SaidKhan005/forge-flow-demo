// Lane B B2.1 — admin Default Role catalog routes.
//
// Implements the two F&F-admin routes documented in the slice spec:
//
//   GET  /v1/admin/auth/role-catalogs           {super_admin, ff_support}
//   POST /v1/admin/auth/role-catalogs/publish   super_admin only
//
// File lives outside `advisor_proxy.dart` per the bleed-stop ceiling
// (`tool/advisor_proxy_size_lint.dart`). The monolith continues to own
// dispatch / auth / claim resolution; this file owns the route's
// business logic.
//
// Hard rules carried from CLAUDE.md:
//
//   * "Proxy & API Conventions" — every write idempotent via
//     `Idempotency-Key` header + `proxy_requests` UNIQUE. The publish
//     route requires the header (rejects 400 when missing).
//   * "RLS-Ready Schema" — the catalog table is NOT operator-scoped;
//     the repository (`DefaultRoleCatalogVersionsRepository`) routes
//     every call through `runAsSystem`. This router is the only public
//     surface for the table.
//   * "Hash-chained audit log" — publish emits an
//     `auth.default_role_catalog.published` row through
//     [DefaultRoleCatalogAuditSink]. The sink resolves
//     `actor_kind = 'forge_admin'` (mirrors the B1.b/B1.c idiom) and
//     fans into the operator's audit chain.
//   * No new permission key — `lib/auth/**` is frozen. Role gate via
//     the per-method role allowlists declared in this file.
//   * No service-principal write path — V1 admins are interactive humans.
//
// Tested by:
//   * test/proxy/b2_1_default_role_catalog_routes_test.dart

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/default_role_catalog_versions_repository.dart';

/// Stable canonical JSON for SHA-256 input. Sorted keys; preserves array
/// order. Mirrors the helper used by other proxy idempotency paths
/// (e.g. `hashAuthHandoffRequest`) so retries hash to the same value
/// regardless of caller-side map insertion order.
String canonicalRoleCatalogJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    final entries = <String>[
      for (final k in keys)
        '${jsonEncode(k)}:${canonicalRoleCatalogJson(value[k])}',
    ];
    return '{${entries.join(',')}}';
  }
  if (value is List) {
    final items = <String>[
      for (final entry in value) canonicalRoleCatalogJson(entry),
    ];
    return '[${items.join(',')}]';
  }
  return jsonEncode(value);
}

/// SHA-256 hex digest of the canonical payload bytes. The repository's
/// `payload_sha256` column stores this exact value; the audit event
/// payload references it for cross-system verification.
String computeRoleCatalogPayloadSha256(List<Object?> payload) {
  final canonical = canonicalRoleCatalogJson(payload);
  return sha256.convert(utf8.encode(canonical)).toString();
}

/// Roles permitted to read the catalog history. Mirrors the B5 posture
/// for read-only admin routes (super_admin + ff_support).
const Set<String> kDefaultRoleCatalogAdminReadRoles = <String>{
  'super_admin',
  'ff_support',
};

/// Roles permitted to publish a new catalog version. super_admin only —
/// publishes affect every operator in the F&F deployment.
const Set<String> kDefaultRoleCatalogAdminWriteRoles = <String>{
  'super_admin',
};

/// Audit-sink seam. Production fans the publish event into the
/// hash-chained `audit_logs` table via `AuditLogsRepository.writeRow`
/// (called inside the publish transaction so the audit row commits
/// atomically with the catalog row). Tests pass a recording fake.
abstract class DefaultRoleCatalogAuditSink {
  /// Records `auth.default_role_catalog.published`. Atomic with the
  /// catalog version INSERT.
  ///
  /// [blastRadiusOperatorCount] is the number of operators pinned to
  /// the prior current version at publish time (the count whose
  /// "Default" copy is about to roll forward). When no prior version
  /// existed (genesis publish) this is 0.
  Future<void> recordPublished({
    required String versionId,
    required int versionNumber,
    required String payloadSha256,
    required String publishedByUserId,
    required int blastRadiusOperatorCount,
    required String? notes,
    required DateTime occurredAt,
  });
}

/// In-memory recording sink for tests. The proxy test injects this and
/// asserts on the captured event shape (action name, actor kind,
/// blast-radius count).
class RecordingDefaultRoleCatalogAuditSink
    implements DefaultRoleCatalogAuditSink {
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];

  @override
  Future<void> recordPublished({
    required String versionId,
    required int versionNumber,
    required String payloadSha256,
    required String publishedByUserId,
    required int blastRadiusOperatorCount,
    required String? notes,
    required DateTime occurredAt,
  }) async {
    events.add(<String, Object?>{
      'version_id': versionId,
      'version_number': versionNumber,
      'payload_sha256': payloadSha256,
      'published_by_user_id': publishedByUserId,
      'blast_radius_operator_count': blastRadiusOperatorCount,
      if (notes != null) 'notes': notes,
      'occurred_at': occurredAt.toIso8601String(),
    });
  }
}

/// No-op audit sink — used when the proxy is constructed without an
/// audit wiring (smoke tests, scaffolds). The publish path still
/// succeeds; nothing is recorded.
class NoopDefaultRoleCatalogAuditSink
    implements DefaultRoleCatalogAuditSink {
  const NoopDefaultRoleCatalogAuditSink();

  @override
  Future<void> recordPublished({
    required String versionId,
    required int versionNumber,
    required String payloadSha256,
    required String publishedByUserId,
    required int blastRadiusOperatorCount,
    required String? notes,
    required DateTime occurredAt,
  }) async {
    // intentionally blank
  }
}

/// Catalog admin path constants. The advisor_proxy dispatcher checks
/// `DefaultRoleCatalogAdminRouter.matches(path, method)` before
/// delegating; the constants are exposed for the route table.
const String kAdminDefaultRoleCatalogsPath = '/v1/admin/auth/role-catalogs';
const String kAdminDefaultRoleCatalogPublishPath =
    '/v1/admin/auth/role-catalogs/publish';

/// Carry-shape for [DefaultRoleCatalogAdminRouter.handle] results.
typedef DefaultRoleCatalogRouteResult = ({
  int statusCode,
  Map<String, Object?> body,
});

/// Pluggable Firebase-UID → Postgres-user_id resolver. The dispatcher
/// passes whichever resolver the proxy has wired (production uses the
/// `IntegrationAdminActorResolver` shared with the integrations route);
/// tests pass an in-memory implementation that returns a pinned UUID.
typedef DefaultRoleCatalogActorResolver = Future<String?> Function({
  required String firebaseUid,
  required String adminReason,
});

class DefaultRoleCatalogAdminRouter {
  DefaultRoleCatalogAdminRouter({
    required this.repository,
    required this.auditSink,
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now;

  final DefaultRoleCatalogVersionsRepository repository;
  final DefaultRoleCatalogAuditSink auditSink;
  final DateTime Function() _now;

  /// True when [path] + [method] match a catalog admin route. The
  /// dispatcher uses this to decide whether to consume the request
  /// before falling through to other matchers.
  static bool matches(String path, String method) {
    if (method == 'GET' && path == kAdminDefaultRoleCatalogsPath) return true;
    if (method == 'POST' && path == kAdminDefaultRoleCatalogPublishPath) {
      return true;
    }
    return false;
  }

  /// True when [path] + [method] is a read-only route (admits ff_support
  /// in addition to super_admin).
  static bool isReadOnly(String path, String method) =>
      method == 'GET' && path == kAdminDefaultRoleCatalogsPath;

  /// Full dispatch entrypoint — owns role gate, idempotency-key
  /// validation, actor resolution, and history-limit parsing so the
  /// advisor_proxy dispatcher stays minimal (mirrors AuthHandoffRouter
  /// shape but with the admin-side concerns folded in).
  ///
  /// [actorRoles] is the caller's role set from the verified JWT.
  /// [actorFirebaseUid] is the Firebase UID (or fallback userId) used
  /// to resolve a Postgres user_id for audit attribution on publish.
  /// [actorResolver] resolves Firebase UID → Postgres UUID; null is
  /// allowed only on GET. Required on POST.
  /// [idempotencyKeyHeader] is the trimmed `Idempotency-Key` header
  /// value (null when absent).
  /// [limitQueryParam] is `?limit=N` from the URL (GET only).
  Future<DefaultRoleCatalogRouteResult> dispatch({
    required String method,
    required String path,
    required Set<String> actorRoles,
    required String actorFirebaseUid,
    required DefaultRoleCatalogActorResolver? actorResolver,
    required String? idempotencyKeyHeader,
    required String? limitQueryParam,
    required Map<String, Object?> body,
  }) async {
    if (!matches(path, method)) {
      return (
        statusCode: 404,
        body: const <String, Object?>{
          'error': 'not_found',
          'message': 'default role catalog admin route not found',
        },
      );
    }
    final isRead = isReadOnly(path, method);
    final requiredRoles = isRead
        ? kDefaultRoleCatalogAdminReadRoles
        : kDefaultRoleCatalogAdminWriteRoles;
    if (!actorRoles.any(requiredRoles.contains)) {
      return (
        statusCode: 403,
        body: <String, Object?>{
          'error': 'permission_denied',
          'message': 'admin role claim required',
          'required_roles': requiredRoles.toList(),
        },
      );
    }
    if (!isRead) {
      final key = idempotencyKeyHeader;
      if (key == null || key.isEmpty) {
        return (
          statusCode: 400,
          body: const <String, Object?>{
            'error': 'missing_idempotency_key',
            'message': 'Idempotency-Key header is required',
          },
        );
      }
      if (key.length > 200) {
        return (
          statusCode: 400,
          body: const <String, Object?>{
            'error': 'idempotency_key_too_long',
            'message':
                'Idempotency-Key header must be 200 characters or fewer',
          },
        );
      }
    }
    if (isRead) {
      var historyLimit = 20;
      final raw = limitQueryParam;
      if (raw != null && raw.isNotEmpty) {
        final parsed = int.tryParse(raw);
        if (parsed != null) historyLimit = parsed.clamp(1, 100);
      }
      return _list(historyLimit: historyLimit);
    }
    if (actorResolver == null) {
      return (
        statusCode: 503,
        body: const <String, Object?>{
          'error': 'default_role_catalog_actor_resolver_not_configured',
          'message': 'route requires an admin actor resolver to be installed',
        },
      );
    }
    String? resolvedActorUserId;
    try {
      resolvedActorUserId = await actorResolver(
        firebaseUid: actorFirebaseUid,
        adminReason: 'admin.default_role_catalog.publish:$actorFirebaseUid',
      );
    } catch (_) {
      return (
        statusCode: 503,
        body: const <String, Object?>{
          'error': 'default_role_catalog_actor_resolve_failed',
          'message': 'actor resolution is unavailable; please retry',
        },
      );
    }
    if (resolvedActorUserId == null) {
      return (
        statusCode: 403,
        body: const <String, Object?>{
          'error': 'actor_user_not_resolvable',
          'message':
              'verified Firebase user has no matching Postgres users row '
              '(audit attribution requires a UUID-shaped actor)',
        },
      );
    }
    return _publish(actorUserId: resolvedActorUserId, body: body);
  }

  Future<DefaultRoleCatalogRouteResult> _list({
    required int historyLimit,
  }) async {
    final current = await repository.getCurrentVersion();
    final history = await repository.listVersions(limit: historyLimit);
    return (
      statusCode: 200,
      body: <String, Object?>{
        if (current != null) 'current': current.toJson(),
        'history': <Map<String, Object?>>[
          for (final row in history) row.toJson(),
        ],
      },
    );
  }

  Future<DefaultRoleCatalogRouteResult> _publish({
    required String actorUserId,
    required Map<String, Object?> body,
  }) async {
    final rawPayload = body['payload'];
    if (rawPayload is! List) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'missing_payload',
          'message':
              'request body must include `payload` as a non-empty array '
              'of role definitions',
        },
      );
    }
    final payload = List<Object?>.from(rawPayload);
    if (payload.isEmpty) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'empty_payload',
          'message':
              'payload must contain at least one role definition; an '
              'empty catalog would leave every operator without seeded '
              'roles',
        },
      );
    }
    final notesRaw = body['notes'];
    String? notes;
    if (notesRaw is String) {
      final trimmed = notesRaw.trim();
      notes = trimmed.isEmpty ? null : trimmed;
    } else if (notesRaw != null) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'invalid_notes',
          'message': 'notes must be a string when provided',
        },
      );
    }

    final payloadSha256 = computeRoleCatalogPayloadSha256(payload);

    // Capture the prior current version BEFORE publish so the blast-
    // radius count is computed against the version the publish is
    // about to supersede (not the new one).
    final priorCurrent = await repository.getCurrentVersion();
    final blastRadius = priorCurrent == null
        ? 0
        : await repository.countOperatorsFollowing(
            versionId: priorCurrent.versionId,
          );

    final DefaultRoleCatalogVersionRow published;
    try {
      published = await repository.publishVersion(
        publishedByUserId: actorUserId,
        payload: payload,
        payloadSha256: payloadSha256,
        notes: notes,
      );
    } on DefaultRoleCatalogPublishValidationError catch (error) {
      return (
        statusCode: 400,
        body: <String, Object?>{
          'error': error.code,
          'message': error.message,
        },
      );
    }

    await auditSink.recordPublished(
      versionId: published.versionId,
      versionNumber: published.versionNumber,
      payloadSha256: published.payloadSha256,
      publishedByUserId: actorUserId,
      blastRadiusOperatorCount: blastRadius,
      notes: notes,
      occurredAt: _now().toUtc(),
    );

    return (statusCode: 201, body: published.toJson());
  }
}
