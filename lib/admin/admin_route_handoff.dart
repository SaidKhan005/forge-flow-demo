import 'package:flutter/widgets.dart';

@immutable
class AdminSupportLogFilterIntent {
  const AdminSupportLogFilterIntent({
    this.operatorId,
    this.locationId,
    this.hierarchyScope,
  });

  factory AdminSupportLogFilterIntent.fromHierarchyScope(
    AdminHierarchyScopeIntent scope,
  ) {
    return AdminSupportLogFilterIntent(
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      hierarchyScope: scope,
    );
  }

  final String? operatorId;
  final String? locationId;
  final AdminHierarchyScopeIntent? hierarchyScope;

  String? get effectiveOperatorId => hierarchyScope?.operatorId ?? operatorId;
  String? get effectiveLocationId => hierarchyScope?.locationId ?? locationId;

  AdminHierarchyScopeIntent? get effectiveHierarchyScope {
    final scope = hierarchyScope;
    if (scope != null) return scope;
    final scopedOperatorId = operatorId;
    if (scopedOperatorId == null || scopedOperatorId.isEmpty) return null;
    final scopedLocationId = locationId;
    if (scopedLocationId == null || scopedLocationId.isEmpty) {
      return AdminHierarchyScopeIntent.business(operatorId: scopedOperatorId);
    }
    return AdminHierarchyScopeIntent.location(
      operatorId: scopedOperatorId,
      locationId: scopedLocationId,
    );
  }

  String get cacheKey =>
      hierarchyScope?.cacheKey ?? '${operatorId ?? ''}|${locationId ?? ''}';

  @override
  bool operator ==(Object other) {
    return other is AdminSupportLogFilterIntent &&
        other.operatorId == operatorId &&
        other.locationId == locationId &&
        other.hierarchyScope == hierarchyScope;
  }

  @override
  int get hashCode => Object.hash(operatorId, locationId, hierarchyScope);
}

enum AdminHierarchyScopeType {
  business,
  orgUnit,
  location;

  String get label {
    switch (this) {
      case AdminHierarchyScopeType.business:
        return 'Business';
      case AdminHierarchyScopeType.orgUnit:
        return 'Org unit';
      case AdminHierarchyScopeType.location:
        return 'Location';
    }
  }

  String get routeValue {
    switch (this) {
      case AdminHierarchyScopeType.business:
        return 'business';
      case AdminHierarchyScopeType.orgUnit:
        return 'org_unit';
      case AdminHierarchyScopeType.location:
        return 'location';
    }
  }
}

enum AdminHierarchyScopeValueState {
  inheritedFromBusiness,
  inheritedFromOrgUnit,
  setAtScope,
  overriddenAtChildScope,
  locationOnly,
}

@immutable
class AdminHierarchyScopeIntent {
  const AdminHierarchyScopeIntent({
    required this.operatorId,
    required this.scopeType,
    this.orgUnitId,
    this.locationId,
    this.operatorName,
    this.orgUnitName,
    this.locationName,
    this.hierarchyPath = const <String>[],
    this.valueState = AdminHierarchyScopeValueState.setAtScope,
    this.inheritedFromLabel,
    this.effectiveValueLabel,
    this.allowedActionsLabel,
  }) : assert(
         scopeType != AdminHierarchyScopeType.orgUnit || orgUnitId != null,
         'orgUnit scopes require orgUnitId',
       ),
       assert(
         scopeType != AdminHierarchyScopeType.location || locationId != null,
         'location scopes require locationId',
       );

  const AdminHierarchyScopeIntent.business({
    required String operatorId,
    String? operatorName,
    AdminHierarchyScopeValueState valueState =
        AdminHierarchyScopeValueState.setAtScope,
    String? inheritedFromLabel,
    String? effectiveValueLabel,
    String? allowedActionsLabel,
  }) : this(
         operatorId: operatorId,
         scopeType: AdminHierarchyScopeType.business,
         operatorName: operatorName,
         valueState: valueState,
         inheritedFromLabel: inheritedFromLabel,
         effectiveValueLabel: effectiveValueLabel,
         allowedActionsLabel: allowedActionsLabel,
       );

  const AdminHierarchyScopeIntent.orgUnit({
    required String operatorId,
    required String orgUnitId,
    String? operatorName,
    String? orgUnitName,
    List<String> hierarchyPath = const <String>[],
    AdminHierarchyScopeValueState valueState =
        AdminHierarchyScopeValueState.setAtScope,
    String? inheritedFromLabel,
    String? effectiveValueLabel,
    String? allowedActionsLabel,
  }) : this(
         operatorId: operatorId,
         scopeType: AdminHierarchyScopeType.orgUnit,
         orgUnitId: orgUnitId,
         operatorName: operatorName,
         orgUnitName: orgUnitName,
         hierarchyPath: hierarchyPath,
         valueState: valueState,
         inheritedFromLabel: inheritedFromLabel,
         effectiveValueLabel: effectiveValueLabel,
         allowedActionsLabel: allowedActionsLabel,
       );

  const AdminHierarchyScopeIntent.location({
    required String operatorId,
    required String locationId,
    String? operatorName,
    String? orgUnitId,
    String? orgUnitName,
    String? locationName,
    List<String> hierarchyPath = const <String>[],
    AdminHierarchyScopeValueState valueState =
        AdminHierarchyScopeValueState.setAtScope,
    String? inheritedFromLabel,
    String? effectiveValueLabel,
    String? allowedActionsLabel,
  }) : this(
         operatorId: operatorId,
         scopeType: AdminHierarchyScopeType.location,
         orgUnitId: orgUnitId,
         locationId: locationId,
         operatorName: operatorName,
         orgUnitName: orgUnitName,
         locationName: locationName,
         hierarchyPath: hierarchyPath,
         valueState: valueState,
         inheritedFromLabel: inheritedFromLabel,
         effectiveValueLabel: effectiveValueLabel,
         allowedActionsLabel: allowedActionsLabel,
       );

  AdminHierarchyScopeIntent.fromOperatorLocation(
    AdminOperatorLocationScopeIntent scope,
  ) : this(
        operatorId: scope.operatorId,
        scopeType: scope.locationId == null
            ? AdminHierarchyScopeType.business
            : AdminHierarchyScopeType.location,
        locationId: scope.locationId,
        operatorName: scope.operatorName,
        locationName: scope.locationName,
        valueState: scope.locationId == null
            ? AdminHierarchyScopeValueState.setAtScope
            : AdminHierarchyScopeValueState.locationOnly,
      );

  final String operatorId;
  final AdminHierarchyScopeType scopeType;
  final String? orgUnitId;
  final String? locationId;
  final String? operatorName;
  final String? orgUnitName;
  final String? locationName;
  final List<String> hierarchyPath;
  final AdminHierarchyScopeValueState valueState;
  final String? inheritedFromLabel;
  final String? effectiveValueLabel;
  final String? allowedActionsLabel;

  String get cacheKey =>
      '$operatorId|${scopeType.routeValue}|${orgUnitId ?? ''}|${locationId ?? ''}';

  String get displayLabel {
    final labels = <String>[];
    final op = _clean(operatorName);
    if (op != null) labels.add(op);
    labels.addAll(hierarchyPath.map(_clean).whereType<String>());
    final org = _clean(orgUnitName);
    if (org != null && !labels.contains(org)) labels.add(org);
    final location = _clean(locationName);
    if (location != null && !labels.contains(location)) labels.add(location);
    if (labels.isEmpty) {
      switch (scopeType) {
        case AdminHierarchyScopeType.business:
          return 'Selected business';
        case AdminHierarchyScopeType.orgUnit:
          return 'Selected org unit';
        case AdminHierarchyScopeType.location:
          return 'Selected location';
      }
    }
    return labels.join(' / ');
  }

  String get inheritanceLabel {
    switch (valueState) {
      case AdminHierarchyScopeValueState.inheritedFromBusiness:
        return inheritedFromLabel == null
            ? 'Inherited from business'
            : 'Inherited from $inheritedFromLabel';
      case AdminHierarchyScopeValueState.inheritedFromOrgUnit:
        return inheritedFromLabel == null
            ? 'Inherited from org unit'
            : 'Inherited from $inheritedFromLabel';
      case AdminHierarchyScopeValueState.setAtScope:
        return 'Set at this scope';
      case AdminHierarchyScopeValueState.overriddenAtChildScope:
        return inheritedFromLabel == null
            ? 'Overridden at child scope'
            : 'Overridden at $inheritedFromLabel';
      case AdminHierarchyScopeValueState.locationOnly:
        return 'Location only';
    }
  }

  bool get isBusinessScope => scopeType == AdminHierarchyScopeType.business;
  bool get isOrgUnitScope => scopeType == AdminHierarchyScopeType.orgUnit;
  bool get isLocationScope => scopeType == AdminHierarchyScopeType.location;

  AdminOperatorLocationScopeIntent toOperatorLocationScope() {
    return AdminOperatorLocationScopeIntent(
      operatorId: operatorId,
      locationId: locationId,
      operatorName: operatorName,
      locationName: locationName,
    );
  }

  bool matches({
    required String operatorId,
    String? orgUnitId,
    String? locationId,
  }) {
    if (this.operatorId != operatorId) return false;
    switch (scopeType) {
      case AdminHierarchyScopeType.business:
        return true;
      case AdminHierarchyScopeType.orgUnit:
        return this.orgUnitId == orgUnitId;
      case AdminHierarchyScopeType.location:
        return this.locationId == locationId;
    }
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  @override
  bool operator ==(Object other) {
    return other is AdminHierarchyScopeIntent &&
        other.operatorId == operatorId &&
        other.scopeType == scopeType &&
        other.orgUnitId == orgUnitId &&
        other.locationId == locationId &&
        other.operatorName == operatorName &&
        other.orgUnitName == orgUnitName &&
        other.locationName == locationName &&
        _listEquals(other.hierarchyPath, hierarchyPath) &&
        other.valueState == valueState &&
        other.inheritedFromLabel == inheritedFromLabel &&
        other.effectiveValueLabel == effectiveValueLabel &&
        other.allowedActionsLabel == allowedActionsLabel;
  }

  @override
  int get hashCode => Object.hash(
    operatorId,
    scopeType,
    orgUnitId,
    locationId,
    operatorName,
    orgUnitName,
    locationName,
    Object.hashAll(hierarchyPath),
    valueState,
    inheritedFromLabel,
    effectiveValueLabel,
    allowedActionsLabel,
  );
}

@immutable
class AdminOperatorLocationScopeIntent {
  const AdminOperatorLocationScopeIntent({
    required this.operatorId,
    this.locationId,
    this.operatorName,
    this.locationName,
  });

  final String operatorId;
  final String? locationId;
  final String? operatorName;
  final String? locationName;

  String get cacheKey => '$operatorId|${locationId ?? ''}';

  AdminHierarchyScopeIntent toHierarchyScope() {
    return AdminHierarchyScopeIntent.fromOperatorLocation(this);
  }

  String get displayLabel {
    final op = _clean(operatorName) ?? 'Selected operator';
    final loc = _clean(locationName);
    if (loc == null) return op;
    return '$op / $loc';
  }

  bool matches({required String operatorId, String? locationId}) {
    if (this.operatorId != operatorId) return false;
    final scopedLocationId = this.locationId;
    return scopedLocationId == null || scopedLocationId == locationId;
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  @override
  bool operator ==(Object other) {
    return other is AdminOperatorLocationScopeIntent &&
        other.operatorId == operatorId &&
        other.locationId == locationId &&
        other.operatorName == operatorName &&
        other.locationName == locationName;
  }

  @override
  int get hashCode =>
      Object.hash(operatorId, locationId, operatorName, locationName);
}

@immutable
class AdminRouteIntent {
  const AdminRouteIntent({
    required this.routeId,
    this.supportLogFilter,
    this.operatorLocationScope,
    this.hierarchyScope,
  }) : assert(
         hierarchyScope == null || operatorLocationScope == null,
         'Use hierarchyScope or operatorLocationScope, not both',
       );

  final String routeId;
  final AdminSupportLogFilterIntent? supportLogFilter;
  final AdminOperatorLocationScopeIntent? operatorLocationScope;
  final AdminHierarchyScopeIntent? hierarchyScope;

  AdminHierarchyScopeIntent? get effectiveHierarchyScope {
    return hierarchyScope ?? operatorLocationScope?.toHierarchyScope();
  }
}

class AdminRouteHandoff extends InheritedWidget {
  const AdminRouteHandoff({
    super.key,
    required this.selectedRouteId,
    required this.onSelectRoute,
    required super.child,
    this.supportLogFilter,
    this.operatorLocationScope,
    this.hierarchyScope,
  });

  final String selectedRouteId;
  final AdminSupportLogFilterIntent? supportLogFilter;
  final AdminOperatorLocationScopeIntent? operatorLocationScope;
  final AdminHierarchyScopeIntent? hierarchyScope;
  final ValueChanged<AdminRouteIntent> onSelectRoute;

  AdminHierarchyScopeIntent? get effectiveHierarchyScope {
    return hierarchyScope ?? operatorLocationScope?.toHierarchyScope();
  }

  static AdminRouteHandoff? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AdminRouteHandoff>();
  }

  @override
  bool updateShouldNotify(AdminRouteHandoff oldWidget) {
    return selectedRouteId != oldWidget.selectedRouteId ||
        supportLogFilter != oldWidget.supportLogFilter ||
        operatorLocationScope != oldWidget.operatorLocationScope ||
        hierarchyScope != oldWidget.hierarchyScope;
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
