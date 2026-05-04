// Phase 8.S / Wave B — QuickBooks Time labor adapter (slice `8.S.QBT`)
// fixture-based test suite.
//
// Tests cover every mandatory framework call from
// `docs/contracts/vendor_adapter_slice_contract.md`:
//   1. Sanity hook called per record (backfill + poll); reject path
//      skips the canonical write.
//   2. Idempotency replay: same payload twice → single canonical write.
//   3. Watermark mid-batch resume across a simulated worker crash.
//   4. handleWebhook throws UnsupportedError (poll-only adapter).
//   5. Connect → backfill → poll → disconnect → reconnect smoke.
//   6. testConnection fieldMapping populated; <30s.
//   7. Module disambiguation: time accepted; accounting → redirect
//      ModuleRefusalException; payroll → refusal ModuleRefusalException.
//   8. VendorCapabilityProfile assertions; lifecycle = `documented`;
//      modules = ['time']; webhookSupport = pollOnly.
//   9. Banned-items grep across the adapter source.
//
// Webhook signature / replay tests are N/A (pollOnly) — see
// `docs/integrations/quickbooks_time/webhook_signature.md` (single-line
// N/A) and `live_verification_checklist.md` row "Webhook signature
// verification" (pre-marked N/A).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/quickbooks_time_labor_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/vendor_timestamp_policy.dart';

import 'fixtures/quickbooks_time_punches_fixture.dart' as fixture;
import 'fixtures/quickbooks_time_punches_fixture.dart'
    show
        sampleQuickBooksTimePunch,
        quickBooksTimeBackfillPage1,
        quickBooksTimeBackfillPage2;

const String _opId = 'op_demo_diner';
const String _locId = 'loc_toronto_yorkville';
const String _actor = 'usr_owner';
const String _intuitRealmId = 'realm-9876543210';

void main() {
  group('VendorCapabilityProfile (Test 8)', () {
    test('vendorId / displayName / category / authMode / scope / webhook', () {
      final adapter = _buildAdapter();
      final profile = adapter.capabilityProfile;

      expect(profile.vendorId, 'quickbooks_time');
      expect(profile.displayName, 'QuickBooks Time');
      expect(profile.category, IntegrationCategory.labor);
      expect(profile.authMode, VendorAuthMode.oauth);
      expect(profile.grantScope, VendorGrantScope.operatorWide);
      expect(profile.webhookSupport, VendorWebhookSupport.pollOnly);
    });

    test('coversFieldExposed = false (labor systems do not expose covers)',
        () {
      final adapter = _buildAdapter();
      expect(adapter.capabilityProfile.coversFieldExposed, isFalse);
    });

    test('lifecycle locked at documented at slice close', () {
      final adapter = _buildAdapter();
      expect(adapter.capabilityProfile.lifecycle, VendorLifecycle.documented);
      expect(adapter.lifecycle, VendorLifecycle.documented);
    });

    test('modules = [\'time\'] (module disambiguation enabled, '
        'time-only support)', () {
      final adapter = _buildAdapter();
      expect(adapter.capabilityProfile.modules, <String>['time']);
    });

    test('timestampPolicyDocId points at the per-vendor doc pack', () {
      final adapter = _buildAdapter();
      expect(adapter.capabilityProfile.timestampPolicyDocId,
          'quickbooks_time.asUtc');
    });

    test('timestampPolicy declares asUtc convention (per registry)', () {
      final adapter = _buildAdapter();
      expect(adapter.timestampPolicy.vendorId, 'quickbooks_time');
      expect(adapter.timestampPolicy.ambiguousConvention,
          AmbiguousTimestampConvention.asUtc);
    });

    test('field-mapping constant mirrors fixture', () {
      // The adapter's documented-per constant carries the engineering
      // source-of-truth; the fixture mirror is what the
      // `*.live.sandbox` slice will diff against. Drift between them
      // would silently break that diff.
      for (final entry in fixture.documented_per_quickbooks_time_v1.entries) {
        expect(documented_per_quickbooks_time_v1.containsKey(entry.key), true,
            reason: 'fixture key "${entry.key}" missing from adapter constant');
      }
    });
  });

  group('Sanity hook contract (Tests 1, 2, 3)', () {
    late _FakeQuickBooksTimeTransport transport;
    late _FakeQuickBooksTimeGateway gateway;
    late QuickBooksTimeLaborAdapter adapter;
    late DateTime nowFixed;

    setUp(() {
      nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      transport = _FakeQuickBooksTimeTransport()
        ..pages = <QuickBooksTimeTimesheetsPage>[
          QuickBooksTimeTimesheetsPage(
            records: quickBooksTimeBackfillPage1,
            nextPage: 2,
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 20, 5, 0),
          ),
          QuickBooksTimeTimesheetsPage(
            records: quickBooksTimeBackfillPage2,
            nextPage: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 31, 0),
          ),
        ];
      gateway = _FakeQuickBooksTimeGateway()
        ..accessToken = 'access-token-001'
        ..intuitRealmId = _intuitRealmId;
      adapter = QuickBooksTimeLaborAdapter(
        transport: transport,
        gateway: gateway,
        clock: () => nowFixed,
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
        expect(isDeliberateBackfill, isTrue,
            reason: 'backfill MUST flag isDeliberateBackfill: true');
        return true;
      }

      final result = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        quickBooksTimeBackfillPage1.length +
            quickBooksTimeBackfillPage2.length,
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
        expect(isDeliberateBackfill, isFalse,
            reason: 'pollIncremental MUST flag isDeliberateBackfill: false');
        return true;
      }

      final result = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        quickBooksTimeBackfillPage1.length +
            quickBooksTimeBackfillPage2.length,
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
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: rejectAll,
        ),
      );

      expect(result.recordsWritten, 0);
      expect(result.sanityDropped, 5);
      expect(gateway.canonicalFacts, isEmpty,
          reason: 'rejecting sanity must short-circuit before fact write');
    });

    test('Test 2 — same payload twice → single canonical write '
        '(idempotency)', () async {
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
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: alwaysOk,
        ),
      );
      expect(gateway.canonicalFacts.length, 5);

      // Replay: re-enqueue the exact same pages.
      transport.pages = <QuickBooksTimeTimesheetsPage>[
        QuickBooksTimeTimesheetsPage(
          records: quickBooksTimeBackfillPage1,
          nextPage: 2,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 20, 5, 0),
        ),
        QuickBooksTimeTimesheetsPage(
          records: quickBooksTimeBackfillPage2,
          nextPage: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 31, 0),
        ),
      ];
      final secondResult = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
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

      // Inject a crash after page 1 so page 2 throws on request.
      transport.crashAfterPageIndex = 0;
      transport.pages = <QuickBooksTimeTimesheetsPage>[
        QuickBooksTimeTimesheetsPage(
          records: quickBooksTimeBackfillPage1,
          nextPage: 2,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 20, 5, 0),
        ),
        QuickBooksTimeTimesheetsPage(
          records: quickBooksTimeBackfillPage2,
          nextPage: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 31, 0),
        ),
      ];

      try {
        await adapter.backfill(
          BackfillCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _actor,
            vendorId: 'quickbooks_time',
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
      expect(watermark!.cursorToken, '2');
      expect(watermark.lastModifiedSeen,
          DateTime.utc(2026, 5, 1, 20, 5, 0),
          reason: 'watermark must reflect last-modified of the batch '
              'that committed before the crash');

      // Resume: backfill from the persisted cursor walks page 2 only.
      transport.crashAfterPageIndex = null;
      transport.pages = <QuickBooksTimeTimesheetsPage>[
        QuickBooksTimeTimesheetsPage(
          records: quickBooksTimeBackfillPage2,
          nextPage: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 31, 0),
        ),
      ];

      final resumeResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: alwaysOk,
          resumeFromCursor: watermark.cursorToken,
        ),
      );
      expect(resumeResult.recordsWritten, quickBooksTimeBackfillPage2.length);
      expect(resumeResult.batchesCommitted, 1);
      expect(transport.requestedPages, contains(2),
          reason: 'resume must request the persisted cursor (page 2)');
    });
  });

  group('handleWebhook (Test 4)', () {
    test('throws UnsupportedError because vendor is poll-only', () async {
      final adapter = _buildAdapter();
      final command = HandleWebhookCommand(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'quickbooks_time',
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

  group('Connect → backfill → poll → disconnect → reconnect smoke (Test 5)',
      () {
    test('full lifecycle preserves watermark across disconnect/reconnect',
        () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final transport = _FakeQuickBooksTimeTransport()
        ..tokenResponse = QuickBooksTimeTokenResponse(
          accessToken: 'access-token-001',
          refreshToken: 'refresh-token-001',
          expiresAt: nowFixed.add(const Duration(hours: 1)),
          scope: 'com.intuit.quickbooks.payroll.time.access',
          realmId: _intuitRealmId,
        )
        ..pages = <QuickBooksTimeTimesheetsPage>[
          QuickBooksTimeTimesheetsPage(
            records: quickBooksTimeBackfillPage1,
            nextPage: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 20, 5, 0),
          ),
        ];
      final gateway = _FakeQuickBooksTimeGateway();
      final adapter = QuickBooksTimeLaborAdapter(
        transport: transport,
        gateway: gateway,
        clock: () => nowFixed,
      );

      // 1. Connect — module = 'time'; OAuth callback completes; realm
      // discovered.
      final connectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
          module: 'time',
          oauthState: 'authorization-code-001',
        ),
      );
      expect(connectResult.status, ConnectionStatus.connected);
      expect(connectResult.firstBackfillStarted, isTrue);
      expect(connectResult.webhookUrl, isNull,
          reason: 'pollOnly vendor — no webhook URL provisioned');
      expect(connectResult.metadata['intuit_realm_id'], _intuitRealmId);
      expect(connectResult.metadata['module'], 'time');

      // Bridge gateway state — production gateway would persist
      // ciphertext here.
      gateway.accessToken = 'access-token-001';
      gateway.intuitRealmId = _intuitRealmId;

      // 2. Backfill.
      transport.pages = <QuickBooksTimeTimesheetsPage>[
        QuickBooksTimeTimesheetsPage(
          records: quickBooksTimeBackfillPage1,
          nextPage: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 20, 5, 0),
        ),
      ];
      final backfillResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
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
        quickBooksTimeBackfillPage1.length,
      );

      // 3. Poll (no new rows — empty page).
      transport.pages = <QuickBooksTimeTimesheetsPage>[
        QuickBooksTimeTimesheetsPage(
          records: const <Map<String, Object?>>[],
          nextPage: null,
          lastModifiedSeen: backfillResult.lastModifiedSeen,
        ),
      ];
      final pollResult = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
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
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
          reason: DisconnectReason.operatorAction,
        ),
      );
      expect(disconnectResult.credentialsWiped, isTrue);
      expect(disconnectResult.webhookUnregistered, isTrue,
          reason: 'pollOnly vendor — vacuously true');
      expect(disconnectResult.watermarkPreserved, isTrue);
      expect(gateway.accessToken, isNull,
          reason: 'wipeCredentials must clear the in-memory token');

      // 5. Reconnect — fresh OAuth callback, watermark survives.
      transport.tokenResponse = QuickBooksTimeTokenResponse(
        accessToken: 'access-token-002',
        refreshToken: 'refresh-token-002',
        expiresAt: nowFixed.add(const Duration(hours: 1)),
        scope: 'com.intuit.quickbooks.payroll.time.access',
        realmId: _intuitRealmId,
      );
      transport.pages = <QuickBooksTimeTimesheetsPage>[
        QuickBooksTimeTimesheetsPage(
          records: const <Map<String, Object?>>[],
          nextPage: null,
          lastModifiedSeen: preDisconnectWatermark!.lastModifiedSeen,
        ),
      ];
      final reconnectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
          module: 'time',
          oauthState: 'authorization-code-002',
        ),
      );
      expect(reconnectResult.status, ConnectionStatus.connected);
      final postReconnectWatermark = await gateway.readWatermark(
        operatorId: _opId,
        locationId: _locId,
      );
      expect(postReconnectWatermark, isNotNull);
      expect(postReconnectWatermark!.lastModifiedSeen,
          preDisconnectWatermark.lastModifiedSeen);
    });
  });

  group('Test connection (Test 6)', () {
    test('populates fieldMapping with shift_start/shift_end/role_name and '
        'returns under 30s on the offline path', () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final transport = _FakeQuickBooksTimeTransport()
        ..sample = sampleQuickBooksTimePunch;
      final gateway = _FakeQuickBooksTimeGateway()
        ..accessToken = 'access-token-001'
        ..intuitRealmId = _intuitRealmId;
      final adapter = QuickBooksTimeLaborAdapter(
        transport: transport,
        gateway: gateway,
        clock: () => nowFixed,
      );

      final result = await adapter.testConnection(
        const TestConnectionCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
        ),
      );

      expect(result.authValid, isTrue);
      expect(result.fieldMapping['shift_start'],
          '2026-05-04T11:00:00.000Z');
      expect(result.fieldMapping['shift_end'],
          '2026-05-04T19:30:00.000Z');
      expect(result.fieldMapping['role_name'], 'server');
      expect(result.fieldMapping['vendor_entity_id'], '901001');
      expect(result.fieldMapping['covers_source'], 'not_applicable');
      // <30s — V1 lean cut 2: do not enforce a 5s SLA.
      expect(result.elapsedMs, lessThan(30 * 1000));
    });
  });

  group('Module disambiguation (Test 7 — CONTRACT-REQUIRED)', () {
    final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);

    test('module = accounting → ModuleRefusalException with redirect copy',
        () async {
      final adapter = _buildAdapter();
      try {
        await adapter.connect(
          const ConnectCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _actor,
            vendorId: 'quickbooks_time',
            module: 'accounting',
            oauthState: 'authorization-code-accounting',
          ),
        );
        fail('expected ModuleRefusalException for accounting module');
      } on ModuleRefusalException catch (e) {
        expect(e.module, 'accounting');
        expect(e.message, contains('Outbound Integrations'));
      }
    });

    test('module = payroll → ModuleRefusalException with refusal copy',
        () async {
      final adapter = _buildAdapter();
      try {
        await adapter.connect(
          const ConnectCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _actor,
            vendorId: 'quickbooks_time',
            module: 'payroll',
            oauthState: 'authorization-code-payroll',
          ),
        );
        fail('expected ModuleRefusalException for payroll module');
      } on ModuleRefusalException catch (e) {
        expect(e.module, 'payroll');
        expect(e.message, contains('not supported'));
      }
    });

    test('module = time (or compatible scope) succeeds', () async {
      final transport = _FakeQuickBooksTimeTransport()
        ..tokenResponse = QuickBooksTimeTokenResponse(
          accessToken: 'access-token-001',
          refreshToken: 'refresh-token-001',
          expiresAt: nowFixed.add(const Duration(hours: 1)),
          scope: 'com.intuit.quickbooks.payroll.time.access',
          realmId: _intuitRealmId,
        )
        ..pages = <QuickBooksTimeTimesheetsPage>[
          QuickBooksTimeTimesheetsPage(
            records: const <Map<String, Object?>>[],
            nextPage: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 1),
          ),
        ];
      final adapter = QuickBooksTimeLaborAdapter(
        transport: transport,
        gateway: _FakeQuickBooksTimeGateway(),
        clock: () => nowFixed,
      );

      final result = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
          module: 'time',
          oauthState: 'authorization-code-time',
        ),
      );
      expect(result.status, ConnectionStatus.connected);
      expect(result.metadata['module'], 'time');

      // Default (no module) also accepts and falls back to time.
      final transport2 = _FakeQuickBooksTimeTransport()
        ..tokenResponse = QuickBooksTimeTokenResponse(
          accessToken: 'access-token-002',
          refreshToken: 'refresh-token-002',
          expiresAt: nowFixed.add(const Duration(hours: 1)),
          scope: 'com.intuit.quickbooks.payroll.time.access',
          realmId: _intuitRealmId,
        );
      final adapter2 = QuickBooksTimeLaborAdapter(
        transport: transport2,
        gateway: _FakeQuickBooksTimeGateway(),
        clock: () => nowFixed,
      );
      final defaultResult = await adapter2.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'quickbooks_time',
          oauthState: 'authorization-code-no-module',
        ),
      );
      expect(defaultResult.status, ConnectionStatus.connected);
      expect(defaultResult.metadata['module'], 'time');
    });
  });

  group('Banned items grep (Test 9)', () {
    test('adapter source contains zero banned-list items', () async {
      final source = await File(
        'lib/integrations/labor/quickbooks_time_labor_adapter.dart',
      ).readAsString();

      // Banned items per `memory/project_v1_lean_cut_2_2026_05_03.md`.
      // Case-insensitive match; the adapter must contain none of these.
      const banned = <String>[
        // KMS / production-key rotation.
        'kms.encrypt',
        'pgp_sym_encrypt_kms',
        // Webhook key rotation UI (poll-only, but assert anyway).
        'rotateSigningKey',
        'rotate_signing_key',
        // parse_warnings / parse_partial.
        'parse_warnings',
        'parse_partial',
        // 5-minute strict replay window.
        'kStrictReplayFiveMinute',
        'replay_strict_5min',
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

    test('adapter does not import package:postgres directly', () async {
      final source = await File(
        'lib/integrations/labor/quickbooks_time_labor_adapter.dart',
      ).readAsString();
      expect(
        source.contains('package:postgres/'),
        isFalse,
        reason: 'package:postgres imports are restricted to '
            'lib/infrastructure/persistence/postgres/ per the '
            'service-layer split (CLAUDE.md)',
      );
    });

    test('webhook signature verifier file does NOT exist for poll-only adapter',
        () {
      final verifier = File(
        'lib/integrations/labor/quickbooks_time_webhook_signature_verifier.dart',
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

QuickBooksTimeLaborAdapter _buildAdapter() => QuickBooksTimeLaborAdapter(
      transport: _FakeQuickBooksTimeTransport(),
      gateway: _FakeQuickBooksTimeGateway(),
      clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
    );

class _FakeQuickBooksTimeTransport implements QuickBooksTimeTransport {
  QuickBooksTimeTokenResponse? tokenResponse;
  List<QuickBooksTimeTimesheetsPage> _pages = <QuickBooksTimeTimesheetsPage>[];
  Map<String, Object?> sample = const <String, Object?>{};
  int? crashAfterPageIndex;
  int _pageCursor = 0;
  final List<int?> requestedPages = <int?>[];

  set pages(List<QuickBooksTimeTimesheetsPage> next) {
    _pages = next;
    _pageCursor = 0;
  }

  List<QuickBooksTimeTimesheetsPage> get pages => _pages;

  @override
  Future<QuickBooksTimeTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  }) async {
    return tokenResponse ??
        QuickBooksTimeTokenResponse(
          accessToken: 'access-token-fake',
          refreshToken: 'refresh-token-fake',
          expiresAt: DateTime.utc(2026, 5, 4, 13, 0, 0),
          scope: 'com.intuit.quickbooks.payroll.time.access',
          realmId: _intuitRealmId,
        );
  }

  @override
  Future<QuickBooksTimeTokenResponse> refresh({
    required String refreshToken,
  }) async {
    return tokenResponse ??
        QuickBooksTimeTokenResponse(
          accessToken: 'access-token-refreshed',
          refreshToken: 'refresh-token-refreshed',
          expiresAt: DateTime.utc(2026, 5, 4, 13, 0, 0),
          scope: 'com.intuit.quickbooks.payroll.time.access',
          realmId: _intuitRealmId,
        );
  }

  @override
  Future<void> revoke({required String refreshToken}) async {}

  @override
  Future<QuickBooksTimeTimesheetsPage> listTimesheets({
    required String accessToken,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    int? page,
  }) async {
    requestedPages.add(page);
    if (crashAfterPageIndex != null && _pageCursor > crashAfterPageIndex!) {
      throw StateError('simulated worker crash after page $crashAfterPageIndex');
    }
    if (_pageCursor >= _pages.length) {
      return QuickBooksTimeTimesheetsPage(
        records: const <Map<String, Object?>>[],
        nextPage: null,
        lastModifiedSeen: modifiedSince,
      );
    }
    final result = _pages[_pageCursor];
    _pageCursor += 1;
    return result;
  }

  @override
  Future<Map<String, Object?>> fetchTimesheet({
    required String accessToken,
    required String timesheetId,
  }) async =>
      sample;

  @override
  Future<Map<String, Map<String, Object?>>> fetchJobcodes({
    required String accessToken,
  }) async =>
      const <String, Map<String, Object?>>{};

  @override
  Future<Map<String, Map<String, Object?>>> fetchUsers({
    required String accessToken,
  }) async =>
      const <String, Map<String, Object?>>{};

  @override
  Future<Map<String, Object?>> sampleTimesheet({
    required String accessToken,
  }) async {
    return sample.isEmpty ? sampleQuickBooksTimePunch : sample;
  }
}

class _FakeQuickBooksTimeGateway implements QuickBooksTimeGateway {
  String? accessToken;
  String? intuitRealmId;
  QuickBooksTimeConnectionRow? connection;
  QuickBooksTimeWatermarkRow? watermark;
  final List<QuickBooksTimeCanonicalPunchFact> canonicalFacts =
      <QuickBooksTimeCanonicalPunchFact>[];
  final Set<String> _idempotencyKeys = <String>{};

  @override
  Future<QuickBooksTimeConnectionRow> upsertConnection({
    required QuickBooksTimeConnectionRow row,
  }) async {
    connection = row;
    intuitRealmId = row.intuitRealmId;
    return row;
  }

  @override
  Future<QuickBooksTimeWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) async =>
      watermark;

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required QuickBooksTimeWatermarkRow row,
  }) async {
    watermark = row;
  }

  @override
  Future<bool> writePunchFact(QuickBooksTimeCanonicalPunchFact fact) async {
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
  Future<String?> readIntuitRealmId({
    required String operatorId,
    required String locationId,
  }) async =>
      intuitRealmId;
}
