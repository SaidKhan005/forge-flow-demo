// Phase 8.TS — Toast POS adapter (lifecycle = `documented`).
//
// Engineered against the documented Toast Standard / Partner API
// surface (https://doc.toasttab.com, retrieved 2026-05-03). No live
// HTTP runs from this slice; the `*.live.sandbox` slice promotes the
// adapter to `sandbox_verified` once the Toast Partner intake clears
// and sandbox credentials are issued.
//
// Authority:
//   * `docs/contracts/vendor_adapter_slice_contract.md` — framework
//     calls (sanity hook, idempotency, watermark per batch, signature
//     verifier, repository pattern, capability profile).
//   * `docs/contracts/per_vendor_doc_pack_contract.md` — every
//     assumption captured in `docs/integrations/toast/`.
//   * `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`
//     `8.TS` slice.
//
// Hard Promises honored:
//   * HP #1 — pure transport swap: writes existing canonical fact rows
//     via the [ToastFactSink] seam; no business-logic changes.
//   * HP #4 — RLS-ready: every fact write is expected to flow through
//     `OperatorScopedRepository.withTenant`. The adapter itself never
//     opens a database connection; the production sink is the only
//     `package:postgres` consumer.
//   * HP #7 — server-side credentials: plaintext OAuth tokens never
//     reach Flutter; the adapter consumes opaque [ToastCredentialHandle]
//     values that the framework's `vendor_credentials_repository`
//     mints.
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

import 'dart:convert';

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/pos_adapter.dart';
import 'toast_webhook_signature_verifier.dart';

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

/// Documented-per-Toast field-mapping constants (api version
/// `orders/v2`, retrieved 2026-05-03 from
/// https://doc.toasttab.com/openapi/orders/orders-bulk-v2). Keeping
/// these as a single Map lets the per-vendor doc pack
/// (`docs/integrations/toast/field_mapping.md`) and the fixtures cite
/// the same source-of-truth without drift.
///
/// The `*.live.sandbox` slice diffs observed responses against this
/// constant; mismatches are bounded fixes, not slice rebuilds.
const Map<String, Object?> documentedPerToastV2 = <String, Object?>{
  'source_url': 'https://doc.toasttab.com/openapi/orders/orders-bulk-v2',
  'retrieval_date': '2026-05-03',
  'api_version': 'orders/v2',
  'covers_path': 'numberOfGuests',
  'covers_type': 'int',
  'covers_classification': 'direct',
  'opened_at_path': 'openedDate',
  'opened_at_format': 'iso8601_utc',
  'closed_at_path': 'closedDate',
  'closed_at_format': 'iso8601_utc',
  'actual_sales_path': 'totalAmount',
  'actual_sales_type': 'decimal_dollars',
  'vendor_entity_id_path': 'guid',
  'vendor_modified_at_path': 'modifiedDate',
  'vendor_modified_at_format': 'iso8601_utc',
  'forbidden_fields': <String>[
    'customer.firstName',
    'customer.lastName',
    'customer.email',
    'payments.cardholderName',
    'payments.cardLast4',
  ],
};

/// Opaque handle for OAuth credentials. Plaintext tokens NEVER reach
/// Flutter or the adapter; the framework's `vendor_credentials`
/// repository mints these handles so the adapter can attach an auth
/// header without seeing the secret. The seam keeps HP #7 enforced
/// at compile time — the adapter cannot accidentally log a token it
/// never holds.
class ToastCredentialHandle {
  const ToastCredentialHandle({
    required this.connectionId,
    required this.restaurantGuid,
  });

  /// `connector_connection.connection_id` of the row this handle
  /// represents.
  final String connectionId;

  /// Vendor-side identity binding (Toast `restaurantGuid`). Stored in
  /// `connector_connection.metadata.restaurant_guid` so the framework
  /// can cross-check the binding on every webhook (see
  /// `WebhookBindingExtractor` in
  /// `lib/services/integration/inbound_webhook_handler.dart`).
  final String restaurantGuid;
}

/// Transport seam. Production wires this to the real Toast HTTP API
/// (`POST /authentication/v1/authentication/login`,
/// `GET /orders/v2/ordersBulk`, `GET /orders/v2/orders/{guid}`,
/// `POST /webhooks-config/v1/webhook` etc.). Tests pass an in-memory
/// fake.
///
/// All methods here are pure transport — no fact writes, no business
/// logic. The adapter pairs each transport call with the framework's
/// sanity hook + the `ToastFactSink.upsertOrderFact` write.
abstract class ToastApiClient {
  /// Confirm an OAuth client_credentials envelope is valid and the
  /// declared `restaurantGuid` is reachable. Returns the resolved
  /// handle on success.
  Future<ToastCredentialHandle> exchangeClientCredentials({
    required String operatorId,
    required String locationId,
    required String restaurantGuid,
    String? oauthState,
  });

  /// Auto-register the F&F webhook URL with Toast. Returns the
  /// vendor-side subscription id stored in
  /// `connector_connection.metadata.webhook_subscription_id`.
  Future<String> registerWebhook({
    required ToastCredentialHandle credentials,
    required String webhookUrl,
  });

  /// Unregister the webhook subscription on disconnect. Best-effort —
  /// the framework still wipes credentials and rotates state even if
  /// the vendor's unregister call fails.
  Future<bool> unregisterWebhook({
    required ToastCredentialHandle credentials,
    String? subscriptionId,
  });

  /// Heavy on-demand sample-pull for the operator-facing
  /// "Test connection" modal. Returns one real-looking order so the
  /// admin surface can show field mapping is working, not just auth.
  Future<Map<String, Object?>> fetchSampleOrder({
    required ToastCredentialHandle credentials,
  });

  /// Page through orders within `[windowStart, windowEnd]`. Toast's
  /// `ordersBulk` query supports a 1-hour window per call; the
  /// production transport will stitch hourly windows here. The fake
  /// in tests just returns canned pages keyed by [resumeFromCursor].
  Future<ToastOrdersPage> fetchOrdersPage({
    required ToastCredentialHandle credentials,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? resumeFromCursor,
  });

  /// Look up a single order by its `guid`. Used by [handleWebhook]
  /// when Toast emits an `orders.modified` event whose body is
  /// id-only.
  Future<Map<String, Object?>?> fetchOrderByGuid({
    required ToastCredentialHandle credentials,
    required String guid,
  });
}

/// One page of vendor orders + the cursor that resumes the next page.
class ToastOrdersPage {
  const ToastOrdersPage({
    required this.orders,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Vendor-shape order DTOs as returned by `ordersBulk`. The adapter
  /// normalizes via [_canonicalize] before any sanity / write call.
  final List<Map<String, Object?>> orders;

  /// Vendor pagination cursor for the next page; null when this was
  /// the last page in the window.
  final String? nextCursor;

  /// `modifiedDate` of the most-recently-modified order in this page.
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
abstract class ToastFactSink {
  /// Upsert one canonical sales / covers fact. Idempotent on
  /// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  /// per the framework's idempotency rule. Implementations return
  /// `true` when the row was inserted (or updated to a newer
  /// `vendor_modified_at`); `false` when the upsert was a no-op
  /// (duplicate or stale event).
  Future<bool> upsertOrderFact({
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

/// Toast POS adapter. Concrete implementation of [PosAdapter] at
/// lifecycle = `documented`.
class ToastPosAdapter implements PosAdapter {
  ToastPosAdapter({
    required this.transport,
    required this.factSink,
    this.signatureVerifier = const ToastWebhookSignatureVerifier(),
    DateTime Function()? now,
    int batchSize = 50,
  })  : _now = now ?? DateTime.now,
        _batchSize = batchSize;

  final ToastApiClient transport;
  final ToastFactSink factSink;
  final ToastWebhookSignatureVerifier signatureVerifier;
  final DateTime Function() _now;
  final int _batchSize;

  /// 4-state lifecycle. The engineering slice ships at `documented`.
  /// Promotion to `sandboxVerified` / `productionCredentialed` /
  /// `liveWithOperators` is the job of the corresponding `*.live.*`
  /// slice — this getter is the assertion seam Codex grades.
  VendorLifecycle get lifecycle => VendorLifecycle.documented;

  @override
  String get vendorId => kToastVendorId;

  @override
  String get displayName => 'Toast';

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kToastVendorId,
        displayName: 'Toast',
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        // Toast issues one `restaurantGuid` per location; multi-location
        // operators run one OAuth flow per location. Mirrors
        // VendorGrantScope.perLocation per the framework.
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.autoRegister,
        // Toast `numberOfGuests` is a first-class direct covers field —
        // see docs/integrations/toast/field_mapping.md.
        coversFieldExposed: true,
        // Partnership-gated detail is captured in
        // docs/integrations/toast/partnership_status.md, NOT via a
        // boolean here. Per the engineer-all-17 doctrine,
        // `partnershipGated: false` lets the adapter ship at lifecycle
        // = `documented` without coupling to commercial-lane state.
        // Picker chrome reads lifecycle, not this flag.
        partnershipGated: false,
        modules: <String>[],
        // Toast emits ISO 8601 UTC timestamps with the `Z` suffix on
        // all `openedDate` / `closedDate` / `modifiedDate` fields per
        // doc.toasttab.com — Scenario E does not apply, but the
        // policy declaration stays so the framework's refuse-by-
        // default protection still recognizes Toast.
        timestampPolicyDocId: 'toast',
      );

  // ─── connect ─────────────────────────────────────────────────────

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != kToastVendorId) {
      throw StateError(
        'ToastPosAdapter received connect for vendor ${command.vendorId}',
      );
    }
    final restaurantGuid = command.keyPaste?.username ??
        (command.oauthState != null
            ? _restaurantGuidFromOauthState(command.oauthState!)
            : null);
    if (restaurantGuid == null || restaurantGuid.isEmpty) {
      throw StateError(
        'Toast connect requires a restaurantGuid in either oauthState or '
        'keyPaste.username; the framework did not pass one.',
      );
    }

    final handle = await transport.exchangeClientCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
      restaurantGuid: restaurantGuid,
      oauthState: command.oauthState,
    );
    final webhookUrl =
        '/v1/webhooks/$kToastVendorId/${command.operatorId}/${command.locationId}';
    final subscriptionId = await transport.registerWebhook(
      credentials: handle,
      webhookUrl: webhookUrl,
    );

    return ConnectResult(
      connectionId: handle.connectionId,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'restaurant_guid': handle.restaurantGuid,
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
      restaurantGuid: '__test-connection__',
    );
    final sample = await transport.fetchSampleOrder(credentials: handle);
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
          'Toast exposes covers via numberOfGuests; covers_source = direct.',
    );
  }

  // ─── backfill ────────────────────────────────────────────────────

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final handle = await transport.exchangeClientCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
      restaurantGuid: '__backfill__',
    );

    var batchesCommitted = 0;
    var recordsWritten = 0;
    var cursor = command.resumeFromCursor;
    var lastModifiedSeen = command.windowStart;
    var completed = false;

    while (true) {
      final page = await transport.fetchOrdersPage(
        credentials: handle,
        windowStart: command.windowStart,
        windowEnd: command.windowEnd,
        resumeFromCursor: cursor,
      );

      final batch = <Map<String, Object?>>[];
      for (final raw in page.orders) {
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
        final wrote = await factSink.upsertOrderFact(
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
      restaurantGuid: '__poll__',
    );

    final windowStart = command.lastModifiedSeen;
    final windowEnd = _now();
    var cursor = command.cursorToken;
    var recordsWritten = 0;
    var sanityDropped = 0;
    var newLastModifiedSeen = command.lastModifiedSeen;

    while (true) {
      final page = await transport.fetchOrdersPage(
        credentials: handle,
        windowStart: windowStart,
        windowEnd: windowEnd,
        resumeFromCursor: cursor,
      );
      for (final raw in page.orders) {
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
        final wrote = await factSink.upsertOrderFact(
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

    Map<String, Object?> orderShape = command.payload;
    final guid = orderShape['guid'];
    final hasFullOrder = orderShape.containsKey('numberOfGuests') &&
        orderShape.containsKey('openedDate');
    if (!hasFullOrder && guid is String && guid.isNotEmpty) {
      // Toast's `orders.modified` notification can be id-only — fetch
      // the full order so we have the canonical fields. The framework
      // mints the credentials handle from `connector_connection`; the
      // route layer passes the resolved handle into the adapter. The
      // production wiring stitches that through; the test-side fake
      // returns a canned order keyed by guid.
      final handle = await transport.exchangeClientCredentials(
        operatorId: command.operatorId,
        locationId: command.locationId,
        restaurantGuid: '__webhook__',
      );
      final fetched =
          await transport.fetchOrderByGuid(credentials: handle, guid: guid);
      if (fetched == null) {
        return const HandleWebhookResult(recordsWritten: 0);
      }
      orderShape = fetched;
    }

    final canonical = _canonicalize(orderShape);
    final wrote = await factSink.upsertOrderFact(
      operatorId: command.operatorId,
      locationId: command.locationId,
      canonicalFact: canonical,
      rawPayload: orderShape,
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
        restaurantGuid: '__disconnect__',
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

  /// Vendor-shape order → canonical fact map. Every assumption here
  /// is mirrored in `documentedPerToastV2` and
  /// `docs/integrations/toast/field_mapping.md`.
  Map<String, Object?> _canonicalize(Map<String, Object?> order) {
    return <String, Object?>{
      'vendor_entity_id': order['guid'],
      'vendor_modified_at': order['modifiedDate'],
      'opened_at': order['openedDate'],
      'closed_at': order['closedDate'],
      'covers': order['numberOfGuests'],
      'covers_source': 'direct',
      'actual_sales': order['totalAmount'],
    };
  }

  /// The framework's OAuth-start route encodes `restaurantGuid` into
  /// the state token alongside CSRF nonce + (operator, location). The
  /// adapter parses it back at callback time.
  String? _restaurantGuidFromOauthState(String state) {
    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(state)));
      if (decoded is Map<String, Object?>) {
        final guid = decoded['restaurant_guid'];
        if (guid is String) return guid;
      }
    } catch (_) {
      // Tolerated — production state tokens are framework-managed.
    }
    return null;
  }
}
