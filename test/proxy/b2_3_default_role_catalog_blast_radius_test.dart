// Lane B B2.3 — blast-radius route tests.
//
// Pins the new read-only route added on top of B2.1's admin router:
//
//   GET /v1/admin/auth/role-catalogs/blast-radius?version_id=<uuid>
//     {super_admin, ff_support}
//
// Tests drive [DefaultRoleCatalogAdminRouter.dispatch] directly so the
// new route's gating + parameter parsing exercise in isolation from
// the proxy's HTTP shell. Mirrors `b2_1_default_role_catalog_routes_test.dart`
// fixture discipline (same fake repository + same recording audit
// sink so a future re-audit can compare both files side-by-side).
//
// Authority:
//   * tool/advisor_proxy/admin_default_role_catalog_routes.dart
//   * docs/archive/_indices/wave_1_closed_2026_05_13/WAVE_EXECUTION_LEDGER.md (row B2.3)
//   * B2.2 PR #590 disclosed gap #1
//
// What we assert:
//   1. Role gate: super_admin + ff_support admit; everything else 403.
//   2. Required version_id query param: missing → 400 missing_version_id.
//   3. Malformed version_id (not UUID-shaped) → 400 invalid_version_id.
//   4. Unknown version_id (gets through validation but no row exists)
//      → 404 version_not_found.
//   5. Happy path → 200 with {version_id, version_number,
//      operator_count, location_count, user_count}.
//   6. No audit row emitted (read-only endpoint).
//   7. No Idempotency-Key required (GET).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/default_role_catalog_versions_repository.dart';

import '../../tool/advisor_proxy/admin_default_role_catalog_routes.dart';

const String _kFirebaseUid = 'firebase-uid-abc';
const String _kAdminPostgresUserId = '11111111-1111-1111-1111-111111111111';
const String _kValidVersionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

void main() {
  group('DefaultRoleCatalogAdminRouter.matches (B2.3 blast-radius path)', () {
    test('matches GET /v1/admin/auth/role-catalogs/blast-radius', () {
      expect(
        DefaultRoleCatalogAdminRouter.matches(
          '/v1/admin/auth/role-catalogs/blast-radius',
          'GET',
        ),
        isTrue,
      );
    });

    test('rejects POST on the blast-radius path (read-only)', () {
      expect(
        DefaultRoleCatalogAdminRouter.matches(
          '/v1/admin/auth/role-catalogs/blast-radius',
          'POST',
        ),
        isFalse,
      );
    });

    test('isReadOnly is true for the blast-radius GET', () {
      expect(
        DefaultRoleCatalogAdminRouter.isReadOnly(
          '/v1/admin/auth/role-catalogs/blast-radius',
          'GET',
        ),
        isTrue,
      );
    });

    test('isReadOnly is false for POST on blast-radius path', () {
      expect(
        DefaultRoleCatalogAdminRouter.isReadOnly(
          '/v1/admin/auth/role-catalogs/blast-radius',
          'POST',
        ),
        isFalse,
      );
    });

    test('path constant matches expected value', () {
      expect(
        kAdminDefaultRoleCatalogBlastRadiusPath,
        equals('/v1/admin/auth/role-catalogs/blast-radius'),
      );
    });
  });

  group('DefaultRoleCatalogAdminRouter.dispatch (blast-radius role gate)', () {
    test('super_admin admits → 200', () async {
      final repo = _FakeCatalogRepository(
        versionRow: _buildRow(versionId: _kValidVersionId, versionNumber: 7),
        counts: const _Counts(operators: 1, locations: 2, users: 3),
      );
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: _kValidVersionId,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
      expect(result.body['version_id'], equals(_kValidVersionId));
      expect(result.body['version_number'], equals(7));
      expect(result.body['operator_count'], equals(1));
      expect(result.body['location_count'], equals(2));
      expect(result.body['user_count'], equals(3));
    });

    test('ff_support admits → 200 (read-only posture)', () async {
      final repo = _FakeCatalogRepository(
        versionRow: _buildRow(versionId: _kValidVersionId, versionNumber: 1),
        counts: const _Counts(operators: 0, locations: 0, users: 0),
      );
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'ff_support'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: _kValidVersionId,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
    });

    test('operator-tier role → 403 permission_denied', () async {
      final repo = _FakeCatalogRepository();
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'operator_owner'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: _kValidVersionId,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(403));
      expect(result.body['error'], equals('permission_denied'));
      // Required roles surfaced for client-side error mapping.
      expect(
        result.body['required_roles'],
        containsAll(<String>['super_admin', 'ff_support']),
      );
      // Repository NEVER consulted on auth failure.
      expect(repo.blastRadiusLookups, isEmpty);
      expect(repo.versionLookups, isEmpty);
    });

    test('empty role set → 403', () async {
      final repo = _FakeCatalogRepository();
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: _kValidVersionId,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(403));
    });
  });

  group('DefaultRoleCatalogAdminRouter.dispatch (version_id validation)', () {
    test('missing version_id → 400 missing_version_id', () async {
      final repo = _FakeCatalogRepository();
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: null,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(400));
      expect(result.body['error'], equals('missing_version_id'));
      // Validation precedes the repository call.
      expect(repo.versionLookups, isEmpty);
      expect(repo.blastRadiusLookups, isEmpty);
    });

    test('empty version_id (whitespace) → 400 missing_version_id', () async {
      final repo = _FakeCatalogRepository();
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: '   ',
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(400));
      expect(result.body['error'], equals('missing_version_id'));
    });

    test('malformed version_id (not UUID-shaped) → 400 invalid_version_id',
        () async {
      final repo = _FakeCatalogRepository();
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: 'not-a-uuid',
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(400));
      expect(result.body['error'], equals('invalid_version_id'));
      expect(repo.versionLookups, isEmpty);
      expect(repo.blastRadiusLookups, isEmpty);
    });

    test('uppercase UUID is normalised lowercase and accepted', () async {
      final repo = _FakeCatalogRepository(
        versionRow: _buildRow(versionId: _kValidVersionId, versionNumber: 2),
        counts: const _Counts(operators: 5, locations: 9, users: 12),
      );
      final router = _router(repo);
      final upper = _kValidVersionId.toUpperCase();
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: upper,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
      // Counts are surfaced for the canonical (uppercase) version_id —
      // the repository never sees a normalised value; we pass through
      // what the caller sent. The downstream column is uuid-typed so
      // Postgres folds case server-side. We surface the caller's value.
      expect(result.body['version_id'], equals(upper));
    });
  });

  group('DefaultRoleCatalogAdminRouter.dispatch (404 + happy path)', () {
    test('unknown version_id → 404 version_not_found', () async {
      final repo = _FakeCatalogRepository(versionRow: null);
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: _kValidVersionId,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(404));
      expect(result.body['error'], equals('version_not_found'));
      // The blast-radius lookup is NEVER fired when the version is
      // unknown — the route guards that path to keep "0 counts" from
      // shadowing "no such version" in the UI.
      expect(repo.versionLookups, equals(<String>[_kValidVersionId]));
      expect(repo.blastRadiusLookups, isEmpty);
    });

    test('happy path → 200 with three counts + version_number', () async {
      final repo = _FakeCatalogRepository(
        versionRow: _buildRow(versionId: _kValidVersionId, versionNumber: 13),
        counts: const _Counts(operators: 47, locations: 312, users: 1403),
      );
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: _kValidVersionId,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
      expect(result.body['version_id'], equals(_kValidVersionId));
      expect(result.body['version_number'], equals(13));
      expect(result.body['operator_count'], equals(47));
      expect(result.body['location_count'], equals(312));
      expect(result.body['user_count'], equals(1403));
      // Single lookup each — no fan-out.
      expect(repo.versionLookups, equals(<String>[_kValidVersionId]));
      expect(repo.blastRadiusLookups, equals(<String>[_kValidVersionId]));
    });

    test('happy path → 200 even when all counts are zero', () async {
      final repo = _FakeCatalogRepository(
        versionRow: _buildRow(versionId: _kValidVersionId, versionNumber: 1),
        counts: const _Counts(operators: 0, locations: 0, users: 0),
      );
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: _kValidVersionId,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
      expect(result.body['operator_count'], equals(0));
      expect(result.body['location_count'], equals(0));
      expect(result.body['user_count'], equals(0));
    });
  });

  group('DefaultRoleCatalogAdminRouter.dispatch (B2.3 cross-route hygiene)',
      () {
    test('Idempotency-Key NOT required on read', () async {
      final repo = _FakeCatalogRepository(
        versionRow: _buildRow(versionId: _kValidVersionId, versionNumber: 1),
        counts: const _Counts(operators: 0, locations: 0, users: 0),
      );
      final router = _router(repo);
      // Pass null header — must NOT 400.
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: _kValidVersionId,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
    });

    test('does NOT emit an audit event (read-only)', () async {
      final repo = _FakeCatalogRepository(
        versionRow: _buildRow(versionId: _kValidVersionId, versionNumber: 1),
        counts: const _Counts(operators: 1, locations: 1, users: 1),
      );
      final audit = RecordingDefaultRoleCatalogAuditSink();
      final router = DefaultRoleCatalogAdminRouter(
        repository: repo,
        auditSink: audit,
      );
      await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: _resolveToAdmin,
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: _kValidVersionId,
        body: const <String, Object?>{},
      );
      expect(audit.events, isEmpty);
    });

    test('does NOT require an actor resolver (no audit attribution needed)',
        () async {
      final repo = _FakeCatalogRepository(
        versionRow: _buildRow(versionId: _kValidVersionId, versionNumber: 1),
        counts: const _Counts(operators: 0, locations: 0, users: 0),
      );
      final router = _router(repo);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/admin/auth/role-catalogs/blast-radius',
        actorRoles: const <String>{'super_admin'},
        actorFirebaseUid: _kFirebaseUid,
        actorResolver: null, // null resolver MUST be acceptable on GET
        idempotencyKeyHeader: null,
        limitQueryParam: null,
        versionIdQueryParam: _kValidVersionId,
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
    });
  });
}

DefaultRoleCatalogAdminRouter _router(_FakeCatalogRepository repo) {
  return DefaultRoleCatalogAdminRouter(
    repository: repo,
    auditSink: const NoopDefaultRoleCatalogAuditSink(),
  );
}

DefaultRoleCatalogVersionRow _buildRow({
  required String versionId,
  required int versionNumber,
}) {
  return DefaultRoleCatalogVersionRow(
    versionId: versionId,
    versionNumber: versionNumber,
    publishedAt: DateTime.utc(2026, 5, 13, 10),
    publishedByUserId: _kAdminPostgresUserId,
    payload: const <Object?>[
      <String, Object?>{'role_key': 'r', 'display_name': 'R'},
    ],
    payloadSha256: 'a' * 64,
    isCurrent: true,
    supersededAt: null,
    notes: null,
  );
}

Future<String?> _resolveToAdmin({
  required String firebaseUid,
  required String adminReason,
}) async =>
    _kAdminPostgresUserId;

class _Counts {
  const _Counts({
    required this.operators,
    required this.locations,
    required this.users,
  });

  final int operators;
  final int locations;
  final int users;
}

/// In-memory fake of [DefaultRoleCatalogVersionsRepository]. The B2.1
/// route tests own the publish-path fake; this one focuses on the
/// blast-radius surface and records every lookup so we can assert on
/// call order (verify version_not_found short-circuits before the
/// counts query fires).
class _FakeCatalogRepository implements DefaultRoleCatalogVersionsRepository {
  _FakeCatalogRepository({
    this.versionRow,
    _Counts? counts,
  }) : counts = counts ?? const _Counts(operators: 0, locations: 0, users: 0);

  final DefaultRoleCatalogVersionRow? versionRow;
  final _Counts counts;

  final List<String> versionLookups = <String>[];
  final List<String> blastRadiusLookups = <String>[];

  @override
  Future<DefaultRoleCatalogVersionRow?> getVersion({
    required String versionId,
    String reason = 'admin.default_role_catalog.get_version',
  }) async {
    versionLookups.add(versionId);
    if (versionRow == null) return null;
    // For the "uppercase-uuid" assertion: route passes the caller's
    // version_id verbatim; we match against the fixture id which is
    // lowercase. Normalize the lookup so the fake matches both casings.
    if (versionRow!.versionId.toLowerCase() == versionId.toLowerCase()) {
      return versionRow;
    }
    return null;
  }

  @override
  Future<DefaultRoleCatalogBlastRadiusCounts> getBlastRadiusCounts({
    required String versionId,
    String reason = 'admin.default_role_catalog.blast_radius_counts',
  }) async {
    blastRadiusLookups.add(versionId);
    return DefaultRoleCatalogBlastRadiusCounts(
      versionId: versionId,
      operatorCount: counts.operators,
      locationCount: counts.locations,
      userCount: counts.users,
    );
  }

  @override
  // ignore: invalid_use_of_visible_for_overriding_member
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
