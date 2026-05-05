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
class AdminRouteIntent {
  const AdminRouteIntent({required this.routeId, this.supportLogFilter});

  final String routeId;
  final AdminSupportLogFilterIntent? supportLogFilter;
}

class AdminRouteHandoff extends InheritedWidget {
  const AdminRouteHandoff({
    super.key,
    required this.selectedRouteId,
    required this.onSelectRoute,
    required super.child,
    this.supportLogFilter,
  });

  final String selectedRouteId;
  final AdminSupportLogFilterIntent? supportLogFilter;
  final ValueChanged<AdminRouteIntent> onSelectRoute;

  static AdminRouteHandoff? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AdminRouteHandoff>();
  }

  @override
  bool updateShouldNotify(AdminRouteHandoff oldWidget) {
    return selectedRouteId != oldWidget.selectedRouteId ||
        supportLogFilter != oldWidget.supportLogFilter;
  }
}
