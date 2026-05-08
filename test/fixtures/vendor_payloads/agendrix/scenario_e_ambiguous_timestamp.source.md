# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: Adversarial fixture for the documented `agendrix.asUtc`
  timestamp policy from `field_mapping.md` ("Timestamp shapes" table)
  and the adapter source comment in
  `agendrix_labor_adapter.dart` `_parseUtcInstant`:

    > "Per `agendrix.asUtc` timestamp policy: ISO-8601 with explicit `Z`
    >  is the documented shape. The adapter does not silently fall back
    >  when `Z` is missing — that ambiguous-shape case is the Scenario
    >  E boundary captured by the policy and verified at sandbox time."

  All three timestamp fields here are missing the `Z` suffix and have
  no offset — they are local-naive ISO-8601 strings the timestamp
  resolver cannot disambiguate (UTC? Montreal local? Vancouver local?
  the location-bound IANA zone? the company-bound zone?). The policy
  REJECTS such rows rather than best-effort guessing.

  Note: `DateTime.parse('2026-05-02T15:00:00')` actually succeeds on
  the Dart VM and returns a local-naive `DateTime`; the rejection
  therefore lands at the policy boundary (sanity hook /
  `vendor_timestamp_policy` lookup), not at the parser. Phase 2
  adapter harness asserts: parse succeeds, sanity hook returns false
  with reason `ambiguous_timestamp_no_offset`, canonical write is
  skipped, `connector_sync_log` records the drop.
