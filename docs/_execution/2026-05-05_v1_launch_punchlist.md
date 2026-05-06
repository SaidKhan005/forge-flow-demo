# V1 Launch Punchlist — 2026-05-05

Source: long-horizon systems audit run 2026-05-05 (architecture / code health
/ data integrity / V1 readiness / tech-debt parallel deep-dives).

Status legend: `[ ]` open · `[~]` in progress · `[x]` done · `[-]` deferred
post-V1.

Owner shorthand: **You** = operator/founder action · **Eng** = Codex/Claude
slice · **Legal** = external counsel · **Cloud** = GCP/Azure/Firebase
provisioning (you, but distinct workstream).

---

## 0 · This week (2026-05-05 → 2026-05-12) — critical path

These are the items where **every day of delay = one day of V1 slip**. Most
are external; engineering can run in parallel.

### Operator (You)

- [ ] **Start GCP/Firebase Production1 provisioning.** Cloud Run service +
      static egress VPC + Firebase apps (mobile + web) + GCP Secret Manager
      namespace `forge-flow-production-*`. Spec:
      `docs/phases/phase_production_cutover/production1_staging_parity_baseline_2026-05-03.md`.
      _Effort: 5–7 days. Blocks: cutover.0._
- [ ] **Apply 2 pending Postgres migrations to Production1:**
      `db/migrations/202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql`
      and
      `db/migrations/202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql`.
      Runbook: `runbooks/phase_9_production1_migration_apply_runbook.md`.
      Both additive-safe (GRANT-only, verified on staging 2026-05-03 / -04).
      _Effort: 1–2 days. Blocks: production admin console writes._
- [ ] **Escalate inbound T&Cs to lawyer.** Draft is in `docs/phases/phase_9_8/`.
      Set explicit deadlines: first pass 2026-05-10, final 2026-05-13. Without
      signed T&Cs there is no `tos_acceptances` row → `cutover.2` cannot run.
      _Effort: 3–7 days external. Blocks: cutover.2._
- [ ] **Provision DNS + TLS for `app.forgeflow.app` and `mail.forgeflow.app`.**
      Required for operator web console + SendGrid domain auth.
      _Effort: 1–2 days. Blocks: 11W shell + email sends._
- [ ] **Stand up SendGrid domain + DKIM/SPF/DMARC.** Free tier (100 emails/day)
      covers V1. PR #88 already wired the email provider gateway.
      _Effort: 1–2 days. Blocks: operator invitations._
- [ ] **Provision sandbox credentials for the live trio:** Lightspeed K-Series
      (developer.lightspeedhq.com), Libro (test account), QuickBooks Time
      (Intuit sandbox).
      _Effort: 2–3 days. Soft-blocks: `*.live.sandbox` slices._

### Engineering decision (You, single signal)

- [ ] **Unpause `8.spine-bridge-sink-fanout`.** 14 file-disjoint Postgres sink
      lanes for the remaining Wave B vendors. Without these, "engineering-
      complete Phase 8" doesn't translate into operator data on launch day.
      Plan: `docs/phases/phase_8/phase_8_spine_bridge_plan.md`.
      _Effort: 3–4 days parallel. Blocks: cutover.0b perf gate (which needs
      real data in production Postgres for the Tier-M load test)._

### Engineering kickoff (Eng)

- [ ] **Generate prompts + spin up worktrees for `11W.0`, `11W.7`, `11W.8`.**
      Web shell + magic-link onboarding · Account / Business setup · Vendor
      Connections widget mount. Three lanes parallel; web shell is a separate
      Flutter Web entry (`lib/main_operator_web.dart` mirroring
      `lib/main_admin.dart`), not a web build of the mobile app.
      _Effort: 15–20 days across 3 lanes. Blocks: cutover.2 operator
      onboarding._

---

## 1 · Engineering critical path (2026-05-12 → ~2026-05-26)

- [ ] **`11W.0` — Web shell + magic-link onboarding.** Brand theme + auth
      gateway reuse from `lib/main_admin.dart` pattern. Thin HTTP client; no
      offline storage.
- [ ] **`11W.7` — Account / Business setup (minimal).** Operator + location
      bootstrap forms. Reuse Phase 11A admin gateways.
- [ ] **`11W.8` — Vendor Connections widget mount.** Mount the existing
      vendor-connections widget tree (the same one `lib/main_admin.dart`
      uses) inside the operator web shell.
- [ ] **`8.spine-bridge-sink-fanout` (14 lanes).** File-disjoint, parallelizable.
      Each lane writes one vendor's canonical facts into Postgres tables
      (`cover_facts`, `labor_punches`, `reservation_facts`).
- [x] **Phase 7.58 depth wave — closed 2026-05-05 on master @ `699a45f`.**
      All 5 slices ACCEPT: `7.58.UX.6` / `.UX.8` / `.cross-axis.0` / `10.5.6` /
      `.UX.7+9`. The `.UX.6` legacy widget-test alignment closed via `3154679`
      (PR #144); `flutter test test/variance_history_widget_test.dart` →
      70/70 PASS. Audit: `docs/_execution/2026-05-05_depth_wave_audit.md`.
      Renderer + analyzer-additive only — engine math, persistence, sync,
      Concern A all signature-stable across the wave. Phase 7.58
      advisor-depth-complete.

---

## 2 · Cutover sequence (gate-driven, not date-driven)

- [ ] **`cutover.0` — Pre-flight readiness.** Read-only smoke tests on
      Production1 (schemas, firewall, DNS, RLS isolation, secrets). Requires
      Production1 provisioning + 2 pending migrations applied.
- [x] **`cutover.0a` + `0a.pg` — CMK provisioning.** Done 2026-05-01.
- [ ] **`cutover.1` — Corpus load to production.** Voyage embeddings +
      Anthropic Contextual Retrieval. Has cost approval gates (you must sign
      off on spend before execution).
- [ ] **`cutover.0b` — Tier-M perf gate.** Requires `cutover.1` corpus
      artifacts. Launch-blocking. Run
      `dart run tool/perf_gate/staging_console_probe.dart --run
      --enforce-budgets`.
- [ ] **`cutover.2` — First operator onboarding.** Vanessa created on
      production1. T&C-acceptance row captured. RLS isolation verified
      live. Tier caps seeded. Requires lawyer-signed T&C.
- [ ] **`cutover.3` — Traffic switch to production.** DNS / env-var flip.
- [ ] **`cutover.4` — 7-day stability watch.** Non-negotiable minimum
      before V1 launch declaration.

---

## 3 · Vendor lifecycle (rolling, parallel — does NOT block V1 launch)

Once trio reaches `production_credentialed`, V1 ships with three live
vendors and 14 "Coming soon" picker entries. Wave D fires per credential
arrival. Tracker: `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`.

### Wave 1 (trio — needed for launch UX)

- [ ] `8.LSK.live.sandbox` — Lightspeed K-Series sandbox verify
- [ ] `8.LSK.live.prod` — Lightspeed K-Series production credentialed
- [ ] `8.LB.live.sandbox` — Libro sandbox verify
- [ ] `8.LB.live.prod` — Libro production credentialed
- [ ] `8.QBT.live.sandbox` — QuickBooks Time sandbox verify
- [ ] `8.QBT.live.prod` — QuickBooks Time production credentialed

### Wave D (rolling, post-launch)

- [ ] Toast — partnership lane (~6–12 weeks)
- [ ] Clover — partnership lane (~1–3 weeks)
- [ ] Oracle Micros Simphony — partnership lane (~8–16 weeks)
- [ ] ADP — partnership lane (~12–24 weeks)
- [ ] Aloha — partnership lane
- [ ] NCR — partnership lane
- [ ] Square — partnership lane
- [ ] 7shifts — partnership lane
- [ ] Revel — partnership lane
- [ ] Tock — partnership lane
- [ ] OpenTable — partnership lane
- [ ] (remaining 3 per `phase_8_live_rollout_plan.md`)

---

## 4 · Phase work in scope (queued, not launch-blocking by themselves)

- [ ] **Phase 10a — Real-time infrastructure.** Webhooks → NOTIFY → Pub/Sub
      bridge. Closes the 5-minute freshness gap post-launch. `.3`/`.4`/`.5`
      queued.
- [ ] **Phase 11A.10 — operations console final slices.** `.8` (support
      audit), `.9` (cross-operator reads), `.10` (user impersonation) — all
      not started; deferred post-launch unless escalated.
- [ ] **Phase 11A.12 / .13 / .14 — cross-operator parity** (Members /
      Hierarchy / audited support actions). Un-deferred 2026-05-05; queues
      after Phase 7 + Phase 10 close, lockstep with `11W.1`–`11W.6` web
      parity.

---

## 5 · Internal tech debt (chip at it; not launch-blocking)

### From the code-health audit

- [ ] **Domain-layer test coverage gap (highest-value internal debt).**
      `lib/domain/` is 70 files / 5 tests. Pure functions, trivially
      testable, formula heart of the product. Add a domain unit test
      alongside every Phase 7.58 slice that lands. Target: domain becomes
      the most-tested module by AI-unfreeze time, not the least.
- [ ] **`vendor_connections_widget.dart` (2261 LOC, 4 bare `catch (e)`).**
      Extract child components; standardize error handling. Largest UI
      file with concentrated catch-all blocks. Worth doing before live
      rollout starts touching it heavily.
- [ ] **18 of 29 Postgres repositories without dedicated tests** (per
      `docs/POST_HARDENING_FOLLOWUPS.md` P2). Chip away during routine
      slices.
- [ ] **Delete 4 confirmed unused public classes** (P3 in
      POST_HARDENING_FOLLOWUPS):
      - `AuditLogExportResult` in `lib/services/admin/audit_log_csv_export.dart`
      - `MfaOverrideChange` in `lib/services/admin/mfa_policy_editor_controller.dart`
      - `MatrixCellChange` in `lib/services/admin/role_permission_matrix_controller.dart`
      - `CorpusCloudLoadResult` in `lib/services/advisor_corpus_admin_service.dart`
- [ ] **Large UI screens (>2000 LOC) — extract components** when next
      touched: `team_settings_section.dart` (2810), `corpus_admin_screen.dart`
      (2427), `observability_admin_screen.dart` (2353),
      `operator_location_admin_screen.dart` (2151).

### From the architecture audit

- [ ] **`business_date DATE` denormalized columns on Phase 8 integration
      tables.** Currently absent (low risk — those are scaffolding tables,
      not operational facts). Wire when canonical-fact materialization
      lands in spine-bridge follow-ups.

### From the tech-debt audit

- [ ] **Daily Azure Blob audit-anchor cron.** Anchor ran once on staging
      post-approval; not yet on a continuous schedule. Migration
      `202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql` should wire it.
      P1 hardening; not launch-blocking.
- [ ] **Worktree cleanup.** 38 stale worktrees in `.claude/worktrees/`.
      Disk-only impact. Codex sweep at next phase close.
- [ ] **Document an "unfreeze sequence."** AI / Outward / Barrio /
      sink-fanout / Production1 are paused. None blocks each other but the
      *order* of unfreeze matters. One-page doc capturing the sequence and
      cross-dependencies.

---

## 6 · Post-launch hardening (defer until after V1)

- [-] **Cloud KMS rollout.** Production hardening lane. V1 uses staging
      pgcrypto envelope. Runbook:
      `runbooks/admin_provider_credentials_kms_rollout_runbook.md`.
- [-] **Webhook key-rotation UI.** Ops rotates via CLI for V1.
- [-] **Inbound/outbound webhook DLQ observability tiles.** Tables exist;
      ops queries via SQL until volume justifies UI.
- [-] **Advisory locks for OAuth refresh.** Low contention at V1 scale.
- [-] **Pod SIGTERM graceful drain.** Cloud Run default handles V1 scale.
- [-] **AI advisor unfreeze (`11b`/`12.*`/`11A.3.*`/`11A.11`/`9.8` advisor
      portion/`10b`).** Provider abstractions are production-ready; no
      rewrites needed when signal arrives.
- [-] **Outward-vendor unfreeze (`8.5`, `11W.9`).** Inbound is V1; outbound
      writes are post-launch.
- [-] **Barrio unfreeze (`9.5.UX.*`, `9.75`, `lib/internal/barrio/**`,
      `lib/main_barrio.dart`).** Fully isolated; no F&F coupling.

---

## Cadence

- Re-audit before V1 declaration (re-run the 5 parallel deep-dives).
- Update this punchlist at every cutover gate transition.
- Archive at `cutover.4` close.
