import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('debug console migration grants forge_admin read-only request access', () {
    final sql = File(
      'db/migrations/202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql',
    ).readAsStringSync().toLowerCase();

    expect(sql, contains("rolname = 'forge_admin'"));
    expect(
      sql,
      contains('grant select on public.proxy_requests to forge_admin'),
    );
    expect(
      sql,
      isNot(contains('grant select, insert, update, delete')),
      reason: 'Debug request-log inspection should stay read-only.',
    );
    expect(
      sql,
      contains('bypassrls skips tenant row policies'),
    );
  });
}
