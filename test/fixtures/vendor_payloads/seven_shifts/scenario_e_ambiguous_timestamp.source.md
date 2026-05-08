# Source

- URL: https://developers.7shifts.com/reference/listtimepunches
- URL (timestamp policy):
  `docs/integrations/seven_shifts/field_mapping.md` "Timestamp shapes"
  + `sevenShiftsTimestampPolicy` in
  `lib/integrations/labor/seven_shifts_labor_adapter.dart`
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: documented `time_punch.edited` envelope, timestamps
  stripped of explicit `Z` / offset
- Notes: adversarial Scenario E. The 7shifts v2 developer reference
  documents every timestamp as ISO 8601 with an explicit `Z`; an
  ambiguous shape (no `Z`, no offset) is exactly the vendor-side
  regression `AmbiguousTimestampConvention.refuse` is designed to
  catch. Silent fallback to "treat as UTC" is the bug Scenario E
  protects against — the adapter rejects at the parse boundary so
  the canonical fact never lands. Once `8.S.7S.live.sandbox`
  confirms observed sandbox payloads always carry `Z`, the policy
  re-binds to `asUtc` and this fixture would still fail (because
  the test asserts "refuse on documented ambiguity").
