# Libro Reserve — Partnership Status

**Vendor ID**: `libro`
**Owner (ops side)**: TBD (assign when `8R.LB.live.sandbox` slice
opens)
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below.

---

## Partnership program

**Program name**: n/a — public OAuth, no partnership required.

Libro publishes the developer portal at
<https://libroreserve.github.io/api-documentation/> and operators
self-serve sandbox credentials. Production credentials follow the
same self-serve path; F&F provisions per-environment client
credentials directly via the Libro developer console.

**Vendor URL**: <https://libroreserve.github.io/api-documentation/>

---

## Application status

`not_started`

**Date of last status change**: 2026-05-04 (engineering slice ship).
**Notes**: Public OAuth — there is no formal application. Ops
provisions client id + client secret in the Libro developer console
when the `8R.LB.live.sandbox` slice opens.

---

## Production credentials issued

`N`

**If Y, date issued**: n/a
**If Y, credential location**: n/a (will be `LIBRO_OAUTH_CLIENT_*`
env vars on Cloud Run when issued).

---

## Estimated lead time remaining

`n/a` — public OAuth, no partnership lead time. Sandbox + prod
credentials provision in the same week the `8R.LB.live.sandbox`
slice opens.

---

## Blockers

None.

---

## Lifecycle promotion gate

The `8R.LB.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice will not run if "Production
credentials issued" is `N` — engineering does not need credentials
they don't have. Ops flips this to `Y` + date once the prod client
secret lands in the Cloud Run env.
