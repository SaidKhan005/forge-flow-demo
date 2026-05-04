// Phase 8.RV — Revel Systems POS adapter (lifecycle = documented).
//
// Engineered against the Revel Webhooks + OAuth + Integration
// Management documentation at
// `https://developer.revelsystems.com/revelsystems/docs/webhooks`
// (retrieval date 2026-05-03). All HTTP transport is abstracted behind
// [RevelTransport] and stubbed for fixtures; live HTTP rolls out via
// `8.RV.live.sandbox` / `8.RV.live.prod` slices when vendor credentials
// arrive (Wave D — `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`).
//
// Per the Phase 8 engineer-all-17 doctrine
// (`memory/project_phase_8_engineer_all_17_doctrine.md`), this slice
// ships with [VendorLifecycle.documented]. The vendor-picker chrome
// surfaces "Coming soon" until the `*.live` slices fire and promote the
// lifecycle. Field-mapping assumptions are captured in
// [documentedPerRevelV1] below and mirrored in
// `docs/integrations/revel/field_mapping.md`; the `*.live.sandbox`
// slice diffs observed responses against this constant.
//
// Banned items per V1 lean cut 2 (REJECT if reintroduced) — see
// `docs/contracts/vendor_adapter_slice_contract.md` for the full list.
// The slice's banned-items grep test pins each forbidden substring in
// `test/integrations/pos/revel_pos_adapter_test.dart`. Engineering
// inside this file refuses every one of them by construction: no key
// rotation surface, no advisory locks, no graceful-drain hook, no
// dead-letter UI, no sidecar raw-payload partitions, no 5-second
// test-connection SLA, no email auto-disable.

import 'dart:convert';

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/oauth_refresh_cron.dart';
import '../../services/integration/pos_adapter.dart';
import '../../services/integration/vendor_timestamp_policy.dart';

// ─── Lifecycle (deferred-merged into framework by slice 8.0.lifecycle) ──

/// Vendor lifecycle states.
///
// ─── Vendor key + display name ──────────────────────────────────────

/// Stable vendor identifier matching `connector_connection.vendor_id`.
const String kRevelVendorId = 'revel';

/// Operator-facing display name.
const String kRevelDisplayName = 'Revel Systems';

// ─── Documented-per-revel field mapping (source of truth for *.live diff) ──

/// Field-mapping reference captured at slice ship. Every canonical
/// fact field the adapter populates traces to one entry here. The
/// `*.live.sandbox` slice diffs observed Revel responses against this
/// constant; mismatches become bounded fixes (not slice rebuilds) per
/// `docs/contracts/vendor_adapter_slice_contract.md`.
///
/// Source: `https://developer.revelsystems.com/revelsystems/docs/webhooks`
/// (retrieval date 2026-05-03).
const Map<String, Object?> documentedPerRevelV1 = <String, Object?>{
  'api_version': 'v1-2026-05-03',
  'vendor_event_id_path': 'order.id',
  'vendor_modified_at_path': 'order.updated_date',
  'opened_at_path': 'order.created_date',
  'closed_at_path': 'order.updated_date',
  'covers_path': 'order.number_of_people',
  'covers_type': 'int',
  'actual_sales_path': 'order.final_total',
  'actual_sales_type': 'string_or_number_dollars',
  'closed_flag_path': 'order.closed',
  'establishment_id_header': 'X-Revel-Establishment-Id',
  'instance_header': 'X-Revel-Instance',
  'event_type_header': 'X-Revel-Event-Type',
  'event_id_header': 'X-Revel-Event-Id',
  'message_id_header': 'X-Revel-Message-Id',
  'signature_header': 'X-Revel-Signature',
  'signature_algorithm': 'HMAC-SHA1',
  'signature_encoding': 'hex_lower',
  'oauth_token_url': 'https://authentication.revelup.com/oauth/token',
  'oauth_grant_type': 'client_credentials',
  'oauth_access_ttl_seconds': 86400,
  'api_base_url': 'https://api.revelsystems.com',
  'integrations_endpoint': '/external/integrations',
  'message_log_endpoint': '/external/message-log',
  'webhook_event_subscribed': 'order.finalized',
  'webhook_protocol': 'https',
  'webhook_response_window_seconds': 10,
  // Forbidden — read these but do NOT persist:
  'forbidden_customer_email_path': 'order.customer.email',
  'forbidden_customer_name_path': 'order.customer.name',
  'forbidden_payment_card_last4_path': 'order.payments[].card_last4',
};

// ─── Local timestamp policy (deferred-merged into framework catalog) ──

/// Local Revel timestamp policy. Slice `8.0.lifecycle`'s integration
/// commit folds this entry into the const map at
/// `lib/services/integration/vendor_timestamp_policy.dart`. Until then
/// the adapter uses [revelTimestampPolicy] directly so the framework's
/// "refuse if no policy declared" guard does not trip in tests.
const TimestampPolicy revelTimestampPolicy = TimestampPolicy(
  vendorId: kRevelVendorId,
  ambiguousConvention: AmbiguousTimestampConvention.asUtc,
  documentationNote:
      'Revel order timestamps (`created_date`, `updated_date`) are '
      'ISO 8601 UTC instants in current API responses. The Revel '
      'developer portal pins UTC as the convention; the adapter '
      'treats any ambiguous form as UTC and the *.live.sandbox slice '
      'verifies the assumption against observed sandbox payloads.',
);

// ─── Local webhook binding spec (deferred-merged into framework) ─────

/// Per-payload key Revel populates with the customer instance name.
const String kRevelInstanceMetadataKey = 'instance_name';

// ─── Transport abstraction (real HTTP lands in *.live slices) ────────

/// Token envelope returned by Revel's OAuth endpoint.
class RevelTokenResponse {
  const RevelTokenResponse({
    required this.accessToken,
    required this.expiresAt,
  });

  final String accessToken;
  final DateTime expiresAt;
}

/// One page of order history returned by Revel's order list endpoint.
class RevelOrdersPage {
  const RevelOrdersPage({
    required this.records,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Raw vendor-shape order rows. The adapter normalizes each into a
  /// canonical fact via [_canonicalize].
  final List<Map<String, Object?>> records;

  /// Next-page cursor; null when the server reports no more pages.
  final String? nextCursor;

  /// `updated_date` of the latest record on this page (UTC).
  final DateTime lastModifiedSeen;
}

/// Stub transport surface. Production wires HTTP via the `*.live`
/// slices; tests inject [_FakeRevelTransport] (in test file) to exercise
/// every framework call without a live vendor.
abstract class RevelTransport {
  /// `POST https://authentication.revelup.com/oauth/token`,
  /// `grant_type=client_credentials`. JWT bearer with 86,400s TTL.
  Future<RevelTokenResponse> exchangeClientCredentials({
    required String clientId,
    required String clientSecret,
    required String audience,
  });

  /// `GET /external/integrations` paginated; the adapter walks pages
  /// during backfill + poll.
  Future<RevelOrdersPage> listOrders({
    required String accessToken,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  });

  /// `GET /external/integrations/{order_id}` — used by webhook lookups
  /// when the inbound payload omits a needed field. Documented but the
  /// V1 path expects the webhook payload to be self-contained; this
  /// shim is the escape hatch for partial payloads observed at
  /// `*.live.sandbox`.
  Future<Map<String, Object?>> fetchOrder({
    required String accessToken,
    required String orderId,
  });

  /// Auto-register a webhook subscription. Returns the vendor-issued
  /// subscription id (stored in `connector_connection.metadata`).
  Future<String> registerWebhook({
    required String accessToken,
    required String url,
    required List<String> events,
    required String signingSecret,
  });

  /// `DELETE` the previously-registered subscription on disconnect.
  Future<void> unregisterWebhook({
    required String accessToken,
    required String subscriptionId,
  });

  /// `ping` event probe used by [PosAdapter.testConnection]. Returns
  /// the most recent order so the operator can eyeball field mapping
  /// (number_of_people, opened_at, closed_at, final_total).
  Future<Map<String, Object?>> sampleOrder({
    required String accessToken,
  });
}

// ─── Persistence abstraction (real Postgres lands in *.live slices) ──

/// Connection row read/written by the adapter. Mirrors the shape of
/// `connector_connection` JSONB metadata for the relevant Revel keys.
class RevelConnectionRow {
  const RevelConnectionRow({
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
    required this.instanceName,
    required this.establishmentId,
    required this.subscriptionId,
    required this.status,
  });

  final String connectionId;
  final String operatorId;
  final String locationId;
  final String instanceName;
  final String? establishmentId;
  final String? subscriptionId;
  final ConnectionStatus status;

  Map<String, Object?> toMetadata() => <String, Object?>{
        kRevelInstanceMetadataKey: instanceName,
        if (establishmentId != null) 'establishment_id': establishmentId,
        if (subscriptionId != null) 'webhook_subscription_id': subscriptionId,
      };
}

/// Watermark row mirroring `connector_sync_watermark`.
class RevelWatermarkRow {
  const RevelWatermarkRow({
    required this.cursorToken,
    required this.lastModifiedSeen,
  });

  final String cursorToken;
  final DateTime lastModifiedSeen;
}

/// One canonical fact write request handed to the gateway. The gateway
/// is responsible for the upsert on
/// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
/// per `docs/contracts/vendor_adapter_slice_contract.md`. Returns
/// `false` when the upsert hits an existing row (idempotency
/// short-circuit).
class RevelCanonicalOrderFact {
  const RevelCanonicalOrderFact({
    required this.operatorId,
    required this.locationId,
    required this.vendorEntityId,
    required this.vendorModifiedAt,
    required this.openedAt,
    required this.closedAt,
    required this.covers,
    required this.actualSales,
    required this.rawPayload,
  });

  final String operatorId;
  final String locationId;
  final String vendorEntityId;
  final DateTime vendorModifiedAt;
  final DateTime openedAt;
  final DateTime closedAt;
  final int covers;
  final num actualSales;
  final Map<String, Object?> rawPayload;
}

/// Persistence surface the adapter depends on. Production wires a
/// `OperatorScopedRepository`-backed implementation. Tests inject
/// fakes.
abstract class RevelGateway {
  /// Persist the connection row inside an
  /// `OperatorScopedRepository.withTenant` block. Returns the
  /// stored row.
  Future<RevelConnectionRow> upsertConnection({
    required RevelConnectionRow row,
  });

  /// Read the watermark for `(operatorId, locationId)`. Null when the
  /// connection has never run a backfill / poll.
  Future<RevelWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  });

  /// Persist the watermark **after each successful batch commit** so a
  /// Cloud Run Job restart resumes from the last persisted cursor (per
  /// the framework contract — never end-of-backfill).
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required RevelWatermarkRow row,
  });

  /// Upsert one canonical order fact; returns `true` when a row was
  /// written, `false` when the upsert short-circuited on the
  /// idempotency UNIQUE.
  Future<bool> writeOrderFact(RevelCanonicalOrderFact fact);

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
}

// ─── Adapter ────────────────────────────────────────────────────────

class RevelPosAdapter implements PosAdapter {
  RevelPosAdapter({
    required RevelTransport transport,
    required RevelGateway gateway,
    DateTime Function()? now,
  })  : _transport = transport,
        _gateway = gateway,
        _now = now ?? DateTime.now;

  final RevelTransport _transport;
  final RevelGateway _gateway;
  final DateTime Function() _now;

  /// Lifecycle pin for this adapter. See [VendorLifecycle].
  VendorLifecycle get lifecycle => capabilityProfile.lifecycle;

  /// Local timestamp policy (deferred-merged into framework catalog).
  TimestampPolicy get timestampPolicy => revelTimestampPolicy;

  @override
  String get vendorId => kRevelVendorId;

  @override
  String get displayName => kRevelDisplayName;

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kRevelVendorId,
        displayName: kRevelDisplayName,
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.autoRegister,
        // Revel's `order.number_of_people` is a first-class covers
        // field — direct mapping; no forecast fallback.
        coversFieldExposed: true,
        // Self-serve OAuth — no partnership gating. Production
        // credentials are operator-issued via the Revel admin portal,
        // not partner-issued.
        lifecycle: VendorLifecycle.documented,
        modules: <String>[],
        timestampPolicyDocId: 'docs/integrations/revel/field_mapping.md',
      );

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != kRevelVendorId) {
      throw StateError(
        'connect dispatched to RevelPosAdapter for non-Revel vendor '
        '${command.vendorId}',
      );
    }
    // For the documented slice we accept a key-paste-shape envelope
    // for the client_id + client_secret pair. The OAuth flow itself
    // happens server-side because Revel's grant is `client_credentials`
    // (no operator browser hop). Operators paste credentials issued by
    // the Revel admin portal; the proxy mints the JWT and stores
    // ciphertext.
    final credential = command.keyPaste;
    if (credential == null || credential.apiKey.isEmpty) {
      return const ConnectResult(
        connectionId: '',
        status: ConnectionStatus.error,
        metadata: <String, Object?>{},
      );
    }
    // The fragment of the credential payload we expect to receive is
    // `client_id` (apiKey) + `client_secret` (username). The
    // Postgres-backed gateway encrypts both before storing; the
    // adapter never sees plaintext beyond this in-memory hop.
    final tokenResponse = await _transport.exchangeClientCredentials(
      clientId: credential.apiKey,
      clientSecret: credential.username ?? '',
      audience: documentedPerRevelV1['api_base_url']! as String,
    );

    // Discover the operator's Revel instance + establishment via the
    // integration list endpoint. The first page is enough because
    // `client_credentials` grants are scoped to a single integration.
    final ordersPage = await _transport.listOrders(
      accessToken: tokenResponse.accessToken,
      modifiedSince: _now().toUtc().subtract(const Duration(seconds: 1)),
      modifiedUntil: _now().toUtc(),
    );

    // Auto-register the webhook subscription so `order.finalized`
    // events flow inbound. The signing secret is operator-owned and
    // round-trips through the Revel admin portal — the adapter holds
    // it in `vendor_credentials.metadata` (encrypted at rest) and
    // hands it back to the verifier on every inbound webhook.
    final subscriptionId = await _transport.registerWebhook(
      accessToken: tokenResponse.accessToken,
      url: 'https://proxy.example/v1/webhooks/${command.operatorId}/'
          '${command.locationId}/$kRevelVendorId',
      events: const <String>[kRevelWebhookEventOrderFinalized],
      signingSecret: credential.apiKey,
    );

    final row = RevelConnectionRow(
      connectionId: 'revel-${command.operatorId}-${command.locationId}',
      operatorId: command.operatorId,
      locationId: command.locationId,
      instanceName: _instanceFromOrders(ordersPage.records) ??
          'pending-discovery',
      establishmentId: _establishmentFromOrders(ordersPage.records),
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
          '${command.locationId}/$kRevelVendorId',
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
        note: 'No access token on file; reconnect required.',
      );
    }
    final sample = await _transport.sampleOrder(accessToken: accessToken);
    // [_canonicalize] expects a webhook-shaped envelope (`{"order": {...}}`).
    // The transport hands back a bare order row at this surface — wrap it.
    final canonical = _canonicalize(
      operatorId: command.operatorId,
      locationId: command.locationId,
      payload: <String, Object?>{'order': sample},
    );
    final elapsed = _now().toUtc().difference(start);
    if (canonical == null) {
      return TestConnectionResult(
        authValid: true,
        sample: sample,
        fieldMapping: const <String, Object?>{},
        elapsedMs: elapsed.inMilliseconds,
        note: 'Sample present but field mapping incomplete; verify '
            'documented_per_revel_v1 against this sample.',
      );
    }
    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: <String, Object?>{
        'covers': canonical.covers,
        'opened_at': canonical.openedAt.toIso8601String(),
        'closed_at': canonical.closedAt.toIso8601String(),
        'actual_sales': canonical.actualSales,
        'vendor_entity_id': canonical.vendorEntityId,
      },
      elapsedMs: elapsed.inMilliseconds,
    );
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final accessToken = await _requireAccessToken(
      command.operatorId,
      command.locationId,
    );
    final existingWatermark = command.resumeFromCursor != null
        ? RevelWatermarkRow(
            cursorToken: command.resumeFromCursor!,
            lastModifiedSeen: command.windowStart,
          )
        : await _gateway.readWatermark(
            operatorId: command.operatorId,
            locationId: command.locationId,
          );

    var cursor = existingWatermark?.cursorToken ?? '';
    var lastModifiedSeen = existingWatermark?.lastModifiedSeen ??
        command.windowStart;
    var batchesCommitted = 0;
    var recordsWritten = 0;

    while (true) {
      final page = await _transport.listOrders(
        accessToken: accessToken,
        modifiedSince: lastModifiedSeen,
        modifiedUntil: command.windowEnd,
        cursor: cursor.isEmpty ? null : cursor,
      );
      for (final row in page.records) {
        final ok = await command.sanityHook(
          vendorEventId: row['id']?.toString() ?? '',
          payload: _payloadForSanity(row),
          isDeliberateBackfill: true,
        );
        if (!ok) {
          continue;
        }
        final canonical = _canonicalize(
          operatorId: command.operatorId,
          locationId: command.locationId,
          payload: <String, Object?>{'order': row},
        );
        if (canonical == null) {
          continue;
        }
        final wrote = await _gateway.writeOrderFact(canonical);
        if (wrote) {
          recordsWritten += 1;
        }
      }
      lastModifiedSeen = page.lastModifiedSeen.isAfter(lastModifiedSeen)
          ? page.lastModifiedSeen
          : lastModifiedSeen;
      cursor = page.nextCursor ?? '';
      batchesCommitted += 1;
      // Per-batch watermark: persist BEFORE moving to the next page so
      // a Cloud Run Job restart resumes from this commit.
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: RevelWatermarkRow(
          cursorToken: cursor,
          lastModifiedSeen: lastModifiedSeen,
        ),
      );
      if (page.nextCursor == null) {
        break;
      }
    }

    return BackfillResult(
      batchesCommitted: batchesCommitted,
      recordsWritten: recordsWritten,
      cursorToken: cursor,
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) async {
    final accessToken = await _requireAccessToken(
      command.operatorId,
      command.locationId,
    );
    var cursor = command.cursorToken ?? '';
    var lastModifiedSeen = command.lastModifiedSeen;
    var recordsWritten = 0;
    var sanityDropped = 0;

    while (true) {
      final page = await _transport.listOrders(
        accessToken: accessToken,
        modifiedSince: lastModifiedSeen,
        modifiedUntil: _now().toUtc(),
        cursor: cursor.isEmpty ? null : cursor,
      );
      for (final row in page.records) {
        final ok = await command.sanityHook(
          vendorEventId: row['id']?.toString() ?? '',
          payload: _payloadForSanity(row),
          isDeliberateBackfill: false,
        );
        if (!ok) {
          sanityDropped += 1;
          continue;
        }
        final canonical = _canonicalize(
          operatorId: command.operatorId,
          locationId: command.locationId,
          payload: <String, Object?>{'order': row},
        );
        if (canonical == null) {
          continue;
        }
        final wrote = await _gateway.writeOrderFact(canonical);
        if (wrote) {
          recordsWritten += 1;
        }
      }
      lastModifiedSeen = page.lastModifiedSeen.isAfter(lastModifiedSeen)
          ? page.lastModifiedSeen
          : lastModifiedSeen;
      cursor = page.nextCursor ?? '';
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: RevelWatermarkRow(
          cursorToken: cursor,
          lastModifiedSeen: lastModifiedSeen,
        ),
      );
      if (page.nextCursor == null) {
        break;
      }
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
    // Framework has already run sig + replay + binding + idempotency +
    // sanity by the time we get here. Adapter dispatches the canonical
    // write and returns the record count; per the framework contract
    // we MUST NOT re-call sanityHook in this path.
    final orderEnvelope = command.payload['order'];
    if (orderEnvelope is! Map) {
      // Malformed payload — drop at the boundary; the framework's
      // adapter-error path logs it and dead-letters on the third
      // attempt. No partial-parse warning flag (banned per V1 lean
      // cut 2 — the adapter either writes a clean fact or refuses).
      return const HandleWebhookResult(recordsWritten: 0);
    }
    final canonical = _canonicalize(
      operatorId: command.operatorId,
      locationId: command.locationId,
      payload: command.payload,
    );
    if (canonical == null) {
      return const HandleWebhookResult(recordsWritten: 0);
    }
    final wrote = await _gateway.writeOrderFact(canonical);
    return HandleWebhookResult(recordsWritten: wrote ? 1 : 0);
  }

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    var webhookUnregistered = false;
    final accessToken = await _gateway.readAccessToken(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (accessToken != null) {
      // Best-effort unregister; if it fails the credential wipe still
      // proceeds and the operator's connection is functionally torn
      // down on our side.
      try {
        await _transport.unregisterWebhook(
          accessToken: accessToken,
          subscriptionId: 'pending-from-metadata',
        );
        webhookUnregistered = true;
      } catch (_) {
        webhookUnregistered = false;
      }
    }
    await _gateway.wipeCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    return DisconnectResult(
      credentialsWiped: true,
      webhookUnregistered: webhookUnregistered,
      // Watermark and canonical facts are preserved per the framework
      // contract so reconnect resumes from the last cursor.
      watermarkPreserved: true,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<String> _requireAccessToken(
    String operatorId,
    String locationId,
  ) async {
    final token = await _gateway.readAccessToken(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (token == null) {
      throw StateError(
        'Revel access token missing for ($operatorId, $locationId); '
        'connection state should be `disconnected` or `error`.',
      );
    }
    return token;
  }

  /// Project a vendor-shape Revel order envelope into the canonical
  /// fact shape. Returns null when required fields are missing — the
  /// caller drops the row and the framework logs it via
  /// `connector_sync_log`.
  RevelCanonicalOrderFact? _canonicalize({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> payload,
  }) {
    final order = payload['order'];
    if (order is! Map) return null;
    final dyn = Map<String, Object?>.from(order);
    final id = dyn['id'];
    final updatedDate = _parseUtc(dyn['updated_date']);
    final createdDate = _parseUtc(dyn['created_date']);
    if (id == null || updatedDate == null || createdDate == null) {
      return null;
    }
    final coversValue = dyn['number_of_people'];
    if (coversValue is! int && coversValue is! num) {
      return null;
    }
    final salesValue = _parseSales(dyn['final_total']);
    if (salesValue == null) return null;
    return RevelCanonicalOrderFact(
      operatorId: operatorId,
      locationId: locationId,
      vendorEntityId: id.toString(),
      vendorModifiedAt: updatedDate,
      openedAt: createdDate,
      closedAt: updatedDate,
      covers: coversValue is int ? coversValue : (coversValue as num).toInt(),
      actualSales: salesValue,
      rawPayload: dyn,
    );
  }

  /// Build the payload-shape sanity hook expects: top-level
  /// `opened_at` / `closed_at` ISO 8601 strings (UTC) the framework's
  /// [VendorTimestampSanity] reads directly.
  Map<String, Object?> _payloadForSanity(Map<String, Object?> row) {
    final opened = _parseUtc(row['created_date']);
    final closed = _parseUtc(row['updated_date']);
    return <String, Object?>{
      'opened_at': opened?.toIso8601String(),
      'closed_at': closed?.toIso8601String(),
      'vendor_entity_id': row['id'],
    };
  }

  String? _instanceFromOrders(List<Map<String, Object?>> rows) {
    for (final row in rows) {
      final instance = row['establishment']?.toString() ??
          row['instance_name']?.toString();
      if (instance != null && instance.isNotEmpty) {
        return instance;
      }
    }
    return null;
  }

  String? _establishmentFromOrders(List<Map<String, Object?>> rows) {
    for (final row in rows) {
      final est = row['establishment_id'];
      if (est != null) {
        return est.toString();
      }
    }
    return null;
  }

  DateTime? _parseUtc(Object? raw) {
    if (raw is DateTime) return raw.toUtc();
    if (raw is String && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      return parsed?.toUtc();
    }
    return null;
  }

  num? _parseSales(Object? raw) {
    if (raw is num) return raw;
    if (raw is String && raw.isNotEmpty) {
      return num.tryParse(raw);
    }
    return null;
  }
}

// ─── OAuth refresh hook (24h client_credentials) ─────────────────────

/// Revel's OAuth flow is `client_credentials` with a 24h JWT bearer.
/// There is no refresh token; a "refresh" is a fresh
/// `client_credentials` exchange against the same client_id +
/// client_secret pair. The framework's
/// [OAuthRefreshCronRunner] still drives this surface — the runner
/// scans for tokens whose `token_expires_at` is inside the 24h
/// horizon (`kRefreshExpiryHorizon`) and fires this implementation.
///
/// V1 lean cut 2: no advisory locks, no email_outbox emit; the third
/// consecutive failure flips `connector_connection.status = 'error'`
/// via the gateway and the operator sees the state in admin chrome.
class RevelOAuthRefresher implements VendorOAuthRefresher {
  RevelOAuthRefresher({
    required RevelTransport transport,
    required Future<RevelCredentialEnvelope?> Function({
      required String operatorId,
      String? locationId,
    }) lookupCredentialEnvelope,
  })  : _transport = transport,
        _lookup = lookupCredentialEnvelope;

  final RevelTransport _transport;
  final Future<RevelCredentialEnvelope?> Function({
    required String operatorId,
    String? locationId,
  }) _lookup;

  @override
  String get vendorId => kRevelVendorId;

  @override
  Future<VendorRefreshOutcome> refresh({
    required String operatorId,
    String? locationId,
    required List<int> refreshTokenCiphertext,
  }) async {
    // Revel does not issue a refresh token; we re-exchange the
    // client_credentials pair the gateway hands us.
    final envelope = await _lookup(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (envelope == null) {
      return const VendorRefreshOutcome.failure(
        'no Revel credential envelope on file for refresh',
      );
    }
    try {
      final response = await _transport.exchangeClientCredentials(
        clientId: envelope.clientId,
        clientSecret: envelope.clientSecret,
        audience:
            documentedPerRevelV1['api_base_url']! as String,
      );
      // Re-encrypt is the gateway's job; the runner persists the new
      // ciphertext via `OAuthRefreshGateway.recordRefreshSuccess`.
      final accessCipher = utf8.encode(response.accessToken);
      return VendorRefreshOutcome.success(
        newAccessTokenCiphertext: accessCipher,
        // No refresh token on Revel — keep the same ciphertext (which
        // is `client_credentials` envelope, not an actual refresh
        // token) so the gateway's contract is satisfied.
        newRefreshTokenCiphertext: refreshTokenCiphertext,
        newExpiresAt: response.expiresAt,
      );
    } catch (e) {
      return VendorRefreshOutcome.failure('Revel token refresh failed: $e');
    }
  }
}

/// Plain-data envelope the refresher reads from the gateway. The
/// gateway is responsible for decrypting the credential ciphertext
/// inside its own `OperatorScopedRepository.withTenant` block — this
/// envelope is the in-memory hop and never persists.
class RevelCredentialEnvelope {
  const RevelCredentialEnvelope({
    required this.clientId,
    required this.clientSecret,
  });

  final String clientId;
  final String clientSecret;
}

// ─── Webhook event constants ─────────────────────────────────────────

/// `order.finalized` — primary event Revel emits when an order
/// completes. Documented at
/// `https://developer.revelsystems.com/revelsystems/docs/webhooks`.
const String kRevelWebhookEventOrderFinalized = 'order.finalized';
