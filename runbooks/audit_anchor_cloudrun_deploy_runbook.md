# Audit Anchor Cloud Run Deploy Runbook

Updated: 2026-05-03.
Owner: F&F launch lane.
Slice: Phase 9.0Σ.f — `audit_anchor` Cloud Run live preflight + deploy.

## Current staging state (2026-05-03)

**Deployed and verified end-to-end on staging, except the immutability
lock — deliberately deferred.**

- Cloud Run Job `forge-flow-audit-anchor` (project `forge-flow-staging`,
  region `northamerica-northeast2`): deployed, image
  `audit-anchor:7f95227`. Egress via VPC connector
  `ff-staging-proxy-egress` → static IP `34.130.85.86`.
- Cloud Scheduler `forge-flow-audit-anchor-daily` (location
  `northamerica-northeast1` — Toronto isn't a Scheduler region): created
  at `55 23 * * *` Etc/UTC. **PAUSED.** Will not fire until manually
  resumed.
- Storage container `audit-chain-anchors-immutable` on
  `forgeflowstaging1`: created, **EMPTY, UNLOCKED.**
- Federated cred `forge-flow-audit-anchor-cloudrun-staging` on AD app
  `forge-flow-audit-anchor-staging`: attached, RBAC granted at container
  scope.
- Latest successful manual sweep: execution `forge-flow-audit-anchor-zmsvj`
  (2026-05-03). Resolved 1 operator from `public.operators`, anchored the
  2026-05-02 chain, and exited 0.
- Live `/health` check during the 2026-05-03 admin-console staging smoke first
  reported `audit_chain_lag_seconds` red with metadata warning
  `no_anchor_recorded`. After action-time approval and execution
  `forge-flow-audit-anchor-zmsvj`, `/health` reported
  `audit_chain_lag_seconds` green. This was not an admin auth/UI wiring defect
  and is not assigned to a future 11A frontend slice.
- Blob write path: **exercised in staging 2026-05-03** by the successful
  anchor of the 2026-05-02 chain. Leave the immutability lock deferred until
  the evidence body/ETag is verified and the four conditions below are true.
  Code path remains covered by unit tests (REST shape + 201/409/403 branches)
  and orchestrator E2E.

### Deferred immutability lock — when to revisit

The 7-year container immutability lock (Stage 2d) is intentionally
deferred until we have direct proof of the blob write path against real
data. Apply the lock when ALL of the following are true:

1. Real audit_log rows exist in staging Postgres for at least one
   operator with `chain_date < today UTC`.
2. The Scheduler has been resumed (`gcloud scheduler jobs resume
   forge-flow-audit-anchor-daily --project=forge-flow-staging
   --location=northamerica-northeast1`) OR a manual sweep has been
   triggered against real data.
3. At least one anchor has been visibly written: a row in
   `public.audit_chain_anchors` AND a blob in
   `audit-chain-anchors-immutable`.
4. The blob's `etag` matches `audit_chain_anchors.blob_etag` and the
   evidence body decodes cleanly via `audit_anchor verify`.

Until then, the unlocked container costs nothing (empty), the paused
Scheduler can't write rogue anchors, and the manual `gcloud run jobs
execute` path is available for ad-hoc tests. The lock procedure stays
authoritative in §2d below — execute it only after the four conditions
above are satisfied.

## Purpose

Provision and deploy the `audit_anchor` daily Cloud Run Job that
SHA-256-chain-anchors each `(operator_id, chain_date)` to a
`audit_chain_anchors` Postgres row plus a write-once Azure Blob with
≥ 7-year container-level retention (Phase 9.0Σ.f Item 13: SOC 2 +
forensic dispute reconstruction).

Pairs with:

- `runbooks/audit_chain_verify_runbook.md` — forensic verification
  procedure for an existing anchor.
- `runbooks/cmk_provisioning_runbook.md` — provides the storage
  account `forgeflowprod1` + key vault `forgeflow-prod-kv` /
  `blob-cmk` this runbook depends on.
- `infrastructure/cloud_run/audit_anchor_job.yaml` — Cloud Run Job
  + Cloud Scheduler name-only manual contract, schedule pinned
  `55 23 * * *` Etc/UTC. The deploy helper now calls `gcloud`
  directly instead of rendering this YAML.
- `scripts/deploy_audit_anchor_job.ps1` — idempotent deploy helper
  (Secret Manager sync, Job deploy/update, Scheduler upsert).
- `tool/audit_anchor/Dockerfile` — Cloud Build container recipe.
- `tool/audit_anchor/cloudbuild.yaml` — image build + push pipeline.

## Acceptance criteria

- [ ] Preflight: every name-only check passes; BLOCKED on any miss.
- [ ] Cloud Run Job `forge-flow-audit-anchor` deployed; Cloud Scheduler
      `forge-flow-audit-anchor-daily` paused-or-active at 23:55 UTC.
- [ ] First manual run produces both an `audit_chain_anchors` row AND
      an immutable blob upload for at least one operator.
- [ ] Blob immutability proven: an overwrite attempt against an
      anchored blob returns HTTP `403` or `409`.
- [ ] No secrets in runbook, deploy script, or job logs (verify by
      `grep` against captured execution logs after the manual run).
- [ ] Runbook committed.

## Conventions

- Live values (subscription IDs, tenant IDs, service account emails,
  key vault keys, etc.) live in the operator's
  `$HOME/.forge_flow/forge_flow.secrets.ps1` and are loaded by
  `scripts/deploy_audit_anchor_job.ps1`. Variable names appear here;
  values never do.
- Every cloud-mutating step in this runbook is gated by a preflight
  assertion. **If preflight fails, STOP — do not partially deploy.**
- Stages 2 (Azure provisioning) and 4d (immutability lock) are
  irreversible. Each lists an explicit human-confirmation prompt.
- Production1 note (2026-05-03): production runtime setup is paused.
  Do not deploy the audit-anchor job to Production1 until
  `docs/phases/phase_production_cutover/production1_staging_parity_baseline_2026-05-03.md`
  has been updated with the production Secret Manager namespace,
  deploy service account, static egress, Azure firewall allowlist,
  and audit-anchor Azure app/federated-credential values.

## Variable name reference

| Variable | Source | Used by |
| --- | --- | --- |
| `FF_GCP_PROJECT` | secrets.ps1 | gcloud |
| `FF_GCP_REGION` | secrets.ps1 (`northamerica-northeast2` for the Cloud Run Job) | gcloud run / Artifact Registry |
| `FF_GCP_SCHEDULER_LOCATION` | secrets.ps1 or deploy param (`northamerica-northeast1`; Cloud Scheduler location) | gcloud scheduler |
| `FF_CLOUDRUN_SA_EMAIL` | secrets.ps1 | gcloud / az |
| `FF_CLOUDRUN_SA_UNIQUE_ID` | secrets.ps1 (numeric) | az federated-credential subject |
| `FF_ARTIFACT_REGISTRY` | secrets.ps1 (`region-docker.pkg.dev/proj/repo`) | gcloud builds + Cloud Run image ref |
| `FF_AZ_TENANT_ID` | secrets.ps1 | az |
| `FF_AZ_SUBSCRIPTION_ID` | secrets.ps1 | az |
| `FF_AZ_RG` | secrets.ps1 (`forge-flow-production1-rg`) | az |
| `FF_AZ_STORAGE_ACCOUNT` | secrets.ps1 (`forgeflowprod1`) | az storage |
| `FF_AZ_APP_CLIENT_ID` | secrets.ps1 | az ad / Cloud Run env `AZURE_AD_CLIENT_ID` |
| `FF_AZ_CMK_KEY_ID` | secrets.ps1 (KID from cmk_provisioning runbook) | sanity check |
| `FF_AUDIT_CONTAINER` | literal `audit-chain-anchors-immutable` | Cloud Run env `AZURE_BLOB_AUDIT_CONTAINER` |
| `FF_AZ_BLOB_ENDPOINT` | derived `https://${FF_AZ_STORAGE_ACCOUNT}.blob.core.windows.net` | Cloud Run env `AZURE_BLOB_AUDIT_ENDPOINT` |
| `FF_POSTGRES_URL` | secrets.ps1 | Cloud Run env `POSTGRES_URL` |

## Stage 1 — Preflight (read-only; idempotent)

Run the deploy script's `-Preflight` switch. The script exits non-zero
on the first missing local env name and prints the exact `gcloud`
commands that would run, without performing any mutation.

```powershell
pwsh scripts/deploy_audit_anchor_job.ps1 -Preflight
```

Expected output: name-only required variables, the Secret Manager mapping,
and dry-run `gcloud` commands. Current
`scripts/deploy_audit_anchor_job.ps1 -Preflight` does not run the
historical `az`/`gcloud describe` checks below; run those describes
manually before live apply when changing target projects, tenants,
service accounts, storage accounts, or the static-egress connector.
The specific assertions to verify are:

1. `gcloud projects describe $FF_GCP_PROJECT` exit 0.
2. Cloud Run Job region is `$FF_GCP_REGION`; Scheduler location is
   `$FF_GCP_SCHEDULER_LOCATION` (staging uses `northamerica-northeast1`
   for Scheduler).
3. `gcloud iam service-accounts describe $FF_CLOUDRUN_SA_EMAIL` exit 0.
4. `gcloud iam service-accounts describe $FF_CLOUDRUN_SA_EMAIL --format='value(uniqueId)'` equals `$FF_CLOUDRUN_SA_UNIQUE_ID`.
5. `gcloud artifacts repositories describe ...` parsed from `$FF_ARTIFACT_REGISTRY` exit 0.
6. `az account tenant show --tenant-id $FF_AZ_TENANT_ID` exit 0.
7. `az ad app show --id $FF_AZ_APP_CLIENT_ID` exit 0.
8. `az ad app federated-credential list --id $FF_AZ_APP_CLIENT_ID` returns one entry with `issuer=https://accounts.google.com`, `subject=$FF_CLOUDRUN_SA_UNIQUE_ID`, `audience=api://AzureADTokenExchange`.
9. `az account show --subscription $FF_AZ_SUBSCRIPTION_ID` exit 0.
10. `az group show -n $FF_AZ_RG` exit 0.
11. `az storage account show -n $FF_AZ_STORAGE_ACCOUNT -g $FF_AZ_RG --query "[allowSharedKeyAccess, minimumTlsVersion, encryption.keyVaultProperties.keyVaultUri]" -o tsv` returns `false TLS1_2 <kv-uri>`. Shared-key access MUST be disabled (we use Bearer tokens only).
12. `az keyvault key show --id $FF_AZ_CMK_KEY_ID` exit 0 (sanity: confirms CMK still exists; cmk_provisioning runbook is authoritative).
13. `az storage container show -n $FF_AUDIT_CONTAINER --account-name $FF_AZ_STORAGE_ACCOUNT --auth-mode login` exit 0 AND `--query 'properties.hasImmutabilityPolicy' -o tsv` returns `false`. The container MUST exist with NO immutability policy yet — Stage 2d creates and locks it.
14. Postgres reachability: from a host with Cloud Run-equivalent network reach, `psql "$FF_POSTGRES_URL" -c "SELECT 1 FROM public.audit_chain_anchors LIMIT 0"` exit 0.

If item 13 returns `true` (a policy already exists), STOP and read its
period — re-locking is irreversible. If item 11 returns `true` for
shared-key access, STOP and disable it before continuing (the live
client never falls back to shared keys; leaving them on widens the
attack surface for no purpose).

**STOP rule:** any failed assertion → emit `BLOCKED: preflight failed
at item N` and exit non-zero. No partial deploy.

## Stage 2 — Provision Azure side (one-time, mostly idempotent)

### 2a. Federated credential on the AD app registration (idempotent)

```bash
az ad app federated-credential create \
  --id "$FF_AZ_APP_CLIENT_ID" \
  --parameters '{
    "name": "forge-flow-audit-anchor-cloudrun",
    "issuer": "https://accounts.google.com",
    "subject": "'"$FF_CLOUDRUN_SA_UNIQUE_ID"'",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

Re-running with the same `name` returns 409 ResourceExists; treat as
success.

### 2b. RBAC at container scope (idempotent)

The AD app needs `Storage Blob Data Contributor` on the *container*,
not the storage account. Container-scope keeps blast radius minimal —
the app cannot list, read, or write any other container, and the
locked immutability policy prevents mutation regardless of role.

```bash
SCOPE="/subscriptions/$FF_AZ_SUBSCRIPTION_ID/resourceGroups/$FF_AZ_RG/providers/Microsoft.Storage/storageAccounts/$FF_AZ_STORAGE_ACCOUNT/blobServices/default/containers/$FF_AUDIT_CONTAINER"

az role assignment create \
  --assignee "$FF_AZ_APP_CLIENT_ID" \
  --role "Storage Blob Data Contributor" \
  --scope "$SCOPE"
```

Re-running emits `RoleAssignmentExists`; treat as success.

### 2c. Create the immutable container (idempotent)

The container itself must exist before any policy. If it does not yet:

```bash
az storage container create \
  --name "$FF_AUDIT_CONTAINER" \
  --account-name "$FF_AZ_STORAGE_ACCOUNT" \
  --auth-mode login \
  --public-access off
```

### 2d. Time-based retention policy + LOCK (irreversible — confirm)

The policy is enforced server-side; the writer holds no `unlock` /
`extend` privilege. Once locked, even a subscription owner cannot
shorten the period for the next 2555 days.

```text
HUMAN CONFIRMATION REQUIRED.
You are about to apply and LOCK a 7-year (2555 day) immutability
policy on container $FF_AUDIT_CONTAINER. This is irreversible:
- you cannot shorten the period;
- you cannot delete the policy;
- you cannot delete blobs the container holds for the retention duration.

Proceed only if (1) the container has no test blobs, and (2) the storage
account is the production account `forgeflowprod1`.
```

```bash
# Step A — create the policy (still mutable until locked).
az storage container immutability-policy create \
  --account-name "$FF_AZ_STORAGE_ACCOUNT" \
  --container-name "$FF_AUDIT_CONTAINER" \
  --period 2555 \
  --allow-protected-append-writes false

# Capture the etag for the lock step.
ETAG=$(az storage container immutability-policy show \
  --account-name "$FF_AZ_STORAGE_ACCOUNT" \
  --container-name "$FF_AUDIT_CONTAINER" \
  --query etag -o tsv)

# Step B — LOCK (irreversible). Operator types `LOCK` to confirm.
read -p "Type LOCK to apply the irreversible immutability lock: " CONFIRM
[ "$CONFIRM" = "LOCK" ] || { echo "abort"; exit 1; }

az storage container immutability-policy lock \
  --account-name "$FF_AZ_STORAGE_ACCOUNT" \
  --container-name "$FF_AUDIT_CONTAINER" \
  --if-match "$ETAG"
```

Verify:

```bash
az storage container immutability-policy show \
  --account-name "$FF_AZ_STORAGE_ACCOUNT" \
  --container-name "$FF_AUDIT_CONTAINER" \
  --query "[immutabilityPeriodSinceCreationInDays, state]" -o tsv
# expected: 2555  Locked
```

## Stage 3 — Build + push the container image

From the repo root (build context MUST include `pubspec.*` and `lib/`):

```bash
SHA=$(git rev-parse --short HEAD)

gcloud builds submit . \
  --config=tool/audit_anchor/cloudbuild.yaml \
  --substitutions="_REGION=${FF_GCP_REGION},_REPO=forge-flow,SHORT_SHA=${SHA}" \
  --project="$FF_GCP_PROJECT"
```

> **Note:** `$SHORT_SHA` is not auto-populated for local `builds submit`
> calls (only for triggers connected to a repo). Pass it explicitly via
> `--substitutions` as shown.

The build takes ~6–10 minutes (Flutter SDK image fetch + `dart compile
exe`). On success the image is tagged with both `${SHA}` and `latest`.
Capture the SHA-tagged URL for Stage 4:

```bash
IMAGE="${FF_GCP_REGION}-docker.pkg.dev/${FF_GCP_PROJECT}/forge-flow/audit-anchor:${SHA}"
```

## Stage 4 — Deploy the Cloud Run Job + Scheduler

The deploy script (idempotent — describe-first, deploy/update) syncs Secret
Manager, deploys or updates the Cloud Run Job directly from the compiled
image, and upserts the Cloud Scheduler trigger. It no longer renders
`infrastructure/cloud_run/audit_anchor_job.yaml`.

### 4a. Sync secrets (idempotent — adds new versions only when content changes)

The script reads the secrets file and syncs five secrets:

| Secret name | Env var inside Cloud Run |
| --- | --- |
| `forge-flow-staging-postgres-url` | `POSTGRES_URL` |
| `forge-flow-staging-azure-blob-audit-container` | `AZURE_BLOB_AUDIT_CONTAINER` |
| `forge-flow-staging-azure-blob-audit-endpoint` | `AZURE_BLOB_AUDIT_ENDPOINT` |
| `forge-flow-staging-azure-ad-tenant-id` | `AZURE_AD_TENANT_ID` |
| `forge-flow-staging-azure-ad-client-id` | `AZURE_AD_CLIENT_ID` |

The last two are new for this slice. They tell the
`_defaultBlobClientFactory` in `tool/audit_anchor/main.dart` to switch
from the scaffold-rejecter to the live
`AzureBlobAuditAnchorBlobClient`.

> **Note — secret name prefix.** Override `-SecretPrefix` when
> targeting a non-staging environment, e.g. `-SecretPrefix
> forge-flow-production-`. Trailing dash is required. The default
> stays `forge-flow-staging-` so the proxy + job continue to share
> the same `forge-flow-staging-postgres-url` secret in staging.

### 4b. Deploy

```powershell
pwsh scripts/deploy_audit_anchor_job.ps1 `
  -Image "$IMAGE" `
  -Project "$FF_GCP_PROJECT" `
  -Region "$FF_GCP_REGION" `
  -SchedulerLocation "$FF_GCP_SCHEDULER_LOCATION" `
  -VpcConnector "$FF_GCP_VPC_CONNECTOR" `
  -VpcEgress all-traffic
```

The script:

1. Validates `Assert-PresentEnv` for every variable above.
2. Calls `Sync-SecretManagerSecret` for each of the five secrets
   (idempotent — describe-first add-version).
3. Runs `gcloud run jobs deploy` on first deploy or `gcloud run jobs
   update` on later runs, with `--vpc-connector` + `--vpc-egress`.
4. Runs `gcloud scheduler jobs create http` or `update http` for
   `forge-flow-audit-anchor-daily` at `55 23 * * *` Etc/UTC, in the
   Scheduler location (not necessarily the Cloud Run Job region).
5. Relies on the image's `ENTRYPOINT ["/app/audit_anchor"]` and
   `CMD ["sweep"]`; do not set `--command` or `--args` for the daily job.

### 4c. Verify Job + Scheduler

```bash
gcloud run jobs describe forge-flow-audit-anchor \
  --region="$FF_GCP_REGION" \
  --format='value(metadata.name, spec.template.spec.template.spec.containers[0].image)'

gcloud scheduler jobs describe forge-flow-audit-anchor-daily \
  --location="$FF_GCP_SCHEDULER_LOCATION" \
  --format='value(name, schedule, timeZone, state)'
# expected: ...  55 23 * * *  Etc/UTC  ENABLED
```

## Stage 5 — First manual run

```bash
gcloud run jobs execute forge-flow-audit-anchor \
  --region="$FF_GCP_REGION" \
  --wait

# Capture the latest execution name and stream logs.
EXEC=$(gcloud run jobs executions list \
  --region="$FF_GCP_REGION" \
  --job=forge-flow-audit-anchor \
  --limit=1 --format='value(name)')

gcloud beta run jobs executions logs read "$EXEC" \
  --region="$FF_GCP_REGION" > /tmp/audit_anchor_exec.log
```

Expected log shape (one line per chain):

```
audit_anchor starting (loaded secret names: AZURE_BLOB_AUDIT_CONTAINER, AZURE_BLOB_AUDIT_ENDPOINT, POSTGRES_URL, AZURE_AD_TENANT_ID, AZURE_AD_CLIENT_ID)
audit_anchor: sweep resolved N operator(s) from public.operators
audit_anchor: anchored <op-uuid> / <yyyy-mm-dd>
…
```

If the log shows `audit_anchor: blob client unavailable …`: live
Azure wiring did not pick up. Re-check that all five secrets are
attached (Stage 4a) and that the new env vars `AZURE_AD_*` reach the
container.

## Stage 6 — Verification

### 6a. DB row exists (RLS-bypass via `runAsSystem` is the orchestrator's job; here we read directly with admin creds)

```sql
SELECT operator_id, chain_date, row_count, blob_uri, blob_etag,
       anchored_at
  FROM public.audit_chain_anchors
 WHERE chain_date = (CURRENT_DATE - INTERVAL '1 day')::date
 ORDER BY operator_id;
```

Expect one row per active operator. `blob_uri` MUST start with
`https://${FF_AZ_STORAGE_ACCOUNT}.blob.core.windows.net/${FF_AUDIT_CONTAINER}/audit_anchors/`.
`blob_etag` MUST match the actual ETag in step 6b.

### 6b. Blob exists with matching ETag

```bash
az storage blob list \
  --account-name "$FF_AZ_STORAGE_ACCOUNT" \
  --container-name "$FF_AUDIT_CONTAINER" \
  --auth-mode login \
  --prefix "audit_anchors/" \
  --query "[].{name:name, etag:properties.etag, contentLength:properties.contentLength}" \
  -o table
```

Spot-check one blob's ETag against the corresponding `blob_etag` from
step 6a — they must match exactly (Azure quotes the value;
`audit_chain_anchors.blob_etag` stores it pre-quoted).

### 6c. End-to-end verify mode

```bash
gcloud run jobs execute forge-flow-audit-anchor \
  --region="$FF_GCP_REGION" \
  --args=verify,--operator-id=<OP_UUID>,--chain-date=<YYYY-MM-DD> \
  --wait
```

Expected exit code 0 and log line:

```
audit_anchor: ok <op-uuid> / <yyyy-mm-dd>
```

### 6d. Immutability proof — the overwrite test

Pick any anchored blob and attempt to overwrite it. Both 403 and 409
satisfy "refused" (`409 BlobAlreadyExists` from the writer's
`If-None-Match: *` is returned first by the service; `403 ImmutableBlob`
is the policy-level rejection if the client did not set the
conditional header).

```bash
TEST_BLOB="audit_anchors/<op-uuid>/<yyyy-mm-dd>.json"

# Use a temp file with arbitrary bytes — the upload must NOT succeed.
echo '{"tampered":true}' > /tmp/tamper.json

az storage blob upload \
  --account-name "$FF_AZ_STORAGE_ACCOUNT" \
  --container-name "$FF_AUDIT_CONTAINER" \
  --name "$TEST_BLOB" \
  --file /tmp/tamper.json \
  --overwrite \
  --auth-mode login
# expected: AzureHttpError 403 ImmutableBlob
#       OR: AzureHttpError 409 BlobAlreadyExists
# either is the success outcome for this proof.

rm /tmp/tamper.json
```

### 6e. No secrets in the captured log

```bash
grep -E '(eyJ|Bearer |password=|sas=|key=)' /tmp/audit_anchor_exec.log
# expected: (no output)
```

## Rotation pattern

Secret rotation is the same pattern as the advisor proxy: update the
operator's non-repo env loader, rerun `scripts/deploy_audit_anchor_job.ps1`,
and let the script add fresh Secret Manager versions before redeploying the
Job. The Job reads only Secret Manager refs at execution time; never paste
secret values into this runbook.

Container rotation is intentionally separate. Build a new image from the repo
root, then rerun Stage 4 with the new `-Image` value. The blob container and
existing `audit_chain_anchors` rows are durable evidence and are not rotated
by a code deploy.

## Rollback

The Cloud Run Job + Scheduler are reversible. The blob container, its
contents, and its locked immutability policy are NOT — that is the
point of the slice.

```bash
# Pause future scheduled executions.
gcloud scheduler jobs pause forge-flow-audit-anchor-daily \
  --location="$FF_GCP_SCHEDULER_LOCATION"

# (Optional) delete the Job — leaves blobs and DB rows intact.
gcloud run jobs delete forge-flow-audit-anchor \
  --region="$FF_GCP_REGION" --quiet
```

To resume later: `gcloud scheduler jobs resume forge-flow-audit-anchor-daily ...`
(if paused) or re-run Stages 3–4 (if deleted).

**Cannot be rolled back:**

- Already-anchored blobs (immutable for 7 years from creation).
- The container immutability policy itself (locked).
- `audit_chain_anchors` rows (table is append-only at the grant
  shape — the migration revoked UPDATE/DELETE).

This is the design. Anchor evidence is supposed to outlive the
deploy.

## Triage matrix

| Symptom | Probable cause | First action |
| --- | --- | --- |
| `audit_anchor: blob client unavailable …` | `AZURE_AD_*` secrets missing or empty in the Cloud Run env | Re-check Stage 4a sync output; redeploy |
| `Azure AD token exchange returned HTTP 400` | Federated credential subject mismatch (numeric unique ID drift) | Reconfirm Stage 2a; rerun preflight item 4 + 8 |
| `Azure Blob PUT … returned HTTP 401` | RBAC missing or storage account `allowSharedKeyAccess=true` (rejected by tenant policy) | Stage 2b + preflight item 11 |
| `existing immutable blob disagrees with current in-DB chain` | Forensic-grade chain divergence — DO NOT auto-recover | Escalate per `audit_chain_verify_runbook.md` |
| `409 BlobAlreadyExists` on first run for a chain | Previous partial run wrote blob, crashed before DB insert | Expected behavior — orchestrator's recovery path inserts the row using the blob's `anchored_at` and reports `already anchored` |
| Scheduler triggers but execution exits non-zero with `chain hash mismatch` | In-DB chain self-verification failed BEFORE blob write | Escalate per `audit_chain_verify_runbook.md` (no anchor was written; data integrity issue) |

## Live mutations performed by this runbook (audit trail)

In execution order:

1. Cloud Build: image tag `forge-flow/audit-anchor:${SHORT_SHA}` + `:latest` (Stage 3).
2. Azure AD: federated credential `forge-flow-audit-anchor-cloudrun` (Stage 2a).
3. Azure RBAC: `Storage Blob Data Contributor` at container scope (Stage 2b).
4. Azure Storage: container `audit-chain-anchors-immutable` create + locked 2555-day immutability policy (Stage 2c–2d). **Irreversible.**
5. GCP Secret Manager: 5 secret versions (Stage 4a; only on content change).
6. Cloud Run Jobs: `forge-flow-audit-anchor` deploy (Stage 4b).
7. Cloud Scheduler: `forge-flow-audit-anchor-daily` upsert at `55 23 * * *` Etc/UTC (Stage 4b).
8. Cloud Run Jobs: one manual execution (Stage 5).
9. After verification: zero or more daily scheduled executions begin firing.
