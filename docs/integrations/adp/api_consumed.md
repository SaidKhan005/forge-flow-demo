# ADP Workforce Now / Workforce Manager — API Consumed

**Vendor ID** (matches `VendorCapabilityProfile.vendorId` and
`connector_connection.vendor_id`): `adp`
**Category**: `labor`
**Source documentation**: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
(public ADP developer-portal API catalog. The same portal hosts the
Workforce Manager (WFM) catalog. Endpoint shapes + sandbox + production
credentials are gated on the ADP Marketplace Developer Participation
Agreement — see `partnership_status.md`.)
**Retrieval date**: 2026-05-04
**API version pinned**: `v1-2026-05-04-assumed`

> **Partnership-only — full doc gated until ADP Marketplace DPA
> clears.** ADP publishes the API catalog (product list, scope
> overview) but the endpoint reference, sandbox, and production
> credentials are released only to vendors that complete the ADP
> Marketplace Developer Participation Agreement (~12-24 weeks; see
> `partnership_status.md`). This file captures every assumption F&F
> engineered against the published shapes (Time Work Schedules v1,
> Team Time Cards v2, Work Assignments). EVERY endpoint, field,
> header, and behavior listed below is flagged "verify in
> `8.S.ADP.live.sandbox`" — the field-mapping diff slice will
> confirm each assumption against an observed sandbox payload and
> cut a bounded fix where any of them differ.

---

## Auth method

`oauth` — assumption: `authorization_code` flow with rotating refresh
tokens (matches the ADP Marketplace partner sign-in surface). Live
production wires `oauth_2.0_client_credentials + mutual_tls` per the
phase plan note in
`docs/archive/phases/phase_8S/phase_8S_scheduling_connector_plan.md`; mutual
TLS lands at the `*.live.prod` slice when partner-issued certs
arrive. Cite vendor doc:
<https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>

See `oauth_shape.md` for flow detail. Every section there is also
flagged for live verification.

> Many endpoint shapes here are **assumptions to verify in
> `8.S.ADP.live.sandbox`**. The adapter binds to these shapes via the
> `documentedPerAdpV1FieldMapping` constant in
> `lib/integrations/labor/adp_labor_adapter.dart`; the
> `*.live.sandbox` slice diffs observed responses row-by-row.

---

## Module disambiguation (LOAD-BEARING)

Three ADP products show up in the operator's life. Connect-time
behavior is split per module:

| Module | Vendor portal label | Adapter behavior |
|---|---|---|
| `workforce_now` | ADP Workforce Now (WFN) | INTEGRATE — proceed through OAuth callback. |
| `workforce_manager` | ADP Workforce Manager (WFM) | INTEGRATE — proceed through OAuth callback. |
| `run` | ADP RUN | REFUSED — `connect()` throws `ModuleRefusalException` with friendly copy from `vendor_master_list.md` "Module Disambiguation Flags". |

`VendorCapabilityProfile.modules` lists all three so the picker can
disambiguate; RUN is listed for picker disambiguation only and bounces
at connect time. The connect flow records the chosen module in
`connector_connection.metadata.module` so reconnects know which
product was originally chosen and the adapter routes to the correct
endpoints (see "Endpoints consumed" rows that diverge between WFN and
WFM).

Both supported modules share the same Forge & Flow code path; the
`module` parameter passes through to the transport so the live HTTP
client at `*.live.*` slices binds to the right base URL +
authorization scopes per module.

---

## Endpoints consumed

| Method | Path (assumed) | Module | Purpose | Rate limit | Pagination shape |
|---|---|---|---|---|---|
| POST | `/auth/oauth/v2/token` | both | OAuth `authorization_code` exchange + `refresh_token` rotation | TBD — partnership | n/a |
| POST | `/auth/oauth/v2/revoke` | both | Best-effort revoke on disconnect | TBD — partnership | n/a |
| GET | `/time/v2/workers/{associate_oid}/team-time-cards` | WFN | Backfill + incremental poll (modified-since window) — Team Time Cards v2 | TBD — partnership | cursor (`nextCursor`) |
| GET | `/time/v2/workers/{associate_oid}/time-events` | WFN | Backfill + incremental poll — Time Events | TBD — partnership | cursor (`nextCursor`) |
| GET | `/time/v1/workers/{associate_oid}/work-schedules` | WFN | Scheduled-shift ingest (Time Work Schedules v1) | TBD — partnership | cursor (`nextCursor`) |
| GET | `/hr/v2/workers/{associate_oid}/work-assignments` | WFN | Role / position lookup; WFM exposes the same data via `workAssignment.jobTitle` directly on the worker. | TBD — partnership | cursor (`nextCursor`) |
| GET | `/hr/v2/workers` | both | Worker directory; binding context for canonical fact writes | TBD — partnership | cursor (`nextCursor`) |
| GET | `/hr/v2/workers/{associate_oid}` | both | Webhook fall-through fetch when an inbound payload omits a worker / position field | TBD — partnership | n/a |
| POST | `/core/v1/event-subscriptions` | both | Auto-register the ADP Marketplace event subscription on connect | TBD — partnership | n/a |
| DELETE | `/core/v1/event-subscriptions/{id}` | both | Unregister on disconnect | TBD — partnership | n/a |

Every endpoint listed is invoked by the adapter code (via
`AdpTransport`); every endpoint the adapter invokes is listed here.
Each row is an assumption; the `*.live.sandbox` slice will verify
each path + method + pagination shape per module and cut a bounded
fix for any drift. Where WFN and WFM diverge in shape (e.g., role
exposure path), the canonicalizer in
`lib/integrations/labor/adp_labor_adapter.dart` already falls back
between `worker.position.position_title` (WFN) and
`workAssignment.jobTitle` (WFM); the live slice records which path
each module returns and removes the dead branch.

---

## ADP Marketplace event subscriptions ("autoRegister")

ADP exposes inbound webhooks via the ADP Marketplace event-
subscription surface. The adapter declares
`VendorWebhookSupport.autoRegister` and calls
`/core/v1/event-subscriptions` on connect to bind the operator's
proxy webhook URL to the `time.timeEvent.modify` event (assumed
event name; verified in `*.live.sandbox`). Event subscriptions land
once the partnership clears — same DPA gate as production
credentials. See `webhook_signature.md` for the signature header /
encoding / replay envelope.

---

## Sandbox / test environment

**Base URL**: TBD — partnership.
**Sign-up**: via partnership; see `partnership_status.md`. The ADP
Marketplace partner sandbox is released after the DPA review
progresses (typically before production credentials, midway through
the 12-24 week clock).
**Known limitations** (assumptions until verified):
- The partner sandbox is presumed to mirror production schemas
  (industry standard) but emit synthetic data.
- Event-subscription auto-registration may require a one-time portal
  step that the adapter cannot automate. Verified in
  `8.S.ADP.live.sandbox`.

If no sandbox is issued at partnership-clear time, the workaround is
to run `8.S.ADP.live.prod` against an F&F-owned ADP Workforce Now
worksite with read-only scopes; the field-mapping diff still applies.

---

## Production environment

**Base URL**: TBD — partnership (typically `https://api.adp.com`).
**Partnership requirements**: ADP Marketplace Developer Participation
Agreement must clear before production credentials + mutual-TLS
certs are issued. Lead time 12-24 weeks (longest in the wave); tracked
in `partnership_status.md`.
**Rate-limit policy**: TBD — partnership.
**Quota**: TBD — partnership.
**Mutual TLS**: required at production per the ADP Marketplace
production envelope. The mTLS cert pair is operator-scoped (one cert
pair per F&F deployment) and provisioned at `*.live.prod` time.

---

## Versioning

**Vendor's deprecation policy**: TBD — partnership. ADP rolls major
API changes through the developer-portal catalog with a deprecation
window; the partner doc pins the exact policy.
**Adapter pinned to**: `v1-2026-05-04-assumed`.
**Vendor's last announced breaking change**: unknown until partnership
clears.
**Re-verification cadence**: every 180 days OR on any vendor
deprecation announcement, whichever is sooner. The adapter will
re-pin the API version on the first observed breaking change in
`8.S.ADP.live.sandbox`.
