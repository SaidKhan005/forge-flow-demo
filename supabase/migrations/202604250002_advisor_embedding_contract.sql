-- Phase 11a.6a - Advisor embedding contract, Claude-aligned revision.
--
-- Anthropic does not offer a native Claude embedding model. For a Claude
-- advisor stack, 11a uses the Anthropic-recommended Voyage embedding lane.
-- Reranking is not persisted in schema; the 11a.6a runtime contract is
-- pgvector cosine candidates -> Voyage rerank-2.5 -> Claude answer runtime.
-- This migration does not generate embeddings or call a provider.

alter table public.advisor_source_chunks
  alter column embedding type vector(1024);

comment on column public.advisor_source_chunks.embedding is
  'Voyage voyage-4-large embedding vector. Contract dimension locked to 1024 in 11a.6a for Claude-aligned retrieval.';

comment on column public.advisor_source_chunks.embedding_model is
  'Embedding provider model id. 11a.6a contract: voyage-4-large. Claude remains the future advisor answer/runtime model.';
