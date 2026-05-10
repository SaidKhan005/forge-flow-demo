# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Reference: `docs/integrations/tock/oauth_shape.md` (auth shape =
  `keyPaste`; OAuth not applicable to Tock)
- Reference: `docs/POST_HARDENING_FOLLOWUPS.md` (2026-05-08
  confirmed-clean note: Tock listed among the six non-OAuth vendors
  with no refresh closure)
- Notes: Tock is one of six non-OAuth vendors per the format spec
  (README.md "Non-OAuth Vendor Note" section). Scenario D is **still
  required** for parity with OAuth vendors but covers the analogous
  credential-rotation path Tock uses: static-API-key revocation event
  (vendor 401 response). The fixture deliberately uses a NON-vendor
  payload shape — it is not a Tock reservation; it is an **event
  description** the Phase 2 harness consumes to drive the adapter +
  framework's credential-rotation behavior.

## Sourcing context

Tock public reservation reference (auth section) +
`docs/integrations/tock/oauth_shape.md` (engineering's documented
keyPaste shape). The Phase 1 fixture corpus does not include a fake
"401 sandbox response" body — the harness drives the 401 via the
transport seam (`TockApiClient` fake throws a typed
`UnauthorizedException`); this fixture is the **expectation
documentation** for that lane.

## Sourcing gap

The Tock public reservation reference does NOT document the precise
401 response body shape. Engineering selected a generic
`{"error": "unauthorized", "message": "API key invalid or revoked"}`
shape per industry-typical conventions. The `8R.TC.live.sandbox`
slice will diff observed 401 body shape and the bounded fix lands
there — Phase 1 fixture corpus does not block on it.
