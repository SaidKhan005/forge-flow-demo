// Phase 8R.SR — SevenRooms reservation adapter.
//
// Wave B reservation adapter for the Phase 8 ReservationAdapter
// framework. Engineered against the documented SevenRooms partner API
// surface (https://sevenrooms.com/platform/integrations-apis/ +
// https://api-docs.sevenrooms.com/, retrieved 2026-05-04) at lifecycle
// = `documented`. Live HTTP verification is deferred to the follow-up
// `8R.SR.live.sandbox` and `8R.SR.live.prod` slices when account-rep
// onboarding issues partner credentials (4-8 week lead time per
// `docs/integrations/sevenrooms/partnership_status.md`).
//
// Webhook delivery is `manualPaste`: SevenRooms does NOT publish a
// webhook subscription endpoint, so the adapter does not auto-register
// a subscription on connect. The operator pastes the F&F webhook URL
// into the SevenRooms admin portal (Settings → Integrations) and
// pastes the signing secret SevenRooms generates back into F&F.
//
// Doctrine reference: `docs/contracts/vendor_adapter_slice_contract.md`
// + `docs/contracts/per_vendor_doc_pack_contract.md` + the per-vendor
// pack at `docs/integrations/sevenrooms/`.
//
// Design constraints honored here:
//   * Sanity hook invoked BEFORE every canonical fact write in
//     `backfill` and `pollIncremental`. `handleWebhook` does NOT
//     re-call sanityHook — `InboundWebhookHandler` enforces sanity
//     inline at step 4 of its dispatch sequence.
//   * Idempotency UNIQUE on
//     `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
//     enforced by the gateway repository.
//   * `connector_sync_watermark.cursor_token` + `last_modified_seen`
//     persist after EACH batch commit, not after the whole backfill.
//   * Webhook signature verification lives in
//     `sevenrooms_webhook_signature_verifier.dart` and uses
//     `constantTimeBytesEquals`. Replay tolerance is 24h.
//   * Production gateway impl wraps every fact write inside
//     `OperatorScopedRepository.withTenant(operatorId, locationId, ...)`.
//     Plaintext credentials never reach this file.
//   * Storage rule (Phase 7.55): every persisted timestamp is the UTC
//     source-truth instant + denormalized `business_date` computed via
//     `IanaTimezoneConverter`.
//
// V1 lean cut 2 banned items (`memory/project_v1_lean_cut_2.md`):
// no KMS code path, no webhook key rotation logic, no `parse_warnings`
// JSONB column, no 5-minute strict replay window, no
// `pg_try_advisory_lock`, no SIGTERM drain handler, no DLQ tile mount,
// no raw-payload sibling tables, no 5-second test-connection SLA,
// no 3-strike auto-disable email wiring.

import 'dart:async';

import '../../infrastructure/persistence/postgres/tenant_context.dart';
import '../../services/integration/iana_timezone_converter.dart';
import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/reservation_adapter.dart';

// ─── Documented-API constants (cite source URL + retrieval date) ────

/// Vendor id matching `connector_connection.vendor_id`.
const String kSevenRoomsVendorId = 'sevenrooms';

/// Operator-facing display name used in the Vendor Connections admin
/// surface and operator dashboard chrome.
const String kSevenRoomsDisplayName = 'SevenRooms';

/// Production API base URL.
/// Source: https://api.sevenrooms.com/2_2/auth (auth endpoint
/// confirmed by Airship integration guide
/// https://academy.airship.co.uk/en/articles/12277047 retrieved
/// 2026-05-04).
const String kSevenRoomsProdBaseUrl = 'https://api.sevenrooms.com';

/// Sandbox base URL — SevenRooms does not publish a separate sandbox
/// host in the public documentation. The account-rep onboarding flow
/// issues sandbox credentials that point at the production base URL
/// scoped to a sandbox venue. The `8R.SR.live.sandbox` slice will
/// confirm and amend if a separate host emerges.
const String kSevenRoomsSandboxBaseUrl = 'https://api.sevenrooms.com';

/// Documented API version pinned by the adapter. Embedded in
/// `documented_per_sevenrooms_<api_version>` constants in fixtures so
/// a future shape change is detectable from the diff.
const String kSevenRoomsApiVersion = 'v2_2_2026_05';

// ─── Vendor data shape (canonical -> vendor field reference) ────────
//
// Single source of truth for the field mapping the adapter applies.
// Mirrored row-for-row in:
//   * `docs/integrations/sevenrooms/field_mapping.md`
//   * `test/integrations/reservation/fixtures/sevenrooms_reservations_fixture.dart`
//     `documented_per_sevenrooms_v2_2_2026_05` constant.

/// Vendor field paths the adapter reads from a reservation object
/// returned by `GET /2_2/reservations` and
/// `GET /2_2/reservations/export`.
class SevenRoomsReservationFields {
  const SevenRoomsReservationFields._();

  /// `id` — stable reservation identifier (uuid-style).
  static const String entityId = 'id';

  /// `arrival_time` — ISO-8601 with timezone offset; the booking time
  /// the operator scheduled.
  static const String reservationAt = 'arrival_time';

  /// `party_size` — int.
  static const String partySize = 'party_size';

  /// `status` — vendor enum (BOOKED / ARRIVED / SEATED / COMPLETED /
  /// CANCELLED / NO_SHOW). Mapped to canonical `ReservationStatus` per
  /// `field_mapping.md`.
  static const String status = 'status';

  /// `last_updated_at` — ISO-8601 UTC; vendor modification cursor.
  static const String lastUpdatedAt = 'last_updated_at';

  /// `arrived_time` — per-status transition timestamp (when guest
  /// checked in).
  static const String arrivedTime = 'arrived_time';

  /// `seated_time` — per-status transition timestamp (when guest was
  /// seated).
  static const String seatedTime = 'seated_time';

  /// `departed_time` — per-status transition timestamp.
  static const String departedTime = 'departed_time';

  /// `cancellation_time` — per-status transition timestamp.
  static const String cancellationTime = 'cancellation_time';

  /// `venue_id` — vendor-side venue identifier; matches
  /// `connector_connection.metadata.venue_id` for the binding
  /// cross-check.
  static const String venueId = 'venue_id';
}

/// Canonical reservation status enum the adapter maps SevenRooms
/// vendor status strings to. Mirrors the per-vendor classification in
/// `field_mapping.md`.
enum SevenRoomsCanonicalStatus {
  booked,
  arrived,
  seated,
  completed,
  cancelled,
  noShow,
}

/// Vendor enum → canonical mapping. Documented in `field_mapping.md`.
const Map<String, SevenRoomsCanonicalStatus> kSevenRoomsStatusMap =
    <String, SevenRoomsCanonicalStatus>{
  'BOOKED': SevenRoomsCanonicalStatus.booked,
  'ARRIVED': SevenRoomsCanonicalStatus.arrived,
  'SEATED': SevenRoomsCanonicalStatus.seated,
  'COMPLETED': SevenRoomsCanonicalStatus.completed,
  'CANCELLED': SevenRoomsCanonicalStatus.cancelled,
  'NO_SHOW': SevenRoomsCanonicalStatus.noShow,
};

// ─── Test-double seams ───────────────────────────────────────────────
//
// The adapter consumes four narrow gateways. Production wires
// Postgres-backed implementations that wrap every write in
// `OperatorScopedRepository.withTenant`; tests pass in-memory fakes.
//
// The adapter NEVER opens its own DB connection, NEVER imports
// `package:postgres`, and NEVER touches plaintext credentials.

/// Persistence + binding-lookup surface the adapter drives.
abstract class SevenRoomsReservationGateway {
  Future<SevenRoomsConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
  });

  Future<SevenRoomsDisconnectBinding?> lookupDisconnectBinding({
    required String operatorId,
    required String locationId,
  });

  /// Persist one canonical reservation row. Returns `true` when the
  /// row was inserted; `false` when the idempotency UNIQUE on
  /// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  /// short-circuited the upsert.
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
  });

  Future<void> updateWatermark({
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeenUtc,
  });

  /// Persist a connector_connection row + capture the vendor's
  /// `venue_id` claim in metadata for the binding cross-check. Returns
  /// the new connection id. Webhook subscription id is NOT stored —
  /// SevenRooms uses manualPaste; the operator-paste UI calls a
  /// separate `recordSigningSecret` flow after pasting the secret back
  /// from the SevenRooms portal.
  Future<String> upsertConnection({
    required TenantContext tenant,
    required String vendorVenueId,
    required String accessTokenCredentialId,
  });

  Future<void> appendSyncLog({
    required String connectionId,
    required String eventKind,
    int? recordsCount,
    String? errorMessage,
  });

  Future<void> wipeCredentialsAndDisconnect({
    required TenantContext tenant,
    required String connectionId,
    required DisconnectReason reason,
  });
}

class SevenRoomsConnectionBinding {
  const SevenRoomsConnectionBinding({
    required this.connectionId,
    required this.venueId,
    required this.accessTokenCredentialId,
  });

  final String connectionId;

  /// Vendor `venue_id` claim — matches
  /// `connector_connection.metadata.venue_id`.
  final String venueId;

  /// Opaque credential id for the partner-issued bearer token. The
  /// production gateway resolves it to ciphertext server-side and
  /// never hands the plaintext token to the adapter.
  final String accessTokenCredentialId;
}

class SevenRoomsDisconnectBinding extends SevenRoomsConnectionBinding {
  const SevenRoomsDisconnectBinding({
    required super.connectionId,
    required super.venueId,
    required super.accessTokenCredentialId,
  });
}

/// Auth client — opaque to the adapter. Production hits
/// `POST https://api.sevenrooms.com/2_2/auth` with the
/// account-rep-issued client_id + client_secret + venue_id; tests
/// inject a fake.
abstract class SevenRoomsAuthClient {
  /// Exchange operator-supplied keypaste credentials (client_id /
  /// client_secret) and venue_id for an opaque access-token credential
  /// id the gateway can resolve later.
  Future<SevenRoomsAuthResult> authenticate({
    required String clientId,
    required String clientSecret,
    required String venueId,
  });

  /// Best-effort revoke on disconnect. SevenRooms does not document a
  /// revoke endpoint in the publicly fetched portion of the docs; the
  /// adapter calls this seam so the production impl can hit one if it
  /// emerges from the partner portal. No-op default for sandbox.
  Future<void> revoke({required String accessTokenCredentialId});
}

class SevenRoomsAuthResult {
  const SevenRoomsAuthResult({
    required this.venueId,
    required this.accessTokenCredentialId,
  });

  final String venueId;
  final String accessTokenCredentialId;
}

/// Webhook subscription client. Declared so the adapter test can
/// assert that `connect()` does NOT invoke `subscribe` for manualPaste
/// vendors. The production wiring binds this to a no-op impl because
/// SevenRooms has no auto-register endpoint; the operator pastes the
/// URL into the SevenRooms admin portal manually.
abstract class SevenRoomsWebhookClient {
  /// MUST NOT be called by the adapter for SevenRooms (manualPaste).
  /// The fake test impl records every call so the test can assert the
  /// list is empty after `connect()`.
  Future<void> subscribe({
    required String accessTokenCredentialId,
    required String webhookUrl,
    required String venueId,
  });
}

/// Reservation-pull client. Production hits
/// `GET /2_2/reservations` (incremental poll) and
/// `GET /2_2/reservations/export` (60-day backfill).
abstract class SevenRoomsReservationsClient {
  /// Fetch one reservation page. `cursorToken == null` means "first
  /// page". Pagination is cursor-based.
  Future<SevenRoomsReservationsPage> fetchReservationsPage({
    required String accessTokenCredentialId,
    required String venueId,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required int pageSize,
    required bool useExport,
    String? cursorToken,
  });

  /// One real sample reservation for the test-connection screen so
  /// the operator can eyeball the field mapping.
  Future<Map<String, Object?>> fetchSampleReservation({
    required String accessTokenCredentialId,
    required String venueId,
  });
}

class SevenRoomsReservationsPage {
  const SevenRoomsReservationsPage({
    required this.reservations,
    required this.nextPageToken,
  });

  final List<Map<String, Object?>> reservations;
  final String? nextPageToken;
}

// ─── Adapter ────────────────────────────────────────────────────────

/// SevenRooms reservation adapter.
///
/// Implements every framework seam declared in [ReservationAdapter]
/// against the documented SevenRooms partner API shape. Live HTTP
/// wiring is the `*.live.sandbox` / `*.live.prod` slice's job.
class SevenRoomsReservationAdapter implements ReservationAdapter {
  SevenRoomsReservationAdapter({
    required this.gateway,
    required this.authClient,
    required this.webhookClient,
    required this.reservationsClient,
    required this.restaurantTimezone,
    required this.businessDayRolloverHour,
    required this.webhookUrl,
    int batchPageSize = _kBackfillPageSize,
    DateTime Function()? now,
    IanaTimezoneConverter? converter,
  })  : _now = now ?? DateTime.now,
        _converter = converter ?? IanaTimezoneConverter.shared,
        _batchPageSize = batchPageSize;

  static const int _kBackfillPageSize = 100;

  final SevenRoomsReservationGateway gateway;
  final SevenRoomsAuthClient authClient;

  /// Declared for symmetry with autoRegister adapters; the adapter
  /// MUST NOT call `subscribe` on this client. Tests assert no calls.
  final SevenRoomsWebhookClient webhookClient;

  final SevenRoomsReservationsClient reservationsClient;
  final String restaurantTimezone;
  final int businessDayRolloverHour;

  /// Operator-facing webhook URL. Surfaced in [ConnectResult] so the
  /// admin widget can render it for the operator to paste into the
  /// SevenRooms portal. The adapter never hits a vendor endpoint with
  /// it.
  final String webhookUrl;

  final DateTime Function() _now;
  final IanaTimezoneConverter _converter;
  final int _batchPageSize;

  @override
  String get vendorId => kSevenRoomsVendorId;

  @override
  String get displayName => kSevenRoomsDisplayName;

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kSevenRoomsVendorId,
        displayName: kSevenRoomsDisplayName,
        category: IntegrationCategory.reservation,
        // Per Airship + Kleene integration guides: account-rep issues
        // a client_id + client_secret keypaste; the partner endpoint
        // exchanges them for an access token via OAuth-shape POST.
        // Adapter accepts both surfaces via `oauthOrKeyPaste` so the
        // operator-side UI can display either.
        authMode: VendorAuthMode.oauthOrKeyPaste,
        // Each SevenRooms venue is one F&F location.
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.manualPaste,
        // Reservations: covers field is not_applicable on this
        // category; see `field_mapping.md` Covers source classification.
        coversFieldExposed: false,
        lifecycle: VendorLifecycle.documented,
        modules: <String>[],
        timestampPolicyDocId: 'vendor_timestamp_policy.sevenrooms',
      );

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != vendorId) {
      throw ArgumentError.value(
        command.vendorId,
        'command.vendorId',
        'expected $vendorId',
      );
    }
    final paste = command.keyPaste;
    if (paste == null) {
      throw ArgumentError.value(
        paste,
        'command.keyPaste',
        'SevenRooms uses partner keypaste auth (client_id + client_secret); '
            'oauthState is not used.',
      );
    }
    // SevenRooms' partner credential pack arrives as a triple
    // (client_id, client_secret, venue_id). The framework's keypaste
    // shape carries `apiKey` (client_secret) + `username` (client_id);
    // the venue_id is supplied via the connect-flow UI as a separate
    // field stored in `command.module` for symmetry with
    // module-disambiguating vendors. The production connect route
    // packs it there.
    final clientSecret = paste.apiKey;
    final clientId = paste.username;
    final venueId = command.module;
    if (clientId == null || clientId.isEmpty) {
      throw ArgumentError.value(
        clientId,
        'command.keyPaste.username',
        'client_id required',
      );
    }
    if (venueId == null || venueId.isEmpty) {
      throw ArgumentError.value(
        venueId,
        'command.module',
        'venue_id required (carried in module slot for SevenRooms)',
      );
    }

    final tenant = TenantContext(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
    );

    final auth = await authClient.authenticate(
      clientId: clientId,
      clientSecret: clientSecret,
      venueId: venueId,
    );

    final connectionId = await gateway.upsertConnection(
      tenant: tenant,
      vendorVenueId: auth.venueId,
      accessTokenCredentialId: auth.accessTokenCredentialId,
    );

    // Webhook is manualPaste — DO NOT call webhookClient.subscribe.
    // The operator pastes [webhookUrl] into the SevenRooms admin
    // portal (Settings → Integrations) and pastes the signing secret
    // SevenRooms generates back into F&F via a separate confirm flow.

    await gateway.appendSyncLog(
      connectionId: connectionId,
      eventKind: 'connect',
    );

    return ConnectResult(
      connectionId: connectionId,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'venue_id': auth.venueId,
        'webhook_state': 'pending_paste',
      },
      webhookUrl: webhookUrl,
      firstBackfillStarted: true,
    );
  }

  @override
  Future<TestConnectionResult> testConnection(
    TestConnectionCommand command,
  ) async {
    final stopwatch = Stopwatch()..start();
    final binding = await _requireBinding(command.operatorId, command.locationId);
    final sample = await reservationsClient.fetchSampleReservation(
      accessTokenCredentialId: binding.accessTokenCredentialId,
      venueId: binding.venueId,
    );
    stopwatch.stop();

    final mapping = _projectFieldMapping(sample);

    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: mapping,
      elapsedMs: stopwatch.elapsedMilliseconds,
      note: 'Covers source: not_applicable (reservation category).',
    );
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final tenant = TenantContext(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
    );
    final binding = await _requireBinding(command.operatorId, command.locationId);

    var batchesCommitted = 0;
    var recordsWritten = 0;
    String cursor = command.resumeFromCursor ?? '';
    var lastModifiedSeen = command.windowStart;

    while (true) {
      final page = await reservationsClient.fetchReservationsPage(
        accessTokenCredentialId: binding.accessTokenCredentialId,
        venueId: binding.venueId,
        windowStartUtc: command.windowStart,
        windowEndUtc: command.windowEnd,
        pageSize: _batchPageSize,
        useExport: true,
        cursorToken: cursor,
      );

      for (final reservation in page.reservations) {
        final mapped = _projectCanonicalRecord(reservation);
        if (mapped == null) {
          await gateway.appendSyncLog(
            connectionId: binding.connectionId,
            eventKind: 'parse_drop',
            errorMessage:
                'reservation payload missing required field; dropped at '
                'adapter boundary',
          );
          continue;
        }
        final ok = await command.sanityHook(
          vendorEventId: mapped.vendorEntityId,
          payload: mapped.sanityPayload,
          isDeliberateBackfill: true,
        );
        if (!ok) {
          continue;
        }
        final inserted = await gateway.writeReservationFact(
          tenant: tenant,
          connectionId: binding.connectionId,
          vendorEntityId: mapped.vendorEntityId,
          reservationAtUtc: mapped.reservationAtUtc,
          partySize: mapped.partySize,
          status: mapped.status,
          statusTransitions: mapped.statusTransitions,
          restaurantTimezone: restaurantTimezone,
          businessDayRolloverHour: businessDayRolloverHour,
          vendorModifiedAtUtc: mapped.vendorModifiedAtUtc,
        );
        if (inserted) recordsWritten += 1;
        if (mapped.vendorModifiedAtUtc.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = mapped.vendorModifiedAtUtc;
        }
      }

      cursor = page.nextPageToken ?? cursor;
      await gateway.updateWatermark(
        connectionId: binding.connectionId,
        cursorToken: cursor,
        lastModifiedSeenUtc: lastModifiedSeen,
      );
      batchesCommitted += 1;

      if (page.nextPageToken == null) break;
    }

    return BackfillResult(
      batchesCommitted: batchesCommitted,
      recordsWritten: recordsWritten,
      cursorToken: cursor,
      lastModifiedSeen: lastModifiedSeen,
      completed: true,
    );
  }

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) async {
    final tenant = TenantContext(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
    );
    final binding = await _requireBinding(command.operatorId, command.locationId);

    var recordsWritten = 0;
    var sanityDropped = 0;
    String cursor = command.cursorToken ?? '';
    var lastModifiedSeen = command.lastModifiedSeen;
    final tickEnd = _now().toUtc();

    while (true) {
      final page = await reservationsClient.fetchReservationsPage(
        accessTokenCredentialId: binding.accessTokenCredentialId,
        venueId: binding.venueId,
        windowStartUtc: command.lastModifiedSeen,
        windowEndUtc: tickEnd,
        pageSize: _batchPageSize,
        useExport: false,
        cursorToken: cursor,
      );

      for (final reservation in page.reservations) {
        final mapped = _projectCanonicalRecord(reservation);
        if (mapped == null) {
          await gateway.appendSyncLog(
            connectionId: binding.connectionId,
            eventKind: 'parse_drop',
            errorMessage:
                'reservation payload missing required field; dropped at '
                'adapter boundary',
          );
          continue;
        }
        final ok = await command.sanityHook(
          vendorEventId: mapped.vendorEntityId,
          payload: mapped.sanityPayload,
          isDeliberateBackfill: false,
        );
        if (!ok) {
          sanityDropped += 1;
          continue;
        }
        final inserted = await gateway.writeReservationFact(
          tenant: tenant,
          connectionId: binding.connectionId,
          vendorEntityId: mapped.vendorEntityId,
          reservationAtUtc: mapped.reservationAtUtc,
          partySize: mapped.partySize,
          status: mapped.status,
          statusTransitions: mapped.statusTransitions,
          restaurantTimezone: restaurantTimezone,
          businessDayRolloverHour: businessDayRolloverHour,
          vendorModifiedAtUtc: mapped.vendorModifiedAtUtc,
        );
        if (inserted) recordsWritten += 1;
        if (mapped.vendorModifiedAtUtc.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = mapped.vendorModifiedAtUtc;
        }
      }

      cursor = page.nextPageToken ?? cursor;
      await gateway.updateWatermark(
        connectionId: binding.connectionId,
        cursorToken: cursor,
        lastModifiedSeenUtc: lastModifiedSeen,
      );

      if (page.nextPageToken == null) break;
    }

    return PollIncrementalResult(
      recordsWritten: recordsWritten,
      newCursorToken: cursor,
      newLastModifiedSeen: lastModifiedSeen,
      sanityDropped: sanityDropped,
    );
  }

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async {
    // The framework already verified signature, replay window,
    // binding, and idempotency BEFORE this call. Sanity is enforced
    // inline at step 4 — do NOT re-call sanityHook here.
    final tenant = TenantContext(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    final binding = await _requireBinding(command.operatorId, command.locationId);
    final mapped = _projectCanonicalRecord(command.payload);
    if (mapped == null) {
      return const HandleWebhookResult(recordsWritten: 0);
    }
    final inserted = await gateway.writeReservationFact(
      tenant: tenant,
      connectionId: binding.connectionId,
      vendorEntityId: mapped.vendorEntityId,
      reservationAtUtc: mapped.reservationAtUtc,
      partySize: mapped.partySize,
      status: mapped.status,
      statusTransitions: mapped.statusTransitions,
      restaurantTimezone: restaurantTimezone,
      businessDayRolloverHour: businessDayRolloverHour,
      vendorModifiedAtUtc: mapped.vendorModifiedAtUtc,
    );
    return HandleWebhookResult(recordsWritten: inserted ? 1 : 0);
  }

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    final tenant = TenantContext(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
    );
    final binding = await gateway.lookupDisconnectBinding(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (binding == null) {
      return const DisconnectResult(
        credentialsWiped: false,
        webhookUnregistered: false,
        watermarkPreserved: true,
      );
    }

    // SevenRooms uses manualPaste — there is no auto-register webhook
    // subscription to tear down. The operator removes the F&F webhook
    // URL from the SevenRooms admin portal manually. The disconnect
    // result reflects this by returning `webhookUnregistered: false`
    // (no programmatic unregister occurred).

    try {
      await authClient.revoke(
        accessTokenCredentialId: binding.accessTokenCredentialId,
      );
    } catch (_) {
      // Best-effort revoke; vendor outage shouldn't block disconnect.
    }

    await gateway.wipeCredentialsAndDisconnect(
      tenant: tenant,
      connectionId: binding.connectionId,
      reason: command.reason,
    );
    await gateway.appendSyncLog(
      connectionId: binding.connectionId,
      eventKind: 'disconnect',
      errorMessage: command.reason.name,
    );

    return const DisconnectResult(
      credentialsWiped: true,
      webhookUnregistered: false,
      watermarkPreserved: true,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<SevenRoomsConnectionBinding> _requireBinding(
    String operatorId,
    String locationId,
  ) async {
    final binding = await gateway.lookupBinding(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (binding == null) {
      throw StateError(
        'no SevenRooms connection on file for '
        '(operator=$operatorId, location=$locationId); the framework '
        'should have refused the request before reaching the adapter.',
      );
    }
    return binding;
  }

  Map<String, Object?> _projectFieldMapping(Map<String, Object?> sample) {
    final mapped = _projectCanonicalRecord(sample);
    if (mapped == null) {
      return const <String, Object?>{
        'reservation_at': null,
        'party_size': null,
        'status': null,
        'note': 'sample missing required fields',
      };
    }
    return <String, Object?>{
      'reservation_at': mapped.reservationAtUtc.toIso8601String(),
      'party_size': mapped.partySize,
      'status': mapped.status.name,
      'vendor_entity_id': mapped.vendorEntityId,
      'vendor_modified_at': mapped.vendorModifiedAtUtc.toIso8601String(),
      'status_transitions': mapped.statusTransitions.map(
        (key, value) => MapEntry(key, value.toIso8601String()),
      ),
    };
  }

  /// Map one SevenRooms reservation to a canonical record. Returns
  /// null when the payload is missing required fields.
  _CanonicalReservation? _projectCanonicalRecord(
    Map<String, Object?> reservation,
  ) {
    final entityId = reservation[SevenRoomsReservationFields.entityId];
    final reservationAtRaw =
        reservation[SevenRoomsReservationFields.reservationAt];
    final partySizeRaw = reservation[SevenRoomsReservationFields.partySize];
    final statusRaw = reservation[SevenRoomsReservationFields.status];
    final updatedRaw = reservation[SevenRoomsReservationFields.lastUpdatedAt];

    if (entityId is! String || entityId.isEmpty) return null;
    if (reservationAtRaw is! String) return null;
    final reservationAt = DateTime.tryParse(reservationAtRaw)?.toUtc();
    if (reservationAt == null) return null;
    if (partySizeRaw is! num) return null;
    if (statusRaw is! String) return null;
    final canonicalStatus = kSevenRoomsStatusMap[statusRaw];
    if (canonicalStatus == null) return null;

    DateTime modified;
    if (updatedRaw is String) {
      modified = DateTime.tryParse(updatedRaw)?.toUtc() ?? reservationAt;
    } else {
      modified = reservationAt;
    }

    final transitions = <String, DateTime>{};
    void capture(String field, String key) {
      final raw = reservation[field];
      if (raw is String) {
        final parsed = DateTime.tryParse(raw)?.toUtc();
        if (parsed != null) transitions[key] = parsed;
      }
    }

    capture(SevenRoomsReservationFields.arrivedTime, 'arrived');
    capture(SevenRoomsReservationFields.seatedTime, 'seated');
    capture(SevenRoomsReservationFields.departedTime, 'departed');
    capture(SevenRoomsReservationFields.cancellationTime, 'cancelled');

    // Validate the IANA timezone projection — a misconfigured
    // location surfaces here rather than at the gateway write
    // boundary.
    _converter.toBusinessDate(
      restaurantTimezone: restaurantTimezone,
      businessDayRolloverHour: businessDayRolloverHour,
      instant: reservationAt,
    );

    return _CanonicalReservation(
      vendorEntityId: entityId,
      reservationAtUtc: reservationAt,
      partySize: partySizeRaw.round(),
      status: canonicalStatus,
      statusTransitions: transitions,
      vendorModifiedAtUtc: modified,
    );
  }
}

class _CanonicalReservation {
  const _CanonicalReservation({
    required this.vendorEntityId,
    required this.reservationAtUtc,
    required this.partySize,
    required this.status,
    required this.statusTransitions,
    required this.vendorModifiedAtUtc,
  });

  final String vendorEntityId;
  final DateTime reservationAtUtc;
  final int partySize;
  final SevenRoomsCanonicalStatus status;
  final Map<String, DateTime> statusTransitions;
  final DateTime vendorModifiedAtUtc;

  Map<String, Object?> get sanityPayload => <String, Object?>{
        'reservation_at': reservationAtUtc.toIso8601String(),
        'party_size': partySize,
        'status': status.name,
      };
}
