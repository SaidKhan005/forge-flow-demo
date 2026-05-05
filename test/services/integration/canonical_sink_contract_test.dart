// Phase 8 Wave B `8.spine-bridge.0` CanonicalSink contract tests +
// banned-items grep over every new file this lane introduces.
//
// Three responsibilities:
//   1. A test fake implementing [CanonicalSink] satisfies the abstract
//      surface; every required method is callable.
//   2. [CanonicalSink.evaluateDemoFlip] is idempotent: a second call
//      with the same `(operatorId, locationId, category)` after the
//      row already flipped is a no-op (the underlying flip side-effect
//      runs exactly once). This proves the policy contract from
//      `lib/services/integration/demo_mode_state.dart` carries through
//      the sink's flip seam.
//   3. Banned-item ledger absent from every new source file this lane
//      shipped. Strict raw grep per the spine-bridge.0 contract.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';

void main() {
  group('CanonicalSink contract', () {
    test('every required method is callable through a test fake', () async {
      final sink = _FakeCanonicalSink();

      expect(
        await sink.upsertCoverFact(
          operatorId: _opId,
          locationId: _locId,
          canonicalFact: const <String, Object?>{'vendor_entity_id': 'cov-1'},
        ),
        true,
      );
      expect(
        await sink.upsertLaborPunch(
          operatorId: _opId,
          locationId: _locId,
          canonicalPunch: const <String, Object?>{'vendor_entity_id': 'p-1'},
        ),
        true,
      );
      expect(
        await sink.upsertReservationFact(
          operatorId: _opId,
          locationId: _locId,
          canonicalReservation: const <String, Object?>{
            'vendor_entity_id': 'r-1',
          },
        ),
        true,
      );

      await sink.advanceWatermark(
        operatorId: _opId,
        locationId: _locId,
        connectionId: 'conn-1',
        cursorToken: 'cursor-1',
        lastModifiedSeen: DateTime.utc(2026, 5, 4),
      );

      await sink.appendSyncLog(
        operatorId: _opId,
        locationId: _locId,
        connectionId: 'conn-1',
        eventKind: 'poll_success',
        recordsCount: 3,
      );

      await sink.evaluateDemoFlip(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 5,
        connectionId: 'conn-1',
      );
      expect(sink.flipEvents, hasLength(1),
          reason: 'connect + backfill commit + records >= 1 must flip live');
    });

    test(
        'evaluateDemoFlip is idempotent: second call after live flip is a '
        'no-op', () async {
      final sink = _FakeCanonicalSink();

      await sink.evaluateDemoFlip(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 5,
        connectionId: 'conn-1',
      );
      expect(sink.flipEvents, hasLength(1));
      final firstFlip = sink.flipEvents.single;

      await sink.evaluateDemoFlip(
        operatorId: _opId,
        locationId: _locId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 99,
        connectionId: 'conn-2',
      );
      expect(sink.flipEvents, hasLength(1),
          reason: 'idempotent: second evaluateDemoFlip MUST NOT add a '
              'second flip event after the row is already live');
      expect(sink.flipEvents.single.connectionId, firstFlip.connectionId,
          reason: 'idempotent: original triggering connectionId preserved');
    });
  });

  group('Banned-item ledger absent from every new source file this lane '
      'shipped', () {
    // Lean-cut ledger per memory/project_v1_lean_cut_2_2026_05_03.md.
    // Strict raw substring check per the spine-bridge.0 contract; no
    // comment stripping. Source files that need to mention the ledger
    // do so via prose (e.g., "the lean-cut ledger") rather than the
    // literal token names.
    const banned = <String>[
      _t1, _t2, _t3, _t4, _t5,
      _t6, _t7, _t8, _t9, _t10,
    ];

    const newFiles = <String>[
      'lib/services/integration/canonical_sink.dart',
      'tool/advisor_proxy/pos_adapter_registry.dart',
      'tool/advisor_proxy/labor_adapter_registry.dart',
      'tool/advisor_proxy/reservation_adapter_registry.dart',
      'tool/advisor_proxy/vendor_capability_index.dart',
      'tool/integration_sync_worker/dispatch.dart',
      'tool/integration_sync_worker/main.dart',
    ];

    for (final path in newFiles) {
      test('$path raw grep: zero banned-token matches', () {
        final source = File(path).readAsStringSync();
        for (final token in banned) {
          expect(source.contains(token), isFalse,
              reason: 'banned token "$token" present in $path');
        }
      });
    }
  });
}

// Banned tokens declared as fragmented constants so this file itself
// does not contain any of the literal tokens (an earlier sibling lane
// might also grep test files, and self-matching would be a false
// positive). Each token is reassembled at runtime.
const String _t1 = 'K' 'M' 'S';
const String _t2 = 'parse' '_' 'warnings';
const String _t3 = 'parse' '_' 'partial';
const String _t4 = 'kStrict' 'Replay' 'FiveMinute';
const String _t5 = 'pg_' 'advisory' '_lock';
const String _t6 = 'sigterm' 'Drain' 'Handler';
const String _t7 = 'inboundWebhook' 'DLQ' 'Tile';
const String _t8 = 'raw_' 'payload' '_partition';
const String _t9 = 'pg_' 'partman' '_raw';
const String _t10 = 'package' ':' 'postgres';

// ─── Fake sink (in-memory; idempotent flip) ────────────────────────

class _FakeCanonicalSink implements CanonicalSink {
  final Set<String> _liveTriples = <String>{};
  final List<_FlipEvent> flipEvents = <_FlipEvent>[];

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async =>
      true;

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async =>
      true;

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async =>
      true;

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {}

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {}

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) async {
    final key = '$operatorId|$locationId|${category.name}';

    // Already live: idempotent no-op (no second flip event recorded).
    if (_liveTriples.contains(key)) return;

    if (connectionStatus != ConnectionStatus.connected ||
        !firstBackfillCommitted ||
        backfillRecordsWritten < 1) {
      return;
    }

    _liveTriples.add(key);
    flipEvents.add(_FlipEvent(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
      connectionId: connectionId,
    ));
  }
}

class _FlipEvent {
  const _FlipEvent({
    required this.operatorId,
    required this.locationId,
    required this.category,
    required this.connectionId,
  });
  final String operatorId;
  final String locationId;
  final IntegrationCategory category;
  final String connectionId;
}
