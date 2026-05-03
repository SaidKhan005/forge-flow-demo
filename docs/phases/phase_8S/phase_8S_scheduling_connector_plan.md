# Phase 8.S — Scheduling Connectors

Updated: 2026-05-03
Status: Planned (opens after Phase 8 `8.0` framework)
Owner: Scheduling connector lane

## Goal

Replace replay/demo transport for scheduling and timekeeping data with official live adapters for the six INTEGRATE scheduling vendors. Same canonical-fact-table boundary, same admin-console UX, same `IntegrationProvider`-style framework as Phase 8 / 8R.

## Scope

Phase 8.S owns:

- Six concrete scheduling adapters: **QuickBooks Time, 7shifts, Agendrix, Humanity (TCP), Push Operations, ADP Workforce Now/Manager**.
- Vendor-specific DTO mapping into canonical schedule + punch + role facts.
- Role-hierarchy ingestion plus FOH/BOH classification persistence.
- Polling-driven incremental sync (most scheduling vendors do not expose webhooks for schedule/punch changes).
- Module disambiguation for ADP (RUN excluded), QuickBooks (Time vs Accounting vs Payroll), and any future module-pivoted vendor.
- Wage-rate or labor-dollar ingestion where vendor exposes it; degrade to app-owned wage fallback otherwise per `LaborModel` contract.

Phase 8.S does **not** own:

- POS adapters (Phase 8) or reservation adapters (Phase 8R).
- The shared adapter framework — `LaborAdapter` interface, IANA timezone converter, `vendor_credentials` schema, admin-console scaffolding (Phase 8 `8.0`).
- The "Vendor connections" admin surface (Phase 8 `8.0`).
- Pure payroll processing (Phase 8.5 covers outbound finance to QuickBooks Online Accounting / Xero / Bill.com).
- Per-employee identity reconciliation **across vendors**. **Deferred — explicit non-goal at V1.** Each vendor's employee namespace is treated as distinct: Toast employee `1234` and 7shifts employee `5678` are NOT auto-mapped even if they're the same physical person. Cross-vendor employee mapping (manual UI or automated heuristic) is a future Phase 11W or Phase 12 concern when operators ask for it. Within a single scheduling vendor, employee identity is preserved via stable vendor employee IDs.

## Runtime Contract

```text
official scheduling APIs
-> adapter DTOs (per-vendor)
-> canonical schedule_shift / time_punch / role_assignment facts
-> repositories (operator-scoped, RLS-ready)
-> SQLite local cache + Postgres source-of-truth
-> read services / state holders / read models
-> UI (operator app reads facts; admin console reads sync status)
```

Per **HP #1**: transport-only. No `lib/services/` or `lib/domain/services/` business-logic changes. Adapters write existing canonical tables.

Per **HP #7**: vendor secrets server-side only, in `vendor_credentials` (encrypted via pgcrypto envelope or Cloud KMS). Flutter clients never see plaintext.

Per **HP #8**: `LaborAdapter` interface is general-purpose. Each concrete adapter is a self-contained module under `lib/integrations/labor/<vendor>_labor_adapter.dart`. Adding a future scheduling vendor = one new adapter file, no framework changes.

## Frontend Exposure

The "Vendor connections" admin-console surface is built once in Phase 8 `8.0` and shared across POS / Reservations / Scheduling. Phase 8.S adds **one card per vendor** to the Scheduling section of that surface — see `docs/phases/phase_8/vendor_connections_admin_surface.md` for the connect / test / disconnect / status flow.

Operator-facing UX is **only** the demo-mode banner (kept in operator app per HP #2 — `kDemoMode` and "no INTEGRATE vendor connected" both render the banner).

There is no operator-app Settings page for integrations. Configuration lives entirely in the admin console under each location.

## Slices

Slices are sequenced reference-first. See `docs/phases/phase_8/vendor_master_list.md` for full wave plan and operator-share rationale.

### `8.S.QBT` — QuickBooks Time (Reference adapter, Wave 1)

- Endpoints: `/schedule_events`, `/timesheets`, `/jobcodes`, `/users`.
- Auth: OAuth 2.0 (public, self-serve at Intuit Developer).
- Sync: `modified_since` polling (5-min default cadence).
- Module disambiguation: connect flow asks "Which QuickBooks product?" — Time → INTEGRATE; Accounting → redirect to Phase 8.5; Payroll → not supported.
- Fields: schedule shifts with role + start/end; punches with `clocked_in` / `clocked_out` / breaks; wages from `users.pay_rate`; finalization signal from `approved_to` flag.
- Walkthrough required at acceptance.

### `8.S.7S` — 7shifts (Wave 2)

- Endpoints: `/v2/company/{id}/shifts`, `/time_punches`, `/users`, `/roles`, `/departments`, `/wages`.
- Auth: OAuth 2.0 client credentials (partner-issued via `partnerships@7shifts.com`).
- Sync: cursor + `modified_since` polling; webhooks (`time_punch.created/edited/deleted`, `schedule.published`, `payroll_period.closed`) where Gourmet plan is enabled.
- Fields: published shifts; punches with `approved` boolean; per-employee wage rates; payroll-period finalization signal.
- Reference for finalization-aware logic that other adapters fall back to when their vendor has no equivalent signal.
- Walkthrough required at acceptance.

### `8.S.AG` — Agendrix (Wave 4)

- Public OAuth, self-serve dev portal with Playground.
- 75+ endpoints covering shifts, time-clock, positions, teams.
- Sync: polling-only (no webhooks documented).
- Wages: partial (per-position, not per-shift).
- Walkthrough required at acceptance.

### `8.S.HM` — Humanity (TCP) (Wave 4)

- Legacy v1 API at `platform.humanity.com/v1.0`.
- Auth: token via username/password (non-OAuth — flagged for the connect flow as legacy auth path).
- Modules: shifts, timeclocks, positions, locations.
- Sync: per-module modified-since polling.
- Wage data partial (position-level only).
- Walkthrough required at acceptance.

### `8.S.PU` — Push Operations (Wave 5)

- Bearer-token API at `developers.pushoperations.com`.
- Partner approval required.
- Sync: date-range polling (2-day window) — bridge worker batches.
- Walkthrough required at acceptance.

### `8.S.ADP` — ADP Workforce Now / Workforce Manager (Wave 3, partnership-gated)

- Endpoints: Time Work Schedules v1, Team Time Cards v2, Work Assignments.
- Auth: OAuth 2.0 client credentials + mutual TLS.
- Sandbox: ADP Marketplace partner sandbox (DPA required, multi-month lead time).
- Module disambiguation: connect flow asks "Which ADP product?" — Workforce Now → INTEGRATE; Workforce Manager → INTEGRATE; **RUN → not supported with friendly refusal** ("ADP RUN is payroll-only; please use a different scheduling vendor or upgrade to Workforce Now").
- Walkthrough required at acceptance.

## Module Disambiguation Pattern (binding)

Two scheduling vendors require pre-card module disambiguation in the Vendor connections admin surface:

| Vendor | Module dropdown options | Outcome |
|---|---|---|
| ADP | Workforce Now / Workforce Manager / RUN | RUN selection shows refusal; others proceed to OAuth |
| QuickBooks | Time / Accounting / Payroll | Time proceeds; Accounting redirects to Phase 8.5; Payroll shows "not supported" |

Module selection is recorded in `vendor_credentials.metadata.module` so subsequent reconnect flows know which module was originally chosen.

## Polling-First Sync Architecture

5 of 6 scheduling vendors do not expose webhooks for schedule/punch changes (only 7shifts on Gourmet plan does). The framework treats polling as a first-class path, not a fallback:

- **Watermark per (operator, location, vendor, resource)**. `last_synced_at` + `last_modified_seen` cursor stored per resource (shifts / punches / roles).
- **Sync cadence configurable per card** in the admin surface (default 5 min for live operator workdays, 1 hour off-hours).
- **Backfill window**: 60 days minimum at first connect, governed by `vendor_capability_profile`.
- **Rate-limit awareness**: each adapter declares its vendor's published rate caps; the bridge worker token-bucket-throttles per vendor.

## Role Hierarchy + FOH/BOH Classification

Vendor role hierarchies vary widely. The framework normalizes:

- **Vendor location** → app `location_id` (1:1 mapping in `connector_location_binding`).
- **Vendor department / team / group** → optional, surfaced in admin UI but not load-bearing.
- **Vendor role / job code / position** → app `role_assignment` row with `foh_boh_classification` (FOH / BOH / manager / excluded). Operator admin maps each vendor role to a classification once during onboarding (default heuristic by role-name match, override available).

Role mapping is stored per (operator, location, vendor) and replayed across all schedule/punch ingestion. Phase 7.55i's `daypart_evidence_visibility_policy` continues to honor this mapping.

## Wage Ingestion Policy

| Vendor | Wage exposure | App fallback |
|---|---|---|
| 7shifts | Per-employee `wage_cents` + per-shift `hourly_wage` | None needed |
| QuickBooks Time | `pay_rate` on user | None needed |
| ADP WFN/WFM | Pay rates on work-assignment | None needed |
| Push Operations | Wage on labour entries | None needed |
| Humanity | Position-level (partial) | App-owned wage generator covers gaps |
| Agendrix | Position-level (partial) | App-owned wage generator covers gaps |

The app-owned wage fallback (`lib/services/wage_authority_service.dart` and the q-lane refactor) stays in place. Adapters report `wage_source = vendor` when vendor data is reliable, `wage_source = app_fallback` when degrading.

## Acceptance Criteria (per vendor slice)

- Adapter passes contract tests against vendor sandbox (or production with throttled volumes if no sandbox exists).
- OAuth (or legacy auth) round-trip works end-to-end through the admin-console connect flow.
- Test-connection diagnostic returns within 5s and surfaces a real sample shift/punch/role row.
- Sync watermark + 60-day backfill complete on first connect for at least one test location.
- Role-mapping override flow works in admin UI; FOH/BOH classification persists.
- Wage-source classification correct (vendor-data when available, app-fallback when not).
- IANA timezone conversion (Phase 8 `8.0` framework) handles vendor timestamps correctly — Scenarios A-F bound at framework level, vendor-specific edge cases bound here.
- Demo-mode walkthrough green per `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Dependencies

- **Phase 8 `8.0`** ships first. `LaborAdapter` interface, `vendor_credentials` schema, IANA timezone converter, admin surface scaffolding all live there.
- **ADP Marketplace partnership application** kicks off at the start of Wave 1 (Phase 8 `8.0`). Multi-month lead time; lands as `8.S.ADP` is ready to start engineering.
- **Push Operations partner approval** kicks off at start of Wave 1.
- **7shifts Gourmet plan** is the operator's commercial decision; not a F&F engineering blocker.
- **Phase 9 RLS** active for per-operator credential isolation (already accepted on master).

## Adjacent Phases

- **Phase 8** — POS adapter family, framework, IANA timezone, raw-payload retention.
- **Phase 8R** — Reservation adapter family.
- **Phase 8.5** — Outbound finance (QBO Accounting / Xero / Bill.com / Plaid). Different direction (we write to operator's systems, not read from them). Cross-references QuickBooks module disambiguation.
- **Phase 9.8** — T&Cs covering operator's authorization for F&F to access scheduling data.

## Cross-references

- `docs/phases/phase_8/vendor_master_list.md` — operator-share table, wave plan, partnership applications, source URLs.
- `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` — Phase 8 plan; the `8.0` framework slice that Phase 8.S depends on.
- `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md` — reservation sibling phase.
- `docs/phases/phase_8/vendor_connections_admin_surface.md` — admin-console UX spec.
- `docs/archive/phases/phase_8_gate/source_ownership_matrix.md` — labor-system field ownership rules.
- `docs/archive/phases/7_55j/phase_7_55j_3_vendor_endpoint_checklist_template.md` — per-vendor capability checklist; extend for each `8.S.*` slice.
