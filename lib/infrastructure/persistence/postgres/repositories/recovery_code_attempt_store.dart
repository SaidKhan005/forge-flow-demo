// Phase 9 live-closeout B13 - Postgres recovery-code attempt store.
//
// Backs RecoveryCodeAttemptLimiter with the durable
// `recovery_code_attempts` table. The limiter interface is user-scoped, so
// this store uses the narrow system path: no operator data is returned, and
// older rows are pruned opportunistically on read.

import '../../../../services/mfa/recovery_code_attempt_limiter.dart';
import '../operator_scoped_repository.dart';

class PostgresRecoveryCodeAttemptStore extends OperatorScopedRepository
    implements RecoveryCodeAttemptStore {
  PostgresRecoveryCodeAttemptStore(super.tenantWrapper);

  @override
  Future<List<DateTime>> recentAttempts({
    required String userId,
    required DateTime now,
    required Duration window,
  }) {
    final cutoff = now.toUtc().subtract(window);
    return withSystem<List<DateTime>>((exec) async {
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
    }, reason: 'auth.recovery_code_attempt_read');
  }

  @override
  Future<void> recordAttempt({required String userId, required DateTime at}) {
    return withSystem<void>((exec) async {
      await exec.execute(
        'insert into recovery_code_attempts (user_id, attempted_at) '
        'values (@user_id::uuid, @attempted_at)',
        parameters: <String, Object?>{
          'user_id': userId,
          'attempted_at': at.toUtc(),
        },
      );
    }, reason: 'auth.recovery_code_attempt_record');
  }
}
