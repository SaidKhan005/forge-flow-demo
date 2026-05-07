// Phase 8 framework — Production-backed [InboundWebhookGateway].
//
// Implements the [InboundWebhookGateway] surface declared in
// `lib/services/integration/inbound_webhook_handler.dart` against the
// Postgres tables landed by
// `db/migrations/202605040000_phase_8_0_integration_framework.sql` plus
// the webhook-signing-secret column added in
// `db/migrations/202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql`:
//
//   * `connector_connection`              — binding cross-check + sync log FK.
//   * `vendor_credentials`                — pgcrypto-decrypted webhook
//                                            signing secret (separate
//                                            column from the OAuth
//                                            bearer ciphertext).
//   * `inbound_webhook_idempotency`       — first-time / duplicate +
//                                            attempt counter.
//   * `inbound_webhook_dead_letter`       — terminal failure ledger.
//   * `connector_sync_log`                — per-event log surfaced in
//                                            the "View logs" modal.
//   * `sanity_log`                        — adapter-boundary sanity-drop ledger.
//
// Webhook signing secret vs OAuth bearer (CODE_OPS_DEBT.md Theme G #2):
//   The OAuth bearer (`access_token_ciphertext`) is for outbound API
//   polling. The webhook signing secret
//   (`webhook_signing_secret_ciphertext`) is the HMAC key the vendor
//   signs inbound webhooks with — every vendor's docs treat it as a
//   separate provisioning artifact. Conflating them broke signature
//   verification for every real vendor. [lookupSigningSecret] reads
//   ONLY `webhook_signing_secret_ciphertext`; when it is NULL the
//   gateway returns null and the handler fails closed (403, "no
//   signing secret on file").
//
// CLAUDE.md alignment:
//   * HP #4 (per-operator isolation): every write rides
//     [OperatorScopedRepository.withTenant] so SET LOCAL injects the
//     tenant context before any RLS policy evaluates. Cross-tenant
//     writes are impossible because [TenantContext] is constructed per
//     call and never reused.
//   * HP #1 (transport-only): the gateway only persists the framework
//     ledgers. It does not touch canonical fact tables.
//   * RLS-Ready Schema: writes go through `OperatorScopedRepository`;
//     RLS is the backup defense.
//
// CODE_HEALTH alignment:
//   * "Webhook synthetic event-id grows attempts table unboundedly"
//     (`inbound_webhook_handler.dart:565`) — synthetic-event-id spam
//     never matches an existing idempotency row because the hash
//     differs per payload. The handler retries 3 times then
//     dead-letters but the table still grows. The gateway closes that
//     loop by capping unprocessed synthetic-event rows per
//     `(operator_id, location_id, vendor_id)` at
//     [kSyntheticEventIdSoftCap] — once the cap is reached, additional
//     synthetic claims short-circuit to the dead-letter table without
//     creating a new idempotency row OR incrementing the attempts
//     counter on the existing rows. Vendor-issued event-ids are
//     unaffected (they hit the UNIQUE constraint by design).
//
// PII redaction:
//   * `connector_sync_log.payload_preview` is the only place a raw
//     payload preview lands. The gateway runs every preview through
//     [redactWebhookPayload] before the INSERT so common credential /
//     PII keys (`password`, `*_token`, `email`, `*_email`, `bearer`,
//     `vendor_payload`, etc.) are dropped from the column even when
//     the upstream caller forgot to scrub them.

import 'dart:convert';

import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import '../../infrastructure/persistence/postgres/tenant_transaction.dart';
import 'inbound_webhook_handler.dart';
import 'integration_adapter_common.dart';

/// Cap on **unprocessed** synthetic-event-id rows per
/// `(operator_id, location_id, vendor_id)` triple. Once the count
/// reaches this threshold, additional [claimIdempotency] calls with a
/// synthetic event-id return [IdempotencyOutcome.duplicate] without
/// creating a new idempotency row. The handler treats duplicates as
/// 200 no-ops, so the spam quietly absorbs at the boundary while the
/// terminal failure record lands in `inbound_webhook_dead_letter` for
/// triage. Closes CODE_HEALTH "Webhook synthetic event-id grows
/// attempts table unboundedly".
const int kSyntheticEventIdSoftCap = 10;

/// Synthetic event-ids are produced by
/// `_vendorEventIdOrSynthetic` in [InboundWebhookHandler] and prefixed
/// with `sha256:`. The gateway treats this prefix as the marker that
/// the row is synthetic and therefore subject to
/// [kSyntheticEventIdSoftCap].
const String kSyntheticEventIdPrefix = 'sha256:';

/// Sensitive field names dropped from
/// `connector_sync_log.payload_preview`. Lower-cased exact match.
/// Email-flavored keys (`*email*`) are also dropped via
/// [_isSensitiveFieldName].
const Set<String> kInboundWebhookSensitiveFields = <String>{
  'password',
  'current_password',
  'new_password',
  'recovery_code',
  'recovery_codes',
  'mfa_code',
  'totp_code',
  'totp_secret',
  'authorization',
  'authorization_id_token',
  'id_token',
  'access_token',
  'refresh_token',
  'jwt',
  'jwt_body',
  'bearer',
  'bearer_token',
  'api_key',
  'apikey',
  'secret',
  'signing_secret',
  'webhook_secret',
  'client_secret',
  'private_key',
  'card_number',
  'cvv',
  'ssn',
  'social_security_number',
  'phone',
  'phone_number',
  'address',
  'street_address',
  'first_name',
  'last_name',
  'full_name',
  'guest_name',
  'customer_name',
  'vendor_payload',
  'raw_vendor_payload',
  'plaintext',
};

/// Maximum byte length (UTF-8) of the JSONB payload preview. The
/// `connector_sync_log.payload_preview` CHECK constraint enforces
/// `octet_length(payload_preview::text) <= 2048`; we mirror it
/// client-side so a too-large preview is truncated to a sentinel
/// rather than rejected by the DB.
const int kPayloadPreviewMaxBytes = 2048;

/// Sentinel object inserted in place of an oversize payload preview.
/// Includes a marker so triage can tell at a glance that the original
/// was dropped client-side rather than missing from the wire.
const Map<String, Object?> kPayloadPreviewTooLargeSentinel =
    <String, Object?>{
  'redacted': true,
  'reason': 'payload_preview_exceeded_size_limit',
};

/// Maximum byte length of the dead-letter `payload_preview` column.
/// `inbound_webhook_dead_letter.payload_preview` allows 4 KiB; the
/// helper below mirrors that limit.
const int kDeadLetterPayloadPreviewMaxBytes = 4096;

/// Typed error thrown by the gateway. The handler catches and surfaces
/// these as `adapterError` outcomes so the proxy returns 500 (vendor
/// retries) rather than leaking the stack trace.
class InboundWebhookGatewayException implements Exception {
  const InboundWebhookGatewayException(this.message);
  final String message;

  @override
  String toString() => 'InboundWebhookGatewayException: $message';
}

/// Production-backed [InboundWebhookGateway].
///
/// Instances must be constructed with the same [TenantTransactionWrapper]
/// the rest of the proxy uses so SET LOCAL injection runs on every
/// transaction. The gateway never holds a [PostgresExecutor] field and
/// never opens a connection outside [withTenant] — all writes happen
/// inside the tenant-scoped transaction the wrapper opens for them.
class RepositoryInboundWebhookGateway extends OperatorScopedRepository
    implements InboundWebhookGateway {
  RepositoryInboundWebhookGateway(
    super.tenantWrapper, {
    required String pgcryptoEnvelopeKey,
  }) : _pgcryptoEnvelopeKey = pgcryptoEnvelopeKey {
    if (pgcryptoEnvelopeKey.isEmpty) {
      throw ArgumentError.value(
        pgcryptoEnvelopeKey,
        'pgcryptoEnvelopeKey',
        'must be non-empty (vendor credential decryption requires it)',
      );
    }
  }

  /// pgcrypto symmetric envelope key used to decrypt
  /// `vendor_credentials.webhook_signing_secret_ciphertext` (and other
  /// pgcrypto-enveloped columns on the same row). Server-side only;
  /// never exposed to clients.
  final String _pgcryptoEnvelopeKey;

  @override
  Future<ConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) {
    final ctx = _tenantContext(operatorId, locationId);
    return withTenant<ConnectionBinding?>(ctx, (exec) async {
      final rows = await exec.query(
        'select '
        '  connection_id::text as connection_id, '
        '  metadata, '
        '  status '
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
      if (rows.isEmpty) return null;
      final row = rows.single;
      final connectionId = row['connection_id'];
      final metadata = _decodeJsonbObject(row['metadata']);
      final statusRaw = row['status'];
      if (connectionId is! String || connectionId.isEmpty) {
        throw const InboundWebhookGatewayException(
          'connector_connection returned a malformed connection_id',
        );
      }
      if (statusRaw is! String) {
        throw const InboundWebhookGatewayException(
          'connector_connection returned a malformed status',
        );
      }
      return ConnectionBinding(
        connectionId: connectionId,
        metadata: metadata,
        status: _parseConnectionStatus(statusRaw),
      );
    });
  }

  @override
  Future<String?> lookupSigningSecret({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) {
    final ctx = _tenantContext(operatorId, locationId);
    return withTenant<String?>(ctx, (exec) async {
      // CODE_OPS_DEBT Theme G #2: read `webhook_signing_secret_ciphertext`,
      // NOT `access_token_ciphertext`. The OAuth bearer is not the
      // HMAC key — every vendor with `webhookSupport != pollOnly` mints
      // a separate signing secret in their portal. See
      // `db/migrations/202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql`
      // for the column header listing each affected vendor + secret
      // shape.
      //
      // Vendor credentials may be operator-wide (location_id NULL) for
      // grants like Square / 7shifts / QuickBooks Time / ADP. Resolve
      // the location-specific row first; fall back to the operator-wide
      // grant. Rows where the webhook signing secret has not yet been
      // provisioned (column is NULL) are skipped — the SELECT
      // short-circuits via `webhook_signing_secret_ciphertext is not
      // null` so we never decrypt an unrelated row's column.
      final rows = await exec.query(
        'select '
        '  pgp_sym_decrypt(webhook_signing_secret_ciphertext, '
        '    @envelope_key) as signing_secret '
        'from public.vendor_credentials '
        'where operator_id = @operator_id::uuid '
        '  and vendor_id = @vendor_id '
        '  and is_active = true '
        '  and webhook_signing_secret_ciphertext is not null '
        '  and (location_id = @location_id::uuid or location_id is null) '
        'order by '
        '  case when location_id is null then 1 else 0 end, '
        '  updated_at desc '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'envelope_key': _pgcryptoEnvelopeKey,
        },
      );
      if (rows.isEmpty) {
        // No row has a non-null `webhook_signing_secret_ciphertext` for
        // this (operator, location, vendor). Surface a clear warning
        // for triage — the handler will fail closed (reject 403) on
        // null. Operators must provision the secret via the credential
        // rotation runbook before signed webhooks for this vendor will
        // validate.
        // ignore: avoid_print
        print(
          'WARN repository_inbound_webhook_gateway: webhook signing '
          'secret not provisioned for vendor=$vendorId '
          'operator=$operatorId location=$locationId — fail-closed '
          '(see runbooks/admin_provider_credentials_kms_rollout_runbook.md '
          'section "Provision A Vendor Webhook Signing Secret").',
        );
        return null;
      }
      final secret = rows.single['signing_secret'];
      if (secret == null) return null;
      if (secret is String) return secret.isEmpty ? null : secret;
      throw const InboundWebhookGatewayException(
        'vendor_credentials returned a malformed signing_secret',
      );
    });
  }

  @override
  Future<IdempotencyOutcome> claimIdempotency({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) {
    final ctx = _tenantContext(operatorId, locationId);
    return withTenant<IdempotencyOutcome>(ctx, (exec) async {
      // Synthetic event-ids: bound the table by short-circuiting once
      // [kSyntheticEventIdSoftCap] unprocessed rows exist for this
      // (operator, location, vendor). The handler treats duplicate as
      // a 200 no-op; the dead-letter row lands separately so triage
      // sees the spam.
      final isSynthetic = vendorEventId.startsWith(kSyntheticEventIdPrefix);
      if (isSynthetic) {
        final unprocessedRows = await exec.query(
          'select count(*)::bigint as cnt '
          'from public.inbound_webhook_idempotency '
          'where operator_id = @operator_id::uuid '
          '  and location_id = @location_id::uuid '
          '  and vendor_id = @vendor_id '
          '  and processed = false '
          "  and vendor_event_id like 'sha256:%'",
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'vendor_id': vendorId,
          },
        );
        final unprocessed = _readBigInt(unprocessedRows);
        if (unprocessed >= kSyntheticEventIdSoftCap) {
          // Record a dead-letter row server-side defense + return
          // duplicate so the handler short-circuits to a 200 no-op
          // without ever creating a new attempts row.
          await _insertDeadLetterRow(
            exec,
            operatorId: operatorId,
            locationId: locationId,
            vendorId: vendorId,
            vendorEventId: vendorEventId,
            payloadPreview: const <String, Object?>{
              'redacted': true,
              'reason': 'synthetic_event_id_cap_exceeded',
            },
            failureKind: InboundWebhookFailureKind.idempotencyConflict,
            failureMessage:
                'synthetic event-id soft cap reached '
                '($kSyntheticEventIdSoftCap unprocessed rows for '
                '$vendorId@$operatorId/$locationId)',
          );
          return IdempotencyOutcome.duplicate;
        }
      }

      final inserted = await exec.query(
        'insert into public.inbound_webhook_idempotency '
        '  (operator_id, location_id, vendor_id, vendor_event_id, '
        '   received_at) '
        'values '
        '  (@operator_id::uuid, @location_id::uuid, @vendor_id, '
        '   @vendor_event_id, @received_at::timestamptz) '
        'on conflict (vendor_id, operator_id, vendor_event_id) '
        'do nothing '
        'returning idempotency_id::text as idempotency_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'vendor_event_id': vendorEventId,
          'received_at': receivedAt.toUtc(),
        },
      );
      if (inserted.isEmpty) {
        return IdempotencyOutcome.duplicate;
      }
      return IdempotencyOutcome.firstTime;
    });
  }

  @override
  Future<void> markProcessed({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) {
    final ctx = _tenantContext(operatorId, locationId);
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'update public.inbound_webhook_idempotency '
        '   set processed = true '
        ' where operator_id = @operator_id::uuid '
        '   and location_id = @location_id::uuid '
        '   and vendor_id = @vendor_id '
        '   and vendor_event_id = @vendor_event_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'vendor_event_id': vendorEventId,
        },
      );
    });
  }

  @override
  Future<void> recordSanityDrop({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String rule,
    required Map<String, Object?> payloadSummary,
  }) {
    final ctx = _tenantContext(operatorId, locationId);
    final summary = redactWebhookPayload(payloadSummary);
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.sanity_log '
        '  (operator_id, location_id, vendor_id, vendor_event_id, '
        '   rule, payload_summary) '
        'values '
        '  (@operator_id::uuid, @location_id::uuid, @vendor_id, '
        '   @vendor_event_id, @rule, @payload_summary::jsonb)',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'vendor_event_id': vendorEventId,
          'rule': rule,
          'payload_summary': jsonEncode(
            _capJsonObjectBytes(summary, kPayloadPreviewMaxBytes),
          ),
        },
      );
    });
  }

  @override
  Future<int> recordFailedAttempt({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String failureMessage,
    required DateTime receivedAt,
  }) {
    final ctx = _tenantContext(operatorId, locationId);
    return withTenant<int>(ctx, (exec) async {
      // UPSERT the attempts row + bump the counter atomically so the
      // returned attempt_count reflects this attempt, even when the
      // event was never claimIdempotency'd (e.g. signature_invalid
      // before idempotency check).
      final rows = await exec.query(
        'insert into public.inbound_webhook_idempotency '
        '  (operator_id, location_id, vendor_id, vendor_event_id, '
        '   received_at, attempt_count, last_error_message) '
        'values '
        '  (@operator_id::uuid, @location_id::uuid, @vendor_id, '
        '   @vendor_event_id, @received_at::timestamptz, 1, '
        '   @failure_message) '
        'on conflict (vendor_id, operator_id, vendor_event_id) '
        'do update set '
        '  attempt_count = '
        '    public.inbound_webhook_idempotency.attempt_count + 1, '
        '  last_error_message = excluded.last_error_message '
        'returning attempt_count',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'vendor_event_id': vendorEventId,
          'received_at': receivedAt.toUtc(),
          'failure_message': failureMessage,
        },
      );
      if (rows.isEmpty) {
        throw const InboundWebhookGatewayException(
          'inbound_webhook_idempotency upsert returned no rows',
        );
      }
      final count = rows.single['attempt_count'];
      if (count is int) return count;
      if (count is num) return count.toInt();
      throw const InboundWebhookGatewayException(
        'inbound_webhook_idempotency upsert returned a malformed '
        'attempt_count',
      );
    });
  }

  @override
  Future<void> deadLetter({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required Map<String, Object?> payloadPreview,
    required InboundWebhookFailureKind failureKind,
    required String failureMessage,
  }) {
    final ctx = _tenantContext(operatorId, locationId);
    return withTenant<void>(ctx, (exec) async {
      await _insertDeadLetterRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        vendorEventId: vendorEventId,
        payloadPreview: redactWebhookPayload(payloadPreview),
        failureKind: failureKind,
        failureMessage: failureMessage,
      );
    });
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) {
    final ctx = _tenantContext(operatorId, locationId);
    final preview = payloadPreview == null
        ? null
        : _capJsonObjectBytes(
            redactWebhookPayload(payloadPreview),
            kPayloadPreviewMaxBytes,
          );
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_sync_log '
        '  (operator_id, location_id, connection_id, event_kind, '
        '   records_count, error_message, payload_preview) '
        'values '
        '  (@operator_id::uuid, @location_id::uuid, '
        '   @connection_id::uuid, @event_kind, @records_count, '
        '   @error_message, @payload_preview::jsonb)',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'event_kind': eventKind,
          'records_count': recordsCount,
          'error_message': errorMessage,
          'payload_preview':
              preview == null ? null : jsonEncode(preview),
        },
      );
    });
  }

  // ── Internal helpers ─────────────────────────────────────────────

  Future<void> _insertDeadLetterRow(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required Map<String, Object?> payloadPreview,
    required InboundWebhookFailureKind failureKind,
    required String failureMessage,
  }) async {
    final preview = _capJsonObjectBytes(
      payloadPreview,
      kDeadLetterPayloadPreviewMaxBytes,
    );
    await exec.execute(
      'insert into public.inbound_webhook_dead_letter '
      '  (operator_id, location_id, vendor_id, vendor_event_id, '
      '   payload_preview, failure_kind, failure_message) '
      'values '
      '  (@operator_id::uuid, @location_id::uuid, @vendor_id, '
      '   @vendor_event_id, @payload_preview::jsonb, @failure_kind, '
      '   @failure_message)',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'vendor_id': vendorId,
        'vendor_event_id': vendorEventId,
        'payload_preview': jsonEncode(preview),
        'failure_kind': failureKind.sqlValue,
        'failure_message': failureMessage,
      },
    );
  }

  TenantContext _tenantContext(String operatorId, String locationId) {
    return TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  ConnectionStatus _parseConnectionStatus(String raw) {
    switch (raw) {
      case 'connected':
        return ConnectionStatus.connected;
      case 'disconnected':
        return ConnectionStatus.disconnected;
      case 'error':
        return ConnectionStatus.error;
    }
    throw InboundWebhookGatewayException(
      'connector_connection.status returned an unknown value: $raw',
    );
  }

  Map<String, Object?> _decodeJsonbObject(Object? raw) {
    if (raw == null) return const <String, Object?>{};
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    if (raw is String) {
      if (raw.isEmpty) return const <String, Object?>{};
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    }
    throw InboundWebhookGatewayException(
      'jsonb column returned an unsupported type ${raw.runtimeType}',
    );
  }

  int _readBigInt(List<PostgresRow> rows) {
    if (rows.isEmpty) return 0;
    final raw = rows.single['cnt'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.parse(raw);
    throw const InboundWebhookGatewayException(
      'count(*) returned a malformed value',
    );
  }
}

/// Strip sensitive field names from [payload] so they never land in
/// `connector_sync_log.payload_preview` /
/// `inbound_webhook_dead_letter.payload_preview` /
/// `sanity_log.payload_summary`. Recursive — handles nested maps and
/// lists. Pure function; safe to call without a database.
Map<String, Object?> redactWebhookPayload(Map<String, Object?> payload) {
  if (payload.isEmpty) return const <String, Object?>{};
  final out = <String, Object?>{};
  for (final entry in payload.entries) {
    if (_isSensitiveFieldName(entry.key)) {
      continue;
    }
    out[entry.key] = _redactValue(entry.value);
  }
  return out;
}

Object? _redactValue(Object? value) {
  if (value is Map<String, Object?>) {
    return redactWebhookPayload(value);
  }
  if (value is Map) {
    return redactWebhookPayload(
      value.map((k, v) => MapEntry(k.toString(), v)),
    );
  }
  if (value is List) {
    return value
        .map(_redactValue)
        .toList(growable: false);
  }
  return value;
}

bool _isSensitiveFieldName(String key) {
  final lower = key.toLowerCase();
  if (kInboundWebhookSensitiveFields.contains(lower)) return true;
  // Email-flavored keys land hashed-only or not at all. Hashed
  // surrogates (`*_email_hash`, `email_domain`) are explicitly
  // permitted; everything else flagged as email is dropped.
  if (lower == 'email' ||
      lower == 'email_address' ||
      lower.endsWith('_email') ||
      lower.endsWith('_email_address')) {
    return true;
  }
  // Any field whose name *contains* `token` / `secret` / `password`
  // is dropped on principle — vendors mint plenty of bespoke field
  // names that the explicit list above does not enumerate.
  if (lower.contains('token') ||
      lower.contains('secret') ||
      lower.contains('password') ||
      lower.contains('apikey') ||
      lower.contains('api_key')) {
    return true;
  }
  return false;
}

/// Mirror the DB CHECK constraint on payload_preview /
/// payload_summary by truncating oversized previews to a sentinel
/// object. The preview is not load-bearing for triage; an oversize
/// payload would simply be rejected by the constraint, and a 4xx /
/// 5xx in the gateway would mask the real failure the row is meant
/// to record. The sentinel is small enough to always fit.
Map<String, Object?> _capJsonObjectBytes(
  Map<String, Object?> payload,
  int maxBytes,
) {
  final encoded = jsonEncode(payload);
  if (encoded.length <= maxBytes) return payload;
  // octet_length on JSONB compares UTF-8 bytes of the cast text. Use
  // utf8.encode to get a byte-accurate comparison.
  if (utf8.encode(encoded).length <= maxBytes) return payload;
  return kPayloadPreviewTooLargeSentinel;
}
