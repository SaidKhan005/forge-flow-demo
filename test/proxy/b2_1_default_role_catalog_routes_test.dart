// Lane B B2.1 — default role catalog admin route tests.
//
// Pins the contract for the two new routes:
//
//   GET  /v1/admin/auth/role-catalogs           {super_admin, ff_support}
//   POST /v1/admin/auth/role-catalogs/publish   super_admin only
//
// Tests drive the [DefaultRoleCatalogAdminRouter.dispatch] entrypoint
// directly so the route's gating logic (role, idempotency, actor
// resolution) is exercised in isolation from the proxy's HTTP shell.
//
// Authority:
//   * tool/advisor_proxy/admin_default_role_catalog_routes.dart
//   * docs/_execution/lane_b_features/03_execution_slices.md
//     ("B2.1 — Default Role catalog schema + publish endpoint")

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/default_role_catalog_versions_repository.dart';

import '../../tool/advisor_proxy/admin_default_role_catalog_routes.dart';
import '../../tool/advisor_proxy/proxy_idempotency_cache.dart';

const String _kAdminPostgresUserId = '11111111-1111-1111-1111-111111111111';
const String _kSupportPostgresUserId = '22222222-2222-2222-2222-222222222222';
const String _kFirebaseUid = 'firebase-uid-abc';

final List<Object?> _kPayload = <Object?>[
  <String, Object?>{'role_key': 'manager', 'display_name': 'Manager'},
  <String, Object?>{'role_key': 'staff', 'display_name': 'Staff'},
];

void main() {
  group('canonicalRoleCatalogJson + computeRoleCatalogPayloadSha256', () {
    test('canonical JSON is stable under map-key reordering', () {
      final a = <String, Object?>{'b': 1, 'a': 2};
      final b = <String, Object?>{'a': 2, 'b': 1};
      expect(canonicalRoleCatalogJson(a), equals(canonicalRoleCatalogJson(b)));
    });

    test('canonical JSON preserves list order', () {
      final a = <Object?>[1, 2, 3];
      final b = <Object?>[3, 2, 1];
      expect(
        canonicalRoleCatalogJson(a),
        isNot(equals(canonicalRoleCatalogJson(b))),
      );
    });

    test('SHA-256 hex is 64 lowercase hex chars', () {
      final hash = computeRoleCatalogPayloadSha256(_kPayload);
      expect(hash, hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hash), isTrue);
    });

    test('SHA-256 hex matches dart:crypto over the canonical JSON', () {
      final canonical = canonicalRoleCatalogJson(_kPayload);
      final expected = sha256.convert(utf8.encode(canonical)).toString();
      expect(computeRoleCatalogPayloadSha256(_kPayload), equals(expected));
    });
  });

  group('DefaultRoleCatalogAdminRouter.matches', () {
    test('matches GET /v1/admin/auth/role-catalogs', () {
      expect(
        DefaultRoleCatalogAdminRouter.matches(
          '/v1/admin/auth/role-catalogs',
          'GET',
        ),
        isTrue,
      );
    });

    test('matches POST /v1/admin/auth/role-catalogs/publish', () {
      expect(
        DefaultRoleCatalogAdminRouter.matches(
          '/v1/admin/auth/role-catalogs/publish',
          'POST',
        ),
        isTrue,
      );
    });

    test('rejects POST on the list path (publish lives at /publish)', () {
      expect(
        DefaultRoleCatalogAdminRouter.matches(
          '/v1/admin/auth/role-catalogs',
          'POST',
        ),
        isFalse,
      );
    });

    test('rejects unrelated admin paths', () {
      expect(
        DefaultRoleCatalogAdminRouter.matches('/v1/admin/auth/roles', 'POST'),
        isFalse,
      );
    });
  });

  group('DefaultRoleCatalogAdminRouter.dispatch (GET)', () {
    test('super_admin can list catalogs (200)', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
      expect(result.body, contains('history'));
    });

    test('ff_support can list catalogs (200)', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs',
        actorRoles: const <String>{'ff_support'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
    });

    test('operator-tier role is rejected with 403 + required_roles', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs',
        actorRoles: const <String>{'operator_owner'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(403));
      expect(result.body['error'], equals('permission_denied'));
      expect(
        result.body['required_roles'],
        containsAll(<String>['super_admin', 'ff_support']),
      );
    });

    test('returns current + history with limit clamped to 1..100', () async {
      final repo = _FakeCatalogRepository(
        currentRow: _buildRow(versionNumber: 2, isCurrent: true),
        history: <DefaultRoleCatalogVersionRow>[
          _buildRow(versionNumber: 2, isCurrent: true),
          _buildRow(versionNumber: 1, isCurrent: false),
        ],
      );
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: const NoopDefaultRoleCatalogAuditSink(),
      );
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: '999', // out-of-bounds clamps to 100
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
      expect(repo.lastListLimit, equals(100));
      expect(result.body['current'], isNotNull);
      expect((result.body['history'] as List).length, equals(2));
    });
  });

  group('DefaultRoleCatalogAdminRouter.dispatch (POST publish)', () {
    test('super_admin can publish (201) and emits audit event', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/admin/auth/role-catalogs/publish',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: 'pub-key-1',
        limitQueryParam: null,
        body: <String, Object?>{
          'payload': _kPayload,
          'notes': 'initial publish',
        },
      );
      expect(result.statusCode, equals(201));
      expect(result.body['version_number'], equals(1));
      expect(result.body['is_current'], isTrue);
      expect(audit.events, hasLength(1));
      final event = audit.events.single;
      expect(event['published_by_user_id'], equals(_kAdminPostgresUserId));
      expect(event['version_number'], equals(1));
      // Genesis publish: no prior current → blast-radius = 0.
      expect(event['blast_radius_operator_count'], equals(0));
      expect(event['notes'], equals('initial publish'));
    });

    test('ff_support cannot publish (403)', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/admin/auth/role-catalogs/publish',
        actorRoles: const <String>{'ff_support'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToSupport,
        idempotencyKeyHeader: 'pub-key-1',
        limitQueryParam: null,
        body: <String, Object?>{'payload': _kPayload},
      );
      expect(result.statusCode, equals(403));
      expect(result.body['error'], equals('permission_denied'));
      expect(repo.publishCount, equals(0));
      expect(audit.events, isEmpty);
    });

    test('missing Idempotency-Key header → 400', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/admin/auth/role-catalogs/publish',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        body: <String, Object?>{'payload': _kPayload},
      );
      expect(result.statusCode, equals(400));
      expect(result.body['error'], equals('missing_idempotency_key'));
      expect(repo.publishCount, equals(0));
      expect(audit.events, isEmpty);
    });

    test(
      'over-length Idempotency-Key → 400 idempotency_key_too_long',
      () async {
        final repo = _FakeCatalogRepository();
        final audit = RecordingDefaultRoleCatalogAuditSink();
        final router = DefaultRoleCatalogAdminRouter(
          repository: repo,
          auditSink: audit,
        );
        final result = await router.dispatch(
          method: 'POST',
          path: '/v1/admin/auth/role-catalogs/publish',
          actorRoles: const <String>{'super_admin'},
          actorFirebaseUid: _kFirebaseUid,
          actorResolver: _resolveToAdmin,
          idempotencyKeyHeader: 'x' * 201,
          limitQueryParam: null,
          body: <String, Object?>{'payload': _kPayload},
        );
        expect(result.statusCode, equals(400));
        expect(result.body['error'], equals('idempotency_key_too_long'));
      },
    );

    test('empty payload → 400 with empty_payload', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/admin/auth/role-catalogs/publish',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: 'pub-key-1',
        limitQueryParam: null,
        body: <String, Object?>{'payload': const <Object?>[]},
      );
      expect(result.statusCode, equals(400));
      expect(result.body['error'], equals('empty_payload'));
    });

    test('missing payload key → 400 with missing_payload', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/admin/auth/role-catalogs/publish',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: 'pub-key-1',
        limitQueryParam: null,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(400));
      expect(result.body['error'], equals('missing_payload'));
    });

    test('non-string notes → 400 with invalid_notes', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/admin/auth/role-catalogs/publish',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: 'pub-key-1',
        limitQueryParam: null,
        body: <String, Object?>{
          'payload': _kPayload,
          'notes': 42, // non-string
        },
      );
      expect(result.statusCode, equals(400));
      expect(result.body['error'], equals('invalid_notes'));
    });

    test('null actor resolver → 503 actor_resolver_not_configured', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/admin/auth/role-catalogs/publish',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: null,
        idempotencyKeyHeader: 'pub-key-1',
        limitQueryParam: null,
        body: <String, Object?>{'payload': _kPayload},
      );
      expect(result.statusCode, equals(503));
      expect(
        result.body['error'],
        equals('default_role_catalog_actor_resolver_not_configured'),
      );
    });

    test('resolver returns null → 403 actor_user_not_resolvable', () async {
      final repo = _FakeCatalogRepository();
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/admin/auth/role-catalogs/publish',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver:
            ({
              required String firebaseUid,
              required String adminReason,
            }) async => null,
        idempotencyKeyHeader: 'pub-key-1',
        limitQueryParam: null,
        body: <String, Object?>{'payload': _kPayload},
      );
      expect(result.statusCode, equals(403));
      expect(result.body['error'], equals('actor_user_not_resolvable'));
    });

    test('blast-radius count uses pre-publish current row', () async {
      final priorVersionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      final repo = _FakeCatalogRepository(
        currentRow: _buildRow(
          versionNumber: 1,
          isCurrent: true,
          versionId: priorVersionId,
        ),
        operatorFollowersByVersion: <String, int>{priorVersionId: 47},
      );
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/admin/auth/role-catalogs/publish',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: 'pub-key-1',
        limitQueryParam: null,
        body: <String, Object?>{'payload': _kPayload},
      );
      expect(result.statusCode, equals(201));
      expect(audit.events.single['blast_radius_operator_count'], equals(47));
    });
  });

  group('DefaultRoleCatalogAdminRouter.dispatch (route mismatch)', () {
    test('unknown path returns 404', () async {
      final router = DefaultRoleCatalogAdminRouter(
        repository: _FakeCatalogRepository(),
        auditSink: const NoopDefaultRoleCatalogAuditSink(),
      );
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/some-other-thing',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(404));
      expect(result.body['error'], equals('not_found'));
    });
  });

  // B-1 — c_12_lane_c_closeout_audit.md: the proxy dispatcher must wrap
  // publish in ProxyAuthIdempotencyCache.runOrReplay so two retries with
  // the same Idempotency-Key coalesce to one repository publish and the
  // replayed 201 returns the SAME version_id (HP #7, Phase 11A.10).
  //
  // The router itself is unaware of replay; the cache wraps `dispatch`.
  // This group replicates the dispatcher's cache wrapping
  // (advisor_proxy.dart ~11384-11422) so the regression is pinned at the
  // composition level without dragging in the full HTTP shell.
  group('Default Role Catalog publish idempotency replay (B-1)', () {
    Future<({int statusCode, Map<String, Object?> body})> dispatchWithCache({
      required DefaultRoleCatalogAdminRouter router,
      required ProxyAuthIdempotencyCache cache,
      required String idempotencyKeyHeader,
      required Map<String, Object?> body,
    }) async {
      const String path = '/v1/admin/auth/role-catalogs/publish';
      final cached = await cache.runOrReplay(
        route: path,
        key: idempotencyKeyHeader,
        compute: () async {
          final r = await router.dispatch(
            method: 'POST',
            path: path,
            actorRoles: const <String>{'super_admin'},
            actorFirebaseUid: _kFirebaseUid,
            actorResolver: _resolveToAdmin,
            idempotencyKeyHeader: idempotencyKeyHeader,
            limitQueryParam: null,
            body: body,
          );
          return CachedProxyResponse(statusCode: r.statusCode, body: r.body);
        },
      );
      return (statusCode: cached.statusCode, body: cached.body);
    }

    test(
      'two POSTs with same Idempotency-Key → one publish, same version_id',
      () async {
        final repo = _FakeCatalogRepository();
        final audit = RecordingDefaultRoleCatalogAuditSink();
        final cache = ProxyAuthIdempotencyCache();
        final router = DefaultRoleCatalogAdminRouter(
          repository: repo,
          auditSink: audit,
        );
        final body = <String, Object?>{
          'payload': _kPayload,
          'notes': 'B-1 replay test',
        };
        final first = await dispatchWithCache(
          router: router,
          cache: cache,
          idempotencyKeyHeader: 'pub-key-replay',
          body: body,
        );
        final second = await dispatchWithCache(
          router: router,
          cache: cache,
          idempotencyKeyHeader: 'pub-key-replay',
          body: body,
        );
        expect(first.statusCode, equals(201));
        expect(second.statusCode, equals(201));
        // Cache replay: the same version_id flows back to the caller, and
        // the repository observes exactly one publish (not two).
        expect(second.body['version_id'], equals(first.body['version_id']));
        expect(repo.publishCount, equals(1));
        // Audit fans only on the first invocation; the replay does not
        // re-emit the auth.default_role_catalog.published event.
        expect(audit.events, hasLength(1));
      },
    );

    test(
      'distinct Idempotency-Keys → cache keys do not collide (publish runs twice)',
      () async {
        final repo = _FakeCatalogRepository();
        final audit = RecordingDefaultRoleCatalogAuditSink();
        final cache = ProxyAuthIdempotencyCache();
        final router = DefaultRoleCatalogAdminRouter(
          repository: repo,
          auditSink: audit,
        );
        final body = <String, Object?>{'payload': _kPayload};
        final first = await dispatchWithCache(
          router: router,
          cache: cache,
          idempotencyKeyHeader: 'pub-key-a',
          body: body,
        );
        final second = await dispatchWithCache(
          router: router,
          cache: cache,
          idempotencyKeyHeader: 'pub-key-b',
          body: body,
        );
        expect(first.statusCode, equals(201));
        expect(second.statusCode, equals(201));
        // The cache MUST NOT coalesce distinct keys. The fake repository
        // reports two publish calls and the audit sink records two
        // events; version_id collisions in the fake's emitted rows are
        // an artifact of the in-memory builder (it does not append to
        // its own history list), not a cache hit.
        expect(repo.publishCount, equals(2));
        expect(audit.events, hasLength(2));
      },
    );
  });
}

DefaultRoleCatalogVersionRow _buildRow({
  required int versionNumber,
  required bool isCurrent,
  String? versionId,
  String publishedByUserId = _kAdminPostgresUserId,
}) {
  return DefaultRoleCatalogVersionRow(
    versionId: versionId ?? 'version-uuid-$versionNumber',
    versionNumber: versionNumber,
    publishedAt: DateTime.utc(2026, 5, 13, 10),
    publishedByUserId: publishedByUserId,
    payload: _kPayload,
    payloadSha256: 'a' * 64,
    isCurrent: isCurrent,
    supersededAt: isCurrent ? null : DateTime.utc(2026, 5, 13, 11),
    notes: null,
  );
}

Future<String?> _resolveToAdmin({
  required String firebaseUid,
  required String adminReason,
}) async => _kAdminPostgresUserId;

Future<String?> _resolveToSupport({
  required String firebaseUid,
  required String adminReason,
}) async => _kSupportPostgresUserId;

/// In-memory fake of [DefaultRoleCatalogVersionsRepository]. Mirrors the
/// minimal method surface the router exercises: getCurrentVersion,
/// listVersions, publishVersion, countOperatorsFollowing.
class _FakeCatalogRepository implements DefaultRoleCatalogVersionsRepository {
  _FakeCatalogRepository({
    this.currentRow,
    this.history = const <DefaultRoleCatalogVersionRow>[],
    Map<String, int>? operatorFollowersByVersion,
  }) : _operatorFollowersByVersion =
           operatorFollowersByVersion ?? const <String, int>{};

  DefaultRoleCatalogVersionRow? currentRow;
  final List<DefaultRoleCatalogVersionRow> history;
  final Map<String, int> _operatorFollowersByVersion;

  int publishCount = 0;
  int? lastListLimit;

  @override
  Future<DefaultRoleCatalogVersionRow?> getCurrentVersion({
    String reason = 'admin.default_role_catalog.get_current',
  }) async {
    return currentRow;
  }

  @override
  Future<DefaultRoleCatalogVersionRow?> getVersion({
    required String versionId,
    String reason = 'admin.default_role_catalog.get_version',
  }) async {
    for (final row in history) {
      if (row.versionId == versionId) return row;
    }
    return null;
  }

  @override
  Future<List<DefaultRoleCatalogVersionRow>> listVersions({
    int limit = 20,
    String reason = 'admin.default_role_catalog.list',
  }) async {
    lastListLimit = limit;
    return history.take(limit).toList(growable: false);
  }

  @override
  Future<int> countOperatorsFollowing({
    required String versionId,
    String reason = 'admin.default_role_catalog.blast_radius',
  }) async {
    return _operatorFollowersByVersion[versionId] ?? 0;
  }

  @override
  Future<DefaultRoleCatalogVersionRow> publishVersion({
    required String publishedByUserId,
    required List<Object?> payload,
    required String payloadSha256,
    String? notes,
    String reason = 'admin.default_role_catalog.publish',
  }) async {
    publishCount += 1;
    final nextNumber =
        (history
            .map((r) => r.versionNumber)
            .fold<int>(0, (a, b) => a > b ? a : b)) +
        1;
    final row = DefaultRoleCatalogVersionRow(
      versionId: 'version-uuid-$nextNumber',
      versionNumber: nextNumber,
      publishedAt: DateTime.utc(2026, 5, 13, 10),
      publishedByUserId: publishedByUserId,
      payload: payload,
      payloadSha256: payloadSha256,
      isCurrent: true,
      supersededAt: null,
      notes: notes,
    );
    currentRow = row;
    return row;
  }

  @override
  // ignore: invalid_use_of_visible_for_overriding_member
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
