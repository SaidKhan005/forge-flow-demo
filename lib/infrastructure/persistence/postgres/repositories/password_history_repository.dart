// Phase 9 live-closeout B15 - PasswordHistoryRepository.
//
// Persistence layer for the `password_history` table from the 9.0
// schema foundation:
//
//   entry_id uuid pk default gen_random_uuid()
//   user_id uuid (FK users)
//   password_hash text  (re-use detection only — Firebase still
//                       handles the credential hash)
//   set_at timestamptz default now()
//   created_at timestamptz default now()
//
// RLS is per-user (`password_history_per_user` in the 9.2 migration).
//
// Pruning: the locked policy keeps the latest 5 hashes per user.
// `prune` is exposed so the proxy can call it after every insert
// without depending on a Postgres trigger (the 9.0 plan calls out
// "trigger or scheduled job"; this file gives the proxy the
// scheduled-job alternative).

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class PasswordHistoryEntry {
  const PasswordHistoryEntry({
    required this.entryId,
    required this.userId,
    required this.passwordHash,
    required this.setAt,
  });

  final String entryId;
  final String userId;
  final String passwordHash;
  final DateTime setAt;
}

class PasswordHistoryRepository extends OperatorScopedRepository {
  PasswordHistoryRepository(super.tenantWrapper);

  /// INSERT a new `password_history` row. Caller MUST hash the
  /// password BEFORE invoking this method — the raw password never
  /// reaches the repository layer.
  Future<String> recordHash({
    required String operatorId,
    required String locationId,
    required String userId,
    required String passwordHashHex,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into password_history (user_id, password_hash) '
        'values (@user_id::uuid, @hash) '
        'returning entry_id::text as entry_id',
        parameters: <String, Object?>{
          'user_id': userId,
          'hash': passwordHashHex,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'password_history insert returned no rows — RLS policy may '
          'have blocked the row even though SET LOCAL ran',
        );
      }
      final id = rows.single['entry_id'];
      if (id is! String || id.isEmpty) {
        throw StateError(
          'password_history insert returned a malformed entry_id',
        );
      }
      return id;
    });
  }

  /// Returns the [n] most recent password hashes for [userId], newest
  /// first. The reuse-check service iterates these and constant-time
  /// compares against a candidate hash.
  Future<List<PasswordHistoryEntry>> latestHashes({
    required String operatorId,
    required String locationId,
    required String userId,
    int n = defaultRetentionCount,
  }) {
    if (n <= 0) {
      throw ArgumentError.value(n, 'n', 'must be > 0');
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<PasswordHistoryEntry>>(ctx, (exec) async {
      final rows = await exec.query(
        'select entry_id::text as entry_id, '
        'user_id::text as user_id, '
        'password_hash, set_at '
        'from password_history '
        'where user_id = @user_id::uuid '
        'order by set_at desc '
        'limit @limit',
        parameters: <String, Object?>{
          'user_id': userId,
          'limit': n,
        },
      );
      return rows
          .map(
            (row) => PasswordHistoryEntry(
              entryId: row['entry_id'] as String,
              userId: row['user_id'] as String,
              passwordHash: row['password_hash'] as String,
              setAt: row['set_at'] as DateTime,
            ),
          )
          .toList(growable: false);
    });
  }

  /// Locked decision: keep the latest 5 hashes per user.
  static const int defaultRetentionCount = 5;

  /// DELETE every `password_history` row for [userId] beyond the
  /// latest [n]. Returns the number of rows pruned. Call after every
  /// [recordHash] so the table doesn't grow unbounded.
  Future<int> prune({
    required String operatorId,
    required String locationId,
    required String userId,
    int n = defaultRetentionCount,
  }) {
    if (n <= 0) {
      throw ArgumentError.value(n, 'n', 'must be > 0');
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'delete from password_history '
        'where user_id = @user_id::uuid '
        'and entry_id not in ('
        'select entry_id from password_history '
        'where user_id = @user_id::uuid '
        'order by set_at desc limit @limit'
        ')',
        parameters: <String, Object?>{
          'user_id': userId,
          'limit': n,
        },
      );
    });
  }

  /// GDPR erasure helper: remove every `password_history` row for
  /// [userId]. Caller establishes the
  /// `app.bypass_rls_audit = 'system:gdpr.erasure_executed'` audit
  /// marker via the wrapper's `withSystem` path.
  ///
  /// Code-health L3 (C5): `password_history` is a per-user table
  /// without its own `operator_id` column, so the WHERE adds an
  /// EXISTS subquery against `users` keyed on `(user_id, operator_id)`.
  /// A `withSystem` (BYPASSRLS) DELETE that targets a `userId` from
  /// operator A while the caller believes it lives in operator B
  /// returns 0 affected rows instead of leaking across tenants.
  Future<int> clearForUser({
    required String userId,
    required String operatorId,
    required String adminReason,
  }) {
    return withSystem<int>(
      (exec) async {
        return exec.execute(
          'delete from password_history '
          'where user_id = @user_id::uuid '
          'and exists ('
          '  select 1 from users u '
          '  where u.user_id = @user_id::uuid '
          '  and u.operator_id = @operator_id::uuid'
          ')',
          parameters: <String, Object?>{
            'user_id': userId,
            'operator_id': operatorId,
          },
        );
      },
      reason: adminReason,
    );
  }
}
