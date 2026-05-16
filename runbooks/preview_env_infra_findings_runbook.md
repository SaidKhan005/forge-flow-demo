# Preview-Env Infra Findings — Runbook

Sprint: `pressure.preview.v1` (2026-05-08 to 2026-05-09; closeout 2026-05-16)
Origin: `docs/archive/_execution/2026-05-08_pressure_preview_findings.md` Section 4
Active tracker line: `docs/POST_HARDENING_FOLLOWUPS.md` "Closeout status (2026-05-09 end-of-day)"

This runbook consolidates the three infra-side findings the
`pressure.preview.v1` sprint flagged that needed Cloud Run / operator
hands rather than code changes. One has already been closed by a
subsequent code change (PF4 hardening); the other two remain
operator-led against the preview Cloud Run + preview Postgres surfaces.

When the operator sits down at Cloud Run, this is the spec to consult.
The runbook is the breadcrumb for "where do I bump this in the future?"
as much as it is the current to-do.

Sequence in the order in the **Sequencing** section at the bottom.

---

## Finding 1 — Postgres pool exhaustion (P1)

### Status

**CLOSED** via commit `7c85e5a4` on 2026-05-13 (A4.2 performance fixes).
`POSTGRES_POOL_MAX_CONNECTIONS=20` is now the documented default for
every Cloud Run service; the upper bound is enforced in code at 200 by
`kPostgresMaxConnectionsPerPoolUpperBound`. Documented surface lives
in `runbooks/cloud_run_env_vars.md`.

Documented here as a historical breadcrumb so a future operator who
sees pool exhaustion again knows exactly which env var to bump and
what ceiling the code enforces.

### Diagnosis (Phase 3A original)

640 of the 1000 5xx responses in the Phase 3A smoke run carried
`DependencyTimeoutException(surface: postgres, operation: acquire_connection, elapsed_ms: 10000)`.
The preview proxy's `PgPool` was hitting the 10s borrow timeout under
sustained 17-vendor × 10-op × 2/min load (about 340 reqs/min sustained).
p95 latency was 5x the 2000ms budget for the same reason. Aggregator
finding category: `connection_pool_exhaustion`.

### What was fixed

- Env var name: `POSTGRES_POOL_MAX_CONNECTIONS`
  - Resolved in `lib/infrastructure/persistence/postgres/postgres_executor.dart`
    by `resolvePostgresMaxConnectionsPerPool`.
  - Const symbol: `kPostgresPoolMaxConnectionsEnvVar`.
  - Fallback default: `kPostgresDefaultMaxConnectionsPerPool` = 20.
  - Upper bound: `kPostgresMaxConnectionsPerPoolUpperBound` = 200
    (env values above this fall back to the default with a warning log).
- The deployment scripts and `runbooks/cloud_run_env_vars.md` now set
  `POSTGRES_POOL_MAX_CONNECTIONS=20` explicitly on every Cloud Run
  service (proxy, sync worker, admin console).
- PF4 sizing math (from `runbooks/cloud_run_env_vars.md`): up to 3
  services × 2 instances × 20 connections = 120 sessions, within the
  Azure DB Flexible Server 150-connection soft ceiling.

### Future tuning

If load grows beyond what `POSTGRES_POOL_MAX_CONNECTIONS=20` per
instance handles, bump the env var on the affected Cloud Run service:

```bash
gcloud run services update <service-name> \
  --update-env-vars POSTGRES_POOL_MAX_CONNECTIONS=<N>
```

`<N>` must respect the Azure DB Flexible Server budget: peak sessions
across **all** Cloud Run services and instances must stay under
`max_connections`. The current PF4 envelope (3 services × 2 instances)
allows headroom for `N=24` before approaching 150 connections. Above
that, either reduce instance count, lower N on a less-busy service,
or raise the Azure DB tier.

### Verification (post any future bump)

Re-run the Phase 3A smoke harness against preview:

```bash
dart run tool/pressure/p3a_webhook_flood.dart \
  --ops=10 --duration=5min --rate=2
```

Expected after a successful bump:

- 0 `DependencyTimeoutException(surface: postgres, operation: acquire_connection)`
  rows in the response bodies.
- 5xx rate under 5%.
- p95 latency under 2000ms.

Full-scale verification (only after the bump rides through smoke):

```bash
dart run tool/pressure/p3a_webhook_flood.dart \
  --ops=100 --duration=30min --rate=10 --retry-each=3
```

---

## Finding 2 — Vendor-capability registry gap (P2)

### Status

**OPEN** as of 2026-05-16.

### Diagnosis (Phase 3A original)

6 vendors returned
`{"outcome":"unknownVendor","records_written":0,"message":"unknown vendor"}`
for every webhook POST against the preview env:

- `aloha_ncr_voyix`
- `clover`
- `libro`
- `quickbooks_time`
- `seven_shifts`
- `square`

The route IS registered (the structured response shape is returned),
but the proxy's vendor adapter factory maps do not have a factory
entry for these six in the preview env.

### Root cause (verified on master 2026-05-16)

The "vendor-capability registry" is the union of three runtime maps
populated at proxy boot by `buildPhase8VendorIntegrationFactoriesFromCredentials`
in `tool/advisor_proxy/phase_8_vendor_integration_factories.dart`:

- `posAdapterFactories`
- `laborAdapterFactories`
- `reservationAdapterFactories`

`lib/services/integration/inbound_webhook_handler.dart` resolves the
factory via `_resolveAdapter(...)` (line 626) and returns
`WebhookOutcome.unknownVendor` (404) when no factory entry exists.

**The registry is env-driven, not static code.** Each of the six
vendors in the failure list has an optional app-credential bundle
that the binder body checks (`if (alohaNcrVoyixCredentials != null)`,
`if (cloverAppCredentials != null)`, etc.). When the credentials are
absent, the vendor is added to `disabledVendors` with a structured
reason like `aloha_ncr_voyix_credentials_missing` and is **not**
registered into `posAdapterFactories` / `laborAdapterFactories` /
`reservationAdapterFactories`. The webhook handler then 404s any
incoming POST for that vendor because the factory map has no entry.

The required env-var bundles per vendor (canonical names from
`ProxySecretNames` in `tool/advisor_proxy/advisor_proxy.dart` lines
375-458 — all loaded as **optional** secrets per
`ProxySecretNames.optional`):

| Vendor | Required env vars (all must be set) |
|---|---|
| `aloha_ncr_voyix` | `ALOHA_NCR_VOYIX_CLIENT_ID`, `ALOHA_NCR_VOYIX_CLIENT_SECRET`, `ALOHA_NCR_VOYIX_APPLICATION_KEY`, `ALOHA_NCR_VOYIX_ORGANIZATION_ID` |
| `clover` | `CLOVER_APP_TOKEN`, `CLOVER_APP_ID` |
| `libro` | `LIBRO_CLIENT_ID`, `LIBRO_CLIENT_SECRET` |
| `quickbooks_time` | `QUICKBOOKS_TIME_CLIENT_ID`, `QUICKBOOKS_TIME_CLIENT_SECRET` |
| `seven_shifts` | `SEVEN_SHIFTS_CLIENT_ID`, `SEVEN_SHIFTS_CLIENT_SECRET` |
| `square` | `SQUARE_CLIENT_ID`, `SQUARE_CLIENT_SECRET`, `SQUARE_NOTIFICATION_URL_HOST` |

When **any** secret in a bundle is missing, `hasXxxAppCredentials`
returns false and that vendor stays unregistered. Partial bundles
are treated the same as no bundle.

### Fix

1. Confirm which Secret Manager namespace the preview Cloud Run
   service is bound to (per `runbooks/preview_environment_runbook.md`:
   `forge-flow-staging-` for runtime-isolated preview;
   `forge-flow-preview-` for data-isolated preview).
2. For each of the 6 vendors above, provision the full required
   bundle into that namespace. Use sandbox / non-production
   credentials issued by each vendor partner program. Do not reuse
   production secrets in a runtime-isolated preview that talks to
   live vendor APIs.
3. Re-deploy the preview proxy revision so it picks up the new
   secrets at boot (the bundles are read once, at startup):

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
     -PreviewName <existing-preview-name> `
     -DeferProxyStartupDatabase `
     -ProxyMaxInstances 1 `
     -SkipApiEnable
   ```

   The canonical deploy shape lives in
   `runbooks/preview_environment_runbook.md`; do not duplicate it
   here. The key requirement is that the redeploy happens **after**
   the new secrets land — the binder reads them at process start.
4. Vendors that genuinely should stay disabled in preview can be
   left out; their webhooks will continue to 404 with the
   `unknownVendor` outcome and the proxy boot log will list them in
   the `disabledVendors` warning with the structured reason.

### Verification

Re-run the Phase 3A smoke harness against preview:

```bash
dart run tool/pressure/p3a_webhook_flood.dart \
  --ops=10 --duration=5min --rate=2
```

Expected: the six vendors no longer return
`{"outcome":"unknownVendor"}`. They will now either accept (200),
reject with `signatureInvalid` 401/403 (forged-signature scenarios),
or return adapter-domain errors. The `vendor_route_404 x6` finding
should drop to zero.

---

## Finding 3 — Preview-env schema gaps (P2)

### Status

**OPEN** as of 2026-05-16. Part of the 55-migration apply queue
documented in `docs/POST_HARDENING_FOLLOWUPS.md` "P0 — Production1
Migration Apply Gap".

### Diagnosis (Phase 3A original)

1000+ 5xx response bodies in the Phase 3A flood contained one of two
schema-error strings:

- `relation "public.vendor_credentials" does not exist`
- `column op.rollover_hour does not exist` (the actual schema element
  is `locations.business_day_rollover_hour` — PR #458's regression
  test confirmed the column name; the response excerpt's `op.` alias
  was emitted by the failing SQL query plan).

Both errors traced back to the proxy crashing inside the credential
read path on every webhook POST, which then leaked the raw Postgres
error message through the framework catch-all. That P0 leak path was
closed by PR #456 (signing-secret cache + 9 leak sites sanitized);
this Finding 3 is the **underlying schema-state** that triggered the
errors in the first place.

### Root cause (verified on master 2026-05-16)

Both schema objects exist in foundational Phase 8 / advisor-cloud
migrations and **should** already be in any environment that has
been kept in sync with staging:

- `public.vendor_credentials` is created in
  `db/migrations/202605040000_phase_8_0_integration_framework.sql`
  (Phase 8.0 integration framework — `CREATE TABLE IF NOT EXISTS
  public.vendor_credentials` plus RLS, indexes, grants).
- `public.locations.business_day_rollover_hour` is created in
  `db/migrations/202604250005_advisor_cloud_foundation.sql`
  (the foundational `locations` table — `business_day_rollover_hour
  integer check (business_day_rollover_hour between 0 and 23)`).

Neither column was the subject of a dedicated migration in the
2026-05-08 → 2026-05-16 window. The "P0 — Production1 Migration
Apply Gap" tracker section currently lists **55 pending migrations**
ending at `202605161500_per_daypart_v1_deprecate_locations_rollover_hour.sql`.
The preview env appears to be behind on multiple migration cohorts
rather than two specific ones.

Notable downstream consumers of `vendor_credentials` that already
landed on master and need the relation present to run:

- `makeSevenRoomsOauthRefreshClosure` per PR #850 (registry 12 → 13
  wired closures) reads SevenRooms `client_secret` + `venue_id` from
  the `vendor_credentials` ciphertext.
- Every broker credential read path (`vendor_credential_broker.dart`
  + `oauth_refresh_cron_runner`) walks `public.vendor_credentials`
  rows under the four `STABLE LEAKPROOF` wrapper functions.

Notable downstream consumers of `locations.business_day_rollover_hour`:

- Every adapter's `business_date` derivation runs through
  `lib/services/integration/iana_timezone_converter.dart`'s
  `toBusinessDate`, which subtracts `business_day_rollover_hour`
  from the projected local time.
- The `phase_8_set_business_date()` SQL trigger in
  `db/migrations/202605050400_phase_8_business_date_denorm.sql`
  reads `l.business_day_rollover_hour` from `public.locations` to
  fill `business_date` on `connector_sync_log`,
  `inbound_webhook_dead_letter`, and `sanity_log` rows when the
  caller leaves the column NULL.
- PR #458's `column op.rollover_hour does not exist` regression test
  guards the `business_date` derivation path; it will fail when
  `POSTGRES_TEST_URL` points at a database missing the column.
- Per-Daypart V1 Slice 7b option (b) — migration
  `202605161500_per_daypart_v1_deprecate_locations_rollover_hour.sql`
  is `COMMENT ON COLUMN` only and does **not** drop the column; the
  SQL trigger still reads it as defense-in-depth.

### Fix

Apply the full pending migration queue to the preview env. The
authoritative procedure is `runbooks/phase_9_production1_migration_apply_runbook.md`
— do not duplicate it here. Apply against preview Postgres first,
not Production1; preview shares the same migration list as staging.

Sub-steps:

1. Run `tool/migration_drift_scanner.dart --strict-docs` against
   preview to enumerate which migrations are missing. This is the
   ground truth — the "55 pending" count in
   `docs/POST_HARDENING_FOLLOWUPS.md` is the Production1 backlog,
   which may differ from the preview backlog by a few migrations.
2. Apply in lex order per the runbook. Use the runbook's
   pre-apply / post-apply verification gates (`migration_drift_scanner`
   re-run, RLS sanity, FK posture).
3. The cron-scheduled migrations (per `pg_cron` rows in
   `202605061700_hardening_audit_anchor_daily_schedule.sql`,
   `202605081100_partman_maintenance_hourly_cron.sql`, etc.) need a
   manual trigger if they do not auto-fire after the apply window.

### Verification

After the apply lands against preview:

- Re-run the Phase 3A smoke harness:

  ```bash
  dart run tool/pressure/p3a_webhook_flood.dart \
    --ops=10 --duration=5min --rate=2
  ```

  Expected: forged-signature scenarios return clean 401/403 (no 5xx),
  and no response body contains `relation` or `column` "does not
  exist" text.
- The `business_date` derivation regression test from PR #458
  passes when `POSTGRES_TEST_URL` points at preview's DB.
- The SevenRooms refresh closure from PR #850 (`makeSevenRoomsOauthRefreshClosure`)
  successfully reads `client_secret` + `venue_id` for any SevenRooms
  row in preview's `vendor_credentials`.

---

## Sequencing

Apply in this order; each step depends on the previous.

1. **Apply schema migrations FIRST (Finding 3).**
   Without this, every other path that touches `vendor_credentials`
   or `locations.business_day_rollover_hour` will continue to 5xx
   in preview, masking the visibility you need to verify the next
   step.

2. **Provision vendor-capability registry env vars SECOND
   (Finding 2).** Until the 6 missing credential bundles land, the
   six vendors stay on `unknownVendor` 404 and the proxy will not
   surface any webhook-shape work for them. Re-deploy the preview
   Cloud Run revision after the secrets are in Secret Manager.

3. **Pool sizing THIRD (Finding 1).**
   Already closed by PF4 (commit `7c85e5a4`). Only revisit if a
   re-run of the 3A harness at full scale after #1 and #2 still
   shows `acquire_connection` timeouts.

---

## Cross-links

- Original findings (archived): `docs/archive/_execution/2026-05-08_pressure_preview_findings.md` Section 4.
- Pressure-test PRs: #452 (Phase 3A — webhook flood), #450 (Phase 3B — backfill flood), #451 (Phase 3C — OAuth refresh storm).
- Closeout status in active tracker: `docs/POST_HARDENING_FOLLOWUPS.md` "Closeout status (2026-05-09 end-of-day)" section.
- Code-side fixes that depend on these findings landing in preview:
  - PR #456 — P0 webhook fix (signing-secret cache + 9 leak sites sanitized). The sanitization closes the schema-info leak regardless of preview env state; applying Finding 3's migrations removes the underlying error class.
  - PR #458 — timing-profiles regression test. Group 5's `op.rollover_hour does not exist` test passes against preview once Finding 3 lands.
  - PR #850 — SevenRooms OAuth refresh wiring. `makeSevenRoomsOauthRefreshClosure` needs `public.vendor_credentials` rows in preview (Finding 3) to refresh SevenRooms bearer tokens.
- `runbooks/preview_environment_runbook.md` — preview deploy shape, Secret Manager namespace selection, `-DeferProxyStartupDatabase` semantics.
- `runbooks/phase_9_production1_migration_apply_runbook.md` — canonical migration apply procedure with pre/post verification gates.
- `runbooks/cloud_run_env_vars.md` — `POSTGRES_POOL_MAX_CONNECTIONS` reference plus other Cloud Run env var docs.
- `tool/advisor_proxy/phase_8_vendor_integration_factories.dart` — vendor adapter factory maps (the "registry" that Finding 2 is about).
- `tool/advisor_proxy/advisor_proxy.dart` — `ProxySecretNames` + `hasXxxAppCredentials` accessors.
- `lib/infrastructure/persistence/postgres/postgres_executor.dart` — `resolvePostgresMaxConnectionsPerPool` + the upper-bound constant for Finding 1.

---

## Closeout

When Findings 2 and 3 are both resolved against preview:

1. Run the full-scale Phase 3A harness against preview:

   ```bash
   dart run tool/pressure/p3a_webhook_flood.dart \
     --ops=100 --duration=30min --rate=10 --retry-each=3
   ```
2. Confirm: 5xx rate under 2%, p95 latency under 2000ms, zero
   response bodies containing `relation ... does not exist` /
   `column ... does not exist` / `unknownVendor` for any of the 6
   previously-disabled vendors.
3. Append status lines to `docs/POST_HARDENING_FOLLOWUPS.md`
   "Closeout status (2026-05-09 end-of-day)" section:
   - `Finding 2 — closed via runbooks/preview_env_infra_findings_runbook.md on YYYY-MM-DD.`
   - `Finding 3 — closed via runbooks/preview_env_infra_findings_runbook.md on YYYY-MM-DD.`
4. Optional: a single tracker entry in `PROJECT_TRACKER.md` if the
   team wants a visible closeout breadcrumb.
