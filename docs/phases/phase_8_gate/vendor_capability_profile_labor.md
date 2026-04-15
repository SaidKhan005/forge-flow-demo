# Labor Vendor Capability Profile

## Connector Role

Primary labor/timekeeping connector for the first live restaurant integration.

## Vendor Identity

| Field | Value |
| --- | --- |
| Vendor name | TBD â€” vendor selection has not been finalized |
| Source type | `labor` |

## Auth & Access

| Field | Value |
| --- | --- |
| Auth mode | Unknown / pending vendor selection |
| Sandbox availability | Unknown / pending vendor selection |
| Partner gating | Unknown â€” some labor platforms require partnership applications |

## Location Mapping

| Field | Value |
| --- | --- |
| Location lookup | Unknown / pending vendor selection |
| External location ID field | Unknown / pending vendor selection |
| Multi-location support needed | No â€” Phase 8 targets one restaurant/location |

## Historical Data

| Field | Value |
| --- | --- |
| Historical actual-hours support | Unknown / pending vendor selection |
| Approved/finalized-hours support | Unknown / pending vendor selection |
| Historical window limits | Unknown â€” app needs at least 60 days |

## Schedule & Forecast

| Field | Value |
| --- | --- |
| Schedule availability | Unknown / pending vendor selection |
| Forecast availability | Unknown / pending vendor selection |
| Schedule granularity | Unknown â€” app needs shift/daypart-level hours |

## Real-Time & Polling

| Field | Value |
| --- | --- |
| Punch / intraday labor updates | Unknown / pending vendor selection |
| Webhook support | Unknown / pending vendor selection |
| Polling strategy | Unknown / pending vendor selection |
| Watermark / cursor strategy | Unknown / pending vendor selection |

## Key Fields

| Field | Value |
| --- | --- |
| Actual worked hours | Expected â€” core labor field |
| Scheduled hours | Unknown â€” availability varies by vendor |
| Overtime state | Unknown / pending vendor selection |
| Labor dollars | Unknown â€” some vendors expose dollars, others only hours |
| Job / role assignments | Unknown / pending vendor selection |

## Close / Finalization

| Field | Value |
| --- | --- |
| Explicit finalized-hours signal | Unknown / pending vendor selection |
| Approved-hours workflow | Unknown / pending vendor selection |
| Same-day vs delayed finalization | Unknown |
| Fallback close policy needed | Likely â€” app already has a close-policy path |

## Rate Limits

| Field | Value |
| --- | --- |
| Rate limit notes | Unknown / pending vendor selection |
| Partner-specific throttling | Unknown |

## Known Missing Fields

- Labor dollars may not be directly exposed. If only hours are available at close time, the app can use the restaurant's sanctioned configured/target wage seam so close-time operations and comparisons can still run.
- Overtime state may not be available from all vendors.

## Fallback Plan

- If labor system does not expose explicit dollars at close time, the current app contract allows the close path to resolve labor dollars from the sanctioned wage seam when the restaurant must keep operating despite vendor limits.
- If the vendor later exposes richer finalized labor dollars or approved-hours truth after close, add explicit sync/reconciliation handlers around close, approval, payroll-close, and other relevant boundary events instead of assuming the first ingest is final forever.
- If labor system does not expose explicit finalized-hours signal, the app's close-policy evaluation path handles delayed finalization.
- If schedule data is not available from the labor system, the app can accept schedule as a manual or POS-side input.

## Open Questions

1. Which labor vendor will be the first Phase 8 target?
2. Does the vendor expose both scheduled and actual hours at shift/daypart granularity?
3. Does the vendor expose labor dollars directly, or only hours?
4. Is there an approved-hours workflow that provides a clean finalization signal?

## Live-Data Capability Audit (7.55n.12)

A vendor-by-vendor live-data capability audit has been completed using
official vendor documentation. See:

- `docs/phases/phase_8_gate/vendor_live_data_capability_matrix.md`
- `docs/archive/phases/7_55n/phase_7_55n_12_vendor_live_data_capability_audit.md`

Key finding: 7shifts is the strongest labor candidate â€” it is the only
one with an explicit finalized-hours signal (`approved` boolean +
`payroll_period.closed` webhook), per-punch wage data, and cursor-based
incremental sync with `modified_since` support.

## Gate Impact

**Blocker: Labor vendor selection is TBD.**

Until a specific vendor is selected and its capability profile is filled in, the labor connector cannot be implemented. The app-side canonical input model and import tracking are ready. The missing piece is vendor-specific transport and field mapping.
