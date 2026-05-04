// Phase 8.RV — RevelPosAdapter + RevelWebhookSignatureVerifier tests.
//
// Drives the adapter against fixture-driven fakes (no live HTTP, no
// Postgres) to prove every framework call required by
// `docs/contracts/vendor_adapter_slice_contract.md`:
//
//   1. Sanity hook called per record on backfill + poll, reject path
//      skips the canonical write.
//   2. Idempotency UNIQUE on canonical fact upsert
//      (`(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`).
//   3. Watermark per batch commit (mid-batch crash → resume from last
//      persisted cursor).
//   4. Webhook signature constant-time HMAC compare; tampered
//      signature 403.
//   5. OperatorScopedRepository `withTenant` indirection (asserted via
//      gateway shape — no `package:postgres` import in adapter).
//   6. Capability profile declares every required field.
//
// Plus the slice-specific tests required by the prompt:
//
//   * Connect → backfill → poll → disconnect → reconnect smoke.
//   * Test connection populates fieldMapping in <30s on the offline
//     path.
//   * Replay window — framework constant pinned at 24h; the adapter
//     verifier returns null timestamp because Revel does not bind one
//     into the signed payload.
//   * 24h client_credentials token refresh: token at
//     `expires_at = now + 30min` triggers refresh by the framework's
//     `OAuthRefreshCronRunner`.
//   * Banned-items grep pinned at the source-file level.
//
// All fixtures cite their doc URL + retrieval date at the top of
// `revel_orders_fixture.dart` / `revel_webhook_fixture.dart`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/revel_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/revel_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';
import 'package:forge_and_flow/services/integration/oauth_refresh_cron.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';
import 'package:forge_and_flow/services/integration/reservation_adapter.dart';
import 'package:forge_and_flow/services/integration/vendor_timestamp_policy.dart';

import 'fixtures/revel_orders_fixture.dart';
import 'fixtures/revel_webhook_fixture.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _signingSecret = 'whsec_revel_test_001';

void main() {
  group('VendorCapabilityProfile (Test 9)', () {
    final adapter = RevelPosAdapter(
      transport: _FakeRevelTransport(),
      gateway: _FakeRevelGateway(),
    );

    test('vendorId / displayName / category / authMode / scope / webhook', () {
      expect(adapter.vendorId, 'revel');
      expect(adapter.displayName, 'Revel Systems');
      expect(adapter.capabilityProfile.category, IntegrationCategory.pos);
      expect(adapter.capabilityProfile.authMode, VendorAuthMode.oauth);
      expect(
        adapter.capabilityProfile.grantScope,
        VendorGrantScope.perLocation,
      );
      expect(
        adapter.capabilityProfile.webhookSupport,
        VendorWebhookSupport.autoRegister,
      );
    });

    test('coversFieldExposed = true (number_of_people, direct mapping)', () {
      expect(adapter.capabilityProfile.coversFieldExposed, true);
    });

    test('lifecycle = VendorLifecycle.documented (engineer-all-17 doctrine)',
        () {
      expect(adapter.lifecycle, VendorLifecycle.documented);
    });

    test('partnershipGated = false (Revel is self-serve OAuth)', () {
      expect(adapter.capabilityProfile.partnershipGated, false);
    });

    test('modules empty (no module disambiguation)', () {
      expect(adapter.capabilityProfile.modules, isEmpty);
    });

    test('timestampPolicyDocId points at the per-vendor doc pack', () {
      expect(
        adapter.capabilityProfile.timestampPolicyDocId,
        'docs/integrations/revel/field_mapping.md',
      );
    });

    test('timestampPolicy declares asUtc convention', () {
      expect(adapter.timestampPolicy.vendorId, 'revel');
      expect(
        adapter.timestampPolicy.ambiguousConvention,
        AmbiguousTimestampConvention.asUtc,
      );
    });
  });

  group('Sanity hook contract (Tests 1, 2, 3)', () {
    late _FakeRevelTransport transport;
    late _FakeRevelGateway gateway;
    late RevelPosAdapter adapter;
    late DateTime nowFixed;

    setUp(() {
      nowFixed = DateTime.utc(2026, 5, 3, 12, 0, 0);
      transport = _FakeRevelTransport()
        ..pages = <RevelOrdersPage>[
          RevelOrdersPage(
            records: revelBackfillBatchPage1,
            nextCursor: 'cursor-page-2',
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
          ),
          RevelOrdersPage(
            records: revelBackfillBatchPage2,
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
          ),
        ];
      gateway = _FakeRevelGateway()..accessToken = 'access-token-001';
      adapter = RevelPosAdapter(
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
          vendorId: 'revel',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        revelBackfillBatchPage1.length + revelBackfillBatchPage2.length,
        reason: 'sanity hook must be called once per record across all '
            'pages',
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
          vendorId: 'revel',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        revelBackfillBatchPage1.length + revelBackfillBatchPage2.length,
      );
      expect(result.recordsWritten, 5);
    });

    test(
        'Test 1 (reject) — sanity hook returning false skips canonical write',
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
          vendorId: 'revel',
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

      // First poll consumes the page.
      await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'revel',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: alwaysOk,
        ),
      );
      expect(gateway.canonicalFacts.length, 5);

      // Replay: re-enqueue the exact same pages.
      transport.pages = <RevelOrdersPage>[
        RevelOrdersPage(
          records: revelBackfillBatchPage1,
          nextCursor: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
        RevelOrdersPage(
          records: revelBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
        ),
      ];
      final secondResult = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'revel',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: alwaysOk,
        ),
      );
      // Idempotency upsert short-circuits — writes counted are zero.
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
      transport.pages = <RevelOrdersPage>[
        RevelOrdersPage(
          records: revelBackfillBatchPage1,
          nextCursor: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
        RevelOrdersPage(
          records: revelBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
        ),
      ];

      try {
        await adapter.backfill(
          BackfillCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _opId,
            vendorId: 'revel',
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
        DateTime.utc(2026, 5, 1, 19, 25, 0),
        reason: 'watermark must reflect last-modified of the batch '
            'that committed before the crash',
      );

      // Resume: the next backfill starts from the persisted cursor and
      // walks page 2 only.
      transport.crashAfterPageIndex = null;
      transport.pages = <RevelOrdersPage>[
        RevelOrdersPage(
          records: revelBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
        ),
      ];

      final resumeResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'revel',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: alwaysOk,
          resumeFromCursor: watermark.cursorToken,
        ),
      );
      expect(resumeResult.recordsWritten, revelBackfillBatchPage2.length);
      expect(resumeResult.batchesCommitted, 1);
    });
  });

  group('Webhook signature verifier (Test 4)', () {
    const verifier = RevelWebhookSignatureVerifier();
    final nowFixed = DateTime.utc(2026, 5, 3, 12, 0, 0);

    test('valid HMAC-SHA1 hex signature → verified, timestamp null', () {
      final rawBody = Uint8List.fromList(utf8.encode(revelOrderFinalizedRawBody));
      final expected = Hmac(sha1, utf8.encode(_signingSecret))
          .convert(rawBody)
          .toString();
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          'x-revel-signature': expected,
          'x-revel-event-type': 'order.finalized',
          'x-revel-event-id': 'evt-revel-001',
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
      expect(result.timestamp, isNull,
          reason: 'Revel does not bind a timestamp into the signed '
              'payload — verifier returns null timestamp by design');
    });

    test('tampered signature → invalid + failure reason', () {
      final rawBody = Uint8List.fromList(utf8.encode(revelOrderFinalizedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          'x-revel-signature': 'a' * 40, // valid hex shape, wrong digest
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, isNotNull);
      expect(result.failureReason, contains('mismatch'));
    });

    test('missing X-Revel-Signature header → invalid', () {
      final rawBody = Uint8List.fromList(utf8.encode(revelOrderFinalizedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{},
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, contains('missing X-Revel-Signature'));
    });

    test('non-hex signature → invalid', () {
      final rawBody = Uint8List.fromList(utf8.encode(revelOrderFinalizedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{
          'x-revel-signature': 'this-is-not-hex',
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, contains('hexadecimal'));
    });

    test('Test 4 (framework end-to-end) — tampered HMAC dispatched through '
        'InboundWebhookHandler returns 403 + audit row + no canonical '
        'write', () async {
      final fakeWebhookGateway = _FakeWebhookGateway()
        ..bindings['revel'] = const ConnectionBinding(
          connectionId: 'revel-conn-1',
          metadata: <String, Object?>{
            'instance_name': 'demo-instance',
          },
          status: ConnectionStatus.connected,
        )
        ..signingSecrets['revel'] = _signingSecret;

      final transport = _FakeRevelTransport();
      final gateway = _FakeRevelGateway()..accessToken = 'access-token-001';
      final adapter = RevelPosAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      final handler = InboundWebhookHandler(
        gateway: fakeWebhookGateway,
        posAdapters: <String, PosAdapter>{adapter.vendorId: adapter},
        laborAdapters: const <String, LaborAdapter>{},
        reservationAdapters: const <String, ReservationAdapter>{},
        signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{
          'revel': verifier,
        },
        bindingExtractor: WebhookBindingExtractor(),
        now: () => nowFixed,
      );

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'revel',
        rawBody: Uint8List.fromList(utf8.encode(revelOrderFinalizedRawBody)),
        payload: revelOrderFinalizedPayload,
        headers: const <String, String>{
          // 40 hex chars (HMAC-SHA1 width) but wrong digest.
          'x-revel-signature': 'beefcafebeefcafebeefcafebeefcafebeefcafe',
          'x-revel-event-id': 'evt-revel-tampered',
          // The proxy route layer maps Revel's `X-Revel-Event-Id` to
          // the framework's standard `x-vendor-event-id` so the
          // inbound handler can key idempotency / failed-attempt rows
          // without re-parsing the body.
          'x-vendor-event-id': 'evt-revel-tampered',
        },
      );
      expect(result.outcome, WebhookOutcome.signatureInvalid);
      expect(result.statusCode, 403);
      expect(gateway.canonicalFacts, isEmpty);
      expect(fakeWebhookGateway.failedAttempts['evt-revel-tampered'], 1);
    });
  });

  group('Connect → backfill → poll → disconnect → reconnect smoke (Test 5)',
      () {
    test('full lifecycle preserves watermark across disconnect/reconnect',
        () async {
      final nowFixed = DateTime.utc(2026, 5, 3, 12, 0, 0);
      final transport = _FakeRevelTransport()
        ..tokenResponse = RevelTokenResponse(
          accessToken: 'access-token-001',
          expiresAt: nowFixed.add(const Duration(hours: 24)),
        )
        ..pages = <RevelOrdersPage>[
          RevelOrdersPage(
            records: revelBackfillBatchPage1,
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
          ),
        ]
        ..registeredSubscriptionId = 'rev-sub-001';

      final gateway = _FakeRevelGateway();
      final adapter = RevelPosAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      // 1. Connect
      final connectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'revel',
          keyPaste: ConnectKeyPasteCredential(
            apiKey: 'test-client-id',
            username: 'test-client-secret',
          ),
        ),
      );
      expect(connectResult.status, ConnectionStatus.connected);
      expect(connectResult.firstBackfillStarted, true);
      expect(
        connectResult.metadata['webhook_subscription_id'],
        'rev-sub-001',
      );

      // Bridge gateway state — production gateway would persist
      // ciphertext here. The fake captures the connect-time access
      // token so backfill / poll can read it back.
      gateway.accessToken = 'access-token-001';

      // 2. Backfill
      transport.pages = <RevelOrdersPage>[
        RevelOrdersPage(
          records: revelBackfillBatchPage1,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
      ];
      final backfillResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'revel',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: ({required vendorEventId, required payload, required isDeliberateBackfill}) async => true,
        ),
      );
      expect(backfillResult.recordsWritten, revelBackfillBatchPage1.length);

      // 3. Poll (no new rows — empty page)
      transport.pages = <RevelOrdersPage>[
        RevelOrdersPage(
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
          vendorId: 'revel',
          lastModifiedSeen:
              backfillResult.lastModifiedSeen,
          sanityHook: ({required vendorEventId, required payload, required isDeliberateBackfill}) async => true,
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
          vendorId: 'revel',
          reason: DisconnectReason.operatorAction,
        ),
      );
      expect(disconnectResult.credentialsWiped, true);
      expect(disconnectResult.watermarkPreserved, true);
      expect(gateway.accessToken, isNull,
          reason: 'wipeCredentials must clear the in-memory token');

      // 5. Reconnect — the watermark from before disconnect is still
      // there. A fresh connect provisions a new access token.
      transport.tokenResponse = RevelTokenResponse(
        accessToken: 'access-token-002',
        expiresAt: nowFixed.add(const Duration(hours: 24)),
      );
      transport.pages = <RevelOrdersPage>[
        RevelOrdersPage(
          records: revelBackfillBatchPage1,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
      ];
      final reconnectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'revel',
          keyPaste: ConnectKeyPasteCredential(
            apiKey: 'test-client-id',
            username: 'test-client-secret',
          ),
        ),
      );
      expect(reconnectResult.status, ConnectionStatus.connected);
      // Watermark survived the disconnect cycle.
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
    test('populates fieldMapping with covers + opened_at + closed_at + '
        'returns under 30s on the offline path', () async {
      final nowFixed = DateTime.utc(2026, 5, 3, 12, 0, 0);
      final transport = _FakeRevelTransport()
        ..sample = revelSampleOrder;
      final gateway = _FakeRevelGateway()..accessToken = 'access-token-001';
      final adapter = RevelPosAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      final result = await adapter.testConnection(
        const TestConnectionCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'revel',
        ),
      );

      expect(result.authValid, true);
      expect(result.fieldMapping['covers'], 3);
      expect(result.fieldMapping['opened_at'], '2026-05-02T18:45:00.000Z');
      expect(result.fieldMapping['closed_at'], '2026-05-02T19:31:00.000Z');
      expect(result.fieldMapping['actual_sales'], 64.30);
      expect(result.fieldMapping['vendor_entity_id'], '8842301');
      expect(result.elapsedMs, lessThan(30000));
    });
  });

  group('Replay window (Test 7)', () {
    test('framework replay ceiling stays at 24h per V1 lean cut 2', () {
      expect(kInboundWebhookReplayCeiling, const Duration(hours: 24));
    });

    test('Revel verifier returns null timestamp (no signed timestamp)', () {
      const verifier = RevelWebhookSignatureVerifier();
      final rawBody = Uint8List.fromList(utf8.encode(revelOrderFinalizedRawBody));
      final expected = Hmac(sha1, utf8.encode(_signingSecret))
          .convert(rawBody)
          .toString();
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{'x-revel-signature': expected},
        signingSecret: _signingSecret,
        now: DateTime.utc(2026, 5, 3, 12, 0, 0),
      );
      expect(result.valid, true);
      expect(
        result.timestamp,
        isNull,
        reason: 'Revel does not sign a timestamp; framework idempotency '
            'UNIQUE is the duplicate-write defense for legitimate '
            'retries (kInboundWebhookReplayCeiling stays at 24h but is '
            'only enforced when a verifier reports a timestamp).',
      );
    });
  });

  group('OAuth refresh — 24h client_credentials (Test 8)', () {
    test('token at expires_at = now + 30min triggers refresh by the cron '
        'runner', () async {
      final nowFixed = DateTime.utc(2026, 5, 3, 12, 0, 0);
      final transport = _FakeRevelTransport()
        ..tokenResponse = RevelTokenResponse(
          accessToken: 'refreshed-token-001',
          expiresAt: nowFixed.add(const Duration(hours: 24)),
        );
      final refreshGateway = _FakeOAuthRefreshGateway()
        ..expiringRows.add(
          VendorCredentialRefreshRow(
            credentialId: 'cred-001',
            operatorId: _opId,
            locationId: _locId,
            vendorId: 'revel',
            module: null,
            // 30min from now is well inside the 24h horizon scanned
            // by the runner.
            tokenExpiresAt: nowFixed.add(const Duration(minutes: 30)),
            consecutiveFailures: 0,
            refreshTokenCiphertext: const <int>[1, 2, 3],
          ),
        );

      Future<RevelCredentialEnvelope?> lookup({
        required String operatorId,
        String? locationId,
      }) async {
        return const RevelCredentialEnvelope(
          clientId: 'test-client-id',
          clientSecret: 'test-client-secret',
        );
      }

      final refresher = RevelOAuthRefresher(
        transport: transport,
        lookupCredentialEnvelope: lookup,
      );
      final runner = OAuthRefreshCronRunner(
        gateway: refreshGateway,
        refreshers: <String, VendorOAuthRefresher>{
          refresher.vendorId: refresher,
        },
        now: () => nowFixed,
      );

      final tick = await runner.runOnce();
      expect(tick.candidatesScanned, 1);
      expect(tick.refreshSuccesses, 1);
      expect(tick.refreshFailures, 0);
      expect(refreshGateway.successCalls.length, 1);
      expect(
        refreshGateway.successCalls.single['vendor_id'],
        'revel',
      );
      // The new envelope encodes the refreshed access token.
      final newAccessCipher =
          refreshGateway.successCalls.single['new_access']! as List<int>;
      expect(utf8.decode(newAccessCipher), 'refreshed-token-001');
    });
  });

  group('Banned items grep (Test 10)', () {
    final adapterFile = File(
      'lib/integrations/pos/revel_pos_adapter.dart',
    );
    final verifierFile = File(
      'lib/integrations/pos/revel_webhook_signature_verifier.dart',
    );

    Iterable<String> bannedSubstrings() => const <String>[
          // V1 lean cut 2 banned items.
          'parse_warnings',
          'parse_partial',
          'pg_try_advisory_lock',
          'sigterm',
          'kms.encrypt',
          'rotate_signing_key',
          // Banned timing patterns.
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

class _FakeRevelTransport implements RevelTransport {
  RevelTokenResponse? tokenResponse;
  List<RevelOrdersPage> _pages = <RevelOrdersPage>[];
  Map<String, Object?> sample = const <String, Object?>{};
  String? registeredSubscriptionId;
  int? crashAfterPageIndex;
  int _pageCursor = 0;

  /// Resets the page cursor whenever the test re-stages the transport.
  /// Without the reset, subsequent calls would index past the new
  /// list's bounds and the adapter's loop would early-exit.
  set pages(List<RevelOrdersPage> next) {
    _pages = next;
    _pageCursor = 0;
  }

  List<RevelOrdersPage> get pages => _pages;

  @override
  Future<RevelTokenResponse> exchangeClientCredentials({
    required String clientId,
    required String clientSecret,
    required String audience,
  }) async {
    return tokenResponse ??
        RevelTokenResponse(
          accessToken: 'access-token-fake',
          expiresAt: DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
  }

  @override
  Future<RevelOrdersPage> listOrders({
    required String accessToken,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    if (_pageCursor >= _pages.length) {
      return RevelOrdersPage(
        records: const <Map<String, Object?>>[],
        nextCursor: null,
        lastModifiedSeen: modifiedSince,
      );
    }
    final page = _pages[_pageCursor];
    _pageCursor += 1;
    if (crashAfterPageIndex != null &&
        _pageCursor - 1 == crashAfterPageIndex) {
      // Allow the page to be returned (so the watermark commits), but
      // throw on the NEXT call to simulate Cloud Run Job kill mid-window.
      crashAfterPageIndex = -1;
      return page;
    }
    if (crashAfterPageIndex == -1) {
      throw StateError('simulated mid-batch crash');
    }
    return page;
  }

  @override
  Future<Map<String, Object?>> fetchOrder({
    required String accessToken,
    required String orderId,
  }) async {
    return sample;
  }

  @override
  Future<String> registerWebhook({
    required String accessToken,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async {
    return registeredSubscriptionId ?? 'rev-sub-fake';
  }

  @override
  Future<void> unregisterWebhook({
    required String accessToken,
    required String subscriptionId,
  }) async {}

  @override
  Future<Map<String, Object?>> sampleOrder({
    required String accessToken,
  }) async {
    return sample.isEmpty ? revelSampleOrder : sample;
  }
}

class _FakeRevelGateway implements RevelGateway {
  String? accessToken;
  RevelConnectionRow? connection;
  RevelWatermarkRow? watermark;
  final List<RevelCanonicalOrderFact> canonicalFacts =
      <RevelCanonicalOrderFact>[];
  final Set<String> _idempotencyKeys = <String>{};

  @override
  Future<RevelConnectionRow> upsertConnection({
    required RevelConnectionRow row,
  }) async {
    connection = row;
    return row;
  }

  @override
  Future<RevelWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) async =>
      watermark;

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required RevelWatermarkRow row,
  }) async {
    watermark = row;
  }

  @override
  Future<bool> writeOrderFact(RevelCanonicalOrderFact fact) async {
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
}

class _FakeOAuthRefreshGateway implements OAuthRefreshGateway {
  final List<VendorCredentialRefreshRow> expiringRows =
      <VendorCredentialRefreshRow>[];
  final List<Map<String, Object?>> successCalls = <Map<String, Object?>>[];
  final List<Map<String, Object?>> failureCalls = <Map<String, Object?>>[];
  final List<Map<String, Object?>> autoDisableCalls =
      <Map<String, Object?>>[];

  @override
  Future<List<VendorCredentialRefreshRow>> findExpiringCredentials({
    required DateTime now,
    required Duration horizon,
  }) async {
    return expiringRows
        .where((row) =>
            row.tokenExpiresAt != null &&
            row.tokenExpiresAt!.isBefore(now.add(horizon)))
        .toList();
  }

  @override
  Future<void> recordRefreshSuccess({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required List<int> newAccessTokenCiphertext,
    required List<int> newRefreshTokenCiphertext,
    required DateTime newExpiresAt,
  }) async {
    successCalls.add(<String, Object?>{
      'credential_id': credentialId,
      'vendor_id': vendorId,
      'new_access': newAccessTokenCiphertext,
      'new_refresh': newRefreshTokenCiphertext,
      'new_expires_at': newExpiresAt,
    });
  }

  @override
  Future<int> recordRefreshFailure({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required String errorMessage,
  }) async {
    failureCalls.add(<String, Object?>{
      'credential_id': credentialId,
      'error': errorMessage,
    });
    return failureCalls.length;
  }

  @override
  Future<void> autoDisableConnection({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required String errorMessage,
  }) async {
    autoDisableCalls.add(<String, Object?>{
      'credential_id': credentialId,
      'vendor_id': vendorId,
    });
  }
}

// ─── Inbound webhook framework fake (reused from Phase 8.0 tests) ────

class _FakeWebhookGateway implements InboundWebhookGateway {
  final Map<String, ConnectionBinding> bindings = <String, ConnectionBinding>{};
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
