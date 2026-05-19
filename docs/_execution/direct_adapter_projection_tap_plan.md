# Direct Adapter Projection Tap Plan

## Plain-English Findings

- PR #1027 made the production projector exist by default.
- The remaining gap is the path that real adapters use to write facts.
- Real adapters still write through vendor-specific sink methods.
- The projector wrapper only sees facts written through its `CanonicalSink` methods.
- That means a real adapter can write the Postgres fact row successfully, then the worker can log success, while the projector never sees the fact.
- Webhooks have the same issue: the handler logs `webhook_received`, but the projecting wrapper is not the object that wrote the fact.

## Role Split

- Orchestrator: own the architecture, shared API, plan doc, integration, tests, PR, merge readiness, and final audit.
- POS worker lane: already completed read-only call-path audit for POS adapters and sinks.
- Labor/reservation worker lane: already completed read-only call-path audit for labor, reservation, and worker dispatch.
- Implementation stays in this worktree only; the shared checkout stays on `master`.

## Fix Plan

1. Add a small projection-tap surface to the existing projector wrapper.
   - It records successful fact writes without writing the fact a second time.
   - It drains the buffered facts after a commit signal.
   - Projection failure remains warning-only and must not fail adapter writes.

2. Treat `webhook_received` as a commit signal.
   - Webhook dispatch writes one or more facts, marks the webhook processed, then logs `webhook_received`.
   - That log is the webhook equivalent of `poll_success` and `backfill_success`.

3. Wire direct adapter sinks into the tap.
   - POS sinks record successful cover/sales writes.
   - Labor sinks record successful labor-punch writes.
   - Reservation sinks record successful reservation writes, including view-based reservation sinks.
   - Existing SQL, idempotency, demo flip counters, and adapter contracts stay unchanged.

4. Drain the tap from all server commit paths.
   - Proxy inbound webhook handler drains after `webhook_received`.
   - Recurring sync worker drains after `poll_success`.
   - First-connect backfill worker drains after `backfill_success` and `backfill_partial`.

5. Keep the old wrapper behavior intact.
   - Existing tests that call `ProjectingCanonicalSink.upsert*` must still pass.
   - The new direct-write path should reuse the same buffering and projector logic.

6. Verify narrowly.
   - Add unit tests for direct tap record plus drain.
   - Add binder/factory tests proving adapters can use the tap without duplicate writes.
   - Add worker/handler tests where practical to prove commit drains happen from real server paths.

## Guardrails

- No duplicate canonical fact writes.
- No adapter API rewrites unless required by an existing interface.
- No schema changes.
- No production credential or cloud calls.
- No tracker edits.
- If full 17-vendor implementation becomes too large for one safe slice, land the shared tap and highest-risk direct write path first, then document the remaining vendor-family follow-up explicitly.

## Execution Result

- Added the shared direct-write projection tap.
- Wired POS, labor, and reservation Postgres sinks to record successful writes.
- Drained taps after webhook, recurring poll, and first-connect backfill commit logs.
- Kept projection failure warning-only, so adapter writes still succeed.
- Verified with focused analyzer, focused tests, UX copy lint, and diff whitespace check.
