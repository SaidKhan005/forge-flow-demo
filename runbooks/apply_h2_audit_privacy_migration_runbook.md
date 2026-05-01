# Apply h2 Audit-Privacy Migration Runbook

Version: 1.0 (2026-05-01)
Owner: F&F super_admin operations
Source authority:
- `db/migrations/202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`
- `docs/phases/phase_9/phase_9_auth_plan.md` (slice 9.0Σ.h2)
- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md` item 5
- `runbooks/phase_9_production1_migration_apply_runbook.md` (parent live-mutation gate)

This runbook documents the live apply of `202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`
(parcel B46) — the app-layer half of the audit-privacy gate that complements
the column-level GRANT split landed in 9.0Σ.h.

## Migration Surface

Additive-only. Three operations, all idempotent on re-run:

1. Insert `admin.audit_privacy.read` into `public.permission_keys`
   (`requires_mfa = true`, `frozen = true`).
2. Grant `admin.audit_privacy.read` to seeded F&F-internal roles
   (`super_admin`, `ff_support`) via `public.role_permissions`.
3. `GRANT audit_privacy TO service_role` so the proxy's runtime
   connection can `SET LOCAL ROLE audit_privacy` on the documented
   audit-privacy access path.

No schema changes. No table/column drops. No data deletes. Re-running
re-emits `INSERT 0 0` / `INSERT 0 0` and a no-op `DO` block.

## Preflight (name-only)

| Check | Command | Status |
|---|---|---|
| psql binary | `Get-Command psql` | PG 16 client present |
| Migration file | `Test-Path db/migrations/202604280014_*.sql` | Present |
| Phase 9 plan doc | `Test-Path docs/phases/phase_9/phase_9_auth_plan.md` | Present |
| Staging env names | `scripts/postgres_staging_preflight.ps1` | exit 0; `POSTGRES_URL`, `POSTGRES_ADMIN_URL` PRESENT |
| Production1 env names | `[Environment]::GetEnvironmentVariable('POSTGRES_PRODUCTION_ADMIN_URL')` | PRESENT |

## Apply Order

Single file, single transaction. Idempotent re-runs are safe.

```powershell
. scripts/use_forge_flow_secrets.ps1
scripts/postgres_staging_preflight.ps1   # exit 0 = OK to proceed

# Staging
psql --single-transaction -v ON_ERROR_STOP=1 `
  -f db/migrations/202604280014_phase_9_0sigma_h2_audit_privacy_role.sql `
  "$env:POSTGRES_ADMIN_URL"

# Production1 (only after 24h staging soak + explicit approval)
psql --single-transaction -v ON_ERROR_STOP=1 `
  -f db/migrations/202604280014_phase_9_0sigma_h2_audit_privacy_role.sql `
  "$env:POSTGRES_PRODUCTION_ADMIN_URL"
```

## Verification Queries

Run each after every apply (staging first; Production1 after soak).

```sql
-- Schema probes (no row data)
\d+ permission_keys
\d+ role_permissions

-- Catalog row presence
select key, category, requires_mfa, frozen
  from public.permission_keys
 where key = 'admin.audit_privacy.read';

-- Default grant presence (must be exactly super_admin + ff_support)
select r.role_key, rp.effect
  from public.role_permissions rp
  join public.roles r on r.role_id = rp.role_id
 where rp.permission_key = 'admin.audit_privacy.read'
 order by r.role_key;

-- Role-membership grant (audit_privacy reachable from service_role)
select 'GRANT_PRESENT'
  from pg_catalog.pg_auth_members am
  join pg_catalog.pg_roles r on r.oid = am.roleid
  join pg_catalog.pg_roles m on m.oid = am.member
 where r.rolname = 'audit_privacy'
   and m.rolname = 'service_role';

-- Role assumption smoke (rolled back; proves SET LOCAL ROLE works)
begin;
  set local role audit_privacy;
  select current_user;       -- expect: audit_privacy
rollback;

-- End-to-end probe write (rolled back; proves audit_privacy can read
-- encrypted columns on rows the operator scope admits)
begin;
  select set_config('app.operator_id', '<staging-test-operator>', true);
  insert into public.advisor_conversation_log (
    operator_id, location_id, conversation_id, turn_index, role,
    content_encrypted, content_iv, content_key_ref, content_hash,
    surface, usage_class
  )
  values (
    '<staging-test-operator>'::uuid,
    '<staging-test-location>'::uuid,
    gen_random_uuid(), 0, 'system',
    decode('00','hex'), decode('00','hex'),
    'h2-probe-key-ref', repeat('0', 64),
    'h2-probe', 'probe'
  );
  set local role audit_privacy;
  select count(*),
         count(*) filter (where octet_length(content_encrypted) is not null)
    from public.advisor_conversation_log
   where surface = 'h2-probe';
  -- expect: (1, 1)
rollback;
```

Proxy smoke (route is live and auth-gated):

```powershell
# Expect 401 on /v1/usage-smoke without a bearer token (route alive,
# auth enforced). Expect 200 {"status":"ok"} on /readyz.
Invoke-WebRequest "$env:STAGING_PROXY_BASE/v1/usage-smoke" -UseBasicParsing
Invoke-WebRequest "$env:STAGING_PROXY_BASE/readyz" -UseBasicParsing
```

## Rollback Plan

The migration is purely additive and there is no destructive step. A
rollback would only be required if a downstream consumer rejects the
new key shape or the role-membership grant produces an unexpected
side effect. Pre-emptive rollback is **not** the recommended posture
for a re-runnable additive migration; prefer forward-fix.

If forward-fix is impossible, the targeted reverse is:

```sql
-- Caveat: only safe if NO production session has yet executed
-- SET LOCAL ROLE audit_privacy via service_role. Confirm via
-- audit_logs / proxy logs first.
begin;
  revoke audit_privacy from service_role;

  delete from public.role_permissions
   where permission_key = 'admin.audit_privacy.read';

  delete from public.permission_keys
   where key = 'admin.audit_privacy.read';
commit;
```

Operator-defined custom grants of `admin.audit_privacy.read` (added
post-launch via 9.6's role-management surface) MUST be enumerated
before the `delete from public.role_permissions` runs, otherwise the
rollback removes operator-level grants that the migration did not
create. The `ON DELETE RESTRICT` FK from `role_permissions` to
`permission_keys` enforces ordering: grants before key.

## Live Apply Log

### Staging

| Field | Value |
|---|---|
| Target | `forge-flow-staging-pg` (Azure Flexible Server, `Canada Central`, PG 16) |
| Database | `forgeflow` |
| Connection | `$env:POSTGRES_ADMIN_URL` (admin role; never printed) |
| Apply start | `2026-05-01T05:24:26.4618162-02:30` |
| Apply end | `2026-05-01T05:24:27.7784395-02:30` |
| Apply exit | `0` |
| Inserts (first run) | `INSERT 0 1` (permission_keys) + `INSERT 0 2` (role_permissions) + `DO` |
| Idempotency re-run | `INSERT 0 0` / `INSERT 0 0` / `DO`, exit `0` |

Verifications (all green):

- `permission_keys` row: `admin.audit_privacy.read | admin | t | t`.
- `role_permissions` grants: `ff_support | allow`, `super_admin | allow`.
- Role-membership probe: returned `GRANT_PRESENT`.
- Role-assumption probe: `set local role audit_privacy` →
  `current_user = audit_privacy`, rolled back.
- End-to-end probe (rolled back): `(audit_privacy_select_count = 1,
  audit_privacy_can_read_encrypted = 1)` for the probe row marked
  `surface = 'h2-probe'`.
- Schema diff vs pre-apply: no structural diff; table definitions for
  `permission_keys` and `role_permissions` unchanged. Only data and
  `pg_auth_members` row added.
- `\d+ permission_keys` and `\d+ role_permissions` confirmed unchanged
  column / index / FK / policy / trigger shape.

Proxy smoke (`https://forge-flow-staging-proxy-rf7nosnoka-pd.a.run.app`):

- `GET /readyz` → `200 {"status":"ok"}`.
- `GET /v1/usage-smoke` → `401` (route alive, auth-gated as expected
  without a bearer token).

Soak window: 24h beginning at `2026-05-01T05:24:27-02:30`. Soak gate
clears no earlier than `2026-05-02T05:24:27-02:30`. During soak,
monitor:

- `audit_logs` for any `actor_kind = 'service_principal'` or
  `actor_user_id` row whose `event` mentions `audit_privacy` —
  expect zero until the audit-read code path lands.
- Proxy error rate dashboard: Cloud Run `forge-flow-staging-proxy`
  service health (request rate, p95 latency, 5xx rate). Dashboard
  URL: TBD — Cloud Run console for project `forge-flow-staging`,
  region `northamerica-northeast2`, service
  `forge-flow-staging-proxy`.

### Production1

| Field | Value |
|---|---|
| Target | `forge-flow-production1-pg` (Azure Flexible Server, `Canada Central`, PG 16) |
| Database | `forgeflow` |
| Connection | `$env:POSTGRES_PRODUCTION_ADMIN_URL` (admin role; never printed) |
| Apply gate | `2026-05-02T05:24:27-02:30` (24h soak from staging apply) |
| Apply start | _pending_ |
| Apply end | _pending_ |
| Apply exit | _pending_ |
| Verifications | _pending_ |

Production1 apply requires explicit chat approval after the soak gate
clears AND the staging soak has emitted no proxy 5xx, no
`audit_privacy`-tagged audit anomalies, and no schema drift on the
parent runbook check list.

## Out of Scope

- Audit-read repository code path (lands in a later 9.x slice; this
  migration only seats the runtime gate the code path will check).
- 9.6 role-management surface that lets operators custom-grant the
  key on operator-scoped roles.
- Cloud Armor enforcement flip (separate gate; see
  `runbooks/phase_9_production1_migration_apply_runbook.md`).
