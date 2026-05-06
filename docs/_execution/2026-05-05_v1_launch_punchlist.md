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

Production1 runtime is already live behind staging-style chrome. Detail
+ resume-after-context-break in
`docs/_execution/2026-05-06_v1_operator_punchlist_execution.md`.

**Done (no operator action needed):**

- [x] GCP / Cloud Run / Secret Manager / VPC provisioning.
- [x] Firebase project (`forge-flow-production1`) + mobile + web +
      admin app registration.
- [x] Production1 Postgres CMK (`forge-flow-production1-pg-cmk`,
      Canada Central, PG 16); `cutover.0a` / `0a.pg` closed
      2026-05-01.
- [x] DNS + TLS for `app.forgeflow.app` (operator-web production
      domain) and `mail.forgeflow.app` (production email domain).
- [x] SendGrid domain auth + DKIM / SPF / DMARC for the production
      sender. `noreply@feflow.org` is already clean enough for V1;
      no rebrand to `noreply@forgeflow.app` is required.
- [x] 10 of 12 follow-up Postgres migrations applied + verified on
      staging.

**Main remaining DNS action — Firebase Auth action-domain switch:**

- [ ] **Repoint `auth.feflow.org` from `forge-flow-staging.web.app`
      to `forge-flow-production1.web.app`.** DNS provider change;
      typical 15–60 min propagation.
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
      (d) Completing the password reset hits the production proxy
      URL (not staging).
      _Effort: ~1 hr active + DNS propagation. Blocks: cutover.0
      pre-flight._
      _Cosmetic: Firebase email-template body styling is a nice-to-have
      gated on Firebase's email-template gate; not launch-blocking._

**Remaining non-DNS blockers:**

- [ ] **Decide and approve the 2 remaining Production1 migration
      applies.** 10 of 12 are staging-verified; only
      `202605061800_phase_8_first_connection_backfill_jobs.sql` and
      `202605070000_phase_11W_7_operator_account_fields.sql` need an
      explicit operator decision before staging-apply +
      Production1-apply runs. Runbook:
      `runbooks/phase_9_production1_migration_apply_runbook.md`.
      _Effort: 1–2 hrs after decision. Blocks: first-connect-backfill
      orchestration on production + operator-web Account editor writes
      on production._
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
      _Effort: 2–3 days, mostly waiting on vendor turnaround.
      Soft-blocks: `8.LSK.live.sandbox`, `8.LB.live.sandbox`,
      `8.QBT.live.sandbox`._

### Engineering kickoff (Eng)

- [x] **`11W.0` / `.7` / `.8` ACCEPT 2026-05-06.** Operator web
      shell + Account / Business Timing editors + Vendor Connections
      mount all merged + live-wiring fix landed. See
      `docs/_execution/2026-05-06_v1_closure_dispatch_plan.md`.
- [~] **Claude V1 closure dispatch (V1.A/B/E/F/G running NOW;
      V1.C/D queued post-Codex).** See dispatch plan for the seven
      file-disjoint lanes Claude is running on top of (a) the user's
      sink-fanout work and (b) Codex's `8.star-target-server-truth`
      sprint.

---

## 1 · Engineering critical path (2026-05-12 → ~2026-05-26)

- [x] **`11W.0` — Web shell + magic-link onboarding (ACCEPT 2026-05-06, A1).**
      `web_session_gateway` facade landed at `f5a94c08`; full shell + onboarding
      pre-existed.
- [x] **`11W.7` - Account / Business setup (ACCEPT 2026-05-06, A2).**
      Operator-scoped routes `/v1/operator/account` + `/v1/operator/business-timing-profiles`
      mounted in `tool/advisor_proxy/operator_routes.dart` with Idempotency-Key
      validation + per-tenant RLS. Migration
      `202605070000_phase_11W_7_operator_account_fields.sql` adds
      `logo_url`/`locale_tag`/`week_start_day`/`rollover_hour`. Validator
      parity confirmed against migration CHECKs (27 validator + 24 proxy
      route + 27 my_account_screen + 4 firebase_auth_source tests pass).
      `business_timing_editor_screen.dart` + `service_period_editor.dart`
      ship in `lib/operator_web/`. Production audit sink writes real
      `audit_logs` rows via `RepositoryOperator*WriteGateway`. Live wiring
      fix `11W.7.live-wire` (this session) mixed
      `OperatorWebAccount/BusinessTimingWriteGatewayProvider` into
      `FirebaseOperatorWebAuthSource`.
- [x] **`11W.8` — Vendor Connections widget mount (ACCEPT 2026-05-06, A3).**
      `075fde54` — `OperatorWebVendorConnectionsResolver` + honest no-location
      state.
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
      Production1 provisioning + 3 pending migrations applied.
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

- [x] **Phase 10a — Real-time infrastructure (CLOSED for V1 2026-05-06).**
      `.0`/`.1`/`.2`/`.3`/`.4`/`.5` + `UX.0`/`UX.1` ACCEPT. Webhooks → NOTIFY
      → Pub/Sub bridge complete; `last_event_id` replay on reconnect; Q22
      tripwires + retention sweep. Bridge worker byte-identical across the
      wave. Phase 10b (offline + optimistic concurrency) deferred post-launch.
- [x] **Phase 11W parity slices `.1`–`.6` ACCEPT 2026-05-06.** Members /
      Roles / Hierarchy / Sessions / Audit / Security web surfaces parity
      with mobile Settings.
- [x] **Phase 11A cross-operator parity `.12`/`.13`/`.14` ACCEPT 2026-05-06.**
      Members + Invites / Roles + Hierarchy + Sessions / Audit log + audited
      support actions.
- [x] **`8.business_date_denorm` ACCEPT 2026-05-06.** Three Phase 8 tables
      (`connector_sync_log`, `inbound_webhook_dead_letter`, `sanity_log`) now
      carry denormalized `business_date DATE` with operator-leading indexes
      and BEFORE-INSERT triggers.
- [ ] **`8.spine-bridge-sink-fanout` (2 of 14 sink lanes remain).** Aloha
      (`.1.AL`), Tock (`.TC`), Humanity (`.HM`), Square (`.SQ`), Toast
      (`.TS`), Push Operations (`.PU`), Agendrix (`.AG`), Clover (`.CL`),
      ADP (`.ADP`), Revel (`.RV`), SevenRooms (`.SR`), Lightspeed LSK
      (`.LSK`) all ACCEPT 2026-05-06. Remaining: Oracle Simphony (POS);
      OpenTable (reservation); plus `.7S.upgrade` 7shifts
      `/reports/hours_and_wages` adapter capability extension.
      File-disjoint; parallelizable.
- [x] **`8.first-connect-backfill-wire-in` ACCEPT 2026-05-06 (PR #195,
      `aa7a58d2`).** Lanes 0–5 closed: durable backfill job seam
      (`93bfd85f`), connect enqueue (`11ea8e70`), worker dispatch
      (`a53953c2`), canonical-fact post-commit projector (`4816b0a8`),
      mobile/proxy backfill status (`3238002a`), proof harness +
      walkthrough + closeout doc (`b120b430`). The production canonical-
      fact write seam now invokes both `CanonicalFactToClosedShiftInputAggregator`
      and `OpenShiftSnapshotProjector`, closing the dormancy gap from the
      2026-05-06 5-agent audit. CI was blocked by the GitHub Actions
      billing/spending-limit annotation, so the local proof gates
      (analyzer + index-leading + RLS + Postgres-import + drift + cutoff
      + `git diff --check` + 118-test focused suite) were the gating
      evidence.
- [~] **`8.spine-bridge-live` + closed timing provenance — components
      landed; production wire-in CLOSED via `8.first-connect-backfill-wire-in`.**
      Lane 0 schema (`9740488f`
      migration `202605061700_phase_8_timing_provenance_shift_records.sql`)
      + Lane 1 builder/writer (`da1484a0`) + Lane 2 V/H/L label resolver
      (`976e8d7e`) + Lane 3 `OpenShiftSnapshotProjector` (`c9a3de6b`) +
      Lane 4 mobile/proxy enrichment (`e3c196bf`) + Lane 5 proof doc
      (`389704bf`) merged 2026-05-06 with passing tests against fakes.
      The earlier 5-agent dormancy audit finding (aggregator + projector
      unwired in production) was resolved by the
      `canonical_fact_post_commit_projector.dart` seam shipped in
      Lane 3 of `8.first-connect-backfill-wire-in` (`4816b0a8`); the
      production canonical-fact write seam now invokes both for completed
      and current/open service periods. Live-half closeout audit lives in
      `docs/_execution/2026-05-06_8_first_connection_backfill_proof.md`.
      Both halves closed via Codex's `8.first-connect-backfill-wire-in`
      sprint (`canonical_fact_post_commit_projector.dart`).
- [ ] **`8.star-target-server-truth` PLANNED 2026-05-06 — next mobile
      core sprint (Codex).** Moves selected star shifts, manager override
      state, target cycles, and active target profiles from local-only/
      mobile cache truth to server truth. Closes Doc 1 items 1–3 (server-
      backed selected star shifts and manager override + server target
      cycles and active target profiles). Lane 0 = decision schema +
      Postgres repositories; Lanes 1–4 in parallel; Lane 5 proof harness.
      Authority: `docs/contracts/mobile_core_star_target_truth_contract.md`,
      `docs/_execution/2026-05-06_mobile_core_star_target_truth_sprint_plan.md`.
- [ ] **Claude V1 closure dispatch (2026-05-06) — seven lanes.**
      Authority: `docs/_execution/2026-05-06_v1_closure_dispatch_plan.md`.
      Five lanes launched NOW (V1.A/B/E/F/G); two queued (V1.C/D) for
      after Codex's `8.star-target-server-truth.Lane 0` / `Lane 3`.
      - **V1.A `8.closed-row-proxy-timing-provenance`** — V1-blocking;
        mirrors open-snapshot timing triplet onto closed-row proxy
        SELECT/mapper so mobile actually consumes Lane 0's stored
        provenance. Closes one P1 follow-up.
      - **V1.B `8.timing-provenance-fk-posture`** — V1-blocking; flips
        `shift_records` profile/version FKs to `ON DELETE SET NULL` so
        Operator Web timing editor can replace profiles without
        blocking on closed rows. Closes one P1 follow-up.
      - **V1.C `8.weekly-plan-server-truth.lane0`** — Doc 1 item 4
        Lane 0 only (additive Postgres schema + repos for
        `weekly_plan_snapshots` + `forecast_context`); waits for
        Codex Lane 0 to land. Authority:
        `docs/contracts/mobile_core_weekly_plan_server_truth_contract.md`.
      - **V1.D `8.mobile-scope-foundation`** — Doc 1 item 5 Lane 0
        only (proxy `business_scopes` route + local active-scope
        repo); waits for Codex Lane 3 to land. Authority:
        `docs/contracts/mobile_core_business_scope_contract.md`.
      - **V1.E `8.live.vendor-now-available-fanout`** — V1-blocking
        prerequisite for any `*.live.prod` slice; ships email
        template + dispatcher + fan-out worker.
      - **V1.F `8.connector-backfill-jobs.test-coverage`** — chip-debt;
        closes one row of "18 of 29 repositories without tests"
        cohort.
      - **V1.G `cutover.0.preflight-runbook-codification`** — operator-
        unblock helper; codifies cutover.0 pre-flight as an
        executable harness.
- [ ] **Doc 1 remaining post-V1 (queued):** Item 6 admin/web setting
      sync inventory · Item 7 connected-device E2E · Item 8 live
      provider proof per vendor · Item 9 push proof · Item 10 larger
      pressure suite (already on `cutover.0b`). Each requires its own
      sprint plan; not V1-launch-blocking.
- [ ] **Phase 11A.8/.9/.10 — operations console final slices.** Support
      audit, cross-operator reads, user impersonation — deferred post-launch
      unless escalated.

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
- [x] **4 "unused public classes" — verified-keep, not dead** (Wave B4,
      2026-05-06; see updated P3 in `docs/POST_HARDENING_FOLLOWUPS.md`).
      Each class is the return type of a unit-tested sibling method
      (`AuditLogCsvExport.export`, `MfaPolicyEditorState.diff`,
      `RolePermissionMatrixController.diff`,
      `AdvisorCorpusAdminService.attemptCloudLoad`); deleting any in
      isolation would break test compilation.
- [ ] **Large UI screens (>2000 LOC) — extract components** when next
      touched: `team_settings_section.dart` (2810), `corpus_admin_screen.dart`
      (2427), `observability_admin_screen.dart` (2353),
      `operator_location_admin_screen.dart` (2151).

### From the architecture audit

- [x] **`business_date DATE` denormalized columns on Phase 8 integration
      tables.** Closed 2026-05-06 via `c61c2ea7` (`8.business_date_denorm`):
      `connector_sync_log`, `inbound_webhook_dead_letter`, `sanity_log`
      now carry denormalized `business_date` with operator-leading indexes
      + BEFORE-INSERT triggers (UTC fallback when timezone null).
- [~] **Timing provenance on closed records — components landed,
      production wire-in PENDING.** Schema migration
      `202605061700_phase_8_timing_provenance_shift_records.sql`,
      `ClosedShiftInput`/`ShiftRecord` model additions,
      `ShiftFactBuilder.fromClosedShiftInput` propagation,
      `PostgresShiftRecordWriter` Concern A preservation, and
      Variance/History/Learn label resolver all landed 2026-05-06 with
      passing tests. **Audit found the production aggregator
      (`CanonicalFactToClosedShiftInputAggregator`) is referenced only
      from `test/`; no production call site instantiates it; closed
      `shift_records` continue to be written without the triplet.**
      Folded into `8.live-and-closed-truth.wire-in` follow-up slice.
- [ ] **Data Accuracy keyed service-period settings.** Replace hardcoded
      lunch/dinner/late covers-source columns with
      `data_accuracy_service_period_settings` before fourth/custom periods
      are operator-configurable.

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
