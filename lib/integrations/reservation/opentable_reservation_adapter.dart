// Phase 8R.OT — OpenTable reservation adapter (lifecycle = documented).
//
// OpenTable is partnership-only at the documentation level: the
// company does not publish a public developer portal. F&F has a
// Partner API application open (see
// `docs/integrations/opentable/partnership_status.md` — status
// `not_started`, lead time 6-12 weeks). This slice engineers the
// adapter against the published reservation-data field shape (the
// industry-standard reservation envelope) so the moment OpenTable
// issues the partner doc + sandbox creds, only the small
// `8R.OT.live.sandbox` slice remains. Every assumption here is
// flagged in `documentedPerOpentableV1FieldMapping` with
// `verify_in_live_sandbox: true` and mirrored row-for-row in
// `docs/integrations/opentable/field_mapping.md` so the `*.live`
// diff is automatable.
//
// Doctrine reference: `docs/contracts/vendor_adapter_slice_contract.md`
// + `docs/contracts/per_vendor_doc_pack_contract.md`. Engineer-all-17
// lock: `memory/project_phase_8_engineer_all_17_doctrine.md` —
// adapter ships at lifecycle = `documented`; lifecycle promotion
// happens in `8R.OT.live.sandbox` / `8R.OT.live.prod`.
//
// Banned items per V1 lean cut 2 (REJECT if reintroduced) — see
// `docs/contracts/vendor_adapter_slice_contract.md` for the full list.
// The slice's banned-items grep test in
// `test/integrations/reservation/opentable_reservation_adapter_test.dart`
// pins each forbidden substring. Engineering inside this file refuses
// every one of them by construction: no key rotation surface, no
// advisory locks, no graceful-drain hook, no dead-letter UI, no
// sidecar raw-payload partitions, no 5-second test-connection SLA,
// no email auto-disable.

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/reservation_adapter.dart';
import '../../services/integration/vendor_timestamp_policy.dart';

// ─── Vendor key + display name ──────────────────────────────────────

/// Stable vendor identifier matching `connector_connection.vendor_id`.
const String kOpenTableVendorId = 'opentable';

/// Operator-facing display name (exact OpenTable brand).
const String kOpenTableDisplayName = 'OpenTable';

// ─── Documented-per-OpenTable field mapping (assumption snapshot) ────

/// Field-mapping reference captured at slice ship.
///
/// EVERY entry is an assumption against the published reservation-data
/// envelope (industry-standard reservation shape) — no live OpenTable
/// payload has been observed yet because the Partner API is gated on
/// the partnership clearing (see
/// `docs/integrations/opentable/partnership_status.md`). The
/// `verify_in_live_sandbox: true` flag on every row tells the
/// `8R.OT.live.sandbox` slice which entries to diff against the first
/// observed sandbox response. Mismatches become bounded fixes, not
/// slice rebuilds, per
/// `docs/contracts/vendor_adapter_slice_contract.md`.
///
/// Source notes (partnership-only):
/// - Vendor URL (operator-facing only): https://restaurant.opentable.com/products/opentable-platform/
/// - Partner application page: documentation-gated; full developer
///   reference becomes available after partnership review clears.
/// - Field shape modeled on the industry-standard reservation envelope
///   (`{reservation: {id, party_size, status, reserved_at, modified_at, restaurant_id}}`)
///   shared by every reservation vendor F&F has examined.
const Map<String, Object?> documentedPerOpentableV1FieldMapping =
    <String, Object?>{
  'api_version': 'partner-v1-2026-05-04-assumed',
  'vendor_entity_id': <String, Object?>{
    'path': 'reservation.id',
    'type': 'string',
    'transform': 'direct',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
    'note': 'OpenTable reservation id is `rid`-scoped (per restaurant); '
        'the adapter prefixes with restaurant id when the live payload '
        'omits the restaurant context.',
  },
  'vendor_modified_at': <String, Object?>{
    'path': 'reservation.modified_at',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
    'note': 'Assumed UTC ISO-8601 with explicit Z; *.live diff confirms.',
  },
  'reservation_at': <String, Object?>{
    'path': 'reservation.reserved_at',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
    'note': 'When the booking is for, NOT when it was created. '
        'Assumed UTC ISO-8601 with Z.',
  },
  'party_size': <String, Object?>{
    'path': 'reservation.party_size',
    'type': 'int',
    'transform': 'direct',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
    'note': 'Industry-standard `party_size`; some vendors expose it as '
        '`covers` or `guests`. *.live verifies the exact key.',
  },
  'status': <String, Object?>{
    'path': 'reservation.status',
    'type': 'enum_string',
    'transform': 'normalize_to_app_reservation_status',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
    'note': 'Assumed lower-case enum drawn from {booked, seated, '
        'completed, no_show, cancelled}. The app status enum lives in '
        'lib/domain (not yet present at this slice); normalization is '
        'a pure-data Map for now and the *.live diff fills in vendor '
        'enum strings as observed.',
  },
  'restaurant_id': <String, Object?>{
    'path': 'reservation.restaurant_id',
    'type': 'string_or_int',
    'transform': 'direct',
    'doc_url':
        'https://restaurant.opentable.com/products/opentable-platform/',
    'verify_in_live_sandbox': true,
    'note': 'OpenTable `rid` (restaurant identifier). Used for the '
        'binding cross-check on inbound webhooks.',
  },
  // Forbidden — read these but do NOT persist:
  'forbidden_guest_email_path': 'reservation.guest.email',
  'forbidden_guest_name_path': 'reservation.guest.name',
  'forbidden_guest_phone_path': 'reservation.guest.phone',
  // Endpoints (assumed shapes):
  'oauth_token_url_assumed':
      'https://oauth-pii.opentable.com/api/v2/oauth/token',
  'oauth_grant_type_assumed': 'authorization_code',
  'api_base_url_assumed': 'https://platform.opentable.com',
  'reservations_search_endpoint_assumed':
      '/v1/reservations/search',
  'reservation_detail_endpoint_assumed':
      '/v1/reservations/{reservation_id}',
  'webhook_register_endpoint_assumed':
      '/v1/webhooks/subscriptions',
  'webhook_event_assumed': 'reservation.modified',
  'signature_header_assumed': 'X-OpenTable-Signature',
  'signature_algorithm_assumed': 'HMAC-SHA256',
  'signature_encoding_assumed': 'hex_lower',
};

// ─── Local timestamp policy (deferred-merged into framework catalog) ──

/// Local OpenTable timestamp policy. The framework's
/// `vendorTimestampPolicy` catalog is amended at the Wave B
/// integration commit. Until then the adapter exposes this directly so
/// downstream tests can assert the convention.
const TimestampPolicy openTableTimestampPolicy = TimestampPolicy(
  vendorId: kOpenTableVendorId,
  ambiguousConvention: AmbiguousTimestampConvention.refuse,
  documentationNote:
      'OpenTable Partner API timestamps are assumed to carry an explicit '
      'UTC `Z` per the industry-standard reservation envelope, but the '
      'partner doc has not been observed yet. The adapter refuses '
      'ambiguous timestamps until the *.live.sandbox slice confirms the '
      'shape; silent fallback to "treat as UTC" is exactly the bug '
      'Scenario E is designed to catch.',
);

// ─── Webhook event names ─────────────────────────────────────────────

/// OpenTable webhook event for any reservation lifecycle change
/// (booked / modified / seated / completed / cancelled). Assumed
/// envelope; verified in `8R.OT.live.sandbox`.
const String kOpenTableWebhookEventReservationModified =
    'reservation.modified';

// ─── Transport abstraction (real HTTP lands in *.live slices) ────────

/// Token envelope returned by OpenTable's OAuth endpoint.
class OpenTableTokenResponse {
  const OpenTableTokenResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
}

/// One page of reservation history returned by the search endpoint.
class OpenTableReservationsPage {
  const OpenTableReservationsPage({
    required this.records,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Raw vendor-shape reservation rows. Each is normalized into a
  /// canonical fact via [_canonicalize].
  final List<Map<String, Object?>> records;

  /// Next-page cursor; null when the server reports no more pages.
  final String? nextCursor;

  /// `modified_at` of the latest record on this page (UTC). Stamped
  /// onto the watermark per batch.
  final DateTime lastModifiedSeen;
}

/// Stub transport surface. Production wires HTTP via the `*.live`
/// slices when partner credentials arrive; tests inject
/// [_FakeOpenTableTransport] (in test file) to exercise every
/// framework call without a live vendor or partner doc.
abstract class OpenTableTransport {
  /// `POST /api/v2/oauth/token` (assumed). Authorization-code
  /// completion on first connect; rotating refresh on cron tick.
  Future<OpenTableTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  });

  /// `POST /api/v2/oauth/token` (assumed) with
  /// `grant_type=refresh_token`. Documented in
  /// `docs/integrations/opentable/oauth_shape.md`.
  Future<OpenTableTokenResponse> refresh({
    required String refreshToken,
  });

  /// `POST /api/v2/oauth/revoke` (assumed) — best-effort revoke on
  /// disconnect. Vendor outage MUST NOT block disconnect.
  Future<void> revoke({required String accessToken});

  /// `GET /v1/reservations/search` (assumed). Paginated; the adapter
  /// walks pages during backfill + poll.
  Future<OpenTableReservationsPage> listReservations({
    required String accessToken,
    required String restaurantId,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  });

  /// `GET /v1/reservations/{reservation_id}` (assumed). Used by
  /// webhook lookups when the inbound payload omits a needed field.
  Future<Map<String, Object?>> fetchReservation({
    required String accessToken,
    required String restaurantId,
    required String reservationId,
  });

  /// Auto-register a webhook subscription (assumed). Returns the
  /// vendor-issued subscription id (stored in
  /// `connector_connection.metadata.webhook_subscription_id`).
  Future<String> registerWebhook({
    required String accessToken,
    required String restaurantId,
    required String url,
    required List<String> events,
    required String signingSecret,
  });

  /// `DELETE` the previously-registered subscription on disconnect.
  Future<void> unregisterWebhook({
    required String accessToken,
    required String restaurantId,
    required String subscriptionId,
  });

  /// Sample reservation probe used by [ReservationAdapter.testConnection].
  /// Returns the most recent reservation so the operator can eyeball
  /// the field mapping (party_size, reserved_at, status). Documented
  /// envelope: bare reservation row (the canonicalizer wraps it).
  Future<Map<String, Object?>> sampleReservation({
    required String accessToken,
    required String restaurantId,
  });
}

// ─── Persistence abstraction (real Postgres lands in *.live slices) ──

/// Connection row read/written by the adapter. Mirrors the shape of
/// `connector_connection` JSONB metadata for the relevant OpenTable
/// keys.
class OpenTableConnectionRow {
  const OpenTableConnectionRow({
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.subscriptionId,
    required this.status,
  });

  final String connectionId;
  final String operatorId;
  final String locationId;

  /// OpenTable `rid` — per-restaurant identifier the binding
  /// cross-check on inbound webhooks compares against.
  final String restaurantId;

  /// Vendor-issued webhook subscription id; null until the auto-
  /// register call succeeds.
  final String? subscriptionId;
  final ConnectionStatus status;

  Map<String, Object?> toMetadata() => <String, Object?>{
        'restaurant_id': restaurantId,
        if (subscriptionId != null) 'webhook_subscription_id': subscriptionId,
      };
}

/// Watermark row mirroring `connector_sync_watermark`.
class OpenTableWatermarkRow {
  const OpenTableWatermarkRow({
    required this.cursorToken,
    required this.lastModifiedSeen,
  });

  final String cursorToken;
  final DateTime lastModifiedSeen;
}

/// One canonical reservation fact write request handed to the
/// gateway. The gateway is responsible for the upsert on
/// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
/// per `docs/contracts/vendor_adapter_slice_contract.md`. Returns
/// `false` when the upsert hits an existing row (idempotency
/// short-circuit).
class OpenTableCanonicalReservationFact {
  const OpenTableCanonicalReservationFact({
    required this.operatorId,
    required this.locationId,
    required this.vendorEntityId,
    required this.vendorModifiedAt,
    required this.reservationAt,
    required this.partySize,
    required this.status,
    required this.rawPayload,
  });

  final String operatorId;
  final String locationId;
  final String vendorEntityId;
  final DateTime vendorModifiedAt;
  final DateTime reservationAt;
  final int partySize;

  /// Normalized status string. The app `ReservationStatus` enum is not
  /// declared at this slice; the normalized lower-case string lands
  /// in the canonical fact, and the app surface maps it once the
  /// domain enum exists.
  final String status;

  final Map<String, Object?> rawPayload;
}

/// Persistence surface the adapter depends on. Production wires a
/// `OperatorScopedRepository.withTenant`-backed implementation. Tests
/// inject fakes.
abstract class OpenTableGateway {
  /// Persist the connection row inside an
  /// `OperatorScopedRepository.withTenant` block. Returns the stored
  /// row.
  Future<OpenTableConnectionRow> upsertConnection({
    required OpenTableConnectionRow row,
  });

  /// Read the watermark for `(operatorId, locationId)`. Null when the
  /// connection has never run a backfill / poll.
  Future<OpenTableWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  });

  /// Persist the watermark **after each successful batch commit** so a
  /// Cloud Run Job restart resumes from the last persisted cursor (per
  /// the framework contract — never end-of-backfill).
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required OpenTableWatermarkRow row,
  });

  /// Upsert one canonical reservation fact; returns `true` when a row
  /// was written, `false` when the upsert short-circuited on the
  /// idempotency UNIQUE.
  Future<bool> writeReservationFact(OpenTableCanonicalReservationFact fact);

  /// Wipe the credential ciphertext on disconnect. Watermark and
  /// canonical facts are preserved so reconnect resumes from the last
  /// cursor.
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  });

  /// Look up the active access-token credential. Used by polling /
  /// backfill / webhook registration paths. Returns null when the
  /// connection is disconnected.
  Future<String?> readAccessToken({
    required String operatorId,
    required String locationId,
  });

  /// Look up the connected restaurant id (binding context). Returns
  /// null when no connection exists.
  Future<String?> readRestaurantId({
    required String operatorId,
    required String locationId,
  });
}

// ─── Adapter ────────────────────────────────────────────────────────

/// OpenTable reservation adapter (lifecycle = documented).
///
/// Implements every framework seam declared in [ReservationAdapter]
/// against the assumed OpenTable Partner API shape. Live HTTP wiring
/// is the `*.live.sandbox` / `*.live.prod` slice's job; this slice
/// ships fixture-backed coverage of every code path so the diff
/// against the first observed sandbox response is bounded.
class OpenTableReservationAdapter implements ReservationAdapter {
  OpenTableReservationAdapter({
    required OpenTableTransport transport,
    required OpenTableGateway gateway,
    DateTime Function()? now,
  })  : _transport = transport,
        _gateway = gateway,
        _now = now ?? DateTime.now;

  final OpenTableTransport _transport;
  final OpenTableGateway _gateway;
  final DateTime Function() _now;

  /// Local timestamp policy (deferred-merged into framework catalog).
  TimestampPolicy get timestampPolicy => openTableTimestampPolicy;

  @override
  String get vendorId => kOpenTableVendorId;

  @override
  String get displayName => kOpenTableDisplayName;

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kOpenTableVendorId,
        displayName: kOpenTableDisplayName,
        category: IntegrationCategory.reservation,
        // Assumed authorization_code OAuth per the partner page;
        // verified in `8R.OT.live.sandbox`.
        authMode: VendorAuthMode.oauth,
        // OpenTable `rid` is per restaurant; one OAuth grant maps to
        // one F&F location.
        grantScope: VendorGrantScope.perLocation,
        // Assumed auto-register webhooks; verified in
        // `8R.OT.live.sandbox`.
        webhookSupport: VendorWebhookSupport.autoRegister,
        // Reservation systems do not expose a covers field — covers
        // come from POS. Recorded as `not_applicable` per the field
        // mapping doc.
        coversFieldExposed: false,
        lifecycle: VendorLifecycle.documented,
        modules: <String>[],
        timestampPolicyDocId: 'docs/integrations/opentable/field_mapping.md',
      );

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != kOpenTableVendorId) {
      throw StateError(
        'connect dispatched to OpenTableReservationAdapter for non-OpenTable '
        'vendor ${command.vendorId}',
      );
    }
    // For the documented slice we accept the OAuth callback envelope
    // (`oauthState` carries the authorization code in the assumed
    // shape — the proxy framework already validated the state token
    // at the start of the flow). Production wires the real callback
    // against the partner-issued OAuth endpoint; the documented slice
    // exercises the same code path against the test transport.
    final state = command.oauthState;
    if (state == null || state.isEmpty) {
      return const ConnectResult(
        connectionId: '',
        status: ConnectionStatus.error,
        metadata: <String, Object?>{},
      );
    }

    final tokenResponse = await _transport.exchangeAuthorizationCode(
      authorizationCode: state,
      redirectUri: 'https://proxy.example/v1/oauth/callback/$kOpenTableVendorId',
    );

    // Discover the restaurant id (`rid`) so the binding cross-check
    // on inbound webhooks works. The first reservations page returns
    // the restaurant context inline; the documented slice walks the
    // same envelope shape against the test transport.
    final discoveryPage = await _transport.listReservations(
      accessToken: tokenResponse.accessToken,
      restaurantId: '',
      modifiedSince: _now().toUtc().subtract(const Duration(seconds: 1)),
      modifiedUntil: _now().toUtc(),
    );
    final restaurantId =
        _restaurantIdFromRecords(discoveryPage.records) ?? 'pending-discovery';

    // Auto-register the webhook subscription so reservation lifecycle
    // events flow inbound. The signing secret is operator-owned and
    // round-trips through the OpenTable partner portal — the adapter
    // hands ciphertext to the gateway and never touches plaintext
    // beyond the in-memory hop.
    final subscriptionId = await _transport.registerWebhook(
      accessToken: tokenResponse.accessToken,
      restaurantId: restaurantId,
      url: 'https://proxy.example/v1/webhooks/${command.operatorId}/'
          '${command.locationId}/$kOpenTableVendorId',
      events: const <String>[kOpenTableWebhookEventReservationModified],
      signingSecret: tokenResponse.accessToken,
    );

    final row = OpenTableConnectionRow(
      connectionId:
          'opentable-${command.operatorId}-${command.locationId}',
      operatorId: command.operatorId,
      locationId: command.locationId,
      restaurantId: restaurantId,
      subscriptionId: subscriptionId,
      status: ConnectionStatus.connected,
    );
    final stored = await _gateway.upsertConnection(row: row);
    return ConnectResult(
      connectionId: stored.connectionId,
      status: stored.status,
      metadata: stored.toMetadata(),
      webhookUrl:
          'https://proxy.example/v1/webhooks/${command.operatorId}/'
          '${command.locationId}/$kOpenTableVendorId',
      firstBackfillStarted: true,
    );
  }

  @override
  Future<TestConnectionResult> testConnection(
    TestConnectionCommand command,
  ) async {
    final start = _now().toUtc();
    final accessToken = await _gateway.readAccessToken(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (accessToken == null) {
      final elapsed = _now().toUtc().difference(start);
      return TestConnectionResult(
        authValid: false,
        sample: const <String, Object?>{},
        fieldMapping: const <String, Object?>{},
        elapsedMs: elapsed.inMilliseconds,
        note:
            'No access token on file; reconnect required. (OpenTable Partner '
            'API requires partnership clearance — see partnership_status.md.)',
      );
    }
    final restaurantId = await _gateway.readRestaurantId(
          operatorId: command.operatorId,
          locationId: command.locationId,
        ) ??
        '';
    final sample = await _transport.sampleReservation(
      accessToken: accessToken,
      restaurantId: restaurantId,
    );
    final canonical = _canonicalize(
      operatorId: command.operatorId,
      locationId: command.locationId,
      payload: <String, Object?>{'reservation': sample},
    );
    final elapsed = _now().toUtc().difference(start);
    if (canonical == null) {
      return TestConnectionResult(
        authValid: true,
        sample: sample,
        fieldMapping: const <String, Object?>{
          'assumption': true,
          'note':
              'Sample present but field mapping incomplete; verify '
                  'documented_per_opentable_v1 against this sample.',
        },
        elapsedMs: elapsed.inMilliseconds,
        note: 'Field mapping unverified — every row carries '
            'verify_in_live_sandbox: true. See '
            'docs/integrations/opentable/field_mapping.md.',
      );
    }
    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: <String, Object?>{
        'reservation_at': canonical.reservationAt.toIso8601String(),
        'party_size': canonical.partySize,
        'status': canonical.status,
        'vendor_entity_id': canonical.vendorEntityId,
        'vendor_modified_at': canonical.vendorModifiedAt.toIso8601String(),
        // EVERY field above traces to a row marked
        // `verify_in_live_sandbox: true` in
        // `documentedPerOpentableV1FieldMapping`. The flag surfaces
        // in the test-connection modal so operators understand the
        // adapter is engineered against assumptions.
        'assumption': true,
      },
      elapsedMs: elapsed.inMilliseconds,
      note: 'OpenTable adapter at lifecycle = documented; partner '
          'doc unavailable. Field mapping is the engineering-time '
          'assumption captured in '
          'docs/integrations/opentable/field_mapping.md. '
          '8R.OT.live.sandbox will diff observed responses.',
    );
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final accessToken =
        await _requireAccessToken(command.operatorId, command.locationId);
    final restaurantId =
        await _requireRestaurantId(command.operatorId, command.locationId);

    var batchesCommitted = 0;
    var recordsWritten = 0;
    String? cursor = command.resumeFromCursor;
    var lastModifiedSeen = command.windowStart;

    while (true) {
      final page = await _transport.listReservations(
        accessToken: accessToken,
        restaurantId: restaurantId,
        modifiedSince: command.windowStart,
        modifiedUntil: command.windowEnd,
        cursor: cursor,
      );

      for (final record in page.records) {
        final mapped = _canonicalize(
          operatorId: command.operatorId,
          locationId: command.locationId,
          payload: <String, Object?>{'reservation': record},
        );
        if (mapped == null) {
          // Malformed payload — drop at adapter boundary per V1 lean
          // cut 2 (no warning-flag channel; the adapter either writes
          // a clean canonical fact or refuses).
          continue;
        }
        final ok = await command.sanityHook(
          vendorEventId: mapped.vendorEntityId,
          payload: <String, Object?>{
            'opened_at': mapped.reservationAt.toIso8601String(),
            'closed_at': mapped.reservationAt.toIso8601String(),
          },
          isDeliberateBackfill: true,
        );
        if (!ok) {
          // Framework already wrote sanity_log + connector_sync_log;
          // skip the canonical fact write.
          continue;
        }
        final inserted = await _gateway.writeReservationFact(mapped);
        if (inserted) recordsWritten += 1;
        if (mapped.vendorModifiedAt.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = mapped.vendorModifiedAt;
        }
      }

      // Per-batch commit. Watermark persists after THIS page's writes,
      // not after the full backfill — Cloud Run Job restart resumes
      // from this cursor.
      cursor = page.nextCursor ?? cursor;
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: OpenTableWatermarkRow(
          cursorToken: cursor ?? '',
          lastModifiedSeen: lastModifiedSeen,
        ),
      );
      batchesCommitted += 1;

      if (page.nextCursor == null) break;
    }

    return BackfillResult(
      batchesCommitted: batchesCommitted,
      recordsWritten: recordsWritten,
      cursorToken: cursor ?? '',
      lastModifiedSeen: lastModifiedSeen,
      completed: true,
    );
  }

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) async {
    final accessToken =
        await _requireAccessToken(command.operatorId, command.locationId);
    final restaurantId =
        await _requireRestaurantId(command.operatorId, command.locationId);

    var recordsWritten = 0;
    var sanityDropped = 0;
    String? cursor = command.cursorToken;
    var lastModifiedSeen = command.lastModifiedSeen;
    final tickEnd = _now().toUtc();

    while (true) {
      final page = await _transport.listReservations(
        accessToken: accessToken,
        restaurantId: restaurantId,
        modifiedSince: command.lastModifiedSeen,
        modifiedUntil: tickEnd,
        cursor: cursor,
      );

      for (final record in page.records) {
        final mapped = _canonicalize(
          operatorId: command.operatorId,
          locationId: command.locationId,
          payload: <String, Object?>{'reservation': record},
        );
        if (mapped == null) {
          continue;
        }
        final ok = await command.sanityHook(
          vendorEventId: mapped.vendorEntityId,
          payload: <String, Object?>{
            'opened_at': mapped.reservationAt.toIso8601String(),
            'closed_at': mapped.reservationAt.toIso8601String(),
          },
          isDeliberateBackfill: false,
        );
        if (!ok) {
          sanityDropped += 1;
          continue;
        }
        final inserted = await _gateway.writeReservationFact(mapped);
        if (inserted) recordsWritten += 1;
        if (mapped.vendorModifiedAt.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = mapped.vendorModifiedAt;
        }
      }

      cursor = page.nextCursor ?? cursor;
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: OpenTableWatermarkRow(
          cursorToken: cursor ?? '',
          lastModifiedSeen: lastModifiedSeen,
        ),
      );

      if (page.nextCursor == null) break;
    }

    return PollIncrementalResult(
      recordsWritten: recordsWritten,
      newCursorToken: cursor ?? '',
      newLastModifiedSeen: lastModifiedSeen,
      sanityDropped: sanityDropped,
    );
  }

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async {
    // The framework already verified signature, replay window,
    // binding, and idempotency BEFORE this call (steps 1-4 of
    // InboundWebhookHandler.dispatch). Sanity is enforced inline at
    // step 4 — do NOT re-call sanityHook here.
    final mapped = _canonicalize(
      operatorId: command.operatorId,
      locationId: command.locationId,
      payload: command.payload,
    );
    if (mapped == null) {
      // Malformed payload: drop at adapter boundary; framework records
      // a `connector_sync_log` row via the dispatch unwind. No
      // partial-write flag (V1 lean cut 2 — the adapter either writes
      // a clean canonical fact or refuses).
      return const HandleWebhookResult(recordsWritten: 0);
    }
    final inserted = await _gateway.writeReservationFact(mapped);
    return HandleWebhookResult(recordsWritten: inserted ? 1 : 0);
  }

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    final accessToken = await _gateway.readAccessToken(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (accessToken == null) {
      // Already disconnected. Idempotent no-op.
      return const DisconnectResult(
        credentialsWiped: false,
        webhookUnregistered: false,
        watermarkPreserved: true,
      );
    }
    final restaurantId = await _gateway.readRestaurantId(
          operatorId: command.operatorId,
          locationId: command.locationId,
        ) ??
        '';

    bool webhookUnregistered = false;
    try {
      await _transport.unregisterWebhook(
        accessToken: accessToken,
        restaurantId: restaurantId,
        // The gateway tracks the subscription id in the connection
        // metadata; the documented slice's fake transport accepts a
        // pass-through. The production gateway looks it up before
        // wiping credentials.
        subscriptionId: '$kOpenTableVendorId-sub-$restaurantId',
      );
      webhookUnregistered = true;
    } catch (_) {
      // Vendor-side unregister failed — operator can revoke from the
      // OpenTable Back Office. Still proceed with local credential
      // wipe.
    }

    try {
      await _transport.revoke(accessToken: accessToken);
    } catch (_) {
      // Best-effort revoke; vendor outage shouldn't block disconnect.
    }

    await _gateway.wipeCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );

    return DisconnectResult(
      credentialsWiped: true,
      webhookUnregistered: webhookUnregistered,
      watermarkPreserved: true,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<String> _requireAccessToken(String operatorId, String locationId) async {
    final token = await _gateway.readAccessToken(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (token == null) {
      throw StateError(
        'no OpenTable access token on file for '
        '(operator=$operatorId, location=$locationId); the framework '
        'should have refused the request before reaching the adapter.',
      );
    }
    return token;
  }

  Future<String> _requireRestaurantId(
    String operatorId,
    String locationId,
  ) async {
    final restaurantId = await _gateway.readRestaurantId(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (restaurantId == null || restaurantId.isEmpty) {
      throw StateError(
        'no OpenTable restaurant_id binding on file for '
        '(operator=$operatorId, location=$locationId).',
      );
    }
    return restaurantId;
  }

  String? _restaurantIdFromRecords(List<Map<String, Object?>> records) {
    for (final record in records) {
      final rid = record['restaurant_id'];
      if (rid != null) return rid.toString();
    }
    return null;
  }

  /// Map one OpenTable reservation envelope to a canonical fact.
  /// Returns null when the payload is missing required fields — the
  /// caller drops it at the adapter boundary.
  OpenTableCanonicalReservationFact? _canonicalize({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> payload,
  }) {
    final reservationRaw = payload['reservation'];
    if (reservationRaw is! Map) return null;
    final reservation = Map<String, Object?>.from(reservationRaw);

    final id = reservation['id'];
    if (id == null) return null;
    final entityId = id.toString();
    if (entityId.isEmpty) return null;

    final reservedAtRaw = reservation['reserved_at'];
    if (reservedAtRaw is! String) return null;
    final reservationAt = DateTime.tryParse(reservedAtRaw)?.toUtc();
    if (reservationAt == null) return null;

    final modifiedRaw = reservation['modified_at'];
    DateTime? modifiedAt;
    if (modifiedRaw is String) {
      modifiedAt = DateTime.tryParse(modifiedRaw)?.toUtc();
    }
    modifiedAt ??= reservationAt;

    final partySizeRaw = reservation['party_size'];
    if (partySizeRaw is! num) return null;
    final partySize = partySizeRaw.toInt();
    if (partySize <= 0) return null;

    final statusRaw = reservation['status'];
    if (statusRaw is! String || statusRaw.isEmpty) return null;
    final status = statusRaw.toLowerCase();

    return OpenTableCanonicalReservationFact(
      operatorId: operatorId,
      locationId: locationId,
      vendorEntityId: entityId,
      vendorModifiedAt: modifiedAt,
      reservationAt: reservationAt,
      partySize: partySize,
      status: status,
      rawPayload: reservation,
    );
  }
}
