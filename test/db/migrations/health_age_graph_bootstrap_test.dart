import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AGE health graph bootstrap creates the canonical empty graph', () {
    final migration = File(
      'db/migrations/202605021700_phase_11A_health_age_graph_bootstrap.sql',
    ).readAsStringSync();

    expect(migration, contains('create extension if not exists age'));
    expect(migration, contains("where name = 'forgeflow'"));
    expect(migration, contains("ag_catalog.create_graph('forgeflow')"));
    expect(
      migration,
      contains(
        "set_config('search_path', 'ag_catalog,\"\$user\",public', false)",
      ),
    );
  });
}
