// Phase 8.S.7S — SevenShiftsLaborAdapter +
// SevenShiftsWebhookSignatureVerifier tests.
//
// Drives the adapter against fixture-driven fakes (no live HTTP, no
// Postgres, no live 7shifts credentials) to prove every framework call
// required by `docs/contracts/vendor_adapter_slice_contract.md`:
//
//   1. Sanity hook called per record on backfill + poll, reject path
//      skips the canonical write.
//   2. Idempotency UNIQUE on canonical fact upsert.
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
//   * Replay window — framework constant pinned at 24h.
//   * `payroll_period.closed` webhook handler writes the canonical
//     `payroll_period_closed_at` row (Phase 7.58 Primary Driver
//     binding).
//   * Plan-tier fallback — non-Gourmet connect skips webhook
//     auto-registration and surfaces the explicit operator-facing
//     note.
//   * Banned-items grep pinned at the source-file level.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/seven_shifts_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';
import 'package:forge_and_flow/services/integration/reservation_adapter.dart';
import 'package:forge_and_flow/services/integration/vendor_timestamp_policy.dart';

import 'fixtures/seven_shifts_punches_fixture.dart';
import 'fixtures/seven_shifts_webhook_fixture.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _signingSecret = 'whsec_seven_shifts_test_001';
const String _companyId = 'co-7s-12345';

void main() {
  group('VendorCapabilityProfile (Test 10)', () {
    final adapter = SevenShiftsLaborAdapter(
      transport: _FakeSevenShiftsTransport(),
      gateway: _FakeSevenShiftsGateway(),
    );

    test('vendorId / displayName / category / authMode / scope / webhook', () {
      expect(adapter.vendorId, 'seven_shifts');
      expect(adapter.displayName, '7shifts');
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

    test('coversFieldExposed = false (labor adapters do not source covers)',
        () {
      expect(adapter.capabilityProfile.coversFieldExposed, false);
    });

    test('lifecycle = VendorLifecycle.documented (engineer-all-17 doctrine)',
        () {
      expect(
        adapter.capabilityProfile.lifecycle,
        VendorLifecycle.documented,
      );
    });

    test('modules empty (no module disambiguation)', () {
      expect(adapter.capabilityProfile.modules, isEmpty);
    });

    test('timestampPolicyDocId points at the per-vendor doc pack', () {
      expect(
        adapter.capabilityProfile.timestampPolicyDocId,
        'docs/integrations/seven_shifts/field_mapping.md',
      );
    });

    test(
        'timestampPolicy declares refuse convention until *.live.sandbox '
        'confirms', () {
      expect(adapter.timestampPolicy.vendorId, 'seven_shifts');
      expect(
        adapter.timestampPolicy.ambiguousConvention,
        AmbiguousTimestampConvention.refuse,
      );
    });

    test(
        'documented field-mapping constant mirrors fixture (every row '
        'carries verify_in_live_sandbox=true)', () {
      for (final entry
          in documentedPerSevenShiftsV2FieldMappingFixture.entries) {
        expect(
          documentedPerSevenShiftsV2FieldMapping.containsKey(entry.key),
          true,
          reason:
              'fixture key "${entry.key}" missing from adapter constant',
        );
      }
      for (final key in const <String>[
        'shift_start',
        'shift_end',
        'role_name',
        'employee_id',
        'is_approved',
        'payroll_period_closed_at',
        'vendor_entity_id',
        'vendor_modified_at',
      ]) {
        final row = documentedPerSevenShiftsV2FieldMapping[key]
            as Map<String, Object?>?;
        expect(row, isNotNull, reason: 'missing field-mapping row for $key');
        expect(
          row!['verify_in_live_sandbox'],
          true,
          reason:
              'row "$key" must carry verify_in_live_sandbox: true so the '
              '*.live.sandbox slice diffs against it',
        );
      }
    });

    test(
        'subscribed webhook events include payroll_period.closed (Phase '
        '7.58 Primary Driver binding)', () {
      expect(
        kSevenShiftsSubscribedWebhookEvents,
        contains('payroll_period.closed'),
      );
      expect(
        kSevenShiftsSubscribedWebhookEvents,
        contains('time_punch.edited'),
      );
    });
  });

  group('Sanity hook contract (Tests 1, 2, 3)', () {
    late _FakeSevenShiftsTransport transport;
    late _FakeSevenShiftsGateway gateway;
    late SevenShiftsLaborAdapter adapter;
    late DateTime nowFixed;

    setUp(() {
      nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      transport = _FakeSevenShiftsTransport()
        ..pages = <SevenShiftsTimePunchPage>[
          SevenShiftsTimePunchPage(
            records: sevenShiftsBackfillBatchPage1,
            nextCursor: 'cursor-page-2',
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 22, 32, 0),
          ),
          SevenShiftsTimePunchPage(
            records: sevenShiftsBackfillBatchPage2,
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 2, 23, 50, 0),
          ),
        ]
        ..companyInfo = const SevenShiftsCompanyInfo(
          companyId: _companyId,
          planTier: kSevenShiftsGourmetPlanTier,
        )
        ..latestPayrollPeriodClosedAt = sevenShiftsLatestPayrollPeriodClosedAt;
      gateway = _FakeSevenShiftsGateway()
        ..accessToken = 'access-token-001'
        ..companyId = _companyId;
      adapter = SevenShiftsLaborAdapter(
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
          vendorId: 'seven_shifts',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        sevenShiftsBackfillBatchPage1.length +
            sevenShiftsBackfillBatchPage2.length,
        reason:
            'sanity hook must be called once per record across all pages',
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
            reason:
                'pollIncremental MUST pass isDeliberateBackfill: false');
        return true;
      }

      final result = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'seven_shifts',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        sevenShiftsBackfillBatchPage1.length +
            sevenShiftsBackfillBatchPage2.length,
      );
      expect(result.recordsWritten, 5);
    });

    test(
        'Test 1 (reject) — sanity hook returning false skips canonical '
        'write', () async {
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
          vendorId: 'seven_shifts',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: rejectAll,
        ),
      );

      expect(result.recordsWritten, 0);
      expect(result.sanityDropped, 5);
      expect(gateway.canonicalPunchFacts, isEmpty,
          reason:
              'rejecting sanity must short-circuit before fact write');
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
          vendorId: 'seven_shifts',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: alwaysOk,
        ),
      );
      expect(gateway.canonicalPunchFacts.length, 5);

      // Replay: re-enqueue the exact same pages.
      transport.pages = <SevenShiftsTimePunchPage>[
        SevenShiftsTimePunchPage(
          records: sevenShiftsBackfillBatchPage1,
          nextCursor: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 22, 32, 0),
        ),
        SevenShiftsTimePunchPage(
          records: sevenShiftsBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 23, 50, 0),
        ),
      ];
      final secondResult = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'seven_shifts',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: alwaysOk,
        ),
      );
      expect(secondResult.recordsWritten, 0);
      expect(gateway.canonicalPunchFacts.length, 5,
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
      transport.pages = <SevenShiftsTimePunchPage>[
        SevenShiftsTimePunchPage(
          records: sevenShiftsBackfillBatchPage1,
          nextCursor: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 22, 32, 0),
        ),
        SevenShiftsTimePunchPage(
          records: sevenShiftsBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 23, 50, 0),
        ),
      ];

      try {
        await adapter.backfill(
          BackfillCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _opId,
            vendorId: 'seven_shifts',
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
        DateTime.utc(2026, 5, 1, 22, 32, 0),
        reason:
            'watermark must reflect last-modified of the batch that '
            'committed before the crash',
      );

      // Resume: backfill from the persisted cursor walks page 2 only.
      transport.crashAfterPageIndex = null;
      transport.pages = <SevenShiftsTimePunchPage>[
        SevenShiftsTimePunchPage(
          records: sevenShiftsBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 23, 50, 0),
        ),
      ];

      final resumeResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'seven_shifts',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: alwaysOk,
          resumeFromCursor: watermark.cursorToken,
        ),
      );
      expect(
        resumeResult.recordsWritten,
        sevenShiftsBackfillBatchPage2.length,
      );
      expect(resumeResult.batchesCommitted, 1);
    });
  });

  group('Webhook signature verifier (Test 4)', () {
    const verifier = SevenShiftsWebhookSignatureVerifier();
    final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);

    test('valid HMAC-SHA256 base64 signature → verified', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(sevenShiftsTimePunchEditedRawBody));
      final expected = base64.encode(
        Hmac(sha256, utf8.encode(_signingSecret)).convert(rawBody).bytes,
      );
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          'x-7shifts-hmac-sha256': expected,
          'x-7shifts-event-id': 'evt-7s-001',
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, true);
      expect(result.timestamp, isNull,
          reason: 'no x-7shifts-timestamp present → null timestamp');
    });

    test(
        'valid HMAC-SHA256 with epoch-second timestamp header → '
        'timestamp populated', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(sevenShiftsTimePunchEditedRawBody));
      final expected = base64.encode(
        Hmac(sha256, utf8.encode(_signingSecret)).convert(rawBody).bytes,
      );
      final epochSeconds = nowFixed.millisecondsSinceEpoch ~/ 1000;
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          'x-7shifts-hmac-sha256': expected,
          'x-7shifts-timestamp': epochSeconds.toString(),
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
          utf8.encode(sevenShiftsTimePunchEditedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: <String, String>{
          // Valid base64 of 32 bytes (HMAC-SHA256 width) but wrong
          // digest.
          'x-7shifts-hmac-sha256':
              base64.encode(List<int>.filled(32, 0xAA)),
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, isNotNull);
      expect(result.failureReason, contains('mismatch'));
    });

    test('missing X-7Shifts-Hmac-SHA256 header → invalid', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(sevenShiftsTimePunchEditedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{},
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason,
          contains('missing X-7Shifts-Hmac-SHA256'));
    });

    test('non-base64 signature → invalid', () {
      final rawBody = Uint8List.fromList(
          utf8.encode(sevenShiftsTimePunchEditedRawBody));
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{
          'x-7shifts-hmac-sha256': 'not\$base64!!',
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(result.valid, false);
      expect(result.failureReason, contains('base64'));
    });

    test(
        'Test 4 (framework end-to-end) — tampered HMAC dispatched through '
        'InboundWebhookHandler returns 403 + audit row + no canonical '
        'write', () async {
      final fakeWebhookGateway = _FakeWebhookGateway()
        ..bindings['seven_shifts'] = const ConnectionBinding(
          connectionId: 'seven_shifts-conn-1',
          metadata: <String, Object?>{
            'company_id': _companyId,
          },
          status: ConnectionStatus.connected,
        )
        ..signingSecrets['seven_shifts'] = _signingSecret;

      final transport = _FakeSevenShiftsTransport();
      final gateway = _FakeSevenShiftsGateway()
        ..accessToken = 'access-token-001'
        ..companyId = _companyId;
      final adapter = SevenShiftsLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      final handler = InboundWebhookHandler(
        gateway: fakeWebhookGateway,
        posAdapters: const <String, PosAdapter>{},
        laborAdapters: <String, LaborAdapter>{
          adapter.vendorId: adapter,
        },
        reservationAdapters: const <String, ReservationAdapter>{},
        signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{
          'seven_shifts': verifier,
        },
        bindingExtractor: WebhookBindingExtractor(),
        now: () => nowFixed,
      );

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'seven_shifts',
        rawBody: Uint8List.fromList(
            utf8.encode(sevenShiftsTimePunchEditedRawBody)),
        payload: sevenShiftsTimePunchEditedPayload,
        headers: <String, String>{
          'x-7shifts-hmac-sha256':
              base64.encode(List<int>.filled(32, 0xAA)),
          'x-7shifts-event-id': 'evt-7s-tampered',
          'x-vendor-event-id': 'evt-7s-tampered',
        },
      );
      expect(result.outcome, WebhookOutcome.signatureInvalid);
      expect(result.statusCode, 403);
      expect(gateway.canonicalPunchFacts, isEmpty);
      expect(
        fakeWebhookGateway.failedAttempts['evt-7s-tampered'],
        1,
      );
    });
  });

  group('Connect → backfill → poll → disconnect → reconnect smoke (Test 5)',
      () {
    test('full lifecycle preserves watermark across disconnect/reconnect',
        () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final transport = _FakeSevenShiftsTransport()
        ..tokenResponse = SevenShiftsTokenResponse(
          accessToken: 'access-token-001',
          refreshToken: 'refresh-token-001',
          expiresAt: nowFixed.add(const Duration(hours: 24)),
        )
        ..companyInfo = const SevenShiftsCompanyInfo(
          companyId: _companyId,
          planTier: kSevenShiftsGourmetPlanTier,
        )
        ..registeredWebhookId = 'seven_shifts-wh-001'
        ..pages = <SevenShiftsTimePunchPage>[
          SevenShiftsTimePunchPage(
            records: sevenShiftsBackfillBatchPage1,
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 22, 32, 0),
          ),
        ]
        ..latestPayrollPeriodClosedAt =
            sevenShiftsLatestPayrollPeriodClosedAt;

      final gateway = _FakeSevenShiftsGateway();
      final adapter = SevenShiftsLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      // 1. Connect — OAuth callback completes, company info detects
      // Gourmet plan, webhook auto-registered.
      final connectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'seven_shifts',
          oauthState: 'authorization-code-001',
        ),
      );
      expect(connectResult.status, ConnectionStatus.connected);
      expect(connectResult.firstBackfillStarted, true);
      expect(connectResult.metadata['company_id'], _companyId);
      expect(
        connectResult.metadata['plan_tier'],
        kSevenShiftsGourmetPlanTier,
      );
      expect(connectResult.metadata['webhook_id'], 'seven_shifts-wh-001');
      expect(connectResult.webhookUrl, isNotNull);

      // Bridge gateway state — production gateway would persist
      // ciphertext here.
      gateway.accessToken = 'access-token-001';
      gateway.companyId = _companyId;

      // 2. Backfill
      transport.pages = <SevenShiftsTimePunchPage>[
        SevenShiftsTimePunchPage(
          records: sevenShiftsBackfillBatchPage1,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 22, 32, 0),
        ),
      ];
      final backfillResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'seven_shifts',
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
        sevenShiftsBackfillBatchPage1.length,
      );

      // The backfill also pulls + writes the latest payroll period.
      expect(gateway.canonicalPayrollPeriodFacts, isNotEmpty);
      expect(
        gateway.canonicalPayrollPeriodFacts.last.payrollPeriodClosedAt,
        sevenShiftsLatestPayrollPeriodClosedAt,
      );

      // 3. Poll (no new rows — empty page)
      transport.pages = <SevenShiftsTimePunchPage>[
        SevenShiftsTimePunchPage(
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
          vendorId: 'seven_shifts',
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
          vendorId: 'seven_shifts',
          reason: DisconnectReason.operatorAction,
        ),
      );
      expect(disconnectResult.credentialsWiped, true);
      expect(disconnectResult.watermarkPreserved, true);
      expect(gateway.accessToken, isNull,
          reason: 'wipeCredentials must clear the in-memory token');

      // 5. Reconnect — fresh OAuth callback, watermark survives.
      transport.tokenResponse = SevenShiftsTokenResponse(
        accessToken: 'access-token-002',
        refreshToken: 'refresh-token-002',
        expiresAt: nowFixed.add(const Duration(hours: 24)),
      );
      final reconnectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'seven_shifts',
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
    test(
        'populates fieldMapping with shift_start + shift_end + role_name '
        '+ is_approved=true and returns under 30s on the offline path',
        () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final transport = _FakeSevenShiftsTransport()
        ..sample = sevenShiftsSamplePunch
        ..companyInfo = const SevenShiftsCompanyInfo(
          companyId: _companyId,
          planTier: kSevenShiftsGourmetPlanTier,
        );
      final gateway = _FakeSevenShiftsGateway()
        ..accessToken = 'access-token-001'
        ..companyId = _companyId;
      final adapter = SevenShiftsLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      final result = await adapter.testConnection(
        const TestConnectionCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'seven_shifts',
        ),
      );

      expect(result.authValid, true);
      expect(result.fieldMapping['shift_start'],
          '2026-05-03T18:30:00.000Z');
      expect(result.fieldMapping['shift_end'], '2026-05-03T23:45:00.000Z');
      expect(result.fieldMapping['role_name'], 'server');
      expect(result.fieldMapping['is_approved'], true);
      expect(result.fieldMapping['employee_id'], '99001');
      expect(result.fieldMapping['vendor_entity_id'], '712001');
      expect(result.elapsedMs, lessThan(30000));
      expect(result.note, isNull,
          reason:
              'Gourmet-plan operator → no fallback note in test result');
    });
  });

  group('Replay window (Test 7)', () {
    test('framework replay ceiling stays at 24h per V1 lean cut 2', () {
      expect(kInboundWebhookReplayCeiling, const Duration(hours: 24));
    });
  });

  group('payroll_period.closed webhook handler (Test 8)', () {
    test(
        'writes canonical payroll_period_closed_at row from inbound '
        'webhook (Phase 7.58 Primary Driver binding)', () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final gateway = _FakeSevenShiftsGateway()
        ..accessToken = 'access-token-001'
        ..companyId = _companyId;
      final adapter = SevenShiftsLaborAdapter(
        transport: _FakeSevenShiftsTransport(),
        gateway: gateway,
        now: () => nowFixed,
      );

      final result = await adapter.handleWebhook(
        HandleWebhookCommand(
          operatorId: _opId,
          locationId: _locId,
          vendorId: 'seven_shifts',
          vendorEventId: 'evt-pp-001',
          payload: sevenShiftsPayrollPeriodClosedPayload,
          headers: const <String, String>{},
          receivedAt: nowFixed,
        ),
      );

      expect(result.recordsWritten, 1);
      expect(gateway.canonicalPayrollPeriodFacts.length, 1);
      expect(
        gateway.canonicalPayrollPeriodFacts.first.payrollPeriodClosedAt,
        DateTime.utc(2026, 5, 4, 8, 0, 0),
        reason:
            'webhook closed_at must round-trip into canonical fact for '
            'Phase 7.58 Primary Driver audit',
      );
      expect(gateway.canonicalPunchFacts, isEmpty,
          reason:
              'payroll_period.closed event must NOT write a punch fact',
      );
    });

    test(
        'time_punch.edited webhook writes canonical punch fact via '
        'handleWebhook', () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final gateway = _FakeSevenShiftsGateway()
        ..accessToken = 'access-token-001'
        ..companyId = _companyId;
      final adapter = SevenShiftsLaborAdapter(
        transport: _FakeSevenShiftsTransport(),
        gateway: gateway,
        now: () => nowFixed,
      );

      final result = await adapter.handleWebhook(
        HandleWebhookCommand(
          operatorId: _opId,
          locationId: _locId,
          vendorId: 'seven_shifts',
          vendorEventId: 'evt-tp-001',
          payload: sevenShiftsTimePunchEditedPayload,
          headers: const <String, String>{},
          receivedAt: nowFixed,
        ),
      );

      expect(result.recordsWritten, 1);
      expect(gateway.canonicalPunchFacts.length, 1);
      expect(
        gateway.canonicalPunchFacts.first.vendorEntityId,
        '712001',
      );
      expect(gateway.canonicalPunchFacts.first.isApproved, true);
    });
  });

  group('Plan-tier fallback (Test 9)', () {
    test(
        'connect on non-Gourmet plan skips webhook auto-register and '
        'returns null webhookUrl + non-Gourmet test note path', () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final transport = _FakeSevenShiftsTransport()
        ..tokenResponse = SevenShiftsTokenResponse(
          accessToken: 'access-token-non-gourmet',
          refreshToken: 'refresh-token-001',
          expiresAt: nowFixed.add(const Duration(hours: 24)),
        )
        ..companyInfo = const SevenShiftsCompanyInfo(
          companyId: _companyId,
          // The Works tier — webhooks NOT available.
          planTier: 'the_works',
        );

      final gateway = _FakeSevenShiftsGateway();
      final adapter = SevenShiftsLaborAdapter(
        transport: transport,
        gateway: gateway,
        now: () => nowFixed,
      );

      final connectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'seven_shifts',
          oauthState: 'authorization-code-001',
        ),
      );

      expect(connectResult.status, ConnectionStatus.connected);
      expect(connectResult.metadata['company_id'], _companyId);
      expect(connectResult.metadata['plan_tier'], 'the_works');
      expect(
        connectResult.metadata.containsKey('webhook_id'),
        false,
        reason:
            'non-Gourmet plan must skip webhook auto-registration',
      );
      expect(connectResult.webhookUrl, isNull);
      expect(transport.registerWebhookCalls, 0,
          reason:
              'non-Gourmet connect must not invoke registerWebhook',
      );

      // testConnection on the same operator surfaces the fallback note.
      gateway.accessToken = 'access-token-non-gourmet';
      gateway.companyId = _companyId;
      transport.sample = sevenShiftsSamplePunch;
      final testResult = await adapter.testConnection(
        const TestConnectionCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'seven_shifts',
        ),
      );
      expect(testResult.authValid, true);
      expect(testResult.note, kSevenShiftsNonGourmetNote);
    });
  });

  group('Banned items grep (Test 11)', () {
    final adapterFile = File(
      'lib/integrations/labor/seven_shifts_labor_adapter.dart',
    );
    final verifierFile = File(
      'lib/integrations/labor/seven_shifts_webhook_signature_verifier.dart',
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
        body.contains('package:postgres/'),
        false,
        reason: 'package:postgres imports are restricted to '
            'lib/infrastructure/persistence/postgres/ per the '
            'service-layer split (CLAUDE.md)',
      );
    });
  });
}

// ─── Fakes ──────────────────────────────────────────────────────────

class _FakeSevenShiftsTransport implements SevenShiftsTransport {
  SevenShiftsTokenResponse? tokenResponse;
  SevenShiftsCompanyInfo? companyInfo;
  List<SevenShiftsTimePunchPage> _pages = <SevenShiftsTimePunchPage>[];
  Map<String, Object?> sample = const <String, Object?>{};
  String? registeredWebhookId;
  int? crashAfterPageIndex;
  int _pageCursor = 0;
  int registerWebhookCalls = 0;
  DateTime? latestPayrollPeriodClosedAt;

  set pages(List<SevenShiftsTimePunchPage> next) {
    _pages = next;
    _pageCursor = 0;
  }

  List<SevenShiftsTimePunchPage> get pages => _pages;

  @override
  Future<SevenShiftsTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  }) async {
    return tokenResponse ??
        SevenShiftsTokenResponse(
          accessToken: 'access-token-fake',
          refreshToken: 'refresh-token-fake',
          expiresAt: DateTime.utc(2026, 5, 5, 12, 0, 0),
        );
  }

  @override
  Future<SevenShiftsTokenResponse> refresh({
    required String refreshToken,
  }) async {
    return tokenResponse ??
        SevenShiftsTokenResponse(
          accessToken: 'access-token-refreshed',
          refreshToken: 'refresh-token-refreshed',
          expiresAt: DateTime.utc(2026, 5, 5, 12, 0, 0),
        );
  }

  @override
  Future<void> revoke({required String accessToken}) async {}

  @override
  Future<SevenShiftsCompanyInfo> fetchCompanyInfo({
    required String accessToken,
  }) async {
    return companyInfo ??
        const SevenShiftsCompanyInfo(
          companyId: _companyId,
          planTier: kSevenShiftsGourmetPlanTier,
        );
  }

  @override
  Future<SevenShiftsTimePunchPage> listTimePunches({
    required String accessToken,
    required String companyId,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    if (_pageCursor >= _pages.length) {
      return SevenShiftsTimePunchPage(
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
  Future<DateTime?> fetchLatestPayrollPeriodClosedAt({
    required String accessToken,
    required String companyId,
  }) async {
    return latestPayrollPeriodClosedAt;
  }

  @override
  Future<String> registerWebhook({
    required String accessToken,
    required String companyId,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async {
    registerWebhookCalls += 1;
    return registeredWebhookId ?? 'seven_shifts-wh-fake';
  }

  @override
  Future<void> unregisterWebhook({
    required String accessToken,
    required String companyId,
    required String webhookId,
  }) async {}

  @override
  Future<Map<String, Object?>> samplePunch({
    required String accessToken,
    required String companyId,
  }) async {
    return sample.isEmpty ? sevenShiftsSamplePunch : sample;
  }
}

class _FakeSevenShiftsGateway implements SevenShiftsGateway {
  String? accessToken;
  String? companyId;
  SevenShiftsConnectionRow? connection;
  SevenShiftsWatermarkRow? watermark;
  final List<SevenShiftsCanonicalTimePunchFact> canonicalPunchFacts =
      <SevenShiftsCanonicalTimePunchFact>[];
  final List<SevenShiftsCanonicalPayrollPeriodClosedFact>
      canonicalPayrollPeriodFacts =
      <SevenShiftsCanonicalPayrollPeriodClosedFact>[];
  final Set<String> _idempotencyKeys = <String>{};
  DateTime? _lastWrittenPayrollPeriodClosedAt;

  @override
  Future<SevenShiftsConnectionRow> upsertConnection({
    required SevenShiftsConnectionRow row,
  }) async {
    connection = row;
    companyId = row.companyId;
    return row;
  }

  @override
  Future<SevenShiftsWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) async =>
      watermark;

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required SevenShiftsWatermarkRow row,
  }) async {
    watermark = row;
  }

  @override
  Future<bool> writeTimePunchFact(
    SevenShiftsCanonicalTimePunchFact fact,
  ) async {
    final key =
        '${fact.operatorId}:${fact.locationId}:${fact.vendorEntityId}:${fact.vendorModifiedAt.toIso8601String()}';
    if (_idempotencyKeys.contains(key)) {
      return false;
    }
    _idempotencyKeys.add(key);
    canonicalPunchFacts.add(fact);
    return true;
  }

  @override
  Future<bool> writePayrollPeriodClosedFact(
    SevenShiftsCanonicalPayrollPeriodClosedFact fact,
  ) async {
    if (_lastWrittenPayrollPeriodClosedAt == fact.payrollPeriodClosedAt) {
      return false;
    }
    _lastWrittenPayrollPeriodClosedAt = fact.payrollPeriodClosedAt;
    canonicalPayrollPeriodFacts.add(fact);
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
  Future<String?> readCompanyId({
    required String operatorId,
    required String locationId,
  }) async =>
      companyId;
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
