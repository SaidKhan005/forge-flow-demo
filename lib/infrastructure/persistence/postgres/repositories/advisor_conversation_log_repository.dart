// Phase 9.0Σ.h — AdvisorConversationLogRepository.
//
// Persistence layer for the `advisor_conversation_log` table created
// in `202604280007_phase_9_0sigma_h_advisor_conversation_log.sql`. Item
// 5 from `phase_9_scalability_decisions_2026-04-27.md` and parcel B29
// in `phase_9_execution_backlog.md` lock the contract: every advisor
// turn writes one provenance row through the proxy, raw content is
// encrypted before insert, and the row stores the encrypted bytes +
// IV + KMS key reference (never the raw key, never plaintext).
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
// Audit-privacy split (item 5):
//   * This repository is write-only at the launch surface. The proxy
//     calls [recordTurn] inside its tenant transaction with the
//     ciphertext and IV produced by the encryption step that pairs
//     with `cutover.0a` CMK.
//   * The matching read API runs through the documented audit-
//     privacy access path (separate slice that lands alongside the
//     audit-privacy proxy gate). That path assumes the
//     `audit_privacy` Postgres role via `SET LOCAL ROLE` and pairs
//     every assumption with an `audit_logs` provenance row.
//
// Privacy posture:
//   * The repository never accepts plaintext content. Producers pass
//     already-encrypted bytes; the constructor signature is the
//     single enforcement point.
//   * Errors thrown from this layer never echo encrypted bytes,
//     IV bytes, key references, hashes, or token values — the
//     messages name only the table, the failure mode (e.g. RLS
//     denial), and the contract that was violated. `toString()`
//     therefore cannot leak any secret material because the class
//     stores none.
//   * `set_config('app.operator_id', ...)` runs through bound
//     parameters via the wrapper; the operator UUID never appears
//     in a string-concatenated SQL fragment.

import '../operator_scoped_repository.dart';
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
  static final RegExp _contentHashPattern =
      RegExp(r'^[0-9a-f]{64}$');

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

  static void _validateRole(String value) {
    if (!allowedRoles.contains(value)) {
      throw ArgumentError.value(
        value,
        'role',
        'must be one of $allowedRoles',
      );
    }
  }
}
