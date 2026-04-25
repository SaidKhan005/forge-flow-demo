# Phase 11a.4 - DB Loader Dry Run

Updated: 2026-04-25
Owner: Codex planning / advisor infrastructure lane
Status: Complete - deterministic build-only SQL load prep landed; no live database apply

## Plain English

The corpus can now be converted into the exact SQL files that would load it
into the staged Supabase tables, but this run only writes those files locally.
Example: the 233 planned source chunks become ordered `insert ... on conflict`
statements for `advisor_source_chunks`, with embeddings still marked pending.

## Landed

- `prepare-load` command on `tool/advisor_corpus/main.dart`
- `CorpusDbLoadPreparer` in `tool/advisor_corpus/advisor_corpus.dart`
- Deterministic run id derived from the materialized summary
- Ordered SQL load files under `build/advisor_corpus/load/`
- `load_manifest.json` describing load order, target tables, counts, and
  build-only apply mode
- Tests proving deterministic output and table mapping

## Generated Output Contract

`dart run tool/advisor_corpus/main.dart prepare-load` regenerates the
materialized JSONL records, then writes:

- `001_ingestion_run.sql`
- `002_source_documents.sql`
- `003_source_chunks.sql`
- `004_graph_node_seeds.sql`
- `005_graph_edge_hints.sql`
- `load_manifest.json`

The generated manifest records:

- `run_id`
- target schema migration
- load order
- record counts
- `embedding_status: pending`
- `apply_mode: not_applied_build_artifacts_only`

These files are generated build artifacts and are not checked in. They are the
dry-run handoff for a later live/local Supabase loader slice.

## Accepted Evidence

- `dart analyze` - clean
- `flutter test test/advisor_corpus_manifest_test.dart` - 12 tests passing
- `dart run tool/advisor_corpus/main.dart validate` - 8 documents, 8 active
  Markdown files
- `dart run tool/advisor_corpus/main.dart plan-chunks` - 8 documents, 233
  planned chunks
- `dart run tool/advisor_corpus/main.dart materialize` - 8 source documents,
  233 chunks, 241 graph node seeds, 233 graph edge hints
- `dart run tool/advisor_corpus/main.dart prepare-load` - 8 source documents,
  233 chunks, 241 graph node seeds, 233 graph edge hints; generated run id
  `387affd6-0397-57eb-a308-97cd602994f6`

## Out Of Scope

- no live database apply
- no Supabase local stack requirement
- no embeddings generated
- no vector index creation
- no Apache AGE graph projection
- no MCP tools
- no source Markdown rewrites
