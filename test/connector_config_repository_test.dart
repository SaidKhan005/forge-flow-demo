// Connector config repository tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/connector_config.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_connector_config_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
    final db = await SqliteDatabase.instance.database;
    await db.delete('connector_configs');
  });

  test('upsert and list connector configs', () async {
    final repo = SqliteConnectorConfigRepository.instance;
    final now = DateTime.now().toIso8601String();

    final config = ConnectorConfig(
      connectorId: 'pos_toast_001',
      restaurantId: 'demo_restaurant_001',
      sourceType: 'pos',
      externalLocationId: 'toast_loc_abc',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertConnectorConfig(config);

    final configs =
        await repo.getConnectorConfigs('demo_restaurant_001');
    expect(configs, isNotEmpty);
    expect(configs.any((c) => c.connectorId == 'pos_toast_001'), isTrue);
  });

  test('lookup by restaurantId and sourceType', () async {
    final repo = SqliteConnectorConfigRepository.instance;
    final now = DateTime.now().toIso8601String();

    await repo.upsertConnectorConfig(ConnectorConfig(
      connectorId: 'labor_7shifts_001',
      restaurantId: 'demo_restaurant_001',
      sourceType: 'labor',
      externalLocationId: '7s_loc_xyz',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    ));

    final found = await repo.getConnectorConfigBySourceType(
        'demo_restaurant_001', 'labor');
    expect(found, isNotNull);
    expect(found!.connectorId, 'labor_7shifts_001');

    final notFound = await repo.getConnectorConfigBySourceType(
        'demo_restaurant_001', 'nonexistent');
    expect(notFound, isNull);
  });

  test('upsert replaces existing config for the same source type', () async {
    final repo = SqliteConnectorConfigRepository.instance;
    final now = DateTime.now().toIso8601String();

    await repo.upsertConnectorConfig(ConnectorConfig(
      connectorId: 'pos_old',
      restaurantId: 'demo_restaurant_001',
      sourceType: 'pos',
      externalLocationId: 'old_loc',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    ));

    await repo.upsertConnectorConfig(ConnectorConfig(
      connectorId: 'pos_new',
      restaurantId: 'demo_restaurant_001',
      sourceType: 'pos',
      externalLocationId: 'new_loc',
      status: 'active',
      createdAt: now,
      updatedAt: now,
    ));

    final configs =
        await repo.getConnectorConfigs('demo_restaurant_001');
    final posConfigs = configs.where((c) => c.sourceType == 'pos');
    expect(posConfigs.length, 1);
    expect(posConfigs.first.connectorId, 'pos_new');
    expect(posConfigs.first.externalLocationId, 'new_loc');
  });
}
