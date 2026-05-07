// Phase 8R.OT — OpenTableReservationAdapter +
// OpenTableWebhookSignatureVerifier tests.
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
//   5. OperatorScopedRepository `withTenant` indirection (asserted via
//      gateway shape — no `package:postgres` import in adapter).
//   6. Capability profile declares every required field.
//
// Plus the slice-specific tests required by the prompt:
//
//   * Connect → backfill → poll → disconnect → reconnect smoke.
//   * Test connection populates fieldMapping in <30s on the offline
//     path with `assumption: true` flag.
//   * Replay window — framework constant pinned at 24h.
//   * Banned-items grep pinned at the source-file level.
//
// All fixtures cite their doc URL + retrieval date at the top of
// `opentable_reservations_fixture.dart` /
// `opentable_webhook_fixture.dart`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/vendor_timestamp_policy.dart';

import 'fixtures/opentable_reservations_fixture.dart';
import 'fixtures/opentable_webhook_fixture.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _signingSecret = 'whsec_opentable_test_001';
const String _restaurantId = 'rid-9876';

void main() {
  group('VendorCapabilityProfile (Test 8)', () {
    final adapter = OpenTableReservationAdapter(
      transport: _FakeOpenTableTransport(),
      gateway: _FakeOpenTableGateway(),
    );

    test('vendorId / displayName / category / authMode / scope / webhook', () {
      expect(adapter.vendorId, 'opentable');
      expect(adapter.displayName, 'OpenTable');
      expect(
        adapter.capabilityProfile.category,
        IntegrationCategory.reservation,
      );
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

    test('coversFieldExposed = false (reservation systems do not expose covers)',
        () {
      expect(adapter.capabilityProfile.coversFieldExposed, false);
    });

    test('lifecycle = VendorLifecycle.documented (engineer-all-17 doctrine)',
        () {
      expect(adapter.capabilityProfile.lifecycle, VendorLifecycle.documented);
    });

    test('modules empty (no module disambiguation)', () {
      expect(adapter.capabilityProfile.modules, isEmpty);
    });

    test('timestampPolicyDocId points at the per-vendor doc pack', () {
      expect(
        adapter.capabilityProfile.timestampPolicyDocId,
        'docs/integrations/opentable/field_mapping.md',
      );
    });

    test('timestampPolicy declares refuse convention (assumed UTC, '
        'unverified)', () {
      expect(adapter.timestampPolicy.vendorId, 'opentable');
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
          in documentedPerOpentableV1FieldMappingFixture.entries) {
        expect(
          documentedPerOpentableV1FieldMapping.containsKey(entry.key),
          true,
          reason: 'fixture key "${entry.key}" missing from adapter constant',
        );
      }
      // Each canonical-field row carries the verify flag.
      for (final key in const <String>[
        'reservation_at',
        'party_size',
        'status',
        'vendor_entity_id',
        'vendor_modified_at',
      ]) {
        final row = documentedPerOpentableV1FieldMapping[key]
            as Map<String, Object?>?;
        expect(row, isNotNull, reason: 'missing field-mapping row for $key');
        expect(row!['verify_in_live_sandbox'], true,
            reason: 'row "$key" must carry verify_in_live_sandbox: true');
      }
    });
  });

  group('Sanity hook contract (Tests 1, 2, 3)', () {
    late _FakeOpenTableTransport transport;
    late _FakeOpenTableGateway gateway;
    late OpenTableReservationAdapter adapter;
    late DateTime nowFixed;

    setUp(() {
      nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      transport = _FakeOpenTableTransport()
        ..pages = <OpenTableReservationsPage>[
          OpenTableReservationsPage(
            records: openTableBackfillBatchPage1,
            nextCursor: 'cursor-page-2',
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
          ),
          OpenTableReservationsPage(
            records: openTableBackfillBatchPage2,
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
          ),
        ];
      gateway = _FakeOpenTableGateway()
        ..accessToken = 'access-token-001'
        ..restaurantId = _restaurantId;
      adapter = OpenTableReservationAdapter(
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
          vendorId: 'opentable',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        openTableBackfillBatchPage1.length +
            openTableBackfillBatchPage2.length,
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
          vendorId: 'opentable',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        openTableBackfillBatchPage1.length +
            openTableBackfillBatchPage2.length,
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
          vendorId: 'opentable',
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
          vendorId: 'opentable',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: alwaysOk,
        ),
      );
      expect(gateway.canonicalFacts.length, 5);

      // Replay: re-enqueue the exact same pages.
      transport.pages = <OpenTableReservationsPage>[
        OpenTableReservationsPage(
          records: openTableBackfillBatchPage1,
          nextCursor: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
        OpenTableReservationsPage(
          records: openTableBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
        ),
      ];
      final secondResult = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'opentable',
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
      transport.pages = <OpenTableReservationsPage>[
        OpenTableReservationsPage(
          records: openTableBackfillBatchPage1,
          nextCursor: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
        OpenTableReservationsPage(
          records: openTableBackfillBatchPage2,
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
            vendorId: 'opentable',
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

      // Resume: backfill from the persisted cursor walks page 2 only.
      transport.crashAfterPageIndex = null;
      transport.pages = <OpenTableReservationsPage>[
        OpenTableReservationsPage(
          records: openTableBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
        ),
      ];

      final resumeResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'opentable',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: alwaysOk,
          resumeFromCursor: watermark.cursorToken,
        ),
      );
      expect(
        resumeResult.recordsWritten,
        openTableBackfillBatchPage2.length,
      );
      expect(resumeResult.batchesCommitted, 1);
    });
  });

  group('Webhook signature verifier (Test 4)', () {
    const verifier = OpenTableWebhookSignatureVerifier();
    final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);

    test('valid HMAC-SHA256 hex signature → verified', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(openTableReservationModifiedRawBody));
      final expected = Hmac(sha256, utf8.encode(_signingSecret))
          .convert(rawBody)
          .toString();
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          'x-opentable-signature': expected,
          'x-opentable-event-id': 'evt-opentable-001',
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
      expect(result.timestamp, isNull,
          reason: 'no x-opentable-timestamp present → null timestamp');
    });

    test('valid HMAC-SHA256 with epoch-second timestamp header → '
        'timestamp populated', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(openTableReservationModifiedRawBody));
      final expected = Hmac(sha256, utf8.encode(_signingSecret))
          .convert(rawBody)
          .toString();
      final epochSeconds = nowFixed.millisecondsSinceEpoch ~/ 1000;
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          'x-opentable-signature': expected,
          'x-opentable-timestamp': epochSeconds.toString(),
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
          utf8.encode(openTableReservationModifiedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          'x-opentable-signature': 'a' * 64, // valid hex shape, wrong digest
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, isNotNull);
      expect(result.failureReason, contains('mismatch'));
    });

    test('missing X-OpenTable-Signature header → invalid', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(openTableReservationModifiedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{},
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, contains('missing X-OpenTable-Signature'));
    });

    test('non-hex signature → invalid', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(openTableReservationModifiedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{
          'x-opentable-signature': 'not-hex-zz',
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
        ..bindings['opentable'] = const ConnectionBinding(
          connectionId: 'opentable-conn-1',
          metadata: <String, Object?>{
            'restaurant_id': _restaurantId,
          },
          status: ConnectionStatus.connected,
        )
        ..signingSecrets['opentable'] = _signingSecret;

      final transport = _FakeOpenTableTransport();
      final gateway = _FakeOpenTableGateway()
        ..accessToken = 'access-token-001'
        ..restaurantId = _restaurantId;
      final adapter = OpenTableReservationAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      final handler = InboundWebhookHandler(
        gateway: fakeWebhookGateway,
        posAdapterFactories: const <String, PosAdapterFactory>{},
        laborAdapterFactories: const <String, LaborAdapterFactory>{},
        reservationAdapterFactories: <String, ReservationAdapterFactory>{
          adapter.vendorId:
              ({required operatorId, required locationId}) async => adapter,
        },
        signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{
          'opentable': verifier,
        },
        bindingExtractor: WebhookBindingExtractor(),
        now: () => nowFixed,
      );

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'opentable',
        rawBody: Uint8List.fromList(
            utf8.encode(openTableReservationModifiedRawBody)),
        payload: openTableReservationModifiedPayload,
        headers: const <String, String>{
          // 64 hex chars (HMAC-SHA256 width) but wrong digest.
          'x-opentable-signature':
              'beefcafebeefcafebeefcafebeefcafebeefcafebeefcafebeefcafebeefcafe',
          'x-opentable-event-id': 'evt-opentable-tampered',
          'x-vendor-event-id': 'evt-opentable-tampered',
        },
      );
      expect(result.outcome, WebhookOutcome.signatureInvalid);
      expect(result.statusCode, 403);
      expect(gateway.canonicalFacts, isEmpty);
      expect(
        fakeWebhookGateway.failedAttempts['evt-opentable-tampered'],
        1,
      );
    });
  });

  group('Connect → backfill → poll → disconnect → reconnect smoke (Test 5)',
      () {
    test('full lifecycle preserves watermark across disconnect/reconnect',
        () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final transport = _FakeOpenTableTransport()
        ..tokenResponse = OpenTableTokenResponse(
          accessToken: 'access-token-001',
          refreshToken: 'refresh-token-001',
          expiresAt: nowFixed.add(const Duration(hours: 24)),
        )
        ..pages = <OpenTableReservationsPage>[
          OpenTableReservationsPage(
            records: openTableBackfillBatchPage1,
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
          ),
        ]
        ..registeredSubscriptionId = 'opentable-sub-001';

      final gateway = _FakeOpenTableGateway();
      final adapter = OpenTableReservationAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      // 1. Connect — OAuth callback completes, restaurant id discovered,
      // webhook auto-registered.
      final connectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'opentable',
          oauthState: 'authorization-code-001',
        ),
      );
      expect(connectResult.status, ConnectionStatus.connected);
      expect(connectResult.firstBackfillStarted, true);
      expect(
        connectResult.metadata['webhook_subscription_id'],
        'opentable-sub-001',
      );
      expect(connectResult.metadata['restaurant_id'], _restaurantId);

      // Bridge gateway state — production gateway would persist
      // ciphertext here.
      gateway.accessToken = 'access-token-001';
      gateway.restaurantId = _restaurantId;

      // 2. Backfill
      transport.pages = <OpenTableReservationsPage>[
        OpenTableReservationsPage(
          records: openTableBackfillBatchPage1,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
      ];
      final backfillResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'opentable',
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
        openTableBackfillBatchPage1.length,
      );

      // 3. Poll (no new rows — empty page)
      transport.pages = <OpenTableReservationsPage>[
        OpenTableReservationsPage(
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
          vendorId: 'opentable',
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
          vendorId: 'opentable',
          reason: DisconnectReason.operatorAction,
        ),
      );
      expect(disconnectResult.credentialsWiped, true);
      expect(disconnectResult.watermarkPreserved, true);
      expect(gateway.accessToken, isNull,
          reason: 'wipeCredentials must clear the in-memory token');

      // 5. Reconnect — fresh OAuth callback, watermark survives.
      transport.tokenResponse = OpenTableTokenResponse(
        accessToken: 'access-token-002',
        refreshToken: 'refresh-token-002',
        expiresAt: nowFixed.add(const Duration(hours: 24)),
      );
      transport.pages = <OpenTableReservationsPage>[
        OpenTableReservationsPage(
          records: openTableBackfillBatchPage1,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
      ];
      final reconnectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'opentable',
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
    test('populates fieldMapping with reservation_at + party_size + status + '
        'assumption=true and returns under 30s on the offline path',
        () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final transport = _FakeOpenTableTransport()
        ..sample = openTableSampleReservation;
      final gateway = _FakeOpenTableGateway()
        ..accessToken = 'access-token-001'
        ..restaurantId = _restaurantId;
      final adapter = OpenTableReservationAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      final result = await adapter.testConnection(
        const TestConnectionCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'opentable',
        ),
      );

      expect(result.authValid, true);
      expect(
        result.fieldMapping['reservation_at'],
        '2026-05-10T19:30:00.000Z',
      );
      expect(result.fieldMapping['party_size'], 4);
      expect(result.fieldMapping['status'], 'booked');
      expect(result.fieldMapping['vendor_entity_id'], 'OT-12345');
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

  group('Banned items grep (Test 9)', () {
    final adapterFile = File(
      'lib/integrations/reservation/opentable_reservation_adapter.dart',
    );
    final verifierFile = File(
      'lib/integrations/reservation/opentable_webhook_signature_verifier.dart',
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

class _FakeOpenTableTransport implements OpenTableTransport {
  OpenTableTokenResponse? tokenResponse;
  List<OpenTableReservationsPage> _pages = <OpenTableReservationsPage>[];
  Map<String, Object?> sample = const <String, Object?>{};
  String? registeredSubscriptionId;
  int? crashAfterPageIndex;
  int _pageCursor = 0;

  set pages(List<OpenTableReservationsPage> next) {
    _pages = next;
    _pageCursor = 0;
  }

  List<OpenTableReservationsPage> get pages => _pages;

  @override
  Future<OpenTableTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  }) async {
    return tokenResponse ??
        OpenTableTokenResponse(
          accessToken: 'access-token-fake',
          refreshToken: 'refresh-token-fake',
          expiresAt: DateTime.utc(2026, 5, 5, 12, 0, 0),
        );
  }

  @override
  Future<OpenTableTokenResponse> refresh({
    required String refreshToken,
  }) async {
    return tokenResponse ??
        OpenTableTokenResponse(
          accessToken: 'access-token-refreshed',
          refreshToken: 'refresh-token-refreshed',
          expiresAt: DateTime.utc(2026, 5, 5, 12, 0, 0),
        );
  }

  @override
  Future<void> revoke({required String accessToken}) async {}

  @override
  Future<OpenTableReservationsPage> listReservations({
    required String accessToken,
    required String restaurantId,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    if (_pageCursor >= _pages.length) {
      return OpenTableReservationsPage(
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
  Future<Map<String, Object?>> fetchReservation({
    required String accessToken,
    required String restaurantId,
    required String reservationId,
  }) async {
    return sample;
  }

  @override
  Future<String> registerWebhook({
    required String accessToken,
    required String restaurantId,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async {
    return registeredSubscriptionId ?? 'opentable-sub-fake';
  }

  @override
  Future<void> unregisterWebhook({
    required String accessToken,
    required String restaurantId,
    required String subscriptionId,
  }) async {}

  @override
  Future<Map<String, Object?>> sampleReservation({
    required String accessToken,
    required String restaurantId,
  }) async {
    return sample.isEmpty ? openTableSampleReservation : sample;
  }
}

class _FakeOpenTableGateway implements OpenTableGateway {
  String? accessToken;
  String? restaurantId;
  OpenTableConnectionRow? connection;
  OpenTableWatermarkRow? watermark;
  final List<OpenTableCanonicalReservationFact> canonicalFacts =
      <OpenTableCanonicalReservationFact>[];
  final Set<String> _idempotencyKeys = <String>{};

  @override
  Future<OpenTableConnectionRow> upsertConnection({
    required OpenTableConnectionRow row,
  }) async {
    connection = row;
    restaurantId = row.restaurantId;
    return row;
  }

  @override
  Future<OpenTableWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) async =>
      watermark;

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required OpenTableWatermarkRow row,
  }) async {
    watermark = row;
  }

  @override
  Future<bool> writeReservationFact(
    OpenTableCanonicalReservationFact fact,
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
  Future<String?> readRestaurantId({
    required String operatorId,
    required String locationId,
  }) async =>
      restaurantId;
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
