// Lane B B2.4 — RolesRepository.listVisibleRoles catalog-version
// projection tests.
//
// Pins the contract added in B2.4: the SELECT in `listVisibleRoles`
// LEFT JOINs `public.operators` (by the caller's operator_id) +
// `public.default_role_catalog_versions` so each row carries
// `catalog_version_id` + `catalog_published_at` for the operator-
// web "Updated by F&F on <date>" annotation.
//
// Resolution rule (mirrors `resolveDefaultRoleCatalogPayload`):
//
//   * Pinned operator (`operators.default_role_catalog_version_id`
//     non-NULL) → seeded rows project the pinned version's
//     metadata.
//   * Unpinned operator (pointer is NULL) → seeded rows project
//     the row with `is_current = true`.
//   * Genesis state (no catalog version published yet) → seeded
//     rows project NULL for both fields; operator-web falls back
//     to the version-agnostic "Managed by Forge & Flow" copy.
//   * Custom rows (`is_seeded = false`) → always NULL.
//
// SQL contract pin: the LEFT JOIN gates on `r.is_seeded = true`
// before evaluating the resolution branch, so the JOIN cannot
// accidentally project metadata onto a custom row even if a
// catalog version row sneaks through.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _actorA = '33333333-3333-3333-3333-333333333333';
const String _roleGlobalSeeded = '44444444-4444-4444-4444-444444444444';
const String _roleOpCustom = '55555555-5555-5555-5555-555555555555';
const String _catalogVersionId =
    '66666666-6666-6666-6666-666666666666';
final DateTime _publishedAt = DateTime.utc(2026, 1, 15, 17, 0);

PostgresRow _seededRow({
  String? catalogVersionId,
  DateTime? catalogPublishedAt,
}) {
  return <String, Object?>{
    'role_id': _roleGlobalSeeded,
    'operator_id': null,
    'role_key': 'operator_owner',
    'display_name': 'Owner',
    'description': '',
    'is_seeded': true,
    'is_editable': false,
    'created_at': DateTime.utc(2026, 1, 1),
    'updated_at': DateTime.utc(2026, 1, 1),
    'deleted_at': null,
    'catalog_version_id': catalogVersionId,
    'catalog_published_at': catalogPublishedAt,
  };
}

PostgresRow _customRow() {
  return <String, Object?>{
    'role_id': _roleOpCustom,
    'operator_id': _opA,
    'role_key': 'shift_manager',
    'display_name': 'Shift Manager',
    'description': '',
    'is_seeded': false,
    'is_editable': true,
    'created_at': DateTime.utc(2026, 1, 1),
    'updated_at': DateTime.utc(2026, 1, 1),
    'deleted_at': null,
    // Custom rows: catalog fields always NULL even if the LEFT JOIN
    // resolves no row. The repo's _projectRow tolerates missing
    // keys; we set explicit nulls here to mirror the production
    // SELECT shape.
    'catalog_version_id': null,
    'catalog_published_at': null,
  };
}

void main() {
  group('RolesRepository.listVisibleRoles catalog-version projection', () {
    test(
      'SELECT shape: LEFT JOIN public.operators + '
      'public.default_role_catalog_versions; both joins gate on '
      'r.is_seeded = true so custom rows cannot inherit catalog '
      'metadata',
      () async {
        final pool = _RolesPool(
          listRows: <PostgresRow>[
            _seededRow(
              catalogVersionId: _catalogVersionId,
              catalogPublishedAt: _publishedAt,
            ),
          ],
        );
        final repo = RolesRepository(TenantTransactionWrapper(pool));
        await repo.listVisibleRoles(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
        );
        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from roles r'),
        );
        // LEFT JOIN to operators on the caller's operator_id.
        expect(selectSql, contains('left join public.operators o'));
        expect(selectSql, contains('o.operator_id = @operator_id::uuid'));
        // LEFT JOIN to default_role_catalog_versions; gated on
        // r.is_seeded = true so custom rows never inherit metadata.
        expect(
          selectSql,
          contains('left join public.default_role_catalog_versions cv'),
        );
        final seededGateMatches = RegExp(
          r'on r\.is_seeded = true',
        ).allMatches(selectSql);
        expect(
          seededGateMatches,
          hasLength(2),
          reason:
              'both LEFT JOINs must gate on r.is_seeded = true so '
              'the operators / catalog tables never project metadata '
              'onto a custom (is_seeded = false) row',
        );
        // Pinned-vs-current resolution branch.
        expect(
          selectSql,
          contains('o.default_role_catalog_version_id is not null'),
        );
        expect(
          selectSql,
          contains('cv.version_id = o.default_role_catalog_version_id'),
        );
        expect(selectSql, contains('cv.is_current = true'));
        // Projected columns.
        expect(
          selectSql,
          contains('cv.version_id::text as catalog_version_id'),
        );
        expect(
          selectSql,
          contains('cv.published_at as catalog_published_at'),
        );
        // operator_id parameter is bound (drives both the operators
        // join and the LEFT-JOIN visibility for the caller's pin
        // state).
        final selectParams = tx.parameters[tx.executedSql.indexOf(selectSql)];
        expect(selectParams['operator_id'], equals(_opA));
      },
    );

    test(
      'pinned operator: seeded row projects the pinned version_id + '
      'published_at',
      () async {
        final pool = _RolesPool(
          listRows: <PostgresRow>[
            _seededRow(
              catalogVersionId: _catalogVersionId,
              catalogPublishedAt: _publishedAt,
            ),
          ],
        );
        final repo = RolesRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listVisibleRoles(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
        );
        expect(rows, hasLength(1));
        expect(rows[0].isSeeded, isTrue);
        expect(rows[0].catalogVersionId, equals(_catalogVersionId));
        expect(rows[0].catalogPublishedAt, equals(_publishedAt));
      },
    );

    test(
      'genesis state (no catalog version published yet): seeded row '
      'projects NULL for both catalog fields; caller falls back to '
      'the version-agnostic copy',
      () async {
        final pool = _RolesPool(
          listRows: <PostgresRow>[
            // The LEFT JOIN found no row → driver returns nulls for
            // the projected aliases.
            _seededRow(catalogVersionId: null, catalogPublishedAt: null),
          ],
        );
        final repo = RolesRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listVisibleRoles(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
        );
        expect(rows, hasLength(1));
        expect(rows[0].isSeeded, isTrue);
        expect(rows[0].catalogVersionId, isNull);
        expect(rows[0].catalogPublishedAt, isNull);
      },
    );

    test(
      'custom (is_seeded = false) row always projects NULL for both '
      'catalog fields, regardless of any catalog metadata in the row',
      () async {
        final pool = _RolesPool(listRows: <PostgresRow>[_customRow()]);
        final repo = RolesRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listVisibleRoles(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
        );
        expect(rows, hasLength(1));
        expect(rows[0].isSeeded, isFalse);
        expect(rows[0].catalogVersionId, isNull);
        expect(rows[0].catalogPublishedAt, isNull);
      },
    );

    test(
      'mixed list: seeded row carries catalog metadata; custom row '
      'on the same caller projects NULL for both fields',
      () async {
        final pool = _RolesPool(
          listRows: <PostgresRow>[
            _seededRow(
              catalogVersionId: _catalogVersionId,
              catalogPublishedAt: _publishedAt,
            ),
            _customRow(),
          ],
        );
        final repo = RolesRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listVisibleRoles(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: _actorA,
        );
        expect(rows, hasLength(2));
        // Seeded row carries metadata.
        final seeded = rows.firstWhere((r) => r.isSeeded);
        expect(seeded.catalogVersionId, equals(_catalogVersionId));
        expect(seeded.catalogPublishedAt, equals(_publishedAt));
        // Custom row stays null.
        final custom = rows.firstWhere((r) => !r.isSeeded);
        expect(custom.catalogVersionId, isNull);
        expect(custom.catalogPublishedAt, isNull);
      },
    );
  });
}

class _RolesPool implements PostgresPool {
  _RolesPool({this.listRows = const <PostgresRow>[]});

  final List<PostgresRow> listRows;
  final List<_RolesTransaction> transactions = <_RolesTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RolesTransaction(listRows: listRows);
    transactions.add(tx);
    return tx;
  }
}

class _RolesTransaction extends PostgresTransaction {
  _RolesTransaction({required this.listRows});

  final List<PostgresRow> listRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from roles r')) return listRows;
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
