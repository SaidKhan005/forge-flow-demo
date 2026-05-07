import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/business_scope.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_active_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  group('SqliteActiveScopeRepository', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('round-trips one active scope per user', () async {
      const scope = BusinessScope(
        scopeId: 'loc-2',
        scopeType: 'location',
        operatorId: 'op-1',
        locationId: 'loc-2',
        parentScopeId: 'region-1',
        label: 'Mercado',
        businessTimezone: 'America/St_Johns',
        sortPath: 'group.mercado',
      );

      await SqliteActiveScopeRepository.instance.saveActiveScope(
        userId: 'user-1',
        scope: scope,
      );

      final loaded = await SqliteActiveScopeRepository.instance.getActiveScope(
        'user-1',
      );
      expect(loaded, isNotNull);
      expect(loaded!.stableKey, 'location:loc-2');
      expect(loaded.locationId, 'loc-2');
      expect(loaded.label, 'Mercado');
      expect(loaded.businessTimezone, 'America/St_Johns');
    });
  });
}
