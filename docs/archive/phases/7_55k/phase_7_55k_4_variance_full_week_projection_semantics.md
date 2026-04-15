# Phase 7.55k.4 â€” Variance Full Week Projection Semantics

Updated: 2026-04-12
Owner: Codex planning / Claude implementation
Status: Implemented

## What This Slice Delivers

Honest, explicit semantics for every row in the Variance Full Week
Projection. Introduces a dedicated `VarianceWeekProjectionReadService`
and `VarianceWeekProjectionRow` read model so the screen renders a
provenance-tagged model instead of deciding source truth itself.

## Key Design Decisions

### Row status semantics

Every Full Week row carries an explicit `RowStatus`:

- `closed` â€” locked closed truth from finalized shift facts
- `open` â€” live in-progress snapshot context, not final truth
- `projected` â€” planned / forecast placeholder context, not actual
  performance

### Day-row aggregation

Day rows aggregate the visible child rows for that day. When a day
contains a mix of closed, open, and projected children, the day row
carries `RowStatus.mixed` and a compact `statusSummary` describing the
composition (e.g., "1 closed, 1 open").

Day-row totals (covers, labor %, variance pts) always reconcile to the
sum of their expanded child rows.

### Week projection composition

The Full Week projection is:

- WTD closed truth (already finalized)
- plus remaining open / projected context (not yet final)

The `PROJ TOTAL` row at the bottom of the Full Week table is a
projection â€” it mixes closed truth with non-final context.

### Row-scope driver honesty

- Closed rows carry their actual detected primary lever.
- Open and projected rows display "Not yet available" instead of the
  `ON_MODEL` placeholder. `ON_MODEL` is still stored on the underlying
  `ShiftRecord` for backward compatibility, but the read model translates
  it to an honest product-facing label.

### Projected-row copy honesty

- Projected rows no longer say "Projected from 60-day baseline" â€” that
  copy was inaccurate when the row actually comes from the active weekly
  plan snapshot + target cycle context.
- New copy: "Projected from weekly plan. Actuals populate when shift
  closes." â€” matches the real runtime authority.
- Open rows: "Live shift in progress. Finalizes on close." â€” unchanged.

### Mixed day-row visibility (7.55k.4a)

- When a day contains children with different statuses (e.g., one closed
  and one projected), the collapsed day row now:
  - uses the accent color instead of the closed-truth primary color
  - renders the compact `statusSummary` text below the daypart chips
    (e.g., "1 closed, 1 projected")
- Fully closed days are visually distinct from mixed days.

### Open-row detail header honesty (7.55k.4a)

- The open-row expanded detail previously used `CURRENT` as its
  right-hand column header, but the values shown were plan context
  (forecast covers, theoretical labor %) â€” not live actual metrics.
- New header: `PLAN CONTEXT` â€” honestly describes the column content.
- Projected rows still use `PROJECTED` as their header â€” unchanged.

### businessDate propagation

`CurrentWeekState.shiftRecordFromSnapshot` now propagates the snapshot's
`businessDate` to the output `ShiftRecord`. Previously this field was
silently dropped.

## What This Slice Does NOT Do

- Does not redesign runtime architecture broadly.
- Does not change target math, cycle math, replay behavior, or labor
  formulas.
- Does not migrate History or Learn.
- Does not make Shift service-period or live-daypart aware.
- Does not pull Phase 10.5 behavior forward.
- Does not implement the restaurant timing runtime foundation (queued
  to 7.55n).
- Does not update tracker markdown files.

## Future Boundaries

- `7.55k.5` owns History benchmark dayparts upgrade.
- `7.55k.6` owns Learn repeatable wins upgrade.
- `7.55k.7` owns visibility rules / early-signal policy.
- `7.55n` owns restaurant timing + service-period runtime foundation.
- `10.5` owns live Shift service-period behavior and daypart-live driver
  teaching.

## Files

- `docs/archive/phases/7_55k/phase_7_55k_4_variance_full_week_projection_semantics.md` (this doc)
- `lib/models/variance_week_projection_row.dart`
- `lib/services/variance_week_projection_read_service.dart`
- `lib/models/current_week_state.dart` (businessDate propagation fix)
- `lib/screens/variance_report.dart` (render from read model, honest copy)
- `test/variance_week_projection_read_service_test.dart`
- `test/variance_visual_widget_test.dart`

## Cross-References

- `docs/archive/phases/7_55k/phase_7_55k_1_daypart_scope_audit.md` â€” overstatement gaps
- `docs/archive/phases/7_55k/phase_7_55k_2_service_period_decoupling_plan.md` â€” identity shapes
- `docs/archive/phases/7_55k/phase_7_55k_3_daypart_pattern_summary_model.md` â€” pattern summary
- `docs/archive/phases/7_55k/phase_7_55k_daypart_variance_history_learn_plan.md` â€” parent plan
- `docs/contracts/phase_7_55_architecture_contract.md` â€” system contract
