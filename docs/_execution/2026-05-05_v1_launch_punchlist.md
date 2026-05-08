# V1 Launch Punchlist

Source: long-horizon systems audit run 2026-05-05.
Last trim: 2026-05-07 — completed items removed; only open items remain.
Done items live in `docs/archive/_execution/2026-05-05_v1_launch_punchlist_done_2026-05-07.md`.

Status legend: `[ ]` open · `[~]` in progress · `[-]` deferred post-V1.

Owner shorthand: **You** = operator/founder action · **Eng** =
Codex/Claude slice · **Legal** = external counsel · **Cloud** =
GCP/Azure/Firebase provisioning.

---

## 0 · Operator critical path

Production1 runtime is live. Detail + resume guide:
`docs/_execution/2026-05-06_v1_operator_punchlist_execution.md`.

### Firebase Auth action-domain switch (DNS)

- [ ] **Repoint `auth.feflow.org` from `forge-flow-staging.web.app` to
      `forge-flow-production1.web.app`.** DNS provider change; typical
      15–60 min propagation.
- [ ] **Set Firebase Auth `callbackUri = https://auth.feflow.org/auth/action`**
      in the `forge-flow-production1` Firebase console once DNS has
      propagated.
- [ ] **Validate (4 checks):**
      (a) `https://auth.feflow.org/auth/action` loads the branded
      production action page (not staging chrome).
      (b) `firebase-config.js` on that domain resolves to
      `forge-flow-production1`.
      (c) A password reset email's link opens the branded production
      action page.
      (d) Completing the password reset hits the production proxy URL
      (not staging).
      _Effort: ~1 hr active + DNS propagation. Blocks: cutover.0
      pre-flight._

### Other operator-blockers

- [ ] **Decide and approve the 2 remaining Production1 migration
      applies.** 18 of 20 are staging-verified; only
      `202605061800_phase_8_first_connection_backfill_jobs.sql` and
      `202605070000_phase_11W_7_operator_account_fields.sql` need an
      explicit operator decision. Runbook:
      `runbooks/phase_9_production1_migration_apply_runbook.md`.
      _Effort: 1–2 hrs after decision._
- [ ] **Escalate inbound-vendor T&Cs to counsel.** Draft is in
      `docs/phases/phase_9_8/`. Suggested deadlines: first pass
      2026-05-10, final 2026-05-13. Without signed T&Cs there is no
      `tos_acceptances` row → `cutover.2` cannot run.
      _Effort: 3–7 days external. Blocks: cutover.2._
- [ ] **Provision sandbox credentials for the live trio:** Lightspeed
      K-Series (developer.lightspeedhq.com), Libro (test account),
      QuickBooks Time (Intuit sandbox). Store each in GCP Secret
      Manager namespace `forge-flow-production-*` per the credential
      rotation runbook.
      _Effort: 2–3 days. Soft-blocks: `8.LSK.live.sandbox`,
      `8.LB.live.sandbox`, `8.QBT.live.sandbox`._

---

## 1 · Engineering still in scope

The Phase 8 sink-fanout, V1 closure dispatch (V1.A–G), 11W.0–.8, 11A
foundation + parity, mobile core (first-connect backfill, star/target,
weekly plan, mobile scope), and 7.58 depth wave have all merged. What
remains:

- [ ] **`8.spine-bridge-sink-fanout` follow-up adapter chips.** Each
      sink lane left an `adapter-side` follow-up to land inside its
      `*.live.sandbox` slice (tri-state covers, covers_source projection,
      hours_worked propagation, watermark resource alignment, etc.).
      Index: `docs/sink_follow_up.md`. These don't gate V1; they fold
      into the matching sandbox slice.

---

## 2 · Cutover sequence (gate-driven)

Plan: `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`.

- [ ] **`cutover.0` — Pre-flight readiness.** Read-only smoke tests on
      Production1 (schemas, firewall, DNS, RLS isolation, secrets).
      Harness: `tool/cutover/preflight_smoke.dart` (V1.G shipped).
      Requires Production1 provisioning + Firebase Auth switch + 2
      pending migrations applied.
- [ ] **`cutover.1` — Corpus load to production.** Voyage embeddings +
      Anthropic Contextual Retrieval. Cost approval gate (you must
      sign off on spend before execution).
- [ ] **`cutover.0b` — Tier-M perf gate.** Requires `cutover.1` corpus
      artifacts. Launch-blocking.
      `dart run tool/perf_gate/staging_console_probe.dart --run
      --enforce-budgets`.
- [ ] **`cutover.2` — First operator onboarding.** Vanessa created on
      production1. T&C-acceptance row captured. RLS isolation verified
      live. Tier caps seeded. Requires lawyer-signed T&Cs.
- [ ] **`cutover.3` — Traffic switch to production.** DNS / env-var flip.
- [ ] **`cutover.4` — 7-day stability watch.** Non-negotiable minimum
      before V1 launch declaration.
- [ ] **`cutover.5` — Post-launch hardening.** After V1 declaration.

---

## 3 · Vendor lifecycle (rolling, parallel — does NOT block V1)

Once trio reaches `production_credentialed`, V1 ships with three live
vendors and 14 "Coming soon" picker entries. Wave D fires per credential
arrival. Tracker:
`docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`.

### Wave 1 (trio — needed for launch UX)

- [ ] `8.LSK.live.sandbox` — Lightspeed K-Series sandbox verify
- [ ] `8.LSK.live.prod` — Lightspeed K-Series production credentialed
- [ ] `8R.LB.live.sandbox` — Libro sandbox verify
- [ ] `8R.LB.live.prod` — Libro production credentialed
- [ ] `8.S.QBT.live.sandbox` — QuickBooks Time sandbox verify
- [ ] `8.S.QBT.live.prod` — QuickBooks Time production credentialed

### Wave D (rolling, post-launch)

- [ ] Toast — partnership lane (~6–12 weeks)
- [ ] Clover — partnership lane (~1–3 weeks)
- [ ] Oracle Micros Simphony — partnership lane (~8–16 weeks)
- [ ] ADP — partnership lane (~12–24 weeks)
- [ ] Aloha — partnership lane
- [ ] Square — partnership lane
- [ ] 7shifts — partnership lane
- [ ] Revel — partnership lane
- [ ] Tock — partnership lane
- [ ] OpenTable — partnership lane
- [ ] SevenRooms — partnership lane (~4–8 weeks)
- [ ] Humanity — legacy auth
- [ ] Agendrix — public OAuth
- [ ] Push Operations — partnership lane (~4–6 weeks)

---

## 4 · Phase work in scope (queued, not launch-blocking by themselves)

- [ ] **`8.spine-bridge-live` connected-device + push proof.** Code
      components landed (see V1 closure dispatch + first-connect
      backfill). Awaiting (a) device + (b) staging apply of mobile push
      migration + (c) operator-blocked sandbox creds.
- [ ] **Doc 1 remaining post-V1:**
      - Item 6 — admin/web setting sync inventory (`audit.admin-web-setting-sync`).
      - Item 7 — connected-device E2E (`8.connected-device-e2e-smoke`); needs physical device.
      - Item 8 — live provider proof per vendor (same as Wave 1 / Wave D above).
      - Item 9 — push proof (`8.push-notification-connected-device-proof`); code-ready.
      - Item 10 — larger pressure suite (already on `cutover.0b`).
- [ ] **Phase 11A.8 / .9 / .10 — operations console final slices.**
      Support audit, cross-operator reads, user impersonation. Deferred
      post-launch unless escalated.
- [ ] **Group / region / company rollup truth.** Mobile location-level
      scope foundation merged 2026-05-07; rollup truth follows server
      rollup snapshots.

---

## 5 · Internal tech debt (chip at it; not launch-blocking)

### From the code-health audit

Closeout: 5-wave remediation closed 2026-05-08 — 52 findings across 41 PRs. Archived at `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`. Open chip-debt:

- [ ] **Domain-layer test coverage gap.** `lib/domain/` is 70 files / 5
      tests. Pure functions, trivially testable. Add a domain unit test
      alongside every slice that lands.
- [ ] **18 of 29 Postgres repositories without dedicated tests** (per
      `docs/POST_HARDENING_FOLLOWUPS.md` P2). Chip away during routine
      slices.
- [ ] **Large UI screens (>2000 LOC) — extract components** when next
      touched: `team_settings_section.dart` (2810),
      `corpus_admin_screen.dart` (2427),
      `observability_admin_screen.dart` (2353),
      `operator_location_admin_screen.dart` (2151),
      `forge_flow_app.dart` (~2.5k, growing),
      `tool/advisor_proxy/advisor_proxy.dart` (~15.9k, growing).
- [ ] **CODE_HEALTH residuals** — chapter closed 2026-05-08; remaining items consolidated into normal tracking surfaces. The bulk of open P0–P3 items lives in `docs/POST_HARDENING_FOLLOWUPS.md` (operational unpause, `backfill_dispatch.dart` bare-catch, widget contract violations, monolith splits, common worker base, two-slot key vs counter-store, SQLite singletons). AI-paused follow-ups in `docs/phases/phase_11a/phase_11a_decision_register.md` (cost-discipline levers, Voyage hardening, `labor_model.dart` rounding). Phase 8 deferred work in `phase_8_spine_bridge_plan.md` (watermark transactional discipline). Permission catalog additions in `docs/contracts/auth_permission_key_catalog.md`. Full historical record in `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`.

### From the architecture audit

- [ ] **Data Accuracy keyed service-period settings.** Replace
      hardcoded lunch/dinner/late covers-source columns with
      `data_accuracy_service_period_settings` before fourth/custom
      periods are operator-configurable. (Schema ships in
      `202605061701_…` migration; consumer code lane open.)

### From the tech-debt audit

- [ ] **Daily Azure Blob audit-anchor cron.** Anchor ran once on
      staging post-approval; not yet on a continuous schedule.
      Migration `202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql`
      should wire it. P1 hardening; not launch-blocking.
- [ ] **Worktree cleanup.** ~38+ stale worktrees in `.claude/worktrees/`.
      Disk-only impact. Codex sweep at next phase close.
- [ ] **Document an "unfreeze sequence."** AI / Outward / Barrio /
      sink-fanout / Production1 are paused. None blocks each other but
      the *order* of unfreeze matters. One-page doc capturing the
      sequence and cross-dependencies.

---

## 6 · Post-launch hardening (defer until after V1)

- [-] **Cloud KMS rollout.** Production hardening lane. V1 uses staging
      pgcrypto envelope. Runbook:
      `runbooks/admin_provider_credentials_kms_rollout_runbook.md`.
- [-] **Webhook key-rotation UI.** Ops rotates via CLI for V1.
- [-] **Inbound/outbound webhook DLQ observability tiles.** Tables
      exist; ops queries via SQL until volume justifies UI.
- [-] **Pod SIGTERM graceful drain across the fleet** beyond what
      CODE_HEALTH closeout shipped (proxy + MFA + audit anchor + email
      + realtime bridge). Cloud Run default handles V1 scale.
- [-] **AI advisor unfreeze (`11b`/`12.*`/`11A.3.*`/`11A.11`/`9.8`
      advisor portion/`10b`).** Provider abstractions are
      production-ready; no rewrites needed when signal arrives.
- [-] **Outward-vendor unfreeze (`8.5`, `11W.9`).** Inbound is V1;
      outbound writes are post-launch.
- [-] **Barrio unfreeze (`9.5.UX.*`, `9.75`, `lib/internal/barrio/**`,
      `lib/main_barrio.dart`).** Fully isolated; no F&F coupling.

---

## Cadence

- Re-audit before V1 declaration (re-run the 5 parallel deep-dives).
- Update this punchlist at every cutover gate transition.
- Archive at `cutover.4` close.
