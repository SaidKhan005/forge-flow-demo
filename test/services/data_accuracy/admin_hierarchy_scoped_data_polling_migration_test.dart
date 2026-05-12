import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _path =
    'db/migrations/202605121200_admin_hierarchy_scoped_data_polling.sql';

void main() {
  group('admin hierarchy scoped data/polling migration', () {
    late String sql;

    setUpAll(() {
      final file = File(_path);
      expect(file.existsSync(), isTrue, reason: 'migration must exist');
      sql = file.readAsStringSync();
    });

    test('adds scoped storage for data accuracy and polling setup', () {
      expect(
        sql,
        contains(
          'create table if not exists public.data_accuracy_scoped_overrides',
        ),
      );
      expect(
        sql,
        contains(
          'create table if not exists public.forge_flow_polling_tier_scope_assignment',
        ),
      );
      expect(
        sql,
        contains("scope_type in ('business', 'org_unit', 'location')"),
      );
      expect(sql, contains('data_accuracy_scoped_override_uq'));
      expect(sql, contains('polling_tier_scope_current_uq'));
    });

    test(
      'effective views resolve selected hierarchy settings per location',
      () {
        expect(sql, contains('public.effective_data_accuracy_settings_v'));
        expect(
          sql,
          contains('public.effective_forge_flow_polling_tier_assignment_v'),
        );
        expect(sql, contains('loc.org_unit_path <@ ou.path'));
        expect(sql, contains("business_scope.scope_type = 'business'"));
        expect(sql, contains("'standard'"));
      },
    );
  });
}
