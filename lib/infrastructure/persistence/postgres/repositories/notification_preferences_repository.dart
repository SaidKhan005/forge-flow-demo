// Phase 8 W2.B - NotificationPreferencesRepository.
//
// Persistence layer for `public.notification_preferences`. Every read
// and write goes through `OperatorScopedRepository.withTenant` so the
// per-tenant + per-user RLS policy admits the row (primary defense:
// repository pattern; backup: RLS).
//
// Authority:
//   * db/migrations/202605070400_phase_8_notification_preferences.sql
//     (table + UNIQUE NULLS NOT DISTINCT on the 6-tuple).
//   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
//     (every operator-scoped table goes through OperatorScopedRepository;
//     no raw `package:postgres` import outside this directory).
//
// Methods:
//   * listForUser  - returns every row for (operatorId, userId).
//   * upsert       - INSERT ... ON CONFLICT DO UPDATE on the 6-tuple
//                    UNIQUE index. Idempotent.
//   * delete       - hard delete (absence = catalog default applies).

import '../../../../domain/models/notification_preference.dart';
import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class NotificationPreferencesRepository extends OperatorScopedRepository {
  NotificationPreferencesRepository(super.tenantWrapper);

  static const String _selectColumns =
      'id::text as id, '
      'operator_id::text as operator_id, '
      'user_id::text as user_id, '
      'event_key, '
      'channel, '
      'scope_kind, '
      'scope_id::text as scope_id, '
      'enabled, '
      'created_at, '
      'updated_at';

  /// List every preference row for `(operatorId, userId)`. Returned in
  /// a stable (event_key, channel, scope_kind, scope_id) order so
  /// gateway responses are deterministic across calls.
  Future<List<NotificationPreference>> listForUser({
    required String operatorId,
    required String locationId,
    required String userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<NotificationPreference>>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_selectColumns '
        'from public.notification_preferences '
        'where operator_id = @operator_id::uuid '
        'and user_id = @user_id::uuid '
        'order by event_key, channel, scope_kind, scope_id nulls first',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'user_id': userId,
        },
      );
      return <NotificationPreference>[
        for (final row in rows) NotificationPreference.fromRow(row),
      ];
    });
  }

  /// Upsert a preference row. Conflict identity matches the migration's
  /// UNIQUE NULLS NOT DISTINCT index on the 6-tuple. DO UPDATE rewrites
  /// `enabled` and bumps `updated_at`. Idempotent: replay yields the
  /// same final row state.
  Future<NotificationPreference> upsert({
    required String operatorId,
    required String locationId,
    required String userId,
    required String eventKey,
    required NotificationChannel channel,
    required NotificationScopeKind scopeKind,
    required String? scopeId,
    required bool enabled,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<NotificationPreference>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into public.notification_preferences ('
        'operator_id, user_id, event_key, channel, '
        'scope_kind, scope_id, enabled) '
        'values ('
        '@operator_id::uuid, @user_id::uuid, @event_key, @channel, '
        '@scope_kind, @scope_id::uuid, @enabled) '
        'on conflict (operator_id, user_id, event_key, channel, '
        'scope_kind, scope_id) do update set '
        'enabled = excluded.enabled, '
        'updated_at = now() '
        'returning $_selectColumns',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'user_id': userId,
          'event_key': eventKey,
          'channel': channel.wire,
          'scope_kind': scopeKind.wire,
          'scope_id': scopeId,
          'enabled': enabled,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'notification_preferences upsert returned no row - RLS policy '
          'likely rejected the write for this tenant',
        );
      }
      return NotificationPreference.fromRow(rows.single);
    });
  }

  /// Hard delete the preference row matching the 6-tuple. Absence of
  /// a row means the catalog default applies, so delete is the
  /// "reset to default" path. Returns true when a row was deleted.
  Future<bool> delete({
    required String operatorId,
    required String locationId,
    required String userId,
    required String eventKey,
    required NotificationChannel channel,
    required NotificationScopeKind scopeKind,
    required String? scopeId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<bool>(ctx, (exec) async {
      // `scope_id is not distinct from $scope_id::uuid` collapses NULL
      // equality so an operator-scope row with scope_id=NULL deletes
      // when called with scope_id=null (parameter binding cannot
      // cleanly express `IS NULL` vs `=` on its own).
      final affected = await exec.execute(
        'delete from public.notification_preferences '
        'where operator_id = @operator_id::uuid '
        'and user_id = @user_id::uuid '
        'and event_key = @event_key '
        'and channel = @channel '
        'and scope_kind = @scope_kind '
        'and scope_id is not distinct from @scope_id::uuid',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'user_id': userId,
          'event_key': eventKey,
          'channel': channel.wire,
          'scope_kind': scopeKind.wire,
          'scope_id': scopeId,
        },
      );
      return affected > 0;
    });
  }
}
