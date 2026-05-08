# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: webhook subscription `order.finalized` — adversarial Scenario E (ambiguous timestamp).
- Notes:
  - Vendor docs pin ISO 8601 UTC for `created_date` / `updated_date` (with the trailing `Z`). Per `docs/integrations/revel/field_mapping.md` "Timestamp shapes":
    > "If the sandbox surface ever emits location-local timestamps with no offset, the adapter REFUSES the event at parse time (drops with `connector_sync_log.event_kind = parse_error`); it does NOT silently re-interpret."
  - The fixture uses a SQL-style naive timestamp (`2026-05-02 19:31:00`, no `T`, no `Z`, no offset). On ambiguous form, the adapter rejects rather than best-efforts: assuming UTC silently mis-buckets the operator's day; assuming local time is unsafe without an IANA hint.
  - Note: the Phase 7.55 time-boundary contract bans `TIMESTAMP WITHOUT TIME ZONE` in operator-scoped tables; the adapter REFUSES upstream events that present this shape so the contract is not violated downstream.
  - Phase 2 adapter harness assertion: signature passes, framework dispatches, `_canonicalize` returns null because `_parseUtc` cannot resolve the timestamp deterministically; `connector_sync_log.event_kind = parse_error`; no canonical fact written.
  - Adversarial set inherited from `docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`.
