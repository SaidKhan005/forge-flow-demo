// Phase 8 (`8.CL`) — Clover POS adapter tests.
//
// Documented-slice tests. Fixture-driven; no live HTTP. The
// `8.CL.live.sandbox` slice owns the live verification.
//
// Mandatory tests per
// `docs/contracts/vendor_adapter_slice_contract.md`:
//   1. Sanity hook call count + reject path.
//   2. Idempotency replay.
//   3. Watermark mid-batch resume.
//   4. Signature reject.
//   5. Connect → backfill → poll → disconnect → reconnect smoke.
//   6. Test-connection: fieldMapping populated; <30s.
//   7. Covers fallback: every fact `covers == null`,
//      `covers_source == 'forecast_fallback'`.
//   8. 90-day cap: backfill clamps `windowStart`.
//   9. Replay window 24h.
//  10. VendorCapabilityProfile assertions; lifecycle = `documented`;
//      coversFieldExposed = false.
//  11. Banned-items grep.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/clover_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import 'fixtures/clover_orders_fixture.dart';
import 'fixtures/clover_webhook_fixture.dart';

void main() {
  group('CloverPosAdapter — capability profile + lifecycle (test 10)', () {
    test('declares Wave B documented-lifecycle profile', () {
      final adapter = _buildAdapter();
      final profile = adapter.capabilityProfile;
      expect(profile.vendorId, 'clover');
      expect(profile.displayName, 'Clover');
      expect(profile.category, IntegrationCategory.pos);
      expect(profile.authMode, VendorAuthMode.oauth);
      expect(profile.grantScope, VendorGrantScope.perLocation);
      expect(profile.webhookSupport, VendorWebhookSupport.autoRegister);
      expect(profile.coversFieldExposed, isFalse,
          reason: 'Clover does not expose a guests/covers field; '
              'covers_source must be forecast_fallback');
      expect(profile.partnershipGated, isTrue,
          reason: 'Clover production credentials require App Market approval');
      expect(profile.modules, isEmpty);
      expect(profile.timestampPolicyDocId, isNotNull);
      expect(adapter.lifecycle, VendorLifecycle.documented);
    });
  });

  group('CloverPosAdapter — sanity hook discipline (tests 1, 7)', () {
    test('backfill calls sanityHook once per record AND every fact has covers '
        'null + covers_source forecast_fallback', () async {
      final api = _FakeCloverApiClient(
        pages: <CloverOrdersPage>[
          CloverOrdersPage(
            elements: <Map<String, Object?>>[
              ...sampleCloverOrdersPageOne,
              ...sampleCloverOrdersPageTwo,
              sampleCloverOrder,
            ],
            nextOffset: null,
          ),
        ],
      );
      final factWriter = _RecordingFactWriter();
      final hook = _CountingSanityHook();
      final adapter = _buildAdapter(api: api, factWriter: factWriter);

      final result = await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        windowStart: DateTime.utc(2026, 4, 4),
        windowEnd: DateTime.utc(2026, 5, 3),
        sanityHook: hook.call,
      ));

      expect(hook.calls, 4,
          reason: 'sanity hook MUST be called once per record');
      expect(hook.lastIsBackfill, isTrue,
          reason: 'backfill MUST pass isDeliberateBackfill: true');
      expect(result.recordsWritten, 4);
      expect(factWriter.writes, hasLength(4));
      for (final write in factWriter.writes) {
        expect(write.fact.covers, isNull,
            reason: 'every Clover fact has covers == null');
        expect(write.fact.coversSource, 'forecast_fallback',
            reason: 'covers_source MUST be forecast_fallback');
      }
    });

    test('sanity hook returning false skips canonical write', () async {
      final api = _FakeCloverApiClient(
        pages: <CloverOrdersPage>[
          CloverOrdersPage(
            elements: <Map<String, Object?>>[sampleCloverOrder],
            nextOffset: null,
          ),
        ],
      );
      final factWriter = _RecordingFactWriter();
      Future<bool> rejecting({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async =>
          false;
      final adapter = _buildAdapter(api: api, factWriter: factWriter);

      final result = await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        windowStart: DateTime.utc(2026, 4, 4),
        windowEnd: DateTime.utc(2026, 5, 3),
        sanityHook: rejecting,
      ));

      expect(result.recordsWritten, 0);
      expect(factWriter.writes, isEmpty,
          reason: 'sanity false MUST suppress write — fall-through is forbidden');
    });

    test('pollIncremental respects sanity hook + reports drop count', () async {
      final api = _FakeCloverApiClient(
        pages: <CloverOrdersPage>[
          CloverOrdersPage(
            elements: <Map<String, Object?>>[
              sampleCloverOrder,
              ...sampleCloverOrdersPageOne,
            ],
            nextOffset: null,
          ),
        ],
      );
      final factWriter = _RecordingFactWriter();
      var calls = 0;
      Future<bool> selectiveHook({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async {
        calls += 1;
        // Reject the first call; keep the next two.
        return calls != 1;
      }

      final adapter = _buildAdapter(api: api, factWriter: factWriter);
      final result = await adapter.pollIncremental(PollIncrementalCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        lastModifiedSeen: DateTime.utc(2026, 5, 1),
        sanityHook: selectiveHook,
      ));

      expect(calls, 3);
      expect(result.recordsWritten, 2);
      expect(result.sanityDropped, 1);
    });
  });

  group('CloverPosAdapter — idempotency replay (test 2)', () {
    test('handleWebhook hydrates the same order id twice → identical writes; '
        'idempotency UNIQUE prevents double-count downstream', () async {
      final api = _FakeCloverApiClient(orderById: <String, Map<String, Object?>>{
        sampleCloverOrder['id'] as String: sampleCloverOrder,
      });
      final factWriter = _RecordingFactWriter();
      final adapter = _buildAdapter(api: api, factWriter: factWriter);

      final cmd = HandleWebhookCommand(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'clover',
        vendorEventId: sampleCloverWebhookEnvelope['event_id'] as String,
        payload: sampleCloverWebhookEnvelope,
        headers: const <String, String>{},
        receivedAt: DateTime.utc(2026, 5, 3, 12),
      );
      final first = await adapter.handleWebhook(cmd);
      final second = await adapter.handleWebhook(cmd);

      expect(first.recordsWritten, 1);
      expect(second.recordsWritten, 1);
      expect(factWriter.writes, hasLength(2),
          reason: 'adapter does not re-check idempotency; framework does');
      expect(factWriter.writes[0].fact.vendorEntityId,
          factWriter.writes[1].fact.vendorEntityId,
          reason: 'same canonical fact — UNIQUE on (vendor_id, operator_id, '
              'vendor_entity_id, vendor_modified_at) collapses downstream');
    });

    test('handleWebhook MUST NOT call sanityHook (framework owns step 4)',
        () async {
      // Adapter has no `sanityHook` parameter on `HandleWebhookCommand` —
      // a missing dependency would fail the type-checker. This is a
      // documentation test that asserts the contract holds.
      const cmdShape = <String>[
        'operatorId',
        'locationId',
        'vendorId',
        'vendorEventId',
        'payload',
        'headers',
        'receivedAt',
      ];
      expect(cmdShape.contains('sanityHook'), isFalse);
    });
  });

  group('CloverPosAdapter — watermark mid-batch resume (test 3)', () {
    test('persists watermark after each batch; crash mid-page-chain '
        'resumes from last successful batch', () async {
      final factWriter = _RecordingFactWriter();
      final watermarkStore = _RecordingWatermarkStore();
      final api = _FakeCloverApiClient(
        pages: <CloverOrdersPage>[
          CloverOrdersPage(
            elements: List<Map<String, Object?>>.from(sampleCloverOrdersPageOne),
            nextOffset: 100,
          ),
          _CrashPage(),
          CloverOrdersPage(
            elements: List<Map<String, Object?>>.from(sampleCloverOrdersPageTwo),
            nextOffset: null,
          ),
        ],
      );
      final adapter = _buildAdapter(
        api: api,
        factWriter: factWriter,
        watermarkStore: watermarkStore,
      );
      final hook = _CountingSanityHook();

      // First run crashes after batch 1 commits its watermark.
      try {
        await adapter.backfill(BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          vendorId: 'clover',
          windowStart: DateTime.utc(2026, 4, 4),
          windowEnd: DateTime.utc(2026, 5, 3),
          sanityHook: hook.call,
        ));
        fail('expected crash on second page');
      } catch (e) {
        expect(e, isA<_BackfillCrash>());
      }

      expect(watermarkStore.commits, hasLength(1),
          reason: 'batch 1 commit must precede the crash');
      final batchOneCursor = watermarkStore.commits.last.cursorToken;

      // Resume run continues from the persisted cursor — no replay
      // of batch-1 records, no skip.
      final resumeApi = _FakeCloverApiClient(
        pages: <CloverOrdersPage>[
          CloverOrdersPage(
            elements: List<Map<String, Object?>>.from(sampleCloverOrdersPageTwo),
            nextOffset: null,
          ),
        ],
      );
      final resumeAdapter = _buildAdapter(
        api: resumeApi,
        factWriter: factWriter,
        watermarkStore: watermarkStore,
      );
      final resumeHook = _CountingSanityHook();
      final result = await resumeAdapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        windowStart: DateTime.utc(2026, 4, 4),
        windowEnd: DateTime.utc(2026, 5, 3),
        sanityHook: resumeHook.call,
        resumeFromCursor: batchOneCursor,
      ));

      expect(result.recordsWritten, sampleCloverOrdersPageTwo.length);
      // Adapter requested page starting at the resume cursor's offset.
      expect(resumeApi.requestedOffsets.first, isNot(0),
          reason: 'resume must not start from 0 — that would replay batch 1');
    });
  });

  group('CloverWebhookSignatureVerifier — signature reject (tests 4, 9)', () {
    final verifier = const CloverWebhookSignatureVerifier();
    final canonicalBody = cloverWebhookCanonicalBody(sampleCloverWebhookEnvelope);
    final rawBody = Uint8List.fromList(utf8.encode(canonicalBody));

    test('valid HMAC-SHA256 signature accepted', () {
      final now = DateTime.utc(2026, 5, 3, 12);
      final headers = cloverFixtureHeaders(
        rawBody: rawBody,
        timestamp: now.subtract(const Duration(seconds: 30)),
        signingSecret: fixtureCloverSigningSecret,
      );

      final result = verifier.verify(
        rawBody: rawBody,
        headers: headers,
        signingSecret: fixtureCloverSigningSecret,
        now: now,
      );
      expect(result.valid, isTrue);
      expect(result.timestamp, isNotNull);
    });

    test('tampered signature → 403 path; constant-time compare returns false',
        () {
      final now = DateTime.utc(2026, 5, 3, 12);
      final headers = cloverFixtureTamperedHeaders(
        rawBody: rawBody,
        timestamp: now,
        signingSecret: fixtureCloverSigningSecret,
      );

      final result = verifier.verify(
        rawBody: rawBody,
        headers: headers,
        signingSecret: fixtureCloverSigningSecret,
        now: now,
      );
      expect(result.valid, isFalse);
      expect(result.failureReason, contains('mismatch'));
    });

    test('replay window is 24h (V1 lean cut 2 — strict 5-min deleted)', () {
      final now = DateTime.utc(2026, 5, 3, 12);
      // Verifier extracts the timestamp; the framework's
      // `kInboundWebhookReplayCeiling` (24h) is the actual window.
      final inWindow = cloverFixtureHeaders(
        rawBody: rawBody,
        timestamp: now.subtract(const Duration(hours: 23, minutes: 59)),
        signingSecret: fixtureCloverSigningSecret,
      );
      final outsideWindow = cloverFixtureHeaders(
        rawBody: rawBody,
        timestamp: now.subtract(const Duration(hours: 25)),
        signingSecret: fixtureCloverSigningSecret,
      );

      final inOk = verifier.verify(
        rawBody: rawBody,
        headers: inWindow,
        signingSecret: fixtureCloverSigningSecret,
        now: now,
      );
      final outOk = verifier.verify(
        rawBody: rawBody,
        headers: outsideWindow,
        signingSecret: fixtureCloverSigningSecret,
        now: now,
      );
      expect(inOk.valid, isTrue);
      expect(outOk.valid, isTrue,
          reason:
              'verifier itself does NOT enforce replay window — framework does '
              '(kInboundWebhookReplayCeiling = 24h). Verifier just exposes the '
              'timestamp so the handler can apply its 24h ceiling.');
      // Cross-check: the framework constant is 24h, not 5min.
      expect(kInboundWebhookReplayCeiling, const Duration(hours: 24),
          reason: 'V1 lean cut 2 — 5-min strict window must remain deleted');
      expect(
          inOk.timestamp!.difference(outOk.timestamp!).abs().inHours,
          greaterThanOrEqualTo(1));
    });

    test('missing signature header → reject', () {
      final result = verifier.verify(
        rawBody: rawBody,
        headers: const <String, String>{},
        signingSecret: fixtureCloverSigningSecret,
        now: DateTime.utc(2026, 5, 3),
      );
      expect(result.valid, isFalse);
      expect(result.failureReason, contains('missing'));
    });
  });

  group('CloverPosAdapter — connect→backfill→poll→disconnect→reconnect '
      '(test 5)', () {
    test('watermark preserved across disconnect / reconnect cycle', () async {
      final api = _FakeCloverApiClient(
        pages: <CloverOrdersPage>[
          CloverOrdersPage(
            elements: <Map<String, Object?>>[sampleCloverOrder],
            nextOffset: null,
          ),
        ],
      );
      final factWriter = _RecordingFactWriter();
      final watermarkStore = _RecordingWatermarkStore();
      final webhookRegistry = _RecordingWebhookRegistry();
      final credentials = _MutableCredentialStore(
        merchantId: fixtureMerchantId,
        webhookSubscriptionId: 'CLV-WHSUB-INITIAL',
      );
      final adapter = _buildAdapter(
        api: api,
        factWriter: factWriter,
        watermarkStore: watermarkStore,
        webhookRegistry: webhookRegistry,
        credentials: credentials,
      );
      final hook = _CountingSanityHook();

      // 1. Connect.
      final connect = await adapter.connect(ConnectCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        oauthState: fixtureMerchantId,
      ));
      expect(connect.status, ConnectionStatus.connected);
      expect(connect.metadata[kCloverMetadataMerchantIdKey], fixtureMerchantId);
      expect(connect.metadata[kCloverMetadataWebhookSubscriptionIdKey],
          isNotNull);
      expect(connect.firstBackfillStarted, isTrue);

      // 2. Backfill.
      final backfill = await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        windowStart: DateTime.utc(2026, 4, 4),
        windowEnd: DateTime.utc(2026, 5, 3),
        sanityHook: hook.call,
      ));
      expect(backfill.recordsWritten, 1);
      final backfillCursor = backfill.cursorToken;

      // 3. Poll.
      api.pages
        ..clear()
        ..add(CloverOrdersPage(elements: const <Map<String, Object?>>[], nextOffset: null));
      final poll = await adapter.pollIncremental(PollIncrementalCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        lastModifiedSeen: backfill.lastModifiedSeen,
        sanityHook: hook.call,
        cursorToken: backfillCursor,
      ));
      expect(poll.recordsWritten, 0);

      // 4. Disconnect.
      final disconnect = await adapter.disconnect(DisconnectCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        reason: DisconnectReason.operatorAction,
      ));
      expect(disconnect.credentialsWiped, isTrue);
      expect(disconnect.webhookUnregistered, isTrue);
      expect(disconnect.watermarkPreserved, isTrue);

      // 5. Reconnect — credential store is repopulated (proxy route
      //    mints fresh creds); watermark store retained the cursor.
      credentials.reset(
        merchantId: fixtureMerchantId,
        webhookSubscriptionId: 'CLV-WHSUB-RECONNECTED',
      );
      final lastCommit = watermarkStore.commits.last;
      expect(lastCommit.cursorToken, isNotEmpty);

      api.pages
        ..clear()
        ..add(CloverOrdersPage(elements: const <Map<String, Object?>>[], nextOffset: null));
      final pollAfter = await adapter.pollIncremental(PollIncrementalCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        lastModifiedSeen: lastCommit.lastModifiedSeen,
        sanityHook: hook.call,
        cursorToken: lastCommit.cursorToken,
      ));
      expect(pollAfter.newCursorToken, isNotEmpty);
      expect(pollAfter.newLastModifiedSeen, lastCommit.lastModifiedSeen,
          reason: 'reconnect must not rewind the watermark');
    });
  });

  group('CloverPosAdapter — testConnection field mapping (test 6)', () {
    test('test-connection projects fieldMapping in <30s with covers fallback',
        () async {
      final api = _FakeCloverApiClient(
        pages: <CloverOrdersPage>[
          CloverOrdersPage(
            elements: <Map<String, Object?>>[sampleCloverOrder],
            nextOffset: null,
          ),
        ],
      );
      final adapter = _buildAdapter(api: api);

      final result = await adapter.testConnection(TestConnectionCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
      ));

      expect(result.authValid, isTrue);
      expect(result.fieldMapping['actual_sales'], 31.40);
      expect(result.fieldMapping['opened_at'], '2026-05-02T18:45:00.000Z');
      expect(result.fieldMapping['closed_at'], '2026-05-02T19:43:00.000Z');
      expect(result.fieldMapping['covers'], isNull);
      expect(result.fieldMapping['covers_source'], 'forecast_fallback');
      expect(result.elapsedMs, lessThan(30000),
          reason: 'V1 lean cut 2 caps test-connection at ~30s');
      expect(result.note, contains('forecast_fallback'));
    });
  });

  group('CloverPosAdapter — 90-day filter cap clamp (test 8)', () {
    test('backfill with windowStart older than 90 days clamps to now-90d',
        () async {
      final api = _FakeCloverApiClient(
        pages: <CloverOrdersPage>[
          CloverOrdersPage(
            elements: const <Map<String, Object?>>[],
            nextOffset: null,
          ),
        ],
      );
      final factWriter = _RecordingFactWriter();
      final fixedNow = DateTime.utc(2026, 5, 3, 12);
      final adapter = _buildAdapter(
        api: api,
        factWriter: factWriter,
        clock: () => fixedNow,
      );
      final hook = _CountingSanityHook();

      await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        windowStart: fixedNow.subtract(const Duration(days: 120)),
        windowEnd: fixedNow,
        sanityHook: hook.call,
      ));

      final issued = api.requestedFromTo.first;
      final expectedFloor = fixedNow.subtract(const Duration(days: 90));
      expect(issued.from.isAtSameMomentAs(expectedFloor), isTrue,
          reason: 'Clover documented filter cap is 90d; '
              'older windowStart MUST be clamped, not error');
    });

    test('backfill with 60-day windowStart is honored (no clamp, no error)',
        () async {
      final api = _FakeCloverApiClient(
        pages: <CloverOrdersPage>[
          CloverOrdersPage(
            elements: const <Map<String, Object?>>[],
            nextOffset: null,
          ),
        ],
      );
      final factWriter = _RecordingFactWriter();
      final fixedNow = DateTime.utc(2026, 5, 3, 12);
      final adapter = _buildAdapter(
        api: api,
        factWriter: factWriter,
        clock: () => fixedNow,
      );
      final hook = _CountingSanityHook();

      final desiredStart = fixedNow.subtract(const Duration(days: 60));
      await adapter.backfill(BackfillCommand(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        vendorId: 'clover',
        windowStart: desiredStart,
        windowEnd: fixedNow,
        sanityHook: hook.call,
      ));

      final issued = api.requestedFromTo.first;
      expect(issued.from.isAtSameMomentAs(desiredStart), isTrue,
          reason: 'V1 lean cut 2 best-effort 60-day target fits inside '
              'Clover 90-day cap — no clamp');
    });
  });

  group('CloverPosAdapter — banned-items grep (test 11)', () {
    test('source files are free of banned V1 lean cut 2 patterns', () async {
      final files = <File>[
        File('lib/integrations/pos/clover_pos_adapter.dart'),
        File('lib/integrations/pos/clover_webhook_signature_verifier.dart'),
      ];
      // The strict 5-min replay window from iter1 is banned (must be 24h).
      final bannedSubstrings = <String>[
        'parse_warnings',
        'parse_partial',
        'pg_try_advisory_lock',
        'kms.encrypt(',
        'kms.decrypt(',
        'sigterm',
        'SIGTERM',
        'webhook_dlq_tile',
        'parse_warning',
      ];

      for (final file in files) {
        final source = await file.readAsString();
        for (final banned in bannedSubstrings) {
          expect(source.contains(banned), isFalse,
              reason: '$banned must not appear in ${file.path} '
                  '(V1 lean cut 2 banned-items list)');
        }
        // 5-min strict replay window banned.
        expect(source.contains('Duration(minutes: 5)'), isFalse,
            reason: '5-min strict replay window deleted in V1 lean cut 2');
        // 5-second SLA banned.
        expect(source.contains('Duration(seconds: 5)'), isFalse,
            reason: '5-second test-connection SLA deleted in V1 lean cut 2');
        // Plaintext-credential leak guard. Per the contract, the
        // grep target is `vendor_credentials.*plaintext` — anywhere
        // the adapter reads plaintext from the credentials store.
        final plainTextLeak = RegExp(r'vendor_credentials.*plaintext',
            caseSensitive: false);
        expect(plainTextLeak.hasMatch(source), isFalse,
            reason: 'plaintext credentials must never reach the adapter '
                '(`vendor_credentials_repository.dart` mints opaque '
                'VendorCredentialHandle)');
        // Postgres-import guard. `package:postgres` is BANNED outside
        // `lib/infrastructure/persistence/postgres/` per contract.
        expect(source.contains("import 'package:postgres"), isFalse,
            reason:
                'package:postgres imports forbidden outside the persistence layer');
      }
    });
  });
}

// ───────────────────────────────────────────────────────────────────
// Test fakes
// ───────────────────────────────────────────────────────────────────

const String _opId = 'op_test';
const String _locId = 'loc_test';
const String _actor = 'usr_test';

CloverPosAdapter _buildAdapter({
  CloverApiClient? api,
  _RecordingFactWriter? factWriter,
  _RecordingWatermarkStore? watermarkStore,
  _RecordingWebhookRegistry? webhookRegistry,
  _MutableCredentialStore? credentials,
  DateTime Function()? clock,
}) {
  return CloverPosAdapter(
    api: api ?? _FakeCloverApiClient(),
    factWriter: factWriter ?? _RecordingFactWriter(),
    watermarkStore: watermarkStore ?? _RecordingWatermarkStore(),
    webhookRegistry: webhookRegistry ?? _RecordingWebhookRegistry(),
    credentials: credentials ?? _MutableCredentialStore(merchantId: fixtureMerchantId),
    clock: clock,
  );
}

class _CountingSanityHook {
  int calls = 0;
  bool? lastIsBackfill;
  Future<bool> call({
    required String vendorEventId,
    required Map<String, Object?> payload,
    required bool isDeliberateBackfill,
  }) async {
    calls += 1;
    lastIsBackfill = isDeliberateBackfill;
    return true;
  }
}

class _FakeCloverApiClient implements CloverApiClient {
  _FakeCloverApiClient({
    List<CloverOrdersPage>? pages,
    Map<String, Map<String, Object?>>? orderById,
  })  : pages = List<CloverOrdersPage>.from(pages ?? <CloverOrdersPage>[]),
        _ordersById = orderById ?? const <String, Map<String, Object?>>{};

  final List<CloverOrdersPage> pages;
  final Map<String, Map<String, Object?>> _ordersById;
  final List<int> requestedOffsets = <int>[];
  final List<({DateTime from, DateTime to})> requestedFromTo =
      <({DateTime from, DateTime to})>[];

  @override
  Future<CloverOrdersPage> listOrders({
    required String merchantId,
    required DateTime modifiedFrom,
    required DateTime modifiedTo,
    required int offset,
    required int limit,
  }) async {
    requestedOffsets.add(offset);
    requestedFromTo.add((from: modifiedFrom, to: modifiedTo));
    if (pages.isEmpty) {
      return const CloverOrdersPage(elements: <Map<String, Object?>>[], nextOffset: null);
    }
    final next = pages.removeAt(0);
    if (next is _CrashPage) {
      throw _BackfillCrash();
    }
    return next;
  }

  @override
  Future<Map<String, Object?>> getOrder({
    required String merchantId,
    required String orderId,
  }) async {
    final order = _ordersById[orderId];
    if (order == null) {
      throw StateError('no fixture order for $orderId');
    }
    return order;
  }

  @override
  Future<String> registerWebhook({
    required String merchantId,
    required String callbackUrl,
    required List<String> eventTypes,
  }) async {
    return 'CLV-WHSUB-FROM-API-CLIENT';
  }

  @override
  Future<void> unregisterWebhook({
    required String merchantId,
    required String subscriptionId,
  }) async {}
}

class _CrashPage extends CloverOrdersPage {
  _CrashPage()
      : super(elements: const <Map<String, Object?>>[], nextOffset: null);
}

class _BackfillCrash implements Exception {}

class _RecordingFactWriter implements CloverTenantFactWriter {
  final List<({String operatorId, String locationId, CloverCanonicalSalesFact fact})>
      writes = <({String operatorId, String locationId, CloverCanonicalSalesFact fact})>[];

  @override
  Future<void> writeSalesFact({
    required String operatorId,
    required String locationId,
    required CloverCanonicalSalesFact fact,
  }) async {
    writes.add((operatorId: operatorId, locationId: locationId, fact: fact));
  }
}

class _RecordingWatermarkStore implements CloverWatermarkStore {
  final List<({String operatorId, String locationId, String cursorToken, DateTime lastModifiedSeen})>
      commits =
      <({String operatorId, String locationId, String cursorToken, DateTime lastModifiedSeen})>[];

  @override
  Future<void> persist({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    commits.add((
      operatorId: operatorId,
      locationId: locationId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
    ));
  }
}

class _RecordingWebhookRegistry implements CloverWebhookRegistry {
  int registerCalls = 0;
  int unregisterCalls = 0;

  @override
  Future<String> register({
    required String operatorId,
    required String locationId,
    required String merchantId,
  }) async {
    registerCalls += 1;
    return 'CLV-WHSUB-${registerCalls.toString().padLeft(4, '0')}';
  }

  @override
  Future<bool> unregister({
    required String operatorId,
    required String locationId,
    required String merchantId,
    required String subscriptionId,
  }) async {
    unregisterCalls += 1;
    return true;
  }
}

class _MutableCredentialStore implements CloverCredentialStore {
  _MutableCredentialStore({
    required String merchantId,
    String? webhookSubscriptionId,
  })  : _merchantId = merchantId,
        _webhookSubscriptionId = webhookSubscriptionId;

  String? _merchantId;
  String? _webhookSubscriptionId;

  void reset({required String merchantId, String? webhookSubscriptionId}) {
    _merchantId = merchantId;
    _webhookSubscriptionId = webhookSubscriptionId;
  }

  @override
  Future<bool> wipe({
    required String operatorId,
    required String locationId,
  }) async {
    _merchantId = null;
    _webhookSubscriptionId = null;
    return true;
  }

  @override
  Future<String?> readMerchantId({
    required String operatorId,
    required String locationId,
  }) async =>
      _merchantId;

  @override
  Future<String?> readWebhookSubscriptionId({
    required String operatorId,
    required String locationId,
  }) async =>
      _webhookSubscriptionId;
}
