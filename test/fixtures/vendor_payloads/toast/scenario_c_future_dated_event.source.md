# Source

- Primary URL: <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>
- Retrieved: 2026-05-08
- API version: `orders/v2`

## Notes

- `_test_now_at_receive` is the test-side wall clock injected via
  the adapter's `now` hook (`ToastPosAdapter`'s constructor accepts
  `DateTime Function()? now`). When tests evaluate the sanity hook,
  current time = `2026-05-04T20:00:00Z`.
- `closedDate`, `modifiedDate`, `openedDate` are set ~24h in the
  future relative to `_test_now_at_receive`. The framework's sanity
  rule rejects timestamps after `now() + tolerance` (per the
  Phase 8 sanity contract referenced from
  `lib/services/integration/integration_adapter_common.dart`).
- This is the same trip-wire exercised by the existing
  `toastBackfillPage2Orders()['p2-order-future']` fixture in
  `test/integrations/pos/fixtures/toast_orders_fixture.dart`,
  promoted to its own pressure-corpus scenario for symmetry with
  other vendors.
- `_event_envelope.toast-webhook-timestamp` (1778098200) ≈
  `2026-05-05T20:10:00Z` — also in the future relative to test
  receive time.

## Sourcing fallback

Reconstructed from `toast_orders_fixture.dart` (the existing
`p2-order-future` shape) and the framework's documented sanity-rule
behavior in `phase_8_live_pos_labor_adapter_plan.md`.

## Expected adapter behavior

- Signature verifies.
- Sanity hook (`isDeliberateBackfill: false` on the webhook path)
  rejects the future-dated event: `command.sanityHook` returns
  false.
- `_canonicalize` may run, but `upsertOrderFact` is NOT called
  because the framework drops the event before the write step.
- Audit log records sanity-rule violation
  (`future_dated_event` reason).
- Or, per Phase 8 Hard Promise, may quarantine to a
  `*_quarantine` row instead of outright rejection — both outcomes
  satisfy "no canonical fact written".
