import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('feature flag sentinel migration grants runtime read access', () {
    final sql = File(
      'db/migrations/202605072000_feature_flags_sentinel_operator.sql',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

    expect(
      sql,
      contains(
        'grant execute on function '
        'public.feature_flag_system_wide_operator_id() to service_role',
      ),
    );
    expect(
      sql,
      contains(
        'grant execute on function '
        'public.feature_flag_system_wide_operator_id() to forge_admin',
      ),
    );
    expect(
      sql,
      contains(
        'grant select on public.feature_flag_scope_sentinels '
        'to service_role, forge_admin',
      ),
      reason: 'The SQL function reads the sentinel table as the caller.',
    );
  });
}
