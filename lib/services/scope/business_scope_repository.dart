import 'dart:async';

import '../../domain/models/business_scope.dart';

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
