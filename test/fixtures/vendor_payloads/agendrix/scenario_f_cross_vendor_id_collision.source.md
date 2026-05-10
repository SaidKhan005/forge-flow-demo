# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: Cross-vendor namespace fixture. The shared opaque-string value
  `te_412901` is presumed to also exist as a `time_punches[].id` on a
  separate connected vendor (7shifts) for the same operator+location
  pair (see `_collision_setup.foreign_row_namespace`). The Phase 2
  adapter harness pre-loads a 7shifts canonical row at
  `(vendor_id = 'seven_shifts', operator_id, vendor_entity_id =
  'te_412901', vendor_modified_at = …)` and then replays this Agendrix
  fixture.

  Documented contract from `field_mapping.md`:

    > "Cross-vendor employee reconciliation — explicit non-goal at V1
    >  per `phase_8S_scheduling_connector_plan.md`. Agendrix `user_id`
    >  is treated as a within-vendor namespace."

  And from `vendor_adapter_slice_contract.md` (idempotency UNIQUE):
  the canonical labor-fact UNIQUE is
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`,
  i.e. `vendor_id` is part of the key. Two rows with the same
  string `vendor_entity_id` but different `vendor_id` are two
  distinct canonical rows by construction.

  Phase 2 assertion: the Agendrix adapter writes a canonical row with
  `vendor_id = 'agendrix'`; the pre-existing 7shifts row at
  `vendor_id = 'seven_shifts'` is NOT overwritten; both rows coexist.
  No shadow-write across vendors.
