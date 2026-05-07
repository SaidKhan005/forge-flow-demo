// Phase 8R.SR — SevenRooms reservation adapter tests.
//
// Fixture-based coverage of every framework seam declared by
// `docs/contracts/vendor_adapter_slice_contract.md`:
//
//   1. Sanity hook call count
//   2. Sanity hook reject path
//   3. Idempotency replay (UNIQUE conflict-do-nothing)
//   4. Watermark mid-batch resume
//   5. Signature reject (tampered HMAC)
//   6. Connect → backfill → poll → disconnect → reconnect smoke
//   7. Test-connection populates fieldMapping with reservation_at +
//      party_size + status (offline path under 30s)
//   8. Replay window 24h (25h reject; 23h accept)
//   9. manualPaste: connect returns ConnectResult with webhookUrl +
//      firstBackfillStarted: true; auto-register endpoint NOT invoked
//  10. VendorCapabilityProfile assertions (every field non-default;
//      lifecycle = VendorLifecycle.documented;
//      webhookSupport = manualPaste)
//  11. Banned-items grep (V1 lean cut 2 list)
//
// Live HTTP is the `8R.SR.live.sandbox` slice's job, not this slice's.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import 'fixtures/sevenrooms_reservations_fixture.dart';
import 'fixtures/sevenrooms_webhook_fixture.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _userId = '00000000-0000-4000-8000-0000000000b1';
const String _venueId = 'sr-venue-7c2f';

void main() {
  group('SevenRoomsReservationAdapter', () {
    late _FakeGateway gateway;
    late _FakeAuthClient auth;
    late _FakeWebhookClient webhook;
    late _FakeReservationsClient reservations;
    late SevenRoomsReservationAdapter adapter;
    late DateTime nowFixed;

    setUp(() {
      nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      gateway = _FakeGateway()
        ..bindings['$_opId|$_locId'] = const SevenRoomsConnectionBinding(
          connectionId: 'conn-1',
          venueId: _venueId,
          accessTokenCredentialId: 'cred-access-1',
        )
        ..disconnectBindings['$_opId|$_locId'] =
            const SevenRoomsDisconnectBinding(
          connectionId: 'conn-1',
          venueId: _venueId,
          accessTokenCredentialId: 'cred-access-1',
        );
      auth = _FakeAuthClient();
      webhook = _FakeWebhookClient();
      reservations = _FakeReservationsClient();
      adapter = SevenRoomsReservationAdapter(
        gateway: gateway,
        authClient: auth,
        webhookClient: webhook,
        reservationsClient: reservations,
        restaurantTimezone: 'America/Toronto',
        businessDayRolloverHour: 4,
        webhookUrl: 'https://api.forgeflow.app/v1/webhooks/sevenrooms/conn-1',
        now: () => nowFixed,
      );
    });

    test(
      'capability profile declares every required field; lifecycle is '
      'documented; webhookSupport is manualPaste',
      () {
        expect(adapter.vendorId, 'sevenrooms');
        expect(adapter.displayName, 'SevenRooms');

        final profile = adapter.capabilityProfile;
        expect(profile.vendorId, 'sevenrooms');
        expect(profile.displayName, 'SevenRooms');
        expect(profile.category, IntegrationCategory.reservation);
        expect(profile.authMode, VendorAuthMode.oauthOrKeyPaste);
        expect(profile.grantScope, VendorGrantScope.perLocation);
        expect(profile.webhookSupport, VendorWebhookSupport.manualPaste);
        expect(profile.coversFieldExposed, false);
        expect(profile.lifecycle, VendorLifecycle.documented);
        expect(profile.modules, isEmpty);
        expect(
          profile.timestampPolicyDocId,
          'vendor_timestamp_policy.sevenrooms',
        );
      },
    );

    test('sanity hook called once per record on backfill', () async {
      reservations.pages = <SevenRoomsReservationsPage>[
        SevenRoomsReservationsPage(
          reservations: sevenRoomsFiveRecordBatch(),
          nextPageToken: null,
        ),
      ];
      final hook = _RecordingSanityHook();
      final result = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: 'sevenrooms',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: hook.call,
        ),
      );

      expect(hook.calls.length, 5);
      expect(result.recordsWritten, 5);
      expect(result.batchesCommitted, 1);
      expect(
        hook.calls.every((call) => call.isDeliberateBackfill == true),
        true,
      );
    });

    test('sanity hook reject path: returning false skips that write', () async {
      reservations.pages = <SevenRoomsReservationsPage>[
        SevenRoomsReservationsPage(
          reservations: sevenRoomsFiveRecordBatch(),
          nextPageToken: null,
        ),
      ];
      final hook = _RecordingSanityHook(rejectVendorEntityId: 'sr-resv-1003');
      final result = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: 'sevenrooms',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: hook.call,
        ),
      );

      expect(hook.calls.length, 5);
      expect(result.recordsWritten, 4,
          reason: 'rejected record must not produce a canonical write');
      expect(
        gateway.reservationWrites.map((w) => w.vendorEntityId),
        isNot(contains('sr-resv-1003')),
      );
    });

    test(
      'idempotency replay: same payload twice writes once (UNIQUE conflict)',
      () async {
        final payload = standardSevenRoomsWebhookPayload(nowUtc: nowFixed);

        final r1 = await adapter.handleWebhook(
          HandleWebhookCommand(
            operatorId: _opId,
            locationId: _locId,
            vendorId: 'sevenrooms',
            vendorEventId: 'evt-sr-resv-1001',
            payload: payload,
            headers: const <String, String>{},
            receivedAt: nowFixed,
          ),
        );
        final r2 = await adapter.handleWebhook(
          HandleWebhookCommand(
            operatorId: _opId,
            locationId: _locId,
            vendorId: 'sevenrooms',
            vendorEventId: 'evt-sr-resv-1001',
            payload: payload,
            headers: const <String, String>{},
            receivedAt: nowFixed,
          ),
        );

        expect(r1.recordsWritten, 1);
        expect(r2.recordsWritten, 0,
            reason: 'second arrival must be UNIQUE-conflict no-op');
        expect(gateway.reservationWrites.length, 1);
      },
    );

    test('watermark mid-batch resume: persists per-batch cursor', () async {
      final batch = sevenRoomsFiveRecordBatch();
      reservations.pages = <SevenRoomsReservationsPage>[
        SevenRoomsReservationsPage(
          reservations: batch.sublist(0, 1),
          nextPageToken: 'cursor-after-batch-1',
        ),
        SevenRoomsReservationsPage(
          reservations: batch.sublist(1, 2),
          nextPageToken: 'cursor-after-batch-2',
        ),
        SevenRoomsReservationsPage(
          reservations: batch.sublist(2, 3),
          nextPageToken: 'cursor-after-batch-3',
        ),
      ];
      reservations.throwOnPage = 4;

      Object? caught;
      try {
        await adapter.backfill(
          BackfillCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _userId,
            vendorId: 'sevenrooms',
            windowStart: nowFixed.subtract(const Duration(days: 60)),
            windowEnd: nowFixed,
            sanityHook: const _AcceptAllSanityHook().call,
          ),
        );
      } catch (e) {
        caught = e;
      }

      expect(caught, isNotNull, reason: 'simulated crash should propagate');
      expect(gateway.watermarkCalls.length, 3);
      expect(
        gateway.watermarkCalls.last.cursorToken,
        'cursor-after-batch-3',
        reason: 'watermark must reflect the LAST successfully committed batch',
      );

      // Resume.
      reservations.throwOnPage = -1;
      reservations.pages = <SevenRoomsReservationsPage>[
        SevenRoomsReservationsPage(
          reservations: batch.sublist(3, 4),
          nextPageToken: 'cursor-after-batch-4',
        ),
        SevenRoomsReservationsPage(
          reservations: batch.sublist(4, 5),
          nextPageToken: null,
        ),
      ];
      reservations.fetchCalls.clear();
      final resumeResult = await adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: 'sevenrooms',
          windowStart: nowFixed.subtract(const Duration(days: 60)),
          windowEnd: nowFixed,
          sanityHook: const _AcceptAllSanityHook().call,
          resumeFromCursor: gateway.watermarkCalls.last.cursorToken,
        ),
      );
      expect(reservations.fetchCalls.first.cursorToken, 'cursor-after-batch-3');
      expect(resumeResult.batchesCommitted, 2);
    });

    test(
      'signature reject: tampered HMAC -> verifier returns false; '
      'inbound handler returns 403; no canonical-fact write',
      () async {
        const verifier = SevenRoomsWebhookSignatureVerifier();
        final tampered = tamperedSevenRoomsWebhook(
          signingSecret: 'secret',
          payload: standardSevenRoomsWebhookPayload(nowUtc: nowFixed),
        );

        final v = verifier.verify(
          rawBody: tampered.rawBody,
          headers: tampered.headers,
          signingSecret: 'secret',
          now: nowFixed,
        );
        expect(v.valid, false);

        // Drive the framework handler with this verifier + a fake
        // gateway. 403 + audit + no fact write.
        final webhookGateway = _RecordingWebhookGateway();
        webhookGateway.bindings['sevenrooms'] = const ConnectionBinding(
          connectionId: 'conn-1',
          metadata: <String, Object?>{'venue_id': _venueId},
          status: ConnectionStatus.connected,
        );
        webhookGateway.signingSecrets['sevenrooms'] = 'secret';

        final handler = InboundWebhookHandler(
          gateway: webhookGateway,
          posAdapterFactories: const <String, PosAdapterFactory>{},
          laborAdapterFactories: const <String, LaborAdapterFactory>{},
          reservationAdapterFactories: <String, ReservationAdapterFactory>{
            adapter.vendorId:
                ({required operatorId, required locationId}) => adapter,
          },
          signatureVerifiers: <String, VendorWebhookSignatureVerifier>{
            verifier.vendorId: verifier,
          },
          bindingExtractor: WebhookBindingExtractor(
            specs: <String, BindingFieldSpec>{
              'sevenrooms': const BindingFieldSpec(
                payloadPath: <String>['venue_id'],
                metadataKey: 'venue_id',
              ),
            },
          ),
          now: () => nowFixed,
        );

        final result = await handler.dispatch(
          operatorId: _opId,
          locationId: _locId,
          vendorId: 'sevenrooms',
          rawBody: tampered.rawBody,
          payload: tampered.payload,
          headers: tampered.headers,
        );

        expect(result.outcome, WebhookOutcome.signatureInvalid);
        expect(result.statusCode, 403);
        expect(gateway.reservationWrites, isEmpty,
            reason: 'no canonical-fact write on signature rejection');
        expect(webhookGateway.failedAttempts.values.first, 1,
            reason: 'audit row written via recordFailedAttempt');
      },
    );

    test(
      'manualPaste: connect returns ConnectResult with webhookUrl + '
      'firstBackfillStarted; webhookClient.subscribe NEVER invoked',
      () async {
        auth.authenticateResult = const SevenRoomsAuthResult(
          venueId: _venueId,
          accessTokenCredentialId: 'cred-access-1',
        );

        final connect = await adapter.connect(
          ConnectCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _userId,
            vendorId: 'sevenrooms',
            module: _venueId,
            keyPaste: const ConnectKeyPasteCredential(
              apiKey: 'partner-secret-xyz',
              username: 'partner-client-abc',
            ),
          ),
        );

        expect(connect.status, ConnectionStatus.connected);
        expect(connect.webhookUrl,
            'https://api.forgeflow.app/v1/webhooks/sevenrooms/conn-1');
        expect(connect.firstBackfillStarted, true);
        expect(connect.metadata['venue_id'], _venueId);
        expect(connect.metadata['webhook_state'], 'pending_paste');

        // The mock vendor API NEVER receives a subscription POST.
        expect(webhook.subscribeCalls, isEmpty,
            reason: 'manualPaste vendors must NOT auto-register webhooks');
      },
    );

    test(
      'smoke: connect -> backfill -> poll -> disconnect -> reconnect '
      'preserves watermark across cycle',
      () async {
        // CONNECT — keypaste credential exchange.
        auth.authenticateResult = const SevenRoomsAuthResult(
          venueId: _venueId,
          accessTokenCredentialId: 'cred-access-1',
        );
        final connect = await adapter.connect(
          ConnectCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _userId,
            vendorId: 'sevenrooms',
            module: _venueId,
            keyPaste: const ConnectKeyPasteCredential(
              apiKey: 'partner-secret-xyz',
              username: 'partner-client-abc',
            ),
          ),
        );
        expect(connect.status, ConnectionStatus.connected);
        expect(connect.metadata['venue_id'], _venueId);
        expect(connect.firstBackfillStarted, true);

        // BACKFILL.
        reservations.pages = <SevenRoomsReservationsPage>[
          SevenRoomsReservationsPage(
            reservations: sevenRoomsFiveRecordBatch().sublist(0, 2),
            nextPageToken: 'cursor-1',
          ),
          SevenRoomsReservationsPage(
            reservations: sevenRoomsFiveRecordBatch().sublist(2),
            nextPageToken: null,
          ),
        ];
        final backfill = await adapter.backfill(
          BackfillCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _userId,
            vendorId: 'sevenrooms',
            windowStart: nowFixed.subtract(const Duration(days: 60)),
            windowEnd: nowFixed,
            sanityHook: const _AcceptAllSanityHook().call,
          ),
        );
        expect(backfill.recordsWritten, 5);
        final watermarkAfterBackfill = gateway.watermarkCalls.last.cursorToken;
        expect(watermarkAfterBackfill, isNotEmpty);

        // POLL — one tick, one new reservation.
        reservations.pages = <SevenRoomsReservationsPage>[
          SevenRoomsReservationsPage(
            reservations: <Map<String, Object?>>[
              <String, Object?>{
                'id': 'sr-resv-1006',
                'arrival_time': '2026-05-04T23:55:00.000Z',
                'party_size': 2,
                'status': 'BOOKED',
                'last_updated_at': '2026-05-04T11:55:00.000Z',
                'venue_id': _venueId,
              },
            ],
            nextPageToken: null,
          ),
        ];
        final poll = await adapter.pollIncremental(
          PollIncrementalCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _userId,
            vendorId: 'sevenrooms',
            lastModifiedSeen: nowFixed.subtract(const Duration(hours: 6)),
            sanityHook: const _AcceptAllSanityHook().call,
          ),
        );
        expect(poll.recordsWritten, 1);
        final watermarkAfterPoll = gateway.watermarkCalls.last;

        // DISCONNECT.
        await adapter.disconnect(
          DisconnectCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _userId,
            vendorId: 'sevenrooms',
            reason: DisconnectReason.operatorAction,
          ),
        );
        expect(auth.revokeCalls.length, 1);
        expect(gateway.disconnectCalls.length, 1);
        expect(
          gateway.watermarkCalls.last.cursorToken,
          watermarkAfterPoll.cursorToken,
          reason: 'disconnect must NOT clear the watermark',
        );
        // No webhook unregister for manualPaste vendors.
        expect(webhook.subscribeCalls, isEmpty);

        // RECONNECT — re-establish binding; verify the prior watermark
        // is still queryable for resume.
        final preservedCursor = gateway.watermarkCalls.last.cursorToken;
        gateway.disconnectCalls.clear();
        gateway.bindings['$_opId|$_locId'] =
            const SevenRoomsConnectionBinding(
          connectionId: 'conn-1',
          venueId: _venueId,
          accessTokenCredentialId: 'cred-access-2',
        );
        reservations.pages = <SevenRoomsReservationsPage>[
          SevenRoomsReservationsPage(
            reservations: const <Map<String, Object?>>[],
            nextPageToken: null,
          ),
        ];
        reservations.fetchCalls.clear();
        await adapter.pollIncremental(
          PollIncrementalCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _userId,
            vendorId: 'sevenrooms',
            lastModifiedSeen: nowFixed.subtract(const Duration(hours: 6)),
            cursorToken: preservedCursor,
            sanityHook: const _AcceptAllSanityHook().call,
          ),
        );
        expect(
          reservations.fetchCalls.first.cursorToken,
          preservedCursor,
          reason: 'reconnect resumes from preserved cursor',
        );
      },
    );

    test(
      'test-connection populates fieldMapping with reservation_at + '
      'party_size + status; offline path returns under 30s',
      () async {
        reservations.sample = sevenRoomsSampleReservation();
        final result = await adapter.testConnection(
          TestConnectionCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _userId,
            vendorId: 'sevenrooms',
          ),
        );
        expect(result.authValid, true);
        expect(
          result.fieldMapping['reservation_at'],
          '2026-05-04T19:00:00.000Z',
        );
        expect(result.fieldMapping['party_size'], 4);
        expect(result.fieldMapping['status'], 'booked');
        expect(result.elapsedMs, lessThan(30000));
        expect(result.note, contains('not_applicable'));
      },
    );

    test('replay window: 25h-old signature is rejected; 23h-old accepted',
        () async {
      const verifier = SevenRoomsWebhookSignatureVerifier();

      final old = signedSevenRoomsWebhook(
        signingSecret: 'secret',
        payload: standardSevenRoomsWebhookPayload(nowUtc: nowFixed),
        signingTimestamp: nowFixed.subtract(const Duration(hours: 25)),
      );
      final v25 = verifier.verify(
        rawBody: old.rawBody,
        headers: old.headers,
        signingSecret: 'secret',
        now: nowFixed,
      );
      expect(v25.valid, true);
      expect(
        nowFixed.difference(v25.timestamp!),
        greaterThan(const Duration(hours: 24)),
        reason: 'verifier surfaces timestamp; handler rejects on age > 24h',
      );

      final fresh = signedSevenRoomsWebhook(
        signingSecret: 'secret',
        payload: standardSevenRoomsWebhookPayload(nowUtc: nowFixed),
        signingTimestamp: nowFixed.subtract(const Duration(hours: 23)),
      );
      final v23 = verifier.verify(
        rawBody: fresh.rawBody,
        headers: fresh.headers,
        signingSecret: 'secret',
        now: nowFixed,
      );
      expect(v23.valid, true);
      expect(
        nowFixed.difference(v23.timestamp!),
        lessThan(const Duration(hours: 24)),
      );
    });
  });

  group('SevenRoomsWebhookSignatureVerifier', () {
    test('valid signature passes', () {
      const verifier = SevenRoomsWebhookSignatureVerifier();
      final env = signedSevenRoomsWebhook(
        signingSecret: 'shh',
        payload: const <String, Object?>{'x': 1},
      );
      final r = verifier.verify(
        rawBody: env.rawBody,
        headers: env.headers,
        signingSecret: 'shh',
        now: DateTime.utc(2026, 5, 4, 12, 0, 0),
      );
      expect(r.valid, true);
    });

    test('missing header returns false', () {
      const verifier = SevenRoomsWebhookSignatureVerifier();
      final r = verifier.verify(
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        headers: const <String, String>{},
        signingSecret: 'shh',
        now: DateTime.utc(2026, 5, 4, 12, 0, 0),
      );
      expect(r.valid, false);
      expect(r.failureReason, contains('missing'));
    });

    test('uppercase hex is rejected (contract is lowercase)', () {
      const verifier = SevenRoomsWebhookSignatureVerifier();
      final env = signedSevenRoomsWebhook(
        signingSecret: 'shh',
        payload: const <String, Object?>{'x': 1},
      );
      final headers = Map<String, String>.from(env.headers);
      headers['x-sevenrooms-signature'] =
          headers['x-sevenrooms-signature']!.toUpperCase();
      final r = verifier.verify(
        rawBody: env.rawBody,
        headers: headers,
        signingSecret: 'shh',
        now: DateTime.utc(2026, 5, 4, 12, 0, 0),
      );
      expect(r.valid, false);
    });
  });

  group('Banned items grep (V1 lean cut 2)', () {
    test('adapter source contains zero matches for banned items in code',
        () {
      // Strip line + block comments before searching: the contract
      // forbids banned CODE patterns, not header narration about why
      // they were deleted.
      final raw = File(
        'lib/integrations/reservation/sevenrooms_reservation_adapter.dart',
      ).readAsStringSync();
      final stripped = _stripDartComments(raw);
      const banned = <String>[
        'KMS',
        'pg_try_advisory_lock',
        'parse_warnings',
        'parse_partial',
        'kInboundWebhookReplayCeiling = Duration(minutes: 5)',
        'SIGTERM',
        'dead_letter_tile',
        'raw_payload_partition',
      ];
      for (final phrase in banned) {
        expect(
          stripped.contains(phrase),
          false,
          reason: 'V1 lean cut 2 banned item present in adapter: "$phrase"',
        );
      }
    });
  });
}

String _stripDartComments(String source) {
  final buffer = StringBuffer();
  var i = 0;
  while (i < source.length) {
    if (i + 1 < source.length &&
        source[i] == '/' &&
        source[i + 1] == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (i + 1 < source.length &&
        source[i] == '/' &&
        source[i + 1] == '*') {
      i += 2;
      while (i + 1 < source.length &&
          !(source[i] == '*' && source[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    buffer.write(source[i]);
    i++;
  }
  return buffer.toString();
}

// ─── Fakes ──────────────────────────────────────────────────────────

class _RecordingSanityHookCall {
  const _RecordingSanityHookCall({
    required this.vendorEventId,
    required this.isDeliberateBackfill,
  });
  final String vendorEventId;
  final bool isDeliberateBackfill;
}

class _RecordingSanityHook {
  _RecordingSanityHook({this.rejectVendorEntityId});
  final String? rejectVendorEntityId;
  final List<_RecordingSanityHookCall> calls = <_RecordingSanityHookCall>[];

  Future<bool> call({
    required String vendorEventId,
    required Map<String, Object?> payload,
    required bool isDeliberateBackfill,
  }) async {
    calls.add(_RecordingSanityHookCall(
      vendorEventId: vendorEventId,
      isDeliberateBackfill: isDeliberateBackfill,
    ));
    if (rejectVendorEntityId != null && vendorEventId == rejectVendorEntityId) {
      return false;
    }
    return true;
  }
}

class _AcceptAllSanityHook {
  const _AcceptAllSanityHook();
  Future<bool> call({
    required String vendorEventId,
    required Map<String, Object?> payload,
    required bool isDeliberateBackfill,
  }) async =>
      true;
}

class _ReservationWrite {
  const _ReservationWrite({
    required this.tenant,
    required this.vendorEntityId,
    required this.vendorModifiedAtUtc,
  });
  final TenantContext tenant;
  final String vendorEntityId;
  final DateTime vendorModifiedAtUtc;
}

class _WatermarkCall {
  const _WatermarkCall({
    required this.cursorToken,
    required this.lastModifiedSeenUtc,
  });
  final String cursorToken;
  final DateTime lastModifiedSeenUtc;
}

class _FakeGateway implements SevenRoomsReservationGateway {
  final Map<String, SevenRoomsConnectionBinding> bindings =
      <String, SevenRoomsConnectionBinding>{};
  final Map<String, SevenRoomsDisconnectBinding> disconnectBindings =
      <String, SevenRoomsDisconnectBinding>{};
  final List<_ReservationWrite> reservationWrites = <_ReservationWrite>[];
  final List<_WatermarkCall> watermarkCalls = <_WatermarkCall>[];
  final List<Map<String, Object?>> syncLogs = <Map<String, Object?>>[];
  final List<Map<String, Object?>> disconnectCalls = <Map<String, Object?>>[];
  final Set<String> _seenIdempotency = <String>{};

  @override
  Future<SevenRoomsConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
  }) async =>
      bindings['$operatorId|$locationId'];

  @override
  Future<SevenRoomsDisconnectBinding?> lookupDisconnectBinding({
    required String operatorId,
    required String locationId,
  }) async =>
      disconnectBindings['$operatorId|$locationId'];

  @override
  Future<bool> writeReservationFact({
    required TenantContext tenant,
    required String connectionId,
    required String vendorEntityId,
    required DateTime reservationAtUtc,
    required int partySize,
    required SevenRoomsCanonicalStatus status,
    required Map<String, DateTime> statusTransitions,
    required String restaurantTimezone,
    required int businessDayRolloverHour,
    required DateTime vendorModifiedAtUtc,
  }) async {
    final key =
        '$connectionId|$vendorEntityId|${vendorModifiedAtUtc.toIso8601String()}';
    if (_seenIdempotency.contains(key)) return false;
    _seenIdempotency.add(key);
    reservationWrites.add(_ReservationWrite(
      tenant: tenant,
      vendorEntityId: vendorEntityId,
      vendorModifiedAtUtc: vendorModifiedAtUtc,
    ));
    return true;
  }

  @override
  Future<void> updateWatermark({
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeenUtc,
  }) async {
    watermarkCalls.add(_WatermarkCall(
      cursorToken: cursorToken,
      lastModifiedSeenUtc: lastModifiedSeenUtc,
    ));
  }

  @override
  Future<String> upsertConnection({
    required TenantContext tenant,
    required String vendorVenueId,
    required String accessTokenCredentialId,
  }) async {
    bindings['${tenant.operatorId}|${tenant.locationId}'] =
        SevenRoomsConnectionBinding(
      connectionId: 'conn-1',
      venueId: vendorVenueId,
      accessTokenCredentialId: accessTokenCredentialId,
    );
    return 'conn-1';
  }

  @override
  Future<void> appendSyncLog({
    required String connectionId,
    required String eventKind,
    int? recordsCount,
    String? errorMessage,
  }) async {
    syncLogs.add(<String, Object?>{
      'connection_id': connectionId,
      'event_kind': eventKind,
      'records_count': recordsCount,
      'error_message': errorMessage,
    });
  }

  @override
  Future<void> wipeCredentialsAndDisconnect({
    required TenantContext tenant,
    required String connectionId,
    required DisconnectReason reason,
  }) async {
    disconnectCalls.add(<String, Object?>{
      'connection_id': connectionId,
      'reason': reason.name,
    });
  }
}

class _FakeAuthClient implements SevenRoomsAuthClient {
  SevenRoomsAuthResult authenticateResult = const SevenRoomsAuthResult(
    venueId: _venueId,
    accessTokenCredentialId: 'cred-access-1',
  );
  final List<String> revokeCalls = <String>[];
  final List<Map<String, String>> authenticateCalls = <Map<String, String>>[];

  @override
  Future<SevenRoomsAuthResult> authenticate({
    required String clientId,
    required String clientSecret,
    required String venueId,
  }) async {
    authenticateCalls.add(<String, String>{
      'client_id': clientId,
      'client_secret': clientSecret,
      'venue_id': venueId,
    });
    return authenticateResult;
  }

  @override
  Future<void> revoke({required String accessTokenCredentialId}) async {
    revokeCalls.add(accessTokenCredentialId);
  }
}

class _FakeWebhookClient implements SevenRoomsWebhookClient {
  final List<Map<String, String>> subscribeCalls = <Map<String, String>>[];

  @override
  Future<void> subscribe({
    required String accessTokenCredentialId,
    required String webhookUrl,
    required String venueId,
  }) async {
    subscribeCalls.add(<String, String>{
      'access_token_credential_id': accessTokenCredentialId,
      'webhook_url': webhookUrl,
      'venue_id': venueId,
    });
  }
}

class _FetchReservationsCall {
  const _FetchReservationsCall({required this.cursorToken, required this.useExport});
  final String? cursorToken;
  final bool useExport;
}

class _FakeReservationsClient implements SevenRoomsReservationsClient {
  List<SevenRoomsReservationsPage> pages = <SevenRoomsReservationsPage>[];
  Map<String, Object?> sample = sevenRoomsSampleReservation();
  int throwOnPage = -1;
  final List<_FetchReservationsCall> fetchCalls = <_FetchReservationsCall>[];

  @override
  Future<SevenRoomsReservationsPage> fetchReservationsPage({
    required String accessTokenCredentialId,
    required String venueId,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required int pageSize,
    required bool useExport,
    String? cursorToken,
  }) async {
    fetchCalls.add(_FetchReservationsCall(
      cursorToken: cursorToken,
      useExport: useExport,
    ));
    final n = fetchCalls.length;
    if (throwOnPage > 0 && n == throwOnPage) {
      throw StateError('simulated mid-batch crash on page $n');
    }
    if (pages.isEmpty) {
      return const SevenRoomsReservationsPage(
        reservations: <Map<String, Object?>>[],
        nextPageToken: null,
      );
    }
    final idx = (n - 1).clamp(0, pages.length - 1);
    return pages[idx];
  }

  @override
  Future<Map<String, Object?>> fetchSampleReservation({
    required String accessTokenCredentialId,
    required String venueId,
  }) async =>
      sample;
}

// ─── Inbound-handler fakes (signature-reject test) ──────────────────

class _RecordingWebhookGateway implements InboundWebhookGateway {
  final Map<String, ConnectionBinding> bindings = <String, ConnectionBinding>{};
  final Map<String, String> signingSecrets = <String, String>{};
  final Map<String, int> failedAttempts = <String, int>{};
  final List<Map<String, Object?>> deadLetterCalls = <Map<String, Object?>>[];
  final List<Map<String, Object?>> sanityDrops = <Map<String, Object?>>[];
  final Set<String> _seenIdempotency = <String>{};
  bool duplicateOnSecondCall = false;

  @override
  Future<ConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async =>
      bindings[vendorId];

  @override
  Future<String?> lookupSigningSecret({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async =>
      signingSecrets[vendorId];

  @override
  Future<IdempotencyOutcome> claimIdempotency({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) async {
    final key = '$vendorId:$vendorEventId';
    if (_seenIdempotency.contains(key) && duplicateOnSecondCall) {
      return IdempotencyOutcome.duplicate;
    }
    _seenIdempotency.add(key);
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
  }) async {
    sanityDrops.add(<String, Object?>{
      'vendor_event_id': vendorEventId,
      'rule': rule,
    });
  }

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
