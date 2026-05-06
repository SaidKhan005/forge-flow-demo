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
