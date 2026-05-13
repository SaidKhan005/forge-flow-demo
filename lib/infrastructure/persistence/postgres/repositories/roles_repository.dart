// Phase 9 live-closeout B17 - RolesRepository.
//
// Persistence layer for the `roles` + `role_permissions` tables.
// Reads / writes routed through the `OperatorScopedRepository` +
// `TenantTransactionWrapper` so the per-tenant RLS policies admit
// the rows.
//
// `roles` rows can be either global (operator_id NULL — seeded
// system roles) or operator-scoped (operator_id set — operator's
// custom roles). The composite PK on `(operator_id, role_key)`
// (with a separate partial index for operator_id IS NULL) is
// enforced at the DB; the repo just round-trips the values.
//
// Lane B B2.1 — `resolveDefaultRoleCatalogPayload` adds a pull-time
// resolver that returns the resolved Default Role catalog payload for
// an operator. Resolution order:
//   1. If `operators.default_role_catalog_version_id` is non-NULL,
//      return that pinned version's payload.
//   2. Otherwise return the row in `default_role_catalog_versions`
//      where `is_current = true` (the latest published version).
//   3. If no version has been published yet (genesis state), return
//      null. Call sites fall back to the existing hard-coded default
//      catalog in that case so behavior is identical to pre-B2.1.
//
// Lane B B2.4 — `listVisibleRoles` projects two extra columns
// (`catalog_version_id`, `catalog_published_at`) onto seeded role
// rows so the operator-web Roles surface can render an
// "Updated by F&F on <date>" annotation. The projection uses the
// same resolution rule as `resolveDefaultRoleCatalogPayload`:
//   * pinned (operators.default_role_catalog_version_id non-NULL) →
//     the pinned version's metadata,
//   * unpinned → the row where `is_current = true`,
//   * genesis (no catalog version published yet) → NULL for both
//     fields (operator-web falls back to "Managed by Forge & Flow").
// Custom (is_seeded = false) rows always project NULL for both
// fields. The JOIN to `public.default_role_catalog_versions` is
// safe under the tenant transaction because the catalog table's
// SELECT grant admits `service_role` (per B2.1 migration grants).

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// Lane B B2.1 — Resolved Default Role catalog for an operator.
///
/// Returned by [RolesRepository.resolveDefaultRoleCatalogPayload]. The
/// `resolutionSource` field distinguishes the two non-genesis paths:
///   * `'pinned'` — `operators.default_role_catalog_version_id` was
///     non-NULL; the resolver returned the pinned version verbatim.
///   * `'current'` — the operators pointer was NULL; the resolver
///     returned the row with `is_current = true`.
class DefaultRoleCatalogResolution {
  const DefaultRoleCatalogResolution({
    required this.versionId,
    required this.versionNumber,
    required this.payload,
    required this.payloadSha256,
    required this.isCurrent,
    required this.publishedAt,
    required this.resolutionSource,
  });

  final String versionId;
  final int versionNumber;
  final List<Object?> payload;
  final String payloadSha256;
  final bool isCurrent;
  final DateTime publishedAt;

  /// Either `'pinned'` (operator pins this version) or `'current'`
  /// (operator follows the latest published version).
  final String resolutionSource;
}

/// One row from `roles`.
class RoleRecord {
  const RoleRecord({
    required this.roleId,
    required this.roleKey,
    required this.displayName,
    required this.description,
    required this.isSeeded,
    required this.isEditable,
    required this.createdAt,
    required this.updatedAt,
    this.operatorId,
    this.deletedAt,
    this.catalogVersionId,
    this.catalogPublishedAt,
  });

  final String roleId;
  final String roleKey;
  final String displayName;
  final String description;
  final bool isSeeded;
  final bool isEditable;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Null for global / seeded roles; non-null for operator-scoped
  /// custom roles.
  final String? operatorId;
  final DateTime? deletedAt;

  /// Lane B B2.4 — `default_role_catalog_versions.version_id` the
  /// reading operator is following for this row, or NULL when the
  /// row isn't catalog-sourced (custom role) or no catalog version
  /// has been published yet (genesis state).
  final String? catalogVersionId;

  /// Lane B B2.4 — `default_role_catalog_versions.published_at`
  /// paired with [catalogVersionId]. Tenant transaction returns the
  /// driver's UTC `DateTime`.
  final DateTime? catalogPublishedAt;
}

class RolesRepository extends OperatorScopedRepository {
  RolesRepository(super.tenantWrapper);

  /// SELECT every role visible to the actor's tenant. Per-tenant RLS
  /// admits operator-scoped rows owned by this operator + every
  /// global (operator_id IS NULL) row, so the caller can render
  /// "global + operator-scoped" together.
  Future<List<RoleRecord>> listVisibleRoles({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<List<RoleRecord>>(ctx, (exec) async {
      // Lane B B2.4 — LEFT JOIN the catalog-version row the operator
      // is currently following so seeded rows carry the version's
      // published_at for the operator-web "Updated by F&F on <date>"
      // annotation. The catalog table's SELECT grant admits
      // service_role (per B2.1 migration), so the JOIN runs inside
      // the standard tenant transaction without elevating. The LEFT
      // JOIN resolves to NULL when the role is custom
      // (is_seeded = false) or no catalog version has been published
      // yet (genesis state) — callers treat both as "no version
      // metadata".
      final rows = await exec.query(
        'select r.role_id::text as role_id, '
        'r.operator_id::text as operator_id, '
        'r.role_key, r.display_name, r.description, '
        'r.is_seeded, r.is_editable, '
        'r.created_at, r.updated_at, r.deleted_at, '
        'cv.version_id::text as catalog_version_id, '
        'cv.published_at as catalog_published_at '
        'from roles r '
        'left join public.operators o '
        '  on r.is_seeded = true '
        '  and o.operator_id = @operator_id::uuid '
        'left join public.default_role_catalog_versions cv '
        '  on r.is_seeded = true '
        '  and ('
        '    (o.default_role_catalog_version_id is not null '
        '     and cv.version_id = o.default_role_catalog_version_id) '
        '    or '
        '    (o.default_role_catalog_version_id is null '
        '     and cv.is_current = true)'
        '  ) '
        'where r.deleted_at is null '
        'order by case when r.operator_id is null then 0 else 1 end, r.role_key',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      return rows.map(_projectRow).toList(growable: false);
    });
  }

  /// SELECT one role visible to the actor's tenant.
  Future<RoleRecord> visibleRoleById({
    required String operatorId,
    required String locationId,
    required String roleId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<RoleRecord>(ctx, (exec) async {
      final rows = await exec.query(
        'select role_id::text as role_id, '
        'operator_id::text as operator_id, '
        'role_key, display_name, description, '
        'is_seeded, is_editable, '
        'created_at, updated_at, deleted_at '
        'from roles '
        'where role_id = @role_id::uuid '
        'and deleted_at is null '
        'and (operator_id = @operator_id::uuid or operator_id is null) '
        'limit 1',
        parameters: <String, Object?>{
          'role_id': roleId,
          'operator_id': operatorId,
        },
      );
      if (rows.isEmpty) {
        throw StateError('role is not visible to this operator');
      }
      return _projectRow(rows.single);
    });
  }

  /// Resolve a seeded role key to its UUID.
  ///
  /// B3 keeps the six seeded role slugs as catalog membership signals, but
  /// custom-role mutation paths must carry `role_id` directly.
  Future<String> roleIdForVisibleKey({
    required String operatorId,
    required String locationId,
    required String roleKey,
    required String actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'select role_id::text as role_id '
        'from roles '
        'where role_key = @role_key '
        'and deleted_at is null '
        'and operator_id is null '
        'and is_seeded = true '
        'limit 1',
        parameters: <String, Object?>{'role_key': roleKey},
      );
      if (rows.isEmpty) {
        throw StateError('seeded role key is not visible to this operator');
      }
      final id = rows.single['role_id'];
      if (id is String && id.isNotEmpty) return id;
      throw StateError('roles lookup returned a malformed role_id');
    });
  }

  /// INSERT a new operator-scoped role. Returns the freshly minted
  /// `role_id`. The proxy validates `RoleManagementPolicy` BEFORE
  /// invoking this — the repo trusts its caller.
  Future<String> insertOperatorRole({
    required String operatorId,
    required String locationId,
    required String createdByUserId,
    required String roleKey,
    required String displayName,
    String description = '',
    bool isEditable = true,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: createdByUserId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into roles ('
        'operator_id, role_key, display_name, description, '
        'is_seeded, is_editable, created_by, updated_by) '
        'values (@operator_id::uuid, @role_key, @display_name, '
        '@description, false, @is_editable, '
        '@created_by::uuid, @created_by::uuid) '
        'returning role_id::text as role_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'role_key': roleKey,
          'display_name': displayName,
          'description': description,
          'is_editable': isEditable,
          'created_by': createdByUserId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'roles insert returned no rows — RLS may have blocked',
        );
      }
      final id = rows.single['role_id'];
      if (id is! String || id.isEmpty) {
        throw StateError('roles insert returned a malformed role_id');
      }
      return id;
    });
  }

  /// Update editable metadata for an operator-scoped custom role.
  Future<int> updateOperatorRole({
    required String operatorId,
    required String locationId,
    required String updatedByUserId,
    required String roleId,
    String? displayName,
    String? description,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: updatedByUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update roles '
        'set display_name = coalesce(@display_name, display_name), '
        'description = coalesce(@description, description), '
        'updated_at = now(), updated_by = @updated_by::uuid '
        'where role_id = @role_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and is_seeded = false '
        'and is_editable = true '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'role_id': roleId,
          'operator_id': operatorId,
          'display_name': displayName,
          'description': description,
          'updated_by': updatedByUserId,
        },
      );
    });
  }

  /// Soft-delete an operator-scoped role. Caller verified
  /// `RoleManagementPolicy.evaluateRoleAction(role)` first.
  /// Refuses to soft-delete a role that still has active grants;
  /// the proxy must revoke / reassign grants first.
  Future<int> softDeleteOperatorRole({
    required String operatorId,
    required String locationId,
    required String updatedByUserId,
    required String roleId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: updatedByUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      final activeGrants = await exec.query(
        'select 1 from user_roles '
        'where role_id = @role_id::uuid '
        'and revoked_at is null '
        'limit 1',
        parameters: <String, Object?>{'role_id': roleId},
      );
      if (activeGrants.isNotEmpty) {
        throw StateError(
          'roles soft-delete refused: role $roleId still has active '
          'user_roles grants; revoke them before deleting',
        );
      }
      return exec.execute(
        'update roles '
        'set deleted_at = now(), updated_at = now(), updated_by = @updated_by::uuid '
        'where role_id = @role_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'role_id': roleId,
          'updated_by': updatedByUserId,
        },
      );
    });
  }

  /// Lane B B2.1 — Resolve the Default Role catalog payload for an
  /// operator at read time.
  ///
  /// Resolution order:
  ///   1. If `operators.default_role_catalog_version_id` is non-NULL,
  ///      return the pinned version's payload + version metadata.
  ///   2. Otherwise return the row in `default_role_catalog_versions`
  ///      where `is_current = true` (the latest published version).
  ///   3. Return null when no version has been published yet (genesis
  ///      state). Callers MUST fall back to the existing hard-coded
  ///      default catalog when null is returned — this is the
  ///      backwards-compatible state that exists at PR-merge time
  ///      (before any admin has published a version).
  ///
  /// The lookup runs through `withTenant` so the operator's tenant
  /// context is active for the row visibility check on the
  /// `operators` table. The `default_role_catalog_versions` join is
  /// safe under that context because the catalog table has no RLS
  /// policy (it is admin-pool only; the SELECT grant to
  /// `service_role` admits the read from the tenant transaction).
  Future<DefaultRoleCatalogResolution?> resolveDefaultRoleCatalogPayload({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<DefaultRoleCatalogResolution?>(ctx, (exec) async {
      // Single round-trip: a LEFT JOIN that resolves either the pinned
      // version (when operators.default_role_catalog_version_id is
      // non-NULL) or the current version (when NULL). The COALESCE
      // produces NULL when neither branch resolves (genesis state).
      final rows = await exec.query(
        'select '
        '  resolved.version_id::text as version_id, '
        '  resolved.version_number as version_number, '
        '  resolved.payload as payload, '
        '  resolved.payload_sha256 as payload_sha256, '
        '  resolved.is_current as is_current, '
        '  resolved.published_at as published_at, '
        '  case '
        '    when o.default_role_catalog_version_id is not null '
        '    then \'pinned\' '
        '    else \'current\' '
        '  end as resolution_source '
        'from public.operators o '
        'left join lateral ( '
        '  select v.version_id, v.version_number, v.payload, '
        '         v.payload_sha256, v.is_current, v.published_at '
        '  from public.default_role_catalog_versions v '
        '  where ('
        '    o.default_role_catalog_version_id is not null '
        '    and v.version_id = o.default_role_catalog_version_id'
        '  ) or ('
        '    o.default_role_catalog_version_id is null '
        '    and v.is_current = true'
        '  ) '
        '  limit 1'
        ') resolved on true '
        'where o.operator_id = @operator_id::uuid '
        'limit 1',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final versionId = row['version_id'];
      if (versionId is! String || versionId.isEmpty) {
        // The operators row exists but the lateral join produced no
        // catalog row — genesis state. Callers fall back to the
        // hard-coded catalog.
        return null;
      }
      final versionNumber = row['version_number'];
      final payloadRaw = row['payload'];
      final payloadSha256 = row['payload_sha256'];
      final isCurrent = row['is_current'];
      final publishedAt = row['published_at'];
      final resolutionSource = row['resolution_source'];
      if (versionNumber is! int && versionNumber is! num) {
        throw StateError(
          'default_role_catalog_versions.version_number returned an '
          'unexpected shape',
        );
      }
      if (payloadSha256 is! String) {
        throw StateError(
          'default_role_catalog_versions.payload_sha256 returned non-String',
        );
      }
      if (publishedAt is! DateTime) {
        throw StateError(
          'default_role_catalog_versions.published_at returned non-DateTime',
        );
      }
      return DefaultRoleCatalogResolution(
        versionId: versionId,
        versionNumber: versionNumber is int
            ? versionNumber
            : (versionNumber as num).toInt(),
        payload: _decodeCatalogPayload(payloadRaw),
        payloadSha256: payloadSha256,
        isCurrent: isCurrent is bool ? isCurrent : false,
        publishedAt: publishedAt,
        resolutionSource: resolutionSource is String
            ? resolutionSource
            : 'current',
      );
    });
  }

  static List<Object?> _decodeCatalogPayload(Object? raw) {
    if (raw == null) return const <Object?>[];
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is List) return List<Object?>.from(decoded);
    throw StateError(
      'default_role_catalog_versions.payload returned a non-array shape '
      '(${raw.runtimeType}) — migration CHECK has been dropped',
    );
  }

  static RoleRecord _projectRow(Map<String, Object?> row) {
    // Lane B B2.4 — `catalog_version_id` / `catalog_published_at`
    // are absent from any callsite still using the pre-B2.4 SELECT
    // (e.g. visibleRoleById, which doesn't need them). The
    // `row[...]` lookup returns null when the key is missing, which
    // is the same shape we project for custom roles / genesis state.
    return RoleRecord(
      roleId: row['role_id'] as String,
      operatorId: row['operator_id'] as String?,
      roleKey: row['role_key'] as String,
      displayName: row['display_name'] as String,
      description: (row['description'] as String?) ?? '',
      isSeeded: row['is_seeded'] as bool,
      isEditable: row['is_editable'] as bool,
      createdAt: row['created_at'] as DateTime,
      updatedAt: row['updated_at'] as DateTime,
      deletedAt: row['deleted_at'] as DateTime?,
      catalogVersionId: row['catalog_version_id'] as String?,
      catalogPublishedAt: row['catalog_published_at'] as DateTime?,
    );
  }
}
