# Tock — Partnership Status

**Vendor ID**: `tock`
**Owner (ops side)**: ops
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below.

---

## Partnership program

**Program name**: `Tock Premium-tier negotiation`

**Vendor URL**: <https://www.exploretock.com>

Tock gates BOTH the reservation API and webhook delivery to **Premium
or Premium Unlimited** tier customers. Production credentials cannot
be issued before the operator's commercial relationship with Tock
reaches that tier. The commercial lane is operator-by-operator: each
F&F operator on Tock must be on the Premium / Premium Unlimited tier,
and Tock issues per-`businessId` API keys via
`integrate@tockhq.com` only after that tier is in place.

F&F's role: surface the gating clearly in the vendor picker (lifecycle
= `documented` shows "Coming soon" with a tooltip explaining the
Premium-tier dependency) and capture "Notify me when ready" interest
so we can re-engage operators when their Tock plan reaches Premium.

---

## Application status

`not_started`

**Date of last status change**: 2026-05-04 (engineering slice ship —
ops has not yet kicked off the intake)
**Notes**: Engineering closes Wave B at lifecycle = `documented`
without partnership intake; ops commercial lane is the gating step
for `production_credentialed` promotion. Sandbox credentials are
issued by Tock under the same Premium-tier gate; engineering does
NOT consume that lane.

---

## Production credentials issued

`N`

**If Y, date issued**: YYYY-MM-DD
**If Y, credential location**: `<Cloud Run secret env name>` (NOT
plaintext here)

---

## Estimated lead time remaining

`4-8 weeks` (typical Tock Premium-tier negotiation lead time per ops
research 2026-05-04; revisit monthly).

---

## Blockers

- **Premium-tier requirement** is the primary blocker. F&F cannot
  issue an integration on a Standard / Premium-Lite Tock plan
  because the API + webhooks are not exposed at those tiers. Ops
  identifies operators on Premium / Premium Unlimited as priority
  candidates for the first cohort.
- **Commercial lane not yet started.** First action is for ops to
  open conversations with Tock partnership / `integrate@tockhq.com`
  about the F&F integration program; update this file on first
  reply.

---

## Lifecycle promotion gate

The `8R.TC.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice will not run if "Production
credentials issued" is `N` — engineering does not need credentials it
does not have. The `8R.TC.live.sandbox` slice may run as soon as Tock
issues sandbox credentials under the Premium-tier intake.
