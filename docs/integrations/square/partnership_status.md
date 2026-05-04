# Square — Partnership Status

**Vendor ID**: `square`
**Owner (ops side)**: ops (no commercial gate — public OAuth)
**Last updated**: 2026-05-03

> Engineering ships this file as a stub. Square does not require a
> partnership program (the developer portal is self-serve), so the
> "lifecycle promotion to `production_credentialed`" gate degenerates
> to "F&F has obtained sandbox + production application credentials
> from the Square developer dashboard."

---

## Partnership program

**Program name**: n/a — public OAuth

**Vendor URL**: https://developer.squareup.com/apps

Square's developer program is self-serve: any account can create a
Square Application in the developer dashboard, mint sandbox + prod
client IDs / secrets, and use those to drive OAuth without contacting
Square. There is no review, tier, or partnership agreement gating
Square API access.

---

## Application status

`not_started`

**Date of last status change**: 2026-05-03 (stub creation)
**Notes**: F&F has not yet created a Square developer application.
The `8.SQ.live.sandbox` slice will be unblocked once an F&F engineer
registers an application at https://developer.squareup.com/apps and
the sandbox client ID + secret are added to the proxy environment.

---

## Production credentials issued

`N`

**If Y, date issued**: —
**If Y, credential location**: `<Cloud Run secret env name>`

---

## Estimated lead time remaining

n/a — public self-serve OAuth has no commercial lead time. The only
gate is "F&F engineer registers the developer application" (~30
minutes one-time).

---

## Blockers

- (none — public OAuth, no commercial blocker)

---

## Lifecycle promotion gate

The `8.SQ.live.prod` slice's prompt MUST cite this file in its
"Authority" section. The slice runs once "Production credentials
issued" is `Y` (which for Square means: F&F engineer has registered
the production application + the production client ID/secret have
been written to the proxy's KMS-managed secret store at the V1 lean
cut 2 simplicity level — env vars in Cloud Run).
