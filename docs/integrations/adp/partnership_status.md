# ADP Workforce Now / Workforce Manager — Partnership Status

**Vendor ID**: `adp`
**Owner (ops side)**: ops
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below.

---

## Partnership program

**Program name**: ADP Marketplace Developer Participation Agreement

ADP releases the partner API endpoint reference, sandbox, and
production credentials only to vendors that complete the ADP
Marketplace Developer Participation Agreement (DPA). The DPA is the
longest commercial lead time in the wave (12-24 weeks); production
credentials additionally require partner-issued mutual-TLS certs
(provisioned at `*.live.prod` time).

**Vendor URL**: <https://www.adp.com/marketplace>

---

## Application status

`not_started`

**Date of last status change**: 2026-05-04
**Notes**: ADP Marketplace DPA not yet submitted. Engineering
proceeded against the published shapes from the developer-portal API
catalog (Time Events / Team Time Cards / Time Work Schedules / Work
Assignments / Workers) so the moment ADP issues partner credentials,
only the small `8.S.ADP.live.sandbox` slice remains. EVERY assumption
in the per-vendor doc pack is flagged "verify in
`8.S.ADP.live.sandbox`"; the field-mapping diff the live slice runs
is what unblocks promotion to `sandbox_verified`.

The module-disambiguation discipline (WFN / WFM accepted; RUN
refused at connect with the friendly copy from
`docs/phases/phase_8/vendor_master_list.md`) is engineered into the
adapter at this slice so the picker behavior is deterministic before
any partner doc lands.

---

## Production credentials issued

`N`

**If Y, date issued**: n/a
**If Y, credential location**: n/a (NOT plaintext here)
**Mutual TLS cert pair issued**: n/a

---

## Estimated lead time remaining

`12-24 weeks` from DPA submission. The clock starts when ops submits
the ADP Marketplace Developer Participation Agreement; the DPA
review is the gating dependency for `8.S.ADP.live.sandbox`. ADP's
review is the longest in the wave (cf. OpenTable 6-12 weeks, Tock
4-8 weeks).

---

## Blockers

- ADP Marketplace DPA not yet submitted (since 2026-05-04). Once the
  DPA is in ADP's hands the 12-24 week clock begins.
- Mutual-TLS cert pair issuance (production-only) is downstream of
  the DPA clearing; sandbox does not require mTLS. Tracked here so
  `*.live.prod` knows what to expect.

---

## Lifecycle promotion gate

The `8.S.ADP.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice will not run if "Production
credentials issued" is `N` — engineering does not need credentials
they don't have.

The intermediate `8.S.ADP.live.sandbox` slice runs against partner-
issued sandbox credentials (released earlier in the DPA review cycle
than production credentials per the standard ADP review pattern).
The exact gate is: ops updates this file with `Application status:
under_review` + sandbox credentials in hand → the
`*.live.sandbox` prompt fires.
