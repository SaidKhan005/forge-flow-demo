# Pressure Integration Harnesses — Pressure Preview v1

Sprint: `pressure.preview.v1` Phase 2.

This directory holds the four integration-level harnesses that drive the
Phase 1 vendor payload corpus through every infrastructure layer in
sequence. Each level isolates one seam so when something fails, the
findings doc can name the layer (not just "pipeline broken").

The plan doc lives at
`docs/_execution/2026-05-08_pressure_preview_v1_plan.md`. Fixtures live
at `test/fixtures/vendor_payloads/<vendor>/`.

## Four Harness Levels

| Level | Name | Seam under test | Output table / artifact |
|---|---|---|---|
| 2A | Adapter | Vendor JSON → `IntegrationAdapter` parsed model | parsed `VendorEvent` instances |
| 2B | Sink | Parsed model → Postgres operator-scoped sink (`*_pos_postgres_sink.dart` and labor / reservation analogues) | rows in `shift_records`, `reservation_records`, etc. |
| 2C | Spine | Postgres sink → canonical fact aggregation → projector | rows in canonical-fact tables; demo-mode flip; idempotency ledger |
| 2D | Mobile-sync | Canonical facts → mobile sync proxy → SQLite read replica | SQLite rows materializing on the device side |

Each level is its own subdirectory (created lazily by Phase 2 agents).
Tests run against the preview proxy URL specified in the plan doc.

## Conventions

- One Dart test file per (vendor × scenario × level) tuple is **not**
  required. Use parametric tests that iterate over the fixture set and
  assert the per-vendor README outcome column.
- Each level reuses fixtures from `test/fixtures/vendor_payloads/`; do
  not duplicate payloads here.
- Tests must be deterministic: clock-injected, no `DateTime.now()`
  references, stable operator/location seed data.
- A test failure must include the fixture path so the findings doc can
  cite it directly.
- All HTTP calls go through the preview proxy. No direct vendor calls.

## Phase 0 (this commit)

Empty placeholder — the four level subdirectories will land in Phase 2.
Only this README + a `.gitkeep` exist now.

## What This Directory Is NOT

- Not a place for unit tests of pure functions (those stay co-located
  with the source under `test/lib/...`).
- Not a place for load tests (Phase 3 owns `test/pressure/`).
- Not a place for click-path / E2E browser tests (Phase 4 emulator
  E2E is user-driven and lives in operator runbooks, not here).
