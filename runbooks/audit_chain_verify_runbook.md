# Audit Chain Verify Runbook

Version: 1.0 (2026-04-28)
Owner: F&F super_admin operations + Cloud Run audit job operator
Source contracts:
- `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`
- `tool/audit_anchor/audit_anchor.dart`
  (`AuditAnchorOrchestrator`, `AuditChainHasher`)
- `phase_9_scalability_decisions_2026-04-27.md` item 13

This runbook is the operational procedure for anchoring and verifying
the SHA-256 hash-chained `public.audit_logs` table against the F&F
immutable Azure Blob anchor evidence. It is canonical: the framework
code matches the runbook; the runbook is what gets executed when
SOC 2 / forensic / dispute reconstruction needs to prove an
operator/day chain has not been tampered with retroactively.

## When to use this runbook

- **Daily anchor (automated):** the Cloud Run scheduled job runs
  `audit_anchor sweep` once per UTC day, after the prior UTC day has
  closed. The `sweep` mode resolves the operator-id list from
  `public.operators` (via `runAsSystem` with audit reason
  `audit_anchor.sweep`) and then dispatches the existing per-operator
  anchor logic, finding chains with no existing
  `audit_chain_anchors` row and writing the day's evidence to the
  immutable Blob container.
- **Manual rerun (operator-scoped):** an operator can run
  `audit_anchor anchor --operator-id=<uuid> [--operator-id=<uuid> ...]`
  to re-anchor a specific subset of operators (e.g. after a job pod
  crash leaves the daily firing partial, or to re-run a single
  operator after security review clears a chain).
- **On-demand verification:** SOC 2 audit, security forensic review,
  or a support escalation can require verifying that a specific
  `(operator_id, chain_date)` chain has not been retroactively
  mutated. Run `audit_anchor verify` manually.
- **Anchor failure triage:** the daily job exited non-zero. Walk the
  triage section below.

Do NOT use this runbook for:

- Mid-row redaction. `audit_logs` is append-only at the grant shape;
  redaction follows the break-glass procedure in the GDPR runbook
  (`runbooks/gdpr_erasure_runbook.md`) extended to `audit_logs` per
  the [Break-glass: redacting audit_logs](#break-glass-redacting-audit_logs)
  section below — both runbooks must agree.
- Retention purges. Partition drop is a separate DBA procedure; this
  runbook only verifies what is currently in the table + what was
  anchored on the day each chain closed.

## Prerequisites

The job refuses to start unless every prerequisite is met. Verify
before triggering a manual or out-of-band run:

1. **Azure Blob immutable container provisioned.** The audit anchor
   container has time-based retention enabled with a retention period
   that meets or exceeds the SOC 2 / Q9 7-year audit floor. The
   container is locked: no role can disable immutability without a
   policy change recorded in the F&F Azure tenant audit log. The
   container name is exposed to the Cloud Run job through the env var
   `AZURE_BLOB_AUDIT_CONTAINER` and the endpoint through
   `AZURE_BLOB_AUDIT_ENDPOINT` (names only — the value is resolved
   from the deployment runtime, never from this runbook).

2. **Cloud Run scheduled job configured.** The job runs at 23:55 UTC
   daily (cron: `55 23 * * *`, timezone `Etc/UTC`). The 23:55 firing
   sweeps every operator's chains whose `chain_date < as-of-utc`;
   the prior UTC day's chain rolls over at 00:00 UTC, so the 5-minute
   pre-rollover firing keeps the sweep aligned with the same UTC
   business date the chain trigger uses. The job + scheduler contract
   lives in
   `infrastructure/cloud_run/audit_anchor_job.yaml`; the deploy
   surface is `scripts/deploy_audit_anchor_job.ps1`. The job's
   managed identity has `Storage Blob Data Contributor` on the audit
   container and `audit_anchor_role` (a Postgres role with
   `service_role` inheritance, no DB-level write privileges beyond
   `audit_logs` INSERT and `audit_chain_anchors` INSERT).

3. **Postgres connectivity.** The job reads `POSTGRES_URL` from its
   env. Live Azure setup, container creation, and any mutation of
   the immutable container retention policy require human approval
   before execution per CLAUDE.md "no live Azure mutation in repo".

4. **Migration `202604280005_phase_9_0sigma_f_audit_logs.sql`
   applied.** Verify with:

   ```sql
   select 1 from information_schema.tables
    where table_schema = 'public'
      and table_name = 'audit_logs';
   ```

   Returns one row when the table exists. If the migration is not
   applied, neither the anchor job nor the verifier can run.

5. **`pg_partman` registered.** Verify with:

   ```sql
   select parent_table, control, partition_interval, premake
     from public.part_config
    where parent_table = 'public.audit_logs';
   ```

   Returns one row with `partition_interval = '1 day'` (or
   equivalent) and `premake >= 7`. If absent, re-run the migration;
   the registration is idempotent.

   Note: pg_partman is installed into the `public` schema on Azure
   DB Flexible Server (verified live 2026-04-26 on staging +
   Production1; matches `phase_11a_decision_register.md` Lock 2 and
   the verified pattern in
   `db/verification/202604250006_advisor_schema_hardening_audits.sql`).
   Do NOT query `partman.part_config` — that schema does not exist
   on the live hosts.

## Daily anchor procedure (automated)

The Cloud Run scheduled job runs the following at 23:55 UTC (cron
`55 23 * * *`, timezone `Etc/UTC`):

```bash
audit_anchor sweep [--as-of-utc=2026-04-28]
```

- `sweep` takes no `--operator-id` argument. The tool resolves the
  operator-id list from `public.operators` via `runAsSystem` (audit
  reason `audit_anchor.sweep`); the per-operator anchor logic
  itself stays inside `runInTenantContext` so RLS posture is
  preserved per-operator.
- `--as-of-utc` is the UTC date to treat as "today"; chains with
  `chain_date < as-of-utc` are eligible. Defaults to the host clock's
  UTC date when omitted.

For a manual rerun against a specific subset of operators (e.g.
after a job pod crash leaves the daily firing partial), use the
`anchor` mode instead:

```bash
audit_anchor anchor \
  --operator-id=<uuid-1> \
  --operator-id=<uuid-2> \
  --as-of-utc=2026-04-28
```

`anchor` requires at least one `--operator-id`; it does NOT query
`public.operators` (no cross-tenant scan from the manual surface).

Expected exit codes (both `sweep` and `anchor`):

- `0` — every chain anchored successfully (or no chains were
  unanchored). Sweep also exits 0 when `public.operators` is empty.
- `1` — at least one chain failed self-verification before anchor;
  see the [Failed-anchor triage](#failed-anchor-triage) section.
- `2` — configuration error (missing env, malformed args). Check the
  job's env wiring against the [Prerequisites](#prerequisites) list.
  Examples: `sweep` was passed `--operator-id` (unsupported), or
  `anchor` was invoked with no `--operator-id`.
- `3` — runtime error (Postgres unreachable, Blob client unavailable,
  network partition, or — for `sweep` only — operator-id resolution
  failed). Check the Cloud Run logs; do NOT retry without reading
  the error — a partial anchor is impossible by design (each chain
  anchor is a single transaction), but a runtime error indicates a
  deeper infrastructure problem that retrying will not resolve.

## Deploy procedure (Cloud Run Job + Cloud Scheduler)

The deploy surface is repo-owned in two files:

- `infrastructure/cloud_run/audit_anchor_job.yaml` — the Cloud Run
  Job + Cloud Scheduler manifest contract. Documents job name,
  region/service-account placeholders, schedule (`55 23 * * *`,
  `Etc/UTC`), command/args (`dart run tool/audit_anchor/main.dart
  sweep`), and the Secret Manager `secretKeyRef` bindings for
  `POSTGRES_URL`, `AZURE_BLOB_AUDIT_CONTAINER`, and
  `AZURE_BLOB_AUDIT_ENDPOINT`. Names only; never values.
- `scripts/deploy_audit_anchor_job.ps1` — name-only deploy script.
  Loads `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1`, asserts the
  required env names are present (values never echoed), syncs each
  to Secret Manager, then deploys the Cloud Run Job and creates /
  updates the Cloud Scheduler trigger.

### IAM / service-account grants

Live Azure setup, Postgres role creation, and any mutation of the
immutable Blob container retention policy require **human approval
before execution** per CLAUDE.md "no live Azure mutation in repo".
Grants the deploy operator must confirm out-of-band:

| Surface              | Identity / role                              | Grant                                                                                  |
| -------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------- |
| Postgres             | `audit_anchor_role` (DB role, not human)     | `INSERT` on `public.audit_logs`, `INSERT` on `public.audit_chain_anchors`; nothing else |
| Postgres             | Cloud Run Job managed identity               | Inherits `audit_anchor_role`                                                            |
| Azure Blob           | Cloud Run Job managed identity               | `Storage Blob Data Contributor` on the immutable audit container                        |
| Azure Blob           | Tenant owner                                 | Container creation + retention policy lock (out-of-band; never scripted)                |
| GCP Secret Manager   | Cloud Run Job service account                | `roles/secretmanager.secretAccessor` on each of the three secrets below                 |
| Cloud Scheduler      | Same service account as the Job              | Used as the `oauth-service-account-email` for the Job's `:run` invocation               |

### Secret Manager mapping

| Env name (used by `audit_anchor`) | Secret name (Secret Manager)                     |
| --------------------------------- | ------------------------------------------------ |
| `POSTGRES_URL`                    | `forge-flow-staging-postgres-url`                |
| `AZURE_BLOB_AUDIT_CONTAINER`      | `forge-flow-staging-azure-blob-audit-container`  |
| `AZURE_BLOB_AUDIT_ENDPOINT`       | `forge-flow-staging-azure-blob-audit-endpoint`   |

The proxy already publishes `forge-flow-staging-postgres-url`; the
job reuses it so the proxy and the daily anchor read the same
connection string. The two `AZURE_BLOB_AUDIT_*` secrets are
job-specific and are NOT part of the proxy bundle.

### Preflight (no live mutation)

```powershell
.\scripts\deploy_audit_anchor_job.ps1 -Preflight
```

The preflight path performs name-only checks, prints the gcloud
commands the deploy *would* run, and exits without touching Cloud
Run, Cloud Scheduler, Secret Manager, or the live Postgres host.
Use it before every real deploy and again after rotation to confirm
no env name is missing.

### Apply (after human approval)

```powershell
.\scripts\deploy_audit_anchor_job.ps1 `
  -Image <artifact-registry-image-uri>
```

The script is idempotent: re-running against an existing job +
scheduler updates them in place. Anchor writes themselves are
idempotent (the orchestrator skips chains that already have an
`audit_chain_anchors` row), so a Cloud Scheduler retry on a
transient failure is safe by design.

### Manual smoke after deploy

After the apply step succeeds, force one execution of the Job to
prove the wiring is live (the Job's command is `audit_anchor sweep`,
so this single call exercises the full daily firing shape):

Action-time approval is required before running this command in staging or
production. If eligible completed audit chains exist, the Job writes durable
append-only `public.audit_chain_anchors` rows and Azure Blob evidence.

```bash
gcloud run jobs execute forge-flow-audit-anchor \
  --project <project> \
  --region <region> \
  --wait
```

Expected: exit `0` and a leading
`audit_anchor: sweep resolved <N> operator(s) from public.operators`
line, followed by one `audit_anchor: anchored ...` or
`audit_anchor: no unanchored completed chains for ...` line per
operator id. If `public.operators` is empty the Job exits `0` with
`audit_anchor: sweep found 0 operators in public.operators` (this
is normal for a brand-new tenant; not a tamper signal). If the Blob
client is still the `ScaffoldRejectingAuditAnchorBlobClient` (live
Azure wiring not
yet landed), the job exits non-zero with the
`audit_anchor blob client is not wired to live Azure yet` reason —
that signals a deploy-config issue, not a chain tamper.

## Manual verification

Run on demand to prove a `(operator_id, chain_date)` chain matches
the anchor evidence:

```bash
audit_anchor verify \
  --operator-id=<uuid> \
  --chain-date=2026-04-27
```

Exit codes:

- `0` — chain matches the in-DB anchor row AND the Blob evidence
  ETag. The chain is verifiably untampered between the producing
  transaction's commit and the daily anchor commit.
- `1` — verification failed; see [Failed-anchor triage]
  (#failed-anchor-triage). The CLI prints which axis failed
  (`chainHashMismatch`, `anchorMissing`, `anchorTerminalMismatch`,
  `blobEvidenceMismatch`).
- `2` — configuration error.
- `3` — Blob unavailable. Cloud Run job's Blob credentials may be
  expired or the container may have been disabled. Re-check
  Prerequisite 1.

## Evidence export

For SOC 2 audit / dispute reconstruction, export the anchor evidence
for a window of dates as JSONL (one JSON object per line — the Q9
lock canonical format). The query projects each row through
`jsonb_build_object` and emits it as a single text value per line so
`\copy` writes a true JSONL file, not a TSV/CSV that just happens to
share the `.jsonl` extension.

```sql
\copy (
  select jsonb_build_object(
    'operator_id',           operator_id,
    'chain_date',            to_char(chain_date, 'YYYY-MM-DD'),
    'terminal_row_hash_hex', encode(terminal_row_hash, 'hex'),
    'terminal_row_id',       terminal_row_id,
    'row_count',             row_count,
    'blob_uri',              blob_uri,
    'blob_etag',             blob_etag,
    'anchored_at',           to_char(
      anchored_at at time zone 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
    )
  )::text as line
    from audit_chain_anchors
   where operator_id = '<operator_uuid>'
     and chain_date  between '<start>' and '<end>'
   order by chain_date
) to '/tmp/audit_chain_anchors_<operator>_<window>.jsonl'
  with (format text);
```

`format text` (without `header`, without a delimiter override)
writes each row's single text value verbatim followed by `\n`. The
result is one JSON object per line — JSONL exactly as the Q9 lock
specifies. Do NOT use `format csv` here, even with a tab delimiter:
CSV mode would quote-wrap values and add a column-header line, both
of which break JSONL parsers.

JSONL is canonical for evidence/replay (Q9 lock); Parquet is
secondary analytics format.

## Failed-anchor triage

When `audit_anchor` reports a violation, follow these steps in order.
Do NOT run `update` / `delete` against `audit_logs` or
`audit_chain_anchors` while triaging — both tables are append-only at
the grant shape; bypassing the constraint masks the forensic signal
and contaminates the chain.

1. **Identify the affected chain.** The CLI prints
   `<operator_id> / <chain_date>`. Record both.

2. **Read the anchor row** if it exists:

   ```sql
   select operator_id, chain_date, encode(terminal_row_hash, 'hex')
       as terminal_row_hash_hex, terminal_row_id, row_count,
       blob_uri, blob_etag, anchored_at
     from audit_chain_anchors
    where operator_id = '<operator_uuid>'
      and chain_date  = '<chain_date>';
   ```

3. **Compare against the in-DB chain** by re-running
   `audit_anchor verify`. The exit-1 message identifies which axis
   disagrees:

   - `chainHashMismatch` — the in-DB chain itself fails internal
     hash verification (a row's `prev_row_hash` does not equal the
     previous row's `row_hash`, or `row_hash` does not equal
     `SHA256(prev_row_hash || canonical_payload)`). This is the
     strongest tamper signal; escalate immediately to the F&F
     security on-call. Do not anchor and do not roll the partition.
   - `anchorMissing` — the chain has rows but no anchor was ever
     written. Re-run `audit_anchor anchor` for that operator. If the
     anchor still does not write, check the Cloud Run job logs for
     Blob client errors.
   - `anchorTerminalMismatch` — the in-DB chain's terminal row hash
     does not equal the anchor row's `terminal_row_hash`. Either a
     row was inserted into the chain after anchoring (which the
     `chain_date` partition makes impossible — once `chain_date <
     today UTC`, no producer should write to it) OR a row was
     mutated retroactively. Treat as a tamper signal.
   - `blobEvidenceMismatch` — the Blob's ETag or evidence body
     disagrees with the anchor row. The Blob immutability lock means
     the body cannot change; an ETag mismatch means the anchor row
     was written before the Blob commit (a job race condition) or
     the Blob was deleted and recreated by an unauthorized actor.
     Escalate.

4. **Re-anchor only after escalation has cleared the chain.** Once
   the security review has documented the cause, the runbook holder
   may re-run `audit_anchor anchor` with a forced `--as-of-utc`
   beyond the affected day to anchor the *current* state (which now
   includes the documented disruption). The original mismatch is
   preserved in the audit trail by the new anchor row's
   `anchored_at` timestamp.

## Break-glass: redacting audit_logs

`audit_logs` is append-only by grant shape: the migration revokes
`UPDATE` and `DELETE` from both `service_role` and `forge_admin`. Any
mid-row redaction (e.g. GDPR Art. 17 obligation reaching audit
content) requires the same break-glass DBA procedure as
`auth_events_audit` (see `runbooks/gdpr_erasure_runbook.md`):

```sql
begin;

-- 1. Temporarily allow forge_admin to UPDATE the audit table.
grant update on public.audit_logs to forge_admin;

-- 2. Switch into forge_admin so SET LOCAL bypass + the new UPDATE
--    grant both apply. Record an audit reason for the BYPASSRLS event.
set local role forge_admin;
set local "app.bypass_rls_audit" = 'system:audit_logs.redaction';

-- 3. Apply the redaction. Recompute row_hash if the redaction
--    changes the payload — otherwise the chain breaks. The DBA
--    issues the recompute manually (no proxy code exists for this).

-- 4. Reset to the default role and revoke the temporary grant so the
--    append-only posture is restored before commit.
reset role;
revoke update on public.audit_logs from forge_admin;

-- 5. Insert a one-row audit trail recording the break-glass run
--    (allowed by the INSERT grant). The chain trigger picks up
--    prev_row_hash from the latest row in (operator_id, chain_date),
--    so the new break-glass row appends cleanly.

commit;
```

If anything inside the transaction fails, ROLLBACK restores the prior
state. Do not COMMIT a partial run. Note that re-anchoring a chain
that has had a break-glass redaction applied is a separate manual
step: the daily anchor job will not detect the redaction unless the
`row_hash` was recomputed inside the same transaction.

## Authority required

- DBA-level Postgres access for break-glass (the `postgres` superuser
  or a role with authority to GRANT / REVOKE on `audit_logs`).
- F&F super_admin paired-approval recorded in the break-glass row,
  same posture as the GDPR runbook.
- Live Azure Blob mutation (immutable container creation, retention
  policy change, role assignment) requires the F&F Azure tenant
  owner approval and lands outside this runbook.

## Audit

Every break-glass run inserts:

- `auth_events_audit` row tagged `event_type =
  'audit_logs.redaction_break_glass'` with the requesting DBA, the
  paired approvers, and the affected row IDs. (The `audit_logs` table
  itself is the chain; the `auth_events_audit` table is the
  cross-cutting audit-of-audits ledger that records that the
  break-glass run happened. Two-layer evidence is the locked posture.)

The daily anchor job's standard run logs:

- One `audit_chain_anchors` row per anchored chain (success path).
- Cloud Run stdout: one structured-log line per chain processed.
  Names only; no Blob URIs containing SAS tokens, no operator
  business names beyond their UUID.

## Rotation pattern

Rotation covers two surfaces — the GCP Secret Manager values that
back the env names, and the Azure Blob immutable container itself.
Both rotations are name-only operations from the deploy script's
perspective; live Azure mutations stay out-of-band.

### Secret rotation (Secret Manager)

The job reads each env via `secretKeyRef ... key: latest`, so a new
secret version is picked up on the next Cloud Run Job execution
without redeploying. Procedure:

1. Update the upstream secret value (e.g. rotate the Postgres user
   password, regenerate the Azure Blob endpoint with a fresh SAS
   identity, change the container name during a tenant move).
2. Update the corresponding entry in
   `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` (NEVER commit this
   file).
3. After human approval for the live Cloud Run / Scheduler refresh,
   re-run the deploy script with the unchanged image:

   ```powershell
   .\scripts\deploy_audit_anchor_job.ps1 `
     -SkipApiEnable `
     -Image <unchanged-image-uri>
   ```

   The script's `Sync-SecretManagerSecret` writes a new version
   under each existing secret name (idempotent), then re-applies the
   Cloud Run Job and Cloud Scheduler trigger with the same image. The
   next 23:55 UTC firing reads `:latest`.

4. Run the manual smoke documented in
   [Deploy procedure](#deploy-procedure-cloud-run-job--cloud-scheduler)
   to confirm the new version works before the unattended firing.

5. Disable older secret versions in Secret Manager only after one
   successful manual smoke. Disabling before the smoke risks
   bricking the next 23:55 UTC sweep.

The deploy script never prints secret values; rotation logs only
the secret *names* it touched.

### Container rotation (Azure Blob)

Rotating the immutable Blob container (e.g. tenant migration,
retention-policy change beyond the existing lock) is a tenant-owner
operation, never a deploy-script operation. Sequence:

1. Tenant owner provisions the new container with retention
   policies matching or exceeding the SOC 2 / Q9 7-year audit floor
   and locks it. Live Azure mutation requires
   **human approval** before execution per CLAUDE.md "no live Azure
   mutation in repo".
2. Tenant owner grants the Cloud Run Job's managed identity
   `Storage Blob Data Contributor` on the new container.
3. Operator updates the `AZURE_BLOB_AUDIT_CONTAINER` (and
   `AZURE_BLOB_AUDIT_ENDPOINT` if the storage account changed)
   value via the secret-rotation procedure above.
4. The old container stays immutable for its full retention window;
   it is NOT deleted on cutover. Existing `audit_chain_anchors` rows
   continue to point at it and `audit_anchor verify` continues to
   walk forward against those Blob URIs.
5. New anchors written after the cutover land in the new container;
   `audit_chain_anchors.blob_uri` records which container each
   anchor was written to, so the verifier picks the right surface
   automatically.

A rotation that changes the schedule (e.g. moving away from
`55 23 * * *` UTC) requires a synchronized edit across:

- `infrastructure/cloud_run/audit_anchor_job.yaml`,
- `scripts/deploy_audit_anchor_job.ps1` (`$ScheduleCron` /
  `$ScheduleTimeZone`),
- this runbook (Prerequisites + Daily anchor procedure),
- and the Phase 9 backlog entry for B43.

The focused test
`test/phase_9_0sigma_f_audit_logs_test.dart` (`audit_chain_verify
runbook posture`) guards the schedule string; a desync produces a
test failure on the next CI run.

## Rollback

**Anchoring is irreversible.** Once `audit_anchor anchor` writes the
Blob and inserts the `audit_chain_anchors` row:

- The Blob is immutable for the retention window — Azure Blob
  Storage rejects any subsequent write or delete to the same
  blob name + container until the retention period elapses.
- The `audit_chain_anchors` row is append-only; UPDATE and DELETE
  are forbidden by grant.

If a rollback is required (e.g. a wrong chain was anchored due to
operator-id misrouting), the procedure is:

- Document the misrouted anchor in a fresh `auth_events_audit` row
  tagged `event_type = 'audit_chain_anchors.misrouted_anchor'`.
- Write a *new* anchor for the correct operator/day; the misrouted
  anchor remains in the table as forensic evidence of the routing
  error.
- The Blob holding the misrouted evidence stays immutable for its
  full retention window — this is by design, since deleting a Blob
  to "fix" a routing mistake would weaken the immutability posture
  for every legitimate anchor too.

## Source-of-truth boundaries

- **Framework decision logic:** `tool/audit_anchor/audit_anchor.dart`
  (`AuditAnchorOrchestrator`, `AuditChainHasher`,
  `AnchorEvidenceCodec`).
- **Persistence path:**
  `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`
  (table shape, trigger, grants, RLS), and the
  `PostgresAuditChainReader` /
  `PostgresAuditChainAnchorWriter` /
  `PostgresOperatorIdReader` classes inside
  `tool/audit_anchor/audit_anchor.dart`.
- **CLI entry point:** `tool/audit_anchor/main.dart`. Three modes
  (`sweep` for the daily firing, `anchor` for manual reruns,
  `verify` for on-demand). Reads env *names* only; never echoes
  secret values.
- **Cloud Run Job + Cloud Scheduler manifest:**
  `infrastructure/cloud_run/audit_anchor_job.yaml`. Placeholders
  only; values are resolved via Secret Manager at deploy time.
- **Deploy script:** `scripts/deploy_audit_anchor_job.ps1`. Loads
  `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1`, asserts required env
  *names*, syncs Secret Manager, deploys Cloud Run Job + Cloud
  Scheduler. Supports `-Preflight` for a no-mutation dry run.
- **Decision lock:** `phase_9_scalability_decisions_2026-04-27.md`
  item 13 (`Hash-chained audit log`).

When this runbook and any of the above disagree, the framework code
wins. Update the runbook to match.
