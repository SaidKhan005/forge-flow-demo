# Source

- URL: https://developer.squareup.com/docs/oauth-api/refresh-revoke-limit-scope
- URL (Order shape): https://developer.squareup.com/reference/square/objects/Order
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- OAuth flow: Authorization Code grant with rotating refresh tokens
  (per `docs/integrations/square/oauth_shape.md`).

## Adversarial scenario

The payload is a normal Square Order webhook. The interesting state
is OUTSIDE the payload — it lives on the `vendor_credentials` row
backing this connection:

- `token_expires_at` = `2026-05-08T18:46:00Z`
- Test "now"      = `2026-05-08T18:45:30Z`
- Time-to-expiry  = **30 seconds**

Per `oauth_shape.md`:

- Proactive refresh cron scans for `token_expires_at < now() + 24h`
  every hour at 5min past — the next polling adapter call would
  fail with HTTP 401 if the refresh hadn't already happened.
- Reactive refresh on 401 retries once after rotating.

The adapter's polling worker MUST NOT issue a `SearchOrders` call
with a token that expires mid-flight. The OAuth refresh worker
holds an advisory lock on the credential row (deferred per V1 lean
cut 2 — `phase_8_live_pos_labor_adapter_plan.md` non-goals: "advisory
locks on OAuth refresh"); for V1 the contract is: the cron runs
proactively, and the adapter's reactive 401-retry handles the
narrow race where two callers contend.

## Phase 2 harness assertions

The fixture itself is the order body. The Phase 2 harness asserts:

1. Given a `vendor_credentials` row with
   `token_expires_at = now + 30s`, the OAuth refresh cron rotates
   FIRST.
2. After rotation, `vendor_credentials.access_token` differs from
   the pre-rotation value, and `token_expires_at` is now > `now() +
   24h`.
3. Square's `POST /oauth2/token` endpoint is called with
   `grant_type=refresh_token` (mocked in the harness — no live
   Square call).
4. The webhook payload (this fixture's body) is then processed
   normally; `factWriter.upsertSalesFact` is called once.
5. If the harness simulates the cron NOT having run (i.e., adapter
   issues a `SearchOrders` with expired token), the adapter
   receives 401, calls `apiClient.refreshOauthToken(...)` once,
   then retries the call successfully.
6. Three consecutive refresh failures flip the connection to
   `ConnectionStatus.error` per `oauth_shape.md`.

## Test placeholders

The harness uses literal placeholder values for any secret material:

- `<<TEST_BEARER>>` — pre-refresh access token
- `<<TEST_BEARER_ROTATED>>` — post-refresh access token
- `<<TEST_REFRESH_TOKEN>>` — pre-refresh refresh token
- `<<TEST_REFRESH_TOKEN_ROTATED>>` — post-refresh (rotated) refresh
  token

These are NEVER stored in a JSON fixture committed to the repo.
This `.source.md` documents them so Phase 2 harness authors know
the contract.

## Field-level edits

The order body shape is verbatim per Square's published Order
object reference, with placeholder identifiers and `CAD` currency.
