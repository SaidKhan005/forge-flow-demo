# Agendrix — Partnership Status

**Vendor ID**: `agendrix`
**Owner (ops side)**: TBD
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below — for Agendrix, "production credentials" means a published
> developer app with a registered `redirect_uri`, NOT a partnership
> review (Agendrix is self-serve OAuth).

---

## Partnership program

**Program name**: n/a — public OAuth (self-serve at developer portal)

**Vendor URL**: <https://developers.agendrix.com/>
(public developer portal with API Playground; no partnership
application required)

---

## Application status

`not_started`

**Date of last status change**: 2026-05-04 (engineering slice ship)
**Notes**: Engineering ships the documented adapter ahead of the
production developer-app registration so the framework is ready when
ops files the registration. Ops registers the app at
<https://developers.agendrix.com/> after the engineer-all-17 push
closes; lead time is effectively zero (self-serve).

---

## Production credentials issued

`N`

**If Y, date issued**: n/a
**If Y, credential location**: n/a (NEVER plaintext here; client id +
client secret are stored in the proxy `vendor_credentials` table
encrypted via pgcrypto envelope when the developer-app registration
lands)

---

## Estimated lead time remaining

`none` — Agendrix is self-serve. Ops registers the developer app
when convenient; production credentials are issued automatically.

---

## Blockers

- developer-app registration not yet filed (since 2026-05-04 — opens
  after the Wave B engineer-all-17 push closes).

---

## Lifecycle promotion gate

The `8.S.AG.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice will not run if "Production
credentials issued" is `N` — engineering does not need credentials
they don't have. For Agendrix the production-credentials line flips
to `Y` as soon as the developer-app registration lands (no
partnership review needed).
