# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/shifts (corrupt response with ambiguous timestamps)
- Notes: Per `field_mapping.md` ALL three documented timestamps
  (`start_at`, `end_at`, `updated_at`) are "ISO 8601 UTC (with
  explicit Z)" and the timestamp policy is `push_operations.asUtc`.
  The `_parseUtcInstant` helper in
  `lib/integrations/labor/push_operations_labor_adapter.dart`
  documents (lines 506-519): "Per push_operations timestamp policy:
  ISO-8601 with explicit `Z` is the documented shape. The adapter
  does not silently fall back when `Z` is missing — that
  ambiguous-shape case is the Scenario E boundary captured by the
  policy and verified at sandbox time."

  This fixture omits the `Z` suffix and any explicit offset on every
  timestamp field. The expected adapter behaviour is **REJECT**, not
  best-effort. The Phase 2A harness asserts:
  1. `DateTime.parse(...).toUtc()` parses the ambiguous string but
     produces a `DateTime` with `isUtc == false` (parser treats
     no-tz as local).
  2. The adapter MUST detect this and refuse the row, OR the
     timestamp policy validator at the framework layer rejects it
     before the canonical write.
  3. No canonical fact is written.
  4. A `connector_sync_log` row with `event_kind =
     'timestamp_policy_violation'` is appended.

  The 2026-01-01T02:30:00 boundary is intentional: in
  `America/New_York` this would land in the DST gap on a different
  date, and in `America/Vancouver` it is in the Pacific overnight
  window — the policy MUST refuse rather than guess which.
