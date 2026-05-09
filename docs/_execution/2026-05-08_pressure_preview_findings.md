# Pressure Preview v1 — Findings

Sprint: `pressure.preview.v1`
Skeleton created: 2026-05-08 (Phase 0)
Filled: 2026-05-09 (Phase 5 consolidation)

This doc consolidates findings from Phases 1-3 of the pressure-test
sprint. Phase 6 reads it to drive the Postgres unit-test backfill.

The plan doc lives at
`docs/_execution/2026-05-08_pressure_preview_v1_plan.md`.

## Top-line severity counts

| Severity | Count | Examples |
|---|---|---|
| P0 | 1 | Schema-info leak via signature-verifier ordering bug (Phase 3A) |
| P1 | 5 | Square / LSK timestamp coercion, Humanity time-off-as-shift, OAuth-closure registry mismatches (×3 actionable), preview-env Postgres pool exhaustion |
| P2 | 6 | Audit-doc auth-mode mismatches (×4), preview-env schema gaps, vendor-route 404 (`unknownVendor` for 6 vendors in preview) |
| P3 | ~25 | Vendor-doc partner-portal escalation items (sourcing gaps), per-vendor field/enum/encoding ambiguity calls |

---

## 1. Per-Vendor Pass / Fail Matrix

Columns map to the harness layers actually run in Phases 2A, 2B, 2C, 2D, 3A, 3C. Phase 3B is load-only at the worker layer (not per-vendor). Cells: `pass` / `fail` / `skip` (no DB / out-of-scope) / `n/a`. PR cites in parentheses.

| Vendor | 2A Adapter | 2B Sink | 2C Spine | 2D Mobile-sync | 3A Webhook flood | 3C OAuth refresh | Real bugs |
|---|---|---|---|---|---|---|---|
| `square` | fail (E coerce + adapter_not_found) | skip (#446) | pass (#449) | pass — POS (#447) | fail — `unknownVendor` 404 in preview (#452) | pass — closure wired | DateTime.tryParse coerce; doc-mismatch lifted |
| `toast` | pass (adapter_not_found only) | skip (#446) | pass (#449) | pass — POS (#447) | fail — 5xx + 5xx_under_load (#452) | pass — closure wired | Preview env `relation public.vendor_credentials does not exist`; signature-verify ordering bug |
| `clover` | pass (adapter_not_found only) | skip (#446) | pass (#449) | pass — POS (#447) | fail — `unknownVendor` 404 in preview (#452) | pass — closure wired | Preview-env vendor-capability registry gap |
| `oracle_micros_simphony` | fail — audit_claim_mismatch (auth) (#448) | skip (#446) | pass (#449) | pass — POS (#447) | fail — signatureInvalid 403 (no verifier registered) (#452) | pass — closure wired (mismatch flagged) | Audit doc claimed mTLS; adapter says `oauth` AND closure exists |
| `aloha_ncr_voyix` | pass (adapter_not_found only) | skip (#446) | pass (#449) | pass — POS (#447) | fail — `unknownVendor` 404 in preview (#452) | pass — closure wired | Preview-env vendor-capability registry gap |
| `revel` | pass (adapter_not_found only) | skip (#446) | pass (#449) | pass — POS (#447) | fail — 5xx + 5xx_under_load (#452) | pass — closure wired | Preview-env schema gap (`column op.rollover_hour does not exist`) |
| `lightspeed_lsk` | fail — scenario_e timestamp coerce (#448) | skip (#446) | pass (#449) | pass — POS (#447) | fail — 5xx + 5xx_under_load (#452) | pass — closure wired | DateTime.tryParse coerce in `_parseUtcInstant`; sink-route preview schema gap |
| `libro` | pass (adapter_not_found only) | skip (#446) | pass (#449) | pass — Reservation (#447) | fail — `unknownVendor` 404 in preview (#452) | pass — closure wired | Preview-env vendor-capability registry gap |
| `tock` | pass (adapter_not_found only) | skip (#446) | pass (#449) | pass — Reservation (#447) | fail — 5xx + 5xx_under_load (#452) | pass — `kVendorsWithoutRefreshClosure` matches keyPaste | None new; corpus all assumptions until partner portal opens |
| `opentable` | fail — audit_claim_mismatch (auth) (#448) | skip (#446) | pass (#449) | pass — Reservation (#447) | fail — 5xx + 5xx_under_load (#452) | fail — `oauth_vendor_missing_closure` (#451) | Audit doc said "internal"; adapter declares `oauth` but worker has NO closure registered (refresh log-and-skipped) |
| `sevenrooms` | fail — audit_claim_mismatch (auth) (#448) | skip (#446) | pass (#449) | pass — Reservation (#447) | fail — 5xx + 5xx_under_load (#452) | fail — `oauth_vendor_missing_closure` (#451) | Audit doc said "transport"; adapter declares `oauthOrKeyPaste` but worker has NO closure |
| `quickbooks_time` | pass (adapter_not_found only) | skip (#446) | pass (#449) | pass — Labor (#447) | fail — `unknownVendor` 404 in preview (#452) | pass — closure wired (Intuit env-gated) | Preview-env vendor-capability registry gap |
| `adp` | fail — audit_claim_mismatch + wrong_reject_reason (#448) | skip (#446) | pass (#449) | pass — Labor (#447) | fail — 5xx + 5xx_under_load (#452) | fail — `oauth_vendor_missing_closure` (#451) | Audit doc said "mTLS"; adapter declares `oauth` but worker has NO closure (refresh log-and-skipped) |
| `seven_shifts` | fail — wrong_reject_reason on F + E (#448) | skip (#446) | pass (#449) | pass — Labor (#447) | fail — `unknownVendor` 404 in preview (#452) | pass — closure wired (env-gated) | Preview-env vendor-capability registry gap |
| `humanity` | fail — pre_flagged_bug confirmed (time_off as 24h shift) + wrong_reject_reason (#448) | skip (#446) | pass (#449) | pass — Labor (#447) | fail — 5xx + 5xx_under_load (#452) | fail — `non_oauth_vendor_has_closure` (#451) | `HumanityShiftDto.tryFromMap` accepts `type=time_off` as 24h shift; closure registered but adapter declares `keyPaste` (inverse mismatch) |
| `agendrix` | fail — audit_claim_mismatch (auth) (#448) | skip (#446) | pass (#449) | pass — Labor (#447) | fail — 5xx + 5xx_under_load (#452) | partial — `agendrix_closure_status` flagged (#451) | Audit doc said "static API key"; adapter declares `oauth` but worker has NO closure (correctly omitted given no closure factory) — operator-doc misleading |
| `push_operations` | pass (adapter_not_found only) | skip (#446) | pass (#449) | pass — Labor (#447) | fail — 5xx + 5xx_under_load (#452) | pass — `kVendorsWithoutRefreshClosure` matches keyPaste | None new; preview env still throws 5xx |

Notes:
- "skip (#446)" for the 2B Sink column: Phase 2B's harness is structural-only on this Windows host (no local Postgres). Each (vendor, fixture) emitted one `setup_skipped` finding; runtime assertions deferred to Phase 6 backfill against staging.
- "pass" in the 2C Spine column means in-memory `CanonicalSink` fake exercised the projector + realtime + flip + cursor-resume + throughput contracts — see PR #449 for the deferral note.
- "pass" in 2D Mobile-sync means the `DemoModeBanner` widget mounted, sync-sets persisted to mobile SQLite without NULLs in NOT NULL columns, and per-scope cursor isolation held under cross-tenant wipe — see PR #447.
- 3A `unknownVendor` 404 means the route IS registered (structured response shape) but the framework's vendor-capability registry is missing those vendor IDs in the preview environment. Production-env behavior unknown until staging-driven re-run.
- 3A 5xx-under-load is preview-env structural state (`relation "public.vendor_credentials" does not exist`, `column op.rollover_hour does not exist`, and `DependencyTimeoutException(surface: postgres, operation: acquire_connection, elapsed_ms: 10000)`), not adapter failures. Same root cause across the 10 affected vendors.

---

## 2. Per-Layer Pipeline Result Tables

### 2A — Adapter (PR #448)

| Metric | Value |
|---|---|
| Total cases run | ~221 (17 vendors × ~13 fixtures) |
| Findings written | 23 |
| Pass rate (no divergence vs README) | ~89% by case |
| Biggest finding | Square `scenario_e_ambiguous_timestamp.json` confirmed silent coerce: `DateTime.tryParse("2026-05-08T18:45:00").toUtc()` yields a UTC instant 2.5h shifted from intent. Same shape on Lightspeed K-Series. |
| Findings by category | `adapter_not_found` ×15 (private parser helpers), `audit_claim_mismatch` ×2 (Oracle Simphony, Agendrix), `pre_flagged_bug_confirmed` ×3 (Square, Lightspeed K-Series, Humanity), `wrong_reject_reason` ×3 (square / adp×7shifts / humanity×7shifts pairings) |

### 2B — Sink Postgres (PR #446)

| Metric | Value |
|---|---|
| Total cases run | 221 (structural mode — no `PRESSURE_PG_URL`) |
| Findings written | 17 (all `setup_skipped`) |
| Pass rate (structural assertions) | 17/17 sink files exist with expected `*PostgresSink` class name; 17/17 corpora classify cleanly into the documented scenario taxonomy |
| Biggest finding | All runtime cases (`idempotency_violation`, `rls_leak`, `system_bypass_failed`, `cross_vendor_namespace_bleed`, `demo_flip_didnt_fire`, `demo_flip_wrong_fields`) deferred to Phase 6 backfill against staging — Phase 6 is the first opportunity to catch real seam regressions. |
| Coverage holes | Per-vendor canonical-fact-table sink writes are `setup_skipped` (per (vendor, fixture)). Phase 2C's spine harness exercised the projector contract via in-memory fakes; Phase 6 needs to convert these to real-DB assertions. |

### 2C — Spine bridge (PR #449)

| Metric | Value |
|---|---|
| Total cases run | 17 (one per vendor) × 5 contract surfaces |
| Findings written | 1 (`setup_skipped` — in-memory `CanonicalSink` fake stood in for real sink) |
| Pass rate | 5/5 contract surfaces hold for all 17 vendors against the in-memory sink |
| Biggest finding | None at this seam. Projector invocation, realtime broadcast, demo-flip broadcast, backfill cursor-resume, and 10-fact throughput all behaved per spec. The deferred risk lives in the gap between in-memory `CanonicalSink` fake and real `*_postgres_sink.dart` Phase 6 has to close. |

### 2D — Mobile sync (PR #447)

| Metric | Value |
|---|---|
| Total cases run | 11 task assertions across 3 categories (POS, Labor, Reservation) |
| Findings written | 0 |
| Pass rate | 11/11 |
| Biggest finding | None. Operator-scoped subset delivery, cross-tenant wipe + per-scope cursor isolation, demo-banner per-category clear, foreground-resume refresh, and widget render against synced data all held. |

---

## 3. Per-Load-Lane Result Tables

### 3A — Webhook flood (PR #452)

| Field | Value |
|---|---|
| Smoke params | `--ops=10 --duration=5min --rate=2` (1700 reqs after 17 warm-ups) |
| Requests sent | 1700 (excl. 17 warmup) |
| 2xx | 0 |
| 4xx (excl. 429) | 700 |
| 5xx | 1000 |
| HTTP-completion rate | 41.2% |
| Latency p50 / p95 / p99 | 5293 / 10083 / 10130 ms (budget 2000) |
| Findings | 27 across 5 categories (`5xx_under_load` ×10 vendors, `signature_verifier_crash` ×10 vendors, `latency_over_budget` aggregate, `vendor_route_404` ×6 vendors, `connection_pool_exhaustion` aggregate) |
| Biggest finding | **Schema-info leak via signature-verifier ordering** — forged-signature scenario_a fixtures returned 5xx instead of 401/403, and the response body included `relation "public.vendor_credentials" does not exist` plus a stack frame. Verifier path crashes BEFORE returning a structured signature-rejection because the upstream Postgres lookup throws first. Signature defense MUST run before credential lookup. |
| Full-scale invocation | `dart run tool/pressure/p3a_webhook_flood.dart --ops=100 --duration=30min --rate=10 --retry-each=3` (~510k POSTs × 3 retries). Deferred until ordering-bug fix + connection-pool fix land — see PR #452 body for guidance. |

### 3B — Backfill flood (PR #450)

| Field | Value |
|---|---|
| Smoke params | `--ops=5 --vendors-per-op=3 --records-per-vendor=100 --worker-pods=2 --simulate-restart=1` |
| Jobs run (smoke) | 18 (15 regular + 3 demo-flip race) |
| Jobs reaching terminal state | 18/18 in 527ms |
| Findings | 1 (`setup_skipped` — in-memory simulator; `POSTGRES_URL` unset) |
| Biggest finding | None observed under in-memory simulation that mirrors `connector_backfill_job_repository.dart`'s `FOR UPDATE SKIP LOCKED` claim semantics. Demo-flip race resolved across all 3 categories with 1-15ms spread; pod-restart resume held; no worker collision. |
| Full-scale invocation | `dart run tool/pressure/p3b_backfill_flood.dart --ops=10 --vendors-per-op=3 --records-per-vendor=1000 --worker-pods=3 --simulate-restart=3` — locally completed 33/33 jobs in 743ms (in-memory). Real-DB run deferred to Phase 6 alongside `connector_backfill_job_repository` real test. |

### 3C — OAuth refresh storm (PR #451)

| Field | Value |
|---|---|
| Smoke params | `--ops=2 --connections-per-op=11` |
| Refreshes coordinated | 11 wired-OAuth + 6 unsupported (per `kVendorsWithoutRefreshClosure`) |
| Findings | 6 across 4 categories |
| Biggest finding | **Closure-registry vs adapter authMode mismatches** — Humanity has a closure registered while declaring `keyPaste` (`non_oauth_vendor_has_closure`); ADP / OpenTable / SevenRooms have `oauth`-flavored authModes but no closure (`oauth_vendor_missing_closure`); Agendrix declares `oauth` but worker correctly omits a closure (audit doc said "static API key" — operator-doc misleading); Oracle Simphony's audit-doc said mTLS but adapter declares `oauth` AND closure is wired (audit doc wrong). |
| Full-scale invocation | `dart run tool/pressure/p3c_oauth_refresh_storm.dart --ops=10 --connections-per-op=11 --near-expiry-ms=2000 --concurrent-polls=10 --worker-pods=3` — not yet executed at scale. Deferred until ADP / OpenTable / SevenRooms closure decisions land (close the gap or document deliberate omission). |

---

## 4. Real Bugs Ranked by Impact

### P0 — Schema-info leak via webhook signature-verifier ordering bug

- **Surface**: preview proxy `POST /v1/webhooks/{vendor}/{operator}/{location}` for the 10 vendors covered by current Phase 8 sink path.
- **Description**: Forged-signature webhook payloads (Phase 1 `scenario_a_forged_signature.json`) return HTTP 5xx instead of 401/403, and the response body leaks `relation "public.vendor_credentials" does not exist` plus a stack frame. The verifier code path is downstream of an upstream Postgres lookup; when the lookup throws (preview-env structural state), the verifier never runs and the framework's catch-all leaks the underlying error message.
- **Evidence**: PR #452. 10 of 17 vendor verifiers exercised; `signature_verifier_crash` finding ×10.
- **Proposed fix**: Re-order verification in `lib/services/integration/inbound_webhook_handler.dart` so the framework's `WebhookSignatureVerifier.verify(...)` runs BEFORE any Postgres call, including the credential-lookup path used to source the signing secret. Sourcing-secret lookup should pull from a per-(operator, location, vendor) cache populated at connection-time, with cache miss falling through to a generic 401 (not a 500). Sanitize stray `Severity.error` strings out of error response bodies regardless.
- **Already in progress**: A separate triage branch (`claude/8.gap-1.missing-webhook-signature-verifiers`) exists; no PR open yet at the time of writing.

### P1 — Square + Lightspeed K-Series silent timestamp coercion (`scenario_e_ambiguous_timestamp`)

- **Surface**: `lib/integrations/pos/square_pos_adapter.dart` (`_orderToCanonicalFact` lines 753-759); `lib/integrations/pos/lightspeed_lsk_pos_adapter.dart` (`_parseUtcInstant`).
- **Description**: `DateTime.tryParse(naiveTimestamp).toUtc()` silently coerces offset-less timestamps against the host's local timezone. Operators in non-UTC zones get rows bucketed onto the wrong `business_date`. The documented `field_mapping.md` policy is "explicit-Z required, refuse otherwise" — both adapters violate this.
- **Evidence**: PR #448. `scenario_e_ambiguous_timestamp.json` for both vendors. Square also flagged in `wrong_reject_reason` divergence (the test fixture expects an `ambiguous_timestamp` reject reason but the adapter accepts and writes a wrong-business-date row).
- **Proposed fix**: In each adapter, replace the `DateTime.tryParse(...)?.toUtc()` chain with a strict parser that returns `null` on missing `Z` or `+HH:MM` offset. Add a unit test pinning the refusal. Two-file change.

### P1 — Humanity time-off rows accepted as 24h shifts

- **Surface**: `lib/integrations/labor/humanity_labor_adapter.dart` (`HumanityShiftDto.tryFromMap`).
- **Description**: Humanity payloads include `type=time_off` rows in the same shift-list response as actual shifts. The adapter does not branch on `type`, so a `time_off` row gets canonicalized as a 24-hour shift and inflates labor-cost projections.
- **Evidence**: PR #448. `happy_path_time_off_request.json` per the Humanity README's "PHASE 2 FLAG" annotation, and the Phase 2A confirmation.
- **Proposed fix**: In `tryFromMap`, return `null` when `type == 'time_off'`. One-liner. Add a unit test pinning the skip.

### P1 — Closure-registry mismatches: ADP / OpenTable / SevenRooms have `oauth`-flavored authMode but no refresh closure

- **Surface**: `tool/integration_sync_worker/production_oauth_refresh_closures.dart` (`buildProductionRefreshClosures`); `lib/integrations/labor/adp_labor_adapter.dart`, `lib/integrations/reservation/opentable_reservation_adapter.dart`, `lib/integrations/reservation/sevenrooms_reservation_adapter.dart` (`capabilityProfile.authMode`).
- **Description**: Three vendors declare `oauth` (ADP, OpenTable) or `oauthOrKeyPaste` (SevenRooms) on their capability profile, but `buildProductionRefreshClosures` does not register a closure factory for them. At runtime the `oauth_refresh_cron` log-and-skips refresh rows for these vendors. ADP is intentional (mTLS owns rotation; the `vendor_credentials.refresh_token` column is null per design), but the operator-facing trail does not say so. OpenTable's adapter README states refresh is handled INTERNALLY by `OpenTableTransport.refresh`, not by the broker — this is a deliberate split that the closure-registry surface should declare. SevenRooms is per `oauth_shape.md` `transport`-layer per-tenant secret rotation at `POST /2_2/auth`.
- **Evidence**: PR #451. `oauth_vendor_missing_closure` finding ×3.
- **Proposed fix**: For each of the three, either (a) add a stub closure that explicitly delegates to the documented surface (mTLS partner ops for ADP, internal transport for OpenTable, transport-layer cron for SevenRooms), OR (b) add a typed entry in `kVendorsWithoutRefreshClosure` with a `reason` field that the OAuth refresh cron logs once at boot. Option (b) is the smaller change.
- **Status (2026-05-08)**: PR #455 chose option (b) — placed all three on `kVendorsWithoutRefreshClosureReason` with documented delegation reasons.
- **Status (2026-05-09)**: re-investigated. ADP and OpenTable both expose a programmatic OAuth `grant_type=refresh_token` surface using per-tenant `client_id` / `client_secret` from `metadata` — both wired via `makeAdpOauthRefreshClosure` / `makeOpenTableOauthRefreshClosure` in this PR (registry now has 12 wired closures; previously 10). PR #455's "ADP partner-ops mTLS" and "OpenTable transport-internal refresh" claims conflated separate surfaces (mTLS cert rotation is on the SecurityContext, not the OAuth grant; OpenTable's `transport.refresh()` exists but has no driver). SevenRooms remains unwired with refined reason `sevenrooms_client_secret_not_persisted`: the bridge's `persistIssuedBearerToken` only persists `client_id` to metadata; the `client_secret` is dropped after the connect-time `authenticate()` call, so the broker cannot call `POST /2_2/auth` to mint a fresh bearer. Re-wiring SevenRooms requires a follow-up slice (modify the bridge to persist `client_secret` ciphertext + connect-flow update + reconnect-prompt for legacy rows) — full follow-up spec in `docs/integrations/sevenrooms/oauth_shape.md` "Refresh handling (broker delegation)".

### P1 — Humanity inverse closure mismatch (`non_oauth_vendor_has_closure`)

- **Surface**: `tool/integration_sync_worker/production_oauth_refresh_closures.dart` registers a closure for `humanity` gated on `HUMANITY_CLIENT_ID/_SECRET`; the adapter's `capabilityProfile.authMode = keyPaste`.
- **Description**: Either the closure is dead code that never fires at runtime (because no Humanity row will ever be `authMode=oauth`), or the adapter declaration is wrong (Humanity actually IS OAuth — the password-grant variant — and authMode should be `oauth` or a new `oauthPasswordGrant` enum).
- **Evidence**: PR #451 + Humanity README ("Auth mode: `keyPaste` — Humanity v1 uses OAuth 2.0 Resource Owner Password Credentials grant…"). The README acknowledges the impedance mismatch.
- **Proposed fix**: Decide which is correct. If `authMode` should reflect the underlying OAuth-ness (most useful for the closure registry), bump it to `oauth` and document the password-grant variant in the adapter. Otherwise remove the closure factory and add Humanity to `kVendorsWithoutRefreshClosure`.

### P1 — Preview-env Postgres pool exhaustion at trivial load

- **Surface**: preview proxy Cloud Run revision; `acquire_connection` borrow timeout at exactly 10000 ms producing the bimodal latency distribution.
- **Description**: 640 of the 1000 5xx responses in the Phase 3A smoke run carry `DependencyTimeoutException(surface: postgres, operation: acquire_connection, elapsed_ms: 10000)`. The preview proxy's PgPool is hitting the borrow timeout under sustained 17-vendor × 10-op × 2/min load (≈340 reqs/min sustained). p95 latency is 5x the 2000ms budget for the same reason.
- **Evidence**: PR #452 — `connection_pool_exhaustion` aggregate finding.
- **Proposed fix**: Either widen pool capacity for the preview Cloud Run revision (env var; verify against `runbooks/preview_environment_runbook.md`) OR run preview with `-DeferProxyStartupDatabase` if the workload doesn't actually need proactive DB warmup. Aggregator now matches `acquire_connection` / `dependencytimeoutexception` patterns and will surface the category automatically on next run.

### P2 — Audit-doc auth-mode mismatches (Oracle Simphony, ADP, OpenTable, SevenRooms, Agendrix)

- **Surface**: `docs/contracts/hardening_rls_and_repository_pattern_contract.md` (already updated by Lane G per #421); the auth-mode source-of-truth lives in `capabilityProfile.authMode` on each adapter, but operator-facing docs still cite the wrong values for: Oracle Simphony (claimed mTLS, actual `oauth`), ADP (claimed mTLS, actual `oauth`), OpenTable (claimed "internal", actual `oauth`), SevenRooms (claimed "transport", actual `oauthOrKeyPaste`), Agendrix (claimed "static API key", actual `oauth`).
- **Description**: Operators reading the audit-tier docs see incorrect classifications, which feeds bad rotation-runbook expectations and may mislead support response when a connection fails to refresh.
- **Evidence**: PR #448 (audit_claim_mismatch ×2 — Oracle, Agendrix); PR #451 closure-registry reconciliation. Lane G already corrected the hardening_rls source contract.
- **Proposed fix**: Sweep `docs/integrations/<vendor>/oauth_shape.md` and any `partnership_status.md` rows that cite the old auth model. The closure-registry-vs-adapter mismatch (P1 above) is the runtime issue; this P2 is the doc-correctness sweep.

### P2 — Preview-env vendor-capability registry gap (6 vendors `unknownVendor`)

- **Surface**: preview Cloud Run framework's vendor-capability registry.
- **Description**: 6 vendors return `{"outcome":"unknownVendor","records_written":0,"message":"unknown vendor"}` for all webhook posts in the preview env: `aloha_ncr_voyix`, `clover`, `libro`, `quickbooks_time`, `seven_shifts`, `square`. The route IS registered (structured response shape), but the framework's vendor-capability registry doesn't have these vendor IDs enabled in the preview env.
- **Evidence**: PR #452 `vendor_route_404` finding ×6.
- **Proposed fix**: Reconcile the preview env's vendor-capability registry with the adapter manifest. Either it's a bootstrap migration that didn't apply to preview, or it's a startup-time enablement env-var that needs flipping. Investigate against the preview Cloud Run revision config.

### P2 — Preview-env schema gaps (`relation "public.vendor_credentials" does not exist`, `column op.rollover_hour does not exist`)

- **Surface**: preview Postgres database (separate Cloud Run revision sharing staging DB cluster, but with revision-bound schema state).
- **Description**: Surfaced as the root cause of 1000 of the 5xx responses in Phase 3A. Two distinct relation/column gaps named in the response excerpts. Preview env is structurally behind staging on at least these two migrations.
- **Evidence**: PR #452 — `5xx_under_load` finding ×10 vendors; the response excerpts directly cite the missing relation and column.
- **Proposed fix**: Apply the missing migrations to the preview env. Cross-reference `docs/POST_HARDENING_FOLLOWUPS.md` P0 staging apply queue to confirm both migrations are present in staging — preview should track staging's migration state.

---

## 5. Vendor-Doc Partner-Portal Escalation List

Sourcing gaps documented by Phase 1 agents that operators (or the partner-engagement lane) should escalate to vendor partner portals when access lands. Grouped by vendor; each item is one ambiguity / unverified shape.

| Vendor | Items | Detail |
|---|---|---|
| `square` | 3 | `Order` resource exposes no covers / guest count (BASELINE behavior, every fact records `forecast_fallback`); webhook docs publish no canonical "verbatim envelope example for order.updated" — fixtures compose two verbatim shapes; refund + payment events are out-of-scope for the F&F adapter. |
| `toast` | 4 | `doc.toasttab.com/openapi/orders/orders-bulk-v2` and `/doc/devguide/api*` returned 403/404 on 2026-05-08 (Partner Program portal-gated); `scenario_e_ambiguous_timestamp` is synthetic — Toast public docs declare always-Z; Toast labor surface out-of-scope for current POS adapter; Toast Order schema may include extra fields (`appliedTaxes[]`, `requiredPrepBy`, `requiredAvailability[]`, `marketplaceFacilitatorTaxInfo`) the adapter doesn't consume. |
| `clover` | 3 | Most `docs.clover.com/reference/*` pages 404/behind-auth on 2026-05-08; webhook/list-endpoint envelope shapes verified verbatim; OAuth token-response v2 shape is binding source (upstream URL was 404). |
| `oracle_micros_simphony` | 4 | Webhook surface is `pollOnly` (no webhook delivery documented); production token TTL (sandbox doc says ~1h); production strict-Z timestamp confirmation; per-`locRef` zone binding for cross-tz fixture verification. |
| `aloha_ncr_voyix` | 3 | NCR Voyix Developer Program intake (8-16 weeks) gates per-API access for byte-level webhook examples; Aloha employee labor out of V1 adapter scope (`happy_path_employee_punch.json` carries `_sourcing_gap`); voided checks event vs `aloha.check.modified` with `voided: true` is the unconfirmed assumption (`happy_path_void.json` carries `_sourcing_gap`); exact OAuth scope strings not on public landing. |
| `revel` | 5 | `dining_option` integer→label mapping not pinned on public webhooks page; `payments[]` per-row field set reconstructed from public references + adapter forbidden-fields list; `void_reason` enum values illustrative; optional order-envelope `timezone` field undocumented; webhook auto-register endpoint exact path "TBD at sandbox". |
| `lightspeed_lsk` | 1 | Webhook signature exact header name + payload concatenation will be confirmed by `8.LSK.live.sandbox`. |
| `libro` | 0 | Wave 1 launch vendor with sandbox creds; corpus already mirrors public docs verbatim. |
| `tock` | 4 | Vendor 401 response body shape (scenario D) — engineering chose a generic shape; hex vs base64 signature encoding (scenario A) — engineering chose hex; per-status transition timestamps (`arrived_at`, `seated_at`, etc.) — undocumented; `reservation.updated` payload completeness — assumed full reservation shape. |
| `opentable` | 9 | OpenTable Partner API reference is partner-gated entirely; every field-mapping row carries `verify_in_live_sandbox: true`. Specific items: industry-standard reservation envelope (assumed), exact endpoint paths, pagination shape, header names, OAuth scope strings, token lifetimes, signature header name, signature encoding, status enum vocabulary. |
| `sevenrooms` | 6 | Exact webhook signature header name + encoding casing; whether timestamp is part of the signed payload; per-status transition timestamp presence on legacy reservations; sandbox base URL; access-token TTL; exhaustive `status` enum coverage. |
| `quickbooks_time` | 0 | Wave 1 launch vendor with sandbox creds; `developers.intuit.com` is self-serve. |
| `adp` | 6 | `time_event.id` exact path (alternates: `time_event.itemID` for some WFN endpoints, `timePunch.punchID` for WFM); `last_modified_date_time` Z-explicit-or-naive across endpoints; exact `ADP-Signature` header + encoding + signing-secret round-trip; exact event-subscription event name (assumed `time.timeEvent.modify`); mTLS cert rotation cadence + operator-facing notice channel; whether `pay_data` extension is on the same subscription or only on pull endpoint. |
| `seven_shifts` | 0 | `developers.7shifts.com` self-serve; corpus mirrors public docs verbatim. |
| `humanity` | 0 | Public dev portal mirrored; the `time_off-as-shift` is an engineering bug, not a sourcing gap. |
| `agendrix` | 4 | Agendrix v2 dev portal docs require sign-in (all public URLs point at the documentation root); no webhook delivery doc — Scenario A verifier shape is industry-standard SaaS partner convention; OAuth scope vocabulary not externally documented; no vendor-published rate-limit numbers (`120 req/min/org` is vendor-soft). |
| `push_operations` | 3 | `developers.pushoperations.com` partner-gated — exact `/api/v1/labour` envelope inferred from sibling endpoints; exact `breaks[]` sub-record schema (`type` ∈ {`meal`, `rest`}) inferred; exact 401 response body on revoked-bearer documented vendor convention but not pinned to a numbered endpoint doc URL. |

**Total sourcing gap items**: ~51 across 17 vendors. Highest-impact partner-portal asks (gating live-sandbox slices): Toast Partner Program (4 items), OpenTable Partner API (9 items), SevenRooms partner API portal (6 items), ADP Marketplace DPA (6 items), NCR Voyix Developer Program (3 items), Push Operations partner portal (3 items), Tock Premium-tier developer surface (4 items).

---

## 6. Audit-Claim Mismatches Reconciliation

Reconciles the prior audit doc's auth-mode classifications (and the Phase 1 calling-prompt's "non-OAuth list") against what the adapter code actually declares + what the worker actually wires.

| Vendor | Audit/prompt claim | Adapter `capabilityProfile.authMode` | Worker closure registry | Mismatch type | Doc-fix needed |
|---|---|---|---|---|---|
| `oracle_micros_simphony` | mTLS | `oauth` | wired (unconditional) | doc out-of-date | Update `docs/integrations/oracle_micros_simphony/oauth_shape.md` to drop mTLS framing and reflect Gen2 OAuth client_credentials grant. Lane G already updated `hardening_rls_and_repository_pattern_contract.md`. |
| `adp` | mTLS | `oauth` | wired post-2026-05-09 (`makeAdpOauthRefreshClosure`); mTLS cert rotation remains a SEPARATE partner-ops out-of-band concern | reconciled — broker handles `refresh_token`, SecurityContext handles cert | `docs/integrations/adp/oauth_shape.md` "Refresh handling" section flipped to "wired" 2026-05-09. |
| `opentable` | "internal" | `oauth` | wired post-2026-05-09 (`makeOpenTableOauthRefreshClosure`); transport's vestigial `refresh()` method remains for the future reactive 401 path | reconciled — broker is single rotation owner | `docs/integrations/opentable/oauth_shape.md` "Refresh handling" section flipped to "wired" 2026-05-09. The "transport-internal refresh" claim was aspirational (no driver existed). |
| `sevenrooms` | "transport" | `oauthOrKeyPaste` | NOT wired — refined reason `sevenrooms_client_secret_not_persisted` (architectural gap: bridge drops `client_secret` after connect-time `authenticate()`) | architectural gap — re-wiring requires bridge change + connect-flow update | `docs/integrations/sevenrooms/oauth_shape.md` "Refresh handling" section now carries the verified gap + follow-up slice spec (2026-05-09). |
| `agendrix` | "static API key" | `oauth` | NOT wired (audit-mismatch) | doc out-of-date AND closure missing for actual `oauth` | Update `docs/integrations/agendrix/oauth_shape.md` and `docs/integrations/agendrix/partnership_status.md` to reflect OAuth 2.0 sliding-refresh. Decide: add a closure factory OR add to `kVendorsWithoutRefreshClosure` with a reason. |
| `humanity` | `keyPaste` (per adapter) | `keyPaste` | wired (gated on `HUMANITY_CLIENT_ID/_SECRET`) | inverse mismatch — closure exists for keyPaste vendor | Decide: bump adapter to `oauth` (Humanity uses OAuth password-grant per README) OR remove closure from `buildProductionRefreshClosures`. |

These are runtime-impacting in two cases (P1 above): (1) ADP / OpenTable / SevenRooms — three operators connecting these vendors today get refresh log-and-skipped silently; (2) Humanity — closure either runs against a row that should never exist, or the row should exist but doesn't. The doc fixes are a separate cleanup pass (P2).

---

## 7. Phase 6 Prioritized Postgres-Repo Coverage Map

The 27 of 47 uncovered repositories (from `docs/POST_HARDENING_FOLLOWUPS.md` P2 line, 2026-05-08 census) ranked by what the pressure tests proved is load-bearing. Phase 6 should backfill in the order below — fixtures from Phase 1 are the input shapes that drive Phase 6 tests against the staging DB.

Priority levels:
- **P0** = Pressure tests proved this repo's contract is load-bearing AND no real-DB tests exist. Phase 6 first wave.
- **P1** = Repo is on a path the pressure test exercised, contract is simpler (fewer state transitions / less I/O).
- **P2** = Repo is operator-scoped fact table for an active vendor lane (Phase 1 fixtures exist).
- **P3** = Repo is admin/global, less critical for V1 launch.

Repos NOT listed here already have `*_test.dart` covering them (per `find test -name "*_repository_test.dart"` 2026-05-09 census — 20 repos covered).

| Repo | LOC | Test? | Pressure-test exposure | Phase 6 priority | Why |
|---|---|---|---|---|---|
| `connector_backfill_job_repository.dart` | 445 | yes (`test/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository_test.dart`) | P3B in-memory simulator only | P0 | Phase 3B exercised the `FOR UPDATE SKIP LOCKED` claim semantics + demo-flip race + pod-restart resume against an in-memory simulator that mirrors the production contract. Real-DB tests should re-run the same assertions against staging Postgres to catch regressions in claim ordering, advisory-lock waits, and audit-row emission under contention. Existing test exists but pre-dates the demo-flip-race + pod-restart contract Phase 3B exercises — extend it. |
| `provider_credentials_repository.dart` | 202 | yes (`test/provider_credentials_repository_test.dart`) | NOT directly exercised by pressure tests | P3 | This repo owns the `public.provider_credentials` table (platform-wide proxy keys: Anthropic, Voyage, Azure DB, Gemini), keyed by `key_kind` with a partial-unique-index swap as the rotation contract. The pre-existing `rotate` / `listActive` test groups already pin that contract. The per-tenant Future-lock + atomic-rotation contracts Phase 3C exercises live on a different surface (see next row). Existing test sufficient for V1. |
| `vendor_credential_broker.dart` + `oauth_refresh_cron_runner` (against `public.vendor_credentials`) | n/a | yes (extended in PR #460 — `test/provider_credentials_repository_test.dart` host file with 4 contract groups against in-memory fakes) | P3C per-tenant Future-lock + atomic ciphertext rotation + advisory-lock + failure-counter contracts | P0 | This is the actual surface the Phase 3C contracts live on: `lib/integrations/_common/vendor_credential_broker.dart` + `tool/oauth_refresh_worker/main.dart` (the `OAuthRefreshCronRunner`) against the per-tenant `public.vendor_credentials` table. PR #460 covers (a) the `oauth_refresh_advisory_lock` migration semantics keyed `(operator_id, vendor_id)`, (b) ciphertext atomicity between the simulated vendor RTT and DB commit, (c) the `consecutive_refresh_failures` counter + `kRefreshFailureAutoDisableThreshold` auto-disable, (d) the no-closure-vendor skip path, via in-memory fakes against `_BrokerPool`, `_AtomicCredentialStore`, `_AdvisoryLockGateway`, `_CounterAwareWorkerGateway`. |
| `weekly_plan_snapshot_repository.dart` | 1038 | no | not directly exercised; downstream of Phase 1 fixtures | P0 | Highest-LOC uncovered repo. Locked-week-in-force comparison plan is referenced throughout the architecture (CLAUDE.md "Architecture Guardrails"). Phase 6 should ground tests in the canonical-fact shapes Phase 1 vendor corpora produce so the snapshot logic is exercised against realistic POS sales / labor punches / reservations. |
| `business_timing_profiles_repository.dart` | 947 | no | timing inputs feed `business_date` resolver used across all Phase 1 fixtures | P0 | Phase 3A's preview-env error excerpts cited `column op.rollover_hour does not exist` — operator timing-profile schema is on the critical path. Real-DB tests must pin the rollover-hour + IANA-zone contract that every adapter's `business_date` derivation depends on. |
| `target_cycle_repository.dart` | 775 | no | Phase 2 spine: `TargetCycle` locks 60-day standards | P1 | Architecture Guardrail: "TargetCycle locks 60-day standards." Reads not directly stressed by pressure tests but writes (cycle creation / lock / supersession) are reachable via Phase 1 fixtures. Tests should cover the lock contract under concurrent writes. |
| `forecast_context_repository.dart` | 690 | no | Phase 1 fixtures with `covers_source = forecast_fallback` (Square, Clover, Aloha, Toast sparse) | P1 | The `forecast_fallback` covers-source is the default for every Square fact and a baseline for several other POS vendors. Tests should cover read-after-write consistency and the operator-scoped index contract. |
| `active_target_profile_repository.dart` | 675 | no | tied to `target_cycle_repository` | P1 | Pair-test with `target_cycle_repository`. Active-profile read path is hot during dashboard load; concurrency contract under cycle supersession is the risk. |
| `selected_star_shift_repository.dart` | 616 | no | downstream of Phase 1 POS shift selection | P1 | Operator selects a star shift from the fact table; Phase 1's POS happy-path fixtures populate the source. Tests should cover the (operator_id, location_id, business_date) UNIQUE on selection and the consequence of a star-shift pointing at a closed shift_records row. |
| `auth_events_audit_repository.dart` | 633 | yes (`test/auth_events_audit_repository_test.dart`) | not directly | P2 | Existing test exists but the `actor_kind` and `system` actor paths after Lane A's `audit_logs_repository` fix (#424) need re-verification — Phase 6 should extend rather than re-write. |
| `user_pii_erasure_repository.dart` | 656 | yes (in `test/infrastructure/persistence/postgres/repositories/`) | not directly | P2 | Compliance surface; non-pressure path. Existing test covers the contract but the cascading-FK contract under operator deletion needs grounding. Lower-priority Phase 6 work. |
| `corpus_repository.dart` | 738 | yes (`test/repositories/corpus_repository_test.dart`) | not directly | P3 | AI-frozen lane (per CLAUDE.md HP #5). Existing test sufficient for V1; deferred until freeze-thaw. |
| `graph_repository.dart` | 684 | yes (`test/repositories/graph_repository_test.dart`) | not directly | P3 | AI-frozen (AGE traversal lights up in `11b.2`). Existing test sufficient. |
| `advisor_conversation_log_repository.dart` | 620 | no | not exercised | P3 | AI-frozen (Phase 11b advisor lane). Defer. |
| `mfa_factor_removal_requests_repository.dart` | 566 | yes | not directly | P3 | Existing test covers; admin/security surface; not on V1 critical path. |
| `auth_invites_repository.dart` | 270 | yes | not directly | P3 | Existing test covers. |
| `auth_sessions_repository.dart` | 461 | yes | not directly | P3 | Existing test covers. |
| `auth_login_attempts_repository.dart` | 283 | yes | not directly | P3 | Existing test covers. |
| `audit_logs_repository.dart` | 241 | yes (×2 — `test/repositories/` and `test/infrastructure/persistence/postgres/repositories/`) | tenant-context fix landed Lane A (#424) | P3 | Already covered post-Lane-A. |
| `event_outbox_repository.dart` | 418 | yes | not directly | P3 | Existing test covers. |
| `event_outbox_dead_letter_repository.dart` | 374 | yes | not directly | P3 | Existing test covers. |
| `connector_connection_list_repository.dart` | 355 | yes | reads exercised by 3A | P3 | Existing test covers; preview-env vendor-capability registry gap is not this repo's concern. |
| `data_accuracy_service_period_settings_repository.dart` | 182 | yes | not directly | P3 | Existing test covers. |
| `notification_preferences_repository.dart` | 165 | yes | not directly | P3 | Existing test covers. |
| `feature_flags_repository.dart` | 190 | yes (`test/repositories/feature_flags_repository_test.dart`) | not directly | P3 | Existing test covers. |
| `leaderboard_score_repository.dart` | 310 | yes | not directly | P3 | Existing test covers. |
| `mfa_factors_repository.dart` | 394 | yes | not directly | P3 | Existing test covers. |
| `org_units_repository.dart` | 437 | no | hierarchy-scoped settings (CLAUDE.md HP #11) | P2 | Hierarchy inheritance is an HP guarantee; tests should cover effective-value resolution under concurrent updates. Not pressure-test-driven but high-value for the hierarchy work-stream. |
| `open_shift_snapshots_repository.dart` | 446 | no | exercised in 2D mobile-sync (Labor sync set) | P2 | Phase 2D's mobile sync set wrote `open_shift_snapshots` rows. Real-DB tests should cover the operator-scoped UNIQUE + the `wrote` accounting contract that the mobile-sync delta-projection depends on. |
| `wage_role_rows_repository.dart` | 207 | yes (×2 — covered) | exercised in 2D mobile-sync (Labor sync set) | P3 | Already covered; 2D's wage-role-rows write path didn't surface findings. |
| `mobile_push_outbox_repository.dart` | 276 | no | not exercised | P3 | Push outbox; not on V1 critical path. |
| `mobile_push_tokens_repository.dart` | 373 | no | not exercised | P3 | Push tokens; not on V1 critical path. |
| `service_principals_repository.dart` | 268 | no | hash-chained audit log uses sp:` actors | P3 | Service-principal contract is documented (CLAUDE.md "Proxy & API Conventions"); existing audit-logs path tests transitively cover. Direct repo test would harden but lower-priority. |
| `user_roles_repository.dart` | 468 | yes | not directly | P3 | Existing test covers. |
| `users_repository.dart` | 1484 | yes | not directly | P3 | Existing test covers. |
| `roles_repository.dart` | 291 | yes | not directly | P3 | Existing test covers. |
| `role_permissions_repository.dart` | 138 | yes | not directly | P3 | Existing test covers. |
| `password_history_repository.dart` | 197 | yes | not directly | P3 | Existing test covers. |
| `usage_caps_repository.dart` | 249 | yes | not directly | P3 | Existing test covers. |
| `locations_repository.dart` | 232 | yes | not directly | P3 | Existing test covers. |
| `operators_repository.dart` | 448 | yes | not directly | P3 | Existing test covers. |
| `operator_admins_repository.dart` | 175 | yes | not directly | P3 | Existing test covers. |
| `operator_account_repository.dart` | 162 | no | not exercised | P3 | Lower-priority surface. |
| `invited_user_activation_repository.dart` | 155 | no | not exercised | P3 | Lower-priority surface. |
| `mfa_recovery_request_attempts_repository.dart` | 93 | no | not exercised | P3 | Lower-priority surface. |
| `kms_rollout_flag.dart` | n/a | no | not exercised | P3 | Helper, not a full repo. |
| `recovery_code_attempt_store.dart` | n/a | no | not exercised | P3 | Helper. |

### Phase 6 first-wave order (P0 ranked)

1. `connector_backfill_job_repository.dart` — extend existing test with the demo-flip race + pod-restart resume + audit-row contracts Phase 3B exercises.
2. `vendor_credential_broker` + `oauth_refresh_cron_runner` — covered by PR #460. The 4 contract groups (per-tenant Future-lock, atomic ciphertext rotation, advisory-lock 8472002, consecutive_refresh_failures counter + threshold-trip + no-closure-vendor skip) are pinned via in-memory fakes in test/provider_credentials_repository_test.dart.
3. `weekly_plan_snapshot_repository.dart` — new test, ground in canonical-fact shapes Phase 1 corpora produce.
4. `business_timing_profiles_repository.dart` — new test, ground rollover-hour + IANA-zone contract every adapter depends on for `business_date`.

### Sequencing notes

- Phase 6 should pair fixture-grounded tests with the demo-flip + cross-tenant-wipe assertions Phase 2D already covered against the SQLite mobile mirror — the postgres versions of the same contracts are the missing half.
- Three of the audit-claim-mismatch P1 entries (ADP, OpenTable, SevenRooms) need the closure-registry decision (close gap or document deliberate omission) BEFORE Phase 6 covers `provider_credentials_repository` against staging — otherwise the test's expected behavior isn't pinned.
- Phase 6 must NOT re-cover repos already with `*_test.dart` unless extending for new pressure-test contracts (e.g. `connector_backfill_job_repository`, `provider_credentials_repository`, `audit_logs_repository`).

> **Surface correction (2026-05-09)**: an earlier draft of this section conflated `provider_credentials_repository` (platform-wide proxy keys table) with `vendor_credential_broker` + `oauth_refresh_cron_runner` (per-tenant vendor OAuth surfaces). They are different tables (`public.provider_credentials` vs `public.vendor_credentials`) with different contracts. PR #460 covered the per-tenant surfaces in the right test file but with explicit `CONTRACT GAP` markers so a future reader sees the mismatch.

---

## 8. Emulator E2E Notes (Phase 4 — user-driven)

### Scaffold

Phase 4 scaffold lives at `integration_test/phase_4_emulator/`. It uses
the `flutter integration_test` driver and runs against a connected
Android emulator (or iOS simulator). CI is billing-blocked at the time
of authoring; this lane is operator-driven, anytime.

Operator run command (all scenarios):

```bash
flutter pub get
flutter test integration_test/phase_4_emulator/click_path_runner.dart \
  --flavor forgeflow \
  --dart-define=kDemoMode=true
```

The harness (`_harness.dart`) refuses to run against a non-demo binary
— Phase 4 is a demo-mode walkthrough only (HP #2 + the "Frontend
Exposure" rule).

### Scenarios

| # | File | Path | Substituted? |
|---|---|---|---|
| 1 | `scenario_01_dashboard_load.dart` | Cold boot -> AppShell -> Shift dashboard renders, demo banner mounted, no overflow. | Partial — login-tap path requires `FORGE_FLOW_USE_FIREBASE_AUTH=true` (offline emulator can't reach Firebase). Covered by widget-level `find.byKey(login_demo_operator_button)` in `test/widget_test.dart`. |
| 2 | `scenario_02_settings_traversal.dart` | Dashboard -> Settings icon -> traverse Account / Setup / Data tabs; assert the two `kDemoMode` carve-out sections render. | Partial — prompt named 10 sub-sections; mobile asserts the surfaces post-W3.A (Account, Active sessions, Setup, Data + the two demo carve-outs). Team / Permissions / MFA-recovery moved to Operator Web. |
| 3 | `scenario_03_weekly_plan_review.dart` | Dashboard -> Plan tab (ScheduleBuilder) -> Benchmark tab (BaselineTracker) -> back to Shift. | Partial — "switch week -> review locked snapshot" lives in operator-web week-detail; mobile Benchmark surface is BaselineTracker. |
| 4 | `scenario_04_variance_review.dart` | Dashboard -> Variance tab renders demo facts. | Yes — the prompt's hierarchy-scoped UX trio (Selected scope / Inherited from / Effective value) is rendered exclusively in `lib/operator_web/screens/` + `lib/admin/screens/` per HP #11 + W3.A. Zero matches in `lib/screens/`. Substituted with Variance tab render against demo facts. |
| 5 | `scenario_05_shift_detail.dart` | Whole-day dashboard sticky-section headers (SHIFT OUTPUTS / SHIFT INPUTS / FOH PRODUCTIVITY) or recognized empty state. | Partial — there is no separate "shift detail" screen on mobile; ShiftDashboard IS the whole-day authoritative view per CLAUDE.md Architecture Guardrails. |

### Surgical production-code touches

None. The integration_test scaffold uses `find.byType(...)` against
existing public widget classes (`AppShell`, `ShiftDashboard`,
`VarianceReport`, `ScheduleBuilder`, `BaselineTracker`,
`SettingsScreen`, `DemoModeBanner`) and existing `Key`s
(e.g. `login_demo_operator_button` in `lib/screens/auth/login_screen.dart`,
already present pre-Phase-4). No new `Key`s added; no
`kDemoMode`-gated reader paths added; HP #2 is intact.

### PR

PR: TBD (filled by Codex when the PR opens).

### Per-run findings

TBD — user fills after Phase 4 click-path runs. Capture: which screens
broke under realistic vendor data, where labels lied, where loading
states never resolved, where copy/UX needs tightening.

---

## Cross-References

- `docs/_execution/2026-05-08_pressure_preview_v1_plan.md` — sprint plan
- `test/fixtures/vendor_payloads/README.md` — fixture format spec
- `test/integration/pressure/README.md` — Phase 2 harness layout
- `test/load/pressure/README.md` — Phase 3 lane layout
- `docs/POST_HARDENING_FOLLOWUPS.md` — Phase 6 input (P2 coverage gap)
- `docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` — origin of the binding A-F adversarial scenario set

PRs cited:
- Phase 0 scaffolding: #428
- Phase 1 vendor corpora (17): #429 (aloha), #430 (oracle_simphony), #431 (sevenrooms), #432 (square), #433 (libro), #434 (tock), #435 (opentable), #436 (revel), #437 (quickbooks_time), #438 (seven_shifts), #439 (adp), #440 (humanity), #441 (lightspeed_lsk), #442 (agendrix), #443 (clover), #444 (push_operations), #445 (toast)
- Phase 2 pipeline harnesses: #446 (sink), #447 (mobile-sync), #448 (adapter), #449 (spine)
- Phase 3 load harnesses: #450 (backfill), #451 (oauth-refresh), #452 (webhook flood)
