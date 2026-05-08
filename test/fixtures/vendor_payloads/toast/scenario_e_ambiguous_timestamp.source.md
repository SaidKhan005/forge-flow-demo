# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08
- API version: `orders/v2`

## Notes

- Per `field_mapping.md#timestamp-shapes`, every Toast `openedDate`
  / `closedDate` / `modifiedDate` is documented as ISO 8601 UTC
  with the trailing `Z`. Toast does NOT document any code path
  that emits a timestamp without `Z` or offset.
- This fixture is **synthetic-adversarial**: timestamps stripped
  of the `Z` suffix to exercise the framework's refuse-by-default
  policy. The adapter declares `timestampPolicyDocId: 'toast'` so
  the framework recognizes the vendor; the `vendor_timestamp_policy.dart`
  registry's reject-on-ambiguous behavior MUST kick in.
- Per the binding policy from
  `phase_8_live_pos_labor_adapter_plan.md` Scenario E:
  "Adapter must declare the vendor's convention explicitly —
  treat as UTC, treat as location-local, or **reject as malformed**."
  Toast's declared convention is "UTC with `Z`"; absence of `Z`
  therefore **must reject**, never best-effort.
- `_sourcing_gap` top-level key is set per the prompt's instruction
  for scenarios that cannot be sourced from any public reference.

## Sourcing fallback

This fixture is the synthetic Scenario E mandated by the Phase 8
A-F binding set; the reject-on-ambiguous policy comes from
`field_mapping.md#timestamp-shapes` and the framework contract
documented in `phase_7_55_time_boundary_contract.md`.

## Expected adapter behavior

- Signature verifies (signature is over raw body bytes; the
  body's malformed timestamps don't affect signature validity).
- Sanity hook OR canonicalization step rejects the event:
  framework's timestamp parser refuses to consume a Toast-tagged
  timestamp without `Z`.
- `upsertOrderFact` is NOT called.
- Audit log records timestamp-resolution failure with
  `vendor_timestamp_policy: 'toast'` and
  `failure_reason: 'ambiguous_timestamp'`.
- No best-effort UTC interpretation. No best-effort location-local
  interpretation. The framework's refuse-by-default protection is
  the entire point of Scenario E.

## Phase 5 partner-portal escalation

Confirm with the Toast partner portal whether any documented
endpoint or webhook variant ever drops the `Z` suffix on Order
timestamps. If yes, the adapter's `vendor_timestamp_policy` entry
needs an explicit treatment rule; if confirmed-never, this
scenario remains a synthetic guardrail and can be deprecated.
