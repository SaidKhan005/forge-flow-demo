# Toast — Partnership Status

**Vendor ID**: `toast`
**Owner (ops side)**: ops
**Last updated**: 2026-05-03

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below.

---

## Partnership program

**Program name**: `Toast Partner — Standard Tier`

**Vendor URL**: <https://pos.toasttab.com/partner-program>

Toast gates production credential issuance behind the Toast Partner
Program. The Standard Tier covers the API surface this adapter
consumes (`orders/v2`, `authentication/v1`, `webhooks-config/v1`,
`restaurants/v1`); the Partner / Custom tiers are upgrades F&F may
opt into post-V1 if quotas justify it.

---

## Application status

`not_started`

**Date of last status change**: 2026-05-03 (engineering slice ship —
ops has not yet kicked off the intake)
**Notes**: Engineering closes Wave B at lifecycle = `documented`
without partnership intake; ops commercial lane is the gating step
for `production_credentialed` promotion. Sandbox credentials may be
issued earlier under the Standard Tier intake; ops should request
them once the commercial conversation opens.

---

## Production credentials issued

`N`

**If Y, date issued**: YYYY-MM-DD
**If Y, credential location**: `<Cloud Run secret env name>` (NOT
plaintext here)

---

## Estimated lead time remaining

`6-12 weeks` (typical Toast Partner program lead time per ops
research 2026-05-03; revisit monthly).

---

## Blockers

None as of 2026-05-03 — the commercial lane has not yet started.
First blocker to clear is "intake started"; ops to update this file
on first conversation with Toast partnership team.

---

## Lifecycle promotion gate

The `8.TS.live.prod` slice MUST cite this file in its prompt's Block 1
"Authority" section. The slice will not run if "Production credentials
issued" is `N` — engineering does not need credentials it does not
have. The `8.TS.live.sandbox` slice may run as soon as Toast issues
sandbox credentials under the Standard Tier; sandbox issuance does
not require full Partner program clearance.
