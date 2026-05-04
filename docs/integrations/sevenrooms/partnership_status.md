# SevenRooms — Partnership Status

**Vendor ID**: `sevenrooms`
**Owner (ops side)**: TBD (Forge & Flow operations)
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. SevenRooms gates partner credentials
> behind account-rep onboarding (no self-serve developer portal at
> V1), so production credentials require this lane to clear.

---

## Partnership program

**Program name**: SevenRooms account-rep onboarding.

SevenRooms does not run a self-serve developer portal at the
publicly fetched docs URL (<https://api-docs.sevenrooms.com/>
requires a partner account login). Production credentials —
`client_id`, `client_secret`, and per-venue `venue_id` — are issued
by a SevenRooms account rep after the operator (or F&F on the
operator's behalf) completes the partnership form linked from
<https://sevenrooms.com/platform/integrations-apis/>.

**Vendor URL**: <https://sevenrooms.com/platform/integrations-apis/>
**Partnership form**: linked from the Vendor URL above
("Let's Talk" / "Contact Us").
**Account-rep contact**: TBD (assigned at form submission).

---

## Application status

`not_started`.

**Date of last status change**: 2026-05-04 (engineering slice ship).
**Notes**: Application kicks off when ops submits the SevenRooms
partnership form. The first batch of partner credentials (sandbox)
typically arrives within 4-8 weeks of form submission per industry
norms; production credentials follow after sandbox sign-off.

---

## Production credentials issued

`N`.

**If Y, date issued**: YYYY-MM-DD
**If Y, credential location**: `<Cloud Run secret env name>` (NOT
plaintext here)

---

## Estimated lead time remaining

`4-8 weeks` once ops submits the partnership form.

The lead time covers:
- account-rep assignment (~ 1-2 weeks)
- partnership form review (~ 1-2 weeks)
- sandbox credential issuance (~ 1 week)
- sandbox verification by F&F (`8R.SR.live.sandbox` slice; ~ 1
  engineering day)
- production credential issuance (~ 1-2 weeks after sandbox sign-off)

Operator-side commercial decisions (whether the operator's
SevenRooms plan tier permits partner API access) may add additional
lead time per operator. Verify per-operator before production
rollout.

---

## Blockers

None at engineering slice ship. Update as the commercial lane
progresses.

---

## Lifecycle promotion gate

The `8R.SR.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice will not run if "Production
credentials issued" is `N` — engineering does not need credentials
they don't have. The `8R.SR.live.sandbox` slice may run as soon as
sandbox credentials arrive, even if production credentials are still
pending; that's the expected sequencing per the per-vendor doctrine
(`memory/project_phase_8_engineer_all_17_doctrine.md`).
