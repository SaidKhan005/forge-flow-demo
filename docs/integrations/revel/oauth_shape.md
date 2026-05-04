# Revel Systems — OAuth Shape

**Vendor ID**: `revel`
**Source documentation**: <https://developer.revelsystems.com/revelsystems/docs/webhooks>
(OAuth section linked from the developer portal's authentication
page; same retrieval root)
**Retrieval date**: 2026-05-03

---

## Flow type

`client_credentials` — server-to-server OAuth.

The operator issues a `client_id` + `client_secret` pair from their
Revel admin portal and pastes both into the F&F connect-flow modal.
There is no operator browser hop / authorization-code redirect; the
proxy mints the JWT bearer server-side. Cite vendor doc:
<https://developer.revelsystems.com/revelsystems/docs>.

Token endpoint:

```
POST https://authentication.revelup.com/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
client_id=...
client_secret=...
audience=https://api.revelsystems.com
```

---

## Scopes requested

Revel's `client_credentials` flow scopes capabilities at the
client-credential pair level (issued from the Revel admin portal),
not via OAuth scope strings on the token endpoint. The minimum-
privilege subset the F&F adapter requires:

| Capability | Unlocks | Required for |
|---|---|---|
| `external_integrations.read` | List integrations + read order history (`/external/integrations`, `/external/integrations/{id}`) | Backfill + polling |
| `webhooks.write` | Auto-register the `order.finalized` webhook | First-connect webhook setup |
| `webhooks.read` | List existing webhook subscriptions on reconnect | Reconnect / disconnect tear-down |
| `message_log.read` | Inspect recent webhook deliveries from F&F admin during `*.live` triage | Operational only — not load-bearing for V1 metrics |

Operators are instructed to issue credentials with these capabilities
only; the connect-flow help text in the Vendor Connections widget
will spell out the exact toggles to enable in the Revel admin portal
(`docs/_walkthroughs/8.RV.md` step 4).

Capabilities the F&F adapter does NOT request even though Revel
offers them:

- `customers.read` / `customers.write` — guest-PII surface; F&F
  doesn't persist guest data per the privacy contract.
- `payments.read` — PCI scope; F&F is not a payment processor.
- `inventory.write` / `menu.write` — F&F doesn't push into Revel.
- `timesheet.read` (on the POS surface) — labor data flows through
  the operator's scheduling vendor, not the POS.

---

## Token lifetime

| Token | TTL | Notes |
|---|---|---|
| Access token (JWT bearer) | 86,400 s = 24h (`oauth_access_ttl_seconds` per `documentedPerRevelV1`) | Revel does not issue a refresh token. A "refresh" is a fresh `client_credentials` exchange against the same `client_id` / `client_secret` pair. |
| Refresh token | n/a | Revel's `client_credentials` grant does not return one. |

---

## Refresh semantics

- **Proactive refresh**: the framework's hourly `pg_cron`
  refresh job (`lib/services/integration/oauth_refresh_cron.dart`)
  scans `vendor_credentials` for tokens with `token_expires_at <
  now() + 24h`. Revel tokens enter this window
  immediately on issue (24h TTL) so a fresh exchange happens every
  hour during normal operation. The refresh implementation is
  [RevelOAuthRefresher] in
  `lib/integrations/pos/revel_pos_adapter.dart`.
- **Reactive refresh on 401**: not needed in V1 — the proactive
  cadence keeps tokens fresh. If observed in `*.live.*` runs, the
  bounded fix is a single retry-after-refresh on `RevelTransport`'s
  internal HTTP client. No advisory locks (banned per V1 lean cut 2).
- **3 consecutive failures**: the framework's runner flips
  `connector_connection.status = 'error'`, writes an audit row, and
  the operator sees the state in the admin widget. Email
  notification deferred to `9.8.email` follow-up per V1 lean cut 2.
- **Rotating vs sliding**: n/a — `client_credentials` issues a
  fresh JWT bearer on every exchange; there is no rolling refresh
  token to rotate.
- **Revocation**: Revel's docs do not expose a public revoke
  endpoint at the credential level; revocation happens by deleting
  the credential pair from the operator's Revel admin portal.
  F&F's disconnect tear-down wipes the ciphertext from
  `vendor_credentials` and unregisters the webhook subscription.

---

## Per-location vs operator-wide grant

`perLocation` (matches `VendorCapabilityProfile.grantScope`).

Each F&F location's Revel connection is a separate `client_id` /
`client_secret` pair issued from a separate Revel-side establishment.
Multi-location operators connect each location independently because
Revel scopes each `client_credentials` grant to a single
establishment. The connect flow renders a vendor picker per location
in the Vendor Connections widget; the `*.live.prod` slice will
verify cross-location isolation against the operator's actual
establishment list.

---

## Module disambiguation

N/A — single module. (Module disambiguation is reserved for ADP
[Workforce Now / Workforce Manager / RUN] and QuickBooks
[Time / Online / Payroll]; see `docs/phases/phase_8/vendor_master_list.md`.)

---

## Edge cases

- **Refresh exchange returns 401** (credentials revoked from Revel
  admin portal): `RevelOAuthRefresher` returns
  `VendorRefreshOutcome.failure`. After three consecutive failures
  the framework flips connection status to `error`. Operator-facing
  copy: "Your Revel connection lost authentication. Reconnect from
  the Vendor Connections card." Email alert deferred to
  `9.8.email`.
- **Refresh exchange times out**: same path as 401 — the framework
  treats the failure as a refresh failure and counts toward the
  3-strike threshold.
- **`audience` parameter mismatch**: the adapter pins
  `audience: https://api.revelsystems.com` per
  `documentedPerRevelV1.api_base_url`. If Revel ever adds a
  separate audience for a sandbox environment, the `*.live.sandbox`
  slice picks it up in the `live_verification_checklist.md` field-
  mapping diff.
- **Account deletion / dormant client_id**: same observable as a
  permanent 401 — the cron flips status to `error`.
- **Scope downgrade**: if an operator's Revel admin removes a
  capability mid-connection, the next data-fetching call returns
  403; the adapter logs it via `connector_sync_log` and the operator
  sees a degraded card in the Vendor Connections widget.
