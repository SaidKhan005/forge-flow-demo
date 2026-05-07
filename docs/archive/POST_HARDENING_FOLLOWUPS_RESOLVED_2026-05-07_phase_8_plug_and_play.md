# POST_HARDENING_FOLLOWUPS — Resolved 2026-05-07 (Phase 8 plug-and-play V1 onboarding)

These items closed during the 2026-05-07 Phase 8 plug-and-play V1
onboarding session. End-to-end, all 17 vendor adapters now have an
operable engineering path from the operator-web Connect button through
descriptor/validator → token persistence → first-connect backfill →
OAuth refresh. Operations work (migration apply, vendor app creds in
Cloud Run env, partner-portal redirect URI registration) is not in
scope of this archive — that lives in
`POST_HARDENING_FOLLOWUPS.md` P0 and the cutover plan.

The current live tracker is at `docs/POST_HARDENING_FOLLOWUPS.md`.

| Item | Resolved by | Resolution note |
|---|---|---|
| MFA test fakes signature drift | PR #280 (`code-health.fix-mfa-test-signature-drift`) | Aligned MFA test fake signatures so suite compiles cleanly post-master-merge. |
| OAuth refresh worker has no closure registry (`kEmptyRefreshClosures`) | PR #281 (`8.oauth-refresh-worker.closure-registry-wire-in`) | Wired 11 production OAuth refresh closures into the OAuth refresh worker. Worker now refreshes real vendor tokens. |
| First-connect backfill worker uses `kScaffoldRejectingAdapterFactory` | PR #282 (`8.backfill-worker-adapter-factory-wire-in`) | Replaced scaffold rejecting factory with `BinderBackedAdapterFactory`. Binder split into thin shell + `phase_8_vendor_integration_factories.dart` so worker no longer pulls `proxy_bootstrap.dart` into its compile graph. |
| OAuth dispatcher returns `disabled=*`; no per-vendor descriptors wired | PR #283 (`8.operator-self-service.per-vendor-oauth-descriptors`) | Wired 6 OAuth descriptors (Square / Clover / 7shifts / QBT / Libro / Humanity) + 11 api-key validators (Toast / Lightspeed LSK / Aloha / Oracle / Revel / ADP / Tock / Push / Agendrix / SevenRooms / OpenTable). All 17 vendors now have an operator-web connect path. |
| Operator-web → proxy route mismatch (`/v1/auth/integrations/*` phantom routes) | PR #286 (`8.operator-self-service.route-alignment-gap-5-6`) | Operator-web client realigned to PR #283 routes. Added `POST /v1/integrations/{vendor}/test-connection` (Gap 5) and `POST /v1/integrations/{vendor}/disconnect` (Gap 6). |
| 33 analyzer errors blocking pre-commit hooks | PR #288 (`code-health.master-analyzer-sweep`) | All 33 analyzer issues cleared. Pre-commit hooks + CI now pass cleanly. |
| Test-connection endpoint returns 503 (`VendorTestConnectionExecutor` not wired) | PR #297 (`8.test-connection-executor-wire-in`) | `Phase8IntegrationTestConnectionExecutor` wraps the validator map. Test-connection endpoint now returns 200 instead of 503. |
| Api-key paste UX missing for 11 key-paste vendors | PR #298 (`8.operator-self-service.api-key-paste-ux`) | Api-key paste dialog with per-vendor labels for the 11 key-paste vendors. `connectWithApiKey` plumbing through `VendorConnectionsGateway`. |
| `GET /v1/auth/locations/{id}/integrations` stub returning empty | PR #301 (`8.location-integrations-list-real-projection`) | Endpoint reads real `connector_connection` rows via new `ConnectorConnectionListRepository`. |
| Binder file pulls `proxy_bootstrap.dart` into worker compile graph | Resolved by binder split in PR #282 | Binder split into thin shell + `phase_8_vendor_integration_factories.dart`; backfill + OAuth refresh workers compile cleanly without proxy bootstrap. |

## V1 plug-and-play closure summary

End-to-end V1 plug-and-play onboarding for all 17 vendors is now
operable on the engineering side. Operations work remaining (not
blocking this archive):

- 20 migrations pending Production1 apply (`POST_HARDENING_FOLLOWUPS.md` P0).
- Vendor app credentials in Cloud Run env (Square / Clover / Humanity / QBT / 7shifts / Libro `*_CLIENT_ID` / `*_CLIENT_SECRET` pairs; Aloha 4-secret bundle).
- `PGCRYPTO_ENVELOPE_KEY` in Cloud Run env (proxy + backfill worker + OAuth refresh worker).
- Worker deploy scripts: `deploy_staging_proxy.ps1`, `deploy_first_connect_backfill_worker.ps1`, `deploy_oauth_refresh_worker.ps1`, `deploy_operator_web.ps1`.
- Vendor partner-portal redirect URI registration (per OAuth vendor).

V1-optional polish deferred (not blocking V1):

- `ProjectingCanonicalSink` — derived metric projection wrapper. Canonical sinks already write raw facts.
- Wave 3 #5 recurring sync worker. Webhooks + first-connect backfill cover most vendors; recurring poll is robustness for vendors with unreliable webhooks.
- Backfill progress indicator in operator-web. Connection shows status from real row, no live progress bar during 60-day pull.
