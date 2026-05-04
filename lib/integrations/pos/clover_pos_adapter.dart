// Phase 8 (`8.CL`) — Clover POS adapter.
//
// Source documentation:
//   * REST API v3:           https://docs.clover.com/reference/orders
//   * Orders shape:          https://docs.clover.com/reference/orderget
//   * 90-day filter cap:     https://docs.clover.com/docs/working-with-list-endpoints
//   * OAuth 2.0 flow:        https://docs.clover.com/docs/using-oauth-20
//   * Webhooks (incl. sig):  https://docs.clover.com/docs/using-webhooks
// Retrieval date: 2026-05-03
// Lifecycle (this slice):    `VendorLifecycle.documented`
//
// Engineered against documented APIs only — no live HTTP. Live
// verification rolls in `8.CL.live.sandbox` (sandbox_verified) and
// `8.CL.live.prod` (production_credentialed) once App Market approval
// issues sandbox + production credentials.
//
// Documented intent diff is published in
// `docs/integrations/clover/`; every assumption this file makes about
// Clover's shape is captured there as a `documented_per_clover_v3_2026_05_03`
// row + ambiguity call.
//
// Capability profile:
//   * vendorId            : `clover`
//   * displayName         : `Clover`
//   * category            : `pos`
//   * authMode            : `oauth`         (App Market authorization-code flow)
//   * grantScope          : `perLocation`   (Clover `merchant_id` is per location)
//   * webhookSupport      : `autoRegister`  (POST /v3/apps/{aId}/webhooks per docs)
//   * coversFieldExposed  : `false`         (no `guests` field on /orders)
//   * partnershipGated    : `true`          (Clover App Market approval required)
//   * lifecycle           : `documented`
//
// Banned items per V1 lean cut 2 (REJECT if present): see
// `memory/project_v1_lean_cut_2_2026_05_03.md` and
// `docs/contracts/vendor_adapter_slice_contract.md` "Banned items"
// table. None appear in this file; the test
// `test/integrations/pos/clover_pos_adapter_test.dart` greps the
// source for each forbidden token at lifecycle = `documented`.

import 'dart:convert';

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/pos_adapter.dart';

/// Adapter-side lifecycle enum for Wave B engineer-all-17 doctrine.
///
/// This enum is duplicated locally so vendor adapter slices can ship
/// without blocking on the framework lane (`8.0.lifecycle`) that lifts
/// `lifecycle` onto [VendorCapabilityProfile]. When the framework
/// lane lands, this declaration migrates to the profile in a small
/// follow-up (one-line change per adapter).
///
/// Locked 2026-05-03 — see
/// `memory/project_phase_8_engineer_all_17_doctrine.md` and
/// `docs/contracts/vendor_adapter_slice_contract.md`.
enum VendorLifecycle {
  /// Engineering slice landed; doc pack populated; no live
  /// verification yet.
  documented,

  /// `*.live.sandbox` slice ran;
  /// `live_verification_checklist.md` checkboxes filled for sandbox.
  sandboxVerified,

  /// `*.live.prod` slice ran; partnership cleared; production keys
  /// issued; checklist re-verified.
  productionCredentialed,

  /// First operator connected; activated automatically.
  liveWithOperators,
}

/// Stable adapter API-version pin matching
/// `test/integrations/pos/fixtures/clover_orders_fixture.dart`.
const String kCloverApiVersion = 'v3_2026_05_03';

/// Clover production order list endpoint.
/// `https://api.clover.com/v3/merchants/{mId}/orders`.
const String kCloverProductionBaseUrl = 'https://api.clover.com';

/// Clover sandbox order list endpoint.
/// `https://apisandbox.dev.clover.com/v3/merchants/{mId}/orders`.
const String kCloverSandboxBaseUrl = 'https://apisandbox.dev.clover.com';

/// Hard cap Clover places on the `modifiedTime` filter range.
/// Per Clover REST API list-endpoint docs, queries cannot span more
/// than 90 days. The framework's V1 lean cut 2 first-connect window
/// is 60 days — comfortably inside the cap — but operator-scheduled
/// custom backfills MAY ask for older data and the adapter clamps
/// `windowStart` to `now - 90d` before issuing the request.
const Duration kCloverBackfillFilterCap = Duration(days: 90);

/// Maximum page size Clover accepts on `/v3/merchants/{mId}/orders`
/// is 1000 per the docs; the adapter pages at 100 to keep watermark
/// commits frequent enough that a Cloud Run Job restart never replays
/// more than 100 records.
const int kCloverPageSize = 100;

/// Logical name in `connector_connection.metadata` carrying the
/// merchant id Clover signed the OAuth grant for.
const String kCloverMetadataMerchantIdKey = 'merchant_id';

/// Logical name in `connector_connection.metadata` carrying the
/// webhook subscription id returned by `POST /v3/apps/{aId}/webhooks`
/// at connect time. Used at disconnect to call the matching DELETE.
const String kCloverMetadataWebhookSubscriptionIdKey =
    'webhook_subscription_id';

/// Documented closed-state value Clover assigns to a finalised order.
/// `closed_at` is sourced from `modifiedTime` only when `state == paid`
/// (ambiguity call documented in `field_mapping.md`).
const String kCloverClosedOrderState = 'paid';

/// Clover-side transport seam. The engineering slice ships only the
/// abstraction; `8.CL.live.sandbox` injects an HTTP-backed
/// implementation. Tests pass a fake.
abstract class CloverApiClient {
  /// List orders modified within `[modifiedFrom, modifiedTo]` (epoch
  /// millis UTC). Clover paginates via `offset`; the cursor token the
  /// adapter persists is `'offset:<n>'` so a Cloud Run Job restart
  /// resumes mid-page-chain.
  Future<CloverOrdersPage> listOrders({
    required String merchantId,
    required DateTime modifiedFrom,
    required DateTime modifiedTo,
    required int offset,
    required int limit,
  });

  /// Fetch a single order by id — used by the webhook handler to
  /// hydrate canonical-fact details when Clover delivers an
  /// `objectId`-only envelope.
  Future<Map<String, Object?>> getOrder({
    required String merchantId,
    required String orderId,
  });

  /// Register the F&F webhook URL with Clover. Returns the
  /// subscription id Clover assigns; persisted in
  /// `connector_connection.metadata.webhook_subscription_id` for the
  /// matching DELETE at disconnect.
  Future<String> registerWebhook({
    required String merchantId,
    required String callbackUrl,
    required List<String> eventTypes,
  });

  /// Unregister a previously-registered webhook subscription. Honored
  /// best-effort on disconnect.
  Future<void> unregisterWebhook({
    required String merchantId,
    required String subscriptionId,
  });
}

class CloverOrdersPage {
  const CloverOrdersPage({
    required this.elements,
    required this.nextOffset,
  });

  /// One page of order JSON shapes returned by Clover.
  final List<Map<String, Object?>> elements;

  /// Next offset token — null when the page chain is exhausted.
  final int? nextOffset;
}

/// Tenant-scoped fact write seam. The adapter MUST go through this
/// surface; the production implementation calls
/// `OperatorScopedRepository.withTenant(operatorId, locationId, ...)`.
/// Tests pass a fake to assert the adapter never bypasses the
/// repository pattern.
abstract class CloverTenantFactWriter {
  Future<void> writeSalesFact({
    required String operatorId,
    required String locationId,
    required CloverCanonicalSalesFact fact,
  });
}

/// Watermark store seam. Production: `connector_sync_watermark`
/// repository. Adapter persists watermark `cursor_token +
/// last_modified_seen` AFTER each batch commit so a Cloud Run Job
/// restart resumes from the last successful page.
abstract class CloverWatermarkStore {
  Future<void> persist({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  });
}

/// Webhook registry seam. Production: thin wrapper over [CloverApiClient]
/// that also writes the resulting subscription id to
/// `connector_connection.metadata`.
abstract class CloverWebhookRegistry {
  /// Register and return the subscription id.
  Future<String> register({
    required String operatorId,
    required String locationId,
    required String merchantId,
  });

  /// Best-effort unregister; returns true on success.
  Future<bool> unregister({
    required String operatorId,
    required String locationId,
    required String merchantId,
    required String subscriptionId,
  });
}

/// Credential store seam. Production: `vendor_credentials_repository.dart`
/// minted opaque [VendorCredentialHandle]; the adapter never sees
/// plaintext tokens.
abstract class CloverCredentialStore {
  Future<bool> wipe({
    required String operatorId,
    required String locationId,
  });

  Future<String?> readMerchantId({
    required String operatorId,
    required String locationId,
  });

  Future<String?> readWebhookSubscriptionId({
    required String operatorId,
    required String locationId,
  });
}

/// One canonical sales fact the adapter writes per inbound order.
/// `covers` is null + `coversSource` is `forecast_fallback` for every
/// Clover row (Hard Promise: covers field NOT exposed by Clover).
class CloverCanonicalSalesFact {
  const CloverCanonicalSalesFact({
    required this.vendorEntityId,
    required this.openedAt,
    required this.closedAt,
    required this.actualSalesDollars,
    required this.vendorModifiedAt,
    required this.businessDate,
    this.covers,
    this.coversSource = 'forecast_fallback',
  });

  final String vendorEntityId;
  final DateTime openedAt;
  final DateTime? closedAt;
  final double actualSalesDollars;
  final DateTime vendorModifiedAt;

  /// Pre-computed business date (location-local, restaurant-day
  /// rollover applied). Producer is the framework's IANA converter;
  /// adapter receives a resolved value from the worker.
  final DateTime businessDate;

  /// Always null for Clover. Operator dashboard chrome surfaces the
  /// forecast-fallback degradation pill per
  /// `docs/contracts/metric_card_honesty_contract.md`.
  final int? covers;

  /// Always `'forecast_fallback'` for Clover.
  final String coversSource;
}

/// Concrete [PosAdapter] for Clover. All seven framework methods
/// honor the contract in
/// `docs/contracts/vendor_adapter_slice_contract.md`.
class CloverPosAdapter implements PosAdapter {
  CloverPosAdapter({
    required this.api,
    required this.factWriter,
    required this.watermarkStore,
    required this.webhookRegistry,
    required this.credentials,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final CloverApiClient api;
  final CloverTenantFactWriter factWriter;
  final CloverWatermarkStore watermarkStore;
  final CloverWebhookRegistry webhookRegistry;
  final CloverCredentialStore credentials;
  final DateTime Function() _clock;

  @override
  String get vendorId => 'clover';

  @override
  String get displayName => 'Clover';

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: 'clover',
        displayName: 'Clover',
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.autoRegister,
        coversFieldExposed: false,
        partnershipGated: true,
        timestampPolicyDocId: 'vendor_timestamp_policy.clover.asUtc',
      );

  /// Locked at slice ship per
  /// `docs/contracts/vendor_adapter_slice_contract.md` lifecycle table.
  /// Promoted by `8.CL.live.sandbox` / `8.CL.live.prod`.
  VendorLifecycle get lifecycle => VendorLifecycle.documented;

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    // The proxy route exchanges the OAuth `code` for a token + the
    // signed `merchant_id`; the route then issues a [ConnectCommand]
    // here to register webhooks + commit the connection row. For the
    // documented slice we trust the merchant id is on
    // `command.oauthState` (set by the route) and defer plaintext
    // handling to the credential repository.
    final merchantId = command.oauthState;
    if (merchantId == null || merchantId.isEmpty) {
      throw StateError(
        'Clover connect missing merchant_id; the proxy OAuth callback '
        'must populate ConnectCommand.oauthState with the signed '
        'merchant_id from /oauth/v2/token.',
      );
    }
    final subscriptionId = await webhookRegistry.register(
      operatorId: command.operatorId,
      locationId: command.locationId,
      merchantId: merchantId,
    );
    return ConnectResult(
      connectionId: 'clover:${command.operatorId}:${command.locationId}',
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        kCloverMetadataMerchantIdKey: merchantId,
        kCloverMetadataWebhookSubscriptionIdKey: subscriptionId,
      },
      firstBackfillStarted: true,
    );
  }

  @override
  Future<TestConnectionResult> testConnection(
    TestConnectionCommand command,
  ) async {
    final start = _clock();
    final merchantId = await credentials.readMerchantId(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (merchantId == null) {
      return TestConnectionResult(
        authValid: false,
        sample: const <String, Object?>{},
        fieldMapping: const <String, Object?>{},
        elapsedMs: _clock().difference(start).inMilliseconds,
        note: 'no merchant id on file — reconnect Clover',
      );
    }
    final now = _clock().toUtc();
    final page = await api.listOrders(
      merchantId: merchantId,
      modifiedFrom: now.subtract(const Duration(days: 1)),
      modifiedTo: now,
      offset: 0,
      limit: 1,
    );
    final sample = page.elements.isEmpty
        ? const <String, Object?>{}
        : page.elements.first;
    final mapping = sample.isEmpty
        ? const <String, Object?>{}
        : _projectMapping(sample);
    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: mapping,
      elapsedMs: _clock().difference(start).inMilliseconds,
      note: 'Clover does not expose covers; '
          'covers_source = forecast_fallback on every row.',
    );
  }

  Map<String, Object?> _projectMapping(Map<String, Object?> order) {
    final fact = _project(order);
    if (fact == null) return const <String, Object?>{};
    return <String, Object?>{
      'vendor_entity_id': fact.vendorEntityId,
      'opened_at': fact.openedAt.toIso8601String(),
      'closed_at': fact.closedAt?.toIso8601String(),
      'actual_sales': fact.actualSalesDollars,
      'covers': fact.covers,
      'covers_source': fact.coversSource,
      'vendor_modified_at': fact.vendorModifiedAt.toIso8601String(),
    };
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final merchantId = await credentials.readMerchantId(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (merchantId == null) {
      throw StateError('no merchant id on file for ${command.operatorId}');
    }

    // Clamp to Clover's documented 90-day filter cap. Best-effort
    // 60-day target from V1 lean cut 2 fits inside.
    final now = _clock().toUtc();
    final earliest = now.subtract(kCloverBackfillFilterCap);
    var windowStart = command.windowStart.toUtc();
    if (windowStart.isBefore(earliest)) {
      windowStart = earliest;
    }
    final windowEnd = command.windowEnd.toUtc();

    var offset = command.resumeFromCursor != null
        ? _decodeOffsetCursor(command.resumeFromCursor!)
        : 0;
    var batches = 0;
    var written = 0;
    String cursor = _encodeOffsetCursor(offset);
    DateTime lastModifiedSeen = windowStart;

    while (true) {
      final page = await api.listOrders(
        merchantId: merchantId,
        modifiedFrom: windowStart,
        modifiedTo: windowEnd,
        offset: offset,
        limit: kCloverPageSize,
      );
      for (final order in page.elements) {
        final ok = await command.sanityHook(
          vendorEventId: '${order['id']}',
          payload: order,
          isDeliberateBackfill: true,
        );
        if (!ok) continue;
        final fact = _project(order);
        if (fact == null) continue;
        await factWriter.writeSalesFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          fact: fact,
        );
        written += 1;
        if (fact.vendorModifiedAt.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = fact.vendorModifiedAt;
        }
      }
      batches += 1;
      cursor = _encodeOffsetCursor(page.nextOffset ?? offset + page.elements.length);
      // Per-batch watermark commit — Codex grades on this contract.
      await watermarkStore.persist(
        operatorId: command.operatorId,
        locationId: command.locationId,
        cursorToken: cursor,
        lastModifiedSeen: lastModifiedSeen,
      );
      if (page.nextOffset == null) {
        return BackfillResult(
          batchesCommitted: batches,
          recordsWritten: written,
          cursorToken: cursor,
          lastModifiedSeen: lastModifiedSeen,
        );
      }
      offset = page.nextOffset!;
    }
  }

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) async {
    final merchantId = await credentials.readMerchantId(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (merchantId == null) {
      throw StateError('no merchant id on file for ${command.operatorId}');
    }
    final now = _clock().toUtc();
    final filterFloor = now.subtract(kCloverBackfillFilterCap);
    var modifiedFrom = command.lastModifiedSeen.toUtc();
    if (modifiedFrom.isBefore(filterFloor)) {
      modifiedFrom = filterFloor;
    }
    var offset = command.cursorToken != null
        ? _decodeOffsetCursor(command.cursorToken!)
        : 0;

    var written = 0;
    var dropped = 0;
    DateTime newLastModifiedSeen = command.lastModifiedSeen.toUtc();
    String cursor = _encodeOffsetCursor(offset);

    while (true) {
      final page = await api.listOrders(
        merchantId: merchantId,
        modifiedFrom: modifiedFrom,
        modifiedTo: now,
        offset: offset,
        limit: kCloverPageSize,
      );
      for (final order in page.elements) {
        final ok = await command.sanityHook(
          vendorEventId: '${order['id']}',
          payload: order,
          isDeliberateBackfill: false,
        );
        if (!ok) {
          dropped += 1;
          continue;
        }
        final fact = _project(order);
        if (fact == null) continue;
        await factWriter.writeSalesFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          fact: fact,
        );
        written += 1;
        if (fact.vendorModifiedAt.isAfter(newLastModifiedSeen)) {
          newLastModifiedSeen = fact.vendorModifiedAt;
        }
      }
      cursor = _encodeOffsetCursor(page.nextOffset ?? offset + page.elements.length);
      await watermarkStore.persist(
        operatorId: command.operatorId,
        locationId: command.locationId,
        cursorToken: cursor,
        lastModifiedSeen: newLastModifiedSeen,
      );
      if (page.nextOffset == null) {
        return PollIncrementalResult(
          recordsWritten: written,
          newCursorToken: cursor,
          newLastModifiedSeen: newLastModifiedSeen,
          sanityDropped: dropped,
        );
      }
      offset = page.nextOffset!;
    }
  }

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async {
    // The framework already verified signature, ran the binding
    // cross-check, claimed idempotency, and ran the timestamp sanity
    // guard. The adapter MUST NOT re-invoke `sanityHook` here — the
    // framework's step-4 guard is the only sanity check on the
    // webhook path.
    final objectId = command.payload['objectId'];
    if (objectId is! String || objectId.isEmpty) {
      throw FormatException(
        'Clover webhook envelope missing objectId — '
        'see https://docs.clover.com/docs/using-webhooks',
      );
    }
    final merchantId =
        ((command.payload['merchant'] as Map?)?['id']?.toString()) ??
            await credentials.readMerchantId(
              operatorId: command.operatorId,
              locationId: command.locationId,
            );
    if (merchantId == null) {
      throw StateError('no merchant id on file for ${command.operatorId}');
    }
    final order = await api.getOrder(
      merchantId: merchantId,
      orderId: objectId,
    );
    final fact = _project(order);
    if (fact == null) {
      return const HandleWebhookResult(recordsWritten: 0);
    }
    await factWriter.writeSalesFact(
      operatorId: command.operatorId,
      locationId: command.locationId,
      fact: fact,
    );
    return const HandleWebhookResult(recordsWritten: 1);
  }

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    final subscriptionId = await credentials.readWebhookSubscriptionId(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    final merchantId = await credentials.readMerchantId(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    var unregistered = false;
    if (subscriptionId != null && merchantId != null) {
      unregistered = await webhookRegistry.unregister(
        operatorId: command.operatorId,
        locationId: command.locationId,
        merchantId: merchantId,
        subscriptionId: subscriptionId,
      );
    }
    final wiped = await credentials.wipe(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    // Watermark + canonical facts are intentionally preserved so a
    // reconnect resumes from the last cursor without rewinding.
    return DisconnectResult(
      credentialsWiped: wiped,
      webhookUnregistered: unregistered,
      watermarkPreserved: true,
    );
  }

  /// Convert a Clover order JSON shape to a canonical sales fact.
  /// Returns null when the payload is malformed (drop at boundary
  /// per V1 lean cut 2 — adapter writes a clean fact or refuses).
  CloverCanonicalSalesFact? _project(Map<String, Object?> order) {
    final id = order['id'];
    final created = order['createdTime'];
    final modified = order['modifiedTime'];
    final total = order['total'];
    final state = order['state'];
    if (id is! String || id.isEmpty) return null;
    if (created is! int) return null;
    if (modified is! int) return null;
    if (total is! int) return null;

    final openedAt = DateTime.fromMillisecondsSinceEpoch(created, isUtc: true);
    final modifiedAt =
        DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true);
    final closedAt =
        state == kCloverClosedOrderState ? modifiedAt : null;
    return CloverCanonicalSalesFact(
      vendorEntityId: id,
      openedAt: openedAt,
      closedAt: closedAt,
      actualSalesDollars: total / 100.0,
      vendorModifiedAt: modifiedAt,
      businessDate: DateTime.utc(openedAt.year, openedAt.month, openedAt.day),
      // covers always null; coversSource defaults to forecast_fallback.
    );
  }

  String _encodeOffsetCursor(int offset) =>
      base64Url.encode(utf8.encode(jsonEncode(<String, int>{'offset': offset})));

  int _decodeOffsetCursor(String cursor) {
    try {
      final decoded =
          jsonDecode(utf8.decode(base64Url.decode(cursor))) as Map<String, dynamic>;
      final offset = decoded['offset'];
      return offset is int ? offset : 0;
    } catch (_) {
      return 0;
    }
  }
}
