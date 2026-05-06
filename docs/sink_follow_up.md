# Sink Follow-Up — `8.spine-bridge.1.AL` (Aloha NCR Voyix)

Three open items left after the sink + test landed on
`claude/8-spine-bridge-sink-fanout-AL`:

1. **CI verification of the sink suite.** The worktree environment has
   no Flutter/Dart SDK on PATH, so `dart analyze`, the new
   `aloha_ncr_voyix_pos_postgres_sink_test.dart` suite, and the
   `aloha_ncr_voyix_pos_adapter_test.dart` regression were not run
   locally. CI (subosito/flutter-action) must run all three before
   merge; any failures are bounded fixes inside the two new files.

2. **Adapter-side tri-state covers.** The sink already tolerates
   `covers = null`, but `AlohaNcrVoyixPosAdapter._canonicalize` still
   maps `numberOfGuests` straight through without an explicit nullable
   fallback, and the capability profile pins `coversFieldExposed: true`.
   `8.AL.live.sandbox` should flip the adapter to tri-state — null
   when Aloha omits `numberOfGuests` — and align the capability
   boolean with reality. This lane intentionally left the adapter
   alone per the slice prompt.

3. **CL (Clover) fanout sink.** The next lane in the sink-fanout
   wave — `8.spine-bridge-sink-fanout.CL` — lands the Clover →
   `cover_facts` Postgres sink in the same shape as `.AL`. Same
   bespoke + unified surface widening, same idempotency partial
   UNIQUE, same demo-flip auto-evaluator. Schedule directly after
   AL merges.

# Sink Follow-Up — `8.spine-bridge.1.PU` (Push Operations)

Three open items left after the sink + test landed on
`claude/8-spine-bridge-sink-fanout-PU`:

1. **CI verification of the sink suite.** The worktree environment has
   no Flutter/Dart SDK on PATH, so `dart analyze`, the new
   `push_operations_postgres_sink_test.dart` suite, and the
   `push_operations_labor_adapter_test.dart` regression were not run
   locally. CI (subosito/flutter-action) must run all three before
   merge; any failures are bounded fixes inside the two new files.

2. **Wage-class promotion path.** The sink is pinned at V1 `hoursOnly`
   per the 2026-05-05 falsehood correction #8 — `pay_rate` and
   `labor_dollars` are intentionally absent from the INSERT and the
   banned-grep enforces zero wage-dollar tokens in the source. When
   Push Operations later exposes a documented pay-rate join (or a V2
   wage-class lift moves them onto `perEmployeeWithRates`), the lane
   that adds wage writes must update the banned-grep ledger and the
   Test G hours-only invariant in the same PR — silent re-introduction
   of either token would slip past today's guard.

3. **Sync-worker dispatcher wiring.** The unified `CanonicalSink`
   surface is implemented but no `tool/integration_sync_worker`
   dispatcher route currently hands a Push Operations labor batch to
   `PushOperationsPostgresSink.upsertLaborPunch`. The follow-up lane
   wires the dispatcher (`8.spine-bridge.2.PU` or the next fanout
   wave's worker pass) and adds an integration test that exercises
   the dispatcher → sink path end-to-end.
