# PR #631 Audit — C-2-D `vendor_sync_error_alert` Wire + First-Failure-of-Outage Detector (Claude)

**Slice:** C-2-D (Lane C — Cross-Surface Parity; matrix Draft D WIRE)
**Owner:** Claude (orchestrator-dispatched, isolated worktree agent)
**Branch:** `claude/c-2-d-vendor-sync-outage-detector-wire`
**Base:** `master` @ `ab4606ef` (post-C-2-Del)
**Gate:** **operator-approval-required** — schema-touching (NEW migration + NEW table) + RLS-touching (new per-tenant policy)
**Risk:** **Medium-High** — net-new state surface (`vendor_sync_outage_state` table), new RLS policy on that table, new state-machine logic in `lib/services/vendor_sync/`, new sink hook in the polling-tier `tool/integration_sync_worker/main.dart`; ~1,102 LoC production code; **production runtime binding NOT shipped in this slice**
**Size:** 2,785 additions / 28 deletions / 15 files

## Verdict

**approve pending operator OK + merge-order note** — audit clean. Worker self-flagged `[operator-approval-required]` correctly. Implementation is careful: explicit state table (option a, preferred over CTE-on-`connector_sync_log` for clarity + testability), additive expand migration (no existing table altered), per-tenant RLS policy mirroring `connector_sync_log` sibling, operator-leading B-tree index per CLAUDE.md, default heuristics (N=3 consecutive failures, M=30-min lookback) match the OAuth refresh worker's cap-threshold posture, optional observer seam (null-tolerant), production binding deferred to a separate small follow-up slice.

**Operator picked WIRE for Draft D** on 2026-05-13. Per-PR sign-off is the merge-time gate. **Merge-order constraint: PR #626 (C-7a, cutoff `…1800`) should merge BEFORE PR #631 (cutoff `…1900`)** — otherwise the rebase has to roll C-7a's cutoff string backward, which is awkward. Standard rebase + textual conflict on the 5 cutoff-mirror docs + POST_HARDENING pending count is expected when the second of {#626, #631} merges.

## Pattern B compliance

**✓ EXEMPLARY** — Pattern B 8-lens self-audit in PR body. Honest disclosures: option (a) explicit table over option (b) CTE (rationale recorded), default heuristic values explicit + overridable, migration apply queue slot + idempotency posture stated, production runtime binding explicitly NOT shipped + same-shape precedent (`VendorLifecycleNotificationDispatcher`) called out.

## What landed

| File | LoC | Kind |
|---|---|---|
| `db/migrations/202605131900_c_2_d_vendor_sync_outage_state.sql` | +221 / 0 | **NEW MIGRATION** — `CREATE TABLE IF NOT EXISTS public.vendor_sync_outage_state` with `(operator_id, location_id, connection_id)` denormalized FKs, RLS policy `vendor_sync_outage_state_per_tenant` mirroring `connector_sync_log` siblings, operator-leading B-tree index `vendor_sync_outage_state_operator_idx`, `ON DELETE CASCADE` from both `connector_connection` and `locations`, `service_role` + `forge_admin` grants, lock + statement timeouts, `begin/commit` wrap, idempotent DDL |
| `lib/services/vendor_sync/vendor_sync_outage_detector.dart` | +509 / 0 | **NEW** — state-machine detector with thorough state-diagram header doc; pure I/O-injected design (Postgres reads/writes via dependency-injected repository seam); enqueue + state-stamp commit atomically with the read-side query |
| `lib/services/email/vendor_sync_error_alert_dispatcher.dart` | +381 / 0 | **NEW** — single-recipient dispatcher; mirrors `MfaFactorChangedNoticeDispatcher` orchestrator shape (PR #629 pattern); on-executor enqueue seam |
| `lib/infrastructure/persistence/postgres/repositories/vendor_sync_outage_state_repository.dart` | +212 / 0 | **NEW** — `PostgresExecutor`-based reads/writes (SELECT current state, INSERT new, UPDATE count + notified_at, DELETE on recovery); `OperatorScopedRepository` extension; tenant-bound |
| `tool/integration_sync_worker/main.dart` | +65 / -4 | EXTEND — new `VendorSyncOutageObserver` typedef + optional `outageObserver` param on `runSyncWorkerOnce` + observer-firing wrapper sink that runs AFTER `appendSyncLog` writes durably; **decoupled from `lib/services/vendor_sync` (production wires detector via closure in runtime bootstrap, separate slice)** |
| `lib/services/email/email_template_renderer.dart` | +21 / -14 | TOUCH — `EmailTemplateIds.vendorSyncErrorAlert` doc-string flipped TEMPLATE-ONLY → WIRED |
| `docs/POST_HARDENING_FOLLOWUPS.md` | +4 / -3 | Bump cutoff row + count 43 → 44 (drift vs C-7a's row count will need rebase) |
| `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` | +1 / -1 | Mirror cutoff filename |
| `docs/phases/phase_9/phase_9_execution_backlog.md` | +14 / -2 | Mirror cutoff filename + C-2-D paragraph |
| `runbooks/phase_9_production1_migration_apply_runbook.md` | +4 / -3 | Mirror cutoff filename + apply queue list |
| `scripts/postgres_staging_setup.ps1` | +1 / -1 | `MIGRATION_CUTOFF_BEGIN`/`END` block bump |
| `test/services/vendor_sync/vendor_sync_outage_detector_test.dart` | +561 / 0 | **NEW** — 11 cases covering all state-machine transitions, threshold boundary, recovery, lookback window stale-row exclusion |
| `test/services/email/vendor_sync_error_alert_dispatcher_test.dart` | +438 / 0 | **NEW** — 8 cases pinning recipient resolution, template-data shape, idempotency-key shape, audit-row contract |
| `test/db/migrations/c_2_d_vendor_sync_outage_state_test.dart` | +242 / 0 | **NEW** — 20 cases pinning column shape, NULL semantics, RLS posture, grants, FK CASCADE behaviour, no-DROP/no-DELETE invariants |
| `test/tool/integration_sync_worker/main_test.dart` | +111 / 0 | EXTEND — 2 new cases for outage observer wiring |

**Net effect:** when the polling tier writes a `connector_sync_log` row with `event_kind='poll_error'`, the optional outage observer (when wired) hands off to `VendorSyncOutageDetector`, which maintains per-connection state. The detector enqueues exactly one `vendor_sync_error_alert` email per outage window (first crossing of the N=3 threshold within an M=30min lookback). A `poll_success` clears the state row (outage recovered). **Production runtime binding NOT shipped in this slice** — observer defaults to null; binding the Postgres-backed dispatcher (operator admin email lookup + vendor catalog lookup + audit writer) through `buildWorkerRuntime` is a separate small slice (same posture as `VendorLifecycleNotificationDispatcher`).

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `tool/advisor_proxy/advisor_proxy.dart` untouched | `git diff origin/master -- tool/advisor_proxy/advisor_proxy.dart` returns 0 lines | **bleed-stop ceiling preserved at 88 headroom** per worker disclosure |
| `lib/auth/` untouched | diff scope | 0 lines |
| `pubspec.yaml` untouched | diff scope | 0 lines — no new package dep |
| `WAVE_EXECUTION_LEDGER.md` untouched | diff scope | 0 lines (orchestrator's job at merge) |
| Migration is additive expand only | migration body | `CREATE TABLE IF NOT EXISTS`; no ALTER on existing tables; no DROP/DELETE/TRUNCATE; no existing row touched |
| `vendor_sync_outage_state` table is operator-scoped fact | migration `:column shape` | `(operator_id, location_id, connection_id)` denormalized; FK to `(operator_id, location_id) → locations`; FK to `connection_id → connector_connection`; both `ON DELETE CASCADE` |
| Per-tenant RLS policy mirrors `connector_sync_log` | migration `:vendor_sync_outage_state_per_tenant` | `using (operator_id = app_current_operator() AND location_id = app_current_location())`; same `with check`; targets `service_role` |
| Operator-leading B-tree index | migration `:vendor_sync_outage_state_operator_idx` | `(operator_id, connection_id)` — CLAUDE.md "every fact-table B-tree index leads with operator_id" honored |
| Grants explicit | migration | `revoke all from public`; `grant select, insert, update, delete to service_role + forge_admin` |
| `timestamptz` (not banned variant) | migration | All timestamp columns are `timestamptz`; `TIMESTAMP WITHOUT TIME ZONE` absent (pinned by shape test) |
| Lock + statement timeouts | migration `:set local` | `statement_timeout='30s'` + `lock_timeout='5s'` |
| Transaction-wrapped | migration | `begin;` / `commit;` |
| Idempotent DDL | migration | `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS` + `DROP POLICY IF EXISTS / CREATE POLICY` |
| Optional observer seam (null-tolerant) | `main.dart:790` | `VendorSyncOutageObserver? outageObserver` — existing tests + non-prod paths unchanged |
| Observer fires AFTER `appendSyncLog` durably writes | sink `_CountingCanonicalSink` wrapper | Detector reads `connector_sync_log` so the row MUST be durable first; ordering pinned in tests |
| Decoupled from `lib/services/vendor_sync` | `main.dart` imports | Worker file does NOT import the detector; closure handed in from runtime bootstrap (deferred) |
| Detector logic: one email per outage window | detector state machine + tests | `notified_at IS NOT NULL` → no-op for subsequent failures in same window; pinned by 11-case state-machine test |
| Recovery clears state row | detector state machine + test | `poll_success` → DELETE state row; next outage window opens fresh; pinned by test |
| Default heuristics (N=3, M=30min) overridable | detector constructor | Constructor accepts overrides; defaults match OAuth refresh worker's cap-threshold posture |
| Audit action `vendor.sync_outage.alerted` | dispatcher impl | Append-only INSERT; one per outage email enqueued; `audit_logs_update_lint` clean |
| Append-only `audit_logs` | dispatcher impl | INSERT only; no UPDATE |
| Idempotency-key stable per outage window | dispatcher | `(operator_id, connection_id, outage_started_at)` triple; load-bearing dedupe is `vendor_sync_outage_state.notified_at` itself |
| `dart analyze --fatal-infos` clean | disclosed | No issues on all touched files |
| `migration_drift_scanner --strict-docs` clean | disclosed | Cutoff `202605131900_c_2_d_…` recognized |
| `migration_cutoff_lint` clean | disclosed | All 5 mirror sites match new cutoff |
| `audit_logs_update_lint` clean | disclosed | New action is INSERT-only |
| `advisor_proxy_size_lint` clean — **headroom unchanged at 88** | disclosed | 19812 lines, ceiling 19900 |
| `postgres_import_lint` clean | disclosed | Pre-push hook clean |
| `index_leading_column_lint` clean | disclosed | Pre-push hook auto-ran |
| `rls_policy_lint` clean | disclosed | Pre-push hook auto-ran |
| 39 new tests pass | disclosed | 11 detector + 8 dispatcher + 20 migration shape + 2 worker = 41 (per worker doc; 39 net) |
| No `--no-verify` traces | confirmed | Pre-push hooks ran clean |

## Executor 14-lens audit (re-verified)

| # | Lens | Verdict | Re-verification |
|---|---|---|---|
| L1 Product & Journey | OK | Operator picked WIRE for Draft D with explicit "first-failure-of-outage" detector requirement (per-row email would spam); this PR ships exactly that |
| L2 IA & Navigation | OK | Email links to `integrationConsoleUrl`; no in-app route change |
| L3 Data Model / Migration / RLS | OK | New `vendor_sync_outage_state` table with operator-scoped FKs + per-tenant RLS mirroring `connector_sync_log`; operator-leading B-tree index; no existing table touched |
| L4 Repository & Service | OK | New repository extends `OperatorScopedRepository`; tenant-bound writes; detector hangs off pure constructor injection |
| L5 Proxy / Route / Gateway | OK | `advisor_proxy.dart` untouched; new email path flows through existing `email_outbox` dispatcher |
| L6 Auth / Roles / Permissions | OK | `lib/auth/` 0-line diff; service-principal actor; `service_role` + `forge_admin` grants only |
| L7 Lifecycle | OK | Outage open → email → close lifecycle is per-connection; state row deleted on recovery; new outage opens fresh window |
| L8 Workers / Deploy / Health | OK | Polling tier (`integration_sync_worker`) gains optional observer seam; no behaviour change when null; production binding deferred |
| L9 UI / UX / Accessibility | OK | Existing `vendor_sync_error_alert.md` template (untouched) — body copy unchanged |
| L10 Performance | OK | Detector runs once per `appendSyncLog` write (per-tick per-row); reads + writes one state row; lookback bounded by M; no full-table scans |
| L11 Parity | OK | Mirrors `MfaFactorChangedNoticeDispatcher` orchestrator shape; same `email_outbox` shape; same `system.X_audit` action naming pattern |
| L12 Tests / Builds / Evidence | OK | 39 new tests; all lints clean (including migration_drift_scanner, migration_cutoff_lint, index_leading_column_lint, rls_policy_lint); all pre-push hooks ran |
| L13 Observability / Audit | OK | Audit row per outage email under `vendor.sync_outage.alerted`; SOC-2 hash chain preserved |
| L14 Docs / Tracker / Hygiene | OK | All 5 cutoff-mirror docs synced; rebase conflict expected with PR #626 on these 5 + POST_HARDENING count (known + documented below) |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `ab4606ef` | ✓ — `baseRefOid` confirms; MERGEABLE CLEAN (against current master; will need rebase if PR #626 merges first) |
| Pattern B both tables | ✓ — worker 8-lens + this 14-lens table |
| 15 files match PR body declaration | ✓ — `git diff --stat` confirms |
| `tool/advisor_proxy/advisor_proxy.dart` diff = 0 lines | ✓ — independent `git diff` |
| `lib/auth/` diff = 0 lines | ✓ |
| `pubspec.yaml` diff = 0 lines | ✓ |
| `WAVE_EXECUTION_LEDGER.md` diff = 0 lines | ✓ |
| Migration is additive only | ✓ — independent re-read of SQL confirms |
| Migration filename = `202605131900_c_2_d_vendor_sync_outage_state.sql` | ✓ — lex-after C-7a's `…1800` (when both land) |
| Per-tenant RLS policy uses `app_current_operator()` + `app_current_location()` wrappers | ✓ — STABLE LEAKPROOF wrappers per CLAUDE.md "bare `current_setting()` reads forbidden" |
| Operator-leading B-tree index present | ✓ — `vendor_sync_outage_state_operator_idx (operator_id, connection_id)` |
| `ON DELETE CASCADE` from `connector_connection` | ✓ — cleans up on connection delete |
| `ON DELETE CASCADE` from `locations` | ✓ — cleans up on location delete (via `(operator_id, location_id)` FK) |
| Detector decouples polling tier from `lib/services/vendor_sync` | ✓ — `main.dart` does NOT import detector |
| Production binding explicitly deferred | ✓ — worker disclosed; observer defaults to null |
| No `--no-verify` traces | ✓ |
| 39 new tests pass | ✓ disclosed |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied | ❌ — code-ready only |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — matches operator's 2026-05-13 WIRE pick for Draft D |
| Worker disclosure operator should know | ⚠ TWO disclosures: <br>(a) **Production runtime binding NOT shipped in this slice** — observer defaults to null; binding the Postgres-backed dispatcher is a separate small slice (same posture as `VendorLifecycleNotificationDispatcher` which existed before separately mounted). Email path is unreachable in production until follow-up. <br>(b) **Cutoff/count rebase needed**: PR #626 (C-7a, cutoff `…1800`) and PR #631 (this PR, cutoff `…1900`) both touch the 5 cutoff-mirror docs + POST_HARDENING pending count. Whichever merges first wins; the second needs rebase. Recommend merging #626 first (C-7a cutoff `…1800` lex-before #631's `…1900` advances cleanly). |
| Stacked PR | ❌ — base is master |
| **Schema / RLS touch** | **✓ TRIGGERED** — operator approval gate per CLAUDE.md |

**Decision**: **HOLD for explicit operator approval**. Audit verdict: approve-on-sign-off. Recommend merge order: PR #626 → PR #631 (cutoff monotonic advance).

## Cross-lane notes

- **Advances C-2** — Draft D WIRE landing (with seam ready but unwired in production) means matrix is C, F, D land-pending + E, G deleted ✓.
- **Schema touch + RLS** — operator approval gate triggered; new table with new policy. Migration is additive expand only; no existing table altered.
- **Production binding deferred** — the email path is unreachable in production until a follow-up slice wires the dispatcher via `buildWorkerRuntime`. Worker explicitly disclosed; same posture as `VendorLifecycleNotificationDispatcher` precedent.
- **Mirrors `MfaFactorChangedNoticeDispatcher` orchestrator shape** — same orchestrator + dispatcher + repository tri-layer; same `email_outbox` shape; same audit action naming convention.
- **Cutoff monotonic constraint** — if PR #631 merges before PR #626, then PR #626 must rebase to NOT roll the cutoff backward. Cleaner order: merge #626 → cutoff goes `…1700 → …1800`; merge #631 → cutoff goes `…1800 → …1900`.

## Findings

None blocking. Two non-blocking notes:
1. Production runtime binding for outage detector deferred to a follow-up slice; the email path is unreachable in production until that lands. Worker disclosure correct; should be tracked as the next C-2-D follow-up after this PR merges.
2. Merge-order: prefer PR #626 first to keep cutoff monotonic.

## Authority anchors

- `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` Draft D WIRE pick (operator 2026-05-13)
- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row C-2-D
- `tool/advisor_proxy/email_templates/vendor_sync_error_alert.md` — template the dispatcher feeds (untouched on master)
- `db/migrations/202605040000_phase_8_0_integration_framework.sql` — precedent for `(operator_id, location_id)` operator-scoped fact-table shape + per-tenant RLS
- `db/migrations/202605131700_c_1a_email_event_provider_id.sql` — precedent for migration header shape + lock+timeout idiom
- `tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart` — production binding pattern this slice's follow-up will mirror
- `tool/oauth_refresh_worker/main.dart` — N=3 cap-threshold precedent the detector mirrors
- CLAUDE.md "RLS-Ready Schema" + "Time Guardrails" + "Proxy & API Conventions" (idempotency) + "Agent-Led Slices"
- Operator's 2026-05-13 "keep 2fa, pos connection and vendor connection only" answer (covers slice-level WIRE approval; per-PR merge sign-off pending)

## Status

**HELD for operator approval.** Audit verdict: approve-on-sign-off. Recommend merge order: PR #626 → PR #631.
