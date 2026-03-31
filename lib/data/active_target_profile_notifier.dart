/// App-wide active-target profile authority.
///
/// Loads the persisted active target profile for the active restaurant.
/// Exposes a revision counter that increments on each profile change.
/// This notifier replaces `BaselineData.revision` as the app-shell
/// propagation authority for active-target changes.

import 'package:flutter/foundation.dart';
import '../domain/models/active_target_profile.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import 'baseline_manager_service.dart';

class ActiveTargetProfileNotifier extends ChangeNotifier {
  ActiveTargetProfile? _profile;
  int _revision = 0;
  bool _isLoading = true;

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
    await _load();
    _revision++;
    notifyListeners();
  }

  Future<void> _load() async {
    final restaurantId =
        await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();
    _profile =
        await SqliteTargetProfileRepository.instance
            .getActiveTargetProfile(restaurantId);
    _profile ??=
        SqliteDatabase.buildActiveTargetProfileFromBaseline(restaurantId);
    _isLoading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    if (BaselineManagerService.instance.onActiveTargetChanged == refresh) {
      BaselineManagerService.instance.onActiveTargetChanged = null;
    }
    super.dispose();
  }
}
