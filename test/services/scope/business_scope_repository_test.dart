import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/business_scope.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_active_scope_repository.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/scope/business_scope_repository.dart';

import '../../_test_helpers/sqlite_demo_helpers.dart';

void main() {
  group('SqliteActiveScopeRepository', () {
    setUp(setUpSqliteDemo);

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

  group('isBusinessScopeInvalidationEvent', () {
    test('matches access-control and hierarchy tables', () {
      for (final table in <String>[
        'restaurant_users',
        'user_roles',
        'roles',
        'role_permissions',
        'org_units',
        'locations',
        'user_effective_locations',
      ]) {
        expect(
          isBusinessScopeInvalidationEvent(_event(table: table)),
          isTrue,
          reason: '$table changes can alter mobile-accessible scopes',
        );
      }
    });

    test('ignores unrelated shared-state tables', () {
      expect(
        isBusinessScopeInvalidationEvent(_event(table: 'shift_records')),
        isFalse,
      );
    });
  });
}

RealtimeEvent _event({required String table}) {
  return RealtimeEvent(
    eventId: 'evt-$table',
    topic: 'shared_state.op-1.$table',
    operatorId: 'op-1',
    occurredAt: DateTime.utc(2026, 5, 7, 12),
    payload: <String, Object?>{'table': table},
  );
}
