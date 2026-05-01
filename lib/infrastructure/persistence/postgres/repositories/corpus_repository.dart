// Phase 11A.3a — CorpusRepository.
//
// Persistence layer for the `corpus_versions` ledger plus the
// per-chunk `version_id` / `superseded_at` pointers added by
// `db/migrations/202605010000_phase_11A_3a_corpus_versions_ledger.sql`.
//
// The F&F admin walks the corpus across operators (the corpus is the
// shared methodology, not an operator-scoped fact table), so every
// statement here runs through `withSystem` — the `forge_admin`
// Postgres role's `BYPASSRLS` privilege is the only path that can
// scan / write across the corpus tables. Each call passes a non-blank
// [adminReason] string the audit marker carries via
// `app.bypass_rls_audit = 'system:<reason>'` so the bypass is
// attributable.
//
// `commitVersion` does the version write transactionally inside one
// `withSystem` block: it stamps the prior current version
// `superseded_at`, inserts a new `corpus_versions` row, marks the
// previously-active chunks `superseded_at = now()`, and inserts the
// new chunk set under the new `version_id`. A rollback writes a new
// version whose `rollback_of` points at the target and re-points the
// active chunks to the rolled-back chunk set.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';

class CorpusRepository extends OperatorScopedRepository {
  CorpusRepository(super.tenantWrapper);

  static const String _versionColumns =
      'version_id::text as version_id, '
      'created_by::text as created_by, '
      'created_at, '
      'summary, '
      'rollback_of::text as rollback_of, '
      'superseded_at';

  /// Column projection with table alias prefix. The chunks table is
  /// joined against `corpus_version_chunks` for membership queries,
  /// so `*` would collide on `version_id`; this helper lets the SELECT
  /// stay explicit.
  static String _chunkColumnsAliased(String alias) =>
      'a.chunk_id, '
              'a.doc_id, '
              'a.source_path, '
              'a.heading_path, '
              'a.text, '
              'a.estimated_tokens, '
              'a.risk_level, '
              'a.content_sha256, '
              'a.version_id::text as version_id, '
              'a.superseded_at, '
              'a.active, '
              'a.created_at, a.updated_at'
          .replaceAll('a.', '$alias.');

  /// SELECT every corpus version row, current-first. The current
  /// version is the unique row with `superseded_at IS NULL`. Prior
  /// versions follow ordered by `superseded_at DESC` so the admin
  /// list reads chronologically newest-to-oldest.
  ///
  /// `chunk_count` is computed on the same statement via a join over
  /// the `corpus_version_chunks` membership table so the admin's
  /// list view can render row sizes without an N+1 round-trip per
  /// version. Using membership (not `advisor_source_chunks.version_id`)
  /// matters: chunks shared across versions are counted once per
  /// version they belong to, which is what the admin expects.
  Future<List<CorpusVersionRow>> listVersions({
    required String adminReason,
  }) {
    return withSystem<List<CorpusVersionRow>>((exec) async {
      final rows = await exec.query(
        'select v.version_id::text as version_id, '
        'v.created_by::text as created_by, '
        'v.created_at, v.summary, '
        'v.rollback_of::text as rollback_of, '
        'v.superseded_at, '
        'coalesce(c.cnt, 0) as chunk_count '
        'from corpus_versions v '
        'left join ('
        'select version_id, count(*) as cnt '
        'from corpus_version_chunks '
        'group by version_id'
        ') c on c.version_id = v.version_id '
        "order by v.superseded_at is null desc, "
        'coalesce(v.superseded_at, v.created_at) desc, '
        'v.created_at desc',
      );
      return <CorpusVersionRow>[
        for (final row in rows) _versionFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// Fetch the chunks that belong to one corpus version. Used by the
  /// admin detail pane to render the per-chunk preview. Resolves
  /// membership through `corpus_version_chunks`; the chunk's own
  /// `version_id` column is informational only after 11A.3a.
  Future<List<CorpusChunkRow>> chunksForVersion({
    required String versionId,
    required String adminReason,
  }) {
    return withSystem<List<CorpusChunkRow>>((exec) async {
      final rows = await exec.query(
        'select ${_chunkColumnsAliased('c')} from advisor_source_chunks c '
        'inner join corpus_version_chunks m on m.chunk_id = c.chunk_id '
        'where m.version_id = @version_id::uuid '
        'order by c.source_path asc, c.start_line asc',
        parameters: <String, Object?>{'version_id': versionId},
      );
      return <CorpusChunkRow>[
        for (final row in rows) _chunkFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// Fetch the active chunks (currently-serving corpus). Resolves
  /// membership through the join table against the unique
  /// `corpus_versions` row whose `superseded_at IS NULL`.
  Future<List<CorpusChunkRow>> activeChunks({required String adminReason}) {
    return withSystem<List<CorpusChunkRow>>((exec) async {
      final rows = await exec.query(
        'select ${_chunkColumnsAliased('c')} from advisor_source_chunks c '
        'inner join corpus_version_chunks m on m.chunk_id = c.chunk_id '
        'inner join corpus_versions v on v.version_id = m.version_id '
        'where v.superseded_at is null '
        'order by c.source_path asc, c.start_line asc',
      );
      return <CorpusChunkRow>[
        for (final row in rows) _chunkFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// Commit a fresh corpus version. Inside one `withSystem`
  /// transaction this:
  ///
  ///   1. stamps the prior current version with `superseded_at = now()`,
  ///   2. inserts a new `corpus_versions` row,
  ///   3. flips the previously-active chunks
  ///      (`superseded_at IS NULL`) to `superseded_at = now()`,
  ///   4. upserts each chunk row content-addressed (does NOT rewrite
  ///      `version_id` on conflict — the column is the
  ///      first-introduced pointer),
  ///   5. inserts membership rows in `corpus_version_chunks` linking
  ///      the new version to its full chunk set.
  ///
  /// Returns the newly-inserted version row.
  Future<CorpusVersionRow> commitVersion({
    required String summary,
    required String actorUserId,
    required List<NewCorpusChunk> chunks,
    String? rollbackOf,
    required String adminReason,
  }) {
    return withSystem<CorpusVersionRow>((exec) async {
      // 1. Supersede the prior current version (if any). We do not
      //    rely on a UNIQUE constraint here because the rollback path
      //    already guarantees at most one row has superseded_at IS
      //    NULL by virtue of always running this same UPDATE first.
      await exec.execute(
        'update corpus_versions set superseded_at = now() '
        'where superseded_at is null',
      );

      // 2. Insert the new version row.
      final inserted = await exec.query(
        'insert into corpus_versions ('
        'created_by, summary, rollback_of'
        ') values ('
        '@actor::uuid, @summary, @rollback_of::uuid'
        ') '
        'returning $_versionColumns',
        parameters: <String, Object?>{
          'actor': actorUserId,
          'summary': summary,
          'rollback_of': rollbackOf,
        },
      );
      if (inserted.isEmpty) {
        throw StateError('corpus_versions insert returned no rows');
      }
      final newVersion = _versionFromMap(inserted.single);

      // 3. Stamp the previously-active chunks superseded. This is a
      //    soft "no longer in the active snapshot" marker; chunks that
      //    are still members of this new version get cleared in step 4.
      await exec.execute(
        'update advisor_source_chunks '
        'set superseded_at = now(), active = false '
        'where superseded_at is null',
      );

      // 4. Upsert each chunk row. Content is overwritten on conflict
      //    (a chunk with the same chunk_id but updated text reflects
      //    the new snapshot's content), but `version_id` is preserved
      //    as the first-introduced pointer — overwriting it would
      //    destroy historical-snapshot reads. Membership in this new
      //    version is recorded in step 5 instead.
      for (final chunk in chunks) {
        await exec.execute(
          'insert into advisor_source_chunks ('
          'chunk_id, doc_id, source_path, scope, '
          'chunk_kind, chunk_profile, heading_path, '
          'start_line, end_line, estimated_tokens, '
          'risk_level, content_sha256, '
          'text, provenance, '
          'version_id, active'
          ') values ('
          '@chunk_id, @doc_id, @source_path, @scope, '
          '@chunk_kind, @chunk_profile, @heading_path, '
          '@start_line, @end_line, @estimated_tokens, '
          '@risk_level, @content_sha256, '
          '@text, @provenance::jsonb, '
          '@version_id::uuid, true'
          ') '
          'on conflict (chunk_id) do update set '
          'text = excluded.text, '
          'heading_path = excluded.heading_path, '
          'start_line = excluded.start_line, '
          'end_line = excluded.end_line, '
          'estimated_tokens = excluded.estimated_tokens, '
          'risk_level = excluded.risk_level, '
          'content_sha256 = excluded.content_sha256, '
          'provenance = excluded.provenance, '
          'superseded_at = null, '
          'active = true',
          parameters: <String, Object?>{
            'chunk_id': chunk.chunkId,
            'doc_id': chunk.docId,
            'source_path': chunk.sourcePath,
            'scope': chunk.scope,
            'chunk_kind': chunk.chunkKind,
            'chunk_profile': chunk.chunkProfile,
            'heading_path': chunk.headingPath,
            'start_line': chunk.startLine,
            'end_line': chunk.endLine,
            'estimated_tokens': chunk.estimatedTokens,
            'risk_level': chunk.riskLevel,
            'content_sha256': chunk.contentSha256,
            'text': chunk.text,
            'provenance': chunk.provenanceJson,
            'version_id': newVersion.versionId,
          },
        );

        // 5. Record membership of this chunk in the new version.
        //    `on conflict do nothing` keeps the upsert idempotent
        //    when the same chunk appears twice in `chunks`.
        await exec.execute(
          'insert into corpus_version_chunks (version_id, chunk_id) '
          'values (@version_id::uuid, @chunk_id) '
          'on conflict do nothing',
          parameters: <String, Object?>{
            'version_id': newVersion.versionId,
            'chunk_id': chunk.chunkId,
          },
        );
      }
      return newVersion;
    }, reason: adminReason);
  }

  /// Rolls back to a prior version. Writes a new `corpus_versions`
  /// row whose `rollback_of` carries the target version id and
  /// duplicates the target's membership rows under the new version
  /// so the active snapshot becomes the rolled-back chunk set
  /// without rewriting any existing chunk row's `version_id` (which
  /// would destroy the historical snapshot).
  ///
  /// `idempotencyKey`, when supplied, makes the rollback safe to
  /// retry on a flaky network. Concurrent retries with the same
  /// `(route, key)` pair are serialized through a per-key
  /// `pg_advisory_xact_lock` taken at the very start of the
  /// transaction. The cache lookup happens AFTER the lock is held,
  /// so two simultaneous retries cannot both miss-and-mutate; the
  /// second one waits for the first to commit and then reads the
  /// cached payload back out. The cache lives in
  /// `admin_idempotency_cache` (cross-tenant) — `public.proxy_requests`
  /// is keyed on `(operator_id, location_id, idempotency_key)` with
  /// NOT NULL FK columns and is not a fit for cross-tenant F&F
  /// admin paths.
  ///
  /// The returned [RollbackResult.replayed] flag tells the caller
  /// whether the response is a fresh write or a cache hit, so audit
  /// emitters (auth_events_audit) can skip a duplicate row on retry.
  Future<RollbackResult> rollbackToVersion({
    required String targetVersionId,
    required String actorUserId,
    required String summary,
    required String adminReason,
    String? idempotencyKey,
  }) {
    return withSystem<RollbackResult>((exec) async {
      final hasKey = idempotencyKey != null && idempotencyKey.isNotEmpty;

      // 0. Acquire a per-(route, key) advisory lock BEFORE the cache
      //    read so concurrent retries serialize. Two transactions
      //    that arrive within the same Idempotency-Key window cannot
      //    both miss the cache and race to write a second
      //    corpus_versions row: the second transaction blocks here
      //    until the first commits, then sees the cached payload on
      //    the next read. The lock auto-releases on commit/rollback
      //    (xact-scoped variant).
      //
      //    Lock collisions across unrelated (route, key) pairs are
      //    harmless; they only cause a brief wait, not a correctness
      //    issue. Hash collisions are a non-issue because the cache
      //    table itself enforces uniqueness on the exact text key.
      if (hasKey) {
        // `hashtext(text)` returns `integer` (4-byte). Postgres
        // exposes the two-argument advisory-lock overload as
        // `pg_advisory_xact_lock(integer, integer)`; passing the
        // hashes through `::bigint` would resolve against the
        // single-argument overload only and the two-arg form would
        // fail with `function pg_advisory_xact_lock(bigint, bigint)
        // does not exist`. Keep the args as plain ints.
        await exec.query(
          'select pg_advisory_xact_lock('
          'hashtext(@route), hashtext(@key)'
          ')',
          parameters: <String, Object?>{
            'route': _rollbackRoute,
            'key': idempotencyKey,
          },
        );

        // 0a. Cache read under the lock. By this point any prior
        //     transaction that owned the same key has either
        //     committed (we'll read its payload) or rolled back (the
        //     row will be absent and we'll proceed with the
        //     mutation).
        final cached = await exec.query(
          'select response_payload::text as response_payload '
          'from admin_idempotency_cache '
          'where route = @route and idempotency_key = @key '
          'limit 1',
          parameters: <String, Object?>{
            'route': _rollbackRoute,
            'key': idempotencyKey,
          },
        );
        if (cached.isNotEmpty) {
          final raw = cached.single['response_payload'];
          if (raw is String && raw.isNotEmpty) {
            final decoded = _decodeJson(raw);
            if (decoded != null) {
              return RollbackResult(
                version: _versionFromMap(decoded),
                replayed: true,
              );
            }
          }
        }
      }
      // Resolve the target version's chunk membership.
      final targetMembers = await exec.query(
        'select chunk_id from corpus_version_chunks '
        'where version_id = @version_id::uuid',
        parameters: <String, Object?>{'version_id': targetVersionId},
      );
      // Supersede the prior current version + flag superseded chunks.
      // Chunks that are still members of the rolled-back snapshot get
      // un-superseded in step 4.
      await exec.execute(
        'update corpus_versions set superseded_at = now() '
        'where superseded_at is null',
      );
      await exec.execute(
        'update advisor_source_chunks '
        'set superseded_at = now(), active = false '
        'where superseded_at is null',
      );
      // Insert the new version row pointing at the rolled-back source.
      final inserted = await exec.query(
        'insert into corpus_versions ('
        'created_by, summary, rollback_of'
        ') values ('
        '@actor::uuid, @summary, @rollback_of::uuid'
        ') '
        'returning $_versionColumns',
        parameters: <String, Object?>{
          'actor': actorUserId,
          'summary': summary,
          'rollback_of': targetVersionId,
        },
      );
      if (inserted.isEmpty) {
        throw StateError(
          'corpus_versions rollback insert returned no rows',
        );
      }
      final newVersion = _versionFromMap(inserted.single);

      // Duplicate membership rows under the new version_id and clear
      // each chunk's superseded_at so the active-snapshot read
      // (`superseded_at IS NULL` joined to the current version) lights
      // them up.
      for (final row in targetMembers) {
        final chunkId = row['chunk_id']! as String;
        await exec.execute(
          'insert into corpus_version_chunks (version_id, chunk_id) '
          'values (@version_id::uuid, @chunk_id) '
          'on conflict do nothing',
          parameters: <String, Object?>{
            'version_id': newVersion.versionId,
            'chunk_id': chunkId,
          },
        );
        await exec.execute(
          'update advisor_source_chunks '
          'set superseded_at = null, active = true '
          'where chunk_id = @chunk_id',
          parameters: <String, Object?>{'chunk_id': chunkId},
        );
      }
      // Idempotency cache write: persist the response so a retry
      // returns the same version row. The advisory lock guarantees
      // this is the only transaction holding `(route, key)`, so a
      // straight INSERT (no ON CONFLICT) is safe — but we keep the
      // ON CONFLICT clause so a leftover row from a half-committed
      // run doesn't crash the transaction.
      if (hasKey) {
        await exec.execute(
          'insert into admin_idempotency_cache ('
          'route, idempotency_key, response_payload'
          ') values (@route, @key, @body::jsonb) '
          'on conflict (route, idempotency_key) do update set '
          'response_payload = excluded.response_payload',
          parameters: <String, Object?>{
            'route': _rollbackRoute,
            'key': idempotencyKey,
            'body': _encodeJson(newVersion.toJson()),
          },
        );
      }
      return RollbackResult(version: newVersion, replayed: false);
    }, reason: adminReason);
  }

  /// `admin_idempotency_cache.route` value for the rollback path.
  /// Keeping the literal in one place makes a future move to a
  /// constant catalog (or a renamed cache table) trivial.
  static const String _rollbackRoute = 'admin.corpus.rollback';
}

/// Outcome of a [CorpusRepository.rollbackToVersion] call. Carries
/// the resulting [version] plus a [replayed] flag the caller uses to
/// decide whether to emit a duplicate audit row on retry.
class RollbackResult {
  const RollbackResult({required this.version, required this.replayed});

  final CorpusVersionRow version;

  /// True when this response was served from the idempotency cache
  /// (a prior request with the same `(route, idempotency_key)` pair
  /// already wrote the ledger row + audit event). Callers that emit
  /// audit-trail rows should skip the emission on replay so a
  /// retried POST never produces a second audit entry.
  final bool replayed;
}

String _encodeJson(Map<String, Object?> map) => jsonEncode(map);

Map<String, Object?>? _decodeJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return decoded.cast<String, Object?>();
  } catch (_) {
    return null;
  }
  return null;
}

/// One `corpus_versions` row.
class CorpusVersionRow {
  const CorpusVersionRow({
    required this.versionId,
    required this.createdBy,
    required this.createdAt,
    required this.summary,
    required this.rollbackOf,
    required this.supersededAt,
    this.chunkCount = 0,
  });

  final String versionId;
  final String? createdBy;
  final DateTime createdAt;
  final String summary;
  final String? rollbackOf;
  final DateTime? supersededAt;
  final int chunkCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'version_id': versionId,
    'created_by': createdBy,
    'created_at': createdAt.toUtc().toIso8601String(),
    'summary': summary,
    'rollback_of': rollbackOf,
    'superseded_at': supersededAt?.toUtc().toIso8601String(),
    'is_current': supersededAt == null,
    'chunk_count': chunkCount,
  };
}

/// One projected chunk row used by the admin preview pane.
class CorpusChunkRow {
  const CorpusChunkRow({
    required this.chunkId,
    required this.docId,
    required this.sourcePath,
    required this.headingPath,
    required this.text,
    required this.estimatedTokens,
    required this.riskLevel,
    required this.contentSha256,
    required this.versionId,
    required this.supersededAt,
    required this.active,
    required this.createdAt,
    required this.updatedAt,
  });

  final String chunkId;
  final String docId;
  final String sourcePath;
  final List<String> headingPath;
  final String text;
  final int estimatedTokens;
  final String riskLevel;
  final String contentSha256;
  final String? versionId;
  final DateTime? supersededAt;
  final bool active;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// JSON projection used by admin proxy responses. Deliberately
  /// omits `text` — the proxy must never return the full chunk body
  /// over the wire (the model contract is "snippets + metadata
  /// only"). Callers that need the snippet should compute it from
  /// [text] before calling [toJson].
  Map<String, Object?> toJson() => <String, Object?>{
    'chunk_id': chunkId,
    'doc_id': docId,
    'source_path': sourcePath,
    'heading_path': headingPath,
    'estimated_tokens': estimatedTokens,
    'risk_level': riskLevel,
    'content_sha256': contentSha256,
    'version_id': versionId,
    'superseded_at': supersededAt?.toUtc().toIso8601String(),
    'active': active,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

/// Insert payload for a fresh chunk row when the admin commits a new
/// corpus version. Mirrors the `advisor_source_chunks` columns the
/// repository writes to; provenance is passed as a JSON string so the
/// repository can use a `::jsonb` cast without depending on the
/// driver's native JSON binding.
class NewCorpusChunk {
  const NewCorpusChunk({
    required this.chunkId,
    required this.docId,
    required this.sourcePath,
    required this.scope,
    required this.chunkKind,
    required this.chunkProfile,
    required this.headingPath,
    required this.startLine,
    required this.endLine,
    required this.estimatedTokens,
    required this.riskLevel,
    required this.contentSha256,
    required this.text,
    required this.provenanceJson,
  });

  final String chunkId;
  final String docId;
  final String sourcePath;
  final String scope;
  final String chunkKind;
  final String chunkProfile;
  final List<String> headingPath;
  final int startLine;
  final int endLine;
  final int estimatedTokens;
  final String riskLevel;
  final String contentSha256;
  final String text;
  final String provenanceJson;
}

CorpusVersionRow _versionFromMap(PostgresRow row) {
  return CorpusVersionRow(
    versionId: row['version_id']! as String,
    createdBy: row['created_by'] as String?,
    createdAt: _toDateTime(row['created_at'])!,
    summary: (row['summary'] as String?) ?? '',
    rollbackOf: row['rollback_of'] as String?,
    supersededAt: _toDateTime(row['superseded_at']),
    chunkCount: (row['chunk_count'] as num?)?.toInt() ?? 0,
  );
}

CorpusChunkRow _chunkFromMap(PostgresRow row) {
  final rawHeading = row['heading_path'];
  final heading = <String>[
    if (rawHeading is List) ...rawHeading.whereType<String>(),
  ];
  return CorpusChunkRow(
    chunkId: row['chunk_id']! as String,
    docId: row['doc_id']! as String,
    sourcePath: row['source_path']! as String,
    headingPath: heading,
    text: row['text']! as String,
    estimatedTokens: (row['estimated_tokens'] as num?)?.toInt() ?? 0,
    riskLevel: row['risk_level']! as String,
    contentSha256: row['content_sha256']! as String,
    versionId: row['version_id'] as String?,
    supersededAt: _toDateTime(row['superseded_at']),
    active: (row['active'] as bool?) ?? true,
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    return value.isEmpty ? null : DateTime.parse(value).toUtc();
  }
  return null;
}
