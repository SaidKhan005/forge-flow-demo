import '../../../../domain/models/connector_config.dart';
import '../../../../domain/repositories/connector_config_repository.dart';
import '../dao/connector_config_dao.dart';
import '../sqlite_database.dart';

class SqliteConnectorConfigRepository implements ConnectorConfigRepository {
  SqliteConnectorConfigRepository._();
  static final SqliteConnectorConfigRepository instance =
      SqliteConnectorConfigRepository._();

  ConnectorConfigDao? _dao;

  Future<ConnectorConfigDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = ConnectorConfigDao(db);
    return _dao!;
  }

  @override
  Future<List<ConnectorConfig>> getConnectorConfigs(
      String restaurantId) async {
    final dao = await _daoReady;
    return dao.getConnectorConfigs(restaurantId);
  }

  @override
  Future<ConnectorConfig?> getConnectorConfigBySourceType(
      String restaurantId, String sourceType) async {
    final dao = await _daoReady;
    return dao.getConnectorConfigBySourceType(restaurantId, sourceType);
  }

  @override
  Future<void> upsertConnectorConfig(ConnectorConfig config) async {
    final dao = await _daoReady;
    return dao.upsertConnectorConfig(config);
  }
}
