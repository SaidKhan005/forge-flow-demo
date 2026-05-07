# Postgres PITR (Point-In-Time Recovery) Drill Runbook

Version: 1.0 (2026-05-07).
Owner: F&F engineering + Azure DBA.
Target: Azure Database for PostgreSQL Flexible Server — Canada Central, PG 16.
RTO target: 4 hours (restore detected to traffic-serving on restored host).
RPO target: 5 minutes (maximum data loss, matching Azure PITR granularity).

## Schedule

| Drill | Timing |
|-------|--------|
| First drill | Before `cutover.0` preflight (mandatory gate) |
| Quarterly drills | Q2/Q3/Q4 of each calendar year |
| Emergency drill | Immediately when a suspected data-loss or corruption event is detected |

Drills run against a fresh isolated host (not production). Do NOT run against the live
production database.

## Prerequisites

Before starting a drill, confirm:

- [ ] Azure CLI installed and authenticated: `az login`; confirm subscription is correct.
- [ ] The target production server name and resource group are documented in the deploy secrets.
      (Never paste these into chat or docs; refer to them by the secret name only.)
- [ ] A spare resource group is available for the restored host (use `forge-flow-pitr-drill`).
      If it does not exist: `az group create --name forge-flow-pitr-drill --location canadacentral`.
- [ ] The driller has the Azure RBAC role `Contributor` on the source server's resource group.
- [ ] A recent snapshot of the connection string for the restored host placeholder is ready.
- [ ] The `runbooks/audit_chain_verify_runbook.md` hash-chain verification script is accessible.
- [ ] No production cutover is in progress; confirm with the primary on-call.

---

## Step 1 — Record the Snapshot Timestamp

Before initiating the restore, record the precise target timestamp. PITR restores to a
specific moment in time; choose a timestamp roughly 30 minutes in the past to give Azure
adequate time to have processed WAL logs up to that point.

```powershell
# Record the drill timestamp (UTC). Adjust as needed.
$snapshotTimestamp = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Host "PITR snapshot timestamp: $snapshotTimestamp"
```

Also record the current `audit_chain_anchors` state on the source server, so you can
compare after restore:

```sql
-- Run on production BEFORE restore. Save output.
SELECT operator_id, chain_date, status, anchored_at, blob_url_prefix
FROM audit_chain_anchors
WHERE chain_date >= current_date - interval '7 days'
ORDER BY operator_id, chain_date;
```

Save this output to `build/pitr-drill/pre_restore_anchors.txt`.

---

## Step 2 — Initiate PITR Restore via Azure CLI

Azure Flexible Server supports PITR via `az postgres flexible-server restore`.
The restored server appears as a NEW server; it does not replace the source.

```powershell
# Replace placeholders with values from the deploy secrets file.
$sourceServer = "__SOURCE_SERVER_NAME__"
$resourceGroup = "__SOURCE_RESOURCE_GROUP__"
$drillResourceGroup = "forge-flow-pitr-drill"
$drillServerName = "forge-flow-pitr-drill-$(Get-Date -Format 'yyyyMMddHHmm')"

az postgres flexible-server restore `
  --source-server $sourceServer `
  --resource-group $drillResourceGroup `
  --name $drillServerName `
  --restore-time $snapshotTimestamp `
  --location canadacentral
```

This command is asynchronous. Monitor until it completes:

```powershell
az postgres flexible-server show `
  --resource-group $drillResourceGroup `
  --name $drillServerName `
  --query "state" --output tsv
```

Expected output when ready: `Ready`. Typical restore time: 20–60 minutes depending on database size.

**RTO clock starts when you issue the restore command.** Target: restored DB is ready
and verified within 4 hours of this command.

---

## Step 3 — Verify the Restored Database

Once the restored server is `Ready`, connect and run verification queries.

### 3a. Basic connectivity

```powershell
# Get the restored server's FQDN.
$drillFqdn = az postgres flexible-server show `
  --resource-group $drillResourceGroup `
  --name $drillServerName `
  --query "fullyQualifiedDomainName" --output tsv

Write-Host "Drill FQDN: $drillFqdn"
```

Connect via `psql` (replace `<admin_user>` with the server admin from the deploy secrets):

```bash
psql "host=$drillFqdn port=5432 dbname=forge_flow user=<admin_user> sslmode=require"
```

### 3b. Row count sanity checks

```sql
-- Confirm tables exist and have expected row counts within RPO tolerance.
SELECT
  relname AS table_name,
  n_live_tup AS live_rows
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC
LIMIT 20;
```

Compare against the pre-restore baseline if available.

### 3c. Audit chain integrity verification

The hash chain must be intact up to the PITR timestamp. Run the `audit_anchor verify`
CLI against the restored database to confirm chain hash integrity.

```powershell
dart run tool/audit_anchor/main.dart verify `
  --connection-string="host=$drillFqdn port=5432 dbname=forge_flow user=<admin_user> password=<password> sslmode=require" `
  --as-of-utc=$snapshotTimestamp
```

Expected output: `verification.ok` for all operators with data before the snapshot timestamp.

Any `chain_hash_mismatch` result is a CRITICAL finding. Do NOT dismiss it. Document and
escalate immediately — this indicates data was mutated retroactively in the source database.

### 3d. Compare anchor state

```sql
-- Run on the RESTORED server.
SELECT operator_id, chain_date, status, anchored_at
FROM audit_chain_anchors
WHERE chain_date >= current_date - interval '7 days'
ORDER BY operator_id, chain_date;
```

Compare against `build/pitr-drill/pre_restore_anchors.txt`:
- Rows present in pre-restore snapshot but not in restore: acceptable only if they were
  written AFTER the snapshot timestamp (within the RPO window).
- Rows present in restore but not in pre-restore: impossible unless data loss occurred on source.
- Hash mismatches: CRITICAL — escalate.

---

## Step 4 — Traffic Flip Plan (Tabletop Exercise Only)

In a real disaster recovery scenario, traffic would flip to the restored host after verification.
During a drill, do NOT flip production traffic. Instead, document the planned flip steps:

1. Update `POSTGRES_URL` secret in GCP Secret Manager to point to the restored server FQDN.
   ```
   gcloud secrets versions add POSTGRES_URL --data-file=- <<< "host=<restored_fqdn> port=5432 ..."
   gcloud run services update forge-flow-proxy --region=__REGION__ \
     --update-secrets=POSTGRES_URL=POSTGRES_URL:latest
   ```
2. Deploy a new Cloud Run revision (the secret update auto-deploys via Cloud Run revision rollout).
3. Confirm health check endpoint returns 200: `https://api.forgeflow.app/health`.
4. Monitor error rates and pool saturation for 15 minutes before calling the flip complete.
5. Update DNS if a custom FQDN is used (typically not needed if Cloud Run handles routing).

**RTO gate:** the steps above should complete within 4 hours of the disaster declaration.
The 4-hour RTO clock includes: detection (< 15 min) + restore initiation (< 5 min) +
restore completion (20–60 min) + verification (< 30 min) + traffic flip (< 15 min) =
approximately 1.5–2 hours in a clean execution. The 4-hour target includes investigation
time for complex failures.

---

## Step 5 — Drill Teardown

After the drill is complete and results are documented:

1. Delete the drill server to avoid ongoing compute cost:
   ```powershell
   az postgres flexible-server delete `
     --resource-group $drillResourceGroup `
     --name $drillServerName `
     --yes
   ```
2. Optionally delete the resource group if it was created for this drill:
   ```powershell
   az group delete --name $drillResourceGroup --yes --no-wait
   ```
3. Write the drill result to `docs/ops/pitr_drill_log.md` (create if not present):
   ```
   | 2026-05-07 | Snapshot: 2026-05-07T09:30:00Z | Restore time: 41 min | RTO: 2h15m | Chains: PASS | Notes: first drill, all green |
   ```

---

## Drill Result Classification

| Finding | Classification | Action |
|---------|---------------|--------|
| All checks green; RTO < 4h | PASS | Log result; schedule next quarterly drill |
| All checks green; RTO 4–6h | PASS with finding | Log result; investigate bottleneck; target fix before next drill |
| RTO > 6h | FAIL | P1 finding; file engineering sprint item to reduce RTO |
| `chain_hash_mismatch` found | CRITICAL | Halt; escalate; do not resume normal operations until source chain is audited |
| Restore fails to reach `Ready` | FAIL | Open Azure support ticket; document error; re-attempt with an earlier snapshot timestamp |

---

## RPO Verification

RPO is verified by comparing the snapshot timestamp to the last event recorded in the
restored database. Acceptable data loss = snapshot_timestamp − max(last_write_in_db) ≤ 5 minutes.

```sql
-- Find the most recent write in the restored DB.
SELECT max(created_at) AS latest_write FROM audit_logs;
```

If `latest_write` is more than 5 minutes before the snapshot timestamp, RPO has been
exceeded. Document and investigate whether Azure WAL shipping had a lag at the time of
the snapshot.
