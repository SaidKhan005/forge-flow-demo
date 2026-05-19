# 03 - Execution Slices (Lane A)

Slice plan for Lane A code-health work. Slices map back to A1-A11 in
`01_product_rule_and_ia.md` and to findings in
`02_plumbing_audit_matrix.md`. Order below is the recommended
dispatch order; parallelization rules follow each slice.

Per `CLAUDE.md` "Agent-Led Slices", each agent contract is:
**commit + push + open PR -> STOP**. No auto-merge. The orchestrator
audits + merges.

Sizing legend:
- **Small**: < 5 files, < 500 LOC, < 1 day agent time.
- **Medium**: 5-20 files, 500-3,000 LOC, 1-3 days agent time.
- **Large**: 20+ files OR > 3,000 LOC OR multi-surface. Apply
  `docs/_audits/audit_chunking_playbook.md` to the audit.

Risk legend:
- **Low**: docs/test-only OR isolated single-file change with
  inline test coverage.
- **Medium**: touches a runtime seam or shared infrastructure.
- **High**: auth-critical, RLS-touching, schema-touching, or
  proxy-touching - requires explicit operator approval before merge
  regardless of audit verdict (per `CLAUDE.md` Workflow).

## Sequencing Constraints

- **A1 is already landed** on master via PR #476 (`c3f1ce0d`).
  Verification probe lives in Slice A0 (below).
- **A11 quick-win is already landed** in the same PR. Remaining A11
  durable work depends on the proxy response handler change in
  Slice A11.2 (below).
- **A5 + A8** ship together: the `post_deploy/` directory + the
  `UPDATE audit_logs` allowlist + the `--require-expand-contract`
  flag are one logical CI-discipline slice.
- **A3** seam-map and bleed-stop lint are independent of all other
  slices but must precede any formal proxy-split phase.
- **A2** scaffold removal is per-surface and can be parallelized
  once the inventory is complete.

## Slice A0 - Verification Probe For B1+B2 Landed Work

Scope: confirm the B1+B2 hot-fix is live and emitting on master.

Files inspected (read-only):

- `tool/advisor_proxy/main.dart`
- `tool/advisor_proxy/advisor_proxy.dart` (`requireOperatorContext`)
- `lib/services/auth/firebase_auth_login_service.dart`
- `tool/pressure/p4_session_soak.dart`
- `tool/pressure/p4_operator_day_soak.dart`
- `tool/pressure/p4_session_record_predicate.dart`
- `test/pressure/p4_session_record_predicate_test.dart`
- `test/advisor_proxy_test.dart`
- `tool/advisor_proxy/health_producers/infra_producers.dart` (pool
  + ring-buffer gauges)

Dependencies: none.

Risk: Low.

Size: Small. < 1 day to confirm + write the probe note.

Acceptance: a short verification report at
`docs/_audits/code_health/a0_b1_b2_post_merge_verification.md` with:
- file fingerprints / line-count snapshots showing
  `runZonedGuarded` + scope-less branch live;
- `dart test test/advisor_proxy_test.dart` passes for the
  scope-less contract case;
- `dart run tool/pressure/p4_session_soak.dart --dry-run` smoke
  runs cleanly;
- the production gauge from R3 §2 is **not yet** wired - that gets
  Slice A11.2.

This slice is the orchestrator's first move; it surfaces any rebase
drift before downstream slices touch the same files.

## Slice A2.1 - Scaffold Inventory + Dead-Code Sweep (Small Pass)

Scope: produce the per-surface wire-or-delete decision matrix for
the cheap easy cases. Delete the dead deferred placeholders.

Files touched (delete-only, no new files):

- `lib/admin/widgets/deferred_admin_screen_placeholder.dart`
  (confirm no callers, delete).
- `lib/operator_web/widgets/deferred_screen_placeholder.dart`
  (confirm no callers, delete).
- `test/` any test that exclusively covers the deleted widgets.

Files inspected (read-only):

- `lib/widgets/metric_card_not_yet_available.dart` (honest scaffold
  per Metric Honesty Doctrine - keep, document).
- `lib/internal/barrio/screens/preston_lee_model_coming_soon_screen.dart`
  (Barrio paused - keep, document).
- All operator-web and admin routes (grep for placeholder usage).

Inventory deliverable:
`docs/_audits/code_health/a2_scaffold_inventory.md` with one row
per surface and a wire-or-delete verdict.

Dependencies: A0 (don't touch files until master verified).

Risk: Low. Pure dead-code deletion + audit doc.

Size: Small.

Authority cited in commit message: addendum C4 ("no scaffold anywhere"),
HP #11 ("operator-facing UX before phase close"), Metric Honesty
Doctrine, Build Toward Production doctrine.

## Slice A2.2 - Email Pipeline Wire-Or-Delete

Scope: per addendum C3, the email pipeline gets its own slice.
Iterate the 14 `Template-only` entries from
`docs/_audits/code_health/c_email_notification_scenario_inventory.md`
and ship a per-template decision.

Two paths per template:

- **Wire**: register a fanout site that calls the existing
  `NotificationEventFanout` hook (pattern from B3) +
  one renderer test.
- **Delete**: remove the template Markdown file + the
  `EmailTemplateIds.<X>` constant + the corresponding entry in
  `EmailTemplateIds.all` + the inventory row.

Files touched (per template decision):

- `tool/advisor_proxy/email_templates/<id>.md`.
- `lib/services/email/email_template_renderer.dart` (`EmailTemplateIds`).
- `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart`
  (wire case).
- The relevant trigger site in the proxy / worker (wire case).
- `test/services/email/email_template_renderer_test.dart`.
- `docs/_audits/code_health/c_email_notification_scenario_inventory.md`
  (status flip).

Dependencies: A2.1 (separate, independent).

Risk: Medium (email is operator-visible behavior change).

Size: Medium. Group of 14 decisions; ship in 2-3 sub-slices of
4-5 templates each.

Authority cited: addendum C3, B3 pattern, HP #11.

## Slice A3.1 - Monolith Seam-Map + Bleed-Stop Lint

Scope: stop `tool/advisor_proxy/advisor_proxy.dart` from growing
further. Produce the seam-map deliverable that the future proxy-split
phase consumes.

Files touched:

- `tool/advisor_proxy/advisor_proxy.dart` (read-only inspection).
- `tool/advisor_proxy_size_lint.dart` (new) - fails CI if
  `advisor_proxy.dart` exceeds N lines where N is the current line
  count + 200 (gives modest headroom; rejects routine growth).
- `.github/workflows/<lint workflow>.yml` - wire the lint.
- `docs/phases/proxy_split/proxy_split_plan.md` - append the
  seam-map table (line ranges per cluster).
- `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` (new) -
  the seam map proper.

Dependencies: A0 (verified base).

Risk: Medium (CI gate that fails noisy PRs).

Size: Small to Medium. Seam map is the bulk of the work.

Authority: HP #4 ("RLS-ready"), Build Toward Production. Cited in
the seam-map README at the top.

## Slice A3.2 - Bare-Catch Tail Chunk 1 (of 3)

Scope: typed-catch the first 4-6 bare `catch (_)` sites in
`advisor_proxy.dart` per the pattern from PR #420.

Files touched:

- `tool/advisor_proxy/advisor_proxy.dart` (4-6 specific line ranges).
- `test/advisor_proxy_test.dart` (one assertion per fixed site).

Dependencies: A3.1 (seam map identifies the next chunk).

Risk: Medium (proxy-touching).

Size: Small per chunk; 3 chunks total = A3.2 / A3.3 / A3.4.

Authority: addendum C4 (no silent failures), PR #420 precedent.

## Slice A4.1 - Performance Audit Pass

Scope: per `PERFORMANCE_FRAMEWORK.md`, measure + flag. No behavior
changes in this slice.

Files inspected (read-only):

- 12 `Timer.periodic` sites enumerated in
  `02_plumbing_audit_matrix.md` Lens 10.
- `lib/screens/shift_dashboard.dart:361, :784, :951, :1329`
  (four-on-one-screen audit).
- `lib/state/connectivity_notifier.dart:53` (cancel-on-dispose
  audit).

Files created:

- `docs/_audits/code_health/a4_performance_audit.md` with
  before-measurements + targeted recommendations + JSON probe paths.

Dependencies: A0.

Risk: Low (read-only).

Size: Small.

Authority: `docs/frameworks/PERFORMANCE_FRAMEWORK.md`.

## Slice A4.2 - Performance Fixes (If Found)

Scope: apply targeted fixes per A4.1 recommendations. Coalesce
duplicates, fix any missing `cancel()` in `dispose`.

Files touched: per A4.1 output.

Dependencies: A4.1.

Risk: Medium.

Size: Small to Medium depending on findings.

## Slice A5+A8 - Schema Versioning + Audit-Log Allowlist Lint

Scope: addendum A7 mandates. Single slice because the three pieces
are one CI-discipline change.

Files touched:

- `db/migrations/post_deploy/.gitkeep` (new directory).
- `db/migrations/post_deploy/README.md` (new) - the convention
  doc.
- `tool/migration_drift_scanner.dart` (add
  `--require-expand-contract` flag).
- `tool/audit_logs_update_allowlist.txt` (new) - empty allowlist
  with a header comment.
- `tool/audit_logs_update_lint.dart` (new) - reads all SQL in
  `db/migrations/**` and fails if `UPDATE audit_logs` appears
  outside the allowlist.
- `.github/workflows/lint.yml` (or equivalent) - add the new lint
  + the drift scanner flag.
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
  (informational; cross-reference only, do not amend the contract
  text in this slice).

Dependencies: A0.

Risk: High (hash-chain integrity guardrail; auth-adjacent because
audit chain is auth evidence). Operator approval required per
`CLAUDE.md` Workflow.

Size: Medium.

Authority: addendum A7. R2 §2 (GitLab expand-contract pattern).

## Slice A6.1 - Proxy Health UI Honesty Pass

Scope: ensure `lib/admin/screens/health_admin_screen.dart` renders
producer state honestly + plain-English remediation copy.

Files inspected and possibly touched:

- `lib/admin/screens/health_admin_screen.dart`.
- `tool/advisor_proxy/health_producers/*.dart` (all 10 producer
  files).
- `lib/admin/services/<health gateway>.dart` (whichever fetches
  `/health`).

Files touched (likely):

- `lib/admin/screens/health_admin_screen.dart` (copy + state
  rendering).

Dependencies: A0.

Risk: Medium (operator-visible UI; Metric Honesty doctrine).

Size: Small to Medium.

Authority: HP #11, Metric Honesty Doctrine.

## Slice A7.1 - Frameworks Cross-Reference Sweep

Scope: pick one canonical path for the framework docs and update
every reference.

Files touched:

- `docs/CODEX_PROMPT_GENERATION_STANDARD.md:33-38` (path
  deduplication).
- `docs/frameworks/README.md` (index update).
- Any phase doc / contract / runbook that double-references
  framework paths (sweep via `rg "docs/frameworks/|docs/PERFORMANCE_FRAMEWORK"`).

Dependencies: A0.

Risk: Low (docs only).

Size: Small.

## Slice A9.1 - lib/data Rehome

Scope: move the two live constants files out of the frozen
delete-only `lib/data/` and delete the rest if no consumer remains.

Files touched:

- `lib/data/app_defaults.dart` -> `lib/domain/constants/app_defaults.dart`
  (move).
- `lib/widgets/lever_card.dart:3` (import update).
- `lib/widgets/week_history_tile.dart:7` (import update).
- `lib/data/cross_axis_pair_catalog.dart` -> `lib/domain/constants/`
  (move if live; delete if no consumer).
- `lib/data/mock_integration_replay_seed.dart` -> review whether the
  mock replay seeder belongs in `lib/dev/` or stays as legacy.
- Any other `lib/widgets/**` or `lib/screens/**` that imports the
  moved files.

Dependencies: A0.

Risk: Medium (broad import update; large test surface).

Size: Medium.

Authority: `CLAUDE.md` service-layer split.

## Slice A10.1 - Test Consolidation Pass

Scope: consolidate pressure tests + close or accept the
`KNOWN_FAILING_TESTS.md` entry.

Files touched:

- `test/pressure/` <- merge with `test/load/pressure/`.
- `test/load/pressure/.gitkeep` removed.
- `docs/KNOWN_FAILING_TESTS.md` - close or flip the entry per
  decision (cross-references Lane B).
- `test/_helpers/` - if duplicate helper code surfaces during the
  merge, consolidate into shared modules.

Dependencies: A0.

Risk: Low (test-only).

Size: Small.

## Slice A11.1 - Production Session-Record Gauge

Scope: wire the R3 §2 stretch goal - proxy emits
`proxy.session_record.incomplete{route, missing_field}` whenever a
2xx response from a session-finalizing route fails
`SessionRecord.assertComplete()`.

Files touched:

- `tool/advisor_proxy/advisor_proxy.dart` (sign-in success + MFA
  finalize + refresh handlers - 3-5 sites).
- `tool/pressure/p4_session_record_predicate.dart` (re-export
  predicate for proxy-side import; refactor if needed).
- `tool/advisor_proxy/health_producers/infra_producers.dart` (or a
  new producer for session-record gauges).
- `test/proxy/<session_record_gauge_test>.dart` (new test).

Dependencies: A0, A3.1 (seam map informs where to add the
producer).

Risk: Medium (proxy-touching, observability-shaped).

Size: Small.

Authority: addendum B2 / R3 §2.

## Slice A11.2 - Soak Harness Durable Extensions

Scope: the R3 quick-win subset deferred from B2.

Files touched:

- `tool/pressure/p4_fd_watcher.dart` (new) - periodic
  `/proc/self/fd` count emitted as a metric.
- `tool/pressure/p4_heap_snapshot_uploader.dart` (new) -
  threshold-triggered Dart heap snapshot uploaded to GCS.
- `tool/pressure/p3c_oauth_refresh_storm.dart` (extend) -
  `--ttl-dist=uniform|normal|bimodal`, `--vendor-mix=equal|power-law`,
  `--jitter=none|full|equal|decorrelated`.
- `test/pressure/<new tests>.dart`.

Dependencies: A11.1.

Risk: Medium (infrastructure; not production user-facing but does
require GCS service-principal permissions).

Size: Medium.

Authority: R3 §3 + §4 quick-wins. Cross-reference:
`runbooks/cloud_run_env_vars.md`.

## Parallelization Map

After A0 completes, the following can run in parallel (disjoint file
ownership):

- A2.1 (scaffold inventory + deferred-placeholder delete) and
  A2.2 (email wire-or-delete).
- A3.1 (seam map + bleed-stop) and A4.1 (performance audit).
- A6.1 (health UI honesty) and A7.1 (framework refs) and A10.1
  (test consolidation).

Serial dependencies:

- A3.2 / A3.3 / A3.4 (bare-catch chunks) must serialize because
  they touch the same monolith file with high line-drift risk.
- A4.2 (perf fixes) after A4.1 (perf audit).
- A11.2 after A11.1 (gauge wires the predicate; durable extensions
  build on top).

## Addendum Decision References (per slice)

| Slice | Addendum decision(s) |
|---|---|
| A0 | B1, B2 (verifying landed work) |
| A2.1 | C4 |
| A2.2 | C3, B3 (pattern) |
| A3.1 | (no addendum; existing `proxy_split_plan.md`) |
| A3.2-A3.4 | C4 |
| A4.1 / A4.2 | (no addendum; PERFORMANCE_FRAMEWORK) |
| A5+A8 | A7 |
| A6.1 | (no addendum; Metric Honesty Doctrine) |
| A7.1 | (no addendum; doc hygiene) |
| A9.1 | (no addendum; service-layer split contract) |
| A10.1 | (no addendum; test hygiene) |
| A11.1 | B2, R3 §2 |
| A11.2 | B2, R3 §3 + §4 |

## Slices NOT Included

These would be cross-lane and are flagged in
`02_plumbing_audit_matrix.md`:

- Default Role catalog publish/sync (Lane B).
- Permission dependency cascade UI (Lane B).
- `ltree` adoption on hierarchy (Lane B).
- Vendor-applicability table (Lane B).
- Redemption-code handoff endpoint + RFC 9470 challenge (Lane B
  surface design; Lane A would only touch proxy endpoint scope
  later).
- Resolving `test/settings_permission_explainer_test.dart`
  (Lane B - copy/resolution drift on a settings-product screen).

## Dispatch Order Summary

1. **A0** (verification probe; orchestrator pre-flight).
2. Then in parallel: **A2.1**, **A3.1**, **A4.1**, **A6.1**,
   **A7.1**, **A10.1**, **A9.1**.
3. Then **A2.2** (after A2.1 inventory), **A4.2** (after A4.1),
   **A5+A8** (after operator approval, high risk).
4. Then **A3.2 -> A3.3 -> A3.4** in series.
5. Then **A11.1**, then **A11.2**.

The next-to-prompt slice (per `05_new_codex_execution_prompt.md`)
is **A0** because every other slice depends on confirming the
master baseline.
