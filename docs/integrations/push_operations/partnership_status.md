# Push Operations — Partnership Status

**Vendor ID**: `push_operations`
**Owner (ops side)**: TBD
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below.

---

## Partnership program

**Program name**: Push Operations partner approval

**Vendor URL**: <https://www.pushoperations.com/partners>
(Push Operations Restaurant Partner Ecosystem; partner approval issues
the bearer token used by `Authorization: Bearer <token>`.)

---

## Application status

`not_started`

**Date of last status change**: 2026-05-04 (engineering slice ship)
**Notes**: Engineering ships the documented adapter ahead of the
partnership lane so the framework is ready when sandbox / production
bearer tokens arrive. Ops opens the application after the
engineer-all-17 push closes. Push Operations partner approval is
shorter than ADP (4-6 weeks vs 8-16+ weeks) but still gates production
credentials.

---

## Production credentials issued

`N`

**If Y, date issued**: n/a
**If Y, credential location**: n/a (NEVER plaintext here)

---

## Estimated lead time remaining

`4-6 weeks` (Push Operations partner approval documented lead time at
slice ship; updated monthly as ops learns more.)

---

## Blockers

- partnership application not yet opened (since 2026-05-04 — opens
  after the Wave B engineer-all-17 push closes).

---

## Lifecycle promotion gate

The `8.S.PU.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice will not run if "Production
credentials issued" is `N` — engineering does not need credentials
they don't have.
