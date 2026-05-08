# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: webhook subscription `order.finalized` — adversarial Scenario B (malformed payload).
- Notes:
  - Body deliberately violates every `documentedPerRevelV1` field-shape contract:
    - `order.id` missing entirely → `_canonicalize` returns null at the first guard.
    - `order.created_date` is an epoch number (Revel docs pin ISO 8601 UTC strings).
    - `order.updated_date` is not a parseable timestamp.
    - `order.final_total` is non-numeric and not parseable as `num`.
    - `order.number_of_people` is a string ("three") instead of int.
    - `order.closed` is a string instead of bool.
    - `establishment_id` is a string instead of int.
    - Unexpected nested `extra_unexpected_field` exercises the framework's malformed-payload defense (the adapter framework wraps DTO parsing in try/catch and drops the event with a single log row per V1 lean cut 2 — `parse_warnings` plumbing is banned).
  - Phase 2 adapter harness assertion: `RevelPosAdapter.handleWebhook` returns `HandleWebhookResult(recordsWritten: 0)`; `connector_sync_log` records the parse failure; no canonical fact written.
  - Adversarial set inherited from `docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`.
