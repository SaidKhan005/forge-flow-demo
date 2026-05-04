// Phase 8R.TC — Tock (Squarespace) reservation adapter.
//
// Engineered against the documented Tock reservation API surface
// (https://api.exploretock.com/docs/latest/reservation.html, retrieved
// 2026-05-04) at lifecycle = `documented`. Live HTTP runs are deferred
// to `8R.TC.live.sandbox` / `8R.TC.live.prod` once Tock issues
// Premium-tier API credentials.
//
// Authority:
//   * `docs/contracts/vendor_adapter_slice_contract.md` — framework
//     calls (sanity hook, idempotency, watermark per batch, signature
//     verifier, repository pattern, capability profile).
//   * `docs/contracts/per_vendor_doc_pack_contract.md` — every
//     assumption captured in `docs/integrations/tock/`.
//   * `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md`
//     `8R.TC` slice.
//
// Hard Promises honored:
//   * HP #1 — pure transport swap: writes the existing reservation
//     canonical fact via [TockFactSink]; no business-logic changes.
//   * HP #4 — RLS-ready: every fact write is expected to flow through
//     `OperatorScopedRepository.withTenant`. The adapter itself never
//     opens a database connection; the production sink is the only
//     `package:postgres` consumer.
//   * HP #7 — server-side credentials: plaintext API keys NEVER reach
//     Flutter; the adapter consumes opaque [TockCredentialHandle]
//     values that the framework's `vendor_credentials_repository` mints.
//   * HP #8 — general-purpose framework: this adapter binds to the
//     existing `ReservationAdapter` interface and the framework's
//     `VendorWebhookSignatureVerifier` shape. No framework changes.
//
// V1 lean cut 2 boundaries respected (REJECT-on-presence list):
//   * No KMS code path / production-key rotation logic.
//   * No webhook key rotation UI surface.
//   * No `parse_warnings` JSONB / `parse_partial` flag.
//   * No 5-minute strict replay window (24h via the framework ceiling).
//   * No OAuth advisory locks.
//   * No SIGTERM graceful drain handler.
//   * No DLQ tile mount.
//   * No raw-payload sibling tables.
//   * No 5-second test-connection SLA.
//   * No 3-strike auto-disable email wiring (deferred to `9.8.email`).
//
// Vendor specifics:
//   * `webhookSupport = manualPaste`. Tock issues a webhook URL +
//     signing secret to the operator; the operator pastes both into the
//     Tock Premium-tier dashboard. The adapter does NOT call any
//     auto-register endpoint.
//   * `authMode = keyPaste`. Tock issues an API key via
//     `integrate@tockhq.com` to Premium / Premium Unlimited tier
//     accounts. Engineering does not own the commercial lane.
//   * `coversFieldExposed = false`; the reservation surface does not
//     emit a "covers" field in the POS sense — `partySize` is the
//     reservation analog and is captured as `party_size`. Forecast
//     fallback does NOT apply (covers source classification =
//     `not_applicable` per `docs/integrations/tock/field_mapping.md`).
//   * Per-transition timestamps (`arrived_at`, `seated_at`,
//     `left_at`, `canceled_at`) are NOT documented in the public Tock
//     reservation reference. The adapter captures only the documented
//     `lastUpdatedTimestamp` as `vendor_modified_at` plus the
//     `serviceDateTimestamp` as `reservation_at`. The `*.live.sandbox`
//     slice diffs observed payload to confirm and adds per-transition
//     fields if Tock exposes them.

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/reservation_adapter.dart';
import 'tock_webhook_signature_verifier.dart';

/// Operator-facing display name used in the Vendor Connections admin
/// surface.
const String kTockDisplayName = 'Tock';

/// Documented API version pin. Tock does not publish a numeric API
/// version on its public reservation reference; the slug below combines
/// the doc retrieval date so a future shape change is detectable from
/// the diff between this constant + observed sandbox responses.
const String kTockApiVersion = 'reservation_2026_05_03';

/// Documented-per-Tock field-mapping constants (api version
/// `reservation_2026_05_03`, retrieved 2026-05-04 from
/// https://api.exploretock.com/docs/latest/reservation.html). Keeping
/// these as a single Map lets the per-vendor doc pack
/// (`docs/integrations/tock/field_mapping.md`) and the fixtures cite
/// the same source-of-truth without drift.
///
/// The `*.live.sandbox` slice diffs observed responses against this
/// constant; mismatches are bounded fixes, not slice rebuilds.
const Map<String, Object?> documentedPerTockReservation20260504 =
    <String, Object?>{
  'source_url':
      'https://api.exploretock.com/docs/latest/reservation.html',
  'retrieval_date': '2026-05-04',
  'api_version': kTockApiVersion,
  'reservation_at_path': 'serviceDateTimestamp',
  'reservation_at_format': 'iso8601_utc',
  'party_size_path': 'partySize',
  'party_size_type': 'int',
  'status_path': 'status',
  'status_type': 'enum',
  'status_values': <String>[
    'EXPECTED',
    'ARRIVED',
    'SEATED',
    'LEFT',
    'NO_SHOW',
    'CANCELLED',
  ],
  'vendor_entity_id_path': 'id',
  'vendor_modified_at_path': 'lastUpdatedTimestamp',
  'vendor_modified_at_format': 'iso8601_utc',
  'created_timestamp_path': 'createdTimestamp',
  'service_date_timestamp_path': 'serviceDateTimestamp',
  'covers_field_classification': 'not_applicable',
  'per_transition_timestamps_documented': false,
  'per_transition_timestamps_ambiguity':
      'verify in 8R.TC.live.sandbox — Tock public reference omits per-status '
          'transition timestamps; sandbox payload may include arrived_at / '
          'seated_at / left_at / canceled_at, which the adapter will adopt as '
          'a bounded fix rather than a slice rebuild.',
  'forbidden_fields': <String>[
    'guest.firstName',
    'guest.lastName',
    'guest.email',
    'guest.phone',
    'paymentInstrument',
  ],
};

/// Canonical reservation status enum the app stores after vendor
/// normalization. Mirrors the lower-snake-case shape downstream
/// canonical fact tables consume. A vendor status outside the
/// documented six is normalized to [TockReservationStatus.unknown];
/// the adapter never silently maps an unknown value to a known one.
enum TockReservationStatus {
  expected,
  arrived,
  seated,
  left,
  noShow,
  canceled,
  unknown,
}

/// Vendor-status string → canonical [TockReservationStatus]. The
/// adapter applies `.trim().toUpperCase()` before lookup so casing /
/// whitespace differences from Tock's payload do not silently miss.
const Map<String, TockReservationStatus> kTockStatusVocabulary =
    <String, TockReservationStatus>{
  'EXPECTED': TockReservationStatus.expected,
  'ARRIVED': TockReservationStatus.arrived,
  'SEATED': TockReservationStatus.seated,
  'LEFT': TockReservationStatus.left,
  'NO_SHOW': TockReservationStatus.noShow,
  'CANCELLED': TockReservationStatus.canceled,
};

/// Snake-case canonical-string projection of [TockReservationStatus].
/// Used as the `status` value on the canonical fact map so downstream
/// consumers see a stable, vendor-neutral string.
const Map<TockReservationStatus, String> kTockCanonicalStatusString =
    <TockReservationStatus, String>{
  TockReservationStatus.expected: 'expected',
  TockReservationStatus.arrived: 'arrived',
  TockReservationStatus.seated: 'seated',
  TockReservationStatus.left: 'left',
  TockReservationStatus.noShow: 'no_show',
  TockReservationStatus.canceled: 'canceled',
  TockReservationStatus.unknown: 'unknown',
};

/// Opaque handle for Tock API credentials. Plaintext API keys NEVER
/// reach Flutter or the adapter; the framework's `vendor_credentials`
/// repository mints these handles so the adapter can attach an auth
/// header without seeing the secret. The seam keeps HP #7 enforced at
/// compile time — the adapter cannot accidentally log a key it never
/// holds.
class TockCredentialHandle {
  const TockCredentialHandle({
    required this.connectionId,
    required this.businessId,
  });

  /// `connector_connection.connection_id` of the row this handle
  /// represents.
  final String connectionId;

  /// Vendor-side identity binding (Tock `business_id`, the per-location
  /// account identifier). Stored in
  /// `connector_connection.metadata.business_id` so the framework can
  /// cross-check the binding on every webhook (see
  /// `WebhookBindingExtractor` in
  /// `lib/services/integration/inbound_webhook_handler.dart`).
  final String businessId;
}

/// Transport seam. Production wires this to the real Tock HTTP API
/// (`POST /reservations/search`, `GET /reservations/{id}`,
/// `GET /businesses/{businessId}` etc.). Tests pass an in-memory fake.
///
/// All methods here are pure transport — no fact writes, no business
/// logic. The adapter pairs each transport call with the framework's
/// sanity hook + the [TockFactSink.upsertReservationFact] write.
///
/// Tock requires manual paste of the webhook URL + signing secret into
/// the Premium-tier dashboard, so this surface deliberately omits any
/// auto-register / un-register method. Omitting them keeps the
/// `webhookSupport = manualPaste` contract enforceable at compile
/// time — the adapter cannot accidentally invoke an endpoint that is
/// not on the transport.
abstract class TockApiClient {
  /// Confirm a Tock API key is valid for the declared business id.
  /// Returns the resolved handle on success.
  Future<TockCredentialHandle> verifyApiKey({
    required String operatorId,
    required String locationId,
    required String businessId,
    required String apiKey,
  });

  /// Heavy on-demand sample-pull for the operator-facing
  /// "Test connection" modal. Returns one real-looking reservation so
  /// the admin surface can show field mapping is working, not just
  /// auth.
  Future<Map<String, Object?>> fetchSampleReservation({
    required TockCredentialHandle credentials,
  });

  /// Page through reservations within `[windowStart, windowEnd]`. Tock
  /// `reservations/search` supports cursor pagination; the production
  /// transport stitches consecutive pages here. The fake in tests just
  /// returns canned pages keyed by [resumeFromCursor].
  Future<TockReservationsPage> fetchReservationsPage({
    required TockCredentialHandle credentials,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? resumeFromCursor,
  });

  /// Look up a single reservation by its `id`. Used by [pollIncremental]
  /// when a vendor-side rate cap forces a stitched single-id resume; the
  /// webhook path does NOT use this method (Tock payloads are documented
  /// as full-shape).
  Future<Map<String, Object?>?> fetchReservationById({
    required TockCredentialHandle credentials,
    required String reservationId,
  });
}

/// One page of vendor reservations + the cursor that resumes the next
/// page.
class TockReservationsPage {
  const TockReservationsPage({
    required this.reservations,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Vendor-shape reservation DTOs as returned by `reservations/search`.
  /// The adapter normalizes via [TockReservationAdapter._canonicalize]
  /// before any sanity / write call.
  final List<Map<String, Object?>> reservations;

  /// Vendor pagination cursor for the next page; null when this was the
  /// last page in the window.
  final String? nextCursor;

  /// `lastUpdatedTimestamp` of the most-recently-modified reservation
  /// in this page. The adapter persists this to
  /// `connector_sync_watermark.last_modified_seen` after the batch
  /// commits.
  final DateTime lastModifiedSeen;
}

/// Canonical-fact write seam. Production binds this to a Postgres-
/// backed sink that runs each upsert inside
/// `OperatorScopedRepository.withTenant` (HP #4). Tests bind an
/// in-memory fake.
///
/// Adapters MUST NOT open their own database connections; the sink is
/// the only seam through which canonical facts reach storage. The
/// production sink resolves `connector_connection_id` internally from
/// `(operator_id, location_id, vendor_id)` so the adapter never has to
/// thread a connection id through the call sites.
abstract class TockFactSink {
  /// Upsert one canonical reservation fact. Idempotent on
  /// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  /// per the framework's idempotency rule. Implementations return
  /// `true` when the row was inserted (or updated to a newer
  /// `vendor_modified_at`); `false` when the upsert was a no-op
  /// (duplicate or stale event).
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
    required Map<String, Object?> rawPayload,
  });

  /// Persist `connector_sync_watermark` per batch commit. The
  /// production implementation upserts on
  /// `(operator_id, location_id, vendor_id)` so worker restart resumes
  /// from the last successful batch.
  Future<void> persistWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  });
}

/// Tock reservation adapter. Concrete implementation of
/// [ReservationAdapter] at lifecycle = `documented`.
class TockReservationAdapter implements ReservationAdapter {
  TockReservationAdapter({
    required this.transport,
    required this.factSink,
    this.signatureVerifier = const TockWebhookSignatureVerifier(),
    DateTime Function()? now,
    int batchSize = 50,
  })  : _now = now ?? DateTime.now,
        _batchSize = batchSize;

  final TockApiClient transport;
  final TockFactSink factSink;
  final TockWebhookSignatureVerifier signatureVerifier;
  final DateTime Function() _now;
  final int _batchSize;

  @override
  String get vendorId => kTockVendorId;

  @override
  String get displayName => kTockDisplayName;

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kTockVendorId,
        displayName: kTockDisplayName,
        category: IntegrationCategory.reservation,
        // Tock issues per-business API keys to Premium-tier customers
        // via integrate@tockhq.com. No OAuth flow is documented on
        // the public reservation reference.
        authMode: VendorAuthMode.keyPaste,
        // Each F&F location maps to one Tock `business_id`; multi-
        // location operators run one key-paste per location.
        grantScope: VendorGrantScope.perLocation,
        // Tock requires manual paste of webhook URL + signing secret
        // in the Premium-tier dashboard. The adapter does NOT auto-
        // register a webhook subscription.
        webhookSupport: VendorWebhookSupport.manualPaste,
        // Reservations do not emit a "covers" field; `partySize` is the
        // reservation analog and is captured as `party_size`. Covers
        // source classification = `not_applicable` per
        // docs/integrations/tock/field_mapping.md.
        coversFieldExposed: false,
        lifecycle: VendorLifecycle.documented,
        modules: <String>[],
        timestampPolicyDocId: 'tock',
      );

  // ─── connect ─────────────────────────────────────────────────────

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != kTockVendorId) {
      throw StateError(
        'TockReservationAdapter received connect for vendor ${command.vendorId}',
      );
    }
    final keyPaste = command.keyPaste;
    if (keyPaste == null || keyPaste.apiKey.isEmpty) {
      throw StateError(
        'Tock connect requires a keyPaste credential with apiKey set; the '
        'framework did not pass one.',
      );
    }
    final businessId = keyPaste.username;
    if (businessId == null || businessId.isEmpty) {
      throw StateError(
        'Tock connect requires keyPaste.username to carry the Tock '
        'business_id; the framework did not pass one.',
      );
    }

    final handle = await transport.verifyApiKey(
      operatorId: command.operatorId,
      locationId: command.locationId,
      businessId: businessId,
      apiKey: keyPaste.apiKey,
    );
    final webhookUrl =
        '/v1/webhooks/$kTockVendorId/${command.operatorId}/${command.locationId}';

    return ConnectResult(
      connectionId: handle.connectionId,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'business_id': handle.businessId,
        // Webhook is operator-pasted into the Tock Premium-tier
        // dashboard; the admin chrome reads this flag to render
        // "Connecting (webhook pending)" until the first signed
        // webhook arrives.
        'webhook_pending': true,
        'webhook_support': 'manual_paste',
      },
      webhookUrl: webhookUrl,
      firstBackfillStarted: true,
    );
  }

  // ─── testConnection ──────────────────────────────────────────────

  @override
  Future<TestConnectionResult> testConnection(
    TestConnectionCommand command,
  ) async {
    final start = _now();
    final handle = await transport.verifyApiKey(
      operatorId: command.operatorId,
      locationId: command.locationId,
      businessId: '__test-connection__',
      apiKey: '__resolved-by-route-layer__',
    );
    final sample = await transport.fetchSampleReservation(credentials: handle);
    final canonical = _canonicalize(sample);
    final elapsed = _now().difference(start).inMilliseconds;

    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: <String, Object?>{
        'reservation_at': canonical['reservation_at'],
        'party_size': canonical['party_size'],
        'status': canonical['status'],
        'vendor_entity_id': canonical['vendor_entity_id'],
        'vendor_modified_at': canonical['vendor_modified_at'],
      },
      elapsedMs: elapsed,
      note:
          'Tock exposes partySize (no covers field); covers source = '
          'not_applicable. Per-transition timestamps are unverified — see '
          'docs/integrations/tock/field_mapping.md Ambiguity calls.',
    );
  }

  // ─── backfill ────────────────────────────────────────────────────

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final handle = await transport.verifyApiKey(
      operatorId: command.operatorId,
      locationId: command.locationId,
      businessId: '__backfill__',
      apiKey: '__resolved-by-route-layer__',
    );

    var batchesCommitted = 0;
    var recordsWritten = 0;
    var cursor = command.resumeFromCursor;
    var lastModifiedSeen = command.windowStart;
    var completed = false;

    while (true) {
      final page = await transport.fetchReservationsPage(
        credentials: handle,
        windowStart: command.windowStart,
        windowEnd: command.windowEnd,
        resumeFromCursor: cursor,
      );

      final batch = <Map<String, Object?>>[];
      for (final raw in page.reservations) {
        final canonical = _canonicalize(raw);
        // Mandatory framework call #1 — sanity hook on the backfill
        // path. Skip the canonical write when the hook returns false
        // (the framework already wrote sanity_log + connector_sync_log).
        final passes = await command.sanityHook(
          vendorEventId: canonical['vendor_entity_id'] as String,
          payload: canonical,
          isDeliberateBackfill: true,
        );
        if (!passes) continue;
        batch.add(<String, Object?>{
          'canonical': canonical,
          'raw': raw,
        });
      }

      // Commit the batch — even an empty batch advances the watermark
      // so a no-op page does not force a full re-walk on restart.
      for (final row in batch) {
        final wrote = await factSink.upsertReservationFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          canonicalFact: row['canonical']! as Map<String, Object?>,
          rawPayload: row['raw']! as Map<String, Object?>,
        );
        if (wrote) recordsWritten += 1;
      }
      batchesCommitted += 1;
      cursor = page.nextCursor;
      lastModifiedSeen = page.lastModifiedSeen.isAfter(lastModifiedSeen)
          ? page.lastModifiedSeen
          : lastModifiedSeen;

      // Mandatory framework call #3 — watermark per batch commit.
      await factSink.persistWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        cursorToken: cursor ?? '',
        lastModifiedSeen: lastModifiedSeen,
      );

      if (cursor == null) {
        completed = true;
        break;
      }
      if (batchesCommitted >= _batchSize) {
        // Cooperative yield — production worker picks the next batch
        // up on its next tick rather than blocking the Cloud Run Job
        // beyond its execution-time budget.
        break;
      }
    }

    return BackfillResult(
      batchesCommitted: batchesCommitted,
      recordsWritten: recordsWritten,
      cursorToken: cursor ?? '',
      lastModifiedSeen: lastModifiedSeen,
      completed: completed,
    );
  }

  // ─── pollIncremental ─────────────────────────────────────────────

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) async {
    final handle = await transport.verifyApiKey(
      operatorId: command.operatorId,
      locationId: command.locationId,
      businessId: '__poll__',
      apiKey: '__resolved-by-route-layer__',
    );

    final windowStart = command.lastModifiedSeen;
    final windowEnd = _now();
    var cursor = command.cursorToken;
    var recordsWritten = 0;
    var sanityDropped = 0;
    var newLastModifiedSeen = command.lastModifiedSeen;

    while (true) {
      final page = await transport.fetchReservationsPage(
        credentials: handle,
        windowStart: windowStart,
        windowEnd: windowEnd,
        resumeFromCursor: cursor,
      );
      for (final raw in page.reservations) {
        final canonical = _canonicalize(raw);
        final passes = await command.sanityHook(
          vendorEventId: canonical['vendor_entity_id'] as String,
          payload: canonical,
          // Polling is not a deliberate backfill — sanity rule 3
          // (90-day floor) is enforced on this path.
          isDeliberateBackfill: false,
        );
        if (!passes) {
          sanityDropped += 1;
          continue;
        }
        final wrote = await factSink.upsertReservationFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          canonicalFact: canonical,
          rawPayload: raw,
        );
        if (wrote) recordsWritten += 1;
      }
      cursor = page.nextCursor;
      if (page.lastModifiedSeen.isAfter(newLastModifiedSeen)) {
        newLastModifiedSeen = page.lastModifiedSeen;
      }
      // Watermark per batch even on poll — V1 lean cut 2 trim
      // preserves per-batch persistence so worker restart resumes
      // mid-poll without rewinding.
      await factSink.persistWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        cursorToken: cursor ?? '',
        lastModifiedSeen: newLastModifiedSeen,
      );
      if (cursor == null) break;
    }

    return PollIncrementalResult(
      recordsWritten: recordsWritten,
      newCursorToken: cursor ?? '',
      newLastModifiedSeen: newLastModifiedSeen,
      sanityDropped: sanityDropped,
    );
  }

  // ─── handleWebhook ───────────────────────────────────────────────

  @override
  Future<HandleWebhookResult> handleWebhook(
    HandleWebhookCommand command,
  ) async {
    // Mandatory framework call #1 — webhook handler enforces sanity
    // INLINE before this method runs (step 4 of the dispatch sequence
    // in inbound_webhook_handler.dart). The adapter MUST NOT re-call
    // the sanity hook here.
    //
    // Tock webhook payloads are documented as full reservation shape;
    // the adapter does NOT round-trip an id-only event back through
    // fetchReservationById.
    final canonical = _canonicalize(command.payload);
    final wrote = await factSink.upsertReservationFact(
      operatorId: command.operatorId,
      locationId: command.locationId,
      canonicalFact: canonical,
      rawPayload: command.payload,
    );
    return HandleWebhookResult(recordsWritten: wrote ? 1 : 0);
  }

  // ─── disconnect ──────────────────────────────────────────────────

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    // Tock is `webhookSupport = manualPaste`. The adapter never
    // registered a vendor-side webhook subscription, so there is
    // nothing for the adapter to unregister. The operator-facing UX
    // instructs the operator to remove the F&F webhook URL from the
    // Tock Premium-tier dashboard manually; that step is documented
    // in the disconnect walkthrough but does not run here.
    return const DisconnectResult(
      credentialsWiped: true,
      webhookUnregistered: false,
      // Per Phase 8R plan: historical canonical facts and watermark
      // are preserved so reconnect resumes from the last cursor.
      watermarkPreserved: true,
    );
  }

  // ─── helpers ─────────────────────────────────────────────────────

  /// Vendor-shape reservation → canonical fact map. Every assumption
  /// here is mirrored in `documentedPerTockReservation20260504` and
  /// `docs/integrations/tock/field_mapping.md`.
  Map<String, Object?> _canonicalize(Map<String, Object?> reservation) {
    final rawStatus = reservation['status'];
    final canonicalStatus = _normalizeStatus(rawStatus);
    return <String, Object?>{
      'vendor_entity_id': reservation['id'],
      'vendor_modified_at': reservation['lastUpdatedTimestamp'],
      'reservation_at': reservation['serviceDateTimestamp'],
      'party_size': reservation['partySize'],
      'status': kTockCanonicalStatusString[canonicalStatus],
      'vendor_status_raw': rawStatus,
      'created_timestamp': reservation['createdTimestamp'],
      // Per-transition timestamps (`arrived_at`, `seated_at`, etc.)
      // are AMBIGUITY: yes — verify in 8R.TC.live.sandbox. Tock's
      // public reference omits per-status transition timestamps;
      // sandbox payloads may include them, in which case the
      // `*.live.sandbox` slice diffs and adopts as a bounded fix.
      // See docs/integrations/tock/field_mapping.md.
    };
  }

  TockReservationStatus _normalizeStatus(Object? rawStatus) {
    if (rawStatus is! String) return TockReservationStatus.unknown;
    final key = rawStatus.trim().toUpperCase();
    return kTockStatusVocabulary[key] ?? TockReservationStatus.unknown;
  }
}
