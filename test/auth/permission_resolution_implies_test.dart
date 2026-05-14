// Wave 2 R-1L — PermissionResolver recursive imply walk tests.
//
// The R-1L slice adds an optional `implies` parameter to
// PermissionResolver.resolve / resolveAll. This file pins:
//
//   1. resolveAll auto-grants implied keys when a parent is allowed.
//   2. Implied grants are transitive (multi-hop walks).
//   3. Direct deny rules win over implied allow.
//   4. Imply edges are NEVER traversed through a deny — denies do not
//      propagate at all.
//   5. resolve() single-key path agrees with resolveAll() for the same
//      input (so the snapshot and the admin guard cannot disagree).
//   6. The walk is cycle-safe (terminates even if metadata contains
//      a cycle).
//   7. When `implies` is null or empty the resolver behaves exactly
//      like it did before R-1L (regression guard for the existing
//      Phase 9.6 callsites).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/auth/permission_resolution.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '33333333-3333-3333-3333-333333333333';
const String _userX = '55555555-5555-5555-5555-555555555555';
const String _roleStaff = 'role-staff';

UserRoleGrant _grant({
  String roleId = _roleStaff,
  String scopeType = 'operator_wide',
  String? locationId,
  List<String> effectiveLocationIds = const <String>[],
}) {
  return UserRoleGrant(
    userRoleId: 'ur-1',
    userId: _userX,
    roleId: roleId,
    operatorId: _opA,
    scopeType: scopeType,
    locationId: locationId,
    effectiveLocationIds: effectiveLocationIds,
    validFrom: DateTime.utc(2026, 4, 1),
  );
}

RolePermissionRule _rule({
  String roleId = _roleStaff,
  required String permissionKey,
  PermissionEffect effect = PermissionEffect.allow,
}) {
  return RolePermissionRule(
    roleId: roleId,
    permissionKey: permissionKey,
    effect: effect,
  );
}

void main() {
  final now = DateTime.utc(2026, 5, 14, 12);

  group('PermissionResolver.resolveAll — imply walk', () {
    test('single-hop imply auto-grants the view sibling', () {
      final result = PermissionResolver.resolveAll(
        grants: <UserRoleGrant>[_grant()],
        rules: <RolePermissionRule>[
          _rule(permissionKey: 'team.users.invite'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
        implies: const <String, List<String>>{
          'team.users.invite': <String>['team.users.view'],
        },
      );
      expect(result['team.users.invite'], PermissionEffect.allow);
      expect(result['team.users.view'], PermissionEffect.allow);
    });

    test('multi-hop imply walk is transitive', () {
      // a -> b -> c. Granting `a` allow should pull `b` and `c` in.
      final result = PermissionResolver.resolveAll(
        grants: <UserRoleGrant>[_grant()],
        rules: <RolePermissionRule>[
          _rule(permissionKey: 'a'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
        implies: const <String, List<String>>{
          'a': <String>['b'],
          'b': <String>['c'],
        },
      );
      expect(result['a'], PermissionEffect.allow);
      expect(result['b'], PermissionEffect.allow);
      expect(result['c'], PermissionEffect.allow);
    });

    test('explicit deny on the implied key beats imply-allow', () {
      // Granting `team.users.invite` would normally pull
      // `team.users.view`; but an explicit deny on `team.users.view`
      // keeps it denied.
      final result = PermissionResolver.resolveAll(
        grants: <UserRoleGrant>[_grant()],
        rules: <RolePermissionRule>[
          _rule(permissionKey: 'team.users.invite'),
          _rule(
            permissionKey: 'team.users.view',
            effect: PermissionEffect.deny,
          ),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
        implies: const <String, List<String>>{
          'team.users.invite': <String>['team.users.view'],
        },
      );
      expect(result['team.users.invite'], PermissionEffect.allow);
      expect(result['team.users.view'], PermissionEffect.deny);
    });

    test('deny is NOT propagated through implies', () {
      // `team.users.invite` is denied; its imply edge to
      // `team.users.view` MUST NOT fire (deny stays the safer state
      // and does not pull anything along with it).
      final result = PermissionResolver.resolveAll(
        grants: <UserRoleGrant>[_grant()],
        rules: <RolePermissionRule>[
          _rule(
            permissionKey: 'team.users.invite',
            effect: PermissionEffect.deny,
          ),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
        implies: const <String, List<String>>{
          'team.users.invite': <String>['team.users.view'],
        },
      );
      expect(result['team.users.invite'], PermissionEffect.deny);
      expect(result.containsKey('team.users.view'), isFalse);
    });

    test('cycle in implies map terminates (a -> b -> a)', () {
      final result = PermissionResolver.resolveAll(
        grants: <UserRoleGrant>[_grant()],
        rules: <RolePermissionRule>[
          _rule(permissionKey: 'a'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
        implies: const <String, List<String>>{
          'a': <String>['b'],
          'b': <String>['a'],
        },
      );
      expect(result['a'], PermissionEffect.allow);
      expect(result['b'], PermissionEffect.allow);
    });

    test('null implies is a regression-safe no-op (Phase 9.6 behaviour)',
        () {
      final result = PermissionResolver.resolveAll(
        grants: <UserRoleGrant>[_grant()],
        rules: <RolePermissionRule>[
          _rule(permissionKey: 'forgeflow.shift.view'),
          _rule(
            permissionKey: 'forgeflow.shift.edit',
            effect: PermissionEffect.deny,
          ),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(
        result,
        equals(<String, PermissionEffect>{
          'forgeflow.shift.view': PermissionEffect.allow,
          'forgeflow.shift.edit': PermissionEffect.deny,
        }),
      );
    });

    test('empty implies is treated the same as null', () {
      final result = PermissionResolver.resolveAll(
        grants: <UserRoleGrant>[_grant()],
        rules: <RolePermissionRule>[
          _rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
        implies: const <String, List<String>>{},
      );
      expect(
        result,
        equals(<String, PermissionEffect>{
          'forgeflow.shift.view': PermissionEffect.allow,
        }),
      );
    });
  });

  group('PermissionResolver.resolve — single-key imply walk', () {
    test(
      'resolve() returns allow for an implied key when its parent is '
      'granted',
      () {
        final effect = PermissionResolver.resolve(
          permissionKey: 'team.users.view',
          grants: <UserRoleGrant>[_grant()],
          rules: <RolePermissionRule>[
            _rule(permissionKey: 'team.users.invite'),
          ],
          operatorId: _opA,
          locationId: _locA,
          now: now,
          implies: const <String, List<String>>{
            'team.users.invite': <String>['team.users.view'],
          },
        );
        expect(effect, PermissionEffect.allow);
      },
    );

    test('resolve() returns deny when the implied key has no parent allowed',
        () {
      final effect = PermissionResolver.resolve(
        permissionKey: 'team.users.view',
        grants: <UserRoleGrant>[_grant()],
        rules: <RolePermissionRule>[],
        operatorId: _opA,
        locationId: _locA,
        now: now,
        implies: const <String, List<String>>{
          'team.users.invite': <String>['team.users.view'],
        },
      );
      expect(effect, PermissionEffect.deny);
    });

    test('resolve() honours explicit deny over imply-allow', () {
      final effect = PermissionResolver.resolve(
        permissionKey: 'team.users.view',
        grants: <UserRoleGrant>[_grant()],
        rules: <RolePermissionRule>[
          _rule(permissionKey: 'team.users.invite'),
          _rule(
            permissionKey: 'team.users.view',
            effect: PermissionEffect.deny,
          ),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
        implies: const <String, List<String>>{
          'team.users.invite': <String>['team.users.view'],
        },
      );
      expect(effect, PermissionEffect.deny);
    });

    test(
      'resolve() without implies behaves like Phase 9.6 (regression '
      'guard for legacy callers)',
      () {
        final effect = PermissionResolver.resolve(
          permissionKey: 'team.users.view',
          grants: <UserRoleGrant>[_grant()],
          rules: <RolePermissionRule>[
            _rule(permissionKey: 'team.users.invite'),
          ],
          operatorId: _opA,
          locationId: _locA,
          now: now,
        );
        expect(effect, PermissionEffect.deny);
      },
    );
  });
}
