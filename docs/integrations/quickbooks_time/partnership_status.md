# QuickBooks Time — Partnership Status

**Vendor ID**: `quickbooks_time`
**Owner (ops side)**: F&F integrations lead (`<name TBD>`)
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. QuickBooks Time uses public Intuit
> OAuth (no partnership program), so production rollout is gated on
> credential issuance only — not commercial negotiation. Lifecycle
> promotion to `production_credentialed` requires "Production
> credentials issued: Y" below.

---

## Partnership program

**Program name**: n/a — public OAuth, no partnership required.

QuickBooks Time uses Intuit's standard OAuth 2.0 developer flow.
Anyone can register a developer app at <https://developer.intuit.com>
and connect to a QuickBooks Time account once the operator approves
the OAuth consent screen.

**Vendor URL**: <https://developer.intuit.com>

---

## Application status

`not_started`

**Date of last status change**: 2026-05-04 (slice ship)
**Notes**: At slice ship, F&F has not yet registered the production
Intuit developer app. Sandbox round-trip (`8.S.QBT.live.sandbox`) and
production credential issuance (`8.S.QBT.live.prod`) are tracked in
the live-rollout phase doc at
`docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`.

---

## Production credentials issued

`N`

**If Y, date issued**: n/a
**If Y, credential location**: n/a (will land in
`<Cloud Run secret env name>` once issued; never plaintext here)

---

## Estimated lead time remaining

`n/a` — public OAuth has no negotiation lead time. Production
credential issuance is bounded by the time it takes F&F to register
an Intuit developer app and complete the OAuth review (Intuit's
review queue is typically 1-3 business days for read-only scopes).

---

## Blockers

None at slice ship.

---

## Lifecycle promotion gate

The `*.live.prod` slice MUST cite this file in its prompt's Block 1
"Authority" section. Because QBT uses public OAuth, "Production
credentials issued: Y" lands as soon as F&F registers the Intuit
developer app and completes Intuit's review — no commercial
negotiation required.
