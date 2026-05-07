import '../../../../domain/models/data_accuracy_service_period_setting.dart';
import '../dao/data_accuracy_service_period_settings_cache_dao.dart';
import '../sqlite_database.dart';

/// Theme H#7 — Singleton repository wrapping the DAS service-period
/// settings persistent cache.
///
/// Used by the mobile sync pipeline to mirror each server pull and by
/// app-start hydration paths that need honest covers/wage source
/// resolution before the first sweep completes.
class SqliteDataAccuracyServicePeriodSettingsCacheRepository {
  SqliteDataAccuracyServicePeriodSettingsCacheRepository._();
  static final SqliteDataAccuracyServicePeriodSettingsCacheRepository
  instance = SqliteDataAccuracyServicePeriodSettingsCacheRepository._();

  DataAccuracyServicePeriodSettingsCacheDao? _dao;

  Future<DataAccuracyServicePeriodSettingsCacheDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = DataAccuracyServicePeriodSettingsCacheDao(db);
    return _dao!;
  }

  Future<List<DataAccuracyServicePeriodSetting>> getRows(
    String restaurantId,
  ) async {
    final dao = await _daoReady;
    return dao.getRows(restaurantId);
  }

  Future<bool> replaceAll(
    String restaurantId,
    List<DataAccuracyServicePeriodSetting> rows,
  ) async {
    final dao = await _daoReady;
    return dao.replaceAll(restaurantId, rows);
  }

  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    final dao = await _daoReady;
    return dao.wipeForOtherScopes(keepRestaurantId);
  }
}
