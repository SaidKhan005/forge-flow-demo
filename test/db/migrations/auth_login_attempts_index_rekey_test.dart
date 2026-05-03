import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'auth login attempts follow-up keeps lockout lookup and rekeys IP triage',
    () {
      final sql = File(
        'db/migrations/202605021800_hardening_auth_login_attempts_index_rekey.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n').toLowerCase();

      expect(
        sql,
        contains(
          'drop index if exists public.auth_login_attempts_idx_email_hash_time',
        ),
      );
      expect(
        sql,
        contains(
          'on public.auth_login_attempts '
          '(user_email_hash, ip_hash, attempted_at desc)',
        ),
        reason:
            'pre-tenant login lockout lookup still runs by email+IP before '
            'operator scope exists',
      );

      expect(
        sql,
        contains(
          'drop index if exists public.auth_login_attempts_idx_ip_hash_failures',
        ),
      );
      expect(
        sql,
        contains(
          'on public.auth_login_attempts '
          '(operator_id, ip_hash, attempted_at desc)',
        ),
        reason: 'operator-side IP failure triage must lead with operator_id',
      );
      expect(sql, contains('where operator_id is not null'));
      expect(sql, contains("outcome in ('failure','locked')"));
    },
  );
}
