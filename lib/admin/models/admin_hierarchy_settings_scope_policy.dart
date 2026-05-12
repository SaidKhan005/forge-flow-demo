import '../admin_route_handoff.dart';

enum AdminHierarchySettingsSurface { dataAccuracy, pollingPricing }

class AdminHierarchySettingsScopePolicy {
  const AdminHierarchySettingsScopePolicy(this.surface);

  final AdminHierarchySettingsSurface surface;

  AdminHierarchyScopeIntent decorate(
    AdminHierarchyScopeIntent scope, {
    required bool editingEnabled,
  }) {
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return AdminHierarchyScopeIntent.business(
          operatorId: scope.operatorId,
          operatorName: scope.operatorName,
          valueState: AdminHierarchyScopeValueState.overriddenAtChildScope,
          inheritedFromLabel: 'location scope',
          effectiveValueLabel: _businessEffectiveLabel,
          allowedActionsLabel: _businessAllowedActionsLabel,
        );
      case AdminHierarchyScopeType.orgUnit:
        return AdminHierarchyScopeIntent.orgUnit(
          operatorId: scope.operatorId,
          orgUnitId: scope.orgUnitId!,
          operatorName: scope.operatorName,
          orgUnitName: scope.orgUnitName,
          hierarchyPath: scope.hierarchyPath,
          valueState: AdminHierarchyScopeValueState.overriddenAtChildScope,
          inheritedFromLabel: 'location scope',
          effectiveValueLabel: _orgUnitEffectiveLabel,
          allowedActionsLabel: _orgUnitAllowedActionsLabel,
        );
      case AdminHierarchyScopeType.location:
        return AdminHierarchyScopeIntent.location(
          operatorId: scope.operatorId,
          locationId: scope.locationId!,
          operatorName: scope.operatorName,
          orgUnitId: scope.orgUnitId,
          orgUnitName: scope.orgUnitName,
          locationName: scope.locationName,
          hierarchyPath: scope.hierarchyPath,
          valueState: AdminHierarchyScopeValueState.locationOnly,
          effectiveValueLabel: _locationEffectiveLabel,
          allowedActionsLabel: editingEnabled
              ? 'Location controls'
              : 'Read-only',
        );
    }
  }

  bool allowsLocationMutation(
    AdminHierarchyScopeIntent? scope, {
    required bool editingEnabled,
  }) {
    if (!editingEnabled) return false;
    if (scope == null) return true;
    return scope.isLocationScope;
  }

  bool isReadOnlyHierarchyScope(AdminHierarchyScopeIntent? scope) {
    return scope != null && !scope.isLocationScope;
  }

  bool includesOperatorLocation(
    AdminHierarchyScopeIntent? scope, {
    required String operatorId,
    required String? locationId,
  }) {
    if (scope == null) return true;
    if (scope.operatorId != operatorId) return false;
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return true;
      case AdminHierarchyScopeType.orgUnit:
        return false;
      case AdminHierarchyScopeType.location:
        return locationId != null && scope.locationId == locationId;
    }
  }

  String? restrictionCopy(AdminHierarchyScopeIntent? scope) {
    if (scope == null || scope.isLocationScope) return null;
    switch (surface) {
      case AdminHierarchySettingsSurface.dataAccuracy:
        if (scope.isBusinessScope) {
          return 'Business scope is a read-only rollup until scoped data accuracy writes land. Select a location in this scope to override covers, wages, or walk-in handling.';
        }
        return 'Org-unit data accuracy editing is disabled until scoped writes land. Select a location in this branch to edit location settings.';
      case AdminHierarchySettingsSurface.pollingPricing:
        if (scope.isBusinessScope) {
          return 'Business scope is a read-only polling rollup until scoped polling assignments land. Select a location in this scope to assign or update a tier.';
        }
        return 'Org-unit polling setup editing is disabled until scoped assignments land. Select a location in this branch to edit the location assignment.';
    }
  }

  String get _businessEffectiveLabel {
    switch (surface) {
      case AdminHierarchySettingsSurface.dataAccuracy:
        return 'Location rollup';
      case AdminHierarchySettingsSurface.pollingPricing:
        return 'Tier assignment rollup';
    }
  }

  String get _orgUnitEffectiveLabel {
    switch (surface) {
      case AdminHierarchySettingsSurface.dataAccuracy:
        return 'Location required';
      case AdminHierarchySettingsSurface.pollingPricing:
        return 'Scoped resolver pending';
    }
  }

  String get _locationEffectiveLabel {
    switch (surface) {
      case AdminHierarchySettingsSurface.dataAccuracy:
        return 'Per-location overrides';
      case AdminHierarchySettingsSurface.pollingPricing:
        return 'Per-location tier assignment';
    }
  }

  String get _businessAllowedActionsLabel {
    switch (surface) {
      case AdminHierarchySettingsSurface.dataAccuracy:
        return 'Select a location to edit';
      case AdminHierarchySettingsSurface.pollingPricing:
        return 'Select a location to assign';
    }
  }

  String get _orgUnitAllowedActionsLabel {
    switch (surface) {
      case AdminHierarchySettingsSurface.dataAccuracy:
        return 'Location required to edit';
      case AdminHierarchySettingsSurface.pollingPricing:
        return 'Location required to assign';
    }
  }
}
