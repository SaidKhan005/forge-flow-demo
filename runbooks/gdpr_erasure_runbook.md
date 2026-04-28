# GDPR Erasure Runbook

Version: 1.0 (2026-04-27)
Owner: F&F super_admin operations
Source contract: `lib/services/auth/gdpr_erasure_service.dart`
(`ErasureRedactionTemplate.payloadFor`)

This runbook is the operational procedure for executing a GDPR
right-to-erasure (Art. 17) request against Forge & Flow user data.

The procedure is **redact-don't-delete**. Per the Phase 9 decision
lock + Art. 17(3) operational record carve-out, a small set of audit
columns are preserved. Everything else is redacted.

This runbook is canonical. The framework code matches the runbook;
the runbook is what gets executed when a request comes in.

## When to use this runbook

A user has submitted a verified erasure request (or an operator has
requested erasure on their behalf with the user's consent). The
target user has already been **soft-deleted** through the standard
lifecycle path (`UserStatus.deleted`); this runbook does not
soft-delete on its own.

Do NOT use this runbook for:

- Data-retention purges driven by retention policy (separate
  operational runbook; preserves much less).
- Legal-hold release scenarios (manual SQL with legal sign-off).
- Operator-driven user removal that is not erasure (use the standard
  `UserLifecycleAction.softDelete` path).

## Prerequisites

The procedure refuses to start unless every prerequisite is met. The
proxy enforces these checks programmatically; the runbook lists them
so an executor can verify before running:

1. **Soft-delete already applied.** `users.status = 'deleted'`
   AND `users.deleted_at IS NOT NULL`. If not, run the standard
   soft-delete path first and wait for the system to confirm.
2. **Two F&F super_admin approvers (paired-approval).** Both must
   hold the `super_admin` role at the time of approval. Operator
   owners / `ff_support` cannot approve. The requester themselves
   cannot approve (no-self-approval). Each approver counts only
   once (no double-counting).
3. **Step-up MFA fresh on both approvers.** `auth_time` within the
   locked 5-minute freshness window for each approver at the moment
   they submit the approval. Stale auth → re-prompt.
4. **No active sessions for the target user.** Run a force-logout-all
   on the target before erasure so live sessions terminate cleanly.
5. **Documented reason.** The `ErasureRequest.reason` field carries
   a human-readable justification (e.g. `"DSAR-2026-04-27 from
   user@example.test, verified via signed identity letter"`) — must
   be non-blank.

## Execution checklist

1. Open the GDPR Erasure surface in the F&F admin console.
2. Verify the target user's status is `deleted` and that
   force-logout-all has run.
3. Submit the request with a documented reason.
4. Pair with a second F&F super_admin. Both submit step-up MFA + an
   approval. The system records the approval timestamps and the
   approving user_ids.
5. Confirm the proxy's pre-flight check returns "ready to execute."
6. Execute. The proxy runs the redaction in a single Postgres
   transaction (`OperatorScopedRepository.withSystem`,
   `app.bypass_rls_audit = 'system:gdpr.erasure_executed'`).
7. The proxy emits a `gdpr.erasure_executed` row in
   `auth_events_audit` with the redaction payload diff summary.
8. Confirm the dashboard reflects the execution. Notify legal/ops
   per your operator's standard SLA.

## Redaction map (matches `ErasureRedactionTemplate`)

| Table.column | Action | Path |
| --- | --- | --- |
| `users.email` | Replace with `redacted-{user_id}@deleted.local` | App-runtime (`UsersRepository.redactPii`) |
| `users.firebase_uid_retain` | Directive flag `true`. The `users.firebase_uid` column is intentionally **preserved** (link integrity to Firebase). | n/a |
| `users.first_name` | Set to NULL | App-runtime (`UsersRepository.redactPii`) |
| `users.last_name` | Set to NULL | App-runtime (`UsersRepository.redactPii`) |
| `users.display_name` | Set to NULL | App-runtime (`UsersRepository.redactPii`) |
| `users.avatar_url` | Set to NULL | App-runtime (`UsersRepository.redactPii`) |
| `auth_events_audit.ip` | Set to NULL | **Break-glass DBA** (see below) |
| `auth_events_audit.user_agent` | Set to NULL | **Break-glass DBA** (see below) |
| `auth_events_audit.event_payload` | Strip `email`, `first_name`, `last_name`, `display_name`, `avatar_url` keys via `jsonb` `-` operator | **Break-glass DBA** (see below) |
| `auth_sessions.ip` | Set to NULL | App-runtime (`AuthSessionsRepository`) |
| `auth_sessions.user_agent` | Set to NULL | App-runtime (`AuthSessionsRepository`) |
| `password_history.cleared` | Directive flag `true`. DELETE every `password_history` row for the user. | App-runtime (`PasswordHistoryRepository.clearForUser`) |
| `mfa_factors.factor_metadata` | Strip the AAGUID key from the JSONB value | App-runtime (`MfaFactorsRepository`) |

`auth_events_audit` rows are **append-only at the grant shape** —
`202604260001_auth_rls_service_role_grants.sql` REVOKEs `UPDATE` and
`DELETE` from both `service_role` and `forge_admin`. The proxy runtime
physically cannot mutate these rows. Audit-log redaction therefore
requires the break-glass DBA path documented immediately below.

## Break-glass: redacting audit log fields

GDPR Art. 17 requires erasing IP / user-agent / personal-name keys
from audit rows targeting (or actored by) the user. Because audit
table grants intentionally block UPDATE, this is a one-shot DBA
procedure rather than a proxy operation.

Audit-fix 2026-04-27 — the break-glass procedure exists separately
from the runtime erasure flow so the append-only posture stays the
default. Do not use this procedure for routine cleanup; do not grant
broader UPDATE permissions to `service_role` in pursuit of "easier"
operation.

### Authority required

- DBA-level Postgres access (the `postgres` superuser or a role with
  authority to GRANT / REVOKE on `auth_events_audit`).
- Written confirmation from BOTH paired-approval super_admins that
  the soft-delete + paired-approval prerequisites have been met for
  the target user. The DBA records the two approver user_ids in the
  break-glass audit row (see below).

### One-shot DBA procedure

Run this in a single transaction, with the target `<user_id>`
substituted in. The GRANT/REVOKE wrapper guarantees the elevated
privilege exists ONLY for the duration of the transaction.

```sql
begin;

-- 1. Temporarily allow forge_admin to UPDATE the audit table.
grant update on public.auth_events_audit to forge_admin;

-- 2. Switch into forge_admin so the SET LOCAL bypass + the new
--    UPDATE grant both apply. Record an audit reason for the
--    BYPASSRLS event.
set local role forge_admin;
set local "app.bypass_rls_audit" = 'system:gdpr.erasure_executed';

-- 3. Redact the rows. SQL is identical to
--    AuthEventsAuditRepository.breakGlassRedactionSql so code +
--    runbook agree byte-for-byte.
update auth_events_audit
   set ip = null, user_agent = null,
       event_payload = (event_payload - 'email' - 'first_name'
         - 'last_name' - 'display_name' - 'avatar_url')
 where target_user_id = '<user_id>'::uuid
    or actor_user_id  = '<user_id>'::uuid;

-- 4. Reset to the default role and revoke the temporary grant
--    so the append-only posture is restored before commit.
reset role;
revoke update on public.auth_events_audit from forge_admin;

-- 5. Insert a one-row audit trail recording the break-glass run.
--    This row is INSERT-only (allowed under the append-only
--    grants), so it captures the redaction without weakening the
--    table's posture.
insert into auth_events_audit (
  actor_user_id, target_user_id, operator_id, location_id,
  event_type, event_payload
) values (
  '<dba_user_id>'::uuid,
  '<user_id>'::uuid,
  '<target_operator_id>'::uuid,
  '<target_location_id>'::uuid,
  'gdpr.audit_log_redacted_break_glass',
  jsonb_build_object(
    'runbook_version', '1.0',
    'first_approver',  '<approver_a_user_id>',
    'second_approver', '<approver_b_user_id>',
    'fields_cleared',  jsonb_build_array(
      'ip', 'user_agent',
      'event_payload.email', 'event_payload.first_name',
      'event_payload.last_name', 'event_payload.display_name',
      'event_payload.avatar_url'
    )
  )
);

commit;
```

If anything inside the transaction fails, ROLLBACK restores the
prior state (no UPDATE applied, the temporary grant is gone). Do
not COMMIT a partial run.

### Verification

After commit, run the verification queries in the [Verification
queries](#verification-queries) section below as the `forge_admin`
role. The expected counts apply equally before and after this
break-glass step.

## Preserved under Art. 17(3)

Per GDPR Art. 17(3) operational-record carve-out, the following
fields stay:

- `auth_events_audit.event_id`
- `auth_events_audit.actor_user_id`
- `auth_events_audit.event_type`
- `auth_events_audit.occurred_at`
- `users.user_id` (primary key — required for join integrity)
- `users.created_at`
- `users.firebase_uid` (Firebase still retains the user record;
  `users.firebase_uid` keeps the link so audit rows referencing it
  remain joinable)
- `users.deleted_at` (was set on soft-delete)
- `users.status` (`'deleted'`)

The justification: these fields make it possible to answer "what
happened in the system" without identifying the natural person. They
are kept for security, audit, dispute, and regulatory-response
purposes. The redaction map above ensures the natural-person
identifiers are gone.

## Rollback

**Erasure is irreversible.** Once the proxy commits the redaction
transaction:

- The redacted columns are gone — they are not soft-redacted; the
  underlying values are overwritten.
- Firebase still has the user record with the redacted email; the
  proxy does NOT delete the Firebase user (link integrity).
- `password_history` rows for the user are gone; if the user later
  needs to use the Forge & Flow product again they create a fresh
  account.

If a hard-delete (full row removal) is required for a legal-hold
release, that is a separate procedure outside this runbook. It
requires:

- Legal team sign-off in writing.
- Manual SQL run by an authorized DB operator with `forge_admin` +
  audit reason annotation.
- Explicit retention-policy review; once Cloud Foundation flips
  cloud-foundation RLS (B10), the manual hard-delete must include
  every cross-table cascade.

## Audit

The proxy writes one `auth_events_audit` row per erasure execution:

- `event_type = 'gdpr.erasure_executed'`
- `actor_user_id` = first approver
- `target_user_id` = the erased user
- `event_payload` = `ErasureRedactionTemplate.payloadFor(...)` output
  (the same shape framework tests assert on, so audit + framework
  are byte-identical)
- `occurred_at` = transaction commit time

Plus the standard `BruteForceTelemetrySink.brute_force_event_audit`
emission via the Phase 9.5 audit pipeline so the row joins the
operator's existing security-event review queue.

## Verification queries

Run these as a F&F super_admin connection AFTER execution to confirm
the redaction landed:

```sql
-- All natural-person identifiers stripped from the user row.
select email, first_name, last_name, display_name
  from users where user_id = '<target>';
-- Expect: email = 'redacted-<target>@deleted.local'; others null.

-- Audit rows preserved but stripped.
select count(*) as audit_count,
       count(*) filter (where ip is not null) as with_ip,
       count(*) filter (where user_agent is not null) as with_ua
  from auth_events_audit
 where target_user_id = '<target>' or actor_user_id = '<target>';
-- Expect: audit_count > 0; with_ip = 0; with_ua = 0.

-- Password history cleared.
select count(*) from password_history where user_id = '<target>';
-- Expect: 0.

-- A gdpr.erasure_executed event was written.
select event_id, occurred_at
  from auth_events_audit
 where target_user_id = '<target>'
   and event_type = 'gdpr.erasure_executed'
 order by occurred_at desc
 limit 1;
-- Expect: exactly one row, very recent.
```

## Source-of-truth boundaries

- **Framework decision logic:** `lib/auth/user_lifecycle.dart`
  (`UserLifecycleStateMachine`) + `lib/services/auth/gdpr_erasure_service.dart`
  (`GdprErasureService`, `ErasureRedactionTemplate`).
- **Persistence path (app-runtime):**
  `lib/infrastructure/persistence/postgres/repositories/users_repository.dart`
  (`redactPii`), `password_history_repository.dart` (`clearForUser`),
  `auth_sessions_repository.dart` (per-row IP / UA cleanup),
  `mfa_factors_repository.dart` (factor-metadata strip).
- **Persistence path (DBA break-glass):** Manual SQL above for
  `auth_events_audit` only — the runtime
  `AuthEventsAuditRepository.redactForUser` intentionally throws a
  `StateError` pointing at this runbook to prevent accidental
  proxy invocation. The exact SQL the DBA runs is also exported as
  `AuthEventsAuditRepository.breakGlassRedactionSql` so code and
  runbook agree byte-for-byte.
- **Proxy orchestration:** lands together with the
  `/v1/admin/auth/users/{user_id}/erase-pii` endpoint in the
  user-lifecycle proxy slice.
- **Decision lock:** `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md`
  (`GDPR erasure` row).

When this runbook and any of the above disagree, the framework
code wins. Update the runbook to match.
