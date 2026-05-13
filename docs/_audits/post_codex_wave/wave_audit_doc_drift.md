# Wave Audit — Doc Drift + Migration Queue Count

**Master tip:** `63b67753` (declared audit tip; worktree HEAD `63ec00d6` includes it; `origin/master` is at `260e3da8` with three additional PRs but they post-date the audit dispatch and do not change the substance of the doc-drift findings below)
**Auditor:** read-only agent (7 of 8)
**Dimension:** Cross-doc drift, migration queue arithmetic, ledger count math, audit-doc completeness

## Verdict

**FAIL (doc-drift batch — non-blocking for code but the docs no longer agree on the queue size or the slice count).**

The wave shipped 61 ledger slices and merged 60 of them, plus a wave's worth of migrations, but the bookkeeping has drifted in four observable ways:

1. **`docs/POST_HARDENING_FOLLOWUPS.md` Production1 queue is 19 migrations short.** Declared count `46`, table rows `46`, but `db/migrations/` post-`202605031430` (the start of the staging-additions window the runbook covers) holds **65** files. Net: 19 files exist on master that no Production1-apply doc has ever heard of. Highest-impact orphan is `202605131550_benchmark_overrides_hierarchy.sql` (B6 / PR #634, merged this wave); the other 18 are older Phase 8 / Phase 9 / Phase 10a / Phase 11A migrations that landed across 2026-05-04 → 2026-05-08 and never got rolled into either the runbook's "Current known post-cutoff staging additions" list or the POST_HARDENING table.
2. **`docs/_indices/WAVE_EXECUTION_LEDGER.md` "Counts" section disagrees with its own table.** Table = 36 Claude / 23 Codex / 2 orchestrator (= 61). Counts bullet = 37 Claude / 22 Codex / 2 orchestrator (= 61 total ✓, but ownership split off-by-one in opposite directions — A0 is listed as Claude in the bullet enumeration but the row says orchestrator). Gate bullets = 20 auto + 34 operator = 54, but the table holds 20 auto + 41 operator = 61. Operator-gate bullet is **7 short**.
3. **`runbooks/phase_9_production1_migration_apply_runbook.md` has a stale interior section header.** Top-of-runbook cutoff (line 10) says `202605131900_c_2_d_vendor_sync_outage_state.sql` (correct); section header at line 648 still reads `### Next follow-up - pending (cutoff '202605080600_phase_8_idempotency_location_id_rekey.sql')`. Body items inside that section have been extended to the current cutoff, but the section title was never bumped.
4. **`session_handoff.md` is six bundles stale.** Says "Total slices: 47. Merged: 24. Assigned: 23." Actual on master: 61 / 60 / 1.

The 5-doc cutoff filename mirror is consistent at the canonical line in each doc (all five agree on `202605131900_c_2_d_vendor_sync_outage_state.sql`). All merged-PR audit docs are present (60/60 hits, no missing audit files). `docs/KNOWN_FAILING_TESTS.md` content is current. `docs/archive/**` hygiene is clean (no "Closed"-status active phase docs found).

---

## Migration queue count audit

Declared cutoff in POST_HARDENING_FOLLOWUPS line 35: "queue now runs through `202605131900_c_2_d_vendor_sync_outage_state.sql`". Header text claims **46 migrations pending Production1 apply**.

| Source | Count | Match |
|---|---|---|
| `docs/POST_HARDENING_FOLLOWUPS.md` declared (line 34) | 46 | ✓ matches table row count |
| `docs/POST_HARDENING_FOLLOWUPS.md` table row count | 46 | ✓ matches declared |
| `db/migrations/*.sql` files newer than `202604280014_phase_9_0sigma_h2_audit_privacy_role.sql` (the "already-applied to Production1 2026-05-03" upper boundary stated in runbook line 24) | **92** at audit tip `63b67753` | — (the 92 = 27 already-applied first batch + 65 post-2026-05-03) |
| `db/migrations/*.sql` files post-`202605031430` (the start of the runbook's "Current known post-cutoff staging additions" window — i.e. the post-applied-batch window the POST_HARDENING table is supposed to enumerate) | **65** at audit tip `63b67753` | ✗ table covers only 46 of 65 → **19-file gap** |
| Newest filename declared in POST_HARDENING (`202605131900_c_2_d_vendor_sync_outage_state.sql`) | matches actual newest at `63b67753` | ✓ |

**Drift:** 19 migration files have landed on master without making it into the POST_HARDENING Production1-pending table. The runbook's "Current known post-cutoff staging additions" list (lines 112-215) also omits them. They are:

```
202605040000_phase_8_0_integration_framework.sql
202605040100_phase_9_8_tos_versions.sql
202605040200_phase_9_8_email_provider.sql
202605040300_phase_10a_2_dead_letter.sql
202605040400_phase_8_0_lifecycle_add_vendor_lifecycle_notification.sql
202605050000_phase_8_data_accuracy_settings.sql
202605050100_phase_8_0a_polling_event_kinds.sql
202605050200_phase_10a_3_event_outbox_retention.sql
202605050300_phase_10a_4_event_outbox_publish_metrics.sql
202605050400_phase_10a_5_subscription_watermark.sql
202605050400_phase_8_business_date_denorm.sql
202605051000_phase_10a_3_outbox_retention_sweep.sql
202605061900_phase_8_star_target_truth.sql
202605071400_advisor_response_cache_table.sql
202605071500_phase_9_mfa_factor_removal_attempt_count.sql
202605071800_actor_kind_constraint_consolidation.sql
202605071900_phase_8_set_business_date_hardening.sql
202605072000_feature_flags_sentinel_operator.sql
202605131550_benchmark_overrides_hierarchy.sql
```

Two ways these 19 could legitimately be absent from a "Production1 pending" list:
- They were applied to Production1 in a third batch (between 2026-05-03 and now) that was never recorded in the runbook's Apply History. Runbook documents only 2026-04-29 first batch + 2026-05-03 second batch.
- They are intentionally classed as "already-shipped via the same staging instance as the first / second batch" and got dropped from the table by an undocumented bookkeeping rule.

Neither is documented. If a Production1 apply is dispatched against the POST_HARDENING table as-of `63b67753`, only 46 of the 65 actual additions would run. The remaining 19 — including B6's `202605131550_benchmark_overrides_hierarchy.sql` (just merged this wave) — would silently miss the apply event. This is exactly the failure mode the runbook calls out at lines 105-110 (`anything outside the cutoff range is gated by tool/migration_cutoff_lint.dart`), and the cutoff lint enforcement is `scripts/postgres_staging_setup.ps1` only — POST_HARDENING and the runbook scope list have no automated enforcement.

**Recommendation:** the next Production1 batch dispatch should reconcile POST_HARDENING + the runbook scope list against `git ls-tree origin/master db/migrations/` and either (a) document a third-batch Apply History entry covering whichever of these 19 are actually applied, or (b) append the unapplied ones to the queue.

---

## Cutoff-filename consistency across 5 mirror docs

Canonical cutoff filename (at audit tip): `202605131900_c_2_d_vendor_sync_outage_state.sql`.

| Mirror doc | Cutoff line | Value | Match |
|---|---|---|---|
| `docs/POST_HARDENING_FOLLOWUPS.md` | L35 "runs through `…1900_c_2_d…`" + L85 table row | `202605131900_c_2_d_vendor_sync_outage_state.sql` | ✓ |
| `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` | L155 "including the later cron … `…1900_c_2_d…`" | `202605131900_c_2_d_vendor_sync_outage_state.sql` | ✓ |
| `docs/phases/phase_9/phase_9_execution_backlog.md` | L149 + L179 + L181 | `202605131900_c_2_d_vendor_sync_outage_state.sql` | ✓ |
| `runbooks/phase_9_production1_migration_apply_runbook.md` | L10 + L98 + L108 | `202605131900_c_2_d_vendor_sync_outage_state.sql` | ✓ |
| `scripts/postgres_staging_setup.ps1` | L49 (inside `# MIGRATION_CUTOFF_BEGIN/END` lint sentinels) | `202605131900_c_2_d_vendor_sync_outage_state.sql` | ✓ |

**All five canonical cutoff lines agree.** The lint surface at `tool/migration_cutoff_lint.dart` covers `postgres_staging_setup.ps1` only, but in practice the bookkeeping convention has kept the other four in lock-step.

### Caveat — interior stale-cutoff text in the runbook

`runbooks/phase_9_production1_migration_apply_runbook.md` line 648 has a stale section header:

```
### Next follow-up - pending (cutoff `202605080600_phase_8_idempotency_location_id_rekey.sql`)
```

The body of that section was extended to cover migrations through `202605131900_c_2_d_…`, but the section title was never updated. Cosmetic — won't mislead a careful reader because the in-scope list at line 98 is correct — but worth fixing in the next sweep.

---

## Ledger consistency

`docs/_indices/WAVE_EXECUTION_LEDGER.md` slice table (counted by grep at the audit tip):

| Metric | Table actual | "Counts" section declared (L105-110) | Match |
|---|---|---|---|
| Total slice rows | 61 | 61 | ✓ |
| Owner = Claude | 36 | 37 (and the L106 bullet enumerates 37 IDs including `A0`, which the table assigns to `orchestrator`) | ✗ off by +1 |
| Owner = Codex | 23 | 22 (but the L107 bullet enumerates 23 IDs) | ✗ off by -1 |
| Owner = orchestrator | 2 | 2 | ✓ |
| Owner row sum | 61 | 61 | ✓ (the +1/-1 cancel) |
| State = merged | 60 (59 plain merged + 1 "merged (matrix; operator picks recorded 2026-05-13)") | — | — |
| State = assigned | 1 (`C-12`) | "Assigned: 23" per session_handoff (stale; ledger does not declare this directly) | ✗ stale by 22 |
| Gate = auto | 20 | 20 | ✓ |
| Gate = operator | 41 | 34 | ✗ **off by -7** |
| Gate row sum | 61 | 54 | ✗ off by -7 |

**Root cause for the gate drift:** the Counts bullet on L110 was last updated at the L_A1/L_A2/C-1a addition (text: "+34 — A3.3 + A3.4 are operator — proxy-touching; L_A1 + L_A2 + C-1a are operator — schema-touching migrations"); the subsequent operator-gate additions (C-2-C, C-2-D, C-2-F, C-7a, B11.2.b, B5.b, B2.1, B6, B8, B8.b, C-2-D-binding, etc.) never bumped the count.

**Root cause for the owner drift:** `A0` is listed in the L106 Claude enumeration (positionally — first in the comma list) but the row at L31 assigns `A0 → orchestrator`. The trailing parenthetical "plus orchestrator A0/C-12" hints at the dual-listing intent, but the leading `**37**` is still computed as if A0 belongs to Claude. Same `A0` overlap appears in the Codex bullet's missing slice ID — the L107 enumeration has 23 entries, but the bold count says `**22**`.

**Owner enumeration sanity check vs ledger table:**

```
Claude (36): A10.1, A11.1, A11.1.b, A11.2, A3.1, A3.2, A3.3, A3.4, A4.1, A4.2,
             A7.1, B1.a, B1.b, B1.c, B11.1, B11.2, B11.2.b, B2.1, B2.2, B2.3,
             B2.4, B8, B8.b, C-1, C-11, C-1a, C-2, C-2-C, C-2-D, C-2-D-binding,
             C-2-Del, C-2-F, C-7a, C-8, L_A1, L_A2
Codex  (23): A2.1, A2.2, A5+A8, A6.1, A9.1, B10.1, B10.2, B3, B4, B5, B5.b, B6,
             B7.a, B9.1, B9.2, B9.3, C-10, C-3, C-4, C-5, C-6, C-7, C-9
Orch.  (2):  A0, C-12
```

---

## Audit doc completeness

Cross-reference of every merged ledger PR (`merged` state) → audit doc filename match in `docs/_audits/post_codex_wave/`.

- Ledger merged PRs distinct count: **59** (matches 60 merged rows minus C-2 which is in special state "merged (matrix; operator picks recorded 2026-05-13)" but still has PR #617 with audit doc)
- Audit-doc PR numbers (extracted from `pr_<N>_*_audit.md` filenames): **77 distinct**
- Missing audit docs for merged ledger PRs: **0**
- Audit docs present but not in the ledger PR list (housekeeping / follow-up / pre-wave): 15 (`#473, #476, #481, #482, #484, #488, #490, #495` from pre-wave; `#539, #542, #588, #604, #610, #625, #630` are wave-internal housekeeping — doc-hygiene, CI-gate, test fixes, and the superseded B6 PR #630 that PR #634 replaced)

**Audit-doc completeness verdict: PASS.** Every merged-slice PR in the ledger has a corresponding `pr_<N>_*_audit.md` file. The 15 "extras" all correspond to documented housekeeping artifacts or pre-wave bundle work, with the lineage written in the ledger change-log.

---

## KNOWN_FAILING_TESTS hygiene

Current content of `docs/KNOWN_FAILING_TESTS.md` (1 active entry):

| File | Notes | Discovered | Owning slice |
|---|---|---|---|
| `test/pressure/p3c_oauth_refresh_storm_runner_test.dart` | Two assertions in "Closure registry coverage" group drift from production: (a) `oauth-flavored vendors NOT in worker registry` expects `containsAll(['agendrix','opentable','adp','sevenrooms'])` but registry is now `['sevenrooms','agendrix']`; (b) `worker registry wires exactly the 11 expected OAuth vendors` expects `hasLength(10)` but actual is `hasLength(12)`. | 2026-05-12 | follow-up — re-pin assertions against current `buildProductionRefreshClosures` + `kVendorsWithoutRefreshClosure` |

**Verdict — valid:** the entry was added during A10.1 (PR #523) per the ledger change-log; the underlying drift is still present on master at the audit tip (the test was relocated `test/load/pressure/` → `test/pressure/` per A10.1's `git mv`, and the assertion shape has not been re-pinned).

**Wave residuals that should have been added but weren't:** the ledger change-log records several "pre-existing test failures" disclosed by workers during the wave that did NOT get added to KNOWN_FAILING_TESTS:

- B2.3 worker disclosed "5 pre-existing test failures in `test/proxy/`" (ledger L184). Investigated and **closed by PR #610** (2 stale snapshots fixed) + **PR #588** (1 stale snapshot fixed) + **PR #625** (1 stale snapshot fixed) + **PR #604** (1 wall-clock time-bomb fixed). So all 5 are now closed and correctly absent from KNOWN_FAILING_TESTS.
- A3.4 worker disclosed `admin_cors_bootstrap_test.dart` 5 pre-existing failures (ledger L37). Closed by PR #588.
- C-5 worker disclosed `test/proxy/b11_2_b_step_up_wiring_test.dart:175` failure. Closed by PR #604.

**Wave residuals — net:** zero open. The single entry that is in the file is still valid. **Verdict: PASS.**

---

## `docs/archive/**` hygiene

CLAUDE.md "Phase Doc Hygiene": closed phase docs retire to `docs/archive/phases/` within a week.

Spot-checked every phase doc with `^Status:` header in `docs/phases/`:

| Phase doc | Status line | Verdict |
|---|---|---|
| `phase_10b/phase_10b_full_offline_sync_plan.md` | "Planned, post-launch" | active — correct |
| `phase_11A_operations_console/phase_11A_operations_console_plan.md` | "Active. Foundation slices … accepted. Cross-operator parity slices ACCEPT 2026-05-06 …" | active — correct |
| `phase_11W/phase_11W_operator_web_console_plan.md` | "Active. Six self-service Settings parity slices ACCEPT 2026-05-06 …" | active — correct |
| `phase_11a/phase_11a_decision_register.md` | "Active decision authority" | active — correct |
| `phase_11b/phase_11b_advisor_ux_plan.md` | "Planned (gated on B43 prod anchor deploy …)" | active — correct |
| `phase_12_workflow_platform/…` | "Planned" | active — correct |
| `phase_8/vendor_master_list.md` | "Locked scope for Phase 8 / 8R / 8.S …" | active — correct |
| `phase_8_5_external_integrations/…` | "Planned (opens between 8R and Phase 12)" | active — correct |
| `phase_8_live_rollout/…` | "Open — rolling …" | active — correct |
| `phase_9/phase_9_auth_plan.md` | "Accepted for next-phase handoff" | borderline — accepted ≈ closed, but the doc itself names the next-phase handoff continuing surface |
| `phase_9/phase_9_decision_lock_2026-04-26.md` | "LOCKED by user approval" | reference artifact — appropriate to keep |
| `phase_9/phase_9_scalability_decisions_2026-04-27.md` | "RECONCILED" | reference artifact — appropriate to keep |
| `phase_9_5/…` | "Active. `9.5.0` accepted 2026-05-03 …" | active — correct |
| `phase_9_75/…` | "Planned" | active — correct |
| `phase_9_8/…` | "Launch-blocking; queued sequentially …" | active — correct |
| `phase_business_timing_live/…` | "foundation + UI shell merged; live producer/proxy write paths still gated" | active — correct |

**Verdict — PASS.** No active phase docs flagged as "Closed" that should have moved. The Phase 9 docs that are "Accepted" / "LOCKED" / "RECONCILED" are decision-anchor artifacts cross-referenced from current phase docs and CLAUDE.md authority order; retiring them would break those references. Treat as durable reference, not stale-content drift.

---

## Contracts freshness

The wave touched several contracts. Spot-check:

| Contract | Updated date / status | Wave-touch evidence | Drift? |
|---|---|---|---|
| `demo_mode_contract.md` | "**Status:** Locked. Audited end-to-end 2026-05-07." | Wave added **Carve-out #4** (C-4 PR #592). `Carve-out #4: Settings screen master Demo -> Live switch` is present at L329. Header still says "Locked. Audited 2026-05-07" but body has been edited to four carve-outs. | Minor: header date hasn't been bumped to reflect the 2026-05-13 Carve-out #4 amendment. Cosmetic. |
| `hardening_rls_and_repository_pattern_contract.md` | "Updated: 2026-05-02" | Wave landed `OperatorScopedRepository<T>` consumers (B11.1, B11.2, B11.2.b, B10.1, L_A1, L_A2). | Header date stale — has not been refreshed to reflect 2026-05-13 wave additions. Body content not audited cell-by-cell. |
| `auth_permission_key_catalog.md` | (not header-dated; tri-mirrored with `lib/auth/permission_keys.dart`) | B5.b added `account.configure` + `business_timing.configure` to the catalog (PR #573); tri-mirror passes per the `permission_catalog_b5b_test.dart`. | Tri-mirror consistent. No drift. |
| `core_app_architecture.md` | (not header-dated) | Wave honored Layers 1-12 invariants per the pattern-B audit citations in every PR audit doc. | Not audited for line-level drift in this dimension. |

**Verdict — minor advisory:** two contracts have stale `Updated:` headers (`demo_mode_contract.md` and `hardening_rls_and_repository_pattern_contract.md`). Bumping them is opportunistic next time anyone is in the file.

---

## Cross-reference rot — spot-check

Sample of 18 cross-references from `docs/POST_HARDENING_FOLLOWUPS.md` that the wave's changes might have invalidated:

| Reference | Target exists? |
|---|---|
| `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-07_phase_8_plug_and_play.md` | ✓ |
| `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md` | ✓ |
| `docs/archive/_execution/2026-05-09_security_finding_webhook_signature_ordering.md` | ✓ |
| `docs/phases/proxy_split/proxy_split_plan.md` | ✓ |
| `docs/contracts/auth_permission_key_catalog.md` | ✓ |
| `docs/contracts/demo_mode_contract.md` | ✓ |
| `docs/contracts/hardening_rls_and_repository_pattern_contract.md` | ✓ |
| `docs/contracts/core_app_architecture.md` | ✓ |
| `tool/migration_drift_scanner.dart` | ✓ |
| `tool/migration_cutoff_lint.dart` | ✓ |
| `tool/audit_anchor/azure_blob_client.dart` | ✓ |
| `docs/_audits/post_codex_wave/pr_537_a11_2_soak_harness_extensions_audit.md` | ✓ |
| `docs/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md` | ✓ |
| `docs/archive/_execution/2026-05-08_pressure_preview_findings.md` | ✓ |
| `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md` | ✓ |
| `docs/archive/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md` | ✓ |
| `runbooks/admin_provider_credentials_kms_rollout_runbook.md` | ✓ |
| `runbooks/admin_console_browser_qa_runbook.md` | ✓ |

**Verdict — PASS:** all 18 sampled cross-references resolve. No reference rot detected in the wave-touched footprint.

---

## `session_handoff.md`

Location: `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/session_handoff.md` (NOT in-repo; user-local).

Content (47 lines, within the 40-line cap declared by CLAUDE.md is **violated by 7 lines** — additional drift):

```
## Last Updated
2026-05-13 03:45Z — Post-Codex wave 24/47 merged. Claude lane restart pending (loop-mode).

## Wave State Snapshot (2026-05-13 03:45Z)
- Master tip: `0973d693` (bundle 24 — B1.c + A3.2 ledger flips).
- Total slices: 47. Merged: 24. Assigned: 23. Audit-pending: 0. Operator queue: empty.
- B11.2.b fully unblocked (3 deps merged: B11.2 + A3.2 + A4.2). Highest-leverage Claude pickup.
```

Actual master state at audit tip:

- Master tip: `63b67753` (Bundle 50 closure)
- Total slices: **61** (not 47)
- Merged: **60** (not 24)
- Assigned: **1** (only C-12 remains; not 23)
- Wave is **closed** in everything but C-12; the loop-mode restart that the handoff is pointing toward already happened (per the A11.1.b ledger note: "First Claude lane PR post-loop-mode restart — Pattern B drift trend reversed from 4/4 pre-restart → 0/2 post-restart")

**Verdict — STALE by ~6 hours of wave progress.** Handoff content reflects state ~03:45Z; the wave kept going through Bundle 50 closure. The file also exceeds the 40-line cap (47 lines). User-local file — the CLAUDE.md authority order rules dictate "Not prompt authority; don't reread mid-execution," so this drift won't mislead an in-flight slice, but the next-session handoff would be wrong if the file isn't refreshed before close-out.

---

## Lane index `docs/_execution/lane_*/0X_*.md`

Lanes present:

```
docs/_execution/lane_a_code_health/
docs/_execution/lane_b_features/
docs/_execution/lane_c_parity/
```

Note: the audit prompt asked about a `lane_b_hierarchy_finalization/` directory. **That directory does not exist in the repo.** Hierarchy work landed inside `lane_b_features` and `lane_c_parity` (L_A1, L_A2, B6, B8, B8.b, C-6) rather than as a separate lane. No drift here — just a prompt assumption that doesn't match the codebase.

Lane `03_execution_slices.md` spot-check (does the spec match what shipped?):

- **Lane A** (`03_execution_slices.md` line 41-409): enumerates A0, A2.1, A2.2, A3.1, A3.2, A4.1, A4.2, A5+A8, A6.1, A7.1, A9.1, A10.1, A11.1, A11.2 — 14 slices. Ledger added 4 mid-wave slices not in the spec doc: A3.3, A3.4, A11.1.b, plus the L_A1/L_A2 hierarchy primitives. Spec doc has not been amended to reflect these additions; ledger change-log is the only source of truth for the new rows.
- **Lane B** (`03_execution_slices.md` line 38-198): enumerates B1.a, B1.b, B2.1, B2.2, B3, B4, B5, B6, B7.a, B8, B9.1, B9.2, B9.3, B10.1, B10.2, B11.1, B11.2 — 17 slices. Ledger added 5 mid-wave slices not in spec doc: B1.c, B5.b, B11.2.b, B2.3, B2.4, B8.b. Same pattern — spec doc is the slice-planning artifact, ledger is the live state.
- **Lane C** (`03_execution_slices.md` line 9-227): enumerates C-1 through C-12 — 12 slices. Ledger added 5 mid-wave prereqs/follow-ups not in spec doc: C-1a, C-2-C, C-2-D, C-2-D-binding, C-2-F, C-2-Del, C-7a.

**Verdict — advisory drift, not blocking.** The lane spec docs (`03_execution_slices.md` per lane) are the at-dispatch-time slice plan, and the ledger is the live wave state. The convention in the change-log entries (every mid-wave row addition records `(new — 2026-05-13 …)`) is consistent with treating the ledger as authority and the spec docs as historical record. Closeout doc (`wave_closeout_checklist_DRAFT.md` exists) is the natural place to reconcile spec vs ledger; spec-doc backfill is a candidate cleanup for C-12.

---

## Findings

### F1 — POST_HARDENING_FOLLOWUPS Production1 queue is 19 migrations short

**Severity:** P1 — operational; a Production1 apply driven off this table would miss 19 files, including a wave-merged migration (`202605131550_benchmark_overrides_hierarchy.sql`, B6 / PR #634).

**Evidence:**

- `git ls-tree origin/master db/migrations/` at audit tip `63b67753` returns 65 files dated post-`202605031430` (the start of the runbook's "Current known post-cutoff staging additions" window).
- POST_HARDENING table holds 46 rows.
- Diff: 19 files exist on master, ALL post-2026-05-03, that no Production1-apply doc references.

**Action:** the next Production1-apply prep must reconcile `db/migrations/` against POST_HARDENING. Either (a) add the missing 19 to the queue, or (b) document a third Apply History batch entry (Apply History only shows 2026-04-29 + 2026-05-03 batches).

### F2 — WAVE_EXECUTION_LEDGER Counts section disagrees with its own table

**Severity:** P2 — bookkeeping; no operational impact, but the next-session orientation depends on these numbers.

**Drift:**
- Claude owner declared **37**, table actual **36** (`A0` counted as Claude in the L106 enumeration but the row says `orchestrator`).
- Codex owner declared **22**, table actual **23** (the L107 enumeration lists 23 IDs).
- Operator-gate declared **34**, table actual **41** (off by 7 — last bumped at L_A2/C-1a, never updated as the 7 newer operator-gate slices were added).

**Action:** one-line correction. Pure ledger edit.

### F3 — runbook stale interior section header

**Severity:** P3 — cosmetic.

**Evidence:** `runbooks/phase_9_production1_migration_apply_runbook.md:648` reads `### Next follow-up - pending (cutoff '202605080600_phase_8_idempotency_location_id_rekey.sql')` but the body covers migrations all the way to `…1900_c_2_d_…`. The cutoff line at the top of the runbook (L10) is correct.

**Action:** rename the section header to match the canonical cutoff. Opportunistic.

### F4 — `session_handoff.md` is six bundles stale and exceeds the 40-line cap

**Severity:** P3 — user-local file; CLAUDE.md classifies it as "Not prompt authority."

**Evidence:** says "Total 47, Merged 24, Assigned 23"; actual is 61/60/1. Also 47 lines vs the 40-line cap.

**Action:** refresh + trim during the next wrap-up turn.

### F5 — Lane spec docs `03_execution_slices.md` are at-dispatch snapshots, not live state

**Severity:** P3 — advisory, not drift in the classic sense.

**Evidence:** the lane spec docs don't enumerate mid-wave-added slices (A3.3/A3.4/A11.1.b/L_A1/L_A2/B1.c/B5.b/B11.2.b/B2.3/B2.4/B8.b/C-1a/C-2-C/C-2-D/C-2-D-binding/C-2-F/C-2-Del/C-7a — 17 slices added during the wave). This is intentional per the change-log convention but worth either (a) documenting in each lane spec's header that the ledger is authority for live additions, or (b) backfilling at closeout.

**Action:** candidate cleanup for C-12 closeout slice.

### F6 — Two contracts have stale `Updated:` headers

**Severity:** P3 — cosmetic.

**Evidence:**
- `docs/contracts/demo_mode_contract.md` header still says `Audited end-to-end 2026-05-07` but Carve-out #4 was added at the wave close (2026-05-13).
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` says `Updated: 2026-05-02` but the wave landed 6+ new `OperatorScopedRepository<T>` consumers (B11.1, B11.2.b, B10.1, L_A1, L_A2, C-2-D, C-2-D-binding).

**Action:** bump headers when next in the file.

---

## Authority anchors

- `CLAUDE.md` — Phase Doc Hygiene rule (closed phase docs retire within a week); Session Handoff 40-line cap rule; doc-drift discipline as a hard guardrail.
- `docs/POST_HARDENING_FOLLOWUPS.md` (lines 22-89) — the canonical Production1 migration queue.
- `runbooks/phase_9_production1_migration_apply_runbook.md` (lines 1-110 scope; lines 590+ Apply History) — the operational queue and apply log.
- `docs/_indices/WAVE_EXECUTION_LEDGER.md` (lines 27-100 slice table; lines 101-110 Counts) — the live wave state.
- `tool/migration_cutoff_lint.dart` — only the staging setup script is automatically guarded; the other 4 mirror docs rely on manual discipline.
- `tool/migration_drift_scanner.dart` — runs the additive migration check but does not enforce the 5-doc consistency loop.
