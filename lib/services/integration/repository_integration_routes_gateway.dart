// Phase 8.framework — Production `IntegrationRoutesGateway` impl.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) section "Sub-lane shape -> .0".
//
// This is the production wiring referenced by the dormancy gap in
// `tool/advisor_proxy/main.dart:653-668`:
//
//     // The bindings holder is set by a follow-up slice (real
//     // Postgres-backed gateway + adapter map); until then
//     // `tryHandleStatic` is a noop pass-through that returns false.
//
// Once the proxy bootstrap binds an instance of
// [RepositoryIntegrationRoutesGateway] into
// `Phase80IntegrationRoutes.globalBindings`, the
// `/v1/admin/operators/:opid/locations/:locid/integrations`,
// `/v1/admin/integrations/oauth/{vendor}/start|callback`,
// `/v1/admin/integrations/{vendor}/connect-key|test-connection|disconnect|logs`,
// routes light up against the canonical Phase 8.0 schema in
// `db/migrations/202605040000_phase_8_0_integration_framework.sql`:
//
//   - `public.connector_connection`
//   - `public.vendor_credentials`           (pgcrypto envelope)
//   - `public.connector_sync_log`
//   - `public.demo_mode_state`
//
// The class structurally matches `IntegrationRoutesGateway` from
// `tool/advisor_proxy/admin_integrations_routes.dart`: identical
// method names, parameter names, and return shapes. `lib/` cannot
// import from `tool/` without dragging the entire proxy module into
// the Flutter binary, so the proxy bootstrap wraps this concrete
// instance in a thin adapter that `implements
// IntegrationRoutesGateway`. The test layer drives the gateway
// directly without the adapter.
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//
//   * HP #1 (pure transport swap). The gateway only writes the
//     framework tables added by the Phase 8.0 migration; canonical
//     fact tables stay owned by sinks. Connect / disconnect lifecycle
//     never touches a fact row.
//   * HP #4 (per-operator isolation). Every read and write runs
//     through `OperatorScopedRepository.withTenant`; the wrapper
//     issues `set_config('app.operator_id', ...)` /
//     `app.location_id` so RLS is the backup defense.
//   * HP #7 (server-side secrets). Plaintext tokens never leave the
//     gateway: ciphertext goes in via `pgp_sym_encrypt(@plaintext,
//     @envelope_key)` and any decrypt is server-side only via
//     `pgp_sym_decrypt`. The Flutter clients never see them.
//
// Permission gate: `hasIntegrationsConfigurePermission` delegates to
// the existing `ProxyAdminPermissionGuard`. Revocation flows through
// the guard's cache invalidation (B19).
//
// Idempotency: connect paths upsert via the unique index
// `(operator_id, location_id, vendor_id, coalesce(module, ''))` on
// `connector_connection`. A second connect with the same key returns
// the same `connection_id`; no duplicate rows.
//
// Audit: every state change (connect, disconnect, status flip, key
// rotation) writes one row to `public.audit_logs` via
// [AuditLogsRepository] inside the same tenant transaction so the
// audit row commits atomically with the business write.

import 'dart:convert';

import '../../auth/permission_keys.dart';
import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import '../../infrastructure/persistence/postgres/tenant_transaction.dart';
import '../auth/proxy_admin_permission_guard.dart';
import 'integration_adapter_common.dart';

// ─── Typed errors ────────────────────────────────────────────────────

/// Base type for every error the gateway surfaces. Routes should
/// never see a bare `StateError` or `Exception` — they get one of
/// these so the HTTP layer can map error → status code uniformly.
sealed class IntegrationGatewayError implements Exception {
  const IntegrationGatewayError(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// 401 / 403. Actor lacks `integrations.configure`, or actor scope
/// does not match the requested (operator, location).
class IntegrationGatewayPermissionDenied extends IntegrationGatewayError {
  const IntegrationGatewayPermissionDenied(super.message);
}

/// 404. The (operator, location, vendor) triple has no
/// `connector_connection` row — disconnect / test-connection /
/// logs cannot run.
class IntegrationGatewayNotFound extends IntegrationGatewayError {
  const IntegrationGatewayNotFound(super.message);
}

/// 409. A precondition failed — e.g., trying to disconnect a row
/// already in `disconnected` status, or connecting a vendor that
/// already has an active connection in a conflicting category.
class IntegrationGatewayConflict extends IntegrationGatewayError {
  const IntegrationGatewayConflict(super.message);
}

/// 500. Credential decryption failed (pgcrypto wrong key, ciphertext
/// corruption, missing envelope). The message intentionally does not
/// echo the ciphertext — it carries only the field name so on-call
/// can diagnose without secrets in logs.
class IntegrationGatewayDecryptError extends IntegrationGatewayError {
  const IntegrationGatewayDecryptError(super.message);
}

/// 503. An optional collaborator (OAuth issuer / callback exchanger
/// / test-connection executor) is not wired in this deploy. The
/// route surfaces a 503 with the field name; bootstrap configures
/// the missing collaborator and redeploys.
class IntegrationGatewayUnavailable extends IntegrationGatewayError {
  const IntegrationGatewayUnavailable(super.message);
}

// ─── Optional collaborators ──────────────────────────────────────────

/// Issued at OAuth flow start. The gateway hands the operator's
/// browser the [redirectUrl] and persists the [stateToken] tied to
/// (operatorId, locationId, vendorId, module) so the callback can
/// verify it. Concrete impls live outside the gateway (HMAC-signed
/// state token in proxy bootstrap); the gateway never owns the
/// signing key.
class OAuthRedirect {
  const OAuthRedirect({required this.redirectUrl, required this.stateToken});

  final String redirectUrl;
  final String stateToken;
}

/// Issues OAuth start redirects. Optional — if null, [startOAuth]
/// surfaces [IntegrationGatewayUnavailable].
abstract class OAuthRedirectIssuer {
  Future<OAuthRedirect> issue({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    String? module,
  });
}

/// Result of exchanging an OAuth callback `code` for a token
/// envelope. The exchanger has already verified the state token's
/// HMAC and resolved (operator, location, actor) so the gateway
/// never owns the signing key.
class OAuthCallbackExchange {
  const OAuthCallbackExchange({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.category,
    required this.actorUserId,
    required this.accessTokenPlaintext,
    this.refreshTokenPlaintext,
    this.tokenExpiresAt,
    this.module,
    this.metadata = const <String, Object?>{},
    this.webhookUrl,
    this.firstBackfillStarted = true,
  });

  final String operatorId;
  final String locationId;
  final String vendorId;
  final IntegrationCategory category;
  final String actorUserId;
  // Plaintext crosses the seam exactly once between exchanger and
  // gateway, where the gateway immediately wraps it in
  // `pgp_sym_encrypt(@plaintext, @envelope_key)` server-side.
  final String accessTokenPlaintext;
  final String? refreshTokenPlaintext;
  final DateTime? tokenExpiresAt;
  final String? module;
  final Map<String, Object?> metadata;
  final String? webhookUrl;
  final bool firstBackfillStarted;
}

/// Exchanges OAuth callback `code` for a token envelope. Optional —
/// if null, [RepositoryIntegrationRoutesGateway.handleOAuthCallback]
/// surfaces [IntegrationGatewayUnavailable].
abstract class OAuthCallbackExchanger {
  Future<OAuthCallbackExchange> exchange({
    required String vendorId,
    required Map<String, String> queryParameters,
  });
}

/// Issues a test-connection diagnostic against a live credential.
/// Optional — if null, [RepositoryIntegrationRoutesGateway.testConnection]
/// surfaces [IntegrationGatewayUnavailable].
abstract class VendorTestConnectionExecutor {
  Future<TestConnectionResult> run({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String credentialId,
    required String accessTokenPlaintext,
  });
}

/// Resolves the [IntegrationCategory] for a key-paste vendor. The
/// production wiring overrides this via the
/// `vendor_capability_index` in the proxy bootstrap; tests pass a
/// fixture map.
typedef KeyPasteCategoryResolver =
    IntegrationCategory Function(String vendorId);

// ─── Production gateway ──────────────────────────────────────────────

/// Production [IntegrationRoutesGateway] (defined in
/// `tool/advisor_proxy/admin_integrations_routes.dart`). The class
/// matches that abstract structurally — identical method names,
/// parameter names, and return shapes — so the proxy bootstrap can
/// wrap it in a thin adapter that `implements
/// IntegrationRoutesGateway`. Tests construct the gateway directly.
class RepositoryIntegrationRoutesGateway extends OperatorScopedRepository {
  RepositoryIntegrationRoutesGateway({
    required TenantTransactionWrapper tenantWrapper,
    required ProxyAdminPermissionGuard permissionGuard,
    required String credentialEnvelopeKey,
    AuditLogsRepository auditLogs = const AuditLogsRepository(),
    OAuthRedirectIssuer? oauthRedirectIssuer,
    OAuthCallbackExchanger? oauthCallbackExchanger,
    VendorTestConnectionExecutor? testConnectionExecutor,
    KeyPasteCategoryResolver? keyPasteCategoryResolver,
    DateTime Function()? now,
  })  : assert(
          credentialEnvelopeKey != '',
          'credentialEnvelopeKey must be a non-empty string '
          '(pgcrypto pgp_sym_encrypt symmetric key)',
        ),
        _permissionGuard = permissionGuard,
        _envelopeKey = credentialEnvelopeKey,
        _auditLogs = auditLogs,
        _oauthRedirectIssuer = oauthRedirectIssuer,
        _oauthCallbackExchanger = oauthCallbackExchanger,
        _testConnectionExecutor = testConnectionExecutor,
        _keyPasteCategoryResolver = keyPasteCategoryResolver,
        _now = now ?? DateTime.now,
        super(tenantWrapper);

  final ProxyAdminPermissionGuard _permissionGuard;
  final String _envelopeKey;
  final AuditLogsRepository _auditLogs;
  final OAuthRedirectIssuer? _oauthRedirectIssuer;
  final OAuthCallbackExchanger? _oauthCallbackExchanger;
  final VendorTestConnectionExecutor? _testConnectionExecutor;
  final KeyPasteCategoryResolver? _keyPasteCategoryResolver;
  final DateTime Function() _now;

  // ─── Permission gate ───────────────────────────────────────────────

  Future<bool> hasIntegrationsConfigurePermission({
    required String operatorId,
    required String userId,
  }) async {
    final decision = await _permissionGuard.evaluate(
      ProxyAdminGuardContext(
        actorUserId: userId,
        operatorId: operatorId,
        // The router calls this with the actor's own (operator,
        // location). The Phase 9.6 resolver scopes the lookup by
        // operator + location internally; passing the actor's
        // location keeps the cache key uniform with the rest of the
        // admin routes.
        locationId: operatorId,
        lastFreshAuthAt: _now(),
        requestedPermissionKey: PermissionKeys.integrationsConfigure,
        requestedAt: _now(),
      ),
    );
    return decision is ProxyAdminAllowed;
  }

  // ─── List ──────────────────────────────────────────────────────────

  Future<Map<String, Object?>> listForLocation({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    await _requirePermission(
      operatorId: operatorId,
      userId: actorUserId,
    );
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<Map<String, Object?>>(ctx, (exec) async {
      final connections = await exec.query(
        'select connection_id::text as connection_id, '
        'vendor_id, category, status, module, '
        'metadata, '
        'last_sync_at, last_error_at, last_error_message, '
        'webhook_url_provisioned, disconnect_reason, '
        'credential_id::text as credential_id, '
        'created_at, updated_at '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        "  and status <> 'disconnected' "
        'order by vendor_id, coalesce(module, \'\')',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      final demo = await exec.query(
        'select category, is_demo, '
        'flipped_to_live_at, '
        'flipped_by_connection_id::text as flipped_by_connection_id '
        'from public.demo_mode_state '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connections': connections
            .map(_connectionRowToJson)
            .toList(growable: false),
        'demo_mode_state': demo.map(_demoModeRowToJson).toList(growable: false),
      };
    });
  }

  // ─── OAuth start ───────────────────────────────────────────────────

  Future<Map<String, Object?>> startOAuth({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    String? module,
  }) async {
    await _requirePermission(
      operatorId: operatorId,
      userId: actorUserId,
    );
    final issuer = _oauthRedirectIssuer;
    if (issuer == null) {
      throw const IntegrationGatewayUnavailable(
        'oauth_redirect_issuer_not_configured',
      );
    }
    final redirect = await issuer.issue(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      vendorId: vendorId,
      module: module,
    );
    // No DB write here: the state token is stamped + signed by the
    // issuer; the callback verifies + persists. This keeps the
    // start path side-effect free other than the audit row.
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    await withTenant<void>(ctx, (exec) async {
      await _auditLogs.writeRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        occurredAt: _now(),
        actorKind: 'user',
        actorUserId: actorUserId,
        targetKind: 'integration_oauth_start',
        targetId: vendorId,
        action: 'integration.oauth.start',
        payload: <String, Object?>{
          'vendor_id': vendorId,
          if (module != null) 'module': module,
        },
      );
    });
    return <String, Object?>{
      'redirect_url': redirect.redirectUrl,
      'state_token': redirect.stateToken,
      'vendor_id': vendorId,
      if (module != null) 'module': module,
    };
  }

  // ─── OAuth callback ────────────────────────────────────────────────

  Future<Map<String, Object?>> handleOAuthCallback({
    required String vendorId,
    required Map<String, String> queryParameters,
  }) async {
    final exchanger = _oauthCallbackExchanger;
    if (exchanger == null) {
      throw const IntegrationGatewayUnavailable(
        'oauth_callback_exchanger_not_configured',
      );
    }
    // The exchanger verifies the state token and resolves
    // (operator, location, actor) from it. We delegate the full
    // verification to the exchanger so the gateway never owns the
    // HMAC key.
    final exchange = await exchanger.exchange(
      vendorId: vendorId,
      queryParameters: queryParameters,
    );
    return _persistConnect(
      operatorId: exchange.operatorId,
      locationId: exchange.locationId,
      actorUserId: exchange.actorUserId,
      vendorId: exchange.vendorId,
      category: exchange.category,
      module: exchange.module,
      accessTokenPlaintext: exchange.accessTokenPlaintext,
      refreshTokenPlaintext: exchange.refreshTokenPlaintext,
      tokenExpiresAt: exchange.tokenExpiresAt,
      metadata: exchange.metadata,
      webhookUrl: exchange.webhookUrl,
      firstBackfillStarted: exchange.firstBackfillStarted,
      authMode: 'oauth',
    );
  }

  // ─── Connect via key paste ─────────────────────────────────────────

  Future<Map<String, Object?>> connectViaKeyPaste({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String apiKey,
    String? username,
    String? module,
  }) async {
    await _requirePermission(
      operatorId: operatorId,
      userId: actorUserId,
    );
    if (apiKey.trim().isEmpty) {
      throw const IntegrationGatewayConflict('api_key_empty');
    }
    final category =
        (_keyPasteCategoryResolver ?? _defaultKeyPasteCategoryResolver)(
      vendorId,
    );
    final metadata = <String, Object?>{
      if (username != null) 'username': username,
    };
    return _persistConnect(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      vendorId: vendorId,
      category: category,
      module: module,
      accessTokenPlaintext: apiKey,
      refreshTokenPlaintext: null,
      tokenExpiresAt: null,
      metadata: metadata,
      webhookUrl: null,
      firstBackfillStarted: true,
      authMode: 'key_paste',
    );
  }

  /// Default fallback that returns POS — every Wave A key-paste
  /// vendor in the framework is POS-class. Production wires the
  /// `vendor_capability_index` resolver via [keyPasteCategoryResolver]
  /// so labor / reservation key-paste vendors classify correctly.
  static IntegrationCategory _defaultKeyPasteCategoryResolver(
    String vendorId,
  ) {
    return IntegrationCategory.pos;
  }

  // ─── Test connection ───────────────────────────────────────────────

  Future<Map<String, Object?>> testConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
  }) async {
    await _requirePermission(
      operatorId: operatorId,
      userId: actorUserId,
    );
    final executor = _testConnectionExecutor;
    if (executor == null) {
      throw const IntegrationGatewayUnavailable(
        'test_connection_executor_not_configured',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    final decrypted = await withTenant<_DecryptedCredential>(ctx, (exec) async {
      final List<PostgresRow> rows;
      try {
        rows = await exec.query(
          'select cc.connection_id::text as connection_id, '
          'cc.credential_id::text as credential_id, '
          'cc.status, '
          'pgp_sym_decrypt(vc.access_token_ciphertext, @envelope_key) '
          '  as access_token_plaintext '
          'from public.connector_connection cc '
          'left join public.vendor_credentials vc '
          '  on vc.credential_id = cc.credential_id '
          'where cc.operator_id = @operator_id::uuid '
          '  and cc.location_id = @location_id::uuid '
          '  and cc.vendor_id = @vendor_id '
          'limit 1',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'vendor_id': vendorId,
            'envelope_key': _envelopeKey,
          },
        );
      } on IntegrationGatewayError {
        rethrow;
      } catch (error) {
        // pgcrypto wrong-key, corrupt ciphertext, or any other
        // server-side decrypt failure surfaces here. Re-wrap as
        // typed error so the route maps it to a 500 cleanly without
        // leaking the underlying SQL exception text.
        throw IntegrationGatewayDecryptError(
          'access_token_decrypt_failed: ${error.runtimeType}',
        );
      }
      if (rows.isEmpty) {
        throw IntegrationGatewayNotFound(
          'connector_connection_missing(vendor=$vendorId)',
        );
      }
      final row = rows.single;
      final credentialId = row['credential_id'];
      if (credentialId is! String || credentialId.isEmpty) {
        throw const IntegrationGatewayNotFound(
          'connector_connection_has_no_credential',
        );
      }
      final plaintext = row['access_token_plaintext'];
      if (plaintext == null) {
        throw const IntegrationGatewayDecryptError(
          'access_token_ciphertext_decrypt_returned_null',
        );
      }
      final plaintextString = plaintext is String
          ? plaintext
          : utf8.decode(plaintext as List<int>);
      return _DecryptedCredential(
        credentialId: credentialId,
        accessTokenPlaintext: plaintextString,
      );
    });
    final TestConnectionResult result;
    try {
      result = await executor.run(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        credentialId: decrypted.credentialId,
        accessTokenPlaintext: decrypted.accessTokenPlaintext,
      );
    } catch (error) {
      // Wrap any executor exception as a gateway error so the route
      // layer can surface a clean status code.
      throw IntegrationGatewayConflict(
        'test_connection_failed: ${error.toString()}',
      );
    }
    // Append a sync-log entry so the operator's "View logs" modal
    // surfaces the test invocation.
    await withTenant<void>(ctx, (exec) async {
      // Look up the connection_id for the sync log row.
      final lookup = await exec.query(
        'select connection_id::text as connection_id '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
        },
      );
      if (lookup.isEmpty) return;
      final connectionId = lookup.single['connection_id']! as String;
      await exec.execute(
        'insert into public.connector_sync_log ('
        'operator_id, location_id, connection_id, event_kind, '
        'duration_ms, error_message, payload_preview'
        ") values ("
        "@operator_id::uuid, @location_id::uuid, "
        "@connection_id::uuid, 'test_connection', "
        "@duration_ms, @error_message, @payload_preview::jsonb"
        ")",
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'duration_ms': result.elapsedMs,
          'error_message': result.authValid ? null : 'auth_invalid',
          'payload_preview': jsonEncode(<String, Object?>{
            'auth_valid': result.authValid,
            if (result.note != null) 'note': result.note,
          }),
        },
      );
      await _auditLogs.writeRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        occurredAt: _now(),
        actorKind: 'user',
        actorUserId: actorUserId,
        targetKind: 'integration_test_connection',
        targetId: vendorId,
        action: 'integration.test_connection',
        payload: <String, Object?>{
          'vendor_id': vendorId,
          'auth_valid': result.authValid,
          'elapsed_ms': result.elapsedMs,
        },
      );
    });
    return <String, Object?>{
      'auth_valid': result.authValid,
      'sample': result.sample,
      'field_mapping': result.fieldMapping,
      'elapsed_ms': result.elapsedMs,
      if (result.note != null) 'note': result.note,
    };
  }

  // ─── Disconnect ────────────────────────────────────────────────────

  Future<Map<String, Object?>> disconnect({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String reason,
  }) async {
    await _requirePermission(
      operatorId: operatorId,
      userId: actorUserId,
    );
    final disconnectReason = _normalizeDisconnectReason(reason);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<Map<String, Object?>>(ctx, (exec) async {
      final lookup = await exec.query(
        'select cc.connection_id::text as connection_id, '
        'cc.credential_id::text as credential_id, '
        'cc.status, '
        'cc.module '
        'from public.connector_connection cc '
        'where cc.operator_id = @operator_id::uuid '
        '  and cc.location_id = @location_id::uuid '
        '  and cc.vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
        },
      );
      if (lookup.isEmpty) {
        throw IntegrationGatewayNotFound(
          'connector_connection_missing(vendor=$vendorId)',
        );
      }
      final row = lookup.single;
      final connectionId = row['connection_id']! as String;
      final credentialId = row['credential_id'];
      final currentStatus = row['status'] as String;
      if (currentStatus == 'disconnected') {
        // Idempotent disconnect — return the existing row without
        // a second audit entry.
        return <String, Object?>{
          'connection_id': connectionId,
          'status': 'disconnected',
          'disconnect_reason': disconnectReason,
          'already_disconnected': true,
        };
      }
      // Soft-disable: flip status, stamp disconnect_reason. Watermark
      // rows stay so reconnect resumes from the cursor (HP #1: no
      // canonical-fact rewrite).
      await exec.execute(
        "update public.connector_connection "
        "   set status = 'disconnected', "
        "       disconnect_reason = "
        "         @disconnect_reason::public.connector_disconnect_reason, "
        "       updated_at = now(), "
        "       updated_by = @updated_by "
        " where connection_id = @connection_id::uuid",
        parameters: <String, Object?>{
          'connection_id': connectionId,
          'disconnect_reason': disconnectReason,
          'updated_by': actorUserId,
        },
      );
      // Wipe the credential ciphertext so an attacker who pops a
      // disconnected row cannot resume the vendor session. The row
      // itself stays for the audit trail; only the secret leaves.
      if (credentialId is String && credentialId.isNotEmpty) {
        await exec.execute(
          'update public.vendor_credentials '
          '   set access_token_ciphertext = null, '
          '       refresh_token_ciphertext = null, '
          '       is_active = false, '
          '       updated_at = now(), '
          '       updated_by = @updated_by '
          ' where credential_id = @credential_id::uuid',
          parameters: <String, Object?>{
            'credential_id': credentialId,
            'updated_by': actorUserId,
          },
        );
      }
      // Append a sync-log entry so the operator's "View logs" modal
      // shows the disconnect.
      await exec.execute(
        'insert into public.connector_sync_log ('
        'operator_id, location_id, connection_id, event_kind, '
        'error_message'
        ") values ("
        "@operator_id::uuid, @location_id::uuid, "
        "@connection_id::uuid, 'disconnect', "
        "@reason"
        ")",
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'reason': disconnectReason,
        },
      );
      await _auditLogs.writeRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        occurredAt: _now(),
        actorKind: 'user',
        actorUserId: actorUserId,
        targetKind: 'integration_connection',
        targetId: connectionId,
        action: 'integration.disconnect',
        payload: <String, Object?>{
          'vendor_id': vendorId,
          'disconnect_reason': disconnectReason,
        },
      );
      return <String, Object?>{
        'connection_id': connectionId,
        'status': 'disconnected',
        'disconnect_reason': disconnectReason,
        'already_disconnected': false,
      };
    });
  }

  // ─── Sync logs ─────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> listSyncLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) {
    final cappedLimit = limit < 1 ? 1 : (limit > 500 ? 500 : limit);
    // listSyncLogs is invoked from the GET logs route AFTER the
    // router has already enforced permission via
    // `hasIntegrationsConfigurePermission`; the router does not
    // pass `actorUserId` here. We still scope the query by
    // (operator, location) via the tenant context so RLS holds.
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<List<Map<String, Object?>>>(ctx, (exec) async {
      final rows = await exec.query(
        'select log_id::text as log_id, '
        'connection_id::text as connection_id, '
        'event_kind, records_count, duration_ms, '
        'error_message, payload_preview, occurred_at '
        'from public.connector_sync_log csl '
        'where csl.operator_id = @operator_id::uuid '
        '  and csl.location_id = @location_id::uuid '
        '  and csl.connection_id in ('
        '    select cc.connection_id from public.connector_connection cc '
        '    where cc.operator_id = @operator_id::uuid '
        '      and cc.location_id = @location_id::uuid '
        '      and cc.vendor_id = @vendor_id'
        '  ) '
        'order by occurred_at desc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'limit': cappedLimit,
        },
      );
      return rows.map(_syncLogRowToJson).toList(growable: false);
    });
  }

  // ─── Internal: connect upsert ──────────────────────────────────────

  /// Idempotent connect / reconnect. Same (operator, location,
  /// vendor, module) twice yields the same `connection_id`; the
  /// second call rotates the credential ciphertext and writes a new
  /// audit row.
  Future<Map<String, Object?>> _persistConnect({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required IntegrationCategory category,
    required String? module,
    required String accessTokenPlaintext,
    required String? refreshTokenPlaintext,
    required DateTime? tokenExpiresAt,
    required Map<String, Object?> metadata,
    required String? webhookUrl,
    required bool firstBackfillStarted,
    required String authMode,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<Map<String, Object?>>(ctx, (exec) async {
      // Step 1: upsert credential ciphertext via pgcrypto envelope.
      // The unique index treats null `module` as `''` and null
      // `location_id` as the all-zeros sentinel.
      final credentialRows = await exec.query(
        'insert into public.vendor_credentials ('
        'operator_id, location_id, vendor_id, module, '
        'access_token_ciphertext, refresh_token_ciphertext, '
        'token_expires_at, metadata, is_active, '
        'consecutive_refresh_failures, '
        'created_by, updated_by'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, @module, '
        'pgp_sym_encrypt(@access_token_plaintext, @envelope_key), '
        'case when @refresh_token_plaintext is null then null '
        '     else pgp_sym_encrypt(@refresh_token_plaintext, '
        '       @envelope_key) end, '
        '@token_expires_at, @metadata::jsonb, true, 0, '
        '@actor::text, @actor::text'
        ') '
        "on conflict (operator_id, "
        "  coalesce(location_id, "
        "    '00000000-0000-0000-0000-000000000000'::uuid), "
        "  vendor_id, coalesce(module, '')"
        ") do update set "
        'access_token_ciphertext = excluded.access_token_ciphertext, '
        'refresh_token_ciphertext = excluded.refresh_token_ciphertext, '
        'token_expires_at = excluded.token_expires_at, '
        'metadata = excluded.metadata, '
        'is_active = true, '
        'consecutive_refresh_failures = 0, '
        'updated_at = now(), '
        'updated_by = excluded.updated_by '
        'returning credential_id::text as credential_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'module': module,
          'access_token_plaintext': accessTokenPlaintext,
          'refresh_token_plaintext': refreshTokenPlaintext,
          'envelope_key': _envelopeKey,
          'token_expires_at': tokenExpiresAt,
          'metadata': jsonEncode(metadata),
          'actor': actorUserId,
        },
      );
      if (credentialRows.isEmpty) {
        throw const IntegrationGatewayConflict(
          'vendor_credentials_upsert_returned_no_rows',
        );
      }
      final credentialId = credentialRows.single['credential_id']! as String;

      // Step 2: upsert connector_connection. Same vendor + module
      // twice yields the same row by the unique index.
      final connectionRows = await exec.query(
        'insert into public.connector_connection ('
        'operator_id, location_id, vendor_id, category, status, '
        'module, metadata, last_sync_at, '
        'webhook_url_provisioned, credential_id, created_by, updated_by'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, '
        "@category, 'connected', "
        '@module, @metadata::jsonb, null, '
        '@webhook_url_provisioned::boolean, '
        '@credential_id::uuid, @actor, @actor'
        ') '
        "on conflict (operator_id, location_id, vendor_id, "
        "  coalesce(module, '')) do update set "
        "status = 'connected', "
        'category = excluded.category, '
        'metadata = excluded.metadata, '
        'webhook_url_provisioned = excluded.webhook_url_provisioned, '
        'credential_id = excluded.credential_id, '
        'disconnect_reason = null, '
        'last_error_at = null, '
        'last_error_message = null, '
        'updated_at = now(), '
        'updated_by = excluded.updated_by '
        'returning connection_id::text as connection_id, status',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'category': category.name,
          'module': module,
          'metadata': jsonEncode(metadata),
          'webhook_url_provisioned': webhookUrl != null,
          'credential_id': credentialId,
          'actor': actorUserId,
        },
      );
      if (connectionRows.isEmpty) {
        throw const IntegrationGatewayConflict(
          'connector_connection_upsert_returned_no_rows',
        );
      }
      final connectionId =
          connectionRows.single['connection_id']! as String;
      final status = connectionRows.single['status']! as String;

      // Step 3: append sync-log entry.
      await exec.execute(
        'insert into public.connector_sync_log ('
        'operator_id, location_id, connection_id, event_kind, '
        'payload_preview'
        ") values ("
        "@operator_id::uuid, @location_id::uuid, "
        "@connection_id::uuid, 'connect', "
        "@payload_preview::jsonb"
        ")",
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'payload_preview': jsonEncode(<String, Object?>{
            'auth_mode': authMode,
            if (module != null) 'module': module,
          }),
        },
      );
      // Step 4: audit log row for the state change.
      await _auditLogs.writeRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        occurredAt: _now(),
        actorKind: 'user',
        actorUserId: actorUserId,
        targetKind: 'integration_connection',
        targetId: connectionId,
        action: 'integration.connect',
        payload: <String, Object?>{
          'vendor_id': vendorId,
          'category': category.name,
          'auth_mode': authMode,
          if (module != null) 'module': module,
        },
      );
      return <String, Object?>{
        'connection_id': connectionId,
        'credential_id': credentialId,
        'vendor_id': vendorId,
        'category': category.name,
        'status': status,
        'metadata': metadata,
        'webhook_url': webhookUrl,
        'first_backfill_started': firstBackfillStarted,
        'operator_id': operatorId,
        'location_id': locationId,
        'actor_user_id': actorUserId,
      };
    });
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  /// Throws [IntegrationGatewayPermissionDenied] when the actor
  /// lacks `integrations.configure`. Routes that catch
  /// [IntegrationGatewayError] map this to a 403.
  Future<void> _requirePermission({
    required String operatorId,
    required String userId,
  }) async {
    final ok = await hasIntegrationsConfigurePermission(
      operatorId: operatorId,
      userId: userId,
    );
    if (!ok) {
      throw const IntegrationGatewayPermissionDenied(
        'integrations.configure_required',
      );
    }
  }

  /// Coerce the operator-supplied reason into the
  /// `connector_disconnect_reason` enum domain. Unknown strings fall
  /// back to `operator_action` so the route never explodes the DB
  /// transaction with a CHECK violation.
  String _normalizeDisconnectReason(String raw) {
    const allowed = <String>{
      'operator_action',
      'vendor_revoked',
      'vendor_endpoint_deprecated',
      'oauth_timeout',
    };
    final trimmed = raw.trim();
    if (allowed.contains(trimmed)) return trimmed;
    return 'operator_action';
  }

  Map<String, Object?> _connectionRowToJson(PostgresRow row) {
    return <String, Object?>{
      'connection_id': row['connection_id'],
      'vendor_id': row['vendor_id'],
      'category': row['category'],
      'status': row['status'],
      'module': row['module'],
      'metadata': _coerceJson(row['metadata']),
      'last_sync_at': _isoOrNull(row['last_sync_at']),
      'last_error_at': _isoOrNull(row['last_error_at']),
      'last_error_message': row['last_error_message'],
      'webhook_url_provisioned': row['webhook_url_provisioned'],
      'disconnect_reason': row['disconnect_reason'],
      'credential_id': row['credential_id'],
      'created_at': _isoOrNull(row['created_at']),
      'updated_at': _isoOrNull(row['updated_at']),
    };
  }

  Map<String, Object?> _demoModeRowToJson(PostgresRow row) {
    return <String, Object?>{
      'category': row['category'],
      'is_demo': row['is_demo'],
      'flipped_to_live_at': _isoOrNull(row['flipped_to_live_at']),
      'flipped_by_connection_id': row['flipped_by_connection_id'],
    };
  }

  Map<String, Object?> _syncLogRowToJson(PostgresRow row) {
    return <String, Object?>{
      'log_id': row['log_id'],
      'connection_id': row['connection_id'],
      'event_kind': row['event_kind'],
      'records_count': row['records_count'],
      'duration_ms': row['duration_ms'],
      'error_message': row['error_message'],
      'payload_preview': _coerceJson(row['payload_preview']),
      'occurred_at': _isoOrNull(row['occurred_at']),
    };
  }

  Object? _coerceJson(Object? value) {
    if (value == null) return null;
    if (value is Map || value is List) return value;
    if (value is String) {
      if (value.isEmpty) return null;
      try {
        return jsonDecode(value);
      } catch (_) {
        return value;
      }
    }
    return value;
  }

  String? _isoOrNull(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is String) return value;
    return value.toString();
  }
}

class _DecryptedCredential {
  const _DecryptedCredential({
    required this.credentialId,
    required this.accessTokenPlaintext,
  });

  final String credentialId;
  final String accessTokenPlaintext;
}
