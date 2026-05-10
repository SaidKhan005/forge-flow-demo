# Source

- URL: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
  (timestamp shape — `timeOfOpening` and `timeClosed` documented as
  ISO-8601 with `Z`, UTC instant)
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`); adapter constant
  `kLightspeedLskApiVersion = 'f-v2-2026-05'`.
- Endpoint: inbound webhook delivery (`POST <fnf-webhook-url>`),
  event `order.DELIVERED`.
- Notes:
  - Both `timeOfOpening` and `timeClosed` carry no `Z` suffix and no
    explicit timezone offset. Per
    `docs/integrations/lightspeed_lsk/field_mapping.md` Timestamp
    shapes, K-Series timestamps SHOULD always carry `Z`; the doc
    notes "some endpoints occasionally drop the trailing `Z`" but
    the framework's `vendor_timestamp_policy.lightspeed_lsk.asUtc`
    declares ambiguous parses must NOT silently coerce.
  - Adapter behavior in `_projectCanonicalRecord`:
    `DateTime.tryParse(openedRaw)` will succeed in Dart on a naive
    string (parsed as local time on the runtime), then `.toUtc()`
    converts. **THIS IS THE FOUND HOLE.** The current adapter does
    NOT honor the `asUtc` rejection policy — it silently coerces.
    Phase 2 harness MUST assert this is rejected; if not, file a
    finding for Phase 5 consolidation.
  - The expected resolution path is for the adapter (or an
    upstream parse helper) to consult
    `lib/services/integration/vendor_timestamp_policy.dart` and
    reject when the policy is `asUtc` and the parsed value carries
    `isUtc == false`.
- Expected outcome (per contract): record rejected, NOT written.
  The fixture exists specifically to detect the silent-coerce bug.
