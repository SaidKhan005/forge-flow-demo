# Vendor Payload Fixtures — Pressure Preview v1

Sprint: `pressure.preview.v1` Phase 1.

This directory holds verbatim vendor-documented payload fixtures for the
17 vendors covered by Phase 8 / 8R. Phase 1 of the pressure-test sprint
fills each subdirectory; Phases 2-3 consume them as input to the
adapter/sink/spine/mobile-sync harnesses and the load harnesses.

The plan doc lives at
`docs/_execution/2026-05-08_pressure_preview_v1_plan.md`.

## Directory Layout

```
vendor_payloads/
  README.md                     <- this file
  <vendor>/
    README.md                   <- per-vendor scenario index + outcomes
    <scenario>.json             <- verbatim vendor payload shape
    <scenario>.source.md        <- source URL, retrieval date, notes
    ...
```

Vendor directory names match the existing `docs/integrations/<vendor>/`
directory names so cross-references stay mechanical:

- POS (7): `lightspeed_lsk`, `toast`, `clover`,
  `oracle_micros_simphony`, `aloha_ncr_voyix`, `revel`, `square`
- Reservation (4): `libro`, `tock`, `opentable`, `sevenrooms`
- Labor (6): `quickbooks_time`, `adp`, `seven_shifts`, `humanity`,
  `agendrix`, `push_operations`

## Fixture Format

One JSON file per scenario. Each JSON file is the vendor's documented
payload shape — taken verbatim from public vendor docs, not synthesized,
not paraphrased. Field names, casing, nesting, and value types must
match exactly what the vendor's published documentation shows.

For each `<scenario>.json`, a sibling `<scenario>.source.md` cites the
exact source URL the payload was taken from, the retrieval date, and
any notes on which API version / endpoint the payload belongs to.
Example shape for the `.source.md`:

```
# Source

- URL: https://developer.example.com/api/webhooks/order-created
- Retrieved: 2026-05-08
- API version: v3 / 2024-09-15
- Endpoint: POST /v3/webhooks (event: order.created)
- Notes: payload trimmed to fields the adapter consumes; original
  upstream includes additional analytics fields not relevant here.
```

## Required Scenario Set Per Vendor

Every vendor directory must cover the following scenarios. The first
six (A-F) are the binding adversarial set inherited from
`docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`.

| Scenario | Filename | Outcome |
|---|---|---|
| A — forged signature | `scenario_a_forged_signature.json` | Reject (signature verification fails) |
| B — malformed payload | `scenario_b_malformed_payload.json` | Reject (schema/parse failure) |
| C — future-dated event | `scenario_c_future_dated_event.json` | Reject (timestamp guard) |
| D — OAuth near-expiry token | `scenario_d_oauth_near_expiry.json` | Refresh path triggers (OAuth vendors) / N/A (non-OAuth — see below) |
| E — ambiguous timestamp | `scenario_e_ambiguous_timestamp.json` | Reject (timezone resolution fails — must reject, not best-effort) |
| F — cross-vendor ID collision | `scenario_f_cross_vendor_id_collision.json` | Reject (idempotency-key namespace prevents shadow-write) |

Plus, per vendor:

- **2-4 happy/sparse path payloads** — typical day-to-day payloads
  named `happy_path_<event>.json` (e.g. `happy_path_shift_close.json`,
  `happy_path_walk_in_seated.json`, `sparse_path_zero_sales.json`).
- **1 DST edge** — `scenario_dst_spring_forward.json` (the 2026-03-08
  US spring-forward window or the equivalent fall-back for the vendor's
  primary deployment region).
- **1 cross-timezone** — `scenario_cross_timezone.json` — payload that
  combines a Vancouver-local `business_date` with a UTC timestamp from
  a different region (forces the resolver to choose).

## Non-OAuth Vendor Note

Six of the 17 vendors do not run OAuth refresh closures (per the
2026-05-08 confirmed-clean note in `docs/POST_HARDENING_FOLLOWUPS.md`):

- ADP — mTLS
- Tock — static key
- Push Operations — bearer
- OpenTable — internal
- SevenRooms — transport
- Agendrix — static key

For these vendors, scenario D (`scenario_d_oauth_near_expiry.json`) is
**still required** but covers the analogous credential-rotation path
the vendor uses (mTLS cert near-expiry, static-key rotation event,
etc.). Document the substitute in the per-vendor README so Phase 2
harnesses know what to assert.

## Per-Vendor README Format

Each `<vendor>/README.md` lists every scenario and the assertion the
Phase 2 harness must enforce. Example skeleton:

```
# <Vendor> Pressure Fixtures

Sources: <links to docs/integrations/<vendor>/ and the vendor's public docs>
Adapter: lib/integrations/<vendor>/<vendor>_adapter.dart
Sink:    lib/integrations/<vendor>/<vendor>_pos_postgres_sink.dart

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| scenario_a_forged_signature.json | reject | _verifySignature throws SignatureMismatch | no DB write |
| scenario_b_malformed_payload.json | reject | parser throws PayloadParseError | no DB write |
| ... | | | |

## Notes

- (Anything specific to this vendor — credential type for scenario D,
  timezone resolver behavior, idempotency-key shape, etc.)
```

## What This Directory Is NOT

- Not a place for live API responses captured from sandbox calls
  (those live in `*.live.sandbox` slices, owned by the vendor lane).
- Not a place for synthetic / fabricated payloads (the point of the
  sprint is to find holes the adapter has against real vendor shapes).
- Not a place for operator data (production or staging facts). Every
  fixture must scrub identifiers — use placeholder operator IDs and
  location IDs that no real operator could match.

## Sourcing Rules

1. Vendor docs URL must resolve at retrieval time.
2. If the vendor has a versioned API (v2 / v3), pick the version named
   in `docs/integrations/<vendor>/` adapter notes.
3. If the vendor publishes both webhook payloads and pull-API
   responses, include scenarios from whichever transport the adapter
   actually uses (per the integration's adapter file).
4. If a published example uses obviously fictional values (e.g.
   `merchant@example.com`), keep them. Don't substitute realistic
   data.
