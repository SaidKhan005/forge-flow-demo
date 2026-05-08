# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: webhook subscription `order.finalized` — adversarial Scenario C (future-dated event).
- Notes:
  - Reference body: `revelFutureDatedOrder` constant in `test/integrations/pos/fixtures/revel_orders_fixture.dart` (the engineering-slice fixture pins this exact future-dated row at retrieval date 2026-05-03; see comment "Reads as 30 days into the future relative to `nowFixed` in the adapter test harness").
  - With harness `now` anchored at 2026-05-08, `created_date: 2026-06-15T12:00:00Z` is ~38 days in the future and trips `VendorTimestampSanity` rule "opened_in_future" (`opened_at <= now() + 1 hour`).
  - Phase 2 adapter harness assertion: signature passes; framework dispatches; `command.sanityHook` returns false; `RevelPosAdapter.handleWebhook` skips the canonical write; `PollIncrementalResult.sanityDropped` count increments via the polling path; `connector_sync_log.event_kind = sanity_drop`.
  - Per `docs/contracts/vendor_adapter_slice_contract.md`, the framework cannot inspect adapter writes; the sanity hook is the ONLY enforcement point. A missed call would silently ship future-dated facts to the operator dashboard.
