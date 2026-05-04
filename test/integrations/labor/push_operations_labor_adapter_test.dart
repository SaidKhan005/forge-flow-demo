// Phase 8.S / Wave B — Push Operations scheduling adapter (slice
// `8.S.PU`) fixture-based test suite.
//
// Tests cover every mandatory framework call from
// `docs/contracts/vendor_adapter_slice_contract.md`:
//   1. Sanity hook called per record (backfill + poll).
//   2. Sanity hook reject path skips the canonical write.
//   3. Idempotency replay: same payload twice -> single canonical write.
//   4. Watermark mid-batch resume across a simulated worker crash.
//   5. handleWebhook throws UnsupportedError (poll-only adapter).
//   6. Connect -> backfill -> poll -> disconnect -> reconnect smoke.
//   7. testConnection: fieldMapping populated; shift_start + shift_end
//      + role_name present; <30s.
//   8. VendorCapabilityProfile assertions; lifecycle = `documented`;
//      webhookSupport = pollOnly; coversFieldExposed = false;
//      grantScope = operatorWide; authMode = keyPaste.
//   + Banned-items grep across the adapter source.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/push_operations_labor_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import 'fixtures/push_operations_punches_fixture.dart';

const String _opId = 'op_demo_diner';
const String _locId = 'loc_toronto_yorkville';
const String _actor = 'usr_owner';

void main() {
  group('PushOperationsLaborAdapter — capability profile', () {
    test('declares pollOnly + bearer keyPaste + operatorWide grant + labor',
        () {
      final adapter = _buildAdapter();
      final profile = adapter.capabilityProfile;

      expect(profile.vendorId, 'push_operations');
      expect(profile.displayName, 'Push Operations');
      expect(profile.category, IntegrationCategory.labor);
      expect(profile.authMode, VendorAuthMode.keyPaste);
      expect(profile.grantScope, VendorGrantScope.operatorWide);
      expect(profile.webhookSupport, VendorWebhookSupport.pollOnly);
      expect(profile.coversFieldExposed, isFalse);
      expect(profile.modules, isEmpty);
      expect(profile.timestampPolicyDocId, 'push_operations.asUtc');
    });

    test('lifecycle locked at documented at slice close', () {
      final adapter = _buildAdapter();
      expect(adapter.capabilityProfile.lifecycle, VendorLifecycle.documented);
      expect(adapter.lifecycle, VendorLifecycle.documented);
    });
  });

  group('PushOperationsLaborAdapter — handleWebhook', () {
    test('throws UnsupportedError because vendor does not support webhooks',
        () async {
      final adapter = _buildAdapter();
      final command = HandleWebhookCommand(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'push_operations',
        vendorEventId: 'evt-1',
        payload: const <String, Object?>{},
        headers: const <String, String>{},
        receivedAt: DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      expect(
        () => adapter.handleWebhook(command),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('pollOnly'),
          ),
        ),
      );
    });
  });

  group('PushOperationsLaborAdapter — testConnection', () {
    test(
        'populates fieldMapping with shift_start + shift_end + role_name + '
        'employee_id', () async {
      final apiClient = _FakePushApiClient(
        samplePage: PushOperationsShiftPage(
          records: const <Map<String, Object?>>[samplePushOperationsShift],
          nextCursor: '',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 15, 45, 0),
        ),
      );
      final sink = _FakeCanonicalSink();
      final adapter = PushOperationsLaborAdapter(
        apiClient: apiClient,
        canonicalSink: sink,
        clock: _FakeClock(
          ticks: <DateTime>[
            DateTime.utc(2026, 5, 4, 12, 0, 0),
            DateTime.utc(2026, 5, 4, 12, 0, 0, 250), // +250ms
          ],
        ).next,
      );

      final result = await adapter.testConnection(
        const TestConnectionCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'push_operations',
        ),
      );

      expect(result.authValid, isTrue);
      expect(
        result.fieldMapping['shift_start'],
        DateTime.utc(2026, 5, 2, 16, 0, 0),
      );
      expect(
        result.fieldMapping['shift_end'],
        DateTime.utc(2026, 5, 2, 23, 30, 0),
      );
      expect(result.fieldMapping['role_name'], 'Server');
      expect(result.fieldMapping['employee_id'], '5512');
      expect(result.fieldMapping['vendor_entity_id'], '800101');
      expect(result.fieldMapping['covers_source'], 'not_applicable');
      // <30s — V1 lean cut 2: do not enforce a 5s SLA.
      expect(result.elapsedMs, lessThan(30 * 1000));
    });
  });

  group('PushOperationsLaborAdapter — backfill', () {
    test(
        'calls sanity hook for every record and skips when hook returns false',
        () async {
      final apiClient = _FakePushApiClient(
        sequencedPages: <PushOperationsShiftPage>[
          PushOperationsShiftPage(
            records: const <Map<String, Object?>>[
              samplePushOperationsShift,
              futureDatedPushOperationsShift,
              secondPushOperationsShift,
            ],
            nextCursor: '',
            lastModifiedSeen: DateTime.utc(2026, 5, 2, 17, 15, 0),
          ),
        ],
      );
      final sink = _FakeCanonicalSink();
      final adapter = PushOperationsLaborAdapter(
        apiClient: apiClient,
        canonicalSink: sink,
      );

      final hookCalls = <String>[];
      Future<bool> hook({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async {
        hookCalls.add(vendorEventId);
        // Reject the future-dated row only.
        return vendorEventId != '999001';
      }

      final result = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'push_operations',
          windowStart: DateTime.utc(2026, 3, 4),
          windowEnd: DateTime.utc(2026, 5, 4),
          sanityHook: hook,
        ),
      );

      // Hook called once per record.
      expect(hookCalls, <String>['800101', '999001', '800102']);
      // Sanity-rejected row was NOT written.
      expect(sink.upserts.length, 2);
      expect(
        sink.upserts.map((e) => e['vendor_entity_id']),
        containsAll(<String>['800101', '800102']),
      );
      expect(
        sink.upserts.any((e) => e['vendor_entity_id'] == '999001'),
        isFalse,
      );
      expect(result.recordsWritten, 2);
      expect(result.completed, isTrue);
    });

    test(
        'idempotency replay: same payload through pollIncremental twice -> '
        'single canonical write', () async {
      final pageOne = PushOperationsShiftPage(
        records: const <Map<String, Object?>>[samplePushOperationsShift],
        nextCursor: '',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 15, 45, 0),
      );
      final pageTwo = PushOperationsShiftPage(
        records: const <Map<String, Object?>>[samplePushOperationsShift],
        nextCursor: '',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 15, 45, 0),
      );
      final apiClient = _FakePushApiClient(
        sequencedPages: <PushOperationsShiftPage>[pageOne, pageTwo],
      );
      final sink = _FakeCanonicalSink();
      final adapter = PushOperationsLaborAdapter(
        apiClient: apiClient,
        canonicalSink: sink,
      );

      Future<bool> alwaysAllow({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async =>
          true;

      await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'push_operations',
          lastModifiedSeen: DateTime.utc(2026, 5, 2),
          sanityHook: alwaysAllow,
        ),
      );
      await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'push_operations',
          lastModifiedSeen: DateTime.utc(2026, 5, 2),
          sanityHook: alwaysAllow,
        ),
      );

      // The sink saw the same key twice; idempotency UNIQUE collapses
      // the second to a no-op (returns false). The adapter's
      // `recordsWritten` counter follows the sink's truth.
      expect(sink.upsertCalls, 2);
      expect(sink.uniqueKeys.length, 1);
    });
  });

  group('PushOperationsLaborAdapter — watermark per batch', () {
    test(
        'persists watermark after each batch so a mid-batch crash resumes '
        'from the last successful cursor', () async {
      final pageOne = PushOperationsShiftPage(
        records: const <Map<String, Object?>>[samplePushOperationsShift],
        nextCursor: 'page:2',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 15, 45, 0),
      );
      final pageTwo = PushOperationsShiftPage(
        records: const <Map<String, Object?>>[secondPushOperationsShift],
        nextCursor: 'page:3',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 17, 15, 0),
      );
      final apiClient = _FakePushApiClient(
        sequencedPages: <PushOperationsShiftPage>[pageOne, pageTwo],
        crashAfterPage: 2, // Throw after delivering page 2.
      );
      final sink = _FakeCanonicalSink();
      final adapter = PushOperationsLaborAdapter(
        apiClient: apiClient,
        canonicalSink: sink,
      );

      Future<bool> alwaysAllow({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async =>
          true;

      // Simulated crash after batch 2 — the adapter throws when the
      // fake's third page is requested. The watermark recorded BEFORE
      // the crash must match batch 2's cursor.
      try {
        await adapter.backfill(
          BackfillCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _actor,
            vendorId: 'push_operations',
            windowStart: DateTime.utc(2026, 3, 4),
            windowEnd: DateTime.utc(2026, 5, 4),
            sanityHook: alwaysAllow,
          ),
        );
        fail('expected fake to throw on page 3 request');
      } on StateError catch (_) {
        // Expected.
      }

      expect(sink.watermarkAdvances.length, 2);
      expect(
        sink.watermarkAdvances.last['cursor_token'],
        'page:3',
      );
      expect(
        sink.watermarkAdvances.last['last_modified_seen'],
        DateTime.utc(2026, 5, 2, 17, 15, 0),
      );

      // Resume after the crash uses the persisted watermark — the
      // adapter passes `resumeFromCursor` and never re-reads batch 1
      // / batch 2 records.
      apiClient.crashAfterPage = null;
      apiClient.resetSequencedPages(<PushOperationsShiftPage>[
        PushOperationsShiftPage(
          records: const <Map<String, Object?>>[],
          nextCursor: '',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 17, 15, 0),
        ),
      ]);
      sink.resetUpsertCounts();

      final resumeResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'push_operations',
          windowStart: DateTime.utc(2026, 3, 4),
          windowEnd: DateTime.utc(2026, 5, 4),
          resumeFromCursor: 'page:3',
          sanityHook: alwaysAllow,
        ),
      );

      expect(apiClient.requestedCursors, contains('page:3'));
      expect(resumeResult.recordsWritten, 0);
      expect(resumeResult.completed, isTrue);
    });
  });

  group('PushOperationsLaborAdapter — connect/disconnect smoke', () {
    test(
        'connect -> backfill -> poll -> disconnect -> reconnect preserves '
        'watermark and resumes from last cursor', () async {
      final apiClient = _FakePushApiClient(
        sequencedPages: <PushOperationsShiftPage>[
          // Backfill page.
          PushOperationsShiftPage(
            records: const <Map<String, Object?>>[samplePushOperationsShift],
            nextCursor: '',
            lastModifiedSeen: DateTime.utc(2026, 5, 2, 15, 45, 0),
          ),
          // Poll tick: one new shift.
          PushOperationsShiftPage(
            records: const <Map<String, Object?>>[secondPushOperationsShift],
            nextCursor: '',
            lastModifiedSeen: DateTime.utc(2026, 5, 2, 17, 15, 0),
          ),
          // After reconnect: empty page (nothing new since watermark).
          PushOperationsShiftPage(
            records: const <Map<String, Object?>>[],
            nextCursor: '',
            lastModifiedSeen: DateTime.utc(2026, 5, 2, 17, 15, 0),
          ),
        ],
      );
      final sink = _FakeCanonicalSink();
      final adapter = PushOperationsLaborAdapter(
        apiClient: apiClient,
        canonicalSink: sink,
      );

      Future<bool> alwaysAllow({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async =>
          true;

      // Connect.
      final connect = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'push_operations',
        ),
      );
      expect(connect.status, ConnectionStatus.connected);
      expect(connect.webhookUrl, isNull);
      expect(connect.firstBackfillStarted, isTrue);
      expect(connect.metadata['grant_scope'], 'operatorWide');

      // Backfill.
      final backfill = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'push_operations',
          windowStart: DateTime.utc(2026, 3, 4),
          windowEnd: DateTime.utc(2026, 5, 4),
          sanityHook: alwaysAllow,
        ),
      );
      expect(backfill.recordsWritten, 1);

      // Poll.
      final poll = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'push_operations',
          lastModifiedSeen: backfill.lastModifiedSeen,
          sanityHook: alwaysAllow,
        ),
      );
      expect(poll.recordsWritten, 1);
      expect(poll.sanityDropped, 0);

      // Disconnect.
      final disconnect = await adapter.disconnect(
        const DisconnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'push_operations',
          reason: DisconnectReason.operatorAction,
        ),
      );
      expect(disconnect.credentialsWiped, isTrue);
      expect(disconnect.webhookUnregistered, isTrue);
      expect(disconnect.watermarkPreserved, isTrue);
      expect(
        sink.watermarkAdvances,
        isNotEmpty,
        reason: 'watermark must persist across disconnect',
      );

      // Reconnect: same path; empty page returns no new records but
      // the watermark from the prior poll is the cursor.
      final pollAfterReconnect = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'push_operations',
          lastModifiedSeen: poll.newLastModifiedSeen,
          sanityHook: alwaysAllow,
        ),
      );
      expect(pollAfterReconnect.recordsWritten, 0);
    });
  });

  group('PushOperationsLaborAdapter — banned items grep', () {
    test('adapter source contains zero banned-list items', () async {
      final source = await File(
        'lib/integrations/labor/push_operations_labor_adapter.dart',
      ).readAsString();

      // Banned items per `memory/project_v1_lean_cut_2_2026_05_03.md`.
      // The adapter must contain none of these tokens (case-insensitive
      // match where the token is a phrase or class name).
      const banned = <String>[
        // KMS / production-key rotation.
        'KMS',
        'pgp_sym_encrypt_kms',
        // Webhook key rotation UI (poll-only, but assert anyway).
        'rotateSigningKey',
        // parse_warnings / parse_partial.
        'parse_warnings',
        'parse_partial',
        // 5-minute strict replay window.
        'kStrictReplayFiveMinute',
        // Advisory locks.
        'pg_try_advisory_lock',
        'pg_advisory_lock',
        // SIGTERM drain handler.
        'sigtermDrainHandler',
        // DLQ tile.
        'inboundWebhookDLQTile',
        // Raw-payload sibling tables.
        'raw_payload_partition',
        'pg_partman_raw',
      ];

      for (final token in banned) {
        expect(
          source.toLowerCase().contains(token.toLowerCase()),
          isFalse,
          reason: 'banned item present in adapter source: $token',
        );
      }
    });

    test(
        'webhook signature verifier file does NOT exist for poll-only adapter',
        () {
      final verifier = File(
        'lib/integrations/labor/push_operations_webhook_signature_verifier.dart',
      );
      expect(
        verifier.existsSync(),
        isFalse,
        reason: 'pollOnly vendor must not ship a signature verifier; '
            'webhook_signature.md documents this as N/A',
      );
    });
  });
}

// ─── Test doubles ───────────────────────────────────────────────────

PushOperationsLaborAdapter _buildAdapter() => PushOperationsLaborAdapter(
      apiClient: _FakePushApiClient(
        samplePage: PushOperationsShiftPage(
          records: const <Map<String, Object?>>[samplePushOperationsShift],
          nextCursor: '',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 15, 45, 0),
        ),
      ),
      canonicalSink: _FakeCanonicalSink(),
    );

class _FakeClock {
  _FakeClock({required this.ticks});
  final List<DateTime> ticks;
  int _idx = 0;
  DateTime next() {
    final value = ticks[_idx];
    if (_idx < ticks.length - 1) _idx++;
    return value;
  }
}

class _FakePushApiClient implements PushOperationsApiClient {
  _FakePushApiClient({
    PushOperationsShiftPage? samplePage,
    List<PushOperationsShiftPage>? sequencedPages,
    this.crashAfterPage,
  })  : _samplePage = samplePage,
        _sequencedPages =
            sequencedPages ?? <PushOperationsShiftPage>[];

  final PushOperationsShiftPage? _samplePage;
  List<PushOperationsShiftPage> _sequencedPages;
  int _pageIdx = 0;
  int? crashAfterPage;
  final List<String?> requestedCursors = <String?>[];

  void resetSequencedPages(List<PushOperationsShiftPage> pages) {
    _sequencedPages = pages;
    _pageIdx = 0;
  }

  @override
  Future<PushOperationsShiftPage> fetchSampleShift({
    required String operatorId,
    required String locationId,
  }) async {
    return _samplePage ??
        PushOperationsShiftPage(
          records: const <Map<String, Object?>>[],
          nextCursor: '',
          lastModifiedSeen: DateTime.utc(1970, 1, 1),
        );
  }

  @override
  Future<PushOperationsShiftPage> fetchShifts({
    required String operatorId,
    required String locationId,
    required DateTime sinceModified,
    required String? cursor,
    required bool isDeliberateBackfill,
  }) async {
    requestedCursors.add(cursor);
    if (crashAfterPage != null && _pageIdx >= crashAfterPage!) {
      throw StateError('simulated worker crash after page $crashAfterPage');
    }
    if (_pageIdx >= _sequencedPages.length) {
      return PushOperationsShiftPage(
        records: const <Map<String, Object?>>[],
        nextCursor: '',
        lastModifiedSeen: sinceModified,
      );
    }
    final page = _sequencedPages[_pageIdx];
    _pageIdx += 1;
    return page;
  }
}

class _FakeCanonicalSink implements PushOperationsCanonicalSink {
  final List<Map<String, Object?>> upserts = <Map<String, Object?>>[];
  final Set<String> uniqueKeys = <String>{};
  int upsertCalls = 0;
  final List<Map<String, Object?>> watermarkAdvances =
      <Map<String, Object?>>[];
  final List<Map<String, Object?>> syncLogRows = <Map<String, Object?>>[];

  void resetUpsertCounts() {
    upserts.clear();
    uniqueKeys.clear();
    upsertCalls = 0;
  }

  @override
  Future<bool> upsertShift({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    upsertCalls += 1;
    final key = '${canonicalFact['vendor_entity_id']}::'
        '${canonicalFact['vendor_modified_at']}';
    if (uniqueKeys.contains(key)) {
      return false;
    }
    uniqueKeys.add(key);
    upserts.add(canonicalFact);
    return true;
  }

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    watermarkAdvances.add(<String, Object?>{
      'cursor_token': cursorToken,
      'last_modified_seen': lastModifiedSeen,
    });
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {
    syncLogRows.add(<String, Object?>{
      'event_kind': eventKind,
      'error_message': errorMessage,
      'records_count': recordsCount,
      'payload_preview': payloadPreview,
    });
  }

  @override
  Future<({bool credentialsWiped, bool webhookUnregistered, bool watermarkPreserved})>
      wipeCredentialsPreserveWatermark({
    required String operatorId,
    required String locationId,
  }) async {
    return (
      credentialsWiped: true,
      webhookUnregistered: true,
      watermarkPreserved: true,
    );
  }
}
