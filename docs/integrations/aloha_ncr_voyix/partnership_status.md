# Aloha (NCR Voyix) — Partnership Status

**Vendor ID**: `aloha_ncr_voyix`
**Owner (ops side)**: TBD
**Last updated**: 2026-05-04

> Engineering ships this file as a stub. Ops updates it as the
> commercial lane progresses. Lifecycle promotion to
> `production_credentialed` requires "Production credentials issued: Y"
> below.

---

## Partnership program

**Program name**: NCR Voyix Developer Program — Aloha module

**Vendor URL**: <https://developer.ncrvoyix.com>

NCR Voyix runs a centralized Developer Program covering Aloha, NCR
Counterpoint, and the broader NCR commerce stack. Each API surface
under the program (Aloha checks, OAuth, events bus, sites) requires
a separate per-API access request once the program intake clears.
Sandbox credentials are not issued until both the program intake AND
the per-API access request clear; production credentials require an
additional commercial conversation with the NCR Voyix partner team.

---

## Application status

`not_started`

**Date of last status change**: 2026-05-04
**Notes**: Engineering slice (`8.AL`) ships at lifecycle =
`documented` against the documented Aloha-module API shape. The
commercial lane is unblocked the moment ops opens the NCR Voyix
Developer Program intake. The 11W picker shows "Coming soon" + a
"Notify me when ready" capture row (deferred wiring at `11W.8`) so
the operator can express interest while the partnership is open.

---

## Production credentials issued

`N`

**If Y, date issued**: n/a
**If Y, credential location**: n/a (NOT plaintext here)

---

## Estimated lead time remaining

`8-16 weeks`

NCR Voyix Developer Program intake plus per-API access request plus
the partner-team commercial conversation typically clears in 8 to
16 weeks for restaurant-tech ISVs. The estimate is updated monthly
as ops gathers signal from the NCR Voyix partner team.

---

## Blockers

- Application not yet opened (since 2026-05-04). Resolves when ops
  initiates the NCR Voyix Developer Program intake.

---

## Lifecycle promotion gate

The `8.AL.live.prod` slice MUST cite this file in its prompt's
Block 1 "Authority" section. The slice will not run if "Production
credentials issued" is `N` — engineering does not need credentials
they don't have.

The `8.AL.live.sandbox` slice fires sooner (sandbox credentials only
require the program intake + per-API access request — not the full
production commercial conversation). When sandbox credentials are
issued, ops updates "Application status" to `under_review` and
references this file from the `8.AL.live.sandbox` prompt.
