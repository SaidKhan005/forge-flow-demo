import 'package:flutter/widgets.dart';

@immutable
class AdminSupportLogFilterIntent {
  const AdminSupportLogFilterIntent({this.operatorId, this.locationId});

  final String? operatorId;
  final String? locationId;

  String get cacheKey => '${operatorId ?? ''}|${locationId ?? ''}';

  @override
  bool operator ==(Object other) {
    return other is AdminSupportLogFilterIntent &&
        other.operatorId == operatorId &&
        other.locationId == locationId;
  }

  @override
  int get hashCode => Object.hash(operatorId, locationId);
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
  });

  final String routeId;
  final AdminSupportLogFilterIntent? supportLogFilter;
  final AdminOperatorLocationScopeIntent? operatorLocationScope;
}

class AdminRouteHandoff extends InheritedWidget {
  const AdminRouteHandoff({
    super.key,
    required this.selectedRouteId,
    required this.onSelectRoute,
    required super.child,
    this.supportLogFilter,
    this.operatorLocationScope,
  });

  final String selectedRouteId;
  final AdminSupportLogFilterIntent? supportLogFilter;
  final AdminOperatorLocationScopeIntent? operatorLocationScope;
  final ValueChanged<AdminRouteIntent> onSelectRoute;

  static AdminRouteHandoff? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AdminRouteHandoff>();
  }

  @override
  bool updateShouldNotify(AdminRouteHandoff oldWidget) {
    return selectedRouteId != oldWidget.selectedRouteId ||
        supportLogFilter != oldWidget.supportLogFilter ||
        operatorLocationScope != oldWidget.operatorLocationScope;
  }
}
