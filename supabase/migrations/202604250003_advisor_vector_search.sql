-- Phase 11a.8 - Advisor vector search: versioned embedding metadata,
-- HNSW pgvector cosine index, and a stable scoped top-K search function.
--
-- 11a.6a locked the embedding contract to Voyage `voyage-4-large` at
-- vector(1024) for Claude-aligned retrieval. 11a.7 loaded ready vectors
-- into `public.advisor_source_chunks.embedding`. This migration makes
-- those vectors searchable and provider-safe so a search query cannot
-- accidentally mix rows produced by future provider/model/dimension
-- combinations.
--
-- Routing context:
--   - This is candidate retrieval only. Voyage rerank-2.5 lands in 11a.9
--     and the Claude answer runtime ships later.
--   - AGE remains the launch graph path; pgvector-only retrieval is
--     fallback insurance, not a replacement for AGE traversal.
--
-- This migration does not call any vendor API, does not generate any
-- embeddings, and does not mutate corpus content.

-- ── Versioned embedding metadata columns ────────────────────────────────────
--
-- The legacy `embedding_model` column from 11a.3 / 11a.6a stays in place
-- so historical writers continue to work; the three columns below are the
-- new provider-safe filters used by the HNSW index and the search function.

alter table public.advisor_source_chunks
  add column if not exists embedding_provider_id text;

alter table public.advisor_source_chunks
  add column if not exists embedding_model_id text;

alter table public.advisor_source_chunks
  add column if not exists embedding_dimension integer
    check (embedding_dimension is null or embedding_dimension > 0);

comment on column public.advisor_source_chunks.embedding_provider_id is
  '11a.8 versioned embedding metadata. Provider id (e.g. ''voyage''). The advisor_search_chunks function filters on this so future providers do not silently mix into Voyage candidate retrieval.';
comment on column public.advisor_source_chunks.embedding_model_id is
  '11a.8 versioned embedding metadata. Model id (e.g. ''voyage-4-large''). Filter prevents cross-model mixing in candidate retrieval.';
comment on column public.advisor_source_chunks.embedding_dimension is
  '11a.8 versioned embedding metadata. Vector dimension (e.g. 1024). Filter prevents cross-dimension mixing in candidate retrieval.';

-- Backfill the new columns from the 11a.7 ready Voyage rows. Existing
-- rows where `embedding_status = ready` and `embedding_model` is the
-- locked Voyage model id get the matching provider/model/dimension
-- triple so the HNSW index and the search function can find them.

update public.advisor_source_chunks
   set embedding_provider_id = 'voyage',
       embedding_model_id = 'voyage-4-large',
       embedding_dimension = 1024
 where embedding_status = 'ready'
   and embedding is not null
   and embedding_model = 'voyage-4-large'
   and (
     embedding_provider_id is null
     or embedding_model_id is null
     or embedding_dimension is null
   );

-- ── HNSW pgvector cosine index ──────────────────────────────────────────────
--
-- Partial index restricted to ready, non-null Voyage `voyage-4-large`
-- 1024-dim rows. The partial predicate uses only constants and the
-- existing immutable columns so pgvector accepts it. Building the index
-- against a single-provider/model/dimension triple keeps the operator
-- class consistent across the index pages.

create index if not exists advisor_source_chunks_voyage_hnsw_idx
  on public.advisor_source_chunks
  using hnsw (embedding vector_cosine_ops)
  where embedding_status = 'ready'
    and embedding is not null
    and embedding_provider_id = 'voyage'
    and embedding_model_id = 'voyage-4-large'
    and embedding_dimension = 1024
    and active = true;

comment on index public.advisor_source_chunks_voyage_hnsw_idx is
  '11a.8 HNSW cosine index over ready Voyage voyage-4-large 1024-dim vectors. Partial predicate keeps the index provider/model/dimension safe.';

-- ── Stable scoped top-K vector search function ──────────────────────────────
--
-- Returns ready candidate chunks ordered by cosine distance to the
-- query embedding. Filters by:
--   - embedding_status = 'ready' and embedding is not null
--   - embedding_provider_id / embedding_model_id / embedding_dimension
--     (so a Voyage caller cannot accidentally mix with a future
--     provider's rows under the same column)
--   - scope (text) and optional restaurant_id (uuid)
--   - max_results capped at a reasonable upper bound
--
-- The function is `stable` because it reads from a table without
-- mutating it. Reranking (11a.9) and Claude answer runtime (later)
-- consume this function's output downstream.

create or replace function public.advisor_search_chunks(
  query_embedding vector(1024),
  scope_filter text,
  restaurant_id_filter uuid,
  provider_id_filter text,
  model_id_filter text,
  dimension_filter integer,
  max_results integer
)
returns table (
  chunk_id text,
  doc_id text,
  source_path text,
  heading_path text[],
  scope text,
  restaurant_id uuid,
  chunk_kind text,
  chunk_profile text,
  risk_level text,
  content_sha256 text,
  embedding_provider_id text,
  embedding_model_id text,
  embedding_dimension integer,
  text text,
  provenance jsonb,
  similarity double precision,
  distance double precision
)
language sql
stable
as $$
  select
    c.chunk_id,
    c.doc_id,
    c.source_path,
    c.heading_path,
    c.scope,
    c.restaurant_id,
    c.chunk_kind,
    c.chunk_profile,
    c.risk_level,
    c.content_sha256,
    c.embedding_provider_id,
    c.embedding_model_id,
    c.embedding_dimension,
    c.text,
    c.provenance,
    (1.0 - (c.embedding <=> query_embedding))::double precision as similarity,
    (c.embedding <=> query_embedding)::double precision as distance
  from public.advisor_source_chunks c
  where c.embedding_status = 'ready'
    and c.embedding is not null
    and c.active = true
    and c.embedding_provider_id = provider_id_filter
    and c.embedding_model_id = model_id_filter
    and c.embedding_dimension = dimension_filter
    and c.scope = scope_filter
    and (restaurant_id_filter is null or c.restaurant_id = restaurant_id_filter)
  order by c.embedding <=> query_embedding
  limit greatest(1, least(coalesce(max_results, 10), 100));
$$;

comment on function public.advisor_search_chunks(
  vector(1024), text, uuid, text, text, integer, integer
) is
  '11a.8 advisor vector search. Returns top scoped chunks ordered by cosine distance with citation metadata (doc_id, source_path, heading_path, scope, restaurant_id, chunk_kind, content_sha256, provenance) and the similarity / distance scores. Provider/model/dimension filters keep candidate retrieval Voyage-safe in the launch product. Reranking is delegated to Voyage rerank-2.5 in 11a.9; this function is candidate retrieval only.';
