# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus delivery, eventType `aloha.check.modified`.
- Notes: Adversarial scenario B. Mutations from documented shape:
  (1) `numberOfGuests` is a string ("four") not an int — violates
  the documented `int` type at `numberOfGuests`.
  (2) `totalAmount` carries a `$` prefix — violates documented
  decimal-dollar `Number` shape.
  (3) `closedAt` is `"not-a-timestamp"` — fails ISO-8601 parse.
  Phase 2 harness asserts parser failure before signature
  verification path or any fact write. Strict reject (no
  best-effort coercion) per V1 lean cut 2 — no `parse_warnings`
  JSONB or `parse_partial` flag in V1.
