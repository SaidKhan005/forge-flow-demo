import 'package:flutter/foundation.dart';
import '../domain/models/active_target_profile.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import '../models/app_data_status.dart';
import '../models/shift_dashboard_read_model.dart';
import 'app_data_status_service.dart';

class ShiftDashboardNotifier extends ChangeNotifier {
  ShiftDashboardReadModel? _readModel;
  AppDataStatus? _status;
  bool _isLoading = true;

  ShiftDashboardReadModel? get readModel => _readModel;
  AppDataStatus? get status => _status;
  bool get isLoading => _isLoading;

  ShiftDashboardNotifier() {
    _load();
  }

  /// Test-only constructor for synchronous setup.
  ShiftDashboardNotifier.fromReadModel(ShiftDashboardReadModel model)
      : _readModel = model,
        _status = null,
        _isLoading = false;

  /// Test-only constructor for synchronous empty-state rendering.
  ShiftDashboardNotifier.emptyForTest(AppDataStatus status)
      : _readModel = null,
        _status = status,
        _isLoading = false;

  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();
    await _load();
  }

  Future<void> _load() async {
    // Always evaluate data status
    _status = await AppDataStatusService.instance.evaluate();

    final restaurantId =
        await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();

    // Load active target profile
    ActiveTargetProfile? profile =
        await SqliteTargetProfileRepository.instance
            .getActiveTargetProfile(restaurantId);
    profile ??=
        SqliteDatabase.buildActiveTargetProfileFromBaseline(restaurantId);

    // Load current open shift
    final snapshot =
        await SqliteOpenShiftSnapshotRepository.instance
            .getCurrentOpenShift(restaurantId);

    if (snapshot != null) {
      _readModel = ShiftDashboardReadModel.build(snapshot, profile);
    } else {
      _readModel = null;
    }

    _isLoading = false;
    notifyListeners();
  }
}
