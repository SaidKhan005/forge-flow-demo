# Humanity (TCP) — Partnership Status

**Vendor ID**: `humanity`
**Owner (ops side)**: ops
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below — for Humanity this gate trivially clears because the vendor
> has no partnership program; production access is granted to any
> operator with a Humanity v1 account.

---

## Partnership program

**Program name**: n/a — legacy auth, no partner program. Humanity v1
(operated by TCP Software) does not run a developer partner program;
any operator with an active Humanity account can connect by pasting
their existing credentials. There is no Marketplace listing or
sales-rep onboarding to clear.

**Vendor URL**: <https://platform.humanity.com/v1.0>

---

## Application status

`not_started`

**Date of last status change**: 2026-05-04
**Notes**: no application is required. The status row stays
`not_started` for tracker uniformity; the engineering slice ships
the adapter at lifecycle = `documented` and the `*.live.sandbox` /
`*.live.prod` slices verify against an F&F-owned demo account and
then real operator credentials respectively, neither of which
requires a partnership commercial lane.

---

## Production credentials issued

`Y` (no partnership gate; production is the same hostname as
sandbox per `api_consumed.md`)

**If Y, date issued**: 2026-05-04 (no issuance event — any active
Humanity account works)
**If Y, credential location**: per-operator
`vendor_credentials.<connection_id>.bearer_token` (pgcrypto envelope)
once the operator pastes credentials at connect time.

---

## Estimated lead time remaining

`n/a` — no partnership clearance to wait on.

---

## Blockers

- (none)

---

## Lifecycle promotion gate

The `8.S.HM.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. Because Humanity has no partnership
program, the slice can run as soon as the engineering slice
(`8.S.HM`) and sandbox slice (`8.S.HM.live.sandbox`) close — there
is no commercial lane to wait on.
