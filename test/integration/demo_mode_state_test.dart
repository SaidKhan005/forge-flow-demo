// Phase 8.0 — Demo-mode-to-live transition tests.
//
// Validates the flip semantics:
//   * Default `is_demo = true` per (operator, location, category).
//   * Flips to false when first INTEGRATE connection reaches
//     `connected` AND first backfill commits >=1 record.
//   * Disconnect does NOT auto-revert.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

void main() {
  group('DemoModeFlipPolicy', () {
    late _FakeGateway gateway;
    late DemoModeFlipPolicy policy;

    setUp(() {
      gateway = _FakeGateway();
      policy = DemoModeFlipPolicy(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );
    });

    test('default state is is_demo = true', () async {
      final result = await gateway.readOrCreateDefault(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
      );
      expect(result.isDemo, true);
    });

    test('flips to live on connected + first backfill commit', () async {
      final after = await policy.evaluateFlip(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 1,
        connectionId: 'conn-1',
      );
      expect(after.isDemo, false);
      expect(after.flippedToLiveAt, DateTime.utc(2026, 5, 4, 12, 0, 0));
      expect(after.flippedByConnectionId, 'conn-1');
    });

    test('does NOT flip if backfill records = 0', () async {
      final after = await policy.evaluateFlip(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 0,
        connectionId: 'conn-1',
      );
      expect(after.isDemo, true);
    });

    test('does NOT flip if connection status != connected', () async {
      final after = await policy.evaluateFlip(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.error,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 5,
        connectionId: 'conn-1',
      );
      expect(after.isDemo, true);
    });

    test('does NOT flip if first backfill not yet committed', () async {
      final after = await policy.evaluateFlip(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: false,
        backfillRecordsWritten: 5,
        connectionId: 'conn-1',
      );
      expect(after.isDemo, true);
    });

    test('disconnect does NOT auto-revert', () async {
      // Flip first.
      await policy.evaluateFlip(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 1,
        connectionId: 'conn-1',
      );
      // Then disconnect — should NOT flip back to demo.
      final after = await policy.handleDisconnect(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
      );
      expect(after.isDemo, false);
    });

    test('flipToLive is idempotent: second flip is no-op', () async {
      await policy.evaluateFlip(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 1,
        connectionId: 'conn-1',
      );
      final firstFlipAt = gateway.records['$_opId/$_locId/pos']!.flippedToLiveAt;
      // Move clock forward and flip again with a different connection.
      final policy2 = DemoModeFlipPolicy(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 5, 12, 0, 0),
      );
      final secondFlip = await policy2.evaluateFlip(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 5,
        connectionId: 'conn-2',
      );
      expect(secondFlip.isDemo, false);
      // First flip timestamp preserved (idempotent).
      expect(secondFlip.flippedToLiveAt, firstFlipAt);
    });
  });
}

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';

class _FakeGateway implements DemoModeStateGateway {
  final Map<String, DemoModeRecord> records = <String, DemoModeRecord>{};

  String _key(String op, String loc, IntegrationCategory cat) =>
      '$op/$loc/${cat.name}';

  @override
  Future<DemoModeRecord> readOrCreateDefault({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
  }) async {
    final key = _key(operatorId, locationId, category);
    return records[key] ??= DemoModeRecord(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
      isDemo: true,
    );
  }

  @override
  Future<DemoModeRecord> flipToLive({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required String connectionId,
    required DateTime flippedAt,
  }) async {
    final key = _key(operatorId, locationId, category);
    final existing = records[key];
    if (existing != null && !existing.isDemo) return existing; // idempotent
    final updated = DemoModeRecord(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
      isDemo: false,
      flippedToLiveAt: flippedAt,
      flippedByConnectionId: connectionId,
    );
    records[key] = updated;
    return updated;
  }
}
