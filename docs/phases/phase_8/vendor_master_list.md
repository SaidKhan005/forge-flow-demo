# Forge & Flow Vendor Master List

Updated: 2026-05-03
Status: Locked scope for Phase 8 / 8R / 8.S inbound integrations
Operator-supplied scope sheet: `docs/phases/phase_8/SOFTWARE SYSTEMS.xlsx` (classified 2026-05-03)

## Scope

This list covers **inbound** integrations only — POS, Reservations, and Scheduling.

Out of scope for this list:

- **Outbound finance integrations** (QuickBooks Online Accounting, Xero, Bill.com / MarginEdge, Plaid) — see `docs/phases/phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md`.
- **Third-party / online ordering** (DoorDash, Uber Eats, Skip the Dishes, Deliverect, Tacit, Onfleet, OLO, Urban Piper, Otter) — deferred until post-launch.

## Classification methodology

Each vendor is classified into one of three buckets based on official developer documentation as of 2026-05-03:

- **INTEGRATE** — Public or partner API exists with OAuth or API-key auth, sandbox/test environment available, webhooks or polling-based incremental sync supported, and the data fields F&F needs are documented.
- **DO NOT INTEGRATE** — API exists but the public API is the wrong shape for our use (e.g., payments-only, consumer-booking-only) or lacks key fields with no engineering-justifiable workaround.
- **CANNOT INTEGRATE** — No public developer portal exists, or partnership access is closed/dormant such that practical access is impossible.

Classifications are scope-locking decisions, not implementation order. Implementation order is described in the Wave Plan section.

## Architectural decision: direct integration only (locked 2026-05-03)

**Direct point-to-point adapters for all 17 INTEGRATE vendors. No middleware in the default path.**

Research conducted 2026-05-03 found:

- **Omnivore** (Olo's POS aggregator) covers only 2 of 7 POS targets (Aloha + Simphony) — not Toast / Square / Clover / Lightspeed / Revel.
- **No equivalent aggregator** exists for restaurant reservations (closest is Mozrest, which is inbound-booking middleware — wrong direction) or restaurant-vertical scheduling (closest is Merge.dev, which covers 2 of 6 in Beta and strips load-bearing fields like FOH/BOH role hierarchy and 7shifts' finalization signal).
- **Field-fidelity loss** through middleware breaks load-bearing math: Toast `numberOfGuests` (CPLH math), 7shifts `payroll_period.closed` (Primary Driver audit).
- **Toast and Lightspeed** explicitly steer partners to direct integration; middleware degrades sandbox/webhook richness.
- **Outage blast radius**: middleware = all POS vendors down at once on a middleware outage; direct = single-vendor blast radius.
- **Cost economics**: Omnivore at ~$35/loc/mo × 5,000 locations = ~$2.1M/year; engineering is amortized.

Omnivore stays as a **documented fallback option** for legacy on-prem POSes (Aloha-on-prem, Micros 3700, POSitouch, Squirrel) only if a specific operator demands one we haven't built directly. Same `PosAdapter` interface; no architectural carve-out.

Memory: `project_phase_8_architecture.md`.

## Operator-share estimates (best estimates, 2026-05-03)

Educated estimates based on publicly known market positioning, weighted slightly toward Canadian-North American mid-market ops (Forge & Flow's natural target). Not market-research-grade — defensible for Wave-plan prioritization only. Memory: `project_operator_share_assumptions.md`.

**POS** (sums to 100%):

| Vendor | Estimated share |
|---|---|
| Toast | 35% |
| Square | 20% |
| Lightspeed K-Series | 15% |
| Clover | 12% |
| Aloha (NCR Voyix) | 8% |
| Revel | 5% |
| Oracle MICROS Simphony | 5% |

**Reservations** (sums to 100%):

| Vendor | Estimated share |
|---|---|
| OpenTable | 55% |
| SevenRooms | 15% |
| **Resy (CANNOT INTEGRATE)** | **15%** — market-coverage gap |
| Tock | 10% |
| Libro | 5% |

**Scheduling** (sums to 100%):

| Vendor | Estimated share |
|---|---|
| 7shifts | 35% |
| QuickBooks Time | 25% |
| ADP Workforce Now/Manager | 15% |
| Humanity (TCP) | 10% |
| Push Operations | 8% |
| Agendrix | 7% |

## POS (12 vendors → 7 INTEGRATE, 1 DO NOT, 4 CANNOT)

| Vendor | Verdict | Why | Notes |
|---|---|---|---|
| Lightspeed Restaurant (K-Series) | INTEGRATE | Cleanest fit — first-class `covers` field, OAuth, sandbox, order/payment webhooks. | **Reference adapter** for POS family. |
| Toast | INTEGRATE | Already audited — OAuth, webhooks, `numberOfGuests` for covers. | Standard / Partner / Custom API tiers. |
| Square | INTEGRATE | Already audited — OAuth + webhooks; no covers, degrades to forecast fallback. | No partnership gating. |
| Clover | INTEGRATE | Already audited — webhooks + 90-day filter cap; no covers field exposed. | App-Market approval needed. |
| Revel | INTEGRATE | OAuth, QA sandbox, `order.finalized` webhook, `number_of_people` field. | Self-serve OAuth. |
| Aloha (NCR Voyix) | INTEGRATE | NCR Voyix dev portal with sandbox + OAuth; per-API access requests gate onboarding. | Partner-gated. |
| Oracle MICROS Simphony | INTEGRATE | Public OAuth + `getGuestChecks` with covers; partner activation gates onboarding. | Poll-only (no webhooks). |
| Shift4 / SkyTab | DO NOT INTEGRATE | Public API is payments + device-handoff only; no SkyTab POS sales-data endpoints. | Surprising — what looks like a POS dev portal is actually a payments API. |
| TouchBistro | CANNOT INTEGRATE | No public dev portal; CEO has confirmed intentional non-publication. | Email-only partnership inquiry. |
| Restaurant Manager (Action Systems / Duet POS) | CANNOT INTEGRATE | No developer portal located on official sites. | — |
| Silverware | CANNOT INTEGRATE | Tokens issued only by sales rep; no public API documentation. | $25/loc/mo gating, no self-serve. |
| Squirrel | CANNOT INTEGRATE | REST API exists but docs sit behind customer-portal login; no self-serve portal. | Partner-direct only. |

## Reservations (6 vendors → 4 INTEGRATE, 1 DO NOT, 1 CANNOT)

| Vendor | Verdict | Why | Notes |
|---|---|---|---|
| Libro | INTEGRATE | Cleanest fit — public OAuth, signed HMAC webhooks, per-status transition timestamps. | **Reference adapter** for Reservations family. |
| OpenTable | INTEGRATE | Industry default; partnership onboarding required. | 55% market share. Partner-gated. |
| SevenRooms | INTEGRATE | Partner API with reservation/client webhooks; account-rep onboarding. | Webhook events include reservations and cancellations. |
| Tock (Squarespace) | INTEGRATE | API + webhooks gated to Premium tier; complete status enum. | Plan-gated; per-transition timestamps unclear. |
| Yelp Reservations / Guest Manager | DO NOT INTEGRATE | API is consumer booking conduit only; no operator-side reservation list endpoint. | No merchant-feed API. |
| Resy (Amex) | CANNOT INTEGRATE | No public developer portal; partnership inquiry only. | **15% market gap** — operators on Resy use demo/CSV fallback. |

## Scheduling (6 vendors → 6 INTEGRATE)

| Vendor | Verdict | Why | Notes |
|---|---|---|---|
| QuickBooks Time (TSheets) | INTEGRATE | QBO Time public OAuth; cleanest self-serve scheduling vendor. | **Reference adapter** for Scheduling family. |
| Agendrix | INTEGRATE | Public OAuth, self-serve dev portal with Playground, 75+ endpoints. | Canadian SMB-friendly. |
| 7shifts | INTEGRATE | Already audited — best-in-class finalization signal (`approved` boolean + `payroll_period.closed` webhook). | Gourmet plan needed for webhooks. |
| Humanity (TCP) | INTEGRATE | Legacy v1 API with shifts/timeclocks/positions; non-OAuth username/password auth. | Auth model is dated but functional. |
| Push Operations | INTEGRATE | Bearer-token API exposing shifts/labour/positions; partner approval required. | Canadian SMB. |
| ADP (Workforce Now / Manager) | INTEGRATE | WFN/WFM modules only (RUN excluded — payroll-only); ADP Marketplace gated. | **Module disambiguation required** (see below). |

**Note: only 7shifts has true webhooks for schedule/punch changes** (on Gourmet plan). All other scheduling integrations rely on `modified_since` polling. The framework supports polling-driven sync as a first-class path.

## Module Disambiguation Flags

When the operator connects ADP, the connect flow MUST disambiguate the module:

- **ADP RUN** → Not supported. Connect flow shows a friendly refusal: "ADP RUN is a payroll-only product. Forge & Flow needs schedule and time-punch data. If you also use ADP Workforce Now or Workforce Manager, connect that instead. Otherwise, please use one of these supported scheduling vendors: [list]."
- **ADP Workforce Now** → INTEGRATE (Marketplace-gated).
- **ADP Workforce Manager** → INTEGRATE (Marketplace-gated).

When the operator connects QuickBooks, the connect flow MUST disambiguate:

- **QuickBooks Time** (formerly TSheets) → Scheduling integration. Lives in this list.
- **QuickBooks Online (Accounting)** → Outbound finance integration. Lives in `phase_8_5_external_integrations` — not on this list.
- **QuickBooks Payroll** → Not supported as a standalone connector.

## Out of Scope for This Phase Family

**DO NOT INTEGRATE** (we choose not to support):

- Shift4 / SkyTab — public API is payments + device-handoff only.
- Yelp Reservations — consumer booking flow only.

**CANNOT INTEGRATE** (no practical path):

- TouchBistro, Restaurant Manager, Silverware, Squirrel (POS).
- Resy (Reservations).

If a target operator runs **only** vendors from these two lists, they cannot be onboarded via the standard inbound integration framework. The product would need to fall back to operator-supplied CSV / fixture mode (existing demo-mode-style transport) — that decision is launch-strategy, not engineering, and should be raised explicitly with the operator before contracting.

## Wave Plan (Reference-First, share-weighted)

Wave 1 ships the framework + three "cleanest API" reference adapters that prove the architecture end-to-end. Wave 3's high-share partnership-gated vendors require partnership applications kicked off **at the start of Wave 1**, in parallel with engineering, so they land roughly when the framework is mature. **Wave 1 + 2 + 3 = MVP launch state.**

### Wave 1 — Framework + reference adapters (start now, ~6-10 weeks)

| Slice | Vendor / Scope | Why this wave |
|---|---|---|
| `8.0` | Adapter framework + admin surface | Blocks every adapter slice. Interfaces, IANA timezone (Scenarios A-F), `vendor_credentials`, `connector_*` schemas, raw-payload retention, admin-console "Vendor connections" surface, Cloud Run admin endpoints, webhook ingestion endpoints. |
| `8.LSK` | Lightspeed K-Series (POS) | Cleanest POS API + 15% share. Reference adapter that proves the framework. |
| `8R.LB` | Libro (Reservations) | Cleanest reservation API + Canadian-relevant. Reference adapter for reservations. |
| `8.S.QBT` | QuickBooks Time (Scheduling) | Cleanest scheduling API + 25% share. Reference adapter for scheduling. |

### Wave 2 — High-share, no partnership gate (~2-4 weeks after Wave 1)

| Slice | Vendor | Why this wave |
|---|---|---|
| `8.SQ` | Square (POS) | 20% share, self-serve OAuth, no gate. Covers degrades to forecast fallback. |
| `8.S.7S` | 7shifts (Scheduling) | 35% share, already audited, easy onboarding. |

### Wave 3 — Partnership-gated high-share (lands ~10-16 weeks from start; applications kicked off at Wave 1 start)

| Slice | Vendor | Lead time |
|---|---|---|
| `8.TS` | Toast (POS) | Partnership review + compliance/security/legal — ~6-12 weeks. **Highest POS share at 35%.** |
| `8R.OT` | OpenTable (Reservations) | Partnership review — ~6-12 weeks. **Highest reservation share at 55%.** |
| `8.S.ADP` | ADP Workforce Now/Manager (Scheduling) | ADP Marketplace DPA — ~12-24 weeks. 15% share. |

### Wave 4 — Mid-share self-serve / quick approval

| Slice | Vendor | Why this wave |
|---|---|---|
| `8.CL` | Clover (POS) | 12% share, App-Market approval (~1-3 weeks). |
| `8.RV` | Revel (POS) | 5% share, self-serve OAuth. |
| `8.S.AG` | Agendrix (Scheduling) | 7% share, self-serve OAuth. |
| `8.S.HM` | Humanity (Scheduling) | 10% share, legacy auth (quick once contract). |
| `8R.SR` | SevenRooms (Reservations) | 15% share, account-rep onboarding (~4-8 weeks). |

### Wave 5 — Long-lead partnerships and lower-priority

| Slice | Vendor | Why deferred |
|---|---|---|
| `8.AL` | Aloha (NCR Voyix) (POS) | 8% share, NCR Voyix partnership — multi-month. |
| `8.OR` | Oracle Simphony (POS) | 5% share, Oracle partnership — multi-month. Enterprise-only. |
| `8R.TC` | Tock (Reservations) | 10% share, Premium-tier negotiation. |
| `8.S.PU` | Push Operations (Scheduling) | 8% share, partner approval. |

## Coverage progression by wave

| End of wave | POS coverage | Reservation coverage | Scheduling coverage |
|---|---|---|---|
| Wave 1 | 15% (Lightspeed) | 5% (Libro) | 25% (QBT) |
| Wave 1+2 | 35% (+Square) | 5% | 60% (+7shifts) |
| Wave 1+2+3 (**MVP**) | **70% (+Toast)** | **60% (+OpenTable)** | **75% (+ADP)** |
| Wave 1-4 | 87% (+Clover, Revel) | 75% (+SevenRooms) | 92% (+Humanity, Agendrix) |
| Wave 1-5 | 100% | 85% (Resy permanently uncovered) | 100% |

## Partnership Applications (kick off at Wave 1 start)

These are parallel critical paths to engineering. Lead times measured in weeks-to-months. Start before adapter engineering begins so they land when needed.

| Vendor | Lane | Estimated lead time |
|---|---|---|
| Toast | Partner Program (compliance + security + legal review) | 6-12 weeks |
| Lightspeed Restaurant K-Series | Standard tier (self-serve) or Partner tier | 1-2 weeks self-serve; 4-8 weeks Partner |
| Oracle MICROS Simphony | Simphony Partner Integration Program | 8-16 weeks |
| NCR Voyix (Aloha) | NCR Voyix Developer Program | 8-16 weeks |
| ADP Workforce Now/Manager | ADP Marketplace Developer Participation Agreement | 12-24 weeks |
| OpenTable | Partner API application | 6-12 weeks |
| SevenRooms | Account-rep onboarding | 4-8 weeks |
| Tock | Premium-tier negotiation + API key request | 4-8 weeks |
| Push Operations | Partner approval | 4-6 weeks |
| Libro | Public OAuth — no partnership required | n/a |
| Square | Public OAuth — no partnership required | n/a |
| Revel | Public OAuth — no partnership required | n/a |
| Clover | App-Market approval | 1-3 weeks |
| 7shifts | Already onboarded; existing audit work | n/a |
| QuickBooks Time | Public OAuth — no partnership required | n/a |
| Agendrix | Public OAuth — no partnership required | n/a |
| Humanity | Legacy auth (username/password) — no formal partner program | n/a |

Operator (you) drives partnership applications. F&F engineering proceeds on Wave 1 in parallel; Wave 3 lands as approvals come back.

## Source Material

Research conducted 2026-05-03 by parallel agents against official vendor developer documentation. Primary doc URLs:

**POS:**

- Toast: https://doc.toasttab.com
- Square: https://developer.squareup.com/docs
- Clover: https://docs.clover.com
- Lightspeed Restaurant K-Series: https://api-docs.lsk.lightspeed.app/
- Revel: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Aloha (NCR Voyix): https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Oracle MICROS Simphony: https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/authenticate.html
- Shift4 / SkyTab: https://dev.shift4.com/docs/

**Reservations:**

- OpenTable: partnership-only, no public dev portal URL
- Libro: https://libroreserve.github.io/api-documentation/
- SevenRooms: https://sevenrooms.com/platform/integrations-apis/
- Tock: https://api.exploretock.com/docs/latest/reservation.html
- Yelp Reservations: https://docs.developer.yelp.com/reference/v3_reservations
- Resy: https://resy.com/join/integrations/ (no API spec)

**Scheduling:**

- 7shifts: https://developers.7shifts.com
- QuickBooks Time: https://tsheetsteam.github.io/api_docs/
- Agendrix: https://developers.agendrix.com/en/documentation
- Humanity: https://platform.humanity.com/v1.0
- Push Operations: https://developers.pushoperations.com/
- ADP Workforce Now: https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog

**Architecture decision sources:**

- Olo Omnivore: https://www.olo.com/omnivoreapi
- Reforming Retail Omnivore teardown: https://reformingretail.com/index.php/2019/12/12/part-1-omnivore-docs-show-compounded-integration-costs-by-strong-arm-pos-companies/
- Toast partner-direct guidance: https://doc.toasttab.com/doc/devguide/integrationDevProcess.html
- 7shifts hybrid posture (direct + Omnivore): https://kb.7shifts.com/hc/en-us/articles/4417514276115-POS-Integration-Partners

## Cross-References

- `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` — Phase 8 plan (POS adapters + framework).
- `docs/phases/phase_8/vendor_connections_admin_surface.md` — admin-console UX spec.
- `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md` — Phase 8R plan (reservation adapters).
- `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md` — Phase 8.S plan (scheduling adapters).
- `docs/phases/phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md` — sibling outbound-integrations lane.
- `docs/archive/phases/phase_8_gate/` — original Phase 8 readiness gate (Toast/Square/Clover/7shifts).
- `docs/archive/phases/7_55j/` — pre-Phase-8 integration audit and capability-checklist template.
- `docs/archive/phases/7_55n/phase_7_55n_12_vendor_live_data_capability_audit.md` — original live-data capability audit.
