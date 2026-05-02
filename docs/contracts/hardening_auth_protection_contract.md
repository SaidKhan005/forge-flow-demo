# Hardening — Auth Protection Contract

Updated: 2026-05-02
Owner: HARD-B (auth hardening sprint)
Status: Closed (shipped commit `50c42f4`, PR #47) — retained as historical authority.

## Why This Exists

Login, MFA-confirm, and password-reset endpoints currently lack brute-force
protection and skip audit emission for failure cases. This contract defines
lockout thresholds, rate-limit envelopes, audit-event coverage for failures,
and supplemental fields (claims hash, optional reason) that bring the auth
boundary to OWASP API6/API2 baseline plus SOC 2 forensic completeness.

Handoff between:

- `tool/advisor_proxy/advisor_proxy.dart` — auth route handlers
  (`/v1/auth/session/login`, `/v1/auth/mfa/totp/confirm`,
  `/v1/auth/password/reset/request`, `/v1/auth/password/change`,
  `/v1/admin/service-principals`, `/v1/admin/feature-flags/toggle`).
- `lib/services/auth/` — gateway implementations.
- `db/migrations/` — new `auth_login_attempts` table (see Schema below).
- [audit_attribution_contract.md](audit_attribution_contract.md) — actor
  attribution rules audit events must follow.

Disagreement rule: this contract wins for lockout thresholds, audit field
shapes, and rate-limit envelopes. Existing
[audit_attribution_contract.md](audit_attribution_contract.md) wins for
actor-kind classification.

## In Scope

| Item | In | Out |
|------|-----|-----|
| Account lockout after threshold failed login attempts | yes | password complexity rules (already enforced) |
| TOTP retry cap per challenge | yes | TOTP secret rotation policy |
| Password-reset request rate limit refinement | yes | reset-link TTL policy (already 30 min) |
| Audit event for failed login | yes | in-app notification on failure (Phase 10a) |
| `claims_hash` on service-principal issuance audit | yes | claim payload encryption |
| Optional `reason` field on feature-flag toggle audit | yes | rationale validation/AI scoring |
| Comment at `lib/admin/admin_routes.dart:345` documenting compile-time gate | yes | code change to admin routes |

Out of scope: SIM-swap detection, anomaly-based MFA challenges,
risk-based authentication, tenant-level lockout, backup-code rotation
ceremonies.

## Lockout Schema

New migration: `db/migrations/<timestamp>_hardening_auth_login_attempts.sql`.

```sql
create table public.auth_login_attempts (
  attempt_id uuid primary key default gen_random_uuid(),
  operator_id uuid references public.operators(operator_id),
  user_email_hash bytea not null,           -- sha256 of normalized email
  ip_hash bytea not null,                   -- sha256 of client IP
  outcome text not null check (outcome in ('success','failure','locked')),
  attempted_at timestamptz not null default now(),
  user_agent_class text                     -- coarse classification only
);

create index auth_login_attempts_idx_email_hash_time
  on public.auth_login_attempts (user_email_hash, attempted_at desc);

create index auth_login_attempts_idx_operator_time
  on public.auth_login_attempts (operator_id, attempted_at desc)
  where operator_id is not null;
```

Index discipline: `operator_id` leads where present (locked 2026-04-26 RLS
performance discipline). Email hash retains anonymous lockout for unknown
operators (pre-tenant resolution).

Retention: `pg_partman` daily partitioning aligned with `audit_logs` window.
Anonymous (no operator) rows retained 30 days; tenant-bound rows retained
per audit log retention.

## Lockout Behavior

Login route (`/v1/auth/session/login`):

- After **5 failed attempts within 15 minutes** for the same
  `(user_email_hash, ip_hash)`, the next failure inserts an `outcome: locked`
  row and returns HTTP **423 Locked** with `{"error":"account_locked","retry_after_seconds":900}`.
- Lockout window is 15 minutes; success after window resets counter.
- Lockout is per-tenant when operator can be resolved; anonymous (e.g.,
  unknown email) lockout is per-`(email_hash, ip_hash)`.
- Successful login within window resets failure count for that
  `(user_email_hash, ip_hash)`.

MFA-confirm route (`/v1/auth/mfa/totp/confirm`):

- **3 failed TOTP guesses per challenge** then HTTP 429 `Retry-After: 30`
  with `{"error":"mfa_retry_limit","retry_after_seconds":30}`.
- Challenge expires after 5 min or 3 failures, whichever first.
- Each new challenge resets retry counter.

Password-reset request (`/v1/auth/password/reset/request`):

- Existing rate limit retained (per Lane 5 finding).
- Add **per-account suspension after 10 reset requests within 24h**:
  HTTP 429 with `{"error":"reset_request_throttled","retry_after_seconds":<seconds>}`.
- Reset confirm route (`/password/reset/confirm`) unchanged.

## Audit Events Required

All audit events land in `auth_events_audit` (the auth-only audit
surface). Events that arrive with a resolvable operator scope **also**
fan out into the hash-chained per-tenant `audit_logs` chain via the
existing `AuthEventsAuditRepository._fanOutToAuditLogs` path — see
[audit_attribution_contract.md](audit_attribution_contract.md) for the
attribution shape. Required event types added or extended:

| Event type | Trigger | Required payload fields | Per-tenant `audit_logs` fan-out |
|------------|---------|-------------------------|---------------------------------|
| `auth.login_failed` | Each failed login (incl. wrong password, unknown email, MFA missing) | `outcome` ∈ {`bad_password`,`unknown_user`,`mfa_required`,`mfa_failed`}, `attempt_count_in_window`, `locked: bool` | **No** — anonymous (operator not yet resolved). |
| `auth.account_locked` | Threshold breach | `lockout_until`, `attempt_count`, `email_hash` | **Conditional** — fans out when triggered from the success-path pre-check (verified bearer token resolves operator + actor); skipped on the anonymous failure-report path. |
| `auth.mfa_retry_exceeded` | TOTP retry cap | `challenge_id_hash`, `retry_count` | **Yes** — operator + actor resolved by bearer token. |
| `auth.password_reset_throttled` | 24h reset cap | `attempt_count_24h` | **No** — anonymous (operator not resolved per the privacy contract that prohibits leaking email presence). |
| `auth.service_principal_issued` (extended) | SP JWT issuance | `claims_hash` (sha256 of canonical JWT payload) — added field | **Yes** — operator + service principal resolved. |
| `admin.feature_flag_toggled` (extended) | Feature flag toggle | `reason` (optional, ≤500 chars) — added field | **Yes** — operator + actor resolved (existing 11A.7 fan-out). |

Sensitive fields **never** emitted: raw password, raw email, JWT body,
TOTP secret, recovery codes.

`auth.login_succeeded` already exists; no change.

### Why anonymous events stay in `auth_events_audit` only

The hash-chained `audit_logs` table from
`db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql` requires
`operator_id NOT NULL` and bounds each chain to
`(operator_id, chain_date)`. Three of the new events fire BEFORE the
proxy can resolve a tenant from the inbound credentials:

* `auth.login_failed` — the failure-report path receives `email +
  failure_outcome` but the email may not match a known user; resolving
  `email → operator` would either require a DB lookup that leaks email
  presence or admit anonymous attempts to a synthetic "platform"
  operator chain that has no SOC 2 ownership.
* `auth.account_locked` (failure-report path) — same constraint. The
  success-path lock has a verified bearer token and DOES fan out.
* `auth.password_reset_throttled` — the password-reset request route
  is contractually privacy-preserving (uniform response regardless of
  whether the email matches an account); attributing the throttle
  event to a real operator would move the presence oracle from the
  response body into the audit log.

`auth_events_audit` is the auth-only audit surface and is itself
append-only at the grant shape (UPDATE + DELETE revoked from
`service_role` and `forge_admin`); the absence of the per-tenant
chain row does not weaken append-only retention. Cross-table forensic
review uses `auth_events_audit` directly for these events.

## Compile-Time Gate Documentation (L-2)

`lib/admin/admin_routes.dart` near line 345 must include a comment
block stating the demo fallback is reachable only when `_kAdminDemoAuth ==
true` (a compile-time const evaluated from `--dart-define=ADMIN_DEMO_AUTH`),
default `false`. Production builds **must** ship without this define or
with `false`. Reference release-build CI assertion (HARD-E owns the CI
side).

## Out of Scope

- Tenant-wide lockout (e.g., suspending a whole operator) — manual ops.
- Detection of credential-stuffing patterns across operators — Phase 12.
- Rate-limit tuning UI — operator self-service is post-launch.
- IP-allow-list per tenant — post-launch.

## Test Surface

- Repository tests for `AuthLoginAttemptsRepository` (insert, count window,
  reset on success, RLS filter).
- Route tests:
  - 5 failures → 6th returns 423; 7th still 423 within window.
  - Success after lockout window → counter reset.
  - 3 TOTP failures → 4th returns 429; new challenge resets.
  - 10 password resets in 24h → 11th returns 429.
- Audit-event coverage tests assert each new event type is written and
  contains required payload fields (use `indexWhere` pattern from HARD-H,
  not `tx.parameters.last`).
- `dart analyze --fatal-infos`.

## Codex Acceptance

- [ ] Migration adds `auth_login_attempts` with RLS-ready schema, indexes leading with `operator_id` where present.
- [ ] Login route enforces 5-failure / 15-min lockout returning 423.
- [ ] MFA-confirm enforces 3-retry cap returning 429 with `Retry-After`.
- [ ] Password-reset enforces 10/24h cap returning 429.
- [ ] All four new audit events emit with full payload.
- [ ] `auth.service_principal_issued` audit row contains `claims_hash`.
- [ ] `admin.feature_flag_toggled` audit row carries optional `reason`.
- [ ] `admin_routes.dart:345` documents compile-time gate.
- [ ] No raw password / email / TOTP secret in any audit row (test asserts).
- [ ] All tests pass; `dart analyze --fatal-infos` clean.
