# Phase 9.0 - Auth Schema Live-Apply Result

**Status:** APPLIED.
**Generated:** 2026-04-26.
**Slice type:** closeout-with-blockers.

`db/migrations/202604250008_auth_schema_foundation.sql` was applied to
both live targets authorized for 9.0:

- Staging: `forge-flow-staging-pg.postgres.database.azure.com`, database
  `forgeflow`, user `ffadmin`
- Production1: `forge-flow-production1-pg.postgres.database.azure.com`,
  database `forgeflow`, user `forgeadmin`

No connection strings, passwords, tokens, or full DSNs were printed.

## Preflight

| Required item | State |
| --- | --- |
| `psql` on PATH | PRESENT (`psql` 16.13) |
| Staging admin DSN | PRESENT from non-repo `$HOME/.forge_flow/forge_flow.secrets.ps1` |
| Production1 admin DSN | PRESENT from non-repo `$HOME/.forge_flow/forge_flow.secrets.ps1` |

The original Claude closeout run saw missing env names in its shell and
correctly stopped before mutation. Codex then re-ran the closeout in a shell
where `psql` was available and the non-repo unified secrets loader exposed the
staging and Production1 admin DSN env names.

## Target Safety

Before any migration was executed, Codex parsed and reported only sanitized
metadata:

| Target | Host | Database | User | Safety |
| --- | --- | --- | --- | --- |
| Staging | `forge-flow-staging-pg.postgres.database.azure.com` | `forgeflow` | `ffadmin` | PASS |
| Production1 | `forge-flow-production1-pg.postgres.database.azure.com` | `forgeflow` | `forgeadmin` | PASS |

## TLS Note

The first real connection attempt found that `psql` needed a local root CA
bundle for Azure Postgres `verify-full` TLS. Codex created a temporary
non-repo PEM bundle under `%TEMP%/forge_flow_pg_certs/` from the two Azure
Postgres roots Microsoft documents for `psql` clients:

- Microsoft RSA Root CA 2017
- DigiCert Global Root G2

`PGSSLROOTCERT` was set only for the apply/verification shell. Nothing was
written to the repo.

## Apply

Each target ran:

```powershell
psql --single-transaction -v ON_ERROR_STOP=1 `
  -f db/migrations/202604250008_auth_schema_foundation.sql <admin-dsn>
```

| Target | Result | Notes |
| --- | --- | --- |
| Staging | OK | 14 idempotency notices; no errors |
| Production1 | OK | 14 idempotency notices; no errors |

The first attempted `psql` invocation used the wrong argument order and did
not execute the migration file. The corrected run placed all `psql` options
before the DSN and completed successfully on both targets.

## Verification

Read-only verification SQL passed on both databases:

| Check | Staging | Production1 |
| --- | ---: | ---: |
| New auth tables present | 12 | 12 |
| `users` 9.0 extension columns | 16 | 16 |
| `operator_admins` 9.0 extension columns | 4 | 4 |
| RLS enabled on new auth tables | 12 | 12 |
| `permission_keys` seed count | 81 | 81 |
| Baseline seeded roles count | 6 | 6 |
| `user_roles_active_grant_idx` tenant-leading | true | true |
| `auth_events_audit_actor_occurred_idx` tenant-leading | true | true |
| `auth_events_audit_target_occurred_idx` tenant-leading | true | true |
| `auth_events_audit_global_occurred_idx` preserved | true | true |
| Auth-table `timestamp without time zone` columns | 0 | 0 |

## Local Test Posture

Local checks remained green:

- `dart analyze db/migrations test/advisor_proxy_test.dart
  lib/auth/permission_keys.dart` -> No issues found.
- `flutter test test/advisor_proxy_test.dart` -> 94/94 passed.

## Scope Check

- No operator data loaded.
- No Firebase call.
- No Anthropic or Voyage call.
- No Azure control-plane mutation.
- No repo secret file read.
- No secret values printed.
- No tracker update in this slice.
- No commit.

## Sequencing Note

9.0 auth schema is now physically present on staging and Production1. The
next Phase 9 slice can move to `9.1` Firebase Identity Platform setup + JWT
verifier wiring, subject to its human setup gate.
