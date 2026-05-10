# Source

- URL: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`); adapter constant
  `kLightspeedLskApiVersion = 'f-v2-2026-05'`.
- Endpoint: `GET /f/v2/business-location/{businessLocationId}/sales`
- Notes:
  - Voided sale shape per the published doc: `cancelled: true` at
    sale level, plus a sale-level `voidReason` and a
    `salesLines[].voidReason`. Both fields appear verbatim in the
    documented 200 example.
  - `payments` is empty array — voided sale never collected payment.
    The adapter sums `payments[].netAmountWithTax` to compute
    `actual_sales`; this fixture forces `actual_sales = 0.0`.
  - Adapter today does NOT special-case `cancelled = true`; the void
    still writes a canonical row with zero sales. Phase 2 harness
    must assert this — voided sales should NOT inflate dashboard
    cover counts. The follow-up review will decide whether `cancelled`
    should suppress the canonical write or write a negation row.
