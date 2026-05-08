# Source

- URL: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`); adapter constant
  `kLightspeedLskApiVersion = 'f-v2-2026-05'`.
- Endpoint: `GET /f/v2/business-location/{businessLocationId}/sales`
- Notes:
  - `nbCovers` field absent. The doc lists `nbCovers` as an optional
    number; counter-service / take-away orders frequently omit it.
    `dineIn = false` corresponds to take-away.
  - Adapter behavior: `_projectCanonicalRecord` reads
    `sale[LightspeedLskSaleFields.covers]` — when absent, the local
    `coversRaw` is `null`, the `if (coversRaw is num)` branch is
    skipped, and `covers` defaults to `0`. The canonical fact row is
    written with `covers = 0`.
  - Phase 2 harness assertion: covers MUST NOT be silently inferred.
    The metric-card honesty contract still flags this row's `covers`
    as `direct` source per `coversFieldExposed: true` on the
    capability profile — but the value is `0`. Operator chrome
    surfaces "0 covers" rather than "—" or a forecast fallback.
  - Sparse path also drops most documented fields the adapter
    ignores (`tableName`, `tableNumber`, `ownerName`, `ownerId`,
    `accountProfileCode`) to mirror minimal real-world shapes.
