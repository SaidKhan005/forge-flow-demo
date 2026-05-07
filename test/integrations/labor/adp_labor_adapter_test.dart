// Phase 8.S.ADP — AdpLaborAdapter +
// AdpWebhookSignatureVerifier tests.
//
// Drives the adapter against fixture-driven fakes (no live HTTP, no
// Postgres, no partner credentials) to prove every framework call
// required by `docs/contracts/vendor_adapter_slice_contract.md`:
//
//   1. Sanity hook called per record on backfill + poll, reject path
//      skips the canonical write.
//   2. Idempotency UNIQUE on canonical fact upsert
//      (`(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`).
//   3. Watermark per batch commit (mid-batch crash → resume from last
//      persisted cursor).
//   4. Webhook signature constant-time HMAC compare; tampered
//      signature 403.
//   5. OperatorScopedRepository `withTenant` indirection (asserted
//      via gateway shape — no `package:postgres` import in adapter).
//   6. Capability profile declares every required field; modules =
//      ['workforce_now', 'workforce_manager', 'run']; lifecycle =
//      `documented`.
//
// Plus the slice-specific tests required by the prompt:
//
//   * Connect → backfill → poll → disconnect → reconnect smoke
//     (driven by the WFN module).
//   * Test connection populates fieldMapping with shift_start +
//     shift_end + role_name in <30s on the offline path with
//     `assumption: true` flag.
//   * Replay window — framework constant pinned at 24h.
//   * Module disambiguation (CONTRACT-REQUIRED — 3 paths):
//     `workforce_now` succeeds; `workforce_manager` succeeds; `run`
//     throws `ModuleRefusalException` with the EXACT friendly copy
//     from `vendor_master_list.md`.
//   * Banned-items grep pinned at the source-file level.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/adp_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/adp_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/vendor_timestamp_policy.dart';

import 'fixtures/adp_punches_fixture.dart';
import 'fixtures/adp_webhook_fixture.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _signingSecret = 'whsec_adp_test_001';

void main() {
  group('VendorCapabilityProfile (Test 9)', () {
    final adapter = AdpLaborAdapter(
      transport: _FakeAdpTransport(),
      gateway: _FakeAdpGateway(),
    );

    test('vendorId / displayName / category / authMode / scope / webhook', () {
      expect(adapter.vendorId, 'adp');
      expect(
        adapter.displayName,
        'ADP Workforce Now / Workforce Manager',
      );
      expect(
        adapter.capabilityProfile.category,
        IntegrationCategory.labor,
      );
      expect(adapter.capabilityProfile.authMode, VendorAuthMode.oauth);
      expect(
        adapter.capabilityProfile.grantScope,
        VendorGrantScope.operatorWide,
      );
      expect(
        adapter.capabilityProfile.webhookSupport,
        VendorWebhookSupport.autoRegister,
      );
    });

    test('coversFieldExposed = false (labor systems do not expose covers)', () {
      expect(adapter.capabilityProfile.coversFieldExposed, false);
    });

    test('lifecycle = VendorLifecycle.documented (engineer-all-17 doctrine)',
        () {
      expect(adapter.capabilityProfile.lifecycle, VendorLifecycle.documented);
    });

    test('modules = [workforce_now, workforce_manager, run] '
        '(picker disambiguation; RUN refused at connect)', () {
      expect(adapter.capabilityProfile.modules, <String>[
        'workforce_now',
        'workforce_manager',
        'run',
      ]);
    });

    test('timestampPolicyDocId points at the per-vendor doc pack', () {
      expect(
        adapter.capabilityProfile.timestampPolicyDocId,
        'docs/integrations/adp/field_mapping.md',
      );
    });

    test('timestampPolicy declares refuse convention (assumed UTC, '
        'unverified)', () {
      expect(adapter.timestampPolicy.vendorId, 'adp');
      expect(
        adapter.timestampPolicy.ambiguousConvention,
        AmbiguousTimestampConvention.refuse,
      );
    });

    test('field-mapping constant mirrors fixture (every row carries '
        'verify_in_live_sandbox=true)', () {
      // The adapter constant carries the engineering source-of-truth;
      // the fixture mirror is what the *.live.sandbox slice will diff
      // against. Drift between them would silently break that diff.
      for (final entry
          in documentedPerAdpV1FieldMappingFixture.entries) {
        expect(
          documentedPerAdpV1FieldMapping.containsKey(entry.key),
          true,
          reason: 'fixture key "${entry.key}" missing from adapter constant',
        );
      }
      // Each canonical-field row carries the verify flag.
      for (final key in const <String>[
        'shift_start',
        'shift_end',
        'role_name',
        'employee_id',
        'vendor_entity_id',
        'vendor_modified_at',
      ]) {
        final row = documentedPerAdpV1FieldMapping[key]
            as Map<String, Object?>?;
        expect(row, isNotNull, reason: 'missing field-mapping row for $key');
        expect(row!['verify_in_live_sandbox'], true,
            reason: 'row "$key" must carry verify_in_live_sandbox: true');
      }
    });
  });

  group('Sanity hook contract (Tests 1, 2, 3)', () {
    late _FakeAdpTransport transport;
    late _FakeAdpGateway gateway;
    late AdpLaborAdapter adapter;
    late DateTime nowFixed;

    setUp(() {
      nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      transport = _FakeAdpTransport()
        ..pages = <AdpTimeEventsPage>[
          AdpTimeEventsPage(
            records: adpBackfillBatchPage1,
            nextCursor: 'cursor-page-2',
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
          ),
          AdpTimeEventsPage(
            records: adpBackfillBatchPage2,
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 3, 1, 30, 48),
          ),
        ];
      gateway = _FakeAdpGateway()
        ..accessToken = 'access-token-001'
        ..module = 'workforce_now';
      adapter = AdpLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );
    });

    test('Test 1 — sanity hook is called once per record on backfill',
        () async {
      final calls = <String>[];
      Future<bool> hook({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async {
        calls.add(vendorEventId);
        expect(isDeliberateBackfill, true,
            reason: 'backfill MUST flag isDeliberateBackfill: true');
        return true;
      }

      final result = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        adpBackfillBatchPage1.length + adpBackfillBatchPage2.length,
        reason: 'sanity hook must be called once per record across all pages',
      );
      expect(result.recordsWritten, 5);
      expect(result.batchesCommitted, 2);
    });

    test('Test 1 — sanity hook is called once per record on pollIncremental',
        () async {
      final calls = <String>[];
      Future<bool> hook({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async {
        calls.add(vendorEventId);
        expect(isDeliberateBackfill, false,
            reason: 'pollIncremental MUST pass isDeliberateBackfill: false');
        return true;
      }

      final result = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        adpBackfillBatchPage1.length + adpBackfillBatchPage2.length,
      );
      expect(result.recordsWritten, 5);
    });

    test('Test 1 (reject) — sanity hook returning false skips canonical write',
        () async {
      Future<bool> rejectAll({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async =>
          false;

      final result = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: rejectAll,
        ),
      );

      expect(result.recordsWritten, 0);
      expect(result.sanityDropped, 5);
      expect(gateway.canonicalFacts, isEmpty,
          reason: 'rejecting sanity must short-circuit before fact write');
    });

    test('Test 2 — same payload twice → single canonical write (idempotency)',
        () async {
      Future<bool> alwaysOk({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async =>
          true;

      // First poll consumes the pages.
      await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: alwaysOk,
        ),
      );
      expect(gateway.canonicalFacts.length, 5);

      // Replay: re-enqueue the exact same pages.
      transport.pages = <AdpTimeEventsPage>[
        AdpTimeEventsPage(
          records: adpBackfillBatchPage1,
          nextCursor: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
        AdpTimeEventsPage(
          records: adpBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 3, 1, 30, 48),
        ),
      ];
      final secondResult = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: alwaysOk,
        ),
      );
      expect(secondResult.recordsWritten, 0);
      expect(gateway.canonicalFacts.length, 5,
          reason: 'idempotency UNIQUE on (vendor_id, operator_id, '
              'vendor_entity_id, vendor_modified_at) must keep the row '
              'count at 5');
    });

    test('Test 3 — watermark persists per batch (mid-backfill crash resume)',
        () async {
      Future<bool> alwaysOk({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async =>
          true;

      // Inject a crash between page 1 and page 2.
      transport.crashAfterPageIndex = 0;
      transport.pages = <AdpTimeEventsPage>[
        AdpTimeEventsPage(
          records: adpBackfillBatchPage1,
          nextCursor: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
        AdpTimeEventsPage(
          records: adpBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 3, 1, 30, 48),
        ),
      ];

      try {
        await adapter.backfill(
          BackfillCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _opId,
            vendorId: 'adp',
            windowStart: nowFixed.subtract(const Duration(days: 60)),
            windowEnd: nowFixed,
            sanityHook: alwaysOk,
          ),
        );
        fail('expected mid-batch crash to throw');
      } on StateError catch (_) {
        // Expected — the crash simulates Cloud Run Job kill mid-window.
      }

      // Watermark should reflect page 1's commit, NOT page 2.
      final watermark = await gateway.readWatermark(
        operatorId: _opId,
        locationId: _locId,
      );
      expect(watermark, isNotNull);
      expect(watermark!.cursorToken, 'cursor-page-2');
      expect(
        watermark.lastModifiedSeen,
        // Max `last_modified_date_time` across page 1's records:
        // ADP-TE-9001 = 02:00:30, ADP-TE-9002 = 19:30:45, ADP-TE-9003
        // = 19:25:00 (record 3 was edited earlier than record 2).
        // The adapter advances `lastModifiedSeen` only when a record
        // strictly post-dates the running max, so the page 1
        // commit's watermark is record 2's modified-at.
        DateTime.utc(2026, 5, 1, 19, 30, 45),
        reason: 'watermark must reflect the latest last_modified_date_time '
            'observed in the batch that committed before the crash',
      );

      // Resume: backfill from the persisted cursor walks page 2 only.
      transport.crashAfterPageIndex = null;
      transport.pages = <AdpTimeEventsPage>[
        AdpTimeEventsPage(
          records: adpBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 3, 1, 30, 48),
        ),
      ];

      final resumeResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: alwaysOk,
          resumeFromCursor: watermark.cursorToken,
        ),
      );
      expect(
        resumeResult.recordsWritten,
        adpBackfillBatchPage2.length,
      );
      expect(resumeResult.batchesCommitted, 1);
    });
  });

  group('Webhook signature verifier (Test 4)', () {
    const verifier = AdpWebhookSignatureVerifier();
    final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);

    test('valid HMAC-SHA256 base64 signature → verified', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(adpTimeEventModifiedRawBody));
      final expected = base64.encode(
        Hmac(sha256, utf8.encode(_signingSecret)).convert(rawBody).bytes,
      );
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          'adp-signature': expected,
          'adp-event-id': 'evt-adp-001',
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
      expect(result.timestamp, isNull,
          reason: 'no adp-signature-timestamp present → null timestamp');
    });

    test('valid HMAC-SHA256 with epoch-second timestamp header → '
        'timestamp populated', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(adpTimeEventModifiedRawBody));
      final expected = base64.encode(
        Hmac(sha256, utf8.encode(_signingSecret)).convert(rawBody).bytes,
      );
      final epochSeconds = nowFixed.millisecondsSinceEpoch ~/ 1000;
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          'adp-signature': expected,
          'adp-signature-timestamp': epochSeconds.toString(),
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
      expect(result.timestamp, isNotNull);
      expect(result.timestamp!.toUtc(), nowFixed);
    });

    test('tampered signature → invalid + failure reason', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(adpTimeEventModifiedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          // Valid base64 shape, wrong digest (32 zero bytes encoded).
          'adp-signature': base64.encode(List<int>.filled(32, 0)),
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, isNotNull);
      expect(result.failureReason, contains('mismatch'));
    });

    test('missing ADP-Signature header → invalid', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(adpTimeEventModifiedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{},
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, contains('missing ADP-Signature'));
    });

    test('non-base64 signature → invalid', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(adpTimeEventModifiedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{
          'adp-signature': '!!!not-base64!!!',
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, contains('base64'));
    });

    test('Test 4 (framework end-to-end) — tampered HMAC dispatched through '
        'InboundWebhookHandler returns 403 + audit row + no canonical '
        'write', () async {
      final fakeWebhookGateway = _FakeWebhookGateway()
        ..bindings['adp'] = const ConnectionBinding(
          connectionId: 'adp-conn-1',
          metadata: <String, Object?>{
            'module': 'workforce_now',
          },
          status: ConnectionStatus.connected,
        )
        ..signingSecrets['adp'] = _signingSecret;

      final transport = _FakeAdpTransport();
      final gateway = _FakeAdpGateway()
        ..accessToken = 'access-token-001'
        ..module = 'workforce_now';
      final adapter = AdpLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      final handler = InboundWebhookHandler(
        gateway: fakeWebhookGateway,
        posAdapterFactories: const <String, PosAdapterFactory>{},
        laborAdapterFactories: <String, LaborAdapterFactory>{
          adapter.vendorId:
              ({required operatorId, required locationId}) => adapter,
        },
        reservationAdapterFactories:
            const <String, ReservationAdapterFactory>{},
        signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{
          'adp': verifier,
        },
        bindingExtractor: WebhookBindingExtractor(),
        now: () => nowFixed,
      );

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'adp',
        rawBody: Uint8List.fromList(
            utf8.encode(adpTimeEventModifiedRawBody)),
        payload: adpTimeEventModifiedPayload,
        headers: <String, String>{
          // Valid base64, wrong digest.
          'adp-signature': base64.encode(List<int>.filled(32, 0xAB)),
          'adp-event-id': 'evt-adp-tampered',
          'x-vendor-event-id': 'evt-adp-tampered',
        },
      );
      expect(result.outcome, WebhookOutcome.signatureInvalid);
      expect(result.statusCode, 403);
      expect(gateway.canonicalFacts, isEmpty);
      expect(
        fakeWebhookGateway.failedAttempts['evt-adp-tampered'],
        1,
      );
    });
  });

  group('Connect → backfill → poll → disconnect → reconnect smoke (Test 5)',
      () {
    test('full lifecycle preserves watermark across disconnect/reconnect '
        '(driven by workforce_now module)',
        () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final transport = _FakeAdpTransport()
        ..tokenResponse = AdpTokenResponse(
          accessToken: 'access-token-001',
          refreshToken: 'refresh-token-001',
          expiresAt: nowFixed.add(const Duration(hours: 1)),
        )
        ..pages = <AdpTimeEventsPage>[
          AdpTimeEventsPage(
            records: adpBackfillBatchPage1,
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
          ),
        ]
        ..registeredSubscriptionId = 'adp-sub-001';

      final gateway = _FakeAdpGateway();
      final adapter = AdpLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      // 1. Connect — OAuth callback completes, event subscription
      // auto-registered (WFN module).
      final connectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          module: 'workforce_now',
          oauthState: 'authorization-code-001',
        ),
      );
      expect(connectResult.status, ConnectionStatus.connected);
      expect(connectResult.firstBackfillStarted, true);
      expect(
        connectResult.metadata['event_subscription_id'],
        'adp-sub-001',
      );
      expect(connectResult.metadata['module'], 'workforce_now');

      // Bridge gateway state — production gateway would persist
      // ciphertext here.
      gateway.accessToken = 'access-token-001';
      gateway.module = 'workforce_now';

      // 2. Backfill
      transport.pages = <AdpTimeEventsPage>[
        AdpTimeEventsPage(
          records: adpBackfillBatchPage1,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
      ];
      final backfillResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: ({
            required vendorEventId,
            required payload,
            required isDeliberateBackfill,
          }) async =>
              true,
        ),
      );
      expect(
        backfillResult.recordsWritten,
        adpBackfillBatchPage1.length,
      );

      // 3. Poll (no new rows — empty page)
      transport.pages = <AdpTimeEventsPage>[
        AdpTimeEventsPage(
          records: const <Map<String, Object?>>[],
          nextCursor: null,
          lastModifiedSeen: nowFixed.subtract(const Duration(days: 1)),
        ),
      ];
      final pollResult = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          lastModifiedSeen: backfillResult.lastModifiedSeen,
          sanityHook: ({
            required vendorEventId,
            required payload,
            required isDeliberateBackfill,
          }) async =>
              true,
        ),
      );
      expect(pollResult.recordsWritten, 0);

      // 4. Disconnect — credentials wiped, watermark preserved.
      final preDisconnectWatermark = await gateway.readWatermark(
        operatorId: _opId,
        locationId: _locId,
      );
      expect(preDisconnectWatermark, isNotNull);

      final disconnectResult = await adapter.disconnect(
        const DisconnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          reason: DisconnectReason.operatorAction,
        ),
      );
      expect(disconnectResult.credentialsWiped, true);
      expect(disconnectResult.watermarkPreserved, true);
      expect(gateway.accessToken, isNull,
          reason: 'wipeCredentials must clear the in-memory token');

      // 5. Reconnect — fresh OAuth callback, watermark survives.
      transport.tokenResponse = AdpTokenResponse(
        accessToken: 'access-token-002',
        refreshToken: 'refresh-token-002',
        expiresAt: nowFixed.add(const Duration(hours: 1)),
      );
      transport.pages = <AdpTimeEventsPage>[
        AdpTimeEventsPage(
          records: adpBackfillBatchPage1,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
      ];
      final reconnectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          module: 'workforce_now',
          oauthState: 'authorization-code-002',
        ),
      );
      expect(reconnectResult.status, ConnectionStatus.connected);
      final postReconnectWatermark = await gateway.readWatermark(
        operatorId: _opId,
        locationId: _locId,
      );
      expect(postReconnectWatermark, isNotNull);
      expect(
        postReconnectWatermark!.lastModifiedSeen,
        preDisconnectWatermark!.lastModifiedSeen,
      );
    });
  });

  group('Test connection (Test 6)', () {
    test('populates fieldMapping with shift_start + shift_end + role_name + '
        'assumption=true and returns under 30s on the offline path',
        () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final transport = _FakeAdpTransport()
        ..sample = adpSampleTimeEvent;
      final gateway = _FakeAdpGateway()
        ..accessToken = 'access-token-001'
        ..module = 'workforce_now';
      final adapter = AdpLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      final result = await adapter.testConnection(
        const TestConnectionCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
        ),
      );

      expect(result.authValid, true);
      expect(
        result.fieldMapping['shift_start'],
        '2026-05-04T15:00:00.000Z',
      );
      expect(
        result.fieldMapping['shift_end'],
        '2026-05-04T23:00:00.000Z',
      );
      expect(result.fieldMapping['role_name'], 'Server');
      expect(
        result.fieldMapping['employee_id'],
        'G3WXX1Y2Z3A4B5C6',
      );
      expect(
        result.fieldMapping['vendor_entity_id'],
        'ADP-TE-12345',
      );
      expect(result.fieldMapping['module'], 'workforce_now');
      expect(result.fieldMapping['assumption'], true,
          reason: 'every documented field carries verify_in_live_sandbox; '
              'the test-connection modal must surface this so operators '
              'understand the adapter is engineered against assumptions');
      expect(result.elapsedMs, lessThan(30000));
    });
  });

  group('Replay window (Test 7)', () {
    test('framework replay ceiling stays at 24h per V1 lean cut 2', () {
      expect(kInboundWebhookReplayCeiling, const Duration(hours: 24));
    });
  });

  group('Module disambiguation (Test 8 — CONTRACT-REQUIRED)', () {
    final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);

    Future<ConnectResult> connectWithModule(String module) async {
      final transport = _FakeAdpTransport()
        ..tokenResponse = AdpTokenResponse(
          accessToken: 'access-token-${module.hashCode}',
          refreshToken: 'refresh-token-${module.hashCode}',
          expiresAt: nowFixed.add(const Duration(hours: 1)),
        )
        ..registeredSubscriptionId = 'adp-sub-${module.hashCode}'
        ..pages = const <AdpTimeEventsPage>[];
      final gateway = _FakeAdpGateway();
      final adapter = AdpLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );
      return adapter.connect(
        ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'adp',
          module: module,
          oauthState: 'authorization-code-${module.hashCode}',
        ),
      );
    }

    test('module: workforce_now → connect succeeds, metadata.module '
        'persisted', () async {
      final result = await connectWithModule('workforce_now');
      expect(result.status, ConnectionStatus.connected);
      expect(result.metadata['module'], 'workforce_now');
    });

    test('module: workforce_manager → connect succeeds, metadata.module '
        'persisted', () async {
      final result = await connectWithModule('workforce_manager');
      expect(result.status, ConnectionStatus.connected);
      expect(result.metadata['module'], 'workforce_manager');
    });

    test('module: run → ModuleRefusalException with EXACT friendly copy '
        'from vendor_master_list.md', () async {
      // The exact string from `docs/phases/phase_8/vendor_master_list.md`
      // "Module Disambiguation Flags" section. Pinned word-for-word so
      // any drift in the operator-facing copy fails the test.
      const expectedCopy =
          'ADP RUN is a payroll-only product. Forge & Flow needs schedule '
          'and time-punch data. If you also use ADP Workforce Now or '
          'Workforce Manager, connect that instead. Otherwise, please '
          'use one of these supported scheduling vendors: [list].';

      // The constant in the adapter must equal the master-list copy.
      expect(kAdpRunRefusalCopy, expectedCopy);

      // Invoking connect with module=run throws the typed exception.
      final transport = _FakeAdpTransport();
      final gateway = _FakeAdpGateway();
      final adapter = AdpLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      try {
        await adapter.connect(
          const ConnectCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _opId,
            vendorId: 'adp',
            module: 'run',
            oauthState: 'authorization-code-run',
          ),
        );
        fail('expected ModuleRefusalException for module=run');
      } on ModuleRefusalException catch (e) {
        expect(e.vendorId, 'adp');
        expect(e.moduleId, 'run');
        expect(e.message, expectedCopy);
      }
    });

    test('module: unknown future module → ModuleRefusalException (defense '
        'against silent acceptance of new ADP products)', () async {
      final transport = _FakeAdpTransport();
      final gateway = _FakeAdpGateway();
      final adapter = AdpLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      try {
        await adapter.connect(
          const ConnectCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _opId,
            vendorId: 'adp',
            module: 'lyric',
            oauthState: 'authorization-code-lyric',
          ),
        );
        fail('expected ModuleRefusalException for unknown module');
      } on ModuleRefusalException catch (e) {
        expect(e.vendorId, 'adp');
        expect(e.moduleId, 'lyric');
        expect(e.message, contains('Unknown ADP module'));
      }
    });
  });

  group('Banned items grep (Test 10)', () {
    final adapterFile = File(
      'lib/integrations/labor/adp_labor_adapter.dart',
    );
    final verifierFile = File(
      'lib/integrations/labor/adp_webhook_signature_verifier.dart',
    );

    Iterable<String> bannedSubstrings() => const <String>[
          // V1 lean cut 2 banned items.
          'parse_warnings',
          'parse_partial',
          'pg_try_advisory_lock',
          'sigterm',
          'kms.encrypt',
          'rotate_signing_key',
          // Banned timing pattern.
          'replay_strict_5min',
        ];

    test('adapter source contains zero banned substrings', () {
      final body = adapterFile.readAsStringSync().toLowerCase();
      for (final banned in bannedSubstrings()) {
        expect(body.contains(banned), false,
            reason: 'banned substring "$banned" must not appear in '
                'adapter source per V1 lean cut 2');
      }
    });

    test('verifier source contains zero banned substrings', () {
      final body = verifierFile.readAsStringSync().toLowerCase();
      for (final banned in bannedSubstrings()) {
        expect(body.contains(banned), false,
            reason: 'banned substring "$banned" must not appear in '
                'verifier source per V1 lean cut 2');
      }
    });

    test('adapter does not import package:postgres directly', () {
      final body = adapterFile.readAsStringSync();
      expect(
        body.contains("package:postgres/"),
        false,
        reason: 'package:postgres imports are restricted to '
            'lib/infrastructure/persistence/postgres/ per the '
            'service-layer split (CLAUDE.md)',
      );
    });
  });
}

// ─── Fakes ──────────────────────────────────────────────────────────

class _FakeAdpTransport implements AdpTransport {
  AdpTokenResponse? tokenResponse;
  List<AdpTimeEventsPage> _pages = <AdpTimeEventsPage>[];
  Map<String, Object?> sample = const <String, Object?>{};
  String? registeredSubscriptionId;
  int? crashAfterPageIndex;
  int _pageCursor = 0;

  set pages(List<AdpTimeEventsPage> next) {
    _pages = next;
    _pageCursor = 0;
  }

  List<AdpTimeEventsPage> get pages => _pages;

  @override
  Future<AdpTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
    required String module,
  }) async {
    return tokenResponse ??
        AdpTokenResponse(
          accessToken: 'access-token-fake',
          refreshToken: 'refresh-token-fake',
          expiresAt: DateTime.utc(2026, 5, 5, 12, 0, 0),
        );
  }

  @override
  Future<AdpTokenResponse> refresh({
    required String refreshToken,
    required String module,
  }) async {
    return tokenResponse ??
        AdpTokenResponse(
          accessToken: 'access-token-refreshed',
          refreshToken: 'refresh-token-refreshed',
          expiresAt: DateTime.utc(2026, 5, 5, 12, 0, 0),
        );
  }

  @override
  Future<void> revoke({required String accessToken}) async {}

  @override
  Future<AdpTimeEventsPage> listTimeEvents({
    required String accessToken,
    required String module,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    if (_pageCursor >= _pages.length) {
      return AdpTimeEventsPage(
        records: const <Map<String, Object?>>[],
        nextCursor: null,
        lastModifiedSeen: modifiedSince,
      );
    }
    final page = _pages[_pageCursor];
    _pageCursor += 1;
    if (crashAfterPageIndex != null &&
        _pageCursor - 1 == crashAfterPageIndex) {
      crashAfterPageIndex = -1;
      return page;
    }
    if (crashAfterPageIndex == -1) {
      throw StateError('simulated mid-batch crash');
    }
    return page;
  }

  @override
  Future<Map<String, Object?>> fetchWorker({
    required String accessToken,
    required String module,
    required String associateOid,
  }) async {
    return sample;
  }

  @override
  Future<String> registerEventSubscription({
    required String accessToken,
    required String module,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async {
    return registeredSubscriptionId ?? 'adp-sub-fake';
  }

  @override
  Future<void> unregisterEventSubscription({
    required String accessToken,
    required String module,
    required String subscriptionId,
  }) async {}

  @override
  Future<Map<String, Object?>> sampleTimeEvent({
    required String accessToken,
    required String module,
  }) async {
    return sample.isEmpty ? adpSampleTimeEvent : sample;
  }
}

class _FakeAdpGateway implements AdpGateway {
  String? accessToken;
  String? module;
  AdpConnectionRow? connection;
  AdpWatermarkRow? watermark;
  final List<AdpCanonicalTimePunchFact> canonicalFacts =
      <AdpCanonicalTimePunchFact>[];
  final Set<String> _idempotencyKeys = <String>{};

  @override
  Future<AdpConnectionRow> upsertConnection({
    required AdpConnectionRow row,
  }) async {
    connection = row;
    module = row.module;
    return row;
  }

  @override
  Future<AdpWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) async =>
      watermark;

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required AdpWatermarkRow row,
  }) async {
    watermark = row;
  }

  @override
  Future<bool> writeTimePunchFact(
    AdpCanonicalTimePunchFact fact,
  ) async {
    final key =
        '${fact.operatorId}:${fact.locationId}:${fact.vendorEntityId}:${fact.vendorModifiedAt.toIso8601String()}';
    if (_idempotencyKeys.contains(key)) {
      return false;
    }
    _idempotencyKeys.add(key);
    canonicalFacts.add(fact);
    return true;
  }

  @override
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  }) async {
    accessToken = null;
  }

  @override
  Future<String?> readAccessToken({
    required String operatorId,
    required String locationId,
  }) async =>
      accessToken;

  @override
  Future<String?> readModule({
    required String operatorId,
    required String locationId,
  }) async =>
      module;
}

// ─── Inbound webhook framework fake (mirrors Phase 8.0 tests) ────────

class _FakeWebhookGateway implements InboundWebhookGateway {
  final Map<String, ConnectionBinding> bindings =
      <String, ConnectionBinding>{};
  final Map<String, String> signingSecrets = <String, String>{};
  final Map<String, int> failedAttempts = <String, int>{};
  final List<Map<String, Object?>> deadLetterCalls =
      <Map<String, Object?>>[];

  @override
  Future<ConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    return bindings[vendorId];
  }

  @override
  Future<String?> lookupSigningSecret({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    return signingSecrets[vendorId];
  }

  @override
  Future<IdempotencyOutcome> claimIdempotency({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) async {
    return IdempotencyOutcome.firstTime;
  }

  @override
  Future<void> markProcessed({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) async {}

  @override
  Future<void> recordSanityDrop({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String rule,
    required Map<String, Object?> payloadSummary,
  }) async {}

  @override
  Future<int> recordFailedAttempt({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String failureMessage,
    required DateTime receivedAt,
  }) async {
    failedAttempts[vendorEventId] = (failedAttempts[vendorEventId] ?? 0) + 1;
    return failedAttempts[vendorEventId]!;
  }

  @override
  Future<void> deadLetter({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required Map<String, Object?> payloadPreview,
    required InboundWebhookFailureKind failureKind,
    required String failureMessage,
  }) async {
    deadLetterCalls.add(<String, Object?>{
      'vendor_event_id': vendorEventId,
      'failure_kind': failureKind,
    });
  }

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
}
