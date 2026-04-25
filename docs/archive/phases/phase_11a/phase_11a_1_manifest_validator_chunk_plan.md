# Phase 11a.1 - Manifest Validator + Chunk Plan Dry Run

Updated: 2026-04-25
Owner: Codex planning / advisor infrastructure lane
Status: Complete - local validator and dry-run chunk planner landed

## Plain English

This run makes the corpus mechanically checkable before backend ingestion
exists. Example: if a new Markdown file appears in the corpus folder without a
manifest row, the tool flags it instead of silently letting the advisor learn
from it.

## Landed

- Local Dart tool under `tool/advisor_corpus/`
- `validate` command for `docs/Knowledge_graph_docs/corpus_manifest.yaml`
- `plan-chunks` dry run command
- Focused validator and planner tests in `test/advisor_corpus_manifest_test.dart`
- Direct dev dependencies for `yaml` and `crypto`

## Validator Coverage

The validator checks:

- included manifest documents exist
- active Markdown files are all manifested
- `The Empty Apron - 2026.md` is not active
- required document fields are present
- duplicate `doc_id`, `source_path`, and `file_name` are rejected
- stored SHA-256 values match current file bytes

## Chunk Planner Coverage

The dry-run planner follows the 11a.0 contract:

- heading-aware documents split by heading path
- glossary documents split one term per chunk
- risk level and source metadata flow into every planned chunk
- source Markdown is not rewritten

## Accepted Evidence

- `dart analyze` - clean
- `flutter test test/advisor_corpus_manifest_test.dart` - 8 tests passing
- `dart run tool/advisor_corpus/main.dart validate` - 8 documents, 8 active
  Markdown files
- `dart run tool/advisor_corpus/main.dart plan-chunks` - 8 documents, 233
  planned chunks

## Out Of Scope

- no embeddings
- no database tables
- no graph writes
- no MCP tools
- no generated output checked in
- no source Markdown rewrites
