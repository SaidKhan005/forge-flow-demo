# Phase 11a.7 - Local Embedding Execution And DB Load

Updated: 2026-04-25
Owner: Codex planning / advisor infrastructure lane
Status: Complete - Voyage embeddings executed and loaded into local Supabase Postgres

## Plain English

The corpus chunks are ready, and this slice adds the guarded path that will
send them to Voyage, generate real 1024-number vectors, and prepare SQL updates
for local Postgres. Example: the chunk
`barrio_company_handbook__barrio_company_handbook_001` will become a row with
`embedding_status = ready`, `embedding_model = voyage-4-large`, and a populated
`vector(1024)` value once the API key is visible.

## Landed

- `execute-embeddings` command on `tool/advisor_corpus/main.dart`
- `CorpusEmbeddingExecutor` in `tool/advisor_corpus/advisor_corpus.dart`
- `VoyageHttpEmbeddingGateway` using `POST https://api.voyageai.com/v1/embeddings`
- provider request contract:
  - model: `voyage-4-large`
  - input type: `document`
  - output dimension: `1024`
  - output dtype: `float`
- generated output contract:
  - `embedding_execution_manifest.json`
  - `embedding_updates.sql`
- test coverage with a fake embedding gateway proving SQL generation without a
  real API call

## Execution State

The first live attempt hit Voyage's no-payment-method rate limit. The final
run used the same executor with free-tier-safe batching:

```text
dart run tool/advisor_corpus/main.dart execute-embeddings --batch-token-limit=4000 --batch-delay-ms=65000
```

Result:

```text
Advisor corpus embedding execution OK: 233 chunks across 29 batches.
Contract: voyage/voyage-4-large (1024 dimensions)
Provider-reported tokens: 103642
Execution ID: af433bf6-692b-5c60-a2f6-2712f712a9f6
```

The generated SQL was applied to the local `forge-flow-advisor-corpus-db`
container:

```powershell
Get-Content -Raw build/advisor_corpus/embeddings/embedding_updates.sql |
  docker exec -i forge-flow-advisor-corpus-db psql -U postgres -d postgres -v ON_ERROR_STOP=1
```

## Local DB Verification

- `advisor_source_chunks.embedding` reports as `vector(1024)`
- 0 chunks remain `embedding_status = pending`
- 233 chunks have `embedding_status = ready`
- 233 chunks have `embedding_model = voyage-4-large`
- 233 chunks have non-null `embedding`
- sample rows report `vector_dims(embedding) = 1024`

## Accepted Evidence

- `dart analyze` - clean
- `flutter test test/advisor_corpus_manifest_test.dart` - 17 tests passing
- `dart run tool/advisor_corpus/main.dart execute-embeddings --batch-token-limit=4000 --batch-delay-ms=65000`
  - 233 chunks, 29 batches, 103,642 provider-reported tokens
- local Supabase Postgres reports `0 pending / 233 ready / 233 populated`

## Out Of Scope

- no key storage in repo
- no rerank API call
- no semantic search function
- no vector index creation
- no cloud or production database apply
