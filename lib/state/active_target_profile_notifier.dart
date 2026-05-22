/// App-wide active-target profile authority.
///
/// Loads the persisted active target profile for the active restaurant.
/// Exposes a revision counter that increments on each profile change.
/// This notifier replaces `BaselineData.revision` as the app-shell
/// propagation authority for active-target changes.
library;

import 'package:flutter/foundation.dart';
import '../domain/models/active_target_profile.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import '../services/wage_standard_context_service.dart';

class ActiveTargetProfileNotifier extends ChangeNotifier {
  ActiveTargetProfile? _profile;
  int _revision = 0;
  bool _isLoading = true;
  bool _disposed = false;

  ActiveTargetProfile? get profile => _profile;
  int get revision => _revision;
  bool get isLoading => _isLoading;

  ActiveTargetProfileNotifier() {
    // Register as the active-target authority listener
    BaselineManagerService.instance.onActiveTargetChanged = refresh;
    _load();
  }

  /// Test-only constructor for synchronous setup.
  ActiveTargetProfileNotifier.fromProfile(ActiveTargetProfile profile)
      : _profile = profile,
        _revision = 0,
        _isLoading = false;

  Future<void> refresh() async {
    if (_disposed) return;
    await _load();
    if (_disposed) return;
    _revision++;
    notifyListeners();
  }

  Future<void> _load() async {
    final restaurantId =
        await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();
    _profile = await WageStandardContextService.instance
        .loadOrBootstrapProfile(restaurantId);
    if (_disposed) return;
    _isLoading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (BaselineManagerService.instance.onActiveTargetChanged == refresh) {
      BaselineManagerService.instance.onActiveTargetChanged = null;
    }
    super.dispose();
  }
}