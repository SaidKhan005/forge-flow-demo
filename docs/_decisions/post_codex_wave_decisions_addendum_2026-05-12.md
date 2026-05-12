# Post-Codex Wave Decision Addendum — 2026-05-12

Status: LOCKED by user approval (single "all defaults accepted" message on 2026-05-12, immediately after the R1–R4 + A1 + C research/audit wave completed).

Extends `post_codex_wave_decisions_2026-05-12.md`. Both docs together form the authoritative decision set for the post-Codex wave.

This addendum captures decisions raised by the research wave that either re-opened or refined the original 8 locks, plus operational and wave-shaping decisions surfaced during synthesis.

## How to read this doc

- **Block A** — architecture and contract decisions. Override or refine the original locks where named.
- **Block B** — operational decisions for work that ships immediately (during the in-flight Codex wave).
- **Block C** — wave-shaping decisions that bind the structure of the post-Codex plan docs.

When this addendum conflicts with the original `post_codex_wave_decisions_2026-05-12.md`, this addendum wins (it is newer).

## Block A — Architecture

| # | Decision | What it does |
|---|---|---|
| **A1** | **Re-open and re-lock decision #5 (mobile → ops-web handoff).** The original "reuse mobile JWT in deep link" lock is **superseded** by **redemption-code handoff with RFC 9470 step-up challenge for fresh-MFA gating**. Mobile asks proxy for a one-time short-TTL opaque code; deep link carries the code; browser redeems the code at the proxy for its own fresh session. Sensitive landings (account edits, MFA enroll, role mutations, billing) require fresh-MFA step-up via RFC 9470 challenge before content renders. | Operator-visible UX is identical to the original lock. Security posture moves from OWASP-flagged anti-pattern (JWT-in-URL → referer/log/history/email-gateway leak) to industry standard. Cost: ~1 day extra proxy work (one new endpoint + redemption table). |
| **A2** | **Refine decision #2 (Default Role catalog inheritance):** swap **Push** (per-business physical copy on F&F admin edit) for **Pull** (single versioned catalog + per-business version pointer). Pattern: OPA bundle / AWS AppConfig / LaunchDarkly. Each business stores only its pinned catalog version; resolution joins at read time. | Same operator behavior. Cleaner audit trail of catalog changes (one timeline, not N copies). Easier rollback. Smaller storage. |
| **A3** | **Refine decision #8 (audit log hierarchy filter):** keep read-side join; **add Postgres `ltree` column on hierarchy tables + descendant-set cache** to keep the join fast at 200+ locations per operator. No denormalization onto `audit_logs`; hash chain stays intact. | Cheap performance improvement. Re-open trigger from the original lock (filter latency at scale) gets a preemptive answer. |
| **A4** | **Confirm Postgres-native authorization. No external ReBAC engine (no OpenFGA, no SpiceDB).** Roles, permissions, dependency cascades, and effective-permission resolution all live in Postgres alongside `audit_logs`. | Avoids a second source of truth fighting hash-chain atomicity. Single durable store for all authorization state. |
| **A5** | **Permission dependency cascade resolved UI-side, not DB-side.** When an operator selects a permission, the editor expands it into its full dependency closure and stores the expanded set in `role_permissions`. No DB triggers, no recursive CTEs at read time. | Path A from R2. Faster reads, easier to test, transparent to operators. Trade-off: storage is slightly redundant; acceptable given role count is small. |
| **A6** | **Vendor-applicability list schema:** one Postgres table `vendor_applicability` with `setting_kind` discriminator column (values: `wage`, `covers`, `polling`, future) + JSONB `metadata` column for per-kind extras + `effective_from` / `effective_until` temporal columns. Admin-editable through admin console; auto-syncs to ops web reads. | Avoids EAV anti-pattern. Single CRUD surface for three feature areas. Supports temporal edits (e.g., "as of next quarter, wage authority covers this vendor"). |
| **A7** | **Adopt expand-contract migration convention.** New convention: `db/migrations/post_deploy/` directory holds destructive / contract-phase migrations that run only after the corresponding feature deploy. CI lint forbids `UPDATE audit_logs` outside an explicit allowlist (chain integrity guardrail). | Locks in the safer migration pattern. Prevents future audit-chain corruption from a careless schema change. |

## Block B — Operational

| # | Decision | What it does |
|---|---|---|
| **B1** | **Hot-fix the two proxy bugs immediately in a Claude worktree, parallel to Codex.** Single slice scoped: `runZonedGuarded` wrap around `main()` + sign-in contract alignment (decide client adds operator-picker step OR proxy accepts scope-less claims for `ff_support`/`super_admin`) + the 6 instrumentation log lines A1 recommended. No code overlap with Codex's in-flight slices (proxy code is outside the admin UX wave). | Stops the proxy crash + the F&F support / super-admin sign-in failure that operators are seeing today. Doesn't touch any code Codex is currently shipping. |
| **B2** | **Soak harness ships in the same slice as B1.** Specifically: extend `tool/pressure/p3*` with `p4_session_soak.dart` + `p4_operator_day_soak.dart`; add `SessionRecord.assertComplete()` predicate; add Postgres pool gauges via `/health`; add `pubsub_subscriber.ring_buffer_keys` gauge. Quick-win subset only (R3 §3 quick-wins, ~6 days). | The harness is the regression test for the bugs B1 fixes. Shipping them together means recurrence triggers a red CI run, not an operator outage. |
| **B3** | **Fix the three silent email-failure paths immediately, in its own minimal slice.** Targets: `notif.backfill.complete`, `notif.backfill.failed`, `notif.audit.anchor_failure`. Action: register the missing template IDs in `EmailTemplateIds.all`, create the three Markdown templates under `tool/advisor_proxy/email_templates/`, add typed-catch + log line at the fanout swallow site so future template misses surface. | Stops the silent failure. Operators start receiving the three backfill / audit emails they were always supposed to. Pattern (catch + log at fanout) protects against future template misses. |
| **B4** | **Defer the dual invite path decision** (Firebase password-reset-email reuse vs the unwired `operator_admin_invite` SendGrid template) **to the code-health wave** when invite flows get a holistic audit. No action until then. | Not blocking. Deserves a real look across the full auth/invite surface. |
| **B5** | **Bundle all 6 research / audit briefs (R1, R2, R3, R4, A1, C) into one PR to master.** Path: `docs/_research/post_codex/r{1-4}_*.md` + `docs/_audits/code_health/{a1, c}_*.md`. | Keeps the doc system coherent. Single reference point for downstream prompts. |

## Block C — Wave shaping

| # | Decision | What it does |
|---|---|---|
| **C1** | **Combine R1 items #1, #2, #5, #6 into one "Trust & Account Control" UX track.** Role + permission editor + Default Role catalog admin + adaptive 2FA button + mobile→ops-web handoff confirmation prompt. One coherent design language; one plan doc; one execution slice cluster. | Matches Stripe / Microsoft Entra / Auth0 / GitHub product pattern. Avoids the patchwork look from scattered slices. |
| **C2** | **Build one shared "Inheritance Tree" component as a code-health A-lane prerequisite** to all feature lanes that need it. Consumers: Codex's scope pane (additive polish layer), blended wage mix table, role inheritance display, hierarchy breadcrumbs. | Build once, reuse three times. Sequencing: lands before any feature lane that depends on it. |
| **C3** | **Email pipeline gets its own code-health lane.** Scope: wire the 6 locked-but-unwired templates OR delete the scaffolding (operator-by-operator decision), fix the 3 silent failures (B3), resolve the dual invite path (B4), inventory + pressure-test all scenarios using `c_email_notification_scenario_inventory.md` as the source of truth. | Bigger than scoped originally. Substantial enough to be its own lane, not folded into a generic scaffold sweep. |
| **C4** | **The "no scaffold anywhere" directive becomes its own code-health lane (Wave A2 expanded scope).** Email pipeline is the first found example; lens-audit agents (Step 3 of game plan, post-Codex) will surface others. Each scaffolded surface gets a per-feature decision: wire OR delete, never leave dormant. | Directly serves the original dump's "no scaffold" mandate. The pattern almost certainly repeats across the codebase. |

## Cross-references

- The original lock doc: `post_codex_wave_decisions_2026-05-12.md` (same directory).
- Research briefs informing this addendum: `docs/_research/post_codex/r1_ux_patterns.md`, `r2_engineering_patterns.md`, `r3_soak_pressure_testing.md`, `r4_email_notification_testing.md`.
- Audit findings informing this addendum: `docs/_audits/code_health/a1_proxy_bug_root_cause.md`, `c_email_notification_scenario_inventory.md`.

## Change log

| Date | Change |
|---|---|
| 2026-05-12 | Initial addendum capturing 7 architecture, 5 operational, and 4 wave-shaping decisions after the R1–R4 + A1 + C research/audit wave. |
