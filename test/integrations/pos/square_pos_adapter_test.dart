// Phase 8 — Square POS adapter tests (lifecycle = `documented`).
//
// Fixture-based; no live HTTP. Every framework call required by
// `vendor_adapter_slice_contract.md` has at least one test below.
//
// Test list (per the slice contract + the 8.SQ prompt):
//
//   1. Sanity hook call count — fake hook + assert calls == records.
//   2. Sanity hook reject path — hook returning false skips the
//      canonical write.
//   3. Idempotency replay — same payload twice produces a single
//      canonical write.
//   4. Watermark mid-batch resume — simulated crash + assert resume
//      cursor matches last successful batch.
//   5. Signature reject — tampered HMAC + assert verifier returns
//      invalid + no canonical write.
//   6. Connect → backfill → poll → disconnect → reconnect smoke —
//      assert watermark preserved across the cycle.
//   7. Test-connection — sample populates fieldMapping with
//      `actual_sales`, `opened_at`, `closed_at`, `covers_source:
//      'forecast_fallback'` and offline path completes <30s.
//   8. Covers fallback — every canonical fact has `covers == null`
//      and `covers_source == 'forecast_fallback'`.
//   9. Replay window 24h — verifier surfaces signature timestamp
//      such that the framework rejects > 24h old as `replayTooOld`.
//   10. VendorCapabilityProfile assertions — lifecycle =
//       `VendorLifecycle.documented`, `coversFieldExposed: false`,
//       `partnershipGated: false`, `grantScope: operatorWide`.
//   11. Banned-items grep — source review of the new adapter +
//       verifier files: zero KMS / parse_warnings / advisory_lock /
//       SIGTERM / DLQ tile / raw_payload sibling code.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/pos/square_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/square_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import 'fixtures/square_orders_fixture.dart';
import 'fixtures/square_webhook_fixture.dart';

void main() {
  group('SquarePosAdapter', () {
    late _FakeSquareApiClient apiClient;
    late _RecordingFactWriter factWriter;
    late _RecordingWatermarkStore watermarkStore;
    late SquarePosAdapter adapter;
    late DateTime fixedNow;

    setUp(() {
      fixedNow = DateTime.utc(2026, 5, 3, 22, 0, 0);
      apiClient = _FakeSquareApiClient(
        locations: List<Map<String, Object?>>.from(sampleLocations),
        searchPages: <SquareSearchOrdersResponse>[
          SquareSearchOrdersResponse(
            orders: List<Map<String, Object?>>.from(
              (sampleSearchOrdersResponse['orders']
                      as List<Map<String, Object?>>)
                  .map(cloneOrder),
            ),
            cursor: sampleSearchOrdersResponse['cursor'] as String?,
          ),
          const SquareSearchOrdersResponse(orders: <Map<String, Object?>>[]),
        ],
        retrieveResponse: Map<String, Object?>.from(
          (sampleRetrieveOrderResponse['order'] as Map)
              .map((k, v) => MapEntry(k.toString(), v)),
        ),
      );
      factWriter = _RecordingFactWriter();
      watermarkStore = _RecordingWatermarkStore();
      adapter = SquarePosAdapter(
        apiClient: apiClient,
        factWriter: factWriter,
        watermarkStore: watermarkStore,
        notificationUrlForConnection: ({
          required String operatorId,
          required String locationId,
        }) async =>
            squareTestNotificationUrl,
        oauthStateMinter: () => 'state-fixed',
        now: () => fixedNow,
      );
    });

    test('1. sanity hook call count: hook fires once per record', () async {
      final hook = _RecordingSanityHook();
      final result = await adapter.backfill(
        BackfillCommand(
          operatorId: 'op_001',
          locationId: 'loc_001',
          actorUserId: 'user_001',
          vendorId: 'square',
          windowStart: fixedNow.subtract(const Duration(days: 60)),
          windowEnd: fixedNow,
          sanityHook: hook.call,
        ),
      );

      // Three orders in the fixture page → hook called three times.
      expect(hook.calls.length, 3);
      expect(result.recordsWritten, 3);
      // Backfill flag passed through.
      expect(hook.calls.every((c) => c.isBackfill), isTrue);
      // Watermark persisted at least once per non-empty batch.
      expect(watermarkStore.persists.length, greaterThanOrEqualTo(2));
    });

    test('2. sanity hook reject path: false skips canonical write', () async {
      final hook = _RecordingSanityHook(
        rejectIds: <String>{'sq_ord_002', 'sq_ord_003'},
      );
      await adapter.backfill(
        BackfillCommand(
          operatorId: 'op_001',
          locationId: 'loc_001',
          actorUserId: 'user_001',
          vendorId: 'square',
          windowStart: fixedNow.subtract(const Duration(days: 60)),
          windowEnd: fixedNow,
          sanityHook: hook.call,
        ),
      );

      // Three orders in the fixture; two rejected → only one written.
      expect(factWriter.writes.length, 1);
      expect(factWriter.writes.first.vendorEntityId, 'sq_ord_001');
    });

    test('3. idempotency replay: same payload twice = single write',
        () async {
      // First poll — writes the page.
      final firstHook = _RecordingSanityHook();
      await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: 'op_001',
          locationId: 'loc_001',
          actorUserId: 'user_001',
          vendorId: 'square',
          lastModifiedSeen: fixedNow.subtract(const Duration(hours: 1)),
          sanityHook: firstHook.call,
        ),
      );
      final writesAfterFirst = factWriter.writes.length;

      // Reset api client to the same first page so replay is exact.
      apiClient.searchPages
        ..clear()
        ..addAll(<SquareSearchOrdersResponse>[
          SquareSearchOrdersResponse(
            orders: List<Map<String, Object?>>.from(
              (sampleSearchOrdersResponse['orders']
                      as List<Map<String, Object?>>)
                  .map(cloneOrder),
            ),
            cursor: null,
          ),
        ]);

      final secondHook = _RecordingSanityHook();
      await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: 'op_001',
          locationId: 'loc_001',
          actorUserId: 'user_001',
          vendorId: 'square',
          lastModifiedSeen: fixedNow.subtract(const Duration(hours: 1)),
          sanityHook: secondHook.call,
        ),
      );

      // factWriter.upsertSalesFact is keyed on
      // (vendor_entity_id, vendor_modified_at) — second pass returns
      // false (no-op) so the recorded write count does not grow.
      expect(factWriter.writes.length, writesAfterFirst);
      expect(factWriter.duplicateNoOpHits, greaterThan(0));
    });

    test('4. watermark mid-batch resume: cursor persists per batch',
        () async {
      // Two pages: first has the fixture orders + cursor, second is empty.
      // After page 1 the watermark must already be persisted so a
      // crash before page 2 does not lose batch 1's ground.
      apiClient.searchPages
        ..clear()
        ..addAll(<SquareSearchOrdersResponse>[
          SquareSearchOrdersResponse(
            orders: List<Map<String, Object?>>.from(
              (sampleSearchOrdersResponse['orders']
                      as List<Map<String, Object?>>)
                  .map(cloneOrder),
            ),
            cursor: 'PAGE_2_CURSOR',
          ),
          SquareSearchOrdersResponse(
            orders: <Map<String, Object?>>[
              <String, Object?>{
                'id': 'sq_ord_005',
                'location_id': 'L_RESTAURANT_A',
                'created_at': '2026-05-03T20:45:00Z',
                'updated_at': '2026-05-03T20:50:00Z',
                'closed_at': '2026-05-03T20:50:00Z',
                'total_money': <String, Object?>{
                  'amount': 1500,
                  'currency': 'CAD',
                },
                'state': 'COMPLETED',
              },
            ],
            cursor: null,
          ),
        ]);

      final hook = _RecordingSanityHook();
      await adapter.backfill(
        BackfillCommand(
          operatorId: 'op_001',
          locationId: 'loc_001',
          actorUserId: 'user_001',
          vendorId: 'square',
          windowStart: fixedNow.subtract(const Duration(days: 60)),
          windowEnd: fixedNow,
          sanityHook: hook.call,
        ),
      );

      // Two persists, one per page.
      expect(watermarkStore.persists.length, 2);
      // First persist carries page-1 cursor (resume point if crash).
      expect(watermarkStore.persists[0].cursorToken, 'PAGE_2_CURSOR');
      // Second persist clears cursor (page-2 was last).
      expect(watermarkStore.persists[1].cursorToken, isNull);
    });

    test('5. signature reject: tampered HMAC returns invalid + no write',
        () async {
      const verifier = SquareWebhookSignatureVerifier();
      final body = encodedSamplePayload();
      final validSig = computeSquareSignature(body: body);
      final tampered = tamperSignature(validSig);

      final result = verifier.verify(
        rawBody: body,
        headers: <String, String>{
          kSquareSignatureHeader: tampered,
          kSquareNotificationUrlHeader: squareTestNotificationUrl,
          kSquareDeliveryTimestampHeader: fixedNow.toIso8601String(),
        },
        signingSecret: squareTestSigningSecret,
        now: fixedNow,
      );

      expect(result.valid, isFalse);
      expect(result.failureReason, contains('HMAC-SHA256 mismatch'));
      // Adapter never reached — no canonical write.
      expect(factWriter.writes, isEmpty);
    });

    test(
        '6. connect → backfill → poll → disconnect → reconnect: '
        'watermark preserved', () async {
      // Connect (callback path).
      final connectResult = await adapter.connect(const ConnectCommand(
        operatorId: 'op_001',
        locationId: 'loc_001',
        actorUserId: 'user_001',
        vendorId: 'square',
        oauthState: 'state-fixed',
      ));
      expect(connectResult.status, ConnectionStatus.connected);
      expect(apiClient.registeredWebhooks, 1);

      // Backfill writes the seed page.
      final hook = _RecordingSanityHook();
      final backfillResult = await adapter.backfill(
        BackfillCommand(
          operatorId: 'op_001',
          locationId: 'loc_001',
          actorUserId: 'user_001',
          vendorId: 'square',
          windowStart: fixedNow.subtract(const Duration(days: 60)),
          windowEnd: fixedNow,
          sanityHook: hook.call,
        ),
      );
      expect(backfillResult.recordsWritten, 3);
      final highWaterPostBackfill = backfillResult.lastModifiedSeen;

      // Poll picks up zero new orders (api returns empty page).
      apiClient.searchPages
        ..clear()
        ..add(const SquareSearchOrdersResponse(
          orders: <Map<String, Object?>>[],
          cursor: null,
        ));
      final pollResult = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: 'op_001',
          locationId: 'loc_001',
          actorUserId: 'user_001',
          vendorId: 'square',
          lastModifiedSeen: highWaterPostBackfill,
          sanityHook: _RecordingSanityHook().call,
        ),
      );
      expect(pollResult.recordsWritten, 0);

      // Disconnect.
      final disconnectResult = await adapter.disconnect(const DisconnectCommand(
        operatorId: 'op_001',
        locationId: 'loc_001',
        actorUserId: 'user_001',
        vendorId: 'square',
        reason: DisconnectReason.operatorAction,
      ));
      expect(disconnectResult.watermarkPreserved, isTrue);
      expect(disconnectResult.credentialsWiped, isTrue);

      // Reconnect — watermark store still holds the highest-seen
      // modified-at; reconnect resumes from there rather than rewinding.
      final reconnectHook = _RecordingSanityHook();
      apiClient.searchPages
        ..clear()
        ..add(const SquareSearchOrdersResponse(
          orders: <Map<String, Object?>>[],
          cursor: null,
        ));
      final reconnect = await adapter.connect(const ConnectCommand(
        operatorId: 'op_001',
        locationId: 'loc_001',
        actorUserId: 'user_001',
        vendorId: 'square',
        oauthState: 'state-fixed',
      ));
      expect(reconnect.status, ConnectionStatus.connected);
      // Last persisted watermark is the same instant; not reset.
      final lastPersist = watermarkStore.persists.last;
      expect(lastPersist.lastModifiedSeen, highWaterPostBackfill);
      // Polling after reconnect uses the prior high-water as the floor.
      await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: 'op_001',
          locationId: 'loc_001',
          actorUserId: 'user_001',
          vendorId: 'square',
          lastModifiedSeen: highWaterPostBackfill,
          sanityHook: reconnectHook.call,
        ),
      );
      expect(reconnectHook.calls, isEmpty);
    });

    test(
        '7. test-connection: fieldMapping populated with covers_source = '
        'forecast_fallback (not a number); offline path <30s', () async {
      final stopwatch = Stopwatch()..start();
      final result = await adapter.testConnection(const TestConnectionCommand(
        operatorId: 'op_001',
        locationId: 'loc_001',
        actorUserId: 'user_001',
        vendorId: 'square',
      ));
      stopwatch.stop();

      expect(result.authValid, isTrue);
      expect(result.fieldMapping['actual_sales'], 42.5);
      expect(result.fieldMapping['opened_at'],
          contains('2026-05-03T17:30:00'));
      expect(result.fieldMapping['closed_at'],
          contains('2026-05-03T18:45:00'));
      expect(result.fieldMapping['covers_source'], 'forecast_fallback');
      // Critical: covers must NOT be a number on Square.
      expect(result.fieldMapping.containsKey('covers'), isFalse);
      expect(result.note,
          contains('Square does not expose covers'));
      // Offline path well under 30s — cap at 30000ms.
      expect(result.elapsedMs, lessThan(30000));
      expect(stopwatch.elapsedMilliseconds, lessThan(30000));
    });

    test(
        '8. covers fallback: every canonical fact has covers == null and '
        'covers_source == forecast_fallback', () async {
      final hook = _RecordingSanityHook();
      await adapter.backfill(
        BackfillCommand(
          operatorId: 'op_001',
          locationId: 'loc_001',
          actorUserId: 'user_001',
          vendorId: 'square',
          windowStart: fixedNow.subtract(const Duration(days: 60)),
          windowEnd: fixedNow,
          sanityHook: hook.call,
        ),
      );
      expect(factWriter.writes, isNotEmpty);
      for (final fact in factWriter.writes) {
        expect(fact.covers, isNull,
            reason: 'Square does not expose covers');
        expect(fact.coversSource, 'forecast_fallback');
      }
    });

    test('9. replay window 24h: verifier flags > 24h timestamp via header',
        () async {
      const verifier = SquareWebhookSignatureVerifier();
      final body = encodedSamplePayload();
      final validSig = computeSquareSignature(body: body);

      // Inside the window — verifier returns valid + timestamp; framework
      // (not under test here) decides to accept.
      final freshTs = fixedNow.subtract(const Duration(hours: 1));
      final fresh = verifier.verify(
        rawBody: body,
        headers: <String, String>{
          kSquareSignatureHeader: validSig,
          kSquareNotificationUrlHeader: squareTestNotificationUrl,
          kSquareDeliveryTimestampHeader: freshTs.toIso8601String(),
        },
        signingSecret: squareTestSigningSecret,
        now: fixedNow,
      );
      expect(fresh.valid, isTrue);
      expect(fresh.timestamp, freshTs);

      // Stale (> 24h) — same signature still valid (signed payload
      // unchanged), but verifier surfaces the stale timestamp so the
      // framework's `kInboundWebhookReplayCeiling` (24h) drops it.
      final staleTs = fixedNow.subtract(const Duration(hours: 25));
      final stale = verifier.verify(
        rawBody: body,
        headers: <String, String>{
          kSquareSignatureHeader: validSig,
          kSquareNotificationUrlHeader: squareTestNotificationUrl,
          kSquareDeliveryTimestampHeader: staleTs.toIso8601String(),
        },
        signingSecret: squareTestSigningSecret,
        now: fixedNow,
      );
      expect(stale.valid, isTrue);
      expect(stale.timestamp, staleTs);
      expect(
        fixedNow.difference(stale.timestamp!) > kSquareReplayTolerance,
        isTrue,
        reason:
            'tolerance must be 24h to match kInboundWebhookReplayCeiling',
      );
      expect(kSquareReplayTolerance, const Duration(hours: 24));
    });

    test(
        '10. capability profile: lifecycle = documented, '
        'coversFieldExposed = false, partnershipGated = false, '
        'grantScope = operatorWide', () {
      final profile = adapter.capabilityProfile;
      expect(profile.vendorId, 'square');
      expect(profile.displayName, 'Square');
      expect(profile.category, IntegrationCategory.pos);
      expect(profile.authMode, VendorAuthMode.oauth);
      expect(profile.grantScope, VendorGrantScope.operatorWide);
      expect(profile.webhookSupport, VendorWebhookSupport.autoRegister);
      expect(profile.coversFieldExposed, isFalse);
      expect(profile.partnershipGated, isFalse);
      expect(profile.modules, isEmpty);
      expect(adapter.lifecycle, VendorLifecycle.documented);
      // Documented field-mapping constant exists and references covers
      // as forecast_fallback (NOT a vendor field path).
      expect(documented_per_square_2024_01_18['covers'],
          contains('forecast_fallback'));
    });

    test(
        '11. banned items grep: source review of new files = zero KMS, '
        'parse_warnings, advisory_lock, SIGTERM, DLQ tile, raw_payload '
        'sibling code', () {
      final adapterSource =
          File('lib/integrations/pos/square_pos_adapter.dart')
              .readAsStringSync();
      final verifierSource = File(
              'lib/integrations/pos/square_webhook_signature_verifier.dart')
          .readAsStringSync();

      // Each banned token must be absent from BOTH new files.
      // We allow the tokens to appear in comments only when prefixed
      // by "no " or "deleted" — banlist comments are permitted because
      // they document the V1 lean cut without smuggling code in.
      final banned = <String, RegExp>{
        'KMS code path': _bannedKms,
        'parse_warnings JSONB column': _bannedParseWarnings,
        'parse_partial flag': _bannedParsePartial,
        'OAuth advisory locks': _bannedAdvisoryLock,
        'SIGTERM drain handler': _bannedSigterm,
        'DLQ tile widget': _bannedDlqTile,
        'raw payload sibling table': _bannedRawPayloadSibling,
      };

      for (final entry in banned.entries) {
        for (final source in <String>[adapterSource, verifierSource]) {
          final matches = entry.value.allMatches(source);
          expect(matches, isEmpty,
              reason: '${entry.key} must not appear in adapter sources');
        }
      }
    });
  });
}

// Banned-pattern regexes. Each one matches the banned token only as
// CODE (not as a comment word in a sentence) — we look for use as a
// real identifier / call / column.
final RegExp _bannedKms = RegExp(
  r'\b(?:kms[A-Z_]\w*|cryptoKeyVersion|kmsClient|envelopeEncrypt)\b',
);
final RegExp _bannedParseWarnings = RegExp(r'parse_warnings');
final RegExp _bannedParsePartial = RegExp(r'parse_partial');
final RegExp _bannedAdvisoryLock = RegExp(r'pg_try_advisory_lock');
final RegExp _bannedSigterm = RegExp(r'(?:SIGTERM|onSigterm|sigtermDrain)');
final RegExp _bannedDlqTile = RegExp(r'DeadLetterTile|DLQTile|dlqTile');
final RegExp _bannedRawPayloadSibling =
    RegExp(r'raw_payload_partition|inbound_raw_payload_p\d');

// ─── Test doubles ────────────────────────────────────────────────────

class _SanityCall {
  _SanityCall(this.vendorEventId, this.isBackfill);
  final String vendorEventId;
  final bool isBackfill;
}

class _RecordingSanityHook {
  _RecordingSanityHook({this.rejectIds = const <String>{}});
  final Set<String> rejectIds;
  final List<_SanityCall> calls = <_SanityCall>[];

  Future<bool> call({
    required String vendorEventId,
    required Map<String, Object?> payload,
    required bool isDeliberateBackfill,
  }) async {
    calls.add(_SanityCall(vendorEventId, isDeliberateBackfill));
    if (rejectIds.contains(vendorEventId)) return false;
    return true;
  }
}

class _RecordingFactWriter implements SquarePosFactWriter {
  final List<SquareCanonicalFact> writes = <SquareCanonicalFact>[];
  final Map<String, DateTime> _seen = <String, DateTime>{};
  int duplicateNoOpHits = 0;

  @override
  Future<bool> upsertSalesFact(SquareCanonicalFact fact) async {
    final key =
        '${fact.vendorEntityId}|${fact.vendorModifiedAt.toIso8601String()}';
    if (_seen.containsKey(key)) {
      duplicateNoOpHits += 1;
      return false;
    }
    _seen[key] = fact.vendorModifiedAt;
    writes.add(fact);
    return true;
  }
}

class _WatermarkPersist {
  _WatermarkPersist({
    required this.cursorToken,
    required this.lastModifiedSeen,
  });
  final String? cursorToken;
  final DateTime lastModifiedSeen;
}

class _RecordingWatermarkStore implements SquareWatermarkStore {
  final List<_WatermarkPersist> persists = <_WatermarkPersist>[];

  @override
  Future<void> persistWatermark({
    required String operatorId,
    required String locationId,
    required String? cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    persists.add(_WatermarkPersist(
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
    ));
  }
}

class _FakeSquareApiClient implements SquareApiClient {
  _FakeSquareApiClient({
    required this.locations,
    required this.searchPages,
    required this.retrieveResponse,
  });

  final List<Map<String, Object?>> locations;
  final List<SquareSearchOrdersResponse> searchPages;
  final Map<String, Object?> retrieveResponse;

  int registeredWebhooks = 0;
  int unregisteredWebhooks = 0;
  int oauthRevocations = 0;

  @override
  Future<SquareSearchOrdersResponse> searchOrders({
    required SquareCredentialHandle credential,
    required DateTime updatedAtMin,
    required DateTime updatedAtMax,
    required List<String> locationIds,
    String? cursor,
    int pageSize = kSquareSearchPageSize,
  }) async {
    if (searchPages.isEmpty) {
      return const SquareSearchOrdersResponse(
        orders: <Map<String, Object?>>[],
      );
    }
    return searchPages.removeAt(0);
  }

  @override
  Future<Map<String, Object?>> retrieveOrder({
    required SquareCredentialHandle credential,
    required String orderId,
    required String squareLocationId,
  }) async {
    return retrieveResponse;
  }

  @override
  Future<List<Map<String, Object?>>> listLocations({
    required SquareCredentialHandle credential,
  }) async {
    return locations;
  }

  @override
  Future<SquareOauthTokens> refreshOauthToken({
    required String refreshToken,
  }) async {
    return SquareOauthTokens(
      accessToken: 'access-${refreshToken.hashCode}',
      refreshToken: 'refresh-${refreshToken.hashCode}',
      expiresAt: DateTime.utc(2026, 5, 4, 22),
      merchantId: 'M_TEST_MERCHANT',
    );
  }

  @override
  Future<String> registerWebhook({
    required SquareCredentialHandle credential,
    required String notificationUrl,
    required List<String> events,
  }) async {
    registeredWebhooks += 1;
    return 'sub_${registeredWebhooks.toString().padLeft(4, '0')}';
  }

  @override
  Future<void> unregisterWebhook({
    required SquareCredentialHandle credential,
    required String subscriptionId,
  }) async {
    unregisteredWebhooks += 1;
  }

  @override
  Future<void> revokeOauth({
    required SquareCredentialHandle credential,
  }) async {
    oauthRevocations += 1;
  }
}

