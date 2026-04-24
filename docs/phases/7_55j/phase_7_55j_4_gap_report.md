# Phase 7.55j.4 - Integration Readiness Gap Report

Updated: 2026-04-23
Owner: Codex planning / tracker truth
Status: Complete - pre-Phase-8 readiness gap report

## Purpose

Summarize what the current canonical Forge & Flow architecture already supports
for live vendor work, what still needs explicit schema or boundary work, and
what must be validated against official vendor docs before Phase 8 / 8R begins.

This is a readiness report, not a new implementation plan.

## Current Verdict

- The major runtime-architecture blockers named in `7.55j.gate` were closed by
  the landed `7.55l` and `7.55k` work.
- The app now has the missing vendor-packaging docs (`7.55j.3` and this
  report), so Phase 8 / 8R no longer starts from vague capability guesses.
- Phase 8 / 8R should still begin only after the selected vendors are checked
  against the capability questions below and the adjacent `7.55n` timing truth
  remains honest about daypart depth.

## A. Features Fully Supported By Current Canonical Models

| Feature / Surface | Readiness | Why It Is Clean |
| --- | --- | --- |
| Benchmark / manager override | ready | closed-truth inputs, app-owned target derivation, locked `TargetCycle`, and explicit wage-authority fallback path already exist |
| Schedule planning | ready | app-owned `DemandForecastContext` + `WeeklyPlanSnapshot` already define the weekly planning truth; integrations feed evidence, not plan logic |
| Shift whole-day view | ready | whole-day Shift remains the active contract; integrations only need to supply live covers, sales, labor, and reservation context |
| Variance WTD / Full Week / History | ready | locked weekly-plan truth, closed-vs-open distinction, and preserved historical targets are already codified |
| History benchmark dayparts + Learn repeatable wins | ready with honest degradation | evidence-backed logic already exists; if vendor timestamps are weak, the app can fall back to whole-day truth without lying |
| Reservation "In the books" signal | ready | reservation snapshot model already exists; vendor work only needs to populate it with real reservation facts |
| External identity link seam | ready as placeholder | Phase 9 identity model already reserves the app-user to vendor-employee mapping path |
| Import tracking and provenance | ready | `import_runs`, raw-import provenance, and replay-era transport seams already exist to host real connector runs |

## B. Features Needing Schema Or Model Additions

| Gap | Why It Still Matters | Notes |
| --- | --- | --- |
| Vendor connector metadata tables | location bindings, module enablement, and non-secret connector config need explicit persisted shape | `Phase 10a` now defines the eventual shared-state home for non-secret connector metadata, but Phase 8 still needs the concrete schema |
| Sync cursor / watermark shape per vendor module | each vendor may require different incremental-sync tokens or updated-since markers | existing import tracking is useful, but per-vendor cursor fields still need explicit implementation-time design |
| Vendor role-mapping persistence | FOH / BOH / manager mapping should not stay implicit in code once real labor roles arrive | critical for 7shifts role classification and manager-hours handling |
| Stronger employee identity mapping rows | placeholder external identity links exist, but real attribution may need vendor employee ids, emails, archived-user behavior, and conflict handling | required once Phase 8 attribution moves past simple one-id mapping |
| Persisted restaurant timing and service-period closeout | daypart evidence depends on restaurant-owned timing truth, not fixture-era defaults | active adjacent gap owned outside this report; do not promise full daypart depth until that seam is honest |
| Explicit vendor correction-event capture | refunds, voids, punch edits, and late adjustments need durable ingestion semantics | current models support correction-aware truth, but vendor-specific change capture still needs implementation-time schema detail |

## C. Features Needing A Backend Connector Boundary

| Boundary | Why It Must Be Server-Side |
| --- | --- |
| OAuth / partner-token storage and refresh | vendor secrets must not live in Flutter |
| Webhook receive, verify, replay, and idempotency | webhook signatures, retries, and duplicate-event handling belong on a trusted backend |
| Historical backfill jobs | large backfills, pagination, and rate-limit-aware retries are backend work, not client work |
| Incremental sync schedulers | polling or cursor-based sync must run outside the mobile UI lifecycle |
| Admin-only connector setup actions | location binding, token exchange, and privileged config writes must not bypass trusted backend checks |

## D. Features That Must Remain App-Derived

These are not gaps and should not be handed to vendors:

- `TargetCycle` and benchmark standards
- `DemandForecastContext`
- `WeeklyPlanSnapshot`
- forecast sales as `covers * target PPA`
- service-period definitions and timestamp bucketing
- OPZ, lever math, CPLH / SPLH / PPA derivations
- row-status honesty (`closed`, `open`, `projected`, `mixed`)
- evidence visibility policy for History / Learn
- reservation aggregation into the app-owned "In the books" signal

## E. Fields To Validate Against Vendor Docs Before Phase 8 / 8R

### Toast (POS)

- business date versus calendar date semantics
- closed / paid / reopened / refunded / voided status semantics
- reliable cover or guest-count field by order channel
- opened / closed / updated timestamps for app-owned daypart bucketing
- intraday sales and covers freshness expectations
- close-of-business or finalization signal
- post-close correction feed and replay semantics
- stable check / order / ticket ids
- location, revenue center, dining option, or service-mode fields

### 7shifts (Labor)

- scheduled-shift model versus actual-punch model
- business date tagging for punches and shifts
- role / department / job-code fields needed for FOH / BOH / manager mapping
- current clocked-in labor path for live Shift
- wage rates, direct labor dollars, or both
- punch edit / correction semantics after close
- stable employee ids plus archived-user behavior
- location binding model for one restaurant scope
- time-range granularity needed for daypart labor evidence

### OpenTable (Reservation)

- reservation id, venue id, and business-date-safe time semantics
- party size reliability
- status vocabulary and the exact meaning of unseated versus seated
- status timestamps (booked, confirmed, arrived, seated, completed,
  cancelled, no-show)
- updated-since or webhook event model
- webhook retry, replay, ordering, and signature-verification behavior
- VIP, area, table, waitlist, or walk-in fields if exposed
- historical backfill window and pagination limits

## F. Clean-Start Guidance For Phase 8 / 8R

Phase 8 / 8R can start cleanly when:

- the chosen vendor docs are filled into `7.55j.3`
- every missing required capability is classified as true blocker or honest
  degrade path
- the remaining gaps above are treated as connector-boundary work or
  implementation-time schema work, not as reasons to reopen the product
  architecture

## Source Material

- [phase_7_55j_integration_feature_endpoint_inventory.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/7_55j/phase_7_55j_integration_feature_endpoint_inventory.md)
- [phase_7_55j_3_vendor_endpoint_checklist_template.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/7_55j/phase_7_55j_3_vendor_endpoint_checklist_template.md)
- [phase_7_55j_2_required_capability_matrix.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55j/phase_7_55j_2_required_capability_matrix.md)
- [phase_7_55j_gate_integration_readiness_pressure_test.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55j/phase_7_55j_gate_integration_readiness_pressure_test.md)
- [phase_7_55k_8_integration_implications.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/phases/7_55k/phase_7_55k_8_integration_implications.md)
- [status_ledger_post_7_55p_deep_check.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/internal/status_ledger_post_7_55p_deep_check.md)
