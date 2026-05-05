# Preview Environment Runbook

Status: Active
Last updated: 2026-05-05

Use this runbook when staging is being used by operators, reviewers, or a
demo, and a branch still needs deployed end-to-end proof before it is promoted.

The preview environment is a separate Cloud Run stack:

- preview admin frontend
- preview proxy/backend
- preview frontend origin in proxy CORS
- zero shared-staging traffic changes

## When To Use Preview

Use preview for:

- feature branches
- admin-console UX iterations
- branch/PR browser acceptance
- CORS and auth wiring checks
- proxy route checks
- safe read-only end-to-end smoke tests
- performance probes before shared staging

Do not deploy experimental branches directly to shared staging when people are
using staging.

## Safety Model

Preview protects shared staging users from runtime changes because it deploys
separate Cloud Run services.

Preview data safety depends on which Secret Manager prefix is used:

| Mode | Secret prefix | Data impact |
| --- | --- | --- |
| Runtime-isolated preview | `forge-flow-staging-` | Separate services, shared staging data. Safe for read-only smoke. Do not submit writes without action-time approval. |
| Data-isolated preview | `forge-flow-preview-` | Separate services and separate preview database/secrets. Use this for write testing after preview secrets are provisioned. |

Current default is runtime-isolated preview because staging secrets already
exist. To make preview fully data-isolated, provision the preview Secret Manager
namespace with preview `POSTGRES_URL` and `POSTGRES_ADMIN_URL`, then run the
same script with `-SecretPrefix forge-flow-preview-`.

## Deploy Preview

From the branch under test:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
  -PreviewName pr-136 `
  -SkipApiEnable `
  -SkipSecretManagerSync
```

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
6. verifies Cloud Run Ready revisions, 100% traffic to the latest Ready
   revision, `/readyz`, and browser-origin CORS preflight

Default service names for `-PreviewName preview` are:

- `forge-flow-preview-admin-console`
- `forge-flow-preview-proxy`

For PR or branch previews, use a short slug:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
  -PreviewName ux-nav `
  -SkipApiEnable `
  -SkipSecretManagerSync
```

This creates:

- `forge-flow-ux-nav-admin-console`
- `forge-flow-ux-nav-proxy`

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
  -PreviewName pr-136 `
  -SecretPrefix forge-flow-preview- `
  -ProxyBaseUriEnvVarName FORGE_FLOW_PREVIEW_PROXY_BASE_URI `
  -SkipApiEnable
```

Do not point preview at production secrets. Do not run write tests against a
runtime-isolated preview that still uses staging data unless the operator
explicitly approves that exact write.

## Verify Preview

After deployment, record:

- branch and commit
- admin URL with cache-bust parameter
- proxy URL
- admin Cloud Run revision
- proxy Cloud Run revision
- both services serving 100% traffic
- proxy `/readyz`
- admin-origin CORS preflight
- Browser Use smoke results
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
  --write-json=build\reports\<label>.json `
  --enforce-budgets
```

Browser acceptance must use the preview admin URL, not shared staging.

Allowed without action-time approval:

- route switching
- filters and search
- scroll and table checks
- opening dialogs and canceling
- safe read-only refresh
- console/network inspection

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
6. Verify shared staging Cloud Run revisions, 100% traffic, `/readyz`, CORS,
   Browser Use smoke, and performance budgets.
7. Update the PR with staging evidence.

Shared staging should be treated as release-candidate proof, not as the first
place where new UX or wiring is tested.

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
