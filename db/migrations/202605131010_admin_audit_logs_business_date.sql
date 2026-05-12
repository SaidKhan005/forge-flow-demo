-- Admin audit-log business-date projection.
--
-- The hash chain stays partitioned by UTC `chain_date`; this adds the
-- operator-facing restaurant-local `business_date` required by the console
-- parity contract. New writes populate it from location timing metadata in
-- AuditLogsRepository. Existing rows backfill from `chain_date` because their
-- original location timing cannot be reconstructed perfectly after the fact.

begin;

alter table public.audit_logs
  add column if not exists business_date date null;

update public.audit_logs
   set business_date = chain_date
 where business_date is null;

alter table public.audit_logs
  alter column business_date set not null;

create index if not exists audit_logs_operator_business_date_idx
  on public.audit_logs (operator_id, business_date, occurred_at desc);

comment on column public.audit_logs.business_date is
  'Restaurant-local business date for operator-facing audit reporting. Distinct from UTC chain_date, which remains the hash-chain partition key.';

commit;
