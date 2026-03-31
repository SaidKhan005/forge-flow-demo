# POS Vendor Capability Profile

## Connector Role

Primary POS connector for the first live restaurant integration.

## Vendor Identity

| Field | Value |
| --- | --- |
| Vendor name | TBD — vendor selection has not been finalized |
| Source type | `pos` |

## Auth & Access

| Field | Value |
| --- | --- |
| Auth mode | Unknown / pending vendor selection |
| Sandbox availability | Unknown / pending vendor selection |
| Partner gating | Unknown — some POS vendors require partnership applications |

## Location Mapping

| Field | Value |
| --- | --- |
| Location lookup | Unknown / pending vendor selection |
| External location ID field | Unknown / pending vendor selection |
| Multi-location support needed | No — Phase 8 targets one restaurant/location |

## Historical Backfill

| Field | Value |
| --- | --- |
| Historical backfill support | Unknown / pending vendor selection |
| Backfill window limits | Unknown — app needs at least 60 days of closed-shift history |
| Backfill format | Unknown / pending vendor selection |

## Real-Time & Polling

| Field | Value |
| --- | --- |
| Webhook support | Unknown / pending vendor selection |
| Polling endpoints | Unknown / pending vendor selection |
| Watermark / cursor strategy | Unknown / pending vendor selection |
| Intraday sales availability | Unknown / pending vendor selection |

## Key Fields

| Field | Value |
| --- | --- |
| Business date ownership | POS is the source of sales truth for business date |
| Sales | Expected — core POS field |
| Covers / guest count | Unknown — availability varies by vendor and tier |
| Checks / tickets | Unknown / pending vendor selection |
| Voids / comps | Unknown — may not be exposed by all vendors |
| Revenue center / order channel | Unknown / pending vendor selection |

## Close / Finalization

| Field | Value |
| --- | --- |
| Explicit close/finalization signal | Unknown / pending vendor selection |
| Same-day vs next-day reconciliation | Unknown |
| Fallback close policy needed | Likely — app already has a close-policy evaluation path |

## Rate Limits

| Field | Value |
| --- | --- |
| Rate limit notes | Unknown / pending vendor selection |
| Partner-specific throttling | Unknown |

## Known Missing Fields

- Covers may not be reliably available from all POS systems. App already handles covers as a forecast-vs-actual variance; if POS covers are unreliable, the adapter must document the fallback.

## Fallback Plan

- If POS does not expose explicit covers, the app can fall back to check count or forecast covers with a documented accuracy trade-off.
- If POS does not expose explicit close/finalization, the app's close-policy evaluation path handles delayed finalization.

## Open Questions

1. Which POS vendor will be the first Phase 8 target?
2. Does the vendor require a partnership application or direct API key access?
3. Does the vendor reliably expose covers/guest count at the shift or daypart level?
4. Is intraday polling feasible within rate limits for live shift updates?

## Gate Impact

**Blocker: POS vendor selection is TBD.**

Until a specific vendor is selected and its capability profile is filled in, the POS connector cannot be implemented. The app-side canonical input model, import tracking, and adapter boundary are ready. The missing piece is vendor-specific transport and field mapping.
