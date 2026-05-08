# Source

- URL: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`); adapter constant
  `kLightspeedLskApiVersion = 'f-v2-2026-05'`.
- Endpoint: `GET /f/v2/business-location/{businessLocationId}/sales`
  (filtered to a `payment.SUCCESS` event re-poll window)
- Notes:
  - Field paths and types match the published Get Sales 200 example
    (same shape used for the payments-side adapter pull). Names
    carried verbatim from the documented `payments[]` shape:
    `code`, `currency`, `netAmountWithTax`, `tip`, `paymentMethodId`,
    `fiscId`, `uuid`, `staffId`, `revenueCenterId`, etc.
  - This fixture exercises the `payment.SUCCESS` re-poll path: a sale
    that opened earlier (`timeOfOpening = 19:14Z`) closes at
    `20:35Z` after card payment authorization. Adapter must update
    `vendor_modified_at = max(timeOfOpening, timeClosed) = 20:35Z`.
  - `tip = "12.50"` is non-zero; the adapter ignores the tip field
    today (per `field_mapping.md`, `actual_sales` sums
    `payments[].netAmountWithTax` only) — fixture preserves it as
    documented.
