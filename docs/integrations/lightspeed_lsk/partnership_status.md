# Lightspeed Restaurant K-Series — Partnership Status

**Vendor ID**: `lightspeed_lsk`
**Owner (ops side)**: TBD (Forge & Flow operations)
**Last updated**: 2026-05-03

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lightspeed K-Series is a public-OAuth
> vendor with no partnership program required, so this file mostly
> exists for symmetry with partnership-gated vendors (Toast, Aloha,
> ADP).

---

## Partnership program

**Program name**: n/a — public OAuth, no partnership required.

Lightspeed K-Series exposes self-serve OAuth registration through
the developer portal
(<https://api-portal.lsk.lightspeed.app>). Any developer can
register a client and receive production credentials by accepting
the standard developer terms; there is no per-integration review
gate.

**Vendor URL**: <https://api-portal.lsk.lightspeed.app>

---

## Application status

`not_started`.

**Date of last status change**: 2026-05-03 (engineering slice ship).
**Notes**: Production credentials will be issued by registering a
client through the developer portal; no waitlist. The
`8.LSK.live.prod` slice will run when ops registers the production
client and the credentials land in Cloud Run secret env.

---

## Production credentials issued

`N`.

**If Y, date issued**: YYYY-MM-DD
**If Y, credential location**: `<Cloud Run secret env name>` (NOT
plaintext here)

---

## Estimated lead time remaining

`< 1 week`. Self-serve registration; the only gate is ops bandwidth
to complete the developer-portal account setup and stash credentials
in Cloud Run secret env.

---

## Blockers

None.

---

## Lifecycle promotion gate

The `8.LSK.live.prod` slice MUST cite this file in its prompt's Block
1 "Authority" section. The slice will not run if "Production
credentials issued" is `N` — engineering does not need credentials
they don't have. For Lightspeed K-Series the gate is light because
the credentials are self-serve.
