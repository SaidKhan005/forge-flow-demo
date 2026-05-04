# 7shifts — Partnership Status

**Vendor ID**: `seven_shifts`
**Owner (ops side)**: ops
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below.

---

## Partnership program

**Program name**: n/a — already onboarded; existing audit work.

7shifts exposes a **public self-serve developer portal** at
<https://developers.7shifts.com>; no partnership program is required
to obtain sandbox or production credentials. F&F has prior audit
work against 7shifts (per
`docs/phases/phase_8/vendor_master_list.md` "Already audited —
best-in-class finalization signal") so the integration shape is
familiar; new operator credentials follow the standard OAuth
sign-in flow each operator completes themselves.

The Gourmet pricing tier is the operator's own commercial decision
with 7shifts (not an F&F engineering blocker) — webhook
auto-registration unlocks at Gourmet, polling-only sync covers every
lower tier.

**Vendor URL**: <https://www.7shifts.com> (operator-facing) /
<https://developers.7shifts.com> (developer portal)

---

## Application status

`not_started`

**Date of last status change**: 2026-05-04
**Notes**: No partnership application required. The
`8.S.7S.live.sandbox` slice runs against developer-portal sandbox
credentials F&F holds today (issued at the original audit work).
The `8.S.7S.live.prod` slice runs against an F&F-controlled paying
account (Gourmet tier, registered for production OAuth client
credentials at the same time as the sandbox account). Operator
connections at launch are standard self-serve OAuth — each operator
signs into their own 7shifts account, F&F never holds the operator's
plaintext password or refresh token.

---

## Production credentials issued

`N`

**If Y, date issued**: pending (F&F's own production OAuth client
credentials are held server-side once the `8.S.7S.live.prod` slice
fires; the slice is what creates the production client).
**If Y, credential location**: Cloud Run secret env (per Hard Promise
#7); name TBD at the live.prod slice. NOT plaintext here.

---

## Estimated lead time remaining

`n/a` — public OAuth. The `8.S.7S.live.sandbox` slice can fire any
time after this engineering slice merges; the `8.S.7S.live.prod`
slice can fire as soon as F&F's production OAuth client is
registered with 7shifts (a one-time admin step in the developer
portal).

---

## Blockers

- None for engineering. The slice's lifecycle promotion path is
  bounded by F&F's own decision to register a production OAuth
  client; there is no vendor-side review.

---

## Lifecycle promotion gate

The `8.S.7S.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice will not run if "Production
credentials issued" is `N`. For 7shifts the gate is administrative
(register the prod OAuth client) rather than partnership-clearance —
the moment ops flips this file to `Y` + dated, the prompt fires.

The intermediate `8.S.7S.live.sandbox` slice runs against the
developer-portal sandbox account F&F already holds; ops does not
need to update this file before that slice fires.
