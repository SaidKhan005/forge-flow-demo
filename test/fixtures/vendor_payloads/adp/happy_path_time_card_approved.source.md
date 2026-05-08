# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed` (Team Time Cards v2 / Time Events v2)
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`
  (action = `approved`); same row also returned by
  `GET /time/v2/workers/{associate_oid}/team-time-cards`
- Notes: re-emits the same `time_event.id` as the prior `submitted`
  delivery, with `last_modified_date_time` advanced to the approval
  moment. The adapter idempotency UNIQUE on
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  treats this as a deliberate update — newest `vendor_modified_at`
  wins per `docs/contracts/vendor_adapter_slice_contract.md`. The
  `approval` block is documented as ignored by the canonicalizer
  (PII-adjacent approver oid not consumed) — listed here so live
  sandbox slice can confirm whether the field is present in
  observed payloads. Partner-only sourcing — see
  `docs/integrations/adp/partnership_status.md`.
