# Next Wave Plan — Post-Codex Closeout → V1 Deploy

> **Created:** 2026-05-13, immediately after the post-Codex wave closed.
> **Status:** Active.
> **Owner:** Operator drives sequencing; orchestrator handles per-phase execution.

Companion to `docs/_indices/WAVE_EXECUTION_LEDGER.md` (which records the
*previous* wave's slice-level execution and is now in closed state). This
doc captures the *forward* plan from happy-state local validation through
V1 production deploy.

## The 5-step pipeline

```
1. Demo-validate full-stack local
   ↓
2. Tag happy state in git
   ↓
3. Refactor phase (R-1 + R-2)
   ↓
4. Re-test against happy state
   ↓
5. Mutate staging + Production1 (migrations + deploy)
```

Each step is operator-gated. The orchestrator does not advance the
pipeline without an explicit "go" — these are large changes whose
sequencing has business impact.

---

## Step 1 — Demo-validate full-stack local

**Goal:** prove the wave's code works end-to-end before changing
anything else. Catches regressions while the recovery cost is still
"restart container" rather than "rollback production".

**Prereqs (all met as of 2026-05-13):**

- Local Postgres bootstrapped per `runbooks/local_full_stack_setup_runbook.md` (container `forge-flow-pg16` on `localhost:5433`, 125 migrations applied, AGE + pgvector + pg_partman + pg_cron + pg_stat_statements + pg_diskann stub).
- Wave bugs W-1 + W-2 worked around locally (stubs + sed patch). Real fixes deferred to post-refactor.
- 4 follow-up merges landed (PRs #639 / #640 / #641 / #642 / #643) cleaning up wave artifacts.

**What to exercise:**

- Boot proxy: `dart run tool/advisor_proxy/main.dart` against `POSTGRES_URL=postgresql://postgres:forge_flow_local@localhost:5433/forge_flow`.
- Boot operator-web in Chrome: `flutter run -t lib/main_operator_web.dart -d chrome --dart-define=OPERATOR_WEB_PROXY_BASE_URI=http://localhost:8080`.
- Operator click-paths: at minimum the demo walkthrough covered in `docs/_walkthroughs/7.58.UX.5.md` and the surfaces the wave touched (Default Role Catalog admin, B6 Benchmarks Hierarchy, B8 Audit Log Hierarchy filter, B8.b operator-web parity pane, C-7 Adaptive 2FA CTA, C-4 Demo-Live Master Switch, C-9 catalog-driven inbox).
- Mobile flavors: `scripts\run_flutter_dev.ps1 -App forgeflow` against the connected Samsung device.

**Exit criteria:**

- All happy-path click-paths succeed without 500s, 401s, or visible UI regression.
- `dart analyze --fatal-infos` clean against current master.
- All wave-touched test suites green: `test/proxy/`, `test/admin/`, `test/widgets/`, `test/auth/`, `test/tool/integration_sync_worker/`.

**Operator gates:** none — orchestrator can drive the validation work, but
the operator does the final "yes this looks right" walkthrough.

---

## Step 2 — Tag happy state in git

**Goal:** durable comparison point for the refactor that follows.

**Action:**

```bash
git tag happy-state-2026-05-13 <commit-hash>
git push origin happy-state-2026-05-13
```

(Replace `<commit-hash>` with master HEAD at the moment Step 1's exit
criteria are met.)

Plus snapshot any operator-edited demo SQLite state to a known path so
the same demo click-paths can replay identically after refactor.

**Operator gates:** operator decides exactly when to tag and what commit
to anchor.

---

## Step 3 — Refactor phase (R-1 + R-2)

**Goal:** structural extraction without behavior change. Lower governance
debt accumulated through the wave's pace.

The refactor scope is already captured in
`docs/POST_HARDENING_FOLLOWUPS.md` under the "Refactor phase scope" header
(via PR #639). Two items:

### R-1 — Operator-web ceiling + `my_account_screen.dart` decomposition

- Codify operator-web ceiling in `tool/operator_web_size_lint.dart` mirroring `tool/advisor_proxy_size_lint.dart` shape.
- Decompose `my_account_screen.dart` into sibling panes (`my_account_security_pane.dart`, `my_account_mfa_pane.dart`, `my_account_sessions_pane.dart`, `my_account_profile_pane.dart`).
- Parent stays as a thin tab-host.
- Pure structural extraction. Zero behavior change.

### R-2 — Advisor proxy helper extraction + ceiling discipline

- Promote envelope helpers (`_readJsonBody`, `_writeJson`, `_resolveOperatorContextOrWrite`, etc.) to `tool/advisor_proxy/route_helpers.dart` sibling.
- Migrate B2.1 + B11.2 + C-4 hybrid dispatchers to Pattern A pre-check shape (`router.tryHandle(HttpRequest)` returning `Future<bool>`).
- Lower `kAdvisorProxyMaxLines` to match new (smaller) monolith size + ~200 lines of forward headroom.
- Codify in CLAUDE.md: **ceiling raises require operator approval** like auth-critical / RLS-touching / schema-touching slices.

**Operator gates:** each sub-slice opens its own operator-gated PR per
CLAUDE.md "Agent-led slices" (R-2 touches the proxy, R-1 touches
operator-web — both are governance-sensitive).

---

## Step 4 — Re-test against happy state

**Goal:** catch any regression introduced by R-1 + R-2 before mutating
production.

**Actions:**

- Re-run the same Step 1 demo click-paths against the post-refactor build.
- Diff `dart analyze --fatal-infos` output against happy-state baseline — must still be 0 errors, no new wave-introduced regressions.
- Re-run wave-touched test suites — same green count as happy state.
- Spot-check the surfaces the refactor touched (panes of `my_account_screen`, the 3 hybrid dispatchers in `advisor_proxy`).

**Exit criteria:** zero behavior regressions vs happy state.

**Operator gates:** orchestrator runs the comparison; operator signs off
on "we are not worse than happy state."

---

## Step 5 — Mutate staging + Production1

**Goal:** ship the wave's code + the refactor + the wave-bug fixes to
real environments.

This step has multiple sub-stages, each operator-gated.

### 5a — Pre-deploy fixes (must land before migrations)

- **W-1 fix slice** — new Phase 8 base-schema migration `CREATE TABLE`-ing the 4 legacy fact tables (`shift_records`, `cover_facts`, `labor_punches`, `reservation_facts`). Operator-gated, schema-touching. See `docs/POST_HARDENING_FOLLOWUPS.md` "Wave bugs surfaced 2026-05-13 by local apply".
- **W-2 fix slice** — single-char migration patch (tagged dollar quote) on `db/migrations/202605081100_partman_maintenance_hourly_cron.sql`. Operator-gated, migration-touching.

### 5b — Environment wires

- **SendGrid pubkey** — `SENDGRID_EVENT_WEBHOOK_PUBKEY_PEM` to Cloud Run env (production-only secret; defer to deploy day).
- **Live operator-web Firebase mixin** — ~10 LoC code change wiring `WebAuditLogHierarchyGatewayProvider` on the Firebase deploy source. Operator decides location.

### 5c — Production1 migration apply

- Follow `runbooks/phase_9_production1_migration_apply_runbook.md` end-to-end.
- 46 migrations pending (per `docs/POST_HARDENING_FOLLOWUPS.md` "P0 — Production1 Migration Apply Gap" table).
- Cutoff file on master: `202605131900_c_2_d_vendor_sync_outage_state.sql`.
- Operator-gated. Operator drives the actual apply.

### 5d — Deploy + verify

- Cloud Run deploy (proxy + operator-web + admin-console).
- Firebase hosting deploy (operator-web static + admin-console static).
- Mobile builds promoted (forgeflow + barrio APKs/AABs).
- Post-deploy smoke: SendGrid webhook receives + verifies, operator-web `/roles/explainer` renders 11 categories (post-B-2), admin Default Role Catalog publish idempotent (post-B-1), local-time on closed shift rows correct (Phase 7.55 time boundaries).

**Operator gates:** every sub-stage 5a / 5b / 5c / 5d.

---

## Cross-references

- Wave closeout that motivated this plan: `docs/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md`.
- Wave bugs that must land before Production1: `docs/POST_HARDENING_FOLLOWUPS.md` "Wave bugs surfaced 2026-05-13 by local apply".
- Refactor scope: `docs/POST_HARDENING_FOLLOWUPS.md` "Refactor phase scope (queued from 2026-05-13 post-Codex wave closeout)".
- Advisory-lock posture (reconciled): `docs/POST_HARDENING_FOLLOWUPS.md` "Advisory-lock posture — reconciled 2026-05-13".
- Local stack setup: `runbooks/local_full_stack_setup_runbook.md`.
- Production1 migration apply: `runbooks/phase_9_production1_migration_apply_runbook.md`.
- CI status (currently dark): see `~/.claude/projects/.../memory/feedback_ci_dark_until_2026_06_01.md`. CI reactivates 2026-06-01.

## Open operator action items (post-wave)

Carried from the C-12 closeout audit; this list collapses once Steps 1-5
land:

| # | Item | Step that closes it |
|---|---|---|
| 1 🔴 | SendGrid pubkey wire | 5b |
| 2 🔴 | Production1 migration apply | 5c |
| 3 🟡 | Mailosaur preview-CI secrets | ✅ Done by Codex 2026-05-13 |
| 4 🟡 | Live operator-web Firebase mixin | 5b |
| W-1 | Phase 8 legacy fact tables CREATE | 5a |
| W-2 | partman dollar-quote fix | 5a |
| (B-1 + B-2: done, merged via PRs #640 + #643) | | |
| (R-1 + R-2: captured for refactor) | | 3 |
| (Advisory-lock memory: reconciled via PR #641) | | (closed) |
