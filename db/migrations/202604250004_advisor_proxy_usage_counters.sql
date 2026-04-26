-- Phase 11a.10b - Advisor proxy usage counters.
--
-- The proxy reads this table before every protected provider call to
-- check per-minute request rate and monthly cost cap, then increments
-- the corresponding minute/month bucket on allow. The Dart side lives
-- in `tool/advisor_proxy/advisor_proxy.dart::ProxyUsageGuard`; this
-- migration only stages the schema. No provider call, no live API.
--
-- Bucket model:
--   - `minute_bucket` is the UTC minute the request lands in (the row
--     covers one (operator, location, tier) at one minute). The
--     proxy's per-minute cap is enforced against the row whose
--     `minute_bucket` equals `date_trunc('minute', now() at time zone
--     'UTC')`.
--   - `month_bucket` is the first day of the same row's UTC month,
--     denormalized so monthly cost rollups are a single sum across
--     all minute rows in that month. The proxy's monthly cost cap is
--     enforced by summing `cost_cents` over all rows where
--     `month_bucket = date_trunc('month', now() at time zone 'UTC')`.
--
-- Per-row uniqueness is on (operator, location, tier, minute_bucket)
-- so concurrent writes for the same minute upsert into one row.

create extension if not exists pgcrypto;

create table if not exists public.advisor_proxy_usage_counters (
  counter_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  tier_id text not null,
  minute_bucket timestamptz not null,
  month_bucket date not null,
  request_count integer not null default 0
    check (request_count >= 0),
  token_count bigint not null default 0
    check (token_count >= 0),
  cost_cents bigint not null default 0
    check (cost_cents >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (operator_id, location_id, tier_id, minute_bucket)
);

-- Read paths: per-minute cap reads by (operator, location, tier,
-- minute_bucket); monthly cap reads by (operator, location, tier,
-- month_bucket). Indexes match.

create index if not exists advisor_proxy_usage_counters_minute_idx
  on public.advisor_proxy_usage_counters
  (operator_id, location_id, tier_id, minute_bucket);

create index if not exists advisor_proxy_usage_counters_month_idx
  on public.advisor_proxy_usage_counters
  (operator_id, location_id, tier_id, month_bucket);

comment on table public.advisor_proxy_usage_counters is
  '11a.10b advisor proxy usage counters. One row per (operator, location, tier, UTC minute). The proxy reads minute + month rollups before each protected provider call to enforce per-minute request and monthly cost caps.';
comment on column public.advisor_proxy_usage_counters.tier_id is
  'Policy tier id (e.g. ''launch''). Joined to the tier policy table when per-operator tier resolution lands in a later proxy slice.';
comment on column public.advisor_proxy_usage_counters.minute_bucket is
  'UTC minute the row covers, truncated to the minute. Per-minute cap enforcement key.';
comment on column public.advisor_proxy_usage_counters.month_bucket is
  'First day of the row''s UTC month. Denormalized for fast monthly cost rollup; never recomputed at read.';
comment on column public.advisor_proxy_usage_counters.request_count is
  '11a.10b counter — incremented once per allowed request landing in this minute bucket.';
comment on column public.advisor_proxy_usage_counters.token_count is
  '11a.10b counter — accumulated input+output tokens for the bucket. Used by future per-tier observability; not load-bearing for the launch caps.';
comment on column public.advisor_proxy_usage_counters.cost_cents is
  '11a.10b counter — accumulated provider cost in cents for the bucket. The monthly cap sums this across all minute rows in the same month_bucket.';

create or replace function public.advisor_proxy_usage_counters_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists advisor_proxy_usage_counters_set_updated_at
  on public.advisor_proxy_usage_counters;
create trigger advisor_proxy_usage_counters_set_updated_at
before update on public.advisor_proxy_usage_counters
for each row execute function public.advisor_proxy_usage_counters_set_updated_at();

-- RLS scaffold. Counters are server-side accounting; only the proxy's
-- service-role connection touches this table. Phase 9 auth does not
-- expose counters to operator-scoped reads. RLS is enabled with no
-- authenticated/anon policy so non-service-role traffic is denied.

alter table public.advisor_proxy_usage_counters enable row level security;

create policy "advisor_proxy_usage_counters_service_role_all"
  on public.advisor_proxy_usage_counters
  for all
  to service_role
  using (true)
  with check (true);
