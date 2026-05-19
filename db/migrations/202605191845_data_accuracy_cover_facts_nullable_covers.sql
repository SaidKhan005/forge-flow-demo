-- Data Accuracy cover_facts nullable covers.
--
-- Why this exists
-- ---------------
-- Some POS vendors, including Square and Clover, do not expose cover counts
-- through their public APIs. Their sink rows must preserve NULL covers so the
-- closed-shift aggregator can distinguish "vendor sent zero covers" from
-- "vendor sent no covers field".

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

alter table public.cover_facts
  alter column covers drop default,
  alter column covers drop not null;

comment on column public.cover_facts.covers is
  'Nullable POS cover count. Zero means a cover-capable vendor sent zero; '
  'NULL means the vendor did not expose a cover count.';

commit;
