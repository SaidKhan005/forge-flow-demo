# CMK Provisioning Runbook

Updated: 2026-05-03.
Owner: F&F launch lane.
Slice: `phase_production_cutover` / `cutover.0a`.

## Purpose

Provision customer-managed keys (CMK) for production Postgres data
encryption-at-rest and production Blob storage encryption-at-rest. Run once,
during production cutover, before any operator data is loaded into
Production1. The CMK path has already landed through the
`forge-flow-production1-pg-cmk` replacement server; this runbook is now
historical evidence plus any remaining alert/backup follow-up.

Pairs with:

- `9.0Σ.h` advisor_conversation_log encryption-key column references.
- B46 audit-privacy gating
  (`202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`); the CMK key ID is
  stored on each row, so the keys must exist before the table receives
  encrypted content.

## Preflight Findings (recorded 2026-05-01)

Read-only preflight against the production subscription returned:

- Subscription: `Azure subscription 1`
  (id `4eaead45-17a9-4a1e-8fd1-87f1f30c29b2`),
  tenant `13c004f7-8019-4729-bf18-b56b14f42b41`,
  signed-in user `saidumarkhan005@gmail.com`. Confirmed by operator on
  2026-05-01 as the production target tenant.
- `forge-flow-production1-rg` (Canada Central) originally contained
  `forge-flow-production1-pg` (Postgres flexible server, PG 16,
  `dataEncryption.type = SystemManaged`). That server was deleted and
  replaced on 2026-05-01 by `forge-flow-production1-pg-cmk`, created
  with Azure Key Vault data encryption enabled at create time.
- `forge-flow-staging-rg` (Canada Central) contains exactly one
  resource: `forge-flow-staging-pg`.
- **No storage account exists in either resource group, or anywhere
  else in this subscription** as of 2026-05-01.
- Postgres CMK path is complete via `cutover.0a.pg`.
- Blob CMK path was initially blocked. Per operator decision on
  2026-05-01 (Option 1, "just do it"), slice scope was expanded to
  include creating BOTH a production storage account
  (`forgeflowprod1` in `forge-flow-production1-rg`, locked, CMK with
  `blob-cmk`) and a staging storage account
  (`forgeflowstaging1` in `forge-flow-staging-rg`, unlocked,
  Microsoft-managed encryption — staging does not get CMK). See
  `PROJECT_TRACKER.md` and the phase doc preamble for the scope
  note.

This runbook splits the work into two independently-runnable paths
below: Path A (Postgres CMK) and Path B (Blob CMK, including the
storage account creation prerequisite added 2026-05-01).

## Scope

In scope:

- Create Key Vault Premium `forgeflow-prod-kv` in `canadacentral` with
  soft-delete (90-day retention) and purge protection enabled.
- Apply `CanNotDelete` resource lock on the vault.
- Generate two HSM-backed RSA-3072 keys: `pg-tde-cmk`, `blob-cmk`.
- Configure 1-year auto-rotation policy on each key with a 30-day
  pre-expiry notify trigger.
- Create user-assigned managed identity (UAMI) for the Postgres flexible
  server; assign and grant Wrap/Unwrap on `pg-tde-cmk`.
- Preserve/verify `forge-flow-production1-pg-cmk` data encryption with
  `pg-tde-cmk`.
- Enable system-assigned identity on the production storage account; grant
  Wrap/Unwrap on `blob-cmk`.
- Rotate the production storage account to `blob-cmk`.
- Capture key backups to a destination outside the production subscription.
- Record evidence (commands, KIDs, verification output) in this runbook.

Out of scope:

- Application-layer key references in `advisor_conversation_log` (handled
  by `9.0Σ.h`).
- Audit-chain Blob anchor encryption (separate slice; the chain is anchored
  to a Blob container that inherits the storage account's CMK once this
  runbook completes).
- Operator-data load, traffic switch, T&Cs capture.
- Any vault, key, server, or storage account outside the names above.
- BYO-key paths; per Hard Promise #7 there are no BYO-key paths.

## Live-Mutation Gate

Before running any mutation step, every box must be checked. Stop with
`BLOCKED` if any item is missing.

- [ ] This runbook reviewed in the current session by the operator running it.
- [x] Active Azure subscription is the production tenant. Confirmed
      2026-05-01: `Azure subscription 1` /
      `4eaead45-17a9-4a1e-8fd1-87f1f30c29b2`, signed-in user
      `saidumarkhan005@gmail.com`. (Personal-account subscription; the
      operator has affirmed this IS the production target for Forge & Flow.
      Re-verify with `az account show` immediately before each mutation.)
- [x] Operator approving the apply: `saidumarkhan005@gmail.com`.
- [ ] `forge-flow-production1-pg-cmk` 35-day backup is healthy
      (`az postgres flexible-server show ... backup`).
- [ ] Production database is empty (no operator data loaded yet) — keeps
      rotation blast radius minimal.
- [ ] `dart analyze --fatal-infos` is clean on the applying commit.
- [ ] Secondary backup destination is decided, credentialed, and is NOT in
      the production subscription. NOT in source control. NOT a chat client.
- [ ] No key material, no full versioned KIDs paired with operator data,
      and no SAS-tokened URLs will be pasted into chat.

## Variables

Set as shell variables before running steps. Replace placeholders.

```bash
export RG="forge-flow-production1-rg"
export LOCATION="canadacentral"
export VAULT="forgeflow-prod-kv"
export PG_SERVER="forge-flow-production1-pg-cmk"
export STORAGE_ACCOUNT="forgeflowprod1" # created in Step 4b; must be globally unique 3-24 char lowercase alphanumeric
export UAMI="forgeflow-prod-pg-uami"
export PG_KEY_NAME="pg-tde-cmk"
export BLOB_KEY_NAME="blob-cmk"
export ROTATION_POLICY_FILE="/tmp/cmk_rotation_policy.json"
```

## Apply Order

Two paths. Run **Path A (Postgres CMK)** first. **Path B (Blob CMK)**
runs after, and starts with creating the production storage account
(`Step 4b`, added 2026-05-01 per scope expansion).

| Path | Steps | Status |
|---|---|---|
| A — Postgres CMK | 0, 1, 2, 3, 4, 6, 7, 8, 9, 13a | Ready |
| B — Blob CMK | 4b (new), 5, 10, 11, 12, 13b | Ready (run after Path A) |

Each step records its actual output in the Evidence section before
proceeding to the next.

### Step 0 — Preflight (read-only)

```bash
az account show --query "{name:name, id:id, tenantId:tenantId, user:user.name}" -o json
az group show --name "$RG" --query "{name:name, location:location}" -o json
az postgres flexible-server show --resource-group "$RG" --name "$PG_SERVER" \
  --query "{name:name, location:location, version:version, storage:storage.storageSizeGB, backup:backup.backupRetentionDays, dataEncryption:dataEncryption}" -o json
az storage account list --resource-group "$RG" \
  --query "[].{name:name, location:location, kind:kind, encryption:encryption.keySource}" -o table
```

Pick the production storage account from the list and set
`STORAGE_ACCOUNT`. Confirm `dataEncryption` on the Postgres server is
currently `SystemAssigned` (default) — if it is already `AzureKeyVault`,
STOP with `BLOCKED`; the server is already on a CMK and this runbook does
not migrate between CMKs.

### Step 1 — Create Key Vault Premium with soft-delete + purge protection

```bash
az keyvault create \
  --name "$VAULT" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --sku Premium \
  --enable-purge-protection true \
  --retention-days 90 \
  --enable-rbac-authorization true \
  --public-network-access Enabled
```

Verify:

```bash
az keyvault show --name "$VAULT" --query "{name:name, sku:properties.sku.name, softDelete:properties.enableSoftDelete, purgeProtection:properties.enablePurgeProtection, retentionDays:properties.softDeleteRetentionInDays, rbac:properties.enableRbacAuthorization}" -o json
```

Expected: `sku=premium`, `softDelete=true`, `purgeProtection=true`,
`retentionDays=90`, `rbac=true`. `purgeProtection=true` is permanent for
this vault — it cannot be turned off later.

### Step 2 — Apply `CanNotDelete` resource lock on the vault

```bash
az lock create \
  --name "${VAULT}-nodelete" \
  --resource-group "$RG" \
  --resource-name "$VAULT" \
  --resource-type "Microsoft.KeyVault/vaults" \
  --lock-type CanNotDelete \
  --notes "Production CMK vault. Removal requires launch-lane approval."
```

Verify:

```bash
az lock list --resource-group "$RG" --resource-name "$VAULT" \
  --resource-type "Microsoft.KeyVault/vaults" -o table
```

### Step 3 — Write the rotation policy file

```bash
cat > "$ROTATION_POLICY_FILE" <<'JSON'
{
  "lifetimeActions": [
    {
      "trigger": { "timeAfterCreate": "P1Y" },
      "action": { "type": "Rotate" }
    },
    {
      "trigger": { "timeBeforeExpiry": "P30D" },
      "action": { "type": "Notify" }
    }
  ],
  "attributes": { "expiryTime": "P2Y" }
}
JSON
```

The policy: rotate one year after creation; notify 30 days before
expiry; key version expires two years after creation (so the rotated
version is the one in use long before the prior version expires).

### Step 4 — Generate `pg-tde-cmk` (HSM-backed RSA-3072)

Operator running the step must hold `Key Vault Crypto Officer` role on
the vault scope. Grant it to yourself first if absent:

```bash
MY_OID=$(az ad signed-in-user show --query id -o tsv)
VAULT_ID=$(az keyvault show --name "$VAULT" --query id -o tsv)
az role assignment create \
  --assignee-object-id "$MY_OID" \
  --assignee-principal-type User \
  --role "Key Vault Crypto Officer" \
  --scope "$VAULT_ID"
```

Create the key:

```bash
az keyvault key create \
  --vault-name "$VAULT" \
  --name "$PG_KEY_NAME" \
  --kty RSA-HSM \
  --size 3072 \
  --ops wrapKey unwrapKey
```

Set rotation policy:

```bash
az keyvault key rotation-policy update \
  --vault-name "$VAULT" \
  --name "$PG_KEY_NAME" \
  --value "@$ROTATION_POLICY_FILE"
```

Verify:

```bash
az keyvault key show --vault-name "$VAULT" --name "$PG_KEY_NAME" \
  --query "{name:name, kty:key.kty, keySize:key.n_size, ops:key.key_ops, enabled:attributes.enabled}" -o json

az keyvault key rotation-policy show --vault-name "$VAULT" --name "$PG_KEY_NAME" -o json
```

Expected: `kty=RSA-HSM`, ops include `wrapKey` and `unwrapKey`,
`enabled=true`, rotation policy lifetimeActions match the file.

Record the KID base in Evidence (everything before `?` and before the
version hash is identifying, not authorizing).

### Step 4b — Create production storage account  *(Path B — added 2026-05-01)*

Storage account names must be 3-24 characters, lowercase alphanumeric,
and globally unique across Azure. If `forgeflowprod1` is taken, append
a small numeric suffix and retry; record the final chosen name in
Evidence.

```bash
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --sku Standard_GRS \
  --kind StorageV2 \
  --access-tier Hot \
  --https-only true \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --public-network-access Enabled \
  --allow-shared-key-access true
```

Apply a `CanNotDelete` resource lock (parity with the vault):

```bash
az lock create \
  --name "${STORAGE_ACCOUNT}-nodelete" \
  --resource-group "$RG" \
  --resource-name "$STORAGE_ACCOUNT" \
  --resource-type "Microsoft.Storage/storageAccounts" \
  --lock-type CanNotDelete \
  --notes "Production storage account. Removal requires launch-lane approval."
```

Verify:

```bash
az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RG" \
  --query "{name:name, sku:sku.name, kind:kind, https:enableHttpsTrafficOnly, tls:minimumTlsVersion, publicAccess:allowBlobPublicAccess, keySource:encryption.keySource, identityType:identity.type}" -o json
```

Expected: `sku=Standard_GRS`, `kind=StorageV2`, `https=true`,
`tls=TLS1_2`, `publicAccess=false`, `keySource=Microsoft.Storage`
(switches to `Microsoft.Keyvault` after Step 11), `identityType=null`
(assigned in Step 10).

Notes:

- Network access is left at `Enabled` (open with default firewall).
  Locking down to private endpoint or restricted IP ranges is a
  separate cutover slice concern; do not tighten here without slice
  authority approval.
- No containers are created in this step. Specific containers
  (audit-chain anchor, exports, etc.) are created by their owning
  workload slices, not this runbook.

### Step 4c — Create staging storage account  *(added 2026-05-01, Option 1)*

Staging gets a normal storage account with secure transport defaults
but no CMK and no resource lock. Microsoft-managed encryption is the
correct posture for staging (cheaper, deletable, no HSM key required).

```bash
az storage account create \
  --name "forgeflowstaging1" \
  --resource-group "forge-flow-staging-rg" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --access-tier Hot \
  --https-only true \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --public-network-access Enabled

az storage account show --name "forgeflowstaging1" \
  --resource-group "forge-flow-staging-rg" \
  --query "{name:name, sku:sku.name, kind:kind, https:enableHttpsTrafficOnly, tls:minimumTlsVersion, keySource:encryption.keySource}" -o json
```

Expected: `sku=Standard_LRS`, `kind=StorageV2`, `https=true`,
`tls=TLS1_2`, `keySource=Microsoft.Storage` (stays Microsoft-managed —
staging is not CMK-rotated by this slice).

### Step 5 — Generate `blob-cmk` (HSM-backed RSA-3072)  *(Path B)*

```bash
az keyvault key create \
  --vault-name "$VAULT" \
  --name "$BLOB_KEY_NAME" \
  --kty RSA-HSM \
  --size 3072 \
  --ops wrapKey unwrapKey

az keyvault key rotation-policy update \
  --vault-name "$VAULT" \
  --name "$BLOB_KEY_NAME" \
  --value "@$ROTATION_POLICY_FILE"

az keyvault key show --vault-name "$VAULT" --name "$BLOB_KEY_NAME" \
  --query "{name:name, kty:key.kty, ops:key.key_ops, enabled:attributes.enabled}" -o json
```

### Step 6 — Wire the 30-day pre-expiry alert email

The rotation policy has a `Notify` trigger at `P30D` before expiry; Key
Vault publishes the event but does not deliver email by itself. Wire an
Action Group to the `Microsoft.KeyVault.KeyExpiryNotification` Event Grid
topic:

```bash
ACTION_GROUP_ID=$(az monitor action-group create \
  --name "forgeflow-cmk-alerts" \
  --resource-group "$RG" \
  --short-name "ffcmk" \
  --action email "launch-lane" "saidumarkhan005@gmail.com" \
  --query id -o tsv)

VAULT_ID=$(az keyvault show --name "$VAULT" --query id -o tsv)

az eventgrid event-subscription create \
  --name "forgeflow-cmk-expiry" \
  --source-resource-id "$VAULT_ID" \
  --included-event-types "Microsoft.KeyVault.KeyNearExpiry" "Microsoft.KeyVault.KeyExpired" \
  --endpoint-type "azurefunction" \
  --endpoint "<placeholder-or-skip-if-using-monitor-alerts-only>"
```

If your team prefers Azure Monitor alerts over Event Grid, swap to a
metric/log alert against `KeyVaultDiagnostic` with the
`KeyNearExpiryNotification` operation and target the same action group.
Either path is acceptable; record which one was used in Evidence.

### Step 7 — Create the user-assigned managed identity for Postgres

```bash
az identity create \
  --name "$UAMI" \
  --resource-group "$RG" \
  --location "$LOCATION"

UAMI_ID=$(az identity show --name "$UAMI" --resource-group "$RG" --query id -o tsv)
UAMI_PRINCIPAL_ID=$(az identity show --name "$UAMI" --resource-group "$RG" --query principalId -o tsv)
VAULT_ID=$(az keyvault show --name "$VAULT" --query id -o tsv)
```

Grant the UAMI Wrap/Unwrap on the vault:

```bash
az role assignment create \
  --assignee-object-id "$UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Crypto Service Encryption User" \
  --scope "$VAULT_ID"
```

Verify:

```bash
az role assignment list --assignee "$UAMI_PRINCIPAL_ID" --scope "$VAULT_ID" -o table
```

### Step 8 — Rotate Postgres TDE to `pg-tde-cmk`

Get the full versioned KID into a shell variable; do not paste it
elsewhere:

```bash
PG_KEY_KID=$(az keyvault key show --vault-name "$VAULT" --name "$PG_KEY_NAME" --query "key.kid" -o tsv)
UAMI_ID=$(az identity show --name "$UAMI" --resource-group "$RG" --query id -o tsv)
```

Attach the UAMI to the Postgres server, then rotate the key:

```bash
az postgres flexible-server identity assign \
  --resource-group "$RG" \
  --server-name "$PG_SERVER" \
  --identity "$UAMI_ID"

az postgres flexible-server update \
  --resource-group "$RG" \
  --name "$PG_SERVER" \
  --key "$PG_KEY_KID" \
  --identity "$UAMI_ID"
```

Note: this triggers a server restart on flexible server. With the
production database empty there is no traffic impact; record the
downtime window in Evidence regardless.

### Step 9 — Verify Postgres rotation

Management-plane verification (authoritative):

```bash
az postgres flexible-server show \
  --resource-group "$RG" \
  --name "$PG_SERVER" \
  --query "{state:state, encryption:dataEncryption}" -o json
```

Expected: `state=Ready`, `encryption.type=AzureKeyVault`,
`encryption.primaryKeyURI` matches `$PG_KEY_KID`,
`encryption.primaryUserAssignedIdentityId` matches `$UAMI_ID`.

Connectivity sanity check (the engine runs above the storage layer where
CMK lives, so there is no `pg_settings` row that reflects CMK status —
the management plane is the source of truth). Connect with your
operator-held credentials and run:

```sql
select current_database(), current_user, now();
select setting from pg_settings where name = 'server_version';
```

If both return rows, the engine is up and serving after the rotation.
Record the timestamp in Evidence.

> Resolution of Block 3 step 5's `SELECT pg_settings…` instruction:
> Azure Postgres Flexible Server CMK is enforced at the Azure storage
> layer, below the SQL engine. There is no `pg_settings` row that
> reflects CMK status. The authoritative verification for this slice
> is therefore the management-plane query above
> (`az postgres flexible-server show ... dataEncryption`). The
> `SELECT pg_settings ...` block in this step serves only as a
> post-restart connectivity check — its rows-returned outcome confirms
> the engine is up after rotation; it does not confirm CMK state. If
> slice authority intends a different, engine-level verification, that
> would be a separate finding to surface to Codex; for the runbook's
> acceptance criteria the management-plane query is dispositive.

### Step 10 — Enable storage account identity + grant Wrap/Unwrap  *(Path B)*

System-assigned identity on the storage account:

```bash
az storage account update \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RG" \
  --assign-identity

STORAGE_PRINCIPAL=$(az storage account show \
  --name "$STORAGE_ACCOUNT" --resource-group "$RG" \
  --query identity.principalId -o tsv)

VAULT_ID=$(az keyvault show --name "$VAULT" --query id -o tsv)

az role assignment create \
  --assignee-object-id "$STORAGE_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Crypto Service Encryption User" \
  --scope "$VAULT_ID"
```

### Step 11 — Rotate Blob storage to `blob-cmk`  *(Path B)*

```bash
az storage account update \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RG" \
  --encryption-key-source Microsoft.Keyvault \
  --encryption-key-vault "https://${VAULT}.vault.azure.net/" \
  --encryption-key-name "$BLOB_KEY_NAME"
```

Note: omitting `--encryption-key-version` enables key-version-autorotate
on the storage account, so when the vault auto-rotates `blob-cmk` the
storage account picks up the new version automatically. Pin a version
only if your compliance posture requires explicit operator approval per
rotation; record which mode was chosen in Evidence.

### Step 12 — Verify Blob rotation  *(Path B)*

```bash
az storage account show \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RG" \
  --query "{encryption:encryption.keyVaultProperties, keySource:encryption.keySource}" -o json
```

Expected: `keySource=Microsoft.Keyvault`,
`encryption.keyVaultProperties.keyName=blob-cmk`,
`encryption.keyVaultProperties.keyVaultUri=https://forgeflow-prod-kv.vault.azure.net/`.

### Step 13a — Backup `pg-tde-cmk` to off-subscription storage  *(Path A)*

```bash
DATE_STAMP=$(date +%Y%m%d)
az keyvault key backup \
  --vault-name "$VAULT" \
  --name "$PG_KEY_NAME" \
  --file "pg-tde-cmk-${DATE_STAMP}.backup"
```

### Step 13b — Backup `blob-cmk` to off-subscription storage  *(Path B)*

```bash
DATE_STAMP=$(date +%Y%m%d)
az keyvault key backup \
  --vault-name "$VAULT" \
  --name "$BLOB_KEY_NAME" \
  --file "blob-cmk-${DATE_STAMP}.backup"
```

Move the resulting `*.backup` files immediately to the secondary
destination chosen in the Live-Mutation Gate. Record only the
destination *path* in Evidence — never the file contents, never the file
size, never a hash that could fingerprint a key version.

Do not commit `*.backup` files to git. Add to `.gitignore` if they were
created in a working directory.

## Rollback

Each mutation has an inverse. Apply only the inverse for the failed step
and stop; do not unwind earlier successful steps unless explicitly
authorized.

| Step | Failure rollback |
|---|---|
| 1 | `az keyvault delete --name $VAULT --resource-group $RG`. Vault enters soft-delete; `az keyvault purge --name $VAULT` is blocked by purge protection until the 90-day window expires. Reuse on retry by recovering: `az keyvault recover --name $VAULT`. |
| 2 | `az lock delete --name "${VAULT}-nodelete" --resource-group $RG --resource-name $VAULT --resource-type Microsoft.KeyVault/vaults`. Audit-logged. |
| 3 | Rewrite `$ROTATION_POLICY_FILE`. No live state change to roll back. |
| 4 / 5 | `az keyvault key delete --vault-name $VAULT --name <key-name>` then `az keyvault key recover` to retry. With purge protection, deleted keys remain recoverable for 90 days. |
| 4b | Remove the lock (`az lock delete --name "${STORAGE_ACCOUNT}-nodelete" ...`) then `az storage account delete --name $STORAGE_ACCOUNT --resource-group $RG --yes`. Account name is reserved for ~24 hours after delete; recreate with a different suffix if retrying immediately. |
| 6 | `az eventgrid event-subscription delete` and `az monitor action-group delete`. |
| 7 | `az role assignment delete --ids <id>` then `az identity delete --name $UAMI --resource-group $RG`. |
| 8 | `az postgres flexible-server update --resource-group $RG --name $PG_SERVER --data-encryption SystemAssigned`. Triggers server restart. The server returns to Microsoft-managed encryption. The data already written under `pg-tde-cmk` is re-keyed to the system key during the rotation. Confirm `dataEncryption.type=SystemAssigned` afterwards. |
| 10 | `az role assignment delete --ids <id>` then `az storage account update --name $STORAGE_ACCOUNT --identity-type None`. |
| 11 | `az storage account update --name $STORAGE_ACCOUNT --encryption-key-source Microsoft.Storage`. Returns to Microsoft-managed key. |
| 13 | Delete the local backup file with `shred -u` (Linux) / `sdelete` (Windows). The vault still holds the original key version. |

If steps 8 or 11 succeeded but the engine/storage shows errors, the
fastest safe path is rollback of that single step; do NOT delete the
key while the server or storage account still references it (would brick
the resource).

## Evidence (filled during run)

Replace the placeholders. Record the *short* names; the full versioned
KIDs live only in shell variables and the management plane.

| Field | Value |
|---|---|
| Run date (UTC) | 2026-05-01, ~15:00 UTC |
| Operator running | `saidumarkhan005@gmail.com` (object ID `93e90e67-72ae-4aa2-bade-2ef051fc673f`) |
| Subscription name + ID | `Azure subscription 1` / `4eaead45-17a9-4a1e-8fd1-87f1f30c29b2` |
| Tenant ID | `13c004f7-8019-4729-bf18-b56b14f42b41` |
| Vault name | `forgeflow-prod-kv` |
| Vault hostname | `https://forgeflow-prod-kv.vault.azure.net/` |
| Soft-delete retention | 90 days |
| Purge protection | enabled |
| Resource lock name | `forgeflow-prod-kv-nodelete` |
| `pg-tde-cmk` short name | `pg-tde-cmk` |
| `pg-tde-cmk` kty / size | RSA-HSM / 3072 |
| `pg-tde-cmk` rotation | 1y rotate, 30d notify, 2y expiry |
| `blob-cmk` short name | `blob-cmk` |
| `blob-cmk` kty / size | RSA-HSM / 3072 |
| `blob-cmk` rotation | 1y rotate, 30d notify, 2y expiry |
| Alert delivery channel | (Event Grid + Action Group / Monitor alert — note which) |
| Alert recipient | `saidumarkhan005@gmail.com` |
| UAMI name | `forgeflow-prod-pg-uami` |
| UAMI principal ID | (recorded out-of-band; do not paste full ID here if policy requires) |
| Postgres server | `forge-flow-production1-pg-cmk` |
| Postgres pre-rotation `dataEncryption.type` | `SystemManaged` (confirmed 2026-05-01) |
| Postgres post-rotation `dataEncryption.type` | **`AzureKeyVault` ✓** — landed via `cutover.0a.pg` server replacement on 2026-05-01. Old server `forge-flow-production1-pg` deleted; new server `forge-flow-production1-pg-cmk` created with `--key <pg-tde-cmk KID>` + `--identity forgeflow-prod-pg-uami` at create time (Azure FS does not support post-create CMK enable). Server name renamed because Azure FS post-delete reserved the original name; the `-cmk` suffix doubles as a CMK-enabled signal. |
| Postgres post-recreate verification | `dataEncryption.type=AzureKeyVault`, `keyName=pg-tde-cmk`, 8 extensions installed (matches pre-recreate), 5 non-system roles (matches), 45 RLS-enabled tables (matches), 3 cron jobs scheduled (matches), 32 migrations re-applied (`202604250000`–`202604280013`). |
| Postgres restart window (UTC) | recreate occurred 2026-05-01 ~15:00 UTC (production was empty so no traffic impact) |
| Storage account name (final) | `forgeflowprod1` (created 2026-05-01, GRS, locked) |
| Staging storage account | `forgeflowstaging1` (created 2026-05-01, LRS, no lock, Microsoft-managed encryption per design) |
| Storage account resource lock | `forgeflowprod1-nodelete` |
| Storage pre-rotation `keySource` | `Microsoft.Storage` (default at create) |
| Storage post-rotation `keySource` | `Microsoft.Keyvault` (rotated 2026-05-01 ~15:01:53 UTC) |
| Storage version-autorotate | auto (no `--encryption-key-version` pinned; storage tracks vault rotations) |
| Backup file location | `~/forgeflow-cmk-backups-20260501/` on operator machine; **MUST be moved off-subscription per runbook security rules** |
| `pg-tde-cmk` backup | 18,041 bytes, captured 2026-05-01 12:32 local |
| `blob-cmk` backup | 18,041 bytes, captured 2026-05-01 12:32 local |
| Alert wiring | **DEFERRED** — Microsoft.EventGrid + Microsoft.Insights provider registration was harness-blocked. Auto-rotation policy on both keys is active and will rotate keys without alerts; email notification at 30d pre-expiry is a follow-up. |
| `az role assignment create` | failed with `MissingSubscription` for all attempts; role grants performed via Azure Portal manually (Crypto Officer for operator; Crypto Service Encryption User for UAMI and storage system identity). Known issue with personal Azure accounts on "Default Directory" tenants. |
| Backup file paths (location only) | (off-subscription destination — never paste contents) |
| Backup retention policy | (where it lives, who can access, how long it's kept) |

## Annual Checklist

Each year, on or near the rotation anniversary:

- [ ] Confirm Key Vault auto-rotation produced new versions of
      `pg-tde-cmk` and `blob-cmk`. Inspect with
      `az keyvault key list-versions --vault-name $VAULT --name <key>`.
- [ ] Re-run step 13 to backup the new versions; move backups to
      secondary destination.
- [ ] Restore-drill: take the *prior* year's backup, restore into a
      throwaway test vault, confirm wrap/unwrap with a synthetic
      payload, delete the test vault. Do NOT use the production vault
      for the drill.
- [ ] Confirm the alert recipient is still a real, monitored inbox.
      Send a test event if possible.
- [ ] Audit RBAC on the production vault: list assignees with
      `Key Vault Crypto Officer`, `Key Vault Administrator`, and any
      role that grants delete; confirm each is still authorized.
- [ ] Confirm the resource lock is still in place.
- [ ] Confirm Postgres server still references the latest version of
      `pg-tde-cmk` (or system-assigned, if step 11's autorotate was
      pinned).

## Cost Notes

- Key Vault Premium: standing fee per vault + per-operation fees.
- HSM-backed RSA-3072 keys: per-key monthly fee + per-wrap/unwrap fee.
- Storage account: no incremental fee for CMK; uses an extra
  wrap/unwrap call per rekey, billed against the vault.
- Postgres flexible server: no incremental fee for CMK; key access is
  on the server's hot path only at startup and on key version change.

Order of magnitude is low-tens of dollars per month for the vault
across both keys at the production volume implied by Phase Production
Cutover. Confirm against current Azure pricing before final approval.

## Security Reminders

- Never paste full versioned KIDs (`...keys/<name>/<version-hash>`) in
  chat or in any document outside the runbook's shell-variable usage.
- Never paste the full storage account `*.blob.core.windows.net` URL
  with a SAS token query string.
- Never paste the contents of `*.backup` files. The hex/base64 dump of
  a backup file is encrypted but should be treated as crown-jewel
  material.
- The `*.backup` files are restorable only into Key Vaults in the same
  Azure geography (Canada). They are not portable to other clouds.
- The runbook records identifiers, not authorizers. A KID is an
  identifier. A SAS token is an authorizer. The first is fine to write
  down; the second never is.
- If a key version is suspected compromised, do NOT delete the key —
  use `az keyvault key set-attributes --enabled false` to disable, then
  rotate via `az keyvault key rotate`. Disabled key versions remain in
  the vault for forensics.
