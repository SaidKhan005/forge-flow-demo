# Source

- URL: https://api.exploretock.com/docs/latest/reservation.html
- Retrieved: 2026-05-08
- API version pinned: `reservation_2026_05_03`
- Reference: `docs/integrations/tock/field_mapping.md` (Timestamp
  shapes section — `serviceDateTimestamp` and `lastUpdatedTimestamp`
  are documented as ISO-8601 with trailing `Z` / UTC)
- Reference: `docs/contracts/phase_7_55_time_boundary_contract.md`
  (refuse-by-default protection for unregistered vendor timestamp
  policies)
- Notes: `lastUpdatedTimestamp` and `serviceDateTimestamp` are
  formatted **without** the trailing `Z` and **without** an explicit
  offset (`2026-11-01T01:30:00`). Per Tock's documented schema they
  MUST carry the `Z`. The 2026-11-01 01:30 wall time is also the
  classic ambiguous moment in US/Eastern fall-back DST: 01:30
  America/New_York occurs twice on that date (once in EDT, once in
  EST). The framework's vendor timestamp policy resolver MUST refuse
  to best-effort interpret this; the canonical fact must NOT be
  written. Adapter assertion: timestamp parser raises (or sanity hook
  rejects); no DB write.
- The `vendor_timestamp_policy.dart` registry currently lacks a
  `'tock'` entry (per `docs/integrations/tock/field_mapping.md`
  Engineering-vs-framework boundary note); the
  `8R.TC.live.sandbox` slice will land the registry entry. Until then,
  the framework's refuse-by-default protection treats Tock as a
  registered vendor (the adapter declares
  `timestampPolicyDocId: 'tock'`) and rejects ambiguous wall-clock
  strings.

## Sourcing context

Public reservation reference + framework time-boundary contract. No
live HTTP calls.
