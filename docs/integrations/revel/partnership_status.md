# Revel Systems — Partnership Status

**Vendor ID**: `revel`
**Owner (ops side)**: ops lead (TBD per `docs/phases/phase_8/vendor_master_list.md`)
**Last updated**: 2026-05-03

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below — but Revel is self-serve, so each operator issues their own
> production credentials at connect time.

---

## Partnership program

**Program name**: n/a — public OAuth, no partnership required.

Revel exposes a public developer portal at
<https://developer.revelsystems.com/> with self-serve `client_id` /
`client_secret` issuance. F&F never holds Revel production keys at
the platform level; each operator issues their own credential pair
from their Revel admin portal and pastes them into the F&F connect
flow. The credential pair is encrypted at rest in
`vendor_credentials` per the framework contract.

**Vendor URL**: <https://developer.revelsystems.com/>

---

## Application status

`not_started` — and intentionally so. There is no application to
file at the F&F-platform level. Per-operator credential issuance
happens at the operator's Revel admin portal at the moment they
connect, not as a precondition.

**Date of last status change**: 2026-05-03 (slice `8.RV` lands at
lifecycle = `documented`).
**Notes**: F&F's commercial lane for Revel is unblocked; all
remaining gating is engineering verification (`8.RV.live.sandbox`
once a QA sandbox is provisioned, then `8.RV.live.prod` once at least
one operator has paid Revel-production credentials to test against).

---

## Production credentials issued

`N` — per the framing above, F&F-platform credentials don't exist;
production credentials are operator-side and issued at connect time.
The lifecycle promotion gate for `8.RV.live.prod` is "at least one
F&F operator has paid Revel-production credentials available for the
verification slice", not "F&F has been issued production
credentials".

**If Y, date issued**: n/a
**If Y, credential location**: n/a (each operator's credentials are
encrypted at rest in their `vendor_credentials` row, not in a
F&F-wide secret env)

---

## Estimated lead time remaining

`n/a` — no commercial lane to clear. Engineering can fire
`8.RV.live.sandbox` as soon as a Revel sandbox is provisioned and
`8.RV.live.prod` as soon as the first operator with Revel commits to
the launch cohort. Memory: `project_phase_8_engineer_all_17_doctrine.md`.

---

## Blockers

- (none at the F&F-platform level — public OAuth, no partnership
  application required)

---

## Lifecycle promotion gate

The `8.RV.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice can run as soon as a launch-
cohort operator has Revel-production credentials they're willing to
let F&F connect against; F&F-platform credentials are not part of
the gate (Revel does not issue them).
