# Humanity (TCP) — OAuth Shape

**Vendor ID**: `humanity`
**Source documentation**: <https://platform.humanity.com/v1.0>
**Retrieval date**: 2026-05-04

> Humanity v1's connect path is documented end-to-end in
> `api_consumed.md`. This file consolidates the OAuth-shape view that
> the cross-vendor refresh-worker doc-pack expects, including the
> broker-delegation decision recorded against the Phase 5 pressure-
> preview findings (P1 closure-registry mismatches).

---

## Flow type

`password` grant (OAuth 2.0 Resource Owner Password Credentials) —
operator pastes their Humanity account email + password into the
F&F connect modal; the proxy POSTs them to
`POST https://platform.humanity.com/v1.0/oauth2/token` with
`grant_type=password` server-side and persists the issued bearer in
`vendor_credentials` (pgcrypto envelope).

There is no authorization-code redirect flow. There is no developer
partnership program for v1 — any operator with an active Humanity
account can connect by pasting their existing credentials.

The capability profile pins `authMode = VendorAuthMode.keyPaste`.
Connect-flow UI consumers (`vendor_connections_widget.dart`,
`operator_web_vendor_connections_gateway.dart`) branch on this exact
value to render the username/password modal — flipping to `oauth`
without a v2 partner program would break the connect path.

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token (bearer) | not publicly documented; observe in `*.live.sandbox` | Resolved at every poll; no `expires_in` claim guaranteed in the response. |
| Refresh token | issued by the password-grant response when present, but the v1 connect path does NOT exercise broker-driven refresh — see "Refresh handling" below. |

---

## Refresh handling (broker delegation — DECIDED 2026-05-09)

The cross-tenant OAuth refresh worker
(`tool/oauth_refresh_worker/main.dart`) does NOT carry a refresh
closure for Humanity. Decision rationale (Phase 5 finding inverse
mismatch resolution):

The Humanity adapter declares `capabilityProfile.authMode =
VendorAuthMode.keyPaste`. The connect flow uses the legacy
`password` grant; the issued bearer is treated as session-bound to
the operator's Humanity account. F&F's v1 path does not currently
drive a broker-side `refresh_token` rotation — when the bearer
expires the operator reconnects through the keyPaste modal.

Behavior at runtime:

- When the worker claims a near-expiry Humanity row, the row is
  log-and-skipped with the structured reason
  `humanity_keypaste_password_grant_no_broker_refresh` (see
  `kVendorsWithoutRefreshClosureReason` in
  `tool/oauth_refresh_worker/main.dart`). No failure-count
  increment, no auto-disable.
- The closure factory `makeHumanityOauthRefreshClosure` remains
  exported in
  `lib/integrations/_common/production_oauth_refresh_closures.dart`
  with unit-test coverage so a future Humanity v2 partnership
  program (which Humanity might ship as `oauthOrKeyPaste`) can
  re-wire the registry without an API change.

This is the inverse of the Phase 5 P1 mismatch (the prior state had a
closure wired but the adapter declared `keyPaste`); the resolved
state has the no-closure registry entry agreeing with the adapter's
keyPaste declaration.

---

## Per-location vs operator-wide grant

`operatorWide` — one Humanity account spans an operator's locations
on the company plan; a single credential covers all. Match
`VendorCapabilityProfile.grantScope = VendorGrantScope.operatorWide`.

---

## Edge cases

- **Bearer expiry / vendor session timeout**: outbound request 401 →
  adapter surfaces a connection error → operator reconnects through
  the keyPaste modal.
- **Account deletion / password change upstream**: same path as
  bearer expiry — 401 surfaces as a reconnect prompt.
- **3 consecutive auth failures on the read path**: connection flips
  to `error` per the adapter's standard auth-failure handling. The
  cross-vendor refresh worker does not contribute to this counter
  for Humanity — its claims are log-and-skipped.

See `api_consumed.md` for the full v1 endpoint inventory and field
mapping.
