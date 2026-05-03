// Phase 8.0 — OAuth refresh cron (V1 lean cut 2).
//
// Production wiring lives in a `pg_cron` job at "5 minutes past every
// hour" calling `proxy.refresh_expiring_inbound_vendor_tokens()`.
// This Dart module is the corresponding application-side runner the
// proxy invokes (and the test fixtures drive). Behavior:
//
//   1. Find rows in `vendor_credentials` with `is_active = true` and
//      `token_expires_at < now() + interval '24 hours'`.
//   2. Refresh tokens via the adapter's vendor-side OAuth refresh
//      flow.
//   3. On success: persist new ciphertext + reset
//      `consecutive_refresh_failures` to 0; write
//      `connector_sync_log` entry `auth_refresh`.
//   4. On failure: increment `consecutive_refresh_failures`; on the
//      third consecutive failure, set
//      `connector_connection.status = 'error'` and write an
//      `audit_logs` row.
//
// V1 lean cut 2 changes from iter1:
//   * NO `pg_advisory_lock` per (operator, vendor). One cron
//     instance with low cadence has no contention at V1.
//   * NO `email_outbox` emit on auto-disable. The cron writes
//     audit_logs and flips status to `error`; operator sees the
//     state in admin UI. Email alert wiring lands later when
//     volume justifies it.
//   * NO `auto_disable_3_strike` enum value (removed from
//     `connector_disconnect_reason`). The status flip on the third
//     failure carries no separate operator-facing copy.

import 'integration_adapter_common.dart';

/// Auto-disable threshold. Three consecutive failures triggers
/// status flip to `error`; resets to 0 on a successful refresh.
const int kRefreshFailureAutoDisableThreshold = 3;

/// How far in advance of expiry a token is considered "near expiry".
/// pg_cron + the runner both filter on this window.
const Duration kRefreshExpiryHorizon = Duration(hours: 24);

/// One vendor row's view as seen by the runner.
class VendorCredentialRefreshRow {
  const VendorCredentialRefreshRow({
    required this.credentialId,
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.module,
    required this.refreshTokenCiphertext,
    required this.tokenExpiresAt,
    required this.consecutiveFailures,
  });

  final String credentialId;
  final String operatorId;
  final String? locationId;
  final String vendorId;
  final String? module;
  final List<int> refreshTokenCiphertext;
  final DateTime? tokenExpiresAt;
  final int consecutiveFailures;
}

/// Refresh result returned by the per-vendor OAuth refresher. The
/// concrete implementation lives in the adapter file; tests drive a
/// fake.
class VendorRefreshOutcome {
  const VendorRefreshOutcome.success({
    required this.newAccessTokenCiphertext,
    required this.newRefreshTokenCiphertext,
    required this.newExpiresAt,
  })  : ok = true,
        errorMessage = null;

  const VendorRefreshOutcome.failure(this.errorMessage)
      : ok = false,
        newAccessTokenCiphertext = const <int>[],
        newRefreshTokenCiphertext = const <int>[],
        newExpiresAt = null;

  final bool ok;
  final List<int> newAccessTokenCiphertext;
  final List<int> newRefreshTokenCiphertext;
  final DateTime? newExpiresAt;
  final String? errorMessage;
}

/// Per-vendor refresh implementation. Adapters that implement OAuth
/// register one of these; key-paste vendors do not (their
/// credentials never expire, so they bypass the cron entirely).
abstract class VendorOAuthRefresher {
  String get vendorId;

  /// Hits the vendor's `/oauth/token` (or equivalent) with
  /// `grant_type=refresh_token` and returns the new envelope.
  Future<VendorRefreshOutcome> refresh({
    required String operatorId,
    String? locationId,
    required List<int> refreshTokenCiphertext,
  });
}

/// Gateway interface the runner depends on. Production wires a
/// Postgres-backed implementation; tests pass a fake.
abstract class OAuthRefreshGateway {
  /// SELECT the rows that need refreshing. Must respect
  /// `is_active = true` and the [horizon] window.
  Future<List<VendorCredentialRefreshRow>> findExpiringCredentials({
    required DateTime now,
    required Duration horizon,
  });

  /// Persist the new envelope on success; reset
  /// `consecutive_refresh_failures` to 0; write a `connector_sync_log`
  /// row with `event_kind = 'auth_refresh'`.
  Future<void> recordRefreshSuccess({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required List<int> newAccessTokenCiphertext,
    required List<int> newRefreshTokenCiphertext,
    required DateTime newExpiresAt,
  });

  /// Increment `consecutive_refresh_failures`; write a
  /// `connector_sync_log` row with `event_kind = 'auth_refresh_failed'`.
  /// Returns the new failure count.
  Future<int> recordRefreshFailure({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required String errorMessage,
  });

  /// On the third consecutive failure: flip
  /// `connector_connection.status = 'error'`, write an `audit_logs`
  /// row capturing the trigger.
  ///
  /// V1 lean cut 2 — no email_outbox emit, no
  /// `disconnect_reason = 'auto_disable_3_strike'` value (the enum
  /// no longer carries it). The audit row records the precise
  /// trigger; the operator-facing copy is the same regardless of
  /// cause.
  Future<void> autoDisableConnection({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required String errorMessage,
  });
}

/// Per-tick result for telemetry.
class OAuthRefreshTickResult {
  const OAuthRefreshTickResult({
    required this.candidatesScanned,
    required this.refreshSuccesses,
    required this.refreshFailures,
    required this.autoDisabled,
  });

  final int candidatesScanned;
  final int refreshSuccesses;
  final int refreshFailures;
  final int autoDisabled;
}

/// Cron runner. Stateless across invocations; the gateway holds the
/// transactional state.
class OAuthRefreshCronRunner {
  OAuthRefreshCronRunner({
    required this.gateway,
    required this.refreshers,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final OAuthRefreshGateway gateway;
  final Map<String, VendorOAuthRefresher> refreshers;
  final DateTime Function() _now;

  /// Run one tick. The pg_cron job invokes this; production also
  /// runs a one-shot CLI for pre-flight checks.
  Future<OAuthRefreshTickResult> runOnce() async {
    // V1 lean cut 2: keep `_now` for future log timestamps. The
    // current implementation does not need a clock read at the top
    // of the tick because the gateway derives the horizon from its
    // own `now` parameter — but we keep the field on the runner so
    // tests can inject a fake clock if they need to.
    final now = _now().toUtc();
    final candidates = await gateway.findExpiringCredentials(
      now: now,
      horizon: kRefreshExpiryHorizon,
    );

    var refreshSuccesses = 0;
    var refreshFailures = 0;
    var autoDisabled = 0;

    for (final row in candidates) {
      final refresher = refreshers[row.vendorId];
      if (refresher == null) {
        // No refresher registered (key-paste vendor with no
        // OAuth, or future vendor not yet wired). Skip without
        // counting as failure.
        continue;
      }
      final outcome = await refresher.refresh(
        operatorId: row.operatorId,
        locationId: row.locationId,
        refreshTokenCiphertext: row.refreshTokenCiphertext,
      );
      if (outcome.ok && outcome.newExpiresAt != null) {
        await gateway.recordRefreshSuccess(
          credentialId: row.credentialId,
          operatorId: row.operatorId,
          locationId: row.locationId,
          vendorId: row.vendorId,
          newAccessTokenCiphertext: outcome.newAccessTokenCiphertext,
          newRefreshTokenCiphertext: outcome.newRefreshTokenCiphertext,
          newExpiresAt: outcome.newExpiresAt!,
        );
        refreshSuccesses += 1;
      } else {
        final failures = await gateway.recordRefreshFailure(
          credentialId: row.credentialId,
          operatorId: row.operatorId,
          locationId: row.locationId,
          vendorId: row.vendorId,
          errorMessage: outcome.errorMessage ?? 'unknown refresh failure',
        );
        refreshFailures += 1;
        if (failures >= kRefreshFailureAutoDisableThreshold) {
          await gateway.autoDisableConnection(
            credentialId: row.credentialId,
            operatorId: row.operatorId,
            locationId: row.locationId,
            vendorId: row.vendorId,
            errorMessage: outcome.errorMessage ?? 'unknown refresh failure',
          );
          autoDisabled += 1;
        }
      }
    }

    return OAuthRefreshTickResult(
      candidatesScanned: candidates.length,
      refreshSuccesses: refreshSuccesses,
      refreshFailures: refreshFailures,
      autoDisabled: autoDisabled,
    );
  }
}

/// Helper to project a [DisconnectReason] into the SQL enum value.
String disconnectReasonSqlValue(DisconnectReason reason) {
  switch (reason) {
    case DisconnectReason.operatorAction:
      return 'operator_action';
    case DisconnectReason.vendorRevoked:
      return 'vendor_revoked';
    case DisconnectReason.vendorEndpointDeprecated:
      return 'vendor_endpoint_deprecated';
    case DisconnectReason.oauthTimeout:
      return 'oauth_timeout';
  }
}
