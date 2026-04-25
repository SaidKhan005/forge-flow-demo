# Phase 11a.2 - Ingestion Record Materializer

Updated: 2026-04-25
Owner: Codex planning / advisor infrastructure lane
Status: Complete - deterministic build-only materializer landed

## Plain English

The validator proved the corpus is allowed to ingest; this run turns the
chunk plan into the exact records the future database and graph can receive.
Example: one Markdown section becomes a stable chunk id, source hash, heading
path, risk flag, graph seed, edge hint, and provenance payload.

## Landed

- `materialize` command on `tool/advisor_corpus/main.dart`
- Deterministic JSONL output under `build/advisor_corpus/`
- Source document records
- Source chunk records
- Graph node seed records
- Graph edge hint records
- Summary JSON
- Tests proving deterministic output and no source Markdown mutation

## Generated Output Contract

The materializer writes build-only files:

- `source_documents.jsonl`
- `source_chunks.jsonl`
- `graph_node_seeds.jsonl`
- `graph_edge_hints.jsonl`
- `manifest_summary.json`

Generated records include:

- stable IDs
- source paths
- document and chunk scope
- `restaurant_id`
- heading paths
- line ranges
- risk metadata
- content hashes
- pending embedding status
- provenance payloads

These files are generated artifacts, not source authority. They are not checked
in and can be regenerated from the manifest and Markdown corpus.

## Accepted Evidence

- `dart analyze` - clean
- `flutter test test/advisor_corpus_manifest_test.dart` - 10 tests passing
- `dart run tool/advisor_corpus/main.dart validate` - 8 documents, 8 active
  Markdown files
- `dart run tool/advisor_corpus/main.dart plan-chunks` - 8 documents, 233
  planned chunks
- `dart run tool/advisor_corpus/main.dart materialize` - 8 source documents,
  233 chunks, 241 graph node seeds, 233 graph edge hints

## Out Of Scope

- no Supabase migrations
- no Apache AGE graph creation
- no pgvector columns
- no embeddings
- no MCP tools
- no agent runtime or UX
- no source Markdown rewrites
