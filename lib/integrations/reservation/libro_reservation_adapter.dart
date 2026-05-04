// Phase 8R.LB — Libro reservation adapter (engineering slice).
//
// Reference adapter for the Reservations family per
// `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md`.
// Lifecycle at slice ship: `documented` (per
// `docs/contracts/vendor_adapter_slice_contract.md`). Promotion to
// `sandbox_verified` / `production_credentialed` happens in
// `8R.LB.live.sandbox` / `8R.LB.live.prod`.
//
// Doc pack (review contract):
//   docs/integrations/libro/api_consumed.md
//   docs/integrations/libro/field_mapping.md
//   docs/integrations/libro/oauth_shape.md
//   docs/integrations/libro/webhook_signature.md
//   docs/integrations/libro/live_verification_checklist.md
//   docs/integrations/libro/partnership_status.md
//
// Source documentation: https://libroreserve.github.io/api-documentation/
// Retrieved: 2026-05-04 (pinned in api_consumed.md).
//
// Hard rules honored here:
//   * `command.sanityHook(...)` is consulted BEFORE every canonical
//     reservation fact write in `pollIncremental` and `backfill`.
//     Returning `false` skips the write (framework already wrote
//     `sanity_log` + `connector_sync_log`).
//   * The webhook handler does NOT re-call `sanityHook` — the
//     framework enforces sanity inline at step 4 of the dispatch
//     sequence (see `inbound_webhook_handler.dart`).
//   * Idempotency is enforced via the canonical-fact gateway's UPSERT
//     keyed on `(vendor_id, operator_id, vendor_entity_id,
//     vendor_modified_at)` per the `reservation_facts` partial unique
//     index in the framework migration.
//   * `connector_sync_watermark` is updated AFTER each successful
//     batch insert via [LibroReservationGateway.recordWatermark].
//   * Webhook signature verification lives in
//     [LibroWebhookSignatureVerifier] (HMAC-SHA256, hex lowercase,
//     constant-time compare; 24h replay tolerance enforced by the
//     framework's `kInboundWebhookReplayCeiling`).
//   * Plaintext credentials never reach this file. The adapter holds
//     a [VendorCredentialHandle] and asks [LibroHttpClient] to resolve
//     it server-side. No `package:postgres` import here; canonical
//     writes flow through [LibroReservationGateway] which is wired to
//     `OperatorScopedRepository.withTenant` in the production gateway.
//   * Capability profile declares every required field per the slice
//     contract; lifecycle is exposed via [kLibroLifecycleAtShip] until
//     `8.0.lifecycle` extends [VendorCapabilityProfile] with the enum.

import 'package:timezone/timezone.dart' as tz;

import '../../services/integration/iana_timezone_converter.dart';
import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/reservation_adapter.dart';
import '../../utils/iana_timezones.dart' as iana;

/// Stable vendor id matching `connector_connection.vendor_id` and
/// `VendorCapabilityProfile.vendorId`. The verifier imports this
/// constant; the framework adapter map keys on it.
const String kLibroVendorId = 'libro';

/// Lifecycle state at slice ship — `documented` per
/// `docs/contracts/vendor_adapter_slice_contract.md`. The framework
/// `VendorLifecycle` enum landed in `8.0.lifecycle`; the picker
/// chrome reads the enum directly off the capability profile.
const VendorLifecycle kLibroLifecycleAtShip = VendorLifecycle.documented;

/// Per-vendor timestamp policy id matching `vendorTimestampPolicy`
/// in `lib/services/integration/vendor_timestamp_policy.dart`. Libro
/// emits restaurant-local wall-clock timestamps with no tz hint;
/// the IANA converter projects to UTC via `restaurantTimezone`.
const String kLibroTimestampPolicyDocId = 'libro';

/// Stable resource string written to `connector_sync_watermark.resource`.
const String kLibroReservationsResource = 'reservations';

/// Vendor-side webhook events the adapter subscribes to. Documented in
/// `docs/integrations/libro/webhook_signature.md` and asserted by
/// [LibroReservationAdapter.connect].
const List<String> kLibroSubscribedEvents = <String>[
  'reservation.created',
  'reservation.updated',
  'reservation.confirmed',
  'reservation.seated',
  'reservation.completed',
  'reservation.canceled',
];

/// Opaque server-side credential reference. Wired to
/// `vendor_credentials_repository.dart` (Phase 8.0). Plaintext bearer
/// tokens never leave the proxy boundary; [LibroHttpClient] resolves
/// the handle internally.
class VendorCredentialHandle {
  const VendorCredentialHandle({required this.credentialId});
  final String credentialId;
}

// ─── Vendor-shape DTOs (documented per Libro v1) ────────────────────

/// Vendor-shape reservation row as emitted by Libro's reservations
/// endpoint. Field names mirror `documented_per_libro_v1` in
/// `test/integrations/reservation/fixtures/libro_reservations_fixture.dart`.
class LibroReservationDto {
  const LibroReservationDto({
    required this.id,
    required this.venueId,
    required this.size,
    required this.status,
    required this.reservationAt,
    required this.updatedAt,
    this.createdAt,
    this.arrivedAt,
    this.confirmedAt,
    this.seatedAt,
    this.completedAt,
    this.canceledAt,
    this.notes,
  });

  final String id;
  final String venueId;
  final int size;
  final String status;

  /// Vendor-local wall-clock instants (no tz hint per
  /// `vendor_timestamp_policy['libro']`). Adapter projects via
  /// `IanaTimezoneConverter` BEFORE deciding `business_date`.
  final DateTime reservationAt;
  final DateTime updatedAt;
  final DateTime? createdAt;
  final DateTime? arrivedAt;
  final DateTime? confirmedAt;
  final DateTime? seatedAt;
  final DateTime? completedAt;
  final DateTime? canceledAt;

  /// Free-text operator notes. Forbidden field per
  /// `field_mapping.md` — adapter ignores it (privacy / scope).
  final String? notes;

  static LibroReservationDto fromMap(Map<String, Object?> map) {
    return LibroReservationDto(
      id: map['id']! as String,
      venueId: map['venue_id']! as String,
      size: (map['size']! as num).toInt(),
      status: map['status']! as String,
      reservationAt: _parseInstant(map['reservation_at']),
      updatedAt: _parseInstant(map['updated_at']),
      createdAt: _parseOptional(map['created_at']),
      arrivedAt: _parseOptional(map['arrived_at']),
      confirmedAt: _parseOptional(map['confirmed_at']),
      seatedAt: _parseOptional(map['seated_at']),
      completedAt: _parseOptional(map['completed_at']),
      canceledAt: _parseOptional(map['canceled_at']),
      notes: map['notes'] as String?,
    );
  }

  static DateTime _parseInstant(Object? raw) {
    if (raw is DateTime) return raw;
    if (raw is String && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
    throw const FormatException('libro reservation timestamp missing');
  }

  static DateTime? _parseOptional(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
    return null;
  }
}

/// One page of Libro reservations + pagination cursor.
class LibroReservationPage {
  const LibroReservationPage({
    required this.reservations,
    this.nextCursor,
  });

  final List<LibroReservationDto> reservations;

  /// Next cursor token; null when the page chain is exhausted.
  final String? nextCursor;
}

// ─── HTTP / gateway seams (test-injectable) ─────────────────────────

/// HTTP transport seam. Production wires a Dart `package:http` /
/// `package:dio` implementation that resolves [VendorCredentialHandle]
/// to a bearer token server-side and pages through the documented
/// endpoints. Tests pass an in-memory stub that returns fixture
/// payloads — no network round-trip, no live HTTP.
abstract class LibroHttpClient {
  /// `GET /v1/reservations?venue_id=...&updated_since=...&cursor=...`
  /// per `docs/integrations/libro/api_consumed.md`.
  Future<LibroReservationPage> listReservations({
    required VendorCredentialHandle credential,
    required String venueId,
    required DateTime updatedSince,
    DateTime? updatedBefore,
    String? cursor,
    int? pageSize,
  });

  /// `POST /v1/oauth/revoke` — called on operator-initiated disconnect
  /// per `docs/integrations/libro/oauth_shape.md`.
  Future<void> revokeCredential({required VendorCredentialHandle credential});

  /// `DELETE /v1/webhooks/subscriptions/{id}` — called on operator-
  /// initiated disconnect per
  /// `docs/integrations/libro/webhook_signature.md`.
  Future<void> unregisterWebhook({
    required VendorCredentialHandle credential,
    required String subscriptionId,
  });

  /// `POST /v1/webhooks/subscriptions` — called on first connect to
  /// register the F&F webhook URL with the operator's Libro venue.
  Future<String> registerWebhook({
    required VendorCredentialHandle credential,
    required String venueId,
    required String webhookUrl,
    required List<String> events,
  });
}

/// Canonical-fact write seam. Production wires this to a
/// Postgres-backed implementation that runs every write inside
/// `OperatorScopedRepository.withTenant(...)` so RLS engages and the
/// `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`
/// idempotency UNIQUE on `reservation_facts` is honored. Tests pass an
/// in-memory fake.
abstract class LibroReservationGateway {
  /// Resolve the operator's Libro venue + credential + webhook
  /// subscription state from `connector_connection.metadata`. Returns
  /// null when the operator has not connected Libro at the named
  /// (operator, location).
  Future<LibroConnectionContext?> lookupConnection({
    required String operatorId,
    required String locationId,
  });

  /// Persist the connector_connection row + vendor_credentials row
  /// during the connect flow. Returns the framework-issued connection
  /// id.
  Future<String> persistConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required VendorCredentialHandle credential,
    required Map<String, Object?> metadata,
  });

  /// Upsert one canonical reservation fact row. Implementations MUST
  /// honor the partial UNIQUE index on
  /// `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`
  /// — same payload arriving twice MUST be a no-op (the second call
  /// returns `wrote: false`).
  Future<ReservationUpsertOutcome> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required CanonicalReservationFact fact,
  });

  /// Persist watermark (cursor + last_modified_seen) AFTER each
  /// successful batch commit. Required for Cloud Run Job restart
  /// resilience per the framework slice contract.
  Future<void> recordWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String resource,
    required String? cursorToken,
    required DateTime lastModifiedSeen,
  });

  /// Write a `connector_sync_log` row.
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    int? recordsCount,
    String? errorMessage,
  });

  /// Flip `demo_mode_state.is_demo = false` for the reservation
  /// channel after the first batch commits ≥1 record. Idempotent.
  Future<void> markReservationsLive({
    required String operatorId,
    required String locationId,
    required String connectionId,
  });

  /// Wipe the credential envelope on disconnect. The historical
  /// canonical facts and watermark are preserved per the framework
  /// contract — reconnect resumes from the last cursor.
  Future<void> wipeCredential({
    required String operatorId,
    required String locationId,
    required String connectionId,
  });
}

/// Connection context loaded by the gateway once per adapter
/// invocation. Carries the operator-scoped venue + credential + webhook
/// subscription state plus the live watermark cursor.
class LibroConnectionContext {
  const LibroConnectionContext({
    required this.connectionId,
    required this.venueId,
    required this.credential,
    required this.webhookSubscriptionId,
    required this.restaurantTimezone,
    required this.businessDayRolloverHour,
  });

  final String connectionId;
  final String venueId;
  final VendorCredentialHandle credential;
  final String? webhookSubscriptionId;
  final String restaurantTimezone;
  final int businessDayRolloverHour;
}

/// Outcome of a canonical reservation fact upsert. `wrote` is `false`
/// when the partial UNIQUE matched (duplicate) and the row was a no-op.
class ReservationUpsertOutcome {
  const ReservationUpsertOutcome({required this.wrote});
  final bool wrote;
}

/// IANA conversion seam. The adapter needs two operations:
///
///   * `wallClockToUtc` — Libro emits restaurant-local wall-clock
///     timestamps with no tz hint per `vendorTimestampPolicy['libro']`.
///     The adapter projects to UTC instant via the location's IANA
///     timezone before storing on the canonical fact.
///   * `toBusinessDate` — denormalize per Phase 7.55 Rule 11.
///
/// Production wires [LibroIanaConverter] backed by
/// `IanaTimezoneConverter.shared`. Tests pass a deterministic stub.
abstract class LibroTimezoneConverter {
  DateTime wallClockToUtc({
    required String restaurantTimezone,
    required DateTime wallClock,
  });

  DateTime toBusinessDate({
    required String restaurantTimezone,
    required int businessDayRolloverHour,
    required DateTime instant,
  });
}

/// Production-wired converter. Uses the framework's
/// [IanaTimezoneConverter] for business-date projection and
/// `package:timezone` directly for wall-clock-to-UTC.
class LibroIanaConverter implements LibroTimezoneConverter {
  LibroIanaConverter({IanaTimezoneConverter? converter})
      : _converter = converter ?? IanaTimezoneConverter.shared;

  final IanaTimezoneConverter _converter;

  @override
  DateTime wallClockToUtc({
    required String restaurantTimezone,
    required DateTime wallClock,
  }) {
    if (wallClock.isUtc) return wallClock;
    if (!iana.isValidIanaTimezoneName(restaurantTimezone)) {
      throw IanaTimezoneConverterError(
        'unknown IANA timezone: $restaurantTimezone',
        restaurantTimezone: restaurantTimezone,
      );
    }
    final location = tz.getLocation(restaurantTimezone);
    final local = tz.TZDateTime(
      location,
      wallClock.year,
      wallClock.month,
      wallClock.day,
      wallClock.hour,
      wallClock.minute,
      wallClock.second,
      wallClock.millisecond,
      wallClock.microsecond,
    );
    return local.toUtc();
  }

  @override
  DateTime toBusinessDate({
    required String restaurantTimezone,
    required int businessDayRolloverHour,
    required DateTime instant,
  }) =>
      _converter.toBusinessDate(
        restaurantTimezone: restaurantTimezone,
        businessDayRolloverHour: businessDayRolloverHour,
        instant: instant,
      );
}

// ─── Canonical reservation fact ─────────────────────────────────────

/// Normalized reservation status the dashboard reads. Mirrors the
/// app-side `ReservationStatus` vocabulary the read model expects.
enum CanonicalReservationStatus {
  expected,
  confirmed,
  arrived,
  seated,
  completed,
  canceled,
  noShow,
}

/// One row written to `reservation_facts`. The JSONB columns
/// (`raw_payload`) carry the full vendor DTO so the live slice can
/// diff observed against documented field mapping.
class CanonicalReservationFact {
  const CanonicalReservationFact({
    required this.vendorId,
    required this.vendorEntityId,
    required this.vendorModifiedAt,
    required this.reservationAt,
    required this.businessDate,
    required this.partySize,
    required this.status,
    required this.statusTransitions,
    required this.rawPayload,
  });

  final String vendorId;
  final String vendorEntityId;
  final DateTime vendorModifiedAt;

  /// UTC instant of the reservation per the IANA-projected vendor
  /// wall-clock. The denormalized [businessDate] column stores the
  /// per-Phase-7.55 Rule 11 business-date projection.
  final DateTime reservationAt;
  final DateTime businessDate;

  final int partySize;
  final CanonicalReservationStatus status;

  /// Per-status transition timestamps as projected to UTC. Keys match
  /// `CanonicalReservationStatus.name`.
  final Map<String, DateTime> statusTransitions;

  /// Full vendor DTO retained on the canonical fact's `raw_payload`
  /// JSONB column.
  final Map<String, Object?> rawPayload;
}

// ─── Adapter ────────────────────────────────────────────────────────

/// Libro reservation adapter. Reference adapter for Phase 8R.
class LibroReservationAdapter implements ReservationAdapter {
  LibroReservationAdapter({
    required this.gateway,
    required this.httpClient,
    required this.timezoneConverter,
    DateTime Function()? now,
    int defaultPageSize = 100,
  })  : _now = now ?? DateTime.now,
        _defaultPageSize = defaultPageSize;

  final LibroReservationGateway gateway;
  final LibroHttpClient httpClient;
  final LibroTimezoneConverter timezoneConverter;
  final DateTime Function() _now;
  final int _defaultPageSize;

  @override
  String get vendorId => kLibroVendorId;

  @override
  String get displayName => 'Libro Reserve';

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kLibroVendorId,
        displayName: 'Libro Reserve',
        category: IntegrationCategory.reservation,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.autoRegister,
        // Reservations are not "covers" — the covers signal is the
        // POS adapter's responsibility. Set false so the framework
        // does not look for a covers field on the reservation channel.
        coversFieldExposed: false,
        lifecycle: kLibroLifecycleAtShip,
        timestampPolicyDocId: kLibroTimestampPolicyDocId,
      );

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    _requireVendor(command.vendorId);
    final oauthState = command.oauthState;
    if (oauthState == null || oauthState.isEmpty) {
      throw const FormatException('libro connect requires oauthState');
    }
    final credential = VendorCredentialHandle(credentialId: oauthState);
    // The framework resolves venue id from the OAuth callback metadata
    // server-side. Tests inject the venue via the gateway's lookup.
    final venueId = await _resolveVenueIdForConnect(command, credential);
    final webhookSubscriptionId = await httpClient.registerWebhook(
      credential: credential,
      venueId: venueId,
      webhookUrl: _publicWebhookUrlFor(command),
      events: kLibroSubscribedEvents,
    );
    final connectionId = await gateway.persistConnection(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      credential: credential,
      metadata: <String, Object?>{
        'venue_id': venueId,
        'webhook_subscription_id': webhookSubscriptionId,
        'subscribed_events': kLibroSubscribedEvents,
      },
    );
    return ConnectResult(
      connectionId: connectionId,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'venue_id': venueId,
        'webhook_subscription_id': webhookSubscriptionId,
      },
      webhookUrl: _publicWebhookUrlFor(command),
      firstBackfillStarted: true,
    );
  }

  @override
  Future<TestConnectionResult> testConnection(
    TestConnectionCommand command,
  ) async {
    _requireVendor(command.vendorId);
    final stopwatch = Stopwatch()..start();
    final ctx = await _requireConnection(command.operatorId, command.locationId);
    final page = await httpClient.listReservations(
      credential: ctx.credential,
      venueId: ctx.venueId,
      updatedSince: _now().toUtc().subtract(const Duration(days: 7)),
      pageSize: 1,
    );
    stopwatch.stop();
    final sample = page.reservations.isEmpty
        ? <String, Object?>{}
        : _dtoToWireMap(page.reservations.first);
    final mapping = page.reservations.isEmpty
        ? <String, Object?>{}
        : _fieldMappingPreview(
            ctx: ctx,
            dto: page.reservations.first,
          );
    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: mapping,
      elapsedMs: stopwatch.elapsedMilliseconds,
      note: page.reservations.isEmpty
          ? 'No reservations returned in the last 7 days; field mapping '
              'preview is empty. Try the connection again after a '
              'reservation is taken.'
          : null,
    );
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    _requireVendor(command.vendorId);
    final ctx = await _requireConnection(command.operatorId, command.locationId);
    final windowStart = command.windowStart.toUtc();
    final windowEnd = command.windowEnd.toUtc();
    var batches = 0;
    var written = 0;
    var cursor = command.resumeFromCursor;
    var lastModified = windowStart;
    var anyWritten = false;
    while (true) {
      final page = await httpClient.listReservations(
        credential: ctx.credential,
        venueId: ctx.venueId,
        updatedSince: windowStart,
        updatedBefore: windowEnd,
        cursor: cursor,
        pageSize: _defaultPageSize,
      );
      var batchWrites = 0;
      for (final dto in page.reservations) {
        final fact = _materialize(ctx: ctx, dto: dto);
        final passed = await command.sanityHook(
          vendorEventId: dto.id,
          payload: <String, Object?>{
            'opened_at': fact.reservationAt.toIso8601String(),
          },
          isDeliberateBackfill: true,
        );
        if (!passed) continue;
        final outcome = await gateway.upsertReservationFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          connectionId: ctx.connectionId,
          fact: fact,
        );
        if (outcome.wrote) {
          batchWrites++;
          anyWritten = true;
        }
        if (dto.updatedAt.isAfter(lastModified)) {
          lastModified = dto.updatedAt.toUtc();
        }
      }
      batches++;
      written += batchWrites;
      cursor = page.nextCursor;
      // Watermark is recorded AFTER the batch commits — restart-safe.
      await gateway.recordWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        connectionId: ctx.connectionId,
        resource: kLibroReservationsResource,
        cursorToken: cursor,
        lastModifiedSeen: lastModified,
      );
      if (cursor == null || cursor.isEmpty) break;
    }
    if (anyWritten) {
      await gateway.markReservationsLive(
        operatorId: command.operatorId,
        locationId: command.locationId,
        connectionId: ctx.connectionId,
      );
    }
    await gateway.appendSyncLog(
      operatorId: command.operatorId,
      locationId: command.locationId,
      connectionId: ctx.connectionId,
      eventKind: 'poll_success',
      recordsCount: written,
    );
    return BackfillResult(
      batchesCommitted: batches,
      recordsWritten: written,
      cursorToken: cursor ?? '',
      lastModifiedSeen: lastModified,
      completed: true,
    );
  }

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) async {
    _requireVendor(command.vendorId);
    final ctx = await _requireConnection(command.operatorId, command.locationId);
    var cursor = command.cursorToken;
    var lastModified = command.lastModifiedSeen.toUtc();
    var written = 0;
    var dropped = 0;
    while (true) {
      final page = await httpClient.listReservations(
        credential: ctx.credential,
        venueId: ctx.venueId,
        updatedSince: lastModified,
        cursor: cursor,
        pageSize: _defaultPageSize,
      );
      for (final dto in page.reservations) {
        final fact = _materialize(ctx: ctx, dto: dto);
        final passed = await command.sanityHook(
          vendorEventId: dto.id,
          payload: <String, Object?>{
            'opened_at': fact.reservationAt.toIso8601String(),
          },
          isDeliberateBackfill: false,
        );
        if (!passed) {
          dropped++;
          continue;
        }
        final outcome = await gateway.upsertReservationFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          connectionId: ctx.connectionId,
          fact: fact,
        );
        if (outcome.wrote) written++;
        if (dto.updatedAt.isAfter(lastModified)) {
          lastModified = dto.updatedAt.toUtc();
        }
      }
      cursor = page.nextCursor;
      await gateway.recordWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        connectionId: ctx.connectionId,
        resource: kLibroReservationsResource,
        cursorToken: cursor,
        lastModifiedSeen: lastModified,
      );
      if (cursor == null || cursor.isEmpty) break;
    }
    return PollIncrementalResult(
      recordsWritten: written,
      newCursorToken: cursor ?? '',
      newLastModifiedSeen: lastModified,
      sanityDropped: dropped,
    );
  }

  @override
  Future<HandleWebhookResult> handleWebhook(
    HandleWebhookCommand command,
  ) async {
    _requireVendor(command.vendorId);
    // The framework already enforced signature, replay, binding,
    // idempotency, and timestamp sanity (steps 1-4 of dispatch). The
    // adapter writes the canonical fact and returns.
    final ctx = await _requireConnection(command.operatorId, command.locationId);
    final reservationMap = _readReservationFromWebhook(command.payload);
    if (reservationMap == null) {
      // Payload missing the `reservation` envelope. Drop at the
      // boundary; framework records a sync log row.
      return const HandleWebhookResult(recordsWritten: 0);
    }
    final dto = LibroReservationDto.fromMap(reservationMap);
    final fact = _materialize(ctx: ctx, dto: dto);
    final outcome = await gateway.upsertReservationFact(
      operatorId: command.operatorId,
      locationId: command.locationId,
      connectionId: ctx.connectionId,
      fact: fact,
    );
    if (outcome.wrote) {
      await gateway.markReservationsLive(
        operatorId: command.operatorId,
        locationId: command.locationId,
        connectionId: ctx.connectionId,
      );
    }
    return HandleWebhookResult(recordsWritten: outcome.wrote ? 1 : 0);
  }

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    _requireVendor(command.vendorId);
    final ctx = await _requireConnection(command.operatorId, command.locationId);
    var webhookUnregistered = false;
    final subscriptionId = ctx.webhookSubscriptionId;
    if (subscriptionId != null && subscriptionId.isNotEmpty) {
      await httpClient.unregisterWebhook(
        credential: ctx.credential,
        subscriptionId: subscriptionId,
      );
      webhookUnregistered = true;
    }
    await httpClient.revokeCredential(credential: ctx.credential);
    await gateway.wipeCredential(
      operatorId: command.operatorId,
      locationId: command.locationId,
      connectionId: ctx.connectionId,
    );
    await gateway.appendSyncLog(
      operatorId: command.operatorId,
      locationId: command.locationId,
      connectionId: ctx.connectionId,
      eventKind: 'disconnect',
    );
    return DisconnectResult(
      credentialsWiped: true,
      webhookUnregistered: webhookUnregistered,
      // Watermark + canonical facts are preserved per framework
      // contract; reconnect resumes from the persisted cursor.
      watermarkPreserved: true,
    );
  }

  // ─── Internal helpers ─────────────────────────────────────────────

  CanonicalReservationFact _materialize({
    required LibroConnectionContext ctx,
    required LibroReservationDto dto,
  }) {
    final reservationAtUtc = timezoneConverter.wallClockToUtc(
      restaurantTimezone: ctx.restaurantTimezone,
      wallClock: dto.reservationAt,
    );
    final businessDate = timezoneConverter.toBusinessDate(
      restaurantTimezone: ctx.restaurantTimezone,
      businessDayRolloverHour: ctx.businessDayRolloverHour,
      instant: reservationAtUtc,
    );
    final updatedAtUtc = timezoneConverter.wallClockToUtc(
      restaurantTimezone: ctx.restaurantTimezone,
      wallClock: dto.updatedAt,
    );
    return CanonicalReservationFact(
      vendorId: kLibroVendorId,
      vendorEntityId: dto.id,
      vendorModifiedAt: updatedAtUtc,
      reservationAt: reservationAtUtc,
      businessDate: businessDate,
      partySize: dto.size,
      status: _normalizeStatus(dto.status),
      statusTransitions: _buildStatusTransitions(ctx, dto),
      rawPayload: _dtoToWireMap(dto),
    );
  }

  Map<String, DateTime> _buildStatusTransitions(
    LibroConnectionContext ctx,
    LibroReservationDto dto,
  ) {
    final out = <String, DateTime>{};
    void add(String key, DateTime? value) {
      if (value == null) return;
      out[key] = timezoneConverter.wallClockToUtc(
        restaurantTimezone: ctx.restaurantTimezone,
        wallClock: value,
      );
    }

    add('expected', dto.createdAt);
    add('confirmed', dto.confirmedAt);
    add('arrived', dto.arrivedAt);
    add('seated', dto.seatedAt);
    add('completed', dto.completedAt);
    add('canceled', dto.canceledAt);
    return out;
  }

  CanonicalReservationStatus _normalizeStatus(String vendor) {
    switch (vendor.trim().toLowerCase()) {
      case 'pending':
      case 'expected':
      case 'created':
        return CanonicalReservationStatus.expected;
      case 'confirmed':
        return CanonicalReservationStatus.confirmed;
      case 'arrived':
        return CanonicalReservationStatus.arrived;
      case 'seated':
        return CanonicalReservationStatus.seated;
      case 'completed':
      case 'left':
        return CanonicalReservationStatus.completed;
      case 'canceled':
      case 'cancelled':
        return CanonicalReservationStatus.canceled;
      case 'no_show':
      case 'no-show':
      case 'noshow':
        return CanonicalReservationStatus.noShow;
    }
    // Unknown vendor status — treat as `expected` so the dashboard
    // does not invent a state. The framework's sync log records the
    // unknown value via raw_payload for the live slice to triage.
    return CanonicalReservationStatus.expected;
  }

  Map<String, Object?>? _readReservationFromWebhook(
    Map<String, Object?> payload,
  ) {
    final raw = payload['reservation'];
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) return raw.cast<String, Object?>();
    return null;
  }

  Map<String, Object?> _dtoToWireMap(LibroReservationDto dto) {
    return <String, Object?>{
      'id': dto.id,
      'venue_id': dto.venueId,
      'size': dto.size,
      'status': dto.status,
      'reservation_at': dto.reservationAt.toIso8601String(),
      'updated_at': dto.updatedAt.toIso8601String(),
      if (dto.createdAt != null) 'created_at': dto.createdAt!.toIso8601String(),
      if (dto.arrivedAt != null) 'arrived_at': dto.arrivedAt!.toIso8601String(),
      if (dto.confirmedAt != null)
        'confirmed_at': dto.confirmedAt!.toIso8601String(),
      if (dto.seatedAt != null) 'seated_at': dto.seatedAt!.toIso8601String(),
      if (dto.completedAt != null)
        'completed_at': dto.completedAt!.toIso8601String(),
      if (dto.canceledAt != null)
        'canceled_at': dto.canceledAt!.toIso8601String(),
    };
  }

  Map<String, Object?> _fieldMappingPreview({
    required LibroConnectionContext ctx,
    required LibroReservationDto dto,
  }) {
    final fact = _materialize(ctx: ctx, dto: dto);
    return <String, Object?>{
      'vendor_entity_id': fact.vendorEntityId,
      'reservation_at': fact.reservationAt.toIso8601String(),
      'business_date':
          fact.businessDate.toIso8601String().substring(0, 10),
      'party_size': fact.partySize,
      'status': fact.status.name,
      'status_transitions': fact.statusTransitions
          .map((k, v) => MapEntry<String, String>(k, v.toIso8601String())),
    };
  }

  Future<LibroConnectionContext> _requireConnection(
    String operatorId,
    String locationId,
  ) async {
    final ctx = await gateway.lookupConnection(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (ctx == null) {
      throw StateError(
        'libro adapter invoked without a persisted connection for '
        '($operatorId, $locationId)',
      );
    }
    return ctx;
  }

  Future<String> _resolveVenueIdForConnect(
    ConnectCommand command,
    VendorCredentialHandle credential,
  ) async {
    // The framework's OAuth callback handler decodes Libro's token
    // response and surfaces the venue id back to the adapter via the
    // gateway's pre-connect hook. Tests inject a fake gateway whose
    // `lookupConnection` already resolves a candidate; production
    // wires the OAuth callback. Either way, the venue id MUST come
    // from a vendor-side claim, not from operator-supplied input.
    final pre = await gateway.lookupConnection(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (pre != null) return pre.venueId;
    // No prior context — fall back to the framework-issued state
    // token, which carries the venue id once the OAuth callback
    // resolves it. The tests assert the connect path via the
    // gateway's pre-resolved venue.
    return credential.credentialId;
  }

  String _publicWebhookUrlFor(ConnectCommand command) {
    // The actual proxy URL is built by the framework; here we return
    // the canonical shape so the connect result can echo it. Tests
    // assert the suffix matches `(vendorId, operatorId, locationId)`.
    return '/v1/integrations/webhook/$kLibroVendorId/${command.operatorId}/${command.locationId}';
  }

  void _requireVendor(String vendorId) {
    if (vendorId != kLibroVendorId) {
      throw ArgumentError.value(
        vendorId,
        'vendorId',
        'LibroReservationAdapter only accepts vendorId == $kLibroVendorId',
      );
    }
  }
}
