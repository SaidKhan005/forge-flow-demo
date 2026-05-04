# 2026-05-04 Vendor API Access And Mobile E2E Gap

Status: Active reference
Last updated: 2026-05-04
Canonical contracts:

- `PROJECT_TRACKER.md`
- `docs/contracts/vendor_adapter_slice_contract.md`
- `docs/contracts/per_vendor_doc_pack_contract.md`
- `docs/contracts/metric_card_honesty_contract.md`
- `docs/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md`

This note preserves the deep vendor API access check, the local
payment-orchestrator Oracle evidence, and the remaining product proof gap after
the documented Wave B vendor adapter work.

## Executive Summary

If the documented Wave B phases are completed exactly as planned, the vendor
API information gap is mostly covered. The per-vendor doc pack contract already
requires endpoints, auth, webhooks or polling, field mapping, ignored fields,
raw payload handling, and live verification checklists.

The bigger gap is product proof:

Vendor payload -> adapter -> canonical operational facts -> benchmark/baseline
inputs -> TargetCycle and DemandForecastContext -> SchedulePlan ->
WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn.

Wave B fixture adapters prove the left side of that chain. They do not, by
themselves, prove every mobile/business workflow reacts correctly after the
facts arrive.

Recommended closeout gate:

- Add `8.integration-mobile-proof` or `8.mobile-e2e`.
- Run it immediately after the 20 Wave B lanes and adapter registry merge.
- Treat it as a Wave B closeout gate before Phase 8 / 8R / 8.S engineering is
  accepted.
- Do not wait for live vendor credentials. Use realistic contract fixtures
  through the real adapters and real mobile/business read paths.

## Oracle Simphony Correction

Oracle MICROS Simphony should not be treated as "undocumented." Oracle has
official Simphony Transaction Services Gen2 documentation, including
Organizations, Configuration, Checks, Employees, and Notifications APIs:

- Oracle STS Gen2 overview:
  `https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/index.html`
- Oracle STS Gen2 REST endpoints:
  `https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/rest-endpoints.html`

Local GitHub evidence strengthens this further. The private
`SaidKhan005/payment-orchestrator` repo was cloned read-only to:

- `C:\Git Local Repos\payment-orchestrator`

Relevant evidence files:

- `backend/src/auth/sts-auth.js`
- `backend/src/simphony/tender-operations.js`
- `backend/tests/list-checks.cjs`
- `backend/tests/analyze-check.js`
- `backend/tests/test-real-check.js`
- `backend/tests/test-idempotency-real.js`
- `CHANGELOG.md`

What this proves:

- OIDC PKCE token flow against Oracle STS Gen2 was implemented.
- `/organizations` was called to discover organization context.
- `/checks?includeClosed=true&sinceTime=...` was called with Simphony
  organization, location, and revenue center headers.
- `/checks/{checkRef}` was used for check detail and tender inspection.
- `/checks/{checkRef}/round` was used for tender posting.
- The code references check header facts that matter to Forge & Flow, including
  check references, status, guest count, open time, totals, tenders, and
  revenue-center context.
- The payment orchestrator includes real-check and idempotency test harnesses.

What this does not yet prove for Forge & Flow:

- The Forge & Flow Oracle adapter itself writes canonical POS facts.
- Closed sales, covers, checks, voids/refunds/comps, business date,
  modified-since cursor behavior, timezone normalization, and 60-day backfill
  all pass the vendor adapter contract.
- Mobile screens and planning/learning logic react correctly to Oracle facts.

Lifecycle implication:

- Keep Oracle `documented` until a Forge & Flow `8.OR.live.sandbox` or
  `8.OR.live.production` slice proves the adapter inside the F&F framework.
- Cite payment-orchestrator as prior operator-proven STS access evidence in the
  Oracle doc pack.

Security note:

- The local `C:\Git Local Repos\simphony-middleware-test` folder contains
  plaintext Oracle-style credential material. Do not copy those values into
  docs or prompts. If any values are still live, rotate them before continuing
  with broader testing.

## Vendor API Access Matrix

This matrix is about "Can Wave B build documented/fixture adapters from
available API information?" It is not a live credential guarantee.

### POS

Lightspeed K-Series:

- Status: Integratable from public docs.
- Source: `https://api-docs.lsk.lightspeed.app/`
- Evidence: public REST docs include Financial, FinancialV2, open check, check
  detail, sales, staff shifts, and webhooks.
- Wave B risk: business-day/covers semantics and sandbox parity still need live
  verification.

Square:

- Status: Integratable from public docs.
- Source: `https://developer.squareup.com/reference/square/orders-api`
- Evidence: Orders API can search/retrieve orders and returns sales, returns,
  itemization, customer references, and related payments.
- Wave B risk: restaurant covers are not a first-class universal field; covers
  may require fallback or Square-for-Restaurants-specific conventions.

Toast:

- Status: Integratable from official docs, with partner/access constraints.
- Source: `https://doc.toasttab.com/doc/devguide/portalOrdersApiOverview.html`
- Evidence: Orders API docs expose order/check structures and fulfillment
  behavior.
- Wave B risk: partner scopes, restaurant group/location structure, and guest
  count availability require sandbox/prod verification.

Clover:

- Status: Integratable from public docs.
- Sources:
  - `https://docs.clover.com/dev/docs/making-rest-api-calls`
  - `https://docs.clover.com/dev/docs/webhooks`
- Evidence: REST API supports merchant orders/payments with OAuth; sandbox and
  production base URLs are documented; webhooks include order events.
- Wave B risk: covers/guest-count fallback and app-permission setup.

Revel:

- Status: Integratable from public/partner docs.
- Sources:
  - `https://developer.revelsystems.com/revelsystems/docs/api-platform-authentication`
  - `https://developer.revelsystems.com/revelsystems/docs/webhooks`
  - `https://developer.revelsystems.com/revelsystems/docs/frequently-asked-questions`
- Evidence: API platform auth, about 140 public endpoints, order/payment/order
  history resources, filters, and `order.finalized` webhook.
- Wave B risk: partner setup and exact wide-order field behavior.

NCR Aloha / NCR Voyix:

- Status: Integratable only if partner/API access is granted.
- Sources:
  - `https://www.docs.ncr.com/`
  - `https://developer.ncrvoyix.com/portals/dev-portal/api-explorer`
- Evidence: NCR product docs and developer/API Explorer path exist; restaurant
  product docs include Aloha POS, Aloha Cloud, Data Sharing, and related
  restaurant modules.
- Wave B risk: exact Aloha data-sharing/order endpoints are the most
  access-gated POS source in this set.

Oracle MICROS Simphony:

- Status: Integratable from official STS Gen2 docs plus local prior proof;
  production provisioning remains Oracle-controlled.
- Sources:
  - Oracle STS Gen2 overview and REST endpoints above.
  - Local `payment-orchestrator` evidence above.
- Evidence: Organizations, Configuration, Checks, Employees, and Notifications
  APIs exist; local code has used checks and round/tender paths.
- Wave B risk: treat payment-orchestrator as evidence, not acceptance. F&F still
  needs its own adapter, doc pack, fixture tests, and live slice.

### Reservations

Libro:

- Status: Integratable from public GitHub docs.
- Source: `https://github.com/libroreserve/api-documentation`
- Evidence: OAuth 2.0, booking list/get endpoints, booking status/timestamps,
  party size, restaurant relationship, and webhook HMAC signature docs are
  public.
- Wave B risk: F&F's 24-hour test tolerance is broader than Libro's recommended
  5-minute webhook signature tolerance; document the test-only deviation.

OpenTable:

- Status: Integratable through OpenTable API partner access/sandbox.
- Sources:
  - `https://www.opentable.com/restaurant-solutions/api-partners/`
  - `https://www.opentable.com/restaurant-solutions/api-partners/faqs/`
- Evidence: official page describes Sync, Booking, and CRM APIs, a sandbox, REST
  APIs, JSON responses, and docs portal.
- Wave B risk: access approval and restaurant/account-management path.

SevenRooms:

- Status: Integratable through SevenRooms API/integration access.
- Source: `https://sevenrooms.com/platform/integrations-apis/`
- Evidence: official platform page describes a flexible API, booking/channel
  management, CRM, reservation/waitlist availability, and POS integrations.
- Wave B risk: exact endpoint docs and credentials are account/partner gated.

Tock:

- Status: Integratable, but API key/webhook setup is account-owner gated.
- Sources:
  - `https://api.exploretock.com/docs/latest/reservation.html`
  - `https://tock.zendesk.com/hc/en-us/articles/25447494175508-API-FAQ`
- Evidence: public reservation data model includes reservation id, service date,
  party size, party state, sequence id, timestamps, payment/refund fields, and
  table/seating data; FAQ describes exports, APIs, webhooks, and API-key
  request path.
- Wave B risk: export cadence vs real-time webhook path and key request process.

### Scheduling / Labor

QuickBooks Time:

- Status: Integratable from public API reference.
- Source: `https://tsheetsteam.github.io/api_docs/`
- Evidence: public reference includes users, jobcodes, timesheets, schedule
  events, reports, custom fields, and supplemental data.
- Wave B risk: polling-only cadence, approval semantics, and QuickBooks product
  naming drift.

7shifts:

- Status: Integratable from public developer docs.
- Source: `https://developers.7shifts.com/reference/gettimepunches`
- Evidence: time punches endpoint supports company/location/department/role/user
  filters, approved state, `modified_since`, business-date filters, cursor
  pagination, OAuth2/Bearer auth.
- Wave B risk: plan/API access and webhook availability.

ADP Workforce Now / Workforce Management:

- Status: Integratable through ADP API Central / Marketplace access.
- Source:
  `https://apps.adp.com/en-US/apps/410612/ADP%C2%AE%20API%20Central%20for%20ADP%20Workforce%20Now%C2%AE/features`
- Evidence: API Central advertises timecards, work schedules, time-off, common
  API use cases, credentials, certificates, and OAuth/OpenID security.
- Wave B risk: module disambiguation is mandatory. ADP Workforce Now, Workforce
  Management, Time & Attendance, and scheduling scopes are not interchangeable.

Humanity / TCP:

- Status: Integratable from public Humanity docs.
- Sources:
  - `https://platform.humanity.com/v1.0/reference/scheduleshifts`
  - `https://platform.humanity.com/`
- Evidence: schedule shifts endpoint returns shifts; public hub exposes shift,
  timeclock, and schedule report surfaces.
- Wave B risk: legacy v1 vs newer v2 API choice and auth behavior.

Agendrix:

- Status: Likely integratable, with API-management sign-in and partnership path.
- Source: `https://developers.agendrix.com/en`
- Evidence: official developer portal advertises documentation, API Management,
  OAuth access generation, and partnership contact.
- Wave B risk: exact shifts/time-punch endpoint details need portal/API
  management access during the slice.

Push Operations:

- Status: Integratable for approved partners.
- Source: `https://developers.pushoperations.com/`
- Evidence: public Postman-backed docs include Clocks, Company, Departments,
  Employees, Labour, Sales, Schedules, Payroll, Revenue Centers, and Job
  Postings. Clocks/schedules/labour endpoints are directly relevant.
- Wave B risk: bearer-token issuance is partner-approved; verify date range,
  pagination, and approval fields live.

## Recommended Mobile E2E Closeout Gate

Add this as a post-Wave-B gate, not a random later follow-up.

Working name:

- `8.integration-mobile-proof`
- Alternative: `8.mobile-e2e`

Prerequisites:

- `8.0.lifecycle`
- 17 vendor adapter prompts
- `11W.7`
- `11W.8`
- adapter registry merge

No live accounts are required for this gate. It should use realistic contract
fixtures derived from vendor docs and run them through the real adapters,
canonical repositories, app read models, and mobile/business logic.

Acceptance proof:

1. POS fixture backfill writes closed sales, covers/checks, PPA inputs, and
   source provenance into canonical facts.
2. Labor fixture backfill writes hours, wage/rate facts where available,
   approval state, roles/job codes, breaks, and employee source ids.
3. Reservation fixture backfill writes in-the-books demand, party size,
   reservation state, booking timestamps, and source provenance.
4. Shift dashboard reads those canonical facts without phantom zeros.
5. 60-day backfill updates benchmark/baseline inputs.
6. TargetCycle and DemandForecastContext react to the new facts.
7. SchedulePlan uses live demand/labor context where available and honest
   fallback where not available.
8. Variance metric provenance is wired; missing live facts show fallback or
   unavailable, not fake zero.
9. History and Learn only consume closed, trustworthy facts.
10. Mobile refresh/invalidation fires after vendor sync.
11. Offline/local cache receives the canonical facts cleanly.
12. Demo mode flips correctly after first successful backfill per category.

This separates two truths:

- Wave B fixture proof: if the vendor returns the documented shape, Forge & Flow
  turns it into product behavior.
- `8.live` proof: the real vendor account actually behaves like the docs and
  fixtures claimed.

## Two-Prompt Handoff After Wave B

Use two prompts after the 20 Wave B lanes complete.

Prompt 1: `8.integration-mobile-proof`

- Purpose: fixture/mobile E2E proof.
- Runs before live vendor accounts are required.
- Audits the 20 adapter outputs, registry merge state, doc packs, and tests.
- Forms or hardens realistic contract fixtures for one complete trio first:
  POS + reservation + labor/scheduling.
- Runs those fixtures through the real adapters, canonical facts, app read
  models, and mobile/business logic.
- Blocks Phase 8 / 8R / 8.S product-complete acceptance until evidence proves
  the app spine.

Prompt 2: `8.live.connected-device-smoke`

- Purpose: live proof after full setup.
- Runs only when the connected device/emulator, app flavor/environment,
  approved secret path, vendor-location mapping, and at least one live-ready
  POS + reservation + labor/scheduling trio are available.
- Proves connect -> test connection -> bounded backfill -> poll/resume ->
  canonical facts -> mobile UI on the connected device.
- Starts with the smallest complete trio; do not attempt all 17 vendors in one
  prompt.
- Does not post payments, tenders, orders, shifts, or reservations unless the
  operator explicitly approves the mutation.

## Current Verdict

The vendor API calls and field requirements are mostly discoverable or already
planned in the doc-pack contract. Oracle is stronger than the previous thread
assumed because the payment-orchestrator repo provides local, concrete Simphony
STS evidence.

The remaining risk is not "we do not know what vendors return." The remaining
risk is "we have not yet proven every mobile/business surface reacts correctly
after those vendor facts land."
