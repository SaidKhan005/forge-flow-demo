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
