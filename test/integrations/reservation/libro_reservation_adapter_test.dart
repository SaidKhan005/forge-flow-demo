// Phase 8R.LB — Libro reservation adapter tests (engineering slice).
//
// Fixture-based; no live HTTP. Live transport is the
// `8R.LB.live.sandbox` slice's responsibility per
// `docs/contracts/vendor_adapter_slice_contract.md`.
//
// Coverage map (each row maps to a mandatory framework call from the
// slice contract):
//
//   1. sanity hook call count — every dto in poll/backfill triggers
//      `command.sanityHook(...)` exactly once.
//   2. sanity hook reject path — returning `false` skips the
//      canonical write.
//   3. idempotency replay — same DTO twice → single canonical write.
//   4. watermark mid-batch resume — simulated crash → watermark
//      points at the last committed batch's cursor.
//   5. webhook signature reject — tampered HMAC → verifier returns
//      `valid: false`. The framework handler maps that to 403 +
//      dead-letter; that boundary is tested in
//      `test/integration/inbound_webhook_handler_test.dart`.
//   6. capability profile — every required field declared.
//   7. test connection — heavy sample-pull populates `fieldMapping`
//      and completes well under 30 s on the offline path.
//   8. connect → backfill → poll → disconnect → reconnect smoke —
//      watermark preserved across the cycle.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/reservation/libro_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/libro_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import 'fixtures/libro_reservations_fixture.dart';
import 'fixtures/libro_webhook_fixture.dart';

void main() {
  group('LibroReservationAdapter — capability profile (framework call #6)', () {
    test('declares every required field for slice contract verdict', () {
      final adapter = _buildAdapter();
      final profile = adapter.capabilityProfile;
      expect(profile.vendorId, kLibroVendorId);
      expect(profile.displayName, 'Libro Reserve');
      expect(profile.category, IntegrationCategory.reservation);
      expect(profile.authMode, VendorAuthMode.oauth);
      expect(profile.grantScope, VendorGrantScope.perLocation);
      expect(profile.webhookSupport, VendorWebhookSupport.autoRegister);
      expect(profile.coversFieldExposed, false,
          reason:
              'reservations channel does not contribute the COVERS card; '
              'POS adapter owns covers.');
      expect(profile.lifecycle, VendorLifecycle.documented,
          reason:
              'engineering slice ships at lifecycle = documented; '
              '*.live.* slices promote.');
      expect(profile.modules, isEmpty);
      expect(profile.timestampPolicyDocId, kLibroTimestampPolicyDocId);
    });

    test('lifecycle constant is `documented` at engineering slice ship', () {
      expect(kLibroLifecycleAtShip, VendorLifecycle.documented);
    });
  });

  group('LibroReservationAdapter — sanity hook (framework calls #1, #2)', () {
    test('pollIncremental calls sanityHook once per fixture row', () async {
      final fixture = _Fixture.standard();
      final hook = _RecordingSanityHook();
      await fixture.adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: kLibroVendorId,
          lastModifiedSeen: DateTime.utc(2026, 5, 1),
          sanityHook: hook.run,
        ),
      );
      expect(hook.calls, fixture.totalReservations);
      expect(hook.backfillFlags, everyElement(isFalse),
          reason: 'pollIncremental must pass isDeliberateBackfill=false.');
    });

    test('backfill calls sanityHook once per row with isDeliberateBackfill=true',
        () async {
      final fixture = _Fixture.standard();
      final hook = _RecordingSanityHook();
      await fixture.adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: kLibroVendorId,
          windowStart: DateTime.utc(2026, 3, 4),
          windowEnd: DateTime.utc(2026, 5, 4),
          sanityHook: hook.run,
        ),
      );
      expect(hook.calls, fixture.totalReservations);
      expect(hook.backfillFlags, everyElement(isTrue),
          reason: 'backfill must pass isDeliberateBackfill=true.');
    });

    test('sanityHook returning false skips the canonical fact write', () async {
      final fixture = _Fixture.standard();
      final result = await fixture.adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: kLibroVendorId,
          lastModifiedSeen: DateTime.utc(2026, 5, 1),
          sanityHook: ({
            required String vendorEventId,
            required Map<String, Object?> payload,
            required bool isDeliberateBackfill,
          }) async =>
              false,
        ),
      );
      expect(fixture.gateway.upserts, isEmpty,
          reason: 'sanityHook returning false must short-circuit the write.');
      expect(result.recordsWritten, 0);
      expect(result.sanityDropped, fixture.totalReservations);
    });
  });

  group('LibroReservationAdapter — idempotency (framework call #2)', () {
    test('same payload twice → single canonical write', () async {
      final fixture = _Fixture.standard();
      await fixture.adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: kLibroVendorId,
          lastModifiedSeen: DateTime.utc(2026, 5, 1),
          sanityHook: _alwaysPass,
        ),
      );
      final firstWrites = fixture.gateway.upserts.length;
      // Re-run the poll with the same fixture pages — the gateway's
      // partial UNIQUE on (vendor_id, vendor_entity_id,
      // vendor_modified_at) returns wrote=false for every row.
      fixture.httpClient.resetCursor();
      final replayResult = await fixture.adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: kLibroVendorId,
          lastModifiedSeen: DateTime.utc(2026, 5, 1),
          sanityHook: _alwaysPass,
        ),
      );
      expect(fixture.gateway.upserts.length, firstWrites,
          reason: 'partial UNIQUE upsert must collapse the second arrival.');
      expect(replayResult.recordsWritten, 0,
          reason: 'idempotent replay returns 0 fresh writes.');
    });
  });

  group('LibroReservationAdapter — watermark per batch (framework call #3)',
      () {
    test('mid-backfill crash leaves watermark at the last successful batch',
        () async {
      final fixture = _Fixture.crashAfterFirstPage();
      Object? captured;
      try {
        await fixture.adapter.backfill(
          BackfillCommand(
            operatorId: _opId,
            locationId: _locId,
            actorUserId: _userId,
            vendorId: kLibroVendorId,
            windowStart: DateTime.utc(2026, 3, 4),
            windowEnd: DateTime.utc(2026, 5, 4),
            sanityHook: _alwaysPass,
          ),
        );
      } catch (e) {
        captured = e;
      }
      expect(captured, isNotNull,
          reason: 'fixture is configured to throw mid-backfill.');
      expect(fixture.gateway.watermarks, isNotEmpty,
          reason: 'watermark must persist before the crash.');
      expect(
        fixture.gateway.watermarks.last['cursor_token'],
        'cursor-page-2',
        reason:
            'watermark records the cursor for the NEXT page, proving the '
            'last successful batch committed.',
      );
    });
  });

  group('LibroReservationAdapter — test connection (framework call #8)', () {
    test('completes well under 30s and populates fieldMapping', () async {
      final fixture = _Fixture.standard();
      final result = await fixture.adapter.testConnection(
        TestConnectionCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: kLibroVendorId,
        ),
      );
      expect(result.authValid, true);
      expect(result.elapsedMs, lessThan(30000),
          reason:
              'test-connection must beat the framework 30s ceiling on the '
              'offline path.');
      expect(result.fieldMapping['party_size'], isNotNull,
          reason: 'fieldMapping must surface party_size for operator '
              'verification.');
      expect(result.fieldMapping['reservation_at'], isNotNull);
      expect(result.fieldMapping['status'], isNotNull);
    });
  });

  group('LibroWebhookSignatureVerifier (framework call #4)', () {
    const verifier = LibroWebhookSignatureVerifier();
    const secret = 'whsec_libro_demo_secret';

    test('accepts a valid Libro signature', () {
      final body = buildLibroSignedBody(
        libroWebhookPayloadReservationConfirmed,
      );
      final ts = DateTime.utc(2026, 5, 4, 11, 30, 6);
      final headerValue = signLibroWebhook(
        body: body,
        signingSecret: secret,
        timestamp: ts,
      );
      final v = verifier.verify(
        rawBody: body,
        headers: <String, String>{kLibroSignatureHeader: headerValue},
        signingSecret: secret,
        now: ts,
      );
      expect(v.valid, true);
      expect(v.timestamp?.toUtc(), ts);
    });

    test('rejects a tampered body with the same header', () {
      final original = buildLibroSignedBody(
        libroWebhookPayloadReservationConfirmed,
      );
      final ts = DateTime.utc(2026, 5, 4, 11, 30, 6);
      final headerValue = signLibroWebhook(
        body: original,
        signingSecret: secret,
        timestamp: ts,
      );
      final tampered = Uint8List.fromList(
        utf8.encode(json.encode(<String, Object?>{
          ...libroWebhookPayloadReservationConfirmed,
          'id': 'wh-evt-tampered',
        })),
      );
      final v = verifier.verify(
        rawBody: tampered,
        headers: <String, String>{kLibroSignatureHeader: headerValue},
        signingSecret: secret,
        now: ts,
      );
      expect(v.valid, false);
      expect(v.failureReason, 'signature mismatch');
    });

    test('rejects a tampered signature with the same body', () {
      final body = buildLibroSignedBody(
        libroWebhookPayloadReservationConfirmed,
      );
      final ts = DateTime.utc(2026, 5, 4, 11, 30, 6);
      final goodHeader = signLibroWebhook(
        body: body,
        signingSecret: secret,
        timestamp: ts,
      );
      final lastChar = goodHeader[goodHeader.length - 1];
      final flipped = goodHeader.substring(0, goodHeader.length - 1) +
          (lastChar == 'a' ? 'b' : 'a');
      final v = verifier.verify(
        rawBody: body,
        headers: <String, String>{kLibroSignatureHeader: flipped},
        signingSecret: secret,
        now: ts,
      );
      expect(v.valid, false);
    });

    test('returns the parsed timestamp so framework can enforce 24h replay',
        () {
      final body = buildLibroSignedBody(
        libroWebhookPayloadReservationConfirmed,
      );
      final ts = DateTime.utc(2026, 5, 4, 11, 30, 6);
      final header = signLibroWebhook(
        body: body,
        signingSecret: secret,
        timestamp: ts,
      );
      final v = verifier.verify(
        rawBody: body,
        headers: <String, String>{kLibroSignatureHeader: header},
        signingSecret: secret,
        now: ts.add(const Duration(hours: 1)),
      );
      expect(v.timestamp?.toUtc(), ts,
          reason:
              'parsed timestamp drives the framework\'s 24h replay window — '
              'the strict 5-min window from iter1 was deleted per V1 lean '
              'cut 2.');
    });

    test('rejects malformed header (missing v1 segment)', () {
      final body = buildLibroSignedBody(
        libroWebhookPayloadReservationConfirmed,
      );
      final v = verifier.verify(
        rawBody: body,
        headers: const <String, String>{
          kLibroSignatureHeader: 't=1746400000',
        },
        signingSecret: secret,
        now: DateTime.utc(2026, 5, 4, 11, 30, 6),
      );
      expect(v.valid, false);
    });

    test('rejects when the signature header is absent', () {
      final body = buildLibroSignedBody(
        libroWebhookPayloadReservationConfirmed,
      );
      final v = verifier.verify(
        rawBody: body,
        headers: const <String, String>{},
        signingSecret: secret,
        now: DateTime.utc(2026, 5, 4, 11, 30, 6),
      );
      expect(v.valid, false);
      expect(v.failureReason, 'missing X-Libro-Signature header');
    });
  });

  group('LibroReservationAdapter — webhook handler (framework call #4)', () {
    test('writes a canonical fact + flips demo-mode on first webhook',
        () async {
      final fixture = _Fixture.standard();
      final result = await fixture.adapter.handleWebhook(
        HandleWebhookCommand(
          operatorId: _opId,
          locationId: _locId,
          vendorId: kLibroVendorId,
          vendorEventId:
              libroWebhookPayloadReservationConfirmed['id']! as String,
          payload: libroWebhookPayloadReservationConfirmed,
          headers: const <String, String>{},
          receivedAt: DateTime.utc(2026, 5, 4, 11, 30, 6),
        ),
      );
      expect(result.recordsWritten, 1);
      expect(fixture.gateway.demoFlipCalls, 1,
          reason: 'first webhook commit must flip demo_mode_state.');
    });

    test('drops malformed webhook (missing reservation envelope) without write',
        () async {
      final fixture = _Fixture.standard();
      final result = await fixture.adapter.handleWebhook(
        HandleWebhookCommand(
          operatorId: _opId,
          locationId: _locId,
          vendorId: kLibroVendorId,
          vendorEventId: 'wh-evt-malformed',
          payload: const <String, Object?>{
            'id': 'wh-evt-malformed',
            'type': 'reservation.confirmed',
          },
          headers: const <String, String>{},
          receivedAt: DateTime.utc(2026, 5, 4, 11, 30, 6),
        ),
      );
      expect(result.recordsWritten, 0);
      expect(fixture.gateway.upserts, isEmpty);
    });
  });

  group('LibroReservationAdapter — connect → backfill → poll → disconnect → reconnect',
      () {
    test('watermark + canonical facts preserved across the cycle', () async {
      final fixture = _Fixture.standard();
      // 1. backfill writes 3 rows + watermark.
      await fixture.adapter.backfill(
        BackfillCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: kLibroVendorId,
          windowStart: DateTime.utc(2026, 3, 4),
          windowEnd: DateTime.utc(2026, 5, 4),
          sanityHook: _alwaysPass,
        ),
      );
      final backfillWatermark =
          Map<String, Object?>.from(fixture.gateway.watermarks.last);
      final backfillUpserts = fixture.gateway.upserts.length;
      expect(backfillUpserts, fixture.totalReservations);

      // 2. disconnect — credentials wiped, watermark preserved.
      final disconnectResult = await fixture.adapter.disconnect(
        DisconnectCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: kLibroVendorId,
          reason: DisconnectReason.operatorAction,
        ),
      );
      expect(disconnectResult.credentialsWiped, true);
      expect(disconnectResult.watermarkPreserved, true);
      expect(
        fixture.gateway.watermarks.last['cursor_token'],
        backfillWatermark['cursor_token'],
        reason: 'disconnect must NOT mutate the watermark cursor.',
      );
      expect(fixture.httpClient.unregisterCalls, 1);
      expect(fixture.httpClient.revokeCalls, 1);

      // 3. reconnect — same fixture, idempotent re-poll picks up zero
      //    fresh writes (UNIQUE upsert collapses replays).
      fixture.httpClient.resetCursor();
      final repollResult = await fixture.adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _userId,
          vendorId: kLibroVendorId,
          lastModifiedSeen:
              backfillWatermark['last_modified_seen']! as DateTime,
          sanityHook: _alwaysPass,
        ),
      );
      expect(repollResult.recordsWritten, 0,
          reason: 'reconnect re-poll must not double-write existing rows.');
    });
  });
}

// ─── Fixtures and stubs ────────────────────────────────────────────

const String _opId = '00000000-0000-4000-8000-000000000111';
const String _locId = '00000000-0000-4000-8000-0000000001a1';
const String _userId = '00000000-0000-4000-8000-0000000001b1';

Future<bool> _alwaysPass({
  required String vendorEventId,
  required Map<String, Object?> payload,
  required bool isDeliberateBackfill,
}) async =>
    true;

class _RecordingSanityHook {
  int calls = 0;
  final List<bool> backfillFlags = <bool>[];

  Future<bool> run({
    required String vendorEventId,
    required Map<String, Object?> payload,
    required bool isDeliberateBackfill,
  }) async {
    calls++;
    backfillFlags.add(isDeliberateBackfill);
    return true;
  }
}

class _Fixture {
  _Fixture._({
    required this.adapter,
    required this.httpClient,
    required this.gateway,
    required this.totalReservations,
  });

  factory _Fixture.standard() {
    final pages = <Map<String, Object?>>[
      libroReservationPagePayloadFirstOfTwo,
      libroReservationPagePayloadSecondOfTwo,
    ];
    final reservations = pages
        .map((p) => (p['reservations'] as List).length)
        .reduce((a, b) => a + b);
    final httpClient = _StubLibroHttpClient(pages);
    final gateway = _StubLibroGateway();
    final adapter = LibroReservationAdapter(
      gateway: gateway,
      httpClient: httpClient,
      timezoneConverter: _FixedOffsetConverter(),
    );
    return _Fixture._(
      adapter: adapter,
      httpClient: httpClient,
      gateway: gateway,
      totalReservations: reservations,
    );
  }

  factory _Fixture.crashAfterFirstPage() {
    final httpClient = _StubLibroHttpClient(
      <Map<String, Object?>>[
        libroReservationPagePayloadFirstOfTwo,
      ],
      throwAfter: 1,
    );
    final gateway = _StubLibroGateway();
    final adapter = LibroReservationAdapter(
      gateway: gateway,
      httpClient: httpClient,
      timezoneConverter: _FixedOffsetConverter(),
    );
    return _Fixture._(
      adapter: adapter,
      httpClient: httpClient,
      gateway: gateway,
      totalReservations: 1,
    );
  }

  final LibroReservationAdapter adapter;
  final _StubLibroHttpClient httpClient;
  final _StubLibroGateway gateway;
  final int totalReservations;
}

/// Deterministic stub converter — tests do not depend on tzdata. Treats
/// the location as a fixed -4h offset (America/Toronto in summer); the
/// real converter ships in production via [LibroIanaConverter].
class _FixedOffsetConverter implements LibroTimezoneConverter {
  static const Duration _offset = Duration(hours: -4);

  @override
  DateTime wallClockToUtc({
    required String restaurantTimezone,
    required DateTime wallClock,
  }) {
    if (wallClock.isUtc) return wallClock;
    return DateTime.utc(
      wallClock.year,
      wallClock.month,
      wallClock.day,
      wallClock.hour,
      wallClock.minute,
      wallClock.second,
      wallClock.millisecond,
      wallClock.microsecond,
    ).subtract(_offset);
  }

  @override
  DateTime toBusinessDate({
    required String restaurantTimezone,
    required int businessDayRolloverHour,
    required DateTime instant,
  }) {
    // Project to local (UTC + offset == local clock) then apply
    // rollover hour.
    final local = instant.add(_offset);
    final adjusted = local.hour < businessDayRolloverHour
        ? DateTime.utc(local.year, local.month, local.day)
            .subtract(const Duration(days: 1))
        : DateTime.utc(local.year, local.month, local.day);
    return adjusted;
  }
}

class _StubLibroHttpClient implements LibroHttpClient {
  _StubLibroHttpClient(this._pages, {this.throwAfter});

  final List<Map<String, Object?>> _pages;
  final int? throwAfter;
  int _cursor = 0;
  int registerCalls = 0;
  int unregisterCalls = 0;
  int revokeCalls = 0;

  void resetCursor() => _cursor = 0;

  @override
  Future<LibroReservationPage> listReservations({
    required VendorCredentialHandle credential,
    required String venueId,
    required DateTime updatedSince,
    DateTime? updatedBefore,
    String? cursor,
    int? pageSize,
  }) async {
    if (throwAfter != null && _cursor >= throwAfter!) {
      throw StateError('simulated mid-backfill crash after page $_cursor');
    }
    if (_cursor >= _pages.length) {
      return const LibroReservationPage(
        reservations: <LibroReservationDto>[],
      );
    }
    final raw = _pages[_cursor++];
    final reservations = (raw['reservations'] as List)
        .cast<Map<String, Object?>>()
        .map(LibroReservationDto.fromMap)
        .toList();
    return LibroReservationPage(
      reservations: reservations,
      nextCursor: raw['next_cursor'] as String?,
    );
  }

  @override
  Future<void> revokeCredential(
      {required VendorCredentialHandle credential}) async {
    revokeCalls++;
  }

  @override
  Future<void> unregisterWebhook({
    required VendorCredentialHandle credential,
    required String subscriptionId,
  }) async {
    unregisterCalls++;
  }

  @override
  Future<String> registerWebhook({
    required VendorCredentialHandle credential,
    required String venueId,
    required String webhookUrl,
    required List<String> events,
  }) async {
    registerCalls++;
    return 'whsub-fixture-1';
  }
}

class _StubLibroGateway implements LibroReservationGateway {
  final Set<String> _idempotencyKeys = <String>{};
  final List<Map<String, Object?>> upserts = <Map<String, Object?>>[];
  final List<Map<String, Object?>> watermarks = <Map<String, Object?>>[];
  int demoFlipCalls = 0;
  int wipeCalls = 0;

  LibroConnectionContext? _ctx = const LibroConnectionContext(
    connectionId: 'conn-libro-1',
    venueId: 'venue-toronto-yorkville',
    credential: VendorCredentialHandle(credentialId: 'cred-1'),
    webhookSubscriptionId: 'whsub-fixture-1',
    restaurantTimezone: 'America/Toronto',
    businessDayRolloverHour: 4,
  );

  @override
  Future<LibroConnectionContext?> lookupConnection({
    required String operatorId,
    required String locationId,
  }) async =>
      _ctx;

  @override
  Future<String> persistConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required VendorCredentialHandle credential,
    required Map<String, Object?> metadata,
  }) async {
    _ctx = LibroConnectionContext(
      connectionId: 'conn-libro-1',
      venueId: metadata['venue_id']! as String,
      credential: credential,
      webhookSubscriptionId:
          metadata['webhook_subscription_id'] as String?,
      restaurantTimezone: 'America/Toronto',
      businessDayRolloverHour: 4,
    );
    return 'conn-libro-1';
  }

  @override
  Future<ReservationUpsertOutcome> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required CanonicalReservationFact fact,
  }) async {
    final key =
        '${fact.vendorId}|${fact.vendorEntityId}|${fact.vendorModifiedAt.toIso8601String()}';
    if (_idempotencyKeys.contains(key)) {
      return const ReservationUpsertOutcome(wrote: false);
    }
    _idempotencyKeys.add(key);
    upserts.add(<String, Object?>{
      'vendor_entity_id': fact.vendorEntityId,
      'vendor_modified_at': fact.vendorModifiedAt,
      'reservation_at': fact.reservationAt,
      'business_date': fact.businessDate,
      'party_size': fact.partySize,
      'status': fact.status.name,
      'status_transitions': fact.statusTransitions,
    });
    return const ReservationUpsertOutcome(wrote: true);
  }

  @override
  Future<void> recordWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String resource,
    required String? cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    watermarks.add(<String, Object?>{
      'cursor_token': cursorToken,
      'last_modified_seen': lastModifiedSeen,
    });
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    int? recordsCount,
    String? errorMessage,
  }) async {}

  @override
  Future<void> markReservationsLive({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    demoFlipCalls++;
  }

  @override
  Future<void> wipeCredential({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    wipeCalls++;
  }
}

LibroReservationAdapter _buildAdapter() => LibroReservationAdapter(
      gateway: _StubLibroGateway(),
      httpClient: _StubLibroHttpClient(const <Map<String, Object?>>[]),
      timezoneConverter: _FixedOffsetConverter(),
    );
