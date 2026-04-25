# Phase 11a.6 - Embedding Contract And Provider Prep

Updated: 2026-04-25
Owner: Codex planning / advisor infrastructure lane
Status: Complete - Claude-aligned embedding + rerank contract locked; dry-run provider prep landed

## Plain English

The corpus is in Postgres, but the chunks still need vectors before semantic
search can work. This run locks the vector shape, names the rerank layer, and
prepares the exact embedding input batch, without calling Voyage or writing any
vectors yet.
Example: `barrio_company_handbook__..._001` now has an embedding job input row
that says "send this text to `voyage-4-large` and expect a 1024-number vector
back"; later retrieval will pull pgvector candidates, rerank them with
`rerank-2.5`, then hand the grounded context to Claude.

## Provider Contract

The initial advisor embedding contract is Claude-aligned:

- advisor answer/runtime model family: Claude / Anthropic, future 11b
- embedding provider: `voyage`
- embedding model: `voyage-4-large`
- dimensions: `1024`
- tokenizer: `voyage`
- max input tokens: `32000`
- distance metric: `cosine`
- rerank provider: `voyage`
- rerank model: `rerank-2.5`
- answer runtime family: `Claude / Anthropic`
- success state: `embedding_status = ready`
- pre-execution state: `embedding_status = pending`

Anthropic's own Claude embedding guide says Anthropic does not offer a native
embedding model and points Claude builders to Voyage AI. Voyage's current model
docs list `voyage-4-large` as the best general-purpose and multilingual
retrieval-quality option, while Voyage's reranker docs list `rerank-2.5` as
the current rerank lane. This keeps Claude as the future advisor reasoning
layer while using the current best Voyage retrieval lane. The slice
intentionally does not make API calls.

## Landed

- `prepare-embeddings` command on `tool/advisor_corpus/main.dart`
- `CorpusEmbeddingJobPreparer` in `tool/advisor_corpus/advisor_corpus.dart`
- embedding + rerank contract constants in the advisor corpus tool
- `advisor_source_chunks.embedding` pinned to `vector(1024)`
- new Supabase migration:
  `supabase/migrations/202604250002_advisor_embedding_contract.sql`
- dry-run embedding job artifacts under `build/advisor_corpus/embeddings/`
- tests for deterministic job prep, unsupported dimension rejection, and schema
  contract presence

## Generated Output Contract

`dart run tool/advisor_corpus/main.dart prepare-embeddings` writes:

- `embedding_job_manifest.json`
- `embedding_inputs.jsonl`
- `embedding_update_template.sql`

The generated manifest records:

- provider/model/dimensions
- distance metric
- tokenizer and max input tokens
- planned retrieval pipeline:
  `pgvector cosine -> voyage/rerank-2.5 -> Claude answer runtime`
- dry-run/no-API mode
- no database mutation
- required future API key environment variable: `VOYAGE_API_KEY`
- chunk count and estimated token count

## Real Corpus Output

The current corpus generated:

- 233 embedding input rows
- 108,462 estimated tokens
- job id: `a264dbca-da0c-5ced-a562-fe29959ae96e`
- mode: `dry_run_no_api_call`
- database mutation: `false`

## Local DB Verification

The local `forge-flow-advisor-corpus-db` container was updated with the
embedding contract migration.

Verified:

- `advisor_source_chunks.embedding` reports as `vector(1024)`
- 233 chunks remain `embedding_status = pending`
- 0 chunks have `embedding` or `embedding_model` populated

## Accepted Evidence

- `dart analyze` - clean
- `flutter test test/advisor_corpus_manifest_test.dart` - 15 tests passing
- `dart run tool/advisor_corpus/main.dart prepare-embeddings` - 233 chunks,
  108,462 estimated tokens
- generated manifest records planned rerank `voyage/rerank-2.5` and Claude
  answer runtime family
- local Supabase Postgres reports `embedding_type = vector(1024)`

## Out Of Scope

- no Voyage API call
- no real embeddings generated
- no rerank API call
- no embedding row updates
- no vector index creation
- no semantic search function
- no Apache AGE graph projection
- no MCP tools
- no cloud or production database apply
