// Phase 9.0Σ.h / 9.0Σ.h2 — AdvisorConversationLogRepository.
//
// Persistence layer for the `advisor_conversation_log` table created
// in `202604280007_phase_9_0sigma_h_advisor_conversation_log.sql`,
// with the audit-privacy permission gate landed in
// `202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`. Item 5
// from `phase_9_scalability_decisions_2026-04-27.md` and parcels B29
// + B46 in `phase_9_execution_backlog.md` lock the contract:
//
//   * Every advisor turn writes one provenance row through the proxy.
//     Raw content is encrypted before insert; the row stores the
//     encrypted bytes + IV + KMS key reference (never the raw key,
//     never plaintext).
//   * Read access to the encrypted columns is gated by the
//     `admin.audit_privacy.read` permission key (MFA required) plus
//     a `SET LOCAL ROLE audit_privacy` assumption inside the tenant
//     transaction. Every successful audit read writes one row into
//     `audit_logs` (action = `advisor_conversation_log.audit_privacy_read`)
//     capturing reader, reason, target conversation, and records-read
//     count.
//
// CLAUDE.md "RLS performance discipline" bindings:
//   * Every write goes through `OperatorScopedRepository.withTenant`
//     so `SET LOCAL app.operator_id` is in place when the per-tenant
//     RLS policy
//     (`advisor_conversation_log_per_tenant_insert`) evaluates.
//   * Indexes lead with `operator_id` so the policy folds into the
//     index probe (verified by the migration's index shape).
//   * Bare `current_setting()` is forbidden in policy bodies — the
//     migration calls `public.app_current_operator()` per the
//     9.0Σ.b wrapper lock.
//
// Audit-privacy split (item 5 + B46):
//   * The proxy's runtime `service_role` connection cannot see the
//     raw encrypted columns at all (column-level GRANT omits them).
//     The audit-read path opens a tenant transaction, asserts the
//     caller's app-layer authorization carries
//     `admin.audit_privacy.read`, issues `SET LOCAL ROLE audit_privacy`
//     just before the SELECT, restores role with `RESET ROLE` before
//     writing the audit row, and inserts a paired `audit_logs` row
//     in the same transaction. If the audit insert fails, the
//     SELECT is rolled back too — there is no read path that returns
//     ciphertext without leaving an audit trail.
//
// Privacy posture:
//   * The repository never accepts plaintext content. Producers pass
//     already-encrypted bytes; the constructor signature is the
//     single enforcement point.
//   * The audit-read path is the forensic surface: it returns the
//     raw `content_encrypted` / `content_iv` / `content_key_ref` /
//     `content_hash` so a forensic investigator can drive the
//     decryption pipeline (CMK lookup → AEAD decrypt). Those
//     secret-shaped fields live on [AuditPrivacyConversationRow]
//     under explicit, audit-named accessors, but the value object's
//     `toString()` deliberately does NOT include them — accidental
//     `print(row)` / log-line interpolation cannot leak the bytes,
//     IV, key reference, or hash. Callers that need the encrypted
//     payload must read the named field explicitly, which makes
//     the disclosure surface auditable in code review.
//   * Errors thrown from this layer never echo encrypted bytes,
//     IV bytes, key references, hashes, or token values — the
//     messages name only the table, the failure mode (e.g. RLS
//     denial, permission denial, blank reason), and the contract
//     that was violated. `toString()` therefore cannot leak any
//     secret material because the class stores none.
//   * `set_config('app.operator_id', ...)` runs through bound
//     parameters via the wrapper; the operator UUID never appears
//     in a string-concatenated SQL fragment.

import 'dart:convert';

import '../../../../auth/permission_keys.dart';
import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class AdvisorConversationLogRepository extends OperatorScopedRepository {
  AdvisorConversationLogRepository(super.tenantWrapper);

  /// Allowed `role` values per the migration's CHECK constraint.
  /// Mirrored in Dart so a malformed argument never reaches the
  /// database — matches the defense-in-depth posture used by
  /// [TenantContext] (UUID validation) and [OrgUnitsRepository]
  /// (`unit_type`).
  static const Set<String> allowedRoles = <String>{
    'user',
    'assistant',
    'system',
    'tool',
  };

  /// SHA-256 hex format the migration's CHECK constraint enforces.
  /// Validated in Dart so a producer that forgot to digest the
  /// payload fails fast instead of after a transaction round-trip.
  static final RegExp _contentHashPattern = RegExp(r'^[0-9a-f]{64}$');

  /// INSERT one advisor-turn provenance row inside the caller's
  /// tenant transaction. Returns the freshly assigned UUID trace id
  /// (rendered as a string).
  ///
  /// All `content*` fields are bound as already-encrypted bytes /
  /// already-resolved KMS reference. The repository deliberately
  /// does NOT accept plaintext content — encryption happens upstream
  /// in the proxy using the KMS-managed CMK, and the row stores the
  /// ciphertext + IV + key reference verbatim.
  ///
  /// Arguments grouped:
  ///
  ///   * Tenant scope — `operatorId`, `locationId`, `userId`. The
  ///     `userId` is optional because system-issued / scheduled turns
  ///     have no human actor (matches the migration's
  ///     `user_id uuid null` column).
  ///
  ///   * Conversation context — `conversationId`, `turnIndex`, `role`.
  ///     `role` is validated against [allowedRoles] before the round-
  ///     trip; `turnIndex` is rejected at zero-or-positive in the DB
  ///     CHECK and validated here for the same reason.
  ///
  ///   * Encrypted payload — `contentEncrypted` (bytea),
  ///     `contentIv` (bytea), `contentKeyRef` (KMS path/version),
  ///     `contentHash` (SHA-256 hex of the canonical payload).
  ///
  ///   * Surface / query-class metadata — `surface`, `queryClass`
  ///     (nullable), `usageClass`. All non-sensitive; queryable
  ///     through `service_role` for audit/replay summaries.
  ///
  ///   * Provider / model / token / cost — `provider`, `modelId`,
  ///     `modelVersion`, `promptTokenCount`, `completionTokenCount`,
  ///     `costUsd`, `latencyMs`. All nullable; system-issued `tool`
  ///     turns may carry none of them.
  Future<String> recordTurn({
    required String operatorId,
    required String locationId,
    String? userId,
    required String conversationId,
    required int turnIndex,
    required String role,
    required List<int> contentEncrypted,
    required List<int> contentIv,
    required String contentKeyRef,
    required String contentHash,
    required String surface,
    String? queryClass,
    required String usageClass,
    String? provider,
    String? modelId,
    String? modelVersion,
    int? promptTokenCount,
    int? completionTokenCount,
    num? costUsd,
    int? latencyMs,
  }) {
    _validateRole(role);
    if (turnIndex < 0) {
      throw ArgumentError.value(
        turnIndex,
        'turnIndex',
        'must be zero or positive (advisor turns are 0-indexed)',
      );
    }
    if (contentEncrypted.isEmpty) {
      throw ArgumentError.value(
        contentEncrypted.length,
        'contentEncrypted',
        'must be a non-empty byte sequence',
      );
    }
    if (contentIv.isEmpty) {
      throw ArgumentError.value(
        contentIv.length,
        'contentIv',
        'must be a non-empty byte sequence',
      );
    }
    if (contentKeyRef.isEmpty || contentKeyRef.length > 200) {
      throw ArgumentError.value(
        contentKeyRef.length,
        'contentKeyRef',
        'must be 1..200 characters',
      );
    }
    if (!_contentHashPattern.hasMatch(contentHash)) {
      throw ArgumentError.value(
        contentHash.length,
        'contentHash',
        'must be a 64-character lowercase SHA-256 hex digest',
      );
    }
    if (surface.isEmpty || surface.length > 64) {
      throw ArgumentError.value(
        surface.length,
        'surface',
        'must be 1..64 characters',
      );
    }
    final qc = queryClass;
    if (qc != null && (qc.isEmpty || qc.length > 64)) {
      throw ArgumentError.value(
        qc.length,
        'queryClass',
        'must be null or 1..64 characters',
      );
    }
    if (usageClass.isEmpty || usageClass.length > 64) {
      throw ArgumentError.value(
        usageClass.length,
        'usageClass',
        'must be 1..64 characters',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into advisor_conversation_log ('
        'operator_id, location_id, user_id, conversation_id, '
        'turn_index, role, '
        'content_encrypted, content_iv, content_key_ref, content_hash, '
        'surface, query_class, usage_class, '
        'provider, model_id, model_version, '
        'prompt_token_count, completion_token_count, cost_usd, '
        'latency_ms) '
        'values ('
        '@operator_id::uuid, @location_id::uuid, @user_id::uuid, '
        '@conversation_id::uuid, '
        '@turn_index, @role, '
        '@content_encrypted, @content_iv, @content_key_ref, '
        '@content_hash, '
        '@surface, @query_class, @usage_class, '
        '@provider, @model_id, @model_version, '
        '@prompt_token_count, @completion_token_count, @cost_usd, '
        '@latency_ms) '
        'returning id::text as id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
          'conversation_id': conversationId,
          'turn_index': turnIndex,
          'role': role,
          'content_encrypted': contentEncrypted,
          'content_iv': contentIv,
          'content_key_ref': contentKeyRef,
          'content_hash': contentHash,
          'surface': surface,
          'query_class': queryClass,
          'usage_class': usageClass,
          'provider': provider,
          'model_id': modelId,
          'model_version': modelVersion,
          'prompt_token_count': promptTokenCount,
          'completion_token_count': completionTokenCount,
          'cost_usd': costUsd,
          'latency_ms': latencyMs,
        },
      );
      if (rows.isEmpty) {
        // The error message names only the table and the failure mode
        // — never the bound parameters — so this surface cannot leak
        // ciphertext / IV / key reference / hash through logs.
        throw StateError(
          'advisor_conversation_log insert returned no rows — RLS may '
          'have blocked the row even though SET LOCAL ran',
        );
      }
      final id = rows.single['id'];
      if (id is! String || id.isEmpty) {
        throw StateError(
          'advisor_conversation_log insert returned a malformed id',
        );
      }
      return id;
    });
  }

  /// SQL action key written to `audit_logs.action` for every paired
  /// audit row this repository emits during an audit-privacy read.
  /// Captured as a constant so tests, the runbook, and the contract
  /// doc agree byte-for-byte.
  static const String auditPrivacyReadAction =
      'advisor_conversation_log.audit_privacy_read';

  /// Read raw advisor-conversation rows under the audit-privacy
  /// access path. The forensic surface — returns the encrypted
  /// payload (ciphertext + IV + KMS key reference + content hash)
  /// alongside the metadata so a forensic investigator can drive
  /// the decryption pipeline (CMK lookup → AEAD decrypt) under the
  /// paired audit row this method writes.
  ///
  /// The encrypted bytes ride on [AuditPrivacyConversationRow] under
  /// explicit, audit-named accessors (`contentEncrypted`,
  /// `contentIv`, `contentKeyRef`, `contentHash`); the value
  /// object's `toString()` deliberately does NOT include them, so
  /// accidental log-line interpolation cannot leak the payload.
  /// Callers that need the bytes must read the named field
  /// explicitly, which makes every disclosure surface auditable in
  /// code review.
  ///
  /// The caller MUST hold [PermissionKeys.adminAuditPrivacyRead] at
  /// request time (validated via [authorization]) and supply a
  /// non-blank [reason]. The repository validates these BEFORE the
  /// tenant transaction opens so a malformed call cannot reach the
  /// `SET LOCAL ROLE audit_privacy` step.
  ///
  /// In the tenant transaction, the repository:
  ///   1. `SET LOCAL ROLE audit_privacy` — flips into the column-
  ///      level GRANT scope that admits the encrypted columns
  ///      (`content_encrypted`, `content_iv`, `content_key_ref`).
  ///      The runtime `service_role` connection cannot SELECT those
  ///      columns at all without this role assumption.
  ///   2. SELECT the conversation rows including the encrypted
  ///      payload columns. These are the columns the audit-privacy
  ///      role exists to authorize; a SELECT under `service_role`
  ///      would error at the column-level GRANT layer.
  ///   3. `RESET ROLE` — drops back to the pooled connection's
  ///      owning role before writing the audit row.
  ///   4. INSERT one row into `audit_logs` with action =
  ///      `advisor_conversation_log.audit_privacy_read`,
  ///      `target_kind = 'advisor_conversation_log'`,
  ///      `target_id = <conversationId>`, and payload carrying
  ///      `reason` + `records_read_count`. If this insert fails the
  ///      SELECT is rolled back too — there is no read path that
  ///      returns ciphertext without leaving an audit trail.
  Future<List<AuditPrivacyConversationRow>> auditReadConversation({
    required AuditPrivacyAuthorization authorization,
    required String operatorId,
    required String locationId,
    required String readerUserId,
    required String conversationId,
    required String reason,
  }) {
    if (!authorization.permissions.contains(
      PermissionKeys.adminAuditPrivacyRead,
    )) {
      // Fail-closed: the message names the missing permission key so
      // the caller can fix the authorization wiring, but it does NOT
      // echo any content / parameter values that might leak through
      // logs.
      throw const AuditPrivacyPermissionDenied();
    }
    final trimmedReason = reason.trim();
    if (trimmedReason.isEmpty) {
      throw ArgumentError.value(
        reason.length,
        'reason',
        'audit-privacy reads require a non-blank reason string',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: readerUserId,
    );
    return withTenant<List<AuditPrivacyConversationRow>>(ctx, (exec) async {
      // Step 1: assume audit_privacy ONLY for the encrypted SELECT.
      // SET LOCAL ROLE is transaction-scoped — committing or rolling
      // back this transaction releases the role assumption, so pooled
      // connection reuse cannot leak audit-privacy access into the
      // next request.
      await exec.execute('set local role audit_privacy');

      // Step 2: SELECT the conversation rows under the audit_privacy
      // role. The column list explicitly includes the encrypted
      // payload columns (`content_encrypted`, `content_iv`,
      // `content_key_ref`, `content_hash`) — those are the columns
      // the role assumption exists to authorize. A SELECT issued
      // through the runtime `service_role` connection cannot reach
      // them (the column-level GRANT in the h migration omits them
      // from `service_role`'s SELECT allowlist). The encrypted bytes
      // ride on the returned value object under explicit accessors,
      // but its `toString()` does not echo them — accidental log-
      // line interpolation cannot leak the payload.
      final List<PostgresRow> rows;
      try {
        rows = await exec.query(
          'select id::text as id, '
          'operator_id::text as operator_id, '
          'location_id::text as location_id, '
          'user_id::text as user_id, '
          'conversation_id::text as conversation_id, '
          'turn_index, role, '
          'content_encrypted, content_iv, content_key_ref, '
          'content_hash, '
          'surface, query_class, usage_class, '
          'provider, model_id, model_version, '
          'prompt_token_count, completion_token_count, cost_usd, '
          'latency_ms, '
          'legal_hold, retention_class, '
          'created_at '
          'from advisor_conversation_log '
          'where operator_id = @operator_id::uuid '
          'and conversation_id = @conversation_id::uuid '
          'order by turn_index',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'conversation_id': conversationId,
          },
        );
      } finally {
        // Step 3: drop back to the pooled connection's owning role
        // BEFORE writing the audit row, so the audit insert runs
        // against the audit_logs grant shape that `service_role` /
        // `forge_admin` hold (not `audit_privacy`, which has no
        // INSERT privilege on audit_logs). The reset runs in the
        // `finally` so a SELECT failure cannot leave the transaction
        // in an audit_privacy-elevated state.
        await exec.execute('reset role');
      }

      final results = <AuditPrivacyConversationRow>[
        for (final row in rows) AuditPrivacyConversationRow._fromRow(row),
      ];

      // Step 4: paired audit row. The payload is bound through
      // jsonb parameter binding — never string-concatenated — so the
      // reason string cannot escape into SQL even if it carries
      // adversarial characters.
      await exec.execute(
        'insert into audit_logs ('
        'operator_id, location_id, chain_date, '
        'actor_kind, actor_user_id, '
        'target_kind, target_id, '
        'action, payload'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, '
        "(now() at time zone 'UTC')::date, "
        "'user', @actor_user_id::uuid, "
        "'advisor_conversation_log', @target_id, "
        '@action, @payload::jsonb'
        ')',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'actor_user_id': readerUserId,
          'target_id': conversationId,
          'action': auditPrivacyReadAction,
          'payload': jsonEncode(<String, Object?>{
            'reason': trimmedReason,
            'records_read_count': results.length,
          }),
        },
      );

      return results;
    });
  }

  static void _validateRole(String value) {
    if (!allowedRoles.contains(value)) {
      throw ArgumentError.value(value, 'role', 'must be one of $allowedRoles');
    }
  }
}

/// Authorization handle the audit-read path checks before opening a
/// tenant transaction. The proxy resolves the caller's permissions
/// (Phase 9.6 resolver) and constructs this object once per request.
///
/// A strongly-typed handle, not a bare string, so the call-site
/// signature forces the caller to provide a permission set rather
/// than passing a raw key string the boundary could trivially typo.
class AuditPrivacyAuthorization {
  AuditPrivacyAuthorization({required Set<String> permissions})
    : permissions = Set<String>.unmodifiable(permissions);

  /// The caller's resolved permission keys at request time.
  final Set<String> permissions;

  // toString stays the default "Instance of '...' " — we deliberately
  // do NOT echo the permission set so an audit-privacy authorization
  // handle that lands in a log line cannot disclose the caller's
  // capability surface.
}

/// Thrown when the audit-read path is invoked without the required
/// `admin.audit_privacy.read` permission. The error names only the
/// missing permission key — never the bound parameter values — so
/// the message is safe to surface in logs.
class AuditPrivacyPermissionDenied implements Exception {
  const AuditPrivacyPermissionDenied();

  @override
  String toString() =>
      'AuditPrivacyPermissionDenied: caller is missing the '
      "'${PermissionKeys.adminAuditPrivacyRead}' permission required "
      'for advisor_conversation_log audit-privacy reads';
}

/// Forensic value object returned by
/// [AdvisorConversationLogRepository.auditReadConversation]. Carries
/// the encrypted payload (`contentEncrypted`, `contentIv`,
/// `contentKeyRef`, `contentHash`) so a forensic investigator can
/// drive the CMK lookup + AEAD decrypt pipeline, alongside the
/// non-sensitive metadata.
///
/// The secret-shaped fields are accessible only through their
/// explicit named getters; `toString()` deliberately surfaces
/// metadata only (the `id`, `conversationId`, `turnIndex`, `role`)
/// so accidental log-line interpolation / `print(row)` cannot leak
/// ciphertext, IV bytes, key references, or hash digests. Any
/// downstream code that wants to log a row should keep using
/// `toString()` (safe) and surface decrypted plaintext through a
/// separate, deliberately-audited surface.
class AuditPrivacyConversationRow {
  AuditPrivacyConversationRow({
    required this.id,
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.conversationId,
    required this.turnIndex,
    required this.role,
    required List<int> contentEncrypted,
    required List<int> contentIv,
    required this.contentKeyRef,
    required this.contentHash,
    required this.surface,
    required this.queryClass,
    required this.usageClass,
    required this.provider,
    required this.modelId,
    required this.modelVersion,
    required this.promptTokenCount,
    required this.completionTokenCount,
    required this.costUsd,
    required this.latencyMs,
    required this.legalHold,
    required this.retentionClass,
    required this.createdAt,
  }) : contentEncrypted = List<int>.unmodifiable(contentEncrypted),
       contentIv = List<int>.unmodifiable(contentIv);

  factory AuditPrivacyConversationRow._fromRow(PostgresRow row) {
    return AuditPrivacyConversationRow(
      id: row['id'] as String,
      operatorId: row['operator_id'] as String,
      locationId: row['location_id'] as String,
      userId: row['user_id'] as String?,
      conversationId: row['conversation_id'] as String,
      turnIndex: row['turn_index'] as int,
      role: row['role'] as String,
      contentEncrypted:
          (row['content_encrypted'] as List<int>?) ?? const <int>[],
      contentIv: (row['content_iv'] as List<int>?) ?? const <int>[],
      contentKeyRef: row['content_key_ref'] as String,
      contentHash: row['content_hash'] as String,
      surface: row['surface'] as String,
      queryClass: row['query_class'] as String?,
      usageClass: row['usage_class'] as String,
      provider: row['provider'] as String?,
      modelId: row['model_id'] as String?,
      modelVersion: row['model_version'] as String?,
      promptTokenCount: row['prompt_token_count'] as int?,
      completionTokenCount: row['completion_token_count'] as int?,
      costUsd: row['cost_usd'] as num?,
      latencyMs: row['latency_ms'] as int?,
      legalHold: row['legal_hold'] as bool,
      retentionClass: row['retention_class'] as String,
      createdAt: row['created_at'] as DateTime,
    );
  }

  /// UUID trace id of the row.
  final String id;
  final String operatorId;
  final String locationId;
  final String? userId;
  final String conversationId;
  final int turnIndex;
  final String role;

  /// Ciphertext of the canonical advisor-turn payload. Encrypted
  /// upstream of the proxy with the CMK referenced by
  /// [contentKeyRef]; decryption is the forensic caller's
  /// responsibility. Stored unmodifiable so a downstream consumer
  /// cannot mutate the underlying buffer.
  final List<int> contentEncrypted;

  /// AEAD initialization vector / nonce that pairs with
  /// [contentEncrypted]. Stored unmodifiable.
  final List<int> contentIv;

  /// Reference to the KMS-managed CMK that encrypted
  /// [contentEncrypted] (e.g. `kv://forge-flow/cmk/v1`). Never the
  /// raw key material.
  final String contentKeyRef;

  /// SHA-256 hex of the canonical advisor-turn payload, computed by
  /// the proxy at write time. Surfaced here so forensic readers can
  /// cross-check integrity after decrypt.
  final String contentHash;

  final String surface;
  final String? queryClass;
  final String usageClass;
  final String? provider;
  final String? modelId;
  final String? modelVersion;
  final int? promptTokenCount;
  final int? completionTokenCount;
  final num? costUsd;
  final int? latencyMs;
  final bool legalHold;
  final String retentionClass;
  final DateTime createdAt;

  /// Metadata-only rendering. Deliberately omits the encrypted
  /// payload, IV, key reference, and content hash so accidental log-
  /// line interpolation / `print(row)` cannot leak the secret-shaped
  /// fields. The format is pinned by tests so a future field
  /// addition that violates the privacy posture (e.g. echoing a
  /// hash) trips review.
  @override
  String toString() =>
      'AuditPrivacyConversationRow(id: $id, conversationId: '
      '$conversationId, turnIndex: $turnIndex, role: $role)';
}
