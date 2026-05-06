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

## `8.spine-bridge-sink-fanout.TC` (Tock) — open items

Three open items left after the sink + test landed on
`claude/great-lewin-3d493b`:

1. **CI verification of the TC sink suite.** Same SDK-on-PATH gap as
   `.AL`: `dart analyze`, the new `tock_reservation_postgres_sink_test.dart`
   (tests A–H including the 2026-05-05 falsehood-correction grep that
   rejects any literal `'seated_at'` Dart token outside the INSERT
   column-name string), and the
   `tock_reservation_adapter_test.dart` regression were not run
   locally. CI must green all three before any downstream lane builds
   on the TC sink.

2. **Per-transition timestamp diff in `8R.TC.live.sandbox`.** The TC
   sink writes `seated_at` and `cancelled_at` as SQL `null` literals
   because Tock's public reservation reference (api version
   `reservation_2026_05_03`) documents only `createdTimestamp`,
   `lastUpdatedTimestamp`, and `serviceDateTimestamp`. The
   `*.live.sandbox` slice must diff observed sandbox payloads against
   `documentedPerTockReservation20260504`; if Tock actually emits
   `arrived_at` / `seated_at` / `left_at` / `canceled_at`, the adapter
   adopts them as a bounded fix and the sink switches the two columns
   from `null`-literal to bound parameters (renaming the parameter
   keys so the banned-grep stays satisfied).

3. **Watermark resource alignment in the unified dispatcher.** The
   sink defines `tockWatermarkResource = 'reservation.reservations'`
   and the canonical view calls `persistWatermark(... resource:
   tockWatermarkResource ...)` explicitly. The sync worker dispatcher
   in `tool/integration_sync_worker/dispatch.dart` must thread the
   same constant when it instantiates the TC sink's
   `asCanonicalSink({connectionIdResolver})` view, otherwise
   `connector_sync_watermark` rows fragment across two resource keys
   on a single connection. Worth a focused dispatcher-side test once
   the dispatcher slice picks this lane up.

# Sink Follow-Up — `8.spine-bridge.1.HM` (Humanity TCP)

Three open items left after the sink + test landed on
`claude/8-spine-bridge-sink-fanout-HM`:

1. **CI verification of the sink suite.** The worktree environment
   has no Flutter/Dart SDK on PATH, so `dart analyze`, the new
   `humanity_postgres_sink_test.dart` suite, and the
   `humanity_labor_adapter_test.dart` regression were not run
   locally. CI (subosito/flutter-action) must run all three before
   merge; any failures are bounded fixes inside the two new files.

2. **`HumanityWatermarkRow` connection-id widening.** The gateway
   path `HumanityPostgresSink.writeWatermark` currently SELECTs
   `connector_connection.connection_id` per call to bridge the
   gap between the typed `HumanityGateway` shape (no connection
   id) and the watermark table's `(connection_id, resource)`
   UNIQUE. A future lane should widen `HumanityWatermarkRow` /
   `HumanityGateway.writeWatermark` to carry `connection_id`
   end-to-end and drop the per-write SELECT. This lane
   intentionally left the adapter alone per the slice prompt.

3. **`8.S.HM.live.sandbox` is unblocked.** With the canonical
   sink on master, the live sandbox slice can diff documented vs
   observed Humanity v1 responses against a real partner sandbox,
   promote the adapter from `documented` → `sandboxVerified`, and
   flag any field-mapping drift as bounded fixes inside the
   adapter (not slice rebuilds). Schedule directly after HM merges.

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

---

# Sink Follow-Up — `8.spine-bridge.1.SQ` (Square)

Three open items left after the sink + test landed on
`claude/bold-hertz-24c86a`:

1. **CI verification of the sink suite.** The worktree environment
   has no Flutter/Dart SDK on PATH, so `dart analyze`, the new
   `square_pos_postgres_sink_test.dart` suite, and the
   `square_pos_adapter_test.dart` regression were not run locally.
   CI must run all three before merge; any failures are bounded
   fixes inside the two new files.

2. **Adapter-side covers_source projection (Lane `.2`).** The sink
   already hard-NULLs `covers` per the Square Order schema and
   threads adapter-supplied `covers_source` through unchanged, but
   `SquarePosAdapter._orderToCanonicalFact` still always emits
   `covers_source: 'forecast_fallback'`. Lane `.2` should teach the
   adapter to project `reservation_plus_walkin` / `manual_fallback`
   when the surrounding signal warrants. This lane intentionally
   left the adapter alone per the slice prompt.

3. **Next sink-fanout lane.** The remaining INTEGRATE vendors in
   the sink-fanout wave land in the same shape as `.AL` and `.SQ`:
   bespoke + unified surface widening, idempotency partial UNIQUE
   on `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`,
   demo-flip auto-evaluator on watermark advance. Schedule the
   next lane directly after SQ merges.

---

# Sink Follow-Up — `8.spine-bridge.1.TS` (Toast)

Three open items left after the sink + test landed on
`claude/relaxed-shirley-d886c5`:

1. **CI verification of the sink suite.** No Flutter/Dart SDK was
   available on the worktree harness, so `dart analyze`, the new
   `toast_pos_postgres_sink_test.dart` suite (tests A–H), and the
   `toast_pos_adapter_test.dart` regression were not run locally.
   CI (subosito/flutter-action) must run all three before merge;
   any failures are bounded fixes inside the two new files.

2. **Adapter-side disconnect → sink wipe wiring.** The sink exposes
   `wipeCredentialsPreserveWatermark` for symmetry with the OR sink,
   but `ToastPosAdapter.disconnect` still routes only through
   `transport.unregisterWebhook` and reports `credentialsWiped: true`
   without actually invoking the sink helper. A follow-up in
   `8.TS.live.sandbox` should thread the sink call through the
   adapter's disconnect path so credential ciphertexts are blanked
   in `vendor_credentials` on operator-initiated disconnect. The
   slice prompt explicitly pinned the adapter as off-limits, so this
   was deliberately deferred.

3. **Spine-bridge dispatcher binding.** The Toast sink now satisfies
   `CanonicalSink`, but the sync worker dispatcher
   (`tool/integration_sync_worker/dispatch.dart`) does not yet route
   Toast through the unified surface. The next lane wires
   `kToastVendorId` into the dispatcher's POS map alongside
   `oracle_micros_simphony` and `aloha_ncr_voyix` so the worker can
   call `upsertCoverFact` / `advanceWatermark` with an explicit
   `connectionId`. Schedule after `.TS` merges and before the next
   POS fanout sink.

# Sink Follow-Up — `8.spine-bridge-sink-fanout.AG` (Agendrix)

Three open items left after the sink + test landed on
`claude/8-spine-bridge-sink-fanout-AG`:

1. **CI verification of the sink suite.** The worktree environment has
   no Flutter/Dart SDK on PATH, so `dart analyze`, the new
   `agendrix_postgres_sink_test.dart` suite (Tests A–H), and the
   `agendrix_labor_adapter_test.dart` regression were not run locally.
   CI (subosito/flutter-action) must run all three before merge; any
   failures are bounded fixes inside the two new files.

2. **Adapter canonical-key alignment.** The sink translates the
   Agendrix adapter's `employee_id` canonical-dict key into
   `labor_punches.employee_source_id` at write time. Long-term the
   adapter should emit `employee_source_id` directly so every labor
   sink consumes one canonical key. `8.S.AG.live.sandbox` is the
   right lane to retire the translation alongside the
   sandbox-observed field-mapping diff; this slice intentionally left
   the adapter alone per the slice prompt.

3. **Wage-source upgrade path.** Agendrix is wage-class
   `app_fallback` today — the documented Public API exposes
   per-position pay only, so the sink binds `pay_rate = NULL` and
   the aggregator falls back to the wage-authority service. If a
   future Agendrix release exposes per-shift pay (mirroring the
   7shifts `/reports/hours_and_wages` upgrade path), promote the
   adapter to `perEmployeeWithRates` and drop the NULL bind in
   favor of the vendor value.

---

# Sink Follow-Up — `8.spine-bridge-sink-fanout.SR` (SevenRooms)

Three open items left after the sink + test landed on
`claude/8-spine-bridge-sink-fanout-SR`:

1. **CI verification of the sink suite.** The worktree environment has
   no Flutter/Dart SDK on PATH, so `dart analyze`, the new
   `sevenrooms_reservation_postgres_sink_test.dart` suite (Tests A–H,
   including G's CANCELLED → `cancelled_at` round-trip), and the
   `sevenrooms_reservation_adapter_test.dart` regression were not run
   locally. CI (subosito/flutter-action) must run all three before
   merge; any failures are bounded fixes inside the two new files.

2. **Bespoke gateway tenant widening.** `SevenRoomsReservationGateway.
   updateWatermark` and `appendSyncLog` only carry `connectionId`, so
   the sink resolves `(operator_id, location_id)` via a `withSystem`
   lookup against `connector_connection` before the tenant-scoped
   write. A future lane should widen those gateway methods to accept
   the tenant tuple directly (matching Libro's shape) so the
   per-call lookup + RLS-bypass round-trip drops out.

3. **Worker dispatcher wiring.** The unified `CanonicalSink` view is
   exposed via `asCanonicalSink({connectionIdResolver})` but no
   integration sync worker dispatch currently routes SevenRooms
   reservation facts through it — the Wave B adapter still writes
   through the bespoke gateway only. The follow-up `8.spine-bridge.2`
   aggregator lane wires the dispatcher and lights up the demo-flip
   auto-evaluator on the unified surface.
