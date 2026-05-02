-- Phase 9 MFA production hardening - Firebase UID text repair.
--
-- Earlier Phase 9 schema work assumed Firebase Identity Platform UIDs would
-- always be pre-generated UUID strings. Live Firebase users can have arbitrary
-- UID strings, and MFA removal workers must target that real Firebase UID, not
-- the local app user_id. Convert the link column to text while preserving
-- existing UUID-shaped placeholder values.

alter table public.users
  drop constraint if exists users_firebase_uid_key;

alter table public.users
  alter column firebase_uid type text using firebase_uid::text;

alter table public.users
  alter column firebase_uid set default gen_random_uuid()::text;

alter table public.users
  alter column firebase_uid set not null;

alter table public.users
  add constraint users_firebase_uid_key unique (firebase_uid);

comment on column public.users.firebase_uid is
  '9.0 Firebase Identity Platform uid. Stored as text because Firebase Identity Platform accepts arbitrary string uids; workers and proxy routes resolve this value instead of assuming users.user_id equals Firebase uid.';
