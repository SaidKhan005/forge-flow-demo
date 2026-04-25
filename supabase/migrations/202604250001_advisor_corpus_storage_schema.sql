-- Phase 11a.3 - Advisor corpus storage schema scaffold.
--
-- This migration prepares storage for the deterministic records emitted by:
--
--   dart run tool/advisor_corpus/main.dart materialize
--
-- It intentionally does not load JSONL records, generate embeddings, create
-- AGE vertices/edges, or expose MCP tools.

create extension if not exists vector;

-- Supabase local Postgres currently has pgvector available but may not ship
-- Apache AGE in every environment. Corpus storage does not depend on AGE types;
-- AGE projection remains a later slice, so missing AGE should not block loading
-- the staging rows.
do $$
begin
  if exists (
    select 1
    from pg_available_extensions
    where name = 'age'
  ) then
    execute 'create extension if not exists age';
  else
    raise notice 'Apache AGE extension is not available; advisor graph projection remains staged only.';
  end if;
end;
$$;

create extension if not exists pgcrypto;

create table if not exists public.advisor_ingestion_runs (
  run_id uuid primary key default gen_random_uuid(),
  materializer_version integer not null check (materializer_version > 0),
  manifest_path text not null,
  document_count integer not null check (document_count >= 0),
  chunk_count integer not null check (chunk_count >= 0),
  graph_node_seed_count integer not null check (graph_node_seed_count >= 0),
  graph_edge_hint_count integer not null check (graph_edge_hint_count >= 0),
  embedding_status text not null default 'pending'
    check (embedding_status in ('pending', 'ready', 'failed', 'skipped')),
  output_summary jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.advisor_source_documents (
  doc_id text primary key,
  ingestion_run_id uuid references public.advisor_ingestion_runs(run_id)
    on delete set null,
  file_name text not null,
  source_path text not null unique,
  title text not null,
  scope text not null,
  restaurant_id uuid,
  brand_context text not null,
  content_role text not null,
  authority_tier text not null,
  risk_level text not null,
  audience text[] not null default '{}'::text[],
  chunk_profile text not null,
  graph_profiles text[] not null default '{}'::text[],
  tags text[] not null default '{}'::text[],
  source_sha256 text not null check (source_sha256 ~ '^[a-f0-9]{64}$'),
  embedding_status text not null default 'pending'
    check (embedding_status in ('pending', 'ready', 'failed', 'skipped')),
  provenance jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (scope <> 'global_shared_methodology' or restaurant_id is null)
);

create table if not exists public.advisor_source_chunks (
  chunk_id text primary key,
  doc_id text not null references public.advisor_source_documents(doc_id)
    on delete cascade,
  ingestion_run_id uuid references public.advisor_ingestion_runs(run_id)
    on delete set null,
  source_path text not null,
  scope text not null,
  restaurant_id uuid,
  chunk_kind text not null,
  chunk_profile text not null,
  heading_path text[] not null default '{}'::text[],
  start_line integer not null check (start_line > 0),
  end_line integer not null check (end_line >= start_line),
  estimated_tokens integer not null check (estimated_tokens >= 0),
  risk_level text not null,
  content_sha256 text not null check (content_sha256 ~ '^[a-f0-9]{64}$'),
  embedding_status text not null default 'pending'
    check (embedding_status in ('pending', 'ready', 'failed', 'skipped')),
  embedding_model text,
  embedding vector(1024),
  text text not null,
  provenance jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (scope <> 'global_shared_methodology' or restaurant_id is null)
);

create table if not exists public.advisor_graph_node_seeds (
  node_id text primary key,
  ingestion_run_id uuid references public.advisor_ingestion_runs(run_id)
    on delete set null,
  node_type text not null,
  source_doc_id text not null references public.advisor_source_documents(doc_id)
    on delete cascade,
  source_chunk_id text references public.advisor_source_chunks(chunk_id)
    on delete cascade,
  confidence text not null check (confidence in ('extracted', 'inferred', 'ambiguous')),
  risk_level text not null,
  properties jsonb not null default '{}'::jsonb,
  age_graph_name text,
  age_vertex_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.advisor_graph_edge_hints (
  edge_id text primary key,
  ingestion_run_id uuid references public.advisor_ingestion_runs(run_id)
    on delete set null,
  edge_type text not null,
  from_node_id text not null references public.advisor_graph_node_seeds(node_id)
    on delete cascade,
  to_node_id text not null references public.advisor_graph_node_seeds(node_id)
    on delete cascade,
  source_doc_id text not null references public.advisor_source_documents(doc_id)
    on delete cascade,
  source_chunk_id text references public.advisor_source_chunks(chunk_id)
    on delete cascade,
  confidence text not null check (confidence in ('extracted', 'inferred', 'ambiguous')),
  properties jsonb not null default '{}'::jsonb,
  age_graph_name text,
  age_edge_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists advisor_source_documents_scope_idx
  on public.advisor_source_documents(scope, restaurant_id);

create index if not exists advisor_source_documents_role_idx
  on public.advisor_source_documents(content_role);

create index if not exists advisor_source_documents_risk_idx
  on public.advisor_source_documents(risk_level);

create index if not exists advisor_source_documents_tags_idx
  on public.advisor_source_documents using gin(tags);

create index if not exists advisor_source_documents_audience_idx
  on public.advisor_source_documents using gin(audience);

create index if not exists advisor_source_chunks_doc_idx
  on public.advisor_source_chunks(doc_id);

create index if not exists advisor_source_chunks_scope_idx
  on public.advisor_source_chunks(scope, restaurant_id);

create index if not exists advisor_source_chunks_heading_path_idx
  on public.advisor_source_chunks using gin(heading_path);

create index if not exists advisor_source_chunks_risk_idx
  on public.advisor_source_chunks(risk_level);

create index if not exists advisor_source_chunks_embedding_status_idx
  on public.advisor_source_chunks(embedding_status, embedding_model);

create index if not exists advisor_graph_node_seeds_doc_idx
  on public.advisor_graph_node_seeds(source_doc_id);

create index if not exists advisor_graph_node_seeds_type_idx
  on public.advisor_graph_node_seeds(node_type);

create index if not exists advisor_graph_edge_hints_from_idx
  on public.advisor_graph_edge_hints(from_node_id);

create index if not exists advisor_graph_edge_hints_to_idx
  on public.advisor_graph_edge_hints(to_node_id);

create index if not exists advisor_graph_edge_hints_type_idx
  on public.advisor_graph_edge_hints(edge_type);

create or replace function public.advisor_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists advisor_source_documents_set_updated_at
  on public.advisor_source_documents;
create trigger advisor_source_documents_set_updated_at
before update on public.advisor_source_documents
for each row execute function public.advisor_set_updated_at();

drop trigger if exists advisor_source_chunks_set_updated_at
  on public.advisor_source_chunks;
create trigger advisor_source_chunks_set_updated_at
before update on public.advisor_source_chunks
for each row execute function public.advisor_set_updated_at();

drop trigger if exists advisor_graph_node_seeds_set_updated_at
  on public.advisor_graph_node_seeds;
create trigger advisor_graph_node_seeds_set_updated_at
before update on public.advisor_graph_node_seeds
for each row execute function public.advisor_set_updated_at();

drop trigger if exists advisor_graph_edge_hints_set_updated_at
  on public.advisor_graph_edge_hints;
create trigger advisor_graph_edge_hints_set_updated_at
before update on public.advisor_graph_edge_hints
for each row execute function public.advisor_set_updated_at();

alter table public.advisor_ingestion_runs enable row level security;
alter table public.advisor_source_documents enable row level security;
alter table public.advisor_source_chunks enable row level security;
alter table public.advisor_graph_node_seeds enable row level security;
alter table public.advisor_graph_edge_hints enable row level security;

-- Phase 9 auth is not live yet. These policies document the intended future
-- shape without granting broad anonymous access. Admin/service ingestion should
-- use the Supabase service role. Authenticated global reads are limited to
-- founder-authored shared methodology rows.

create policy "advisor_ingestion_runs_service_role_all"
  on public.advisor_ingestion_runs
  for all
  to service_role
  using (true)
  with check (true);

create policy "advisor_source_documents_service_role_all"
  on public.advisor_source_documents
  for all
  to service_role
  using (true)
  with check (true);

create policy "advisor_source_chunks_service_role_all"
  on public.advisor_source_chunks
  for all
  to service_role
  using (true)
  with check (true);

create policy "advisor_graph_node_seeds_service_role_all"
  on public.advisor_graph_node_seeds
  for all
  to service_role
  using (true)
  with check (true);

create policy "advisor_graph_edge_hints_service_role_all"
  on public.advisor_graph_edge_hints
  for all
  to service_role
  using (true)
  with check (true);

create policy "advisor_source_documents_global_read_placeholder"
  on public.advisor_source_documents
  for select
  to authenticated
  using (scope = 'global_shared_methodology' and restaurant_id is null);

create policy "advisor_source_chunks_global_read_placeholder"
  on public.advisor_source_chunks
  for select
  to authenticated
  using (scope = 'global_shared_methodology' and restaurant_id is null);

create policy "advisor_graph_node_seeds_global_read_placeholder"
  on public.advisor_graph_node_seeds
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.advisor_source_documents doc
      where doc.doc_id = advisor_graph_node_seeds.source_doc_id
        and doc.scope = 'global_shared_methodology'
        and doc.restaurant_id is null
    )
  );

create policy "advisor_graph_edge_hints_global_read_placeholder"
  on public.advisor_graph_edge_hints
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.advisor_source_documents doc
      where doc.doc_id = advisor_graph_edge_hints.source_doc_id
        and doc.scope = 'global_shared_methodology'
        and doc.restaurant_id is null
    )
  );

comment on table public.advisor_ingestion_runs is
  '11a advisor corpus ingestion audit table. Stores metadata for future JSONL loads.';
comment on table public.advisor_source_documents is
  '11a source document records emitted by tool/advisor_corpus materialize.';
comment on table public.advisor_source_chunks is
  '11a source chunk records. Embedding columns are present but remain pending until provider selection.';
comment on table public.advisor_graph_node_seeds is
  '11a graph node staging records for later Apache AGE ingestion.';
comment on table public.advisor_graph_edge_hints is
  '11a graph edge staging records for later Apache AGE ingestion.';
comment on column public.advisor_source_chunks.embedding is
  'Voyage voyage-4-large embedding vector. Contract dimension locked to 1024 in 11a.6a for Claude-aligned retrieval.';
