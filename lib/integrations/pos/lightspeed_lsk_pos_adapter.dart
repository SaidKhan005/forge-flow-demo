// Phase 8.LSK — Lightspeed Restaurant K-Series POS adapter.
//
// Reference adapter for the Phase 8 PosAdapter framework. Engineered
// against the public Lightspeed K-Series API documentation
// (https://api-docs.lsk.lightspeed.app/, retrieved 2026-05-03) at
// lifecycle = `documented`. Live HTTP verification is deferred to the
// follow-up `8.LSK.live.sandbox` and `8.LSK.live.prod` slices when
// trial / production credentials arrive.
//
// Doctrine reference: `docs/contracts/vendor_adapter_slice_contract.md`
// + `docs/contracts/per_vendor_doc_pack_contract.md` + the per-vendor
// pack at `docs/integrations/lightspeed_lsk/`.
//
// Design constraints honored here:
//   * Sanity hook invoked BEFORE every canonical fact write in
//     `backfill` and `pollIncremental`. `handleWebhook` does NOT
//     re-call sanityHook — `InboundWebhookHandler` enforces sanity
//     inline at step 4 of its dispatch sequence.
//   * Idempotency UNIQUE on
//     `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
//     enforced by the gateway repository. The adapter passes the key
//     tuple; conflict-do-nothing is a no-op.
//   * `connector_sync_watermark.cursor_token` + `last_modified_seen`
//     persist after EACH batch commit, not after the whole backfill.
//   * Webhook signature verification lives in
//     `lightspeed_lsk_webhook_signature_verifier.dart` and uses
//     `constantTimeBytesEquals`.
//   * Production gateway impl wraps every fact write inside
//     `OperatorScopedRepository.withTenant(operatorId, locationId,
//     ...)`. Plaintext credentials never reach this file — the gateway
//     hands the adapter an opaque OAuth-token handle.
//   * Storage rule (Phase 7.55): every persisted timestamp is the
//     UTC source-truth instant + denormalized `business_date` computed
//     from `location.timezone` + `business_day_rollover_hour` via
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
import '../../services/integration/pos_adapter.dart';

// ─── Lifecycle enum (FORWARD DECLARATION) ───────────────────────────
//
// `VendorLifecycle` will live in
// `lib/services/integration/integration_adapter_common.dart` once
// `8.0.lifecycle` (Wave B's first slice) merges. Until then, every
// adapter slice in Wave B forward-declares the enum locally so that
// each adapter compiles against the same shape; the integration commit
// at Wave B close folds the duplicates into the framework. Do not
// rename or extend the variants here — they MUST mirror the contract
// in `docs/contracts/vendor_adapter_slice_contract.md` table 1.

enum VendorLifecycle {
  documented,
  sandboxVerified,
  productionCredentialed,
  liveWithOperators,
}

// ─── Documented-API constants (cite source URL + retrieval date) ────

/// Vendor id matching `connector_connection.vendor_id`.
const String kLightspeedLskVendorId = 'lightspeed_lsk';

/// Operator-facing display name used in the Vendor Connections admin
/// surface and operator dashboard chrome.
const String kLightspeedLskDisplayName = 'Lightspeed Restaurant K-Series';

/// Production API base URL.
/// Source: https://api-portal.lsk.lightspeed.app/quick-start/authentication/authorization-overview
/// Retrieved: 2026-05-03.
const String kLightspeedLskProdBaseUrl = 'https://api.lsk.lightspeed.app';

/// Trial / sandbox API base URL.
/// Source: https://api-portal.lsk.lightspeed.app/quick-start/authentication/authorization-overview
/// Retrieved: 2026-05-03.
const String kLightspeedLskSandboxBaseUrl =
    'https://api.trial.lsk.lightspeed.app';

/// Documented API version string the adapter is pinned to. Embedded
/// in the `documented_per_lightspeed_lsk_<api_version>` constant in
/// fixtures so a future shape change is detectable from the diff.
const String kLightspeedLskApiVersion = 'f-v2-2026-05';

// ─── Vendor data shape (canonical -> vendor field reference) ────────
//
// Single source of truth for the field mapping the adapter applies.
// Mirrored row-for-row in:
//   * `docs/integrations/lightspeed_lsk/field_mapping.md`
//   * `test/integrations/pos/fixtures/lightspeed_lsk_orders_fixture.dart`
//     `documented_per_lightspeed_lsk_f_v2_2026_05` constant.
// Codex grades the diff between these three. A row added here without
// the doc + fixture row triggers FOLLOW-UP NEEDED.

/// Vendor field paths the adapter reads from a sale object returned
/// by `GET /f/v2/business-location/{businessLocationId}/sales`.
class LightspeedLskSaleFields {
  const LightspeedLskSaleFields._();

  /// `nbCovers` — number of guests on the order. Lightspeed exposes
  /// this as a double (fractional covers are theoretically possible);
  /// the adapter rounds half-up to the nearest int because
  /// `canonical.covers` is `int`.
  static const String covers = 'nbCovers';

  /// `timeOfOpening` — ISO-8601 with `Z`. UTC instant.
  static const String openedAt = 'timeOfOpening';

  /// `timeClosed` — ISO-8601 with `Z`. UTC instant.
  static const String closedAt = 'timeClosed';

  /// `accountFiscId` — stable order id (e.g., `A65315.17`).
  static const String entityId = 'accountFiscId';

  /// `payments` — array containing per-payment amounts. The adapter
  /// sums `payments[].netAmountWithTax` to produce `actual_sales`.
  static const String paymentsArray = 'payments';

  /// `payments[].netAmountWithTax` — decimal string, **already in
  /// major units (dollars), NOT cents** per the K-Series Sales
  /// endpoint reference. Documented in `field_mapping.md` Ambiguity
  /// calls; the `*.live.sandbox` slice will verify on real data.
  static const String paymentNetAmountWithTax = 'netAmountWithTax';
}

// ─── Test-double seams ───────────────────────────────────────────────
//
// The adapter consumes four narrow, well-typed gateways. Production
// wires Postgres-backed implementations that wrap every write in
// `OperatorScopedRepository.withTenant`; tests pass in-memory fakes
// (`test/integrations/pos/lightspeed_lsk_pos_adapter_test.dart`).
//
// The adapter NEVER opens its own DB connection, NEVER imports
// `package:postgres`, and NEVER touches plaintext credentials.

/// Persistence + binding-lookup surface the adapter drives. The
/// production impl wraps every write in
/// `OperatorScopedRepository.withTenant(...)` so RLS is the backup
/// defense and the repository pattern is the primary defense.
abstract class LightspeedLskGateway {
  /// Look up the per-(operator, location) connection binding for the
  /// inbound poll / webhook / test-connection flow. Returns null when
  /// no connection exists.
  Future<LightspeedLskConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
  });

  /// Disconnect-flow lookup: as [lookupBinding] but also includes the
  /// webhook subscription id so the adapter can call
  /// `LightspeedLskWebhookClient.unregister` upstream.
  Future<LightspeedLskDisconnectBinding?> lookupDisconnectBinding({
    required String operatorId,
    required String locationId,
  });

  /// Persist one canonical sales row. Returns `true` when the row was
  /// inserted; `false` when the idempotency UNIQUE on
  /// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  /// short-circuited the upsert (replay arrived twice).
  Future<bool> writeSalesFact({
    required TenantContext tenant,
    required String connectionId,
    required String vendorEntityId,
    required DateTime openedAtUtc,
    required DateTime closedAtUtc,
    required int covers,
    required double actualSales,
    required String restaurantTimezone,
    required int businessDayRolloverHour,
    required DateTime vendorModifiedAtUtc,
  });

  /// Update `connector_sync_watermark` cursor + last_modified_seen.
  /// MUST be called after every batch commit — not at the end of
  /// the whole backfill.
  Future<void> updateWatermark({
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeenUtc,
  });

  /// Persist a connector_connection row + capture the vendor's
  /// `business_id` claim in metadata for the binding cross-check.
  /// Returns the new connection id.
  Future<String> upsertConnection({
    required TenantContext tenant,
    required String vendorBusinessId,
    required String accessTokenCredentialId,
    required String refreshTokenCredentialId,
    required DateTime tokenExpiresAtUtc,
  });

  /// Append a `connector_sync_log` row.
  Future<void> appendSyncLog({
    required String connectionId,
    required String eventKind,
    int? recordsCount,
    String? errorMessage,
  });

  /// Wipe credentials + flip `connector_connection.status` to
  /// `disconnected`. Watermark is preserved for reconnect.
  Future<void> wipeCredentialsAndDisconnect({
    required TenantContext tenant,
    required String connectionId,
    required DisconnectReason reason,
  });
}

/// Connection binding handed to the adapter for poll / backfill /
/// webhook / test-connection flows.
class LightspeedLskConnectionBinding {
  const LightspeedLskConnectionBinding({
    required this.connectionId,
    required this.businessId,
    required this.accessTokenCredentialId,
  });

  final String connectionId;

  /// Vendor `business_id` claim — matches
  /// `connector_connection.metadata.business_id`.
  final String businessId;

  /// Opaque credential id for the access token; the production
  /// gateway resolves it to ciphertext server-side and never hands
  /// the plaintext token to the adapter.
  final String accessTokenCredentialId;
}

/// Same as [LightspeedLskConnectionBinding] but carries the webhook
/// subscription id so the adapter can call
/// `LightspeedLskWebhookClient.unregister` upstream on disconnect.
class LightspeedLskDisconnectBinding extends LightspeedLskConnectionBinding {
  const LightspeedLskDisconnectBinding({
    required super.connectionId,
    required super.businessId,
    required super.accessTokenCredentialId,
    required this.webhookSubscriptionId,
  });

  final String webhookSubscriptionId;
}

/// OAuth client — opaque to the adapter. Production impl reads the
/// encrypted ciphertext from `vendor_credentials` via the gateway;
/// tests inject a fake.
abstract class LightspeedLskOAuthClient {
  /// Complete the authorization-code exchange (vendor returns
  /// `access_token`, `refresh_token`, `expires_in`,
  /// `refresh_expires_in`, `scope`, `token_type`). Returns the
  /// vendor-side `business_id` claim from the access token plus
  /// opaque credential ids the gateway can resolve later.
  Future<LightspeedLskTokenExchangeResult> completeAuthorization({
    required String oauthState,
  });

  /// Hits `POST /oauth/token` with `grant_type=refresh_token`. Used
  /// by the framework's `oauth_refresh_cron`. Documented in
  /// `docs/integrations/lightspeed_lsk/oauth_shape.md`.
  Future<LightspeedLskTokenExchangeResult> refresh({
    required String refreshTokenCredentialId,
  });

  /// Calls the vendor's `/oauth/revoke` so the operator's grant is
  /// invalidated upstream on disconnect.
  Future<void> revoke({required String accessTokenCredentialId});
}

class LightspeedLskTokenExchangeResult {
  const LightspeedLskTokenExchangeResult({
    required this.businessId,
    required this.accessTokenCredentialId,
    required this.refreshTokenCredentialId,
    required this.tokenExpiresAtUtc,
    required this.scopes,
  });

  final String businessId;
  final String accessTokenCredentialId;
  final String refreshTokenCredentialId;
  final DateTime tokenExpiresAtUtc;
  final List<String> scopes;
}

/// Webhook subscription client. Production hits
/// `PUT /o/wh/1/webhook`; tests pass a fake.
abstract class LightspeedLskWebhookClient {
  Future<LightspeedLskWebhookSubscription> subscribe({
    required String accessTokenCredentialId,
    required String webhookUrl,
    required String endpointId,
  });

  Future<void> unregister({
    required String accessTokenCredentialId,
    required String subscriptionId,
  });
}

class LightspeedLskWebhookSubscription {
  const LightspeedLskWebhookSubscription({
    required this.subscriptionId,
    required this.signingSecretCredentialId,
  });

  final String subscriptionId;
  final String signingSecretCredentialId;
}

/// Sales-pull client. Production hits
/// `GET /f/v2/business-location/{businessLocationId}/sales`; tests
/// pass a fixture-backed fake.
abstract class LightspeedLskOrdersClient {
  /// Fetch one sales page. `cursorToken == null` means "first page".
  /// Pagination is cursor-based via `nextPageToken`.
  Future<LightspeedLskSalesPage> fetchSalesPage({
    required String accessTokenCredentialId,
    required String businessId,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required int pageSize,
    String? cursorToken,
  });

  /// One real sample order for the test-connection screen so the
  /// operator can eyeball the field mapping.
  Future<Map<String, Object?>> fetchSampleOrder({
    required String accessTokenCredentialId,
    required String businessId,
  });
}

class LightspeedLskSalesPage {
  const LightspeedLskSalesPage({
    required this.sales,
    required this.nextPageToken,
  });

  final List<Map<String, Object?>> sales;

  /// `null` when this is the last page.
  final String? nextPageToken;
}

// ─── Adapter ────────────────────────────────────────────────────────

/// Lightspeed Restaurant K-Series POS adapter.
///
/// Implements every framework seam declared in [PosAdapter] against
/// the documented Lightspeed K-Series API shape. Live HTTP wiring is
/// the `*.live.sandbox` / `*.live.prod` slice's job; this slice ships
/// fixture-backed coverage of every code path.
class LightspeedLskPosAdapter implements PosAdapter {
  LightspeedLskPosAdapter({
    required this.gateway,
    required this.oauthClient,
    required this.webhookClient,
    required this.ordersClient,
    required this.restaurantTimezone,
    required this.businessDayRolloverHour,
    required this.webhookUrl,
    int batchPageSize = _kBackfillPageSize,
    DateTime Function()? now,
    IanaTimezoneConverter? converter,
  })  : _now = now ?? DateTime.now,
        _converter = converter ?? IanaTimezoneConverter.shared,
        _batchPageSize = batchPageSize;

  static const int _kBackfillPageSize = 50; // K-Series default
  static const String _kEndpointId = 'forge-flow-lsk';

  final LightspeedLskGateway gateway;
  final LightspeedLskOAuthClient oauthClient;
  final LightspeedLskWebhookClient webhookClient;
  final LightspeedLskOrdersClient ordersClient;

  /// IANA timezone of the restaurant (e.g., `America/Toronto`). Used
  /// by [IanaTimezoneConverter] to compute `business_date` per the
  /// Phase 7.55 storage rule.
  final String restaurantTimezone;

  /// `business_day_rollover_hour` in `[0, 23]`.
  final int businessDayRolloverHour;

  /// Operator-facing webhook URL. Auto-registered with Lightspeed via
  /// `webhookClient.subscribe` on connect.
  final String webhookUrl;

  final DateTime Function() _now;
  final IanaTimezoneConverter _converter;
  final int _batchPageSize;

  @override
  String get vendorId => kLightspeedLskVendorId;

  @override
  String get displayName => kLightspeedLskDisplayName;

  /// Lifecycle declaration. Published as a getter on the adapter
  /// pending Wave B's `8.0.lifecycle` slice (which moves the field
  /// onto [VendorCapabilityProfile]). The contract bar in
  /// `vendor_adapter_slice_contract.md` is satisfied by both surfaces
  /// declaring `documented` at slice ship.
  VendorLifecycle get lifecycle => VendorLifecycle.documented;

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kLightspeedLskVendorId,
        displayName: kLightspeedLskDisplayName,
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        // Lightspeed K-Series scopes per `business_id` (one OAuth grant
        // == one vendor location).
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.autoRegister,
        // K-Series exposes `nbCovers` directly; covers source = direct.
        coversFieldExposed: true,
        // Public OAuth, no partnership review required.
        partnershipGated: false,
        modules: <String>[],
        // The vendor-timestamp policy entry lives in the framework
        // catalog and declares `asUtc` for K-Series.
        timestampPolicyDocId: 'vendor_timestamp_policy.lightspeed_lsk',
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
    final state = command.oauthState;
    if (state == null || state.isEmpty) {
      throw ArgumentError.value(
        state,
        'command.oauthState',
        'Lightspeed K-Series uses authorization_code OAuth; oauthState '
            'must be set on the callback.',
      );
    }
    final tenant = TenantContext(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
    );

    final tokens = await oauthClient.completeAuthorization(oauthState: state);

    final connectionId = await gateway.upsertConnection(
      tenant: tenant,
      vendorBusinessId: tokens.businessId,
      accessTokenCredentialId: tokens.accessTokenCredentialId,
      refreshTokenCredentialId: tokens.refreshTokenCredentialId,
      tokenExpiresAtUtc: tokens.tokenExpiresAtUtc,
    );

    await webhookClient.subscribe(
      accessTokenCredentialId: tokens.accessTokenCredentialId,
      webhookUrl: webhookUrl,
      endpointId: _kEndpointId,
    );

    await gateway.appendSyncLog(
      connectionId: connectionId,
      eventKind: 'connect',
    );

    return ConnectResult(
      connectionId: connectionId,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'business_id': tokens.businessId,
        'scopes': tokens.scopes,
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
    final sample = await ordersClient.fetchSampleOrder(
      accessTokenCredentialId: binding.accessTokenCredentialId,
      businessId: binding.businessId,
    );
    stopwatch.stop();

    final mapping = _projectFieldMapping(sample);

    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: mapping,
      elapsedMs: stopwatch.elapsedMilliseconds,
      note: 'Covers source: direct (Lightspeed K-Series exposes nbCovers).',
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
      final page = await ordersClient.fetchSalesPage(
        accessTokenCredentialId: binding.accessTokenCredentialId,
        businessId: binding.businessId,
        windowStartUtc: command.windowStart,
        windowEndUtc: command.windowEnd,
        pageSize: _batchPageSize,
        cursorToken: cursor,
      );

      for (final sale in page.sales) {
        final mapped = _projectCanonicalRecord(sale);
        if (mapped == null) {
          // Malformed payload — drop at adapter boundary per V1 lean
          // cut 2. One log row only.
          await gateway.appendSyncLog(
            connectionId: binding.connectionId,
            eventKind: 'parse_drop',
            errorMessage:
                'sale payload missing required field; dropped at adapter boundary',
          );
          continue;
        }
        final ok = await command.sanityHook(
          vendorEventId: mapped.vendorEntityId,
          payload: mapped.sanityPayload,
          isDeliberateBackfill: true,
        );
        if (!ok) {
          // Framework already wrote sanity_log + connector_sync_log;
          // skip the canonical fact write.
          continue;
        }
        final inserted = await gateway.writeSalesFact(
          tenant: tenant,
          connectionId: binding.connectionId,
          vendorEntityId: mapped.vendorEntityId,
          openedAtUtc: mapped.openedAtUtc,
          closedAtUtc: mapped.closedAtUtc,
          covers: mapped.covers,
          actualSales: mapped.actualSales,
          restaurantTimezone: restaurantTimezone,
          businessDayRolloverHour: businessDayRolloverHour,
          vendorModifiedAtUtc: mapped.vendorModifiedAtUtc,
        );
        if (inserted) recordsWritten += 1;
        if (mapped.vendorModifiedAtUtc.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = mapped.vendorModifiedAtUtc;
        }
      }

      // Per-batch commit. Crash between fetch + commit is acceptable
      // (idempotency UNIQUE absorbs replay); crash AFTER commit means
      // resume picks up at this cursor.
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
      final page = await ordersClient.fetchSalesPage(
        accessTokenCredentialId: binding.accessTokenCredentialId,
        businessId: binding.businessId,
        windowStartUtc: command.lastModifiedSeen,
        windowEndUtc: tickEnd,
        pageSize: _batchPageSize,
        cursorToken: cursor,
      );

      for (final sale in page.sales) {
        final mapped = _projectCanonicalRecord(sale);
        if (mapped == null) {
          await gateway.appendSyncLog(
            connectionId: binding.connectionId,
            eventKind: 'parse_drop',
            errorMessage:
                'sale payload missing required field; dropped at adapter boundary',
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
        final inserted = await gateway.writeSalesFact(
          tenant: tenant,
          connectionId: binding.connectionId,
          vendorEntityId: mapped.vendorEntityId,
          openedAtUtc: mapped.openedAtUtc,
          closedAtUtc: mapped.closedAtUtc,
          covers: mapped.covers,
          actualSales: mapped.actualSales,
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
    // binding, and idempotency BEFORE this call (steps 1-4 of
    // InboundWebhookHandler.dispatch). Sanity is enforced inline at
    // step 4 — do NOT re-call sanityHook here.
    final tenant = TenantContext(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    final binding = await _requireBinding(command.operatorId, command.locationId);
    final mapped = _projectCanonicalRecord(command.payload);
    if (mapped == null) {
      // Malformed payload: drop at adapter boundary; framework writes
      // a `connector_sync_log` row via the dispatch unwind.
      return const HandleWebhookResult(recordsWritten: 0);
    }
    final inserted = await gateway.writeSalesFact(
      tenant: tenant,
      connectionId: binding.connectionId,
      vendorEntityId: mapped.vendorEntityId,
      openedAtUtc: mapped.openedAtUtc,
      closedAtUtc: mapped.closedAtUtc,
      covers: mapped.covers,
      actualSales: mapped.actualSales,
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
      // Already disconnected. Idempotent no-op.
      return const DisconnectResult(
        credentialsWiped: false,
        webhookUnregistered: false,
        watermarkPreserved: true,
      );
    }

    bool webhookUnregistered = false;
    try {
      await webhookClient.unregister(
        accessTokenCredentialId: binding.accessTokenCredentialId,
        subscriptionId: binding.webhookSubscriptionId,
      );
      webhookUnregistered = true;
    } catch (_) {
      // Vendor-side unregister failed — operator can revoke from
      // Lightspeed Back Office. Still proceed with local credential
      // wipe.
    }

    try {
      await oauthClient.revoke(
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

    return DisconnectResult(
      credentialsWiped: true,
      webhookUnregistered: webhookUnregistered,
      watermarkPreserved: true,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<LightspeedLskConnectionBinding> _requireBinding(
    String operatorId,
    String locationId,
  ) async {
    final binding = await gateway.lookupBinding(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (binding == null) {
      throw StateError(
        'no Lightspeed K-Series connection on file for '
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
        'covers': null,
        'opened_at': null,
        'closed_at': null,
        'actual_sales': null,
        'note': 'sample missing required fields',
      };
    }
    return <String, Object?>{
      'covers': mapped.covers,
      'opened_at': mapped.openedAtUtc.toIso8601String(),
      'closed_at': mapped.closedAtUtc.toIso8601String(),
      'actual_sales': mapped.actualSales,
      'vendor_entity_id': mapped.vendorEntityId,
      'vendor_modified_at': mapped.vendorModifiedAtUtc.toIso8601String(),
    };
  }

  /// Map one Lightspeed sale to a canonical fact record. Returns null
  /// when the payload is missing required fields — the caller drops
  /// it at the adapter boundary with one `connector_sync_log` row.
  _CanonicalSale? _projectCanonicalRecord(Map<String, Object?> sale) {
    final entityId = sale[LightspeedLskSaleFields.entityId];
    final coversRaw = sale[LightspeedLskSaleFields.covers];
    final openedRaw = sale[LightspeedLskSaleFields.openedAt];
    final closedRaw = sale[LightspeedLskSaleFields.closedAt];
    final paymentsRaw = sale[LightspeedLskSaleFields.paymentsArray];

    if (entityId is! String || entityId.isEmpty) return null;
    if (openedRaw is! String) return null;
    final openedAt = DateTime.tryParse(openedRaw)?.toUtc();
    if (openedAt == null) return null;

    final closedAt = closedRaw is String
        ? DateTime.tryParse(closedRaw)?.toUtc() ?? openedAt
        : openedAt;

    int covers = 0;
    if (coversRaw is num) {
      covers = coversRaw.round();
    }

    double actualSales = 0.0;
    if (paymentsRaw is List) {
      for (final entry in paymentsRaw) {
        if (entry is Map) {
          final amount = entry[LightspeedLskSaleFields.paymentNetAmountWithTax];
          if (amount is num) {
            actualSales += amount.toDouble();
          } else if (amount is String) {
            final parsed = double.tryParse(amount);
            if (parsed != null) actualSales += parsed;
          }
        }
      }
    }

    final modified = closedAt.isAfter(openedAt) ? closedAt : openedAt;

    // Validate the IANA timezone projection — a misconfigured location
    // surfaces here rather than at the gateway write boundary.
    _converter.toBusinessDate(
      restaurantTimezone: restaurantTimezone,
      businessDayRolloverHour: businessDayRolloverHour,
      instant: openedAt,
    );

    return _CanonicalSale(
      vendorEntityId: entityId,
      openedAtUtc: openedAt,
      closedAtUtc: closedAt,
      covers: covers,
      actualSales: double.parse(actualSales.toStringAsFixed(2)),
      vendorModifiedAtUtc: modified,
    );
  }
}

class _CanonicalSale {
  const _CanonicalSale({
    required this.vendorEntityId,
    required this.openedAtUtc,
    required this.closedAtUtc,
    required this.covers,
    required this.actualSales,
    required this.vendorModifiedAtUtc,
  });

  final String vendorEntityId;
  final DateTime openedAtUtc;
  final DateTime closedAtUtc;
  final int covers;
  final double actualSales;
  final DateTime vendorModifiedAtUtc;

  Map<String, Object?> get sanityPayload => <String, Object?>{
        'opened_at': openedAtUtc.toIso8601String(),
        'closed_at': closedAtUtc.toIso8601String(),
      };
}
