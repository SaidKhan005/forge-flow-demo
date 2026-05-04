// Phase 8R.TC — Tock reservation adapter tests.
//
// Engineering slice (lifecycle = `documented`). Fixture-only; no live
// HTTP. The `*.live.sandbox` slice repeats every check against the
// vendor sandbox per
// `docs/integrations/tock/live_verification_checklist.md`.
//
// Tests cover the mandatory framework calls per
// `docs/contracts/vendor_adapter_slice_contract.md`:
//   1. Sanity hook call count + reject.
//   2. Idempotency replay.
//   3. Watermark mid-batch resume.
//   4. Signature reject.
//   5. Connect → backfill → poll → disconnect → reconnect smoke.
//   6. Test-connection: fieldMapping with reservation_at, party_size,
//      status; offline ≪ 30s.
//   7. Replay window 24h.
//   8. manualPaste: connect returns ConnectResult with webhookUrl;
//      auto-register endpoint NOT invoked.
//   9. VendorCapabilityProfile assertions; lifecycle = documented;
//      webhookSupport = manualPaste.
//  10. Banned-items grep.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/reservation/tock_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/tock_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import 'fixtures/tock_reservations_fixture.dart';
import 'fixtures/tock_webhook_fixture.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _userId = '00000000-0000-4000-8000-0000000000b1';
const String _businessId = 'bus_3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011';
const String _signingSecret = 'tock-test-secret-2026-05-04';

void main() {
  group('TockReservationAdapter', () {
    late _FakeTockApiClient transport;
    late _RecordingFactSink sink;
    late TockReservationAdapter adapter;
    late DateTime nowFixed;

    setUp(() {
      nowFixed = DateTime.utc(2026, 5, 4, 20, 0, 0);
      transport = _FakeTockApiClient();
      sink = _RecordingFactSink();
      adapter = TockReservationAdapter(
        transport: transport,
        factSink: sink,
        now: () => nowFixed,
        batchSize: 50,
      );
    });

    test('1a. sanity hook is called once per record on backfill (deliberate)',
        () async {
      transport.queueBackfillPages(<List<Map<String, Object?>>>[
        tockBackfillPage1Reservations(),
      ]);
      final hook = _RecordingSanityHook(returnValue: true);

      await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
        windowStart: nowFixed.subtract(const Duration(days: 60)),
        windowEnd: nowFixed,
        sanityHook: hook.call,
      ));

      expect(hook.calls, tockBackfillPage1Reservations().length);
      expect(sink.factWrites.length, tockBackfillPage1Reservations().length);
      expect(
        hook.callsByDeliberateBackfillFlag[true],
        tockBackfillPage1Reservations().length,
        reason: 'backfill MUST set isDeliberateBackfill: true',
      );
    });

    test(
        '1b. sanity hook reject path skips canonical fact write '
        '(framework already logged the drop)', () async {
      transport.queueBackfillPages(<List<Map<String, Object?>>>[
        tockBackfillPage1Reservations(),
      ]);
      final hook = _RecordingSanityHook(returnValue: false);

      final result = await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
        windowStart: nowFixed.subtract(const Duration(days: 60)),
        windowEnd: nowFixed,
        sanityHook: hook.call,
      ));

      expect(hook.calls, tockBackfillPage1Reservations().length);
      expect(sink.factWrites, isEmpty);
      expect(result.recordsWritten, 0);
    });

    test('1c. polling sets isDeliberateBackfill: false', () async {
      transport.queuePollPages(<List<Map<String, Object?>>>[
        <Map<String, Object?>>[_resAt('poll-1', '2026-05-04T19:30:00.000Z')],
      ]);
      final hook = _RecordingSanityHook(returnValue: true);

      await adapter.pollIncremental(PollIncrementalCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
        lastModifiedSeen: nowFixed.subtract(const Duration(hours: 1)),
        sanityHook: hook.call,
      ));

      expect(hook.calls, 1);
      expect(
        hook.callsByDeliberateBackfillFlag[false],
        1,
        reason: 'polling MUST set isDeliberateBackfill: false',
      );
    });

    test('2. idempotency: same payload twice → single canonical write',
        () async {
      sink.idempotent = true;
      final webhookCmd = HandleWebhookCommand(
        operatorId: _opId,
        locationId: _locId,
        vendorId: kTockVendorId,
        vendorEventId: tockSampleReservation['id']! as String,
        payload: Map<String, Object?>.from(tockSampleReservation),
        headers: const <String, String>{},
        receivedAt: nowFixed,
      );

      final first = await adapter.handleWebhook(webhookCmd);
      final second = await adapter.handleWebhook(webhookCmd);

      expect(first.recordsWritten, 1);
      expect(second.recordsWritten, 0,
          reason: 'idempotent replay must short-circuit to no-op');
      expect(sink.factWrites.length, 1,
          reason: 'production-side UNIQUE is the only write');
    });

    test(
        '3. watermark mid-walk resume: throw on page 4 fetch leaves the '
        'last persisted watermark on page 3', () async {
      transport.queueBackfillPagesExplicit(<_FakePage>[
        _page(
          <Map<String, Object?>>[_resAt('p1-1', '2026-05-01T18:00:00.000Z')],
          nextCursor: 'cursor-after-1',
        ),
        _page(
          <Map<String, Object?>>[_resAt('p2-1', '2026-05-02T18:00:00.000Z')],
          nextCursor: 'cursor-after-2',
        ),
        _page(
          <Map<String, Object?>>[_resAt('p3-1', '2026-05-03T18:00:00.000Z')],
          nextCursor: 'cursor-after-3',
        ),
        _page(
          const <Map<String, Object?>>[],
          nextCursor: null,
          throwInstead: true,
        ),
      ]);

      Object? thrown;
      try {
        await adapter.backfill(BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: kTockVendorId,
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: ({
            required String vendorEventId,
            required Map<String, Object?> payload,
            required bool isDeliberateBackfill,
          }) async => true,
        ));
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isNotNull,
          reason: 'transport failure must propagate so worker can retry');
      expect(sink.watermarks.length, 3);
      expect(sink.watermarks.last['cursor_token'], 'cursor-after-3');
      expect(sink.factWrites.length, 3);
    });

    test('4. signature reject: tampered HMAC → valid:false + no fact write',
        () {
      const verifier = TockWebhookSignatureVerifier();
      final body = utf8.encode(jsonEncode(tockSampleReservation));
      final realSig = signTockWebhookBody(
        rawBody: body,
        signingSecret: _signingSecret,
      );
      // Flip the final hex character to force a mismatch.
      final tamperedSig =
          realSig.substring(0, realSig.length - 1) +
              (realSig.endsWith('0') ? '1' : '0');
      final result = verifier.verify(
        rawBody: Uint8List.fromList(body),
        headers: <String, String>{
          'x-tock-signature': tamperedSig,
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );

      expect(result.valid, false);
      expect(result.failureReason, contains('HMAC mismatch'));

      // Real signature passes (sanity check that the test is wired
      // correctly).
      final real = verifier.verify(
        rawBody: Uint8List.fromList(body),
        headers: <String, String>{
          'x-tock-signature': realSig,
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(real.valid, true);
    });

    test('5. connect → backfill → poll → disconnect → reconnect smoke',
        () async {
      // Connect.
      final connectResult = await adapter.connect(ConnectCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
        keyPaste: const ConnectKeyPasteCredential(
          apiKey: 'tock-key-fixture',
          username: _businessId,
        ),
      ));
      expect(connectResult.status, ConnectionStatus.connected);
      expect(connectResult.metadata['business_id'], _businessId);
      expect(connectResult.metadata['webhook_pending'], true);
      expect(connectResult.metadata['webhook_support'], 'manual_paste');
      expect(connectResult.firstBackfillStarted, true);
      expect(connectResult.webhookUrl,
          '/v1/webhooks/$kTockVendorId/$_opId/$_locId');

      // Backfill.
      transport.queueBackfillPages(<List<Map<String, Object?>>>[
        tockBackfillPage1Reservations(),
      ]);
      final backfill = await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
        windowStart: nowFixed.subtract(const Duration(days: 60)),
        windowEnd: nowFixed,
        sanityHook: ({
          required String vendorEventId,
          required Map<String, Object?> payload,
          required bool isDeliberateBackfill,
        }) async => true,
      ));
      expect(backfill.completed, true);
      expect(
        backfill.recordsWritten,
        tockBackfillPage1Reservations().length,
      );
      final watermarkAfterBackfill = sink.watermarks.last;

      // Poll.
      transport.queuePollPages(<List<Map<String, Object?>>>[
        <Map<String, Object?>>[
          _resAt('poll-1', '2026-05-04T19:30:00.000Z'),
        ],
      ]);
      final poll = await adapter.pollIncremental(PollIncrementalCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
        lastModifiedSeen: backfill.lastModifiedSeen,
        sanityHook: ({
          required String vendorEventId,
          required Map<String, Object?> payload,
          required bool isDeliberateBackfill,
        }) async => true,
      ));
      expect(poll.recordsWritten, 1);

      // Disconnect — preserves history + watermark; no auto-unregister
      // because Tock is manualPaste.
      final disconnect = await adapter.disconnect(DisconnectCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
        reason: DisconnectReason.operatorAction,
      ));
      expect(disconnect.credentialsWiped, true);
      expect(disconnect.webhookUnregistered, false,
          reason:
              'manualPaste vendor: adapter never registered a vendor-side webhook');
      expect(disconnect.watermarkPreserved, true);

      // Reconnect — runs another backfill resuming from the preserved
      // watermark.
      transport.queueBackfillPages(<List<Map<String, Object?>>>[
        <Map<String, Object?>>[
          _resAt('resume-1', '2026-05-05T18:00:00.000Z'),
        ],
      ]);
      final reconnect = await adapter.connect(ConnectCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
        keyPaste: const ConnectKeyPasteCredential(
          apiKey: 'tock-key-fixture',
          username: _businessId,
        ),
      ));
      expect(reconnect.status, ConnectionStatus.connected);

      final secondBackfill = await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
        windowStart: nowFixed.subtract(const Duration(days: 60)),
        windowEnd: nowFixed,
        resumeFromCursor: watermarkAfterBackfill['cursor_token']! as String,
        sanityHook: ({
          required String vendorEventId,
          required Map<String, Object?> payload,
          required bool isDeliberateBackfill,
        }) async => true,
      ));
      expect(secondBackfill.recordsWritten, 1);
      expect(
        sink.factWrites.where((w) => w['vendor_entity_id'] == 'p1-res-001'),
        hasLength(1),
        reason: 'reconnect resumes from cursor; no rewind',
      );
    });

    test('6. test-connection: fieldMapping populated; offline ≪ 30s',
        () async {
      var clockTicks = 0;
      adapter = TockReservationAdapter(
        transport: transport,
        factSink: sink,
        now: () {
          clockTicks++;
          return clockTicks == 1
              ? DateTime.utc(2026, 5, 4, 20, 0, 0, 0)
              : DateTime.utc(2026, 5, 4, 20, 0, 0, 7);
        },
      );

      final result = await adapter.testConnection(TestConnectionCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
      ));

      expect(result.authValid, true);
      expect(
        result.fieldMapping['reservation_at'],
        '2026-05-04T19:00:00.000Z',
      );
      expect(result.fieldMapping['party_size'], 4);
      expect(result.fieldMapping['status'], 'seated');
      expect(
        result.fieldMapping['vendor_entity_id'],
        'res_d1f9cd4a-4f4b-4d6e-9b7d-9a4f1f7c8e21',
      );
      expect(
        result.fieldMapping['vendor_modified_at'],
        '2026-05-04T19:10:00.000Z',
      );
      expect(result.elapsedMs, lessThan(30000),
          reason: 'offline path ≪ 30s framework timeout');
      expect(result.note, contains('partySize'),
          reason: 'covers source = not_applicable surfaced for the operator');
      expect(result.note, contains('Per-transition timestamps'),
          reason:
              'note must flag the per-transition-timestamp ambiguity for *.live.sandbox');
    });

    test(
        '7. replay window 24h: framework ceiling enforced via the verifier '
        'extracting X-Tock-Webhook-Timestamp', () {
      const verifier = TockWebhookSignatureVerifier();
      final body = utf8.encode(jsonEncode(tockSampleReservation));
      final sig = signTockWebhookBody(
        rawBody: body,
        signingSecret: _signingSecret,
      );

      // Just inside 24h — accepted; replay defense does not fire.
      final freshTs = nowFixed.subtract(const Duration(hours: 23));
      final fresh = verifier.verify(
        rawBody: Uint8List.fromList(body),
        headers: <String, String>{
          'x-tock-signature': sig,
          'x-tock-webhook-timestamp':
              (freshTs.millisecondsSinceEpoch ~/ 1000).toString(),
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(fresh.valid, true);
      expect(fresh.timestamp, isNotNull);
      expect(
        nowFixed.difference(fresh.timestamp!),
        lessThan(kInboundWebhookReplayCeiling),
        reason: 'fresh signature timestamp is within the 24h ceiling',
      );

      // Just outside 24h — verifier still returns valid (signature
      // OK) but the framework will reject because the timestamp is
      // older than `kInboundWebhookReplayCeiling`.
      final staleTs = nowFixed.subtract(const Duration(hours: 25));
      final stale = verifier.verify(
        rawBody: Uint8List.fromList(body),
        headers: <String, String>{
          'x-tock-signature': sig,
          'x-tock-webhook-timestamp':
              (staleTs.millisecondsSinceEpoch ~/ 1000).toString(),
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(stale.valid, true,
          reason:
              'signature itself is valid; replay defense is the framework');
      expect(stale.timestamp, isNotNull);
      expect(
        nowFixed.difference(stale.timestamp!),
        greaterThan(kInboundWebhookReplayCeiling),
        reason:
            'stale timestamp must trigger framework replay rejection at 24h',
      );

      // V1 lean cut 2 ceiling is exactly 24h.
      expect(kInboundWebhookReplayCeiling, const Duration(hours: 24));
    });

    test(
        '8. manualPaste: connect returns ConnectResult with webhookUrl; no '
        'auto-register endpoint exists or is invoked', () async {
      final connectResult = await adapter.connect(ConnectCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kTockVendorId,
        keyPaste: const ConnectKeyPasteCredential(
          apiKey: 'tock-key-fixture',
          username: _businessId,
        ),
      ));

      expect(connectResult.webhookUrl,
          '/v1/webhooks/$kTockVendorId/$_opId/$_locId');
      expect(connectResult.metadata['webhook_support'], 'manual_paste');
      expect(connectResult.metadata['webhook_pending'], true);

      // Source-level guarantee: TockApiClient must NOT expose an
      // auto-register / unregister method. Adding one would invite an
      // accidental call path that violates the manualPaste contract.
      final adapterSource = File(
        'lib/integrations/reservation/tock_reservation_adapter.dart',
      ).readAsStringSync();
      expect(adapterSource, isNot(contains('registerWebhook')),
          reason:
              'manualPaste adapter must not expose registerWebhook on transport');
      expect(adapterSource, isNot(contains('unregisterWebhook')),
          reason:
              'manualPaste adapter must not expose unregisterWebhook on transport');
    });

    test(
        '9. capability profile: every required field declared; lifecycle = '
        'documented; webhookSupport = manualPaste; coversFieldExposed = '
        'false (covers_source = not_applicable in field_mapping.md)', () {
      final profile = adapter.capabilityProfile;

      expect(profile.vendorId, kTockVendorId);
      expect(profile.displayName, kTockDisplayName);
      expect(profile.category, IntegrationCategory.reservation);
      expect(profile.authMode, VendorAuthMode.keyPaste,
          reason:
              'Tock issues per-business API keys via integrate@tockhq.com — no OAuth flow documented');
      expect(profile.grantScope, VendorGrantScope.perLocation,
          reason: 'Tock business_id is per-location');
      expect(profile.webhookSupport, VendorWebhookSupport.manualPaste,
          reason:
              'Tock requires manual paste of webhook URL + signing secret in the Premium-tier dashboard');
      expect(profile.coversFieldExposed, false,
          reason:
              'reservations expose partySize, not covers — classification is not_applicable');
      expect(profile.lifecycle, VendorLifecycle.documented,
          reason: 'engineering slice ships at lifecycle = documented');
      expect(profile.modules, isEmpty,
          reason: 'Tock has no module disambiguation');
      expect(profile.timestampPolicyDocId, 'tock');

      // Partnership / Premium-tier detail is captured in
      // docs/integrations/tock/partnership_status.md, not via a
      // boolean here. Picker chrome reads `lifecycle`.
      final partnershipDoc = File(
        'docs/integrations/tock/partnership_status.md',
      );
      expect(partnershipDoc.existsSync(), true,
          reason: 'partnership status doc must be populated');
      final body = partnershipDoc.readAsStringSync();
      expect(body, contains('not_started'));
      expect(body, contains('Premium'));
      expect(body, contains('4-8 weeks'));
    });

    test('10. status vocabulary normalization: every documented vendor '
        'status maps to the canonical enum; unknown vendor strings fall '
        'through to "unknown"', () async {
      final cases = <String, String>{
        'EXPECTED': 'expected',
        'ARRIVED': 'arrived',
        'SEATED': 'seated',
        'LEFT': 'left',
        'NO_SHOW': 'no_show',
        'CANCELLED': 'canceled',
        'expected': 'expected',
        '  seated  ': 'seated',
        'TOTALLY_NEW_STATUS': 'unknown',
      };
      for (final entry in cases.entries) {
        final webhookCmd = HandleWebhookCommand(
          operatorId: _opId,
          locationId: _locId,
          vendorId: kTockVendorId,
          vendorEventId: 'res-status-${entry.key.trim()}-${entry.value}',
          payload: <String, Object?>{
            'id': 'res-status-${entry.key.trim()}-${entry.value}',
            'businessId': _businessId,
            'createdTimestamp': '2026-05-01T00:00:00.000Z',
            'lastUpdatedTimestamp': '2026-05-04T00:00:00.000Z',
            'serviceDateTimestamp': '2026-05-04T19:00:00.000Z',
            'partySize': 2,
            'status': entry.key,
          },
          headers: const <String, String>{},
          receivedAt: nowFixed,
        );
        await adapter.handleWebhook(webhookCmd);
        final lastWrite = sink.factWrites.last;
        expect(lastWrite['status'], entry.value,
            reason:
                'vendor status "${entry.key}" must normalize to canonical "${entry.value}"');
        expect(lastWrite['vendor_status_raw'], entry.key,
            reason: 'raw vendor status preserved for audit trace');
      }
    });

    test(
        '11. banned-items grep: V1 lean cut 2 list absent from adapter + '
        'verifier source', () {
      const banned = <String>[
        'KMS',
        'pgp_sym_decrypt',
        'parse_warnings',
        'parse_partial',
        'pg_try_advisory_lock',
        'SIGTERM',
        'inbound_webhook_dlq',
        'raw_payload_partition',
        '5-second SLA',
      ];

      final adapterSource = File(
        'lib/integrations/reservation/tock_reservation_adapter.dart',
      ).readAsStringSync();
      final verifierSource = File(
        'lib/integrations/reservation/tock_webhook_signature_verifier.dart',
      ).readAsStringSync();

      final adapterCode = _stripLeadingDocComment(adapterSource);
      final verifierCode = _stripLeadingDocComment(verifierSource);

      for (final token in banned) {
        expect(adapterCode, isNot(contains(token)),
            reason: 'banned token "$token" present in adapter source');
        expect(verifierCode, isNot(contains(token)),
            reason: 'banned token "$token" present in verifier source');
      }

      // Replay window must be the framework 24h ceiling, not a strict
      // 5-minute window.
      expect(adapterCode, isNot(contains('Duration(minutes: 5)')));
      expect(verifierCode, isNot(contains('Duration(minutes: 5)')));
    });
  });
}

/// Strip the leading `//`-style doc-comment block so the banned-items
/// grep does not flag the contract reminder at the top of each file.
String _stripLeadingDocComment(String source) {
  final lines = source.split('\n');
  var firstNonComment = 0;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (trimmed.startsWith('//') || trimmed.isEmpty) continue;
    firstNonComment = i;
    break;
  }
  return lines.sublist(firstNonComment).join('\n');
}

Map<String, Object?> _resAt(String id, String iso) {
  return <String, Object?>{
    'id': id,
    'businessId': _businessId,
    'createdTimestamp': iso,
    'lastUpdatedTimestamp': iso,
    'serviceDateTimestamp': iso,
    'partySize': 2,
    'status': 'EXPECTED',
  };
}

class _RecordingSanityHook {
  _RecordingSanityHook({required this.returnValue});

  final bool returnValue;
  int calls = 0;
  final Map<bool, int> callsByDeliberateBackfillFlag = <bool, int>{
    true: 0,
    false: 0,
  };

  Future<bool> call({
    required String vendorEventId,
    required Map<String, Object?> payload,
    required bool isDeliberateBackfill,
  }) async {
    calls++;
    callsByDeliberateBackfillFlag[isDeliberateBackfill] =
        (callsByDeliberateBackfillFlag[isDeliberateBackfill] ?? 0) + 1;
    return returnValue;
  }
}

class _RecordingFactSink implements TockFactSink {
  final List<Map<String, Object?>> factWrites = <Map<String, Object?>>[];
  final List<Map<String, Object?>> watermarks = <Map<String, Object?>>[];

  bool idempotent = false;

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
    required Map<String, Object?> rawPayload,
  }) async {
    if (idempotent) {
      final key =
          '${canonicalFact['vendor_entity_id']}|${canonicalFact['vendor_modified_at']}';
      final dup = factWrites.any((w) =>
          '${w['vendor_entity_id']}|${w['vendor_modified_at']}' == key);
      if (dup) return false;
    }
    factWrites.add(<String, Object?>{
      ...canonicalFact,
    });
    return true;
  }

  @override
  Future<void> persistWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    watermarks.add(<String, Object?>{
      'cursor_token': cursorToken,
      'last_modified_seen': lastModifiedSeen.toIso8601String(),
    });
  }
}

_FakePage _page(
  List<Map<String, Object?>> reservations, {
  String? nextCursor,
  bool throwInstead = false,
}) {
  return _FakePage(
    reservations: reservations,
    nextCursor: nextCursor,
    throwInstead: throwInstead,
  );
}

class _FakePage {
  _FakePage({
    required this.reservations,
    required this.nextCursor,
    this.throwInstead = false,
  });

  final List<Map<String, Object?>> reservations;
  final String? nextCursor;
  final bool throwInstead;
}

class _FakeTockApiClient implements TockApiClient {
  final List<_FakePage> _backfillPages = <_FakePage>[];
  final List<_FakePage> _pollPages = <_FakePage>[];

  void queueBackfillPages(List<List<Map<String, Object?>>> pages) {
    _backfillPages.clear();
    for (var i = 0; i < pages.length; i++) {
      _backfillPages.add(_page(
        pages[i],
        nextCursor: i == pages.length - 1 ? null : 'cursor-after-${i + 1}',
      ));
    }
  }

  void queueBackfillPagesExplicit(List<_FakePage> pages) {
    _backfillPages
      ..clear()
      ..addAll(pages);
  }

  void queuePollPages(List<List<Map<String, Object?>>> pages) {
    _pollPages.clear();
    for (var i = 0; i < pages.length; i++) {
      _pollPages.add(_page(
        pages[i],
        nextCursor: i == pages.length - 1 ? null : 'cursor-after-${i + 1}',
      ));
    }
  }

  @override
  Future<TockCredentialHandle> verifyApiKey({
    required String operatorId,
    required String locationId,
    required String businessId,
    required String apiKey,
  }) async {
    return const TockCredentialHandle(
      connectionId: 'conn-tock-1',
      businessId: _businessId,
    );
  }

  @override
  Future<Map<String, Object?>> fetchSampleReservation({
    required TockCredentialHandle credentials,
  }) async {
    return Map<String, Object?>.from(tockSampleReservation);
  }

  @override
  Future<TockReservationsPage> fetchReservationsPage({
    required TockCredentialHandle credentials,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? resumeFromCursor,
  }) async {
    final pool = _backfillPages.isNotEmpty ? _backfillPages : _pollPages;
    if (pool.isEmpty) {
      return TockReservationsPage(
        reservations: const <Map<String, Object?>>[],
        nextCursor: null,
        lastModifiedSeen: windowStart,
      );
    }
    final page = pool.removeAt(0);
    if (page.throwInstead) {
      throw StateError('fake transport: simulated mid-walk failure');
    }
    return TockReservationsPage(
      reservations: page.reservations,
      nextCursor: page.nextCursor,
      lastModifiedSeen: page.reservations.isEmpty
          ? windowStart
          : DateTime.parse(
              page.reservations.last['lastUpdatedTimestamp']! as String,
            ),
    );
  }

  @override
  Future<Map<String, Object?>?> fetchReservationById({
    required TockCredentialHandle credentials,
    required String reservationId,
  }) async {
    return Map<String, Object?>.from(tockSampleReservation)
      ..['id'] = reservationId;
  }
}
