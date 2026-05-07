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
      topic.contains('restaurant_users') ||
      topic.contains('user_role') ||
      topic.contains('role_permission') ||
      topic.contains('org_unit') ||
      topic.contains('effective_location') ||
      topic.contains('locations')) {
    return true;
  }
  final table = event.payload['table']?.toString().toLowerCase();
  if (table == 'business_scopes' ||
      table == 'active_business_scopes' ||
      table == 'restaurant_users' ||
      table == 'user_roles' ||
      table == 'roles' ||
      table == 'role_permissions' ||
      table == 'org_units' ||
      table == 'locations' ||
      table == 'user_effective_locations') {
    return true;
  }
  // Theme H#9 — explicit insert/delete coverage for `restaurant_users`.
  //
  // The earlier substring match on `'restaurant_user'` only fires when
  // the topic name itself carries the table; for the producer surface
  // that emits the op via the payload (`payload['op']` ∈ {insert,
  // update, delete}, `payload['table']` ∈ {restaurant_users}) the
  // table check above already catches it. This branch makes the
  // contract explicit so reassigning a user to a different-tz location
  // refreshes BusinessScope.businessTimezone immediately instead of
  // waiting for the next manual sync trigger.
  final op = event.payload['op']?.toString().toLowerCase();
  if (table == 'restaurant_users' &&
      (op == 'insert' || op == 'delete' || op == 'update')) {
    return true;
  }
  return false;
}
