import '../models/connector_config.dart';

abstract class ConnectorConfigRepository {
  Future<List<ConnectorConfig>> getConnectorConfigs(String restaurantId);
  Future<ConnectorConfig?> getConnectorConfigBySourceType(
      String restaurantId, String sourceType);
  Future<void> upsertConnectorConfig(ConnectorConfig config);
}
