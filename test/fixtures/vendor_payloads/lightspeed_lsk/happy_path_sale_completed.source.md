# Source

- URL: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`); adapter constant
  `kLightspeedLskApiVersion = 'f-v2-2026-05'`.
- Endpoint: `GET /f/v2/business-location/{businessLocationId}/sales`
- Notes:
  - Verbatim from the documented "200 OK" example payload on the
    Get Sales reference page. The published `sales[0]` example carries
    `accountFiscId = "A65315.17"`, `nbCovers = 2.0`,
    `payments[0].netAmountWithTax = "11.00"`, `timeOfOpening` /
    `timeClosed` UTC ISO-8601 with `Z`. All preserved.
  - Documented example mixes a 2023-02-14 sale envelope with a
    2023-07-27 `salesLines[].timeOfSale`. Kept verbatim — that's
    Lightspeed's published example.
  - Top-level keys sorted alphabetically; sale object keys sorted
    alphabetically per repo style.
  - `nextPageToken` set to `null` (single-page response). The doc shows
    `"string"` as a placeholder; we use `null` to denote
    end-of-pagination, which is the documented sentinel for last page.
