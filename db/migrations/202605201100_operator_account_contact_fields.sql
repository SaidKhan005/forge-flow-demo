-- Operator account contact fields.
--
-- The hierarchy account override tables inherit their contact defaults from
-- public.operators, so the business row needs real contact columns before
-- Brand / Region / District / Location overrides can behave consistently.
--
-- RLS posture: public.operators already carries operator-scoped RLS from the
-- cloud foundation slices. These columns are written only through
-- PATCH /v1/operator/account under the existing TenantContext flow.

begin;

alter table public.operators
  add column if not exists contact_email text,
  add column if not exists contact_phone text;

comment on column public.operators.contact_email is
  'Operator-level public contact email. Child account scopes inherit this '
  'value unless they set their own override.';

comment on column public.operators.contact_phone is
  'Operator-level public contact phone. Child account scopes inherit this '
  'value unless they set their own override.';

alter table public.operators
  drop constraint if exists operators_contact_email_format_check;
alter table public.operators
  add constraint operators_contact_email_format_check
  check (
    contact_email is null
    or (contact_email like '%@%' and length(contact_email) <= 320)
  );

alter table public.operators
  drop constraint if exists operators_contact_phone_length_check;
alter table public.operators
  add constraint operators_contact_phone_length_check
  check (
    contact_phone is null
    or length(contact_phone) between 1 and 64
  );

commit;
