# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: N/A — Aloha (NCR Voyix) employee punch is NOT in V1
  adapter scope.
- Sourcing gap: `_sourcing_gap` field on the JSON marks this
  scenario as not-implemented for Aloha. Phase 1 task description
  marks employee punch as "if exposed" — for Aloha (NCR Voyix) it
  is not exposed via the V1 adapter scopes. The adapter only
  requests `aloha:checks.read` and `aloha:sites.read` per
  `oauth_shape.md`.
- Phase 2 harness behavior: skip this fixture for Aloha; do not
  treat it as a regression. The fixture is preserved for shape
  symmetry with vendors where employee punch IS exposed
  (e.g., labor vendors `quickbooks_time`, `seven_shifts`).
- Partner-portal escalation: when Aloha Workforce API access is
  granted (separate per-API access request), this fixture should
  be replaced with the documented punch shape. Until then the
  `_sourcing_gap` marker is the source of truth.
