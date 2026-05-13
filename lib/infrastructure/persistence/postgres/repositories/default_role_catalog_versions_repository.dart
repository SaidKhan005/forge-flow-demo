// Lane B B2.1 — DefaultRoleCatalogVersionsRepository.
//
// Persistence layer for the global F&F-wide `default_role_catalog_versions`
// table created in `202605131500_b2_1_default_role_catalog_versions.sql`.
//
// IMPORTANT — this repository does NOT extend `OperatorScopedRepository`.
// The Default Role catalog is a F&F-wide table (no operator_id column,
// no RLS policy). Every read/write routes through
// `TenantTransactionWrapper.runAsSystem` so the connection elevates to
// `forge_admin` (BYPASSRLS) for the lifetime of the transaction. The
// admin pool sees the catalog; tenant pools see only the resolver path
// (joined through the operators table) when computing the active
// version for an operator.
//
// CLAUDE.md authority:
//   * "Service-Layer Split" — `lib/infrastructure/persistence/postgres/`
//     is the only place raw `package:postgres` imports are allowed. The
//     repository owns Postgres I/O exclusively.
//   * "RLS-Ready Schema" — operator-scoped fact tables require RLS
//     policy stubs from creation. This table is NOT operator-scoped;
//     the migration explains why no RLS policy exists. The repository
//     enforces the admin-pool posture in code by routing every call
//     through `runAsSystem`.
//   * "Proxy & API Conventions" — admin writes are idempotent at the
//     proxy layer (Idempotency-Key + `proxy_requests` UNIQUE). The
//     repository does not own idempotency — the proxy route handler
//     does.
//
// Method surface (matching the slice spec):
//   * publishVersion — INSERT a new row, flip the prior current row's
//     `is_current = false` + stamp `superseded_at`, set the new row's
//     `is_current = true`. All inside a single transaction so the
//     partial UNIQUE INDEX never observes two current rows.
//   * getCurrentVersion — SELECT the lone `is_current = true` row.
//   * listVersions — SELECT history ordered by `version_number desc`.
//   * getVersion — SELECT by version_id.
//   * countOperatorsFollowing — read-side helper for the blast-radius
//     count emitted in the audit event payload at publish time.
//   * getBlastRadiusCounts — read-side helper for the B2.3 blast-radius
//     admin endpoint. Returns operator + location + user counts in one
//     round-trip so the B2.2 publish dialog can render "Affecting N
//     businesses, N locations, N users" numeric copy.
//
// Tested by:
//   * test/infrastructure/persistence/postgres/default_role_catalog_versions_repository_test.dart
//   * test/infrastructure/persistence/postgres/repositories/default_role_catalog_versions_repository_blast_radius_test.dart
//   * test/proxy/b2_1_default_role_catalog_routes_test.dart
//   * test/proxy/b2_3_default_role_catalog_blast_radius_test.dart

import 'dart:convert';

import '../tenant_transaction.dart';

/// Stable hex SHA-256 length carried as a CHECK by the migration; mirror
/// the value here so the repository can reject malformed input before a
/// round trip to Postgres.
const int _kPayloadSha256HexLength = 64;

/// One `default_role_catalog_versions` row, projected for the admin
/// console + the per-operator roles resolver.
class DefaultRoleCatalogVersionRow {
  const DefaultRoleCatalogVersionRow({
    required this.versionId,
    required this.versionNumber,
    required this.publishedAt,
    required this.publishedByUserId,
    required this.payload,
    required this.payloadSha256,
    required this.isCurrent,
    required this.supersededAt,
    required this.notes,
  });

  final String versionId;
  final int versionNumber;
  final DateTime publishedAt;
  final String publishedByUserId;

  /// The catalog payload as a Dart List (jsonb array). Each entry is a
  /// role definition map; the repository preserves the published shape
  /// verbatim so a rollback is a byte-identical replay.
  final List<Object?> payload;

  /// Lowercase hex SHA-256 of the canonical payload bytes. Computed at
  /// publish time; reads expose it so downstream consumers can verify
  /// the bytes match.
  final String payloadSha256;

  final bool isCurrent;
  final DateTime? supersededAt;
  final String? notes;

  Map<String, Object?> toJson() => <String, Object?>{
        'version_id': versionId,
        'version_number': versionNumber,
        'published_at': publishedAt.toUtc().toIso8601String(),
        'published_by_user_id': publishedByUserId,
        'payload': payload,
        'payload_sha256': payloadSha256,
        'is_current': isCurrent,
        if (supersededAt != null)
          'superseded_at': supersededAt!.toUtc().toIso8601String(),
        if (notes != null) 'notes': notes,
      };
}

/// Aggregate blast-radius counts for a default-role-catalog version,
/// computed across every operator pinned to the version. Surfaced by
/// the B2.3 `GET /v1/admin/auth/role-catalogs/blast-radius` endpoint so
/// the publish dialog can render the slice-specced "Affecting N
/// businesses, N locations, N users" copy.
///
/// `operatorCount` mirrors [DefaultRoleCatalogVersionsRepository.countOperatorsFollowing]
/// — operators with `default_role_catalog_version_id = versionId`.
/// Operators with a NULL pointer (follow-latest) are NOT counted; they
/// are the catalog's implicit audience and have no blast radius
/// against any specific version.
///
/// `locationCount` is every location whose operator is pinned to
/// `versionId`. NULL-pointer operators' locations are NOT counted.
///
/// `userCount` is every user row whose operator is pinned to
/// `versionId`. The `public.users` table has no `is_active` / `deleted_at`
/// columns at the present schema (verified against migration
/// `202604250005_advisor_cloud_foundation.sql`), so the count is a
/// total — soft-delete filtering would require a schema column that
/// does not yet exist. Documented honestly here so the consumer surface
/// can present the count as "users on file" rather than "active users".
class DefaultRoleCatalogBlastRadiusCounts {
  const DefaultRoleCatalogBlastRadiusCounts({
    required this.versionId,
    required this.operatorCount,
    required this.locationCount,
    required this.userCount,
  });

  final String versionId;
  final int operatorCount;
  final int locationCount;
  final int userCount;

  Map<String, Object?> toJson() => <String, Object?>{
        'version_id': versionId,
        'operator_count': operatorCount,
        'location_count': locationCount,
        'user_count': userCount,
      };
}

/// Thrown by [DefaultRoleCatalogVersionsRepository.publishVersion] when
/// the caller passes a malformed payload (non-array shape or empty),
/// SHA-256 (wrong length / non-hex), or notes (above 2000 chars).
/// The proxy translates this to a 400 with a stable error code.
class DefaultRoleCatalogPublishValidationError implements Exception {
  const DefaultRoleCatalogPublishValidationError({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() =>
      'DefaultRoleCatalogPublishValidationError($code): $message';
}

class DefaultRoleCatalogVersionsRepository {
  DefaultRoleCatalogVersionsRepository(this._tenantWrapper);

  final TenantTransactionWrapper _tenantWrapper;

  /// Publishes a new catalog version atomically.
  ///
  /// Transaction sequence (single `runAsSystem` block):
  ///   1. SELECT MAX(version_number) FOR UPDATE → next version number.
  ///   2. UPDATE the prior current row: is_current = false,
  ///      superseded_at = now() (skipped on the genesis publish when
  ///      no prior current row exists).
  ///   3. INSERT the new row with is_current = true and the computed
  ///      version_number.
  ///   4. Return the new row projected.
  ///
  /// The partial UNIQUE INDEX `default_role_catalog_versions_current_unique`
  /// guarantees the "at most one current" invariant; the FOR UPDATE
  /// lock above guarantees two concurrent publishes serialize (the
  /// second sees the first's freshly-inserted current row and either
  /// supersedes it or rolls back if its FOR UPDATE detects a stale read).
  ///
  /// Caller responsibilities:
  ///   * Compute [payloadSha256] over the canonical bytes of [payload]
  ///     before calling. This repository does NOT compute SHA-256 (the
  ///     value is content-addressed evidence; the call site must own it).
  ///   * Supply [publishedByUserId] as the F&F admin's Postgres user_id
  ///     UUID (the proxy role gate already enforces super_admin).
  ///   * Use the proxy idempotency layer (`Idempotency-Key` header +
  ///     `proxy_requests` UNIQUE) to coalesce retries — this repository
  ///     does not idempotently handle replays.
  Future<DefaultRoleCatalogVersionRow> publishVersion({
    required String publishedByUserId,
    required List<Object?> payload,
    required String payloadSha256,
    String? notes,
    String reason = 'admin.default_role_catalog.publish',
  }) {
    _validatePayload(payload);
    _validatePayloadSha256(payloadSha256);
    _validateNotes(notes);

    return _tenantWrapper.runAsSystem<DefaultRoleCatalogVersionRow>(
      (exec) async {
        // Step 1: lock the current row (if any) and compute the next
        // version_number. We use `for update` on the partial index
        // predicate so two concurrent publishes serialize on the same
        // row; if no current exists yet, the lock is a no-op and the
        // INSERT below starts version 1.
        final lockedRows = await exec.query(
          'select version_number '
          'from public.default_role_catalog_versions '
          'where is_current = true '
          'for update',
        );

        final maxRows = await exec.query(
          'select coalesce(max(version_number), 0) as max_v '
          'from public.default_role_catalog_versions',
        );
        final maxVal = maxRows.single['max_v'];
        final nextVersionNumber = (maxVal is int)
            ? maxVal + 1
            : (maxVal is num)
                ? maxVal.toInt() + 1
                : 1;

        // Step 2: supersede the prior current row (if any).
        if (lockedRows.isNotEmpty) {
          await exec.execute(
            'update public.default_role_catalog_versions '
            'set is_current = false, '
            '    superseded_at = now() '
            'where is_current = true',
          );
        }

        // Step 3: INSERT the new row as current.
        final inserted = await exec.query(
          'insert into public.default_role_catalog_versions ('
          'version_number, published_at, published_by_user_id, '
          'payload, payload_sha256, is_current, notes) '
          'values (@version_number::int, now(), '
          '@published_by_user_id::uuid, '
          '@payload::jsonb, @payload_sha256, true, @notes) '
          'returning version_id::text as version_id, '
          'version_number, published_at, '
          'published_by_user_id::text as published_by_user_id, '
          'payload, payload_sha256, is_current, '
          'superseded_at, notes',
          parameters: <String, Object?>{
            'version_number': nextVersionNumber,
            'published_by_user_id': publishedByUserId,
            'payload': jsonEncode(payload),
            'payload_sha256': payloadSha256,
            'notes': notes,
          },
        );
        if (inserted.isEmpty) {
          throw StateError(
            'default_role_catalog_versions insert returned no rows',
          );
        }
        return _rowFromMap(inserted.single);
      },
      reason: reason,
    );
  }

  /// Returns the lone `is_current = true` row, or null when no version
  /// has been published yet (the genesis state).
  Future<DefaultRoleCatalogVersionRow?> getCurrentVersion({
    String reason = 'admin.default_role_catalog.get_current',
  }) {
    return _tenantWrapper.runAsSystem<DefaultRoleCatalogVersionRow?>(
      (exec) async {
        final rows = await exec.query(
          'select version_id::text as version_id, '
          'version_number, published_at, '
          'published_by_user_id::text as published_by_user_id, '
          'payload, payload_sha256, is_current, '
          'superseded_at, notes '
          'from public.default_role_catalog_versions '
          'where is_current = true '
          'limit 1',
        );
        if (rows.isEmpty) return null;
        return _rowFromMap(rows.single);
      },
      reason: reason,
    );
  }

  /// Returns the row keyed by [versionId], or null when absent.
  Future<DefaultRoleCatalogVersionRow?> getVersion({
    required String versionId,
    String reason = 'admin.default_role_catalog.get_version',
  }) {
    return _tenantWrapper.runAsSystem<DefaultRoleCatalogVersionRow?>(
      (exec) async {
        final rows = await exec.query(
          'select version_id::text as version_id, '
          'version_number, published_at, '
          'published_by_user_id::text as published_by_user_id, '
          'payload, payload_sha256, is_current, '
          'superseded_at, notes '
          'from public.default_role_catalog_versions '
          'where version_id = @version_id::uuid '
          'limit 1',
          parameters: <String, Object?>{'version_id': versionId},
        );
        if (rows.isEmpty) return null;
        return _rowFromMap(rows.single);
      },
      reason: reason,
    );
  }

  /// Returns up to [limit] rows ordered by `version_number desc` for the
  /// admin history view. Defaults to 20; callable with a larger value
  /// when the admin console asks for "show all".
  Future<List<DefaultRoleCatalogVersionRow>> listVersions({
    int limit = 20,
    String reason = 'admin.default_role_catalog.list',
  }) {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be >= 1');
    }
    return _tenantWrapper.runAsSystem<List<DefaultRoleCatalogVersionRow>>(
      (exec) async {
        final rows = await exec.query(
          'select version_id::text as version_id, '
          'version_number, published_at, '
          'published_by_user_id::text as published_by_user_id, '
          'payload, payload_sha256, is_current, '
          'superseded_at, notes '
          'from public.default_role_catalog_versions '
          'order by version_number desc '
          'limit @limit::int',
          parameters: <String, Object?>{'limit': limit},
        );
        return rows
            .map(_rowFromMap)
            .toList(growable: false);
      },
      reason: reason,
    );
  }

  /// Counts operators that currently point at [versionId] via the
  /// `operators.default_role_catalog_version_id` column. The publish
  /// path emits this as the blast-radius count in the audit event
  /// payload (the count of operators whose pinned version is about to
  /// be superseded). Operators with NULL pointer follow the latest
  /// version automatically and are NOT counted by this method.
  ///
  /// Returns 0 when no operators are pinned (the common case at
  /// PR-merge time, since the column starts NULL for every operator).
  Future<int> countOperatorsFollowing({
    required String versionId,
    String reason = 'admin.default_role_catalog.blast_radius',
  }) {
    return _tenantWrapper.runAsSystem<int>(
      (exec) async {
        final rows = await exec.query(
          'select count(*) as cnt '
          'from public.operators '
          'where default_role_catalog_version_id = @version_id::uuid',
          parameters: <String, Object?>{'version_id': versionId},
        );
        if (rows.isEmpty) return 0;
        final raw = rows.single['cnt'];
        if (raw is int) return raw;
        if (raw is num) return raw.toInt();
        if (raw is String) return int.tryParse(raw) ?? 0;
        return 0;
      },
      reason: reason,
    );
  }

  /// Returns the three blast-radius counts for [versionId] in a single
  /// round-trip: operators pinned to the version + locations under
  /// those operators + users under those operators. Surfaced by the
  /// B2.3 `GET /v1/admin/auth/role-catalogs/blast-radius` endpoint.
  ///
  /// The query uses a single CTE so the three counts share the same
  /// snapshot of `operators` — a concurrent operator-flip cannot leak
  /// into a partial result. `runAsSystem` (admin-pool BYPASSRLS) is
  /// required because the join walks every operator's locations / users
  /// across the entire deployment.
  ///
  /// User count caveat (honest disclosure): the `public.users` table
  /// has no soft-delete / is-active column at the present schema
  /// (`202604250005_advisor_cloud_foundation.sql` only defines
  /// `user_id, operator_id, email, role, created_at, updated_at`), so
  /// the count is total users-on-file for the pinned operators. If
  /// future schema work adds `deleted_at` / `is_active`, update this
  /// method to filter accordingly.
  ///
  /// Returns zero counts (versionId echoed verbatim) when no operators
  /// are pinned — the common case at PR-merge time. The proxy layer is
  /// responsible for verifying the version exists (via [getVersion])
  /// before calling this method; otherwise an unknown version_id would
  /// silently return zero counts.
  Future<DefaultRoleCatalogBlastRadiusCounts> getBlastRadiusCounts({
    required String versionId,
    String reason = 'admin.default_role_catalog.blast_radius_counts',
  }) {
    return _tenantWrapper
        .runAsSystem<DefaultRoleCatalogBlastRadiusCounts>(
      (exec) async {
        // Single CTE: identify the pinned operator set once, then
        // count operators + locations + users that resolve through it.
        // `coalesce(count, 0)` defends against the no-operators path
        // returning a NULL aggregate (LEFT JOIN on empty CTE → 0).
        final rows = await exec.query(
          'with pinned_operators as ('
          '  select operator_id from public.operators '
          '  where default_role_catalog_version_id = @version_id::uuid'
          ') '
          'select '
          '  (select count(*) from pinned_operators) as operator_count, '
          '  (select count(*) from public.locations l '
          '     where l.operator_id in (select operator_id from pinned_operators)'
          '  ) as location_count, '
          '  (select count(*) from public.users u '
          '     where u.operator_id in (select operator_id from pinned_operators)'
          '  ) as user_count',
          parameters: <String, Object?>{'version_id': versionId},
        );
        if (rows.isEmpty) {
          return DefaultRoleCatalogBlastRadiusCounts(
            versionId: versionId,
            operatorCount: 0,
            locationCount: 0,
            userCount: 0,
          );
        }
        final row = rows.single;
        return DefaultRoleCatalogBlastRadiusCounts(
          versionId: versionId,
          operatorCount: _coerceCount(row['operator_count']),
          locationCount: _coerceCount(row['location_count']),
          userCount: _coerceCount(row['user_count']),
        );
      },
      reason: reason,
    );
  }

  static int _coerceCount(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  // ─── helpers ────────────────────────────────────────────────────

  static DefaultRoleCatalogVersionRow _rowFromMap(Map<String, Object?> row) {
    final versionId = row['version_id'];
    final versionNumber = row['version_number'];
    final publishedAt = row['published_at'];
    final publishedByUserId = row['published_by_user_id'];
    final payloadRaw = row['payload'];
    final payloadSha256 = row['payload_sha256'];
    final isCurrent = row['is_current'];
    final supersededAt = row['superseded_at'];
    final notes = row['notes'];

    if (versionId is! String || versionId.isEmpty) {
      throw StateError(
        'default_role_catalog_versions row returned a malformed version_id',
      );
    }
    if (publishedByUserId is! String || publishedByUserId.isEmpty) {
      throw StateError(
        'default_role_catalog_versions row returned a malformed published_by_user_id',
      );
    }
    if (publishedAt is! DateTime) {
      throw StateError(
        'default_role_catalog_versions row returned a non-DateTime published_at',
      );
    }
    if (payloadSha256 is! String || payloadSha256.isEmpty) {
      throw StateError(
        'default_role_catalog_versions row returned a malformed payload_sha256',
      );
    }
    if (isCurrent is! bool) {
      throw StateError(
        'default_role_catalog_versions row returned a non-bool is_current',
      );
    }
    final int versionNum;
    if (versionNumber is int) {
      versionNum = versionNumber;
    } else if (versionNumber is num) {
      versionNum = versionNumber.toInt();
    } else if (versionNumber is String) {
      versionNum = int.parse(versionNumber);
    } else {
      throw StateError(
        'default_role_catalog_versions row returned a non-int version_number',
      );
    }
    final payloadList = _decodePayload(payloadRaw);
    return DefaultRoleCatalogVersionRow(
      versionId: versionId,
      versionNumber: versionNum,
      publishedAt: publishedAt,
      publishedByUserId: publishedByUserId,
      payload: payloadList,
      payloadSha256: payloadSha256,
      isCurrent: isCurrent,
      supersededAt: supersededAt is DateTime ? supersededAt : null,
      notes: notes is String ? notes : null,
    );
  }

  /// `payload` arrives from the driver as either a Dart `List` (jsonb
  /// decoded by the underlying adapter) or a `String` (raw JSON text).
  /// Normalize both into `List<Object?>`. A non-array body would have
  /// failed the migration's `jsonb_typeof = 'array'` CHECK; the runtime
  /// guard here surfaces a clear error if the CHECK is ever dropped.
  static List<Object?> _decodePayload(Object? raw) {
    if (raw == null) {
      throw StateError(
        'default_role_catalog_versions.payload returned null',
      );
    }
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is List) return List<Object?>.from(decoded);
    throw StateError(
      'default_role_catalog_versions.payload returned a non-array shape '
      '(${raw.runtimeType}) — migration CHECK has been dropped',
    );
  }

  static void _validatePayload(List<Object?> payload) {
    if (payload.isEmpty) {
      throw const DefaultRoleCatalogPublishValidationError(
        code: 'empty_payload',
        message:
            'default role catalog payload must be a non-empty array of '
            'role definitions',
      );
    }
  }

  static void _validatePayloadSha256(String sha256) {
    final ok = sha256.length == _kPayloadSha256HexLength &&
        RegExp(r'^[0-9a-f]+$').hasMatch(sha256);
    if (!ok) {
      throw const DefaultRoleCatalogPublishValidationError(
        code: 'invalid_payload_sha256',
        message:
            'payload_sha256 must be 64-char lowercase hex (raw SHA-256 '
            'over the canonical payload bytes)',
      );
    }
  }

  static void _validateNotes(String? notes) {
    if (notes == null) return;
    if (notes.length > 2000) {
      throw const DefaultRoleCatalogPublishValidationError(
        code: 'notes_too_long',
        message:
            'notes must be 2000 characters or fewer (the migration CHECK '
            'enforces the ceiling)',
      );
    }
  }
}
