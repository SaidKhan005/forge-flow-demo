# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: `POST /api/v2/oauth/token` (assumed) per
  `docs/integrations/opentable/oauth_shape.md` "Refresh semantics".
  OAuth 2.0 token-response shape per RFC 6749 §5.1
  (<https://datatracker.ietf.org/doc/html/rfc6749#section-5.1>) —
  this is the universal OAuth response body shape OpenTable's
  partner-only Partner API is assumed to return.
- Notes: Adversarial scenario D for OpenTable carries a binding
  expectation distinct from broker-refresh-closure vendors: per the
  2026-05-08 post-hardening adapter audit
  (`docs/POST_HARDENING_FOLLOWUPS.md`, six non-broker-refresh
  vendors: ADP, Tock, Push Operations, **OpenTable**, SevenRooms,
  Agendrix), the OpenTable adapter's transport implementation handles
  OAuth refresh INTERNALLY rather than via the broker
  `oauth_refresh_cron`. Phase 2 harness asserts the adapter does NOT
  register a refresh closure with the broker; instead it observes the
  near-expiry condition through `OpenTableTransport.refresh` (declared
  at line 230 of `lib/integrations/reservation/opentable_reservation_adapter.dart`)
  and rotates inline. Refresh tokens are rotating per
  `oauth_shape.md` "Token lifetime" — old refresh token revoked on
  use; the new pair is persisted via the gateway credential surface.
- Adapter assertion (Phase 2): On a near-expiry token (55 minutes
  remaining), the adapter's transport-internal refresh fires; vendor
  returns the `token_response` shape; adapter persists the new
  access+refresh pair; the inflight API call retries once and
  succeeds with the rotated `Bearer ot-access-token-rotated-v2`. The
  broker's `oauth_refresh_cron` does NOT process this connection —
  Phase 2 harness asserts no broker refresh closure is registered for
  vendor `opentable`. Sink assertion: `vendor_credentials` row
  updated atomically (no torn write); the audit log records the
  rotation event with `actor_kind = adapter_internal`, not
  `oauth_refresh_cron`.
