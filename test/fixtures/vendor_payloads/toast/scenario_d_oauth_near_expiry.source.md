# Source

- Primary URL: <https://doc.toasttab.com/doc/devguide/apiAuthenticationOverview.html>
- Retrieved: 2026-05-08
- API version: `authentication/v1` (login) + `orders/v2` (the body)

## Notes

- The Order body itself is well-formed and valid — Scenario D is
  about credential lifecycle, not payload validity.
- `_test_credential_state` is the test-side input the Phase 2 / 3
  harness asserts against:
  - `token_expires_at` is 5 minutes ahead of `now_at_receive`,
    inside the proactive-refresh window
    (`token_expires_at < now() + interval '24 hours'` per
    `oauth_shape.md#refresh-semantics`).
  - The Toast `client_credentials` flow returns a fresh access
    token on every login — there is NO refresh-token rotation;
    every refresh is a clean re-login at
    `POST /authentication/v1/authentication/login` with body
    `{clientId, clientSecret, userAccessType: "TOAST_MACHINE_CLIENT"}`.
  - `expected_refresh_grant.expected_response` shape mirrors
    Toast's documented login response (`token.accessToken`,
    `token.expiresIn`, `token.tokenType`).

## Sourcing fallback

Reconstructed from `docs/integrations/toast/oauth_shape.md`
sections "Flow type" and "Refresh semantics" + the existing
`oauth_refresh_cron.dart` cadence cited there.

## Expected refresh-worker behavior

1. `oauth_refresh_cron.dart` (5 minutes past every hour) scans
   `vendor_credentials` for tokens with
   `token_expires_at < now() + interval '24 hours'`.
2. Hits this row, runs the documented login exchange.
3. Mints a fresh access token (`<<TEST_BEARER_REFRESHED>>`).
4. Updates `vendor_credentials.token_expires_at = now + 86400s`.
5. The webhook delivery (this body) processes successfully on
   the next adapter call using the refreshed token.

## Expected adapter behavior on the webhook itself

- Signature verifies; sanity hook passes.
- `_canonicalize` produces canonical fact; `upsertOrderFact` writes
  one row.
- Crucially: any 401 from Toast (if the cron lost the race) MUST
  trigger reactive refresh per `oauth_shape.md` "Reactive refresh
  on 401" — adapter retries once after a fresh
  client_credentials exchange.
- Three consecutive failures flip connection to `error` (V1 lean
  cut 2: email notification deferred to `9.8.email`).

## No real secrets

- `<<TEST_CLIENT_ID>>`, `<<TEST_CLIENT_SECRET>>`,
  `<<TEST_BEARER_NEAR_EXPIRY>>`, `<<TEST_BEARER_REFRESHED>>`,
  `<<TEST_CLIENT_SECRET_KMS_REF>>` are literal placeholders.
  No live Toast credentials anywhere.
