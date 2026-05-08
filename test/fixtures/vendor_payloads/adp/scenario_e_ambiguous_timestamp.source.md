# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed`
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`
- Notes: ambiguous-timestamp scenario for binding E. Timestamps are
  ISO-8601-shaped but lack an explicit `Z` or numeric offset. ADP's
  documented samples carry the `Z` (per
  `docs/integrations/adp/field_mapping.md` "Timestamp shapes") but
  until the live sandbox slice confirms the partner-doc rule,
  `adpTimestampPolicy` (in
  `lib/integrations/labor/adp_labor_adapter.dart`) declares
  `AmbiguousTimestampConvention.refuse`. The Phase 2 harness MUST
  assert the framework's vendor timestamp sanity guard rejects
  these rows — silent fallback to "treat as UTC" is exactly the
  bug `vendor_timestamp_sanity.dart` Scenario E is designed to
  catch. Partner-only sourcing.
