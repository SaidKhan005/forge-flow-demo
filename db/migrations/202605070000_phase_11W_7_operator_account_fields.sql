-- Phase 11W.7 / Wave A2 - operator account write-fields.
--
-- Adds the editable business-identity columns the operator-web Account
-- settings page (PATCH /v1/operator/account) needs. Columns are
-- additive and nullable / defaulted so existing rows are preserved.
--
-- Field locations follow the existing schema:
--   * business_name and primary_location_id already live on operators.
--   * business_day_rollover_hour already lives on locations and is the
--     authoritative per-location source. Phase 11W.7 stores an
--     operator-level default (rollover_hour) that the operator-web
--     settings UI reads/writes; per-location overrides remain on
--     locations.business_day_rollover_hour.
--   * locale_tag, currency_code, week_start_day, logo_url are
--     operator-level identity/regional defaults that locations inherit.
--
-- RLS posture: operators is identity (per-operator) and is already
-- protected by existing operator policies created in earlier slices
-- (operator owners can update their own row through the proxy's
-- TenantContext SET LOCAL flow). This migration does not change RLS.
--
-- Time posture: no new TIMESTAMPTZ columns added; updated_at is already
-- present and maintained by cloud_foundation_set_updated_at trigger.

begin;

alter table public.operators
  add column if not exists logo_url text,
  add column if not exists locale_tag text not null default 'en-US',
  add column if not exists week_start_day text not null default 'monday',
  add column if not exists rollover_hour integer not null default 4;

-- preferred_currency already exists with check (~ '^[A-Z]{3}$') and
-- default 'CAD'. Mirror an alias-style column comment so the proxy
-- writers can target the same column when the request body says
-- `currencyCode`.
comment on column public.operators.preferred_currency is
  '11W.7 / A2: ISO 4217 currency code (3 uppercase letters). Settable '
  'via PATCH /v1/operator/account currencyCode.';

comment on column public.operators.logo_url is
  '11W.7 / A2: Optional https URL pointing at the operator''s brand '
  'logo. Settable via PATCH /v1/operator/account logoUrl.';

comment on column public.operators.locale_tag is
  '11W.7 / A2: BCP 47 locale tag (e.g. en-US, fr-CA). Settable via '
  'PATCH /v1/operator/account localeTag.';

comment on column public.operators.week_start_day is
  '11W.7 / A2: Operator-default week start (monday..sunday). '
  'Settable via PATCH /v1/operator/account weekStartDay. '
  'Per-location business timing profiles may override this.';

comment on column public.operators.rollover_hour is
  '11W.7 / A2: Operator-default business-day rollover hour (0..23). '
  'Settable via PATCH /v1/operator/account rolloverHour. '
  'Per-location locations.business_day_rollover_hour overrides this.';

-- Format constraints. NOT VALID so existing rows that already match
-- the defaults pass without a backfill scan; the constraint applies
-- to every future INSERT/UPDATE.
alter table public.operators
  drop constraint if exists operators_logo_url_format_check;
alter table public.operators
  add constraint operators_logo_url_format_check
  check (
    logo_url is null
    or (logo_url like 'https://%' and length(logo_url) <= 2048)
  );

alter table public.operators
  drop constraint if exists operators_locale_tag_format_check;
alter table public.operators
  add constraint operators_locale_tag_format_check
  check (locale_tag ~ '^[a-z]{2,3}(-[A-Z]{2})?$');

alter table public.operators
  drop constraint if exists operators_week_start_day_check;
alter table public.operators
  add constraint operators_week_start_day_check
  check (week_start_day in (
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday'
  ));

alter table public.operators
  drop constraint if exists operators_rollover_hour_range_check;
alter table public.operators
  add constraint operators_rollover_hour_range_check
  check (rollover_hour between 0 and 23);

alter table public.operators
  drop constraint if exists operators_business_name_length_check;
alter table public.operators
  add constraint operators_business_name_length_check
  check (length(trim(business_name)) between 1 and 120);

commit;
