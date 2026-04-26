-- Phase 11a.11c.6a - Contextual Retrieval + usage telemetry hardening.
--
-- Local schema-hardening migration. Adds the launch sparse-retrieval /
-- cache-invalidation columns and expands usage rollups so cost telemetry
-- dimensions do not collapse into one aggregate row.

-- Contextual Retrieval: indexing-time Haiku context is stored separately
-- from founder-authored chunk text, then included in sparse retrieval.
alter table public.advisor_source_chunks
  add column if not exists chunk_context text;

alter table public.advisor_source_chunks
  add column if not exists corpus_version text not null default 'launch_v1'
    check (length(btrim(corpus_version)) > 0);

alter table public.advisor_source_chunks
  add column if not exists bm25_tsv tsvector;

create index if not exists advisor_source_chunks_bm25_tsv_idx
  on public.advisor_source_chunks
  using gin (bm25_tsv)
  where active = true;

comment on column public.advisor_source_chunks.chunk_context is
  '11a.11c.6a Anthropic Contextual Retrieval. Haiku-generated 50-100 token context prepended at indexing time for retrieval only; founder-authored text remains in text.';

comment on column public.advisor_source_chunks.corpus_version is
  '11a.11c.6a corpus/cache version. Included in advisor cache keys so prompt-cache and response-cache entries invalidate when corpus material changes.';

comment on column public.advisor_source_chunks.bm25_tsv is
  '11a.11c.6a sparse retrieval vector. Weighted heading_path + chunk_context + text for BM25 leg before RRF + Voyage rerank. Populated by deterministic load/update SQL because Postgres generated columns require immutable expressions.';

comment on index public.advisor_source_chunks_bm25_tsv_idx is
  '11a.11c.6a GIN index for BM25 sparse retrieval over active advisor chunks.';

-- Usage telemetry dimensions. These are part of the rollup identity: a
-- Haiku cache hit and a Sonnet fallback miss must never be aggregated into
-- the same counter row.
alter table public.usage_logs
  add column if not exists query_class text not null default 'unknown'
    check (length(btrim(query_class)) > 0),
  add column if not exists cache_hit boolean not null default false,
  add column if not exists llm_tier text not null default 'unknown'
    check (length(btrim(llm_tier)) > 0),
  add column if not exists model_used text not null default 'unknown'
    check (length(btrim(model_used)) > 0),
  add column if not exists batch_mode boolean not null default false,
  add column if not exists circuit_state text not null default 'closed'
    check (circuit_state in ('closed', 'open', 'half_open', 'unknown')),
  add column if not exists fallback_used text not null default 'none'
    check (length(btrim(fallback_used)) > 0);

alter table public.usage_logs
  drop constraint if exists usage_logs_pkey;

alter table public.usage_logs
  add primary key (
    operator_id,
    location_id,
    usage_class,
    period_start,
    query_class,
    cache_hit,
    llm_tier,
    model_used,
    batch_mode,
    circuit_state,
    fallback_used
  );

comment on table public.usage_logs is
  '11a.11c.6a partitioned usage rollup. Primary key includes query/model/cache/batch/circuit/fallback dimensions so cost telemetry remains attributable by class and provider behavior.';

comment on column public.usage_logs.query_class is
  '11a.11c.6a advisor/workflow query class, e.g. methodology_lookup, causal_chain, recommendation, workflow_action.';

comment on column public.usage_logs.cache_hit is
  '11a.11c.6a true when the response/semantic/precompute cache served the request without a fresh model call.';

comment on column public.usage_logs.llm_tier is
  '11a.11c.6a logical model tier used for cost attribution, e.g. haiku or sonnet.';

comment on column public.usage_logs.model_used is
  '11a.11c.6a concrete provider model identifier used for the request or unknown for non-LLM rows.';

comment on column public.usage_logs.batch_mode is
  '11a.11c.6a true when the usage was produced through a batch/asynchronous provider path.';

comment on column public.usage_logs.circuit_state is
  '11a.11c.6a provider circuit-breaker state recorded at request time.';

comment on column public.usage_logs.fallback_used is
  '11a.11c.6a fallback path used for the request, or none when the primary path served it.';
