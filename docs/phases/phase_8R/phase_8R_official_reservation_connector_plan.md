# Phase 8R — Official Reservation Connectors

Updated: 2026-05-03
Status: Planned (opens after Phase 8 `8.0` framework)
Owner: Reservation connector lane

> **Scope rewrite (2026-05-03):** This phase was previously scoped to a single reservation vendor (OpenTable preferred). Scope is now four INTEGRATE reservation vendors per `docs/phases/phase_8/vendor_master_list.md`. The Resy market gap is documented explicitly.

## Goal

Replace the app-side reservation demo/cache path with **four direct live reservation adapters** for the INTEGRATE vendors: Libro, OpenTable, SevenRooms, Tock. Each writes into the same canonical reservation fact tables (`reservation_book_snapshots`, party-level cache), exposes the same "In the Books" aggregate signal on Shift, and shares the same admin-console UX as Phase 8 / 8.S.

Per HP #1, transport-only. No app logic changes. Adapters write existing repository/read-model seam.

## Scope

Phase 8R owns:

- Four concrete reservation adapters: **Libro, OpenTable, SevenRooms, Tock**.
- Vendor-specific DTO mapping into canonical reservation events / parties / status transitions.
- Status vocabulary normalization (vendor enums → app `ReservationStatus`).
- Reservation status transition timestamp ingestion.
- Polling-driven sync and webhook-driven sync per vendor capability.
- Webhook signature verification per vendor (HMAC-SHA256 for Libro; vendor-specific schemes for others).
- Documented Resy fallback path: operators on Resy use demo-mode or operator-supplied CSV ingestion. F&F has no live reservation data for these locations.

Phase 8R does **not** own:

- POS or scheduling transport (Phases 8 / 8.S).
- The shared adapter framework — `ReservationAdapter` interface, IANA timezone converter, `vendor_credentials` schema, admin-console scaffolding (Phase 8 `8.0`).
- The "Vendor connections" admin surface (Phase 8 `8.0`).
- Auth-aware guest/VIP detail surfaces (Phase 9 + later Barrio work).
- Cross-device shared state (Phase 10a).
- Labor math or benchmark logic.

## Runtime Contract

```text
official reservation APIs (Libro / OpenTable / SevenRooms / Tock)
-> per-vendor adapter DTOs
-> canonical reservation parties / events / status transitions
-> reservation_book_snapshots + party-level cache
-> ShiftDashboardReadModel
-> COVERS card / future reservation-aware surfaces

raw vendor DTO -> stored as JSONB alongside canonical fact (escape hatch)
```

Forge & Flow stays aggregate-first — `In the Books` style aggregate counts on Shift. Party-level / VIP / detail surfaces wait for later auth-aware Barrio work.

## Frontend Exposure

The "Vendor connections" admin-console surface is built once in Phase 8 `8.0` and shared across POS / Reservations / Scheduling. Phase 8R adds **one card per vendor** to the Reservations section. Spec: `docs/phases/phase_8/vendor_connections_admin_surface.md`.

Operator-facing UX is **only**:
- The COVERS card on Shift continues rendering aggregate counts; gains a freshness indicator pulled from connector status.
- The demo-mode banner (kept per HP #2 — `kDemoMode` and "no INTEGRATE reservation vendor connected" both render the banner).

There is no operator-app Settings page for reservation integrations. Configuration lives in the admin console under each location.

## The Resy Gap (binding)

**Resy is CANNOT INTEGRATE.** No public developer portal exists. ~15% of NA target operators use Resy for reservations.

Operators on Resy must use one of:

1. **Demo-mode reservation data** — `kDemoMode = true` on the reservation channel only; POS and Scheduling can still be live.
2. **Manual CSV upload** — out-of-band reservation data ingested via the operator's manual export from Resy. Not a launch-priority surface; deferred to a post-launch lane (`8R.csv` placeholder if demand emerges).

Sales conversations with Resy-using operators must surface this gap explicitly before contracting. The vendor master list has a Resy-specific Notes row.

## Slices

Slices are sequenced reference-first per `docs/phases/phase_8/vendor_master_list.md`. Partnership applications kick off at the start of Wave 1 (Phase 8 `8.0`).

### `8R.LB` — Libro adapter (Wave 1, **Reservations reference adapter**)

- Public OAuth 2.0 docs at `libroreserve.github.io/api-documentation/`.
- Auth: OAuth (auth code + client credentials), bearer tokens with refresh.
- Webhooks: HMAC-SHA256 signed payloads.
- Status timestamps: per-status transition timestamps (`created-at`, `arrived-at`, `confirmed-at`, `seated-at`, `completed-at`, `canceled-at`) — richest of the 4 vendors.
- Reference adapter: cleanest API + lowest engineering risk. Proves the reservation half of the framework.
- Field mapping: `size` → canonical `party_size`; `status` → app `ReservationStatus` enum; per-status timestamps → status-transition rows.

### `8R.OT` — OpenTable adapter (Wave 3, partnership-gated)

- Partnership-only API access; application kicked off at start of Wave 1.
- ~6-12 week partnership review timeline.
- Industry default — 55% market share in target market.
- API docs disclosed only after partnership approval; vendor capability profile filled in per `7.55j.3` template at engineering start.
- Status vocabulary normalization to app `ReservationStatus`.

### `8R.SR` — SevenRooms adapter (Wave 4, account-rep onboarding)

- Partner API at `api.sevenrooms.com/2_2/auth`; partner credentials issued by SevenRooms account rep.
- Webhooks documented for reservation + client + cancellation events.
- Onboarding via account-rep — kicks off in parallel with engineering.
- Status timestamps unclear in public docs; verify at engineering time.

### `8R.TC` — Tock adapter (Wave 5, plan-gated)

- API + webhooks gated to Premium / Premium Unlimited tier.
- API key issued via `integrate@tockhq.com`.
- Status enum: `EXPECTED`, `ARRIVED`, `SEATED`, `LEFT`, `NO_SHOW`, `CANCELLED`.
- `createdTimestamp`, `lastUpdatedTimestamp`, `serviceDateTimestamp` on reservation; per-transition timestamps unclear.
- Operator must hold Premium tier — this is a commercial decision on operator's side, not an F&F engineering blocker.

## Acceptance Criteria (per vendor slice)

Per `docs/contracts/slice_runtime_acceptance_contract.md`:

- Adapter passes contract tests against vendor sandbox (or production with throttled volumes).
- OAuth (or key-issued partner credentials) round-trip works through admin-console connect flow.
- Heavy test-connection returns within 5s with a real sample reservation showing party size + status + business date.
- Webhook signature verification correctly rejects invalid signatures.
- Sync watermark + 60-day backfill complete on first connect for at least one test (operator, location).
- Disconnect preserves historical facts; reconnect resumes from preserved watermark.
- IANA Scenarios A-F re-verified with vendor-specific timestamp shapes.
- Raw-payload retention populated.
- COVERS card renders aggregate count + freshness indicator; demo-mode banner renders correctly when no reservation vendor connected.
- Demo-mode walkthrough green per `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Capability Questions

Filled in per vendor at engineering start using the `7.55j.3` checklist template:

- Reservation list endpoint with stable reservation ID + business-date timestamp.
- Status vocabulary and exact meaning of unseated vs seated.
- Webhook retry, replay, ordering, and signature-verification behavior.
- Updated-since / cursor model.
- Historical backfill window.
- VIP / area / table metadata exposure (optional for launch).

## Non-Negotiables

- Official integrations only.
- No scraping.
- No vendor credentials in Flutter.
- No mutation of covers/forecast math from widget code.
- No guest-detail overreach in Forge & Flow at launch — aggregate-first.

## Dependencies

- **Phase 8 `8.0`** ships first. `ReservationAdapter` interface, `vendor_credentials` schema, IANA timezone converter, admin surface scaffolding all live there.
- **OpenTable partnership application** kicks off at start of Wave 1. Multi-week review.
- **SevenRooms account-rep onboarding** kicks off at start of Wave 1.
- **Tock Premium tier** is the operator's commercial decision; not an F&F engineering blocker.
- **Phase 9 RLS** active for per-operator credential isolation (already accepted).
- **Phase 9.8** T&Cs covering operator's authorization for F&F to access their reservation data.

## Source Material

- [phase_7_56_reservation_book_signal_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_56/phase_7_56_reservation_book_signal_plan.md) — current demo/local foundation.
- [phase_7_55j_integration_feature_endpoint_inventory.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md) — pre-Phase-8 reservation requirements.
- The `7.56` doc's "Future Phase 8R Scope" section is the direct precursor to this phase.

## Cross-references

- `docs/phases/phase_8/vendor_master_list.md` — full classification, operator-share estimates, Wave plan, partnership applications, source URLs.
- `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` — Phase 8 framework slice that 8R depends on.
- `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md` — scheduling sibling.
- `docs/phases/phase_8/vendor_connections_admin_surface.md` — admin-console UX spec.
- `docs/archive/phases/7_55j/phase_7_55j_3_vendor_endpoint_checklist_template.md` — per-vendor capability checklist; extend per `8R.*` slice.
