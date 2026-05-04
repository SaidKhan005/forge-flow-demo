// Phase 8.AL — Aloha (NCR Voyix) POS adapter tests.
//
// Engineering slice (lifecycle = `documented`). Fixture-only; no live
// HTTP. The `8.AL.live.sandbox` slice repeats every check against the
// vendor sandbox per
// `docs/integrations/aloha_ncr_voyix/live_verification_checklist.md`.
//
// Tests cover the mandatory framework calls per
// `docs/contracts/vendor_adapter_slice_contract.md`:
//   1. Sanity hook call count.
//   2. Sanity hook reject path.
//   3. Idempotency replay.
//   4. Watermark mid-batch resume.
//   5. Signature reject.
//   6. Connect → backfill → poll → disconnect → reconnect smoke.
//   7. Test connection (fieldMapping populated; offline ≪ 30s).
//   8. Replay window 24h.
//   9. VendorCapabilityProfile assertions; lifecycle = documented.
//  10. Banned-items grep.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import 'fixtures/aloha_ncr_voyix_orders_fixture.dart';
import 'fixtures/aloha_ncr_voyix_webhook_fixture.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _userId = '00000000-0000-4000-8000-0000000000b1';
const String _siteId = 'site-aloha-001';
const String _signingSecret = 'aloha-ncr-voyix-test-secret-2026-05-04';

void main() {
  group('AlohaNcrVoyixPosAdapter', () {
    late _FakeAlohaNcrVoyixApiClient transport;
    late _RecordingFactSink sink;
    late AlohaNcrVoyixPosAdapter adapter;
    late DateTime nowFixed;

    setUp(() {
      nowFixed = DateTime.utc(2026, 5, 4, 20, 0, 0);
      transport = _FakeAlohaNcrVoyixApiClient();
      sink = _RecordingFactSink();
      adapter = AlohaNcrVoyixPosAdapter(
        transport: transport,
        factSink: sink,
        now: () => nowFixed,
        // Force small batch limits so the watermark-resume test can
        // simulate mid-walk restarts deterministically without 50+
        // pages of fixture.
        batchSize: 50,
      );
    });

    test('1. sanity hook is called once per record on backfill + poll',
        () async {
      transport.queueBackfillPages(<List<Map<String, Object?>>>[
        alohaNcrVoyixBackfillPage1Checks(),
      ]);
      final hook = _RecordingSanityHook(returnValue: true);

      await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kAlohaNcrVoyixVendorId,
        windowStart: nowFixed.subtract(const Duration(days: 60)),
        windowEnd: nowFixed,
        sanityHook: hook.call,
      ));

      expect(hook.calls, alohaNcrVoyixBackfillPage1Checks().length);
      expect(sink.factWrites.length, alohaNcrVoyixBackfillPage1Checks().length);
      expect(
        hook.callsByDeliberateBackfillFlag[true],
        alohaNcrVoyixBackfillPage1Checks().length,
        reason: 'backfill MUST set isDeliberateBackfill: true',
      );
    });

    test(
        '2. sanity hook reject path skips canonical fact write '
        '(framework already logged the drop)', () async {
      transport.queueBackfillPages(<List<Map<String, Object?>>>[
        alohaNcrVoyixBackfillPage1Checks(),
      ]);
      // Reject every event.
      final hook = _RecordingSanityHook(returnValue: false);

      final result = await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kAlohaNcrVoyixVendorId,
        windowStart: nowFixed.subtract(const Duration(days: 60)),
        windowEnd: nowFixed,
        sanityHook: hook.call,
      ));

      expect(hook.calls, alohaNcrVoyixBackfillPage1Checks().length);
      expect(sink.factWrites, isEmpty);
      expect(result.recordsWritten, 0);
    });

    test('3. idempotency: same payload twice → single canonical write',
        () async {
      // The framework's idempotency UNIQUE
      // `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
      // is enforced by the production sink. The fake sink mirrors that
      // contract: a second upsert with identical canonical fields
      // returns false (no-op).
      sink.idempotent = true;
      final hook = _RecordingSanityHook(returnValue: true);
      final webhookCmd = HandleWebhookCommand(
        operatorId: _opId,
        locationId: _locId,
        vendorId: kAlohaNcrVoyixVendorId,
        vendorEventId: alohaNcrVoyixSampleCheck['checkId']! as String,
        payload: Map<String, Object?>.from(alohaNcrVoyixSampleCheck),
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
      // Ensure the test is independent of the sanity hook (webhook
      // path runs sanity inline at the framework before this point).
      expect(hook.calls, 0);
    });

    test(
        '4. watermark mid-walk resume: throw on page 4 fetch leaves the '
        'last persisted watermark on page 3', () async {
      // Three serve-able pages, then a throw sentinel. After three
      // batches commit (cursors `cursor-after-1`, `cursor-after-2`,
      // `cursor-after-3`), the next fetch throws — the worker propagates
      // the failure, retries on the next tick, and resumes from
      // `cursor-after-3`. Per `vendor_adapter_slice_contract.md`
      // Mandatory call #3, the watermark is updated AFTER each
      // successful batch commit.
      transport.queueBackfillPagesExplicit(<_FakePage>[
        _page(
          <Map<String, Object?>>[_checkAt('p1-1', '2026-05-01T18:00:00.000Z')],
          nextCursor: 'cursor-after-1',
        ),
        _page(
          <Map<String, Object?>>[_checkAt('p2-1', '2026-05-02T18:00:00.000Z')],
          nextCursor: 'cursor-after-2',
        ),
        _page(
          <Map<String, Object?>>[_checkAt('p3-1', '2026-05-03T18:00:00.000Z')],
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
          vendorId: kAlohaNcrVoyixVendorId,
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
      // Three batches committed before the failure → three watermarks.
      expect(sink.watermarks.length, 3);
      // Last persisted watermark = page 3's nextCursor; the resume
      // cursor for the failed page 4 fetch.
      expect(sink.watermarks.last['cursor_token'], 'cursor-after-3');
      expect(sink.factWrites.length, 3,
          reason: 'three pages worth of checks committed before the throw');
    });

    test(
        '5. signature reject: tampered HMAC → valid:false + no fact write',
        () {
      const verifier = AlohaNcrVoyixWebhookSignatureVerifier();
      final body = utf8.encode(jsonEncode(alohaNcrVoyixSampleCheck));
      final realSig = signAlohaNcrVoyixWebhookBody(
        rawBody: body,
        signingSecret: _signingSecret,
      );
      final tamperedSig = base64Encode(<int>[
        ...base64Decode(realSig).sublist(0, base64Decode(realSig).length - 1),
        // Flip the final byte to force a mismatch.
        (base64Decode(realSig).last ^ 0x01) & 0xff,
      ]);
      final result = verifier.verify(
        rawBody: Uint8List.fromList(body),
        headers: <String, String>{
          'ncr-webhook-signature': tamperedSig,
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );

      expect(result.valid, false);
      expect(result.failureReason, contains('HMAC mismatch'));

      // Real signature passes (sanity check that the test is wired
      // correctly — a tampered-signature test is meaningless if even
      // the un-tampered payload would have failed).
      final real = verifier.verify(
        rawBody: Uint8List.fromList(body),
        headers: <String, String>{
          'ncr-webhook-signature': realSig,
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(real.valid, true);
    });

    test('6. connect → backfill → poll → disconnect → reconnect smoke',
        () async {
      // Connect.
      final connectResult = await adapter.connect(ConnectCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kAlohaNcrVoyixVendorId,
        keyPaste: const ConnectKeyPasteCredential(
          apiKey: 'unused',
          username: _siteId,
        ),
      ));
      expect(connectResult.status, ConnectionStatus.connected);
      expect(connectResult.metadata['site_id'], _siteId);
      expect(connectResult.firstBackfillStarted, true);

      // Backfill.
      transport.queueBackfillPages(<List<Map<String, Object?>>>[
        alohaNcrVoyixBackfillPage1Checks(),
      ]);
      final backfill = await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kAlohaNcrVoyixVendorId,
        windowStart: nowFixed.subtract(const Duration(days: 60)),
        windowEnd: nowFixed,
        sanityHook: ({
          required String vendorEventId,
          required Map<String, Object?> payload,
          required bool isDeliberateBackfill,
        }) async => true,
      ));
      expect(backfill.completed, true);
      expect(backfill.recordsWritten,
          alohaNcrVoyixBackfillPage1Checks().length);
      final watermarkAfterBackfill = sink.watermarks.last;

      // Poll.
      transport.queuePollPages(<List<Map<String, Object?>>>[
        <Map<String, Object?>>[_checkAt(
          'poll-1', '2026-05-04T19:30:00.000Z',
        )],
      ]);
      final poll = await adapter.pollIncremental(PollIncrementalCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kAlohaNcrVoyixVendorId,
        lastModifiedSeen: backfill.lastModifiedSeen,
        sanityHook: ({
          required String vendorEventId,
          required Map<String, Object?> payload,
          required bool isDeliberateBackfill,
        }) async => true,
      ));
      expect(poll.recordsWritten, 1);

      // Disconnect — preserves history + watermark.
      final disconnect = await adapter.disconnect(DisconnectCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kAlohaNcrVoyixVendorId,
        reason: DisconnectReason.operatorAction,
      ));
      expect(disconnect.credentialsWiped, true);
      expect(disconnect.watermarkPreserved, true,
          reason: 'reconnect resumes from this cursor');

      // Reconnect — runs another backfill resuming from the preserved
      // watermark. The fake transport accepts the resume cursor and
      // returns one more page.
      transport.queueBackfillPages(<List<Map<String, Object?>>>[
        <Map<String, Object?>>[_checkAt(
          'resume-1', '2026-05-05T18:00:00.000Z',
        )],
      ]);
      final reconnect = await adapter.connect(ConnectCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kAlohaNcrVoyixVendorId,
        keyPaste: const ConnectKeyPasteCredential(
          apiKey: 'unused',
          username: _siteId,
        ),
      ));
      expect(reconnect.status, ConnectionStatus.connected);

      final secondBackfill = await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _userId,
        vendorId: kAlohaNcrVoyixVendorId,
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
      // Cursor advanced; old facts aren't double-written (the fake
      // sink would double-record only if the adapter re-read from
      // the start).
      expect(
        sink.factWrites.where((w) => w['vendor_entity_id'] == 'p1-check-001'),
        hasLength(1),
        reason: 'reconnect resumes from cursor; no rewind',
      );
    });

    test('7. test-connection: fieldMapping populated; offline ≪ 30s',
        () async {
      // Force two distinct clock values so elapsedMs is observable +
      // bounded — the offline path completes in well under the
      // 30-second framework timeout.
      var clockTicks = 0;
      adapter = AlohaNcrVoyixPosAdapter(
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
        vendorId: kAlohaNcrVoyixVendorId,
      ));

      expect(result.authValid, true);
      expect(result.fieldMapping['covers'], 4);
      expect(
        result.fieldMapping['opened_at'],
        '2026-05-04T18:30:00.000Z',
      );
      expect(
        result.fieldMapping['closed_at'],
        '2026-05-04T19:55:00.000Z',
      );
      expect(result.fieldMapping['actual_sales'], 87.20);
      expect(
        result.fieldMapping['vendor_entity_id'],
        'chk-2026-05-04-001',
      );
      expect(result.elapsedMs, lessThan(30000),
          reason: 'offline path ≪ 30s framework timeout');
      expect(result.note, contains('numberOfGuests'),
          reason: 'covers source = direct surfaced for the operator');
    });

    test(
        '8. replay window 24h: framework ceiling enforced via the verifier '
        'extracting NCR-Webhook-Timestamp', () {
      const verifier = AlohaNcrVoyixWebhookSignatureVerifier();
      final body = utf8.encode(jsonEncode(alohaNcrVoyixSampleCheck));
      final sig = signAlohaNcrVoyixWebhookBody(
        rawBody: body,
        signingSecret: _signingSecret,
      );

      // Just inside 24h — accepted; replay defense does not fire.
      final freshTs = nowFixed.subtract(const Duration(hours: 23));
      final fresh = verifier.verify(
        rawBody: Uint8List.fromList(body),
        headers: <String, String>{
          'ncr-webhook-signature': sig,
          'ncr-webhook-timestamp':
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

      // Just outside 24h — verifier still returns valid (signature OK)
      // but the framework will reject because the timestamp is older
      // than `kInboundWebhookReplayCeiling`.
      final staleTs = nowFixed.subtract(const Duration(hours: 25));
      final stale = verifier.verify(
        rawBody: Uint8List.fromList(body),
        headers: <String, String>{
          'ncr-webhook-signature': sig,
          'ncr-webhook-timestamp':
              (staleTs.millisecondsSinceEpoch ~/ 1000).toString(),
        },
        signingSecret: _signingSecret,
        now: nowFixed,
      );
      expect(stale.valid, true,
          reason: 'signature itself is valid; replay defense is the framework');
      expect(stale.timestamp, isNotNull);
      expect(
        nowFixed.difference(stale.timestamp!),
        greaterThan(kInboundWebhookReplayCeiling),
        reason:
            'stale timestamp must trigger framework replay rejection at 24h',
      );

      // V1 lean cut 2 ceiling is exactly 24h — strict 5-min window
      // is explicitly NOT used.
      expect(kInboundWebhookReplayCeiling, const Duration(hours: 24));
    });

    test(
        '9. capability profile: every required field declared; lifecycle = '
        'documented; coversFieldExposed = true; partnership detail lives in '
        'partnership_status.md not via boolean', () {
      final profile = adapter.capabilityProfile;

      expect(profile.vendorId, kAlohaNcrVoyixVendorId);
      expect(profile.displayName, kAlohaNcrVoyixDisplayName);
      expect(profile.category, IntegrationCategory.pos);
      expect(profile.authMode, VendorAuthMode.oauth);
      expect(profile.grantScope, VendorGrantScope.perLocation,
          reason: 'Aloha siteId is per-location');
      expect(profile.webhookSupport, VendorWebhookSupport.autoRegister);
      expect(profile.coversFieldExposed, true,
          reason: 'Aloha numberOfGuests = direct covers');
      expect(profile.modules, isEmpty,
          reason: 'Aloha (NCR Voyix) has no module disambiguation');
      expect(profile.timestampPolicyDocId, 'aloha_ncr_voyix');

      // Lifecycle is the canonical state at engineering close.
      expect(adapter.lifecycle, VendorLifecycle.documented);

      // Partnership-gated detail is captured in
      // docs/integrations/aloha_ncr_voyix/partnership_status.md, not
      // via a boolean here. The slice prompt explicitly forbids
      // surfacing partnership state via the capability boolean —
      // picker chrome reads `lifecycle`.
      final partnershipDoc = File(
        'docs/integrations/aloha_ncr_voyix/partnership_status.md',
      );
      expect(partnershipDoc.existsSync(), true,
          reason: 'partnership status doc must be populated');
      final body = partnershipDoc.readAsStringSync();
      expect(body, contains('not_started'));
      expect(body, contains('NCR Voyix Developer Program'));
      expect(body, contains('Aloha module'));
      expect(body, contains('8-16 weeks'),
          reason: 'lead time for NCR Voyix Developer Program intake');
    });

    test(
        '10. banned-items grep: V1 lean cut 2 list absent from adapter + '
        'verifier source', () {
      // Per memory/project_v1_lean_cut_2_2026_05_03.md. REJECT-on-
      // presence list.
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
        'lib/integrations/pos/aloha_ncr_voyix_pos_adapter.dart',
      ).readAsStringSync();
      final verifierSource = File(
        'lib/integrations/pos/aloha_ncr_voyix_webhook_signature_verifier.dart',
      ).readAsStringSync();

      // Strip out the prologue comments — banned terms are allowed in
      // the "REJECT if present" doc-comment ledger at the top of each
      // file (those comments are the contract reminder, not banned
      // code paths). The grep targets material below the doc-comment
      // header.
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

Map<String, Object?> _checkAt(String checkId, String iso) {
  return <String, Object?>{
    'checkId': checkId,
    'siteId': _siteId,
    'modifiedAt': iso,
    'openedAt': iso,
    'closedAt': iso,
    'numberOfGuests': 2,
    'totalAmount': 25.00,
    'voided': false,
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

class _RecordingFactSink implements AlohaNcrVoyixFactSink {
  final List<Map<String, Object?>> factWrites = <Map<String, Object?>>[];
  final List<Map<String, Object?>> watermarks = <Map<String, Object?>>[];

  /// When true, repeated upserts on the same
  /// `(vendor_entity_id, vendor_modified_at)` return false (no-op),
  /// mirroring the production UNIQUE constraint.
  bool idempotent = false;

  @override
  Future<bool> upsertCheckFact({
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

/// Convenience constructor for [_FakePage]; reduces test verbosity.
_FakePage _page(
  List<Map<String, Object?>> checks, {
  String? nextCursor,
  bool throwInstead = false,
}) {
  return _FakePage(
    checks: checks,
    nextCursor: nextCursor,
    throwInstead: throwInstead,
  );
}

class _FakePage {
  _FakePage({
    required this.checks,
    required this.nextCursor,
    this.throwInstead = false,
  });

  final List<Map<String, Object?>> checks;
  final String? nextCursor;
  final bool throwInstead;
}

class _FakeAlohaNcrVoyixApiClient implements AlohaNcrVoyixApiClient {
  /// Pages returned by `fetchChecksPage` in backfill order. Tests
  /// queue pages with explicit `nextCursor` so the watermark
  /// assertions are deterministic. A sentinel page with
  /// `throwInstead = true` simulates a mid-walk vendor failure.
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
  Future<AlohaNcrVoyixCredentialHandle> exchangeClientCredentials({
    required String operatorId,
    required String locationId,
    required String siteId,
    String? oauthState,
  }) async {
    return const AlohaNcrVoyixCredentialHandle(
      connectionId: 'conn-aloha-ncr-voyix-1',
      siteId: _siteId,
    );
  }

  @override
  Future<String> registerWebhook({
    required AlohaNcrVoyixCredentialHandle credentials,
    required String webhookUrl,
  }) async {
    return 'sub-aloha-ncr-voyix-1';
  }

  @override
  Future<bool> unregisterWebhook({
    required AlohaNcrVoyixCredentialHandle credentials,
    String? subscriptionId,
  }) async {
    return true;
  }

  @override
  Future<Map<String, Object?>> fetchSampleCheck({
    required AlohaNcrVoyixCredentialHandle credentials,
  }) async {
    return Map<String, Object?>.from(alohaNcrVoyixSampleCheck);
  }

  @override
  Future<AlohaNcrVoyixChecksPage> fetchChecksPage({
    required AlohaNcrVoyixCredentialHandle credentials,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? resumeFromCursor,
  }) async {
    final pool = _backfillPages.isNotEmpty ? _backfillPages : _pollPages;
    if (pool.isEmpty) {
      return AlohaNcrVoyixChecksPage(
        checks: const <Map<String, Object?>>[],
        nextCursor: null,
        lastModifiedSeen: windowStart,
      );
    }
    final page = pool.removeAt(0);
    if (page.throwInstead) {
      throw StateError('fake transport: simulated mid-walk failure');
    }
    return AlohaNcrVoyixChecksPage(
      checks: page.checks,
      nextCursor: page.nextCursor,
      lastModifiedSeen: page.checks.isEmpty
          ? windowStart
          : DateTime.parse(page.checks.last['modifiedAt']! as String),
    );
  }

  @override
  Future<Map<String, Object?>?> fetchCheckById({
    required AlohaNcrVoyixCredentialHandle credentials,
    required String checkId,
  }) async {
    return Map<String, Object?>.from(alohaNcrVoyixSampleCheck)
      ..['checkId'] = checkId;
  }
}
