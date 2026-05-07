import 'dart:async';

import '../../domain/models/business_scope.dart';
import '../realtime/realtime_event.dart';

abstract class BusinessScopeClient {
  Future<List<BusinessScope>> fetchAccessibleBusinessScopes({
    required String userId,
  });
}

abstract class ActiveBusinessScopeRepository {
  Future<BusinessScope?> getActiveScope(String userId);

  Future<void> saveActiveScope({
    required String userId,
    required BusinessScope scope,
  });

  Future<void> clearActiveScope(String userId);
}

class ActiveBusinessScopeChangeBus {
  ActiveBusinessScopeChangeBus._();

  static final ActiveBusinessScopeChangeBus instance =
      ActiveBusinessScopeChangeBus._();

  final StreamController<BusinessScope> _controller =
      StreamController<BusinessScope>.broadcast();

  Stream<BusinessScope> get changes => _controller.stream;

  void publish(BusinessScope scope) {
    if (!_controller.isClosed) {
      _controller.add(scope);
    }
  }
}

bool isBusinessScopeInvalidationEvent(RealtimeEvent event) {
  final topic = event.topic.toLowerCase();
  if (topic.contains('business_scope') ||
      topic.contains('restaurant_user') ||
      topic.contains('user_role') ||
      topic.contains('role_permission') ||
      topic.contains('org_unit') ||
      topic.contains('effective_location') ||
      topic.contains('locations')) {
    return true;
  }
  final table = event.payload['table']?.toString().toLowerCase();
  return table == 'business_scopes' ||
      table == 'active_business_scopes' ||
      table == 'restaurant_users' ||
      table == 'user_roles' ||
      table == 'roles' ||
      table == 'role_permissions' ||
      table == 'org_units' ||
      table == 'locations' ||
      table == 'user_effective_locations';
}
