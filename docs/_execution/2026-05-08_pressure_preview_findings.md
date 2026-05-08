# Pressure Preview v1 — Findings

Sprint: `pressure.preview.v1`
Skeleton created: 2026-05-08 (Phase 0)
Filled by: Phase 5 consolidation agent

This doc consolidates findings from Phases 1-4 of the pressure-test
sprint. Phase 5 fills it; Phase 6 reads it to drive the Postgres unit-
test backfill.

The plan doc lives at
`docs/_execution/2026-05-08_pressure_preview_v1_plan.md`.

---

## 1. Per-Vendor Pass / Fail Matrix

TBD — Phase 5 agent will fill. One row per vendor (17 rows). Columns:
scenario A (forged signature), B (malformed payload), C (future-dated),
D (OAuth near-expiry / credential rotation), E (ambiguous timestamp),
F (cross-vendor ID collision), happy-path-1, happy-path-2, DST,
cross-tz. Cells: pass / fail / N/A. Each fail links to the bug entry
in section 6.

| Vendor | A | B | C | D | E | F | Happy | DST | Cross-tz |
|---|---|---|---|---|---|---|---|---|---|
| lightspeed_lsk | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| toast | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| clover | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| oracle_micros_simphony | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| aloha_ncr_voyix | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| revel | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| square | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| libro | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| tock | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| opentable | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| sevenrooms | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| quickbooks_time | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| adp | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| seven_shifts | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| humanity | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| agendrix | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| push_operations | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD |

---

## 2. Per-Layer Failure Summary

TBD — Phase 5 agent will fill. One subsection per harness level
(2A adapter, 2B sink, 2C spine, 2D mobile-sync). Each subsection lists
the (vendor, scenario, fixture path, failure mode) tuples that failed
at that layer.

### 2A — Adapter

TBD — Phase 5.

### 2B — Sink (Postgres)

TBD — Phase 5.

### 2C — Spine (canonical-fact aggregation + projector)

TBD — Phase 5.

### 2D — Mobile-sync (proxy → SQLite)

TBD — Phase 5.

---

## 3. Load Test Outcomes

TBD — Phase 5 agent will fill. One subsection per load lane.

### 3A — Webhook flood

TBD — Phase 5. Capture: peak RPS sustained, p50/p95/p99 latency,
errors observed, idempotency-ledger contention, advisory-lock waits.

### 3B — Backfill flood

TBD — Phase 5. Capture: backfill-job throughput, OAuth-refresh
advisory-lock contention, sink write throughput, RLS context-switch
overhead.

### 3C — OAuth-refresh storm

TBD — Phase 5. Capture: refresh success rate, advisory-lock wait
times, vendor rate-limit responses, idempotency on retry.

---

## 4. Emulator E2E Notes (Phase 4 — user-driven)

TBD — user fills after Phase 4 click-path runs. Capture: which screens
broke under realistic vendor data, where labels lied, where loading
states never resolved, where copy/UX needs tightening.

---

## 5. Postgres Repository Coverage Map

Phase 6 input. Per `docs/POST_HARDENING_FOLLOWUPS.md` P2, 27 of 47
postgres repositories are uncovered (20 with `*_test.dart`). Phase 5
maps each finding from sections 2-3 to the repository it implicates,
then Phase 6 backfills tests grounded in the real fixtures from
Phase 1 instead of fabricated ones.

| Repository | Lines | Test file present? | Implicated by finding(s) | Phase 6 priority |
|---|---|---|---|---|
| weekly_plan_snapshot_repository.dart | 1038 | TBD | TBD | TBD |
| business_timing_profiles_repository.dart | 947 | TBD | TBD | TBD |
| target_cycle_repository.dart | 775 | TBD | TBD | TBD |
| corpus_repository.dart | 738 | TBD | TBD | TBD |
| forecast_context_repository.dart | 690 | TBD | TBD | TBD |
| graph_repository.dart | 684 | TBD | TBD | TBD |
| active_target_profile_repository.dart | 675 | TBD | TBD | TBD |
| auth_events_audit_repository.dart | 633 | TBD | TBD | TBD |
| selected_star_shift_repository.dart | 616 | TBD | TBD | TBD |
| user_pii_erasure_repository.dart | 656 | TBD | TBD | TBD |
| (remaining 17 of the uncovered 27) | TBD | TBD | TBD | TBD |

TBD — Phase 5 agent expands the table with the remaining 17 repos and
fills the columns.

---

## 6. Discovered Bugs

TBD — Phase 5 agent will fill. Each entry: short title, layer
(adapter/sink/spine/mobile-sync/load), repro fixture path, observed
behavior, expected behavior, severity, fix slice (if known).

(none yet)

---

## 7. Vendor Doc Gaps

TBD — Phase 5 agent will fill. Each entry: vendor, what the public
docs do not say, how Phase 1 worked around it (or what scenario could
not be authored), what live-sandbox slice should re-confirm.

(none yet)

---

## Cross-References

- `docs/_execution/2026-05-08_pressure_preview_v1_plan.md` — sprint plan
- `test/fixtures/vendor_payloads/README.md` — fixture format spec
- `test/integration/pressure/README.md` — Phase 2 harness layout
- `test/load/pressure/README.md` — Phase 3 lane layout
- `docs/POST_HARDENING_FOLLOWUPS.md` — Phase 6 input (P2 coverage gap)
- `docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` —
  origin of the binding A-F adversarial scenario set
