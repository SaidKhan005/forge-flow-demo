// Admin hierarchy lifecycle/access hardening tests.
//
// Offline migration-shape coverage for the additive lifecycle migration.
// Live trigger semantics remain covered by the passive staging hierarchy suite
// in `phase_9_hierarchy_access_wiring_test.dart`; these tests pin the SQL
// contract that inactive org units/locations are excluded from
// `user_effective_locations` materialization and that lifecycle updates refresh
// the cache.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('admin hierarchy lifecycle access hardening migration', () {
    final migrationFile = File(
      'db/migrations/202605131020_admin_hierarchy_lifecycle_access_hardening.sql',
    );

    setUpAll(() {
      expect(migrationFile.existsSync(), isTrue);
    });

    String migration() =>
        migrationFile.readAsStringSync().replaceAll('\r\n', '\n');

    test(
      'adds lifecycle audit stamps and active-only org-unit path uniqueness',
      () {
        final sql = migration();
        expect(sql, contains('add column if not exists created_by uuid null'));
        expect(sql, contains('add column if not exists updated_by uuid null'));
        expect(
          sql,
          contains('drop constraint if exists org_units_operator_id_path_key'),
        );
        expect(sql, contains('org_units_operator_path_active_uq'));
        expect(sql, contains('where deleted_at is null'));
      },
    );

    test('adds direct active target lookup indexes for repository guards', () {
      final sql = migration();
      expect(sql, contains('user_roles_active_location_target_idx'));
      expect(sql, contains('user_roles_active_org_unit_target_idx'));
      expect(sql, contains('auth_invites_active_location_target_idx'));
      expect(sql, contains('auth_invites_active_org_unit_target_idx'));
      expect(sql, contains("where scope_type = 'location'"));
      expect(sql, contains("where scope_type = 'org_unit'"));
      expect(sql, contains('accepted_at is null'));
      expect(sql, contains('revoked_at is null'));
    });

    test(
      'excludes deleted and suspended hierarchy rows from effective access',
      () {
        final sql = migration();
        expect(
          sql,
          contains(
            'create or replace function public.refresh_user_effective_locations',
          ),
        );
        expect(sql, contains('and loc.deleted_at is null'));
        expect(sql, contains('and loc.suspended_at is null'));
        expect(sql, contains('inactive_ancestor.deleted_at is not null'));
        expect(sql, contains('inactive_ancestor.suspended_at is not null'));
        expect(
          sql,
          contains('and loc.org_unit_path <@ inactive_ancestor.path'),
        );
        expect(sql, contains('and ou.deleted_at is null'));
        expect(sql, contains('and ou.suspended_at is null'));
        expect(sql, contains('and ou.id is not null'));
        expect(sql, contains('and loc.org_unit_path <@ ou.path'));
      },
    );

    test('refresh triggers react to suspend and delete lifecycle updates', () {
      final sql = migration();
      expect(
        sql,
        contains(
          'after update of parent_org_unit_id, org_unit_path, suspended_at, deleted_at',
        ),
      );
      expect(
        sql,
        contains('after update of parent_id, path, suspended_at, deleted_at'),
      );
      expect(sql, contains('refresh_user_effective_locations_from_location()'));
      expect(sql, contains('refresh_user_effective_locations_from_org_unit()'));
    });

    test('runs in one transaction and avoids timestamp without time zone', () {
      final sql = migration().toLowerCase();
      expect(sql, contains('begin;'));
      expect(sql, contains('commit;'));
      expect(sql, isNot(contains('timestamp without time zone')));
      expect(sql, isNot(matches(RegExp(r'\btimestamp\b(?!\s*with)'))));
    });
  });
}
