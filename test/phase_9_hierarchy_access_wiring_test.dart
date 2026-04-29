// Phase 9 hierarchy access wiring migration contract.
//
// This is intentionally SQL-text level: it keeps the Phase 9 scalability
// docs honest by ensuring the tail migration exposes org-unit scoped auth
// grants and the materialized effective-location lookup the runtime reads.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    'db/migrations/202604290001_phase_9_hierarchy_access_wiring.sql',
  ).readAsStringSync();

  group('Phase 9 hierarchy access wiring migration', () {
    test('attaches locations to org_units with denormalized paths', () {
      expect(
        migration,
        contains('add column if not exists parent_org_unit_id'),
      );
      expect(migration, contains('add column if not exists org_unit_path'));
      expect(migration, contains('locations_parent_org_unit_fk'));
      expect(migration, contains('locations_org_unit_path_gist_idx'));
      expect(migration, contains('set_location_org_unit_path'));
    });

    test('allows org-unit scoped user roles and invites', () {
      expect(
        migration,
        contains(
          "check (scope_type in ('operator_wide', 'org_unit', 'location'))",
        ),
      );
      expect(migration, contains('add column if not exists org_unit_id'));
      expect(migration, contains('user_roles_scope_payload_check'));
      expect(migration, contains('auth_invites_scope_payload_check'));
      expect(migration, contains('auth_invites_operator_org_unit_idx'));
    });

    test('materializes effective locations for permission resolution', () {
      expect(
        migration,
        contains('create table if not exists public.user_effective_locations'),
      );
      expect(migration, contains('source_scope_type text not null'));
      expect(migration, contains("ur.scope_type = 'operator_wide'"));
      expect(migration, contains("ur.scope_type = 'location'"));
      expect(migration, contains("ur.scope_type = 'org_unit'"));
      expect(migration, contains('loc.org_unit_path <@ ou.path'));
      expect(migration, contains('refresh_user_effective_locations'));
      expect(migration, contains('user_roles_refresh_effective_locations'));
    });

    test('keeps tenant RLS wrapper discipline on effective-location cache', () {
      expect(migration, contains('enable row level security'));
      expect(
        migration,
        contains('using (operator_id = public.app_current_operator())'),
      );
      expect(
        migration,
        contains('with check (operator_id = public.app_current_operator())'),
      );
    });
  });
}
