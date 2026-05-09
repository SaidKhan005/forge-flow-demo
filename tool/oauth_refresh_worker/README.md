# oauth_refresh_worker — operator runbook

Cloud Run-deployable Dart worker that closes the "vendor tokens
silently expire" gap. Without this worker, near-expiry rows in
`public.vendor_credentials` never get refreshed and live OAuth
connections die after the per-vendor expiry (~1 hour for most
POS / labor vendors).

## Pieces in scope

```
tool/oauth_refresh_worker/
  main.dart        # entrypoint + Postgres-backed gateway + tick + loop
  Dockerfile       # mirrors tool/first_connect_backfill_worker/Dockerfile
  README.md        # this file

scripts/deploy_oauth_refresh_worker.ps1
                   # Cloud Run Job + Cloud Scheduler trigger (every 10 min)
test/tool/oauth_refresh_worker/main_test.dart
```

These compose existing master-side pieces:

* `lib/services/integration/oauth_refresh_cron.dart` declares the
  `OAuthRefreshGateway` / `VendorOAuthRefresher` / threshold contract
  the master-side cron documents. The new worker re-implements the
  loop on top of `VendorCredentialBroker` so the broker's per-tenant
  Future-lock collapses concurrent refreshes for the same
  `(operator, location, vendor)` triple to one round trip.
* `lib/integrations/_common/vendor_credential_broker.dart` performs
  the actual ciphertext write-back inside `withTenant` (RLS-ready).
  The broker also resets `consecutive_refresh_failures` to 0 on
  success.
* `lib/integrations/_common/production_oauth_refresh_closures.dart`
  ships the per-vendor OAuth refresh HTTP closures (Toast, Square,
  Clover, Lightspeed LSK, Aloha NCR Voyix, Oracle MICROS Simphony,
  Revel, 7shifts, QuickBooks Time, Libro, Humanity).

## Deploy shape: Cloud Run Job invoked by Cloud Scheduler every 10 min

The deploy lands the worker as a **Cloud Run Job** (not a Service)
fired by a **Cloud Scheduler** trigger every 10 minutes. The job
runs `runOnce`, claims every near-expiry row (up to
`MAX_ROWS_PER_TICK`), refreshes each, and exits.

Why every 10 minutes:

* The refresh window is `now() + 5 minutes` (`HORIZON_SECONDS`
  default). A 10-minute cadence catches a row up to 15 minutes
  before its expiry, which is enough headroom for a slow OAuth
  round trip + clock skew + retries on the next tick.
* A 1-minute cadence (the first_connect_backfill_worker shape)
  would be wasteful — most vendor tokens last 1+ hour, so 10 min
  per row is plenty.

Why Job + Scheduler over Service-with-always-on (mirrors the
`first_connect_backfill_worker` rationale):

1. **Bounded per-invocation cost.** Cloud Run Jobs bill only while
   the container runs. A 10-minute cadence drains the queue with the
   latency budget operators expect; an always-on Service with
   `min-instances=1` bills 24/7 for empty-queue ticks.
2. **No SIGTERM gymnastics required.** The worker's `runOnce` mode
   exits as soon as the tick finishes. The `daemon` mode still
   exists for local dev / ad-hoc runs but is never the production
   deploy shape.
3. **FOR UPDATE SKIP LOCKED is multi-instance safe.** Two parallel
   Job pods running concurrently will see disjoint claim sets.
4. **Mirrors `first_connect_backfill_worker` and `audit_anchor`.**
   Reusing the pattern keeps the F&F deploy story coherent.

The `daemon` mode is documented for local dev (`flutter pub run
tool/oauth_refresh_worker/main.dart daemon`); production never
uses it.

## Required env (NAMES only — values flow through Secret Manager)

| Env name | Purpose |
|---|---|
| `POSTGRES_URL` | Same secret the audit_anchor + advisor proxy + first_connect_backfill_worker mount; reused so connection-string drift never occurs. |
| `PGCRYPTO_ENVELOPE_KEY` | Same secret the advisor proxy uses for `pgp_sym_decrypt(...)` of the broker's vendor_credentials ciphertext. Required by the broker constructor. |
| `OAUTH_REFRESH_WORKER_POLL_SECONDS` (optional) | Daemon-mode tick interval. Default 60. Production ignores it (Cloud Scheduler controls cadence). |
| `OAUTH_REFRESH_WORKER_MAX_ROWS_PER_TICK` (optional) | Per-tick claim cap. Default 50. |
| `OAUTH_REFRESH_WORKER_MAX_CONSECUTIVE_FAILURES` (optional) | Auto-disable threshold. Default 3 (mirrors `kRefreshFailureAutoDisableThreshold` in `lib/services/integration/oauth_refresh_cron.dart`). |
| `OAUTH_REFRESH_WORKER_HORIZON_SECONDS` (optional) | Refresh window — rows with `token_expires_at < now() + horizon` are claimable. Default 300s (5 minutes). |
| `OAUTH_REFRESH_WORKER_ID_PREFIX` (optional) | `worker_id` prefix; default `oauth-refresh`. |

Secret values are NEVER printed. Startup logs the loaded env NAMES
only — same posture as `tool/audit_anchor/main.dart`,
`scripts/deploy_audit_anchor_job.ps1`, and
`scripts/deploy_first_connect_backfill_worker.ps1`.

## Refresh flow

For each near-expiry row claimed via `FOR UPDATE SKIP LOCKED`:

1. The worker looks up the vendor's refresh closure in the registry
   the bootstrap composed at boot. Vendors WITHOUT a closure
   (`sevenrooms`, `tock`, `push_operations`, `agendrix`, `humanity`
   per `kVendorsWithoutRefreshClosureReason`) are SKIPPED with a
   single structured trace log line carrying the documented
   delegation reason (no failure-count increment):
   * `sevenrooms` — `sevenrooms_client_secret_not_persisted`
     (architectural gap: the bridge's `persistIssuedBearerToken` only
     writes `client_id` to metadata; the `client_secret` is dropped
     after connect-time, so the broker cannot call `POST /2_2/auth`
     to mint a fresh bearer. Re-wiring requires a bridge change +
     connect-flow update — see follow-up spec in
     `docs/integrations/sevenrooms/oauth_shape.md`).
   * `humanity` — `humanity_keypaste_password_grant_no_broker_refresh`
     (adapter declares `keyPaste`; v1 connect-time bearer is
     refreshed by reconnect, not by the broker).
   * `tock`, `push_operations` — static API key / partner-issued
     bearer.
   * `agendrix` — OAuth sliding-refresh per the adapter declaration,
     but the closure factory is not yet wired in
     `lib/integrations/_common/production_oauth_refresh_closures.dart`.

   **2026-05-09 wiring**: ADP and OpenTable were on this no-closure
   list under PR #455 with reasons `adp_partner_ops_mtls_out_of_band`
   and `opentable_transport_internal_refresh`. Re-investigation found
   both expose a programmatic OAuth `grant_type=refresh_token` surface
   using per-tenant `client_id` / `client_secret` from `metadata`;
   both now wire via `makeAdpOauthRefreshClosure` and
   `makeOpenTableOauthRefreshClosure` (registry has 12 wired closures,
   up from 10).
2. The closure is invoked through
   `VendorCredentialBroker.refreshAccessToken(...)`. The broker:
   * acquires a per-`(operator, location, vendor)` Future lock so
     concurrent in-flight refreshes collapse to one;
   * reads the bundle, calls the closure, writes the new ciphertext
     + `token_expires_at`, and resets
     `consecutive_refresh_failures` to 0 on success.
3. On success: writes `connector_sync_log` event
   `event_kind='auth_refresh'`. The success counter advances.
4. On failure (broker throws `VendorRefreshFailed`,
   `VendorCredentialDecryptFailed`, or `VendorCredentialNotFound`):
   the worker increments `consecutive_refresh_failures` by 1 and
   writes `connector_sync_log` `event_kind='auth_refresh_failed'`.
5. When the post-increment count hits `MAX_CONSECUTIVE_FAILURES`
   (default 3): the worker flips
   `connector_connection.status='error'`,
   `disconnect_reason='oauth_timeout'`,
   `is_active=false` on the vendor_credentials row, and writes one
   `audit_logs` row with
   `action='vendor_credential_auto_disabled'`. The operator must
   reconnect through the integrations console.

### DEVIATION: `disabled_pending_reauth` status

The slice prompt called for `connector_connection.status =
'disabled_pending_reauth'`. The migration's status CHECK admits only
`(connected, disconnected, error)` — see
`db/migrations/202605040000_phase_8_0_integration_framework.sql`,
line 159. The prompt also marked migrations READ-ONLY for this
slice. The worker uses the existing `error` value (mirrors the
master-side `lib/services/integration/oauth_refresh_cron.dart`
`autoDisableConnection` contract docstring) plus
`disconnect_reason = 'oauth_timeout'` (the closest enum value among
the four the migration's `connector_disconnect_reason` enum admits)
plus an `audit_logs` row whose `action` field carries the precise
trigger. A follow-up slice can widen the status enum if a separate
"reauth required" terminal proves more useful.

### DEVIATION: SIGTERM drain semantics

The prompt asked for "drain in-flight refreshes" on SIGTERM. The
broker's per-tenant Future lock already serializes refreshes; the
worker checks `shouldStop()` between rows, NOT mid-row. Aborting a
broker call mid-flight would risk a half-written ciphertext. The
postgres driver propagates cancellation cleanly, so the in-flight
broker call's transaction either commits (broker already returned)
or rolls back (broker still running when stop fires + transaction
context lost). Either way, the row's lock releases on transaction
end and the next worker tick re-claims via `FOR UPDATE SKIP
LOCKED`. No row is lost.

## Cloud Scheduler trigger

The deploy script registers the schedule. Manual command shape:

```sh
gcloud scheduler jobs create http forge-flow-oauth-refresh-trigger \
  --project forge-flow-staging \
  --location northamerica-northeast1 \
  --schedule '*/10 * * * *' \
  --time-zone 'Etc/UTC' \
  --uri https://northamerica-northeast2-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/forge-flow-staging/jobs/forge-flow-oauth-refresh:run \
  --http-method POST \
  --oauth-service-account-email forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com \
  --attempt-deadline 600s
```

Cloud Scheduler is not available in `northamerica-northeast2`
today, so the trigger lives in `northamerica-northeast1` while the
Job itself runs in `northamerica-northeast2`. Same constraint as
`scripts/deploy_audit_anchor_job.ps1` and
`scripts/deploy_first_connect_backfill_worker.ps1`.

## Refresh closure registry wiring (NOT YET PRODUCTION)

The worker entrypoint expects a `RefreshClosureRegistry` — a
`Map<String, RefreshClosure>` keyed on `vendor_id`. Today the
production main() defaults to `kEmptyRefreshClosures`, which
treats every claimed row as a "no closure registered" skip and
logs once per row.

A follow-up slice must wire the production registry by composing
the thirteen `make<Vendor>OauthRefreshClosure(...)` factories from
`lib/integrations/_common/production_oauth_refresh_closures.dart`
into the worker's main() — the bootstrap reads the same env vars
the advisor proxy already uses (`SQUARE_OAUTH_CLIENT_ID`,
`CLOVER_APP_ID`, `INTUIT_OAUTH_CLIENT_ID` /
`INTUIT_OAUTH_CLIENT_SECRET`, `SEVENSHIFTS_*`, etc.) and threads
them in plus a long-lived `http.Client`. That follow-up is OUT of
scope for this slice (which closes the deploy gap); the wiring
lives in a sibling slice.

In test paths the registry is injected via
`runCli(refreshClosuresOverride: ...)` so the worker's claim /
broker / cap-and-audit paths can be exercised end-to-end without
real vendor calls.

## Local dev

Run `runOnce` once against a local Postgres:

```ps1
$env:POSTGRES_URL = "postgres://forge_admin@localhost:5432/forge_flow_dev"
$env:PGCRYPTO_ENVELOPE_KEY = "<dev envelope key>"
flutter pub run tool/oauth_refresh_worker/main.dart runOnce
```

`daemon` mode polls every 60s by default; SIGINT (Ctrl+C) exits
between rows.

## Test surface

`test/tool/oauth_refresh_worker/main_test.dart` covers:

* Happy path: a near-expiry row is claimed, the closure is called,
  the broker writes the new ciphertext (we assert on the recorded
  `recordRefreshSuccess` call + the broker's `withTenant` UPDATE)
  and `consecutive_refresh_failures` resets to 0.
* SKIP LOCKED contention: two parallel ticks against a single
  available row — only one claims it (the in-memory fake mirrors
  the migration's `FOR UPDATE SKIP LOCKED` semantics).
* Cap-and-disable: a row that fails 3 times trips
  `connector_connection.status='error'` +
  `disconnect_reason='oauth_timeout'` +
  `vendor_credentials.is_active=false` AND a single
  `public.audit_logs` row with
  `action='vendor_credential_auto_disabled'`.
* Vendor without refresh closure: the row is logged-and-skipped,
  `token_expires_at` is NOT advanced, no error / no failure-count
  increment.
* SIGTERM mid-tick: the loop exits between rows; the in-flight
  broker call's transaction completes naturally.

The tests use a fake `OAuthRefreshWorkerGateway` + a fake broker
helper rather than touching live Postgres or vendor HTTP.
