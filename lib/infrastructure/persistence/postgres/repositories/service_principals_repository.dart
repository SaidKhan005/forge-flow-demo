// Phase 9.0Σ.d — ServicePrincipalsRepository.
//
// Persistence layer for the `service_principals` table created in
// `202604280004_phase_9_0sigma_d_service_principals.sql` (item 14
// from `phase_9_scalability_decisions_2026-04-27.md`, parcel B25 in
// `phase_9_execution_backlog.md`). The repository owns ONLY the
// schema-facing operations the migration shape supports:
//
//   * [create]   — INSERT a new principal for the tenant.
//   * [list]     — SELECT every principal visible under the tenant
//                  context, ordered by `created_at`.
//   * [getById]  — SELECT one row by `id`; returns null when RLS
//                  blocks the read or the row is absent.
//   * [revoke]   — UPDATE `revoked_at = now()` so the principal can
//                  no longer mint tokens. Soft-revocation: rows are
//                  never deleted because audit rows reference the id.
//
// Hard scope guard — this slice MUST NOT add any of:
//
//   * `sp:` JWT issuance / signing keys / token rotation.
//   * Proxy verifier routing or any `tool/advisor_proxy/**` change.
//   * actor_kind writes to `auth_events_audit` or `audit_logs` (the
//     auth_events_audit_repository continues to own its writes; the
//     migration adds the column with a `'user'` default so existing
//     callers do not need to update).
//
// Those land in follow-up slices that touch the proxy + JWT verifier.
//
// CLAUDE.md "RLS performance discipline" bindings:
//   * Every read/write goes through `OperatorScopedRepository.withTenant`
//     so `SET LOCAL app.operator_id` is in place when the policy
//     (`service_principals_per_tenant`) evaluates.
//   * Tenant-leading indexes (`(operator_id, id)` + the active-only
//     partial) let the planner fold the policy into the index probe.
//   * `scopes` is bound as serialized JSON (jsonEncode) and cast to
//     jsonb in the SQL — never string-concatenated.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// One `service_principals` row, narrowed to the columns the launch
/// surface (admin UI in 11A, future proxy verifier path) needs.
/// Timestamps are exposed as `DateTime` (the `package:postgres`
/// adapter maps `timestamptz` → `DateTime`).
class ServicePrincipalRow {
  const ServicePrincipalRow({
    required this.id,
    required this.operatorId,
    required this.name,
    required this.scopes,
    required this.createdAt,
    required this.updatedAt,
    required this.revokedAt,
  });

  final String id;
  final String operatorId;
  final String name;

  /// Permission-key strings, decoded from the jsonb array. Empty
  /// list when the principal has no scopes (the migration default
  /// is `'[]'::jsonb`).
  final List<String> scopes;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// NULL when active. A non-null value means revoked; the verifier
  /// path (follow-up slice) will refuse to mint tokens once set.
  final DateTime? revokedAt;

  bool get isActive => revokedAt == null;
}

class ServicePrincipalsRepository extends OperatorScopedRepository {
  ServicePrincipalsRepository(super.tenantWrapper);

  /// INSERT a new service principal for the tenant. Returns the
  /// freshly assigned UUID.
  ///
  /// [scopes] is a flat list of permission-key strings. Stored as a
  /// jsonb array; the migration's `jsonb_typeof(scopes) = 'array'`
  /// CHECK guards the shape at the DB layer.
  Future<String> create({
    required String operatorId,
    required String locationId,
    required String name,
    List<String> scopes = const <String>[],
    String? userId,
  }) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'must be non-blank (the DB CHECK enforces 1..200 chars)',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into service_principals '
        '(operator_id, name, scopes) '
        'values (@operator_id::uuid, @name, @scopes::jsonb) '
        'returning id::text as id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'name': name,
          'scopes': jsonEncode(scopes),
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'service_principals insert returned no rows — RLS may have '
          'blocked the row even though SET LOCAL ran',
        );
      }
      final id = rows.single['id'];
      if (id is! String || id.isEmpty) {
        throw StateError(
          'service_principals insert returned a malformed id',
        );
      }
      return id;
    });
  }

  /// SELECT every `service_principals` row visible to the tenant
  /// context. Ordered by `created_at desc` so the most recently
  /// issued principals show first in the admin UI. Pass
  /// [includeRevoked] = false to filter to active rows only (matches
  /// the partial index `service_principals_operator_active_idx`).
  Future<List<ServicePrincipalRow>> list({
    required String operatorId,
    required String locationId,
    bool includeRevoked = true,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    final whereClause = includeRevoked ? '' : 'where revoked_at is null ';
    return withTenant<List<ServicePrincipalRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select id::text as id, operator_id::text as operator_id, '
        'name, scopes, created_at, updated_at, revoked_at '
        'from service_principals '
        '$whereClause'
        'order by created_at desc',
      );
      return rows.map(_rowFromMap).toList(growable: false);
    });
  }

  /// SELECT a single row by id. Returns null when the row is
  /// invisible to the tenant (RLS) or absent.
  Future<ServicePrincipalRow?> getById({
    required String operatorId,
    required String locationId,
    required String id,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<ServicePrincipalRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select id::text as id, operator_id::text as operator_id, '
        'name, scopes, created_at, updated_at, revoked_at '
        'from service_principals '
        'where id = @id::uuid',
        parameters: <String, Object?>{'id': id},
      );
      if (rows.isEmpty) return null;
      return _rowFromMap(rows.single);
    });
  }

  /// Soft-revoke the principal: stamps `revoked_at = now()` so the
  /// future verifier path refuses to mint tokens. Idempotent — a
  /// re-revoke leaves the original `revoked_at` value untouched (the
  /// `where revoked_at is null` predicate skips already-revoked
  /// rows). Returns the row count actually updated (0 when the row
  /// was already revoked or not visible to the tenant).
  Future<int> revoke({
    required String operatorId,
    required String locationId,
    required String id,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update service_principals '
        'set revoked_at = now() '
        'where id = @id::uuid '
        '  and revoked_at is null',
        parameters: <String, Object?>{'id': id},
      );
    });
  }

  static ServicePrincipalRow _rowFromMap(Map<String, Object?> row) {
    final id = row['id'];
    final operatorId = row['operator_id'];
    final name = row['name'];
    final createdAt = row['created_at'];
    final updatedAt = row['updated_at'];
    final revokedAt = row['revoked_at'];
    if (id is! String ||
        operatorId is! String ||
        name is! String ||
        createdAt is! DateTime ||
        updatedAt is! DateTime) {
      throw StateError(
        'service_principals row returned a malformed shape',
      );
    }
    if (revokedAt != null && revokedAt is! DateTime) {
      throw StateError(
        'service_principals.revoked_at returned a non-DateTime value',
      );
    }
    return ServicePrincipalRow(
      id: id,
      operatorId: operatorId,
      name: name,
      scopes: _decodeScopes(row['scopes']),
      createdAt: createdAt,
      updatedAt: updatedAt,
      revokedAt: revokedAt as DateTime?,
    );
  }

  /// `scopes` arrives from the driver as either a Dart `List` (jsonb
  /// decoded by the underlying adapter) or a `String` (raw JSON
  /// text). The repository normalizes both into `List<String>` so
  /// downstream code does not branch. A non-array body would have
  /// failed the migration's CHECK; the runtime guard here surfaces a
  /// clear error if a future schema change ever drops that CHECK.
  static List<String> _decodeScopes(Object? raw) {
    if (raw == null) return const <String>[];
    final decoded = raw is String && raw.isNotEmpty
        ? jsonDecode(raw)
        : raw;
    if (decoded is List) {
      return decoded.map((scope) => scope.toString()).toList(growable: false);
    }
    if (decoded is String && decoded.isEmpty) return const <String>[];
    throw StateError(
      'service_principals.scopes returned a value of unsupported type '
      '${raw.runtimeType} — the migration CHECK requires a jsonb array',
    );
  }
}
