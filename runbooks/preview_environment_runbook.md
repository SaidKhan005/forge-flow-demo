# Preview Environment Runbook

Status: Active
Last updated: 2026-05-06

Use this runbook when a branch needs end-to-end proof before shared staging or
production. Preview deploys separate Cloud Run services, so shared staging users
are not routed onto branch revisions.

## When To Use Preview

Use preview for:

- feature branches
- admin-console UX iterations
- branch or PR browser acceptance
- CORS and auth wiring checks
- proxy route checks
- safe read-only end-to-end smoke tests
- performance probes before shared staging

Do not deploy experimental branches directly to shared staging when preview has
not passed.

## Safety Model

Preview isolates runtime services:

- preview admin frontend
- preview proxy/backend
- preview admin origin in proxy CORS
- zero shared-staging traffic changes

Preview data safety depends on the Secret Manager prefix:

| Mode | Secret prefix | Data impact |
| --- | --- | --- |
| Runtime-isolated preview | `forge-flow-staging-` | Separate services, shared staging data. Safe for read-only smoke. Do not submit writes without action-time approval. |
| Data-isolated preview | `forge-flow-preview-` | Separate services and separate preview database/secrets. Use this for write testing after preview secrets are provisioned. |

The default is runtime-isolated preview because staging secrets already exist.
To make preview fully data-isolated, provision the preview Secret Manager
namespace with preview `POSTGRES_URL` and `POSTGRES_ADMIN_URL`, then run with
`-SecretPrefix forge-flow-preview-`.

Do not point preview at production secrets.

## Deploy Preview

From the branch or worktree under test:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
  -PreviewName backend-surface-audit `
  -SkipApiEnable `
  -SkipSecretManagerSync
```

The script uses separate service names derived from `-PreviewName`:

- `forge-flow-preview-<preview-name>-admin`
- `forge-flow-preview-<preview-name>-proxy`

Example:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
  -PreviewName ux-nav `
  -SkipApiEnable `
  -SkipSecretManagerSync
```

Creates:

- `forge-flow-preview-ux-nav-admin`
- `forge-flow-preview-ux-nav-proxy`

The default Forge & Flow staging project preview uses the staging proxy VPC
connector `ff-staging-proxy-egress` so the preview proxy can reach Postgres
through the same controlled egress path as shared staging. Override
`-VpcConnector` only when deploying into a project with a different connector
or no Azure Postgres dependency.

The script:

1. deploys the preview proxy
2. discovers the preview proxy URL
3. deploys the preview admin console with `ADMIN_PROXY_BASE_URI` set to that
   proxy URL
4. discovers the preview admin URL
5. redeploys the preview proxy with the preview admin origin in CORS
6. verifies Cloud Run Ready revisions and 100 percent traffic
7. verifies proxy `/readyz`
8. verifies admin-origin CORS preflight

To preview the resolved service names and scripts without deploying:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
  -PreviewName ux-nav `
  -PrintCommandOnly
```

## Deploy Data-Isolated Preview

Use this only after preview secrets exist in Secret Manager.

Required preview secrets:

- `forge-flow-preview-anthropic-api-key`
- `forge-flow-preview-voyage-api-key`
- `forge-flow-preview-postgres-url`
- `forge-flow-preview-postgres-admin-url`
- `forge-flow-preview-firebase-web-api-key`
- `forge-flow-preview-service-principal-jwt-secret`

Then deploy:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
  -PreviewName backend-surface-audit `
  -SecretPrefix forge-flow-preview- `
  -SkipApiEnable
```

Do not run write tests against a runtime-isolated preview that still uses
staging data unless the operator explicitly approves the exact write at action
time.

## Verify Preview

After deployment, record:

- branch and commit
- admin URL with cache-bust parameter
- proxy URL
- admin Cloud Run revision
- proxy Cloud Run revision
- both services serving 100 percent traffic
- proxy `/readyz`
- admin-origin CORS preflight
- Browser Use smoke results
- database mode, either staging data or isolated preview data
- any write-action boundary

Use the deployed preview URLs in the performance probe:

```powershell
dart run tool\perf_gate\staging_console_probe.dart `
  --run `
  --admin-url=<preview-admin-url> `
  --proxy-url=<preview-proxy-url> `
  --admin-revision=<preview-admin-revision> `
  --proxy-revision=<preview-proxy-revision> `
  --label=<branch-or-pr-label> `
  --write-json=build\perf_gate\<label>.json `
  --enforce-budgets
```

Browser acceptance must use the preview admin URL, not shared staging.

Allowed without action-time approval:

- route switching
- filters and search
- scroll and table checks
- opening dialogs and canceling
- safe read-only refresh
- console or network inspection

Stop for action-time approval before:

- submitting a form
- changing pricing, tiers, provider credentials, feature flags, or status
- creating, suspending, deleting, rotating, replaying, rebuilding, or exporting
  live data
- running aggressive load tests

## Promote To Shared Staging

Promote only after preview passes.

1. Rebase or merge branch onto current `origin/master`.
2. Run local gates.
3. Push the branch and update the PR with preview evidence.
4. Deploy shared staging proxy with `scripts\deploy_staging_proxy.ps1`.
5. Deploy shared staging admin with `scripts\deploy_admin_console.ps1`.
6. Verify shared staging Cloud Run revisions, 100 percent traffic, `/readyz`,
   CORS, Browser Use smoke, and performance budgets.
7. Update the PR with staging evidence.

Shared staging is release-candidate proof. It should not be the first live
runtime for new UX or proxy wiring.

## Promote To Production

Production remains gated by the production cutover runbooks and the tracker.
Do not deploy production from a preview branch.

Required before production:

- PR merged to `master`
- production unfreeze explicitly approved
- production migration drift checked
- production secrets and service accounts confirmed
- production proxy deployed with production CORS origins
- production frontend deployed against production proxy
- production Cloud Run traffic verified
- production smoke and rollback plan recorded

Production deployment uses environment-specific parameters on the existing
deploy scripts. Follow:

- `runbooks/phase_9_production1_migration_apply_runbook.md`
- `runbooks/proxy_redeploy_reset_confirm_account_info_runbook.md`
- `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`

## Cleanup

Preview services are cheap by default because `scripts\deploy_preview_stack.ps1`
uses `-MinInstances 0`. Delete stale preview services when a PR is merged or
abandoned:

```powershell
gcloud run services delete <preview-admin-service> `
  --project forge-flow-staging `
  --region northamerica-northeast2

gcloud run services delete <preview-proxy-service> `
  --project forge-flow-staging `
  --region northamerica-northeast2
```

Do not delete shared staging or production services from preview cleanup.
