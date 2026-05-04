# Phase 8 — Live POS Adapters + Inbound Integration Framework

Updated: 2026-05-03
Status: Framework `8.0` accepted on master 2026-05-03 (PR #90 + master-side hardening at `4f2dc85`); Wave B engineers all 7 POS adapters in one push (lifecycle = `documented`). **Engineering closes when Wave B lands.** Lifecycle promotion to `sandbox_verified` / `production_credentialed` / `live_with_operators` tracked in `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`.
Owner: POS connector lane (engineering); Phase 8.live (rolling lifecycle)

> **Doctrine lock (2026-05-03):** Engineer all 17 INTEGRATE vendors against documented APIs in one push (Wave B), lock each adapter at lifecycle = `documented`, then fire `*.live.sandbox` / `*.live.prod` slices when credentials arrive. The wave-1-through-wave-5 staggering from the prior plan is collapsed. Memory: `memory/project_phase_8_engineer_all_17_doctrine.md`.

> **Review contracts.** Every adapter slice in this phase is graded by Codex against:
> - `docs/contracts/vendor_adapter_slice_contract.md` — framework rules (mandatory calls, banned items, test discipline, walkthrough bar, lifecycle promotion).
> - `docs/contracts/per_vendor_doc_pack_contract.md` — the 6-file folder Codex compares the adapter code to.
>
> A slice that violates either contract is `FOLLOW-UP NEEDED` or `REJECT` per the contract's verdict table.

## Per-slice doctrine (binding)

Every adapter slice in Phase 8 / 8R / 8.S ships in a **single PR** that performs all three steps. None is optional:

1. **Online API check.** Verify the vendor's developer documentation is current; capture URL + retrieval date in the per-vendor `api_consumed.md`. CI lint warns if older than 180 days.
2. **Framework engineering.** Implement the adapter against the documented API shape; bind to every framework seam in `vendor_adapter_slice_contract.md`; ship fixture-based tests that prove every framework call.
3. **Docs synthesis.** Populate `docs/integrations/<vendor_id>/` with the 6-file doc pack per `per_vendor_doc_pack_contract.md`. Every assumption the adapter makes about vendor shape is captured here so the `*.live` slice can diff documented vs observed.

A slice that ships steps 1+2 but skips step 3 is incomplete; the doc pack is the contract the `*.live` slice grades against.

## 4-state vendor lifecycle (binding)

Every adapter lives in one of these states. State is canonical truth on `VendorCapabilityProfile.lifecycle`:

- `documented` — engineering slice landed; adapter compiles + fixture-tested; doc pack populated. Vendor picker shows "Coming soon" pill, no Connect button.
- `sandbox_verified` — `*.live.sandbox` slice ran; sandbox verification checklist filled. Picker shows "Coming soon — sandbox verified" pill.
- `production_credentialed` — `*.live.prod` slice ran; partnership cleared; production keys issued. Connect button live.
- `live_with_operators` — first operator connected (auto-promote, no slice). Connected-operator chip in F&F Ops Console.

The lifecycle field replaces the boolean `partnershipGated` on `VendorCapabilityProfile`. Slice `8.0.lifecycle` (first item in Wave B) extends the existing boolean to the enum.

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

Additional `8.0` deliverables (V1 leaner posture, locked 2026-05-03; trimmed again 2026-05-03 after first-iteration over-engineering review per `memory/project_v1_lean_cut_2_2026_05_03.md`):

- **Metric Honesty Doctrine plumbing.** Lands the data layer + widgets that bind `docs/contracts/metric_card_honesty_contract.md`. Every load-bearing metric (CPLH / SPLH / PPA / blended wage / covers / hours) carries `state` (live / partial / fallback / unavailable) + `provenance` from the read model. New code surface: `lib/domain/models/metric_provenance.dart`, `lib/widgets/metric_card_not_yet_available.dart`, `lib/widgets/data_source_health_pill.dart`. The widget-layer rule is strict: `live`, `partial`, and `fallback` all render the number clean (same as today) — degradation surfaces only via the top-left dashboard pill (absent when fully live, single plain-English line when not). `unavailable` renders the empty-state widget; never a phantom zero.
- **Inbound webhook reliability.** Per-vendor signature verification using constant-time HMAC compare. Loose 24-hour replay window (rejects signatures older than 24h for vendors that include a timestamp). Idempotency keyed on `(vendor_id, operator_id, vendor_event_id)` stored in `inbound_webhook_idempotency` with 30-day TTL via `pg_partman`. After signature verification passes, the adapter cross-checks the payload's claimed vendor-location identifier against the stored binding in `connector_connection.metadata`. Mismatch returns 403 with audit row, no canonical-fact write. Dead-letter table `inbound_webhook_dead_letter` captures events that fail processing 3 times. **No 11A.6 tile at V1** — log rows + admin SQL query are enough; tile lands when operator depth justifies it.
- **Fact-level idempotency.** Canonical fact writes upsert on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`. Same fact arriving via webhook and polling is a no-op on the second arrival. Out-of-order delivery is handled by last-write-wins on `vendor_modified_at`; older incoming event is rejected as stale.
- **Timestamp sanity guard at adapter boundary.** New `lib/services/integration/vendor_timestamp_sanity.dart` runs three rules per inbound event before any canonical-fact write: `closed_at >= opened_at`, `opened_at <= now() + 1 hour`, `opened_at >= now() - 90 days` (deliberate backfill paths skip the historical guard via an explicit flag). Failures drop the event with a log row; never silently mis-bucket the operator's day. Less rigorous than IANA Scenarios A-F (which stay rigorous because they govern business-date bucketing) and more rigorous than nothing.
- **Sanity hook contract (V1 lean cut 2 amendment 2026-05-03 master fix).** The webhook handler enforces sanity inline (step 4 of the dispatch sequence). The polling and backfill paths enforce via a per-tick `sanityHook` callback bound on `PollIncrementalCommand` / `BackfillCommand` by `tool/integration_sync_worker/integration_sync_worker.dart`. **Every Wave 1+ adapter MUST call `command.sanityHook(...)` before each canonical fact write and skip the write when it returns `false`.** The framework cannot inspect the rows adapters write, so the hook is the ONLY enforcement point for the polling path; a missed call silently ships future-dated / out-of-order facts to the operator dashboard and breaks priority 1 (correct timestamps). The `sanityDropped` count is surfaced on `PollIncrementalResult` so worker telemetry sees per-tick drop counts without re-querying `sanity_log`.
- **OAuth refresh cron (no advisory lock).** `pg_cron` job at 5 minutes past every hour runs `proxy.refresh_expiring_inbound_vendor_tokens()`. Refreshes any `vendor_credentials` row with `token_expires_at < now() + interval '24 hours'`. Single Cloud Run job instance + low cadence = no contention at V1 scale; advisory lock dropped per the lean cut. On success, update tokens and write audit row. On 3 consecutive failures, set the connection's status to `error` and write an audit row. **Email alert wiring to `9.8.email` deferred** — operator sees the `error` state in admin UI; auto-disable + email notification land as a `9.8.email` follow-up when volume justifies the engineering work.
- **Credential encryption: pgcrypto envelope only at V1.** Staging and V1 production both encrypt `vendor_credentials` via `pgp_sym_encrypt`/`pgp_sym_decrypt` with the key in Cloud Run secret env. **Cloud KMS rollout deferred** to a Production1 hardening lane post-launch. Crypto-shredding namespace is part of the deferred KMS work.
- **Demo-mode-to-live transition.** New `demo_mode_state` table at `(operator_id, location_id, category)` granularity. Default `is_demo = true` at operator-create time. Flip to `is_demo = false` when the first INTEGRATE vendor connection for that (op, loc, cat) reaches `connected` status and first backfill commits at least 1 record. Disconnect does not auto-revert; historical facts stay. Spec: `docs/phases/phase_11W/operator_onboarding_flow.md` "Demo-mode-to-live transition" section.
- **Backfill cursor persistence per batch commit.** `connector_sync_watermark.cursor_token` and `last_modified_seen` are updated after each successful batch insert. On Cloud Run Job crash, restart resumes from the last persisted cursor.
- **`disconnect_reason` enum on `connector_connection`.** Values: `operator_action`, `vendor_revoked`, `vendor_endpoint_deprecated`, `oauth_timeout`. (`auto_disable_3_strike` deferred with the email-alert wiring.) Operator-facing copy varies per reason.
- **Malformed vendor payload defense.** Adapter framework wraps DTO parsing in try-catch and drops the event with a single log row. **No `parse_warnings` JSONB column, no `parse_partial` flag** — those add plumbing the operator never sees and that engineering can introduce later if real failure patterns argue for it.
- **Raw_payload retention (single column).** Vendor DTO stored as JSONB alongside the normalized fact on the canonical fact tables. **No sibling `*_raw_payload` partitions, no pg_partman, no rolling delete** at V1. Single JSONB column is enough until table size or storage cost makes the engineering work justified.

State machine for `connector_connection.status` is 3 states at V1: `connected`, `disconnected`, `error`. `degraded` and `connecting` are added later when monitoring justifies them. Operator-facing copy makes `error` actionable (most often "vendor revoked our access; please reconnect and sign back in").

V1 acceptance posture (relaxed per lean cut 2):

- **Test-connection acceptance:** returns within client timeout (~30s default) and surfaces a real sample row. **No 5-second SLA** — vendor APIs do not reliably meet 5s and the SLA was unnecessary engineering pressure.
- **Backfill window:** best-effort 60-day attempt at first connect; accept whatever the vendor allows; watermark is preserved regardless of how much history actually loaded.
- **IANA Scenarios A-F:** bound at the framework level (this slice). Per-vendor adapter slices cite the framework + only re-run scenarios that touch their specific timestamp shape; full A-F re-run is not required per vendor unless the vendor exposes an exotic timestamp form.
- **Partnership programs:** parallel commercial lane; never gate adapter shipping. Adapters ship against documented APIs / sandboxes; production credentials unlock live data when the partnership clears. See `vendor_master_list.md` Wave Plan.

V1 explicit non-goals (deferred per `project_v1_lean_scope_cut.md` round 1 + `project_v1_lean_cut_2_2026_05_03.md` round 2): append-only supersede mechanism, `source_connection_id` on canonical fact rows, vendor-migration overlap window, per-vendor token bucket, PgBouncer, schema-migration freeze-window runbook, async-Cloud-Run-Job backfill with progress UI, 5-state connection machine, KMS rollout, webhook signing key rotation UI, `parse_warnings` plumbing, advisory locks on OAuth refresh, 3-strike auto-disable email wiring, pod SIGTERM graceful drain handler, raw-payload sibling partitions + pg_partman, 11A.6 inbound-webhook DLQ tile.

Walkthrough at acceptance — click-path per `docs/CODEX_PROMPT_GENERATION_STANDARD.md` Walkthrough Specificity section. Anchor scenarios:

1. Demo operator, kDemoMode=true, business date 2026-W18 Mon. Settings → Vendor connections → POS card. Empty state reads "Connect your POS." Top-left dashboard pill **absent** (operator is in pure demo, no sources to evaluate).
2. Tap "Choose your POS" → vendor picker → Lightspeed K-Series → "Sign in with Lightspeed". Sandbox OAuth completes. Card flips to Connected, green dot, "Last sync: just now."
3. Open Shift dashboard. CPLH card renders the number clean (same as today). PPA card renders the number clean. **No card-level chrome.** Top-left dashboard pill absent (Lightspeed is `live` for sales/covers; labor not yet connected so Labor metrics are `unavailable` → empty-state widget renders, pill appears with "Labor: not yet connected").
4. Variance > This Week > Full Week Projection. Open/projected rows continue to honor 7.58 lever-id honesty (no carry-forward).
5. Disconnect Lightspeed. Confirmation bullets. Confirm. Card flips grey. Sales/covers metric cards flip to `MetricCardNotYetAvailable` widget. No phantom $0.00. Pill updates to "Sales: not yet connected, Labor: not yet connected" or similar.
6. Reconnect Lightspeed. Watermark preserves; first backfill resumes from where it left off. Card flips green. Metric cards return to `live` rendering.
7. Forged-signature webhook → 403 + audit row + no fact write.
8. Malformed payload (unexpected field shape) → log row + dropped, not in the queue.
9. Future-dated event (`opened_at = now() + 5 days`) → log row + dropped via timestamp sanity guard.
10. OAuth near-expiry → cron refreshes token within 1 hour; audit row written; connection stays `connected`.

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
