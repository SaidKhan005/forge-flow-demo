// Forge & Flow — PostgresCorpusRetrievalRepository.
//
// Advisor Knowledge Activation — Slice A1.
//
// Concrete implementation of [CorpusRetrievalRepository] that calls
// `public.advisor_search_chunks(...)` defined in
// `db/migrations/202604250003_advisor_vector_search.sql`.
//
// The corpus tables are shared methodology (not operator-scoped fact
// tables), so every call uses [withSystem] with a non-blank [adminReason]
// for audit attribution — the same pattern used by [CorpusRepository].
//
// CI rule: `package:postgres` imports are only allowed under
// `lib/infrastructure/persistence/postgres/`. This file is in that
// subtree; no other file in this slice imports `package:postgres`.
//
// Signature of the called SQL function (verbatim from migration):
//
//   public.advisor_search_chunks(
//     query_embedding   vector(1024),
//     scope_filter      text,
//     restaurant_id_filter uuid,           -- NULL = global shared corpus
//     provider_id_filter  text,
//     model_id_filter     text,
//     dimension_filter    integer,
//     max_results         integer
//   )
//   returns table (
//     chunk_id text, doc_id text, source_path text,
//     heading_path text[], scope text, restaurant_id uuid,
//     chunk_kind text, chunk_profile text, risk_level text,
//     content_sha256 text, embedding_provider_id text,
//     embedding_model_id text, embedding_dimension integer,
//     text text, provenance jsonb,
//     similarity double precision, distance double precision
//   )
//
// This repository projects only the fields needed by [RetrievedChunk];
// unused return columns are intentionally not mapped.

import '../../../../domain/models/retrieved_chunk.dart';
import '../../../../domain/repositories/corpus_retrieval_repository.dart';
import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';

/// Postgres implementation of [CorpusRetrievalRepository].
///
/// Extends [OperatorScopedRepository] for the [withSystem] execution
/// path, matching the pattern established by [CorpusRepository].
class PostgresCorpusRetrievalRepository extends OperatorScopedRepository
    implements CorpusRetrievalRepository {
  PostgresCorpusRetrievalRepository(super.tenantWrapper);

  /// Admin reason string carried in the SET LOCAL audit marker. Callers
  /// that need a more specific label can extend or replace this.
  static const String _adminReason = 'corpus_retrieval.vector_search';

  @override
  Future<List<RetrievedChunk>> searchChunks({
    required List<double> queryEmbedding,
    required String graphScope,
    String? restaurantId,
    required String providerId,
    required String modelId,
    required int dimension,
    required int maxResults,
  }) {
    return withSystem<List<RetrievedChunk>>((exec) async {
      // Build the pgvector literal from the embedding list.
      // Format: '[0.1,0.2,...,0.9]' — the package:postgres driver
      // accepts this as the `vector(1024)` argument when the parameter
      // is bound as a plain string with an explicit cast in the SQL.
      final embeddingLiteral = '[${queryEmbedding.join(',')}]';

      final rows = await exec.query(
        'select '
        '  chunk_id, '
        '  doc_id, '
        '  source_path, '
        '  heading_path, '
        '  text, '
        '  scope, '
        '  similarity '
        'from public.advisor_search_chunks('
        '  @query_embedding::vector, '
        '  @scope_filter, '
        '  @restaurant_id_filter::uuid, '
        '  @provider_id_filter, '
        '  @model_id_filter, '
        '  @dimension_filter, '
        '  @max_results'
        ')',
        parameters: <String, Object?>{
          'query_embedding': embeddingLiteral,
          'scope_filter': graphScope,
          'restaurant_id_filter': restaurantId,
          'provider_id_filter': providerId,
          'model_id_filter': modelId,
          'dimension_filter': dimension,
          'max_results': maxResults,
        },
      );

      return <RetrievedChunk>[
        for (final row in rows) _chunkFromRow(row),
      ];
    }, reason: _adminReason);
  }

  RetrievedChunk _chunkFromRow(PostgresRow row) {
    final rawHeading = row['heading_path'];
    final headingPath = <String>[
      if (rawHeading is List) ...rawHeading.whereType<String>(),
    ];
    final Object? rawSimilarity = row['similarity'];
    final similarity = switch (rawSimilarity) {
      final double d => d,
      final num n => n.toDouble(),
      _ => 0.0,
    };
    return RetrievedChunk(
      chunkId: row['chunk_id']! as String,
      docId: row['doc_id']! as String,
      headingPath: headingPath,
      text: (row['text'] as String?) ?? '',
      similarity: similarity,
      sourcePath: row['source_path'] as String?,
      scope: row['scope'] as String?,
    );
  }
}
