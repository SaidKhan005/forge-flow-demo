# Clover — Partnership Status

**Vendor ID**: `clover`
**Owner (ops side)**: TBD (assigned at Wave B kickoff)
**Last updated**: 2026-05-03

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below.

---

## Partnership program

**Program name**: Clover App Market.
**Vendor URL**: <https://www.clover.com/developers>

Clover App Market is the gating program for production OAuth
credentials. Lighter than Toast / Aloha NCR Voyix / Oracle MICROS —
sandbox keys are issued at developer-account signup with no review;
production credentials require an App Market submission with security
+ branding review (1-3 weeks lead time per the doctrine memo).

---

## Application status

`not_started`

**Date of last status change**: 2026-05-03
**Notes**: engineering slice (`8.CL`) shipped at lifecycle =
`documented` on 2026-05-03. Ops application kicks off at Wave B
close once all 17 vendor adapters are documented.

---

## Production credentials issued

`N`

**If Y, date issued**: —
**If Y, credential location**: — (will live in Cloud Run env
`CLOVER_APP_PROD_CLIENT_SECRET`; never plaintext in this file)

---

## Estimated lead time remaining

`1-3 weeks` from application submission per Clover developer-program
documentation. Realistic estimate; updated monthly as ops learns
more.

---

## Blockers

None at engineering-slice close. Application has not started.

---

## Lifecycle promotion gate

The `8.CL.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice will not run if "Production
credentials issued" is `N` — engineering does not need credentials
they don't have.
