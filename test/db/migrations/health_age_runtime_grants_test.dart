import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AGE runtime grants let forge_admin execute health cypher probes', () {
    final migration = File(
      'db/migrations/202605021710_phase_11A_health_age_runtime_grants.sql',
    ).readAsStringSync();

    expect(migration, contains("rolname = 'forge_admin'"));
    expect(
      migration,
      contains('grant usage on schema ag_catalog to forge_admin'),
    );
    expect(
      migration,
      contains('grant execute on all functions in schema ag_catalog'),
    );
    expect(migration, contains('grant usage on schema forgeflow'));
    expect(migration, contains('grant select on all tables in schema forgeflow'));
  });
}
