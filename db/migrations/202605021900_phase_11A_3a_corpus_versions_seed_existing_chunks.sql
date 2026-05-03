-- Phase 11A.3a follow-up: seed the corpus version ledger from any
-- active corpus chunks that were loaded before the admin ledger
-- existed.
--
-- 11A.3a intentionally made advisor_source_chunks.version_id
-- nullable so pre-existing staging loads would keep working. The
-- live admin screen, however, reads corpus_versions plus the
-- corpus_version_chunks membership table. If staging already has
-- active chunks but an empty ledger, the screen truthfully says
-- "No corpus versions yet" even though retrieval data exists. This
-- one-time seed creates a baseline ledger row only for that state.

begin;

do $$
declare
  v_seed_version_id uuid;
begin
  if exists (
    select 1
      from public.advisor_source_chunks
     where active = true
       and superseded_at is null
  )
  and not exists (
    select 1 from public.corpus_versions
  ) then
    insert into public.corpus_versions (created_by, summary)
    values (
      null,
      'Seeded baseline from pre-11A.3a active corpus chunks'
    )
    returning version_id into v_seed_version_id;

    insert into public.corpus_version_chunks (version_id, chunk_id)
    select v_seed_version_id, chunk_id
      from public.advisor_source_chunks
     where active = true
       and superseded_at is null
    on conflict do nothing;

    update public.advisor_source_chunks
       set version_id = v_seed_version_id
     where active = true
       and superseded_at is null
       and version_id is null;
  end if;
end;
$$;

commit;
