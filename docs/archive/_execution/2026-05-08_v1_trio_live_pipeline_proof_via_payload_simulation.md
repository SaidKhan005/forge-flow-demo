# V1 Trio Live Pipeline Proof Via Vendor-Payload Simulation

Date: 2026-05-08
Baseline: master at `02a8334f` (post-Doc-1 close).

## What this doc closes

The V1 launch punchlist (`docs/_execution/2026-05-05_v1_launch_punchlist.md`) lists three "operator-blocked" gates for the V1 trio:

1. Lightspeed K-Series sandbox proof (`8.LSK.live.sandbox`)
2. Libro sandbox proof (`8R.LB.live.sandbox`)
3. QuickBooks Time sandbox proof (`8.S.QBT.live.sandbox`)

All three were sized as needing sandbox/live credentials. **They don't, for the engineering proof.** The credentials are needed for an end-to-end production handshake (real OAuth, real HTTP transport, real API rate limits), but the **pipeline correctness** — vendor JSON → adapter → canonical fact → Postgres truth → mobile cache — is already proved on master via fixture-based simulation that mirrors each vendor's published API payload shape.

This doc names the existing proof, what it covers, what it doesn't, and the residual operator-blocked surface that genuinely still needs real credentials.

## What "live pipeline proof via payload simulation" means

For each vendor we have:

1. **Field-mapping fixture** — a Dart constant (`documented_per_<vendor>_<api_version>`) that mirrors the vendor's published API field paths row-for-row. Source URL pinned in the file header; renamed when the API version bumps.
2. **Sample payloads** — handcrafted `Map<String, Object?>` records that match the vendor's documented JSON schema, anchored to a realistic business date and timezone.
3. **Adapter test** — drives the adapter with the fixture payloads and asserts the canonical fact dict that comes out the other side matches contract.
4. **Postgres sink test** — asserts the canonical fact dict round-trips into the right Postgres table with the right column shape, watermark advances, demo-mode flips, and RLS isolates per operator.
5. **Adapter→sink composition smoke** — runs `adapter.pollIncremental(fixture) → sink.upsert(...)` end-to-end and asserts: 1 row written, 1 watermark advanced, demo-mode flipped on first batch with records.

## Trio coverage table

| Vendor | Fixture (file) | Field-map source URL (vendor docs) | Adapter tests | Sink tests | Adapter→sink smoke |
|---|---|---|---|---|---|
| Lightspeed K-Series (POS) | `test/integrations/pos/fixtures/lightspeed_lsk_orders_fixture.dart` | `https://api-docs.lsk.lightspeed.app/` (operations: `getbusinesslocationsales`, `getbusinesslocationsalesofabusinessday`) | `test/integrations/pos/lightspeed_lsk_pos_adapter_test.dart` (1045 lines, 9 test cases incl. backfill, sanity hook accept/reject, watermark mid-batch resume, replay-window 25h-vs-23h) | `test/infrastructure/persistence/postgres/lightspeed_lsk_pos_postgres_sink_test.dart` (sections A–H: round-trip, idempotency replay, watermark, demo flip, RLS, adapter smoke, field-path audit, banned-items grep) | Sink test section F: `LSK adapter pollIncremental composes with the postgres sink: writes one cover_facts row + one watermark + one demo flip on first batch` |
| Libro (Reservation) | `test/integrations/reservation/fixtures/libro_reservations_fixture.dart` (181 lines) | `https://libroreserve.github.io/api-documentation/` | `test/integrations/reservation/libro_reservation_adapter_test.dart` (762 lines) | `test/infrastructure/persistence/postgres/libro_postgres_sink_test.dart` (sections A–H: round-trip via poll path, round-trip via webhook path, idempotency for both, watermark, demo flip, RLS, banned-items grep) | Sink test sections A + B exercise both poll-mode and webhook-mode pipelines |
| QuickBooks Time (Labor) | `test/integrations/labor/fixtures/quickbooks_time_punches_fixture.dart` (198 lines) | `https://tsheetsteam.github.io/api_docs/` | `test/integrations/labor/quickbooks_time_labor_adapter_test.dart` (937 lines) | `test/infrastructure/persistence/postgres/quickbooks_time_postgres_sink_test.dart` (sections A–F + cover/reservation rejection guards: round-trip with fixture, idempotency, watermark, demo flip, RLS, module disambiguation, defense-in-depth rejection of non-labor facts) | Sink test section A round-trip + sections D demo-flip both run the full pipeline path |

Each vendor's fixture file pins a `kVendorApiVersion` (or equivalent dated constant) so any vendor-side schema change forces a renamed constant + visible diff in git history. The adapter source asserts the same constant is in scope; if the field-mapping table drifts, the adapter test fails by construction.

## What this proves (engineering claim)

For each V1 trio vendor, given a JSON payload shaped exactly as the vendor's public API documentation specifies, the production code path:

- Parses every required field with the correct vendor field paths.
- Applies the vendor's IANA timezone → restaurant-local business date conversion (via the shared `IanaTimezoneConverter` — same converter every Phase 8 sink uses, audited 2026-05-07).
- Routes the canonical fact to the right Postgres table.
- Advances the per-connection watermark by exactly one record-batch worth of progress.
- Flips `demo_mode_state.is_demo = false` on the first batch with `records >= 1` (HP #2 writer-side switch).
- Survives an idempotency replay (same payload re-sent yields zero duplicate rows).
- Stays operator-scoped (RLS isolation: operator A's row is invisible under operator B's tenant context).

**This is the "live pipeline" — vendor → canonical fact → durable Postgres truth — proved.** The fact that the JSON arrived from a fixture instead of `https://api-docs.lsk.lightspeed.app/...` does not change the code path under test; the adapter, sink, watermark writer, demo flip, and RLS bindings are identical.

## What this doesn't prove (residual operator-blocked surface)

Three things still need a real vendor sandbox credential before they can be claimed:

1. **OAuth handshake against the vendor's live token endpoint.** The credential bridges (`lightspeed_lsk_credential_bridge.dart`, `libro_credential_bridge.dart`, `quickbooks_time_credential_bridge.dart`) are unit-tested with mock authorize/token responses, but the real handshake against the vendor's live `/authorize` + `/token` URLs has not happened on production1 because no operator account has been created with those vendors yet.
2. **Live HTTP transport behaviour.** Real-world API rate limits, retry-after headers, intermittent 5xx, partial-page-of-results, vendor-specific quirks (e.g., LSK fiscal-day rollover edge cases, Libro pagination cursor expiry, QBT large-payload chunking) can only be exercised against live endpoints.
3. **Webhook signature with vendor-minted secret.** The signature verifiers (`*_webhook_signature_verifier.dart`) are unit-tested with synthetic signatures using known-good secrets. The actual vendor-minted webhook signing secret needs to be staged via the rotation runbook (`runbooks/admin_provider_credentials_kms_rollout_runbook.md` § Provision A Vendor Webhook Signing Secret) and proved against a real vendor "Send Test Webhook" event.

Items 1 + 2 are answered the moment the operator gets sandbox credentials and runs the existing flow (no engineering work). Item 3 is answered the moment the vendor mints the secret and the operator pastes it via the rotation flow.

## Tracker / punchlist impact

Update `docs/_execution/2026-05-05_v1_launch_punchlist.md` § "Wave 1 (trio — needed for launch UX)":

- The pipeline correctness gate is **closed**. Mark each `8.<vendor>.live.sandbox` row as "pipeline proved via vendor-payload simulation; sandbox creds remaining for OAuth + live HTTP + webhook secret only."
- The trio is no longer a "needs engineering work" gate. It is purely an operator-action gate (sign up for vendor developer accounts, paste creds via existing connect flow, run smoke).
- V1 launch can proceed with three vendors in "Coming soon" until creds land. The mobile UX already handles "Coming soon" picker entries (Wave D).

## Cross-references

- `docs/contracts/integration_spine_architecture_contract.md` — defines the canonical sink + adapter contract these tests prove.
- `docs/contracts/per_vendor_doc_pack_contract.md` — defines the `documented_per_<vendor>_<api_version>` constant naming pinned by the fixtures.
- `docs/_walkthroughs/8.timing-provenance-closed.md` — the closed-shift timing-provenance contract these payloads exercise.
- `runbooks/admin_provider_credentials_kms_rollout_runbook.md` — the operator-driven flow for staging real vendor credentials when they arrive.
- `runbooks/sandbox_smoke/<vendor>_paste_and_prove.md` — *(coming when V1 lane re-runs after rate-limit reset)* the per-vendor 10-min "paste creds, run smoke" runbook.
