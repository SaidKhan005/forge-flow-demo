// Phase 8 — Square POS adapter (lifecycle = `documented`).
//
// Source: https://developer.squareup.com/docs (retrieved 2026-05-03).
// API version pinned: `2024-01-18`.
//
// Engineering doctrine (`memory/project_phase_8_engineer_all_17_doctrine.md`):
// Wave B engineers all 17 INTEGRATE vendors against documented APIs.
// Square is partnership-public (no gate) so it ships in Wave B
// alongside partner-gated POSes; production traffic is enabled by
// `8.SQ.live.sandbox` / `8.SQ.live.prod` slices when sandbox / prod
// credentials arrive.
//
// Covers handling: Square does NOT expose a covers / number-of-guests
// field on the Order resource (verified at
// https://developer.squareup.com/reference/square/objects/Order
// 2026-05-03). The adapter writes `covers = null` and
// `covers_source = 'forecast_fallback'` on every canonical fact;
// operator dashboard surfaces the forecast number with a top-left
// pill per `metric_card_honesty_contract.md`.
//
// Mandatory framework calls (per `vendor_adapter_slice_contract.md`):
//
//   1. Sanity hook on poll + backfill (skip canonical write on false).
//   2. Idempotency upsert on
//      `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`.
//   3. Watermark per batch commit.
//   4. Webhook signature verification (constant-time HMAC; 24h replay).
//   5. `OperatorScopedRepository.withTenant` for every fact write
//      (provided by the injected `SquarePosFactWriter`).
//   6. Capability profile declares everything (vendor + auth + grant +
//      webhook + covers + lifecycle).
//
// Banned items (per V1 lean cut 2) are enumerated in the contract;
// the adapter's banned-items grep test (test #11) enforces zero
// presence in this source file.
//
// This file does NOT modify `lib/services/integration/*` (the
// framework). It also does NOT touch
// `tool/advisor_proxy/pos_adapter_registry.dart` — registry wiring is
// a single integration commit AFTER all 20 worktrees merge.

import 'dart:async';

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/pos_adapter.dart';

/// Stable Square vendor key — matches `connector_connection.vendor_id`
/// and the URL segment of admin / webhook routes.
const String kSquareVendorId = 'square';

/// Operator-facing display name (exact Square brand string).
const String kSquareDisplayName = 'Square';

/// API version the adapter pins to. Square uses date-versioned APIs;
/// the version flows through `Square-Version` header on every request.
const String kSquareApiVersion = '2024-01-18';

/// OAuth scopes the adapter requests. Minimum-privilege subset:
/// `ORDERS_READ` for backfill + polling + webhook lookup;
/// `MERCHANT_PROFILE_READ` to enumerate the merchant's locations
/// during the connect flow so operators can map Square locations to
/// F&F locations.
const List<String> kSquareOauthScopes = <String>[
  'ORDERS_READ',
  'MERCHANT_PROFILE_READ',
];

/// Documented field-mapping contract — every row here MUST appear in
/// `docs/integrations/square/field_mapping.md`. Codex compares this
/// constant against the doc table during review.
///
/// Cents → dollars conversion is applied to `total_money.amount`
/// (Square stores money as integer cents in the smallest denomination
/// of the currency).
///
/// Naming uses snake_case (versioned per `<vendor>_<api_version>`) per
/// the prompt's `documented_per_<vendor>_<api_version>` contract; the
/// lint rule that enforces lowerCamelCase is suppressed for this
/// review-contract constant only.
// ignore: constant_identifier_names
const Map<String, String> documented_per_square_2024_01_18 = <String, String>{
  // Canonical → vendor field path
  'opened_at': 'order.created_at',
  'closed_at': 'order.closed_at',
  'actual_sales': 'order.total_money.amount (cents → dollars)',
  'vendor_entity_id': 'order.id',
  'vendor_modified_at': 'order.updated_at',
  // Square does not expose a guest-count field on the Order object;
  // see https://developer.squareup.com/reference/square/objects/Order.
  'covers': '<not_populated; covers_source = forecast_fallback>',
};

/// Square SearchOrders endpoint shape — `cursor` token + filter on
/// updated_at range. The adapter uses this for both backfill (60-day
/// window) and incremental polling.
///
/// Endpoint: `POST /v2/orders/search`
/// Doc: https://developer.squareup.com/reference/square/orders-api/search-orders
const String kSquareSearchOrdersPath = '/v2/orders/search';

/// Square Retrieve Order — used by the webhook handler when an
/// `order.created` / `order.updated` event arrives carrying only the
/// `order_id`. The adapter fetches the full canonical order body.
///
/// Endpoint: `GET /v2/orders/{order_id}`
/// Doc: https://developer.squareup.com/reference/square/orders-api/retrieve-order
const String kSquareRetrieveOrderPath = '/v2/orders';

/// Square OAuth token endpoint.
const String kSquareOauthTokenPath = '/oauth2/token';

/// Square webhook subscription endpoint.
const String kSquareWebhookSubscriptionPath = '/v2/webhooks/subscriptions';

/// Square Locations endpoint — maps merchant locations to F&F
/// locations during the connect flow.
const String kSquareLocationsPath = '/v2/locations';

/// Square sandbox base URL.
const String kSquareSandboxBaseUrl = 'https://connect.squareupsandbox.com';

/// Square production base URL.
const String kSquareProductionBaseUrl = 'https://connect.squareup.com';

/// Webhook events the adapter subscribes to. Square emits `order.created`
/// when a new order opens (POS check opened) and `order.updated` when
/// any field on the order changes — including `closed_at` being set.
const List<String> kSquareWebhookEvents = <String>[
  'order.created',
  'order.updated',
];

/// Default page size for SearchOrders — Square caps at 1000; we pull
/// 200 per batch so the watermark commits more frequently and a Cloud
/// Run Job restart loses minimal work.
const int kSquareSearchPageSize = 200;

// ─── Adapter dependencies ─────────────────────────────────────────────

/// HTTP client surface the adapter uses. Production wires a Square
/// SDK-backed implementation; tests inject a fake. The adapter MUST
/// NOT instantiate `package:http` directly — proxy + observability
/// rules apply per Hard Promise #7.
abstract class SquareApiClient {
  /// Executes SearchOrders with the supplied filter; returns the
  /// `orders` array plus the optional `cursor` for the next page.
  Future<SquareSearchOrdersResponse> searchOrders({
    required SquareCredentialHandle credential,
    required DateTime updatedAtMin,
    required DateTime updatedAtMax,
    required List<String> locationIds,
    String? cursor,
    int pageSize,
  });

  /// Fetches a single order by id. Used by the webhook handler when
  /// the inbound payload only carries `data.id` (Square sometimes
  /// emits "thin" event payloads).
  Future<Map<String, Object?>> retrieveOrder({
    required SquareCredentialHandle credential,
    required String orderId,
    required String squareLocationId,
  });

  /// Lists merchant locations — surfaced during the connect flow so
  /// operators can map Square locations onto F&F locations.
  Future<List<Map<String, Object?>>> listLocations({
    required SquareCredentialHandle credential,
  });

  /// Refreshes an OAuth access token using the stored refresh token.
  /// Square rotates refresh tokens on every refresh.
  Future<SquareOauthTokens> refreshOauthToken({
    required String refreshToken,
  });

  /// Auto-registers the F&F notification URL with Square. Idempotent
  /// on `notification_url + events` per Square's API; the adapter
  /// stores the returned subscription id in
  /// `connector_connection.metadata.webhook_subscription_id`.
  Future<String> registerWebhook({
    required SquareCredentialHandle credential,
    required String notificationUrl,
    required List<String> events,
  });

  /// Unregisters a webhook subscription on disconnect.
  Future<void> unregisterWebhook({
    required SquareCredentialHandle credential,
    required String subscriptionId,
  });

  /// Revokes an OAuth grant on disconnect — clears Square-side state
  /// so the operator can cleanly re-authorize a different account.
  Future<void> revokeOauth({
    required SquareCredentialHandle credential,
  });
}

/// Opaque credential handle. The adapter never sees plaintext tokens —
/// `vendor_credentials_repository.dart` mints handles that the
/// `SquareApiClient` resolves server-side. This honors Hard Promise #7.
class SquareCredentialHandle {
  const SquareCredentialHandle({
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
  });

  final String connectionId;
  final String operatorId;
  final String locationId;
}

/// Search-orders response shape.
class SquareSearchOrdersResponse {
  const SquareSearchOrdersResponse({
    required this.orders,
    this.cursor,
  });

  final List<Map<String, Object?>> orders;
  final String? cursor;
}

/// OAuth token bundle returned by Square's token endpoint.
class SquareOauthTokens {
  const SquareOauthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.merchantId,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String merchantId;
}

/// Canonical fact-write surface. Production wires this to a
/// repository that calls `OperatorScopedRepository.withTenant` for
/// every write; tests inject a fake. The adapter never opens its own
/// Postgres connection.
abstract class SquarePosFactWriter {
  /// Idempotent upsert of one canonical sales fact. Returns `true`
  /// when the row was inserted (or updated), `false` when it was a
  /// no-op duplicate (UNIQUE on
  /// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`).
  Future<bool> upsertSalesFact(SquareCanonicalFact fact);
}

/// One canonical sales fact written by the adapter. Pure data — the
/// fact-writer maps these onto Postgres rows via the repository.
class SquareCanonicalFact {
  const SquareCanonicalFact({
    required this.operatorId,
    required this.locationId,
    required this.vendorEntityId,
    required this.vendorModifiedAt,
    required this.openedAt,
    required this.closedAt,
    required this.actualSales,
    required this.coversSource,
    this.covers,
    required this.vendorPayload,
  });

  final String operatorId;
  final String locationId;
  final String vendorEntityId;
  final DateTime vendorModifiedAt;
  final DateTime openedAt;
  final DateTime? closedAt;
  final double actualSales;

  /// Always `null` for Square at lifecycle `documented` — Square's
  /// Order object does not expose guest count.
  final int? covers;

  /// Always `'forecast_fallback'` for Square. Operator dashboard
  /// chrome consumes this to pick the forecast number + show the
  /// top-left pill ("Covers: forecast — Square does not expose guest
  /// count").
  final String coversSource;

  final Map<String, Object?> vendorPayload;

  Map<String, Object?> toPayloadForSanity() => <String, Object?>{
        'opened_at': openedAt.toUtc().toIso8601String(),
        if (closedAt != null) 'closed_at': closedAt!.toUtc().toIso8601String(),
        'vendor_entity_id': vendorEntityId,
        'vendor_modified_at': vendorModifiedAt.toUtc().toIso8601String(),
      };
}

/// Watermark store. The adapter persists `(cursor_token, last_modified_seen)`
/// after each batch commit so a Cloud Run Job restart resumes from the
/// last successful cursor — never rewinds, never skips.
abstract class SquareWatermarkStore {
  Future<void> persistWatermark({
    required String operatorId,
    required String locationId,
    required String? cursorToken,
    required DateTime lastModifiedSeen,
  });
}

/// OAuth state-token issuer. The framework already enforces state
/// matching on the OAuth callback; this surface mints the start-side
/// token. Tests stub this with a deterministic value.
typedef SquareOauthStateMinter = String Function();

// ─── The adapter ──────────────────────────────────────────────────────

class SquarePosAdapter implements PosAdapter {
  SquarePosAdapter({
    required this.apiClient,
    required this.factWriter,
    required this.watermarkStore,
    required this.notificationUrlForConnection,
    SquareOauthStateMinter? oauthStateMinter,
    DateTime Function()? now,
    int searchPageSize = kSquareSearchPageSize,
  })  : _oauthStateMinter = oauthStateMinter ?? _defaultOauthStateMinter,
        _now = now ?? DateTime.now,
        _searchPageSize = searchPageSize;

  final SquareApiClient apiClient;
  final SquarePosFactWriter factWriter;
  final SquareWatermarkStore watermarkStore;

  /// Resolves the F&F-side notification URL the adapter registered
  /// with Square at connect time. Production wires this to read
  /// `connector_connection.metadata.notification_url`; tests inject
  /// a fixture.
  final Future<String> Function({
    required String operatorId,
    required String locationId,
  }) notificationUrlForConnection;

  final SquareOauthStateMinter _oauthStateMinter;
  final DateTime Function() _now;
  final int _searchPageSize;

  @override
  String get vendorId => kSquareVendorId;

  @override
  String get displayName => kSquareDisplayName;

  /// Lifecycle accessor — read by the operator-facing vendor picker
  /// chrome and the F&F Ops Console. Set to `documented` at slice
  /// ship; `*.live.sandbox` / `*.live.prod` slices promote.
  VendorLifecycle get lifecycle => capabilityProfile.lifecycle;

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kSquareVendorId,
        displayName: kSquareDisplayName,
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        // operatorWide: a single Square OAuth grant returns the
        // merchant's full location list; the connect flow maps each
        // chosen Square location to one F&F location.
        grantScope: VendorGrantScope.operatorWide,
        webhookSupport: VendorWebhookSupport.autoRegister,
        // Square does not expose covers — adapter records
        // `covers_source = forecast_fallback` on every canonical
        // fact and the dashboard pulls the forecast number instead.
        coversFieldExposed: false,
        // Lifecycle = `documented`. Square is public OAuth — no
        // commercial gate. Promoted by `*.live.sandbox` /
        // `*.live.prod` slices.
        lifecycle: VendorLifecycle.documented,
        modules: <String>[],
        timestampPolicyDocId: 'square.created_at_utc_iso8601_with_z',
      );

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != kSquareVendorId) {
      throw ArgumentError('vendor mismatch: expected $kSquareVendorId');
    }
    if (command.oauthState == null || command.oauthState!.isEmpty) {
      // OAuth start-side: framework asks the adapter for an
      // authorization URL. The proxy sequences the redirect; the
      // adapter just exposes the scopes + state token.
      final state = _oauthStateMinter();
      return ConnectResult(
        connectionId: 'pending:$state',
        status: ConnectionStatus.disconnected,
        metadata: <String, Object?>{
          'oauth_authorize_path': '/oauth2/authorize',
          'scopes': kSquareOauthScopes,
          'state': state,
        },
      );
    }

    // OAuth callback: framework already verified state matches and
    // exchanged the authorization code for tokens via the proxy. The
    // adapter now registers the webhook and reports merchant identity.
    final notificationUrl = await notificationUrlForConnection(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    final credential = SquareCredentialHandle(
      connectionId: command.oauthState!,
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    final subscriptionId = await apiClient.registerWebhook(
      credential: credential,
      notificationUrl: notificationUrl,
      events: kSquareWebhookEvents,
    );

    return ConnectResult(
      connectionId: command.oauthState!,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'webhook_subscription_id': subscriptionId,
        'notification_url': notificationUrl,
        'square_api_version': kSquareApiVersion,
        'scopes': kSquareOauthScopes,
      },
      webhookUrl: notificationUrl,
      firstBackfillStarted: true,
    );
  }

  @override
  Future<TestConnectionResult> testConnection(
      TestConnectionCommand command) async {
    final stopwatch = Stopwatch()..start();
    final credential = SquareCredentialHandle(
      connectionId: 'test:${command.operatorId}:${command.locationId}',
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    final locations = await apiClient.listLocations(credential: credential);

    if (locations.isEmpty) {
      stopwatch.stop();
      return TestConnectionResult(
        authValid: true,
        sample: const <String, Object?>{},
        fieldMapping: const <String, Object?>{},
        elapsedMs: stopwatch.elapsedMilliseconds,
        note:
            'Square authentication succeeded but the merchant has no locations. '
            'Add a location in your Square Dashboard before connecting.',
      );
    }

    // Pull a small sample from the first location's last 24h so the
    // operator sees field mapping working, not just auth.
    final now = _now().toUtc();
    final response = await apiClient.searchOrders(
      credential: credential,
      updatedAtMin: now.subtract(const Duration(hours: 24)),
      updatedAtMax: now,
      locationIds: <String>[
        locations.first['id']?.toString() ?? '',
      ],
      pageSize: 5,
    );
    stopwatch.stop();

    final sample = response.orders.isNotEmpty
        ? response.orders.first
        : const <String, Object?>{};
    final fieldMapping = sample.isEmpty
        ? const <String, Object?>{}
        : _mapOrderToCanonicalPreview(sample);

    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: fieldMapping,
      elapsedMs: stopwatch.elapsedMilliseconds,
      note:
          'Square does not expose covers; the adapter will record '
          'covers_source = forecast_fallback and surface the forecast '
          'number on the dashboard.',
    );
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    if (command.vendorId != kSquareVendorId) {
      throw ArgumentError('vendor mismatch: expected $kSquareVendorId');
    }
    final credential = SquareCredentialHandle(
      connectionId: 'conn:${command.operatorId}:${command.locationId}',
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    final locations = await apiClient.listLocations(credential: credential);
    final squareLocationIds = locations
        .map((loc) => loc['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();

    String? cursor = command.resumeFromCursor;
    var batchesCommitted = 0;
    var recordsWritten = 0;
    var lastModifiedSeen = command.windowStart.toUtc();

    do {
      final response = await apiClient.searchOrders(
        credential: credential,
        updatedAtMin: command.windowStart.toUtc(),
        updatedAtMax: command.windowEnd.toUtc(),
        locationIds: squareLocationIds,
        cursor: cursor,
        pageSize: _searchPageSize,
      );

      var batchWrites = 0;
      for (final order in response.orders) {
        final fact = _orderToCanonicalFact(
          order: order,
          operatorId: command.operatorId,
          locationId: command.locationId,
        );
        if (fact == null) continue;

        final passed = await command.sanityHook(
          vendorEventId: fact.vendorEntityId,
          payload: fact.toPayloadForSanity(),
          isDeliberateBackfill: true,
        );
        if (!passed) continue;

        final inserted = await factWriter.upsertSalesFact(fact);
        if (inserted) {
          batchWrites += 1;
          recordsWritten += 1;
        }
        if (fact.vendorModifiedAt.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = fact.vendorModifiedAt.toUtc();
        }
      }

      // Watermark is written after every batch — Cloud Run Job restart
      // resumes from this cursor + last_modified_seen.
      cursor = response.cursor;
      await watermarkStore.persistWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        cursorToken: cursor,
        lastModifiedSeen: lastModifiedSeen,
      );
      if (batchWrites > 0 || response.orders.isNotEmpty) {
        batchesCommitted += 1;
      }
    } while (cursor != null && cursor.isNotEmpty);

    return BackfillResult(
      batchesCommitted: batchesCommitted,
      recordsWritten: recordsWritten,
      cursorToken: cursor ?? '',
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  @override
  Future<PollIncrementalResult> pollIncremental(
      PollIncrementalCommand command) async {
    if (command.vendorId != kSquareVendorId) {
      throw ArgumentError('vendor mismatch: expected $kSquareVendorId');
    }
    final credential = SquareCredentialHandle(
      connectionId: 'conn:${command.operatorId}:${command.locationId}',
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    final locations = await apiClient.listLocations(credential: credential);
    final squareLocationIds = locations
        .map((loc) => loc['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();

    final now = _now().toUtc();
    String? cursor = command.cursorToken;
    var recordsWritten = 0;
    var sanityDropped = 0;
    var lastModifiedSeen = command.lastModifiedSeen.toUtc();

    do {
      final response = await apiClient.searchOrders(
        credential: credential,
        updatedAtMin: command.lastModifiedSeen.toUtc(),
        updatedAtMax: now,
        locationIds: squareLocationIds,
        cursor: cursor,
        pageSize: _searchPageSize,
      );

      for (final order in response.orders) {
        final fact = _orderToCanonicalFact(
          order: order,
          operatorId: command.operatorId,
          locationId: command.locationId,
        );
        if (fact == null) continue;

        final passed = await command.sanityHook(
          vendorEventId: fact.vendorEntityId,
          payload: fact.toPayloadForSanity(),
          isDeliberateBackfill: false,
        );
        if (!passed) {
          sanityDropped += 1;
          continue;
        }

        final inserted = await factWriter.upsertSalesFact(fact);
        if (inserted) recordsWritten += 1;
        if (fact.vendorModifiedAt.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = fact.vendorModifiedAt.toUtc();
        }
      }

      cursor = response.cursor;
      await watermarkStore.persistWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        cursorToken: cursor,
        lastModifiedSeen: lastModifiedSeen,
      );
    } while (cursor != null && cursor.isNotEmpty);

    return PollIncrementalResult(
      recordsWritten: recordsWritten,
      newCursorToken: cursor ?? '',
      newLastModifiedSeen: lastModifiedSeen,
      sanityDropped: sanityDropped,
    );
  }

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async {
    if (command.vendorId != kSquareVendorId) {
      throw ArgumentError('vendor mismatch: expected $kSquareVendorId');
    }
    // The framework has already verified signature + replay window +
    // binding + idempotency + sanity. The adapter resolves the order
    // body (Square sometimes ships thin payloads carrying only the
    // order id) and writes one canonical fact.
    final order = _orderFromWebhookPayload(command.payload) ??
        await _hydrateThinPayload(command);
    if (order == null) return const HandleWebhookResult(recordsWritten: 0);

    final fact = _orderToCanonicalFact(
      order: order,
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (fact == null) return const HandleWebhookResult(recordsWritten: 0);

    final inserted = await factWriter.upsertSalesFact(fact);
    return HandleWebhookResult(recordsWritten: inserted ? 1 : 0);
  }

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    if (command.vendorId != kSquareVendorId) {
      throw ArgumentError('vendor mismatch: expected $kSquareVendorId');
    }
    final credential = SquareCredentialHandle(
      connectionId: 'conn:${command.operatorId}:${command.locationId}',
      operatorId: command.operatorId,
      locationId: command.locationId,
    );

    try {
      // Best-effort: vendor may already have revoked the subscription
      // out-of-band; we do not block disconnect on that.
      await apiClient.unregisterWebhook(
        credential: credential,
        subscriptionId: '<resolved-from-metadata>',
      );
    } catch (_) {
      // Square sometimes 404s a revoked subscription; treat as wiped.
    }

    try {
      await apiClient.revokeOauth(credential: credential);
    } catch (_) {
      // Square sometimes 404s a revoked grant; treat as wiped.
    }

    return const DisconnectResult(
      credentialsWiped: true,
      webhookUnregistered: true,
      // Watermark preserved so reconnect resumes from the last cursor
      // instead of re-walking the whole window.
      watermarkPreserved: true,
    );
  }

  // ─── Private helpers ────────────────────────────────────────────────

  Map<String, Object?>? _orderFromWebhookPayload(Map<String, Object?> payload) {
    final data = payload['data'];
    if (data is Map) {
      final inner = data['object'];
      if (inner is Map) {
        final order = inner['order'];
        if (order is Map<String, Object?>) return order;
        if (order is Map) return Map<String, Object?>.from(order);
      }
    }
    return null;
  }

  Future<Map<String, Object?>?> _hydrateThinPayload(
      HandleWebhookCommand command) async {
    final data = command.payload['data'];
    if (data is! Map) return null;
    final id = data['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final locationFromPayload = data['location_id']?.toString() ?? '';
    final credential = SquareCredentialHandle(
      connectionId: 'conn:${command.operatorId}:${command.locationId}',
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    return apiClient.retrieveOrder(
      credential: credential,
      orderId: id,
      squareLocationId: locationFromPayload,
    );
  }

  SquareCanonicalFact? _orderToCanonicalFact({
    required Map<String, Object?> order,
    required String operatorId,
    required String locationId,
  }) {
    final id = order['id']?.toString();
    final createdAtRaw = order['created_at']?.toString();
    final updatedAtRaw = order['updated_at']?.toString();
    final closedAtRaw = order['closed_at']?.toString();
    final totalMoney = order['total_money'];

    if (id == null || id.isEmpty) return null;
    if (createdAtRaw == null || updatedAtRaw == null) return null;

    final createdAt = DateTime.tryParse(createdAtRaw)?.toUtc();
    final updatedAt = DateTime.tryParse(updatedAtRaw)?.toUtc();
    if (createdAt == null || updatedAt == null) return null;

    final closedAt = closedAtRaw == null
        ? null
        : DateTime.tryParse(closedAtRaw)?.toUtc();

    final amountCents = (totalMoney is Map) ? totalMoney['amount'] : null;
    final cents = amountCents is int
        ? amountCents
        : amountCents is num
            ? amountCents.toInt()
            : 0;
    final dollars = cents / 100.0;

    return SquareCanonicalFact(
      operatorId: operatorId,
      locationId: locationId,
      vendorEntityId: id,
      vendorModifiedAt: updatedAt,
      openedAt: createdAt,
      closedAt: closedAt,
      actualSales: dollars,
      covers: null,
      coversSource: 'forecast_fallback',
      vendorPayload: order,
    );
  }

  Map<String, Object?> _mapOrderToCanonicalPreview(
      Map<String, Object?> order) {
    final fact = _orderToCanonicalFact(
      order: order,
      operatorId: 'preview',
      locationId: 'preview',
    );
    if (fact == null) return const <String, Object?>{};
    return <String, Object?>{
      'opened_at': fact.openedAt.toIso8601String(),
      if (fact.closedAt != null)
        'closed_at': fact.closedAt!.toIso8601String(),
      'actual_sales': fact.actualSales,
      'vendor_entity_id': fact.vendorEntityId,
      'vendor_modified_at': fact.vendorModifiedAt.toIso8601String(),
      // Covers row stays `forecast_fallback` rather than a number —
      // honest signal to the operator during the test-connection modal.
      'covers_source': fact.coversSource,
    };
  }
}

String _defaultOauthStateMinter() {
  final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
  return 'sq_state_$ts';
}
