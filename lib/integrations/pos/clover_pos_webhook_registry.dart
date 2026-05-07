// Phase 8 (`8.transport.clover-pos`) — Production Clover webhook
// registry.
//
// Implements [CloverWebhookRegistry] by composing a [CloverApiClient]
// (for the HTTP `POST /v3/apps/{aId}/webhooks` and matching DELETE)
// with a tenant-scoped `connector_connection.metadata` writer (for
// persisting the returned subscription id under the
// `webhook_subscription_id` key the [CloverPosAdapter] reads on
// disconnect).
//
// Idempotency posture:
//
//   * `register` first looks for an existing
//     `connector_connection.metadata.webhook_subscription_id` for the
//     (operator, location, vendor=clover) row. If one is on file, it
//     is returned without an additional vendor-side POST — this matches
//     the contract test "idempotent re-subscribe doesn't double-create".
//   * The underlying `CloverApiClient.registerWebhook` sets an
//     `Idempotency-Key` so a transport-layer retry of a single subscribe
//     also lands the same subscription id.
//   * `unregister` is best-effort — the vendor-side DELETE may 404 if
//     Clover already revoked the subscription; the registry treats 404
//     as success (the desired end-state is achieved).
//
// Hard-Promise alignment:
//
//   * HP #1 (transport-only): no formula change.
//   * HP #4 (per-operator isolation): every read / write goes through
//     `OperatorScopedRepository.withTenant` so RLS is the backup
//     defense and the repository pattern is the primary one.
//   * HP #7 (server-side secrets): the registry never sees plaintext
//     tokens; the [CloverApiClient]'s injected token sources own that.

import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import 'clover_pos_adapter.dart';
import 'clover_pos_production_api_client.dart';

/// Resolves the F&F webhook callback URL the framework presents to
/// Clover at subscribe time. Production injects the deployed proxy
/// hostname (`https://app.forgeflow.app/v1/integrations/clover/webhook`);
/// tests pass a fixed URL.
typedef CloverWebhookCallbackUrlSource = String Function();

/// Static list of Clover event types the framework subscribes to. Per
/// `docs/integrations/clover/field_mapping.md` the framework consumes
/// order create / update events; payment events are not consumed at
/// V1 (covers / sales come from order finalisation).
const List<String> kCloverWebhookEventTypes = <String>[
  'O', // order create / update / delete (Clover's documented set)
];

/// Local literal — see `clover_pos_postgres_sink.dart` for the same
/// rationale. The adapter exposes `vendorId` only as an instance
/// getter.
const String _kCloverVendorId = 'clover';

/// Postgres-backed [CloverWebhookRegistry]. Composes a
/// [CloverApiClient] for vendor-side HTTP and an
/// [OperatorScopedRepository] base for the tenant-scoped metadata
/// writes / reads.
class CloverPosWebhookRegistry extends OperatorScopedRepository
    implements CloverWebhookRegistry {
  CloverPosWebhookRegistry(
    super.tenantWrapper, {
    required CloverApiClient api,
    required CloverWebhookCallbackUrlSource callbackUrlSource,
    List<String> eventTypes = kCloverWebhookEventTypes,
  })  : _api = api,
        _callbackUrlSource = callbackUrlSource,
        _eventTypes = eventTypes;

  final CloverApiClient _api;
  final CloverWebhookCallbackUrlSource _callbackUrlSource;
  final List<String> _eventTypes;

  @override
  Future<String> register({
    required String operatorId,
    required String locationId,
    required String merchantId,
  }) async {
    if (merchantId.isEmpty) {
      throw ArgumentError.value(
        merchantId,
        'merchantId',
        'must be non-empty',
      );
    }

    // Step 1 — look for an existing subscription id on the connection
    // row. If present, the framework already subscribed for this
    // (operator, location); return that id without a fresh POST so a
    // reconnect storm does not double-register on Clover's side.
    final existing = await _readSubscriptionId(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final callbackUrl = _callbackUrlSource();
    if (callbackUrl.isEmpty) {
      throw StateError('Clover webhook callback URL source returned empty');
    }

    // Step 2 — vendor-side POST. The API client's Idempotency-Key
    // protects this call from creating duplicates if the request
    // succeeds at Clover but the response never reaches the worker.
    final subscriptionId = await _api.registerWebhook(
      merchantId: merchantId,
      callbackUrl: callbackUrl,
      eventTypes: _eventTypes,
    );

    // Step 3 — persist on the connection metadata so the adapter's
    // `disconnect` path can read it back. The writer JSON-merges the
    // key rather than replacing the metadata payload so other vendor
    // metadata (e.g. `merchant_id`) is preserved.
    await _writeSubscriptionId(
      operatorId: operatorId,
      locationId: locationId,
      subscriptionId: subscriptionId,
    );

    return subscriptionId;
  }

  @override
  Future<bool> unregister({
    required String operatorId,
    required String locationId,
    required String merchantId,
    required String subscriptionId,
  }) async {
    if (merchantId.isEmpty) {
      throw ArgumentError.value(
        merchantId,
        'merchantId',
        'must be non-empty',
      );
    }
    if (subscriptionId.isEmpty) {
      throw ArgumentError.value(
        subscriptionId,
        'subscriptionId',
        'must be non-empty',
      );
    }
    try {
      await _api.unregisterWebhook(
        merchantId: merchantId,
        subscriptionId: subscriptionId,
      );
    } on CloverApiClientErrorException catch (e) {
      // 404 — Clover already revoked the subscription (operator-side
      // app removal is a common path). Honour the end-state and clean
      // up our metadata.
      if (e.statusCode != 404) {
        await _clearSubscriptionId(
          operatorId: operatorId,
          locationId: locationId,
        );
        return false;
      }
    } on CloverApiAuthException {
      // 401 / 403 on disconnect is treated as best-effort failure;
      // the framework's overall disconnect contract still wipes
      // credentials. Surface the failure to the caller.
      await _clearSubscriptionId(
        operatorId: operatorId,
        locationId: locationId,
      );
      return false;
    } on CloverApiException {
      // Other vendor-side errors are also best-effort failures.
      await _clearSubscriptionId(
        operatorId: operatorId,
        locationId: locationId,
      );
      return false;
    }
    await _clearSubscriptionId(
      operatorId: operatorId,
      locationId: locationId,
    );
    return true;
  }

  // ─── helpers ──────────────────────────────────────────────────────

  Future<String?> _readSubscriptionId({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        "select metadata->>'$kCloverMetadataWebhookSubscriptionIdKey' "
        '  as webhook_subscription_id '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': _kCloverVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final value = rows.single['webhook_subscription_id'];
      if (value is String && value.isNotEmpty) return value;
      return null;
    });
  }

  Future<void> _writeSubscriptionId({
    required String operatorId,
    required String locationId,
    required String subscriptionId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'update public.connector_connection set '
        '  metadata = '
        "    coalesce(metadata, '{}'::jsonb) "
        "    || jsonb_build_object('$kCloverMetadataWebhookSubscriptionIdKey', "
        '                           @subscription_id::text), '
        '  webhook_url_provisioned = true, '
        '  updated_at = now() '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': _kCloverVendorId,
          'subscription_id': subscriptionId,
        },
      );
    });
  }

  Future<void> _clearSubscriptionId({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'update public.connector_connection set '
        '  metadata = '
        "    coalesce(metadata, '{}'::jsonb) "
        "    - '$kCloverMetadataWebhookSubscriptionIdKey', "
        '  webhook_url_provisioned = false, '
        '  updated_at = now() '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': _kCloverVendorId,
        },
      );
    });
  }
}
