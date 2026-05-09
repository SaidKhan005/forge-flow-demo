// Phase 8.S.HM — HumanityLaborAdapter tests.
//
// Drives the adapter against fixture-driven fakes (no live HTTP, no
// Postgres, no plaintext credentials in adapter scope) to prove every
// framework call required by
// `docs/contracts/vendor_adapter_slice_contract.md`:
//
//   1. Sanity hook called per record on backfill + poll, reject path
//      skips the canonical write.
//   2. Idempotency UNIQUE on canonical fact upsert
//      (`(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`).
//   3. Watermark per batch commit (mid-batch crash → resume from last
//      persisted cursor).
//   4. Webhook signature verification — N/A for Humanity (pollOnly);
//      the test asserts `handleWebhook` throws `UnsupportedError`
//      instead, which is the framework's defense-in-depth contract
//      for poll-only adapters.
//   5. Capability profile declares every required field; lifecycle =
//      `documented`, authMode = `keyPaste`, webhookSupport =
//      `pollOnly`.
//   6. Connect via keyPaste → backfill → poll → disconnect →
//      reconnect smoke. Reconnect requires the operator to re-paste
//      credentials (no refresh-token magic for legacy auth).
//   7. Test-connection populates `fieldMapping` with `shift_start +
//      shift_end + role_name` and returns under 30s on the offline
//      path.
//   8. Banned-items grep pinned at the source-file level (V1 lean cut
//      2 — see `docs/contracts/vendor_adapter_slice_contract.md`).
//
// All fixtures cite their doc URL + retrieval date at the top of
// `humanity_punches_fixture.dart`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/humanity_labor_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/vendor_timestamp_policy.dart';

import 'fixtures/humanity_punches_fixture.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _legacyUsername = 'restaurant-admin';
const String _legacyPassword = 'humanity-test-password-001';

void main() {
  group('VendorCapabilityProfile (Test 7)', () {
    final adapter = HumanityLaborAdapter(
      httpClient: _FakeHumanityHttpClient(),
      gateway: _FakeHumanityGateway(),
    );

    test('vendorId / displayName / category / authMode / scope / webhook', () {
      expect(adapter.vendorId, 'humanity');
      expect(adapter.displayName, 'Humanity');
      expect(adapter.capabilityProfile.category, IntegrationCategory.labor);
      expect(adapter.capabilityProfile.authMode, VendorAuthMode.keyPaste);
      expect(
        adapter.capabilityProfile.grantScope,
        VendorGrantScope.operatorWide,
      );
      expect(
        adapter.capabilityProfile.webhookSupport,
        VendorWebhookSupport.pollOnly,
      );
    });

    test('coversFieldExposed = false (labor adapters do not produce covers)',
        () {
      expect(adapter.capabilityProfile.coversFieldExposed, false);
    });

    test('lifecycle = VendorLifecycle.documented (engineer-all-17 doctrine)',
        () {
      expect(adapter.capabilityProfile.lifecycle, VendorLifecycle.documented);
    });

    test('modules empty (no module disambiguation for Humanity)', () {
      expect(adapter.capabilityProfile.modules, isEmpty);
    });

    test('timestampPolicyDocId points at the per-vendor doc pack', () {
      expect(
        adapter.capabilityProfile.timestampPolicyDocId,
        'docs/integrations/humanity/field_mapping.md',
      );
    });

    test('timestampPolicy declares asUtc convention', () {
      expect(adapter.timestampPolicy.vendorId, 'humanity');
      expect(
        adapter.timestampPolicy.ambiguousConvention,
        AmbiguousTimestampConvention.asUtc,
      );
    });

    test('field-mapping constant mirrors fixture', () {
      // The adapter constant carries the engineering source-of-truth;
      // the fixture mirror is what the *.live.sandbox slice will diff
      // against. Drift between them would silently break that diff.
      for (final entry
          in documentedPerHumanityV10FieldMappingFixture.entries) {
        expect(
          documentedPerHumanityV10FieldMapping.containsKey(entry.key),
          true,
          reason: 'fixture key "${entry.key}" missing from adapter constant',
        );
      }
      for (final key in const <String>[
        'shift_start',
        'shift_end',
        'role_name',
        'employee_id',
        'vendor_entity_id',
        'vendor_modified_at',
      ]) {
        final adapterRow =
            documentedPerHumanityV10FieldMapping[key] as Map<String, Object?>?;
        final fixtureRow = documentedPerHumanityV10FieldMappingFixture[key]
            as Map<String, Object?>?;
        expect(adapterRow, isNotNull,
            reason: 'adapter missing field-mapping row for $key');
        expect(fixtureRow, isNotNull,
            reason: 'fixture missing field-mapping row for $key');
        expect(adapterRow!['path'], fixtureRow!['path'],
            reason: '$key.path drift between adapter and fixture');
        expect(adapterRow['type'], fixtureRow['type'],
            reason: '$key.type drift between adapter and fixture');
      }
    });
  });

  group('Sanity hook contract (Tests 1, 2, 3)', () {
    late _FakeHumanityHttpClient httpClient;
    late _FakeHumanityGateway gateway;
    late HumanityLaborAdapter adapter;
    late DateTime nowFixed;

    setUp(() {
      nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      httpClient = _FakeHumanityHttpClient()
        ..pages = <HumanityShiftsPage>[
          HumanityShiftsPage(
            records: humanityBackfillBatchPage1,
            nextCursor: 'cursor-page-2',
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
          ),
          HumanityShiftsPage(
            records: humanityBackfillBatchPage2,
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
          ),
        ];
      gateway = _FakeHumanityGateway()
        ..credential = const VendorCredentialHandle(credentialId: 'cred-001');
      adapter = HumanityLaborAdapter(
        httpClient: httpClient,
        gateway: gateway,
        now: () => nowFixed,
      );
    });

    test('Test 1 — sanity hook called once per record on backfill', () async {
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
          vendorId: 'humanity',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        humanityBackfillBatchPage1.length +
            humanityBackfillBatchPage2.length,
        reason: 'sanity hook must be called once per record across all pages',
      );
      expect(result.recordsWritten, 5);
      expect(result.batchesCommitted, 2);
    });

    test('Test 1 — sanity hook called once per record on pollIncremental',
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
          vendorId: 'humanity',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: hook,
        ),
      );

      expect(
        calls.length,
        humanityBackfillBatchPage1.length +
            humanityBackfillBatchPage2.length,
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
          vendorId: 'humanity',
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
          vendorId: 'humanity',
          lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
          sanityHook: alwaysOk,
        ),
      );
      expect(gateway.canonicalFacts.length, 5);

      // Replay: re-enqueue the exact same pages.
      httpClient.pages = <HumanityShiftsPage>[
        HumanityShiftsPage(
          records: humanityBackfillBatchPage1,
          nextCursor: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
        HumanityShiftsPage(
          records: humanityBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
        ),
      ];
      final secondResult = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'humanity',
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
      httpClient.crashAfterPageIndex = 0;
      httpClient.pages = <HumanityShiftsPage>[
        HumanityShiftsPage(
          records: humanityBackfillBatchPage1,
          nextCursor: 'cursor-page-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
        HumanityShiftsPage(
          records: humanityBackfillBatchPage2,
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
            vendorId: 'humanity',
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
      httpClient.crashAfterPageIndex = null;
      httpClient.pages = <HumanityShiftsPage>[
        HumanityShiftsPage(
          records: humanityBackfillBatchPage2,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
        ),
      ];

      final resumeResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'humanity',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: alwaysOk,
          resumeFromCursor: watermark.cursorToken,
        ),
      );
      expect(
        resumeResult.recordsWritten,
        humanityBackfillBatchPage2.length,
      );
      expect(resumeResult.batchesCommitted, 1);
    });
  });

  group('handleWebhook UnsupportedError (Test 4)', () {
    test('throws UnsupportedError citing pollOnly', () async {
      final adapter = HumanityLaborAdapter(
        httpClient: _FakeHumanityHttpClient(),
        gateway: _FakeHumanityGateway(),
      );
      expect(
        () => adapter.handleWebhook(
          HandleWebhookCommand(
            operatorId: _opId,
            locationId: _locId,
            vendorId: 'humanity',
            vendorEventId: 'unreachable',
            payload: const <String, Object?>{},
            headers: const <String, String>{},
            receivedAt: DateTime.utc(2026, 5, 4, 12, 0, 0),
          ),
        ),
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
    test('full lifecycle preserves watermark; reconnect requires re-paste',
        () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final httpClient = _FakeHumanityHttpClient()
        ..tokenResponse = const HumanityTokenResponse(
          accessToken: 'bearer-001',
          refreshToken: null,
        )
        ..pages = <HumanityShiftsPage>[
          HumanityShiftsPage(
            records: humanityBackfillBatchPage1,
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
          ),
        ];

      final gateway = _FakeHumanityGateway();
      final adapter = HumanityLaborAdapter(
        httpClient: httpClient,
        gateway: gateway,
        now: () => nowFixed,
      );

      // 1. Connect via keyPaste — username + password.
      final connectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'humanity',
          keyPaste: ConnectKeyPasteCredential(
            apiKey: _legacyPassword,
            username: _legacyUsername,
          ),
        ),
      );
      expect(connectResult.status, ConnectionStatus.connected);
      expect(connectResult.firstBackfillStarted, true);
      expect(connectResult.webhookUrl, isNull,
          reason: 'pollOnly — no webhook URL is provisioned');
      expect(connectResult.metadata['auth_mode'], 'keyPaste');
      expect(connectResult.metadata['auth_method'],
          'legacy_username_password');
      expect(httpClient.usernamePasswordCalls.length, 1);
      expect(httpClient.usernamePasswordCalls.first['username'],
          _legacyUsername);
      expect(httpClient.usernamePasswordCalls.first['password'],
          _legacyPassword);

      // 2. Backfill 60-day window.
      httpClient.pages = <HumanityShiftsPage>[
        HumanityShiftsPage(
          records: humanityBackfillBatchPage1,
          nextCursor: null,
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
        ),
      ];
      final backfillResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'humanity',
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
      expect(backfillResult.recordsWritten,
          humanityBackfillBatchPage1.length);

      // 3. Poll (no new rows — empty page).
      httpClient.pages = <HumanityShiftsPage>[
        HumanityShiftsPage(
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
          vendorId: 'humanity',
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
          vendorId: 'humanity',
          reason: DisconnectReason.operatorAction,
        ),
      );
      expect(disconnectResult.credentialsWiped, true);
      expect(disconnectResult.watermarkPreserved, true);
      expect(disconnectResult.webhookUnregistered, true,
          reason: 'pollOnly — uniform contract reports true');
      expect(gateway.credential, isNull,
          reason: 'wipeCredentials must clear the in-memory credential');

      // 5. Reconnect — operator re-pastes credentials. Watermark
      // survives because `wipeCredentials` only wipes credentials, not
      // the watermark or canonical facts.
      httpClient.tokenResponse = const HumanityTokenResponse(
        accessToken: 'bearer-002',
        refreshToken: null,
      );
      final reconnectResult = await adapter.connect(
        const ConnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'humanity',
          keyPaste: ConnectKeyPasteCredential(
            apiKey: 'humanity-rotated-password',
            username: _legacyUsername,
          ),
        ),
      );
      expect(reconnectResult.status, ConnectionStatus.connected);
      expect(httpClient.usernamePasswordCalls.length, 2,
          reason: 'reconnect must re-exchange username/password — there '
              'is no refresh-token magic on the legacy auth path');
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

    test('connect rejects empty username (legacy auth requires both)',
        () async {
      final adapter = HumanityLaborAdapter(
        httpClient: _FakeHumanityHttpClient(),
        gateway: _FakeHumanityGateway(),
      );
      expect(
        () => adapter.connect(
          const ConnectCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _opId,
            vendorId: 'humanity',
            keyPaste: ConnectKeyPasteCredential(
              apiKey: 'password-only',
            ),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Test connection (Test 6)', () {
    test('populates fieldMapping with shift_start + shift_end + role_name '
        'and returns under 30s on the offline path', () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      final httpClient = _FakeHumanityHttpClient()
        ..sample = humanitySampleShift;
      final gateway = _FakeHumanityGateway()
        ..credential = const VendorCredentialHandle(credentialId: 'cred-001');
      final adapter = HumanityLaborAdapter(
        httpClient: httpClient,
        gateway: gateway,
        now: () => nowFixed,
      );

      final result = await adapter.testConnection(
        const TestConnectionCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _opId,
          vendorId: 'humanity',
        ),
      );

      expect(result.authValid, true);
      expect(result.fieldMapping['shift_start'], '2026-05-04T16:00:00.000Z');
      expect(result.fieldMapping['shift_end'], '2026-05-04T22:30:00.000Z');
      expect(result.fieldMapping['role_name'], 'Server');
      expect(result.fieldMapping['employee_id'], 'EMP-7777');
      expect(result.fieldMapping['vendor_entity_id'], 'HUM-12345');
      expect(result.elapsedMs, lessThan(30000));
    });
  });

  group('Banned items grep (Test 8)', () {
    final adapterFile = File(
      'lib/integrations/labor/humanity_labor_adapter.dart',
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

    test('adapter has no webhook signature verifier file '
        '(pollOnly — N/A)', () {
      final verifier = File(
        'lib/integrations/labor/humanity_webhook_signature_verifier.dart',
      );
      expect(verifier.existsSync(), false,
          reason: 'pollOnly vendors do not ship a webhook signature '
              'verifier; the file existing would contradict the '
              'capability profile');
    });
  });

  // Phase 5 P1 #2 regression — Humanity time-off rows must NOT be
  // canonicalized as 24h shifts. Pre-fix the adapter accepted any row
  // with `in_time` / `out_time` populated, so a `type=time_off` row
  // (e.g. an 8h vacation day modeled as a midnight-to-midnight pair)
  // landed on the labor fact table as a 24h shift and inflated
  // labor-cost projections. Fixture:
  // `test/fixtures/vendor_payloads/humanity/happy_path_time_off_request.json`.
  group('HumanityShiftDto.tryFromMap time_off filter (P1 #2)', () {
    test('happy_path_time_off_request fixture: time_off row returns null',
        () {
      final raw = File(
        'test/fixtures/vendor_payloads/humanity/happy_path_time_off_request.json',
      ).readAsStringSync();
      final payload = jsonDecode(raw) as Map<String, Object?>;
      final data = payload['data'] as List<Object?>;
      final shiftRow =
          (data.firstWhere((r) => (r as Map)['type'] == 'shift')) as Map;
      final timeOffRow =
          (data.firstWhere((r) => (r as Map)['type'] == 'time_off')) as Map;

      final shiftDto = HumanityShiftDto.tryFromMap(
        Map<String, Object?>.from(shiftRow),
      );
      final timeOffDto = HumanityShiftDto.tryFromMap(
        Map<String, Object?>.from(timeOffRow),
      );

      expect(shiftDto, isNotNull,
          reason: 'regular shift row must still parse to a non-null DTO');
      expect(timeOffDto, isNull,
          reason: 'type=time_off row must be dropped at the boundary');
    });

    test('synthesized type=timeoff (no underscore) also returns null', () {
      final dto = HumanityShiftDto.tryFromMap(<String, Object?>{
        'id': '9999',
        'employee_id': 'EMP-999',
        'position_name': 'Server',
        'in_time': '2026-05-11T00:00:00Z',
        'out_time': '2026-05-12T00:00:00Z',
        'updated': '2026-05-04T09:15:00Z',
        'type': 'timeoff',
      });
      expect(dto, isNull);
    });

    test('case-insensitive: TIME_OFF returns null', () {
      final dto = HumanityShiftDto.tryFromMap(<String, Object?>{
        'id': '9998',
        'employee_id': 'EMP-998',
        'position_name': 'Server',
        'in_time': '2026-05-11T00:00:00Z',
        'out_time': '2026-05-12T00:00:00Z',
        'updated': '2026-05-04T09:15:00Z',
        'type': 'TIME_OFF',
      });
      expect(dto, isNull);
    });

    test('regular shift (type=shift) still parses to a non-null DTO', () {
      final dto = HumanityShiftDto.tryFromMap(<String, Object?>{
        'id': '5001',
        'employee_id': 'EMP-100',
        'position_name': 'Cook',
        'in_time': '2026-05-10T16:00:00Z',
        'out_time': '2026-05-10T22:00:00Z',
        'updated': '2026-05-04T09:15:00Z',
        'type': 'shift',
      });
      expect(dto, isNotNull);
      expect(dto!.id, '5001');
      expect(dto.positionName, 'Cook');
    });

    test('missing type field defaults to shift (parses to non-null DTO)', () {
      final dto = HumanityShiftDto.tryFromMap(<String, Object?>{
        'id': '5002',
        'employee_id': 'EMP-101',
        'position_name': 'Server',
        'in_time': '2026-05-10T16:00:00Z',
        'out_time': '2026-05-10T22:00:00Z',
        'updated': '2026-05-04T09:15:00Z',
      });
      expect(dto, isNotNull,
          reason: 'absent `type` field must not block normal-shift parse');
    });
  });
}

// ─── Fakes ──────────────────────────────────────────────────────────

class _FakeHumanityHttpClient implements HumanityHttpClient {
  HumanityTokenResponse? tokenResponse;
  Map<String, Object?> sample = const <String, Object?>{};
  List<HumanityShiftsPage> _pages = <HumanityShiftsPage>[];
  int? crashAfterPageIndex;
  int _pageCursor = 0;
  final List<Map<String, String>> usernamePasswordCalls =
      <Map<String, String>>[];
  int revokeCalls = 0;

  set pages(List<HumanityShiftsPage> next) {
    _pages = next;
    _pageCursor = 0;
  }

  List<HumanityShiftsPage> get pages => _pages;

  @override
  Future<HumanityTokenResponse> exchangeUsernamePassword({
    required String username,
    required String password,
  }) async {
    usernamePasswordCalls.add(<String, String>{
      'username': username,
      'password': password,
    });
    return tokenResponse ??
        const HumanityTokenResponse(accessToken: 'bearer-fake');
  }

  @override
  Future<HumanityShiftsPage> listShifts({
    required VendorCredentialHandle credential,
    required DateTime modifiedSince,
    DateTime? modifiedUntil,
    String? cursor,
  }) async {
    if (_pageCursor >= _pages.length) {
      return HumanityShiftsPage(
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
  Future<Map<String, Object?>?> fetchSampleShift({
    required VendorCredentialHandle credential,
  }) async {
    return sample.isEmpty ? null : sample;
  }

  @override
  Future<void> revokeCredential({
    required VendorCredentialHandle credential,
  }) async {
    revokeCalls += 1;
  }
}

class _FakeHumanityGateway implements HumanityGateway {
  VendorCredentialHandle? credential;
  HumanityWatermarkRow? watermark;
  String? connectionId;
  Map<String, Object?>? lastConnectionMetadata;
  final List<HumanityCanonicalShiftFact> canonicalFacts =
      <HumanityCanonicalShiftFact>[];
  final Set<String> _idempotencyKeys = <String>{};

  @override
  Future<String> persistConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required VendorCredentialHandle credential,
    required Map<String, Object?> metadata,
  }) async {
    this.credential = credential;
    lastConnectionMetadata = metadata;
    final id = 'humanity-$operatorId-$locationId';
    connectionId = id;
    return id;
  }

  @override
  Future<VendorCredentialHandle?> readCredential({
    required String operatorId,
    required String locationId,
  }) async =>
      credential;

  @override
  Future<HumanityWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) async =>
      watermark;

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required HumanityWatermarkRow row,
  }) async {
    watermark = row;
  }

  @override
  Future<bool> writeShiftFact(HumanityCanonicalShiftFact fact) async {
    final key = '${fact.operatorId}:${fact.locationId}:${fact.vendorEntityId}'
        ':${fact.vendorModifiedAt.toIso8601String()}';
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
    credential = null;
  }
}
