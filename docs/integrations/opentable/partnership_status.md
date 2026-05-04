# OpenTable — Partnership Status

**Vendor ID**: `opentable`
**Owner (ops side)**: ops
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below.

---

## Partnership program

**Program name**: OpenTable Partner API

OpenTable does not maintain a public developer portal. The Partner
API + sandbox + production credentials are released only to vendors
that complete the partnership program review.

**Vendor URL**: <https://restaurant.opentable.com/products/opentable-platform/>

---

## Application status

`not_started`

**Date of last status change**: 2026-05-04
**Notes**: Partner application not yet submitted. Engineering
proceeded against the published reservation-data field shape (the
industry-standard reservation envelope) so that the moment OpenTable
issues the partner doc + sandbox creds, only the small
`8R.OT.live.sandbox` slice remains. EVERY assumption in the per-
vendor doc pack is flagged "verify in `8R.OT.live.sandbox`"; the
field-mapping diff the live slice runs is what unblocks promotion to
`sandbox_verified`.

---

## Production credentials issued

`N`

**If Y, date issued**: n/a
**If Y, credential location**: n/a (NOT plaintext here)

---

## Estimated lead time remaining

`6-12 weeks` from partner-application submission. The clock starts
when ops submits the OpenTable Partner API application; the
partnership review is the gating dependency for `8R.OT.live.sandbox`.

---

## Blockers

- Partner application not yet submitted (since 2026-05-04). Once the
  application is in OpenTable's hands the 6-12 week clock begins.

---

## Lifecycle promotion gate

The `8R.OT.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice will not run if "Production
credentials issued" is `N` — engineering does not need credentials
they don't have.

The intermediate `8R.OT.live.sandbox` slice runs against partner-
issued sandbox credentials (released earlier in the partnership
review cycle than production credentials per the industry-standard
review pattern). The exact gate is: ops updates this file with
`Application status: under_review` + sandbox credentials in hand →
the `*.live.sandbox` prompt fires.
