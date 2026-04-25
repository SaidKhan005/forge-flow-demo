# Phase 11a.5 - Local DB Load Verification

Updated: 2026-04-25
Owner: Codex planning / advisor infrastructure lane
Status: Complete - corpus loaded into local Supabase Postgres container

## Plain English

The corpus is now not just files on disk; it has been loaded into a real local
Postgres database using the same table contract staged in 11a.3. Example: the
233 source chunks now exist as rows in `advisor_source_chunks`, still marked
`pending` for embeddings.

## Local Database

The verification database is a disposable local Docker container backed by a
named Docker volume:

- container: `forge-flow-advisor-corpus-db`
- image: `supabase/postgres:15.8.1.060`
- host port: `55432`
- database: `postgres`
- user: `postgres`
- password: `postgres`
- named volume: `forge_flow_advisor_corpus_pgdata`

The container was restarted after load and the loaded rows remained present,
proving the data is on the named volume rather than only in a transient smoke
test.

## Schema Adjustment

The Supabase Postgres image has `vector` available but does not expose the
`age` extension. Because this slice loads staging rows only and does not create
an Apache AGE graph, the migration now:

- still requires `pgvector` via `create extension if not exists vector`
- conditionally creates `age` only when `pg_available_extensions` reports it
- raises a notice when AGE is unavailable
- leaves AGE graph projection as a later slice

This keeps corpus storage loadable against the Supabase-local shape while
preserving the graph projection placeholder columns.

## Loaded Counts

| Table | Count |
| --- | ---: |
| `advisor_ingestion_runs` | 1 |
| `advisor_source_documents` | 8 |
| `advisor_source_chunks` | 233 |
| `advisor_graph_node_seeds` | 241 |
| `advisor_graph_edge_hints` | 233 |

The loaded run id is:

```text
387affd6-0397-57eb-a308-97cd602994f6
```

## Verification

- all five advisor tables exist
- RLS is enabled on all five advisor tables
- `vector` and `pgcrypto` extensions are installed
- AGE is unavailable in this Supabase image and was skipped with an explicit
  notice
- all 233 chunks have `embedding_status = pending`
- zero chunks have `embedding` or `embedding_model` set
- all 8 source documents remain `global_shared_methodology` with
  `restaurant_id is null`
- chunk/document, node/document, node/chunk, and edge/node orphan counts are 0
- reapplying all five load files leaves counts unchanged
- restarting the container leaves loaded rows present on the named volume

## Accepted Evidence

- `docker pull supabase/postgres:15.8.1.060` succeeded
- migration applied with `ON_ERROR_STOP=1`
- all five SQL load files applied with `ON_ERROR_STOP=1`
- idempotent reload kept counts at 1 / 8 / 233 / 241 / 233
- container restart kept counts at 8 / 233 / 241 / 233 for the loaded record
  tables

## Out Of Scope

- no cloud or production database apply
- no embeddings generated
- no vector indexes
- no Apache AGE graph creation
- no MCP tools
- no agent runtime or UX
- no source Markdown rewrites
