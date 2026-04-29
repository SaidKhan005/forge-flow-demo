// Phase 9 live-closeout B13 - Postgres recovery-code attempt store.
//
// Backs RecoveryCodeAttemptLimiter with the durable
// `recovery_code_attempts` table. The table has no `operator_id`
// column; its RLS policy filters by `public.app_current_actor_user()`,
// so this store extends [UserScopedRepository] and routes every
// read/write through [withUser]. That sets only `app.user_id`
// transaction-locally and does NOT engage `forge_admin`'s BYPASSRLS —
// the policy itself admits the row. Older rows are pruned
// opportunistically on read.

import '../../../../services/mfa/recovery_code_attempt_limiter.dart';
import 'user_scoped_repository.dart';

class PostgresRecoveryCodeAttemptStore extends UserScopedRepository
    implements RecoveryCodeAttemptStore {
  PostgresRecoveryCodeAttemptStore(super.tenantWrapper);

  @override
  Future<List<DateTime>> recentAttempts({
    required String userId,
    required DateTime now,
    required Duration window,
  }) {
    final cutoff = now.toUtc().subtract(window);
    return withUser<List<DateTime>>(userId, (exec) async {
      await exec.execute(
        'delete from recovery_code_attempts '
        'where user_id = @user_id::uuid '
        'and attempted_at <= @cutoff',
        parameters: <String, Object?>{'user_id': userId, 'cutoff': cutoff},
      );
      final rows = await exec.query(
        'select attempted_at from recovery_code_attempts '
        'where user_id = @user_id::uuid '
        'and attempted_at > @cutoff '
        'order by attempted_at asc',
        parameters: <String, Object?>{'user_id': userId, 'cutoff': cutoff},
      );
      return rows
          .map((row) => row['attempted_at'])
          .whereType<DateTime>()
          .map((value) => value.toUtc())
          .toList(growable: false);
    });
  }

  @override
  Future<void> recordAttempt({required String userId, required DateTime at}) {
    return withUser<void>(userId, (exec) async {
      await exec.execute(
        'insert into recovery_code_attempts (user_id, attempted_at) '
        'values (@user_id::uuid, @attempted_at)',
        parameters: <String, Object?>{
          'user_id': userId,
          'attempted_at': at.toUtc(),
        },
      );
    });
  }
}
