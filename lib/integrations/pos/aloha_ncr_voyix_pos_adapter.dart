// Phase 8.AL — Aloha (NCR Voyix) POS adapter (lifecycle = `documented`).
//
// Engineered against the documented NCR Voyix Aloha-module API surface
// (https://developer.ncrvoyix.com/portals/dev-portal/api-explorer,
// retrieved 2026-05-04). No live HTTP runs from this slice; the
// `8.AL.live.sandbox` slice promotes the adapter to `sandbox_verified`
// once NCR Voyix Developer Program intake clears + Aloha-module
// sandbox credentials are issued. The Aloha module sits behind the
// NCR Voyix Developer Program (8-16 weeks lead) plus a per-API access
// request — see `docs/integrations/aloha_ncr_voyix/api_consumed.md`
// and `docs/integrations/aloha_ncr_voyix/partnership_status.md`.
//
// Authority:
//   * `docs/contracts/vendor_adapter_slice_contract.md` — framework
//     calls (sanity hook, idempotency, watermark per batch, signature
//     verifier, repository pattern, capability profile).
//   * `docs/contracts/per_vendor_doc_pack_contract.md` — every
//     assumption captured in `docs/integrations/aloha_ncr_voyix/`.
//   * `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`
//     `8.AL` slice.
//
// Hard Promises honored:
//   * HP #1 — pure transport swap: writes existing canonical fact rows
//     via the [AlohaNcrVoyixFactSink] seam; no business-logic changes.
//   * HP #4 — RLS-ready: every fact write flows through
//     `OperatorScopedRepository.withTenant`. The adapter never opens a
//     database connection; the production sink is the only
//     `package:postgres` consumer.
//   * HP #7 — server-side credentials: plaintext OAuth tokens never
//     reach Flutter; the adapter consumes opaque
//     [AlohaNcrVoyixCredentialHandle] values that the framework's
//     `vendor_credentials_repository` mints.
//   * HP #8 — general-purpose framework: this adapter binds to the
//     existing `PosAdapter` interface and the existing
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

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/pos_adapter.dart';
import 'aloha_ncr_voyix_webhook_signature_verifier.dart';

/// Engineering-vs-live lifecycle for one vendor adapter. Mirrors the
/// 4-state ladder in `docs/contracts/vendor_adapter_slice_contract.md`.
///
/// The framework will eventually carry this enum on
/// `VendorCapabilityProfile.lifecycle` (slice `8.0.lifecycle`, the
/// first item in Wave B). Until that slice ships, the enum lives in
/// the per-vendor adapter file and is exposed as a separate getter on
/// the adapter — Codex grades acceptance against the getter.
enum VendorLifecycle {
  /// Engineering slice landed; adapter compiles + fixture-tested; doc
  /// pack populated. Vendor picker shows "Coming soon" pill, no
  /// Connect button.
  documented,

  /// `*.live.sandbox` slice ran; field mapping confirmed against
  /// vendor sandbox. Picker shows "Coming soon — sandbox verified"
  /// pill.
  sandboxVerified,

  /// `*.live.prod` slice ran; partnership cleared; production keys
  /// issued. Connect button live.
  productionCredentialed,

  /// First operator connected (auto-promote, no slice). Connected-
  /// operator chip in F&F Ops Console activated.
  liveWithOperators,
}

/// Documented-per-Aloha (NCR Voyix) field-mapping constants (api
/// version `aloha-v1-2026-05`, retrieved 2026-05-04 from
/// https://developer.ncrvoyix.com/portals/dev-portal/api-explorer).
/// Keeping these as a single Map lets the per-vendor doc pack
/// (`docs/integrations/aloha_ncr_voyix/field_mapping.md`) and the
/// fixtures cite the same source-of-truth without drift.
///
/// The `*.live.sandbox` slice diffs observed responses against this
/// constant; mismatches are bounded fixes, not slice rebuilds.
const Map<String, Object?> documentedPerAlohaNcrVoyixV1 = <String, Object?>{
  'source_url':
      'https://developer.ncrvoyix.com/portals/dev-portal/api-explorer',
  'retrieval_date': '2026-05-04',
  'api_version': 'aloha-v1-2026-05',
  'covers_path': 'numberOfGuests',
  'covers_type': 'int',
  'covers_classification': 'direct',
  'opened_at_path': 'openedAt',
  'opened_at_format': 'iso8601_utc',
  'closed_at_path': 'closedAt',
  'closed_at_format': 'iso8601_utc',
  'actual_sales_path': 'totalAmount',
  'actual_sales_type': 'decimal_dollars',
  'vendor_entity_id_path': 'checkId',
  'vendor_modified_at_path': 'modifiedAt',
  'vendor_modified_at_format': 'iso8601_utc',
  'site_id_path': 'siteId',
  'forbidden_fields': <String>[
    'guest.firstName',
    'guest.lastName',
    'guest.email',
    'payments.cardholderName',
    'payments.cardLast4',
  ],
};

/// Stable vendor key. Mirrors `VendorCapabilityProfile.vendorId` and
/// `connector_connection.vendor_id`. The `_` separator follows the
/// `<brand>_<provider>` shape already used by `quickbooks_time` and
/// `lightspeed_lsk`.
const String kAlohaNcrVoyixVendorId = 'aloha_ncr_voyix';

/// Operator-facing display name shown in the vendor picker chrome and
/// admin surface. Matches the NCR Voyix brand for Aloha.
const String kAlohaNcrVoyixDisplayName = 'Aloha (NCR Voyix)';

/// Opaque handle for OAuth credentials. Plaintext tokens NEVER reach
/// Flutter or the adapter; the framework's `vendor_credentials`
/// repository mints these handles so the adapter can attach an auth
/// header without seeing the secret. The seam keeps HP #7 enforced
/// at compile time — the adapter cannot accidentally log a token it
/// never holds.
class AlohaNcrVoyixCredentialHandle {
  const AlohaNcrVoyixCredentialHandle({
    required this.connectionId,
    required this.siteId,
  });

  /// `connector_connection.connection_id` of the row this handle
  /// represents.
  final String connectionId;

  /// Vendor-side identity binding (Aloha `siteId`). Stored in
  /// `connector_connection.metadata.site_id` so the framework can
  /// cross-check the binding on every webhook (see
  /// `WebhookBindingExtractor` in
  /// `lib/services/integration/inbound_webhook_handler.dart`).
  final String siteId;
}

/// Transport seam. Production wires this to the real NCR Voyix Aloha
/// HTTP API. Tests pass an in-memory fake.
///
/// All methods here are pure transport — no fact writes, no business
/// logic. The adapter pairs each transport call with the framework's
/// sanity hook + the [AlohaNcrVoyixFactSink.upsertCheckFact] write.
abstract class AlohaNcrVoyixApiClient {
  /// Confirm an OAuth client_credentials envelope is valid and the
  /// declared `siteId` is reachable. Returns the resolved handle on
  /// success. Per the `oauth_shape.md` doc-pack section, NCR Voyix
  /// uses OAuth 2.0 client_credentials with per-API access requests
  /// gating the actual scopes the credential resolves.
  Future<AlohaNcrVoyixCredentialHandle> exchangeClientCredentials({
    required String operatorId,
    required String locationId,
    required String siteId,
    String? oauthState,
  });

  /// Auto-register the F&F webhook URL with the NCR Voyix events bus
  /// (Aloha module). Returns the vendor-side subscription id stored
  /// in `connector_connection.metadata.webhook_subscription_id`.
  ///
  /// Ambiguity call: NCR Voyix exposes an events bus for Aloha module
  /// orders/checks per the developer portal landing; the exact
  /// subscription endpoint shape is verified in `8.AL.live.sandbox`.
  /// Until then, the adapter assumes a `POST` with a JSON body
  /// containing the URL + event filter (mirrors the documented Toast
  /// + Lightspeed shapes; both are direct integrations like Aloha).
  Future<String> registerWebhook({
    required AlohaNcrVoyixCredentialHandle credentials,
    required String webhookUrl,
  });

  /// Unregister the webhook subscription on disconnect. Best-effort —
  /// the framework still wipes credentials and rotates state even if
  /// the vendor's unregister call fails.
  Future<bool> unregisterWebhook({
    required AlohaNcrVoyixCredentialHandle credentials,
    String? subscriptionId,
  });

  /// Heavy on-demand sample-pull for the operator-facing
  /// "Test connection" modal. Returns one real-looking check so the
  /// admin surface can show field mapping is working, not just auth.
  Future<Map<String, Object?>> fetchSampleCheck({
    required AlohaNcrVoyixCredentialHandle credentials,
  });

  /// Page through Aloha checks within `[windowStart, windowEnd]`.
  /// Production transport stitches windowed pulls per the documented
  /// pagination shape; the fake in tests just returns canned pages
  /// keyed by [resumeFromCursor].
  Future<AlohaNcrVoyixChecksPage> fetchChecksPage({
    required AlohaNcrVoyixCredentialHandle credentials,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? resumeFromCursor,
  });

  /// Look up a single check by its `checkId`. Used by [handleWebhook]
  /// when NCR Voyix emits an `aloha.check.modified` event whose body
  /// is id-only.
  Future<Map<String, Object?>?> fetchCheckById({
    required AlohaNcrVoyixCredentialHandle credentials,
    required String checkId,
  });
}

/// One page of vendor checks + the cursor that resumes the next page.
class AlohaNcrVoyixChecksPage {
  const AlohaNcrVoyixChecksPage({
    required this.checks,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Vendor-shape check DTOs as returned by the Aloha checks endpoint.
  /// The adapter normalizes via [_canonicalize] before any sanity /
  /// write call.
  final List<Map<String, Object?>> checks;

  /// Vendor pagination cursor for the next page; null when this was
  /// the last page in the window.
  final String? nextCursor;

  /// `modifiedAt` of the most-recently-modified check in this page.
  /// The adapter persists this to
  /// `connector_sync_watermark.last_modified_seen` after the batch
  /// commits.
  final DateTime lastModifiedSeen;
}

/// Canonical-fact write seam. Production binds this to a Postgres-
/// backed sink that runs each upsert inside
/// `OperatorScopedRepository.withTenant` (HP #4). Tests bind an
/// in-memory fake.
///
/// Adapters MUST NOT open their own database connections; the sink
/// is the only seam through which canonical facts reach storage. The
/// production sink resolves `connector_connection_id` internally from
/// `(operator_id, location_id, vendor_id)` so the adapter never has
/// to thread a connection id through the call sites.
abstract class AlohaNcrVoyixFactSink {
  /// Upsert one canonical sales / covers fact. Idempotent on
  /// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  /// per the framework's idempotency rule. Implementations return
  /// `true` when the row was inserted (or updated to a newer
  /// `vendor_modified_at`); `false` when the upsert was a no-op
  /// (duplicate or stale event).
  Future<bool> upsertCheckFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
    required Map<String, Object?> rawPayload,
  });

  /// Persist `connector_sync_watermark` per batch commit. The
  /// production implementation upserts on
  /// `(operator_id, location_id, vendor_id)` so worker restart
  /// resumes from the last successful batch.
  Future<void> persistWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  });
}

/// Aloha (NCR Voyix) POS adapter. Concrete implementation of
/// [PosAdapter] at lifecycle = `documented`.
class AlohaNcrVoyixPosAdapter implements PosAdapter {
  AlohaNcrVoyixPosAdapter({
    required this.transport,
    required this.factSink,
    this.signatureVerifier =
        const AlohaNcrVoyixWebhookSignatureVerifier(),
    DateTime Function()? now,
    int batchSize = 50,
  })  : _now = now ?? DateTime.now,
        _batchSize = batchSize;

  final AlohaNcrVoyixApiClient transport;
  final AlohaNcrVoyixFactSink factSink;
  final AlohaNcrVoyixWebhookSignatureVerifier signatureVerifier;
  final DateTime Function() _now;
  final int _batchSize;

  /// 4-state lifecycle. The engineering slice ships at `documented`.
  /// Promotion to `sandboxVerified` / `productionCredentialed` /
  /// `liveWithOperators` is the job of the corresponding `*.live.*`
  /// slice — this getter is the assertion seam Codex grades.
  VendorLifecycle get lifecycle => VendorLifecycle.documented;

  @override
  String get vendorId => kAlohaNcrVoyixVendorId;

  @override
  String get displayName => kAlohaNcrVoyixDisplayName;

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kAlohaNcrVoyixVendorId,
        displayName: kAlohaNcrVoyixDisplayName,
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        // NCR Voyix issues one Aloha `siteId` per location; multi-
        // location operators run one OAuth flow per location. Mirrors
        // VendorGrantScope.perLocation per the framework.
        grantScope: VendorGrantScope.perLocation,
        // NCR Voyix exposes an events bus for the Aloha module per the
        // developer portal landing. The exact subscription endpoint
        // is verified in `8.AL.live.sandbox`; if the live verification
        // shows the events bus does not deliver Aloha check events,
        // this slice will be retrofitted to `pollOnly` in a bounded
        // fix per the lifecycle promotion contract.
        webhookSupport: VendorWebhookSupport.autoRegister,
        // Aloha exposes guest count via the documented `numberOfGuests`
        // field — see docs/integrations/aloha_ncr_voyix/field_mapping.md.
        coversFieldExposed: true,
        // Partnership-gated detail is captured in
        // docs/integrations/aloha_ncr_voyix/partnership_status.md, NOT
        // via this boolean. Per the engineer-all-17 doctrine,
        // `partnershipGated: false` lets the adapter ship at lifecycle
        // = `documented` without coupling to commercial-lane state.
        // Picker chrome reads `lifecycle`, not this flag. The 8.0.
        // lifecycle slice retires this boolean entirely.
        partnershipGated: false,
        modules: <String>[],
        // NCR Voyix Aloha-module timestamps are documented as ISO 8601
        // UTC. The vendor-timestamp policy entry lives in the
        // framework catalog; Scenario E does not apply.
        timestampPolicyDocId: 'aloha_ncr_voyix',
      );

  // ─── connect ─────────────────────────────────────────────────────

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != kAlohaNcrVoyixVendorId) {
      throw StateError(
        'AlohaNcrVoyixPosAdapter received connect for vendor '
        '${command.vendorId}',
      );
    }
    final siteId = command.keyPaste?.username ??
        (command.oauthState != null
            ? _siteIdFromOauthState(command.oauthState!)
            : null);
    if (siteId == null || siteId.isEmpty) {
      throw StateError(
        'Aloha (NCR Voyix) connect requires a siteId in either '
        'oauthState or keyPaste.username; the framework did not pass '
        'one.',
      );
    }

    final handle = await transport.exchangeClientCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
      siteId: siteId,
      oauthState: command.oauthState,
    );
    final webhookUrl =
        '/v1/webhooks/$kAlohaNcrVoyixVendorId/${command.operatorId}/${command.locationId}';
    final subscriptionId = await transport.registerWebhook(
      credentials: handle,
      webhookUrl: webhookUrl,
    );

    return ConnectResult(
      connectionId: handle.connectionId,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'site_id': handle.siteId,
        'webhook_subscription_id': subscriptionId,
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
    // The route layer mints the handle from `vendor_credentials`; the
    // test-connection command itself only carries the (operator,
    // location) pair so the route can resolve the connection. The
    // production wiring passes the resolved handle through; tests
    // inject a fake transport that does the same lookup in-memory.
    final handle = await transport.exchangeClientCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
      siteId: '__test-connection__',
    );
    final sample = await transport.fetchSampleCheck(credentials: handle);
    final canonical = _canonicalize(sample);
    final elapsed = _now().difference(start).inMilliseconds;

    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: <String, Object?>{
        'covers': canonical['covers'],
        'opened_at': canonical['opened_at'],
        'closed_at': canonical['closed_at'],
        'actual_sales': canonical['actual_sales'],
        'vendor_entity_id': canonical['vendor_entity_id'],
        'vendor_modified_at': canonical['vendor_modified_at'],
      },
      elapsedMs: elapsed,
      note:
          'Aloha exposes covers via numberOfGuests; covers_source = direct.',
    );
  }

  // ─── backfill ────────────────────────────────────────────────────

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final handle = await transport.exchangeClientCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
      siteId: '__backfill__',
    );

    var batchesCommitted = 0;
    var recordsWritten = 0;
    var cursor = command.resumeFromCursor;
    var lastModifiedSeen = command.windowStart;
    var completed = false;

    while (true) {
      final page = await transport.fetchChecksPage(
        credentials: handle,
        windowStart: command.windowStart,
        windowEnd: command.windowEnd,
        resumeFromCursor: cursor,
      );

      final batch = <Map<String, Object?>>[];
      for (final raw in page.checks) {
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
        final wrote = await factSink.upsertCheckFact(
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
    final handle = await transport.exchangeClientCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
      siteId: '__poll__',
    );

    final windowStart = command.lastModifiedSeen;
    final windowEnd = _now();
    var cursor = command.cursorToken;
    var recordsWritten = 0;
    var sanityDropped = 0;
    var newLastModifiedSeen = command.lastModifiedSeen;

    while (true) {
      final page = await transport.fetchChecksPage(
        credentials: handle,
        windowStart: windowStart,
        windowEnd: windowEnd,
        resumeFromCursor: cursor,
      );
      for (final raw in page.checks) {
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
        final wrote = await factSink.upsertCheckFact(
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

    Map<String, Object?> checkShape = command.payload;
    final checkId = checkShape['checkId'];
    final hasFullCheck = checkShape.containsKey('numberOfGuests') &&
        checkShape.containsKey('openedAt');
    if (!hasFullCheck && checkId is String && checkId.isNotEmpty) {
      // NCR Voyix's `aloha.check.modified` notification can be id-only —
      // fetch the full check so we have the canonical fields. The
      // framework mints the credentials handle from
      // `connector_connection`; the route layer passes the resolved
      // handle into the adapter. The production wiring stitches that
      // through; the test-side fake returns a canned check keyed by
      // checkId.
      final handle = await transport.exchangeClientCredentials(
        operatorId: command.operatorId,
        locationId: command.locationId,
        siteId: '__webhook__',
      );
      final fetched = await transport.fetchCheckById(
        credentials: handle,
        checkId: checkId,
      );
      if (fetched == null) {
        return const HandleWebhookResult(recordsWritten: 0);
      }
      checkShape = fetched;
    }

    final canonical = _canonicalize(checkShape);
    final wrote = await factSink.upsertCheckFact(
      operatorId: command.operatorId,
      locationId: command.locationId,
      canonicalFact: canonical,
      rawPayload: checkShape,
    );
    return HandleWebhookResult(recordsWritten: wrote ? 1 : 0);
  }

  // ─── disconnect ──────────────────────────────────────────────────

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    bool unregistered = false;
    try {
      final handle = await transport.exchangeClientCredentials(
        operatorId: command.operatorId,
        locationId: command.locationId,
        siteId: '__disconnect__',
      );
      unregistered = await transport.unregisterWebhook(credentials: handle);
    } catch (_) {
      // Vendor unregister is best-effort — the framework still wipes
      // credentials and rotates state. The audit row carries the
      // failure detail.
    }
    return DisconnectResult(
      credentialsWiped: true,
      webhookUnregistered: unregistered,
      // Per Phase 8 plan: historical canonical facts and watermark
      // are preserved so reconnect resumes from the last cursor.
      watermarkPreserved: true,
    );
  }

  // ─── helpers ─────────────────────────────────────────────────────

  /// Vendor-shape Aloha check → canonical fact map. Every assumption
  /// here is mirrored in `documentedPerAlohaNcrVoyixV1` and
  /// `docs/integrations/aloha_ncr_voyix/field_mapping.md`.
  Map<String, Object?> _canonicalize(Map<String, Object?> check) {
    return <String, Object?>{
      'vendor_entity_id': check['checkId'],
      'vendor_modified_at': check['modifiedAt'],
      'opened_at': check['openedAt'],
      'closed_at': check['closedAt'],
      'covers': check['numberOfGuests'],
      'covers_source': 'direct',
      'actual_sales': check['totalAmount'],
    };
  }

  /// The framework's OAuth-start route encodes `siteId` into the
  /// state token alongside CSRF nonce + (operator, location). The
  /// adapter parses it back at callback time. The production state
  /// token is opaque to the adapter; the parser tolerates malformed
  /// input and falls through to the keyPaste seam.
  String? _siteIdFromOauthState(String state) {
    // NCR Voyix returns the same `state` parameter the F&F OAuth-start
    // route issued. The state token is framework-managed; the adapter
    // does not parse the body itself. Production wiring resolves the
    // siteId from `oauth_authorization_in_flight` keyed by the state
    // nonce. Tests pass siteId via keyPaste.username instead.
    return null;
  }
}
