// Phase 8 (`8.transport.clover-pos`) — Postgres-backed
// [CloverCredentialStore] production impl.
//
// The Clover credential-store seam exposes three methods the adapter
// depends on (`readMerchantId`, `readWebhookSubscriptionId`, `wipe`).
// The impl reads `connector_connection.metadata` for the two non-secret
// look-ups and updates `vendor_credentials` ciphertext columns plus the
// `connector_connection` status on `wipe`.
//
// Plaintext access tokens never appear in this file. The adapter never
// asks for plaintext — the Clover [CloverApiClient] gets its bearer
// from a separate `CloverAccessTokenSource` injected at the proxy
// boundary (decryption runs server-side via `pgp_sym_decrypt`).
//
// Hard-Promise alignment:
//
//   * HP #1 (transport-only): no formula change.
//   * HP #4 (per-operator isolation): every read / write goes through
//     `OperatorScopedRepository.withTenant`.
//   * HP #7 (server-side secrets): plaintext tokens never traverse this
//     surface. `wipe` nulls the ciphertext columns; `readMerchantId` /
//     `readWebhookSubscriptionId` only return non-secret metadata.

import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import 'clover_pos_adapter.dart';

const String _kCloverVendorId = 'clover';

class CloverPosPostgresCredentialStore extends OperatorScopedRepository
    implements CloverCredentialStore {
  CloverPosPostgresCredentialStore(super.tenantWrapper);

  @override
  Future<String?> readMerchantId({
    required String operatorId,
    required String locationId,
  }) {
    return _readMetadataKey(
      operatorId: operatorId,
      locationId: locationId,
      key: kCloverMetadataMerchantIdKey,
    );
  }

  @override
  Future<String?> readWebhookSubscriptionId({
    required String operatorId,
    required String locationId,
  }) {
    return _readMetadataKey(
      operatorId: operatorId,
      locationId: locationId,
      key: kCloverMetadataWebhookSubscriptionIdKey,
    );
  }

  @override
  Future<bool> wipe({
    required String operatorId,
    required String locationId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      // Wipe the ciphertext envelope — the framework treats this row
      // as the source of truth for "credentials present". Clearing the
      // ciphertext + flagging `is_active = false` is the V1 lean cut 2
      // posture (KMS rollout is a separate Production1 lane).
      final wipedCount = await exec.execute(
        'update public.vendor_credentials set '
        '  access_token_ciphertext = null, '
        '  refresh_token_ciphertext = null, '
        '  token_expires_at = null, '
        '  is_active = false, '
        '  consecutive_refresh_failures = 0, '
        '  updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and (location_id = @location_id::uuid or location_id is null) '
        '  and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': _kCloverVendorId,
        },
      );

      // Flip the connection row to `disconnected` with the documented
      // operator-action reason. The adapter's bespoke `disconnect`
      // result reflects this back to the framework.
      await exec.execute(
        'update public.connector_connection set '
        "  status = 'disconnected', "
        "  disconnect_reason = 'operator_action', "
        '  webhook_url_provisioned = false, '
        '  updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': _kCloverVendorId,
        },
      );

      return wipedCount >= 0;
    });
  }

  // ─── helpers ──────────────────────────────────────────────────────

  Future<String?> _readMetadataKey({
    required String operatorId,
    required String locationId,
    required String key,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        "select metadata->>@metadata_key as value "
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': _kCloverVendorId,
          'metadata_key': key,
        },
      );
      if (rows.isEmpty) return null;
      final value = rows.single['value'];
      if (value is String && value.isNotEmpty) return value;
      return null;
    });
  }
}
