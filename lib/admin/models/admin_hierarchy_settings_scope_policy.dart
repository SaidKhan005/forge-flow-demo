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
          valueState: AdminHierarchyScopeValueState.setAtScope,
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
          valueState: AdminHierarchyScopeValueState.setAtScope,
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
          return 'Pick a location row to apply a data accuracy repair.';
        }
        return 'Pick a location row to apply a data accuracy repair.';
      case AdminHierarchySettingsSurface.pollingPricing:
        if (scope.isBusinessScope) {
          return 'Covered locations inherit this polling setup until a lower scope overrides it.';
        }
        return 'Covered locations inherit this polling setup until a lower scope overrides it.';
    }
  }

  String get _businessEffectiveLabel {
    switch (surface) {
      case AdminHierarchySettingsSurface.dataAccuracy:
        return 'Business scope';
      case AdminHierarchySettingsSurface.pollingPricing:
        return 'Business scope';
    }
  }

  String get _orgUnitEffectiveLabel {
    switch (surface) {
      case AdminHierarchySettingsSurface.dataAccuracy:
        return 'Org unit scope';
      case AdminHierarchySettingsSurface.pollingPricing:
        return 'Org unit scope';
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
        return 'Review';
      case AdminHierarchySettingsSurface.pollingPricing:
        return 'Assign';
    }
  }

  String get _orgUnitAllowedActionsLabel {
    switch (surface) {
      case AdminHierarchySettingsSurface.dataAccuracy:
        return 'Review';
      case AdminHierarchySettingsSurface.pollingPricing:
        return 'Assign';
    }
  }
}
