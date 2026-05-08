# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: Documented sparse case — `position` is `null` on a punch where
  the operator has not yet assigned a role to the user. Adapter
  `_mapTimeEntryToCanonical` reads `position.name` only when `position`
  is a `Map`; null position yields `role_name = null`, which is the
  documented behavior captured in `field_mapping.md` (Ambiguity calls —
  `position` shape). Canonical write must still succeed (role is
  nullable in the labor fact schema); covers/wage classification rows
  are unchanged.
