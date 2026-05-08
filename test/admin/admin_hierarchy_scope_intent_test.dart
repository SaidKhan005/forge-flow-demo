import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';

void main() {
  group('AdminHierarchyScopeIntent', () {
    test('builds stable business scope labels and cache keys', () {
      const scope = AdminHierarchyScopeIntent.business(
        operatorId: 'op-1',
        operatorName: 'Demo Diner Co.',
        effectiveValueLabel: 'Manual wage mix',
        allowedActionsLabel: 'Can edit',
      );

      expect(scope.scopeType, AdminHierarchyScopeType.business);
      expect(scope.cacheKey, 'op-1|business||');
      expect(scope.displayLabel, 'Demo Diner Co.');
      expect(scope.inheritanceLabel, 'Set at this scope');
      expect(scope.effectiveValueLabel, 'Manual wage mix');
      expect(scope.allowedActionsLabel, 'Can edit');
      expect(scope.matches(operatorId: 'op-1', locationId: 'loc-1'), isTrue);
    });

    test('builds org-unit scope inheritance labels', () {
      const scope = AdminHierarchyScopeIntent.orgUnit(
        operatorId: 'op-1',
        orgUnitId: 'ou-north',
        operatorName: 'Demo Diner Co.',
        orgUnitName: 'North Region',
        valueState: AdminHierarchyScopeValueState.inheritedFromBusiness,
        inheritedFromLabel: 'business',
        hierarchyPath: <String>['Canada'],
      );

      expect(scope.cacheKey, 'op-1|org_unit|ou-north|');
      expect(scope.displayLabel, 'Demo Diner Co. / Canada / North Region');
      expect(scope.inheritanceLabel, 'Inherited from business');
      expect(scope.matches(operatorId: 'op-1', orgUnitId: 'ou-north'), isTrue);
      expect(scope.matches(operatorId: 'op-1', orgUnitId: 'ou-south'), isFalse);
    });

    test(
      'converts legacy operator-location scopes for handoff compatibility',
      () {
        const legacy = AdminOperatorLocationScopeIntent(
          operatorId: 'op-1',
          locationId: 'loc-1',
          operatorName: 'Demo Diner Co.',
          locationName: 'Yorkville',
        );

        final hierarchy = legacy.toHierarchyScope();

        expect(hierarchy.scopeType, AdminHierarchyScopeType.location);
        expect(hierarchy.cacheKey, 'op-1|location||loc-1');
        expect(hierarchy.displayLabel, 'Demo Diner Co. / Yorkville');
        expect(hierarchy.inheritanceLabel, 'Location only');
        expect(hierarchy.toOperatorLocationScope(), legacy);
      },
    );

    test('route intent exposes one effective hierarchy scope', () {
      const legacy = AdminOperatorLocationScopeIntent(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      const routeIntent = AdminRouteIntent(
        routeId: 'data-accuracy',
        operatorLocationScope: legacy,
      );

      expect(
        routeIntent.effectiveHierarchyScope?.scopeType,
        AdminHierarchyScopeType.location,
      );
      expect(routeIntent.effectiveHierarchyScope?.locationId, 'loc-1');
    });
  });
}
