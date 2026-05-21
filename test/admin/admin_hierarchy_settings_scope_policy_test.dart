import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/models/admin_hierarchy_settings_scope_policy.dart';

void main() {
  group('AdminHierarchySettingsScopePolicy', () {
    const dataAccuracy = AdminHierarchySettingsScopePolicy(
      AdminHierarchySettingsSurface.dataAccuracy,
    );
    const pollingPricing = AdminHierarchySettingsScopePolicy(
      AdminHierarchySettingsSurface.pollingPricing,
    );

    test('decorates business data accuracy scope for location-row review', () {
      const raw = AdminHierarchyScopeIntent.business(
        operatorId: 'op-1',
        operatorName: 'Demo Diner Co.',
        allowedActionsLabel: 'Editable',
      );

      final scope = dataAccuracy.decorate(raw, editingEnabled: true);

      expect(scope.inheritanceLabel, 'Set at this scope');
      expect(scope.effectiveValueLabel, 'Business scope');
      expect(scope.allowedActionsLabel, 'Review selected scope');
      expect(
        dataAccuracy.allowsLocationMutation(scope, editingEnabled: true),
        isFalse,
      );
      expect(
        dataAccuracy.includesOperatorLocation(
          scope,
          operatorId: 'op-1',
          locationId: 'loc-1',
        ),
        isTrue,
      );
      expect(
        dataAccuracy.includesOperatorLocation(
          scope,
          operatorId: 'op-2',
          locationId: 'loc-1',
        ),
        isFalse,
      );
    });

    test('decorates org-unit polling scope for selected-scope assignment', () {
      const raw = AdminHierarchyScopeIntent.orgUnit(
        operatorId: 'op-1',
        orgUnitId: 'ou-north',
        operatorName: 'Demo Diner Co.',
        orgUnitName: 'North Region',
      );

      final scope = pollingPricing.decorate(raw, editingEnabled: true);

      expect(scope.inheritanceLabel, 'Set at this scope');
      expect(scope.effectiveValueLabel, 'Org unit scope');
      expect(scope.allowedActionsLabel, 'Assign selected scope');
      expect(
        pollingPricing.includesOperatorLocation(
          scope,
          operatorId: 'op-1',
          locationId: 'loc-1',
        ),
        isFalse,
      );
      expect(
        pollingPricing.restrictionCopy(scope),
        contains('covered locations inherit'),
      );
    });

    test('allows existing no-scope and location-scope mutations only', () {
      const raw = AdminHierarchyScopeIntent.location(
        operatorId: 'op-1',
        locationId: 'loc-1',
        operatorName: 'Demo Diner Co.',
        locationName: 'Yorkville',
      );
      final scope = pollingPricing.decorate(raw, editingEnabled: true);

      expect(scope.inheritanceLabel, 'Location only');
      expect(scope.effectiveValueLabel, 'Per-location tier assignment');
      expect(scope.allowedActionsLabel, 'Location controls');
      expect(
        pollingPricing.allowsLocationMutation(scope, editingEnabled: true),
        isTrue,
      );
      expect(
        pollingPricing.allowsLocationMutation(null, editingEnabled: true),
        isTrue,
      );
      expect(
        pollingPricing.allowsLocationMutation(scope, editingEnabled: false),
        isFalse,
      );
    });
  });
}
