import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('feature flags follow-up migration grants forge_admin runtime access', () {
    final sql = File(
      'db/migrations/202605021600_phase_11A_7_feature_flags_forge_admin_grants.sql',
    ).readAsStringSync().toLowerCase();

    expect(sql, contains("rolname = 'forge_admin'"));
    expect(
      sql,
      contains('grant select, update on public.feature_flags to forge_admin'),
    );
  });
}
