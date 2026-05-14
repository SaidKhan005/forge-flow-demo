// Wave 2 R-1L - PermissionKeyMetadata catalog tests.
//
// Coverage:
//   1. Every key in PermissionKeys.all carries a metadata entry with
//      non-empty productLabel + categoryLabel.
//   2. scope_kind is one of org_wide / location_scoped / either.
//   3. The metadata mirror agrees with the validator's
//      kOrgWidePermissionKeys list (no drift between schema-side mirror
//      and Q-4 advisory tables).
//   4. The metadata mirror agrees with kViewRequiredForWrite —
//      every (write -> view) pair the validator advises about is
//      already an `implies` edge in the metadata catalog.
//   5. expandImplies walks the imply graph recursively and is
//      cycle-safe.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_key_metadata.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/services/auth/custom_role_validator.dart';

void main() {
  group('PermissionKeyMetadataCatalog backfill coverage', () {
    test(
      'every key in PermissionKeys.all has a metadata entry with '
      'non-empty productLabel + categoryLabel',
      () {
        for (final key in PermissionKeys.all) {
          final meta = PermissionKeyMetadataCatalog.byKey[key];
          expect(
            meta,
            isNotNull,
            reason:
                'PermissionKeys.all contains $key but '
                'PermissionKeyMetadataCatalog.byKey has no entry. '
                'Add a PermissionKeyMetadata row to '
                'lib/auth/permission_key_metadata.dart.',
          );
          expect(
            meta!.productLabel,
            isNotEmpty,
            reason: '$key has empty productLabel',
          );
          expect(
            meta.categoryLabel,
            isNotEmpty,
            reason: '$key has empty categoryLabel',
          );
        }
      },
    );

    // Wave 2 R-2L — every metadata entry MUST carry a Title Case English
    // humanLabel per memory/project_ux_writing_standard.md. The label is
    // rendered in the R-2L role editor + permission explainer surfaces
    // in place of the raw dotted key.
    test(
      'every key in PermissionKeys.all has a non-empty humanLabel '
      'with no underscores (R-2L UX naming standard)',
      () {
        for (final key in PermissionKeys.all) {
          final meta = PermissionKeyMetadataCatalog.byKey[key];
          expect(meta, isNotNull, reason: 'no metadata for $key');
          expect(
            meta!.humanLabel,
            isNotEmpty,
            reason:
                '$key has an empty humanLabel. Set a Title Case '
                'English label per memory/project_ux_writing_standard.md.',
          );
          expect(
            meta.humanLabel.contains('_'),
            isFalse,
            reason:
                '$key humanLabel "\${meta.humanLabel}" contains an '
                'underscore. Operator-facing labels must be Title Case '
                'English with spaces; no underscores or engineering '
                'jargon.',
          );
        }
      },
    );

    test(
      'every key flagged org_wide in the metadata mirror is also '
      'listed in kOrgWidePermissionKeys (validator + schema agree)',
      () {
        // The validator's kOrgWidePermissionKeys is the source the
        // backfill cribs from; if drift happens between the two
        // tables the schema and the UI will disagree about which
        // keys reject location-scoped grants.
        final metaOrgWide = <String>{
          for (final entry in PermissionKeyMetadataCatalog.byKey.entries)
            if (entry.value.scopeKind == PermissionScopeKind.orgWide)
              entry.key,
        };
        for (final key in kOrgWidePermissionKeys) {
          expect(
            metaOrgWide.contains(key),
            isTrue,
            reason:
                'validator says $key is org-wide but metadata mirror '
                'says scopeKind = ${PermissionKeyMetadataCatalog.byKey[key]?.scopeKind}',
          );
        }
      },
    );

    test(
      'every kViewRequiredForWrite pair appears as an implies edge in '
      'the metadata mirror',
      () {
        for (final entry in kViewRequiredForWrite.entries) {
          final write = entry.key;
          final view = entry.value;
          final meta = PermissionKeyMetadataCatalog.byKey[write];
          expect(meta, isNotNull, reason: 'no metadata for $write');
          expect(
            meta!.implies,
            contains(view),
            reason:
                'validator says $write requires view $view but '
                'metadata mirror has implies = ${meta.implies}',
          );
        }
      },
    );

    test('scope kinds round-trip to SQL values', () {
      expect(PermissionScopeKind.orgWide.sqlValue, equals('org_wide'));
      expect(
        PermissionScopeKind.locationScoped.sqlValue,
        equals('location_scoped'),
      );
      expect(PermissionScopeKind.either.sqlValue, equals('either'));
    });
  });

  // Wave 2 RP-9 (2026-05-14) — Default Role Catalog admin permission
  // keys. The two keys gate the F&F-internal
  // `default_role_catalog_admin_screen.dart` surface; the metadata mirror
  // MUST classify them as org-wide (publishing a default catalog version
  // is a global F&F-deployment-wide event) and `edit` MUST imply `view`.
  group('Wave 2 RP-9 default catalog admin permission keys', () {
    test(
      'team.roles.default_catalog.view + .edit are registered with '
      'org-wide scope, the team product label, and the Team management '
      'category',
      () {
        for (final key in const <String>[
          'team.roles.default_catalog.view',
          'team.roles.default_catalog.edit',
        ]) {
          final meta = PermissionKeyMetadataCatalog.byKey[key];
          expect(meta, isNotNull, reason: 'no metadata for $key');
          expect(meta!.productLabel, equals('team'));
          expect(meta.categoryLabel, equals('Team management'));
          expect(
            meta.scopeKind,
            equals(PermissionScopeKind.orgWide),
            reason:
                '$key gates a global F&F-deployment-wide action; '
                'location-scoped grants are nonsensical.',
          );
          expect(
            meta.humanLabel,
            isNotEmpty,
            reason: '$key has empty humanLabel',
          );
        }
      },
    );

    test(
      'team.roles.default_catalog.edit implies '
      'team.roles.default_catalog.view (view-required-for-write chain)',
      () {
        final meta = PermissionKeyMetadataCatalog.byKey[
          'team.roles.default_catalog.edit'
        ];
        expect(meta, isNotNull);
        expect(
          meta!.implies,
          contains('team.roles.default_catalog.view'),
          reason:
              'edit MUST imply view so the role editor and resolver auto-'
              'grant read access when the edit key is granted.',
        );
      },
    );

    test(
      'expandImplies on team.roles.default_catalog.edit returns both '
      'keys',
      () {
        final result = PermissionKeyMetadataCatalog.expandImplies(
          const <String>['team.roles.default_catalog.edit'],
        );
        expect(
          result,
          equals(<String>{
            'team.roles.default_catalog.edit',
            'team.roles.default_catalog.view',
          }),
        );
      },
    );
  });

  group('PermissionKeyMetadataCatalog.expandImplies', () {
    test('returns the starting set when no key has implies edges', () {
      // barrio.handbook.view has no implies edges.
      final result = PermissionKeyMetadataCatalog.expandImplies(
        const <String>['barrio.handbook.view'],
      );
      expect(result, equals(<String>{'barrio.handbook.view'}));
    });

    test('expands single-hop implies (team.users.invite -> team.users.view)',
        () {
      final result = PermissionKeyMetadataCatalog.expandImplies(
        const <String>['team.users.invite'],
      );
      expect(
        result,
        equals(<String>{'team.users.invite', 'team.users.view'}),
      );
    });

    test('expands multi-key starting set (deduplicates by visited set)', () {
      final result = PermissionKeyMetadataCatalog.expandImplies(
        const <String>['team.users.invite', 'team.users.deactivate'],
      );
      expect(
        result,
        equals(<String>{
          'team.users.invite',
          'team.users.deactivate',
          'team.users.view',
        }),
      );
    });

    test('expands forgeflow edit -> view chain', () {
      final result = PermissionKeyMetadataCatalog.expandImplies(
        const <String>['forgeflow.target_cycle.replace'],
      );
      expect(
        result,
        equals(<String>{
          'forgeflow.target_cycle.replace',
          'forgeflow.target_cycle.view',
        }),
      );
    });

    test('terminates safely when the input is empty', () {
      final result = PermissionKeyMetadataCatalog.expandImplies(
        const <String>[],
      );
      expect(result, isEmpty);
    });
  });
}
