# Cutover 0 Pre-Flight Runbook

Updated: 2026-05-07.

Purpose: govern the read-only `cutover.0` pre-flight gate that
must pass before any production cutover work begins. Pairs the
human checklist in
`docs/phases/phase_production_cutover/phase_production_cutover_plan.md`
with the executable harness at
`tool/cutover/preflight_smoke.dart`.

## When to Run

Run this gate *exactly once* per Production1 cutover attempt, and
*before* any other cutover work. The gate's job is to surface
configuration drift between staging-known-good and Production1
*before* corpus load, operator onboarding, or any cost-bearing
slice can begin.

Trigger conditions:

- Production1 setup has just completed (Cloud Run proxy, Secret
  Manager namespace, VPC/static egress, DNS, Firebase apps,
  firewall allowlist all done).
- The lex-cutoff migration set in
  `runbooks/phase_9_production1_migration_apply_runbook.md` has
  applied successfully.
- Operator has explicitly authorized the cutover lane to advance.

Stop with `BLOCKED` if any trigger condition is missing.

## Live-Mutation Gate

Before running:

- [ ] Confirm this runbook was reviewed in the current session.
- [ ] Confirm the exact Production1 hostname/database target by name.
- [ ] Confirm the operator approving the run; do not run unless the
      operator explicitly says "begin pre-flight".
- [ ] Confirm `flutter analyze --fatal-infos` passes on the running
      commit.
- [ ] Confirm `dart run tool/rls_policy_lint.dart` passes.
- [ ] Confirm `dart run tool/postgres_import_lint.dart` passes.
- [ ] Confirm `dart run tool/index_leading_column_lint.dart` passes.
- [ ] Confirm `dart run tool/migration_cutoff_lint.dart` passes.
- [ ] Confirm `dart run tool/permission_key_lint.dart` passes.
- [ ] Confirm no secrets, DSNs, tokens, or passwords will be pasted
      into chat or docs.

Stop with `BLOCKED` if any item is missing. The harness itself is
read-only against the target DB (one fixture INSERT inside a
`BEGIN; … ROLLBACK` for the RLS isolation check; nothing persists),
but the cutover-lane discipline is the operator's authority gate.

## Plan Step (Always Required)

Run plan-only first to confirm flag set:

```powershell
dart run tool/cutover/preflight_smoke.dart
```

The output enumerates which checks will run. Confirm the planned
list matches the cutover.0 checklist before proceeding.

## Run Step

Full invocation. Replace placeholders with real values; never paste
the resolved DSN into chat or commits.

```powershell
dart run tool/cutover/preflight_smoke.dart `
  --run `
  --connection-string="<production1 DSN>" `
  --report-out=build/cutover/preflight_smoke.json `
  --label=production1_first_preflight `
  --include-rls-isolation `
  --rls-operator-a=<uuid> `
  --rls-operator-b=<uuid> `
  --rls-location-a=<uuid> `
  --rls-location-b=<uuid> `
  --include-firewall-probe `
  --dns-hostname=app.forgeflow.app `
  --dns-hostname=admin.forgeflow.app `
  --proxy-base-uri=https://proxy.forgeflow.app `
  --gcp-project-id=forge-flow-production1
```

If the harness is run from a workstation (not the production deploy
account), pass `--skip-secrets`. The Secret Manager probe will
report yellow; the operator must perform that verification manually
via `gcloud secrets versions access` from the deploy account before
calling the gate green. Pass `--skip-health-endpoint` from a
workstation that cannot reach the Cloud Run egress directly.

### Required Environment Variables

The harness reads two env vars when the corresponding flag is not
set on the command line:

| Env Var | Used By | Notes |
|---|---|---|
| `PROXY_BASE_URI` | `health_endpoint` smoke | Falls back to this when `--proxy-base-uri` is omitted. `/health` is appended automatically. |
| `GOOGLE_CLOUD_PROJECT` (or `GCP_PROJECT`) | `secret_manager_reachability` smoke | Falls back to this when `--gcp-project-id` is omitted. Required when the Secret Manager probe is not skipped. |

Authentication for the live Secret Manager read is handled by
Application Default Credentials. From a Cloud Run / Compute Engine
host, the GCE metadata server provides the access token
automatically. From a workstation, set `GOOGLE_APPLICATION_CREDENTIALS`
to a service-account key file (or use `gcloud auth application-default
login`). The CLI is a one-shot harness — failures bubble up as red
verdicts, never blocking exceptions.

## Reading the Report

The report has two surfaces:

- **Human stdout table**: one row per check + an overall verdict.
- **JSON report at `--report-out`**: machine-readable; mirrors
  `tool/perf_gate/staging_console_probe.dart` shape.

Verdict layers (in order of precedence):

1. **`overall_status: red`** — at least one check is red. The
   harness exits 1. Halt cutover. Find the offending check below.
2. **`overall_status: yellow`** — a check is yellow. Default posture
   is non-blocking; cutover may proceed if the operator explicitly
   accepts the yellow. With `--require-all`, any yellow flips to red
   and exits 1.
3. **`overall_status: green`** — all checks green. Proceed to
   `cutover.1`.

Each check that fails carries a stable
`cutover_preflight_red_<reason>` token in its `message` so the
operator can grep this runbook directly to the escalation row.

## Escalation by Red Reason

### `cutover_preflight_red_schema_presence`

What it means: at least one of the expected tables, RLS-enabled
tables, or tenant-leading indexes is missing from Production1.

Escalation:

- Read `runbooks/phase_9_production1_migration_apply_runbook.md`
  Apply History; confirm the latest cutoff includes the missing
  table's source migration.
- If the migration is in the cutoff but the table is missing,
  apply the gap migrations under that runbook's Live-Mutation
  Gate. Re-run pre-flight.
- If the table is intentionally not in production yet, narrow the
  expected-table set via `--expect-table=<name>` overrides and
  re-run. Document the deviation in the cutover.0 result file.

### `cutover_preflight_red_schema_presence_query_failed`

What it means: the catalog query itself errored. Likely a
permission issue (the runtime role lacks SELECT on `pg_tables` /
`information_schema.tables` / `pg_indexes`) or a connection drop.

Escalation:

- Re-run with `--include-firewall-probe` to isolate connectivity
  from authorization.
- If connectivity is green but the query still fails, switch the
  DSN to a `forge_admin` role (BYPASSRLS) for the gate run and
  re-test. The runtime role's grants are then a separate cleanup.

### `cutover_preflight_red_rls_isolation`

What it means: tenant B saw rows belonging to tenant A under the
fixture table. RLS is broken on Production1.

Escalation:

- Halt cutover immediately. Run
  `dart run tool/rls_policy_lint.dart` and review every red
  policy.
- Inspect the fixture table's policies via:
  ```sql
  select policyname, cmd, qual, with_check
  from pg_policies
  where tablename = '<fixture-table>';
  ```
- Confirm policies use the wrapper functions (e.g.
  `app_current_operator()`), not bare `current_setting()`.
- File a hardening migration to repair the policy; apply it
  under the migration apply runbook's Live-Mutation Gate.

### `cutover_preflight_red_rls_isolation_query_failed`

What it means: the RLS isolation check could not complete. The
fixture table may not exist, or the runtime role may lack INSERT /
SELECT on it.

Escalation:

- Confirm the fixture table is present (default: `event_outbox`).
- If a different RLS-enabled minimal-FK table is preferred, pass
  `--rls-fixture-table=<name>`.
- Verify role grants on the fixture table match the production
  proxy expectation.

### `cutover_preflight_red_firewall_reachability`

What it means: the TCP probe to the Postgres host failed. The
caller's IP is NOT on the firewall allowlist, or the host is
unreachable.

Escalation:

- Confirm the Production1 firewall rule list under Azure portal:
  `forge-flow-production1-pg-cmk` → Networking → Firewall rules.
  The Cloud Run static egress NAT IP must be allowlisted; nothing
  else should be.
- If the harness is being run from a workstation, that's expected
  — temporarily allowlist the workstation IP, run the gate, and
  remove the allowlist entry afterward.
- Verify Private Endpoint / VNet integration is correctly bound
  if Private Link is in use.

### `cutover_preflight_red_secret_manager_reachability`

What it means: at least one production secret is unreadable by the
configured GCP service account.

Escalation:

- Run `gcloud secrets list --project=forge-flow-production1` to
  confirm the secret exists in the right namespace.
- Run `gcloud secrets versions access latest
  --secret=<name> --project=forge-flow-production1` to confirm
  the calling identity can read it.
- If the harness is being run from a workstation without
  production GCP credentials, pass `--skip-secrets` and perform
  this verification manually from the deploy account.

### `cutover_preflight_red_dns_resolution`

What it means: at least one configured production hostname does
not resolve to any A/AAAA record.

Escalation:

- Confirm the production DNS zone has the hostname mapped to the
  production Cloud Run service / load balancer / serverless NEG.
- Confirm the rollback DNS path back to staging is documented in
  the cutover.0 result file (Hard Promise: every traffic switch
  has a documented "point back at staging" path).
- If using a managed DNS provider, confirm the record propagation
  TTL has elapsed since the most recent change.

### `cutover_preflight_red_age_cypher_match`

What it means: the trivial `MATCH (n) RETURN n LIMIT 1` Cypher
traversal against the named AGE graph (default `forge_graph`)
failed. The two common causes are:

1. The `age` extension is not installed on Production1.
2. The named graph does not exist (the bootstrap migration that
   creates the graph never ran).

Escalation:

- Confirm `CREATE EXTENSION IF NOT EXISTS age` has been applied
  by inspecting `pg_extension` from a `psql` session.
- Confirm the bootstrap migration that calls
  `ag_catalog.create_graph('forge_graph')` is in the applied set
  for the production cutoff.
- If a non-default graph name is in use, re-run with
  `--age-graph-name=<name>`.

### `cutover_preflight_red_pgvector_cosine`

What it means: the `'[1,0,0]'::vector <=> '[0,1,0]'::vector`
probe failed, returned a non-numeric result, or the distance was
outside the documented `[0, 2]` range.

Escalation:

- Confirm `CREATE EXTENSION IF NOT EXISTS vector` has been
  applied. The Azure Postgres Flexible Server flavor must enable
  pgvector in `azure.extensions` before the extension can be
  created.
- If the cosine operator is missing entirely, the bootstrap
  migration may have applied an older `vector` package — confirm
  the version is at least 0.5.0.
- An out-of-range distance is extremely unusual; capture the JSON
  report and escalate to the data platform on-call.

### `cutover_preflight_red_health_endpoint`

What it means: the proxy `/health` endpoint did not return HTTP
200 + the expected body marker. Common causes:

1. The Cloud Run revision has not been promoted to the production
   service yet, so DNS points at a non-existent revision.
2. The proxy is up but cannot reach Postgres or another
   dependency, so `/health` returns 5xx.
3. A non-proxy service is answering on the production hostname.

Escalation:

- Hit the URL directly with `curl` and inspect the response body.
- If 5xx, follow `runbooks/proxy_health_check_runbook.md` for the
  dependency-by-dependency diagnostic ladder.
- If 200 but the body marker is absent, confirm the deployed
  revision is built from this repository (a forked or stale build
  may not emit the marker).
- If the harness was run from a workstation that cannot reach the
  Cloud Run egress, re-run with `--skip-health-endpoint` and
  perform the verification from a host with network egress.

### `cutover_preflight_red_partman_cron_active`

What it means: either `pg_partman` / `pg_cron` is missing from
`pg_extension`, or `cron.job` has zero rows. Either failure mode
silently breaks audit-chain anchoring and per-operator partition
maintenance.

Escalation:

- Confirm both extensions are listed under `azure.extensions` for
  the Production1 Flexible Server. Re-apply the bootstrap
  migrations if missing.
- Inspect `cron.job`:
  ```sql
  select jobname, schedule, command, active from cron.job;
  ```
  Confirm at least the audit-chain anchor job is present and
  active. If absent, re-run
  `db/migrations/<audit-anchor-bootstrap>.sql` and verify the
  scheduling INSERT executed without skipping.

### `cutover_preflight_red_partman_cron_active_query_failed`

What it means: the catalog or `cron.job` query itself errored.
Likely a permissions issue (the runtime role lacks SELECT on
`cron.job`) or `pg_cron` is not installed in the database the DSN
points to.

Escalation:

- Confirm `pg_cron` is loaded in the *database* the DSN targets.
  Azure-managed `pg_cron` runs in a single management database
  per server (default `postgres`); the application database must
  have its own grants on the cron objects.
- Re-run with a `forge_admin` role if the runtime role is missing
  grants; file a follow-up to repair the runtime role's access.

## Output

On green, save the following to the cutover.0 result file
`docs/phases/phase_production_cutover/phase_production_cutover_0_preflight_result.md`:

- The harness JSON report path.
- The label passed via `--label`.
- The operator who approved.
- The hostnames resolved.
- The fixture table used.
- An explicit "go" verdict + initials.

On red, do NOT advance to `cutover.1`. Record the red reasons + the
escalation actions taken in the result file, then re-run the gate
once the underlying issue is resolved.

## Backout

The harness is read-only; there is nothing to back out. The single
fixture INSERT inside the RLS isolation check ROLLBACKS at the end
of the check, so no row persists.

## Apply History

This runbook ships ready-to-use; it has no Apply History rows of
its own. Cutover.0 result files (per cutover attempt) are the
primary record of when this gate ran and what it returned.
