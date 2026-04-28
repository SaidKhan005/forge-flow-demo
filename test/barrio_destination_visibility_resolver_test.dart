// Phase 9 live-closeout B18 tests.
//
// Covers the new BarrioDestinationVisibilityResolver hook + the
// production PermissionContextBarrioVisibilityResolver:
//
//   * AlwaysVisibleBarrioDestinationResolver returns true for every
//     destination.
//   * PreviewRoleBarrioVisibilityResolver matches BarrioPreviewRole
//     .isIntendedFor (preserves the legacy chip-driven behavior).
//   * PermissionContextBarrioVisibilityResolver consults the
//     `barrio.destination.<id>` permission key under the live
//     permission context. When the context is null, fallback wins.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_cache.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destination_visibility_resolver.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_preview_role.dart';
import 'package:forge_and_flow/state/permission_context.dart';

void main() {
  final dest = BarrioDestination(
    id: 'forge_and_flow',
    label: 'Forge & Flow',
    description: 'd',
    audiences: const <BarrioAudience>{
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
  );
  final allStaffDest = BarrioDestination(
    id: 'company_handbook',
    label: 'Handbook',
    description: 'd',
    audiences: const <BarrioAudience>{BarrioAudience.allStaff},
  );

  group('AlwaysVisibleBarrioDestinationResolver', () {
    test('returns true for every destination', () {
      const resolver = AlwaysVisibleBarrioDestinationResolver();
      expect(resolver.isVisible(dest), isTrue);
      expect(resolver.isVisible(allStaffDest), isTrue);
    });
  });

  group('PreviewRoleBarrioVisibilityResolver', () {
    test('matches BarrioPreviewRole.isIntendedFor for staff tier', () {
      const resolver = PreviewRoleBarrioVisibilityResolver(
        BarrioPreviewRole.staff,
      );
      // Staff sees only allStaff audiences.
      expect(resolver.isVisible(allStaffDest), isTrue);
      expect(resolver.isVisible(dest), isFalse);
    });

    test('admin tier sees everything', () {
      const resolver = PreviewRoleBarrioVisibilityResolver(
        BarrioPreviewRole.admin,
      );
      expect(resolver.isVisible(dest), isTrue);
      expect(resolver.isVisible(allStaffDest), isTrue);
    });
  });

  group('PermissionContextBarrioVisibilityResolver', () {
    PermissionContext buildContext({
      required Map<String, PermissionEffect> entries,
    }) {
      return PermissionContext(
        snapshot: PermissionSnapshot(
          userId: 'user-1',
          rolesVersion: 7,
          operatorId: 'op-1',
          locationId: 'loc-1',
          evaluatedAt: DateTime.utc(2026, 4, 27, 12),
          entries: entries,
        ),
      );
    }

    test('isVisible true when context allows the derived permission key',
        () {
      final ctx = buildContext(
        entries: <String, PermissionEffect>{
          'barrio.destination.forge_and_flow': PermissionEffect.allow,
        },
      );
      final resolver = PermissionContextBarrioVisibilityResolver(
        context: ctx,
      );
      expect(resolver.isVisible(dest), isTrue);
    });

    test('isVisible false when context denies (or missing — default deny) '
        'the key', () {
      final ctx = buildContext(
        entries: <String, PermissionEffect>{
          'barrio.destination.forge_and_flow': PermissionEffect.deny,
        },
      );
      final resolver = PermissionContextBarrioVisibilityResolver(
        context: ctx,
      );
      expect(resolver.isVisible(dest), isFalse);

      // Default-deny when missing entirely.
      final ctxMissing = buildContext(entries: const {});
      final resolverMissing = PermissionContextBarrioVisibilityResolver(
        context: ctxMissing,
      );
      expect(resolverMissing.isVisible(dest), isFalse);
    });

    test('null context falls back (default fallback = always visible)', () {
      const resolver = PermissionContextBarrioVisibilityResolver(context: null);
      // Acceptance: the dev / demo path without a PermissionContext
      // keeps the existing "see everything" behavior.
      expect(resolver.isVisible(dest), isTrue);
      expect(resolver.isVisible(allStaffDest), isTrue);
    });

    test('null context with custom fallback honors the closure', () {
      final resolver = PermissionContextBarrioVisibilityResolver(
        context: null,
        fallback: (d) => d.id == 'company_handbook',
      );
      expect(resolver.isVisible(dest), isFalse);
      expect(resolver.isVisible(allStaffDest), isTrue);
    });

    test('permissionKeyFor uses the locked prefix', () {
      expect(
        PermissionContextBarrioVisibilityResolver.permissionKeyFor(dest),
        equals('barrio.destination.forge_and_flow'),
      );
      expect(
        PermissionContextBarrioVisibilityResolver.permissionKeyPrefix,
        equals('barrio.destination.'),
      );
    });
  });
}
