# Phase 11a.11e Staging Live Load Result

Date: 2026-04-26
Status: ACCEPTED

## Summary

The staging corpus/live-retrieval path is loaded and verified on Azure
Postgres. After Anthropic credits were added, the Claude gate passed:
Anthropic Contextual Retrieval contexts were generated for every active chunk,
Voyage embeddings were refreshed from the context-enriched inputs, vector
search and Voyage rerank returned expected candidates, and Claude answer smoke
completed with `end_turn`.

No secret values are recorded here.

## Applied To Staging

- `db/migrations/202604250006_advisor_contextual_retrieval_telemetry.sql`
- `db/migrations/202604250007_advisor_rls_index_hardening.sql`
- `build/advisor_corpus/load/001_ingestion_run.sql`
- `build/advisor_corpus/load/002_source_documents.sql`
- `build/advisor_corpus/load/003_source_chunks.sql`
- `build/advisor_corpus/load/004_graph_node_seeds.sql`
- `build/advisor_corpus/load/005_graph_edge_hints.sql`
- `build/advisor_corpus/embeddings/embedding_updates.sql`
- `build/advisor_corpus/age/006_age_projection.sql`
- `build/advisor_corpus/age/008_age_index_strategy.sql`

## Staging Counts

- Source documents: 8
- Source chunks: 233
- Ready Voyage embeddings: 233
- BM25 vectors populated: 233
- AGE Document -> Chunk pairs: 233

Initial Voyage embedding execution:

- Provider/model: `voyage / voyage-4-large`
- Dimensions: 1024
- Chunks: 233
- Batches: 49
- Provider-reported tokens: 103642
- Execution id: `40e22c55-98e6-5ca5-ac6d-0de90e5dedc7`

Contextual Retrieval execution:

- Provider/model: `anthropic / claude-haiku-4-5`
- Chunks: 233
- Context execution id: `5b411ca8-e883-5e90-a2c3-44dc1c9bb8b2`
- Output: `build/advisor_corpus/context/chunk_contexts.jsonl`
- SQL applied: `build/advisor_corpus/context/chunk_context_updates.sql`

Context-enriched Voyage embedding refresh:

- Provider/model: `voyage / voyage-4-large`
- Dimensions: 1024
- Chunks: 233
- Batches: 53
- Provider-reported tokens: 116285
- Execution id: `7deb1778-262c-5790-a8b4-20bfd0c9a671`
- SQL applied: `build/advisor_corpus/context/embedding_updates.sql`

## Retrieval Smokes

- pgvector live candidate smoke returned 5 candidates over 233 ready chunks.
- Voyage rerank live smoke returned 5 scored results using `rerank-2.5`;
  top index was 0 with relevance score 0.9140625.
- Claude answer smoke used the top reranked candidate and returned
  `stop_reason=end_turn` on `claude-haiku-4-5-20251001`.
- AGE smoke traversal returned `document_chunk_pairs=233` and
  `cplh_bearing_chunks=17`.
- BM25 `bm25_tsv` is populated for all active staging chunks.
- `chunk_context` is populated for all 233 active staging chunks.

## AGE Benchmark

Harness: `build/advisor_corpus/age/009_age_benchmark_harness.sql`

- 1 client, 60 seconds: 512 transactions, 0 failures, average latency
  116.105 ms, corrected p95 127.187 ms.
- 10 clients, 60 seconds: 5145 transactions, 0 failures, average latency
  111.854 ms, corrected p95 133.046 ms.

Both pass the gate: isolated p95 <= 500 ms and 10x concurrent p95 <= 1000 ms.

## DiskANN / HNSW Decision

Staging verified that `pg_diskann` is installed and that a DiskANN candidate
index can be created. The corpus is currently tiny (233 chunks), so the
planner used sequential scan/top-N sort for direct vector explain; that is
expected and not a production-scale benchmark.

Decision for launch: keep HNSW as the authoritative live index. DiskANN stays
validated as available, but should be re-benchmarked when the corpus reaches
meaningful production scale.

## RLS / Partition Maintenance

- RLS-leading-column index audit: 0 violations on staging after
  `202604250007_advisor_rls_index_hardening.sql`.
- `pg_partman` registered `public.usage_logs`: 1 config row.
- `pg_cron` hourly maintenance job exists and targets `forgeflow`: 1 active job.
- Azure installed pg_partman functions into `public`, so the live calls are
  `public.create_parent` and `public.run_maintenance`.

## Not Done / Scope Boundary

- No production corpus data load.
- No production embedding execution.
- No production AGE projection data.
- No Cloud Run proxy production traffic.
