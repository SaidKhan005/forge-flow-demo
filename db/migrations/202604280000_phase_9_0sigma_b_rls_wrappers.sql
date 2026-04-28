-- Phase 9.0Σ.b — RLS UUID wrapper functions (item 4 from
-- phase_9_scalability_decisions_2026-04-27.md).
--
-- Creates four read-only SQL wrappers that every operator-scoped RLS
-- policy must call instead of reading `current_setting('app.*', true)`
-- inline. Rationale: bare `current_setting()` inside a policy body is
-- not marked `LEAKPROOF`, which forces the planner to evaluate the
-- policy at the row level rather than folding it into the index scan.
-- Wrapping the call in a `STABLE LEAKPROOF PARALLEL SAFE` SQL function
-- restores planner pushdown and (per item 4) is the locked posture for
-- every Phase 9 policy — auth tables today, fact tables and the 9.0g
-- usage_caps two-slot key rewrite next.
--
-- Wrapper naming and read order — matches scalability decisions item 4
-- and execution backlog B23 verbatim:
--
--   `app_current_operator()`     reads `app.operator_id`
--   `app_current_location()`     reads `app.location_id`
--   `app_current_actor_user()`   reads `app.user_id`
--   `app_acting_as_operator()`   reads `app.acting_as_operator_id`
--
-- The first three GUCs are the existing names the proxy already
-- injects via `set_config('app.<name>', @value, true)` inside
-- `lib/infrastructure/persistence/postgres/tenant_transaction.dart`.
-- The fourth (`app.acting_as_operator_id`) has no proxy injection
-- today — the wrapper returns NULL until F&F internal cross-operator
-- access lands. NULL is a fail-closed default: policies that compare
-- `operator_id = app_acting_as_operator()` will not match while the
-- GUC is unset, and only the existing per-tenant filter wins. Adding
-- the wrapper now (rather than alongside the impersonation feature)
-- means future policies do not need to be rewritten when the GUC is
-- finally set.
--
-- NULL-safe cast — `current_setting('app.<name>', true)` returns the
-- empty string when the GUC is unset (the second `true` arg suppresses
-- the missing-GUC error). Casting `''::uuid` raises
-- `invalid_input_syntax_for_type_uuid`, which would propagate up
-- through every policy evaluation. `nullif(...)::uuid` collapses both
-- "missing" and "empty" into NULL so policies see a single absent
-- value to compare against.
--
-- Function posture per item 4:
--   * `LANGUAGE sql`    — pure SQL, no plpgsql control flow needed.
--   * `STABLE`          — same input → same output within a single
--                         statement; safe for index pushdown.
--   * `LEAKPROOF`       — required for the planner to fold the policy
--                         into joins/index conditions. PG 16 still
--                         requires superuser to set this attribute;
--                         migration runs as the migration role which
--                         has the privilege on staging and Production1
--                         (same role that creates `forge_admin
--                         BYPASSRLS` in 202604260000).
--   * `PARALLEL SAFE`   — readonly GUC reads are parallel-safe.
--
-- This migration is local framework only — no live database mutation.
-- The matching policy rewrite lands in 202604280001 (next file).

-- ─── app_current_operator ──────────────────────────────────────────
create or replace function public.app_current_operator()
returns uuid
language sql
stable leakproof parallel safe
as $$
  select nullif(current_setting('app.operator_id', true), '')::uuid;
$$;

comment on function public.app_current_operator() is
  'Phase 9.0Σ.b — returns the active operator UUID from the app.operator_id GUC. '
  'NULL when unset. Every operator-scoped RLS policy MUST call this wrapper '
  'instead of bare current_setting(...) so the planner can fold the comparison '
  'into the tenant-leading index. CI lint forbids new policy bodies that read '
  'app.operator_id directly.';

-- ─── app_current_location ──────────────────────────────────────────
create or replace function public.app_current_location()
returns uuid
language sql
stable leakproof parallel safe
as $$
  select nullif(current_setting('app.location_id', true), '')::uuid;
$$;

comment on function public.app_current_location() is
  'Phase 9.0Σ.b — returns the active location UUID from the app.location_id GUC. '
  'NULL when unset. Per-location policies MUST use this wrapper.';

-- ─── app_current_actor_user ────────────────────────────────────────
create or replace function public.app_current_actor_user()
returns uuid
language sql
stable leakproof parallel safe
as $$
  select nullif(current_setting('app.user_id', true), '')::uuid;
$$;

comment on function public.app_current_actor_user() is
  'Phase 9.0Σ.b — returns the actor user UUID from the app.user_id GUC. '
  'NULL when unset. Per-user policies (auth_sessions, mfa_factors, '
  'password_history) MUST use this wrapper.';

-- ─── app_acting_as_operator ────────────────────────────────────────
--
-- The `app.acting_as_operator_id` GUC is reserved for the F&F internal
-- admin/dev cross-operator access path described in
-- `phase_9_scalability_decisions_2026-04-27.md` Q1 audit attribution
-- ("`actor_user_id`, `active_operator_id`, and `acting_as_operator_id`
-- or `target_operator_id` where relevant"). No proxy code injects the
-- GUC today; the wrapper returns NULL until that lift lands. Defining
-- the wrapper now means policies that need to gate cross-operator
-- F&F access can already reference it without a follow-up DDL change.
create or replace function public.app_acting_as_operator()
returns uuid
language sql
stable leakproof parallel safe
as $$
  select nullif(current_setting('app.acting_as_operator_id', true), '')::uuid;
$$;

comment on function public.app_acting_as_operator() is
  'Phase 9.0Σ.b — returns the impersonated/target operator UUID from the '
  'app.acting_as_operator_id GUC. NULL when unset. Reserved for the F&F '
  'internal admin/dev cross-operator access path (see scalability decisions '
  'Q1 audit attribution); no proxy code injects this GUC today, but defining '
  'the wrapper now means future policies need no follow-up DDL.';

-- ─── Execute grants ────────────────────────────────────────────────
--
-- Wrappers are read-only; both the runtime tenant role (`service_role`)
-- and the BYPASSRLS escape hatch (`forge_admin`) need EXECUTE so that
-- policy evaluation succeeds in either path. SECURITY INVOKER (the
-- default for non-DEFINER functions) is what we want — the wrapper
-- runs with the calling role's privileges, so a tenant cannot use the
-- wrapper to escalate.

grant execute on function public.app_current_operator() to service_role;
grant execute on function public.app_current_location() to service_role;
grant execute on function public.app_current_actor_user() to service_role;
grant execute on function public.app_acting_as_operator() to service_role;

grant execute on function public.app_current_operator() to forge_admin;
grant execute on function public.app_current_location() to forge_admin;
grant execute on function public.app_current_actor_user() to forge_admin;
grant execute on function public.app_acting_as_operator() to forge_admin;
