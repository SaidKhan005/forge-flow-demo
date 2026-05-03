# Phase 8 — Live POS Adapters + Inbound Integration Framework

Updated: 2026-05-03
Status: Planned (framework + 7 POS adapters; reference-first wave plan; partnership applications kicked off in parallel)
Owner: POS connector lane

> **Scope rewrite (2026-05-03):** This phase was previously titled "Phase 8 - Live POS + Labor Adapters" and lumped POS + 7shifts into one doc. Scheduling is now its own phase (`phase_8S`) covering all 6 scheduling vendors. Phase 8 is POS-focused — framework slice plus 7 POS adapters. The file path stays stable to minimize citation churn.

## Goal

Two outcomes:

1. Build the shared **inbound integration framework** that Phase 8 / 8R / 8.S all consume — adapter interfaces, IANA timezone converter, per-(operator, location, vendor) credential storage, raw-payload retention, the admin-console "Vendor connections" surface, and partnership-application hygiene.
2. Replace replay/demo POS transport with **direct live adapters for 7 INTEGRATE POS vendors**: Lightspeed K-Series, Toast, Square, Revel, Clover, Aloha, Oracle MICROS Simphony.

Per HP #1, this is a pure transport swap. No app logic changes. Adapters write existing canonical SQLite/Postgres tables.

## Scope

Phase 8 owns:

- Shared `PosAdapter`, `LaborAdapter`, `ReservationAdapter` interfaces (consumed by 8R + 8.S).
- IANA-backed timezone converter at the adapter boundary (Scenarios A-F binding tests).
- `vendor_credentials`, `connector_connection`, `connector_sync_watermark`, `connector_sync_log` schemas.
- Raw-payload retention pattern: every canonical fact carries the vendor DTO as JSONB alongside normalized fields.
- The admin-console "Vendor connections" surface scoped per (operator, location). Spec: `docs/phases/phase_8/vendor_connections_admin_surface.md`.
- Cloud Run admin endpoints under `/v1/admin/integrations/*` (OAuth start/callback, key-paste connect, test-connection, disconnect, logs).
- Webhook ingestion endpoints under `/v1/webhooks/{vendor}/{operator_id}/{location_id}` with per-vendor signature verification.
- Per-vendor sync workers (polling-driven for vendors without webhooks; webhook-driven where available; hybrid for vendors that support both).
- 7 POS adapters: vendor-specific DTO mapping into canonical sales/covers/timestamps/finalization facts.
- Partnership-application kickoff hygiene (parallel critical path to engineering).

Phase 8 does **not** own:

- Reservation adapters (Phase 8R).
- Scheduling adapters (Phase 8.S).
- Outbound finance integrations (Phase 8.5).
- Auth / permissions (Phase 9 — RLS already accepted).
- Cross-device shared state (Phase 10a).
- Live daypart-aware Shift behavior (Phase 10.5 — accepted).
- Another internal architecture rewrite.

## Runtime Contract

```text
official POS APIs (Toast / Lightspeed / Square / ...)
-> per-vendor adapter DTOs
-> IANA-converted, normalized canonical facts
-> repositories (operator-scoped, RLS-ready)
-> SQLite local cache + Postgres source-of-truth
-> read services / state holders / read models
-> UI (operator app reads facts; admin console reads sync status)

raw vendor DTO -> stored as JSONB alongside canonical fact (escape hatch)
```

Per **HP #1**: transport-only. No `lib/services/` or `lib/domain/services/` business-logic changes.

Per **HP #7**: vendor secrets server-side only. `vendor_credentials` encrypted with pgcrypto envelope or Cloud KMS. Flutter clients never see plaintext tokens.

Per **HP #8**: adapter framework is general-purpose. Adding a future POS = one new file under `lib/integrations/pos/<vendor>_pos_adapter.dart`, no framework changes.

## Architectural Decisions (locked 2026-05-03)

**Direct integration for all 17 inbound vendors. No middleware in the default path.**

Research conducted 2026-05-03 found:

- Omnivore (Olo's POS aggregator) covers only 2 of 7 POS targets — not Toast / Square / Clover / Lightspeed / Revel.
- Field-fidelity loss through middleware breaks load-bearing math (Toast `numberOfGuests`, finalization signals, role hierarchy).
- Toast and Lightspeed explicitly steer partners to direct integration.
- Outage blast radius: middleware = all POS vendors down at once; direct = isolated.
- Economics: ~$2.1M/year for Omnivore at our scale vs amortized engineering.

Omnivore stays as a **documented fallback option** for legacy on-prem POSes (Aloha-on-prem, Micros 3700, POSitouch, Squirrel) only if a specific operator demands one we haven't built directly. Same `PosAdapter` interface; no architectural carve-out.

Memory: `project_phase_8_architecture.md` carries the durable decision and reasoning.

## Frontend Exposure

The "Vendor connections" admin-console surface is built once in `8.0` and shared across POS / Reservations / Scheduling. Phase 8 adds the POS section + one card per POS vendor (over the wave plan).

Spec: `docs/phases/phase_8/vendor_connections_admin_surface.md` — pick-then-show UX, OAuth-led + key-paste fallback, heavy on-demand test connection, disconnect semantics (preserve history, wipe creds, preserve watermark), multi-location apply-to-all flow, module disambiguation (POS has none — that's a scheduling concern), webhook URL provisioning.

Operator-facing UX is **only** the demo-mode banner in the operator app (`kDemoMode == true` OR no INTEGRATE vendor connected for the location). Banner reads runtime state, not config. There is no operator-app Settings page for integrations.

## Slices

Slices are sequenced reference-first per `docs/phases/phase_8/vendor_master_list.md` Wave plan. Partnership applications kick off at the start of Wave 1.

### `8.0` — Framework slice (Wave 1, blocks everything below)

Owns:

- `PosAdapter`, `LaborAdapter`, `ReservationAdapter` interfaces in `lib/services/integration/`.
- IANA-backed timezone converter at adapter boundary. **Scenarios A-F binding** (see acceptance criteria below).
- `vendor_credentials` schema + repository. Encrypted-token storage. Operator-scoped + location-scoped + module-scoped.
- `connector_connection`, `connector_sync_watermark`, `connector_sync_log` schemas (see admin surface spec for SQL).
- Raw-payload retention: canonical fact tables get `raw_payload JSONB` column or sibling `*_raw_payload` table per vendor.
- Cloud Run admin endpoints: `POST /v1/admin/integrations/oauth/{vendor}/start`, `GET /v1/admin/integrations/oauth/{vendor}/callback`, `POST /v1/admin/integrations/{vendor}/connect-key`, `POST /v1/admin/integrations/{vendor}/test-connection`, `POST /v1/admin/integrations/{vendor}/disconnect`, `GET /v1/admin/integrations/{vendor}/logs`, `GET /v1/admin/operators/:operator_id/locations/:location_id/integrations`.
- Webhook ingestion endpoints: `POST /v1/webhooks/{vendor}/{operator_id}/{location_id}` with per-vendor signature-verification adapters.
- Admin-console "Vendor connections" surface (Flutter, lives under `lib/admin/screens/vendor_connections/`).
- Sync-worker scaffold under `tool/integration_sync_worker/` — polling-driven by default, webhook-driven where vendor supports.
- New permission key `integrations.configure` added to `docs/contracts/auth_permission_key_catalog.md`. Granted to `forge_admin` and `operator_admin` / `operator_owner`. Read-only for `ff_support`. Denied to `location_manager`.
- Migration discipline: `dart run tool/migration_drift_scanner.dart --fix --strict-docs` then `dart run tool/migration_cutoff_lint.dart` after schema changes.

Additional `8.0` deliverables (V1 leaner posture, locked 2026-05-03 after pressure-test cut):

- **Inbound webhook reliability.** Per-vendor signature verification using constant-time HMAC compare (security). Replay defense rejects signatures older than 5 minutes for vendors that include a timestamp in the signature. Idempotency keyed on `(vendor_id, operator_id, vendor_event_id)` stored in new table `inbound_webhook_idempotency` with 30-day TTL via `pg_partman`. After signature verification passes, the adapter cross-checks the payload's claimed vendor-location identifier (e.g., Toast `restaurantGuid`, Libro venue ID, 7shifts `location_id`) against the stored binding in `connector_connection.metadata` for the (operator_id, location_id) resolved from the URL path. Mismatch returns 403 with audit log entry, no canonical-fact write. Dead-letter table `inbound_webhook_dead_letter` captures events that fail processing 3 times; surfaces as a tile in 11A.6 (basic webhook delivery + dead-letter only at V1; richer monitoring lands when operator volume justifies it).
- **Fact-level idempotency.** Canonical fact writes use a unique constraint or upsert keyed on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`. Same fact arriving via webhook and polling (during recovery) is a no-op on the second arrival. Same fact arriving twice from one path is a no-op. Out-of-order delivery is handled by last-write-wins on `vendor_modified_at`; older incoming event is rejected as stale.
- **OAuth refresh cron with advisory lock.** `pg_cron` job at 5 minutes past every hour runs `proxy.refresh_expiring_inbound_vendor_tokens()`. Refreshes any `vendor_credentials` row with `token_expires_at < now() + interval '24 hours'`. Per-operator-per-vendor `pg_advisory_lock` so two pods cannot race on the same refresh. On success, update tokens and write audit row. On 3 consecutive failures, set `is_active = false`, set `disconnect_reason = 'auto_disable_3_strike'`, and emit a `vendor_connection_auto_disabled` email through the Phase 9.8 email-provider slice.
- **KMS rollout plan for `vendor_credentials`.** Staging encrypts via pgcrypto envelope (`pgp_sym_encrypt` and `pgp_sym_decrypt`) with the key stored in Cloud Run secret env. Production uses Cloud KMS-managed encryption with a KMS-derived data-encryption key. Per-operator namespace in KMS supports crypto-shredding on operator deletion.
- **Demo-mode-to-live transition.** New `demo_mode_state` table at `(operator_id, location_id, category)` granularity. Default `is_demo = true` at operator-create time. Flip to `is_demo = false` when the first INTEGRATE vendor connection for that (op, loc, cat) reaches `connected` status and first backfill commits at least 1 record. Disconnect does not auto-revert; historical facts stay. Spec: `docs/phases/phase_11W/operator_onboarding_flow.md` "Demo-mode-to-live transition" section.
- **Pod graceful drain.** SIGTERM handler in `forge-flow-proxy` finishes in-flight webhooks, refuses new with HTTP 503 (vendors retry), and exits cleanly within the Cloud Run 10-second drain window.
- **Backfill cursor persistence per batch commit.** `connector_sync_watermark.cursor_token` and `last_modified_seen` are updated after each successful batch insert, not just at backfill end. On Cloud Run Job crash, restart resumes from the last persisted cursor instead of starting over.
- **Manual webhook signing key rotation.** Admin UI action on the per-vendor card lets operator paste a new webhook signing key. Framework starts dual-verification (accept old plus new) for a 24-hour grace window, then flips to new-only after the grace.
- **`disconnect_reason` enum on `connector_connection`.** Values: `operator_action`, `vendor_revoked`, `auto_disable_3_strike`, `vendor_endpoint_deprecated`, `oauth_timeout`. Operator-facing copy varies per reason so the operator knows what to do (covered in admin surface UX writing standard).
- **Malformed vendor payload defense.** Adapter framework wraps DTO parsing in try-catch, logs unexpected fields to `inbound_webhook_idempotency.parse_warnings` JSONB, and never lets one bad payload poison the queue. Adapter records `parse_partial = true` on the canonical fact when fields are missing.
- **Raw_payload 30-day rolling retention.** Vendor DTO stored as JSONB alongside the normalized fact. `pg_partman` partitions by `received_at_month` with rolling 30-day delete. F&F-internal access via 11A.5 debug console preserved during the retention window.

State machine for `connector_connection.status` is 3 states at V1: `connected`, `disconnected`, `error`. `degraded` and `connecting` are added later when monitoring justifies them. Operator-facing copy makes `error` actionable (most often "vendor revoked our access; please reconnect and sign back in").

V1 explicit non-goals captured in `project_v1_lean_scope_cut.md`: append-only supersede mechanism for fact corrections, `source_connection_id` column on canonical fact rows, vendor-migration overlap window with primary-source filtering, per-vendor token bucket rate limiting, PgBouncer, schema-migration freeze-window runbook, async-Cloud-Run-Job backfill with progress UI, and 5-state connection machine. These get added when actual operator volume or actual incidents demand them, not preemptively.

Walkthrough at acceptance: connect Lightspeed sandbox to a test (operator, location), test-connection returns a sample order with covers and timestamps, disconnect preserves watermark, reconnect resumes from preserved cursor, demo-mode flag flips correctly, signed webhook signature verification rejects forged signatures, malformed payload is logged and rejected without poisoning the queue, OAuth refresh cron handles a near-expiry token correctly, pod graceful drain completes in-flight webhook on simulated SIGTERM.

### `8.LSK` — Lightspeed K-Series adapter (Wave 1, **POS reference adapter**)

- Public OAuth at `developer.lightspeedhq.com`; sandbox at `api.trial.lsk.lightspeed.app`.
- Endpoints: business-day sales, open checks, transactions, financials.
- Webhooks: Order/Account/Payment events including `CHECK_WAS_UPDATED`, `Account: CLOSED`.
- Field mapping: `covers` is a first-class field; opened/closed/paid timestamps populate the canonical fact.
- This adapter is the reference implementation that proves the framework end-to-end.

### `8.SQ` — Square adapter (Wave 2)

- OAuth 2.0 (no partnership gating — self-serve).
- `SearchOrders` for backfill; webhooks for live.
- **No covers** — adapter records `covers_source = forecast_fallback` per the documented degrade path.

### `8.TS` — Toast adapter (Wave 3, partnership-gated)

- Partnership review required (compliance + security + legal); applications kicked off at start of Wave 1.
- OAuth 2.0 client credentials.
- Webhooks for orders + partner events (`partners` install/uninstall).
- `numberOfGuests` field maps to canonical `covers` 1:1.

### `8.RV` — Revel adapter (Wave 4)

- Public dev portal, OAuth (Bearer, 24h client-credentials).
- `order.finalized` webhook for finalization; `number_of_people` field for covers.

### `8.CL` — Clover adapter (Wave 4)

- App-Market approval (~1-3 weeks).
- Webhook events for Orders + Payments + Employees.
- 90-day filter window cap on historical queries — adapter must page through windows for 60-day backfill.
- **No covers** — same degrade path as Square.

### `8.AL` — Aloha (NCR Voyix) adapter (Wave 5, partnership-gated)

- NCR Voyix dev portal; per-API access requests.
- Sandbox available via Business Services Platform.
- OAuth 2.0.
- Covers field availability not confirmed in In-Store Order API at time of audit — adapter must verify at sandbox time and document the field-availability finding before merge.

### `8.OR` — Oracle MICROS Simphony adapter (Wave 5, partnership-gated)

- Oracle Simphony Partner Integration Program; partner activation required.
- OAuth 2.0; `getGuestChecks` API exposes covers.
- **Poll-only** — no webhooks documented. Polling cadence: 5 min default per location.

## Timezone Acceptance Criteria (binding, Scenarios A-F)

This is a hard requirement for the `8.0` framework slice and re-verified per vendor adapter.

The 7.55r foundation-closeout audit established that central timezone conversion belongs at the adapter boundary, not in screens or read services. This phase implements that converter and binds the test scenarios.

### Architectural constraint (not negotiable)

- **Use an IANA-backed timezone library (e.g. `package:timezone`).** Fixed-offset calculation will silently mis-bucket DST fall-back timestamps twice a year.
- The adapter layer must interpret every vendor timestamp in the restaurant's configured `businessTimezone` (from `RestaurantTimingConfig`) before any business-date decision is made.
- `BusinessDateResolver` stays as-is (already expects pre-converted local timestamps).
- The restaurant timezone is the authority. Device clock is never the source of truth for business boundaries.

### Scenarios A–F — binding test cases

These are the named acceptance tests `8.0` must pass and each per-vendor adapter must re-verify with vendor-specific timestamp shapes:

- **Scenario A — Pacific restaurant, 4 AM business-day cutoff.** Vendor emits `2025-01-01T10:30:00Z` (UTC). Restaurant tz `America/Los_Angeles`, business-day start `04:00`. Expected `businessDate = 2024-12-31`. Naive UTC bucketing = wrong.
- **Scenario B — late-night ticket spanning midnight.** Dinner ticket opens 23:55 ET, closes 00:15 ET. Both events belong to the prior business date with `04:00` local cutoff.
- **Scenario C — DST fall-back ambiguity.** Vendor emits `2025-11-02T05:30:00Z` and `2025-11-02T06:30:00Z`. Both convert to `01:30 local` in `America/New_York` (DST fall-back). IANA library must disambiguate; fixed-offset cannot. **This is why IANA is mandatory.**
- **Scenario D — multi-location chain.** Two locations on the same operator with different timezones (e.g. Toronto + Vancouver). "Today's covers" for each resolves against the location's own timezone, not the operator's device clock.
- **Scenario E — ambiguous vendor timestamp (no tz info).** Vendor emits `2025-01-01T02:30:00` with no `Z` suffix and no offset. Adapter must declare the vendor's convention explicitly (document per integration) — treat as UTC, treat as location-local, or reject as malformed.
- **Scenario F — historical replay / pre-DST-policy-change timestamps.** Replay data from a year when DST rules differed. IANA's historical offset database is the only reliable source; replay of a 2022 timestamp uses 2022's tz rules.

Cannot ship `8.0` without all six green. Each per-vendor adapter declares its timestamp convention in a `vendor_timestamp_policy.dart` constant and re-runs Scenarios A-F with vendor-shape inputs.

## Acceptance Criteria (per slice)

Per `docs/contracts/slice_runtime_acceptance_contract.md`. Each per-vendor slice:

- Adapter passes contract tests against vendor sandbox (or production with throttled volumes if no sandbox).
- OAuth (or key-paste) round-trip works through admin-console connect flow.
- Heavy test-connection returns within 5s with a real sample order showing covers (where applicable) + timestamps + check ID.
- Sync watermark + 60-day backfill complete on first connect for at least one test (operator, location).
- Disconnect preserves historical facts; reconnect resumes from preserved watermark.
- IANA Scenarios A-F re-verified with vendor-specific timestamp shapes.
- Raw-payload retention populated: every canonical fact row has its source DTO accessible.
- `numberOfGuests` (or vendor-equivalent covers field) maps 1:1 to canonical `covers` where vendor exposes it; degrade path documented where vendor does not.
- Demo-mode walkthrough green per `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Dependencies

- **Phase 9 RLS** active for per-operator credential isolation (already accepted on master).
- **Phase 10a real-time bridge** for webhook → NOTIFY → Pub/Sub → WebSocket flow (Cloud Pub/Sub publisher accepted; bridge worker dead-letter cap queued as `10a.2`).
- **Cloud KMS** for production credential encryption (`11a.11e` Production1 setup; staging uses pgcrypto envelope).
- **Partnership applications** kick off at the start of `8.0`:
  - Toast Partner Program
  - Lightspeed Partner / Standard tier (self-serve possible)
  - Oracle Simphony Partner Integration Program
  - NCR Voyix Developer Program
  - ADP Marketplace DPA (for Phase 8.S)
  - SevenRooms partner onboarding (for Phase 8R)
  - Push Operations partner approval (for Phase 8.S)

## Adjacent Phases

- **Phase 8R** — Reservation adapter family (4 vendors). Plugs into the same framework.
- **Phase 8.S** — Scheduling adapter family (6 vendors). Plugs into the same framework.
- **Phase 8.5** — Outbound finance integrations (QBO Accounting / Xero / Bill.com / Plaid). Different direction (we write to operator's systems, not read from them). Same admin-console surface, different category section.
- **Phase 9** — Identity, roles, permissions. RLS-ready schema already in place. `integrations.configure` permission key added by `8.0`.
- **Phase 9.8** — T&Cs covering operator's authorization for F&F to access their POS data.

## Cross-references

- `docs/phases/phase_8/vendor_master_list.md` — full 17-vendor classification, operator-share estimates, Wave 1-5 plan, partnership applications.
- `docs/phases/phase_8/vendor_connections_admin_surface.md` — admin-console UX spec.
- `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md` — reservation sibling.
- `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md` — scheduling sibling.
- `docs/archive/phases/phase_8_gate/` — original Phase 8 readiness gate (Toast/Square/Clover audited; signoff blocked on vendor selection — now resolved by 17-vendor classification).
- `docs/archive/phases/7_55j/` — pre-Phase-8 integration audit and capability-checklist template (extend per vendor).
- `docs/archive/phases/7_55n/phase_7_55n_12_vendor_live_data_capability_audit.md` — original live-data capability audit.
- `docs/contracts/phase_7_55_time_boundary_contract.md` — business-date authority contract that the IANA converter must serve.
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — RLS / OperatorScopedRepository pattern.
- `docs/contracts/auth_permission_key_catalog.md` — `integrations.configure` permission key (added by `8.0`).
- `lib/data/business_date_authority_service.dart` — existing resolver that consumes post-conversion local timestamp.
- `lib/domain/models/restaurant_timing_config.dart` — `businessTimezone` field the converter reads from.
