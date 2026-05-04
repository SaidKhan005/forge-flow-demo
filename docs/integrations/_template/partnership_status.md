# `<vendor_display_name>` — Partnership Status

**Vendor ID**: `<vendor_id>`
**Owner (ops side)**: `<name>`
**Last updated**: YYYY-MM-DD

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below.

---

## Partnership program

**Program name**: `<exact program name + tier>`

Examples:
- "Toast Partner — Standard Tier"
- "ADP Marketplace Developer Participation Agreement"
- "NCR Voyix Developer Program — Aloha module"
- "n/a — public OAuth, no partnership required" (Lightspeed K-Series,
  Square, Revel, QuickBooks Time, Agendrix, Libro, Humanity)

**Vendor URL**: `<https://...>`

---

## Application status

`not_started` | `applied` | `under_review` | `cleared` | `denied`

**Date of last status change**: YYYY-MM-DD
**Notes**: any context (e.g., "vendor requested security audit
documentation; sent 2026-04-15; awaiting response").

---

## Production credentials issued

`Y` / `N`

**If Y, date issued**: YYYY-MM-DD
**If Y, credential location**: `<Cloud Run secret env name>` (NOT
plaintext here)

---

## Estimated lead time remaining

Realistic estimate; updated monthly as ops learns more.

`<X-Y weeks>` | `<unknown>` | `<n/a>`

---

## Blockers

Any commercial blocker (legal review pending, pricing-tier
negotiation, vendor's response time slow, etc.). One bullet per
blocker; resolve as they clear.

- `<blocker description>` (since YYYY-MM-DD)

---

## Lifecycle promotion gate

The `*.live.prod` slice MUST cite this file in its prompt's Block 1
"Authority" section. The slice will not run if "Production credentials
issued" is `N` — engineering does not need credentials they don't
have.
